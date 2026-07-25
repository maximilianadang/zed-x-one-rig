# TASKS - Native browser field viewer for the dual ZED X One rig

Ordered, approval-gated plan for replacing the Ubuntu/RViz viewing computer
with a self-hosted browser interface that works natively on a MacBook Pro or
another modern computer. The Jetson remains the camera, NEURAL-depth, replay,
and recording host.

This plan follows the project's all-caps rigor: READ records observed facts,
INFER separates proposed conclusions, DERISK makes failure containment and
acceptance evidence explicit, and implementation does not begin until the user
approves the gate. The prior RViz field-console plan is preserved at
`docs/archive/TASKS_REMOTE_FIELD_CONSOLE_2026-07-21.md`.
The current proven operating and rollback protocol is frozen in the repository
root at `RUNBOOK.md`.

## Planning status - 2026-07-25

| Section | Status | Gate |
|---|---|---|
| READ | Complete | Current repository, ROS topics, RViz configuration, control/replay helpers, installed transports, and receiver packaging were inspected. |
| INFER | Approved | User approved this bounded line of work on 2026-07-25. |
| DERISK | Approved | The documented containment, rollback, and acceptance gates remain mandatory. |
| Implementation | Release candidate built | Jetson/replay tests pass; actual MacBook, live-camera, recording, two-network, and comparative resource acceptance remain open. |

## Desired outcome

- From a MacBook Pro or any current desktop browser on the same reachable
  network, one native launcher establishes an authenticated connection to the
  Jetson, opens the field interface, and requires no ROS, RViz, ZED SDK, CUDA,
  VNC, branded visualization product, cloud account, or internet connection on
  the viewing computer.
- The browser reproduces the operational content of the proven RViz view:
  rectified RGB, registered depth, colored point cloud, XY grid, camera axes,
  fixed `zed_camera_link` frame, and orbit/pan/zoom controls.
- "Reproduces RViz" means data-equivalent and convention-equivalent, not a
  video stream of the RViz desktop or a pixel-for-pixel copy of RViz chrome.
  The browser must use the same source measurements and match the meaningful
  visual transformations.
- The browser replaces the current RViz/DDS receiver. It does not run beside it
  during normal field use and must not duplicate the camera or preview pipeline.
- The proven publication and capture contract remains unchanged:
  - rectified RGB: 960x600 at 5 Hz;
  - registered depth: 960x600 at 5 Hz;
  - colored point cloud: `REDUCED` at 2 Hz;
  - native acquisition: 1920x1200 at 15 FPS;
  - lossless SVO2 recording: synchronized 1920x1200 at 15 FPS on the Jetson.
- Standard and `--outdoor` acquisition profiles remain available. Browser
  selection of a profile must not silently alter resolution, publication rate,
  depth mode, calibration, or recording compression.
- The browser includes the field console's prominent view/record state,
  elapsed recording time, bytes written, current write rate, free-space
  estimate, saved filename, errors, and explicit start/finalize/status/quit
  actions.
- The same interface browses and replays finalized Jetson SVO2 datasets. It
  preserves the proven forward-only replay model: play/pause, next frame,
  speed, loop, restart, dataset selection with arrows or number, and no
  backward/time seeking that can hang the ZED playback service.
- A browser, tunnel, laptop, or Wi-Fi loss leaves the independent Jetson live
  session and any active recording unchanged. Reconnection reports and attaches
  to the real state.
- Field deployment is fully offline. All JavaScript, WebAssembly, fonts,
  packages, checksums, and install artifacts required by the shipped path are
  retained locally.

## Non-goals

- Do not stream a rendered Jetson desktop, RViz window, VNC session, or GPU
  framebuffer.
- Do not move ZED SDK processing, NEURAL depth, SVO2 recording, or replay onto
  the MacBook.
- Do not increase preview resolution, RGB/depth frequency, point-cloud
  frequency, native acquisition, or recording rate in this line of work.
- Do not add spatial mapping, positional tracking, object detection, body
  tracking, multi-user control, public-internet access, cloud relay, or remote
  file deletion.
- Do not replace lossless SVO2 with browser video, ROS bags, MCAP, or a
  transcoded recording.
- Do not install, rebuild, restart, or modify JetPack/L4T, the GMSL driver, ZED
  SDK, camera daemons, calibration, or physical-camera configuration.

