#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

TOKEN_FILE="${1:-}"
PORT="${2:-8765}"
BINARY="$ROOT/build/web_gateway/zed_web_gateway"
LOOPBACK_DDS="$ROOT/config/ros2/cyclonedds-loopback.xml"

[[ "$TOKEN_FILE" == /* && -r "$TOKEN_FILE" ]] || {
  echo "Usage: $0 ABSOLUTE_TOKEN_FILE [PORT]" >&2
  exit 2
}
[[ "$PORT" =~ ^[1-9][0-9]{0,4}$ && "$PORT" -le 65535 ]] || {
  echo "Invalid gateway port: $PORT" >&2
  exit 2
}
[[ -x "$BINARY" ]] || {
  echo "Missing gateway binary. Run: $ROOT/scripts/build_web_gateway.sh" >&2
  exit 1
}
[[ -r "$LOOPBACK_DDS" ]] || {
  echo "Missing browser loopback DDS profile: $LOOPBACK_DDS" >&2
  exit 1
}

export CYCLONEDDS_URI="file://$LOOPBACK_DDS"
export ZED_SESSION_DDS_PROFILE_OVERRIDE="$LOOPBACK_DDS"
zed_ros_source_environment
exec "$BINARY" \
  --rig-root "$ROOT" \
  --web-root "$ROOT/web" \
  --token-file "$TOKEN_FILE" \
  --port "$PORT"
