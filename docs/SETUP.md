# Exact Rig Setup

This procedure recreates the software and configuration used by the calibrated
dual-ZED-X-One rig. It does not replace the mechanical requirement that both
cameras remain rigid in the pose used during calibration.

## 1. Hardware arrangement

- NVIDIA Jetson Orin Nano developer kit.
- ZED Link Capture Duo.
- ZED X One GS SN `304467158` is the calibrated **left** camera.
- ZED X One GS SN `306605936` is the calibrated **right** camera.
- Both cameras must be rigidly mounted, approximately 851.8 mm apart.
- Identify cameras by serial number, never by changing Explorer ID.

On the captured configuration, SN `304467158` enumerated on capture port 1 and
SN `306605936` on port 2. If physical camera placement and serial assignment do
not agree with the calibrated left/right order, depth will be wrong even when
both cameras enumerate successfully.

Power the Jetson and Capture Duo off completely before connecting, reseating,
or moving GMSL/ribbon connections. Do not hot-plug while Argus is active.

## 2. Software baseline

The known-good snapshot is:

```text
Jetson Linux: 36.5.0
Ubuntu:       22.04.5 LTS
ZED SDK:      5.4.0
CUDA:         12.6.68 as reported by ZED Diagnostic
Architecture: aarch64
```

Install the JetPack/L4T-compatible Stereolabs ZED SDK and its GMSL driver for
the Capture Duo before using this repository. The driver and ZED SDK are not
redistributed here. A working installation provides at least:

```text
/usr/local/zed/
/usr/sbin/ZEDX_Daemon
/usr/local/bin/ZED_Media_Server
ZED_Explorer
ZED_Depth_Viewer
ZED_SVO_Editor
```

Required build/runtime packages on the captured host include CMake, a C++17
compiler, OpenCV development libraries, Python 3, NumPy, Pillow, PyGObject,
and the GStreamer good/ugly/tool packages. The ZED SDK provides `pyzed.sl`.

## 3. Verify before installing repository configuration

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/verify_setup.sh
```

Expected enumeration when no application owns the cameras:

```text
SN 304467158  AVAILABLE  /dev/i2c-9  ID 0  Port 1
SN 306605936  AVAILABLE  /dev/i2c-10 ID 1  Port 2
```

`NOT AVAILABLE` normally means another process has a camera open. Serial
numbers and calibrated left/right order matter; IDs are not stable.

## 4. Build and install

```bash
./scripts/build.sh
./scripts/install.sh
```

The install script:

1. Builds the custom recorder and vendored upstream calibration tools.
2. Backs up and installs `calibration/active/SN116863460.conf` into
   `/usr/local/zed/settings/SN116863460.conf`.
3. Installs desktop launchers with this repository's actual path.
4. Does not restart Argus or ZED services.

The physical-camera factory calibration backups are included for offline
recovery but are not overwritten by default. To restore those exact files:

```bash
./scripts/install.sh --restore-factory-calibrations
```

Use that option only for these exact serial numbers. Existing files are backed
up before replacement.

## 5. Confirm the installed calibration

```bash
sha256sum /usr/local/zed/settings/SN116863460.conf
```

Expected:

```text
0502a05ec12942b4f02c375793c1200c6bec1387b4368c744121cbf61da19ed6
```

Run `./scripts/verify_setup.sh` again after installation.

## 6. Install ROS 2 remote viewing

ROS 2 is intentionally separate from the base rig installer. Provision the
pinned Humble/ZED wrapper stack on the Jetson with:

```bash
./scripts/preflight_ros2.sh
./scripts/install_ros2_jetson.sh
./scripts/verify_ros2_setup.sh
```

The installer builds Stereolabs wrapper `v5.4.0` in
`/home/dusty/zed_ros2_ws`, retains downloaded AArch64 packages for offline use,
and installs the **ZED ROS 2 Virtual Stereo** desktop launcher. It does not
modify JetPack/L4T, the GMSL driver, ZED SDK, calibration, camera daemons, or
boot services.

The matching Ubuntu 22.04 remote workstation setup and operating commands are
in [ROS2_REMOTE_VIEWING.md](ROS2_REMOTE_VIEWING.md).

## 7. First depth test

Close anything holding either camera, then run:

```bash
./scripts/launch_neural_viewer.sh
```

The rectified image window is the left-camera reference image. The 3D point
cloud still uses synchronized images from both physical cameras.

## 8. Recalibration

Recalibrate if either camera is moved or rotated relative to the other. The
exact command and target definition are in [CALIBRATION.md](CALIBRATION.md).
Never replace the active calibration merely because camera IDs changed.
