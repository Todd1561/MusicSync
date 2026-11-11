#!/bin/bash
# Builds MusicSync.app (Apple silicon + Intel) and MusicSync.zip into this folder.
# Needs only the Xcode Command Line Tools. Attach MusicSync.zip to a GitHub Release.
set -euo pipefail
cd "$(dirname "$0")"

# Keep intermediate build files out of the cloud-synced project folder.
SCRATCH="$HOME/Library/Caches/MusicSync-build"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --scratch-path "$SCRATCH" "${ARCHS[@]}"
BIN="$(swift build -c release --scratch-path "$SCRATCH" "${ARCHS[@]}" --show-bin-path)/MusicSync"

STAGE="$SCRATCH/MusicSync.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BIN" "$STAGE/Contents/MacOS/MusicSync"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"

# App icon: draw the 1024px master, then let sips/iconutil make the other sizes.
ICONSET="$SCRATCH/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$STAGE/Contents/Resources"
swift Resources/make-icon.swift "$SCRATCH/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SCRATCH/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$SCRATCH/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$STAGE"

rm -rf MusicSync.app
ditto "$STAGE" MusicSync.app
rm -f MusicSync.zip
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" MusicSync.zip
echo "Built $(pwd)/MusicSync.app ($(lipo -archs MusicSync.app/Contents/MacOS/MusicSync)) and MusicSync.zip"
