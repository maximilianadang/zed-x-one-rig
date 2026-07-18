# Near-Field Stereo Math for This Dual ZED X One Rig

Last updated: 2026-07-17

This note derives the near-field limits for this specific calibrated rig. The key conclusion is:

> Correction: the available information does **not** justify calling `1.5 m` a minimum, or even a predicted practical minimum. The hard rectified-overlap boundary is about `0.642 m`. The number `1.5 m` can be produced only by adding an unsupported assumption—such as requiring 57% horizontal overlap or assuming an 820-pixel matcher limit. Neither assumption is a published ZED specification or a measured threshold for this rig.

## Rig values used

These values were read through ZED SDK 5.4.0 from the valid recording `virtual_stereo_20260717_145159.svo2` and the installed virtual-camera calibration:

| Quantity | Symbol | Value |
|---|---:|---:|
| Image width per eye | `W` | `1920 px` |
| Full 3D baseline | `B` | `0.8518099 m` |
| Raw focal length | `f_raw` | `727.329 px` |
| Raw horizontal field of view | `theta_raw` | `108.378 deg` |
| Rectified focal length used by depth | `f_rect` | `1446.177 px` |
| Rectified horizontal field of view | `theta_rect` | `67.156 deg` |
| SDK-selected minimum-depth clip | `Z_SDK_min` | `0.322624 m` |
| SDK-selected maximum-depth clip | `Z_SDK_max` | `20.0 m` |

The calibration assigns physical left camera SN `304467158`, physical right camera SN `306605936`, and virtual stereo SN `116863460`.

The installed `.conf` lists `Baseline = 851.662 mm`, which is the dominant horizontal translation component. The full length of the three-dimensional camera-center translation is `851.810 mm`; that full length is the `B` used here.

## What is known about the SDK rectification output

We do not have the ZED SDK source code for its crop/zoom selection, remap generation, or proprietary NEURAL matcher. We therefore do not know why it selected this particular rectified focal length, its internal valid-pixel ROI, or the largest disparity the neural model can match reliably.

We **can** inspect the result exposed through the public SDK. For this SVO, `camera_configuration.calibration_parameters` reports the post-rectification projection used for the `VIEW::LEFT` and `VIEW::RIGHT` images that feed depth estimation:

```text
Output size: 1920 x 1200 per eye

K_left = K_right =
  [ 1446.1765       0       1022.2148 ]
  [      0       1446.1765   621.2672 ]
  [      0           0          1     ]

R_rectified = identity
T_rectified = [ 0.8518099, 0, 0 ] meters
```

The raw SDK calibration reports approximately `108.38 deg` horizontal FOV and `727.33 px` focal length. The post-rectification calibration reports approximately `67.16 deg` horizontal FOV and `1446.18 px` focal length. This demonstrates that the SDK's output rectification is substantially zoomed/cropped relative to the raw wide-angle view, even though the internal rule that chose that output is opaque.

Because both rectified eyes have identical intrinsics, zero relative rotation, and a purely horizontal baseline, the standard rectified disparity and common-domain equations below apply directly to the SDK-reported output geometry. They establish visibility bounds, but not the success rate of the proprietary matcher within those bounds.

## 1. Pure field-of-view overlap

For two ideal parallel cameras separated by baseline `B`, each with horizontal field of view `theta`, the two horizontal viewing cones first overlap on the center plane at:

```text
Z_overlap = B / (2 tan(theta / 2))
```

### Using the raw wide-angle views

```text
Z_raw_overlap
  = 0.8518099 / (2 tan(108.378 deg / 2))
  = 0.3073 m
```

Thus, the wide-angle lenses really do help: the raw images begin to have common central coverage at about `0.31 m`.

### Using the rectified views that feed depth

The SDK reports a narrower rectified field of view for the images used by its depth pipeline:

```text
Z_rect_overlap
  = 0.8518099 / (2 tan(67.156 deg / 2))
  = 0.6416 m
```

