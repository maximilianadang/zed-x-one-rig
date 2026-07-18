# Calibration for This Camera Pair

## Coordinate assignment

```text
Physical left:  SN 304467158
Physical right: SN 306605936
Virtual serial: SN 116863460
```

This order is encoded in the recorder, Media Server configuration, launch
scripts, and active calibration. Camera IDs are deliberately not used.

## Target used for the active calibration

- 9 horizontal inner corners.
- 6 vertical inner corners.
- 93.0 mm per black or white square.
- Displayed on a large television and measured physically.
- 15 captured stereo pairs, 13 detected, one outlier rejected, 12 used.

Result:

```text
Full baseline: 851.810 mm
Left RMS:      0.14 px
Right RMS:     0.14 px
Stereo RMS:    0.20 px
```

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
  --left_sn 304467158 \
  --right_sn 306605936 \
  --h_edges 9 \
  --v_edges 6 \
  --square_size 93.0
```

Capture broad position, distance, and tilt diversity while keeping the complete
checkerboard visible in both cameras. With this wide baseline, close targets
have very little shared field of view.

## Active outputs

```text
calibration/active/SN116863460.conf
calibration/active/zed_calibration_116863460.yml
```

The SDK automatically loads the first file from:

```text
/usr/local/zed/settings/SN116863460.conf
```

The two files under `calibration/factory/` are exact backups of the individual
camera configurations present on the known-good host. They are not stereo
extrinsics and must not replace the virtual calibration.
