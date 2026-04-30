#!/usr/bin/env bash
# Stop nanoclaw: halt the host service and any running agent containers.
set -euo pipefail

# Stop agent containers (--rm means Docker removes them automatically on stop)
CONTAINERS=$(docker ps --format '{{.Names}}' | grep '^nanoclaw-' 2>/dev/null || true)
if [ -n "$CONTAINERS" ]; then
  echo "Stopping containers..."
  echo "$CONTAINERS" | xargs docker stop
  echo "Containers stopped."
else
  echo "No running containers."
fi

# Stop the host service
if [ "$(uname -s)" = "Darwin" ]; then
  PLIST=$(ls ~/Library/LaunchAgents/com.nanoclaw*.plist 2>/dev/null | head -1 || true)
  if [ -z "$PLIST" ]; then
    echo "No nanoclaw launchd service found."
    exit 0
  fi
  LABEL=$(basename "$PLIST" .plist)
  if launchctl list "$LABEL" >/dev/null 2>&1; then
    launchctl unload "$PLIST"
    echo "Service stopped."
  else
    echo "Service not running."
  fi
else
  if systemctl --user is-active nanoclaw >/dev/null 2>&1; then
    systemctl --user stop nanoclaw
    echo "Service stopped."
  else
    echo "Service not running."
  fi
fi