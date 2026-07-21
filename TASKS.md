# TASKS - ROS 2 remote viewing for the dual ZED X One rig

Ordered execution plan for adding LAN remote visualization and SVO2 replay to
this exact calibrated virtual-stereo rig. ROS 2 is the transport, control, and
visualization layer; the existing direct recorder remains the authoritative
SVO2 capture path.

This plan follows the project's all-caps rigor: establish observed facts before
implementation, distinguish inference from evidence, de-risk system and camera
ownership changes, implement one layer at a time, verify the intended run path
before advancing, and update field documentation whenever runnable behavior
changes.

## Execution status - 2026-07-21

| Task | Status | Evidence / remaining gate |
|---|---|---|
| Approval | Passed | User approved the READ / INFER / DE-RISK line of work. |
| T0 | Jetson passed; remote pending | Jetson boundary and wrapper commit are frozen. A named receiver has not been inspected. |
| T1 | Passed | Live/replay namespace, topics, rates, compression, ownership, and lifecycle are implemented. |
| T2 | Jetson passed; remote/offline rehearsal pending | Humble and the pinned wrapper are installed and built; AArch64 packages are cached. |
| T3 | Passed | Dry-run, preflight, exact serial order, checksum, live launch, replay launch, and safe refusal paths are implemented. |
| T4 | Passed locally | Known SVO2 delivered the topic contract; the compressed viewer bridge delivered RGB/depth/cloud at `4.683/4.412/2.051 Hz` and RViz rendered locally. |
| T5 | Passed | Live rates were `4.841/5.000/1.995 Hz`; clean exit returned both cameras to `AVAILABLE` with no service restart. |
| T6 | Pending external receiver | Requires the Ubuntu 22.04 LAN workstation. |
| T7 | Pending field network | Requires the actual field Wi-Fi. |
| T8 | Existing SVO replay passed; new remote round trip pending | Recording path was deliberately left unchanged. |
| T9 | Local artifacts passed; two-machine rehearsal pending | See `docs/ROS2_VERIFICATION.md`. |

## Desired outcome

- The Jetson opens the calibrated pair as virtual stereo using physical left
  SN `304467158`, physical right SN `306605936`, and virtual SN `116863460`.
- The Jetson computes NEURAL depth and publishes selected, bandwidth-controlled
  ROS 2 image, depth, point-cloud, camera-info, diagnostic, and transform data.
- A supported remote Ubuntu workstation on the same LAN displays rectified
  color, depth, and a colored point cloud in RViz2 without installing the ZED
  SDK or CUDA on that workstation.
- The Jetson can replay a valid virtual-stereo SVO2 through the same ROS 2 topic
  surface, so the remote viewing workflow is the same for live and recorded
  data.
- Existing calibration, direct SVO2 recording, calibration tools, NEURAL
  viewer, and Media Server compatibility path continue to work unchanged.
- The repository contains copy/paste launch, verification, recovery, and
  offline provisioning instructions for both machines.

## READ

### Local rig and repository

- `README.md`, `docs/SETUP.md`, `docs/FIELD_GUIDE.md`, and
  `docs/RECORDER.md` establish the current shipped interfaces and field
  recovery sequence.
- `config/rig.yaml`, `config/rig.env`, and
  `config/virtual_xone_config.json` establish the exact serial-number order,
  virtual serial, capture mode, and legacy stream port.
- `calibration/active/SN116863460.conf` is the authoritative installed virtual
  calibration. Its expected SHA-256 is
  `0502a05ec12942b4f02c375793c1200c6bec1387b4368c744121cbf61da19ed6`.
- `scripts/record_virtual_stereo.sh` and the custom recorder are the currently
  proven synchronized SVO2 recording path.
- `scripts/start_virtual_stereo_stream.sh` is the current Media Server
  compatibility path and uses `127.0.0.1:34000`.
- The known-good software baseline is Ubuntu 22.04.5, Jetson Linux 36.5.0, ZED
  SDK 5.4.0, and CUDA 12.6.68 as reported by ZED.
