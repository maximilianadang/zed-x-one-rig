#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/field_console.env"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

UNIT="${ZED_REPLAY_UNIT_OVERRIDE:-$ZED_REPLAY_UNIT}"
OUTPUT_DIR="${ZED_FIELD_OUTPUT_DIR_OVERRIDE:-$ZED_FIELD_OUTPUT_DIR}"
START_TIMEOUT="${ZED_FIELD_START_TIMEOUT_OVERRIDE:-$ZED_FIELD_START_TIMEOUT}"
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE_DIR="$RUNTIME_BASE/zed-replay-console"
STATUS_FILE="$STATE_DIR/playback.status"
COMMAND_SOCKET="$STATE_DIR/control.sock"
COMMAND_LOCK="$STATE_DIR/command.lock"
MACHINE=false

usage() {
  cat <<EOF
Manage headless SVO2 replay on the Jetson for a remote RViz workstation.

Most likely commands on the Jetson:
  $ROOT/scripts/zed_replay_session.sh list
  $ROOT/scripts/zed_replay_session.sh start --latest
  $ROOT/scripts/zed_replay_session.sh status
  $ROOT/scripts/zed_replay_session.sh pause-toggle
  $ROOT/scripts/zed_replay_session.sh stop

Commands:
  list [--machine] [--limit N]           List finalized SVO2 files, newest first
  start [--latest|--index N|--svo PATH]  Start or attach; paused at frame zero
        [--profile PATH] [--loop] [--rate 0.1-5.0]
  status [--machine]                     Show file, frame, time, rate, and state
  pause-toggle                            Toggle paused/playing
  pause | play                            Set an explicit playback state
  next                                    Advance one frame sequentially and pause
  speed up|down|RATE                      Change playback speed from 0.1x to 5x
  stop                                    Stop the transient replay unit
  logs                                    Show recent replay-unit logs
  -h, --help                              Show this help
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

ensure_runtime() {
  [[ -d "$RUNTIME_BASE" ]] || die "Missing user runtime directory: $RUNTIME_BASE"
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
}

lock_commands() {
  ensure_runtime
  exec 9>"$COMMAND_LOCK"
  flock -w 15 9 || die "Another replay command is still running"
}

unit_active() {
  systemctl --user is-active --quiet "$UNIT"
}

state_value() {
  local name="$1"
  [[ -r "$STATE_DIR/$name" ]] && head -n1 "$STATE_DIR/$name" || true
}

monitor_value() {
  local name="$1"
  [[ -r "$STATUS_FILE" ]] && sed -n "s/^${name}=//p" "$STATUS_FILE" | head -n1 || true
}

write_state() {
  local name="$1" value="$2" temporary
  temporary="$STATE_DIR/.${name}.tmp.$$"
  printf '%s\n' "$value" >"$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$STATE_DIR/$name"
}

clear_session_state() {
  rm -f -- "$STATE_DIR/session.svo" "$STATE_DIR/session.profile" \
    "$STATE_DIR/session.frames" "$STATE_DIR/session.fps" \
    "$STATE_DIR/session.loop" "$STATE_DIR/session.rate" \
    "$STATE_DIR/session.started" "$STATUS_FILE" "$COMMAND_SOCKET"
}

reset_ros_cli_daemon() {
  timeout 5s ros2 daemon stop >/dev/null 2>&1 || true
}

show_logs() {
  journalctl "_SYSTEMD_USER_UNIT=$UNIT" -n 200 --no-pager
}

recording_at_index() {
  local index="$1" line
  [[ "$index" =~ ^[1-9][0-9]*$ ]] || die "Recording index must be a positive integer: $index"
  line="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.svo2' \
    ! -name '*.recording.svo2' -printf '%T@|%p\n' 2>/dev/null |
    sort -t'|' -k1,1nr | sed -n "${index}p")"
  [[ -n "$line" ]] || die "No finalized SVO2 exists at index $index in $OUTPUT_DIR"
  printf '%s' "${line#*|}"
}

