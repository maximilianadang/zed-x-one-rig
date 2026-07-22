#!/usr/bin/env python3
"""Persist the ZED wrapper's SVO playback status for a low-latency SSH UI."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import socketserver
import tempfile
import threading
import time

import rclpy
from rcl_interfaces.msg import Parameter, ParameterType, ParameterValue
from rcl_interfaces.srv import SetParameters
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from std_srvs.srv import Trigger
from zed_msgs.msg import HealthStatusStamped, SvoStatus
from zed_msgs.srv import SetSvoFrame


STATUS_NAMES = {
    SvoStatus.STATUS_PLAYING: "PLAYING",
    SvoStatus.STATUS_PAUSED: "PAUSED",
    SvoStatus.STATUS_END: "END",
}

# The exact field rig records at 15 FPS. In controlled (non-real-time) replay,
# 0.1x schedules grabs 2/3 second apart. The wrapper checks its paused flag at
# least every 100 ms, so this pulse starts one sequential grab and re-pauses
# well before a second scheduled grab. No SVO-position service is involved.
NEXT_FRAME_RATE = 0.1
NEXT_FRAME_PULSE_SECONDS = 0.25
NEXT_FRAME_MIN_COMMAND_SECONDS = 0.8
NEXT_FRAME_POST_GRAB_SETTLE_SECONDS = 0.25
NEXT_FRAME_COMPLETION_TIMEOUT_SECONDS = 5.0


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


class StatusMonitor(Node):
    def __init__(
        self, output: Path, topic: str, health_topic: str, zed_node: str
    ) -> None:
        super().__init__("zed_field_svo_status_monitor")
        self.output = output
        self.status_lock = threading.Lock()
        self.status_fields: dict[str, object] = {}
        self.event_condition = threading.Condition()
        self.status_sequence = 0
        self.health_sequence = 0
        self.last_wrapper_frame = 0
        self.last_health_monotonic = 0.0
        self.create_subscription(SvoStatus, topic, self.on_status, qos_profile_sensor_data)
        self.create_subscription(
            HealthStatusStamped,
            health_topic,
            self.on_health,
            qos_profile_sensor_data,
        )
        self.pause_client = self.create_client(Trigger, f"{zed_node}/toggle_svo_pause")
        self.seek_client = self.create_client(SetSvoFrame, f"{zed_node}/set_svo_frame")
        self.parameters_client = self.create_client(SetParameters, f"{zed_node}/set_parameters")

    def on_status(self, message: SvoStatus) -> None:
        filename = message.file_name.replace("\n", "").replace("\r", "")
        fields: dict[str, object] = {
            "STATUS": STATUS_NAMES.get(message.status, f"UNKNOWN_{message.status}"),
            "FRAME_ID": message.frame_id,
            "TOTAL_FRAMES": message.total_frames,
            "FRAME_TS": message.frame_ts,
            "LOOP_ACTIVE": str(message.loop_active).lower(),
            "LOOP_COUNT": message.loop_count,
            "REAL_TIME_MODE": str(message.real_time_mode).lower(),
            "FILE": filename,
            "UPDATED_NS": self.get_clock().now().nanoseconds,
        }
        with self.status_lock:
            self.status_fields = fields
            self.write_status_fields()
        with self.event_condition:
            self.status_sequence += 1
            self.last_wrapper_frame = message.frame_id
            self.event_condition.notify_all()

    def on_health(self, _: HealthStatusStamped) -> None:
        # The wrapper emits health immediately after a successful SDK grab.
        # This tiny message lets next-frame wait for real progress without
        # subscribing to and deserializing a multi-megabyte image or cloud.
        with self.event_condition:
            self.health_sequence += 1
            self.last_health_monotonic = time.monotonic()
            self.event_condition.notify_all()

    def write_status_fields(self) -> None:
        atomic_write(
            self.output,
            "".join(f"{key}={value}\n" for key, value in self.status_fields.items()),
        )

    def update_status_fields(self, **updates: object) -> None:
        with self.status_lock:
            self.status_fields.update(updates)
            self.status_fields["UPDATED_NS"] = self.get_clock().now().nanoseconds
            self.write_status_fields()

    @staticmethod
    def await_response(client, request, timeout: float = 15.0):
        if not client.wait_for_service(timeout_sec=timeout):
            raise RuntimeError(f"service unavailable: {client.srv_name}")
        future = client.call_async(request)
        completed = threading.Event()
        future.add_done_callback(lambda _: completed.set())
        if not completed.wait(timeout):
            raise RuntimeError(f"service timeout: {client.srv_name}")
        exception = future.exception()
        if exception is not None:
            raise RuntimeError(str(exception))
        return future.result()

    def toggle_pause(self, timeout: float = 15.0) -> tuple[str, str]:
        response = self.await_response(
            self.pause_client, Trigger.Request(), timeout=timeout
        )
        if not response.success:
            raise RuntimeError(response.message)
        message = response.message.lower()
        if "paused" in message:
            status = "PAUSED"
        elif "playing" in message:
            status = "PLAYING"
        else:
            raise RuntimeError(f"ambiguous pause response: {response.message}")
        self.update_status_fields(STATUS=status)
        return response.message, status

    def set_replay_rate(self, rate: float, timeout: float = 15.0) -> str:
        request = SetParameters.Request()
        request.parameters = [
            Parameter(
                name="svo.replay_rate",
                value=ParameterValue(
                    type=ParameterType.PARAMETER_DOUBLE, double_value=rate
                ),
            )
        ]
        response = self.await_response(
            self.parameters_client, request, timeout=timeout
        )
        if not response.results or not response.results[0].successful:
            reason = (
                response.results[0].reason
                if response.results
                else "empty parameter response"
            )
            raise RuntimeError(reason)
        return f"replay rate set to {rate:g}x"

    def play_next(self, original_rate: float) -> str:
        if not 0.1 <= original_rate <= 5.0:
            raise ValueError(f"invalid replay rate: {original_rate:g}")
        with self.status_lock:
            status = str(self.status_fields.get("STATUS", "UNKNOWN"))
            frame = int(self.status_fields.get("FRAME_ID", 0))
            total = int(self.status_fields.get("TOTAL_FRAMES", 0))
        if status != "PAUSED":
            raise RuntimeError("next-frame is available only while paused")
        if total <= 0 or frame >= total - 1:
            raise RuntimeError("replay is already at the final frame")

        with self.event_condition:
            starting_status_sequence = self.status_sequence
            starting_health_sequence = self.health_sequence

        command_started = time.monotonic()
        rate_changed = abs(original_rate - NEXT_FRAME_RATE) > 1e-9
        if rate_changed:
            self.set_replay_rate(NEXT_FRAME_RATE, timeout=5.0)
        try:
            _, play_status = self.toggle_pause(timeout=5.0)
            if play_status != "PLAYING":
                raise RuntimeError("wrapper did not enter playing state")
            time.sleep(NEXT_FRAME_PULSE_SECONDS)
            _, pause_status = self.toggle_pause(timeout=5.0)
            if pause_status != "PAUSED":
                raise RuntimeError("wrapper did not return to paused state")
        finally:
            if rate_changed:
                self.set_replay_rate(original_rate, timeout=5.0)

        deadline = time.monotonic() + NEXT_FRAME_COMPLETION_TIMEOUT_SECONDS
        with self.event_condition:
            while (
                self.status_sequence <= starting_status_sequence
                or self.health_sequence <= starting_health_sequence
            ):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError(
                        "no completed sequential grab was observed within 5 seconds"
                    )
                self.event_condition.wait(remaining)
            wrapper_frame = self.last_wrapper_frame
            health_completed = self.last_health_monotonic

        # The health event is after SDK grab() and before image/cloud
        # publication. Preserve enough of the 0.1x scheduler interval for the
        # wrapper to finish the iteration and observe the paused flag before a
        # second workstation key can be accepted.
        settle_until = max(
            command_started + NEXT_FRAME_MIN_COMMAND_SECONDS,
            health_completed + NEXT_FRAME_POST_GRAB_SETTLE_SECONDS,
        )
        remaining = settle_until - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)

        target = wrapper_frame + 1
        if target >= total:
            target = total - 1
        # The wrapper does not publish another SvoStatus message after the
        # one-shot grab because it sees PAUSED at the top of its next loop.
        # Reflect the confirmed sequential advance in the controller status.
        self.update_status_fields(STATUS="PAUSED", FRAME_ID=target)
        return f"advanced sequentially to frame {target} and paused"

    def command(self, words: list[str]) -> str:
        if not words:
            raise ValueError("empty command")
        if words[0] == "pause-toggle" and len(words) == 1:
            message, _ = self.toggle_pause()
            return message
        if words[0] == "play-next" and len(words) == 2:
            return self.play_next(float(words[1]))
        if words[0] == "seek" and len(words) == 2:
            request = SetSvoFrame.Request()
            request.frame_id = int(words[1])
            # set_svo_frame is serialized behind the SDK grab mutex.  A full
            # HD1200 NEURAL grab can take well over ten seconds when remote
            # RGB/depth/point-cloud subscribers are active, so a short client
            # timeout reports failure even though the seek later completes.
            response = self.await_response(self.seek_client, request, timeout=35.0)
            if not response.success:
                raise RuntimeError(response.message)
            status = self.status_fields.get("STATUS", "PLAYING")
            if status == "END":
                status = "PLAYING"
            self.update_status_fields(FRAME_ID=request.frame_id, STATUS=status)
            return response.message
        if words[0] == "speed" and len(words) == 2:
            rate = float(words[1])
            return self.set_replay_rate(rate)
        raise ValueError(f"unsupported command: {' '.join(words)}")


class CommandHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        line = self.rfile.readline(4096).decode("utf-8", errors="replace").strip()
        try:
            message = self.server.monitor.command(line.split())
            response = f"OK {message}\n"
        except Exception as error:  # Return bounded errors to the field CLI.
            response = f"ERROR {error}\n"
        self.wfile.write(response.encode("utf-8"))


class CommandServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path: Path, monitor: StatusMonitor) -> None:
        self.monitor = monitor
        super().__init__(str(path), CommandHandler)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--topic", default="/zed/zed_node/status/svo")
    parser.add_argument("--health-topic", default="/zed/zed_node/status/health")
    parser.add_argument("--zed-node", default="/zed/zed_node")
    arguments = parser.parse_args()

    rclpy.init()
    arguments.socket.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        arguments.socket.unlink()
    except FileNotFoundError:
        pass
    node = StatusMonitor(
        arguments.output,
        arguments.topic,
        arguments.health_topic,
        arguments.zed_node,
    )
    server = CommandServer(arguments.socket, node)
    os.chmod(arguments.socket, 0o600)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    try:
        rclpy.spin(node)
    finally:
        server.shutdown()
        server.server_close()
        try:
            arguments.socket.unlink()
        except FileNotFoundError:
            pass
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
