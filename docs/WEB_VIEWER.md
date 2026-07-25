# Native browser field viewer

This is the additive, no-VNC browser interface for the exact calibrated dual
ZED X One rig. The Jetson continues to own the cameras, run ZED NEURAL depth,
and write lossless SVO2. A MacBook or Linux workstation only decodes and
renders the already-compressed preview through an SSH tunnel.

The existing Ubuntu/RViz procedure remains installed and is the rollback path
in root [RUNBOOK.md](../RUNBOOK.md).

## Fixed data contract

| Product | Source and rate |
|---|---|
| Rectified RGB | Original ROS JPEG, 960x600 at 5 Hz |
| Registered depth | Original ROS compressed-depth payload, 960x600 at 5 Hz |
| Colored point cloud | Original ROS Draco payload, reduced cloud at 2 Hz |
| Lossless recording | Jetson-local synchronized SVO2, 1920x1200 at 15 FPS |
| Depth computation | ZED SDK `NEURAL` on the Jetson |
| Browser fixed frame | `zed_camera_link`, X forward, Y left, Z up |

The browser path does not re-encode the preview and does not change
`field.yaml`, `outdoor.yaml`, calibration, serial order, acquisition, depth
mode, or recording compression.

Browser sessions launch both the ZED wrapper/replay and gateway with
`config/ros2/cyclonedds-loopback.xml`. DDS discovery and payloads therefore
remain on Jetson interface `lo`; only the authenticated SSH tunnel crosses the
field LAN. The existing RViz launchers retain
`config/ros2/cyclonedds-jetson.xml` and their current LAN behavior.

## Why the gateway is C++, not ROSBridge

The approved plan allowed a narrow C++ adapter if the ROSBridge audit justified
it. This Jetson had ROSBridge, Tornado, and the Python WebSocket runtime absent,
but already had `rclcpp`, the exact ROS messages, and Boost.Beast. The shipped
gateway therefore:

- adds no system package or field runtime;
- forwards the original compressed bytes without CBOR conversion;
- creates one depth, RGB, and cloud subscription only while its authenticated
  WebSocket is attached;
- uses a latest-only ROS queue and a separate socket per stream;
- binds only to `127.0.0.1`;
- exposes only fixed existing session-helper operations.

The wire format is documented in [WEB_PROTOCOL.md](WEB_PROTOCOL.md).

## One-time Jetson preparation

The browser assets and their source archives are already in the repository.
No internet is used by the build or field runtime.

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/verify_web_assets.sh
./scripts/build_web_gateway.sh
./scripts/verify_ros2_setup.sh
```

This does not open cameras, install packages, restart daemons, or enable a boot
service. The gateway is a transient per-user unit started on demand.

The normal persistent-user-manager prerequisite still applies:

```bash
sudo loginctl enable-linger dusty
loginctl show-user dusty -p Linger
```

Expected: `Linger=yes`.

## Workstation requirements

The viewing computer may run current macOS or Linux. It needs:

- a current Safari, Chromium, Chrome, Firefox, or Edge with WebAssembly,
  WebGL2, Web Workers, and `DecompressionStream("deflate")`;
- OpenSSH;
- this repository's scripts;
- noninteractive SSH key access to the Jetson.

It does **not** need Ubuntu, ROS, DDS, RViz, ZED SDK, CUDA, VNC, Node, npm, a
cloud account, a branded viewer, or internet access.

The gateway Content Security Policy permits `wasm-unsafe-eval` solely so the
pinned offline Draco decoder can compile its WebAssembly module. General
JavaScript `unsafe-eval` remains disabled.

## One-time MacBook setup

Do this while internet access is available. macOS already supplies Git,
OpenSSH, and the `open` browser launcher:

```bash
mkdir -p ~/Documents/workspace/terraforming_mars
cd ~/Documents/workspace/terraforming_mars
git clone git@github.com:maximilianadang/zed-x-one-rig.git
cd zed-x-one-rig
git pull --ff-only
```

If that repository already exists, use only the last two commands from inside
it. The Mac clone does not need to build anything.

Create a dedicated field SSH key if the Mac does not already have one:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_zed_field
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_zed_field
cat ~/.ssh/id_ed25519_zed_field.pub | \
  ssh dusty@ubuntu.local 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys'
```

