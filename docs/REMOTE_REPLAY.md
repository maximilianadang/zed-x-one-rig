# Headless Remote SVO2 Replay

This is the normal field-review workflow when the Jetson has no monitor. The
Jetson retains each raw SVO2, uses its NVIDIA GPU and the installed virtual
calibration to recompute NEURAL depth and the colored point cloud, and publishes
standard ROS 2 topics. The Ubuntu ThinkPad runs RViz and needs neither the ZED
SDK nor CUDA.

## Start the newest recording

First stop a live camera session with `q`. Then, from this repository on the
ThinkPad:

```bash
./scripts/zed_replay_console.sh --jetson zed-jetson
```

With mDNS instead of the recommended SSH alias:

```bash
./scripts/zed_replay_console.sh \
  --jetson dusty@ubuntu.local \
  --remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig
```

The command selects the newest finalized `.svo2`, validates its frame index and
virtual serial, starts a named headless Jetson replay unit, pauses and rewinds
to frame zero, opens RViz locally, and republishes frame zero after RViz is
ready. It never needs a Jetson desktop session or attached display.

## Select a recording

```bash
# Show finalized recordings, newest first.
./scripts/zed_replay_console.sh --jetson zed-jetson --list

# Replay the third-newest recording.
./scripts/zed_replay_console.sh --jetson zed-jetson --index 3

# Replay an exact path stored on the Jetson.
./scripts/zed_replay_console.sh --jetson zed-jetson \
  --svo /home/dusty/Videos/ZED/virtual_stereo_YYYYMMDD_HHMMSS.svo2

# Loop the selected recording.
./scripts/zed_replay_console.sh --jetson zed-jetson --index 2 --loop
```

Files ending in `.recording.svo2` are deliberately excluded because they were
not confirmed as finalized. Selection index `1` always means newest.

## Controls

| Key | Action |
|---|---|
| `Space` or `p` | Play or pause. At end-of-file, return to the beginning. |
| `Left` / `Right`, or `j` / `l` | Pause and step backward/forward one second. |
| `,` / `.` | Pause and step backward/forward one frame. |
| `J` / `L` | Pause and step backward/forward ten seconds. |
| `-` / `+` | Reduce/increase playback speed through 0.1x–5x presets. |
| `0` | Pause and return to frame zero. |
| `i` | Print detailed file, frame, loop, speed, and unit status. |
| `v` | Reopen RViz and republish the current paused frame. |
| `h` | Print the key reference. |
| `q` | Stop the named Jetson replay unit and close RViz. |

The fixed footer shows `PLAYING`, `PAUSED`, or `END`, current and total time,
frame position, speed, loop count, RViz state, and filename. Seeking is clamped
to the valid frame range. Step commands always pause first. A persistent
Jetson-side controller keeps the ROS services discovered, so each workstation
key does not pay a fresh DDS-discovery delay.

## Disconnect and recovery

`Ctrl+C`, terminal closure, ThinkPad sleep, or Wi-Fi loss closes local RViz but
leaves the named Jetson replay unit running. Reconnect with the same replay
command. To inspect or stop it without opening RViz:

```bash
./scripts/zed_replay_console.sh --jetson zed-jetson --status
./scripts/zed_replay_console.sh --jetson zed-jetson --stop
```

The live field console and replay console are mutually exclusive because both
publish the same `/zed/zed_node` interface. Close one normally before opening
the other. Replay does not open or require the physical GMSL cameras.

## Manual Jetson fallback

If the workstation controller is unavailable, the Jetson helper remains fully
usable over SSH:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/zed_replay_session.sh list
./scripts/zed_replay_session.sh start --latest
./scripts/zed_replay_session.sh pause-toggle
./scripts/zed_replay_session.sh step 15
./scripts/zed_replay_session.sh speed 0.5
./scripts/zed_replay_session.sh status
./scripts/zed_replay_session.sh stop
```

The lower-level foreground `scripts/play_svo_ros2.sh` remains available for
diagnostics. Its `--controlled` mode enables the native wrapper pause, seek, and
dynamic replay-rate interfaces used by this console.