- The repository was clean at the planning read:
  `main` at `46f1318`, tracking `origin/main`.
- `ZED_Explorer --version` reports ZED SDK 5.4.0 on the current host.
- No `ros2` executable and no `/opt/ros` distribution were observed on the
  current host. ROS 2 must therefore be provisioned; it is not an existing
  interface we can assume.

### Existing rigor process

- The local `networked_sensors/DEVELOPMENT-PROCEDURE.md` requires evidence-led
  `READ`, explicit `INFER`, and `DE-RISK` before code.
- A step is complete only after its intended run path is exercised.
- Simulation or file playback should precede dependence on live hardware where
  practical.
- Runnable/configuration/artifact changes update the matching all-caps
  documentation in the same step.
- Planned behavior must remain clearly labeled as planned until verified.

### Upstream interfaces

- The current Stereolabs ROS 2 wrapper supports `camera_model:=virtual` for two
  calibrated ZED X One cameras and accepts their serial numbers or camera IDs.
- The wrapper's new virtual-stereo API support is based on ZED SDK 5.1 or later
  and does not require ZED Media Server to construct the pair.
- The wrapper publishes rectified and raw images, depth, colored point clouds,
  camera information, transforms, diagnostics, and other ZED data as ROS 2
  topics.
- Stereolabs provides SVO recording and playback through the wrapper.
- Stereolabs recommends reduced publication resolution and frequency for
  preview, `image_transport` compressed image/depth topics, and
  `point_cloud_transport` compression for point clouds.
- Ubuntu 22.04 maps to ROS 2 Humble. The wrapper must still be pinned and built
  against the installed ZED SDK rather than assuming the latest source is
  compatible with SDK 5.4.0.

Primary references:

- <https://docs.stereolabs.com/docs/products/cameras/zedxone/dual-camera-stereo-vision>
- <https://github.com/stereolabs/zed-ros2-wrapper>
- <https://github.com/stereolabs/zed-ros2-wrapper/blob/master/CHANGELOG.rst>
- <https://docs.stereolabs.com/docs/integrations/ros-2>
- <https://docs.stereolabs.com/docs/integrations/ros-2/record-and-replay-data>
- <https://www.stereolabs.com/docs/ros2/150_dds_and_network_tuning>

## INFER

- ROS 2 Humble is the correct first implementation target for this Jetson's
  Ubuntu 22.04 baseline.
- The remote reference client should initially be Ubuntu 22.04 with ROS 2
  Humble and RViz2. A browser-only or non-Linux client is a separate transport
  arm and is not required to prove this one.
- The ZED SDK, GMSL driver, Argus, calibration file, and NEURAL processing
  remain Jetson-side. The remote workstation needs ROS 2, RViz2, the message
  definitions used by displayed topics, and this repository's RViz/config
  assets; it should not need the ZED SDK or CUDA.
- ROS 2 must not become the canonical recording container. SVO2 preserves the
  synchronized stereo inputs and lets the ZED SDK recompute depth later;
  rosbag is optional diagnostic capture only.
- One process may own the physical pair at a time. The ROS wrapper, direct
  recorder, calibration/viewer, and Media Server paths must be treated as
  mutually exclusive modes with explicit preflight checks.
- Serial numbers, not camera IDs, should configure the virtual pair because IDs
  can change. The serial order is part of calibration and must never be
  auto-swapped.
- Full-resolution raw image and dense point-cloud topics are not a viable field
  default. At 1920x1200, a dense 16-byte point representation at 15 FPS is
  approximately 553 MB/s before DDS overhead.
- NEURAL depth should continue at the native 1920x1200, 15 FPS capture mode,
  while publication is independently downscaled and throttled.
- The first conservative field profile should publish image and depth at
  960x600 and 5 FPS, publish a reduced point cloud at 2 FPS, and expose
  compressed transports. Values can be increased only after measured wired
  and wireless acceptance runs.
