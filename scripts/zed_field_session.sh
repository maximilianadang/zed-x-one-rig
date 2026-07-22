#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/field_console.env"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

UNIT="${ZED_FIELD_UNIT_OVERRIDE:-$ZED_FIELD_UNIT}"
OUTPUT_DIR="${ZED_FIELD_OUTPUT_DIR_OVERRIDE:-$ZED_FIELD_OUTPUT_DIR}"
MIN_FREE_BYTES="${ZED_FIELD_MIN_FREE_BYTES_OVERRIDE:-$ZED_FIELD_MIN_FREE_BYTES}"
LOSSLESS_BYTES_PER_SEC="${ZED_FIELD_LOSSLESS_BYTES_PER_SEC_OVERRIDE:-$ZED_FIELD_LOSSLESS_BYTES_PER_SEC}"
START_TIMEOUT="${ZED_FIELD_START_TIMEOUT_OVERRIDE:-$ZED_FIELD_START_TIMEOUT}"
FINALIZE_TIMEOUT="${ZED_FIELD_FINALIZE_TIMEOUT_OVERRIDE:-$ZED_FIELD_FINALIZE_TIMEOUT}"
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE_DIR="$RUNTIME_BASE/zed-field-console"
COMMAND_LOCK="$STATE_DIR/command.lock"
START_SERVICE="/zed/zed_node/start_svo_rec"
START_SERVICE_TYPE="zed_msgs/srv/StartSvoRec"
STOP_SERVICE="/zed/zed_node/stop_svo_rec"
MACHINE=false
FAST=false

usage() {
  cat <<EOF
Manage the Jetson-side live/view/record session for the dual ZED X One rig.

Copy/paste commands on the Jetson:
  $ROOT/scripts/zed_field_session.sh start
  $ROOT/scripts/zed_field_session.sh status
  $ROOT/scripts/zed_field_session.sh record-start
  $ROOT/scripts/zed_field_session.sh record-stop
  $ROOT/scripts/zed_field_session.sh stop

Commands:
  start [--profile PATH]  Start or attach to the transient live ROS session
  status [--machine] [--fast]
                          Show unit, ROS, recording, file, and storage state
  record-start            Start the proven lossless SVO2 mode
  record-stop             Finalize, validate, and promote the current SVO2
  stop                    Finalize if needed, stop ROS, and verify camera release
  logs                    Show recent transient-unit logs
  -h, --help              Show this help

Environment overrides:
  ZED_FIELD_OUTPUT_DIR_OVERRIDE
  ZED_FIELD_MIN_FREE_BYTES_OVERRIDE
  ZED_FIELD_LOSSLESS_BYTES_PER_SEC_OVERRIDE
  ZED_FIELD_START_TIMEOUT_OVERRIDE
  ZED_FIELD_FINALIZE_TIMEOUT_OVERRIDE

H.264 and H.265 are intentionally unavailable: both rejected every frame in
bounded tests on this virtual stereo path. Recording is lossless HD1200/15 FPS.
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
  flock -w 15 9 || die "Another field-session command is still running"
}

unit_active() {
  systemctl --user is-active --quiet "$UNIT"
}

source_ros() {
  zed_ros_source_environment
}

reset_ros_cli_daemon() {
  # A ros2cli daemon keeps the DDS interface/address it had when it started.
  # After changing field networks it can therefore hide a healthy graph behind
  # stale discovery data. All controller probes below are direct, so no daemon
  # is needed for this session.
  timeout 5s ros2 daemon stop >/dev/null 2>&1 || true
}

show_recent_unit_logs() {
  local lines="${1:-200}"
  # User-unit output is stored in the system journal on this Jetson. The
  # --user/-u form reports no journal files here.
  journalctl "_SYSTEMD_USER_UNIT=$UNIT" -n "$lines" --no-pager
}

