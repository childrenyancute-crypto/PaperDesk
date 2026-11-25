#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PROJECT_DIR/.build/cache"
cd "$PROJECT_DIR"
if printf 'import XCTest\n' | swiftc -typecheck -module-cache-path "$CLANG_MODULE_CACHE_PATH" - >/dev/null 2>&1; then
    swift test --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH" "$@"
else
    printf 'Command Line Tools: running standalone verification.\n'
    "$PROJECT_DIR/scripts/build.sh"
fi
BIN_DIR="$("$PROJECT_DIR/scripts/build.sh" --show-bin-path)"
if command -v python3 >/dev/null 2>&1; then
    python3 "$PROJECT_DIR/scripts/check-mcp-stdio.py" "$BIN_DIR/paperdesk-mcp"
fi
"$BIN_DIR/paperdesk-check" --verify
"$BIN_DIR/PaperDesk" --self-check
