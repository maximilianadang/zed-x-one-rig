#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/ros2/versions.env"

WORKSPACE="${ZED_ROS_WORKSPACE:-$ZED_ROS_WORKSPACE_DEFAULT}"
CACHE_DIR="$ROOT/offline/ros2/jetson-$(dpkg --print-architecture)/debs"
OFFLINE_DIR=""
SKIP_BUILD=false
BUILD_ONLY=false

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
Install the pinned ROS 2 Humble/ZED wrapper stack on this exact Jetson.

Copy/paste online installation and retain downloaded packages for field use:
  $ROOT/scripts/install_ros2_jetson.sh

Copy/paste offline installation from an already populated package cache:
  $ROOT/scripts/install_ros2_jetson.sh \\
    --offline-dir $ROOT/offline/ros2/jetson-arm64/debs

Options:
  --workspace PATH    Build workspace (default: $WORKSPACE)
  --cache-dir PATH    Online apt package cache (default: $CACHE_DIR)
  --offline-dir PATH  Install only from cached .deb files; no network
  --build-only        Skip package installation and build the pinned wrapper
  --skip-build        Install packages but do not extract/build the wrapper
  -h, --help          Show this help

This script does not install or change JetPack, L4T, the ZED SDK, the GMSL
driver, calibration files, camera daemons, or boot services.
EOF
}

while (($#)); do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift ;;
    --cache-dir) CACHE_DIR="$2"; shift ;;
    --offline-dir) OFFLINE_DIR="$2"; shift ;;
    --build-only) BUILD_ONLY=true ;;
    --skip-build) SKIP_BUILD=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -m)" != aarch64 ]] || [[ "$(lsb_release -sc)" != jammy ]]; then
  echo "This installer is limited to the Ubuntu 22.04 AArch64 Jetson." >&2
  exit 1
fi

if [[ ! -r /usr/local/zed/zed-config-version.cmake ]] ||
   ! grep -q 'PACKAGE_VERSION "5.4.0"' /usr/local/zed/zed-config-version.cmake; then
  echo "ZED SDK 5.4.0 is required and was not detected." >&2
  exit 1
fi

bootstrap="$ROOT/vendor/ros2/ros2-apt-source_1.2.0.jammy_all.deb"
archive="$ROOT/vendor/ros2/zed-ros2-wrapper-v5.4.0.tar.gz"
printf '%s  %s\n' "$ROS_APT_SOURCE_SHA256" "$bootstrap" | sha256sum -c -
printf '%s  %s\n' "$ZED_ROS_WRAPPER_ARCHIVE_SHA256" "$archive" | sha256sum -c -

mapfile -t required_packages < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
  "$ROOT/config/ros2/jetson-packages.txt")
mapfile -t optional_packages < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
  "$ROOT/config/ros2/optional-packages.txt")

if $BUILD_ONLY; then
  echo "Skipping package installation; building from the installed ROS stack"
elif [[ -n "$OFFLINE_DIR" ]]; then
  shopt -s nullglob
  cached_packages=("$OFFLINE_DIR"/*.deb)
  shopt -u nullglob
  if ((${#cached_packages[@]} == 0)); then
    echo "No .deb files found in offline directory: $OFFLINE_DIR" >&2
    exit 1
  fi
  echo "Installing ROS packages from offline cache: $OFFLINE_DIR"
  "${sudo_cmd[@]}" apt-get install -y "${cached_packages[@]}"
else
  echo "Installing pinned ROS apt source $ROS_APT_SOURCE_VERSION"
  "${sudo_cmd[@]}" apt-get install -y "$bootstrap"
  "${sudo_cmd[@]}" apt-get update

  "${sudo_cmd[@]}" install -d -m 0755 "$CACHE_DIR" "$CACHE_DIR/partial"
  available_optional=()
  for package in "${optional_packages[@]}"; do
    if apt-cache show "$package" >/dev/null 2>&1; then
      available_optional+=("$package")
    else
      echo "Optional package unavailable and skipped: $package"
    fi
  done

  echo "Installing required ROS/build packages and retaining .deb files"
  "${sudo_cmd[@]}" apt-get -o "Dir::Cache::archives=$CACHE_DIR" \
    -o APT::Keep-Downloaded-Packages=true install -y \
    "${required_packages[@]}" "${available_optional[@]}"
fi

if $SKIP_BUILD; then
  echo "Package installation complete; wrapper build skipped."
  exit 0
fi

set +u
source "/opt/ros/$ROS_DISTRO/setup.bash"
set -u

if ! $BUILD_ONLY && [[ -z "$OFFLINE_DIR" ]]; then
  if [[ ! -r /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    "${sudo_cmd[@]}" rosdep init
  fi
  rosdep update --rosdistro "$ROS_DISTRO"
fi

source_dir="$WORKSPACE/src/zed-ros2-wrapper"
marker="$source_dir/.zed-rig-source"
if [[ -d "$source_dir" ]]; then
  if [[ ! -r "$marker" ]] || ! grep -qx "$ZED_ROS_WRAPPER_COMMIT" "$marker"; then
    echo "Refusing to overwrite an unrecognized wrapper source tree: $source_dir" >&2
    exit 1
  fi
else
  mkdir -p "$source_dir"
  tar -xzf "$archive" -C "$source_dir"
  printf '%s\n' "$ZED_ROS_WRAPPER_COMMIT" >"$marker"
fi

if [[ -r "$HOME/.ros/rosdep/sources.cache/index" ]]; then
  echo "Checking wrapper dependencies without making additional changes"
  rosdep check --from-paths "$source_dir" --ignore-src --rosdistro "$ROS_DISTRO"
else
  echo "WARN: rosdep cache unavailable offline; the pinned package manifest is authoritative"
fi

echo "Building pinned ZED ROS wrapper $ZED_ROS_WRAPPER_TAG"
cd "$WORKSPACE"
colcon build \
  --symlink-install \
  --parallel-workers 2 \
  --packages-skip zed_debug \
  --cmake-args -DCMAKE_BUILD_TYPE=Release

"$ROOT/scripts/install_desktop_launchers.sh"

echo
echo "ROS 2 Jetson installation complete."
echo "Workspace: $WORKSPACE"
echo "Verify:    $ROOT/scripts/verify_ros2_setup.sh"
echo "Launch:    $ROOT/scripts/start_ros2_virtual_stereo.sh"
