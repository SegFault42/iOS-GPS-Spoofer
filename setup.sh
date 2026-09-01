#!/usr/bin/env bash
# One-time setup: create the Python venv with pymobiledevice3 and build the tool.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/pymobiledevice3 ]; then
  echo "==> creating .venv with pymobiledevice3"
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip pymobiledevice3
fi
.venv/bin/pymobiledevice3 version >/dev/null && echo "==> pymobiledevice3 $(.venv/bin/pymobiledevice3 version) ready"

echo "==> building (release): CLI + GUI"
swift build -c release

ROOT="$(pwd)"
echo
echo "Done."
echo "  CLI:  $ROOT/.build/release/iosgpsspoof list"
echo "  GUI:  $ROOT/.build/release/iosgpsspoofer-gui     (or ./run-gui.sh)"
