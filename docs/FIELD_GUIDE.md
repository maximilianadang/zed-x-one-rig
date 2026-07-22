# Dual ZED X One GS Field Guide

Last updated: 2026-07-21

This guide is specific to the dual ZED X One GS rig on this Jetson Orin Nano with the ZED Link Capture Duo. It is designed to be usable without internet access.

## Where this guide and field kit are stored

The canonical, version-controlled field copy of this guide is:

```text
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/docs/FIELD_GUIDE.md
```

The complete offline field kit is the repository containing this file:

```text
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/
```

It contains the virtual-stereo configuration, calibration backups, launcher scripts, custom direct SVO2 recorder, depth-analysis tools, a snapshot of the upstream calibration source, and matching prebuilt Jetson binaries. The ZED SDK applications themselves are installed under `/usr/local/zed/tools` and are not redistributed here.

Rig-specific near-field derivation:

```text
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/docs/NEAR_FIELD_MATH.md
```

This derives the hard geometric overlap limit and explains why `1.5 m` cannot be claimed as a minimum without an unpublished matcher limit or a controlled measurement.

## Known-good rig configuration

- Physical left camera: serial `304467158` (observed Explorer ID `0`, port `1`)
- Physical right camera: serial `306605936` (observed Explorer ID `1`, port `2`)
- Virtual stereo serial: `116863460`
- Native capture mode: `1920x1200` at `15 FPS`
- Checkerboard: `9x6` inner corners, `93.0 mm` per individual black or white tile
- Solved baseline: `851.810 mm` (`2.795 ft`)
- Calibration result: 15 captured pairs, 13 detected, 1 outlier rejected, 12 used
- Reprojection RMS: left `0.14 px`, right `0.14 px`, stereo `0.20 px`

Always identify the cameras by serial number. Camera IDs can change.

## Calibration files

Installed SDK calibration:

```text
/usr/local/zed/settings/SN116863460.conf
```

Persistent source copies:

```text
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/calibration/active/SN116863460.conf
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/calibration/active/zed_calibration_116863460.yml
```

Expected SHA-256 for the installed `.conf` file:

```text
0502a05ec12942b4f02c375793c1200c6bec1387b4368c744121cbf61da19ed6
```

Verify it:

```bash
sha256sum /usr/local/zed/settings/SN116863460.conf
```

Reinstall it if necessary:

```bash
sudo install -m 0644 \
  /home/dusty/workspace/terraforming_mars/zed-x-one-rig/calibration/active/SN116863460.conf \
  /usr/local/zed/settings/SN116863460.conf
```

Do not overwrite `SN304467158.conf` or `SN306605936.conf`; those are the individual cameras' factory calibration files.

## Normal availability check

```bash
ZED_Explorer --all
```

Expected result:

```text
SN 304467158  AVAILABLE  /dev/i2c-9
SN 306605936  AVAILABLE  /dev/i2c-10
```

`NOT AVAILABLE` normally means another process has a camera open. `No ZED detected` means enumeration or the driver/daemon state needs attention.

## Start NEURAL depth directly

This repository's reprojection viewer explicitly uses `DEPTH_MODE::NEURAL`, opens the two serials through the SDK virtual-stereo API, and displays the rectified image and live 3D point cloud:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig

./scripts/launch_neural_viewer.sh
```

The installed `SN116863460.conf` is loaded automatically. To force the workspace OpenCV calibration instead:

```bash
./build/calibration/stereo_reprojection_viewer/zed_reprojection_viewer \
  --virtual \
  --left_sn 304467158 \
  --right_sn 306605936 \
  --ocv /home/dusty/workspace/terraforming_mars/zed-x-one-rig/calibration/active/zed_calibration_116863460.yml
```

Press `Q` or `Esc`, or close the 3D window, to release both cameras.

## If cameras say NOT AVAILABLE

First find the process that owns them:

```bash
ps -eo pid,ppid,stat,comm,args | \
  grep -Ei 'zed_stereo_calibration|zed_reprojection_viewer|ZED_Depth_Viewer|ZED_Studio|ZED_Explorer|ZED_Media_Server|zed_media_server' | \
  grep -v grep