The second command asks for the Jetson login password once. Then add the stable
alias below to `~/.ssh/config`, substituting the verified Jetson address when
`ubuntu.local` is ambiguous:

```sshconfig
Host zed-jetson
    HostName ubuntu.local
    User dusty
    IdentityFile ~/.ssh/id_ed25519_zed_field
    IdentitiesOnly yes
    AddKeysToAgent yes
    UseKeychain yes
```

Protect and test that configuration:

```bash
chmod 600 ~/.ssh/config
ssh -o BatchMode=yes zed-jetson 'hostname; test -x /home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/zed_web_session.sh'
```

The test must print `ubuntu` and return without a password prompt. Before going
offline, update both clones and confirm that their commit IDs match:

```bash
git pull --ff-only
git rev-parse --short HEAD
ssh zed-jetson 'cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig && git rev-parse --short HEAD'
```

Use a stable SSH alias when possible:

```sshconfig
Host zed-jetson
    HostName JETSON_ADDRESS_OR_UNAMBIGUOUS_MDNS_NAME
    User dusty
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Check it before the field:

```bash
ssh -o BatchMode=yes zed-jetson true
```

Do not disable host-key checking. If `ubuntu.local` resolves ambiguously on
AsteraMesh, Mars, or MarsLink, update the alias with the Jetson's current
address.

## Live launch

On the Mac/Linux viewing computer:

```bash
cd /path/to/zed-x-one-rig
./scripts/zed_web_console.sh \
  --jetson zed-jetson \
  --remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig
```

The interface opens **view-only**. For the sky-heavy exposure profile:

```bash
./scripts/zed_web_console.sh \
  --jetson zed-jetson \
  --remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig \
  --outdoor
```

The browser must show `PROFILE STANDARD` or `PROFILE OUTDOOR`. Outdoor changes
only the approved exposure behavior.

If automatic browser opening is unavailable:

```bash
./scripts/zed_web_console.sh \
  --jetson zed-jetson \
  --remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig \
  --no-open
```

Copy the printed loopback URL into the local browser. The token is temporary,
is removed from visible browser history after load, and is retained only in
that tab's session storage so a refresh works. It is not stored in the
repository or in persistent browser storage.

## Browser layout and controls

The fixed layout contains:

- rectified left RGB;
- registered left-frame metric depth, using RViz's five-frame
  median-normalized grayscale;
- the colored cloud in `zed_camera_link` with an XY grid and one-metre axes;
- stream receive rates and dropped-sequence counts;
- independently measured receive/render rates, timestamp age, and dropped or
  deliberately superseded frames;
- actual Jetson session/profile/storage/path state;
- a persistent red recording banner with elapsed time, bytes, and measured
  write rate.

Live buttons:

| Control | Effect |
|---|---|
| Start lossless recording | Calls the proven helper, waits for SDK acceptance, and verifies file growth. |
| Stop & validate recording | Finalizes, inspects, validates, and promotes the SVO2. |
| Safely stop rig session | Finalizes first if needed, stops the exact unit, and checks camera release. |
| Reset view | Restores the RViz-equivalent 3D orbit target and orientation. |

Controls remain disabled while a prior mutation is in flight. Every result is
reconciled from Jetson state; the page does not claim success optimistically.
Exactly one browser holds the renewable control lease. Additional authenticated
tabs can view streams and status but visibly remain read-only until the current
controller closes or its lease expires.

The footer's age is source-timestamp age during live operation. During replay,
where the original capture timestamp is intentionally historical, it reports
browser receive-to-render age instead.

## Disconnect and reconnect

Closing the browser, pressing `Ctrl+C` in the workstation launcher, losing
Wi-Fi, or sleeping the laptop closes only the tunnel/view. The Jetson camera
session and an active recording continue.

Reconnect with the same command. It attaches to the existing live/replay
session and returns the current recording state.

The gateway itself owns neither the camera nor recording. It can be stopped
without changing either:

```bash
ssh zed-jetson \
  /home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/zed_web_session.sh \
  stop-gateway
