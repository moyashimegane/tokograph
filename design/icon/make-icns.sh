#!/bin/bash
# Generates the app icon from the final SVG source.
set -euo pipefail
cd "$(dirname "$0")/../.."

SOURCE="design/icon/icon.svg"
OUTPUT="design/icon/AppIcon.icns"

if [[ ! -f "$SOURCE" ]]; then
    echo "Missing icon source: $SOURCE" >&2
    exit 1
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tokograph-icon.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
MASTER="$WORK_DIR/master.png"
ICONSET="$WORK_DIR/AppIcon.iconset"
RENDERER="$WORK_DIR/render-svg.swift"
PACKER="$WORK_DIR/pack-icns.swift"
mkdir -p "$ICONSET"

cat > "$RENDERER" <<'SWIFT'
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("Usage: render-svg.swift input.svg output.png")
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let size = 1024

guard let source = NSImage(contentsOfFile: inputPath) else {
    fail("Unable to load SVG: \(inputPath)")
}
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("Unable to create the bitmap canvas")
}

bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
source.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    from: .zero,
    operation: .copy,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fail("Unable to encode the master PNG")
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fail("Unable to write the master PNG: \(error)")
}
SWIFT

SWIFT_MODULECACHE_PATH="$WORK_DIR/swift-module-cache" \
CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache" \
swift "$RENDERER" "$SOURCE" "$MASTER"

resize() {
    local pixels="$1"
    local filename="$2"
    sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/$filename" >/dev/null
}

resize 16 icon_16x16.png
resize 32 icon_16x16@2x.png
resize 32 icon_32x32.png
resize 64 icon_32x32@2x.png
resize 128 icon_128x128.png
resize 256 icon_128x128@2x.png
resize 256 icon_256x256.png
resize 512 icon_256x256@2x.png
resize 512 icon_512x512.png
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

if ! iconutil -c icns "$ICONSET" -o "$WORK_DIR/AppIcon.icns"; then
    echo "iconutil could not compile the iconset; using the ICNS container fallback." >&2
    cat > "$PACKER" <<'SWIFT'
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, arguments.count % 2 == 1 else {
    fail("Usage: pack-icns.swift output.icns type input.png [type input.png ...]")
}

var body = Data()
var index = 1
while index < arguments.count {
    let type = arguments[index]
    guard type.utf8.count == 4 else {
        fail("Invalid ICNS type: \(type)")
    }
    let inputURL = URL(fileURLWithPath: arguments[index + 1])
    let png: Data
    do {
        png = try Data(contentsOf: inputURL)
    } catch {
        fail("Unable to read icon image: \(error)")
    }
    body.append(Data(type.utf8))
    appendUInt32(UInt32(png.count + 8), to: &body)
    body.append(png)
    index += 2
}

var result = Data("icns".utf8)
appendUInt32(UInt32(body.count + 8), to: &result)
result.append(body)
do {
    try result.write(to: URL(fileURLWithPath: arguments[0]))
} catch {
    fail("Unable to write the ICNS file: \(error)")
}
SWIFT

    SWIFT_MODULECACHE_PATH="$WORK_DIR/swift-module-cache" \
    CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache" \
    swift "$PACKER" "$WORK_DIR/AppIcon.icns" \
        icp4 "$ICONSET/icon_16x16.png" \
        ic11 "$ICONSET/icon_16x16@2x.png" \
        icp5 "$ICONSET/icon_32x32.png" \
        ic12 "$ICONSET/icon_32x32@2x.png" \
        ic07 "$ICONSET/icon_128x128.png" \
        ic13 "$ICONSET/icon_128x128@2x.png" \
        ic08 "$ICONSET/icon_256x256.png" \
        ic14 "$ICONSET/icon_256x256@2x.png" \
        ic09 "$ICONSET/icon_512x512.png" \
        ic10 "$ICONSET/icon_512x512@2x.png"
fi

mv "$WORK_DIR/AppIcon.icns" "$OUTPUT"
echo "Created $OUTPUT"
