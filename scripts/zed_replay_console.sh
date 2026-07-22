#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/field_console.env"
# shellcheck disable=SC1091
source "$ROOT/config/ros2/versions.env"

JETSON="${ZED_FIELD_JETSON:-$ZED_FIELD_DEFAULT_JETSON}"
REMOTE_ROOT="${ZED_FIELD_REMOTE_ROOT_OVERRIDE:-$ZED_FIELD_REMOTE_ROOT}"
VIEW_PROFILE=field
INDEX=1
SVO=""
SELECTION_MODE=choose
RATE=1.0
LOOP=false
NO_RVIZ=false
DRY_RUN=false
ACTION=console
RVIZ_PID=""
CURRENT_FRAME=0
CURRENT_TOTAL=0
CURRENT_FPS=15
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/tmp/zed-replay-console-$(id -u)}"
CONTROL_PATH="$RUNTIME_BASE/zed-field-ssh-%C"
RVIZ_LOG="$RUNTIME_BASE/zed-replay-rviz-$(id -u).log"
RVIZ_READY="$RUNTIME_BASE/zed-replay-rviz-$(id -u).ready"
TTY_STATE=""
FOOTER_DRAWN=false
STATUS_TEXT="REPLAY STARTING"
STATUS_STYLE="1;33"
CONTROL_TEXT="Keys: Space/p play-pause | o open dataset | ←/→ 1s | ,/. frame | -/+ speed | i info | v RViz | q quit"
STATUS_INTERVAL=1
SSH_OPTIONS=(
  -n
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
  -o ControlMaster=auto
  -o ControlPersist=600
  -o "ControlPath=$CONTROL_PATH"
)

