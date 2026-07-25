# Synthetic codec fixture v1

This non-sensitive fixture was generated on the rig Jetson with
`tools/publish_synthetic_codec_fixture.py` and encoded by the installed ROS
Humble transports:

- `compressed_image_transport` 2.5.5;
- `compressed_depth_image_transport` 2.5.5;
- `draco_point_cloud_transport` 1.0.14.

It contains a deterministic 96x60 color gradient, a metric 32-bit float depth
ramp with explicit invalid pixels, and a 256-point colored synthetic plume.
The JSON references contain the corresponding uncompressed ROS values.

The committed fixture is intentionally synthetic. A synchronized 960x600
fixture captured from finalized rig replay was used during T0/T1 validation,
but its RGB frame contained an identifiable person and was deleted rather than
placed in the public repository. That private validation produced:

- RGB and depth timestamp identity;
- 29,637 valid metric-depth pixels;
- a 1,404-point Draco cloud;
- browser depth agreement within 2 mm of the installed ROS decoder at the
  sampled positions;
- exact Draco point count, XYZ bounds/samples, and packed color bytes relative
  to the installed ROS decoder.

The fixture test permits 2 cm depth error against the synthetic pre-compression
source. That bound includes the installed compressed-depth transport's own
inverse-depth quantization at the far end of the 0.75-9.30 m test ramp; the
browser applies no additional quantization.
