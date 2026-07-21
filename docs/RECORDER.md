# Virtual Stereo Recorder

The custom recorder opens the two physical cameras through the ZED SDK virtual
stereo API, verifies virtual serial `116863460`, and records one synchronized
SVO2 containing both image streams. NEURAL depth is computed during playback;
it is not baked into the recording.

## Copy/paste commands

Proven maximum-fidelity recording:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh --lossless
```

One minute at 15 FPS with an explicit filename:

```bash
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/scripts/record_virtual_stereo.sh \
  --lossless --frames 900 \
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
--h264          Experimental H.264; not validated on this virtual pair
--h265          Experimental H.265; not validated on this virtual pair
-h, --help      Full help and copy/paste commands
```

The current recorder is fixed at 1920x1200 and 15 FPS. Bounded tests on
2026-07-21 found that H.264 and H.265 start requests were accepted but every
frame was rejected on this virtual-stereo path. Use lossless for field data.
The remote field console therefore exposes lossless only.

## Storage

The measured lossless rate on this rig was approximately 56 MB/s, or 3.4
GB/minute. Actual lossless size depends on scene content. Lossy sizes depend on
the SDK-selected encoder bitrate.

Lossy compression would change the left and right images used to compute depth
during playback. Do not rely on the low-level lossy switches unless a future
rig-specific test produces a finalized, indexed file and successful replay.

For simultaneous RViz viewing and recording, use the workstation-side field
console documented in `docs/FIELD_CONSOLE.md`. It records lossless native stereo
through the already-open ROS wrapper while ROS publishes the reduced preview.

## Safe shutdown and validation

Press `Ctrl+C`, wait for `Finalizing SVO2`, and confirm a nonzero encoded frame
count. Validate the result with:

```bash
ZED_SVO_Editor -inf /home/dusty/Videos/ZED/RECORDING.svo2
```

Do not remove power while the file is being finalized.
