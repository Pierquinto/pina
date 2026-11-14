#!/bin/bash
# Compila Pina e la installa in ~/Applications.
# BUNDLE_ID si può cambiare per una propria distribuzione: BUNDLE_ID=com.tuodominio.pina ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
BUNDLE_ID="${BUNDLE_ID:-app.pina.mac}"
VERSIONE="0.2.0"
swift build -c release
APP="${DEST:-$HOME/Applications}/Pina.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pina "$APP/Contents/MacOS/Pina"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Pina</string>
  <key>CFBundleDisplayName</key><string>Pina</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Pina</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSIONE</string>
  <key>CFBundleVersion</key><string>$VERSIONE</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Installata in $APP"
