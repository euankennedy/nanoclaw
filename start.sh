#!/usr/bin/env bash
# Start nanoclaw host service (or restart it if already running).
set -euo pipefail

# ─── Docker readiness check ─────────────────────────────────────────────────
# Nanoclaw spawns agent containers, so Docker must be running before the host
# service starts. If Docker isn't up, launch it and wait (up to 60s).

ensure_docker() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  if [ "$(uname -s)" = "Darwin" ]; then
    echo "Docker is not running — launching Docker Desktop…"
    open -a Docker 2>/dev/null || {
      echo "Error: could not launch Docker Desktop. Start it manually and retry." >&2
      exit 1
    }
  elif [ "$(uname -s)" = "Linux" ]; then
    echo "Docker is not running — starting Docker daemon…"
    sudo systemctl start docker 2>/dev/null || {
      echo "Error: could not start Docker. Run: sudo systemctl start docker" >&2
      exit 1
    }
  else
    echo "Error: Docker is not running. Please start it and retry." >&2
    exit 1
  fi

  local i
  for i in $(seq 1 30); do
    sleep 2
    if docker info >/dev/null 2>&1; then
      echo "Docker is ready."
      return 0
    fi
    printf '\rWaiting for Docker… (%ds)' "$((i * 2))"
  done
  printf '\n'
  echo "Error: Docker did not become ready within 60s. Check Docker Desktop and retry." >&2
  exit 1
}

ensure_docker

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