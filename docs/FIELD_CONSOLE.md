# Remote Field Console

This is the normal no-VNC workflow for viewing and recording the calibrated
dual ZED X One rig from an Ubuntu 22.04 workstation on the same trusted LAN.
The Jetson owns the cameras and computes NEURAL depth. RViz displays standard
ROS 2 color, registered depth, and point-cloud topics. The synchronized native
stereo SVO2 is recorded and retained on the Jetson.

## Exact field command

From this repository on the viewing workstation:

```bash
cd /path/to/zed-x-one-rig
./scripts/zed_field_console.sh --jetson zed-jetson
```

If a dedicated alias has not been configured and `ubuntu.local` resolves to
the correct Jetson on that LAN:

```bash
./scripts/zed_field_console.sh --jetson dusty@ubuntu.local
```

On the current AsteraMesh lease, the fully explicit form is:

```bash
./scripts/zed_field_console.sh \
  --jetson dusty@192.168.20.45 \
  --remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig
```

`--remote-root` always names a directory on the Jetson. It is not the directory
where the command is being run on the viewing computer.

The console starts in **view-only** mode. It never starts recording merely
because the camera or RViz is open.

## Keys

| Key | Action |
|---|---|
| `r` | Start a new lossless SVO2 on the Jetson; return after the SDK accepts it and file growth passes. |
| `s` | Stop, finalize, validate, and promote the temporary SVO2 to its final name. |
| `i` | Run a detailed ROS health probe and print unit, recording, path, size, storage, and last-saved status. |
| `v` | Reopen local RViz without reopening cameras or changing recording. |
| `h` | Print the key reminder. |
| `q` | Finalize if necessary, stop the exact Jetson unit, close RViz, and confirm both cameras are available. |

These keys are read by the terminal controller. Focus the terminal—not the
RViz window—before pressing them. SSH control commands have stdin disabled so
they cannot consume a key intended for the controller.

While the controller is running, its last two terminal rows are a persistent
status-and-key footer. Periodic state changes redraw those rows in place instead
of appending status lines to the terminal. Command results remain above the
footer as useful scrollback. Terminal echo stays disabled for the entire control
session, including while a remote start, save, or health check is running, so a
queued key cannot be printed in the middle of command output. Normal terminal
settings are restored on `q`, `Ctrl+C`, failure, or ordinary process exit.

The first footer row is a prominent state indicator. Green `○ VIEW ONLY` means
the cameras are live but no SVO2 is being written. Bold red `● REC` means the
SDK-confirmed recording file is active; beside it, the console refreshes elapsed
time, total bytes saved in decimal MB/GB, the rolling decimal MB/s write rate,
RViz state, and the active filename once per second. Yellow indicates an
unconfirmed recording or disconnected control path. The write rate comes from
the change in the actual Jetson-side file size, not an assumed preset bitrate.

The controller reuses one multiplexed SSH connection and its automatic status
line reads only the Jetson unit and saved session state. It does not launch ROS
discovery in the keyboard loop. Pressing `i` deliberately performs the deeper
live ROS graph check, so that one command can take a few seconds if DDS is slow.
The `r` command also waits about five seconds to prove that the SVO2 is growing;
`s` waits for finalization and validation. Both acknowledge the key immediately,
so those safety checks should not feel like a missed keystroke.

`Ctrl+C`, a closed laptop, lost Wi-Fi, a dead SSH connection, or an RViz crash
does **not** stop the Jetson session or an active recording. This is deliberate:
it avoids corrupting a capture because its control connection disappeared.
Reconnect with the same field command; it attaches to the named session. Press
`i` to inspect it and `s` to finalize an active recording.

## One-time workstation setup while online

The viewing computer needs Ubuntu 22.04, this repository, ROS 2 Humble,
Cyclone DDS, RViz2, image transports, and point-cloud transports. It does not need the ZED SDK,
CUDA, or VNC.

```bash
cd /path/to/zed-x-one-rig
./scripts/install_ros2_remote.sh
```

The installer retains downloaded packages under the architecture-specific
`offline/ros2/remote-ARCH/debs/` directory. Before field deployment, run the
online installation once and keep the populated repository on the workstation.

Set up normal key-based SSH from the workstation. Reuse an existing Ed25519
key if present; do not overwrite it:

```bash
test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
ssh-copy-id dusty@JETSON_ADDRESS
ssh dusty@JETSON_ADDRESS true
```

The final command records and verifies the Jetson host key. Do not disable
`StrictHostKeyChecking`. Confirm an unexpected fingerprint out of band before
accepting it.

For consistent use across AsteraMesh, Mars, and MarsLink, create a workstation
SSH alias after the router address or mDNS identity is known:

```sshconfig
Host zed-jetson
    HostName JETSON_ADDRESS_OR_UNAMBIGUOUS_MDNS_NAME
    User dusty
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Then prove noninteractive operation:

```bash
ssh -o BatchMode=yes zed-jetson true
./scripts/zed_field_console.sh --jetson zed-jetson --status
```

On the Jetson, enable the per-user manager to remain alive when no desktop or
SSH login exists:

```bash
sudo loginctl enable-linger dusty
loginctl show-user dusty -p Linger
```

Expected: `Linger=yes`. This does not install, enable, or start a camera service;
it only permits explicitly created user units to survive logout. The session
helper also accepts an active local desktop/console session, as on the current
Jetson, but fails before opening cameras if neither condition is true.

`ubuntu.local` is a generic name and may resolve to the wrong interface or
another Ubuntu host. The console prints resolver results but does not treat
them as trusted identity. A dedicated alias backed by a router DHCP reservation
is preferred after the Mars/MarsLink topology is finalized.

## Recording contract

- Native file: virtual stereo serial `116863460`, 1920x1200, 15 FPS.
- Left: physical serial `304467158`; right: `306605936`.
- Compression: generic SDK lossless PNG/ZSTD only.
- Location: `/home/dusty/Videos/ZED/virtual_stereo_YYYYMMDD_HHMMSS.svo2`.
- Temporary active name: the same basename ending in `.recording.svo2`.
- Reserve: recording is refused below 20 GiB free.
- Conservative planning rate: 60 MB/s. Status estimates remaining whole
  lossless minutes above the reserve; actual scene content changes the rate.

H.264 and H.265 are deliberately absent from the field console. On 2026-07-21,
the wrapper accepted their start requests but the SDK rejected every frame.
This also occurred with H.264 ULTRAFAST, asynchronous image retrieval, and IPC
disabled. Generic lossless produced 523 indexed frames in the mode test and
382 indexed frames through the finished supervisor. Both files reported the
correct virtual serial and native mode; the first replayed through NEURAL ROS
depth at the expected field rates.

The reduced 960x600/5 Hz images and reduced 2 Hz point cloud shown in RViz are
preview products only. They are not what the SVO2 records. The SVO2 preserves
the synchronized native stereo images so depth can be recomputed later.

Recording startup is accepted when the ZED SDK service returns success and the
temporary SVO2 has a positive size that continues growing across the five-second
check. That direct storage evidence is authoritative. The aggregate ROS
`/diagnostics` topic is not used as a startup gate because a one-shot diagnostic
sample can omit the SVO status and report `UNKNOWN` while the SDK is actively
writing valid frames. `s` still performs strict SVO2 metadata and frame-count
validation before giving the file its final `.svo2` name.

The shipped RViz layout keeps controls at left, the point cloud in the center,
and visible RGB and Depth image docks stacked at right. If a prior RViz user
layout overrides or closes a dock, use RViz's **View** menu to re-enable `RGB`
and `Depth`, then press `v` in the field console to reload the shipped layout.

The LAN carries compressed RGB, compressed depth, and the wrapper's Draco
point-cloud transport. RViz subscribes directly to the wrapper's compressed
RGB and compressed-depth topics. One workstation helper expands Draco into an
ordinary local `PointCloud2`, because this Humble RViz PointCloud2 display does
not consume `point_cloud_transport` directly. On this rig the raw reduced point
cloud measured about 974 KB/s, while the current scene's Draco stream measured
about 140 KB/s and decoded at the full 2 Hz preview rate. Draco size varies with
scene content. This affects only visualization transport, never SVO2 contents.

The Jetson camera publisher uses `config/ros2/cyclonedds-jetson.xml`, which
caps UDP payloads at 1400 bytes on the 1500-byte field-LAN MTU. Cyclone DDS then
fragments the roughly 174 KB RGB, 60 KB depth, and 69 KB Draco samples at the
DDS layer, where lost pieces can be retransmitted, instead of relying on fragile
IP fragmentation. The workstation retains the general Cyclone profile because
its expanded image topics travel only between local processes.

Before opening RViz, the console confirms that all three source topics are
discoverable. Keyboard controls activate as soon as the RViz process and
window are stable. It does not subscribe to a second copy of the
high-bandwidth streams merely to test them. The operator verifies actual frame
delivery directly in the visible RGB, depth, and point-cloud panes; degraded
preview does not kill a usable viewer or disable recording controls.

Older revisions used separate `ros2 topic echo` subscribers as an acceptance
gate. That duplicated full RGB and depth traffic and could time out on a
marginal LAN even while RViz visibly displayed live data. The parent timeout
then stopped the otherwise healthy session before keyboard controls appeared.
Current revisions treat a living RViz window as ready and leave visual frame
delivery for the operator to confirm directly.

## Status, attach, and safe stop without RViz

From the workstation:

```bash
./scripts/zed_field_console.sh --jetson zed-jetson --status
./scripts/zed_field_console.sh --jetson zed-jetson --stop
```

Run the controller without an RViz window, while retaining recording keys:

```bash
./scripts/zed_field_console.sh --jetson zed-jetson --no-rviz
```

On the Jetson itself, the equivalent recovery commands are:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/zed_field_session.sh status
./scripts/zed_field_session.sh logs
./scripts/zed_field_session.sh record-stop
./scripts/zed_field_session.sh stop
```