## READ

### Proven repository and rig boundary

- The repository was clean at `main` commit `30c6b31`, tracking `origin/main`,
  when this planning read began.
- Physical-left serial `304467158`, physical-right serial `306605936`, virtual
  serial `116863460`, and the installed virtual calibration remain the fixed
  rig identity.
- `scripts/start_ros2_virtual_stereo.sh` is the only intended live camera
  owner. It opens the calibrated virtual pair at HD1200/15 FPS with NEURAL
  depth and refuses known competing camera owners.
- `config/ros2/field.yaml` and `config/ros2/outdoor.yaml` both publish RGB and
  registered depth at 960x600/5 Hz and a reduced colored cloud at 2 Hz.
  Outdoor mode changes exposure controls only.
- Lossless recording is performed inside the already-open ZED wrapper at
  1920x1200/15 FPS. Preview transport is not the recording source, and changing
  the viewer must not change the SVO2 contract.

### Exact current RViz content

- `rviz/virtual_stereo.rviz` uses fixed frame `zed_camera_link`.
- The view contains:
  - an XY line grid in the fixed frame;
  - camera axes referenced to `zed_camera_link`;
  - an RGB image display;
  - a registered-depth image display with normalized range enabled;
  - a colored `PointCloud2` display using XYZ positions, the `rgb` field,
    `RGB8` color transformation, and two-pixel points;
  - an orbit camera with pan, zoom, focus, and selection behavior.
- RGB arrives from
  `/zed/zed_node/rgb/color/rect/image/compressed`.
- Registered depth arrives from
  `/zed/zed_node/depth/depth_registered/compressedDepth`.
- The remote RViz launcher receives
  `/zed/zed_node/point_cloud/cloud_registered/draco`, decodes it locally, and
  displays `/zed_field/point_cloud/cloud_registered`.
- Historical field measurements observed approximately 174 KB RGB, 60 KB
  depth, and 69 KB Draco messages at the configured rates. These are
  scene-dependent samples, not fixed bandwidth guarantees.

### Browser-relevant message and codec facts

- RGB and compressed depth use `sensor_msgs/msg/CompressedImage`.
- RGB is already JPEG-compressed and can be decoded directly by current
  browsers without re-encoding on the Jetson.
- ROS `compressedDepth` includes a transport configuration header followed by
  PNG-compressed depth data. The installed transport defines inverse-depth
  quantization parameters for floating-point depth. A browser decoder must
  interpret the header and reconstruct metric depth before applying the display
  color mapping; stripping the header and showing the PNG as an ordinary image
  is not sufficient evidence of correctness.
- Draco point-cloud transport uses
  `point_cloud_interfaces/msg/CompressedPointCloud2`. The message retains the
  ROS header, dimensions, `PointField` metadata, layout, density flags, format,
  and a `compressed_data` byte array.
- Google Draco supplies a JavaScript/WebAssembly decoder for point clouds.
  Compatibility between its decoded attributes and this installed ROS
  transport's XYZ/RGB encoding has not yet been proven on a captured rig
  message.
- ROSBridge v2 supports WebSocket transport plus JSON, CBOR, and CBOR-RAW
  encodings. The Jetson does not currently have `ros-humble-rosbridge-suite`
  installed. The configured ROS apt repository currently offers version
  `2.0.7-1jammy.20260606.004959` for this arm64 Jammy host.

### Existing control and replay boundary

- `scripts/zed_field_session.sh` is the authoritative live/view/record
  supervisor. It owns the transient user unit, state, command lock, storage
  checks, SDK recording service calls, file-growth checks, finalization,
  validation, and camera-release confirmation.
- `scripts/zed_replay_session.sh` is the authoritative SVO2 replay supervisor.
  The existing workstation replay console supplies dataset listing, arrow or
  number selection, pause/play, sequential next-frame stepping, rate, loop,
  restart, status, and safe stop.
- Backward and arbitrary time seeking were deliberately removed after the
  installed ZED `set_svo_frame` path blocked for unusable intervals and caused
  failures under load.
- The existing console treats control loss differently from clean `q`.
  Disconnect leaves Jetson state untouched; clean quit finalizes an active
  recording before stopping the exact owned unit.
