#include <boost/asio.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/version.hpp>
#include <boost/beast/websocket.hpp>

#include <point_cloud_interfaces/msg/compressed_point_cloud2.hpp>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>

#include <sys/poll.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
namespace websocket = beast::websocket;
using tcp = asio::ip::tcp;
using namespace std::chrono_literals;

namespace
{

constexpr uint16_t kProtocolVersion = 1;
constexpr std::size_t kHeaderBytes = 32;
constexpr std::size_t kMaxRgbBytes = 16U * 1024U * 1024U;
constexpr std::size_t kMaxDepthBytes = 16U * 1024U * 1024U;
constexpr std::size_t kMaxCloudBytes = 64U * 1024U * 1024U;
constexpr std::size_t kMaxControlBody = 256;
constexpr std::size_t kMaxCommandOutput = 1024U * 1024U;
constexpr auto kControllerLeaseDuration = 30s;

enum class StreamId : uint8_t
{
  Rgb = 1,
  Depth = 2,
  Cloud = 3,
};

struct Frame
{
  uint32_t sequence = 0;
  int32_t stamp_sec = 0;
  uint32_t stamp_nsec = 0;
  std::string metadata;
  std::vector<uint8_t> payload;
};

std::string json_escape(const std::string & input)
{
  std::ostringstream output;
  for (const unsigned char value : input) {
    switch (value) {
      case '"': output << "\\\""; break;
      case '\\': output << "\\\\"; break;
      case '\b': output << "\\b"; break;
      case '\f': output << "\\f"; break;
      case '\n': output << "\\n"; break;
      case '\r': output << "\\r"; break;
      case '\t': output << "\\t"; break;
      default:
        if (value < 0x20) {
          output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                 << static_cast<unsigned>(value) << std::dec;
        } else {
          output << static_cast<char>(value);
        }
    }
  }
  return output.str();
}

void append_u16(std::vector<uint8_t> & output, const uint16_t value)
{
  output.push_back(static_cast<uint8_t>(value & 0xffU));
  output.push_back(static_cast<uint8_t>((value >> 8U) & 0xffU));
}

void append_u32(std::vector<uint8_t> & output, const uint32_t value)
{
  output.push_back(static_cast<uint8_t>(value & 0xffU));
  output.push_back(static_cast<uint8_t>((value >> 8U) & 0xffU));
  output.push_back(static_cast<uint8_t>((value >> 16U) & 0xffU));
  output.push_back(static_cast<uint8_t>((value >> 24U) & 0xffU));
}

std::vector<uint8_t> serialize_frame(const StreamId stream, const Frame & frame)
{
  if (frame.metadata.size() > std::numeric_limits<uint32_t>::max() ||
    frame.payload.size() > std::numeric_limits<uint32_t>::max())
  {
    throw std::runtime_error("frame is too large for protocol v1");
  }

  std::vector<uint8_t> output;
  output.reserve(kHeaderBytes + frame.metadata.size() + frame.payload.size());
  output.insert(output.end(), {'Z', 'X', 'R', '1'});
  append_u16(output, kProtocolVersion);
  output.push_back(static_cast<uint8_t>(stream));
  output.push_back(0);
  append_u32(output, frame.sequence);
  append_u32(output, static_cast<uint32_t>(frame.stamp_sec));
  append_u32(output, frame.stamp_nsec);
  append_u32(output, static_cast<uint32_t>(frame.metadata.size()));
  append_u32(output, static_cast<uint32_t>(frame.payload.size()));
  append_u32(output, 0);
  output.insert(output.end(), frame.metadata.begin(), frame.metadata.end());
  output.insert(output.end(), frame.payload.begin(), frame.payload.end());
  return output;
}

class LatestFrames
{
public:
  void publish(const StreamId stream, Frame frame)
  {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto & slot = slots_[stream];
      frame.sequence = slot.sequence + 1U;
      slot = std::move(frame);
    }
    condition_.notify_all();
  }

  uint32_t current_sequence(const StreamId stream) const
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto iterator = slots_.find(stream);
    return iterator == slots_.end() ? 0U : iterator->second.sequence;
  }

  std::optional<Frame> wait_new(
    const StreamId stream, const uint32_t after,
    const std::chrono::milliseconds timeout)
  {
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait_for(lock, timeout, [&]() {
      const auto iterator = slots_.find(stream);
      return stopped_ || (iterator != slots_.end() && iterator->second.sequence > after);
    });
    if (stopped_) {
      return std::nullopt;
    }
    const auto iterator = slots_.find(stream);
    if (iterator == slots_.end() || iterator->second.sequence <= after) {
      return std::nullopt;
    }
    return iterator->second;
  }

  void stop()
  {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopped_ = true;
    }
    condition_.notify_all();
  }

