#!/bin/bash
set -euo pipefail

# Swift's generated module cache contains absolute paths. Recreate generated
# state when the checkout has moved, so builds remain portable.
prepare_build_cache() {
  local project_dir="$1"
  local build_dir="$project_dir/.build"
  local marker="$build_dir/.lire-project-root"
  local previous=""

  if [[ -f "$marker" ]]; then
    previous="$(cat "$marker")"
  fi
  if [[ ( -n "$previous" && "$previous" != "$project_dir" ) || ( ! -f "$marker" && -d "$build_dir" ) ]]; then
    rm -rf "$build_dir"
  fi

  mkdir -p "$build_dir/clang-cache" "$build_dir/swift-cache"
  printf '%s\n' "$project_dir" > "$marker"
  export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
}
