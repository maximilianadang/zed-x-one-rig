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
| `r` | Start a new lossless SVO2 on the Jetson; return only after diagnostics and file growth pass. |
| `s` | Stop, finalize, validate, and promote the temporary SVO2 to its final name. |
| `i` | Print unit, ROS, recording, path, size, storage, and last-saved status. |
| `v` | Reopen local RViz without reopening cameras or changing recording. |
| `h` | Print the key reminder. |
| `q` | Finalize if necessary, stop the exact Jetson unit, close RViz, and confirm both cameras are available. |

These keys are read by the terminal controller. Focus the terminal—not the
RViz window—before pressing them. SSH control commands have stdin disabled so
they cannot consume a key intended for the controller.

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

The shipped RViz layout keeps controls at left, the point cloud in the center,
and visible RGB and Depth image docks stacked at right. If a prior RViz user
layout overrides or closes a dock, use RViz's **View** menu to re-enable `RGB`
and `Depth`, then press `v` in the field console to reload the shipped layout.

The LAN carries compressed RGB, compressed depth, and the wrapper's Draco
point-cloud transport. The workstation expands all three into ordinary local
ROS topics for RViz. On this rig the raw reduced point cloud measured about
974 KB/s, while Draco measured about 12-14 KB/s and decoded at the full 2 Hz
preview rate. This affects only visualization transport, never SVO2 contents.

Initial startup is accepted only after actual messages reach all three local
RViz topics and RViz has subscribed to them. If that health gate fails, the
console reports the local log and stops the new Jetson session instead of
leaving an orphaned camera owner.

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
- **RViz closes after a healthy startup:** focus the controller terminal and
  press `v`. Camera ownership and recording are unchanged.
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

Do not guess a static address from the SSID. AsteraMesh currently has a working
Jetson path, but receiver-side SSH/DDS acceptance and the Mars/MarsLink routing,
client-isolation, and multicast behavior must be measured on those networks.

## Offline playback on the viewing computer

The lightweight workstation does not open `.svo2` itself. The Jetson replays
the file through the same standard ROS topics, so the workstation still does
not need the ZED SDK:

```bash
# Jetson
./scripts/play_svo_ros2.sh /home/dusty/Videos/ZED/RECORDING.svo2

# Workstation
./scripts/start_ros2_rviz.sh
```

The playback launcher validates the SVO2 before opening it. Stop playback with
`Ctrl+C` on the Jetson. The interactive field console currently controls live
camera sessions; playback selection remains this explicit two-command path.

## Direct fallback

If SSH/DDS viewing is not required, stop the field session and use the proven
headless lossless recorder:

```bash
./scripts/record_virtual_stereo.sh --lossless
```

Wait for `Finalizing SVO2` after Ctrl+C. Low-level H.264/H.265 options remain
experimental and unvalidated on this exact virtual pair.
