#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONNECTOR=""
for APP in "/Applications/PaperDesk.app" "$HOME/Applications/PaperDesk.app" "$PROJECT_DIR/dist/PaperDesk.app"; do
    if [ -x "$APP/Contents/Helpers/paperdesk-mcp" ]; then
        CONNECTOR="$APP/Contents/Helpers/paperdesk-mcp"
        break
    fi
done
CODEX_BIN="$(command -v codex || true)"
if [ -z "$CODEX_BIN" ]; then
    CODEX_BIN="/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
fi
if [ ! -x "$CODEX_BIN" ]; then
    printf '请先安装或打开 Codex 桌面应用。\n' >&2
    exit 1
fi
if [ ! -x "$CONNECTOR" ]; then
    "$PROJECT_DIR/scripts/package-app.sh"
    CONNECTOR="$PROJECT_DIR/dist/PaperDesk.app/Contents/Helpers/paperdesk-mcp"
fi
if "$CODEX_BIN" mcp get paperdesk --json >/dev/null 2>&1; then
    printf 'Codex 已有名为 paperdesk 的连接。请在 Codex 设置中查看该连接。\n'
    exit 0
fi
exec "$CODEX_BIN" mcp add paperdesk -- "$CONNECTOR" --library "$HOME/Library/Application Support/PaperDesk/Library"
