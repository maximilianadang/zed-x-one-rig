#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RESTORE_FACTORY=false
INSTALL_DESKTOP=true

usage() {
  cat <<EOF
Install this exact ZED X One rig configuration.

Copy/paste normal installation:
  $ROOT/scripts/install.sh

Options:
  --restore-factory-calibrations  Also restore SN304467158/SN306605936 configs
  --no-desktop                    Do not install desktop launchers
  -h, --help                      Show this help

Existing calibration files are backed up. Camera services are not restarted.
EOF
}

while (($#)); do
  case "$1" in
    --restore-factory-calibrations) RESTORE_FACTORY=true ;;
    --no-desktop) INSTALL_DESKTOP=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

"$ROOT/scripts/build.sh"

SETTINGS="/usr/local/zed/settings"
STAMP="$(date +%Y%m%d_%H%M%S)"

install_calibration() {
  local source="$1"
  local target="$2"
  if [[ -e "$target" ]]; then
    echo "Backing up $target to ${target}.backup_${STAMP}"
    sudo cp -a "$target" "${target}.backup_${STAMP}"
  fi
  sudo install -m 0644 "$source" "$target"
}

install_calibration \
  "$ROOT/calibration/active/SN116863460.conf" \
  "$SETTINGS/SN116863460.conf"

if $RESTORE_FACTORY; then
  install_calibration \
    "$ROOT/calibration/factory/SN304467158.conf" \
    "$SETTINGS/SN304467158.conf"
  install_calibration \
    "$ROOT/calibration/factory/SN306605936.conf" \
    "$SETTINGS/SN306605936.conf"
fi

if $INSTALL_DESKTOP; then
  APP_DIR="$HOME/.local/share/applications"
  mkdir -p "$APP_DIR"
  for template in "$ROOT"/launchers/*.desktop.in; do
    target="$APP_DIR/$(basename "${template%.in}")"
    sed "s|@REPO_ROOT@|$ROOT|g" "$template" >"$target"
    chmod 0644 "$target"
  done
  update-desktop-database "$APP_DIR" 2>/dev/null || true
  echo "Installed desktop launchers in $APP_DIR"
fi

echo
echo "Installation complete. Services were not restarted."
echo "Verify with: $ROOT/scripts/verify_setup.sh"
