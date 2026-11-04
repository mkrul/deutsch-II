#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/Translate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ICON_DIR="$(mktemp -d)"
cat > "$ICON_DIR/main.swift" << 'EOF'
import AppKit
let side = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fputs("bitmap failed\n", stderr); exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
AppIcon.make(side: CGFloat(side)).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF
swiftc -framework AppKit -o "$ICON_DIR/make-icon" Sources/Translate/Icon.swift "$ICON_DIR/main.swift"
"$ICON_DIR/make-icon" "$ICON_DIR/icon_1024.png"
mkdir -p "$ICON_DIR/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_DIR"

cp "$BIN_DIR/Translate" "$APP/Contents/MacOS/Translate"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "Translate Local" "$APP"
echo "$APP"
