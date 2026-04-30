# NanoClaw Customisations

Personal customisations layered on top of [qwibitai/nanoclaw](https://github.com/qwibitai/nanoclaw).

## Git setup

Two remotes:
- `origin` — personal fork: https://github.com/euankennedy/nanoclaw.git (push customisations here)
- `upstream` — original repo: https://github.com/qwibitai/nanoclaw.git (pull updates from here)

To pull upstream updates: run `/update-nanoclaw`, or manually:
```bash
git fetch upstream
git rebase upstream/main
git push origin main
```

## Authentication

Uses an **Anthropic API key** (not OAuth) stored in OneCLI's vault. OAuth was the original setup method but violates Anthropic's T&Cs for agent harnesses.

To rotate the key:
```bash
onecli secrets list                          # find the current secret id
onecli secrets delete --id <id>
onecli secrets create --name "Anthropic" --type anthropic \
  --value "sk-ant-api03-..." \
  --host-pattern "api.anthropic.com"
```
No service restart needed — OneCLI injects credentials per-request.

## Headroom context compression

[Headroom](https://github.com/chopratejas/headroom) runs as a sidecar inside every agent container, compressing LLM context before it reaches the Anthropic API.

**Modified files:**
- `container/Dockerfile` — adds Python venv, installs `headroom-ai` and dependencies
- `container/headroom-start.sh` — new startup script: launches headroom, waits for health, sets `ANTHROPIC_BASE_URL=http://localhost:8787`, then execs the agent runner
- `src/container-runner.ts` — one-line change: calls `headroom-start.sh` instead of launching bun directly

**Key lesson:** Do NOT set `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY` in `headroom-start.sh`. The claude-code binary reads its credentials from `/home/node/.claude` (mounted from `data/v2-sessions/<group>/.claude-shared`). Overriding with a placeholder breaks auth.

**Request chain:** `claude-code SDK → headroom (localhost:8787) → HTTPS_PROXY (OneCLI) → api.anthropic.com`

To verify headroom is receiving traffic:
```bash
docker exec $(docker ps --format '{{.Names}}' | grep '^nanoclaw-' | head -1) \
  curl -s --noproxy localhost http://localhost:8787/stats | python3 -m json.tool
```

## Service management scripts

Two scripts at the project root:

- `./start.sh` — starts the launchd service (or restarts if already running)
- `./stop.sh` — stops all running agent containers, then unloads the service

These auto-detect the install-slug-versioned plist name (`com.nanoclaw-v2-<slug>.plist`).

Manual restart shortcut:
```bash
launchctl kickstart -k gui/$(id -u)/com.nanoclaw-v2-f4f2273a
```

## macOS menu bar status indicator

A native Swift app (`dist/statusbar`) shows a bolt icon in the menu bar with a green/red dot for NanoClaw's running state. Supports Start, Stop, Restart, and View Logs from the menu.

**Source:** `.claude/skills/add-macos-statusbar/add/src/statusbar.swift` (modified from the skill default to dynamically detect the slug-versioned plist name)

**Installed as:** `~/Library/LaunchAgents/com.nanoclaw.statusbar.plist`

To rebuild after source changes:
```bash
swiftc -O -o dist/statusbar .claude/skills/add-macos-statusbar/add/src/statusbar.swift
xattr -cr dist/statusbar
launchctl unload ~/Library/LaunchAgents/com.nanoclaw.statusbar.plist
launchctl load ~/Library/LaunchAgents/com.nanoclaw.statusbar.plist
```

## Channels

Telegram is set up (adapter files in `src/channels/`).