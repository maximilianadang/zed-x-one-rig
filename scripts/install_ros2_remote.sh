#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/ros2/versions.env"

CACHE_DIR="$ROOT/offline/ros2/remote-$(dpkg --print-architecture)/debs"
OFFLINE_DIR=""

sudo_cmd=(sudo)
if [[ ! -t 0 ]]; then
  for askpass in /usr/libexec/seahorse/ssh-askpass /usr/libexec/gcr-ssh-askpass; do
    if [[ -x "$askpass" ]]; then
      export SUDO_ASKPASS="$askpass"
      sudo_cmd=(sudo -A)
      break
    fi
  done
fi

usage() {
  cat <<EOF
Install the lightweight ROS 2/RViz receiver on Ubuntu 22.04.

Copy/paste online installation and retain packages for field use:
  $ROOT/scripts/install_ros2_remote.sh

Copy/paste offline installation:
  $ROOT/scripts/install_ros2_remote.sh --offline-dir /path/to/debs

Options:
  --cache-dir PATH    Online apt package cache (default: $CACHE_DIR)
  --offline-dir PATH  Install only cached .deb files; no network
  -h, --help          Show this help

This receiver does not install the ZED SDK or CUDA.
EOF
}

while (($#)); do
  case "$1" in
    --cache-dir) CACHE_DIR="$2"; shift ;;
    --offline-dir) OFFLINE_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$(lsb_release -sc)" != jammy ]]; then
  echo "The reference receiver requires Ubuntu 22.04 Jammy." >&2
  exit 1
fi

bootstrap="$ROOT/vendor/ros2/ros2-apt-source_1.2.0.jammy_all.deb"
printf '%s  %s\n' "$ROS_APT_SOURCE_SHA256" "$bootstrap" | sha256sum -c -
mapfile -t packages < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
  "$ROOT/config/ros2/remote-packages.txt")

if [[ -n "$OFFLINE_DIR" ]]; then
  shopt -s nullglob
  cached_packages=("$OFFLINE_DIR"/*.deb)
  shopt -u nullglob
  if ((${#cached_packages[@]} == 0)); then
    echo "No .deb files found in offline directory: $OFFLINE_DIR" >&2
    exit 1
  fi
  "${sudo_cmd[@]}" apt-get install -y "${cached_packages[@]}"
else
  "${sudo_cmd[@]}" apt-get install -y "$bootstrap"
  "${sudo_cmd[@]}" apt-get update
  "${sudo_cmd[@]}" install -d -m 0755 "$CACHE_DIR" "$CACHE_DIR/partial"
  "${sudo_cmd[@]}" apt-get -o "Dir::Cache::archives=$CACHE_DIR" \
    -o APT::Keep-Downloaded-Packages=true install -y "${packages[@]}"
fi

echo
echo "Remote viewer installed. No ZED SDK or CUDA was installed."
echo "One-command field console:"
echo "  $ROOT/scripts/zed_field_console.sh --jetson dusty@ubuntu.local"
echo "Manual RViz-only fallback:"
echo "  $ROOT/scripts/start_ros2_rviz.sh"