Below approximately `0.642 m`, there is no horizontal location visible in both complete rectified pinhole views under this simplified parallel-camera model. At exactly that boundary, the common image width is effectively zero. This is a geometric bound, independent of the choice of NEURAL, NEURAL LIGHT, or another matcher.

The real calibration includes small rotations and small vertical/forward offsets. Rectification absorbs most of these, so the parallel rectified model is the appropriate first-order calculation, but the actual boundary will not be a perfectly flat plane.

## 2. Disparity versus distance

For a rectified stereo pair:

```text
d = f B / Z
```

where:

- `d` is horizontal disparity in pixels;
- `f` is rectified focal length in pixels;
- `B` is baseline in meters;
- `Z` is forward depth in meters.

For this rig:

```text
f_rect B = 1446.1765 * 0.8518099
         = 1231.8675 pixel-meters

d = 1231.8675 / Z
Z = 1231.8675 / d
```

Examples:

| Distance `Z` | Disparity `d` | Common horizontal width `W-d` | Common fraction `(W-d)/W` |
|---:|---:|---:|---:|
| `0.642 m` | about `1920 px` | about `0 px` | about `0%` |
| `1.00 m` | `1232 px` | `688 px` | `35.8%` |
| `1.25 m` | `985 px` | `935 px` | `48.7%` |
| `1.50 m` | `821 px` | `1099 px` | `57.2%` |
| `1.75 m` | `704 px` | `1216 px` | `63.3%` |
| `2.00 m` | `616 px` | `1304 px` | `67.9%` |
| `2.50 m` | `493 px` | `1427 px` | `74.3%` |
| `3.00 m` | `411 px` | `1509 px` | `78.6%` |

This explains why the transition is gradual rather than a sharp dead-zone wall. Just past `0.642 m`, only a narrow strip can possibly match. As distance increases, more of the two images overlaps, disparity falls, occlusion decreases, and the matcher has more usable context.

## 3. How an added assumption can manufacture a `1.5 m` result

The geometry alone does not select `1.5 m`. Two possible extra assumptions happen to produce that number, but neither is currently supported by ZED documentation or a controlled measurement of this rig.

### Criterion A: require a chosen common-image fraction

Let `p` be the desired fraction of each 1920-pixel rectified image that has a corresponding horizontal region in the other image:

```text
p = (W - d) / W
```

Substitute `d = fB/Z` and solve for `Z`:

```text
Z_required = f B / (W (1 - p))
```

For this rig:

| Required common fraction `p` | Required distance `Z` |
|---:|---:|
| `25%` | `0.855 m` |
| `40%` | `1.069 m` |
| `50%` | `1.283 m` |
| `55%` | `1.426 m` |
| `57%` | `1.492 m` |
| `60%` | `1.604 m` |
| `67%` | `1.944 m` |
| `75%` | `2.566 m` |

Therefore, `1.5 m` corresponds to requiring about `57%` common horizontal support. There is no mathematical or documented ZED reason to choose 57% instead of 40%, 50%, 60%, or another value. This calculation describes the consequence of the assumption; it does not validate the assumption.

### Criterion B: assume a practical maximum reliable disparity

If a matcher has a practical reliable maximum disparity `d_max`, then:

```text
Z_practical_min = f B / d_max
```

Sensitivity for this rig:

| Assumed `d_max` | Implied practical minimum |
|---:|---:|
| `1200 px` | `1.027 m` |
| `1000 px` | `1.232 m` |
| `960 px` | `1.283 m` |
| `820 px` | `1.502 m` |
| `800 px` | `1.540 m` |
| `768 px` | `1.604 m` |
| `600 px` | `2.053 m` |
| `512 px` | `2.406 m` |

Thus, saying “approximately `1.5 m`” is equivalent to assuming reliable matching through roughly `800–820 px` of disparity. Stereolabs does not publish a hard `d_max` for its NEURAL model, and we have not measured one for this rig. Consequently, this table cannot establish a practical minimum.

## 4. Why the SDK minimum of 0.323 m does not guarantee points there

The probed `depth_minimum_distance = 0.322624 m` is a clipping parameter: depths smaller than it will not be returned. It is not a promise that the stereo matcher can produce valid depth at every pixel immediately beyond that value.