```

Close its GUI normally. If it is stuck, terminate only its PID:

```bash
kill PID
sleep 2
ZED_Explorer --all
```

Use `kill -9 PID` only when a normal `kill` cannot stop a confirmed stuck process. Do not use a broad `pkill` against all ZED software.

## If Explorer says No ZED detected

Check the normal services and device nodes:

```bash
systemctl is-active driver_zed_loader.service zed_x_daemon.service nvargus-daemon.service

lsmod | grep -Ei 'sl_max96712|sl_max9295|sl_zedx'
ls -l /dev/i2c-9 /dev/i2c-10
```

`driver_zed_loader.service` is a one-shot loader and may show `inactive` after completing successfully. `zed_x_daemon.service` and `nvargus-daemon.service` should be active.

Re-probe the already-installed driver, then restart only the ZED daemon:

```bash
sudo systemctl start driver_zed_loader.service zed_x_daemon.service
sudo systemctl restart zed_x_daemon.service
sleep 3
ZED_Explorer --all
```

This recovered both cameras on 2026-07-15 without rebooting.

## If an application reports Argus timeout/reset errors

Typical messages include `Error Timeout`, `Connection reset by peer`, or `Receive thread is not running`.

1. Close or terminate the application holding the cameras.
2. Confirm no ZED application remains in the process list.
3. Restart Argus alone:

```bash
sudo systemctl restart nvargus-daemon.service
sleep 5
ZED_Explorer --all
```

If the cameras still do not enumerate, use the driver/ZED-daemon re-probe sequence from the previous section. Do not repeatedly launch calibration or viewers while Argus is unhealthy.

## Logs for diagnosis

Recent kernel camera/GMSL errors:

```bash
sudo dmesg | \
  grep -Ei 'zed|sl_|max96712|max9295|camera|nvcsi|i2c|error|fail|falcon' | \
  tail -n 200
```

Recent daemon logs:

```bash
sudo journalctl \
  -u nvargus-daemon.service \
  -u zed_x_daemon.service \
  -u driver_zed_loader.service \
  --since '-10 min' --no-pager
```

Errors such as `FALCON_ERROR`, `IoctlFailed`, or a camera reboot failing in state `8` after a connector is disturbed point to a real GMSL/link interruption, not a checkerboard or calibration-software problem.

## Connector and mechanical precautions

- Never nudge, reseat, or hot-plug camera/capture-board connectors while streaming.
- Close the camera application and fully remove power before reseating a questionable connection.
- Keep strain off the ribbon/GMSL cables and connector bodies.
- The stereo transform is valid only while the cameras remain rigid relative to one another.
- Recalibrate after either camera is moved, rotated, impacted, or remounted—even slightly.

## Recommended field recording: direct virtual-stereo recorder

When an Ubuntu viewing workstation is available on the same LAN, the preferred
combined view-and-record workflow is the remote field console:

```bash
cd /path/to/zed-x-one-rig
./scripts/zed_field_console.sh --jetson zed-jetson
```

It starts in view-only mode. Use `r` to start lossless recording, `s` to
finalize/validate/save, `i` for status, `v` to reopen RViz, and `q` for complete
safe shutdown. One-time SSH setup, disconnect recovery, and offline operation
are documented in `docs/FIELD_CONSOLE.md`.

For standalone recording without the remote view, use the direct recorder.

Use the application named **ZED Virtual Stereo Recorder** from the desktop application menu. It opens the two cameras as calibrated virtual stereo serial `116863460` and starts recording immediately in reliable headless mode. This route does **not** use Media Server, does **not** need sudo, and does **not** need internet.

The equivalent terminal command is:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh
```

