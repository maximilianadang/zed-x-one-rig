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

## Record synchronized stereo

Recommended smaller field recording:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --h264
```

Maximum fidelity for calibration or quantitative depth work:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --lossless
```

One-minute H.264 recording with an explicit filename:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh \
  --h264 --frames 900 \
  --output /home/dusty/Videos/ZED/field_test.svo2
```

Show every currently implemented recorder option and the same copy/paste
examples:

```bash
./scripts/record_virtual_stereo.sh --help
```

Always stop with `Ctrl+C` and wait for `Finalizing SVO2` before removing power.
Never hot-plug or reseat a GMSL/capture-board connection while streaming.

## Repository contents

```text
calibration/   Exact active virtual calibration and physical-camera backups
config/        Rig manifest and ZED Media Server virtual-stereo configuration
docs/          Setup, field operation, recorder, calibration, and depth notes
launchers/     Desktop launcher templates installed by scripts/install.sh
prebuilt/      AArch64 binaries built on the known-good Jetson software stack
recorder/      Source for the custom synchronized virtual-stereo SVO2 recorder
scripts/       Build, installation, verification, recording, and stream commands
tools/         Offline SVO depth-analysis and overlay-video tools
vendor/        Exact upstream ZED OpenCV calibration source snapshot
```

Recordings, generated images/videos, calibration capture frames, diagnostic
dumps, caches, and build directories are intentionally excluded from Git.

See [docs/SETUP.md](docs/SETUP.md) for complete provisioning and
[docs/FIELD_GUIDE.md](docs/FIELD_GUIDE.md) for offline operation and recovery.
