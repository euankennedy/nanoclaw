#!/usr/bin/env bash
# Start nanoclaw host service (or restart it if already running).
#
# This runs the shared preflight (Docker + OneCLI readiness) with visible
# terminal output, then (re)starts the launchd/systemd service. The service
# itself runs the SAME preflight via service-run.sh, so the checks here are
# for immediate feedback — under launchd they short-circuit once already up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=preflight.sh
source "$SCRIPT_DIR/preflight.sh"

ensure_docker
ensure_onecli

# Derive the per-install service name the same way upstream tooling does
# (the old com.nanoclaw*.plist glob could also match the statusbar plist).
# shellcheck source=setup/lib/install-slug.sh
source "$SCRIPT_DIR/setup/lib/install-slug.sh"

if [ "$(uname -s)" = "Darwin" ]; then
  LABEL="$(launchd_label)"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  if [ ! -f "$PLIST" ]; then
    echo "No nanoclaw launchd service found ($PLIST). Run the setup first." >&2
    exit 1
  fi
  if launchctl list "$LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
    echo "Service restarted."
  else
    launchctl load "$PLIST"
    echo "Service started."
  fi
else
  systemctl --user start "$(systemd_unit)"
  echo "Service started."
fi