#!/bin/sh
# Build CCMenubar.app (menu bar only). Usage: ./build.sh [--install]
set -e
cd "$(dirname "$0")"
APP=build/CCMenubar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/CCMenubar" Sources/main.swift
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.leondgarse.cc-menubar</string>
  <key>CFBundleName</key><string>CCMenubar</string>
  <key>CFBundleExecutable</key><string>CCMenubar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
if [ "$1" = "--install" ]; then
  pkill -x CCMenubar 2>/dev/null || true
  rm -rf ~/Applications/CCMenubar.app
  mkdir -p ~/Applications && cp -R "$APP" ~/Applications/
  open ~/Applications/CCMenubar.app
  echo "Installed to ~/Applications and launched"
fi