The self-contained field-kit command is:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh
```

During recording:

- No image-preview window opens. Watch the terminal for increasing `ingested` and `encoded` counts.
- Press `Ctrl+C` in the terminal to stop.
- Always wait for `Finalizing SVO2` and the saved-file message before removing power.
- Recordings are saved as `~/Videos/ZED/virtual_stereo_YYYYMMDD_HHMMSS.svo2`.
- The default is lossless PNG/ZSTD compression. It preserves the best inputs for later NEURAL depth but consumes substantial storage. Check free disk space before a long session.

Do not use the recorder's experimental `--preview` option in the field. On this Jetson, OpenCV/GTK preview activity while lossless SDK recording is enabled can produce a header-only SVO2 with no readable frame index. Use headless recording, then inspect the finalized SVO2 in ZED Explorer or ZED Depth Viewer. The GTK message `Failed to load module "canberra-gtk-module"` is harmless by itself. The recorder may also report that the SDK recording pipeline has not accepted an initial frame yet; it continues through transient startup events and stops only if the SDK rejects recording frames continuously for five seconds. A valid session should show increasing `ingested` and `encoded` counts before it is stopped.

Copy/paste proven recording command:

```bash
# Maximum fidelity for quantitative depth work; approximately 3.4 GB/minute
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --lossless
```

Run the following for the complete option list and the same copy/paste examples:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --help
```

Other implemented low-level controls are `--h264`, `--h265`,
`--output /path/name.svo2`, `--no-preview`, and `--frames N`. The normal launcher
is already headless, so `--no-preview` is explicit but optional. Do not use
`--preview` in the field. H.264 and H.265 did not produce a valid file in the
2026-07-21 bounded tests on this exact virtual pair; treat them as experimental,
not field-supported presets.

The corrected direct recorder was validated on this Jetson on 2026-07-17 using `ZED_SVO_Editor -inf`. A bounded headless lossless test produced a readable SVO2 v2 containing 46 indexed frames at 1920×1200, 15 FPS, with virtual serial `116863460`. It was approximately 169 MB, or roughly 56 MB/s; the actual rate varies with image content. Budget storage conservatively for long lossless sessions. The recorder produces one synchronized stereo SVO2 containing both camera streams. The installed `SN116863460.conf` associates the rig calibration with the virtual camera; NEURAL depth is computed from the stereo images during playback rather than baked into the file.

## Validate and view an SVO2 recording

An `.svo2` is a Stereolabs stereo/data container, not a standard MP4 video. VLC and the default Linux video player cannot open it. Media Server and live cameras are not needed for file playback.

First verify that the file contains a valid index and frames:

```bash
ZED_SVO_Editor -inf /home/dusty/Videos/ZED/RECORDING.svo2
```

A valid recording reports its frame count and camera information. `FAIL: failed to get infos` means the recording was not finalized or contains no usable frames. A file several megabytes in size can still contain only an SVO2 header and zero frames.

For normal stereo/color playback:

```bash
ZED_Explorer /home/dusty/Videos/ZED/RECORDING.svo2
```

Alternative color/multi-stream playback:

```bash
ZED_Studio --recording /home/dusty/Videos/ZED/RECORDING.svo2
```

For depth-map or point-cloud playback:

```bash
ZED_Depth_Viewer /home/dusty/Videos/ZED/RECORDING.svo2
```

Select `NEURAL` in Depth Viewer after opening the recording. The SDK uses the installed virtual stereo calibration to compute depth from the recorded left/right images.

In the Files application, right-click a valid `.svo2`, choose **Open With Other Application**, and select **ZED Explorer** or **ZED Depth Viewer**. Ubuntu initially identifies `.svo2` as generic `application/octet-stream`, so double-clicking it may not automatically select a ZED application.

## Installed GUI applications

These applications are installed locally and work without internet:

```text
/usr/local/bin/ZED_Media_Server
/usr/local/bin/ZED_Explorer
/usr/local/bin/ZED_Depth_Viewer
/usr/local/bin/ZED_Studio
```

Four custom desktop application launchers are installed for field use:

