#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/field_console.env"
# shellcheck disable=SC1091
source "$ROOT/config/ros2/versions.env"

JETSON="${ZED_FIELD_JETSON:-$ZED_FIELD_DEFAULT_JETSON}"
REMOTE_ROOT="${ZED_FIELD_REMOTE_ROOT_OVERRIDE:-$ZED_FIELD_REMOTE_ROOT}"
VIEW_PROFILE="field"
NO_RVIZ=false
DRY_RUN=false
ACTION=console
RVIZ_PID=""
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/tmp/zed-field-console-$(id -u)}"
CONTROL_PATH="$RUNTIME_BASE/zed-field-ssh-%C"
RVIZ_LOG="$RUNTIME_BASE/zed-field-rviz-$(id -u).log"
RVIZ_READY="$RUNTIME_BASE/zed-field-rviz-$(id -u).ready"
SSH_OPTIONS=(
  -n
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
  -o ControlMaster=auto
  -o ControlPersist=60
  -o "ControlPath=$CONTROL_PATH"
)

usage() {
  cat <<EOF
Open and control this calibrated ZED rig from the Ubuntu viewing workstation.

Most likely field command (from this repository on the viewing computer):
  $ROOT/scripts/zed_field_console.sh --jetson dusty@ubuntu.local

Using a stable SSH alias configured as zed-jetson:
  $ROOT/scripts/zed_field_console.sh --jetson zed-jetson

Useful noninteractive commands:
  $ROOT/scripts/zed_field_console.sh --jetson dusty@ubuntu.local --status
  $ROOT/scripts/zed_field_console.sh --jetson dusty@ubuntu.local --stop

Options:
  --jetson USER@HOST   Jetson SSH target (default: $JETSON)
  --remote-root PATH   Repository path on Jetson (default: $REMOTE_ROOT)
  --view-profile NAME  Jetson ROS profile name or absolute path (default: field)
  --no-rviz            Run the controller without opening a local RViz window
  --status             Report the existing Jetson session and exit
  --stop               Safely finalize/stop the existing Jetson session and exit
  --dry-run            Print resolved commands without SSH, ROS, or camera access
  -h, --help           Show this help

Interactive keys:
  r  Start a new LOSSLESS recording on the Jetson
  s  Stop, finalize, validate, and save the active recording
  i  Print detailed session, file, and storage status
  v  Reopen local RViz without touching the Jetson session
  h  Print key help
  q  Finalize if needed, stop the Jetson session, and close RViz

Safety behavior:
  Recording is OFF at startup. A network loss, terminal Ctrl+C, or RViz close
  leaves the Jetson session and any active recording running for reconnection.
  Only q requests complete remote shutdown. SVO2 files remain on the Jetson in
  $ZED_FIELD_OUTPUT_DIR. H.264/H.265 are unavailable because they rejected every
  frame in bounded tests on this exact virtual-stereo rig.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

key_help() {
  echo
  echo "Terminal focus required for keys."
  echo "Keys: [r] record lossless  [s] stop/save  [i] status  [v] reopen RViz  [h] help  [q] safe quit"
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
  remote_shell "$REMOTE_ROOT/scripts/zed_field_session.sh" "$@"
}

close_ssh_master() {
  ssh "${SSH_OPTIONS[@]}" -O exit "$JETSON" >/dev/null 2>&1 || true
}

stop_rviz() {
  local deadline
  if [[ -n "$RVIZ_PID" ]] && kill -0 -- "-$RVIZ_PID" 2>/dev/null; then
    kill -INT -- "-$RVIZ_PID" 2>/dev/null || true
    deadline=$((SECONDS + 10))
    while kill -0 -- "-$RVIZ_PID" 2>/dev/null && ((SECONDS < deadline)); do
      sleep 1
    done
    if kill -0 -- "-$RVIZ_PID" 2>/dev/null; then
      kill -TERM -- "-$RVIZ_PID" 2>/dev/null || true
      sleep 2
    fi
    kill -KILL -- "-$RVIZ_PID" 2>/dev/null || true
    wait "$RVIZ_PID" 2>/dev/null || true
  fi
  RVIZ_PID=""
  rm -f -- "$RVIZ_READY"
}

detached_exit() {
  trap - INT TERM EXIT
  stop_rviz
  close_ssh_master
  echo
  echo "Controller closed; the Jetson session and any recording were left unchanged."
  echo "Reconnect with the same command and press i for status."
  exit 130
}

local_cleanup() {
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
  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    die "No workstation graphical display; run the console from a terminal in its desktop session"
  fi
  for package in image_transport compressed_image_transport \
    compressed_depth_image_transport point_cloud_transport \
    draco_point_cloud_transport rviz2; do
    ros2 pkg prefix "$package" >/dev/null 2>&1 ||
      die "Missing receiver package $package; run: $ROOT/scripts/install_ros2_remote.sh"
  done
  command -v setsid >/dev/null 2>&1 ||
    die "Missing setsid from util-linux; it is required for bounded RViz cleanup"
}

wait_for_topics() {
  local elapsed=0 topics
  source_receiver_ros
  echo "Waiting for ROS 2 field topics on domain $ROS_DOMAIN_ID..."
  while ((elapsed < 35)); do
    topics="$(timeout 5s ros2 topic list --no-daemon 2>/dev/null || true)"
    if grep -Fxq /zed/zed_node/rgb/color/rect/image/compressed <<<"$topics" &&
       grep -Fxq /zed/zed_node/depth/depth_registered/compressedDepth <<<"$topics" &&
       grep -Fxq /zed/zed_node/point_cloud/cloud_registered <<<"$topics"; then
      echo "ROS 2 RGB, depth, and point-cloud topics are visible."
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "Jetson control works, but the viewing computer cannot discover all ROS topics." >&2
  echo "The Jetson session was left running. Check domain 42, firewall, and LAN multicast." >&2
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
  echo "Opening RViz; keyboard controls activate when its window is stable..."
  elapsed=0
  while ((elapsed < 50)); do
    if [[ -e "$RVIZ_READY" ]]; then
      echo "RViz opened (PID $RVIZ_PID). Keyboard controls are active."
      echo "  No duplicate image/depth health streams were opened."
      echo "  Log: $RVIZ_LOG"
      return 0
    fi
    if ! kill -0 "$RVIZ_PID" 2>/dev/null; then
      wait "$RVIZ_PID" 2>/dev/null || true
      RVIZ_PID=""
      echo "RViz or a local data bridge failed during startup. Log: $RVIZ_LOG" >&2
      tail -n 80 "$RVIZ_LOG" >&2 || true
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "RViz window startup timed out. Log: $RVIZ_LOG" >&2
  tail -n 80 "$RVIZ_LOG" >&2 || true
  stop_rviz
  return 1
}

print_resolution() {
  local host="${JETSON##*@}" resolved network
  resolved="$(getent ahosts "$host" 2>/dev/null |
    awk '!seen[$1]++ {printf "%s%s", sep, $1; sep=","}' || true)"
  network="$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1 == "yes" {print $2; exit}' || true)"
  echo "Field console target"
  echo "  SSH:      $JETSON"
  echo "  Resolver: ${resolved:-SSH will resolve the configured host/alias}"
  echo "  Network:  ${network:-not reported by NetworkManager}"
  echo "  Profile:  $REMOTE_PROFILE"
}

