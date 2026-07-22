# TASKS - Remote field console for the dual ZED X One rig

Ordered execution plan for controlling this Jetson-hosted calibrated virtual
stereo rig from the Ubuntu RViz workstation. The intended interface is one
viewer-side command that starts a view-only session, opens RViz, and provides
explicit keyboard controls for starting, finalizing, and validating SVO2
recordings on the Jetson.

This plan follows the project's all-caps rigor: establish observed facts in
READ, separate proposed conclusions in INFER, make failure containment explicit
in DE-RISK, and do not begin implementation until the approval gate is accepted.
The completed ROS 2 viewing plan is preserved at
`docs/archive/TASKS_ROS2_REMOTE_VIEWING_2026-07-21.md`.

## Execution status - 2026-07-21

| Task | Status | Evidence / remaining gate |
|---|---|---|
| READ | Complete | Repository, wrapper recording services, direct recorder, diagnostics, and current Jetson network were inspected. |
| INFER | Approved | User approved the proposed control/data split, lifecycle, keybindings, recording behavior, and network identity. |
| DE-RISK | Approved | User approved the recording integrity, camera ownership, disconnect, disk, discovery, and rollback gates. |
| T0 | Jetson complete; receiver pending | Transient user unit, lock/state/log paths, SSH fail-closed behavior, persistence guard, storage, and timeouts are proven. Receiver facts still require that machine. |
| T1 | Lossless passed; lossy rejected | Lossless produced 523 indexed frames and replayed with NEURAL depth. H.264/H.265 rejected every frame, including ULTRAFAST/async/no-IPC. |
| T2 | Complete | Jetson helper passed view, attach, refusal, recording, validation, stop, and camera-release gates. |
| T3 | Implemented; receiver retry pending | Actual receiver proved SSH/DDS/cold start, exposing exit-status, image-health, and q-cleanup bugs. All fixes now pass local acceptance; receiver must pull and repeat. |
| T4-T5 | Pending external networks | AsteraMesh receiver plus Mars/MarsLink topology and recovery tests require the viewing computer/networks. |
| T6 | In progress | Offline docs, help, and static checks are being finalized; cross-machine rehearsal remains pending. |

## Desired outcome

- From the Ubuntu viewing workstation, one command connects to the intended
  Jetson, starts or safely attaches to the calibrated live ROS session, opens
  the supplied RViz view, and leaves recording off by default.
- The same terminal presents unambiguous keybindings to start a new lossless
  SVO2, stop/finalize/save it, inspect status/storage, and close the complete
  session safely. Lossy quality choices remain disabled because they failed T1.
- The already-running ROS wrapper remains the only process that owns the two
  physical cameras while viewing and recording. Recording must not require a
  camera close/reopen transition.
- Recordings contain the synchronized full-resolution virtual-stereo inputs and
  are written on the Jetson under `/home/dusty/Videos/ZED/`; RViz remains a
  bandwidth-controlled preview and is not the recorded image source.
- A control disconnect, RViz crash, or Wi-Fi transition does not corrupt or
  silently stop an active Jetson-side recording. A later controller can report
  the existing session and attach to it.
- The controller works on AsteraMesh, Mars, or MarsLink by resolving a Jetson
  host identity. It does not encode an SSID as the destination.
- No VNC, cloud account, internet connection, boot-time camera service, driver
  restart, daemon restart, or calibration change is required in field use.
- The proven direct `record_virtual_stereo.sh` path remains available as the
  rollback recorder until in-process ROS recording passes every acceptance
  gate in this plan.

## READ

### Proven repository and rig boundary

- The repository was clean at `main` commit `1fc35f5`, tracking `origin/main`,
  when this planning read began.
- The physical-left serial is `304467158`, physical-right serial is
  `306605936`, and the calibrated virtual serial is `116863460`.
- The installed virtual calibration SHA-256 remains
  `0502a05ec12942b4f02c375793c1200c6bec1387b4368c744121cbf61da19ed6`.