- The web interface must use these supervisors rather than call raw ZED
  recording/replay services and bypass their validation or recovery behavior.

### Current remote-computer and network boundary

- The supported receiver is currently Ubuntu 22.04 with ROS 2 Humble, Cyclone
  DDS, RViz2, image transports, and point-cloud transports.
- `scripts/install_ros2_remote.sh` explicitly requires Jammy and apt packages;
  it is not a macOS installer.
- The current workstation receives DDS discovery and all preview data across
  the LAN. Field work already exposed MTU, fragmentation, multicast discovery,
  frozen-image, and stale-session behavior that required careful containment.
- The proposed browser path can keep ROS 2/DDS on the Jetson and carry only
  browser-oriented binary streams through an authenticated SSH tunnel.
- AsteraMesh and Mars have both been used. `ubuntu.local` and observed DHCP
  addresses are not a guaranteed unique identity on every future topology; the
  existing `zed-jetson` SSH-alias recommendation remains valid.
- The target MacBook model, CPU architecture, macOS version, Safari version,
  available Chromium browser, wired/Wi-Fi interface, repository path, and SSH
  key state have not yet been captured.

### Current resource boundary

- NEURAL depth, image publication, depth compression, and Draco compression
  already execute on the Jetson for the RViz path.
- RViz rendering and Draco decompression currently execute on the Ubuntu
  workstation. In the browser path, depth/Draco decoding and 2D/3D rendering
  should execute on the MacBook instead.
- Forwarding already-compressed payloads does not inherently add ZED GPU work.
  A bridge still adds CPU serialization/copying, SSH encryption, process
  memory, socket buffers, and possible backpressure.
- No browser-gateway CPU, RSS, GPU, power, temperature, wire-rate, or
  end-to-end-latency measurement exists yet. Resource claims must remain
  hypotheses until measured against the current RViz baseline.

## INFER

### Proposed architecture

- Keep the existing ZED ROS node, profiles, session supervisors, topics, and
  SVO2 recording/replay paths unchanged.
- Add one on-demand Jetson web gateway that:
  - binds only to Jetson loopback;
  - subscribes once to the existing compressed RGB, compressed-depth, and
    Draco topics;
  - forwards binary payloads without image, depth, or point-cloud re-encoding;
  - retains at most the newest message per stream;
  - fans out the same retained payload if read-only multi-client support is
    later enabled;
  - exposes a narrow, fixed control surface backed by the existing session
    supervisors.
- Use ROSBridge with binary CBOR/CBOR-RAW as the first transport implementation
  because it reuses the current ROS messages and minimizes custom Jetson code.
  Keep the browser transport adapter isolated so profiling can replace
  ROSBridge with a small C++ `rclcpp` gateway without rewriting visualization
  or control behavior.
- Do not use JSON/base64 for image, depth, or point-cloud payloads.
- Use independent/latest-only stream handling so a large cloud cannot queue
  stale RGB/depth frames behind it. If one WebSocket produces head-of-line
  blocking, split image/depth/cloud across separate loopback WebSockets before
  considering a different protocol.
- Serve a prebuilt static application. Node/npm may be used for a pinned,
  reproducible development build, but Node is not a Jetson field-runtime
  dependency.
- Vendor and checksum every runtime asset, including Three.js, orbit controls,
  the Draco WebAssembly decoder, and any 16-bit PNG/depth decoder. Do not load
  a CDN in normal or fallback operation.

### Proposed browser rendering

- Decode RGB using browser-native JPEG facilities and present only the newest
  completed frame.
- Decode compressed depth in a Web Worker, reconstruct metric Z from the
  transport header/quantization parameters, and colorize using a documented
  shader that matches the current RViz normalized-depth behavior.
- Decode Draco in a Web Worker/WASM, transfer typed arrays rather than clone
  them, reuse Three.js `BufferGeometry`, and preserve XYZ plus packed RGB.
- Render the 3D scene in the `zed_camera_link` convention: X forward, Y left,
  Z up. Reproduce the current XY grid, axes, two-pixel colored points, starting
  view, orbit, pan, zoom, and reset/focus controls.
- Present fixed RGB, depth, and cloud panels by default. Resizing a panel must
  not alter source publication rates or start another subscription.
