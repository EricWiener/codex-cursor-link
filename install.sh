#!/bin/zsh
# Builds Codex Cursor Link into ~/Applications and starts it at login.
set -euo pipefail

SRC="${0:A:h}"
APP="$HOME/Applications/Codex Cursor Link.app"
LABEL="local.codex-cursor-link"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if ! command -v swiftc >/dev/null; then
  echo "swiftc not found. Install the Xcode command line tools: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$APP/Contents/MacOS"
swiftc -O "$SRC/main.swift" -o "$APP/Contents/MacOS/CodexCursorLink"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Codex Cursor Link</string>
  <key>CFBundleExecutable</key><string>CodexCursorLink</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/CodexCursorLink</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for i in {1..10}; do
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break
  sleep 0.5
done
launchctl print "gui/$(id -u)/$LABEL" >/dev/null
echo "Installed $APP and started it. It will also start at login."
