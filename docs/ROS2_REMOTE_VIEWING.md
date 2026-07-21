# ROS 2 Remote Viewing and SVO2 Replay

This is the no-VNC, no-cloud remote visualization path for the exact calibrated
dual ZED X One GS rig. The Jetson owns the cameras and performs NEURAL depth.
An Ubuntu 22.04 workstation on the same LAN displays rectified color, depth,
and the colored point cloud in RViz2 without the ZED SDK or CUDA.

## Fixed contract

| Item | Value |
|---|---|
| Jetson ROS distribution | ROS 2 Humble |
| Wrapper | Stereolabs `v5.4.0`, commit `6545933af94d70922881654e6fb29d95e3a8f14f` |
| DDS | Cyclone DDS |
| ROS domain | `42` |
| Left camera | `304467158` |
| Right camera | `306605936` |
| Virtual serial | `116863460` |
| Native acquisition | HD1200, 1920x1200 at 15 FPS |
| Depth mode | NEURAL |
| Field image/depth publication | 960x600 at 5 FPS |
| Field point cloud publication | `REDUCED` at 2 FPS |
| ROS namespace | `/zed/zed_node` |

The initial field profile is
`config/ros2/field.yaml`. It reduces only published previews; the SDK still
acquires and computes depth at the native rig mode.

## Camera ownership

Only one of these modes may run at a time:

- ROS live viewing;
- direct SVO2 recording;
- calibration or direct NEURAL viewer;
- ZED Media Server;
- another ZED GUI that opens a physical camera.

The ROS launchers inspect known owners and refuse to start instead of killing
anything. Stop the current foreground application normally and wait for it to
release the cameras.

## One-time Jetson installation

Online installation, pinned wrapper build, package caching, and launcher
installation:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/preflight_ros2.sh
./scripts/install_ros2_jetson.sh
./scripts/verify_ros2_setup.sh
```

The installer may request the local sudo password. It does not modify JetPack,
L4T, the GMSL driver, ZED SDK, camera calibration, camera daemons, or boot
services. It builds the wrapper in `/home/dusty/zed_ros2_ws` and does not add
anything to `.bashrc`.

Downloaded AArch64 packages are retained under:

```text
offline/ros2/jetson-arm64/debs/
```

Offline reinstall after that cache has been populated:

```bash
./scripts/install_ros2_jetson.sh \
  --offline-dir ./offline/ros2/jetson-arm64/debs
```

## One-time remote workstation installation

Copy or clone this repository onto an Ubuntu 22.04 workstation. From its copy:

```bash
./scripts/install_ros2_remote.sh
```

This installs ROS 2 Humble, Cyclone DDS, RViz2, and image transports. It does
not install the ZED SDK or CUDA. Downloaded packages are retained in the
architecture-specific remote cache, normally:

```text
offline/ros2/remote-amd64/debs/
```

For offline field use, install the receiver while online before deployment or
copy its populated package cache alongside the repository.

## Live remote viewing

On the Jetson:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/start_ros2_virtual_stereo.sh
```

The exact equivalent can also be opened from the application menu as
**ZED ROS 2 Virtual Stereo**. Keep its terminal visible.

On the remote workstation:

```bash
cd /path/to/zed-x-one-rig
./scripts/start_ros2_rviz.sh
```

The launcher deliberately receives the bandwidth-saving image transports:

- rectified color: `/zed/zed_node/rgb/color/rect/image/compressed`;
- registered depth: `/zed/zed_node/depth/depth_registered/compressedDepth`;
- colored point cloud: `/zed/zed_node/point_cloud/cloud_registered`.

Two local `image_transport republish` helpers expand the compressed messages
into `/zed_field/rgb/image` and `/zed_field/depth/image` on the workstation for
RViz. Raw images therefore exist only after crossing the LAN. The launcher
stops both helpers when RViz exits. The original uncompressed ZED base topics
remain available for local diagnosis; do not use them across field Wi-Fi
unless you have measured enough bandwidth.

