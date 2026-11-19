#!/bin/bash
# Compiles Gauge.swift into ~/Applications/Gauge.app and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")"

app="$HOME/Applications/Gauge.app"
build="build/Gauge.app"

rm -rf "$build"
mkdir -p "$build/Contents/MacOS" "$build/Contents/Resources"

# App icon: render the 1024px master if missing, then build every size macOS wants into an .icns
[ -f icon/AppIcon-1024.png ] || swift icon/make-icon.swift icon/AppIcon-1024.png
iconset=build/AppIcon.iconset
rm -rf "$iconset" && mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s icon/AppIcon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon/AppIcon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$build/Contents/Resources/AppIcon.icns"

swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  Gauge.swift -o "$build/Contents/MacOS/Gauge"

cat > "$build/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.gauge</string>
  <key>CFBundleName</key><string>Gauge</string>
  <key>CFBundleExecutable</key><string>Gauge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- menu bar only: no Dock icon, no app menu -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# ad-hoc signature so macOS will run it locally and allow "Open at login"
codesign --force --sign - "$build"

pkill -x Gauge || true
mkdir -p "$HOME/Applications"
rm -rf "$app"
cp -R "$build" "$app"
open "$app"
echo "Built and launched $app"
