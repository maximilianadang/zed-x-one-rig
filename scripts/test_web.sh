#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${NODE:-node}"
TEMPORARY=""

cleanup() {
  [[ -z "$TEMPORARY" ]] || rm -rf -- "$TEMPORARY"
}
trap cleanup EXIT

command -v "$NODE" >/dev/null 2>&1 || {
  echo "Node.js is needed only for development tests; it is not a field dependency." >&2
  echo "Set NODE=/path/to/node and retry." >&2
  exit 1
}

"$NODE" --check "$ROOT/web/bootstrap.js"
"$NODE" --check "$ROOT/web/app.js"
"$NODE" --check "$ROOT/web/depth_worker.js"
"$NODE" --check "$ROOT/web/protocol.js"
"$NODE" --check "$ROOT/web/draco_worker.js"
"$NODE" "$ROOT/tests/web/test_protocol.mjs"
"$NODE" "$ROOT/tests/web/test_depth_worker.mjs"
TEMPORARY="$(mktemp -d)"
mkdir -p "$TEMPORARY/draco3d"
tar -xzf "$ROOT/offline/web/draco3d-1.5.7.tgz" \
  -C "$TEMPORARY/draco3d" --strip-components=1
DRACO3D_DIR="$TEMPORARY/draco3d" \
  "$NODE" --expose-gc "$ROOT/tests/web/test_codec_fixture.mjs"
"$ROOT/scripts/verify_web_assets.sh"

echo "Static browser tests passed."
