#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CmdMD"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
EXECUTABLE="$MACOS_DIR/$APP_NAME"
PLIST="$CONTENTS_DIR/Info.plist"
ZIP_FILE="$DIST_DIR/$APP_NAME-macos.zip"

echo "Building $APP_NAME release..."
BUILD_BIN_DIR="$(swift build --configuration release --show-bin-path)"
swift build --configuration release

BUILT_EXECUTABLE="$BUILD_BIN_DIR/$APP_NAME"
if [[ ! -x "$BUILT_EXECUTABLE" ]]; then
  echo "Release executable not found: $BUILT_EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$ZIP_FILE"
mkdir -p "$MACOS_DIR"

cp "$BUILT_EXECUTABLE" "$EXECUTABLE"
chmod 755 "$EXECUTABLE"

cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>CmdMD</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>md</string>
        <string>markdown</string>
        <string>mdown</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Markdown Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
      </array>
    </dict>
  </array>
  <key>CFBundleExecutable</key>
  <string>CmdMD</string>
  <key>CFBundleIdentifier</key>
  <string>com.cmdmd.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>CmdMD</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.cmdmd.app</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>cmdmd</string>
      </array>
    </dict>
  </array>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "Ad-hoc signing $APP_NAME.app..."
  codesign --force --deep --sign - "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
else
  echo "codesign not found; leaving $APP_NAME.app unsigned."
fi

(
  cd "$DIST_DIR"
  zip -qry -X "$(basename "$ZIP_FILE")" "$APP_NAME.app"
)

echo "Created $ZIP_FILE"
