#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/config/virtual_xone_config.json"
CALIBRATION="/usr/local/zed/settings/SN116863460.conf"

if [[ ! -r "$CALIBRATION" ]]; then
  echo "Missing installed virtual calibration: $CALIBRATION" >&2
  echo "Run: $ROOT/scripts/install.sh" >&2
  exit 1
fi

echo "Starting calibrated virtual stereo stream"
echo "  Left:    304467158"
echo "  Right:   306605936"
echo "  Virtual: 116863460"
echo "  Stream:  127.0.0.1:34000"
echo
echo "Keep this terminal open. Press Ctrl+C to stop."

exec /usr/local/bin/ZED_Media_Server --cli --config "$CONFIG"
