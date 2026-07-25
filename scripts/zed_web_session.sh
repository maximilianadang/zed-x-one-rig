#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/field_console.env"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

UNIT="${ZED_WEB_GATEWAY_UNIT:-zed-web-gateway.service}"
PORT="${ZED_WEB_GATEWAY_PORT:-8765}"
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE_DIR="$RUNTIME_BASE/zed-web-console"
TOKEN_FILE="$STATE_DIR/token"
BINARY="$ROOT/build/web_gateway/zed_web_gateway"
LOOPBACK_DDS="$ROOT/config/ros2/cyclonedds-loopback.xml"

usage() {
  cat <<EOF
Manage the Jetson side of the native browser field viewer.

Copy/paste live launch from a Mac or Linux workstation:
  $ROOT/scripts/zed_web_console.sh --jetson dusty@ubuntu.local --remote-root $ROOT

Jetson-side commands:
  $0 start --mode live
  $0 start --mode live --profile $ROOT/config/ros2/outdoor.yaml
  $0 start --mode replay
  $0 status
  $0 stop-gateway

The gateway is an on-demand transient user service bound to 127.0.0.1. Stopping
the gateway never stops an independent camera session or active recording.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

gateway_active() {
  systemctl --user is-active --quiet "$UNIT"
}

new_token() {
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

read_token() {
  [[ -r "$TOKEN_FILE" ]] || return 1
  head -n1 "$TOKEN_FILE"
}

write_token() {
  local token="$1" temporary="$STATE_DIR/.token.$$"
  printf '%s\n' "$token" >"$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$TOKEN_FILE"
}

gateway_responding() {
  local token="$1"
  timeout 3s curl -fsS \
    -H "X-ZED-Token: $token" \
    "http://127.0.0.1:$PORT/api/v1/status?mode=live" >/dev/null 2>&1
}

start_gateway() {
  local token elapsed=0
  [[ -x "$BINARY" ]] || die "Gateway is not built; run: $ROOT/scripts/build_web_gateway.sh"
  for asset in index.html app.js style.css protocol.js depth_worker.js draco_worker.js \
    vendor/three.module.min.js vendor/OrbitControls.js vendor/DRACOLoader.js \
    vendor/draco/draco_wasm_wrapper.js vendor/draco/draco_decoder.wasm; do
    [[ -r "$ROOT/web/$asset" ]] || die "Missing offline browser asset: $ROOT/web/$asset"
  done
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR"

  if gateway_active; then
    token="$(read_token || true)"
    if [[ -n "$token" ]] && gateway_responding "$token"; then
      printf '%s' "$token"
      return
    fi
    echo "Replacing an unhealthy browser gateway; camera/replay session is unchanged." >&2
    systemctl --user stop "$UNIT"
  fi

  token="$(new_token)"
  [[ "$token" =~ ^[0-9a-f]{64}$ ]] || die "Could not generate gateway token"
  write_token "$token"
  systemd-run --user --unit="$UNIT" --collect \
    --property=KillSignal=SIGINT \
    --property=TimeoutStopSec=10s \
    --property=SuccessExitStatus=SIGINT \
    "$ROOT/scripts/run_web_gateway.sh" "$TOKEN_FILE" "$PORT" >/dev/null

  while ((elapsed < 15)); do
    if gateway_responding "$token"; then
      printf '%s' "$token"
      return
    fi
    gateway_active || {
      journalctl "_SYSTEMD_USER_UNIT=$UNIT" -n 80 --no-pager >&2 || true
      die "Browser gateway exited during startup"
    }
    sleep 1
    elapsed=$((elapsed + 1))
  done
  die "Browser gateway did not answer on loopback port $PORT"
}

start_session() {
  local mode=live profile="$ZED_ROS_PROFILE" index=latest token replay_status active_dds active_profile
  while (($#)); do
    case "$1" in
      --mode) mode="${2:-}"; shift ;;
      --profile) profile="${2:-}"; shift ;;
      --index) index="${2:-}"; shift ;;
      *) die "Unknown start option: $1" ;;
    esac
    shift
  done
  [[ "$mode" == live || "$mode" == replay ]] || die "Mode must be live or replay"
  profile="$(realpath -e "$profile")" || die "Unreadable profile: $profile"
  [[ -r "$LOOPBACK_DDS" ]] || die "Missing browser loopback DDS profile: $LOOPBACK_DDS"

  if [[ "$mode" == live ]]; then
    "$ROOT/scripts/zed_field_session.sh" start \
      --profile "$profile" --dds-profile "$LOOPBACK_DDS" >&2
  else
    if systemctl --user is-active --quiet "$ZED_REPLAY_UNIT" &&
       [[ "$index" == latest ]]; then
      replay_status="$("$ROOT/scripts/zed_replay_session.sh" status --machine)"
      active_dds="$(sed -n 's/^DDS_PROFILE=//p' <<<"$replay_status")"
      active_profile="$(sed -n 's/^PROFILE=//p' <<<"$replay_status")"
      [[ "$active_dds" == "$LOOPBACK_DDS" ]] ||
        die "Active replay uses LAN DDS; stop it before opening the browser viewer"
      [[ "$active_profile" == "$profile" ]] ||
        die "Active replay uses a different camera profile; stop it before attaching"
      echo "Transient replay session is already active; attaching." >&2
      "$ROOT/scripts/zed_replay_session.sh" status >&2
    elif [[ "$index" == latest ]]; then
      "$ROOT/scripts/zed_replay_session.sh" start --latest \
        --profile "$profile" --dds-profile "$LOOPBACK_DDS" >&2
    else
      [[ "$index" =~ ^[1-9][0-9]*$ ]] || die "Replay index must be a positive integer"
      "$ROOT/scripts/zed_replay_session.sh" start --index "$index" \
        --profile "$profile" --dds-profile "$LOOPBACK_DDS" >&2
    fi
  fi

  token="$(start_gateway)"
  printf 'WEB_PORT=%s\nWEB_TOKEN=%s\nMODE=%s\nPROFILE=%s\n' \
    "$PORT" "$token" "$mode" "$profile"
}

status() {
  local token
  if gateway_active; then
    token="$(read_token || true)"
    echo "GATEWAY=active"
    echo "PORT=$PORT"
    if [[ -n "$token" ]] && gateway_responding "$token"; then
      echo "HEALTH=ready"
    else
      echo "HEALTH=unhealthy"
    fi
  else
    echo "GATEWAY=inactive"
    echo "PORT=$PORT"
    echo "HEALTH=stopped"
  fi
}

stop_gateway() {
  if gateway_active; then
    systemctl --user stop "$UNIT"
    echo "Browser gateway stopped. Camera/replay state was not changed."
  else
    echo "Browser gateway is already stopped."
  fi
  rm -f -- "$TOKEN_FILE"
}

command="${1:-}"
[[ -n "$command" ]] || { usage >&2; exit 2; }
shift || true
case "$command" in
  start) start_session "$@" ;;
  status) status ;;
  stop-gateway) stop_gateway ;;
  logs) journalctl "_SYSTEMD_USER_UNIT=$UNIT" -n 200 --no-pager ;;
  -h|--help|help) usage ;;
  *) echo "Unknown command: $command" >&2; usage >&2; exit 2 ;;
esac
