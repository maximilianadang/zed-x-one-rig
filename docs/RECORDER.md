# Virtual Stereo Recorder

The custom recorder opens the two physical cameras through the ZED SDK virtual
stereo API, verifies virtual serial `116863460`, and records one synchronized
SVO2 containing both image streams. NEURAL depth is computed during playback;
it is not baked into the recording.

## Copy/paste commands

Recommended smaller H.264 field recording:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --h264
```

Maximum-fidelity lossless recording:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --lossless
```

One minute at 15 FPS:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh \
  --h264 --frames 900 \
  --output /home/dusty/Videos/ZED/field_test.svo2
```

Complete built-in help:

```bash
./scripts/record_virtual_stereo.sh --help
```

## Implemented controls

```text
--output PATH   Output .svo2 path; default is ~/Videos/ZED/timestamp.svo2
--frames N      Stop after N successfully grabbed frames
--preview       Experimental and not reliable on this Jetson
--no-preview    Headless recording; this is the default
--lossless      PNG/ZSTD; maximum fidelity and largest files
--h264          H.264 lossy; much smaller and may affect depth
--h265          H.265 lossy; requires working encoder support
-h, --help      Full help and copy/paste commands
```

The current recorder is fixed at 1920x1200 and 15 FPS. The installed SDK can
accept explicit H.264/H.265 recording bitrates, but this recorder revision does
not yet expose a bitrate CLI option.

## Storage

The measured lossless rate on this rig was approximately 56 MB/s, or 3.4
GB/minute. Actual lossless size depends on scene content. Lossy sizes depend on
the SDK-selected encoder bitrate.

Lossy compression changes the left and right images used to compute depth
during playback. Prefer lossless for calibration and quantitative validation.
Validate a chosen lossy mode against a short lossless reference before relying
on it for measurements.

## Safe shutdown and validation

Press `Ctrl+C`, wait for `Finalizing SVO2`, and confirm a nonzero encoded frame
count. Validate the result with:

```bash
ZED_SVO_Editor -inf /home/dusty/Videos/ZED/RECORDING.svo2
```

Do not remove power while the file is being finalized.
