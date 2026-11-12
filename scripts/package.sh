#!/bin/bash
# Construieste EGPRO.app si EGPRO.dmg (ruleaza pe macOS, local sau pe GitHub).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="${GITHUB_RUN_NUMBER:-1}"
ARCHS=(--arch arm64 --arch x86_64)

echo "==> Compilez EGPRO $VERSION ($BUILD)"
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

OUT=build
APP="$OUT/EGPRO.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/EGPRO" "$APP/Contents/MacOS/EGPRO"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> Iconita"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Semnatura locala (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "EGPRO" -srcfolder "$STAGE" -ov -format UDZO "$OUT/EGPRO.dmg"
rm -rf "$STAGE"

echo "==> Gata: $OUT/EGPRO.dmg"