- Define equivalence with fixtures and numeric comparisons:
  - identical source timestamps and frame identities;
  - RGB decoded from the identical JPEG payload;
  - metric depth samples matching the ROS decoder within an explicit tolerance;
  - cloud point count, XYZ, RGB, frame, and bounds matching the ROS Draco
    decoder within the codec's existing quantization;
  - axes/grid/view conventions matching `virtual_stereo.rviz`.

### Proposed launcher and security model

- Add a portable `scripts/zed_web_console.sh` that runs on macOS and Linux with
  only POSIX shell tools, OpenSSH, and a supported browser.
- Proposed normal commands:

  ```bash
  ./scripts/zed_web_console.sh --jetson zed-jetson
  ./scripts/zed_web_console.sh --jetson zed-jetson --outdoor
  ./scripts/zed_web_console.sh --jetson zed-jetson --replay
  ```

- The launcher should verify the SSH host key and rig identity, start or attach
  to the appropriate Jetson transient session, establish a local port forward,
  and open `http://127.0.0.1:<allocated-port>/`.
- Bind the gateway to `127.0.0.1` on the Jetson and reach it only through SSH.
  Do not expose an unauthenticated ROSBridge/WebSocket/HTTP port to AsteraMesh,
  Mars, MarsLink, or a Starlink-facing interface.
- Browser commands must map to a fixed allowlist such as status, record-start,
  record-stop, live-stop, replay-list, replay-start, replay-toggle,
  replay-next-frame, replay-rate, replay-loop, and replay-stop. Never accept a
  shell command, arbitrary path, arbitrary ROS service, or arbitrary topic
  publication from browser input.
- A read-only status/stream connection may be shared later, but exactly one
  controller lease may issue state-changing commands. Duplicate control must
  fail visibly rather than race.

### Proposed lifecycle and operator behavior

- Browser startup is view-only. Recording remains off until an explicit
  control action.
- The current standard/outdoor profile is selected before camera launch and is
  displayed prominently from Jetson-reported state.
- Recording controls retain the current temporary-file, file-growth,
  finalization, `ZED_SVO_Editor` validation, promotion, storage-reserve, and
  camera-ownership behavior.
- The browser displays a continuously visible recording indicator, duration,
  saved bytes, write rate, capacity estimate, active/final path, and validation
  result.
- Closing a browser tab, losing the SSH tunnel, sleeping the MacBook, or
  changing Wi-Fi leaves the Jetson live session and active recording running.
  Reopening the launcher attaches and reports actual state.
- Clean quit explicitly finalizes any recording, stops the exact live/replay
  unit, confirms camera availability where applicable, and then closes the
  tunnel.
- Live and replay feed the same browser rendering components. Mode-specific
  controls remain separate so a replay command can never reach the live camera
  session.
- The current Ubuntu/RViz console and replay console remain supported rollback
  paths until browser acceptance is complete.
- `RUNBOOK.md` remains the authoritative current field protocol. Browser work
  may not remove or rewrite that protocol before the browser acceptance gate;
  accepted browser operation is added as a new section only after proof.

### Proposed resource behavior

- Preserve the exact current `field.yaml` and `outdoor.yaml` publication rates
  and resolutions for the first release.
- Subscribe to transports only while at least one authenticated browser session
  is active; an idle gateway must not keep compression work alive.
- Move JPEG/depth/Draco decoding and all rendering to browser workers/GPU.
  Do not colorize depth, expand Draco to raw `PointCloud2`, or render 3D on the
  Jetson merely for browser delivery.
- Use bounded single-message queues and drop obsolete preview messages. The
  newest valid view is more useful than complete but increasingly stale
  preview delivery.
- Compare browser and RViz using the same scene, profile, rates, and recording
  state. A browser release is not accepted merely because it looks responsive.

## DERISK

- **Approval boundary:** do not install ROSBridge or web dependencies, add
  code, create a unit, expose a port, open the cameras, replay an SVO, or modify
  offline caches until the user approves this READ/INFER/DERISK gate.
- **Camera-stack boundary:** do not install, rebuild, reload, replace, or
  restart JetPack/L4T, the GMSL driver, ZED SDK, `nvargus-daemon`, or
  `zed_x_daemon`. Browser/gateway failure is not evidence of a driver fault.