list_recordings() {
  local limit=12 count=0 modified bytes path stamp
  while (($#)); do
    case "$1" in
      --machine) MACHINE=true ;;
      --limit) limit="${2:-}"; shift ;;
      *) die "Unknown list option: $1" ;;
    esac
    shift
  done
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "List limit must be a positive integer: $limit"

  if ! $MACHINE; then
    echo "Finalized ZED recordings (newest first)"
    printf '%-4s %-19s %10s  %s\n' "#" "Modified" "Size" "File"
  fi
  while IFS='|' read -r modified bytes path; do
    [[ -n "$path" ]] || continue
    count=$((count + 1))
    ((count <= limit)) || break
    stamp="$(date -d "@${modified%.*}" '+%Y-%m-%d %H:%M:%S')"
    if $MACHINE; then
      printf '%s\t%s\t%s\t%s\n' "$count" "${modified%.*}" "$bytes" "$path"
    else
      printf '%-4s %-19s %10s  %s\n' "$count" "$stamp" \
        "$(numfmt --to=iec-i --suffix=B "$bytes")" "$(basename -- "$path")"
    fi
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.svo2' \
    ! -name '*.recording.svo2' -printf '%T@|%s|%p\n' 2>/dev/null |
    sort -t'|' -k1,1nr)
  ((count > 0)) || die "No finalized SVO2 recordings found in $OUTPUT_DIR"
}

validate_rate() {
  local rate="$1"
  [[ "$rate" =~ ^([0-4]([.][0-9]+)?|5([.]0+)?|[.]([0-9]+))$ ]] || return 1
  awk -v rate="$rate" 'BEGIN {exit !(rate >= 0.1 && rate <= 5.0)}'
}

