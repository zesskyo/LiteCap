#!/bin/bash
# Builds LiteCap.app (and optionally a .dmg) into ./build.
#
#   ./build-app.sh                 build + ad-hoc sign
#   ./build-app.sh --open          …then launch it
#   ./build-app.sh --dmg           …and make build/LiteCap-<version>.dmg
#
# Optional environment:
#   VERSION=1.2.3                  defaults to the latest git tag (v1.2.3 → 1.2.3)
#   SIGN_ID="Developer ID Application: Name (TEAMID)"   real signing + hardened runtime
#   NOTARY_PROFILE=litecap         notarytool keychain profile → notarize + staple the dmg
#   (or NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD, an app-specific password — used in CI)
set -euo pipefail
cd "$(dirname "$0")"

OPEN=0
DMG=0
for arg in "$@"; do
  case "$arg" in
    --open) OPEN=1 ;;
    --dmg) DMG=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v swift >/dev/null; then
  echo "Swift not found. Install Xcode 26+ (App Store) or run: xcode-select --install" >&2
  exit 1
fi

VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_ID="${SIGN_ID:--}"

echo "▸ Compiling LiteCap $VERSION ($BUILD_NUMBER)…"
swift build -c release --arch arm64 --product LiteCap
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/LiteCap.app"
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset
cp "$BIN_DIR/LiteCap" "$APP/Contents/MacOS/LiteCap"

echo "▸ Icon…"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LiteCap</string>
    <key>CFBundleDisplayName</key><string>LiteCap</string>
    <key>CFBundleIdentifier</key><string>app.litecap.LiteCap</string>
    <key>CFBundleExecutable</key><string>LiteCap</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>LiteCap</string>
    <key>NSMicrophoneUsageDescription</key><string>LiteCap records and streams the microphones and audio inputs you add to the mixer.</string>
    <key>NSCameraUsageDescription</key><string>LiteCap shows cameras and capture cards you add as sources.</string>
</dict>
</plist>
PLIST

echo "▸ Signing…"
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp \
    --entitlements Resources/LiteCap.entitlements --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict "$APP"
echo "✓ Built $APP"

if [[ $DMG == 1 ]]; then
  echo "▸ Disk image…"
  DMG_PATH="build/LiteCap-$VERSION.dmg"
  rm -rf build/dmg "$DMG_PATH"
  mkdir -p build/dmg
  cp -R "$APP" build/dmg/
  ln -s /Applications build/dmg/Applications
  hdiutil create -volname "LiteCap $VERSION" -srcfolder build/dmg -ov -format UDZO "$DMG_PATH" >/dev/null
  if [[ "$SIGN_ID" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG_PATH"
  fi
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "▸ Notarizing (a few minutes)…"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
  elif [[ -n "${NOTARY_APPLE_ID:-}" && "$SIGN_ID" != "-" ]]; then
    echo "▸ Notarizing (a few minutes)…"
    xcrun notarytool submit "$DMG_PATH" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" --wait
    xcrun stapler staple "$DMG_PATH"
  fi
  echo "✓ $DMG_PATH"
fi

if [[ $OPEN == 1 ]]; then open "$APP"; fi
