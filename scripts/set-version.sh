#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
BUILD_NUMBER="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo "Usage: ./scripts/set-version.sh <major.minor.patch> <increasing-build-number>" >&2
  exit 1
fi
PLIST="$PROJECT_DIR/Resources/Info.plist"
PREVIOUS_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
if (( BUILD_NUMBER <= PREVIOUS_BUILD )); then
  echo "Build number must be greater than $PREVIOUS_BUILD." >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
echo "Version: $VERSION ($BUILD_NUMBER)"