private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::map<StreamId, Frame> slots_;
  bool stopped_ = false;
};

class GatewayNode : public rclcpp::Node
{
public:
  explicit GatewayNode(std::shared_ptr<LatestFrames> frames)
  : Node("zed_web_gateway"), frames_(std::move(frames))
  {
  }

  void activate(const StreamId stream)
  {
    std::lock_guard<std::mutex> lock(subscription_mutex_);
    auto & count = clients_[stream];
    ++count;
    if (count != 1) {
      return;
    }

    const auto qos = rclcpp::SensorDataQoS().keep_last(1);
    if (stream == StreamId::Rgb) {
      rgb_subscription_ = create_subscription<sensor_msgs::msg::CompressedImage>(
        "/zed/zed_node/rgb/color/rect/image/compressed", qos,
        [this](sensor_msgs::msg::CompressedImage::ConstSharedPtr message) {
          if (message->data.size() > kMaxRgbBytes) {
            RCLCPP_ERROR_THROTTLE(
              get_logger(), *get_clock(), 5000,
              "Rejected oversized RGB frame: %zu bytes", message->data.size());
            return;
          }
          Frame frame;
          frame.stamp_sec = message->header.stamp.sec;
          frame.stamp_nsec = message->header.stamp.nanosec;
          frame.metadata =
            "{\"frame_id\":\"" + json_escape(message->header.frame_id) +
            "\",\"format\":\"" + json_escape(message->format) + "\"}";
          frame.payload = message->data;
          frames_->publish(StreamId::Rgb, std::move(frame));
        });
    } else if (stream == StreamId::Depth) {
      depth_subscription_ = create_subscription<sensor_msgs::msg::CompressedImage>(
        "/zed/zed_node/depth/depth_registered/compressedDepth", qos,
        [this](sensor_msgs::msg::CompressedImage::ConstSharedPtr message) {
          if (message->data.size() > kMaxDepthBytes) {
            RCLCPP_ERROR_THROTTLE(
              get_logger(), *get_clock(), 5000,
              "Rejected oversized depth frame: %zu bytes", message->data.size());
            return;
          }
          Frame frame;
          frame.stamp_sec = message->header.stamp.sec;
          frame.stamp_nsec = message->header.stamp.nanosec;
          frame.metadata =
            "{\"frame_id\":\"" + json_escape(message->header.frame_id) +
            "\",\"format\":\"" + json_escape(message->format) + "\"}";
          frame.payload = message->data;
          frames_->publish(StreamId::Depth, std::move(frame));
        });
    } else {
      cloud_subscription_ =
        create_subscription<point_cloud_interfaces::msg::CompressedPointCloud2>(
        "/zed/zed_node/point_cloud/cloud_registered/draco", qos,
        [this](point_cloud_interfaces::msg::CompressedPointCloud2::ConstSharedPtr message) {
          if (message->compressed_data.size() > kMaxCloudBytes) {
            RCLCPP_ERROR_THROTTLE(
              get_logger(), *get_clock(), 5000,
              "Rejected oversized Draco frame: %zu bytes", message->compressed_data.size());
            return;
          }
          std::ostringstream metadata;
          metadata << "{\"frame_id\":\"" << json_escape(message->header.frame_id)
                   << "\",\"format\":\"" << json_escape(message->format)
                   << "\",\"height\":" << message->height
                   << ",\"width\":" << message->width
                   << ",\"is_bigendian\":" << (message->is_bigendian ? "true" : "false")
                   << ",\"point_step\":" << message->point_step
                   << ",\"row_step\":" << message->row_step
                   << ",\"is_dense\":" << (message->is_dense ? "true" : "false")
                   << ",\"fixed_frame\":\"zed_camera_link\""
                   << ",\"fixed_translation\":[0.0,0.0,0.0155]"
                   << ",\"fields\":[";
          for (std::size_t index = 0; index < message->fields.size(); ++index) {
            const auto & field = message->fields[index];
            if (index != 0) {
              metadata << ',';
            }
            metadata << "{\"name\":\"" << json_escape(field.name)
                     << "\",\"offset\":" << field.offset
                     << ",\"datatype\":" << static_cast<unsigned>(field.datatype)
                     << ",\"count\":" << field.count << '}';
          }
          metadata << "]}";

          Frame frame;
          frame.stamp_sec = message->header.stamp.sec;
          frame.stamp_nsec = message->header.stamp.nanosec;
          frame.metadata = metadata.str();
          frame.payload = message->compressed_data;
          frames_->publish(StreamId::Cloud, std::move(frame));
        });
    }
    RCLCPP_INFO(get_logger(), "Activated browser stream %u", static_cast<unsigned>(stream));
  }

