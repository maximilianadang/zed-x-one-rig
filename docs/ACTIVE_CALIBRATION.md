# Active calibration — 2026-10-14

The default live rig calibration is now SN117941018.conf, using 28 mm
checkerboard squares, 9x6 inner corners, and a fitted baseline of 244.410 mm.
Source session: zed-opencv-calibration/calibration-sessions/1792023751877379356.

Left: ID 1, serial 306605936, port 2. Right: ID 0, serial 304467158, port 1.
Preserve this physical ordering and camera geometry.

The SDK file is /usr/local/zed/settings/SN117941018.conf. Repository copies
are in calibration/active, together with zed_calibration_117941018.yml.
SHA256: 02f32f76dfce5dd99410f8e30983a98037cd3fde53557f675ccec92d9d7d38fe.

Rig configuration, calibration checksum guards, installer, console preflights,
and neural viewer paths have been updated. Existing browser launch commands
are unchanged. Restart any camera session to load the new calibration.

The pre-update configuration, scripts, active calibration, and RUNBOOK are
backed up in calibration/archive/pre-117941018-20261014_173416.
The old SDK SN116863460.conf remains installed for historical data. Do not
reinterpret old-baseline recordings using the new live calibration.

The replay helper currently checks against the active virtual serial; it will
reject old 116863460 recordings under the new rig configuration. Use the SDK
playback tools for those files, retaining their original geometry. Do not
rename an old calibration to bypass the guard.

The standalone recorder source and supplied Jetson binary have also been
updated to 117941018. The browser's ROS recording path is separate.

Checksum and camera identity checks passed. Known-distance live depth validation
is still required. Historical calibration documentation may describe the old rig;
this note and config/rig.yaml describe the new active geometry.
