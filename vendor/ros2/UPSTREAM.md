# Pinned ROS 2 upstream assets

These small upstream assets are committed so the rig does not depend on GitHub
availability in the field.

## ZED ROS 2 wrapper

- Repository: <https://github.com/stereolabs/zed-ros2-wrapper>
- Tag: `v5.4.0`
- Commit: `6545933af94d70922881654e6fb29d95e3a8f14f`
- Archive: `zed-ros2-wrapper-v5.4.0.tar.gz`
- SHA-256:
  `e8b514f0bba6b759db07c0e2bbb838565a28a60ce7b62667e8c3d707a2eb3b87`

The archive was produced with:

```bash
git -C zed-ros2-wrapper archive \
  --format=tar.gz \
  --output=zed-ros2-wrapper-v5.4.0.tar.gz \
  v5.4.0
```

## ROS apt-source bootstrap

- Repository: <https://github.com/ros-infrastructure/ros-apt-source>
- Release: `1.2.0`
- Asset: `ros2-apt-source_1.2.0.jammy_all.deb`
- SHA-256:
  `767884cf4ed03116b9d64438930a832ed854147ae435279a7924dfdf60f94433`

The package installs the official ROS 2 apt repository definition and key for
Ubuntu 22.04 Jammy. Architecture-specific ROS package caches are generated
under `offline/ros2/` and are intentionally excluded from Git.
