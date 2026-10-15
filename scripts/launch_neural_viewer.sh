#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"
BUILT="$ROOT/build/calibration/stereo_reprojection_viewer/zed_reprojection_viewer"
PREBUILT="$ROOT/prebuilt/jetson-l4t-r36.5.0-aarch64/zed_reprojection_viewer"

if [[ -x "$BUILT" ]]; then
  BINARY="$BUILT"
elif [[ -x "$PREBUILT" ]]; then
  BINARY="$PREBUILT"
else
  echo "NEURAL viewer is missing. Run: $ROOT/scripts/build.sh" >&2
  exit 1
fi

case "${1:-}" in
  -h|--help) exec "$BINARY" "$@" ;;
esac

zed_ros_check_calibration
zed_ros_require_no_owner
zed_ros_check_hardware_identity true

exec "$BINARY" \
  --virtual \
  --left_id 1 \
  --right_id 0 \
  --ocv "$ROOT/calibration/active/zed_calibration_117941018.yml" \
  "$@"