ssh_preflight() {
  local output remote_host remote_addresses
  if ! output="$(remote_shell hostname 2>&1)"; then
    printf '%s\n' "$output" >&2
    die "Cannot SSH noninteractively to $JETSON; verify its address, host key, and SSH key"
  fi
  remote_host="$(head -n1 <<<"$output")"
  remote_addresses="$(remote_shell hostname -I 2>/dev/null || true)"
  echo "SSH connected"
  echo "  Remote host: ${remote_host:-unknown}"
  echo "  Remote IPs:  ${remote_addresses:-not reported}"

  if ! output="$(remote_shell test -r /usr/local/zed/settings/SN116863460.conf 2>&1)"; then
    printf '%s\n' "$output" >&2
    die "SSH reached $remote_host, but it is not the configured ZED rig Jetson (SN116863460 calibration is absent)"
  fi

  if ! output="$(remote_shell test -x "$REMOTE_ROOT/scripts/zed_field_session.sh" 2>&1)"; then
    printf '%s\n' "$output" >&2
    echo "SSH is working and reached $remote_host." >&2
    echo "The missing path is on that remote host, not on this viewing computer:" >&2
    echo "  $REMOTE_ROOT/scripts/zed_field_session.sh" >&2
    die "Jetson repository path is wrong, stale, or not executable; pass --remote-root with the Jetson's repository path"
  fi
  echo "  Jetson tool: $REMOTE_ROOT/scripts/zed_field_session.sh"
}

machine_status() {
  remote_session status --machine
}