- Field discovery must be deterministic. A fixed `ROS_DOMAIN_ID` plus verified
  same-subnet multicast is the simplest first path; an explicit DDS peer or
  discovery-server fallback belongs in the runbook for networks that suppress
  multicast.
- No ROS camera service should be enabled at boot until live and replay paths
  pass acceptance. Foreground launch and `Ctrl+C` shutdown preserve observability
  and reduce hidden camera ownership.

## DE-RISK

- **Driver and Argus risk:** do not install, rebuild, replace, reload, or
  restart the GMSL driver, JetPack/L4T, ZED SDK, `nvargus-daemon`, or
  `zed_x_daemon` as part of ROS provisioning.
- **Calibration risk:** verify the installed virtual calibration checksum and
  generated virtual serial before every live launch. Never write the two
  physical factory calibration files.
- **Camera-ownership risk:** launchers inspect known camera-owning processes and
  fail with an actionable message. They never use broad `pkill` and never take
  ownership away from an existing process automatically.
- **Version risk:** select and record an exact wrapper tag/commit that compiles
  against ZED SDK 5.4.0 and ROS 2 Humble. Do not track `master` in field setup.
- **System-mutation risk:** separate read-only verification, package caching,
  installation, configuration, and launch scripts. Installation must be
  explicit and idempotent; verification must never install or restart.
- **Performance risk:** preserve native depth processing but begin with a
  downscaled, throttled preview. Measure topic frequency, bandwidth, frame
  loss, Jetson load, temperature, and Argus/ZED logs before raising rates.
- **Network risk:** validate over wired LAN first, then the actual field Wi-Fi.
  Document firewall, multicast, `ROS_DOMAIN_ID`, interface selection, and a
  static-discovery fallback. No cloud account or internet path is required.
- **Remote-compatibility risk:** prove the first receiver on a named OS,
  architecture, ROS distribution, RMW implementation, and repository commit.
  Generate offline package bundles per architecture; do not assume one bundle
  works on both Jetson AArch64 and workstation x86_64.
- **Recording risk:** do not replace or modify the known-good custom SVO2
  recorder in the first implementation. Validate transitions between ROS live
  view and direct recording as separate camera-ownership modes.
- **Replay risk:** begin remote topic/display work with a known-valid SVO2 where
  possible, then test the live pair. Replay must use the same topic names and
  RViz configuration as live viewing.
- **Rollback:** stopping the foreground ROS launch restores the pre-change
  application topology. Existing launchers and scripts remain intact; no
  boot-time service is added during initial acceptance.

## Settled decisions pending approval of this gate

- ROS 2 is an additive remote-viewing layer, not a replacement for SVO2.
- Jetson distribution: ROS 2 Humble on Ubuntu 22.04.
- First remote reference client: Ubuntu 22.04, ROS 2 Humble, RViz2.
- Live virtual-pair identity: left `304467158`, right `306605936`, virtual
  `116863460`; serial-number selection only.
- Depth: NEURAL at native HD1200/15 FPS on the Jetson.
- Initial field publication profile: 960x600 at 5 FPS for image/depth and a
  reduced point cloud at 2 FPS, with compressed transports available.
- Direct recorder remains the authoritative field recording command.
- No VNC, no required cloud service, no required internet in operation.
- No driver, JetPack/L4T, ZED SDK, calibration, daemon, or boot-service changes
  in the initial line of work.

## Ordered tasks

- [x] **APPROVAL GATE - accept READ / INFER / DE-RISK and settled decisions.**
  - Do not install packages or change system configuration before approval.
  - Resolve any rejected inference in this document before T0.

