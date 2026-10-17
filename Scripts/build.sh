#!/bin/bash
# Builds "JApp Runtime.app" (runtime + bundled `japp` CLI + example) into ./build.
#
#   Scripts/build.sh            release build
#   CONFIG=debug Scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/JApp Runtime.app"
VERSION="$(sed -n 's/.*static let runtime = "\(.*\)".*/\1/p' "$ROOT/Sources/JAppKit/JAppVersion.swift")"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT" --product JAppRuntime
swift build -c "$CONFIG" --package-path "$ROOT" --product japp
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Examples" "$APP/Contents/Resources/Docs"
cp "$BIN/JAppRuntime" "$APP/Contents/MacOS/JAppRuntime"
cp "$BIN/japp" "$APP/Contents/Helpers/japp"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$(date +%Y%m%d%H%M)/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/JAppDocument.icns" "$APP/Contents/Resources/"
cp "$ROOT/Docs/"*.md "$APP/Contents/Resources/Docs/" 2>/dev/null || true

echo "==> Packing examples"
for example in "$ROOT/Examples/"*/; do
    name="$(basename "$example")"
    "$BIN/japp" pack "$example" --output "$BUILD_DIR/$name.japp"
    cp "$BUILD_DIR/$name.japp" "$APP/Contents/Resources/Examples/"
done

echo "==> Signing (ad hoc)"
xattr -cr "$APP"   # codesign rejects extended attributes (e.g. Finder info) inside a bundle
codesign --force --options runtime --sign - "$APP/Contents/Helpers/japp"
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP ($VERSION)"
