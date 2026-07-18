#include <sl/Camera.hpp>

#include <opencv2/opencv.hpp>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

constexpr unsigned int kLeftSerial = 304467158;
constexpr unsigned int kRightSerial = 306605936;
constexpr unsigned int kExpectedVirtualSerial = 116863460;
constexpr int kFps = 15;

std::atomic<bool> keep_running{true};

struct Options {
  std::filesystem::path output;
  int frame_limit = 0;
  bool preview = false;
  sl::SVO_COMPRESSION_MODE compression = sl::SVO_COMPRESSION_MODE::LOSSLESS;
};

void onSignal(int) { keep_running = false; }

std::filesystem::path defaultOutputPath() {
  const char* home = std::getenv("HOME");
  const auto root = home ? std::filesystem::path(home) : std::filesystem::current_path();

  const auto now = std::chrono::system_clock::now();
  const std::time_t timestamp = std::chrono::system_clock::to_time_t(now);
  std::tm local_time{};
  localtime_r(&timestamp, &local_time);

  std::ostringstream name;
  name << "virtual_stereo_" << std::put_time(&local_time, "%Y%m%d_%H%M%S")
       << ".svo2";
  return root / "Videos" / "ZED" / name.str();
}

void printUsage(const char* app) {
  std::cout
      << "Calibrated dual-ZED-X-One SVO2 recorder\n\n"
      << "Usage: " << app << " [options]\n\n"
      << "COPY/PASTE COMMANDS FOR THIS RIG\n\n"
      << "  Recommended smaller field recording (H.264):\n"
      << "    /home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --h264\n\n"
      << "  Maximum-fidelity recording for depth analysis (large files):\n"
      << "    /home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --lossless\n\n"
      << "  One-minute H.264 recording with an explicit filename (900 frames at 15 FPS):\n"
      << "    /home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --h264 --frames 900 --output /home/dusty/Videos/ZED/field_test.svo2\n\n"
      << "Recording begins immediately. Press Ctrl+C and wait for finalization before removing power.\n"
      << "The default is lossless and can consume roughly 3.4 GB/minute on this rig.\n\n"
      << "Options:\n"
      << "  --output PATH   Output .svo2 path (default: ~/Videos/ZED/timestamp.svo2)\n"
      << "  --frames N      Stop automatically after N successfully grabbed frames\n"
      << "  --preview       Experimental preview; not reliable while recording on this Jetson\n"
      << "  --no-preview    Record without a preview window (default)\n"
      << "  --lossless      PNG/ZSTD lossless recording (default; largest files)\n"
      << "  --h264          H.264 lossy recording (smaller; may affect depth)\n"
      << "  --h265          H.265 lossy recording (requires encoder support)\n"
      << "  -h, --help      Show this help\n";
}

Options parseOptions(int argc, char** argv) {
  Options options;
  options.output = defaultOutputPath();

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "-h" || arg == "--help") {
      printUsage(argv[0]);
      std::exit(EXIT_SUCCESS);
    } else if (arg == "--output") {
      if (++i >= argc) throw std::runtime_error("--output requires a path");
      options.output = argv[i];
    } else if (arg == "--frames") {
      if (++i >= argc) throw std::runtime_error("--frames requires a positive integer");
      options.frame_limit = std::stoi(argv[i]);
      if (options.frame_limit <= 0) {
        throw std::runtime_error("--frames requires a positive integer");
      }
    } else if (arg == "--preview") {
      options.preview = true;
    } else if (arg == "--no-preview") {
      options.preview = false;
    } else if (arg == "--lossless") {
      options.compression = sl::SVO_COMPRESSION_MODE::LOSSLESS;
    } else if (arg == "--h264") {
      options.compression = sl::SVO_COMPRESSION_MODE::H264;
    } else if (arg == "--h265") {
      options.compression = sl::SVO_COMPRESSION_MODE::H265;
    } else {
      throw std::runtime_error("unknown option: " + arg);
    }
  }

  if (options.output.extension() != ".svo" && options.output.extension() != ".svo2") {
    options.output += ".svo2";
  }
  return options;
}

