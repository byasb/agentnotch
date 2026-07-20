#!/bin/bash
# Build AgentNotch.app and package it into a distributable DMG.
#
#   ./scripts/build-dmg.sh [version]
#
# Produces dist/AgentNotch.dmg — drag-to-Applications installer. Ad-hoc signed
# (no paid Apple Developer account needed); see the README for the one-time
# Gatekeeper step users run on first launch.
set -euo pipefail

VERSION="${1:-0.1.0}"
APP="AgentNotch"
BUNDLE_ID="app.agentnotch"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ Building release binary…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP"
[ -f "$BIN" ] || { echo "build produced no $APP binary"; exit 1; }

echo "▸ Generating icon…"
python3 scripts/make-icon.py >/dev/null

echo "▸ Assembling $APP.app…"
STAGE="$(mktemp -d)"
APPDIR="$STAGE/$APP.app"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"
cp scripts/AppIcon.icns "$APPDIR/Contents/Resources/AppIcon.icns"

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APPDIR" 2>/dev/null || echo "  (codesign skipped)"

echo "▸ Building DMG…"
mkdir -p "$ROOT/dist"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/dist/$APP.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
