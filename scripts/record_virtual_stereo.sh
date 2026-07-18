#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT="$ROOT/build/recorder/zed_virtual_stereo_recorder"
PREBUILT="$ROOT/prebuilt/jetson-l4t-r36.5.0-aarch64/zed_virtual_stereo_recorder"

if [[ -x "$BUILT" ]]; then
  BINARY="$BUILT"
elif [[ -x "$PREBUILT" ]]; then
  BINARY="$PREBUILT"
else
  echo "Recorder is not built and the known-good prebuilt binary is missing." >&2
  echo "Run: $ROOT/scripts/build.sh" >&2
  exit 1
fi

exec "$BINARY" "$@"
