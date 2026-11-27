#!/usr/bin/env bash
# Builds Runway and publishes it as a GitHub release: ./scripts/release.sh 0.1.0
# install.sh always fetches releases/latest/download/Runway.zip; Sparkle reads
# releases/latest/download/appcast.xml, written here and attached to the same release.
# The EdDSA private key lives in the login keychain (account "runway", see generate_keys).
# Direct download (landing page): RUNWAY_SIGN_IDENTITY="Developer ID Application: …" and
# RUNWAY_NOTARY_PROFILE=<notarytool keychain profile> notarize the app and add a Runway.dmg.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.1.0>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="Romainl01/runway"

# Fail before the build and the notarization wait, not after.
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "release.sh: v$VERSION already exists on GitHub; pick another version." >&2
    exit 1
fi

swift test
# Sparkle compares CFBundleVersion: the commit count only goes up.
BUILD_NUMBER="$(git rev-list --count HEAD)"
RUNWAY_VERSION="$VERSION" RUNWAY_BUILD_NUMBER="$BUILD_NUMBER" ./scripts/build-app.sh
rm -f build/Runway.zip build/Runway.dmg
ditto -c -k --keepParent build/Runway.app build/Runway.zip
ASSETS=(build/Runway.zip build/appcast.xml)

if [[ -n "${RUNWAY_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit build/Runway.zip --keychain-profile "$RUNWAY_NOTARY_PROFILE" --wait
    xcrun stapler staple build/Runway.app
    # Re-zip so Sparkle and install.sh also get the stapled app.
    rm -f build/Runway.zip
    ditto -c -k --keepParent build/Runway.app build/Runway.zip

    # Drag-and-drop DMG: the app next to an Applications alias.
    STAGE="$(mktemp -d)"
    ditto build/Runway.app "$STAGE/Runway.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Runway -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/Runway.dmg
    rm -rf "$STAGE"
    codesign --force --timestamp --sign "$RUNWAY_SIGN_IDENTITY" build/Runway.dmg
    xcrun notarytool submit build/Runway.dmg --keychain-profile "$RUNWAY_NOTARY_PROFILE" --wait
    xcrun stapler staple build/Runway.dmg
    ASSETS+=(build/Runway.dmg)
fi

# sign_update prints: sparkle:edSignature="…" length="…"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
SIGNATURE="$("$SIGN_UPDATE" --account runway build/Runway.zip)"

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Runway</title>
    <item>
      <title>Runway ${VERSION}</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/${REPO}/releases/tag/v${VERSION}</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/${REPO}/releases/download/v${VERSION}/Runway.zip" type="application/octet-stream" ${SIGNATURE} />
    </item>
  </channel>
</rss>
XML

gh release create "v$VERSION" "${ASSETS[@]}" --title "Runway $VERSION" --generate-notes
