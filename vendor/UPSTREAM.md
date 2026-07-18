# Vendored calibration toolkit

`vendor/zed-opencv-calibration/` is an unmodified source snapshot of:

```text
Repository: https://github.com/stereolabs/zed-opencv-calibration.git
Commit:     903c775
Commit:     Merge pull request #7 from stereolabs/add_calibration_checker
Branch at snapshot time: main
```

It is vendored so the calibration, calibration-checker, and reprojection tools
can be rebuilt in the field without network access. Rig-specific source and
configuration live outside this vendor directory.
