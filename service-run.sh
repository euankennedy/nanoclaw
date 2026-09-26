#!/usr/bin/env bash
# Launchd/service entry point for the nanoclaw host.
#
# The launchd plist runs THIS script instead of `node dist/index.js` directly,
# so the startup preflight (Docker + OneCLI readiness) runs on every start path
# — boot/login, the menu-bar widget (load/kickstart), and `start.sh` (which
# ends by kickstarting the same plist). Without this, only a manual `./start.sh`
# got the preflight; boot and the widget went straight to node with no guard.
#
# It `exec`s node as the final step so launchd tracks the node PID directly and
# SIGTERM forwards cleanly for graceful shutdown (no bash in the middle).
#
# NOTE: pointing the plist here is a local plist edit (see docs/CUSTOMISATIONS).
# Re-running `/setup` regenerates the plist targeting node directly and must be
# re-pointed at this script afterwards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=preflight.sh
source "$SCRIPT_DIR/preflight.sh"

ensure_docker
ensure_onecli

# Resolve node. The launchd plist's PATH does not include nvm's bin dir, so
# `node` is not on PATH here — source nvm to pick up the default version, and
# fall back to the absolute path the plist historically used.
if ! command -v node >/dev/null 2>&1; then
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
fi
NODE_BIN="$(command -v node || echo "$HOME/.nvm/versions/node/v23.11.0/bin/node")"

exec "$NODE_BIN" "$SCRIPT_DIR/dist/index.js"