cv::Mat slMatToCv(sl::Mat& input) {
  return cv::Mat(input.getHeight(), input.getWidth(), CV_8UC4,
                 input.getPtr<sl::uchar1>(sl::MEM::CPU),
                 input.getStepBytes(sl::MEM::CPU));
}

std::string compressionName(sl::SVO_COMPRESSION_MODE mode) {
  switch (mode) {
    case sl::SVO_COMPRESSION_MODE::LOSSLESS:
      return "LOSSLESS (PNG/ZSTD)";
    case sl::SVO_COMPRESSION_MODE::H264:
      return "H264";
    case sl::SVO_COMPRESSION_MODE::H265:
      return "H265";
    default:
      return sl::toString(mode).c_str();
  }
}

}  // namespace

int main(int argc, char** argv) {
  Options options;
  try {
    options = parseOptions(argc, argv);
    if (!options.output.parent_path().empty()) {
      std::filesystem::create_directories(options.output.parent_path());
    }
  } catch (const std::exception& error) {
    std::cerr << "Error: " << error.what() << "\n\n";
    printUsage(argv[0]);
    return EXIT_FAILURE;
  }

  std::signal(SIGINT, onSignal);
  std::signal(SIGTERM, onSignal);

  const unsigned int virtual_serial =
      sl::generateVirtualStereoSerialNumber(kLeftSerial, kRightSerial);
  if (virtual_serial != kExpectedVirtualSerial) {
    std::cerr << "Unexpected virtual serial " << virtual_serial << " (expected "
              << kExpectedVirtualSerial << "). Refusing to use the wrong calibration.\n";
    return EXIT_FAILURE;
  }

  std::cout << "Opening calibrated virtual stereo camera\n"
            << "  Left:        " << kLeftSerial << '\n'
            << "  Right:       " << kRightSerial << '\n'
            << "  Virtual:     " << virtual_serial << '\n'
            << "  Mode:        HD1200 @ " << kFps << " FPS\n"
            << "  Compression: " << compressionName(options.compression) << '\n'
            << "  Output:      " << options.output << "\n";

  sl::InitParameters init;
  init.camera_resolution = sl::RESOLUTION::HD1200;
  init.camera_fps = kFps;
  init.depth_mode = sl::DEPTH_MODE::NONE;
  init.sdk_verbose = false;
  init.input.setVirtualStereoFromSerialNumbers(kLeftSerial, kRightSerial,
                                                virtual_serial);

  sl::Camera camera;
  const auto open_result = camera.open(init);
  if (open_result > sl::ERROR_CODE::SUCCESS) {
    std::cerr << "Could not open virtual stereo camera: " << open_result << "\n"
              << "Close other ZED programs, run ZED_Explorer --all, and follow the "
                 "field guide if either camera is unavailable.\n";
    return EXIT_FAILURE;
  }

  constexpr const char* kWindowName = "ZED Virtual Stereo Recorder - Q/Esc to stop";
  const sl::Resolution preview_resolution(1440, 450);
  sl::Mat preview_image(preview_resolution, sl::MAT_TYPE::U8_C4, sl::MEM::CPU);
  cv::Mat preview_cv = slMatToCv(preview_image);
  if (options.preview) {
    // GTK/OpenCV window creation can take several seconds on the Jetson. Do
    // this before enableRecording(), because the SDK recorder expects the
    // first grab immediately after it is enabled.
    cv::namedWindow(kWindowName, cv::WINDOW_NORMAL);
    cv::waitKey(1);
  }

  const sl::RecordingParameters recording(options.output.string().c_str(),
                                            options.compression, kFps);
  const auto recording_result = camera.enableRecording(recording);
  if (recording_result > sl::ERROR_CODE::SUCCESS) {
    std::cerr << "Could not start SVO2 recording: " << recording_result << '\n';
    if (options.preview) cv::destroyAllWindows();
    camera.close();
    return EXIT_FAILURE;
  }

  if (options.preview) {
    std::cout << "RECORDING NOW. Press Q, Esc, or Ctrl+C to stop and finalize.\n";
  } else {
    std::cout << "RECORDING NOW (headless). Press Ctrl+C to stop and finalize.\n";
  }

  int grabbed = 0;
  int consecutive_grab_errors = 0;
  int consecutive_recording_errors = 0;
  int total_recording_errors = 0;
  int last_ingested = 0;
  int last_encoded = 0;
  bool recording_failed = false;
  while (keep_running &&
         (options.frame_limit == 0 || grabbed < options.frame_limit)) {
    const auto grab_result = camera.grab();
    if (grab_result != sl::ERROR_CODE::SUCCESS) {
      ++consecutive_grab_errors;
      if (consecutive_grab_errors == 1 || consecutive_grab_errors % 30 == 0) {
        std::cerr << "Frame grab failed: " << grab_result << '\n';
      }
      if (consecutive_grab_errors >= 90) {
        std::cerr << "Stopping after repeated frame-grab failures.\n";
        recording_failed = true;
        break;
      }
      continue;
    }

    consecutive_grab_errors = 0;
    ++grabbed;
    const auto status = camera.getRecordingStatus();
    last_ingested = status.number_frames_ingested;
    last_encoded = status.number_frames_encoded;
    if (!status.status) {
      ++consecutive_recording_errors;
      ++total_recording_errors;
      if (consecutive_recording_errors == 1 ||
          consecutive_recording_errors % kFps == 0) {
        std::cerr << "SDK recording pipeline has not accepted frame " << grabbed
                  << " yet (ingested=" << last_ingested
                  << ", encoded=" << last_encoded << "). Continuing...\n";
      }
      if (consecutive_recording_errors >= kFps * 5) {
        std::cerr << "Stopping after five continuous seconds of rejected recording "
                     "frames. Check disk space and storage health.\n";
        recording_failed = true;
        break;
      }
    } else {
      consecutive_recording_errors = 0;
    }

    if (grabbed == 1 || grabbed % kFps == 0) {
      std::cout << "Recording: " << last_ingested << " ingested / "
                << last_encoded << " encoded\r" << std::flush;
    }

    if (options.preview) {
      // Do not request a preview until the SDK recorder has accepted this
      // frame. On Jetson, retrieving SIDE_BY_SIDE while the lossless recorder
      // is still starting can keep the recording pipeline from ever becoming
      // ready.
      if (status.status) {
        camera.retrieveImage(preview_image, sl::VIEW::SIDE_BY_SIDE, sl::MEM::CPU,
                             preview_resolution);
        cv::putText(preview_cv,
                    "RECORDING  " + std::to_string(last_ingested) + " ingested / " +
                        std::to_string(last_encoded) + " encoded",
                    cv::Point(20, 38), cv::FONT_HERSHEY_SIMPLEX, 0.9,
                    cv::Scalar(30, 30, 255, 255), 2, cv::LINE_AA);
        cv::imshow(kWindowName, preview_cv);
      }
      const int key = cv::waitKey(1) & 0xff;
      if (key == 'q' || key == 'Q' || key == 27) keep_running = false;
      if (cv::getWindowProperty(kWindowName, cv::WND_PROP_VISIBLE) < 1) {
        keep_running = false;
      }
    }
  }

  std::cout << "\nFinalizing SVO2...\n";
  const auto final_status = camera.getRecordingStatus();
  last_ingested = final_status.number_frames_ingested;
  last_encoded = final_status.number_frames_encoded;
  camera.disableRecording();
  camera.close();
  if (options.preview) cv::destroyAllWindows();

  std::error_code file_error;
  const auto bytes = std::filesystem::file_size(options.output, file_error);
  if (last_ingested == 0 && last_encoded == 0) recording_failed = true;

  std::cout << "SDK final count: " << last_ingested << " ingested / "
            << last_encoded << " encoded\n"
            << "Saved the synchronized recording to\n"
            << "  " << options.output << '\n';
  if (total_recording_errors > 0) {
    std::cout << "SDK reported " << total_recording_errors
              << " transient/rejected frame status event(s).\n";
  }
  if (!file_error) {
    std::cout << "File size: " << std::fixed << std::setprecision(1)
              << (static_cast<double>(bytes) / (1024.0 * 1024.0)) << " MiB\n";
  }

  return recording_failed ? EXIT_FAILURE : EXIT_SUCCESS;
}