  void deactivate(const StreamId stream)
  {
    std::lock_guard<std::mutex> lock(subscription_mutex_);
    auto iterator = clients_.find(stream);
    if (iterator == clients_.end() || iterator->second == 0) {
      return;
    }
    --iterator->second;
    if (iterator->second != 0) {
      return;
    }
    if (stream == StreamId::Rgb) {
      rgb_subscription_.reset();
    } else if (stream == StreamId::Depth) {
      depth_subscription_.reset();
    } else {
      cloud_subscription_.reset();
    }
    RCLCPP_INFO(get_logger(), "Deactivated idle browser stream %u", static_cast<unsigned>(stream));
  }

private:
  std::shared_ptr<LatestFrames> frames_;
  std::mutex subscription_mutex_;
  std::map<StreamId, std::size_t> clients_;
  rclcpp::Subscription<sensor_msgs::msg::CompressedImage>::SharedPtr rgb_subscription_;
  rclcpp::Subscription<sensor_msgs::msg::CompressedImage>::SharedPtr depth_subscription_;
  rclcpp::Subscription<point_cloud_interfaces::msg::CompressedPointCloud2>::SharedPtr
    cloud_subscription_;
};

struct CommandResult
{
  int exit_code = 1;
  bool timed_out = false;
  std::string output;
};

CommandResult run_command(
  const std::filesystem::path & executable,
  const std::vector<std::string> & arguments,
  const std::chrono::seconds timeout)
{
  int pipe_fds[2];
  if (pipe(pipe_fds) != 0) {
    return {1, false, "could not create command pipe\n"};
  }
  const pid_t child = fork();
  if (child < 0) {
    close(pipe_fds[0]);
    close(pipe_fds[1]);
    return {1, false, "could not fork control command\n"};
  }
  if (child == 0) {
    close(pipe_fds[0]);
    dup2(pipe_fds[1], STDOUT_FILENO);
    dup2(pipe_fds[1], STDERR_FILENO);
    close(pipe_fds[1]);
    std::vector<char *> argv;
    std::string executable_text = executable.string();
    argv.push_back(executable_text.data());
    std::vector<std::string> owned = arguments;
    for (auto & argument : owned) {
      argv.push_back(argument.data());
    }
    argv.push_back(nullptr);
    execv(executable_text.c_str(), argv.data());
    _exit(127);
  }

  close(pipe_fds[1]);
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  CommandResult result;
  int status = 0;
  bool exited = false;
  std::array<char, 4096> buffer{};
  while (std::chrono::steady_clock::now() < deadline) {
    pollfd descriptor{pipe_fds[0], POLLIN, 0};
    const int ready = poll(&descriptor, 1, 100);
    if (ready > 0 && (descriptor.revents & (POLLIN | POLLHUP))) {
      const ssize_t count = read(pipe_fds[0], buffer.data(), buffer.size());
      if (count > 0 && result.output.size() < kMaxCommandOutput) {
        const auto room = kMaxCommandOutput - result.output.size();
        result.output.append(buffer.data(), std::min<std::size_t>(count, room));
      }
    }
    const pid_t waited = waitpid(child, &status, WNOHANG);
    if (waited == child) {
      exited = true;
      break;
    }
  }
  if (!exited) {
    result.timed_out = true;
    kill(child, SIGTERM);
    for (int attempt = 0; attempt < 20; ++attempt) {
      if (waitpid(child, &status, WNOHANG) == child) {
        exited = true;
        break;
      }
      std::this_thread::sleep_for(50ms);
    }
    if (!exited) {
      kill(child, SIGKILL);
      waitpid(child, &status, 0);
    }
  }
  while (true) {
    const ssize_t count = read(pipe_fds[0], buffer.data(), buffer.size());
    if (count <= 0) {
      break;
    }
    if (result.output.size() < kMaxCommandOutput) {
      const auto room = kMaxCommandOutput - result.output.size();
      result.output.append(buffer.data(), std::min<std::size_t>(count, room));
    }
  }
  close(pipe_fds[0]);
  if (result.timed_out) {
    result.exit_code = 124;
    result.output += "\nERROR: control command timed out\n";
  } else if (WIFEXITED(status)) {
    result.exit_code = WEXITSTATUS(status);
  } else if (WIFSIGNALED(status)) {
    result.exit_code = 128 + WTERMSIG(status);
  }
  return result;
}

