#!/bin/bash
# Builds PaperDrop.app (release) into mac/build/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
# UI languages: must equal PaperKit Language.allCases (L10nTests checks this file)
LANGS=(en ja zh-Hans)
swift build -c release --product PaperDrop
swift build -c release --product paperdrop-cli
BIN="$(swift build -c release --show-bin-path)"

APP="build/PaperDrop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PaperDrop" "$APP/Contents/MacOS/PaperDrop"
cp "$BIN/paperdrop-cli" "$APP/Contents/Resources/paperdrop-cli"
swift scripts/make_icon.swift "$APP/Contents/Resources/AppIcon.icns"
# One .lproj per UI language (PaperKit/L10n.swift) so AppKit localizes the standard menus
# and offers the per-app language setting. Our own strings live in L10n, not in these files.
for lang in "${LANGS[@]}"; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  echo '"CFBundleDisplayName" = "PaperDrop";' > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done

LOCALIZATIONS=""
for lang in "${LANGS[@]}"; do LOCALIZATIONS+="<string>$lang</string>"; done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PaperDrop</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
  <key>CFBundleDisplayName</key><string>PaperDrop</string>
  <key>CFBundleIdentifier</key><string>local.paperdrop.app</string>
  <key>CFBundleExecutable</key><string>PaperDrop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "built $(pwd)/$APP"