usage() {
  cat <<EOF
Review this rig's SVO2 recordings from the Ubuntu viewing workstation.

Browse remote recordings and select one (most likely field command):
  $ROOT/scripts/zed_replay_console.sh --jetson dusty@ubuntu.local

Skip the browser and immediately replay newest, or select the third-newest:
  $ROOT/scripts/zed_replay_console.sh --jetson dusty@ubuntu.local --latest
  $ROOT/scripts/zed_replay_console.sh --jetson dusty@ubuntu.local --list
  $ROOT/scripts/zed_replay_console.sh --jetson dusty@ubuntu.local --index 3

Select an exact Jetson-side path:
  $ROOT/scripts/zed_replay_console.sh --jetson dusty@ubuntu.local \
    --svo /home/dusty/Videos/ZED/RECORDING.svo2

Options:
  --jetson USER@HOST   Jetson SSH target (default: $JETSON)
  --remote-root PATH   Repository path on the Jetson (default: $REMOTE_ROOT)
  --view-profile NAME  ROS profile name or absolute Jetson path (default: field)
  --choose             Show the interactive remote dataset browser (default)
  --latest             Immediately replay the newest finalized recording
  --index N            Immediately replay the Nth-newest finalized recording
  --svo PATH           Replay an exact absolute path on the Jetson
  --loop               Loop at end of recording
  --rate RATE          Initial playback speed, 0.1-5.0 (default: $RATE)
  --no-rviz            Run controls without opening local RViz
  --list               List finalized recordings on the Jetson and exit
  --status             Report an existing replay and exit
  --stop               Stop an existing replay and exit
  --dry-run            Print resolved commands without SSH, ROS, or replay
  -h, --help           Show this help

Interactive keys:
  Space or p   Play/pause
  Left/Right  Step backward/forward one second and pause
  , and .     Step backward/forward one frame and pause
  j and l     Step backward/forward one second and pause
  J and L     Step backward/forward ten seconds and pause
  - and +     Decrease/increase playback speed (0.1x to 5x)
  0           Pause and return to frame zero
  o           Open the remote dataset browser and switch recordings
  i           Detailed replay status
  v           Reopen RViz and refresh the current frame
  h           Show keys
  q           Stop Jetson replay and close RViz

Ctrl+C, terminal closure, or Wi-Fi loss leaves replay running for reconnection.
Only q or --stop shuts down the named Jetson replay unit.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

key_help() {
  echo
  echo "Terminal focus required for replay keys."
  echo "  Space/p    play or pause"
  echo "  Left/Right or j/l    step -/+ 1 second (pauses)"
  echo "  ,/.        step -/+ 1 frame (pauses)"
  echo "  J/L        step -/+ 10 seconds (pauses)"
  echo "  -/+        slower/faster (0.1x to 5x)"
  echo "  o open dataset  0 restart  i status  v reopen RViz  h help  q safe quit"
}

shell_join() {
  local out="" word
  for word in "$@"; do
    printf -v word '%q' "$word"
    out+="${out:+ }$word"
  done
  printf '%s' "$out"
}

remote_shell() {
  local command
  command="$(shell_join "$@")"
  ssh "${SSH_OPTIONS[@]}" "$JETSON" "exec $command"
}

remote_session() {
  remote_shell "$REMOTE_ROOT/scripts/zed_replay_session.sh" "$@"
}

build_start_args() {
  start_args=(start --profile "$REMOTE_PROFILE" --rate "$RATE")
  if [[ "$SELECTION_MODE" == path ]]; then
    start_args+=(--svo "$SVO")
  else
    start_args+=(--index "$INDEX")
  fi
  if $LOOP; then start_args+=(--loop); fi
}

choose_recording() {
  local output status_output active_svo="" number modified bytes path choice stamp size marker
  local -a recording_paths=()
  if ! output="$(remote_session list --machine --limit 50 2>&1)"; then
    printf '%s\n' "$output" >&2
    echo "Could not load the remote SVO2 directory." >&2
    return 1
  fi
  status_output="$(remote_session status --machine 2>/dev/null || true)"
  active_svo="$(sed -n 's/^SVO=//p' <<<"$status_output" | head -n1)"

  echo
  echo "Remote SVO2 datasets on $JETSON (newest first)"
  printf '%-4s %-19s %10s  %s\n' "#" "Captured" "Size" "Dataset"
  while IFS=$'\t' read -r number modified bytes path; do
    [[ "$number" =~ ^[1-9][0-9]*$ && -n "$path" ]] || continue
    recording_paths[$number]="$path"
    stamp="$(date -d "@$modified" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$modified")"
    size="$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%sB' "$bytes")"
    marker=""
    [[ "$path" == "$active_svo" ]] && marker="  [ACTIVE]"
    printf '%-4s %-19s %10s  %s%s\n' "$number" "$stamp" "$size" \
      "$(basename -- "$path")" "$marker"
  done <<<"$output"
  ((${#recording_paths[@]} > 0)) || {
    echo "No finalized remote SVO2 datasets were returned." >&2
    return 1
  }

  while true; do
    printf 'Select dataset [1 newest, Enter=1, q=cancel]: '
    IFS= read -r choice
    choice="${choice:-1}"
    [[ "$choice" == q || "$choice" == Q ]] && return 1
    if [[ "$choice" =~ ^[1-9][0-9]*$ && -n "${recording_paths[$choice]:-}" ]]; then
      INDEX="$choice"
      SVO=""
      SELECTION_MODE=index
      echo "Selected #$choice: $(basename -- "${recording_paths[$choice]}")"
      return 0
    fi
    echo "Enter one of the listed dataset numbers, or q to cancel."
  done
}

close_ssh_master() {
  ssh "${SSH_OPTIONS[@]}" -O exit "$JETSON" >/dev/null 2>&1 || true
}

clear_footer() {
  if $FOOTER_DRAWN; then
    printf '\r\033[2K\033[1A\r\033[2K'
    FOOTER_DRAWN=false
  fi
}

fit_footer_line() {
  local text="$1" columns width
  columns="$(tput cols 2>/dev/null || printf '120')"
  [[ "$columns" =~ ^[0-9]+$ ]] || columns=120
  width=$((columns > 20 ? columns - 1 : 20))
  printf '%s' "${text:0:width}"
}

draw_footer() {
  local status controls
  clear_footer
  status="$(fit_footer_line "$STATUS_TEXT")"
  controls="$(fit_footer_line "$CONTROL_TEXT")"
  printf '\r\033[2K\033[%sm%s\033[0m\n\033[2K\033[2m%s\033[0m' \
    "$STATUS_STYLE" "$status" "$controls"
  FOOTER_DRAWN=true
}

enable_console_tty() {
  TTY_STATE="$(stty -g)" || die "Cannot read terminal state"
  stty -echo
}

restore_console_tty() {
  clear_footer
  if [[ -n "$TTY_STATE" ]]; then
    stty "$TTY_STATE" 2>/dev/null || true
    TTY_STATE=""
  fi
}

stop_rviz() {
  local deadline
  if [[ -n "$RVIZ_PID" ]] && kill -0 -- "-$RVIZ_PID" 2>/dev/null; then
    kill -INT -- "-$RVIZ_PID" 2>/dev/null || true
    deadline=$((SECONDS + 10))
    while kill -0 -- "-$RVIZ_PID" 2>/dev/null && ((SECONDS < deadline)); do sleep 1; done
    kill -TERM -- "-$RVIZ_PID" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$RVIZ_PID" 2>/dev/null || true
    wait "$RVIZ_PID" 2>/dev/null || true
  fi
  RVIZ_PID=""
  rm -f -- "$RVIZ_READY"
}

detached_exit() {
  trap - INT TERM EXIT
  restore_console_tty
  stop_rviz
  close_ssh_master
  echo
  echo "Replay controller closed; Jetson replay was left running."
  echo "Reconnect with the same command, or use --stop to shut it down."
  exit 130
}

local_cleanup() {
  restore_console_tty
  stop_rviz
  close_ssh_master
}

source_receiver_ros() {
  local setup="/opt/ros/$ROS_DISTRO/setup.bash"
  [[ -r "$setup" ]] || die "ROS 2 $ROS_DISTRO is missing; run $ROOT/scripts/install_ros2_remote.sh"
  set +u
  # shellcheck disable=SC1090
  source "$setup"
  set -u
  export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$DEFAULT_ROS_DOMAIN_ID}"
  export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-$DEFAULT_RMW_IMPLEMENTATION}"
  export CYCLONEDDS_URI="${CYCLONEDDS_URI:-file://$ROOT/config/ros2/cyclonedds.xml}"
}

