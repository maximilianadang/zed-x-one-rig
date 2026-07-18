#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
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

exec "$BINARY" \
  --virtual \
  --left_sn 304467158 \
  --right_sn 306605936 \
  "$@"