- [ ] **T0 - freeze the supported-version and system boundary.**
  - Capture the Jetson OS, L4T, kernel, architecture, CUDA, ZED SDK, GMSL
    package, service, calibration-checksum, and camera-enumeration facts in a
    machine-readable verification artifact.
  - Inspect available Stereolabs wrapper releases and select one exact
    tag/commit compatible with ROS 2 Humble and ZED SDK 5.4.0.
  - Record the corresponding ROS apt repository/key and package set without
    installing them during the read-only phase.
  - Record the first remote workstation's OS and architecture before creating
    its offline package bundle.
  - **Gate:** the two-machine compatibility matrix and rollback boundary are
    reviewable before package installation.

- [x] **T1 - define the live, replay, topic, and ownership contracts.**
  - Define mutually exclusive modes: `live-ros`, `replay-ros`,
    `direct-record`, `calibrate`, `direct-viewer`, and `media-server`.
  - Define exact launch inputs for virtual serial numbers, NEURAL depth,
    HD1200/15 capture, publication scaling/rates, namespace, and ROS domain.
  - Define the minimum remotely consumed topics: rectified color, registered
    depth, colored point cloud, both camera-info streams, TF, and diagnostics.
  - Define compressed topic choices and uncompressed local diagnostic topics.
  - Define foreground lifecycle, signal handling, camera-release verification,
    and failure messages.
  - **Gate:** names, ownership, units, rates, compression, and lifecycle are
    fixed before launchers or RViz configuration depend on them.

- [ ] **T2 - add reproducible, offline-capable provisioning.**
  - Add a read-only ROS preflight script.
  - Add an explicit Jetson installer for ROS 2 Humble, build tools, selected
    wrapper source, message packages, image transports, point-cloud transports,
    and the chosen RMW implementation.
  - Pin wrapper source by tag/commit and record checksums or package versions.
  - Add package-cache commands and manifests for Jetson AArch64 and the remote
    workstation architecture; keep large generated caches out of Git unless a
    deliberate storage policy says otherwise.
  - Add a no-camera build verification path.
  - Never fold ROS installation into the existing `scripts/install.sh` without
    a separate explicit flag.
  - **Gate:** a clean install and a second idempotent run succeed without
    touching drivers, calibration, camera daemons, or desktop launchers.

- [x] **T3 - implement the rig-specific ROS configuration and launchers.**
  - Add a minimal parameter override for this exact virtual rig rather than
    editing vendored wrapper defaults.
  - Add foreground live and SVO2 replay launchers with full copy/paste `--help`.
  - Use serial-number order `304467158,306605936`; verify that the SDK-generated
    virtual serial is `116863460`.
  - Verify the installed calibration checksum before live or replay startup.
  - Refuse startup when another known process owns a camera; report its PID and
    command without terminating it.
  - Add a clean stop/release check. Do not add a systemd service.
  - **Gate:** launchers dry-run, validate arguments, and fail safely before
    opening cameras.

- [x] **T4 - prove SVO2 replay locally before live hardware.**
  - Select a known-valid virtual-stereo SVO2 using `ZED_SVO_Editor -inf`.
  - Replay it through the wrapper with the intended namespace, timestamps,
    depth mode, publication profile, and topic surface.
  - Verify topic types, frame IDs, rates, depth values, point-cloud dimensions,
    camera info, TF, diagnostics, pause/seek/loop behavior, and clean exit.
  - Add an RViz2 configuration that displays rectified color, depth, and a
    colored point cloud without hard-coded recording filenames.
  - **Gate:** the complete local ROS topic and visualization contract works
    without claiming the physical cameras.

- [x] **T5 - prove the live virtual stereo pair locally.**
  - Confirm both physical cameras are `AVAILABLE` and no owner exists.
  - Launch the wrapper using the serial-number virtual API and NEURAL depth.
  - Confirm left/right orientation, virtual serial, calibration baseline,
    rectification, registered depth, point cloud, topic rates, and diagnostics.
  - Measure CPU/GPU use, memory, temperatures, dropped frames, topic bandwidth,
    and recent Argus/ZED errors for the conservative field profile.
  - Stop normally and confirm both cameras return to `AVAILABLE` without daemon
    restarts or reboot.
  - **Gate:** a bounded local live run opens, publishes, and releases the exact
    pair without an Argus timeout or camera-state regression.