receiver_gui_preflight() {
  local package
  source_receiver_ros
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || \
    die "No workstation display; run this from a terminal in the desktop session"
  for package in image_transport compressed_image_transport \
    compressed_depth_image_transport point_cloud_transport \
    draco_point_cloud_transport rviz2; do
    ros2 pkg prefix "$package" >/dev/null 2>&1 || \
      die "Missing receiver package $package; run: $ROOT/scripts/install_ros2_remote.sh"
  done
  command -v setsid >/dev/null || die "Missing setsid from util-linux"
}

wait_for_topics() {
  local elapsed=0 topics
  source_receiver_ros
  echo "Waiting for replay topics on ROS domain $ROS_DOMAIN_ID..."
  while ((elapsed < 35)); do
    topics="$(timeout 5s ros2 topic list --no-daemon 2>/dev/null || true)"
    if grep -Fxq /zed/zed_node/rgb/color/rect/image/compressed <<<"$topics" &&
       grep -Fxq /zed/zed_node/depth/depth_registered/compressedDepth <<<"$topics" &&
       grep -Fxq /zed/zed_node/point_cloud/cloud_registered <<<"$topics"; then
      echo "Replay RGB, depth, and point-cloud topics are visible."
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "Jetson replay is running, but the workstation cannot discover all ROS topics." >&2
  return 1
}

