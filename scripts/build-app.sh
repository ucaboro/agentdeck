#!/bin/zsh
# Builds AgentDeck.app (release), ad-hoc signed, into ./build/.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
APP="build/AgentDeck.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/AgentDeck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentDeck"

if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Optional Cursor bridge extension, installable from Settings → Integrations.
integrations/cursor-bridge/build.sh --no-install >/dev/null
cp integrations/cursor-bridge/agentdeck-bridge-*.vsix "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentDeck</string>
  <key>CFBundleDisplayName</key><string>AgentDeck</string>
  <key>CFBundleIdentifier</key><string>app.agentdeck.AgentDeck</string>
  <key>CFBundleExecutable</key><string>AgentDeck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>AgentDeck — local AI agent command centre</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP ($VERSION, $BUILD_NUMBER)"
