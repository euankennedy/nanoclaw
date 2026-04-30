#!/bin/bash
# Start headroom proxy, wait for it to be healthy, then exec the agent runner.
# headroom's outbound calls inherit HTTPS_PROXY (set by OneCLI), so credential
# injection still flows: SDK → headroom → OneCLI → api.anthropic.com.
set -e

headroom proxy --host 127.0.0.1 --port 8787 &

for i in $(seq 1 20); do
  sleep 0.5
  curl -sf --noproxy localhost http://localhost:8787/health >/dev/null 2>&1 && break
  if [ "$i" -eq 20 ]; then
    echo "[headroom-start] headroom failed to become healthy after 10s" >&2
    exit 1
  fi
done

export ANTHROPIC_BASE_URL=http://localhost:8787
# Do NOT set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN — claude-code reads
# its real OAuth credentials from /home/node/.claude (mounted by container-runner).
# Overriding with a placeholder breaks auth.

# Prevent NODE_USE_ENV_PROXY (set by OneCLI) from routing localhost traffic
# through the host-side OneCLI gateway, which can't reach the container's localhost.
export NO_PROXY=localhost,127.0.0.1
export no_proxy=localhost,127.0.0.1

exec bun run /app/src/index.ts