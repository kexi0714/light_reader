#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
ARCHITECTURE="${1:-arm64}"
if [[ "$ARCHITECTURE" != "universal" && "$ARCHITECTURE" != "native" && "$ARCHITECTURE" != "arm64" ]]; then
  echo "Usage: ./scripts/package.sh [arm64|native|universal]" >&2
  exit 1
fi
./scripts/build.sh release "$ARCHITECTURE"
APP_DIR="$PROJECT_DIR/build/release/Light Reader.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
LABEL="$ARCHITECTURE"
if [[ "$ARCHITECTURE" == "native" ]]; then LABEL="$(uname -m)"; fi
./scripts/verify-release.sh "$APP_DIR" "$LABEL"
mkdir -p dist
IMAGE="$PROJECT_DIR/dist/Light-Reader-$VERSION-macOS-$LABEL.dmg"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/build/dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/Light Reader.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/Install.txt" <<'INSTALL'
Light Reader

1. Drag Light Reader.app to Applications.
2. Eject this disk image.
3. Launch Light Reader from Applications.
4. Open Translation Settings (Command-comma) and configure your own translation API.

Requires macOS 14 Sonoma or later. The default arm64 package requires Apple silicon. No Python, Conda, or source checkout is needed.
Settings: ~/Library/Application Support/Light Reader/
PDF annotations are saved into each PDF with Command-S.

This development package has an ad-hoc signature, unless its distributor has
signed and notarized it separately. For a trusted, unnotarized build blocked by
macOS, review System Settings > Privacy & Security after attempting to open it.
INSTALL
hdiutil create -volname "Light Reader" -srcfolder "$STAGING_DIR" -format UDZO -ov "$IMAGE"
hdiutil verify "$IMAGE"
(cd dist && shasum -a 256 "$(basename "$IMAGE")" > "$(basename "$IMAGE").sha256")
echo "Packaged: $IMAGE"
echo "Checksum: $IMAGE.sha256"