- **ZED Virtual Stereo Recorder**: recommended no-sudo synchronized SVO2 recorder.
- **ZED Virtual Stereo Stream**: starts the exact Media Server CLI configuration on port `34000`; it may ask for the Jetson sudo password.
- **ZED Media Server**: opens the Media Server configuration GUI.
- **ZED ROS 2 Virtual Stereo**: publishes rectified color, NEURAL depth, and a reduced colored point cloud to a same-LAN ROS 2 workstation.

It is expected that this SDK installation did not originally show ZED Media Server in the desktop application menu. The executable was installed, but no `.desktop` launcher was supplied. The custom launcher fixes that discoverability issue.

## Remote viewing without VNC

The supported remote field path is ROS 2 Humble with RViz2. The Jetson opens
the calibrated pair and computes NEURAL depth. The remote Ubuntu 22.04
workstation receives standard ROS images, depth, and point clouds and does not
need the ZED SDK or CUDA.

Preferred one-command launch from the viewing workstation:

```bash
cd /path/to/zed-x-one-rig
./scripts/zed_field_console.sh --jetson zed-jetson
```

It starts in view-only mode and provides `r`, `s`, `i`, `v`, `h`, and `q`
controls. See `docs/FIELD_CONSOLE.md` for one-time SSH setup and recovery.

Manual diagnosis remains possible by starting these in order on the Jetson and
then the workstation:

```bash
# Jetson
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/start_ros2_virtual_stereo.sh

# Workstation
./scripts/start_ros2_rviz.sh
```

From the ThinkPad, browse finalized recordings and select one to replay instead
of opening live cameras:

```bash
./scripts/zed_replay_console.sh --jetson zed-jetson
```

This headless workflow starts paused at frame zero and provides play/pause,
forward-only single-frame advance, 0.1x-5x speed, loop, RViz reopen, and
safe-stop controls. Right Arrow advances sequentially without seeking;
backward and timed scrubbing are disabled. The default command shows a numbered
remote directory; press Enter for newest or type an index. Use `o` during replay
to switch datasets, or use
`--latest`, `--index N`, or `--svo /absolute/jetson/path.svo2` to bypass the
browser. Complete offline instructions are in
`docs/REMOTE_REPLAY.md`.

The default ROS domain is `42`. Live and replay expose the same `/zed/zed_node`
topics and use the same RViz configuration. The viewer launcher receives
compressed color and compressed depth, expands them locally for RViz, and
keeps the already reduced point cloud as standard `PointCloud2`. The complete
one-time installation, offline cache, discovery, bandwidth, and recovery
procedure is in `docs/ROS2_REMOTE_VIEWING.md`.

For the console, use `q` and wait for camera-release confirmation before
starting calibration, Media Server, or another ZED viewer. For the manual path,
stop the foreground ROS launch with `Ctrl+C`. The launchers refuse an existing
camera owner and do not terminate it.

## Media Server, live Depth Viewer, and GUI recording fallback

The installed calibration enables SDK applications that explicitly open virtual stereo serial `116863460`. Some current ZED GUI tools do not directly create a dual-ZED-X-One pair through the new virtual-stereo API.

The window named `Rectified Image` in `zed_reprojection_viewer` is only the rectified **left-camera preview**. The 3D point cloud in that application still uses both cameras. That viewer does not record SVO files.

For live use of ZED Depth Viewer, or for recording through ZED Explorer, use this compatibility path:

1. Close `zed_reprojection_viewer` or any other process using either camera. In the 3D viewer, press `Q` or `Esc`.
2. Confirm both physical cameras are `AVAILABLE` with `ZED_Explorer --all`.
3. Launch **ZED Virtual Stereo Stream** from the application menu. It loads the field kit's exact pair configuration and streams on `127.0.0.1:34000`. Keep its terminal open. On this Media Server `0.1.9` installation, the server may request the Jetson sudo password.
4. If using **ZED Media Server** instead, configure:
   - Left: `304467158`
   - Right: `306605936`
   - Virtual stereo serial: `116863460`
   - Resolution/frame rate: `HD1200`, `15 FPS`