- `scripts/start_ros2_virtual_stereo.sh` already opens that exact serial order
  with HD1200/15 FPS acquisition and NEURAL depth. It verifies calibration,
  refuses known camera owners, and runs in the foreground.
- `scripts/start_ros2_rviz.sh` already opens the body-frame RViz view and uses
  compressed color/depth transports plus a reduced point cloud.
- Local live acceptance measured RGB/depth/cloud at approximately
  `4.841/5.000/1.995 Hz`; normal shutdown returned both physical cameras to
  `AVAILABLE` without restarting a service.
- The current ROS profile publishes only a reduced preview. Native synchronized
  camera acquisition remains 1920x1200 at 15 FPS on the Jetson.

### Existing recording boundary

- `scripts/record_virtual_stereo.sh` and the custom SDK recorder are the proven
  recording path. They own the camera pair directly, so they cannot run at the
  same time as the ROS live publisher.
- The custom recorder checks SDK recording status on every grabbed frame,
  reports ingested/encoded counts, tolerates bounded startup rejection, stops
  after sustained write failure, calls `disableRecording()`, closes the camera,
  and reports the final file size.
- The measured lossless rate is approximately 56 MB/s, or 3.4 GB/minute.
  Lossy recording is smaller but alters the images later used for depth.
- A complete SVO2 is saved by finalizing the recording. There is no useful
  separate deferred "save" operation after stop.

### Pinned wrapper recording interface

- The installed wrapper is Stereolabs `v5.4.0`, commit
  `6545933af94d70922881654e6fb29d95e3a8f14f`, built against ZED SDK 5.4.0.
- The live node creates private services `~/start_svo_rec` and
  `~/stop_svo_rec`, which resolve for this launch as
  `/zed/zed_node/start_svo_rec` and `/zed/zed_node/stop_svo_rec`.
- `start_svo_rec` accepts bitrate, compression mode, target frame rate, input
  transcode, and the Jetson-side output filename. It rejects a second active
  recording and rejects recording while an SVO is being replayed.
- The implementation accepts bitrate `0` or `1000..60000`, maps compression
  values to H.264, H.264 lossless, H.265 lossless, generic lossless, or H.265,
  and accepts target frame rates including 15 FPS.
- The installed `StartSvoRec.srv` comment says compression is limited to
  `[0,2]`, while the pinned wrapper implementation explicitly accepts `[0,5]`.
  That disagreement is observed evidence and prevents treating any untested
  numeric preset as authoritative.
- `stop_svo_rec` calls the SDK stop/finalization path and returns success or an
  error message. It refuses stop when recording is not active.
- During live recording the wrapper checks SDK recording status each frame and
  reports `SVO Recording: ACTIVE`, `ERROR`, or `NOT ACTIVE` through ROS
  diagnostics. The wrapper's `SvoStatus` topic describes SVO playback, not
  live recording, so it is not a sufficient recording-state interface.
- The remote package manifest does not currently install `ros-humble-zed-msgs`.
  Recording control can therefore avoid a new remote message dependency by
  invoking the ROS services locally on the Jetson through authenticated SSH.

### Current control and network facts

- The Jetson hostname is currently `ubuntu`; Avahi and SSH are active, and
  `ubuntu.local` resolves locally.
- At this read the Jetson is connected to Wi-Fi connection `AsteraMesh` on
  interface `wlP1p1s0` with dynamic address `192.168.20.45/24`.
- `192.168.20.45` is an observed current lease, not a stable field identity and
  must not be embedded as a permanent destination.
- Planned field networks are AsteraMesh, Mars, and possibly MarsLink. Whether
  Mars and MarsLink are one broadcast domain, separate subnets, or subject to
  client isolation has not been measured.
- ROS 2 currently uses domain `42`, Cyclone DDS, automatic interface selection,
  and multicast-default discovery. SSH requires only routability; RViz data
  additionally requires working DDS discovery and transport.
- The receiving workstation's hostname, OS build, architecture, repository
  location, SSH key state, firewall, and interfaces have not yet been captured.

## INFER

- SSH should be the authenticated control plane. It starts/stops the Jetson
  session and invokes recording services on the Jetson. ROS 2 remains the
  color/depth/point-cloud data plane.
