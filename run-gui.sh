#!/usr/bin/env bash
# Build (if needed) and launch the GUI. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product iosgpsspoofer-gui
exec ./.build/release/iosgpsspoofer-gui
