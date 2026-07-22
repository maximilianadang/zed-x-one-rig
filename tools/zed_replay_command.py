#!/usr/bin/env python3
"""Send one command to the persistent Jetson SVO replay controller."""

from __future__ import annotations

import argparse
from pathlib import Path
import socket


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("command", nargs="+")
    arguments = parser.parse_args()

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        # The Jetson-side seek service may wait behind an in-flight HD1200
        # NEURAL grab.  Keep this longer than the controller's 35 s service
        # deadline so callers receive the real response instead of an early
        # socket timeout.
        connection.settimeout(45.0)
        connection.connect(str(arguments.socket))
        connection.sendall((" ".join(arguments.command) + "\n").encode("utf-8"))
        response = connection.makefile("r", encoding="utf-8").readline().rstrip("\n")
    if response.startswith("OK "):
        print(response[3:])
        return
    if response.startswith("ERROR "):
        raise SystemExit(f"ERROR: {response[6:]}")
    raise SystemExit(f"ERROR: malformed replay-controller response: {response}")


if __name__ == "__main__":
    main()