- **Calibration/capture boundary:** retain exact serial order, calibration
  checksum, HD1200/15 FPS acquisition, NEURAL depth, profile exposure settings,
  and lossless SVO2 behavior. Reject any implementation that changes these as
  an incidental viewer side effect.
- **Quality/frequency boundary:** first acceptance is fixed at RGB/depth
  960x600/5 Hz and reduced cloud/2 Hz. Higher-rate or higher-resolution preview
  is a separate future approval and benchmark.
- **Codec-correctness risk:** capture small versioned fixtures from each
  compressed topic. Compare browser depth and cloud outputs numerically against
  the installed ROS decoders before live visual acceptance.
- **Depth risk:** test NaN, infinity, zero, too-near, too-far, invalid, and
  inverse-depth cases. A plausible color image is not proof that metric Z was
  decoded correctly.
- **Draco risk:** prove XYZ and RGB attribute identity, point count, coordinate
  handedness, frame, quantization, and invalid-point handling. Do not silently
  substitute a raw cloud across Wi-Fi if browser decoding fails.
- **Visual-equivalence risk:** maintain screenshot/fixture acceptance for RGB,
  depth color mapping, point size/color, grid spacing, axes orientation, initial
  camera pose, and orbit controls. Document intentional differences from RViz.
- **Backpressure risk:** instrument sequence/timestamp age, receive/decode/render
  rates, drops, and queue depth. Every queue is bounded; stale frames are
  discarded rather than delivered late.
- **Resource risk:** measure Jetson CPU per process, GPU load, RAM/RSS,
  temperature, power mode, topic rates, SVO write health, and network bytes for
  RViz baseline versus browser. Test view-only and simultaneous lossless
  recording. No claim of lower load is accepted without those measurements.
- **Browser risk:** test the actual MacBook's Safari/WebGL2/WebAssembly behavior
  and one current Chromium browser. Record model, architecture, OS, browser
  version, decode rates, memory growth, sleep/wake, tab-background behavior,
  and GPU-reset recovery.
- **Network risk:** test AsteraMesh and Mars separately. SSH success, HTTP page
  load, WebSocket stream health, reconnect, and recording survival must be
  proven without depending on LAN multicast or internet.
- **Security risk:** bind only to loopback, require SSH key and normal host-key
  verification, allocate a local forwarded port safely, apply origin checks,
  and expose no arbitrary ROS/shell interface. Store no password or private key
  in the repository.
- **Control-integrity risk:** route mutations through existing locked session
  helpers. Reconcile browser UI with Jetson-reported state after every action;
  optimistic UI alone cannot declare recording or finalization success.
- **Disconnect risk:** close the tab, kill the browser, kill the launcher, drop
  Wi-Fi, suspend the laptop, and terminate the tunnel during view and recording.
  The Jetson must remain safe and later attach/finalize correctly.
- **Replay risk:** retain forward-only controls. Do not reintroduce backward or
  arbitrary SVO seeking unless the installed SDK later passes a separately
  approved bounded-latency test.
- **Offline risk:** remove internet access during acceptance. The page, workers,
  WASM, fonts, gateway packages, SSH launcher, live view, recording controls,
  dataset browser, and replay must all function from retained artifacts.
- **Multi-client risk:** first release supports one controlling browser.
  Additional viewers must be read-only and consume shared encoded payloads; do
  not multiply Jetson encoders or permit competing recording actions.
- **Rollback:** retain the current `zed_field_console.sh`,
  `zed_replay_console.sh`, RViz profile, ROS receiver installer, and direct
  recorder exactly as documented in root `RUNBOOK.md`. Removing the web gateway
  must require no camera, calibration, driver, or network repair.
- **Runbook-drift risk:** test the root runbook before browser changes and again
  at final acceptance. Do not document a proposed browser path as operational
  until it has passed its gates; do not delete proven commands when adding it.

## Approved decisions

- Browser delivery replaces, rather than accompanies, RViz in normal use.
- Initial browser quality and frequency exactly match the current field profile.
- ROS and DDS remain Jetson-local; the Mac receives binary browser streams
  through an SSH tunnel.
