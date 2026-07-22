#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

RUNTIME=false

usage() {
  cat <<EOF
Verify the installed ROS 2/ZED field-viewing setup without changing it.

Copy/paste static verification:
  $ROOT/scripts/verify_ros2_setup.sh

Copy/paste while a live or replay ROS launch is running:
  $ROOT/scripts/verify_ros2_setup.sh --runtime

Options:
  --runtime   Also verify the running ZED node, topic types, parameters, and rates
  -h, --help  Show this help
EOF
}

while (($#)); do
  case "$1" in
    --runtime) RUNTIME=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

failures=0
warnings=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

echo "ROS 2/ZED wrapper verification"
echo

if [[ -r "/opt/ros/$ROS_DISTRO/setup.bash" ]]; then pass "ROS 2 $ROS_DISTRO setup"; else fail "missing ROS 2 $ROS_DISTRO"; fi
if [[ -r "$ZED_ROS_WORKSPACE/install/local_setup.bash" ]]; then pass "wrapper workspace setup"; else fail "missing wrapper workspace build"; fi
if zed_ros_check_calibration; then pass "virtual calibration checksum"; else failures=$((failures + 1)); fi

if ((failures == 0)); then
  zed_ros_source_environment
  if [[ "$(ros2 pkg prefix zed_wrapper 2>/dev/null)" == "$ZED_ROS_WORKSPACE/install/zed_wrapper" ]]; then
    pass "pinned zed_wrapper resolves from rig workspace"
  else
    fail "zed_wrapper does not resolve from $ZED_ROS_WORKSPACE"
  fi
  version="$(sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p' \
    "$ZED_ROS_WORKSPACE/src/zed-ros2-wrapper/zed_wrapper/package.xml" | head -n1)"
  if [[ "$version" == 5.4.0 ]]; then pass "zed_wrapper version 5.4.0"; else fail "unexpected wrapper version: $version"; fi
  if ros2 pkg prefix rmw_cyclonedds_cpp >/dev/null 2>&1; then pass "Cyclone DDS middleware"; else fail "missing Cyclone DDS middleware"; fi
  if ros2 pkg prefix rviz2 >/dev/null 2>&1; then pass "RViz2"; else warn "RViz2 not installed on this host"; fi
fi

for script in start_ros2_virtual_stereo.sh play_svo_ros2.sh start_ros2_rviz.sh \
  zed_field_session.sh zed_field_console.sh; do
  if [[ -x "$ROOT/scripts/$script" ]]; then pass "executable: scripts/$script"; else fail "not executable: scripts/$script"; fi
done

if [[ -r "$ROOT/config/field_console.env" ]]; then
  pass "field-console configuration"
else
  fail "missing config/field_console.env"
fi

jetson_dds="$ROOT/config/ros2/cyclonedds-jetson.xml"
if [[ -r "$jetson_dds" ]] &&
   grep -Fq '<FragmentSize>1344B</FragmentSize>' "$jetson_dds" &&
   grep -Fq '<MaxMessageSize>1400B</MaxMessageSize>' "$jetson_dds" &&
   grep -Fq '<MaxRexmitMessageSize>1400B</MaxRexmitMessageSize>' "$jetson_dds"; then
  pass "MTU-safe Jetson DDS sender profile"
else
  fail "missing or unsafe Jetson DDS sender profile: $jetson_dds"
fi

if zed_ros_user_manager_persistent; then
  pass "field session survives SSH disconnect (linger or active local session)"
else
  warn "field session needs: sudo loginctl enable-linger $(id -un)"
fi

owners="$(zed_ros_camera_owners)"
if [[ -z "$owners" ]]; then
  pass "no known camera-owning process"
elif $RUNTIME && grep -q 'ros2 launch zed_wrapper zed_camera.launch.py' <<<"$owners"; then
  pass "expected ROS camera owner is present"
else
  warn "camera owner currently present"
  printf '%s\n' "$owners"
fi

runtime_topic() {
  local topic="$1"
  local expected_type="$2"
  local info
  info="$(timeout 10s ros2 topic info --no-daemon "$topic" 2>&1)"
  if grep -Fq "Type: $expected_type" <<<"$info" &&
     grep -Eq 'Publisher count: [1-9]' <<<"$info"; then
    pass "runtime topic: $topic [$expected_type]"
  else
    fail "missing runtime topic/type: $topic [$expected_type]"
    printf '%s\n' "$info"
  fi
}

runtime_param() {
  local name="$1"
  local expected="$2"
  local value
  value="$(timeout 10s ros2 param get --no-daemon /zed/zed_node "$name" 2>&1)"
  if grep -Fq "$expected" <<<"$value"; then
    pass "runtime parameter: $name = $expected"
  else
    fail "unexpected runtime parameter: $name (expected $expected)"
    printf '%s\n' "$value"
  fi
}

runtime_rate_measure() {
  local topic="$1"
  local expected="$2"
  local output average
  output="$(timeout --signal=INT 20s ros2 topic hz --wall-time --window 60 "$topic" 2>&1)"
  average="$(sed -n 's/^average rate: \([0-9.]*\).*/\1/p' <<<"$output" | tail -n1)"
  if [[ -n "$average" ]] && awk -v got="$average" -v want="$expected" \
    'BEGIN { exit !(got >= want * 0.50 && got <= want * 1.50) }'; then
    printf 'PASS  runtime rate: %s = %s Hz (configured cap %s Hz)\n' \
      "$topic" "$average" "$expected"
    return 0
  else
    printf 'FAIL  runtime rate: %s did not approach configured %s Hz\n' \
      "$topic" "$expected"
    printf '%s\n' "$output"
    return 1
  fi
}

if $RUNTIME && ((failures == 0)); then
  echo
  echo "Running-node checks (read-only; allow about 45 seconds)"
  export ROS2CLI_DISABLE_DAEMON=1
  nodes="$(timeout 10s ros2 node list --no-daemon 2>&1)"
  if grep -Fxq '/zed/zed_node' <<<"$nodes"; then
    pass "runtime node: /zed/zed_node"
  else
    fail "runtime node /zed/zed_node not discovered"
    printf '%s\n' "$nodes"
  fi

  runtime_topic /zed/zed_node/rgb/color/rect/image sensor_msgs/msg/Image
  runtime_topic /zed/zed_node/rgb/color/rect/image/compressed sensor_msgs/msg/CompressedImage
  runtime_topic /zed/zed_node/depth/depth_registered sensor_msgs/msg/Image
  runtime_topic /zed/zed_node/depth/depth_registered/compressedDepth sensor_msgs/msg/CompressedImage
  runtime_topic /zed/zed_node/point_cloud/cloud_registered sensor_msgs/msg/PointCloud2
  runtime_topic /zed/zed_node/rgb/color/rect/camera_info sensor_msgs/msg/CameraInfo
  runtime_topic /zed/zed_node/depth/camera_info sensor_msgs/msg/CameraInfo

  runtime_param general.grab_resolution HD1200
  runtime_param general.pub_downscale_factor 2.0
  runtime_param general.pub_frame_rate 5.0
  runtime_param depth.depth_mode NEURAL
  runtime_param depth.depth_stabilization 0
  runtime_param depth.point_cloud_freq 2.0

  viewer_direct=false
  viewer_rgb_info="$(timeout 10s ros2 topic info --no-daemon /zed/zed_node/rgb/color/rect/image/compressed 2>&1)"
  viewer_depth_info="$(timeout 10s ros2 topic info --no-daemon /zed/zed_node/depth/depth_registered/compressedDepth 2>&1)"
  viewer_cloud_info="$(timeout 10s ros2 topic info --no-daemon /zed_field/point_cloud/cloud_registered 2>&1)"
  if grep -Fq 'Type: sensor_msgs/msg/CompressedImage' <<<"$viewer_rgb_info" &&
     grep -Eq 'Subscription count: [1-9]' <<<"$viewer_rgb_info" &&
     grep -Fq 'Type: sensor_msgs/msg/CompressedImage' <<<"$viewer_depth_info" &&
     grep -Eq 'Subscription count: [1-9]' <<<"$viewer_depth_info" &&
     grep -Fq 'Type: sensor_msgs/msg/PointCloud2' <<<"$viewer_cloud_info" &&
     grep -Eq 'Publisher count: [1-9]' <<<"$viewer_cloud_info" &&
     grep -Eq 'Subscription count: [1-9]' <<<"$viewer_cloud_info"; then
    viewer_direct=true
    pass "runtime viewer: direct compressed images plus decoded Draco cloud"
  fi

  rate_dir="$(mktemp -d /tmp/zed-ros2-rates.XXXXXX)"
  if $viewer_direct; then
    rate_topics=(
      /zed/zed_node/rgb/color/rect/image/compressed
      /zed/zed_node/depth/depth_registered/compressedDepth
      /zed_field/point_cloud/cloud_registered
    )
  else
    rate_topics=(
      /zed/zed_node/rgb/color/rect/image
      /zed/zed_node/depth/depth_registered
      /zed/zed_node/point_cloud/cloud_registered
    )
  fi
  rate_targets=(5 5 2)
  rate_pids=()
  for i in "${!rate_topics[@]}"; do
    runtime_rate_measure "${rate_topics[$i]}" "${rate_targets[$i]}" \
      >"$rate_dir/$i" 2>&1 &
    rate_pids+=("$!")
  done
  for i in "${!rate_pids[@]}"; do
    if wait "${rate_pids[$i]}"; then
      cat "$rate_dir/$i"
    else
      cat "$rate_dir/$i"
      failures=$((failures + 1))
    fi
  done
  rm -rf "$rate_dir"
fi

echo
zed_ros_print_network_environment
echo
printf 'Result: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
((failures == 0))