```

Use the browser's safe-stop button or the existing field helper when the camera
session should actually end.

## Browser replay

Stop live acquisition first. Then run:

```bash
./scripts/zed_web_console.sh \
  --jetson zed-jetson \
  --remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig \
  --replay
```

Select a finalized SVO2 with Up/Down and Enter or by clicking/double-clicking a
row. Direct newest-first selection is also available:

```bash
./scripts/zed_web_console.sh \
  --jetson zed-jetson \
  --remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig \
  --replay --index 3
```

Replay controls:

| Control | Effect |
|---|---|
| Space or Play/Pause | Toggle sequential playback. |
| `.` or Next frame | Advance one frame while paused without seeking. |
| Slower/Faster | Step through the proven 0.1x-5x rates. |
| Loop next dataset | Apply loop mode when opening the selected dataset. |
| Stop replay session | Stop the exact transient replay unit. |

Backward and arbitrary seeking remain intentionally absent because the
installed ZED frame-position service previously blocked for 11.5 seconds.

## Offline assets and tests

Runtime assets and upstream archives are retained in:

```text
web/vendor/
offline/web/
```

Checksums and licenses are in
[web/vendor/VERSIONS.md](../web/vendor/VERSIONS.md).

Development tests use Node only as a test runner:

```bash
NODE=/path/to/node ./scripts/test_web.sh
```

Node is not used by the field launcher, gateway, or browser.

The committed codec fixture is synthetic and non-sensitive. Jetson validation
also used a synchronized real SVO2 replay frame and the installed ROS decoders;
its identifiable RGB was deliberately not retained. See
[tests/fixtures/synthetic-v1/README.md](../tests/fixtures/synthetic-v1/README.md).

## Troubleshooting

- **SSH preflight fails:** repair the target address, host key, and SSH key.
  Do not restart camera daemons.
- **Gateway is not built:** SSH to the Jetson and run
  `./scripts/build_web_gateway.sh`.
- **Page cannot open:** keep the launcher running; verify its SSH tunnel did
  not exit and use the exact printed `127.0.0.1` URL.
- **Page opens but all streams reconnect:** verify a live/replay session is
  ready and inspect `./scripts/zed_web_session.sh logs`.
- **One pane is stale:** its socket reconnects independently; source and
  receive rates appear in the footer. A cloud cannot queue RGB/depth behind it.
- **Depth decoder error:** use a current browser with deflate
  `DecompressionStream`; fall back to the RViz runbook while updating the
  workstation browser.
- **Control reports conflict:** read the complete operator message and status.
  Existing session locks reject duplicate recording/replay mutations.
- **Network changes:** close the current field session as documented in
  `RUNBOOK.md`, move both machines, verify SSH identity, and relaunch.
- **Browser reports an active LAN-DDS session:** safely stop the existing RViz
  live/replay session, then launch the browser again. It will not silently
  attach to a session using the wrong DDS profile.
- **Browser failure during recording:** the recording continues. Reconnect or
  use `zed_field_session.sh status` and `record-stop` over SSH.

## Rollback

The browser implementation changes no current ROS profile or existing helper.
At any point, stop only the gateway and use:

```bash
./scripts/zed_field_console.sh --jetson zed-jetson
./scripts/zed_replay_console.sh --jetson zed-jetson
```

The direct lossless recorder remains the final fallback in root `RUNBOOK.md`.
