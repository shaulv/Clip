#!/usr/bin/env bash
# Clip — build helper
# Usage:
#   ./build.sh            # build an unsigned .app (for local testing)
#   ./build.sh xcode      # just open the project in Xcode

set -euo pipefail

MODE="${1:-build}"

if [ "$MODE" = "xcode" ]; then
  # A fresh clone has no project file yet - it is generated, not committed.
  python3 regen-project.py
  open Clip.xcodeproj
  exit 0
fi

# The project file is generated from the files on disk, and is not committed.
# A fresh clone therefore has no Clip.xcodeproj at all, and without this the
# first thing a new contributor sees is "'Clip.xcodeproj' does not exist."
echo "▸ Generating the Xcode project"
python3 regen-project.py

echo "▸ Building Clip (unsigned)..."

xcodebuild -project Clip.xcodeproj \
  -scheme Clip \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="build/Build/Products/Debug/Clip.app"

echo ""
echo "▸ Built successfully: $APP"
echo "▸ Launching Clip..."
open "$APP"
echo "   Clip is a menu-bar app — look for the clipboard icon in the menu bar."
