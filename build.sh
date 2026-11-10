#!/bin/sh
# Build cc-menubar (macOS menu bar app or Linux AppIndicator). Usage: ./build.sh [--install]
set -e
cd "$(dirname "$0")"

if [ "$(uname -s)" = "Linux" ]; then
  mkdir -p build
  cp cc-menubar.py build/cc-menubar
  cp statusline.sh install-statusline.sh build/
  chmod +x build/cc-menubar build/statusline.sh build/install-statusline.sh
  echo "Built build/cc-menubar (Linux AppIndicator)"
  if [ "$1" = "--install" ]; then
    pkill -f "cc-menubar/cc-menubar" 2>/dev/null || pkill -f "cc-menubar\.py" 2>/dev/null || true
    DEST="$HOME/.local/share/cc-menubar"
    BIN="$HOME/.local/bin"
    mkdir -p "$DEST" "$BIN" "$HOME/.config/autostart" "$HOME/.local/share/applications" "$HOME/.config/systemd/user"
    cp build/cc-menubar build/statusline.sh build/install-statusline.sh "$DEST/"
    ln -sf "$DEST/cc-menubar" "$BIN/cc-menubar"
    cat > "$HOME/.config/autostart/cc-menubar.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CC Menubar
Comment=Menu bar monitor for Antigravity CLI (agy) and Claude Code sessions
Exec=$DEST/cc-menubar
Terminal=false
Categories=Utility;Development;
X-GNOME-Autostart-enabled=true
EOF
    cp "$HOME/.config/autostart/cc-menubar.desktop" "$HOME/.local/share/applications/cc-menubar.desktop"
    cat > "$HOME/.config/systemd/user/cc-menubar.service" <<EOF
[Unit]
Description=CC Menubar monitor for Antigravity CLI (agy) and Claude Code sessions
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=$DEST/cc-menubar
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
    if command -v systemctl >/dev/null 2>&1 && systemctl --user is-system-running >/dev/null 2>&1; then
      rm -f "$HOME/.config/autostart/cc-menubar.desktop"
      systemctl --user daemon-reload
      systemctl --user enable cc-menubar.service >/dev/null 2>&1 || true
      systemctl --user restart cc-menubar.service
    else
      setsid -f "$DEST/cc-menubar" >/dev/null 2>&1
    fi
    echo "Installed to $DEST (symlinked at $BIN/cc-menubar, systemd user service enabled & running)"
  fi
  exit 0
fi

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
mkdir -p "$APP/Contents/Resources"
cp statusline.sh install-statusline.sh "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
if [ "$1" = "--install" ]; then
  pkill -x CCMenubar 2>/dev/null || true
  rm -rf ~/Applications/CCMenubar.app
  mkdir -p ~/Applications && cp -R "$APP" ~/Applications/
  open ~/Applications/CCMenubar.app
  echo "Installed to ~/Applications and launched"
fi
