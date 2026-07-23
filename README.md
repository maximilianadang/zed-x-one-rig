# Dual ZED X One GS Rig

Reproducible source, configuration, calibration, launchers, and offline field
documentation for this machine's wide-baseline virtual stereo system.

This repository is rig-specific. Its camera serial numbers, left/right order,
virtual serial, calibration, and expected Jetson/ZED versions are intentional.
Do not install its calibration on a different camera pair.

## Exact known-good rig

| Component | Value |
|---|---|
| Host | NVIDIA Jetson Orin Nano Engineering Reference Developer Kit Super |
| Capture interface | ZED Link Capture Duo, two GMSL ports |
| Jetson Linux | 36.5.0 |
| Ubuntu | 22.04.5 LTS |
| ZED SDK | 5.4.0 |
| CUDA reported by ZED | 12.6.68 |
| Calibrated left camera | ZED X One GS, SN `304467158` |
| Calibrated right camera | ZED X One GS, SN `306605936` |
| Virtual stereo serial | `116863460` |
| Capture mode | 1920x1200 at 15 FPS |
| Media Server endpoint | `127.0.0.1:34000` |
| Checkerboard | 9x6 inner corners, 93.0 mm squares |
| Solved baseline | 851.810 mm (2.795 ft) |
| Reprojection RMS | left 0.14 px, right 0.14 px, stereo 0.20 px |

Serial numbers are authoritative. Camera IDs can change. On the 2026-07-17
snapshot, Explorer reported SN `304467158` on `/dev/i2c-9`, ID 0, port 1 and
SN `306605936` on `/dev/i2c-10`, ID 1, port 2.

## First commands

Verify the host, installed configuration, services, and cameras without
changing them:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/verify_setup.sh
```

Build all source included in this repository:

```bash
./scripts/build.sh
```

Install the exact virtual calibration and desktop launchers. Existing camera
configuration is backed up before replacement:

```bash
./scripts/install.sh
```

The installer does not restart camera services and does not touch the two
physical factory calibrations unless explicitly given
`--restore-factory-calibrations`.

## One-command remote view and recording

From the Ubuntu 22.04 viewing workstation, one command starts or attaches to
the Jetson's calibrated ROS session, opens RViz, and provides recording keys:

```bash
cd /path/to/zed-x-one-rig
./scripts/zed_field_console.sh --jetson zed-jetson
```

The console starts in view-only mode. Press `r` to start lossless recording,
`s` to finalize/validate/save, `i` for status, `v` to reopen RViz, and `q` for
a complete safe shutdown. Recordings are synchronized full-resolution SVO2
files on the Jetson, not the reduced ROS preview.

For bright-sky scenes and optically thick, contrast-limited dust plumes, select
the outdoor acquisition profile at startup:

```bash
./scripts/zed_field_console.sh --jetson zed-jetson --outdoor
```

The footer must report `[OUTDOOR]`. This preserves the normal calibrated
NEURAL/lossless pipeline while limiting exposure time and protecting highlight
structure; see [docs/FIELD_CONSOLE.md](docs/FIELD_CONSOLE.md) for the exact
settings and limitations.

The default target can also be supplied directly when mDNS is unambiguous:

```bash
./scripts/zed_field_console.sh --jetson dusty@ubuntu.local
```

See [docs/FIELD_CONSOLE.md](docs/FIELD_CONSOLE.md) for one-time SSH setup,
offline operation, recovery semantics, and network checks.

## Direct synchronized recording fallback

When no remote view is needed, the proven direct fallback is lossless:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh \
  --lossless
```

The H.264/H.265 options exist in the low-level recorder, but neither produced
a valid recording in bounded tests on this exact virtual-stereo path. Do not
use them for field data unless a future rig-specific test validates them.

Show every low-level recorder option:

```bash
./scripts/record_virtual_stereo.sh --help
```

Always stop with `Ctrl+C` and wait for `Finalizing SVO2` before removing power.
Never hot-plug or reseat a GMSL/capture-board connection while streaming.

## Remote viewing without VNC

ROS 2 is the supported same-LAN remote viewing path. The Jetson computes
NEURAL depth and publishes rectified color, registered depth, and a reduced
colored point cloud. The supplied RViz profile selects compressed color,
depth, and Draco point-cloud transports to keep LAN traffic bounded, then
expands them locally for display. An Ubuntu 22.04 workstation uses RViz2 and does not need the ZED SDK
or CUDA.

One-time Jetson setup:

```bash
./scripts/install_ros2_jetson.sh
```

Preferred one-command control from the workstation:

```bash
./scripts/zed_field_console.sh --jetson zed-jetson
```

Manual launch remains available for diagnosis. Start publication on the Jetson,
then RViz from the remote workstation:

```bash
./scripts/start_ros2_virtual_stereo.sh
./scripts/start_ros2_rviz.sh
```

Browse the Jetson's finalized recordings and replay one headlessly from the
same workstation, with rosbag-style pause, forward-one-frame, speed, dataset
selection, loop, status, and RViz controls. Backward seeking is intentionally
disabled on this rig because it does not respond within usable field latency:

```bash
./scripts/zed_replay_console.sh --jetson zed-jetson
```

See [docs/ROS2_REMOTE_VIEWING.md](docs/ROS2_REMOTE_VIEWING.md) for installation,
offline caches, field operation, discovery checks, and recovery.
See [docs/REMOTE_REPLAY.md](docs/REMOTE_REPLAY.md) for replay controls and
recording selection.

## Repository contents

```text
calibration/   Exact active virtual calibration and physical-camera backups
config/        Rig, Media Server, and ROS 2/DDS configuration
docs/          Setup, field operation, recorder, remote viewing, calibration, and depth notes
launchers/     Desktop launcher templates installed by scripts/install.sh
prebuilt/      AArch64 binaries built on the known-good Jetson software stack
recorder/      Source for the custom synchronized virtual-stereo SVO2 recorder
scripts/       Build, installation, verification, recording, and stream commands
tools/         Offline SVO depth-analysis and overlay-video tools
vendor/        Exact upstream calibration source and pinned ROS 2 assets
```

Recordings, generated images/videos, calibration capture frames, diagnostic
dumps, caches, and build directories are intentionally excluded from Git.

See [docs/SETUP.md](docs/SETUP.md) for complete provisioning and
[docs/FIELD_GUIDE.md](docs/FIELD_GUIDE.md) for offline operation and recovery.
