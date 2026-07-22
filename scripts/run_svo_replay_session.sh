#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

STATUS_FILE="${1:-}"
COMMAND_SOCKET="${2:-}"
PROFILE="${3:-}"
SVO="${4:-}"
LOOP="${5:-false}"
RATE="${6:-1.0}"

[[ "$STATUS_FILE" == /* && "$COMMAND_SOCKET" == /* && -n "$PROFILE" && -n "$SVO" ]] || {
  echo "Usage: $0 STATUS_FILE COMMAND_SOCKET PROFILE SVO LOOP RATE" >&2
  exit 2
}

zed_ros_source_environment
rm -f -- "$STATUS_FILE"
python3 "$ROOT/tools/zed_svo_status_monitor.py" \
  --output "$STATUS_FILE" --socket "$COMMAND_SOCKET" &

command=(
  "$ROOT/scripts/play_svo_ros2.sh"
  --profile "$PROFILE"
  --controlled
  --rate "$RATE"
)
[[ "$LOOP" == true ]] && command+=(--loop)
command+=("$SVO")

# The monitor remains in this systemd unit's cgroup. Stopping the unit signals
# both it and the ROS launch, while exec keeps ROS as the unit's main process.
exec "${command[@]}"
