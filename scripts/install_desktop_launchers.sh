#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/.local/share/applications"

usage() {
  cat <<EOF
Install this repository's desktop application launchers without rebuilding,
changing calibration, or restarting services.

Copy/paste command:
  $ROOT/scripts/install_desktop_launchers.sh
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

mkdir -p "$APP_DIR"
for template in "$ROOT"/launchers/*.desktop.in; do
  target="$APP_DIR/$(basename "${template%.in}")"
  sed "s|@REPO_ROOT@|$ROOT|g" "$template" >"$target"
  chmod 0644 "$target"
done
update-desktop-database "$APP_DIR" 2>/dev/null || true
echo "Installed desktop launchers in $APP_DIR"