- [ ] **T6 - establish deterministic same-LAN remote viewing.**
  - Provision the named Ubuntu 22.04 remote workstation with ROS 2 Humble,
    RViz2, required message/display packages, and no ZED SDK or CUDA.
  - Configure the same ROS domain and explicit network-interface choice.
  - Validate discovery, firewall behavior, and compressed subscriptions over
    wired LAN before Wi-Fi.
  - Display rectified color, registered depth, and colored point cloud using
    the repository RViz configuration.
  - Measure received rates, latency, loss, bandwidth, and Jetson load. Verify a
    clean remote disconnect/reconnect without restarting the camera node.
  - Exercise explicit DDS-peer/discovery fallback if multicast is unavailable.
  - **Gate:** the remote machine can view the required data with no VNC, no ZED
    SDK, and no internet connection.

- [ ] **T7 - prove field Wi-Fi and tune bounded publication profiles.**
  - Repeat the remote acceptance run on the actual field LAN/Wi-Fi equipment.
  - Tune publication rate, downscale factor, point-cloud resolution/frequency,
    compression, QoS, and DDS settings from measured results.
  - Preserve a conservative `field` profile and an optional higher-bandwidth
    `wired` profile; do not silently change native capture/depth resolution.
  - Verify that loss or reconnection does not accumulate stale reliable queues
    or destabilize the ZED/Argus pipeline.
  - **Gate:** each committed profile states measured rates and the network on
    which it passed.

- [ ] **T8 - integrate remote SVO2 playback without changing recording.**
  - Stop live ROS cleanly, make a short recording with the existing direct
    recorder, and validate/finalize it with `ZED_SVO_Editor -inf`.
  - Replay that SVO2 over ROS 2 and use the same remote RViz configuration.
  - Verify pause, seek, normal-speed playback, end-of-file behavior, and clean
    shutdown.
  - Treat rosbag as optional topic-level diagnostics only; document why it is
    not the master stereo recording.
  - **Gate:** a newly recorded field SVO2 can be remotely inspected without
    changing the known-good recording path.

- [ ] **T9 - finish offline documentation and acceptance.**
  - Add `docs/ROS2_REMOTE_VIEWING.md` with exact Jetson and remote copy/paste
    commands, topic/profile definitions, RViz operation, replay, discovery,
    recovery, and rollback.
  - Update `README.md`, `docs/SETUP.md`, and `docs/FIELD_GUIDE.md` only with
    interfaces that have passed their gates.
  - Extend verification to report ROS/wrapper/config state without requiring a
    camera launch or network mutation.
  - Inventory and checksum offline installers, package manifests, source
    archives, RViz configuration, and scripts for both architectures.
  - Perform a no-internet field rehearsal: cold boot, verify, live remote view,
    disconnect/reconnect, clean camera release, direct record, validate SVO2,
    remote replay, and final camera availability check.
  - Run shell syntax checks, repository tests, checksum checks, Markdown link
    checks, and `git diff --check`.
  - **Gate:** another operator can reproduce live and recorded remote viewing
    from repository documentation on the named hardware without internet.

## Acceptance summary

The line of work is complete only when all of the following are true:

- The exact virtual pair opens by serial number and reports virtual serial
  `116863460` with the installed calibration.
- Live and replay modes expose the same remotely consumed ROS topic contract.
- Remote RViz2 displays rectified color, depth, and a colored point cloud
  without ZED SDK, CUDA, VNC, cloud service, or internet on the remote machine.
- The field profile has measured bandwidth and stable received rates on the
  actual field network.
- Normal shutdown returns both cameras to `AVAILABLE` without restarting camera
  services or rebooting.
- The existing direct SVO2 recorder remains valid and unchanged as the master
  recording path.
- Offline installation, operation, recovery, and rollback are documented and
  rehearsed.
