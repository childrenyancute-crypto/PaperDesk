#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_DIR/scripts/build.sh"
BIN_DIR="$("$PROJECT_DIR/scripts/build.sh" --show-bin-path)"
DIST_DIR="$PROJECT_DIR/dist"
mkdir -p "$DIST_DIR"
STAGE_DIR="$(mktemp -d "$DIST_DIR/.paperdesk-build.XXXXXX")"
trap 'rm -rf -- "$STAGE_DIR"' EXIT
APP_DIR="$STAGE_DIR/PaperDesk.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/PaperDesk" "$APP_DIR/Contents/MacOS/PaperDesk"
cp "$BIN_DIR/paperdesk-mcp" "$APP_DIR/Contents/Helpers/paperdesk-mcp"
cp "$PROJECT_DIR/assets/PaperDesk.icns" "$APP_DIR/Contents/Resources/PaperDesk.icns"
/usr/bin/ditto "$BIN_DIR/PaperDesk_SwiftMath.bundle" "$APP_DIR/Contents/Resources/PaperDesk_SwiftMath.bundle"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>PaperDesk</string>
<key>CFBundleDisplayName</key><string>PaperDesk</string>
<key>CFBundleIdentifier</key><string>local.paperdesk.reader</string>
<key>CFBundleExecutable</key><string>PaperDesk</string>
<key>CFBundleIconFile</key><string>PaperDesk.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.8</string>
<key>CFBundleVersion</key><string>30</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>PDF document</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
</dict></array>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep "$APP_DIR"
FINAL_APP="$DIST_DIR/PaperDesk.app"
if [ -e "$FINAL_APP" ]; then
    mv "$FINAL_APP" "$STAGE_DIR/Previous.app"
fi
if ! mv "$APP_DIR" "$FINAL_APP"; then
    if [ -e "$STAGE_DIR/Previous.app" ]; then
        mv "$STAGE_DIR/Previous.app" "$FINAL_APP"
    fi
    exit 1
fi
printf 'Built %s\n' "$FINAL_APP"
