# RUNBOOK - Current operational ZED X One field protocol

This is the authoritative operating and rollback procedure for the calibrated
dual ZED X One GS rig as it works today. Follow it when the Jetson has no
monitor and an Ubuntu 22.04 workstation provides the RViz view and controls.

The planned browser viewer is additive. Until its acceptance gates pass, it
must not replace, remove, or silently change any command or contract in this
runbook.

## Fixed rig contract

| Item | Operational value |
|---|---|
| Physical left | ZED X One GS serial `304467158` |
| Physical right | ZED X One GS serial `306605936` |
| Virtual stereo | Serial `116863460` |
| Native acquisition | 1920x1200 at 15 FPS |
| Depth | `NEURAL` |
| RGB preview | 960x600 at 5 Hz |
| Registered-depth preview | 960x600 at 5 Hz |
| Point-cloud preview | `REDUCED` at 2 Hz |
| Recording | Lossless synchronized SVO2, 1920x1200 at 15 FPS |
| Recording directory | `/home/dusty/Videos/ZED/` on the Jetson |
| ROS domain | `42` |
| Middleware | Cyclone DDS |
| Jetson repository | `/home/dusty/workspace/terraforming_mars/zed-x-one-rig` |

The preview is not the recording source. Reduced preview quality never changes
the synchronized native frames retained in SVO2.

## Non-negotiable safety rules

- Only one process may own the cameras. Live ROS viewing/recording, the direct
  recorder, calibration, ZED GUI tools, and Media Server are mutually
  exclusive.
- Never move, nudge, reseat, or hot-plug a camera, GMSL cable, ribbon, capture
  card, or connector while a camera application is open.
- Stop/finalize recording normally before stopping ROS, disconnecting power, or
  changing camera tools.
- Do not use `pkill`, broad process-name kills, or forced unit termination for
  ordinary operation.
- Do not restart Argus, the ZED daemon, the GMSL driver, or the Jetson to solve
  SSH, DDS, RViz, or browser problems.
- Do not modify serial order or `/usr/local/zed/settings/SN116863460.conf`.
- Use only the proven generic lossless recording mode. H.264 and H.265 rejected
  every frame in bounded tests on this virtual rig, even though the low-level
  recorder still exposes experimental switches.
- A file ending in `.recording.svo2` is not a confirmed finalized recording.
  Preserve it and inspect session status before touching the process or file.

## Before field deployment

Update the repository on both the Jetson and Ubuntu workstation while internet
is available, and confirm that both report the same revision:

```bash
cd /path/to/zed-x-one-rig
git pull --ff-only
git rev-parse --short HEAD
```

On the Jetson, verify the installed camera/ROS setup without opening cameras:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/verify_ros2_setup.sh
```

The Jetson should use a persistent per-user manager so an SSH or workstation
disconnect cannot destroy its transient camera session:

```bash
sudo loginctl enable-linger dusty
loginctl show-user dusty -p Linger
```

Expected: `Linger=yes`.

The workstation must already have the offline ROS/RViz receiver installed and
its package cache retained:

```bash
./scripts/install_ros2_remote.sh
```

Configure and verify a dedicated SSH alias rather than depending on a changing
SSID address:

```sshconfig
Host zed-jetson
    HostName JETSON_ADDRESS_OR_UNAMBIGUOUS_MDNS_NAME
    User dusty
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

```bash
ssh -o BatchMode=yes zed-jetson true
./scripts/zed_field_console.sh --jetson zed-jetson --status
```

Do not disable SSH host-key verification. `ubuntu.local` is an acceptable
explicit fallback only after confirming that it resolves to this Jetson:

```bash
./scripts/zed_field_console.sh --jetson dusty@ubuntu.local --status
```

## Normal live view and recording

Run this from the repository on the Ubuntu viewing workstation:

```bash
cd /path/to/zed-x-one-rig
./scripts/zed_field_console.sh --jetson zed-jetson
```

If an alias has not been configured:

```bash
./scripts/zed_field_console.sh \
  --jetson dusty@ubuntu.local \
  --remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig
```

The console starts **view-only**. RViz should show rectified RGB, registered
depth, and the colored point cloud. Its fixed frame is `zed_camera_link`: X
forward, Y left, Z up. The grid is the XY plane through the camera origin, not
an estimated ground plane.

