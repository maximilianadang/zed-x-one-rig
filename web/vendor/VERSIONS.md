# Offline browser assets

All runtime files are served locally by the loopback gateway. The field path
does not contact a CDN.

## Three.js r180 / 0.180.0

Source archive:
`offline/web/three-0.180.0.tgz`

Archive SHA-256:
`ad66d724565ee29a2467277fa84daa5ed0211d6b8d446e9ef29f6bae0cd14144`

Runtime assets:

| File | SHA-256 |
|---|---|
| `three.module.min.js` | `e2b5ee6bccd38fd6d8a2428546b83c5f2426d84b152ef82be8055556e3b40eb6` |
| `OrbitControls.js` | `6c860c6b342200f8aef65493319c12bfb2d652107355b1d25eb2154371128391` |
| `DRACOLoader.js` | `9211e54d182308c64c0ecfb03803b7749149f59d7a3351b45e67775d2a1d58b8` |
| `THREE-LICENSE.txt` | `bfe119ea4fd413f5f7ca3fcd63adb0c4a073ed39daa2fe7d3e6b769e21272601` |

The two addon modules have one local packaging change: their bare
`from 'three'` import points to the adjacent pinned
`./three.module.min.js`. No runtime logic was changed.

## Google Draco decoder

The runtime decoder is the default point-cloud-capable Draco WASM bundle
shipped in the pinned Three.js r180 archive. The separate upstream npm archive
is retained at `offline/web/draco3d-1.5.7.tgz` for offline provenance.

Archive SHA-256:
`f2d2b97a938c514dfc1a0f07564eee95b1d889f6862c9c9ccad3001eb0c6f26e`

Runtime assets:

| File | SHA-256 |
|---|---|
| `draco/draco_wasm_wrapper.js` | `e8049906ef3f8f75d3456c22a3f31bfdfe5b5b5bd09ccdec613b9e9a49d554d8` |
| `draco/draco_decoder.wasm` | `c55a594e8ffd18426d36b27fea9618af3df5e173640a3e56d46f09d76f0574f2` |
| `draco/LICENSE.txt` | `d3709b0fb4b8a94bbb1d02b8a2e484f258b0d9c5c5a01f940391f3fe662cd1a4` |
| `draco/README.md` | `8b9d277bf5743f4ce8d85d63c16690071b53f81796e877d4d395af943bde02a0` |
