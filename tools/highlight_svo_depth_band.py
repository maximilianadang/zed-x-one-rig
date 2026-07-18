#!/usr/bin/env python3
"""Highlight pixels in a ZED SVO whose SDK Z-depth is near a target value.

Uses the ZED SDK for rectification and NEURAL depth. Produces a CSV, full-size
annotated top frames, a contact sheet, an optional annotated MP4, and a text
summary. OpenCV is avoided because this Jetson's system OpenCV currently
conflicts with NumPy 2.
"""

import argparse
import csv
import heapq
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
import pyzed.sl as sl


DEPTH_MODES = {
    "NEURAL": sl.DEPTH_MODE.NEURAL,
    "NEURAL_LIGHT": sl.DEPTH_MODE.NEURAL_LIGHT,
    "NEURAL_PLUS": sl.DEPTH_MODE.NEURAL_PLUS,
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Highlight a target Z-depth in one or more ZED SVO files."
    )
    parser.add_argument("svo", nargs="+", type=Path, help="Input .svo/.svo2 file(s)")
    parser.add_argument("--target", type=float, default=0.90,
                        help="Target forward Z-depth in meters (default: 0.90)")
    parser.add_argument("--tolerance", type=float, default=0.025,
                        help="Half-width of highlighted band in meters (default: 0.025)")
    parser.add_argument("--mode", choices=DEPTH_MODES, default="NEURAL")
    parser.add_argument("--confidence", type=int, default=95,
                        help="ZED confidence threshold, 0-100 (default: 95)")
    parser.add_argument("--texture-confidence", type=int, default=100,
                        help="ZED texture confidence threshold, 0-100 (default: 100)")
    parser.add_argument("--top-frames", type=int, default=12,
                        help="Save this many frames with the most highlighted pixels")
    parser.add_argument("--save-every", type=int, default=0,
                        help="Also save every Nth annotated frame; 0 disables")
    parser.add_argument("--max-frames", type=int, default=0,
                        help="Stop after N frames; 0 processes the complete SVO")
    parser.add_argument("--video", action="store_true",
                        help="Write every annotated frame to a playable video")
    parser.add_argument("--video-format", choices=("ogv", "mjpeg", "mp4"),
                        default="ogv",
                        help="Video format: locally playable Theora OGV (default), "
                             "MJPEG AVI, or smaller H.264 MP4")
    parser.add_argument("--video-bitrate", type=int, default=12000,
                        help="MP4 H.264 bitrate in kbit/s (default: 12000)")
    parser.add_argument("--output-root", type=Path,
                        help="Parent output directory (default: beside each SVO)")
    return parser.parse_args()


def unique_output_dir(base):
    candidate = base
    suffix = 2
    while candidate.exists():
        candidate = Path(f"{base}_{suffix}")
        suffix += 1
    candidate.mkdir(parents=True)
    return candidate


def annotate_frame(camera, image_mat, mask, row, target, tolerance):
    error = camera.retrieve_image(image_mat, sl.VIEW.LEFT, sl.MEM.CPU)
    if error != sl.ERROR_CODE.SUCCESS:
        raise RuntimeError(f"Could not retrieve rectified left image: {error}")

    bgra = np.asarray(image_mat.get_data())
    rgb = bgra[:, :, :3][:, :, ::-1].copy()
    # Bright magenta is uncommon in natural scenes and remains visible over
    # both light and dark image regions.
    color = np.array([255, 0, 220], dtype=np.float32)
    rgb[mask] = np.clip(
        0.30 * rgb[mask].astype(np.float32) + 0.70 * color, 0, 255
    ).astype(np.uint8)

    image = Image.fromarray(rgb, "RGB")
    draw = ImageDraw.Draw(image)
    if row["count"]:
        box = (row["x_min"], row["y_min"], row["x_max"], row["y_max"])
        draw.rectangle(box, outline=(255, 255, 0), width=4)
        u = int(round(row["u_median"]))
        v = int(round(row["v_median"]))
        draw.line((u - 12, v, u + 12, v), fill=(0, 255, 255), width=3)
        draw.line((u, v - 12, u, v + 12), fill=(0, 255, 255), width=3)

    lines = [
        f"frame {row['frame']}  Z target {target:.3f} +/- {tolerance:.3f} m",
        f"pixels {row['count']}  median Z {row['z_median']:.3f} m",
        f"median pixel ({row['u_median']:.1f}, {row['v_median']:.1f})",
        f"estimated XYZ ({row['x_m']:.3f}, {row['y_m']:.3f}, {row['z_median']:.3f}) m",
        "MAGENTA=target band  YELLOW=all-target bbox  CYAN=median pixel",
    ]
    text_width = max(len(line) for line in lines) * 7 + 20
    text_height = len(lines) * 16 + 14
    draw.rectangle((8, 8, min(image.width - 8, text_width), text_height),
                   fill=(0, 0, 0))
    for index, line in enumerate(lines):
        draw.text((15, 14 + 16 * index), line, fill=(255, 255, 255))
    return image


