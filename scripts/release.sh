#!/usr/bin/env bash
# Builds Runway and publishes it as a GitHub release: ./scripts/release.sh 0.1.0
# install.sh always fetches releases/latest/download/Runway.zip.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.1.0>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift test
RUNWAY_VERSION="$VERSION" ./scripts/build-app.sh
rm -f build/Runway.zip
ditto -c -k --keepParent build/Runway.app build/Runway.zip

gh release create "v$VERSION" build/Runway.zip --title "Runway $VERSION" --generate-notes
