#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"
sha256sum --check <<'EOF'
e2b5ee6bccd38fd6d8a2428546b83c5f2426d84b152ef82be8055556e3b40eb6  web/vendor/three.module.min.js
b28b369ab5090b393a39b5c2699a7b2085007f0cf41d35f3e7e446877981c62f  web/vendor/three.field.module.min.js
61ba0df005b05991361d040d8ff670e1aadfd0ce7aeebd1fdb0725957a8957de  web/vendor/three.core.min.js
6c860c6b342200f8aef65493319c12bfb2d652107355b1d25eb2154371128391  web/vendor/OrbitControls.js
9211e54d182308c64c0ecfb03803b7749149f59d7a3351b45e67775d2a1d58b8  web/vendor/DRACOLoader.js
e8049906ef3f8f75d3456c22a3f31bfdfe5b5b5bd09ccdec613b9e9a49d554d8  web/vendor/draco/draco_wasm_wrapper.js
c55a594e8ffd18426d36b27fea9618af3df5e173640a3e56d46f09d76f0574f2  web/vendor/draco/draco_decoder.wasm
bfe119ea4fd413f5f7ca3fcd63adb0c4a073ed39daa2fe7d3e6b769e21272601  web/vendor/THREE-LICENSE.txt
d3709b0fb4b8a94bbb1d02b8a2e484f258b0d9c5c5a01f940391f3fe662cd1a4  web/vendor/draco/LICENSE.txt
8b9d277bf5743f4ce8d85d63c16690071b53f81796e877d4d395af943bde02a0  web/vendor/draco/README.md
ad66d724565ee29a2467277fa84daa5ed0211d6b8d446e9ef29f6bae0cd14144  offline/web/three-0.180.0.tgz
f2d2b97a938c514dfc1a0f07564eee95b1d889f6862c9c9ccad3001eb0c6f26e  offline/web/draco3d-1.5.7.tgz
EOF

echo "Offline browser assets match their pinned checksums."
