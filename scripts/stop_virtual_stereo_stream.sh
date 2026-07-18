#!/usr/bin/env bash
set -euo pipefail

if pgrep -x ZED_Media_Server >/dev/null; then
  pkill -TERM -x ZED_Media_Server
  echo "Requested ZED Media Server shutdown."
else
  echo "ZED Media Server is not running."
fi
