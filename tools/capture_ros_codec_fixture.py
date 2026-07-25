#!/usr/bin/env python3
"""Capture one compressed frame and ROS-decoded reference from SVO replay."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import struct
import time

import rclpy
from point_cloud_interfaces.msg import CompressedPointCloud2
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import CompressedImage, Image, PointCloud2, PointField


RGB_TOPIC = "/zed/zed_node/rgb/color/rect/image/compressed"
DEPTH_TOPIC = "/zed/zed_node/depth/depth_registered/compressedDepth"
DEPTH_REFERENCE_TOPIC = "/zed_field/fixture/depth"
CLOUD_TOPIC = "/zed/zed_node/point_cloud/cloud_registered/draco"
CLOUD_REFERENCE_TOPIC = "/zed_field/fixture/cloud"


def stamp(message) -> tuple[int, int]:
    return message.header.stamp.sec, message.header.stamp.nanosec


def header_json(message) -> dict[str, object]:
    return {
        "stamp_sec": message.header.stamp.sec,
        "stamp_nsec": message.header.stamp.nanosec,
        "frame_id": message.header.frame_id,
    }


def jpeg_dimensions(data: bytes) -> tuple[int, int]:
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        raise ValueError("compressed RGB fixture is not a JPEG")
    offset = 2
    sof_markers = {
        0xC0,
        0xC1,
        0xC2,
        0xC3,
        0xC5,
        0xC6,
        0xC7,
        0xC9,
        0xCA,
        0xCB,
        0xCD,
        0xCE,
        0xCF,
    }
    while offset + 9 < len(data):
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        marker = data[offset]
        offset += 1
        if marker in (0xD8, 0xD9):
            continue
        length = int.from_bytes(data[offset : offset + 2], "big")
        if marker in sof_markers:
            height = int.from_bytes(data[offset + 3 : offset + 5], "big")
            width = int.from_bytes(data[offset + 5 : offset + 7], "big")
            return width, height
        offset += length
    raise ValueError("JPEG dimensions were not found")


def scalar_format(datatype: int, big_endian: bool) -> str:
    endian = ">" if big_endian else "<"
    formats = {
        PointField.INT8: "b",
        PointField.UINT8: "B",
        PointField.INT16: "h",
        PointField.UINT16: "H",
        PointField.INT32: "i",
        PointField.UINT32: "I",
        PointField.FLOAT32: "f",
        PointField.FLOAT64: "d",
    }
    if datatype not in formats:
        raise ValueError(f"unsupported PointField datatype: {datatype}")
    return endian + formats[datatype]


def point_cloud_reference(message: PointCloud2) -> dict[str, object]:
    fields = {field.name: field for field in message.fields}
    for name in ("x", "y", "z"):
        if name not in fields:
            raise ValueError(f"raw cloud does not contain {name}")
    formats = {
        name: scalar_format(fields[name].datatype, message.is_bigendian)
        for name in ("x", "y", "z")
    }
    total = message.width * message.height
    finite = 0
    minimum = [math.inf, math.inf, math.inf]
    maximum = [-math.inf, -math.inf, -math.inf]
    samples: list[dict[str, object]] = []
    sample_stride = max(1, total // 128)
    for index in range(total):
        offset = index * message.point_step
        xyz = [
            struct.unpack_from(formats[name], message.data, offset + fields[name].offset)[0]
            for name in ("x", "y", "z")
        ]
        if not all(math.isfinite(value) for value in xyz):
            continue
        finite += 1
        for axis, value in enumerate(xyz):
            minimum[axis] = min(minimum[axis], value)
            maximum[axis] = max(maximum[axis], value)
        if index % sample_stride == 0 and len(samples) < 128:
            sample: dict[str, object] = {"index": index, "xyz": xyz}
            color_field = fields.get("rgb") or fields.get("rgba")
            if color_field is not None:
                color_bytes = bytes(
                    message.data[
                        offset
                        + color_field.offset : offset
                        + color_field.offset
                        + 4
                    ]
                )
                sample["packed_color_bytes"] = list(color_bytes)
            samples.append(sample)
    return {
        **header_json(message),
        "width": message.width,
        "height": message.height,
        "point_step": message.point_step,
        "row_step": message.row_step,
        "is_bigendian": message.is_bigendian,
        "is_dense": message.is_dense,
        "fields": [
            {
                "name": field.name,
                "offset": field.offset,
                "datatype": field.datatype,
                "count": field.count,
            }
            for field in message.fields
        ],
        "total_points": total,
        "finite_points": finite,
        "bounds_min": minimum if finite else None,
        "bounds_max": maximum if finite else None,
        "samples": samples,
    }


def depth_reference(message: Image) -> dict[str, object]:
    if message.encoding not in ("32FC1", "16UC1"):
        raise ValueError(f"unexpected depth encoding: {message.encoding}")
    big_endian = bool(message.is_bigendian)
    format_code = (">" if big_endian else "<") + (
        "f" if message.encoding == "32FC1" else "H"
    )
    item_bytes = 4 if message.encoding == "32FC1" else 2
    finite_values: list[float] = []
    samples: list[dict[str, object]] = []
    rows = sorted({0, message.height // 4, message.height // 2, 3 * message.height // 4, message.height - 1})
    columns = sorted({0, message.width // 4, message.width // 2, 3 * message.width // 4, message.width - 1})
    sample_positions = {(row, column) for row in rows for column in columns}
    for row in range(message.height):
        row_offset = row * message.step
        for column in range(message.width):
            value = struct.unpack_from(
                format_code, message.data, row_offset + column * item_bytes
            )[0]
            metres = value if message.encoding == "32FC1" else value / 1000.0
            if math.isfinite(metres) and metres > 0:
                finite_values.append(metres)
            if (row, column) in sample_positions:
                samples.append(
                    {
                        "row": row,
                        "column": column,
                        "metres": metres if math.isfinite(metres) else None,
                    }
                )
    finite_values.sort()
    return {
        **header_json(message),
        "width": message.width,
        "height": message.height,
        "encoding": message.encoding,
        "is_bigendian": big_endian,
        "step": message.step,
        "valid_pixels": len(finite_values),
        "minimum_metres": finite_values[0] if finite_values else None,
        "maximum_metres": finite_values[-1] if finite_values else None,
        "median_metres": (
            finite_values[len(finite_values) // 2] if finite_values else None
        ),
        "samples": samples,
    }


class FixtureCapture(Node):
    def __init__(
        self,
        rgb_topic: str,
        depth_topic: str,
        depth_reference_topic: str,
        cloud_topic: str,
        cloud_reference_topic: str,
    ) -> None:
        super().__init__("zed_web_fixture_capture")
        self.rgb: dict[tuple[int, int], CompressedImage] = {}
        self.depth: dict[tuple[int, int], CompressedImage] = {}
        self.depth_reference: dict[tuple[int, int], Image] = {}
        self.cloud: dict[tuple[int, int], CompressedPointCloud2] = {}
        self.cloud_reference: dict[tuple[int, int], PointCloud2] = {}
        self.create_subscription(
            CompressedImage, rgb_topic, self.on_rgb, qos_profile_sensor_data
        )
        self.create_subscription(
            CompressedImage, depth_topic, self.on_depth, qos_profile_sensor_data
        )
        self.create_subscription(
            Image,
            depth_reference_topic,
            self.on_depth_reference,
            qos_profile_sensor_data,
        )
        self.create_subscription(
            CompressedPointCloud2,
            cloud_topic,
            self.on_cloud,
            qos_profile_sensor_data,
        )
        self.create_subscription(
            PointCloud2,
            cloud_reference_topic,
            self.on_cloud_reference,
            qos_profile_sensor_data,
        )

    @staticmethod
    def retain_latest(mapping: dict, message) -> None:
        mapping[stamp(message)] = message
        while len(mapping) > 12:
            del mapping[next(iter(mapping))]

    def on_rgb(self, message: CompressedImage) -> None:
        self.retain_latest(self.rgb, message)

    def on_depth(self, message: CompressedImage) -> None:
        self.retain_latest(self.depth, message)

    def on_depth_reference(self, message: Image) -> None:
        self.retain_latest(self.depth_reference, message)

    def on_cloud(self, message: CompressedPointCloud2) -> None:
        self.retain_latest(self.cloud, message)

    def on_cloud_reference(self, message: PointCloud2) -> None:
        self.retain_latest(self.cloud_reference, message)

    def complete(self) -> bool:
        return bool(
            set(self.depth).intersection(self.depth_reference)
            and set(self.cloud).intersection(self.cloud_reference)
            and self.rgb
        )

    def save(self, output: Path) -> None:
        output.mkdir(parents=True, exist_ok=True)
        depth_stamp = sorted(set(self.depth).intersection(self.depth_reference))[-1]
        cloud_stamp = sorted(set(self.cloud).intersection(self.cloud_reference))[-1]
        rgb_stamp = min(
            self.rgb,
            key=lambda item: abs(
                (item[0] - depth_stamp[0]) * 1_000_000_000
                + item[1]
                - depth_stamp[1]
            ),
        )
        rgb = self.rgb[rgb_stamp]
        compressed_depth = self.depth[depth_stamp]
        raw_depth = self.depth_reference[depth_stamp]
        compressed_cloud = self.cloud[cloud_stamp]
        raw_cloud = self.cloud_reference[cloud_stamp]

        rgb_bytes = bytes(rgb.data)
        rgb_width, rgb_height = jpeg_dimensions(rgb_bytes)
        (output / "rgb.jpg").write_bytes(rgb_bytes)
        (output / "depth.compressed").write_bytes(bytes(compressed_depth.data))
        (output / "cloud.drc").write_bytes(bytes(compressed_cloud.compressed_data))
        (output / "rgb.json").write_text(
            json.dumps(
                {
                    **header_json(rgb),
                    "format": rgb.format,
                    "bytes": len(rgb.data),
                    "width": rgb_width,
                    "height": rgb_height,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        (output / "depth.json").write_text(
            json.dumps(
                {
                    **header_json(compressed_depth),
                    "format": compressed_depth.format,
                    "bytes": len(compressed_depth.data),
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        (output / "depth-reference.json").write_text(
            json.dumps(depth_reference(raw_depth), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        (output / "cloud.json").write_text(
            json.dumps(
                {
                    **header_json(compressed_cloud),
                    "format": compressed_cloud.format,
                    "bytes": len(compressed_cloud.compressed_data),
                    "width": compressed_cloud.width,
                    "height": compressed_cloud.height,
                    "point_step": compressed_cloud.point_step,
                    "row_step": compressed_cloud.row_step,
                    "is_bigendian": compressed_cloud.is_bigendian,
                    "is_dense": compressed_cloud.is_dense,
                    "fields": [
                        {
                            "name": field.name,
                            "offset": field.offset,
                            "datatype": field.datatype,
                            "count": field.count,
                        }
                        for field in compressed_cloud.fields
                    ],
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        (output / "cloud-reference.json").write_text(
            json.dumps(point_cloud_reference(raw_cloud), indent=2, sort_keys=True)
            + "\n",
            encoding="utf-8",
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--rgb-topic", default=RGB_TOPIC)
    parser.add_argument("--depth-topic", default=DEPTH_TOPIC)
    parser.add_argument("--depth-reference-topic", default=DEPTH_REFERENCE_TOPIC)
    parser.add_argument("--cloud-topic", default=CLOUD_TOPIC)
    parser.add_argument("--cloud-reference-topic", default=CLOUD_REFERENCE_TOPIC)
    arguments = parser.parse_args()

    rclpy.init()
    node = FixtureCapture(
        arguments.rgb_topic,
        arguments.depth_topic,
        arguments.depth_reference_topic,
        arguments.cloud_topic,
        arguments.cloud_reference_topic,
    )
    deadline = time.monotonic() + arguments.timeout
    try:
        while rclpy.ok() and time.monotonic() < deadline and not node.complete():
            rclpy.spin_once(node, timeout_sec=0.25)
        if not node.complete():
            print("ERROR: timed out waiting for matched compressed/reference frames")
            return 1
        node.save(arguments.output)
        print(f"Captured synchronized codec fixtures in {arguments.output}")
        return 0
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