validate_svo() {
  local svo="$1" info frames fps
  info="$(ZED_SVO_Editor -inf "$svo" 2>&1)" || {
    printf '%s\n' "$info" >&2
    return 1
  }
  grep -q 'SVO Infos : SVO v 2' <<<"$info" || return 1
  grep -q "ZED Serial Number :  $VIRTUAL_SERIAL" <<<"$info" || return 1
  frames="$(sed -n 's/^Number of Frames :  *//p' <<<"$info" | head -n1)"
  fps="$(sed -n 's/^Framerate :  *//p' <<<"$info" | head -n1)"
  [[ "$frames" =~ ^[1-9][0-9]*$ && "$fps" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s %s' "$frames" "$fps"
}

wait_for_status() {
  local deadline=$((SECONDS + START_TIMEOUT)) status
  while ((SECONDS < deadline)); do
    unit_active || return 1
    status="$(monitor_value STATUS)"
    if [[ -S "$COMMAND_SOCKET" ]] &&
       [[ "$status" == PLAYING || "$status" == PAUSED || "$status" == END ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

control_command() {
  python3 "$ROOT/tools/zed_replay_command.py" --socket "$COMMAND_SOCKET" "$@"
}

call_pause_toggle() {
  control_command pause-toggle
}

call_seek() {
  control_command seek "$1"
}

wait_for_monitor_state() {
  local wanted="$1" deadline=$((SECONDS + 4))
  while ((SECONDS < deadline)); do
    [[ "$(monitor_value STATUS)" == "$wanted" ]] && return 0
    sleep 0.2
  done
  return 1
}

ensure_paused() {
  local status
  status="$(monitor_value STATUS)"
  [[ "$status" == PAUSED ]] && return 0
  call_pause_toggle || return 1
  wait_for_monitor_state PAUSED || true
}

print_status() {
  local unit state svo profile frames fps loop rate frame status loops updated bytes
  ensure_runtime
  svo="$(state_value session.svo)"
  profile="$(state_value session.profile)"
  frames="$(state_value session.frames)"
  fps="$(state_value session.fps)"
  loop="$(state_value session.loop)"
  rate="$(state_value session.rate)"
  frame="$(monitor_value FRAME_ID)"
  status="$(monitor_value STATUS)"
  loops="$(monitor_value LOOP_COUNT)"
  updated="$(monitor_value UPDATED_NS)"
  bytes=0
  [[ -n "$svo" && -f "$svo" ]] && bytes="$(stat -c %s "$svo")"

  if unit_active; then
    unit=active
    state="${status:-STARTING}"
  else
    unit=inactive
    state=STOPPED
  fi
  frame="${frame:-0}"
  frames="${frames:-0}"
  fps="${fps:-$FPS}"
  loop="${loop:-false}"
  rate="${rate:-1.0}"
  loops="${loops:-0}"

  if $MACHINE; then
    printf 'STATE=%s\nUNIT=%s\nSVO=%s\nSVO_BYTES=%s\n' "$state" "$unit" "$svo" "$bytes"
    printf 'FRAME_ID=%s\nTOTAL_FRAMES=%s\nFPS=%s\nRATE=%s\n' "$frame" "$frames" "$fps" "$rate"
    printf 'LOOP=%s\nLOOP_COUNT=%s\nPROFILE=%s\nUPDATED_NS=%s\n' \
      "$loop" "$loops" "$profile" "$updated"
    return
  fi

  echo "ZED replay session"
  echo "  State:     $state"
  echo "  Unit:      $unit"
  [[ -n "$svo" ]] && echo "  File:      $svo"
  echo "  Frame:     $frame / $frames"
  echo "  Speed:     ${rate}x"
  echo "  Loop:      $loop (completed: $loops)"
  [[ -n "$profile" ]] && echo "  Profile:   $profile"
}

start_session() {
  local selection=latest index=1 svo="" profile="$ZED_ROS_PROFILE" loop=false rate=1.0 metadata frames fps
  while (($#)); do
    case "$1" in
      --latest) selection=latest ;;
      --index) selection=index; index="${2:-}"; shift ;;
      --svo) selection=path; svo="${2:-}"; shift ;;
      --profile) profile="${2:-}"; shift ;;
      --loop) loop=true ;;
      --rate) rate="${2:-}"; shift ;;
      *) die "Unknown start option: $1" ;;
    esac
    shift
  done
  validate_rate "$rate" || die "Replay rate must be between 0.1 and 5.0: $rate"
  case "$selection" in
    latest) svo="$(recording_at_index 1)" ;;
    index) svo="$(recording_at_index "$index")" ;;
  esac
  svo="$(realpath -e "$svo")" || die "Unreadable SVO2: $svo"
  profile="$(realpath -e "$profile")" || die "Unreadable ROS profile: $profile"
  [[ "$svo" == *.svo2 || "$svo" == *.svo ]] || die "Expected an SVO/SVO2 file: $svo"

  lock_commands
  if unit_active; then
    [[ "$(state_value session.svo)" == "$svo" ]] || \
      die "Replay is already active with $(state_value session.svo)"
    [[ "$(state_value session.profile)" == "$profile" ]] || \
      die "Replay is already active with a different profile"
    echo "Transient replay session is already active; attaching."
    print_status
    return
  fi

  metadata="$(validate_svo "$svo")" || die "Invalid SVO2 or wrong virtual serial: $svo"
  read -r frames fps <<<"$metadata"
  zed_ros_check_calibration
  zed_ros_user_manager_persistent || \
    die "No persistent user manager: run once with sudo loginctl enable-linger $(id -un)"
  zed_ros_source_environment
  reset_ros_cli_daemon
  zed_ros_require_no_owner
  clear_session_state
  write_state session.svo "$svo"
  write_state session.profile "$profile"
  write_state session.frames "$frames"
  write_state session.fps "$fps"
  write_state session.loop "$loop"
  write_state session.rate "$rate"
  write_state session.started "$(date +%s)"

  echo "Starting transient Jetson replay: $UNIT"
  echo "  File:   $svo"
  echo "  Frames: $frames at $fps FPS"
  systemd-run --user --unit="$UNIT" --collect \
    --property=KillSignal=SIGINT \
    --property=TimeoutStopSec=30s \
    --property=SuccessExitStatus=SIGINT \
    --setenv="CYCLONEDDS_URI=file://$ROOT/config/ros2/cyclonedds-jetson.xml" \
    "$ROOT/scripts/run_svo_replay_session.sh" "$STATUS_FILE" "$COMMAND_SOCKET" \
      "$profile" "$svo" "$loop" "$rate" \
    >/dev/null

  echo "Waiting up to ${START_TIMEOUT}s for controlled SVO playback..."
  if ! wait_for_status; then
    show_logs >&2 || true
    systemctl --user stop "$UNIT" 2>/dev/null || true
    clear_session_state
    die "Replay did not publish status within ${START_TIMEOUT}s"
  fi

  # Pause before the remote viewer opens, then rewind so no field footage is
  # missed during ROS discovery and RViz startup.
  ensure_paused || {
    systemctl --user stop "$UNIT" 2>/dev/null || true
    clear_session_state
    die "Replay opened but could not enter controlled pause mode"
  }
  sleep 0.6
  call_seek 0 || {
    systemctl --user stop "$UNIT" 2>/dev/null || true
    clear_session_state
    die "Replay opened but could not rewind to frame zero"
  }
  echo "Replay is ready, paused at frame zero. Press p or Space on the workstation to play."
  print_status
}

