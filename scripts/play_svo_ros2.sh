#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

PROFILE="$ZED_ROS_PROFILE"
LOOP=false
CONTROLLED=false
RATE="1.0"
DRY_RUN=false
SVO=""

usage() {
  cat <<EOF
Replay a virtual-stereo SVO2 through the same ROS 2 topics as live viewing.

Copy/paste latest known-good rig recording:
  $ROOT/scripts/play_svo_ros2.sh \\
    /home/dusty/Videos/ZED/virtual_stereo_20260717_162826.svo2

Options:
  --profile PATH  ROS parameter override (default: $PROFILE)
  --loop          Loop playback
  --controlled    Enable pause, seek, step, and dynamic replay-rate controls
  --rate RATE     Controlled playback speed, 0.1-5.0 (default: $RATE)
  --dry-run       Validate and print the command without opening the SVO2
  -h, --help      Show this help

On the remote workstation, run:
  $ROOT/scripts/start_ros2_rviz.sh
EOF
}

while (($#)); do
  case "$1" in
    --profile) PROFILE="$2"; shift ;;
    --loop) LOOP=true ;;
    --controlled) CONTROLLED=true ;;
    --rate) RATE="${2:-}"; shift ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$SVO" ]]; then echo "Only one SVO2 path is accepted." >&2; exit 2; fi
      SVO="$1"
      ;;
  esac
  shift
done

[[ -n "$SVO" ]] || { echo "An SVO2 path is required." >&2; usage >&2; exit 2; }
SVO="$(realpath "$SVO")"
[[ -r "$SVO" ]] || { echo "Unreadable SVO2: $SVO" >&2; exit 1; }
[[ "$SVO" == *.svo || "$SVO" == *.svo2 ]] || { echo "Expected a .svo or .svo2 file." >&2; exit 1; }
[[ -r "$PROFILE" ]] || { echo "Missing ROS profile: $PROFILE" >&2; exit 1; }
[[ "$RATE" =~ ^([0-4]([.][0-9]+)?|5([.]0+)?|[.]([0-9]+))$ ]] || {
  echo "Replay rate must be numeric and between 0.1 and 5.0: $RATE" >&2
  exit 1
}
awk -v rate="$RATE" 'BEGIN {exit !(rate >= 0.1 && rate <= 5.0)}' || {
  echo "Replay rate must be between 0.1 and 5.0: $RATE" >&2
  exit 1
}

zed_ros_check_calibration
zed_ros_source_environment
zed_ros_require_no_owner

info="$(ZED_SVO_Editor -inf "$SVO" 2>&1)"
if ! grep -q 'SVO Infos : SVO v 2' <<<"$info" ||
   ! grep -q "ZED Serial Number :  $VIRTUAL_SERIAL" <<<"$info" ||
   ! grep -q 'Number of Frames :  [1-9]' <<<"$info"; then
  echo "SVO2 is invalid or is not from virtual serial $VIRTUAL_SERIAL:" >&2
  printf '%s\n' "$info" >&2
  exit 1
fi

if $CONTROLLED; then
  # Non-real-time mode exposes pause and frame-seek services. Wall-clock
  # timestamps allow seeking, looping, and dynamic replay-rate changes.
  overrides="svo.svo_loop:=$LOOP;svo.svo_realtime:=false;svo.use_svo_timestamps:=false;svo.replay_rate:=$RATE"
elif $LOOP; then
  # The wrapper deliberately ignores svo_loop while original SVO timestamps
  # are enabled. Looping therefore needs wall-clock timestamps.
  overrides="svo.svo_loop:=true;svo.svo_realtime:=true;svo.use_svo_timestamps:=false"
else
  overrides="svo.svo_loop:=false;svo.svo_realtime:=true;svo.use_svo_timestamps:=true"
fi
command=(
  ros2 launch zed_wrapper zed_camera.launch.py
  camera_model:=virtual
  camera_name:=zed
  "svo_path:=$SVO"
  "ros_params_override_path:=$PROFILE"
  "param_overrides:=$overrides"
  publish_urdf:=true
  publish_tf:=false
  publish_map_tf:=false
  publish_imu_tf:=false
  enable_ipc:=true
  node_log_type:=both
)

if $DRY_RUN; then
  echo "Validated ROS 2 replay command:"
  printf ' %q' "${command[@]}"
  echo
  zed_ros_print_network_environment
  exit 0
fi

frames="$(sed -n 's/^Number of Frames :  //p' <<<"$info")"
echo "Starting ROS 2 SVO2 replay"
echo "  Input:       $SVO"
echo "  Frames:      $frames"
echo "  Virtual:     $VIRTUAL_SERIAL"
echo "  Depth:       NEURAL"
echo "  Loop:        $LOOP"
echo "  Controlled:  $CONTROLLED"
echo "  Rate:        ${RATE}x"
echo "  ROS domain:  $ROS_DOMAIN_ID"
echo
echo "Press Ctrl+C to stop playback."

exec "${command[@]}"