start_rviz() {
  local elapsed
  $NO_RVIZ && return 0
  if [[ -n "$RVIZ_PID" ]] && kill -0 "$RVIZ_PID" 2>/dev/null; then
    echo "RViz is already running (PID $RVIZ_PID)."
    return 0
  fi
  : >"$RVIZ_LOG"
  rm -f -- "$RVIZ_READY"
  ZED_RVIZ_READY_FILE="$RVIZ_READY" \
    setsid "$ROOT/scripts/start_ros2_rviz.sh" >"$RVIZ_LOG" 2>&1 &
  RVIZ_PID=$!
  echo "Opening RViz for SVO2 replay..."
  elapsed=0
  while ((elapsed < 50)); do
    if [[ -e "$RVIZ_READY" ]]; then
      echo "RViz opened (PID $RVIZ_PID). Log: $RVIZ_LOG"
      return 0
    fi
    if ! kill -0 "$RVIZ_PID" 2>/dev/null; then
      wait "$RVIZ_PID" 2>/dev/null || true
      RVIZ_PID=""
      echo "RViz or its local data bridge failed. Log: $RVIZ_LOG" >&2
      tail -n 80 "$RVIZ_LOG" >&2 || true
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "RViz startup timed out. Log: $RVIZ_LOG" >&2
  stop_rviz
  return 1
}

print_resolution() {
  local host="${JETSON##*@}" resolved network selection
  resolved="$(getent ahosts "$host" 2>/dev/null |
    awk '!seen[$1]++ {printf "%s%s", sep, $1; sep=","}' || true)"
  network="$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1 == "yes" {print $2; exit}' || true)"
  case "$SELECTION_MODE" in
    choose) selection="interactive remote dataset browser" ;;
    path) selection="$SVO" ;;
    *) selection="recording #$INDEX (newest=1)" ;;
  esac
  echo "Remote replay target"
  echo "  SSH:       $JETSON"
  echo "  Resolver:  ${resolved:-SSH will resolve the configured host/alias}"
  echo "  Network:   ${network:-not reported by NetworkManager}"
  echo "  Recording: $selection"
  echo "  Profile:   $REMOTE_PROFILE"
}

ssh_preflight() {
  local output remote_host remote_addresses
  if ! output="$(remote_shell hostname 2>&1)"; then
    printf '%s\n' "$output" >&2
    die "Cannot SSH noninteractively to $JETSON"
  fi
  remote_host="$(head -n1 <<<"$output")"
  remote_addresses="$(remote_shell hostname -I 2>/dev/null || true)"
  echo "SSH connected"
  echo "  Remote host: ${remote_host:-unknown}"
  echo "  Remote IPs:  ${remote_addresses:-not reported}"
  remote_shell test -r /usr/local/zed/settings/SN116863460.conf 2>/dev/null || \
    die "SSH target lacks the rig's virtual calibration"
  remote_shell test -x "$REMOTE_ROOT/scripts/zed_replay_session.sh" 2>/dev/null || \
    die "Jetson replay helper is missing or not executable under $REMOTE_ROOT"
  echo "  Jetson tool: $REMOTE_ROOT/scripts/zed_replay_session.sh"
}

format_time() {
  local seconds="$1"
  ((seconds >= 0)) || seconds=0
  printf '%02d:%02d:%02d' "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
}

machine_status() { remote_session status --machine; }