status_line() {
  local output state="UNKNOWN" diagnostic="UNKNOWN" free=0 minutes=0 path="" rviz=closed line key value
  if ! output="$(machine_status 2>&1)"; then
    printf '\r\033[KCONTROL DISCONNECTED - Jetson session left unchanged'
    return 1
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      STATE) state="$value" ;;
      DIAGNOSTIC) diagnostic="$value" ;;
      FREE_BYTES) free="$value" ;;
      EST_LOSSLESS_MINUTES) minutes="$value" ;;
      RECORDING_PATH) path="$value" ;;
    esac
  done <<<"$output"
  if [[ -n "$RVIZ_PID" ]] && kill -0 "$RVIZ_PID" 2>/dev/null; then rviz=open; fi
  line="STATE=$state  RECORDING=$diagnostic  RVIZ=$rviz  LOSSLESS≈${minutes}min"
  [[ -n "$path" ]] && line+="  FILE=$(basename -- "$path")"
  printf '\r\033[K%s' "$line"
}

detailed_status() {
  echo
  remote_session status
}

safe_quit() {
  echo
  echo "Requesting safe Jetson shutdown (active recording will finalize first)..."
  if remote_session stop; then
    stop_rviz
    close_ssh_master
    trap - INT TERM EXIT
    echo "Field session closed cleanly."
    exit 0
  fi
  echo "Safe shutdown was not confirmed. Jetson state was preserved; press i to inspect." >&2
}

while (($#)); do
  case "$1" in
    --jetson) JETSON="${2:-}"; shift ;;
    --remote-root) REMOTE_ROOT="${2:-}"; shift ;;
    --view-profile) VIEW_PROFILE="${2:-}"; shift ;;
    --no-rviz) NO_RVIZ=true ;;
    --status) ACTION=status ;;
    --stop) ACTION=stop ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$JETSON" =~ ^([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+$ && "$JETSON" != -* ]] ||
  die "Unsafe SSH target: $JETSON"
[[ "$REMOTE_ROOT" == /* && "$REMOTE_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Unsafe remote root: $REMOTE_ROOT"
if [[ "$VIEW_PROFILE" == /* ]]; then
  REMOTE_PROFILE="$VIEW_PROFILE"
elif [[ "$VIEW_PROFILE" =~ ^[A-Za-z0-9_-]+$ ]]; then
  REMOTE_PROFILE="$REMOTE_ROOT/config/ros2/${VIEW_PROFILE}.yaml"
else
  die "Profile must be a simple name or absolute path: $VIEW_PROFILE"
fi

print_resolution
if $DRY_RUN; then
  echo "Dry run; no SSH, ROS, RViz, or camera action was taken."
  echo "Remote start: $(shell_join "$REMOTE_ROOT/scripts/zed_field_session.sh" start --profile "$REMOTE_PROFILE")"
  echo "Local viewer: $ROOT/scripts/start_ros2_rviz.sh"
  exit 0
fi

command -v ssh >/dev/null || die "ssh is not installed on this viewing computer"
mkdir -p "$RUNTIME_BASE"
chmod 0700 "$RUNTIME_BASE"
ssh_preflight

case "$ACTION" in
  status) remote_session status; close_ssh_master; exit 0 ;;
  stop) remote_session stop; close_ssh_master; exit 0 ;;
esac

[[ -t 0 ]] || die "Interactive console requires a terminal; use --status or --stop for automation"
if ! $NO_RVIZ; then
  receiver_gui_preflight
fi
trap detached_exit INT TERM
trap local_cleanup EXIT

remote_session start --profile "$REMOTE_PROFILE"
if ! $NO_RVIZ; then
  wait_for_topics || die "ROS topic preflight failed"
  if ! start_rviz; then
    echo "Initial RViz acceptance failed; stopping the Jetson session to avoid an orphan." >&2
    remote_session stop ||
      echo "Automatic Jetson stop was not confirmed; run this console with --stop." >&2
    die "RViz failed to keep its window open during startup"
  fi
fi

echo
echo "VIEW ONLY - recording is OFF until you press r."
key_help
last_status=0
while true; do
  now="$(date +%s)"
  if ((now - last_status >= 5)); then
    status_line || true
    last_status="$now"
  fi
  key=""
  if IFS= read -rsn1 -t 1 key; then
    case "$key" in
      r|R)
        echo
        if remote_session record-start --preset lossless; then
          echo "Recording is active and file growth was verified."
        else
          echo "Recording did not pass its startup health check; press i for status." >&2
        fi
        ;;
      s|S)
        echo
        if remote_session record-stop; then
          echo "Recording was finalized, validated, and saved."
        else
          echo "Save/finalization was not confirmed; state and temporary file were preserved." >&2
        fi
        ;;
      i|I) detailed_status ;;
      v|V) echo; start_rviz || true ;;
      h|H|'?') key_help ;;
      q|Q) safe_quit ;;
    esac
    last_status=0
  fi
done
