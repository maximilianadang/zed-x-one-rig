#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${JOBS:-$(nproc)}"

echo "Building rig recorder..."
cmake -S "$ROOT/recorder" -B "$ROOT/build/recorder" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/build/recorder" --parallel "$JOBS"

echo "Building vendored ZED OpenCV calibration tools..."
cmake -S "$ROOT/vendor/zed-opencv-calibration" \
  -B "$ROOT/build/calibration" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/build/calibration" --parallel "$JOBS"

echo
echo "Build complete."
echo "Recorder: $ROOT/build/recorder/zed_virtual_stereo_recorder"
echo "Calibration: $ROOT/build/calibration/stereo_calibration/zed_stereo_calibration"
echo "NEURAL viewer: $ROOT/build/calibration/stereo_reprojection_viewer/zed_reprojection_viewer"
