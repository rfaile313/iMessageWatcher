#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="iMessageWatcher"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME v2.0..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# ── Generate app icon ──────────────────────────────────────────────
echo "Generating app icon..."
ICON_DIR=$(mktemp -d)
ICONSET="$ICON_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"

# Generate icon PNGs at all required sizes using a Swift script
/usr/bin/swift - "$ICONSET" <<'ICONSWIFT'
import Cocoa

let outDir = CommandLine.arguments[1]

let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (sz, name) in sizes {
    let s = CGFloat(sz)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext

    // Background: rounded rect with blue gradient
    let pad = s * 0.08
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let radius = s * 0.2
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Blue gradient background
    let colors = [
        CGColor(red: 0.05, green: 0.45, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.02, green: 0.35, blue: 0.85, alpha: 1.0)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.resetClip()

    // Speech bubble
    let bubbleW = s * 0.55
    let bubbleH = s * 0.40
    let bubbleX = (s - bubbleW) / 2
    let bubbleY = s * 0.35
    let bubbleRect = CGRect(x: bubbleX, y: bubbleY, width: bubbleW, height: bubbleH)
    let bubbleRadius = s * 0.08
    let bubblePath = CGMutablePath()
    bubblePath.addRoundedRect(in: bubbleRect, cornerWidth: bubbleRadius, cornerHeight: bubbleRadius)

    // Tail
    let tailX = bubbleX + bubbleW * 0.2
    let tailY = bubbleY
    bubblePath.move(to: CGPoint(x: tailX, y: tailY))
    bubblePath.addLine(to: CGPoint(x: tailX - s * 0.06, y: tailY - s * 0.08))
    bubblePath.addLine(to: CGPoint(x: tailX + s * 0.06, y: tailY))

    ctx.setFillColor(CGColor.white)
    ctx.addPath(bubblePath)
    ctx.fillPath()

    // Calendar grid inside bubble: 3x2 grid of small squares
    let gridCols = 3
    let gridRows = 2
    let cellSz = s * 0.06
    let gap = s * 0.03
    let gridW = CGFloat(gridCols) * cellSz + CGFloat(gridCols - 1) * gap
    let gridH = CGFloat(gridRows) * cellSz + CGFloat(gridRows - 1) * gap
    let gridX = bubbleX + (bubbleW - gridW) / 2
    let gridY = bubbleY + (bubbleH - gridH) / 2

    for row in 0..<gridRows {
        for col in 0..<gridCols {
            let cx = gridX + CGFloat(col) * (cellSz + gap)
            let cy = gridY + CGFloat(row) * (cellSz + gap)
            let cellRect = CGRect(x: cx, y: cy, width: cellSz, height: cellSz)
            let cr = s * 0.01
            ctx.addPath(CGPath(roundedRect: cellRect, cornerWidth: cr, cornerHeight: cr, transform: nil))
        }
    }
    ctx.setFillColor(CGColor(red: 0.05, green: 0.45, blue: 1.0, alpha: 0.8))
    ctx.fillPath()

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        continue
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try? png.write(to: url)
}
ICONSWIFT

# Convert iconset to icns
iconutil -c icns -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$ICON_DIR"
echo "Icon generated."

# ── Compile ────────────────────────────────────────────────────────
swiftc \
    -framework Cocoa \
    -framework EventKit \
    -lsqlite3 \
    -O \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "$SCRIPT_DIR/main.swift" \
    "$SCRIPT_DIR/AppDelegate.swift"

# Bundle Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# ── Create release zip ────────────────────────────────────────────
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$BUILD_DIR/$APP_NAME.zip"

echo ""
echo "Built: $APP_BUNDLE"
echo "Zip:   $BUILD_DIR/$APP_NAME.zip"
echo ""
echo "To run:  open $APP_BUNDLE"
echo "To install: cp -r $APP_BUNDLE ~/Applications/"
