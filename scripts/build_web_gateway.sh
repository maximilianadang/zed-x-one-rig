#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

BUILD_DIR="$ROOT/build/web_gateway"
JOBS="${ZED_WEB_BUILD_JOBS:-$(nproc)}"

usage() {
  cat <<EOF
Build the loopback-only ZED browser gateway.

Copy/paste on the Jetson:
  $ROOT/scripts/build_web_gateway.sh

Options:
  --clean       Remove only the gateway build directory before building
  --jobs N      Parallel compiler jobs (default: $JOBS)
  -h, --help    Show this help

This does not install packages, open cameras, alter ROS profiles, or change the
existing RViz/recording paths.
EOF
}

CLEAN=false
while (($#)); do
  case "$1" in
    --clean) CLEAN=true ;;
    --jobs) JOBS="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Build jobs must be a positive integer: $JOBS" >&2
  exit 2
}

zed_ros_source_environment

if $CLEAN; then
  rm -rf -- "$BUILD_DIR"
fi

cmake -S "$ROOT/gateway" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install"
cmake --build "$BUILD_DIR" --parallel "$JOBS"

binary="$BUILD_DIR/zed_web_gateway"
[[ -x "$binary" ]] || {
  echo "Gateway build did not produce: $binary" >&2
  exit 1
}

echo "Built ZED browser gateway:"
echo "  $binary"
