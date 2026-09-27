#!/usr/bin/env bash
# Stop nanoclaw: halt the host service first, then any running agent containers.
#
# Order matters: with the host still up, its sweep can respawn a container in
# the gap after we stop it (2.3.0+ hosts also adopt running sessions). Stop the
# service first so nothing respawns, then drain containers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Derive the per-install service name the same way upstream tooling does.
# shellcheck source=setup/lib/install-slug.sh
source "$SCRIPT_DIR/setup/lib/install-slug.sh"

# Stop the host service
if [ "$(uname -s)" = "Darwin" ]; then
  LABEL="$(launchd_label)"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  if [ ! -f "$PLIST" ]; then
    echo "No nanoclaw launchd service found ($PLIST)."
  elif launchctl list "$LABEL" >/dev/null 2>&1; then
    launchctl unload "$PLIST"
    echo "Service stopped."
  else
    echo "Service not running."
  fi
else
  UNIT="$(systemd_unit)"
  if systemctl --user is-active "$UNIT" >/dev/null 2>&1; then
    systemctl --user stop "$UNIT"
    echo "Service stopped."
  else
    echo "Service not running."
  fi
fi

# Stop agent containers. Since 2.3.0's driver seam, containers are named
# ncl-… and carry the nanoclaw-session label — filter by label, not name.
CONTAINERS=$(docker ps --filter label=nanoclaw-session --format '{{.Names}}' 2>/dev/null || true)
if [ -n "$CONTAINERS" ]; then
  echo "Stopping containers..."
  echo "$CONTAINERS" | xargs docker stop
  echo "Containers stopped."
else
  echo "No running containers."
fi