Never kill the ROS wrapper while it reports an active recording. Use
`record-stop` so the SDK can write the frame index and close the SVO2.

## What failures mean

- **SSH/host-key failure:** control is unavailable. The Jetson session is not
  changed. Correct the hostname, route, key, or known-host discrepancy.
- **SSH works but the helper is missing:** keep the local viewing-computer path
  unchanged and pass the Jetson path explicitly with
  `--remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig`.
- **SSH works but ROS topics are missing:** the camera may be fine. Check ROS
  domain 42, Cyclone DDS, workstation firewall, AP/client isolation, and LAN
  multicast. The console leaves the Jetson session running.
- **Startup stops at `Running as unit`:** older revisions queried discovery
  through a persistent ROS 2 CLI daemon. After moving between SSIDs, that
  daemon could remain bound to the previous address even though the ZED node
  had opened normally. Current revisions stop the stale daemon, use direct DDS
  discovery, print a bounded 90-second readiness wait, and show the preserved
  unit log before cleaning up a failed start. Pull the current repository on
  both machines.
- **RViz closes after a healthy startup:** focus the controller terminal and
  press `v`. Camera ownership and recording are unchanged.
- **RViz is live but controls have not appeared:** pull the current repository
  on the workstation. Older revisions blocked the terminal behind duplicate
  high-bandwidth message probes. In current revisions, controls appear as soon
  as the RViz window is stable.
- **Low-space refusal:** move or archive data from `/home/dusty/Videos/ZED/`;
  do not bypass the reserve casually.
- **Temporary `.recording.svo2` remains:** finalization or validation was not
  confirmed. The helper preserves it and does not label it valid. Inspect
  status and logs before touching the process or file.
- **Named unit is already active:** normal attach is safe only when its stored
  profile matches the requested profile. A mismatch is rejected.

The field console never restarts Argus, the ZED daemon, the GMSL driver, or the
Jetson. DDS or SSH problems are not camera-driver evidence.

## Network checks

SSH is the control plane; ROS 2 DDS is the data plane. They can fail
independently. On both machines, the field scripts use ROS domain `42` and
Cyclone DDS. If control works but RViz discovery does not, test:

```bash
# Workstation
source /opt/ros/humble/setup.bash
export ROS_DOMAIN_ID=42
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 multicast receive

# Jetson, in a second terminal
source /opt/ros/humble/setup.bash
export ROS_DOMAIN_ID=42
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 multicast send
```

Before changing AsteraMesh, Mars, or MarsLink, press `q` or use `--stop` and
wait for both cameras to return to `AVAILABLE`. A detached/orphaned camera
publisher cannot migrate its DDS participant to a new IP. Then move both
machines to the new SSID, wait for each to receive its new address, and rerun
the field command. On a new launch, the Jetson helper resets its persistent
ROS 2 CLI daemon automatically because a daemon started on the old address
cannot migrate either. The new camera publisher and RViz processes select the
current interface.

Internet access is not required for live control, preview, or recording once
the offline setup is installed. Lack of WAN access is distinct from local
multicast/client-isolation behavior.

Do not guess a static address from the SSID. AsteraMesh currently has a working
Jetson path, but receiver-side SSH/DDS acceptance and the Mars/MarsLink routing,
client-isolation, and multicast behavior must be measured on those networks.

## Offline playback on the viewing computer

The lightweight workstation does not open `.svo2` itself. The Jetson replays
the file through the same standard ROS topics, so the workstation still does
not need the ZED SDK. From the workstation, browse and select a finalized file:

```bash
./scripts/zed_replay_console.sh --jetson zed-jetson
```

Use `--list`, `--index N`, or `--svo /absolute/jetson/path.svo2` to select an
older file; use `--latest` to skip the default interactive directory. Replay
starts paused at frame zero and provides local keys for
play/pause, forward-one-frame, speed, dataset selection, RViz reopen, and safe
shutdown. Right Arrow advances sequentially without seeking. Backward seeking
and time scrubbing remain disabled because the ZED wrapper did not provide
usable seek latency under this rig's NEURAL replay load. The playback launcher
validates the SVO2 before opening it. See
`docs/REMOTE_REPLAY.md` for the complete offline workflow.

## Direct fallback

If SSH/DDS viewing is not required, stop the field session and use the proven
headless lossless recorder:

```bash
./scripts/record_virtual_stereo.sh --lossless
```

Wait for `Finalizing SVO2` after Ctrl+C. Low-level H.264/H.265 options remain
experimental and unvalidated on this exact virtual pair.
