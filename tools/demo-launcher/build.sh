#!/bin/bash
# Assembles `Cal Demo.app` on the Desktop from the launcher script and the
# placeholder icon. Re-run after editing either.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Desktop/Cal Demo.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Cal.iconset"
gen() { sips -z "$1" "$1" "$HERE/placeholder-icon-1024.png" --out "$WORK/Cal.iconset/icon_$2.png" >/dev/null; }
gen 16 16x16;    gen 32 16x16@2x
gen 32 32x32;    gen 64 32x32@2x
gen 128 128x128; gen 256 128x128@2x
gen 256 256x256; gen 512 256x256@2x
gen 512 512x512; gen 1024 512x512@2x
iconutil -c icns "$WORK/Cal.iconset" -o "$WORK/Cal.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/cal-demo-launcher.sh" "$APP/Contents/MacOS/CalDemo"
chmod +x "$APP/Contents/MacOS/CalDemo"
cp "$WORK/Cal.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
touch "$APP"
echo "built: $APP"
