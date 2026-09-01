#!/usr/bin/env bash
#
# Build the GUI as a double-clickable "iOS GPS Spoofer.app" and wrap it in a DMG.
#
#   ./package-dmg.sh              # bundles the .venv (pymobiledevice3) into the app
#   ./package-dmg.sh --no-venv    # lean build; the app expects pymobiledevice3 on PATH
#
# Output: dist/iOS-GPS-Spoofer-<version>.dmg
#
# NOTE on the bundled venv: it's a copy of ./.venv, whose Python still points at
# this machine's Homebrew Python (see .venv/pyvenv.cfg). The DMG therefore runs
# on this Mac and on Macs with the same `brew install python@3.x`. For a fully
# portable build, use --no-venv and have users install pymobiledevice3 themselves.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iOS GPS Spoofer"
BUNDLE_ID="com.iosgpsspoofer.gui"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="build"
DIST_DIR="dist"
APP="$BUILD_DIR/$APP_NAME.app"
BUNDLE_VENV=1

for arg in "$@"; do
  case "$arg" in
    --no-venv) BUNDLE_VENV=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

echo "==> swift build -c release"
swift build -c release --product iosgpsspoofer-gui
BIN=".build/release/iosgpsspoofer-gui"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Uses Apple developer location-simulation via pymobiledevice3.</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
</dict></plist>
PLIST

echo "==> generating icon"
if ICON_OUT="$APP/Contents/Resources/AppIcon.icns" swift - <<'SWIFT'
import AppKit

let out = ProcessInfo.processInfo.environment["ICON_OUT"]!
let iconset = NSTemporaryDirectory() + "iosgpsspoof.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = size * 0.085
    let r = size * 0.2237
    let bgRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: r, yRadius: r)
    NSGradient(colors: [NSColor(srgbRed: 0.28, green: 0.56, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.29, blue: 0.86, alpha: 1)])!
        .draw(in: bg, angle: -90)

    if let base = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let glyph = base.withSymbolConfiguration(cfg) ?? base
        let gs = glyph.size
        glyph.draw(in: NSRect(x: (size - gs.width) / 2, y: (size - gs.height) / 2,
                              width: gs.width, height: gs.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for pt in [16, 32, 128, 256, 512] {
    try! render(CGFloat(pt)).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(pt)x\(pt).png"))
    try! render(CGFloat(pt * 2)).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(pt)x\(pt)@2x.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", out]
try! p.run(); p.waitUntilExit()
exit(p.terminationStatus)
SWIFT
then :; else
  echo "   icon generation failed — app will use the default icon"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

if [ "$BUNDLE_VENV" = 1 ]; then
  if [ ! -x .venv/bin/pymobiledevice3 ]; then
    echo "!! .venv/bin/pymobiledevice3 not found. Run ./setup.sh first, or use --no-venv." >&2
    exit 1
  fi
  echo "==> bundling .venv (pymobiledevice3 $(.venv/bin/pymobiledevice3 version 2>/dev/null || echo '?'))"
  rm -rf "$APP/Contents/Resources/venv"
  cp -R .venv "$APP/Contents/Resources/venv"
  find "$APP/Contents/Resources/venv" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
  find "$APP/Contents/Resources/venv" -type f -name '*.pyc' -delete 2>/dev/null || true
  rm -rf "$APP/Contents/Resources/venv"/lib/python*/site-packages/{pip,pip-*,setuptools,pkg_resources,_distutils_hack} 2>/dev/null || true
  rm -rf "$APP/Contents/Resources/venv"/lib/python*/site-packages/*.dist-info/RECORD 2>/dev/null || true
else
  echo "==> --no-venv: app will look for pymobiledevice3 on PATH / \$PYMOBILEDEVICE3"
fi

echo "==> codesigning (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null \
  || codesign --force --sign - "$APP/Contents/MacOS/$APP_NAME"

echo "==> creating DMG"
mkdir -p "$DIST_DIR"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$DIST_DIR/${APP_NAME// /-}-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "==> done: $DMG  ($SIZE)"
echo "    Open it, drag the app to Applications."
echo "    First launch: right-click ▸ Open (ad-hoc signed, so Gatekeeper warns once)."
