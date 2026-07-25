#!/usr/bin/env python3
"""Publish deterministic, non-sensitive raw RGB/depth/cloud fixture messages."""

from __future__ import annotations

import math
import struct

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile
from sensor_msgs.msg import Image, PointCloud2, PointField
from std_msgs.msg import Header


WIDTH = 96
HEIGHT = 60
POINTS = 256


class SyntheticFixturePublisher(Node):
    def __init__(self) -> None:
        super().__init__("zed_web_synthetic_fixture")
        qos = QoSProfile(depth=1)
        self.rgb_publisher = self.create_publisher(
            Image, "/zed_fixture/rgb", qos
        )
        self.depth_publisher = self.create_publisher(
            Image, "/zed_fixture/depth", qos
        )
        self.cloud_publisher = self.create_publisher(
            PointCloud2, "/zed_fixture/cloud", qos
        )
        self.create_timer(0.2, self.publish_fixture)

    @staticmethod
    def rgb_data() -> bytes:
        data = bytearray(WIDTH * HEIGHT * 3)
        for row in range(HEIGHT):
            for column in range(WIDTH):
                offset = (row * WIDTH + column) * 3
                data[offset] = round(255 * column / (WIDTH - 1))
                data[offset + 1] = round(255 * row / (HEIGHT - 1))
                data[offset + 2] = (column * 7 + row * 11) % 256
        return bytes(data)

    @staticmethod
    def depth_data() -> bytes:
        data = bytearray(WIDTH * HEIGHT * 4)
        for row in range(HEIGHT):
            for column in range(WIDTH):
                if (row + column) % 17 == 0:
                    value = math.nan
                else:
                    value = 0.75 + 8.25 * column / (WIDTH - 1) + row / 200.0
                struct.pack_into("<f", data, (row * WIDTH + column) * 4, value)
        return bytes(data)

    @staticmethod
    def cloud_data() -> bytes:
        data = bytearray(POINTS * 16)
        for index in range(POINTS):
            angle = index * 2.0 * math.pi / 64.0
            ring = index // 64
            x = 0.8 + index * 0.012
            y = math.sin(angle) * (0.2 + ring * 0.07)
            z = 0.15 + math.cos(angle) * (0.2 + ring * 0.05)
            red = round(255 * index / (POINTS - 1))
            green = round(255 * (1.0 - index / (POINTS - 1)))
            blue = (index * 13) % 256
            rgba = (255 << 24) | (red << 16) | (green << 8) | blue
            struct.pack_into("<fffI", data, index * 16, x, y, z, rgba)
        return bytes(data)

    def publish_fixture(self) -> None:
        header = Header()
        header.stamp = self.get_clock().now().to_msg()

        rgb = Image()
        rgb.header = header
        rgb.header.frame_id = "zed_left_camera_frame_optical"
        rgb.height = HEIGHT
        rgb.width = WIDTH
        rgb.encoding = "bgr8"
        rgb.is_bigendian = False
        rgb.step = WIDTH * 3
        rgb.data = self.rgb_data()
        self.rgb_publisher.publish(rgb)

        depth = Image()
        depth.header = header
        depth.header.frame_id = "zed_left_camera_frame_optical"
        depth.height = HEIGHT
        depth.width = WIDTH
        depth.encoding = "32FC1"
        depth.is_bigendian = False
        depth.step = WIDTH * 4
        depth.data = self.depth_data()
        self.depth_publisher.publish(depth)

        cloud = PointCloud2()
        cloud.header = header
        cloud.header.frame_id = "zed_left_camera_frame"
        cloud.height = 1
        cloud.width = POINTS
        cloud.fields = [
            PointField(name="x", offset=0, datatype=PointField.FLOAT32, count=1),
            PointField(name="y", offset=4, datatype=PointField.FLOAT32, count=1),
            PointField(name="z", offset=8, datatype=PointField.FLOAT32, count=1),
            PointField(name="rgb", offset=12, datatype=PointField.FLOAT32, count=1),
        ]
        cloud.is_bigendian = False
        cloud.point_step = 16
        cloud.row_step = POINTS * 16
        cloud.data = self.cloud_data()
        cloud.is_dense = True
        self.cloud_publisher.publish(cloud)


def main() -> int:
    rclpy.init()
    node = SyntheticFixturePublisher()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
