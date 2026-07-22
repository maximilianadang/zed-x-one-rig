#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/ros2/versions.env"

RVIZ_CONFIG="$ROOT/rviz/virtual_stereo.rviz"
READY_FILE="${ZED_RVIZ_READY_FILE:-}"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$DEFAULT_ROS_DOMAIN_ID}"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-$DEFAULT_RMW_IMPLEMENTATION}"
export CYCLONEDDS_URI="${CYCLONEDDS_URI:-file://$ROOT/config/ros2/cyclonedds.xml}"

usage() {
  cat <<EOF
Open the same-LAN RViz2 display for this virtual stereo rig.

Copy/paste remote viewer command:
  $ROOT/scripts/start_ros2_rviz.sh

Options:
  -h, --help  Show this help

The workstation must be Ubuntu 22.04 with the receiver packages installed:
  $ROOT/scripts/install_ros2_remote.sh

The remote workstation does not need the ZED SDK or CUDA.
RViz subscribes directly to the ZED wrapper's compressed color and depth
topics. A single local helper decodes Draco because Humble's PointCloud2
display accepts only sensor_msgs/PointCloud2. The launcher reports graph
discovery before launch and does not create duplicate high-bandwidth health
subscribers. Ctrl+C closes RViz and the helper.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

if [[ ! -r "/opt/ros/$ROS_DISTRO/setup.bash" ]]; then
  echo "ROS 2 $ROS_DISTRO is not installed." >&2
  echo "Run: $ROOT/scripts/install_ros2_remote.sh" >&2
  exit 1
fi
[[ -r "$RVIZ_CONFIG" ]] || { echo "Missing RViz configuration: $RVIZ_CONFIG" >&2; exit 1; }

# shellcheck disable=SC1090
set +u
source "/opt/ros/$ROS_DISTRO/setup.bash"
set -u

for package in image_transport compressed_image_transport \
  compressed_depth_image_transport point_cloud_transport \
  draco_point_cloud_transport rviz2; do
  if ! ros2 pkg prefix "$package" >/dev/null 2>&1; then
    echo "Missing receiver package: $package" >&2
    echo "Run: $ROOT/scripts/install_ros2_remote.sh" >&2
    exit 1
  fi
done

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  echo "No graphical display is available on this workstation terminal." >&2
  echo "Run this command from a terminal inside the workstation desktop session." >&2
  exit 1
fi

if [[ -n "$READY_FILE" ]]; then
  mkdir -p "$(dirname -- "$READY_FILE")"
  rm -f -- "$READY_FILE"
fi

echo "Opening RViz2 for ROS domain $ROS_DOMAIN_ID"
echo "Fixed frame: zed_camera_link (X forward, Y left, Z up)"
echo "RGB transport:   /zed/zed_node/rgb/color/rect/image/compressed"
echo "Depth transport: /zed/zed_node/depth/depth_registered/compressedDepth"
echo "Point transport: /zed/zed_node/point_cloud/cloud_registered/draco"

pids=()
cleanup() {
  local pid alive deadline
  trap - EXIT INT TERM
  for pid in "${pids[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  deadline=$((SECONDS + 8))
  while ((SECONDS < deadline)); do
    alive=false
    for pid in "${pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive=true
    done
    $alive || break
    sleep 1
  done
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# RViz's Image display is itself an image_transport subscriber. Giving it the
# transport-suffixed ZED topics makes it select compressed/compressedDepth
# directly, without intermediate raw-image publishers or extra DDS endpoints.
ros2 run point_cloud_transport republish --ros-args \
  -p in_transport:=draco \
  -p out_transport:=raw \
  --remap in/draco:=/zed/zed_node/point_cloud/cloud_registered/draco \
  --remap out:=/zed_field/point_cloud/cloud_registered &
pids+=("$!")

rviz2 -d "$RVIZ_CONFIG" &
rviz_pid=$!
pids+=("$rviz_pid")

sleep 2
kill -0 "$rviz_pid" 2>/dev/null || {
  echo "RViz exited before its window became ready." >&2
  exit 1
}

# The controller must become interactive as soon as the window is alive.
# Receiving another copy of each large image merely to prove RViz is receiving
# one duplicates network traffic and can starve a marginal field LAN. The
# source-topic preflight already ran in zed_field_console.sh; report window
# readiness immediately and let the operator judge the visible frames.
[[ -z "$READY_FILE" ]] || printf 'window-alive\n' >"$READY_FILE"
echo "RViz window ready; use its visible panes to judge live frame delivery."
wait "$rviz_pid"
