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
- `container/Dockerfile` — adds Python venv, installs `headroom-ai` and dependencies (`HEADROOM_VERSION` ARG)
- `container/headroom-start.sh` — new startup script: launches headroom, waits for health, sets `ANTHROPIC_BASE_URL=http://localhost:8787`, then execs the agent runner
- `src/container-runner.ts` — one-line change in the agent `ContainerSpec` (search for `headroom-start.sh`, ~line 1300 in the spec-composition function): `args: ['exec bash /app/headroom-start.sh']` instead of `exec bun run /app/src/index.ts`. Since the 2.3.0 driver seam this lives in the spec, not in the old `buildContainerArgs`.
- `src/container-runner.test.ts` — the "splits PID 1" assertion expects the headroom entrypoint (fork-local).

**Key lesson:** Do NOT set `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY` in `headroom-start.sh`. The claude-code binary reads its credentials from `/home/node/.claude` (mounted from `data/v2-sessions/<group>/.claude-shared`). Overriding with a placeholder breaks auth.

**Key lesson 2 (2.4.0 update):** a host shell with `ANTHROPIC_BASE_URL` exported (e.g. from a profile that sets it for headroom testing) breaks the upstream OneCLI gateway tests — run `pnpm test` with `ANTHROPIC_BASE_URL=""` if it's set in your shell.

**Request chain:** `claude-code SDK → headroom (localhost:8787) → HTTPS_PROXY (OneCLI) → api.anthropic.com`

To verify headroom is receiving traffic (since 2.3.0 containers are named `ncl-…`; filter by label):
```bash
docker exec $(docker ps --filter label=nanoclaw-session --format '{{.Names}}' | head -1) \
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

## Startup preflight (Docker + OneCLI readiness)

Before the host starts, a shared preflight ensures **both Docker and the OneCLI
gateway** are up. Motivation: nanoclaw fetches each agent's secrets from the
OneCLI gateway *before* it can spawn an agent container. If the gateway is down
(e.g. a Docker Desktop update leaves its containers stopped), every spawn fails
with `OneCLIError: fetch failed` and messages queue silently with no Docker
activity — exactly the symptom that looks like "nanoclaw is broken."

**Files (all ours, not upstream):**
- `preflight.sh` — single source of truth: `ensure_docker` + `ensure_onecli`
  (sourced, not executed). `ensure_onecli` brings up
  `~/.onecli/docker-compose.yml` if the `onecli` container isn't healthy;
  best-effort (silent skip if no compose file, never blocks host startup).
- `service-run.sh` — what the launchd plist runs: sources the preflight, runs
  both checks, then `exec node dist/index.js` (exec so SIGTERM forwards cleanly).
- `start.sh` — sources the same preflight for visible terminal output, then
  kickstarts the service.

**Unified pathway:** the plist `ProgramArguments` points at
`/bin/bash <root>/service-run.sh` instead of `node dist/index.js` directly, so
the preflight runs on **every** start path — boot/login (`RunAtLoad`), the
menu-bar widget (`launchctl load`/`kickstart`), and `./start.sh`.

**⚠️ Setup-clobber caveat:** `setup/service.ts` (upstream) unconditionally
rewrites the plist `ProgramArguments` back to `node dist/index.js` on every
`/setup` run. After ever re-running setup, re-point the plist:
```bash
PLIST=$(ls ~/Library/LaunchAgents/com.nanoclaw-v2*.plist | head -1)
/usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /bin/bash" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $(pwd)/service-run.sh" "$PLIST"
launchctl unload "$PLIST" && launchctl load "$PLIST"   # unload+load; kickstart won't re-read ProgramArguments
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
## 2.4.0 update notes (2026-09-26)

Updated from 2.1.19 → 2.4.0 via the upstream transactional `/update-nanoclaw`
controller (transaction `20260926085944-feac8808-7e019754`; snapshot retained
under `~/DevProjects/.nanoclaw-updates/f4f2273a/` — keep until the next update).

Fork-local deltas that had to move during the merge:

- **maxTurns migration renumbered** `019` → `026-container-config-max-turns.ts`
  (upstream took 019–025). The DB identity is the migration *name*, which is
  unchanged — never rename it.
- **Model pinned**: `NANOCLAW_DEFAULT_MODEL=claude-opus-4-8` in `.env` so the
  2.4.0 default-model move to Opus 5.5 doesn't change costs. Upgrade per group
  via `ncl groups config update --id <group> --model ...` when desired.
- **dashboard-pusher.ts** ported to the async central-DB `DbDriver` API.
  Session-DB reads still use better-sqlite3 directly (read-only telemetry).
- **Memory migrated** (all 4 groups) from `CLAUDE.local.md` + Claude
  auto-memory into the shared OKF `groups/<folder>/memory/` tree +
  `instructions.prepend.md`. Staged originals kept in
  `groups/<folder>/.memory-migration-staging/` as backup.
- **Scheduled tasks**: Pomni's pre-2.4.0 recurring series (fireflies check,
  feedly briefing) still live in her *chat* session's `messages_in` and keep
  firing, but `ncl tasks list` only sees tasks in the group *system session*.
  To manage them via `ncl tasks`, recreate them with `ncl tasks create` and
  cancel the old rows.
- **stop.sh** filters containers by `label=nanoclaw-session` (names are now
  `ncl-…`).