At `0.322624 m`, the rectified disparity equation gives:

```text
d = 1231.8675 / 0.322624
  = 3818 px
```

That is almost twice the entire 1920-pixel image width, so the rectified views have no common horizontal image region under the ideal model. Lowering the SDK minimum-depth control cannot create correspondence where the second camera has no matching view.

## 5. Other effects that push the useful minimum farther away

The equations above describe only ideal horizontal visibility. Real point-cloud density is also reduced by:

- occlusion: a close foreground object exposes very different surfaces to cameras separated by 0.852 m;
- low texture or repeated texture;
- specular, transparent, or emissive surfaces;
- motion between non-simultaneous exposures or motion blur;
- confidence and texture-confidence filtering;
- vertical mismatch from imperfect calibration or mechanical movement;
- the proprietary disparity range and training distribution of the NEURAL model.

Consequently, `0.642 m` is a theoretical rectified-overlap boundary. No defensible practical transition distance follows from the available geometry alone. A value such as `1.5 m` or `2 m` requires measured validity/error criteria or an authoritative matcher disparity specification.

## 6. How to measure the practical minimum for this rig

To replace the heuristic with an empirical number:

1. Place a richly textured, matte target centered between the two optical axes.
2. Keep it approximately perpendicular to the rig's forward axis.
3. Record it at measured distances such as `0.75`, `1.0`, `1.25`, `1.5`, `1.75`, `2.0`, and `2.5 m`.
4. Use the same depth mode and confidence settings intended for field work.
5. For a fixed central region of interest, compute the percentage of pixels with finite valid depth and the median absolute depth error.
6. Define the practical minimum using an application-specific requirement, for example at least `80%` valid pixels and less than `5%` median error.

The resulting distance is the defensible minimum for the target type, lighting, depth mode, and filter settings tested. Until that experiment is performed, the only justified numeric statements are the SDK clip (`0.3226 m`) and the ideal rectified common-domain boundary (`0.6416 m`); neither guarantees successful matching.

## 7. Small calculator

This uses only Python's standard library:

```python
import math

B = 0.8518099       # meters
W = 1920            # pixels per rectified eye
f = 1446.1765       # rectified focal length, pixels
hfov = 67.15594     # rectified horizontal FOV, degrees

z_overlap = B / (2 * math.tan(math.radians(hfov / 2)))
print("first rectified overlap:", z_overlap, "m")

for z in (0.642, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0):
    disparity = f * B / z
    overlap_fraction = max(0.0, 1.0 - disparity / W)
    print(z, "m:", disparity, "px disparity,",
          100 * overlap_fraction, "% common width")

for desired_overlap in (0.50, 0.55, 0.57, 0.60, 0.67):
    z = f * B / (W * (1 - desired_overlap))
    print(100 * desired_overlap, "% common width requires", z, "m")
```

## 8. Empirical result from the shorter 14:51 capture

The complete valid recording below was processed through ZED SDK 5.4.0 using `DEPTH_MODE::NEURAL`:

```text
/home/dusty/Videos/ZED/virtual_stereo_20260717_145159.svo2
```

Analysis settings and input:

| Item | Value |
|---|---:|
| Frames | `159` |
| Resolution | `1920 x 1200` |
| Confidence threshold | `95` |
| Texture-confidence threshold | `100` |
| Valid depth samples | `17,904,297 / 366,336,000` (`4.887%`) |
| Valid samples per frame | min `52,132`; median `116,530`; max `162,999` |

### Nearest returned measurements

| Statistic | Z depth | Euclidean range from left optical center |
|---|---:|---:|
| Absolute nearest sample in all frames | `0.7405 m` | `0.7806 m` absolute range minimum |
| Per-frame nearest sample, median | `0.7737 m` | `0.8736 m` |
| Per-frame 100th-nearest sample, minimum | `0.7501 m` | `0.7842 m` |
| Per-frame 100th-nearest sample, median | `0.7806 m` | `0.8797 m` |
| Per-frame 1000th-nearest sample, median | `0.8915 m` | `0.9845 m` |