- The transport remains behind an adapter and carries binary payloads only.
  The implementation audit found ROSBridge, Tornado, and its WebSocket runtime
  absent, while the already-installed ROS 2 C++ message stack and Boost.Beast
  provide the required transport without a new system package or Python
  runtime. The approved fallback is therefore the narrow C++ `rclcpp` gateway,
  subject to the same loopback, queue, protocol, and resource gates.
- Browser runtime is static/offline; no Node, CDN, cloud, account, VNC, ZED SDK,
  ROS, or CUDA is required on the Mac.
- Three.js plus vendored Draco WASM renders the colored cloud; depth decoding
  and both heavy codecs run in browser workers.
- Existing Jetson session scripts remain authoritative for live ownership,
  recording, validation, replay, failure recovery, and safe shutdown.
- The browser begins view-only, shows Jetson-reported state, and preserves
  current disconnect-survival behavior.
- Backward and arbitrary replay seeking remain unavailable.
- The Ubuntu/RViz path remains installed and documented as rollback until all
  browser gates pass.
- Root `RUNBOOK.md` is the operational source of truth throughout this work.

## Ordered tasks

- [x] **APPROVAL GATE - accept READ / INFER / DERISK and pending decisions.**
  - Resolve rejected assumptions in this document before implementation.
  - User approval authorizes this bounded line of work, not unrelated camera,
    driver, network-router, cloud, or capture-quality changes.
  - Approved by the user on 2026-07-25.

- [ ] **T0 - freeze browser, fixture, protocol, and baseline contracts.**
  - Rehearse the root `RUNBOOK.md` current live, recording, reconnect, replay,
    shutdown, camera-release, and direct-recorder rollback commands before
    changing the viewing path.
  - Capture the target MacBook hardware, architecture, macOS, Safari, optional
    Chromium, SSH, interface, and expected repository/launcher location.
  - Record the exact installed ROS message definitions, compressed-depth header
    layout, Draco transport version/settings, RViz display settings, and topic
    QoS.
  - Capture short, non-sensitive RGB/depth/Draco fixtures from synchronized
    live or replay output plus ROS-decoded reference values and screenshots.
  - Measure current RViz baseline rates, message sizes, latency/staleness,
    Jetson process CPU/GPU/RAM/temperature/power, network bytes, and recording
    health using the current field profile.
  - Specify versioned binary WebSocket envelopes, timestamps, frame IDs,
    stream IDs, status/error messages, control allowlist, and compatibility
    version.
  - **Gate:** every browser output and performance comparison has a fixed,
    reviewable input and baseline before UI implementation.

- [ ] **T1 - prove browser decoding without a live camera.**
  - Build an offline static fixture viewer with pinned local assets.
  - Decode identical JPEG bytes and verify dimensions and sampled pixels.
  - Implement compressed-depth header/PNG decoding and compare metric samples,
    validity masks, ranges, and colorized output against ROS/RViz references.
  - Decode the captured Draco payload with WASM and compare point count, XYZ,
    RGB, bounds, invalids, frame, and quantization against the ROS decoder.
  - Run codecs in workers with transferable buffers and prove bounded memory
    over a long repeated-fixture test.
  - **Gate:** all three products match references numerically and visually
    without ROS, ZED SDK, network, or camera access on the browser machine.

- [ ] **T2 - implement the loopback Jetson gateway and SSH transport.**
  - Pin and cache the approved ROSBridge package and dependencies for arm64
    Jammy, or record why the profiled adapter must be replaced by C++.
  - Subscribe once to the three compressed sources and forward binary data with
    one-message buffers, timestamps, drop counters, and stream health.
  - Serve versioned static assets from loopback and reject non-tunnel access,
    invalid origins, unknown protocol versions, arbitrary ROS operations, and
    malformed/oversized messages.
  - Add an on-demand transient user unit; do not boot-enable it.
  - Add a macOS/Linux SSH launcher with safe port allocation, host/rig
    verification, attach behavior, browser opening, and clear manual fallback.
  - **Gate:** a browser receives all three fixture/live-replay streams through
    the tunnel with no DDS traffic on the LAN and no unbounded process/socket
    growth.

