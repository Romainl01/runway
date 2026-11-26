#!/usr/bin/env bash
# Installs (or updates) Runway from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/Romainl01/runway/main/install.sh | bash
set -euo pipefail

REPO="Romainl01/runway"
URL="https://github.com/$REPO/releases/latest/download/Runway.zip"

fail() { printf 'Runway: %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 26 )) || fail "needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))."

# /Applications when writable, else ~/Applications (no sudo).
DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Runway…"
curl -fsSL "$URL" -o "$tmp/Runway.zip" || fail "download failed ($URL)."
ditto -x -k "$tmp/Runway.zip" "$tmp"
[[ -d "$tmp/Runway.app" ]] || fail "the archive has no Runway.app."

# Quit a running copy, then replace it.
pkill -x Runway 2>/dev/null || true
rm -rf "$DEST/Runway.app"
ditto "$tmp/Runway.app" "$DEST/Runway.app"
xattr -dr com.apple.quarantine "$DEST/Runway.app" 2>/dev/null || true

open "$DEST/Runway.app"
echo "Runway is installed in $DEST and running in your menu bar."
