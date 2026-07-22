#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The camera publisher crosses a 1500-byte field LAN. Select the sender profile
# before ros2_common assigns its general workstation/loopback default.
export CYCLONEDDS_URI="${CYCLONEDDS_URI:-file://$ROOT/config/ros2/cyclonedds-jetson.xml}"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

DRY_RUN=false
PROFILE="$ZED_ROS_PROFILE"

usage() {
  cat <<EOF
Publish this calibrated dual ZED X One rig over ROS 2.

Copy/paste field launch:
  $ROOT/scripts/start_ros2_virtual_stereo.sh

On the remote Ubuntu 22.04 workstation:
  $ROOT/scripts/start_ros2_rviz.sh

Options:
  --profile PATH  ROS parameter override (default: $PROFILE)
  --dry-run       Validate and print the exact command without opening cameras
  -h, --help      Show this help

Native processing is HD1200 at 15 FPS with NEURAL depth. The field profile
publishes 960x600 image/depth at 5 FPS and a reduced point cloud at 2 FPS.
This foreground process owns both cameras. Press Ctrl+C and wait for shutdown.
EOF
}

while (($#)); do
  case "$1" in
    --profile) PROFILE="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -r "$PROFILE" ]] || { echo "Missing ROS profile: $PROFILE" >&2; exit 1; }
zed_ros_check_calibration
zed_ros_source_environment
zed_ros_require_no_owner

command=(
  ros2 launch zed_wrapper zed_camera.launch.py
  camera_model:=virtual
  camera_name:=zed
  "serial_numbers:=[$LEFT_SERIAL,$RIGHT_SERIAL]"
  "ros_params_override_path:=$PROFILE"
  publish_urdf:=true
  publish_tf:=false
  publish_map_tf:=false
  publish_imu_tf:=false
  enable_ipc:=true
  node_log_type:=both
)

if $DRY_RUN; then
  echo "Validated ROS 2 live command:"
  printf ' %q' "${command[@]}"
  echo
  zed_ros_print_network_environment
  exit 0
fi

explorer="$(ZED_Explorer --all 2>&1)"
for serial in "$LEFT_SERIAL" "$RIGHT_SERIAL"; do
  block="$(grep -A4 "S/N :  $serial" <<<"$explorer" || true)"
  if [[ -z "$block" ]] || ! grep -q 'State :  "AVAILABLE"' <<<"$block"; then
    echo "Camera $serial is not AVAILABLE:" >&2
    printf '%s\n' "$block" >&2
    exit 1
  fi
done

echo "Starting ROS 2 calibrated virtual stereo"
echo "  Left:        $LEFT_SERIAL"
echo "  Right:       $RIGHT_SERIAL"
echo "  Virtual:     $VIRTUAL_SERIAL"
echo "  Native:      ${WIDTH}x${HEIGHT} @ ${FPS} FPS"
echo "  Depth:       NEURAL"
echo "  Profile:     $PROFILE"
echo "  ROS domain:  $ROS_DOMAIN_ID"
echo "  Middleware:  $RMW_IMPLEMENTATION"
echo
echo "Press Ctrl+C and wait for ROS shutdown before recording or opening another tool."

exec "${command[@]}"