- [ ] **T3 - reproduce the RViz field view in the browser.**
  - Implement fixed RGB and depth panels plus a Three.js point-cloud panel.
  - Match `zed_camera_link`, XY grid, axes, RGB8 cloud color, two-pixel points,
    initial orbit view, pan/zoom/focus/reset, and responsive layout.
  - Display source rate, rendered rate, timestamp age, dropped messages,
    connection state, active profile, and live/replay mode without covering
    scientific content.
  - Ensure layout changes do not change source subscriptions or camera profile.
  - **Gate:** side-by-side fixture and live-replay comparison passes the
    documented numeric, screenshot, orientation, and interaction criteria.

- [ ] **T4 - integrate safe live viewing and recording controls.**
  - Start/attach through `zed_field_session.sh` with standard or outdoor
    profile, beginning in view-only state.
  - Expose only fixed status, record-start, record-stop/finalize, reopen/attach,
    and safe-quit operations through the locked supervisor.
  - Reproduce the prominent recording state, elapsed time, bytes, write rate,
    capacity, paths, validation result, and actionable errors.
  - Exercise duplicate control, low space, SDK refusal, ambiguous finalization,
    browser/tunnel loss, reconnect, and clean shutdown.
  - **Gate:** browser control produces the same validated SVO2 and recovery
    semantics as the proven terminal console without bypassing safeguards.

- [ ] **T5 - integrate the remote SVO2 dataset browser and replay.**
  - Reuse `zed_replay_session.sh` listing, validation, and playback state.
  - Implement newest-first datasets, arrow/number selection, pause/play,
    forward-one-frame, rate, loop, restart, status, dataset switch, and stop.
  - Feed replay through the same RGB/depth/cloud rendering pipeline and expose
    frame/duration/progress state.
  - Confirm that no backward or arbitrary seek control is exposed.
  - **Gate:** multiple valid SVO2 files can be selected and reviewed without
    ZED SDK/ROS on the Mac or a hung playback control.

- [ ] **T6 - prove resource, recording, and network behavior.**
  - Compare current RViz versus browser at identical 5/5/2 rates in view-only
    and lossless-recording states.
  - Measure Jetson total/per-process CPU, GPU, RAM/RSS, temperatures, power,
    topic rates, compression rates, socket queues, network bytes, SVO frame
    count/write rate, and Argus/ZED diagnostics.
  - Measure browser CPU/GPU/memory, receive/decode/render rates, timestamp age,
    drops, background-tab behavior, sleep/wake, and reconnect.
  - Repeat on AsteraMesh and Mars with RViz closed and internet unavailable.
  - **Gate:** browser delivery preserves camera/depth/recording health, does not
    add material GPU work, has bounded CPU/RAM/latency, and is no less reliable
    than the measured RViz baseline.

- [ ] **T7 - finish offline packaging, documentation, and rollback acceptance.**
  - Cache Jetson packages per architecture and vendor/checksum every browser
    runtime asset. Prove installation from the retained offline tree.
  - Document exact Mac setup, SSH alias/key, standard/outdoor live launch,
    controls, reconnect, recording, replay, errors, resource expectations,
    clean exit, and RViz/direct-recorder rollback.
  - Add static checks, frontend tests, codec fixtures, protocol tests, shell
    checks, Markdown-link checks, dry-runs, and `git diff --check`.
  - Rehearse a cold offline Mac-to-Jetson session: view-only, record,
    disconnect, reconnect, finalize, replay, safe stop, camera availability,
    and rollback.
  - **Gate:** another operator can perform the complete browser workflow from
    the written offline procedure alone.

## Implementation evidence - 2026-07-25

Completed and retained in the repository:

- The existing `zed_field_*`, `zed_replay_*`, direct recorder, RViz profile,
  `field.yaml`, `outdoor.yaml`, calibration, and camera configuration have no
  implementation diff. The browser path is additive.
- A deterministic, non-sensitive 96x60 RGB/depth/cloud fixture was produced
  through the installed ROS compressed-depth and Draco encoders. Browser depth
  samples match the stored source within the existing 2 cm transport
  quantization allowance; Draco point count, XYZ bounds/samples, and packed
  color bytes match.
- The depth display follows the installed RViz Humble `ImageDisplay` path:
  finite 32-bit metric depth is normalized to 8-bit grayscale using the median
  of the last five frame minima/maxima. Invalid depth is black.
- A synchronized frame from the rig's short finalized SVO2 was also compared
  against the installed ROS decoders: 960x600 RGB/depth, 29,637 valid depth
  pixels, and 1,404 cloud points. Its identifiable RGB was deliberately
  deleted and was never placed in Git.
