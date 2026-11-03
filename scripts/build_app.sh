#!/usr/bin/env bash
# Builds AISchool.app (needed for native notifications, the aischool:// URL scheme and login item).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AISchool"

APP="build/AISchool.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AISchool"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.personalaischool.app</string>
  <key>CFBundleName</key><string>AI School</string>
  <key>CFBundleDisplayName</key><string>Personal AI School</string>
  <key>CFBundleExecutable</key><string>AISchool</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.personalaischool.deeplink</string>
    <key>CFBundleURLSchemes</key><array><string>aischool</string></array>
  </dict></array>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local use and for notification permission prompts.
codesign --force --deep --sign - "$APP"
echo "Built $APP"
echo "Open it with:  open $APP"
