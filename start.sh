#!/usr/bin/env bash
# Start nanoclaw host service (or restart it if already running).
set -euo pipefail

if [ "$(uname -s)" = "Darwin" ]; then
  PLIST=$(ls ~/Library/LaunchAgents/com.nanoclaw*.plist 2>/dev/null | head -1 || true)
  if [ -z "$PLIST" ]; then
    echo "No nanoclaw launchd service found. Run the setup first." >&2
    exit 1
  fi
  LABEL=$(basename "$PLIST" .plist)
  if launchctl list "$LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
    echo "Service restarted."
  else
    launchctl load "$PLIST"
    echo "Service started."
  fi
else
  systemctl --user start nanoclaw
  echo "Service started."
fi