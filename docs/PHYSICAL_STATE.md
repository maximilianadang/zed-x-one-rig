# Saved Physical Camera State

This is the configured left/right hardware identity. Enumeration was checked
again on 2026-10-14 for the new calibration. Left and right are defined while
looking forward from behind the camera rig.

| Role | Serial | ZED ID | GMSL port | I2C path |
|---|---:|---:|---:|---|
| Physical left | `306605936` | `1` | `2` | `/dev/i2c-10` |
| Physical right | `304467158` | `0` | `1` | `/dev/i2c-9` |

The operational virtual camera remains serial `117941018` and uses the verified
calibration checksum
`02f32f76dfce5dd99410f8e30983a98037cd3fde53557f675ccec92d9d7d38fe`.

## Required acquisition binding

ZED SDK 5.4.0 was observed to publish the physical views in reverse when the
ROS wrapper opened this pair through serial-number arguments. The live and
direct-recorder paths therefore open fixed camera IDs `[1,0]` and explicitly
retain virtual serial `117941018`.

IDs are not treated as identity by themselves. Before opening either camera,
the launch guard requires all four saved properties—serial, ID, port, and I2C
path—to agree. It refuses to start if enumeration or cabling ever differs.
Never work around that refusal by swapping browser labels.

## Historical field observations (July geometry)

The following older observations are not validation of the new calibration;
known-distance live validation is still pending.

Before correction, a timestamp-matched pair had negative foreground disparity
and the point cloud produced sparse false returns with a median distance near
`81 m`. With ID `1` as left and ID `0` as right, foreground disparity became
positive (about `212 px` on the visible screen support) and recovered depth was
concentrated around the visible foreground at roughly `3.2–3.5 m`.

The machine-readable copies of this state are `config/rig.env` and
`config/rig.yaml`.
