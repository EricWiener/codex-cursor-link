#!/bin/zsh
# Stops Codex Cursor Link and removes the app and its login item.
set -euo pipefail

LABEL="local.codex-cursor-link"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Codex Cursor Link.app"
echo "Codex Cursor Link removed."
