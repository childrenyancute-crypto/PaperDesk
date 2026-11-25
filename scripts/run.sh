#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
for APP in "/Applications/PaperDesk.app" "$HOME/Applications/PaperDesk.app" "$PROJECT_DIR/dist/PaperDesk.app"; do
    if [ -x "$APP/Contents/MacOS/PaperDesk" ]; then
        exec /usr/bin/open "$APP" --args "$@"
    fi
done
"$PROJECT_DIR/scripts/package-app.sh"
exec /usr/bin/open "$PROJECT_DIR/dist/PaperDesk.app" --args "$@"
