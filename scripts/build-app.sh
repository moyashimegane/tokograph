#!/bin/bash
# Builds Tokograph.app (release, unsigned → ad-hoc signed for local arm64 execution).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
swift build -c release
BIN=".build/release/tokograph"
APP="dist/Tokograph.app"
ICON="design/icon/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
    echo "Missing app icon: $ICON" >&2
    exit 1
fi
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.moyashimegane.tokograph</string>
    <key>CFBundleName</key><string>Tokograph</string>
    <key>CFBundleExecutable</key><string>tokograph</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/tokograph"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"   # ad-hoc: required for local arm64 execution; not identity signing
echo "Built $APP"
(cd dist && zip -qry Tokograph.zip Tokograph.app && shasum -a 256 Tokograph.zip && shasum -a 256 Tokograph.zip > Tokograph.zip.sha256)