status_line() {
  local output state=UNKNOWN svo="" frame=0 total=0 fps=15 rate=1.0 loop=false loops=0
  local rviz=closed key value current_time total_time line
  if ! output="$(machine_status 2>&1)"; then
    STATUS_STYLE="1;33"
    STATUS_TEXT="? CONTROL DISCONNECTED - Jetson replay left unchanged"
    draw_footer
    return 1
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      STATE) state="$value" ;;
      SVO) svo="$value" ;;
      FRAME_ID) frame="$value" ;;
      TOTAL_FRAMES) total="$value" ;;
      FPS) fps="$value" ;;
      RATE) rate="$value" ;;
      LOOP) loop="$value" ;;
      LOOP_COUNT) loops="$value" ;;
    esac
  done <<<"$output"
  [[ "$frame" =~ ^[0-9]+$ ]] || frame=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  [[ "$fps" =~ ^[1-9][0-9]*$ ]] || fps=15
  CURRENT_FRAME="$frame"
  CURRENT_TOTAL="$total"
  CURRENT_FPS="$fps"
  [[ -n "$RVIZ_PID" ]] && kill -0 "$RVIZ_PID" 2>/dev/null && rviz=open
  current_time="$(format_time "$((frame / fps))")"
  total_time="$(format_time "$((total / fps))")"
  case "$state" in
    PLAYING) STATUS_STYLE="1;32"; line="▶ PLAY" ;;
    PAUSED) STATUS_STYLE="1;33"; line="Ⅱ PAUSED" ;;
    END) STATUS_STYLE="1;36"; line="■ END" ;;
    STOPPED) STATUS_STYLE="1;36"; line="■ STOPPED" ;;
    *) STATUS_STYLE="1;33"; line="? $state" ;;
  esac
  line+="  $current_time/$total_time  FRAME=$frame/$total  ${rate}x  LOOP=$loop:$loops  RVIZ=$rviz"
  [[ -n "$svo" ]] && line+="  $(basename -- "$svo")"
  STATUS_TEXT="$line"
  draw_footer
}

detailed_status() { remote_session status; }

open_dataset() {
  local had_tty=false
  [[ -n "$TTY_STATE" ]] && had_tty=true
  restore_console_tty
  if ! choose_recording; then
    echo "Dataset switch cancelled. Current replay was left unchanged."
    $had_tty && enable_console_tty
    return 0
  fi
  $had_tty && enable_console_tty
  build_start_args
  echo "Stopping the current replay before opening dataset #$INDEX..."
  if ! remote_session stop; then
    echo "Current replay did not stop; the selected dataset was not opened." >&2
    return 1
  fi
  if ! remote_session "${start_args[@]}"; then
    echo "Selected dataset did not start. Use o to choose another or q to exit." >&2
    return 1
  fi
  if ! $NO_RVIZ; then
    wait_for_topics || return 1
    start_rviz || return 1
    remote_session seek 0 >/dev/null
  fi
  echo "Dataset #$INDEX is ready, paused at frame zero."
}

safe_quit() {
  echo "Stopping headless Jetson replay and closing RViz..."
  if remote_session stop; then
    stop_rviz
    close_ssh_master
    restore_console_tty
    trap - INT TERM EXIT
    echo "Replay session closed cleanly."
    exit 0
  fi
  echo "Replay shutdown was not confirmed; state was preserved." >&2
}

while (($#)); do
  case "$1" in
    --jetson) JETSON="${2:-}"; shift ;;
    --remote-root) REMOTE_ROOT="${2:-}"; shift ;;
    --view-profile) VIEW_PROFILE="${2:-}"; shift ;;
    --choose) SELECTION_MODE=choose ;;
    --latest) SELECTION_MODE=index; INDEX=1 ;;
    --index) SELECTION_MODE=index; INDEX="${2:-}"; shift ;;
    --svo) SELECTION_MODE=path; SVO="${2:-}"; shift ;;
    --loop) LOOP=true ;;
    --rate) RATE="${2:-}"; shift ;;
    --no-rviz) NO_RVIZ=true ;;
    --list) ACTION=list ;;
    --status) ACTION=status ;;
    --stop) ACTION=stop ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$JETSON" =~ ^([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+$ && "$JETSON" != -* ]] || \
  die "Unsafe SSH target: $JETSON"
