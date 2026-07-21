# ROS 2 offline package caches

The committed repository contains the pinned ROS repository bootstrap and ZED
wrapper source under `vendor/ros2/`. Debian packages are architecture-specific
and too large for normal Git history, so online installer runs retain them here:

```text
jetson-arm64/debs/   Ubuntu 22.04 AArch64 Jetson packages
remote-amd64/debs/  Ubuntu 22.04 x86_64 workstation packages
```

Populate each cache on the matching machine while internet is available:

```bash
# Jetson
./scripts/install_ros2_jetson.sh

# Remote workstation
./scripts/install_ros2_remote.sh
```

Copy the populated cache with the repository for field use. Do not exchange
the AArch64 and x86_64 directories. The corresponding installer `--offline-dir`
option installs only from the supplied `.deb` files.