- The workstation should target a stable logical host such as an SSH alias
  `zed-jetson`, defaulting initially to `dusty@ubuntu.local` with an explicit
  `--jetson USER@HOST` override. The script should display the resolved address
  and fail closed on an unknown SSH host key.
- SSID names should be reported for diagnostics but must not select the target
  or encode IP addresses. A DHCP reservation on the Mars router is desirable
  after its topology is known, but not required for the first implementation.
- The Jetson live node should run as a named transient per-user systemd unit,
  not as a permanent or boot-enabled service. This gives exact ownership,
  logs, idempotent status, and `SIGINT` shutdown without broad process killing.
- The controller needs an explicit state machine:
  `DISCONNECTED -> STARTING -> VIEWING -> RECORDING -> FINALIZING -> VIEWING -> STOPPING`.
  Unsupported transitions must be rejected rather than guessed.
- Starting the console must always enter `VIEWING`; it must never start a
  recording automatically or resume recording merely because a preset was
  selected.
- Recording quality and preview bandwidth are different controls. T1 proved
  only generic lossless recording. H.264 and H.265 both rejected every frame,
  including H.264 with ULTRAFAST encoding, asynchronous image retrieval, and
  IPC disabled. The field UI must therefore expose only `lossless`; preview
  bandwidth remains a launch profile because changing it may restart the node.
- `r` should create a timestamped temporary SVO2 name on the Jetson and call
  the start service. `s` should stop/finalize, validate the file, and only then
  promote it to its final filename. The terminal should show a persistent red
  recording state, selected preset, elapsed time, path, and free space.
- A workstation or network disconnect should leave the named Jetson session
  and any active recording running. Reconnection should attach to the existing
  state rather than opening the cameras a second time.
- Clean `q` should stop/finalize an active recording first, validate it, close
  RViz and its transport helpers, then send `SIGINT` to the exact transient
  Jetson unit and confirm both cameras return to `AVAILABLE`.
- Closing RViz alone should not terminate or finalize a recording. The terminal
  controller remains the authoritative lifecycle UI.
- The proven direct recorder remains the field fallback until in-process ROS
  recordings match its integrity checks and replay successfully.

## DE-RISK

- **Approval boundary:** before this gate is approved, do not add scripts,
  install packages, create units, call a recording service, alter SSH/network
  configuration, or open the cameras for this line of work.
- **Driver/Argus boundary:** do not install, rebuild, reload, replace, or
  restart JetPack/L4T, the GMSL driver, ZED SDK, `nvargus-daemon`, or
  `zed_x_daemon`. A controller failure is not evidence of a camera-driver fault.
- **Calibration boundary:** retain exact serial order and verify virtual
  calibration checksum before live launch. Never write physical-camera factory
  calibration files.
- **Service-contract risk:** treat the compression-mode metadata disagreement
  as unresolved. Probe candidate modes with short recordings; record the actual
  codec, service response, diagnostics, frame count, file size, and replay
  result before assigning a preset name.
- **Recording-integrity risk:** start with 10-20 second bounded recordings.
  Require `SVO Recording: ACTIVE`, file growth, successful stop response,
  nonzero indexed frames from `ZED_SVO_Editor -inf`, correct virtual serial,
  successful replay, and expected left/right orientation.
- **Finalization risk:** never kill the wrapper while recording. `q`, signals,
  and error cleanup must call stop/finalize and wait with a bounded timeout.
  If finalization cannot be confirmed, preserve the temporary file, report its
  exact path, and do not label it valid.
- **Storage risk:** check the output directory, write permission, free bytes,
  and a configurable reserve before start. Show estimated remaining minutes
  using measured per-preset rates. Monitor diagnostics and file growth; stop
  safely on sustained SDK write errors rather than filling the disk silently.
- **Camera-ownership risk:** take a Jetson-side lock before starting the
  transient unit. If another known owner exists, print its exact PID/command
  and refuse. If the named unit already owns the pair, offer attach/status;
  never use `pkill`, kill by name, or terminate an unrelated process.
