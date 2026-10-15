#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_JETSON="dusty@ubuntu.local"
DEFAULT_REMOTE_ROOT="/home/dusty/workspace/terraforming_mars/zed-x-one-rig"

JETSON="$DEFAULT_JETSON"
REMOTE_ROOT="$DEFAULT_REMOTE_ROOT"
MODE=live
OUTDOOR=false
NO_OPEN=false
LOCAL=false
REMOTE_OPTIONS=false
LOCAL_PORT=""
REPLAY_INDEX=latest

usage() {
  cat <<EOF
Open the native browser field viewer locally or through an authenticated SSH tunnel.

On the Jetson desktop (no SSH):
  $ROOT/scripts/zed_web_console.sh --local

Replay locally:
  $ROOT/scripts/zed_web_console.sh --local --replay

Most likely live command:
  $ROOT/scripts/zed_web_console.sh --jetson dusty@ubuntu.local --remote-root $DEFAULT_REMOTE_ROOT

Sky-heavy outdoor command:
  $ROOT/scripts/zed_web_console.sh --jetson dusty@ubuntu.local --remote-root $DEFAULT_REMOTE_ROOT --outdoor

Replay the newest finalized SVO2:
  $ROOT/scripts/zed_web_console.sh --jetson dusty@ubuntu.local --remote-root $DEFAULT_REMOTE_ROOT --replay

Options:
  --local               Run directly on this Jetson; no SSH or tunnel
  --jetson USER@HOST    SSH target (default: $JETSON)
  --remote-root PATH    Repository path on Jetson (default: $REMOTE_ROOT)
  --outdoor             Use the exposure-only outdoor live profile
  --replay              Open replay mode instead of physical cameras
  --index N             Start replay dataset N, newest first
  --local-port PORT     Remote mode only: workstation tunnel port (default: first free 8765-8799)
  --no-open             Print the URL without opening a browser
  -h, --help            Show this help

Workstation requirements: macOS or Linux, OpenSSH, and a current Safari,
Chromium, Chrome, Firefox, or Edge browser. ROS, RViz, ZED SDK, CUDA, VNC,
Node, and internet access are not required.

Ctrl+C closes only the SSH tunnel; the independent Jetson session and any
active recording continue. Use the browser's safe stop control to stop them.
Local mode returns to the terminal after opening the browser. Closing the
browser does not stop a session or recording. Run as your normal user, not sudo.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --local) LOCAL=true ;;
    --jetson) JETSON="${2:-}"; REMOTE_OPTIONS=true; shift ;;
    --remote-root) REMOTE_ROOT="${2:-}"; REMOTE_OPTIONS=true; shift ;;
    --outdoor) OUTDOOR=true ;;
    --replay) MODE=replay ;;
    --index) REPLAY_INDEX="${2:-}"; MODE=replay; shift ;;
    --local-port) LOCAL_PORT="${2:-}"; shift ;;
    --no-open) NO_OPEN=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[[ "$REPLAY_INDEX" == latest || "$REPLAY_INDEX" =~ ^[1-9][0-9]*$ ]] ||
  die "Replay index must be a positive integer"
if $OUTDOOR && [[ "$MODE" != live ]]; then
  die "--outdoor is only valid for live viewing"
fi

if $LOCAL; then
  if $REMOTE_OPTIONS || [[ -n "$LOCAL_PORT" ]]; then
    die "--local cannot be combined with --jetson, --remote-root, or --local-port"
  fi
  SESSION_ROOT="$ROOT"
