# Headless Remote SVO2 Replay

This is the normal field-review workflow when the Jetson has no monitor. The
Jetson retains each raw SVO2, uses its NVIDIA GPU and the installed virtual
calibration to recompute NEURAL depth and the colored point cloud, and publishes
standard ROS 2 topics. The Ubuntu ThinkPad runs RViz and needs neither the ZED
SDK nor CUDA.

## Browse and start a recording

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

The command validates the selected finalized `.svo2` frame index and
virtual serial, starts a named headless Jetson replay unit, pauses and rewinds
to frame zero, opens RViz locally, and republishes frame zero after RViz is
ready. Before starting, it displays a numbered remote dataset directory with
capture time, size, and filename. Press Enter for the newest file or type an
index. A currently loaded replay is marked `[ACTIVE]`. It never needs a Jetson
desktop session or attached display.

## Select a recording

```bash
# Show finalized recordings, newest first.
./scripts/zed_replay_console.sh --jetson zed-jetson --list

# Skip the interactive directory and immediately replay newest.
./scripts/zed_replay_console.sh --jetson zed-jetson --latest

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
| `Space` or `p` | Play or pause. At end-of-file, use `o` to reopen. |
| `Right Arrow` | While paused, process the next sequential frame and pause again. |
| `Up` / `Down`, or `+` / `-` | Increase/reduce playback speed through 0.1x–5x presets. |
| `o` | Open the remote dataset directory and switch recordings. |
| `i` | Print detailed file, frame, loop, speed, and unit status. |
| `v` | Restart RViz without seeking or changing replay position. |
| `h` | Print the key reference. |
| `q` | Stop the named Jetson replay unit and close RViz. |

The fixed footer shows `PLAYING`, `PAUSED`, or `END`, current and total time,
frame position, requested speed, measured output FPS, loop count, RViz state,
and filename. `ZED PROCESSING` means the replay unit is still active but the
Jetson has not completed another frame for at least five seconds. While a key
command is pending, the footer explicitly says it is waiting for the Jetson/ZED
SDK. Successful controls update the footer in place instead of printing a full
status block for every key.

A persistent Jetson-side controller keeps the ROS services discovered, so each
workstation key does not pay a fresh DDS-discovery delay. A failed or timed-out
control no longer exits the workstation console: it displays a red warning,
keeps the replay attached, and leaves `i`, `v`, and `q` available.

The playback keys follow the useful subset of `ros2 bag play`: Space toggles
pause, Right Arrow advances once while paused, and Up/Down adjusts rate.
Right Arrow is not implemented as a seek. The Jetson controller temporarily
uses the minimum sequential playback rate, allows exactly one normal grab,
pauses before another scheduled grab, waits for the wrapper's small post-grab
health message, and restores the selected rate. It never calls `set_svo_frame`
for this control. If a frame does not complete within five seconds, the command
returns a bounded error with playback still paused rather than waiting on a
seek indefinitely.

Backward seeking and time scrubbing are deliberately not offered. On this rig,
the ZED wrapper serializes `set_svo_frame` behind an in-flight HD1200 NEURAL
grab; an observed one-second rewind took 11.5 seconds. To revisit an earlier
time, press `o`, reopen the dataset from frame zero, reduce the playback rate,
and play or step forward.

Choosing `o` lists the current Jetson files before stopping anything. Cancelling
leaves the current replay untouched. After a selection, the console cleanly
stops the old replay, starts the selected SVO2 paused at frame zero, retains or
reopens RViz, and republishes the first frame.

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

## Playback rate and apparent stalls

`1.0x` is the requested SVO rate, not a promise that the Orin Nano can generate
HD1200 NEURAL depth and the point cloud at 15 frames per second. Controlled
replay deliberately processes every recorded frame. On this rig, NEURAL replay
can therefore advance video time more slowly than wall time when RGB, depth,
and point-cloud subscribers are active. Read the footer's `OUTPUT≈...fps`
measurement to distinguish slow processing from a stopped unit.

Frame positioning is used internally only while initially opening a dataset at
frame zero. The console does not expose it as a scrubbing or RViz-reconnect
control.

For a weaker or congested field network, begin at half-rate to reduce the
publication target and use `+` later if the link is healthy:

```bash
./scripts/zed_replay_console.sh \
  --jetson dusty@ubuntu.local \
  --remote-root /home/dusty/workspace/terraforming_mars/zed-x-one-rig \
  --rate 0.5
```

ROS 2 DDS participants select a network interface when they start. If either
computer moves between AsteraMesh and Mars while replay is open, stop and
relaunch the replay after both machines are on the new network. Do not reuse a
unit that was started on the previous subnet; its DDS sockets still target the
old address even though SSH may reconnect.

## Manual Jetson fallback

If the workstation controller is unavailable, the Jetson helper remains fully
usable over SSH:

```bash
cd /home/dusty/workspace/terraforming_mars/zed-x-one-rig
./scripts/zed_replay_session.sh list
./scripts/zed_replay_session.sh start --latest
./scripts/zed_replay_session.sh pause-toggle
./scripts/zed_replay_session.sh next
./scripts/zed_replay_session.sh speed 0.5
./scripts/zed_replay_session.sh status
./scripts/zed_replay_session.sh stop
```

The lower-level foreground `scripts/play_svo_ros2.sh` remains available for
diagnostics. Its `--controlled` mode enables the wrapper pause and dynamic
replay-rate interfaces used by this console.
