#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-$PROJECT_DIR/build/release/Light Reader.app}"
EXPECTED_ARCH="${2:-arm64}"
PLIST="$APP_DIR/Contents/Info.plist"
EXECUTABLE="$APP_DIR/Contents/MacOS/LightReader"
plutil -lint "$PLIST"
if /usr/libexec/PlistBuddy -c 'Print :LightReaderProjectRoot' "$PLIST" >/dev/null 2>&1; then
  echo 'Release app must not contain a development project path.' >&2
  exit 1
fi
ACTUAL_ARCH="$(xcrun lipo -archs "$EXECUTABLE")"
case "$EXPECTED_ARCH" in
  arm64|x86_64)
    [[ "$ACTUAL_ARCH" == "$EXPECTED_ARCH" ]] || { echo "Unexpected architecture: $ACTUAL_ARCH" >&2; exit 1; }
    ;;
  universal)
    xcrun lipo -verify_arch arm64 x86_64 "$EXECUTABLE"
    ;;
  *) echo 'Expected architecture must be arm64, x86_64, or universal.' >&2; exit 1 ;;
esac
# Explicit allowlist: release bundles currently have no third-party frameworks.
# Update this deliberately if a future feature adds resources or an updater.
while IFS= read -r -d '' FILE; do
  RELATIVE="${FILE#"$APP_DIR/"}"
  case "$RELATIVE" in
    Contents/Info.plist|Contents/MacOS/LightReader|Contents/Resources/AppIcon.icns|Contents/_CodeSignature/CodeResources) ;;
    *) echo "Unexpected release bundle entry: $RELATIVE" >&2; exit 1 ;;
  esac
done < <(find "$APP_DIR" \( -type f -o -type l \) -print0)
codesign --verify --deep --strict "$APP_DIR"
echo "Release bundle verified: $ACTUAL_ARCH; no project path or extra data files."