std::string trim(std::string value)
{
  const auto not_space = [](const unsigned char byte) {return !std::isspace(byte);};
  value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
  value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
  return value;
}

std::string read_token(const std::filesystem::path & path)
{
  std::ifstream input(path);
  if (!input) {
    throw std::runtime_error("cannot read token file: " + path.string());
  }
  std::string token;
  std::getline(input, token);
  token = trim(token);
  if (!std::regex_match(token, std::regex("[A-Fa-f0-9]{48,128}"))) {
    throw std::runtime_error("token must contain 48-128 hexadecimal characters");
  }
  return token;
}

bool constant_time_equal(const std::string & left, const std::string & right)
{
  const std::size_t length = std::max(left.size(), right.size());
  unsigned difference = static_cast<unsigned>(left.size() ^ right.size());
  for (std::size_t index = 0; index < length; ++index) {
    const unsigned a = index < left.size() ? static_cast<unsigned char>(left[index]) : 0U;
    const unsigned b = index < right.size() ? static_cast<unsigned char>(right[index]) : 0U;
    difference |= a ^ b;
  }
  return difference == 0;
}

std::string target_path(const std::string & target)
{
  const auto query = target.find('?');
  return target.substr(0, query);
}

std::map<std::string, std::string> query_parameters(const std::string & target)
{
  std::map<std::string, std::string> output;
  const auto question = target.find('?');
  if (question == std::string::npos) {
    return output;
  }
  std::istringstream input(target.substr(question + 1));
  std::string pair;
  while (std::getline(input, pair, '&')) {
    const auto equals = pair.find('=');
    if (equals != std::string::npos) {
      output[pair.substr(0, equals)] = pair.substr(equals + 1);
    }
  }
  return output;
}

std::string mime_type(const std::string & path)
{
  if (path.size() >= 5 && path.substr(path.size() - 5) == ".html") {
    return "text/html; charset=utf-8";
  }
  if (path.size() >= 3 && path.substr(path.size() - 3) == ".js") {
    return "text/javascript; charset=utf-8";
  }
  if (path.size() >= 4 && path.substr(path.size() - 4) == ".css") {
    return "text/css; charset=utf-8";
  }
  if (path.size() >= 5 && path.substr(path.size() - 5) == ".wasm") {
    return "application/wasm";
  }
  if (path.size() >= 4 && path.substr(path.size() - 4) == ".svg") {
    return "image/svg+xml";
  }
  return "application/octet-stream";
}

class GatewayServer
{
public:
  GatewayServer(
    asio::io_context & context, const uint16_t port,
    std::filesystem::path rig_root, std::filesystem::path web_root,
    std::string token, std::shared_ptr<LatestFrames> frames,
    std::shared_ptr<GatewayNode> node)
  : acceptor_(context), rig_root_(std::move(rig_root)), web_root_(std::move(web_root)),
    token_(std::move(token)), frames_(std::move(frames)), node_(std::move(node))
  {
    const tcp::endpoint endpoint(asio::ip::make_address("127.0.0.1"), port);
    acceptor_.open(endpoint.protocol());
    acceptor_.set_option(asio::socket_base::reuse_address(true));
    acceptor_.bind(endpoint);
    acceptor_.listen(asio::socket_base::max_listen_connections);
    acceptor_.non_blocking(true);
  }

  void run()
  {
    RCLCPP_INFO(
      node_->get_logger(), "Browser gateway listening on 127.0.0.1:%u",
      acceptor_.local_endpoint().port());
    while (rclcpp::ok()) {
      beast::error_code error;
      tcp::socket socket(acceptor_.get_executor());
      acceptor_.accept(socket, error);
      if (error == asio::error::would_block || error == asio::error::try_again) {
        reap_connections();
        std::this_thread::sleep_for(50ms);
        continue;
      }
      if (error) {
        if (rclcpp::ok()) {
          RCLCPP_WARN(node_->get_logger(), "accept failed: %s", error.message().c_str());
        }
        continue;
      }
      if (!socket.remote_endpoint().address().is_loopback()) {
        RCLCPP_WARN(node_->get_logger(), "rejected non-loopback peer");
        socket.close(error);
        continue;
      }
      auto finished = std::make_shared<std::atomic<bool>>(false);
      Connection connection;
      connection.finished = finished;
      connection.thread = std::thread(
        [this, socket = std::move(socket), finished]() mutable {
          try {
            serve_connection(std::move(socket));
          } catch (const std::exception & exception) {
            RCLCPP_WARN(
              node_->get_logger(), "connection failed: %s", exception.what());
          }
          finished->store(true);
        });
      connections_.push_back(std::move(connection));
      reap_connections();
    }
  }