The fixed viewing frame is `zed_camera_link`, so RViz uses normal ROS body
axes: X forward, Y left, Z up. Its XY grid is therefore a horizontal reference
plane through the camera origin; it is not an estimated physical ground plane.
The source image/depth measurements remain in their calibrated optical frames
and TF performs the display transform. Press `Ctrl+C` in the Jetson launch
terminal to stop. Wait for ROS shutdown, then verify both cameras are available
before starting the recorder or another ZED application:

```bash
ZED_Explorer --all
```

## Remote SVO2 viewing

The raw `.svo2` remains on the Jetson. The Jetson opens it with the ZED SDK,
recomputes NEURAL depth, and publishes the same ROS topics used for live data.
The remote workstation continues using the same RViz command.

On the Jetson:

```bash
./scripts/play_svo_ros2.sh \
  /home/dusty/Videos/ZED/virtual_stereo_20260717_162826.svo2
```

Loop the recording:

```bash
./scripts/play_svo_ros2.sh --loop \
  /home/dusty/Videos/ZED/virtual_stereo_20260717_162826.svo2
```

The launcher first uses `ZED_SVO_Editor -inf` and refuses files that have no
indexed frames or do not report virtual serial `116863460`.

The remote workstation does not need the proprietary `.svo2` codec because it
receives standard ROS image, depth, and point-cloud messages. Opening the raw
file directly on the remote workstation would still require the ZED SDK.

## Verify ROS discovery before opening RViz

On both machines, the scripts set:

```text
ROS_DOMAIN_ID=42
RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
```

With the Jetson publisher running, the remote workstation should report:

```bash
source /opt/ros/humble/setup.bash
export ROS_DOMAIN_ID=42
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file:///absolute/path/to/zed-x-one-rig/config/ros2/cyclonedds.xml

ros2 node list
ros2 topic list | grep '^/zed/'
```

Expected node prefix:

```text
/zed/zed_node
```

Useful rate and bandwidth checks:

```bash
./scripts/verify_ros2_setup.sh --runtime

ros2 topic hz /zed/zed_node/rgb/color/rect/image/compressed
ros2 topic hz /zed/zed_node/depth/depth_registered/compressedDepth
ros2 topic hz /zed/zed_node/point_cloud/cloud_registered
ros2 topic bw /zed/zed_node/point_cloud/cloud_registered
```

The `--runtime` verifier subscribes to all three uncompressed base streams for
a deliberately demanding local health check. The RViz field configuration
uses compressed image transports and therefore sends substantially less image
traffic over the LAN.

## If discovery does not work

1. Confirm both machines are on the same trusted LAN and can ping each other.
2. Confirm both use ROS domain `42` and `rmw_cyclonedds_cpp`.
3. Confirm the Wi-Fi access point does not enable client/AP isolation.
4. Check ROS multicast before debugging the camera:

```bash
# Remote workstation
ros2 multicast receive

# Jetson, in another terminal
ros2 multicast send
```

5. If UFW is enabled, allow traffic from the trusted field subnet on both
   machines. Substitute the real subnet rather than copying this example
   blindly:

```bash
sudo ufw allow from 192.168.8.0/24
```

6. If the LAN deliberately blocks multicast, configure explicit Cyclone DDS
   peers for the two fixed LAN addresses before changing camera settings.

Discovery failure is a network/DDS problem. Do not restart Argus, reinstall the
GMSL driver, or change calibration to solve it.

## Recording remains separate

ROS 2 does not replace the proven master recorder. Stop ROS live viewing, wait
for camera release, then record:

```bash
./scripts/record_virtual_stereo.sh --h264
```

Use lossless recording when the images will support quantitative depth work:

```bash
./scripts/record_virtual_stereo.sh --lossless
```

SVO2 preserves synchronized stereo inputs. A rosbag records selected published
topics after downscaling/throttling and is therefore diagnostic material, not
the canonical camera recording.

## Safe rollback

The ROS path has no boot service. Stop the foreground ROS process with
`Ctrl+C`. Existing recording, calibration, direct viewer, and Media Server
commands remain independent. Removing the ROS packages is not required to
return to the previous application topology.
