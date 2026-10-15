#!/usr/bin/env bash

# Shared, source-only helpers for the rig's ROS 2 scripts.

ZED_RIG_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ZED_RIG_ROOT/config/rig.env"
# shellcheck disable=SC1091
source "$ZED_RIG_ROOT/config/ros2/versions.env"

ZED_ROS_WORKSPACE="${ZED_ROS_WORKSPACE:-$ZED_ROS_WORKSPACE_DEFAULT}"
ZED_ROS_PROFILE="${ZED_ROS_PROFILE:-$ZED_RIG_ROOT/config/ros2/field.yaml}"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-$DEFAULT_ROS_DOMAIN_ID}"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-$DEFAULT_RMW_IMPLEMENTATION}"
export CYCLONEDDS_URI="${CYCLONEDDS_URI:-file://$ZED_RIG_ROOT/config/ros2/cyclonedds.xml}"

zed_ros_source_environment() {
  local ros_setup="/opt/ros/$ROS_DISTRO/setup.bash"
  local workspace_setup="$ZED_ROS_WORKSPACE/install/local_setup.bash"

  if [[ ! -r "$ros_setup" ]]; then
    echo "ROS 2 $ROS_DISTRO is not installed: $ros_setup" >&2
    echo "Run: $ZED_RIG_ROOT/scripts/install_ros2_jetson.sh" >&2
    return 1
  fi
  if [[ ! -r "$workspace_setup" ]]; then
    echo "Pinned ZED ROS workspace is not built: $workspace_setup" >&2
    echo "Run: $ZED_RIG_ROOT/scripts/install_ros2_jetson.sh" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  set +u
  source "$ros_setup"
  # shellcheck disable=SC1090
  source "$workspace_setup"
  set -u
}

zed_ros_check_calibration() {
  local calibration="/usr/local/zed/settings/SN${VIRTUAL_SERIAL}.conf"
  local expected="02f32f76dfce5dd99410f8e30983a98037cd3fde53557f675ccec92d9d7d38fe"
  local actual

  if [[ ! -r "$calibration" ]]; then
    echo "Missing installed virtual calibration: $calibration" >&2
    return 1
  fi
  actual="$(sha256sum "$calibration" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Virtual calibration checksum mismatch: $calibration" >&2
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    return 1
  fi
}

zed_ros_check_hardware_identity() {
  local require_available="${1:-false}"
  local explorer role serial camera_id port i2c_path block
  explorer="$(ZED_Explorer --all 2>&1)" || {
    echo "Could not read the ZED hardware inventory." >&2
    printf '%s\n' "$explorer" >&2
    return 1
  }

  for role in left right; do
    if [[ "$role" == left ]]; then
      serial="$LEFT_SERIAL"
      camera_id="$LEFT_CAMERA_ID"
      port="$LEFT_PORT"
      i2c_path="$LEFT_I2C_PATH"
    else
      serial="$RIGHT_SERIAL"
      camera_id="$RIGHT_CAMERA_ID"
      port="$RIGHT_PORT"
      i2c_path="$RIGHT_I2C_PATH"
    fi

    block="$(grep -A6 "S/N :  $serial" <<<"$explorer" || true)"
    if [[ -z "$block" ]] ||
       ! grep -Fq "Path :  $i2c_path" <<<"$block" ||
       ! grep -Fq "ID :  $camera_id" <<<"$block" ||
       ! grep -Fq "Port :  $port" <<<"$block"; then
      echo "Physical $role camera identity mismatch." >&2
      echo "Expected: serial=$serial path=$i2c_path id=$camera_id port=$port" >&2
      printf '%s\n' "$explorer" >&2
      return 1
    fi
    if [[ "$require_available" == true ]] &&
       ! grep -Fq 'State :  "AVAILABLE"' <<<"$block"; then
      echo "Physical $role camera is not AVAILABLE:" >&2
      printf '%s\n' "$block" >&2
      return 1
    fi
  done
}

zed_ros_camera_owners() {
  ps -eo pid=,comm=,args= | awk -v self="$$" '
    $1 != self &&
    ($2 ~ /^(ZED_Media_Server|ZED_Depth_Viewer|ZED_Studio|zed_virtual_stereo_recorder|zed_stereo_calibration|zed_reprojection_viewer)$/ ||
     $0 ~ /[z]ed_wrapper.*zed_camera\.launch\.py/ ||
     $0 ~ /[z]ed_camera_component/) {print}
  '
}

zed_ros_require_no_owner() {
  local owners
  owners="$(zed_ros_camera_owners)"
  if [[ -n "$owners" ]]; then
    echo "A camera-owning ZED process is already running:" >&2
    printf '%s\n' "$owners" >&2
    echo "Close it normally, then retry. Nothing was terminated." >&2
    return 1
  fi
}

zed_ros_print_network_environment() {
  echo "ROS_DOMAIN_ID=$ROS_DOMAIN_ID"
  echo "RMW_IMPLEMENTATION=$RMW_IMPLEMENTATION"
  echo "CYCLONEDDS_URI=$CYCLONEDDS_URI"
}

zed_ros_user_manager_persistent() {
  local user sessions session remote active
  user="$(id -un)"
  if [[ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" == yes ]]; then
    return 0
  fi

  sessions="$(loginctl show-user "$user" -p Sessions --value 2>/dev/null || true)"
  for session in $sessions; do
    remote="$(loginctl show-session "$session" -p Remote --value 2>/dev/null || true)"
    active="$(loginctl show-session "$session" -p Active --value 2>/dev/null || true)"
    if [[ "$remote" == no && "$active" == yes ]]; then
      return 0
    fi
  done
  return 1
}