require_active() {
  unit_active || die "No replay session is active"
  [[ -S "$COMMAND_SOCKET" ]] || die "Replay control socket is unavailable"
}

pause_toggle() {
  lock_commands
  require_active
  if [[ "$(monitor_value STATUS)" == END ]]; then
    die "Replay reached the end; reopen the dataset from the field console"
  else
    call_pause_toggle || die "Pause/play request failed"
  fi
  sleep 0.3
  print_status
}

set_play_state() {
  local wanted="$1" current
  lock_commands
  require_active
  current="$(monitor_value STATUS)"
  if [[ "$wanted" == PAUSED ]]; then
    [[ "$current" == PAUSED ]] || call_pause_toggle || die "Pause request failed"
  else
    if [[ "$current" == END ]]; then
      die "Replay reached the end; reopen the dataset from the field console"
    elif [[ "$current" == PAUSED ]]; then
      call_pause_toggle || die "Play request failed"
    fi
  fi
  sleep 0.3
  print_status
}

play_next_frame() {
  local rate
  lock_commands
  require_active
  rate="$(state_value session.rate)"
  rate="${rate:-1.0}"
  control_command play-next "$rate" || die "Sequential next-frame request failed"
  print_status
}

refresh_current_frame() {
  local current
  lock_commands
  require_active
  ensure_paused || die "Could not pause before refreshing the current frame"
  current="$(monitor_value FRAME_ID)"
  current="${current:-0}"
  sleep 0.55
  call_seek "$current" || die "Could not refresh the current frame"
}

next_rate() {
  local direction="$1" current="$2"
  case "$direction:$current" in
    up:0.1) echo 0.25 ;; up:0.25) echo 0.5 ;; up:0.5) echo 1.0 ;;
    up:1.0|up:1) echo 1.5 ;; up:1.5) echo 2.0 ;; up:2.0|up:2) echo 3.0 ;;
    up:3.0|up:3) echo 5.0 ;; up:5.0|up:5) echo 5.0 ;;
    down:5.0|down:5) echo 3.0 ;; down:3.0|down:3) echo 2.0 ;;
    down:2.0|down:2) echo 1.5 ;; down:1.5) echo 1.0 ;;
    down:1.0|down:1) echo 0.5 ;; down:0.5) echo 0.25 ;;
    down:0.25) echo 0.1 ;; down:0.1) echo 0.1 ;;
    *) [[ "$direction" == up ]] && echo 1.0 || echo 0.5 ;;
  esac
}

set_speed() {
  local requested="$1" current rate
  lock_commands
  require_active
  current="$(state_value session.rate)"
  case "$requested" in
    up|down) rate="$(next_rate "$requested" "${current:-1.0}")" ;;
    *) rate="$requested" ;;
  esac
  validate_rate "$rate" || die "Replay rate must be between 0.1 and 5.0: $rate"
  control_command speed "$rate" || die "Wrapper rejected replay rate $rate"
  write_state session.rate "$rate"
  print_status
}

stop_session() {
  lock_commands
  if ! unit_active; then
    clear_session_state
    echo "Replay session is already stopped."
    return
  fi
  echo "Stopping transient replay session..."
  systemctl --user kill --signal=SIGINT "$UNIT" 2>/dev/null || true
  deadline=$((SECONDS + 30))
  while unit_active && ((SECONDS < deadline)); do sleep 1; done
  unit_active && systemctl --user stop "$UNIT"
  clear_session_state
  zed_ros_require_no_owner || die "Replay unit stopped but a ZED ROS process remains"
  echo "Replay session stopped cleanly."
}

command="${1:-}"
[[ -n "$command" ]] || { usage >&2; exit 2; }
shift || true
case "$command" in
  list) list_recordings "$@" ;;
  start) start_session "$@" ;;
  status)
    case "${1:-}" in --machine) MACHINE=true ;; "") ;; *) die "Unknown status option: $1" ;; esac
    print_status
    ;;
  pause-toggle) pause_toggle ;;
  pause) set_play_state PAUSED ;;
  play) set_play_state PLAYING ;;
  next) play_next_frame ;;
  speed) set_speed "${1:-}" ;;
  _refresh-current-frame) refresh_current_frame ;;
  stop) stop_session ;;
  logs) show_logs ;;
  -h|--help|help) usage ;;
  *) echo "Unknown command: $command" >&2; usage >&2; exit 2 ;;
esac
