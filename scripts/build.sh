#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION="${1:-release}"
ARCHITECTURE="${2:-native}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]] ||
   [[ "$ARCHITECTURE" != "native" && "$ARCHITECTURE" != "arm64" && "$ARCHITECTURE" != "universal" ]]; then
  echo "Usage: ./scripts/build.sh [release|debug] [native|arm64|universal]" >&2
  exit 1
fi
mkdir -p .build/clang-cache .build/swift-cache build
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache"
if [[ "$CONFIGURATION" == "debug" ]]; then
  APP_DIR="$PROJECT_DIR/build/Light Reader.app"
else
  APP_DIR="$PROJECT_DIR/build/release/Light Reader.app"
fi
# Construct a clean bundle; never copy a project directory or personal settings.
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/build/bundle.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/Light Reader.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
BUILD_ARGS=(-c "$CONFIGURATION" --product LightReader --disable-sandbox --cache-path "$PROJECT_DIR/.build/swift-cache")
if [[ "$ARCHITECTURE" == "universal" ]]; then
  BINARIES=()
  for ARCH in arm64 x86_64; do
    swift build "${BUILD_ARGS[@]}" --arch "$ARCH"
    BINARY_DIR="$(swift build -c "$CONFIGURATION" --arch "$ARCH" --show-bin-path --disable-sandbox)"
    BINARIES+=("$BINARY_DIR/LightReader")
  done
  xcrun lipo -create "${BINARIES[@]}" -output "$STAGED_APP/Contents/MacOS/LightReader"
else
  ARCH_ARGS=()
  if [[ "$ARCHITECTURE" == "arm64" ]]; then ARCH_ARGS=(--arch arm64); fi
  swift build "${BUILD_ARGS[@]}" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
  BINARY_DIR="$(swift build -c "$CONFIGURATION" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path --disable-sandbox)"
  cp "$BINARY_DIR/LightReader" "$STAGED_APP/Contents/MacOS/LightReader"
fi
cp Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
if [[ "$CONFIGURATION" == "debug" ]]; then
  /usr/libexec/PlistBuddy -c "Add :LightReaderProjectRoot string $PROJECT_DIR" "$STAGED_APP/Contents/Info.plist"
fi
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"; fi
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$STAGED_APP"
else
  codesign --force --sign - "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
mkdir -p "$(dirname "$APP_DIR")"
# ditto overwrites only the generated bundle; fresh staging keeps personal data out.
ditto "$STAGED_APP" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Built: $APP_DIR"
