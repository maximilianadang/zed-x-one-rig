# Calibration for This Camera Pair

## Coordinate assignment

```text
Physical left:  SN 306605936, ID 1, port 2
Physical right: SN 304467158, ID 0, port 1
Virtual serial: SN 117941018
```

The operational launch and recorder use guarded camera IDs `[1,0]` and
explicitly retain virtual serial `117941018`. Before open, each ID is checked
against its serial, port, and I2C path. This preserves the verified active
calibration while avoiding the reversed physical views observed with the ZED
SDK 5.4 serial-pair path.

## Target used for the active calibration

- 9 horizontal inner corners.
- 6 vertical inner corners.
- 28.0 mm per black or white square, physically measured on the screen.
- Captured on 2026-10-14 after changing the baseline.
- Source session: `1792023751877379356` in the adjacent calibration repository.

Result:

```text
Horizontal baseline: 244.410 mm
```

The new files are installed and pass identity/checksum checks. Known-distance
live depth validation is pending. The earlier 15-pair counts and RMS values
describe the old baseline and must not be attributed to this solve.

## Build and run the included upstream tool

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/build.sh
./scripts/launch_calibration.sh
```

The launcher executes the equivalent full command:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/build/calibration/stereo_calibration/zed_stereo_calibration \
  --virtual \
  --left_id 1 \
  --right_id 0 \
  --h_edges 9 \
  --v_edges 6 \
  --square_size 28.0
```

Capture broad position, distance, and tilt diversity while keeping the complete
checkerboard visible in both cameras. Close targets may have limited shared
field of view.

The SDK derives a new order-dependent virtual serial when recalibrating through
IDs. Treat any new calibration as an explicit migration: validate its
left/right images and depth before installing it. The current operational
calibration remains virtual serial `117941018`.

The adjacent `zed-opencv-calibration` checkout additionally has automatic
capture and C/Enter-to-finish controls. Those changes are not yet vendored here;
the bundled calibration tool retains its existing controls.

## Active outputs

```text
calibration/active/SN117941018.conf
calibration/active/zed_calibration_117941018.yml
```

The SDK automatically loads the first file from:

```text
/usr/local/zed/settings/SN117941018.conf
```

The two files under `calibration/factory/` are exact backups of the individual
camera configurations present on the known-good host. They are not stereo
extrinsics and must not replace the virtual calibration.
