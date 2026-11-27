#!/usr/bin/env bash
# Builds build/Runway.app: release, universal (Apple silicon + Intel), signed.
# Signing: ad-hoc by default; RUNWAY_SIGN_IDENTITY="<codesigning identity>" for a stable identity
# (keeps notification permissions across rebuilds). VERSION comes from RUNWAY_VERSION.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${RUNWAY_SIGN_IDENTITY:--}"
APP="$ROOT/build/Runway.app"
VERSION="${RUNWAY_VERSION:-0.1.0}"
BUILD_NUMBER="${RUNWAY_BUILD_NUMBER:-1}"

cd "$ROOT"
swift build -c release --product Runway --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Runway"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Runway"
# Sparkle (updates): the binary's rpath points at Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
    <key>CFBundleExecutable</key><string>Runway</string>
    <key>CFBundleIdentifier</key><string>com.rocapine.runway</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Runway</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDisplayName</key><string>Runway</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>SUFeedURL</key><string>https://github.com/Romainl01/runway/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>zueBxSsaUNfu8rKInRG2ttOYmmn3DiylQsOxGFbbMWE=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Romain Lagrange</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# String Catalog -> en.lproj / fr.lproj (English is the source, French a translation).
xcrun xcstringstool compile "$ROOT/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources"

# App icon (black square, white mini gauge), rendered then packed as .icns.
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/icon_1024.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ROOT/build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$ROOT/build/icon_1024.png"

# Inside out: Sparkle's helpers, then the framework, then the app. Hardened runtime and a timestamp only
# with a real identity: ad-hoc code has no team ID, so library validation would refuse Sparkle.
TS=(); [[ "$IDENTITY" == "-" ]] || TS=(--options runtime --timestamp)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    if [[ -e "$item" ]]; then codesign --force ${TS[@]+"${TS[@]}"} --sign "$IDENTITY" "$item"; fi
done
# The downloader keeps its own entitlements (Sparkle's documented signing order).
codesign --force ${TS[@]+"${TS[@]}"} --preserve-metadata=entitlements --sign "$IDENTITY" "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force ${TS[@]+"${TS[@]}"} --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force ${TS[@]+"${TS[@]}"} --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "OK: $APP"