wait_for_recording_service() {
  local deadline=$((SECONDS + START_TIMEOUT)) node_info remaining probe_timeout
  while ((SECONDS < deadline)); do
    if ! unit_active; then
      echo "The transient live unit stopped before ROS became ready." >&2
      return 1
    fi
    remaining=$((deadline - SECONDS))
    probe_timeout=3
    ((remaining < probe_timeout)) && probe_timeout=$remaining
    node_info="$(timeout "${probe_timeout}s" ros2 node info --no-daemon \
      --spin-time 1 /zed/zed_node 2>/dev/null || true)"
    if grep -Fq "$START_SERVICE: $START_SERVICE_TYPE" <<<"$node_info"; then
      return 0
    fi
    ((SECONDS < deadline)) && sleep 1
  done
  echo "Timed out after ${START_TIMEOUT}s waiting for direct discovery of $START_SERVICE" >&2
  return 1
}

recording_diagnostic() {
  local output
  output="$(timeout 8s ros2 topic echo --once /diagnostics \
    diagnostic_msgs/msg/DiagnosticArray 2>/dev/null || true)"
  awk '
    /key: SVO Recording/ {found=1; next}
    found && /value:/ {
      sub(/^[[:space:]]*value:[[:space:]]*/, "")
      gsub(/\047/, "")
      print
      exit
    }
  ' <<<"$output"
}

free_bytes() {
  df -B1 --output=avail "$OUTPUT_DIR" | awk 'NR == 2 {gsub(/[[:space:]]/, ""); print}'
}

human_bytes() {
  numfmt --to=iec-i --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"
}

state_value() {
  local name="$1"
  [[ -r "$STATE_DIR/$name" ]] && head -n1 "$STATE_DIR/$name" || true
}

write_state() {
  local name="$1" value="$2" tmp
  tmp="$STATE_DIR/.${name}.tmp.$$"
  printf '%s\n' "$value" >"$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$STATE_DIR/$name"
}

clear_recording_state() {
  rm -f -- "$STATE_DIR/recording.path" "$STATE_DIR/recording.final" \
    "$STATE_DIR/recording.started" "$STATE_DIR/recording.preset"
}

camera_pair_available() {
  local explorer serial block
  explorer="$(ZED_Explorer --all 2>&1)" || return 1
  for serial in "$LEFT_SERIAL" "$RIGHT_SERIAL"; do
    block="$(grep -A4 "S/N :  $serial" <<<"$explorer" || true)"
    [[ -n "$block" ]] && grep -q 'State :  "AVAILABLE"' <<<"$block" || return 1
  done
}

print_status() {
  local unit_state node_state state path final started preset bytes free diag last failed profile usable minutes
  ensure_runtime
  if unit_active; then unit_state=active; else unit_state=inactive; fi

  path="$(state_value recording.path)"
  final="$(state_value recording.final)"
  started="$(state_value recording.started)"
  preset="$(state_value recording.preset)"
  last="$(state_value last.path)"
  failed="$(state_value last.failed_path)"
  profile="$(state_value session.profile)"
  free="$(free_bytes 2>/dev/null || printf '0')"
  usable=0
  minutes=0
  if [[ "$free" =~ ^[0-9]+$ && "$MIN_FREE_BYTES" =~ ^[0-9]+$ &&
        "$LOSSLESS_BYTES_PER_SEC" =~ ^[1-9][0-9]*$ && "$free" -gt "$MIN_FREE_BYTES" ]]; then
    usable=$((free - MIN_FREE_BYTES))
    minutes=$((usable / LOSSLESS_BYTES_PER_SEC / 60))
  fi
  bytes=0
  [[ -n "$path" && -f "$path" ]] && bytes="$(stat -c %s "$path")"

  node_state=absent
  diag="NOT ACTIVE"
  if [[ "$unit_state" == active ]]; then
    if $FAST; then
      # start_session writes the profile only after the ZED service is ready,
      # and stop_session removes it. This avoids blocking the interactive
      # controller on a fresh DDS discovery probe every five seconds.
      if [[ -n "$profile" ]]; then
        node_state=ready
      else
        node_state=starting
      fi
    else
      source_ros >/dev/null
      if timeout 5s ros2 node list --no-daemon 2>/dev/null | grep -Fxq /zed/zed_node; then
        node_state=ready
      else
        node_state=starting
      fi
    fi
  fi

  if [[ -n "$path" ]]; then
    state=RECORDING
    if [[ "$unit_state" == active && "$node_state" == ready ]]; then
      diag=ACTIVE
    else
      diag=UNKNOWN
    fi
  elif [[ "$unit_state" == active ]]; then
    state=VIEWING
  else
    state=STOPPED
  fi

  if $MACHINE; then
    printf 'STATE=%s\nUNIT=%s\nNODE=%s\nDIAGNOSTIC=%s\n' \
      "$state" "$unit_state" "$node_state" "$diag"
    printf 'RECORDING_PATH=%s\nFINAL_PATH=%s\nSTARTED_EPOCH=%s\nPRESET=%s\n' \
      "$path" "$final" "$started" "$preset"
    printf 'FILE_BYTES=%s\nFREE_BYTES=%s\nLAST_PATH=%s\nFAILED_PATH=%s\n' \
      "$bytes" "$free" "$last" "$failed"
    printf 'PROFILE=%s\nEST_LOSSLESS_MINUTES=%s\n' "$profile" "$minutes"
    return
  fi

  echo "ZED field session"
  echo "  State:       $state"
  echo "  Unit:        $unit_state"
  echo "  ROS node:    $node_state"
  echo "  Recording:   $diag"
  echo "  Free space:  $(human_bytes "$free")"
  echo "  Est. record: ${minutes} lossless minutes above reserve"
  [[ -n "$profile" ]] && echo "  Profile:     $profile"
  if [[ -n "$path" ]]; then
    echo "  Active file: $path"
    echo "  File size:   $(human_bytes "$bytes")"
    echo "  Started:     $started"
    echo "  Preset:      $preset"
  fi
  [[ -n "$last" ]] && echo "  Last saved:  $last"
  [[ -n "$failed" ]] && echo "  Needs check: $failed"
  return 0
}