### Outdoor exposure profile

For bright sky and exposure-limited dust plumes:

```bash
./scripts/zed_field_console.sh --jetson zed-jetson --outdoor
```

Confirm `[OUTDOOR]` in the terminal footer. This retains all fixed rates,
resolution, calibration, NEURAL depth, and lossless recording behavior. It
caps automatic exposure at 8 ms and applies approximately -0.4 EV compensation.

Stop the current session before switching between standard and outdoor
profiles. A running session with a different stored profile is rejected rather
than altered.

### Live controls

Focus the terminal, not RViz:

| Key | Action |
|---|---|
| `r` | Start lossless recording and verify file growth. |
| `s` | Stop, finalize, validate, and save the active SVO2. |
| `i` | Show detailed ROS, recording, storage, path, and session status. |
| `v` | Reopen RViz without reopening cameras or changing recording. |
| `h` | Show control help. |
| `q` | Finalize if necessary, stop the exact Jetson unit, close RViz, and confirm camera release. |

Expected footer states:

- Green `○ VIEW ONLY`: cameras are active; recording is off.
- Red `● REC`: lossless recording is active. Duration, saved bytes, measured
  write rate, RViz state, and filename update in place.
- Yellow: recording or control state is not confirmed; press `i`.

Starting a recording deliberately takes about five seconds because the helper
requires actual file growth. Saving waits for SDK finalization and metadata
validation. Do not interpret those checks as a missed keypress.

## Recording contract

- Output:
  `/home/dusty/Videos/ZED/virtual_stereo_YYYYMMDD_HHMMSS.svo2`.
- Active temporary output uses `.recording.svo2`.
- Recording is refused below the 20 GiB free-space reserve.
- Budget approximately 60 MB/s, or about 3.6 GB/minute; scene content changes
  the actual rate.
- A final file is accepted only after it reports the correct virtual serial,
  1920x1200 resolution, 15 FPS, lossless compression, and a nonzero frame count.

Inspect a finalized file on the Jetson:

```bash
ZED_SVO_Editor -inf /home/dusty/Videos/ZED/RECORDING.svo2
```

Never remove power before the console reports finalization and validation.

## Disconnect and reconnect

`Ctrl+C`, terminal closure, RViz failure, workstation sleep, SSH loss, or Wi-Fi
loss intentionally leaves the Jetson session and an active recording running.

Reconnect with the same live command:

```bash
./scripts/zed_field_console.sh --jetson zed-jetson
```

Then press `i`. If recording is active, use `s` to finalize it. Only `q` or
`--stop` requests complete remote shutdown.

Status or safe stop without opening RViz:

```bash
./scripts/zed_field_console.sh --jetson zed-jetson --status
./scripts/zed_field_console.sh --jetson zed-jetson --stop
```

Keep recording controls but omit RViz:

```bash
./scripts/zed_field_console.sh --jetson zed-jetson --no-rviz
```

## Changing field networks

Before moving between AsteraMesh, Mars, or MarsLink:

1. Press `s` if recording.
2. Press `q` and wait for both cameras to return to `AVAILABLE`.
3. Move both machines to the new network.
4. Wait for both to receive addresses.
5. Verify SSH identity.
6. Run a new field-console command.

Do not carry a live ROS/DDS session across a network change. Its DDS
participant remains bound to the interface/address selected at startup even
when SSH becomes reachable again.

If a workstation disconnect orphaned the old session, SSH to the Jetson and use
the Jetson-side recovery procedure below before relaunching on the new network.

## Jetson-side recovery

These commands are safe over SSH and do not require RViz:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/zed_field_session.sh status
./scripts/zed_field_session.sh logs
```

If status reports an active recording:

```bash
./scripts/zed_field_session.sh record-stop
```

Then stop the owned live session:

```bash
./scripts/zed_field_session.sh stop
```

Verify release:

```bash
ZED_Explorer --all
```

Both serials `304467158` and `306605936` must report `AVAILABLE`.

If finalization is ambiguous, preserve the temporary file, leave the state
files intact, and inspect logs. Never kill the wrapper while it may still be
recording.

## Remote replay

Stop the live session before replay. From the Ubuntu workstation:

```bash
./scripts/zed_replay_console.sh --jetson zed-jetson
```

The interactive list is newest first. Use Up/Down and Enter, or type a dataset
number and press Enter. Direct selection is also available:

```bash
./scripts/zed_replay_console.sh --jetson zed-jetson --latest
./scripts/zed_replay_console.sh --jetson zed-jetson --list
./scripts/zed_replay_console.sh --jetson zed-jetson --index 3
./scripts/zed_replay_console.sh --jetson zed-jetson \
  --svo /home/dusty/Videos/ZED/RECORDING.svo2
