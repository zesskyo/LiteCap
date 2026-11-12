#!/bin/bash
# Signs build/LiteCap-<version>.dmg for Sparkle and writes build/appcast.xml.
# Used by CI for tagged releases. Needs SPARKLE_PRIVATE_KEY in the environment.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"
REPO="${REPO:-zesskyo/LiteCap}"
PLIST="build/LiteCap.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
TAG="${TAG:-v$VERSION}"
DMG="build/LiteCap-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "$DMG not found" >&2; exit 1; }

SIGN_UPDATE="$(find .build/artifacts -name sign_update -type f -not -path '*old_dsa*' | head -1)"
[[ -n "$SIGN_UPDATE" ]] || { echo "Sparkle's sign_update not found" >&2; exit 1; }
KEYFILE="$(mktemp)"
trap 'rm -f "$KEYFILE"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEYFILE"
# Prints: sparkle:edSignature="…" length="…"
ATTRIBUTES="$("$SIGN_UPDATE" --ed-key-file "$KEYFILE" "$DMG")"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LiteCap</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>LiteCap $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/LiteCap-$VERSION.dmg"
                 type="application/octet-stream" $ATTRIBUTES />
    </item>
  </channel>
</rss>
XML
echo "✓ build/appcast.xml for $VERSION ($BUILD)"