start_session() {
  local profile="$ZED_ROS_PROFILE" active_profile
  while (($#)); do
    case "$1" in
      --profile) profile="${2:-}"; shift ;;
      --machine) MACHINE=true ;;
      *) die "Unknown start option: $1" ;;
    esac
    shift
  done

  lock_commands
  profile="$(realpath -e "$profile")" || die "Unreadable ROS profile: $profile"
  if unit_active; then
    active_profile="$(state_value session.profile)"
    if [[ -z "$active_profile" ]]; then
      die "The named unit is active but its profile state is missing; inspect: $0 logs"
    fi
    [[ "$active_profile" == "$profile" ]] ||
      die "Active profile is $active_profile, not requested $profile"
    echo "Transient live session is already active; attaching."
    print_status
    return
  fi
  if [[ -n "$(state_value recording.path)" ]]; then
    die "Stale recording state exists in $STATE_DIR; inspect it before starting"
  fi

  zed_ros_check_calibration
  if ! zed_ros_user_manager_persistent; then
    die "No persistent user manager: run once with a local password: sudo loginctl enable-linger $(id -un)"
  fi
  source_ros
  echo "Resetting ROS 2 CLI discovery for the current network..."
  reset_ros_cli_daemon
  zed_ros_require_no_owner
  mkdir -p "$OUTPUT_DIR"
  [[ -w "$OUTPUT_DIR" ]] || die "Output directory is not writable: $OUTPUT_DIR"

  echo "Starting transient Jetson live session: $UNIT"
  systemd-run --user --unit="$UNIT" --collect \
    --property=KillSignal=SIGINT \
    --property=TimeoutStopSec="${FINALIZE_TIMEOUT}s" \
    --property=SuccessExitStatus=SIGINT \
    --setenv="ZED_ROS_PROFILE=$profile" \
    --setenv="CYCLONEDDS_URI=file://$ROOT/config/ros2/cyclonedds-jetson.xml" \
    "$ROOT/scripts/start_ros2_virtual_stereo.sh" >/dev/null

  echo "Waiting up to ${START_TIMEOUT}s for direct ZED service discovery..."
  if ! wait_for_recording_service; then
    echo "Recent transient-unit log:" >&2
    show_recent_unit_logs 80 >&2 || true
    systemctl --user stop "$UNIT" 2>/dev/null || true
    return 1
  fi
  write_state session.profile "$profile"
  write_state session.started "$(date +%s)"
  echo "Live session is ready in view-only mode."
  print_status
}

call_stop_service() {
  timeout "${FINALIZE_TIMEOUT}s" ros2 service call "$STOP_SERVICE" \
    std_srvs/srv/Trigger '{}'
}