[[ "$REMOTE_ROOT" == /* && "$REMOTE_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
  die "Unsafe remote root: $REMOTE_ROOT"
[[ "$INDEX" =~ ^[1-9][0-9]*$ ]] || die "--index must be a positive integer"
if [[ -n "$SVO" ]]; then
  [[ "$SVO" == /* && "$SVO" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Unsafe Jetson SVO path: $SVO"
fi
if [[ "$VIEW_PROFILE" == /* ]]; then
  REMOTE_PROFILE="$VIEW_PROFILE"
elif [[ "$VIEW_PROFILE" =~ ^[A-Za-z0-9_-]+$ ]]; then
  REMOTE_PROFILE="$REMOTE_ROOT/config/ros2/${VIEW_PROFILE}.yaml"
else
  die "Profile must be a simple name or absolute path"
fi

print_resolution
build_start_args
if $DRY_RUN; then
  echo "Dry run; no SSH, ROS, RViz, or replay action was taken."
  echo "Remote start: $(shell_join "$REMOTE_ROOT/scripts/zed_replay_session.sh" "${start_args[@]}")"
  echo "Local viewer: $ROOT/scripts/start_ros2_rviz.sh"
  exit 0
fi

command -v ssh >/dev/null || die "ssh is not installed"
mkdir -p "$RUNTIME_BASE"
chmod 0700 "$RUNTIME_BASE"
ssh_preflight
case "$ACTION" in
  list) remote_session list; close_ssh_master; exit 0 ;;
  status) remote_session status; close_ssh_master; exit 0 ;;
  stop) remote_session stop; close_ssh_master; exit 0 ;;
esac

[[ -t 0 ]] || die "Interactive replay requires a terminal; use --list, --status, or --stop for automation"
if [[ "$SELECTION_MODE" == choose ]]; then
  choose_recording || {
    close_ssh_master
    echo "No dataset selected."
    exit 0
  }
  build_start_args
fi
$NO_RVIZ || receiver_gui_preflight
trap detached_exit INT TERM
trap local_cleanup EXIT

remote_session "${start_args[@]}"
if ! $NO_RVIZ; then
  wait_for_topics || die "ROS replay topic preflight failed"
  if ! start_rviz; then
    echo "RViz failed; Jetson replay was left paused for inspection." >&2
    die "RViz failed to remain open"
  fi
  # Status topics are volatile. Seeking the paused current frame after RViz
  # subscribes guarantees visible RGB/depth/cloud on the first screen.
  remote_session seek 0 >/dev/null
fi

echo
echo "REPLAY READY - paused at the first frame."
key_help
enable_console_tty
last_status="$(date +%s)"
status_line || true
while true; do
  now="$(date +%s)"
  if ((now - last_status >= STATUS_INTERVAL)); then
    status_line || true
    last_status="$now"
  fi
  key=""
  if IFS= read -rsn1 -t 1 key; then
    if [[ "$key" == $'\e' ]]; then
      sequence=""
      IFS= read -rsn2 -t 0.15 sequence || true
      case "$sequence" in
        '[D') key=j ;;
        '[C') key=l ;;
        '[A') key='+' ;;
        '[B') key='-' ;;
        *) key="" ;;
      esac
    fi
    clear_footer
    case "$key" in
      ' '|p|P) echo "Toggling play/pause..."; remote_session pause-toggle ;;
      ',') echo "Stepping back one frame..."; remote_session step -1 ;;
      '.') echo "Stepping forward one frame..."; remote_session step 1 ;;
      j) echo "Stepping back one second..."; remote_session step "-$CURRENT_FPS" ;;
      l) echo "Stepping forward one second..."; remote_session step "$CURRENT_FPS" ;;
      J) echo "Stepping back ten seconds..."; remote_session step "$((-10 * CURRENT_FPS))" ;;
      L) echo "Stepping forward ten seconds..."; remote_session step "$((10 * CURRENT_FPS))" ;;
      -|'_') echo "Reducing playback speed..."; remote_session speed down ;;
      +|'=') echo "Increasing playback speed..."; remote_session speed up ;;
      0) echo "Returning to the first frame..."; remote_session restart ;;
      o|O) open_dataset || true ;;
      i|I) detailed_status ;;
      v|V)
        if start_rviz; then remote_session seek "$CURRENT_FRAME" >/dev/null || true; fi
        ;;
      h|H|'?') key_help ;;
      q|Q) safe_quit ;;
    esac
    last_status="$(date +%s)"
    status_line || true
  fi
done
