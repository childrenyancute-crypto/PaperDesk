#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/cache"
cd "$PROJECT_DIR"
exec swift build --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH" "$@"
