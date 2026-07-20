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

# The icon is committed (scripts/AppIcon.icns). Only regenerate if it's missing
# (needs Python + Pillow); everyday builds just reuse the checked-in file.
if [ ! -f scripts/AppIcon.icns ]; then
  echo "▸ Icon missing — generating…"
  python3 scripts/make-icon.py >/dev/null
fi

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

# Sign with a Developer ID cert if one is available (needed for notarization).
# Override with SIGN_ID="Developer ID Application: Name (TEAMID)"; otherwise
# auto-detect. Falls back to ad-hoc so builds still work with no paid account.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')}"

if [ -n "$SIGN_ID" ]; then
  echo "▸ Signing with: $SIGN_ID"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_ID" "$APPDIR"
else
  echo "▸ Ad-hoc signing (no Developer ID cert found — app won't be notarizable)"
  codesign --force --deep --sign - "$APPDIR" 2>/dev/null || echo "  (codesign skipped)"
fi

# Notarize the .app itself, then staple the ticket INTO the bundle, so the app
# carries its own proof and opens cleanly even offline. Set the profile up once:
#   xcrun notarytool store-credentials NOTARY --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>
# then: NOTARY_PROFILE=NOTARY ./scripts/build-dmg.sh
if [ -n "${NOTARY_PROFILE:-}" ] && [ -n "$SIGN_ID" ]; then
  echo "▸ Notarizing the app (this can take a minute or two)…"
  ZIP="$STAGE/$APP.zip"
  ditto -c -k --keepParent "$APPDIR" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP"
  echo "▸ Stapling ticket into the app…"
  xcrun stapler staple "$APPDIR"
  NOTARIZED=1
else
  echo "▸ Skipping notarization (set NOTARY_PROFILE and a Developer ID cert to enable)"
fi

echo "▸ Building DMG…"
mkdir -p "$ROOT/dist"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/dist/$APP.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Staple the DMG too, so the whole download is self-verifying.
if [ "${NOTARIZED:-0}" = 1 ]; then
  xcrun stapler staple "$DMG" >/dev/null && echo "✓ notarized + stapled"
fi
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
