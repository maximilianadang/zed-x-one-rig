#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT="$ROOT/build/calibration/stereo_calibration/zed_stereo_calibration"
PREBUILT="$ROOT/prebuilt/jetson-l4t-r36.5.0-aarch64/zed_stereo_calibration"

if [[ -x "$BUILT" ]]; then
  BINARY="$BUILT"
elif [[ -x "$PREBUILT" ]]; then
  BINARY="$PREBUILT"
else
  echo "Calibration tool is missing. Run: $ROOT/scripts/build.sh" >&2
  exit 1
fi

exec "$BINARY" \
  --virtual \
  --left_sn 304467158 \
  --right_sn 306605936 \
  --h_edges 9 \
  --v_edges 6 \
  --square_size 93.0 \
  "$@"
