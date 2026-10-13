#!/bin/zsh
# Builds MacRamPulse.app from the SwiftPM package.
# Usage: scripts/build_app.sh [--install]   (--install copies to /Applications and relaunches)
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product MacRamPulse
bin="$(swift build -c release --show-bin-path)/MacRamPulse"
app=".build/MacRamPulse.app"

mkdir -p "$app/Contents/MacOS"
cp Support/Info.plist "$app/Contents/Info.plist"
cp "$bin" "$app/Contents/MacOS/MacRamPulse"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
  # ditto, not `cp -R`: cp nests the bundle when the destination already exists
  ditto "$app" /Applications/MacRamPulse.app
  killall MacRamPulse 2>/dev/null || true
  open /Applications/MacRamPulse.app
  echo "Installed /Applications/MacRamPulse.app"
fi
