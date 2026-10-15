#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/rig.env"
failures=0
warnings=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

check_command() {
  if command -v "$1" >/dev/null 2>&1; then pass "command: $1"; else fail "missing command: $1"; fi
}

echo "Dual ZED X One rig verification"
echo "Repository: $ROOT"
echo

for command in ZED_Explorer ZED_Depth_Viewer ZED_SVO_Editor cmake g++ python3 gst-launch-1.0; do
  check_command "$command"
done

if [[ -r /etc/nv_tegra_release ]] && grep -q 'R36.*REVISION: 5.0' /etc/nv_tegra_release; then
  pass "Jetson Linux 36.5.0"
else
  warn "host does not report the captured Jetson Linux 36.5.0 baseline"
fi

if [[ -r /usr/local/zed/zed-config-version.cmake ]] &&
   grep -q 'PACKAGE_VERSION "5.4.0"' /usr/local/zed/zed-config-version.cmake; then
  pass "ZED SDK 5.4.0"
else
  fail "ZED SDK 5.4.0 not detected"
fi

for service in driver_zed_loader.service zed_x_daemon.service nvargus-daemon.service; do
  state="$(systemctl is-active "$service" 2>/dev/null || true)"
  if [[ "$state" == active ]]; then pass "service active: $service"; else warn "service $service is $state"; fi
done

check_hash() {
  local expected="$1"
  local path="$2"
  if [[ ! -r "$path" ]]; then fail "missing file: $path"; return; fi
  local actual
  actual="$(sha256sum "$path" | awk '{print $1}')"
  if [[ "$actual" == "$expected" ]]; then pass "checksum: $path"; else fail "checksum mismatch: $path"; fi
}

check_hash 02f32f76dfce5dd99410f8e30983a98037cd3fde53557f675ccec92d9d7d38fe \
  /usr/local/zed/settings/SN117941018.conf
check_hash 36e7f85dc121013f13baf377b6c84bf5f90be3d9af159af2392a4ac49434cb23 \
  /usr/local/zed/settings/SN304467158.conf
check_hash 65b210cf9c18a7720a9ba1ef6086bf23f13743bb54644bcf4733931f976b1931 \
  /usr/local/zed/settings/SN306605936.conf

echo
echo "Camera enumeration:"
explorer="$(ZED_Explorer --all 2>&1)"
printf '%s\n' "$explorer"
for serial in "$LEFT_SERIAL" "$RIGHT_SERIAL"; do
  if grep -A3 "S/N :  $serial" <<<"$explorer" | grep -q 'State :  "AVAILABLE"'; then
    pass "camera $serial available"
  elif grep -q "S/N :  $serial" <<<"$explorer"; then
    warn "camera $serial detected but currently held/unavailable"
  else
    fail "camera $serial not detected"
  fi
done
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
  if [[ -n "$block" ]] &&
     grep -Fq "Path :  $i2c_path" <<<"$block" &&
     grep -Fq "ID :  $camera_id" <<<"$block" &&
     grep -Fq "Port :  $port" <<<"$block"; then
    pass "physical $role identity: serial $serial, ID $camera_id, port $port, $i2c_path"
  else
    fail "physical $role identity differs from config/rig.env"
  fi
done

echo
printf 'Result: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
((failures == 0))