record_start() {
  local preset=lossless available stamp base temp final response size1 size2
  while (($#)); do
    case "$1" in
      --preset) preset="${2:-}"; shift ;;
      --machine) MACHINE=true ;;
      *) die "Unknown record-start option: $1" ;;
    esac
    shift
  done
  [[ "$preset" == lossless ]] || die "Only the proven 'lossless' preset is available"

  lock_commands
  unit_active || die "Live session is not active; run: $0 start"
  [[ -z "$(state_value recording.path)" ]] || die "A recording is already active"
  source_ros
  wait_for_recording_service

  mkdir -p "$OUTPUT_DIR"
  [[ -w "$OUTPUT_DIR" ]] || die "Output directory is not writable: $OUTPUT_DIR"
  available="$(free_bytes)"
  [[ "$available" =~ ^[0-9]+$ ]] || die "Could not read free space for $OUTPUT_DIR"
  ((available >= MIN_FREE_BYTES)) || die "Free space is below the $(human_bytes "$MIN_FREE_BYTES") reserve"

  stamp="$(date +%Y%m%d_%H%M%S)"
  base="$OUTPUT_DIR/virtual_stereo_${stamp}"
  final="${base}.svo2"
  temp="${base}.recording.svo2"
  if [[ -e "$final" || -e "$temp" ]]; then
    base="${base}_$$"
    final="${base}.svo2"
    temp="${base}.recording.svo2"
  fi

  echo "Requesting LOSSLESS recording from the ZED SDK..."
  response="$(timeout 20s ros2 service call "$START_SERVICE" \
    zed_msgs/srv/StartSvoRec \
    "{bitrate: 0, compression_mode: 5, target_framerate: 15, input_transcode: false, svo_filename: '$temp'}")"
  if ! grep -Fq 'success=True' <<<"$response"; then
    printf '%s\n' "$response" >&2
    die "The ZED wrapper refused to start recording"
  fi

  write_state recording.path "$temp"
  write_state recording.final "$final"
  write_state recording.started "$(date +%s)"
  write_state recording.preset lossless

  echo "SDK accepted recording; verifying file growth for about 5 seconds..."
  sleep 3
  size1=0
  [[ -f "$temp" ]] && size1="$(stat -c %s "$temp")"
  sleep 2
  size2=0
  [[ -f "$temp" ]] && size2="$(stat -c %s "$temp")"
  if [[ "$size1" -le 0 || "$size2" -le "$size1" ]]; then
    call_stop_service >/dev/null 2>&1 || true
    write_state last.failed_path "$temp"
    clear_recording_state
    echo "Recording health check failed; preserved unvalidated file: $temp" >&2
    echo "File sizes did not grow: $size1 -> $size2" >&2
    return 1
  fi

  if $MACHINE; then
    printf 'STATE=RECORDING\nPRESET=lossless\nRECORDING_PATH=%s\nFINAL_PATH=%s\nSTARTED_EPOCH=%s\n' \
      "$temp" "$final" "$(state_value recording.started)"
  else
    echo "RECORDING LOSSLESS"
    echo "  Temporary: $temp"
    echo "  Final:     $final"
    echo "  Size:      $(human_bytes "$size2") and growing"
    echo "  Stop/save: $0 record-stop"
  fi
}

