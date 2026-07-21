#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/ros2_common.sh"

failures=0
warnings=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

echo "ROS 2 preflight for the dual ZED X One rig"
echo "Repository: $ROOT"
echo

if [[ "$(uname -m)" == aarch64 ]]; then pass "architecture: aarch64"; else fail "Jetson installer requires aarch64"; fi
if [[ "$(lsb_release -sc 2>/dev/null)" == jammy ]]; then pass "Ubuntu codename: jammy"; else fail "ROS Humble target requires Ubuntu 22.04 Jammy"; fi
if grep -q 'R36.*REVISION: 5.0' /etc/nv_tegra_release 2>/dev/null; then pass "Jetson Linux 36.5.0"; else warn "host differs from the captured L4T 36.5.0 baseline"; fi

if [[ -r /usr/local/zed/zed-config-version.cmake ]] &&
   grep -q 'PACKAGE_VERSION "5.4.0"' /usr/local/zed/zed-config-version.cmake; then
  pass "ZED SDK 5.4.0"
else
  fail "ZED SDK 5.4.0 not detected"
fi

if dpkg-query -W -f='${Version}' stereolabs-zedlink-duo 2>/dev/null |
   grep -qx '1.4.2-LI-MAX96712-L4T36.5.0'; then
  pass "GMSL package: stereolabs-zedlink-duo 1.4.2 for L4T 36.5.0"
else
  fail "unexpected or missing stereolabs-zedlink-duo package"
fi

if zed_ros_check_calibration; then pass "virtual calibration checksum"; else failures=$((failures + 1)); fi

owners="$(zed_ros_camera_owners)"
if [[ -z "$owners" ]]; then
  pass "no known camera-owning process"
else
  warn "camera owner present; live ROS launch will refuse"
  printf '%s\n' "$owners"
fi

if [[ -r "/opt/ros/$ROS_DISTRO/setup.bash" ]]; then pass "ROS 2 $ROS_DISTRO installed"; else warn "ROS 2 $ROS_DISTRO not installed"; fi
if [[ -r "$ZED_ROS_WORKSPACE/install/local_setup.bash" ]]; then pass "ZED wrapper workspace built"; else warn "ZED wrapper workspace not built"; fi

archive="$ROOT/vendor/ros2/zed-ros2-wrapper-v5.4.0.tar.gz"
if [[ -r "$archive" ]] &&
   [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$ZED_ROS_WRAPPER_ARCHIVE_SHA256" ]]; then
  pass "pinned ZED wrapper archive: $ZED_ROS_WRAPPER_TAG"
else
  fail "missing or mismatched pinned ZED wrapper archive"
fi

bootstrap="$ROOT/vendor/ros2/ros2-apt-source_1.2.0.jammy_all.deb"
if [[ -r "$bootstrap" ]] &&
   [[ "$(sha256sum "$bootstrap" | awk '{print $1}')" == "$ROS_APT_SOURCE_SHA256" ]]; then
  pass "pinned ROS apt-source bootstrap"
else
  fail "missing or mismatched ROS apt-source bootstrap"
fi

echo
zed_ros_print_network_environment
echo
printf 'Result: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
((failures == 0))
