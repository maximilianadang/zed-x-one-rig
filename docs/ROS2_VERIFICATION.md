# ROS 2 Verification Record

Evidence captured on the reference Jetson on 2026-07-21. This record separates
what passed locally from the acceptance work that requires a second machine or
the field network.

## Frozen Jetson boundary

| Item | Observed value |
|---|---|
| OS | Ubuntu 22.04.5 LTS, AArch64 |
| Jetson Linux | R36.5.0, GCID `43688277` |
| Kernel | `5.15.185-tegra` |
| CUDA toolkit | 12.6, build 12.6.68 |
| ZED SDK | 5.4.0 |
| GMSL package | `stereolabs-zedlink-duo` `1.4.2-LI-MAX96712-L4T36.5.0` |
| ROS distribution | Humble |
| ZED ROS wrapper | tag `v5.4.0`, commit `6545933af94d70922881654e6fb29d95e3a8f14f` |
| DDS | `rmw_cyclonedds_cpp`, ROS domain `42` |

Pinned supply-chain artifacts:

- wrapper archive SHA-256:
  `e8b514f0bba6b759db07c0e2bbb838565a28a60ce7b62667e8c3d707a2eb3b87`;
- ROS apt-source bootstrap SHA-256:
  `767884cf4ed03116b9d64438930a832ed854147ae435279a7924dfdf60f94433`;
- installed virtual calibration SHA-256:
  `0502a05ec12942b4f02c375793c1200c6bec1387b4368c744121cbf61da19ed6`;
- installed ROS package versions:
  `config/ros2/jetson-installed-versions.txt`.

The wrapper was built from the bundled archive in `/home/dusty/zed_ros2_ws`
with two workers. All three selected packages (`zed_components`, `zed_wrapper`,
and `zed_ros2`) built successfully. The AArch64 apt cache contains 359 Debian
packages under `offline/ros2/jetson-arm64/debs/`; the generated cache is
intentionally excluded from Git.

## Static verification

`./scripts/verify_ros2_setup.sh` passed with zero failures and zero warnings
when no camera owner was running. It verified ROS, the workspace, wrapper
version, Cyclone DDS, RViz2, launcher executability, and the installed
calibration checksum.

The initial installer reached package completion but exited while sourcing the
ROS setup under shell `nounset` mode. The source boundaries now temporarily
disable `nounset`; the pinned wrapper subsequently built and static
verification passed. The apt `_apt` cache-access message was a nonfatal warning
and did not indicate package-install failure.

## SVO2 replay acceptance

Input:
`/home/dusty/Videos/ZED/virtual_stereo_20260717_162826.svo2`

- `ZED_SVO_Editor -inf`: SVO v2, 1210 frames, 1920x1200 at 15 FPS,
  virtual serial `116863460`;
- SDK opened `Virtual ZED-X`, serial `116863460`, NEURAL depth;
- native processing remained 1920x1200 and publication was 960x600;
- reduced point-cloud dimensions were 224x128;
- required image, registered-depth, point-cloud, and camera-info topic types
  were present;
- measured simultaneous base-topic rates were RGB `4.166 Hz`, depth
  `3.649 Hz`, and point cloud `2.071 Hz`, against caps of `5/5/2 Hz`;
- the compressed-to-local viewer bridge delivered RGB `4.683 Hz`, depth
  `4.412 Hz`, and point cloud `2.051 Hz` in a later bounded replay;
- RViz opened with color, depth, and point cloud enabled; its field view uses
  `zed_camera_link` (X forward, Y left, Z up) while preserving the calibrated
  optical frames as the message sources;
- normal `Ctrl+C` closed the SVO camera and both ROS processes cleanly.

Replay is more compute-intensive than simply decoding the file because depth
and point clouds are generated only while subscribers request them. Loop mode
uses wall-clock timestamps because the wrapper ignores looping when original
SVO timestamps are selected.

## Live-camera acceptance

- before launch: physical serials `304467158` and `306605936` both
  `AVAILABLE`;
- launch input: serial order `[304467158,306605936]`;
- SDK result: GMSL input, HD1200 at 15 FPS, virtual serial `116863460`,
  NEURAL depth;
- installed calibration baseline: `851.662 mm`;
- output: 960x600 rectified color/registered depth and 224x128 reduced colored
  point cloud;
- measured simultaneous rates: RGB `4.841 Hz`, depth `5.000 Hz`, point cloud
  `1.995 Hz`;
- the runtime verifier reported zero failures and zero warnings;
- no Argus timeout, reset, invalid-state, critical, or failed-reboot message
  appeared during the bounded run;
- normal `Ctrl+C` logged `CAMERA CLOSED` and both physical cameras immediately
  returned to `AVAILABLE`, with no daemon restart or reboot.

A nine-second post-rate snapshot while the live node remained open showed
2.473-2.474 GiB total system RAM in use, GPU temperature 50.8-51.1 C, junction
temperature 50.9-51.2 C, and input power 7.20-7.36 W. GPU activity varied with
the lazy subscriber workload. These are local acceptance observations, not
field-network limits.

## Network payload contract

The demanding local verifier intentionally subscribes to the uncompressed base
topics. At the measured live rates their nominal payload is approximately:

- BGR image: 960 x 600 x 3 x 4.841 = 8.37 MB/s;
- float depth: 960 x 600 x 4 x 5.000 = 11.52 MB/s;
- reduced XYZRGB cloud: 224 x 128 x 16 x 1.995 = 0.92 MB/s.

That is about 20.8 MB/s before DDS overhead, which is why the committed RViz
launcher subscribes directly with `compressed` for color and `compressedDepth`
for depth. Only the Draco cloud needs a workstation-local decoder to become the
standard `PointCloud2` consumed by this Humble RViz display.

## Acceptance still requiring external hardware

The following are not claimed as passed:

- provisioning and offline-cache rehearsal on a named Ubuntu 22.04 x86_64
  receiver;
- wired-LAN discovery, compressed-transport bandwidth, latency, loss, RViz
  rendering, and disconnect/reconnect from that receiver;
- the same measurements on the actual field Wi-Fi;
- a full no-internet, two-machine cold-start rehearsal.

Those gates cannot be honestly completed on the Jetson alone. They do not
block local live use, local SVO replay, or direct SVO2 recording.