record_stop() {
  local temp final response info frames bytes diag
  lock_commands
  temp="$(state_value recording.path)"
  final="$(state_value recording.final)"
  [[ -n "$temp" && -n "$final" ]] || die "No recording is active"
  unit_active || die "Recording state exists but the live unit is not active; preserving $temp"
  source_ros

  echo "Finalizing lossless SVO2..."
  if ! response="$(call_stop_service)" || ! grep -Fq 'success=True' <<<"$response"; then
    printf '%s\n' "$response" >&2
    # The client can time out after the server has already finalized. Continue
    # only when wrapper diagnostics independently prove recording is inactive.
    sleep 2
    diag="$(recording_diagnostic)"
    if [[ "$diag" != "NOT ACTIVE" ]]; then
      echo "Finalization was not confirmed; preserving active state and $temp" >&2
      return 1
    fi
    echo "Stop response was ambiguous, but diagnostics report NOT ACTIVE; validating the preserved file." >&2
  fi

  if [[ ! -r "$temp" ]]; then
    write_state last.failed_path "$temp"
    clear_recording_state
    echo "Finalized file is missing: $temp" >&2
    return 1
  fi
  if ! info="$(ZED_SVO_Editor -inf "$temp" 2>&1)"; then
    write_state last.failed_path "$temp"
    clear_recording_state
    printf '%s\n' "$info" >&2
    echo "SVO2 inspection failed; preserved unvalidated file: $temp" >&2
    return 1
  fi
  frames="$(sed -n 's/^Number of Frames :  //p' <<<"$info")"
  if ! grep -q 'SVO Infos : SVO v 2' <<<"$info" ||
     ! grep -q 'Image Size : \[ 1920  x  1200 \]' <<<"$info" ||
     ! grep -q 'Framerate :  15' <<<"$info" ||
     ! grep -q "ZED Serial Number :  $VIRTUAL_SERIAL" <<<"$info" ||
     ! grep -q 'Compression mode :  "Lossless compression (png)"' <<<"$info" ||
     [[ ! "$frames" =~ ^[1-9][0-9]*$ ]]; then
    write_state last.failed_path "$temp"
    clear_recording_state
    printf '%s\n' "$info" >&2
    echo "SVO2 validation failed; preserved unvalidated file: $temp" >&2
    return 1
  fi

  if [[ -e "$final" ]] || ! mv -- "$temp" "$final"; then
    write_state last.failed_path "$temp"
    clear_recording_state
    echo "Finalized SVO2 is valid but could not be promoted; preserved: $temp" >&2
    return 1
  fi
  bytes="$(stat -c %s "$final")"
  write_state last.path "$final"
  write_state last.frames "$frames"
  write_state last.bytes "$bytes"
  write_state last.saved "$(date +%s)"
  rm -f -- "$STATE_DIR/last.failed_path"
  clear_recording_state

  if $MACHINE; then
    printf 'STATE=VIEWING\nSAVED_PATH=%s\nFRAMES=%s\nFILE_BYTES=%s\n' \
      "$final" "$frames" "$bytes"
  else
    echo "SAVED AND VALIDATED"
    echo "  File:   $final"
    echo "  Frames: $frames"
    echo "  Size:   $(human_bytes "$bytes")"
  fi
}

stop_session() {
  local elapsed=0
  lock_commands
  if [[ -n "$(state_value recording.path)" ]]; then
    # The command lock is already held; call the finalization body by releasing
    # this descriptor so record_stop can take the same serialized lock.
    flock -u 9
    exec 9>&-
    record_stop
    lock_commands
  fi

  if unit_active; then
    echo "Stopping transient live session with SIGINT..."
    systemctl --user stop "$UNIT"
    while unit_active && ((elapsed < 30)); do
      sleep 1
      elapsed=$((elapsed + 1))
    done
    unit_active && die "Transient unit did not stop within 30 seconds"
  else
    echo "Transient live session is already stopped."
  fi

  elapsed=0
  while ! camera_pair_available && ((elapsed < 20)); do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  camera_pair_available || die "Camera pair did not return to AVAILABLE"
  rm -f -- "$STATE_DIR/session.profile" "$STATE_DIR/session.started"
  echo "Both physical cameras are AVAILABLE."
}

show_logs() {
  show_recent_unit_logs 200
}

command="${1:-}"
[[ -n "$command" ]] || { usage >&2; exit 2; }
shift || true

case "$command" in
  start) start_session "$@" ;;
  status)
    while (($#)); do
      case "$1" in
        --machine) MACHINE=true ;;
        --fast) FAST=true ;;
        *) die "Unknown status option: $1" ;;
      esac
      shift
    done
    print_status
    ;;
  record-start) record_start "$@" ;;
  record-stop)
    case "${1:-}" in
      --machine) MACHINE=true ;;
      "") ;;
      *) die "Unknown record-stop option: $1" ;;
    esac
    record_stop
    ;;
  stop) stop_session "$@" ;;
  logs) show_logs ;;
  -h|--help|help) usage ;;
  *) echo "Unknown command: $command" >&2; usage >&2; exit 2 ;;
esac
