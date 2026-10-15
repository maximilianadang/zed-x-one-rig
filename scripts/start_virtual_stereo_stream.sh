#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"
CONFIG="$ROOT/config/virtual_xone_config.json"

zed_ros_check_calibration
zed_ros_require_no_owner
zed_ros_check_hardware_identity true

echo "Starting calibrated virtual stereo stream"
echo "  Left:    306605936"
echo "  Right:   304467158"
echo "  Virtual: 117941018"
echo "  Stream:  127.0.0.1:34000"
echo
echo "Keep this terminal open. Press Ctrl+C to stop."

exec /usr/local/bin/ZED_Media_Server --cli --config "$CONFIG"
