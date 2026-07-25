# ZED browser gateway protocol

Protocol version 1 carries each already-compressed ROS preview message as one
binary WebSocket message. RGB, depth, and cloud use separate sockets so a
large cloud cannot queue newer image frames behind it.

The gateway listens only on Jetson loopback. The workstation reaches it through
an authenticated SSH local-forward and supplies the per-gateway bearer token
in the WebSocket query string and HTTP `X-ZED-Token` header.

## Stream endpoints

- `/api/v1/stream/rgb?v=1&token=...`
- `/api/v1/stream/depth?v=1&token=...`
- `/api/v1/stream/cloud?v=1&token=...`

The gateway rejects a missing or unknown `v`. Browser requests must originate
from a loopback HTTP page. Non-browser diagnostic clients may omit `Origin`.

All integers in the fixed 32-byte header are little-endian:

| Offset | Type | Meaning |
|---:|---|---|
| 0 | 4 bytes | ASCII magic `ZXR1` |
| 4 | `uint16` | protocol version, currently `1` |
| 6 | `uint8` | stream: RGB `1`, depth `2`, cloud `3` |
| 7 | `uint8` | flags, currently `0` |
| 8 | `uint32` | per-stream sequence |
| 12 | `int32` | ROS header stamp seconds |
| 16 | `uint32` | ROS header stamp nanoseconds |
| 20 | `uint32` | UTF-8 JSON metadata byte count |
| 24 | `uint32` | compressed payload byte count |
| 28 | `uint32` | reserved, must be zero |

The small metadata document immediately follows the header. The compressed
payload follows the metadata. Large payloads are never JSON- or base64-encoded.

- RGB payload: the original `sensor_msgs/CompressedImage.data` JPEG.
- Depth payload: the original compressed-depth bytes, including the 12-byte
  transport configuration header followed by its 16-bit PNG.
- Cloud payload: the original
  `point_cloud_interfaces/CompressedPointCloud2.compressed_data` Draco stream.
  Metadata retains the PointCloud2 layout and Draco format.

Receivers must reject unknown versions, stream IDs, inconsistent lengths, or
messages above their documented stream limit.

## Control API

The HTTP API accepts only fixed operations that delegate to the existing
locked field/replay session helpers. It accepts no shell command, ROS topic,
ROS service, or arbitrary path.

- `GET /api/v1/status?mode=live|replay`
- `GET /api/v1/datasets`
- `POST /api/v1/lease`
- `POST /api/v1/lease/release`
- `POST /api/v1/live/record-start`
- `POST /api/v1/live/record-stop`
- `POST /api/v1/live/stop`
- `POST /api/v1/replay/toggle`
- `POST /api/v1/replay/next`
- `POST /api/v1/replay/speed` with body `up`, `down`, or `0.1` through `5.0`
- `POST /api/v1/replay/select` with a positive newest-first dataset index
- `POST /api/v1/replay/stop`

Responses are UTF-8 text. Status and dataset responses retain the machine
formats of the existing supervisors so the browser and terminal paths share
one source of truth.

Every browser creates a random 128-bit identifier and sends it as
`X-ZED-Controller`. The first viewer to acquire `/api/v1/lease` is the sole
controller. It renews its 30-second lease every five seconds; other authenticated
viewers remain read-only. A clean tab close releases the lease immediately,
while a crashed or disconnected controller releases it by expiry. Mutating
operations require both the bearer token and the active controller identifier.