- **Duplicate-controller risk:** serialize recording commands Jetson-side and
  make start/stop idempotent. A second workstation must see the current owner
  and state; it must not create a second session or recording.
- **Disconnect risk:** test SSH loss during view and during recording. The
  Jetson must continue safely, retain logs/state, accept reconnection, and
  finalize later. A clean user exit remains distinct from a transport loss.
- **State-observability risk:** do not rely only on the playback-oriented
  `SvoStatus` topic. Reconcile service responses, Jetson-side session state,
  wrapper diagnostics, file existence/growth, and transient-unit status.
- **Network-discovery risk:** prove SSH and DDS separately. Test multicast on
  each network and add a scoped Cyclone DDS peer fallback when necessary.
  Never respond to DDS failure by restarting Argus or changing calibration.
- **Addressing/security risk:** require SSH keys and normal host-key checking;
  never embed a password or disable `StrictHostKeyChecking`. ROS 2 Humble DDS
  traffic is not authenticated by this design, so operate only on trusted LANs
  or add DDS security as a separately approved scope.
- **Performance risk:** measure live view rates and recording health together
  for every accepted preset. Reject a preset that destabilizes acquisition,
  depth publication, thermals, or storage even if the output file finalizes.
- **UI risk:** single-key actions must be visible and state-dependent. Quality
  cannot change mid-recording; stop/save cannot report success before SDK
  finalization and validation; destructive deletion is out of scope.
- **System-mutation risk:** any systemd use is transient and per-user. Do not
  add a boot-enabled system service, modify camera services, or change network
  profiles automatically.
- **Rollback:** retain the current live/RViz launchers and direct recorder.
  Removing the new controller must restore the current topology without
  uninstalling ROS, changing calibration, or touching camera daemons.

## Settled decisions pending approval of this gate

- Proposed viewer command: `scripts/zed_field_console.sh` with full copy/paste
  examples in `--help`.
- Default target: SSH alias `zed-jetson` when configured, otherwise an explicit
  `--jetson dusty@ubuntu.local`; no SSID-specific destination logic.
- Control plane: SSH. Data plane: ROS 2 domain 42 with Cyclone DDS.
- Jetson lifecycle: one named transient per-user unit, never boot-enabled.
- Initial state: view-only. Recording always requires an explicit `r` key.
- Revised key contract after T1: `r` start lossless; `s` stop/finalize/save;
  `i` status/storage/path; `v` reopen RViz; `h` help; `q` finalize if needed
  and close the complete session safely.
- Active recordings survive loss of RViz, the controller, or the network.
- `lossless` is the only accepted recording preset. H.264/H.265 controls are
  deliberately unavailable rather than producing corrupt or zero-frame files.
- Recording files live on the Jetson. No automatic file transfer or deletion
  is included in this first line of work.
- Preview quality is a launch profile, not a mid-recording keybinding.
- The direct SDK recorder remains the authoritative fallback until the final
  acceptance gate passes.

## Ordered tasks

- [x] **APPROVAL GATE - accept READ / INFER / DE-RISK and settled decisions.**
  - Approved by the user on 2026-07-21.
  - Resolve any rejected inference or safety behavior in this file first.
  - Do not implement or run an in-process recording test before approval.

- [ ] **T0 - freeze the receiver, SSH, network, and lifecycle contract.**
  - Capture the intended workstation's Ubuntu version, architecture, hostname,
    interfaces, current SSID/address, firewall, repository path, ROS version,
    and installed receiver packages.
  - Verify key-based SSH, normal host-key verification, `ubuntu.local`/alias
    resolution, noninteractive command execution, and the fixed Jetson repo path.
  - Observe AsteraMesh multicast, routing, and client isolation without changing
    the router. Record what remains unknown for Mars and MarsLink.
  - Specify the transient-unit name, lock, state file, log path, output directory,
    signal behavior, attach behavior, and bounded shutdown/finalization timeouts.
  - Current Jetson evidence is `Linger=no` plus an active local X11 session. The
    helper accepts that persistent session and otherwise requires the documented
    one-time `sudo loginctl enable-linger dusty` before it opens cameras.
  - **Gate:** both machines and every lifecycle transition have an explicit,
    reviewable identity before camera or recording tests.