The absolute minimum-Z sample occurred in frame 9 at pixel `(1906, 910)`, almost at the extreme right edge, and had Euclidean range `0.8803 m`. It should not be treated alone as a robust near-range result. The absolute minimum Euclidean-range point was `0.7806 m` away in frame 0 at pixel `(1118, 198)`, with Z depth `0.7476 m`.

### Support across frames

| Threshold | Total Z-depth samples below it | Frames with >=1 | Frames with >=100 | Frames with >=1000 |
|---:|---:|---:|---:|---:|
| `0.70 m` | `0` | `0 / 159` | `0 / 159` | `0 / 159` |
| `0.75 m` | `202` | `7 / 159` | `0 / 159` | `0 / 159` |
| `0.80 m` | `38,915` | `159 / 159` | `157 / 159` | `8 / 159` |
| `0.90 m` | `218,175` | `159 / 159` | `159 / 159` | `93 / 159` |
| `1.00 m` | `422,552` | `159 / 159` | `159 / 159` | `149 / 159` |
| `1.25 m` | `733,306` | `159 / 159` | `159 / 159` | `156 / 159` |
| `1.50 m` | `805,857` | `159 / 159` | `159 / 159` | `157 / 159` |

For Euclidean range rather than forward Z depth, no returned point was closer than `0.75 m`. Six frames contained some points within `0.80 m`; 127 frames contained at least 100 points within `0.90 m`; and 94 frames contained at least 1000 points within `1.00 m`.

### What this capture establishes

- It disproves `1.5 m` as a hard minimum: this recording contains persistent returned depth substantially closer than `1.5 m`.
- For the scene and default confidence settings recorded, returns begin around `0.74–0.78 m`, with stronger support around `0.8–1.0 m`.
- It does **not** prove that the rig cannot measure below `0.74 m`. The capture may simply contain no suitable textured surface in the shared field of view between `0.642 m` and `0.74 m`.
- It does **not** establish accuracy. A known-distance target is required to compare returned depth with ground truth.
- Only `4.887%` of all image pixels had valid depth, so point-cloud sparsity remains significant even though close returns exist.

The reusable analysis script is:

```text
/home/dusty/workspace/terraforming_mars/zed-x-one-rig/tools/analyze_svo_near_depth.py
```

Run it with:

```bash
python3 /home/dusty/workspace/terraforming_mars/zed-x-one-rig/tools/analyze_svo_near_depth.py \
  /path/to/recording.svo2
```

## 9. Empirical result from the latest/longest 15:09 capture

The latest and longest recording was analyzed separately over all 371 frames:

```text
/home/dusty/Videos/ZED/virtual_stereo_20260717_150912.svo2
```

Analysis settings and input:

| Item | Value |
|---|---:|
| Frames | `371` |
| Resolution | `1920 x 1200` |
| Confidence threshold | `95` |
| Texture-confidence threshold | `100` |
| Valid depth samples | `576,514,604 / 854,784,000` (`67.446%`) |
| Valid samples per frame | min `585,823`; median `1,597,197`; max `1,920,178` |

### Absolute and robust nearest statistics

| Statistic | Z depth | Euclidean range |
|---|---:|---:|
| Absolute nearest sample | `0.9638 m` | `1.0636 m` |
| Per-frame nearest sample, median | `1.4419 m` | `1.6226 m` |
| Per-frame 100th-nearest sample, minimum | `0.9703 m` | `1.0683 m` |
| Per-frame 100th-nearest sample, median | `1.4766 m` | `1.6497 m` |
| Per-frame 1000th-nearest sample, minimum | `1.0694 m` | `1.1932 m` |
| Per-frame 1000th-nearest sample, median | `1.6274 m` | `1.7518 m` |
| Per-frame 10000th-nearest sample, minimum | `1.4865 m` | `1.5805 m` |
| Per-frame 10000th-nearest sample, median | `1.8267 m` | `2.0334 m` |

