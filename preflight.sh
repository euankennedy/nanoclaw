#!/usr/bin/env bash
# Shared startup preflight for the nanoclaw host service.
#
# This file is SOURCED, not executed — it only defines functions. Both entry
# points source it so they run the identical checks:
#   - start.sh       — manual start/restart from a terminal (visible output)
#   - service-run.sh — what the launchd plist runs (boot/login + the widget)
#
# Keeping the checks here is the single source of truth: every way of starting
# nanoclaw goes through the same preflight, no matter who triggers it.

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

# ─── OneCLI gateway readiness check ─────────────────────────────────────────
# Nanoclaw fetches each agent's secrets from the OneCLI gateway *before* it can
# spawn an agent container. If the gateway is down, every spawn fails at
# ensureAgent with "OneCLIError: fetch failed" and messages queue forever with
# no visible Docker activity. A Docker Desktop update can leave these containers
# stopped even though the daemon came back, so bring them up here.
#
# Best-effort: installs using the native credential proxy have no compose file,
# so a missing file is a silent skip, not an error. Never exits non-zero — if
# the gateway can't be started, the host still comes up and its sweep retries
# once the gateway is back.
ensure_onecli() {
  local compose_file="${ONECLI_COMPOSE_FILE:-$HOME/.onecli/docker-compose.yml}"
  local gateway_ctr="onecli"

  if [ ! -f "$compose_file" ]; then
    return 0  # No OneCLI gateway on this install (e.g. native credential proxy).
  fi

  # Reports "healthy" / "starting" / "unhealthy" / "running" (no healthcheck) /
  # "stopped" / "missing" (container doesn't exist yet).
  onecli_health() {
    docker inspect --format \
      '{{if .State.Health}}{{.State.Health.Status}}{{else if .State.Running}}running{{else}}stopped{{end}}' \
      "$gateway_ctr" 2>/dev/null || echo missing
  }

  local status
  status=$(onecli_health)
  if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
    return 0
  fi

  echo "OneCLI gateway is not up (status: $status) — starting it…"
  if ! docker compose -f "$compose_file" up -d 2>&1; then
    echo "Warning: could not start OneCLI gateway. Agents will not spawn until it's up." >&2
    echo "  Try manually: docker compose -f \"$compose_file\" up -d" >&2
    return 0  # Don't block the host from starting; the sweep retries once it's up.
  fi

  local i
  for i in $(seq 1 30); do
    status=$(onecli_health)
    if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
      echo "OneCLI gateway is ready."
      return 0
    fi
    sleep 2
    printf '\rWaiting for OneCLI gateway… (%ds)' "$((i * 2))"
  done
  printf '\n'
  echo "Warning: OneCLI gateway did not become ready within 60s (status: $status)." >&2
  echo "  The host will start anyway; the sweep will retry once the gateway is up." >&2
}