- The browser decoder stress test completed 300 repeated depth/cloud cycles
  with a 9.8-20.5 MiB process RSS delta. That test found and corrected improper
  destruction of Draco-owned attribute/status wrappers before deployment.
- The native C++ gateway builds entirely from installed `rclcpp`,
  `sensor_msgs`, `point_cloud_interfaces`, and Boost.Beast. It binds only to
  `127.0.0.1`, serves an allowlisted static tree, requires a 256-bit bearer
  token, checks loopback browser origins and protocol version, and exposes no
  arbitrary topic, ROS service, path, or command.
- Browser live/replay sessions and the gateway use
  `cyclonedds-loopback.xml`, explicitly selecting `lo` and disabling
  multicast. Existing RViz commands retain the prior LAN DDS profile.
- RGB, depth, and cloud use independent binary WebSockets and activate their
  ROS subscriptions only while an authenticated stream is connected. Repeated
  end-to-end tests showed all three subscriptions deactivate after disconnect
  and the gateway exits cleanly.
- A single renewable 30-second controller lease prevents competing browser
  mutations. A second controller receives HTTP 423 while remaining able to
  view authenticated data and status.
- Deployed replay acceptance passed from the actual repository path using the
  original compressed payloads: 960x600 metric depth and a ZED Draco cloud.
  Authentication, invalid origin, dataset reopen, gateway survival across a
  replay-node restart, play/pause, forward-one-frame, speed, state
  reconciliation, and clean stop all passed.
- One sampled idle/disconnected gateway used 15,676 KiB RSS and 0.4% CPU. This
  is evidence only, not the required RViz-versus-browser field resource
  comparison.
- Offline Three.js/Draco archives, runtime assets, checksums, licenses, static
  tests, protocol tests, codec tests, build scripts, the macOS/Linux launcher,
  and operator documentation are retained locally. The deployed
  `verify_ros2_setup.sh` completed with 0 failures and 0 warnings.

Acceptance deliberately still pending:

- Visual/interaction testing in Safari and one Chromium browser on the actual
  MacBook, including model, architecture, macOS/browser versions, memory,
  background-tab, and sleep/wake behavior.
- A full live-camera test of standard/outdoor view, lossless record,
  disconnect/reconnect, finalization/validation, safe stop, and camera release.
- AsteraMesh and Mars tests with internet unavailable, including SSH tunnel
  recovery and the absence of LAN DDS dependence.
- RViz-versus-browser CPU/GPU/RAM/power/temperature/network/latency and
  simultaneous-recording measurements at identical rates.
- Side-by-side visual sign-off for RGB, depth colors, point size/color, grid,
  axes, initial pose, orbit/pan/zoom, and responsive layout.

Until those field gates pass, `RUNBOOK.md` continues to identify the existing
Ubuntu/RViz workflow as the proven default and browser operation as the
additive release candidate.

## Acceptance summary

This line of work is complete only when all of the following are true:

- A MacBook with no ROS, RViz, ZED SDK, CUDA, VNC, branded viewer, account, or
  internet connection opens the self-hosted field interface through SSH.
- RGB, metric registered depth, colored point cloud, grid, axes, frame
  convention, and controls match the defined RViz-equivalence fixtures.
- Preview remains 960x600/5 Hz for RGB/depth and reduced/2 Hz for the cloud;
  acquisition and lossless recording remain 1920x1200/15 FPS.
- The browser begins view-only and safely controls Jetson-local recording with
  visible, reconciled state and validated final files.
- Live control survives browser, laptop, tunnel, and Wi-Fi loss without
  corrupting or silently stopping a recording.
- Dataset selection and forward-only replay work through the same viewer
  without a ZED installation on the Mac.
- DDS does not cross the field LAN in normal browser use; the web gateway is
  loopback-only and reachable only through authenticated SSH.
- Runtime assets and packages are available offline, queues and memory are
  bounded, and measured Jetson GPU/CPU/RAM/network/recording behavior passes
  the documented comparison with RViz.
- The existing Ubuntu/RViz console, replay console, and direct recorder remain
  functional rollback paths, with the root `RUNBOOK.md` still accurate.