else
  SESSION_ROOT="$REMOTE_ROOT"
  [[ "$JETSON" =~ ^([A-Za-z0-9._-]+@)?[A-Za-z0-9._:-]+$ ]] ||
    die "Unsafe or invalid SSH target: $JETSON"
  [[ "$REMOTE_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "Unsafe or invalid remote root: $REMOTE_ROOT"
  command -v ssh >/dev/null || die "OpenSSH client is required"

  if [[ -z "$LOCAL_PORT" ]]; then
    for candidate in $(seq 8765 8799); do
      if command -v nc >/dev/null 2>&1; then
        if ! nc -z 127.0.0.1 "$candidate" >/dev/null 2>&1; then
          LOCAL_PORT="$candidate"
          break
        fi
      else
        LOCAL_PORT="$candidate"
        break
      fi
    done
  fi
  [[ "$LOCAL_PORT" =~ ^[1-9][0-9]{0,4}$ && "$LOCAL_PORT" -le 65535 ]] ||
    die "No valid local port is available"

  ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=3
  )
fi

session_command=("$SESSION_ROOT/scripts/zed_web_session.sh" start --mode "$MODE")
if $OUTDOOR; then
  session_command+=(--profile "$SESSION_ROOT/config/ros2/outdoor.yaml")
fi
if [[ "$MODE" == replay ]]; then
  session_command+=(--index "$REPLAY_INDEX")
fi

echo "Native browser field viewer"
if $LOCAL; then
  echo "  Connection:  local (no SSH)"
  echo "  Repository:  $ROOT"
else
  echo "  SSH:         $JETSON"
  echo "  Remote root: $REMOTE_ROOT"
fi
echo "  Mode:        $MODE"
echo "Starting or attaching to the Jetson session..."

if $LOCAL; then
  [[ -x "${session_command[0]}" ]] || die "Local Jetson session helper is not executable: ${session_command[0]}"
  remote_output="$("${session_command[@]}")" || die "Local Jetson browser session preflight failed"
else
  set +e
  remote_output="$(ssh "${ssh_options[@]}" "$JETSON" "${session_command[@]}" 2> >(tee /dev/stderr))"
  remote_status=$?
  set -e
  ((remote_status == 0)) || die "Jetson browser session preflight failed"
fi

remote_port="$(printf '%s\n' "$remote_output" | sed -n 's/^WEB_PORT=//p' | tail -n1)"
web_token="$(printf '%s\n' "$remote_output" | sed -n 's/^WEB_TOKEN=//p' | tail -n1)"
[[ "$remote_port" =~ ^[1-9][0-9]{0,4}$ && "$remote_port" -le 65535 ]] || die "Jetson did not return a gateway port"
[[ "$web_token" =~ ^[0-9a-fA-F]{48,128}$ ]] || die "Jetson did not return a gateway token"

if $LOCAL; then
  LOCAL_PORT="$remote_port"
else
  echo "Opening SSH loopback tunnel: 127.0.0.1:$LOCAL_PORT -> Jetson 127.0.0.1:$remote_port"
  ssh "${ssh_options[@]}" \
    -o ExitOnForwardFailure=yes \
    -N -L "127.0.0.1:$LOCAL_PORT:127.0.0.1:$remote_port" \
    "$JETSON" &
  tunnel_pid=$!

  cleanup() {
    trap - EXIT INT TERM
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
    echo
    echo "SSH tunnel closed. Jetson session and any recording were left unchanged."
  }
  trap cleanup EXIT INT TERM

  sleep 1
  kill -0 "$tunnel_pid" 2>/dev/null || die "SSH tunnel exited before becoming ready"
fi

url="http://127.0.0.1:$LOCAL_PORT/?mode=$MODE&token=$web_token"
echo
echo "Viewer ready:"
echo "  $url"
if ! $NO_OPEN; then
  if command -v open >/dev/null 2>&1; then
    open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 &
  else
    echo "No browser opener found; copy the URL above."
  fi
fi
echo
if $LOCAL; then
  echo "Browser controls are active. Local session continues independently."
  echo "Closing the browser does not stop recording; use Stop/Save and safe stop."
  exit 0
fi
echo "Browser controls are active. Ctrl+C closes only this tunnel."
wait "$tunnel_pid"