5. Click **SAVE**, then click **Stream**. The normal local streaming port is `34000`.
6. Choose the GUI for the task:
   - `ZED_Depth_Viewer`: depth map, confidence map, and 3D point cloud.
   - `ZED_Explorer`: straightforward SVO2 recording and playback.
   - `ZED_Studio`: multi-camera color-stream viewing/management and recording; it is not the dedicated depth-map interface.
7. In the selected application, click the **network/stream icon**. Do not select either physical ZED X One as a live monocular camera; an individual ZED X One cannot generate stereo depth.
8. Enter address `127.0.0.1` and port `34000`, then connect.
9. Confirm Explorer reports `STREAMING (NETWORK)` and shows a live feed.
10. Optional: click the gear beside the camera/serial field, then set the **SVO and Screenshot Folder**, compression, and automatic naming under Application Settings.
11. Click the **record icon** at the lower-left to start recording. Click it again to stop.
12. Wait for recording finalization before closing Explorer or stopping Media Server. Verify that the resulting `.svo2` file is non-empty and can be reopened in Explorer.

The Media Server sudo request is not an internet requirement. In the field, a
plain SSH session can run Media Server in CLI mode and accept the local sudo
password. Media Server remains a local compatibility path for ZED GUI tools;
use the ROS 2 workflow above for remote color/depth/point-cloud viewing. The
direct **ZED Virtual Stereo Recorder** remains the simplest recording path when
live Depth Viewer is not required.

Exact Media Server CLI command:

```bash
/usr/local/bin/ZED_Media_Server --cli --config \
  /home/dusty/workspace/terraforming_mars/zed-x-one-rig/config/virtual_xone_config.json
```

To inspect live depth, launch `ZED_Depth_Viewer`, connect its network input to `127.0.0.1:34000`, select `NEURAL`, and use its Depth Feed or 3D Data Feed. If the application reports `LIVE` with serial `304467158` or `306605936` instead of `STREAMING (NETWORK)`, it opened one monocular camera and will not offer stereo depth.

### What the SVO2 contains

- It records the synchronized **left and right camera images**, not just the one-camera preview currently displayed by a GUI.
- The stereo images can be retrieved individually as left/right views or together as a side-by-side view during playback.
- It also records timestamps and supported camera metadata.
- Standard recording does not bake the displayed NEURAL point cloud into the file. The SDK re-runs depth estimation from the recorded stereo pair during playback, so a different depth mode can be selected later.
- Compression applies to the recorded camera images. This rig's proven path is lossless. H.264/H.265 would be smaller but currently reject frames on this virtual pair and are not field-supported.

The direct reprojection-viewer command is preferable for the first local NEURAL-depth validation because it avoids the Media Server streaming layer.

## Recovery order summary

Use the smallest applicable step and stop as soon as both cameras are `AVAILABLE`:

1. Close the process holding the cameras.
2. Check `ZED_Explorer --all`.
3. Restart `nvargus-daemon` only for Argus timeout/reset failures.
4. Re-probe `driver_zed_loader` and restart `zed_x_daemon` for `No ZED detected`.
5. Power down and reseat connections only when logs or physical disturbance indicate a link problem.
6. Reboot only after the non-reboot recovery steps fail.

## Online references

- ZED X One virtual stereo setup: https://docs.stereolabs.com/docs/products/cameras/zedxone/dual-camera-stereo-vision
- OpenCV calibration and reprojection viewer: https://docs.stereolabs.com/docs/integrations/opencv/zed-open-cv-calibration
- ZED Explorer and recording: https://docs.stereolabs.com/docs/development/zed-tools/zed-explorer
- ZED SDK recording: https://docs.stereolabs.com/docs/development/zed-sdk/modules/camera/recording
- ZED Depth Viewer: https://docs.stereolabs.com/docs/development/zed-tools/zed-depth-viewer