  void join_connections()
  {
    for (auto & connection : connections_) {
      if (connection.thread.joinable()) {
        connection.thread.join();
      }
    }
    connections_.clear();
  }

private:
  struct Connection
  {
    std::thread thread;
    std::shared_ptr<std::atomic<bool>> finished;
  };

  void reap_connections()
  {
    auto iterator = connections_.begin();
    while (iterator != connections_.end()) {
      if (iterator->finished->load()) {
        if (iterator->thread.joinable()) {
          iterator->thread.join();
        }
        iterator = connections_.erase(iterator);
      } else {
        ++iterator;
      }
    }
  }

  using Request = http::request<http::string_body>;
  using Response = http::response<http::string_body>;

  static Response text_response(
    const Request & request, const http::status status,
    std::string body, const std::string & content_type = "text/plain; charset=utf-8")
  {
    Response response{status, request.version()};
    response.set(http::field::server, "zed-web-gateway/1");
    response.set(http::field::content_type, content_type);
    response.set(http::field::cache_control, "no-store");
    response.set("X-Content-Type-Options", "nosniff");
    response.set("Referrer-Policy", "no-referrer");
    response.set(
      "Content-Security-Policy",
      "default-src 'self'; script-src 'self'; worker-src 'self' blob:; "
      "style-src 'self'; img-src 'self' blob: data:; connect-src 'self' ws://127.0.0.1:* "
      "ws://localhost:*; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
    response.keep_alive(false);
    response.body() = std::move(body);
    response.prepare_payload();
    return response;
  }

  bool authorized(const Request & request) const
  {
    const auto header = request.find("X-ZED-Token");
    if (header != request.end() && constant_time_equal(header->value().to_string(), token_)) {
      return true;
    }
    const auto parameters = query_parameters(request.target().to_string());
    const auto token = parameters.find("token");
    return token != parameters.end() && constant_time_equal(token->second, token_);
  }

  static bool allowed_origin(const Request & request)
  {
    const auto origin = request.find(http::field::origin);
    if (origin == request.end()) {
      // Non-browser field diagnostics such as curl do not send Origin.
      return true;
    }
    static const std::regex loopback_origin(
      R"(^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?$)");
    return std::regex_match(origin->value().to_string(), loopback_origin);
  }

  static bool supported_stream_version(const Request & request)
  {
    const auto parameters = query_parameters(request.target().to_string());
    const auto version = parameters.find("v");
    return version != parameters.end() && version->second == "1";
  }

  static std::optional<std::string> controller_header(const Request & request)
  {
    const auto header = request.find("X-ZED-Controller");
    if (header == request.end()) {
      return std::nullopt;
    }
    const std::string controller = header->value().to_string();
    if (!std::regex_match(controller, std::regex("[A-Fa-f0-9]{32}"))) {
      return std::nullopt;
    }
    return controller;
  }

  bool acquire_controller(const std::string & controller)
  {
    std::lock_guard<std::mutex> lock(lease_mutex_);
    const auto now = std::chrono::steady_clock::now();
    if (controller_id_.empty() || controller == controller_id_ || now >= controller_expires_) {
      controller_id_ = controller;
      controller_expires_ = now + kControllerLeaseDuration;
      return true;
    }
    return false;
  }

  bool holds_controller(const std::string & controller)
  {
    std::lock_guard<std::mutex> lock(lease_mutex_);
    const auto now = std::chrono::steady_clock::now();
    if (now >= controller_expires_) {
      controller_id_.clear();
      return false;
    }
    if (controller != controller_id_) {
      return false;
    }
    controller_expires_ = now + kControllerLeaseDuration;
    return true;
  }

  void release_controller(const std::string & controller)
  {
    std::lock_guard<std::mutex> lock(lease_mutex_);
    if (controller == controller_id_) {
      controller_id_.clear();
      controller_expires_ = {};
    }
  }

  std::optional<StreamId> requested_stream(const std::string & path) const
  {
    if (path == "/api/v1/stream/rgb") {
      return StreamId::Rgb;
    }
    if (path == "/api/v1/stream/depth") {
      return StreamId::Depth;
    }
    if (path == "/api/v1/stream/cloud") {
      return StreamId::Cloud;
    }
    return std::nullopt;
  }

  void serve_connection(tcp::socket socket)
  {
    beast::tcp_stream stream(std::move(socket));
    beast::flat_buffer buffer;
    Request request;
    beast::error_code error;
    stream.expires_after(15s);
    http::read(stream, buffer, request, error);
    if (error) {
      return;
    }

    const std::string target = request.target().to_string();
    const std::string path = target_path(target);
    const auto requested = requested_stream(path);
    if (requested && websocket::is_upgrade(request)) {
      if (!authorized(request) || !allowed_origin(request)) {
        auto response = text_response(request, http::status::unauthorized, "Unauthorized\n");
        http::write(stream, response, error);
        return;
      }
      if (!supported_stream_version(request)) {
        auto response = text_response(
          request, http::status::upgrade_required, "Unsupported stream protocol\n");
        http::write(stream, response, error);
        return;
      }
      websocket_session(std::move(stream.socket()), std::move(request), *requested);
      return;
    }

    Response response;
    if (path.rfind("/api/", 0) == 0) {
      if (!authorized(request) || !allowed_origin(request)) {
        response = text_response(request, http::status::unauthorized, "Unauthorized\n");
      } else {
        response = api_response(request, path);
      }
    } else {
      response = static_response(request, path);
    }
    http::write(stream, response, error);
    stream.socket().shutdown(tcp::socket::shutdown_send, error);
  }

  void websocket_session(tcp::socket socket, Request request, const StreamId stream_id)
  {
    websocket::stream<beast::tcp_stream> websocket_stream(std::move(socket));
    beast::error_code error;
    websocket_stream.set_option(
      websocket::stream_base::timeout::suggested(beast::role_type::server));
    websocket_stream.set_option(websocket::stream_base::decorator(
      [](websocket::response_type & response) {
        response.set(http::field::server, "zed-web-gateway/1");
      }));
    websocket_stream.accept(request, error);
    if (error) {
      return;
    }
    websocket_stream.binary(true);
    const uint32_t initial_sequence = frames_->current_sequence(stream_id);
    node_->activate(stream_id);
    uint32_t last_sequence = initial_sequence;
    while (rclcpp::ok()) {
      pollfd descriptor{
        beast::get_lowest_layer(websocket_stream).socket().native_handle(),
        POLLIN,
        0};
      const int readable = poll(&descriptor, 1, 0);
      if (readable > 0 && (descriptor.revents & (POLLIN | POLLHUP | POLLERR))) {
        beast::flat_buffer input;
        beast::get_lowest_layer(websocket_stream).expires_after(2s);
        websocket_stream.read(input, error);
        if (error) {
          break;
        }
        // Browser clients have no valid upstream stream messages.
        continue;
      }
      const auto frame = frames_->wait_new(stream_id, last_sequence, 250ms);
      if (!frame) {
        continue;
      }
      std::vector<uint8_t> wire;
      try {
        wire = serialize_frame(stream_id, *frame);
      } catch (const std::exception & exception) {
        RCLCPP_ERROR(node_->get_logger(), "serialization failed: %s", exception.what());
        break;
      }
      beast::get_lowest_layer(websocket_stream).expires_after(5s);
      websocket_stream.write(asio::buffer(wire), error);
      if (error) {
        break;
      }
      last_sequence = frame->sequence;
    }
    node_->deactivate(stream_id);
    if (!error) {
      websocket_stream.close(websocket::close_code::normal, error);
    }
  }

  Response static_response(const Request & request, std::string path)
  {
    if (request.method() != http::verb::get && request.method() != http::verb::head) {
      return text_response(request, http::status::method_not_allowed, "GET required\n");
    }
    static const std::map<std::string, std::string> files = {
      {"/", "index.html"},
      {"/index.html", "index.html"},
      {"/app.js", "app.js"},
      {"/protocol.js", "protocol.js"},
      {"/style.css", "style.css"},
      {"/depth_worker.js", "depth_worker.js"},
      {"/draco_worker.js", "draco_worker.js"},
      {"/vendor/three.module.min.js", "vendor/three.module.min.js"},
      {"/vendor/OrbitControls.js", "vendor/OrbitControls.js"},
      {"/vendor/DRACOLoader.js", "vendor/DRACOLoader.js"},
      {"/vendor/draco/draco_wasm_wrapper.js", "vendor/draco/draco_wasm_wrapper.js"},
      {"/vendor/draco/draco_decoder.wasm", "vendor/draco/draco_decoder.wasm"},
    };
    const auto mapping = files.find(path);
    if (mapping == files.end()) {
      return text_response(request, http::status::not_found, "Not found\n");
    }
    const auto file = web_root_ / mapping->second;
    std::ifstream input(file, std::ios::binary);
    if (!input) {
      return text_response(request, http::status::not_found, "Missing web asset\n");
    }
    std::string body(
      (std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    if (request.method() == http::verb::head) {
      body.clear();
    }
    auto response = text_response(
      request, http::status::ok, std::move(body), mime_type(mapping->second));
    if (path.find("/vendor/") == 0) {
      response.set(http::field::cache_control, "public, max-age=31536000, immutable");
    }
    return response;
  }

  CommandResult field_command(
    const std::vector<std::string> & arguments,
    const std::chrono::seconds timeout = 20s) const
  {
    return run_command(rig_root_ / "scripts/zed_field_session.sh", arguments, timeout);
  }

  CommandResult replay_command(
    const std::vector<std::string> & arguments,
    const std::chrono::seconds timeout = 20s) const
  {
    return run_command(rig_root_ / "scripts/zed_replay_session.sh", arguments, timeout);
  }

  Response command_response(const Request & request, const CommandResult & result) const
  {
    const auto status = result.exit_code == 0 ? http::status::ok : http::status::conflict;
    return text_response(request, status, result.output.empty() ? "\n" : result.output);
  }

  Response api_response(const Request & request, const std::string & path)
  {
    if (request.body().size() > kMaxControlBody) {
      return text_response(request, http::status::payload_too_large, "Control body too large\n");
    }
    if (request.method() == http::verb::get && path == "/api/v1/status") {
      const auto parameters = query_parameters(request.target().to_string());
      const auto mode = parameters.find("mode");
      if (mode != parameters.end() && mode->second == "replay") {
        return command_response(request, replay_command({"status", "--machine"}, 8s));
      }
      return command_response(
        request, field_command({"status", "--machine", "--fast"}, 8s));
    }
    if (request.method() == http::verb::get && path == "/api/v1/datasets") {
      return command_response(
        request, replay_command({"list", "--machine", "--limit", "100"}, 15s));
    }
    if (request.method() != http::verb::post) {
      return text_response(request, http::status::method_not_allowed, "POST required\n");
    }

    const auto controller = controller_header(request);
    if (path == "/api/v1/lease") {
      if (!controller) {
        return text_response(request, http::status::bad_request, "Invalid controller identity\n");
      }
      if (!acquire_controller(*controller)) {
        return text_response(
          request, http::status::locked,
          "Another browser holds the control lease; this viewer is read-only\n");
      }
      return text_response(request, http::status::ok, "CONTROLLER=ACTIVE\nLEASE_SECONDS=30\n");
    }
    if (path == "/api/v1/lease/release") {
      if (!controller) {
        return text_response(request, http::status::bad_request, "Invalid controller identity\n");
      }
      release_controller(*controller);
      return text_response(request, http::status::ok, "CONTROLLER=RELEASED\n");
    }
    if (!controller || !holds_controller(*controller)) {
      return text_response(
        request, http::status::locked,
        "Control lease required; another viewer may currently be the controller\n");
    }

    std::lock_guard<std::mutex> control_lock(control_mutex_);
    if (path == "/api/v1/live/record-start") {
      return command_response(
        request, field_command({"record-start", "--machine"}, 30s));
    }
    if (path == "/api/v1/live/record-stop") {
      return command_response(
        request, field_command({"record-stop", "--machine"}, 150s));
    }
    if (path == "/api/v1/live/stop") {
      return command_response(request, field_command({"stop"}, 180s));
    }
    if (path == "/api/v1/replay/toggle") {
      return command_response(request, replay_command({"pause-toggle"}, 20s));
    }
    if (path == "/api/v1/replay/next") {
      return command_response(request, replay_command({"next"}, 20s));
    }
    if (path == "/api/v1/replay/speed") {
      const std::string speed = trim(request.body());
      static const std::regex valid_speed(
        R"((up|down|0\.1|0\.25|0\.5|1(\.0)?|1\.5|2(\.0)?|3(\.0)?|5(\.0)?))");
      if (!std::regex_match(speed, valid_speed)) {
        return text_response(request, http::status::bad_request, "Invalid replay speed\n");
      }
      return command_response(request, replay_command({"speed", speed}, 20s));
    }
    if (path == "/api/v1/replay/select") {
      std::smatch match;
      const std::string selection = trim(request.body());
      static const std::regex valid_selection(R"(index=([1-9][0-9]{0,2})&loop=([01]))");
      if (!std::regex_match(selection, match, valid_selection)) {
        return text_response(request, http::status::bad_request, "Invalid dataset selection\n");
      }
      const std::string index = match[1].str();
      const bool loop = match[2].str() == "1";
      const auto stop = replay_command({"stop"}, 45s);
      if (stop.exit_code != 0) {
        return command_response(request, stop);
      }
      std::vector<std::string> arguments{"start", "--index", index};
      if (loop) {
        arguments.push_back("--loop");
      }
      return command_response(request, replay_command(arguments, 120s));
    }
    if (path == "/api/v1/replay/stop") {
      return command_response(request, replay_command({"stop"}, 45s));
    }
    return text_response(request, http::status::not_found, "Unknown control operation\n");
  }

  tcp::acceptor acceptor_;
  std::filesystem::path rig_root_;
  std::filesystem::path web_root_;
  std::string token_;
  std::shared_ptr<LatestFrames> frames_;
  std::shared_ptr<GatewayNode> node_;
  std::mutex control_mutex_;
  std::mutex lease_mutex_;
  std::string controller_id_;
  std::chrono::steady_clock::time_point controller_expires_{};
  std::vector<Connection> connections_;
};

struct Options
{
  uint16_t port = 8765;
  std::filesystem::path rig_root;
  std::filesystem::path web_root;
  std::filesystem::path token_file;
};

void print_usage(const char * executable)
{
  std::cerr
    << "Usage: " << executable
    << " --rig-root PATH --web-root PATH --token-file PATH [--port 8765]\n";
}

Options parse_options(const int argc, char ** argv)
{
  Options options;
  for (int index = 1; index < argc; ++index) {
    const std::string argument = argv[index];
    const auto value = [&](const std::string & name) {
        if (++index >= argc) {
          throw std::runtime_error("missing value for " + name);
        }
        return std::string(argv[index]);
      };
    if (argument == "--rig-root") {
      options.rig_root = value(argument);
    } else if (argument == "--web-root") {
      options.web_root = value(argument);
    } else if (argument == "--token-file") {
      options.token_file = value(argument);
    } else if (argument == "--port") {
      const std::string text = value(argument);
      const unsigned long port = std::stoul(text);
      if (port == 0 || port > 65535) {
        throw std::runtime_error("port is out of range");
      }
      options.port = static_cast<uint16_t>(port);
    } else if (argument == "-h" || argument == "--help") {
      print_usage(argv[0]);
      std::exit(0);
    } else {
      throw std::runtime_error("unknown argument: " + argument);
    }
  }
  if (options.rig_root.empty() || options.web_root.empty() || options.token_file.empty()) {
    throw std::runtime_error("--rig-root, --web-root, and --token-file are required");
  }
  options.rig_root = std::filesystem::canonical(options.rig_root);
  options.web_root = std::filesystem::canonical(options.web_root);
  options.token_file = std::filesystem::canonical(options.token_file);
  if (!std::filesystem::is_regular_file(
      options.rig_root / "scripts/zed_field_session.sh") ||
    !std::filesystem::is_regular_file(
      options.rig_root / "scripts/zed_replay_session.sh") ||
    !std::filesystem::is_regular_file(options.web_root / "index.html"))
  {
    throw std::runtime_error("rig root or web root does not contain expected files");
  }
  return options;
}

}  // namespace

int main(int argc, char ** argv)
{
  try {
    const auto options = parse_options(argc, argv);
    const auto token = read_token(options.token_file);
    rclcpp::init(argc, argv);
    auto frames = std::make_shared<LatestFrames>();
    auto node = std::make_shared<GatewayNode>(frames);
    rclcpp::executors::MultiThreadedExecutor executor(rclcpp::ExecutorOptions(), 2);
    executor.add_node(node);
    std::thread ros_thread([&executor]() {executor.spin();});

    asio::io_context context(1);
    GatewayServer server(
      context, options.port, options.rig_root, options.web_root, token, frames, node);
    server.run();

    frames->stop();
    server.join_connections();
    executor.cancel();
    if (ros_thread.joinable()) {
      ros_thread.join();
    }
    rclcpp::shutdown();
    return 0;
  } catch (const std::exception & exception) {
    std::cerr << "ERROR: " << exception.what() << '\n';
    if (rclcpp::ok()) {
      rclcpp::shutdown();
    }
    return 1;
  }
}