- [x] **T1 - prove wrapper recording locally on the Jetson.**
  - Start the existing live ROS launcher with no remote controller and confirm
    view-only topics/rates first.
  - Inspect advertised service names and types at runtime.
  - For each candidate compression/bitrate combination, record 10-20 seconds at
    15 FPS to a unique temporary filename while RGB/depth/cloud subscribers run.
  - Observe diagnostics and file growth during recording; call stop and wait for
    the response before stopping the live node.
  - Validate virtual serial, indexed frames, resolution, FPS, duration, file
    size, replay, left/right orientation, and NEURAL depth generation.
  - Stop the node normally and confirm both cameras immediately return to
    `AVAILABLE` without a daemon restart.
  - **Gate result:** generic lossless passed with 523 indexed 1920x1200/15 FPS
    frames, virtual serial `116863460`, successful NEURAL RGB/depth/cloud replay
    at `4.836/4.371/2.054 Hz`, and clean shutdown. H.264 at default and 12 Mb/s
    and H.265 at default rejected every frame. ULTRAFAST H.264 with asynchronous
    retrieval and IPC disabled also failed. Scope is revised to lossless only.

- [x] **T2 - implement the Jetson-side session supervisor.**
  - Add a source-controlled helper that owns the exact transient unit, lock,
    state file, logs, recording-service calls, diagnostics checks, and validation.
  - Implement explicit `start`, `attach/status`, `record-start`, `record-stop`,
    and `stop` operations with machine-readable results and useful human output.
  - Use temporary recording names and promote only validated files. Preserve and
    report failed/incomplete files without deleting them.
  - Reject bad paths, insufficient free space, invalid presets, wrong node/service
    identity, replay mode, duplicate recording, and foreign camera ownership.
  - Ensure every stop path uses `SIGINT` on the exact unit after recording is
    finalized; verify camera release without restarting services.
  - **Gate:** helper state transitions and failure exits pass locally, including
    duplicate commands and simulated service/validation failures.
  - **Gate result:** `zed_field_session.sh` launched one named transient unit,
    attached idempotently, rejected simulated low space, rejected H.264, rejected
    a duplicate recording, reported `SVO Recording: ACTIVE`, finalized and
    validated 382 indexed frames (1,485,704,318 bytes), stopped with SIGINT,
    and returned both cameras to `AVAILABLE`. No camera daemon was restarted.

- [ ] **T3 - implement the one-command workstation console.**
  - Add `scripts/zed_field_console.sh` (or a small standard-library helper behind
    it) with full copy/paste `--help`, `--jetson`, and `--view-profile` examples.
  - Run SSH/network preflight, print resolved target and current network, start or
    attach to the Jetson session, verify ROS discovery/topics, then open RViz.
  - Implement the approved state-dependent keybindings and a continuously clear
    view/record/finalize/error indicator.
  - Keep the controller usable if RViz closes; allow RViz restart without touching
    the camera or active recording.
  - On clean `q`, finalize if necessary, close local helpers, stop the exact
    Jetson session, and print recording and camera-release results.
  - **Gate:** one workstation command can enter view-only mode and exit cleanly
    without recording, manual Jetson commands, VNC, or orphan processes.
  - **Implementation result:** the console and full copy/paste help are present.
    A simulated SSH target exercised view-only startup and `r/i/s/q` successfully;
    SSH host-key failure also failed closed without changing Jetson state. The
    first actual receiver cold start proved SSH and DDS but exposed a successful
    Jetson status being returned as failure; commit `ebcc1f9` corrected it. The
    next receiver run exposed blank image bridges, raw-cloud degradation, and q
    cleanup/input races. The revised launcher requires real RGB/depth/cloud
    messages and RViz subscriptions, uses Draco for the preview cloud, isolates
    the viewer process group, bounds shutdown, and prevents SSH from consuming
    terminal keys. Local acceptance reached the readiness gate on all three
    streams and the isolated group exited after SIGINT. The next receiver run
    showed `NO IMAGE` in both visible docks; live probing corrected the initial
    layout diagnosis. Native RGB/depth/cloud measured 5/5/2 Hz and compressed
    Jetson outputs measured 5/5/2 Hz, while the network receiver got no image
    samples. The common DDS profile allowed 65.5 KB UDP payloads across a
    1500-byte Wi-Fi MTU; measured samples were about 174 KB RGB, 60 KB depth,
    and 69 KB Draco. A Jetson-specific profile now caps initial and retransmit
    UDP payloads at 1400 bytes with 1344-byte DDSI fragments and unicast user
    data. The gate remains open until the actual receiver repeats visible
    images, recording, q, and orphan checks.