def make_contact_sheet(top_frames, output):
    if not top_frames:
        return
    columns = 3
    tile_width = 640
    tile_height = 400
    rows = math.ceil(len(top_frames) / columns)
    sheet = Image.new("RGB", (columns * tile_width, rows * tile_height), (20, 20, 20))
    resampling = getattr(Image, "Resampling", Image).LANCZOS
    for index, (_, _, image, _) in enumerate(top_frames):
        tile = image.copy()
        tile.thumbnail((tile_width, tile_height), resampling)
        x = (index % columns) * tile_width + (tile_width - tile.width) // 2
        y = (index // columns) * tile_height + (tile_height - tile.height) // 2
        sheet.paste(tile, (x, y))
    sheet.save(output, compress_level=3)


class VideoWriter:
    """Stream RGB frames into a local GStreamer video encoder."""

    def __init__(self, output, width, height, fps, bitrate, video_format):
        import gi
        gi.require_version("Gst", "1.0")
        from gi.repository import Gst

        self.Gst = Gst
        Gst.init(None)
        source = (
            "appsrc name=source is-live=false format=time block=true "
            f"caps=video/x-raw,format=RGB,width={width},height={height},"
            f"framerate={fps}/1 "
        )
        if video_format == "ogv":
            encoding = (
                "! videoconvert ! video/x-raw,format=I420 "
                f"! theoraenc quality=48 speed-level=2 keyframe-force={max(fps * 2, 1)} "
                "! oggmux "
            )
        elif video_format == "mjpeg":
            encoding = (
                "! videoconvert ! video/x-raw,format=I420 "
                "! jpegenc quality=90 ! avimux "
            )
        else:
            encoding = (
                "! videoconvert ! video/x-raw,format=I420 "
                f"! x264enc speed-preset=ultrafast tune=zerolatency bitrate={bitrate} "
                f"key-int-max={max(fps * 2, 1)} "
                "! video/x-h264,stream-format=avc,alignment=au "
                "! mp4mux faststart=true "
            )
        description = source + encoding + "! filesink name=output sync=false"
        self.pipeline = Gst.parse_launch(description)
        self.source = self.pipeline.get_by_name("source")
        self.pipeline.get_by_name("output").set_property("location", str(output))
        self.duration = Gst.util_uint64_scale_int(1, Gst.SECOND, fps)
        self.frame_index = 0
        state = self.pipeline.set_state(Gst.State.PLAYING)
        if state == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("Could not start the GStreamer video encoder")

    def push(self, image):
        rgb = np.asarray(image, dtype=np.uint8)
        data = rgb.tobytes()
        buffer = self.Gst.Buffer.new_allocate(None, len(data), None)
        buffer.fill(0, data)
        buffer.pts = self.frame_index * self.duration
        buffer.dts = buffer.pts
        buffer.duration = self.duration
        buffer.offset = self.frame_index
        result = self.source.emit("push-buffer", buffer)
        if result != self.Gst.FlowReturn.OK:
            raise RuntimeError(f"Video encoder rejected frame {self.frame_index}: {result}")
        self.frame_index += 1

    def close(self):
        result = self.source.emit("end-of-stream")
        if result != self.Gst.FlowReturn.OK:
            raise RuntimeError(f"Could not finalize video stream: {result}")
        bus = self.pipeline.get_bus()
        message = bus.timed_pop_filtered(
            self.Gst.CLOCK_TIME_NONE,
            self.Gst.MessageType.ERROR | self.Gst.MessageType.EOS,
        )
        try:
            if message is None:
                raise RuntimeError("Timed out while finalizing video")
            if message.type == self.Gst.MessageType.ERROR:
                error, debug = message.parse_error()
                raise RuntimeError(f"GStreamer video error: {error}; {debug}")
        finally:
            self.pipeline.set_state(self.Gst.State.NULL)


def process_svo(path, args):
    if not path.is_file():
        print(f"Skipping missing input: {path}")
        return

    root = args.output_root if args.output_root else path.parent
    band_name = f"Z_{args.target:.3f}m_pm_{args.tolerance:.3f}m"
    output_dir = unique_output_dir(root / f"{path.stem}_{band_name}")
    periodic_dir = output_dir / "periodic_frames"
    if args.save_every > 0:
        periodic_dir.mkdir()

    init = sl.InitParameters()
    init.set_from_svo_file(str(path))
    init.svo_real_time_mode = False
    init.depth_mode = DEPTH_MODES[args.mode]
    init.coordinate_units = sl.UNIT.METER

    camera = sl.Camera()
    error = camera.open(init)
    if error != sl.ERROR_CODE.SUCCESS:
        raise RuntimeError(f"Could not open {path}: {error}")

    config = camera.get_camera_information().camera_configuration
    calibration = config.calibration_parameters.left_cam
    fx = float(calibration.fx)
    fy = float(calibration.fy)
    cx = float(calibration.cx)
    cy = float(calibration.cy)

    runtime = sl.RuntimeParameters()
    runtime.confidence_threshold = args.confidence
    runtime.texture_confidence_threshold = args.texture_confidence
    depth_mat = sl.Mat()
    image_mat = sl.Mat()

    csv_path = output_dir / "target_pixels_by_frame.csv"
    fieldnames = [
        "frame", "timestamp_ns", "count", "fraction_of_image", "z_min",
        "z_median", "z_max", "u_median", "v_median", "x_min", "y_min",
        "x_max", "y_max", "x_m", "y_m", "euclidean_range_m",
    ]
    top_heap = []
    frames_with_target = 0
    total_target_pixels = 0
    frame_count = 0
    strongest_row = None
    video_writer = None
    video_extensions = {"ogv": ".ogv", "mjpeg": ".avi", "mp4": ".mp4"}
    video_extension = video_extensions[args.video_format]
    video_path = output_dir / f"annotated_depth_band{video_extension}"

    lower = args.target - args.tolerance
    upper = args.target + args.tolerance

    with csv_path.open("w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()

        while True:
            if args.max_frames > 0 and frame_count >= args.max_frames:
                break
            error = camera.grab(runtime)
            if error == sl.ERROR_CODE.END_OF_SVOFILE_REACHED:
                break
            if error != sl.ERROR_CODE.SUCCESS:
                print(f"Skipping frame after grab error: {error}")
                continue

            camera.retrieve_measure(depth_mat, sl.MEASURE.DEPTH, sl.MEM.CPU)
            depth = np.asarray(depth_mat.get_data())
            mask = np.isfinite(depth) & (depth >= lower) & (depth <= upper)
            y, x = np.nonzero(mask)
            z = depth[mask].astype(np.float64, copy=False)
            count = int(z.size)
            timestamp = camera.get_timestamp(sl.TIME_REFERENCE.IMAGE).get_nanoseconds()

            if count:
                frames_with_target += 1
                total_target_pixels += count
                u_median = float(np.median(x))
                v_median = float(np.median(y))
                z_median = float(np.median(z))
                x_m = (u_median - cx) * z_median / fx
                y_m = (v_median - cy) * z_median / fy
                row = {
                    "frame": frame_count,
                    "timestamp_ns": timestamp,
                    "count": count,
                    "fraction_of_image": count / depth.size,
                    "z_min": float(z.min()),
                    "z_median": z_median,
                    "z_max": float(z.max()),
                    "u_median": u_median,
                    "v_median": v_median,
                    "x_min": int(x.min()),
                    "y_min": int(y.min()),
                    "x_max": int(x.max()),
                    "y_max": int(y.max()),
                    "x_m": x_m,
                    "y_m": y_m,
                    "euclidean_range_m": math.sqrt(x_m*x_m + y_m*y_m + z_median*z_median),
                }
            else:
                row = {
                    "frame": frame_count,
                    "timestamp_ns": timestamp,
                    "count": 0,
                    "fraction_of_image": 0.0,
                    "z_min": math.nan,
                    "z_median": math.nan,
                    "z_max": math.nan,
                    "u_median": math.nan,
                    "v_median": math.nan,
                    "x_min": "", "y_min": "", "x_max": "", "y_max": "",
                    "x_m": math.nan, "y_m": math.nan,
                    "euclidean_range_m": math.nan,
                }
            writer.writerow(row)

            top_candidate = args.top_frames > 0 and count and (
                len(top_heap) < args.top_frames or count > top_heap[0][0]
            )
            periodic_candidate = args.save_every > 0 and frame_count % args.save_every == 0
            if args.video or top_candidate or periodic_candidate:
                annotated = annotate_frame(
                    camera, image_mat, mask, row, args.target, args.tolerance
                )
                if args.video:
                    if video_writer is None:
                        video_writer = VideoWriter(
                            video_path,
                            annotated.width,
                            annotated.height,
                            max(int(round(float(config.fps))), 1),
                            args.video_bitrate,
                            args.video_format,
                        )
                    video_writer.push(annotated)
                if periodic_candidate:
                    annotated.save(periodic_dir / f"frame_{frame_count:06d}.png",
                                   compress_level=3)
                if top_candidate:
                    item = (count, frame_count, annotated, row)
                    if len(top_heap) < args.top_frames:
                        heapq.heappush(top_heap, item)
                    else:
                        heapq.heapreplace(top_heap, item)

            if strongest_row is None or count > strongest_row["count"]:
                strongest_row = row
            frame_count += 1
            if frame_count % 20 == 0:
                print(f"{path.name}: processed {frame_count}/{camera.get_svo_number_of_frames()}",
                      flush=True)

    if video_writer is not None:
        print(f"Finalizing video: {video_path}", flush=True)
        video_writer.close()
    camera.close()

    top_frames = sorted(top_heap, key=lambda item: (-item[0], item[1]))
    for rank, (count, frame, image, _) in enumerate(top_frames, 1):
        image.save(output_dir / f"top_{rank:02d}_frame_{frame:06d}_{count}_pixels.png",
                   compress_level=3)
    make_contact_sheet(top_frames, output_dir / "top_frames_contact_sheet.png")

    summary_path = output_dir / "SUMMARY.txt"
    with summary_path.open("w") as summary:
        summary.write(f"Input: {path}\n")
        summary.write(f"Depth mode: {args.mode}\n")
        summary.write(f"Target Z band: {lower:.3f} to {upper:.3f} m\n")
        summary.write(f"Frames processed: {frame_count}\n")
        summary.write(f"Frames containing target pixels: {frames_with_target}\n")
        summary.write(f"Total target pixels: {total_target_pixels}\n")
        summary.write(f"Confidence thresholds: {args.confidence} / "
                      f"{args.texture_confidence}\n")
        if video_writer is not None:
            summary.write(f"Annotated video: {video_path}\n")
        summary.write("IMPORTANT: Z is forward depth from the rectified left-camera "
                      "frame, not Euclidean tape-measure range.\n")
        if strongest_row and strongest_row["count"]:
            summary.write("\nStrongest frame:\n")
            for key, value in strongest_row.items():
                summary.write(f"  {key}: {value}\n")

    print(f"\nFinished: {path}")
    print(f"Output: {output_dir}")
    print(f"Frames with target pixels: {frames_with_target}/{frame_count}")
    print(f"Total target pixels: {total_target_pixels}")
    if video_writer is not None:
        print(f"Annotated video: {video_path}")
    if strongest_row and strongest_row["count"]:
        print("Strongest frame: "
              f"{strongest_row['frame']}, {strongest_row['count']} pixels, "
              f"median pixel=({strongest_row['u_median']:.1f}, "
              f"{strongest_row['v_median']:.1f}), "
              f"median XYZ=({strongest_row['x_m']:.3f}, "
              f"{strongest_row['y_m']:.3f}, "
              f"{strongest_row['z_median']:.3f}) m")


def main():
    args = parse_args()
    if args.tolerance <= 0:
        raise SystemExit("--tolerance must be positive")
    if args.target <= 0:
        raise SystemExit("--target must be positive")
    if args.top_frames < 0 or args.save_every < 0 or args.max_frames < 0:
        raise SystemExit("frame-count options cannot be negative")
    if args.video_bitrate <= 0:
        raise SystemExit("--video-bitrate must be positive")
    for svo in args.svo:
        process_svo(svo.resolve(), args)


if __name__ == "__main__":
    main()
