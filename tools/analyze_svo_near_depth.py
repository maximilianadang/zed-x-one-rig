#!/usr/bin/env python3
"""Report empirical near-depth statistics from a ZED SVO2 recording."""

import argparse
import math
from pathlib import Path

import numpy as np
import pyzed.sl as sl


THRESHOLDS_M = np.array(
    [0.35, 0.40, 0.50, 0.60, 0.65, 0.70, 0.75, 0.80, 0.90,
     1.00, 1.25, 1.50, 1.75, 2.00, 2.50, 3.00],
    dtype=np.float64,
)
ORDER_STATISTICS = (1, 10, 100, 1000, 10000)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("svo", type=Path, help="Input .svo or .svo2 recording")
    return parser.parse_args()


def format_value(value):
    return "n/a" if not np.isfinite(value) else f"{value:.4f}"


def main():
    args = parse_args()
    if not args.svo.is_file():
        raise SystemExit(f"Input does not exist: {args.svo}")

    init = sl.InitParameters()
    init.set_from_svo_file(str(args.svo))
    init.svo_real_time_mode = False
    init.depth_mode = sl.DEPTH_MODE.NEURAL
    init.coordinate_units = sl.UNIT.METER

    camera = sl.Camera()
    error = camera.open(init)
    if error != sl.ERROR_CODE.SUCCESS:
        raise SystemExit(f"Could not open SVO: {error}")

    actual = camera.get_init_parameters()
    info = camera.get_camera_information()
    config = info.camera_configuration
    calibration = config.calibration_parameters
    width = config.resolution.width
    height = config.resolution.height
    fx = float(calibration.left_cam.fx)
    fy = float(calibration.left_cam.fy)
    cx = float(calibration.left_cam.cx)
    cy = float(calibration.left_cam.cy)

    runtime = sl.RuntimeParameters()
    depth_mat = sl.Mat()

    depth_minimum = math.inf
    depth_minimum_location = None
    range_minimum = math.inf
    range_minimum_location = None
    total_valid = 0
    total_pixels = 0
    frame_count = 0
    grab_errors = 0

    per_frame_valid = []
    per_frame_depth_order = []
    per_frame_range_order = []
    depth_threshold_counts = []
    range_threshold_counts = []

    while True:
        error = camera.grab(runtime)
        if error == sl.ERROR_CODE.END_OF_SVOFILE_REACHED:
            break
        if error != sl.ERROR_CODE.SUCCESS:
            grab_errors += 1
            continue

        camera.retrieve_measure(depth_mat, sl.MEASURE.DEPTH, sl.MEM.CPU)
        depth = np.asarray(depth_mat.get_data())
        valid_mask = np.isfinite(depth) & (depth > 0)
        y, x = np.nonzero(valid_mask)
        z = depth[valid_mask].astype(np.float64, copy=False)

        frame_count += 1
        total_pixels += depth.size
        total_valid += z.size
        per_frame_valid.append(z.size)

        if z.size == 0:
            per_frame_depth_order.append([math.nan] * len(ORDER_STATISTICS))
            per_frame_range_order.append([math.nan] * len(ORDER_STATISTICS))
            depth_threshold_counts.append([0] * len(THRESHOLDS_M))
            range_threshold_counts.append([0] * len(THRESHOLDS_M))
            continue

        radial_scale = np.sqrt(
            1.0 + ((x.astype(np.float64) - cx) / fx) ** 2
            + ((y.astype(np.float64) - cy) / fy) ** 2
        )
        distance = z * radial_scale

        z_min_index = int(np.argmin(z))
        if z[z_min_index] < depth_minimum:
            depth_minimum = float(z[z_min_index])
            depth_minimum_location = (
                frame_count - 1,
                int(x[z_min_index]),
                int(y[z_min_index]),
                float(distance[z_min_index]),
            )

        range_min_index = int(np.argmin(distance))
        if distance[range_min_index] < range_minimum:
            range_minimum = float(distance[range_min_index])
            range_minimum_location = (
                frame_count - 1,
                int(x[range_min_index]),
                int(y[range_min_index]),
                float(z[range_min_index]),
            )

        z_sorted = np.sort(z)
        range_sorted = np.sort(distance)
        per_frame_depth_order.append(
            [float(z_sorted[min(k - 1, z_sorted.size - 1)]) for k in ORDER_STATISTICS]
        )
        per_frame_range_order.append(
            [float(range_sorted[min(k - 1, range_sorted.size - 1)]) for k in ORDER_STATISTICS]
        )
        depth_threshold_counts.append(
            np.searchsorted(z_sorted, THRESHOLDS_M, side="left").tolist()
        )
        range_threshold_counts.append(
            np.searchsorted(range_sorted, THRESHOLDS_M, side="left").tolist()
        )

        if frame_count % 20 == 0:
            print(f"Processed {frame_count}/{camera.get_svo_number_of_frames()} frames", flush=True)

    camera.close()

    per_frame_valid = np.asarray(per_frame_valid, dtype=np.int64)
    per_frame_depth_order = np.asarray(per_frame_depth_order, dtype=np.float64)
    per_frame_range_order = np.asarray(per_frame_range_order, dtype=np.float64)
    depth_threshold_counts = np.asarray(depth_threshold_counts, dtype=np.int64)
    range_threshold_counts = np.asarray(range_threshold_counts, dtype=np.int64)

    print("\nINPUT")
    print(f"file: {args.svo}")
    print(f"frames processed: {frame_count}")
    print(f"grab errors: {grab_errors}")
    print(f"resolution: {width} x {height}")
    print(f"depth mode: {actual.depth_mode}")
    print(f"SDK min/max clip: {actual.depth_minimum_distance:.6f} / "
          f"{actual.depth_maximum_distance:.3f} m")
    print(f"runtime confidence thresholds: {runtime.confidence_threshold} / "
          f"{runtime.texture_confidence_threshold}")
    print(f"rectified fx/fy/cx/cy: {fx:.4f} / {fy:.4f} / {cx:.4f} / {cy:.4f}")

    print("\nVALIDITY")
    print(f"valid samples: {total_valid} / {total_pixels} "
          f"({100.0 * total_valid / total_pixels:.3f}%)")
    print(f"valid pixels per frame min/median/max: {per_frame_valid.min()} / "
          f"{int(np.median(per_frame_valid))} / {per_frame_valid.max()}")

    print("\nABSOLUTE MINIMA (sensitive to one-pixel outliers)")
    print(f"minimum Z depth: {depth_minimum:.6f} m; "
          f"frame/x/y/range={depth_minimum_location}")
    print(f"minimum Euclidean range: {range_minimum:.6f} m; "
          f"frame/x/y/Z={range_minimum_location}")

    print("\nPER-FRAME K-TH NEAREST VALID SAMPLE")
    print("k       depth: min / median / max (m)       range: min / median / max (m)")
    for column, k in enumerate(ORDER_STATISTICS):
        dz = per_frame_depth_order[:, column]
        rr = per_frame_range_order[:, column]
        print(
            f"{k:<7d} "
            f"{format_value(np.nanmin(dz))} / {format_value(np.nanmedian(dz))} / "
            f"{format_value(np.nanmax(dz))}        "
            f"{format_value(np.nanmin(rr))} / {format_value(np.nanmedian(rr))} / "
            f"{format_value(np.nanmax(rr))}"
        )

    print("\nDEPTH THRESHOLD SUPPORT")
    print("Z below   total pixels   frames >=1 / >=100 / >=1000 / >=10000   median/frame")
    for column, threshold in enumerate(THRESHOLDS_M):
        counts = depth_threshold_counts[:, column]
        print(
            f"{threshold:>5.2f} m  {int(counts.sum()):>12d}   "
            f"{np.count_nonzero(counts >= 1):>4d} / "
            f"{np.count_nonzero(counts >= 100):>4d} / "
            f"{np.count_nonzero(counts >= 1000):>4d} / "
            f"{np.count_nonzero(counts >= 10000):>4d}             "
            f"{int(np.median(counts)):>8d}"
        )

    print("\nEUCLIDEAN RANGE THRESHOLD SUPPORT")
    print("R below   total points   frames >=1 / >=100 / >=1000 / >=10000   median/frame")
    for column, threshold in enumerate(THRESHOLDS_M):
        counts = range_threshold_counts[:, column]
        print(
            f"{threshold:>5.2f} m  {int(counts.sum()):>12d}   "
            f"{np.count_nonzero(counts >= 1):>4d} / "
            f"{np.count_nonzero(counts >= 100):>4d} / "
            f"{np.count_nonzero(counts >= 1000):>4d} / "
            f"{np.count_nonzero(counts >= 10000):>4d}             "
            f"{int(np.median(counts)):>8d}"
        )


if __name__ == "__main__":
    main()