- [ ] **T4 - prove interactive recording and recovery on AsteraMesh.**
  - Exercise each accepted preset from the workstation while RViz displays all
    three required products. Verify remote key latency and state consistency.
  - Measure recording frame count/rate, size rate, preview rates, network traffic,
    Jetson CPU/GPU/memory/temperature/power, and SDK/Argus diagnostics.
  - Exercise: RViz close/reopen, SSH loss while viewing, SSH loss while recording,
    controller crash, duplicate controller, reconnect/attach, low-space refusal,
    stop timeout, and clean shutdown.
  - Confirm active recording continues across control loss and can later be
    finalized, validated, replayed, and found at the reported path.
  - **Gate:** the AsteraMesh workflow survives realistic operator and network
    failures without corrupting a validated recording or wedging camera ownership.

- [ ] **T5 - establish deterministic Mars and MarsLink operation.**
  - Record whether Mars and MarsLink share a subnet/broadcast domain and whether
    either enables AP/client isolation or suppresses multicast.
  - Establish a DHCP reservation or documented hostname/address mapping when the
    Mars router topology is final; do not silently alter router configuration.
  - Repeat SSH, DDS discovery, rates, disconnect/reconnect, record/finalize, and
    replay acceptance on every supported network.
  - Add and test a scoped Cyclone DDS peer fallback if multicast is unreliable;
    leave the camera stack unchanged.
  - **Gate:** each supported network has a named, measured connection procedure
    and no field command depends on guessing an SSID-derived address.

- [ ] **T6 - finish offline packaging, documentation, and release acceptance.**
  - Update README, setup, field guide, recorder guide, and ROS remote-viewing
    guide only with behavior that passed its gate.
  - Add exact one-time SSH-key/alias setup, normal operation, keybindings, preset
    measurements, output paths, attach/recovery, validation, replay, and rollback.
  - Ensure workstation dependencies and architecture-specific offline packages
    are cached; field operation must require no internet.
  - Run shell/static checks, repository tests, checksum checks, Markdown-link
    checks, dry-runs, and `git diff --check`.
  - Rehearse cold start to view-only, record/finalize, reconnect, replay, safe
    exit, camera availability, and direct-recorder rollback with internet absent.
  - **Gate:** another operator can run one workstation command and safely view,
    record, recover, and exit from the written field procedure alone.

## Acceptance summary

This line of work is complete only when all of the following are true:

- One workstation command starts or attaches to the correct Jetson and opens the
  calibrated view without starting a recording.
- Accepted keybindings start, visibly monitor, stop, finalize, validate, and
  report synchronized virtual-stereo SVO2 files on the Jetson.
- The shipped lossless preset has measured frame/file/replay evidence on this
  exact virtual pair; failed lossy numeric modes are not exposed.
- Active recording survives RViz, controller, and network loss and is recoverable
  from a second controller session.
- Clean exit finalizes first, stops only the owned transient unit, and returns
  both cameras to `AVAILABLE` without daemon restart or reboot.
- AsteraMesh and every supported Mars/MarsLink topology have passed SSH and DDS
  discovery, view, recording, recovery, and clean-shutdown acceptance.
- No password, static lease guess, disabled host-key check, VNC, cloud service,
  internet dependency, boot camera service, or camera-stack mutation is required.
- The existing direct recorder still works as a documented rollback path.