The absolute minimum occurred in frame 285 at pixel `(758, 0)`, directly on the top image boundary. A `0.95–1.05 m` overlay found only 1,213 target-band pixels across six frames, concentrated primarily along that ceiling/image boundary. These are weak edge matches and should not be interpreted as a physical object at one meter.

Support below selected Z thresholds:

| Z threshold | Total pixels | Frames with >=1 | Frames with >=100 | Frames with >=1000 | Frames with >=10000 |
|---:|---:|---:|---:|---:|---:|
| `1.00 m` | `582` | `2 / 371` | `1 / 371` | `0 / 371` | `0 / 371` |
| `1.25 m` | `34,996` | `49 / 371` | `36 / 371` | `11 / 371` | `0 / 371` |
| `1.50 m` | `387,777` | `225 / 371` | `201 / 371` | `121 / 371` | `1 / 371` |
| `1.75 m` | `2,716,189` | `330 / 371` | `321 / 371` | `262 / 371` | `99 / 371` |
| `2.00 m` | `16,901,301` | `360 / 371` | `359 / 371` | `346 / 371` | `306 / 371` |

### Nearest coherent visible region

A second overlay covering `1.10–1.30 m` found 58,301 pixels across 73 frames. The strongest frame contained 3,482 pixels in this band. Its median highlighted location was:

```text
pixel:             (1534, 988)
XYZ:               (0.405, 0.290, 1.144) m
Euclidean range:   1.247 m
```

Visually, these returns lie mainly on the dark curved/vertical object immediately to the right of the white/gray equipment in the lower-right portion of the rectified left image. This is the nearest clearly coherent surface found in the latest capture. It should be checked with a tape measure from the left-camera optical center: approximately `1.247 m` straight-line distance, or approximately `1.144 m` forward Z separation.

Annotated results:

```text
/home/dusty/Videos/ZED/virtual_stereo_20260717_150912_Z_1.000m_pm_0.050m_2/annotated_depth_band.ogv
/home/dusty/Videos/ZED/virtual_stereo_20260717_150912_Z_1.200m_pm_0.100m_2/annotated_depth_band.ogv
```

This latest capture therefore supports three distinct statements: the numerical minimum is `0.9638 m`; that minimum is probably an image-edge mismatch; and the nearest coherent visible region found by inspection is around `1.14 m` Z / `1.25 m` Euclidean range.

## 10. Depth-band highlighter

To locate a particular Z-depth in the rectified left image, use the offline highlighter:

```bash
python3 /home/dusty/workspace/terraforming_mars/zed-x-one-rig/tools/highlight_svo_depth_band.py \
  /path/to/recording.svo2 \
  --target 0.90 \
  --tolerance 0.025 \
  --video
```

This highlights SDK NEURAL Z-depths from `0.875–0.925 m` in magenta. With `--video`, it writes a full-length, 15 FPS annotated `.ogv` video that opens in the Jetson's standard video player. It also writes full-resolution top frames, a contact sheet, a per-frame CSV, and a summary beside the SVO. The cyan cross is the median highlighted pixel. The yellow rectangle contains all highlighted pixels in that frame; it is not a connected-object bounding box. The reported Z value is forward depth in the rectified left-camera coordinate system, while `euclidean_range_m` is the straight-line distance from the left optical center.

The `.ogv` default is intentional: this Jetson has local Theora encoding and decoding support, whereas its standard H.264 software-decoder plugin is absent. `--video-format mp4` makes a smaller H.264 file for moving to another computer; `--video-format mjpeg` makes an MJPEG AVI.

## References

- Installed calibration: `/usr/local/zed/settings/SN116863460.conf`
- Persistent calibration source: `/home/dusty/workspace/terraforming_mars/zed-x-one-rig/calibration/active/SN116863460.conf`
- Stereolabs depth settings: https://docs.stereolabs.com/docs/development/zed-sdk/modules/depth-sensing/depth-settings
- Stereolabs depth modes and baseline note: https://docs.stereolabs.com/docs/development/zed-sdk/modules/depth-sensing/depth-modes
- Stereolabs camera calibration: https://docs.stereolabs.com/docs/development/zed-sdk/modules/camera/camera-calibration
