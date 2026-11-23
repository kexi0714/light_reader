#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
source "$PROJECT_DIR/scripts/prepare-build.sh"
prepare_build_cache "$PROJECT_DIR"
swift run --disable-sandbox --cache-path "$PROJECT_DIR/.build/swift-cache" LightReaderChecks