```

### Replay controls

| Key | Action |
|---|---|
| `Space` or `p` | Play or pause. |
| `Right Arrow` | Advance one sequential frame while paused. |
| `Up` / `Down`, or `+` / `-` | Change speed from 0.1x through 5x. |
| `o` | Open the dataset list and switch recordings. |
| `i` | Show detailed replay status. |
| `v` | Reopen RViz without seeking. |
| `h` | Show controls. |
| `q` | Stop the exact replay unit and close RViz. |

Backward and arbitrary time seeking are intentionally unavailable. An observed
one-second backward request took 11.5 seconds and could block the playback
pipeline. Reopen the dataset and play or step forward instead.

Replay disconnects follow the same survival rule as live sessions. Reattach
with the same command, or inspect/stop without RViz:

```bash
./scripts/zed_replay_console.sh --jetson zed-jetson --status
./scripts/zed_replay_console.sh --jetson zed-jetson --stop
```

Replay uses the Jetson GPU and installed calibration to recompute NEURAL depth.
The viewing workstation never opens the SVO2 and does not need the ZED SDK.

## Direct-recorder fallback

Use this only after stopping live ROS, replay, calibration, and every ZED GUI:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/record_virtual_stereo.sh --lossless
```

Recording begins immediately without a preview. Press `Ctrl+C` and wait for
`Finalizing SVO2` plus the saved-file message before closing the terminal or
removing power.

Do not use `--preview`, `--h264`, or `--h265` in the field. Those low-level
options remain experimental on this exact virtual pair and are not part of the
proven protocol.

## Failure interpretation

- **SSH fails:** correct routing, host identity, host key, or SSH key. Camera
  state is unchanged.
- **SSH works but repository/helper is missing:** pass the exact Jetson
  `--remote-root`; do not change the workstation path.
- **RViz does not open:** the Jetson session may still be healthy. Reconnect,
  press `i`, or use `--status`.
- **RGB/depth say `NO IMAGE`:** inspect ROS domain 42, Cyclone DDS, receiver
  packages, firewall, LAN multicast/client isolation, and whether both machines
  changed networks. Do not restart camera daemons.
- **Point cloud is present but images lag/freeze:** treat it as DDS/network
  delivery first. The configured preview rates are deliberately 5/5/2 Hz.
- **Low-space refusal:** archive data from `/home/dusty/Videos/ZED/`; do not
  bypass the reserve without a separate decision.
- **`.recording.svo2` remains:** finalization or validation is unresolved. Use
  status and logs; do not rename it manually.
- **Profile mismatch:** stop the current session and relaunch with the intended
  standard or outdoor profile.
- **Camera reports unavailable after a confirmed stop:** inspect the exact
  camera owner and logs before considering any service or hardware action.

## Offline and rollback contract

Normal live view, recording, status, replay, recovery, and shutdown require no
internet after the Jetson and workstation offline packages are installed.

The current operational rollback surface consists of:

- `scripts/zed_field_console.sh`;
- `scripts/zed_replay_console.sh`;
- `scripts/zed_field_session.sh`;
- `scripts/zed_replay_session.sh`;
- `scripts/start_ros2_virtual_stereo.sh`;
- `scripts/start_ros2_rviz.sh`;
- `rviz/virtual_stereo.rviz`;
- `scripts/record_virtual_stereo.sh --lossless`;
- `config/ros2/field.yaml` and `config/ros2/outdoor.yaml`.

Browser-viewer development may add new files and optional dependencies, but it
must leave this surface operational. Detailed background and troubleshooting
remain in:

- `docs/FIELD_CONSOLE.md`;
- `docs/REMOTE_REPLAY.md`;
- `docs/ROS2_REMOTE_VIEWING.md`;
- `docs/FIELD_GUIDE.md`.
