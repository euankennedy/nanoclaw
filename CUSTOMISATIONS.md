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
- `container/Dockerfile` — adds Python venv, installs `headroom-ai[proxy]` (`HEADROOM_VERSION` ARG, 0.40.0 as of 2026-10-08; the `[proxy]` extra resolves its own deps — don't go back to `--no-deps` + hand-pinned lists)
- `container/headroom-start.sh` — new startup script: launches headroom with `--disable-kompress` (see below), waits for health (up to 30s; 0.40.0 is healthy in ~2s), sets `ANTHROPIC_BASE_URL=http://localhost:8787`, then execs the agent runner
- `src/container-runner.ts` — one-line change in the agent `ContainerSpec` (search for `headroom-start.sh`, ~line 1300 in the spec-composition function): `args: ['exec bash /app/headroom-start.sh']` instead of `exec bun run /app/src/index.ts`. Since the 2.3.0 driver seam this lives in the spec, not in the old `buildContainerArgs`.
- `src/container-runner.test.ts` — the "splits PID 1" assertion expects the headroom entrypoint (fork-local).

**Key lesson:** Do NOT set `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY` in `headroom-start.sh`. The claude-code binary reads its credentials from `/home/node/.claude` (mounted from `data/v2-sessions/<group>/.claude-shared`). Overriding with a placeholder breaks auth.

**Key lesson 2 (2.4.0 update):** a host shell with `ANTHROPIC_BASE_URL` exported (e.g. from a profile that sets it for headroom testing) breaks the upstream OneCLI gateway tests — run `pnpm test` with `ANTHROPIC_BASE_URL=""` if it's set in your shell.

**Kompress disabled (2026-10-08):** on 0.39.0 the Kompress ML compressor
pulled its HF model (`chopratejas/kompress-v2-base` + ModernBERT) on every
container boot — ~50 requests to `us.aws.cdn.hf.co` / `huggingface.co` /
`cas-server.xethub.hf.co` per spawn, uncached because containers are `--rm`.
With hourly task wakes that was constant background traffic, and it peaked
alongside a stalled mail-check token request on 8 Oct. 0.40.0's `[proxy]` extra
no longer installs Kompress at all (`[ml]` does); the flag guards against it
returning. To bring ML compression back properly: install `[ml]`, bake the
model into the image at build time, and set `HF_HUB_OFFLINE=1`.

**Request chain:** `claude-code SDK → headroom (localhost:8787) → HTTPS_PROXY (OneCLI) → api.anthropic.com`

**Expected log noise (0.39+):** headroom's `/health` and `/readyz` endpoints run
an upstream reachability check — a `HEAD https://api.anthropic.com/` with a 30s
result cache. The API root has no route, so the probe logs as a **404 in the
OneCLI request log — that 404 IS the success signal** ("any HTTP response means
TLS+TCP worked" per headroom source). One shows up at every container boot
(headroom-start.sh polls `/health`), so hourly task spawns → hourly HEAD 404s.
Harmless; silence with `HEADROOM_SKIP_UPSTREAM_CHECK=1` in headroom-start.sh if
ever unwanted.

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

## macOS menu bar status indicator — REMOVED

Was a native Swift app (`dist/statusbar`, `com.nanoclaw.statusbar.plist`)
showing NanoClaw's running state in the menu bar. Removed 2026-09-27 per
`.claude/skills/add-macos-statusbar/REMOVE.md`. The install skill remains in
`.claude/skills/add-macos-statusbar/` if it's ever wanted again (its custom
slug-detection tweak is in the skill's `add/src/statusbar.swift`).

## Channels

Telegram is set up (adapter files in `src/channels/`).

## LM Studio server LaunchAgent (2026-10-01)

`~/Library/LaunchAgents/com.euankennedy.lms-server.plist` runs
`~/.lmstudio/bin/lms server start` at login (RunAtLoad, logs to
`/tmp/lms-server-start.log`). Added after an overnight reboot left the LM
Studio headless server down and the local-LLM email/URL lanes silently closed
(everything escalated to Claude for a morning). The macOS "background items"
alert attributes this agent to **Element Labs Inc.** — that's the code
signature on the `lms` binary, i.e. LM Studio's developer; it IS this agent.

Pause/resume: System Settings → Login Items & Extensions → "Allow in the
Background" (Element Labs Inc. item), or
`launchctl disable|enable gui/$UID/com.euankennedy.lms-server`. The agent only
starts the server at login; a running server is stopped with `lms server stop`.
If paused, the lanes degrade gracefully — health check fails and all work
routes to Claude.

## Sleep-prevention LaunchAgent — 06:00-18:00 work window (2026-10-05)

`~/Library/LaunchAgents/com.euankennedy.nanoclaw-awake.plist` holds a
`caffeinate -s` assertion (prevent system sleep, **AC only**) during the
06:00-18:00 window so macOS 27 maintenance sleep doesn't freeze the host
process + task containers mid-run.

**Why:** diagnosed 5 Oct — on macOS 27.0.1 (Golden Gate, build 26A434) the
`node` host is suspended for the entire duration of each "Maintenance Sleep"
window (proven: multi-hour gaps in the 1s delivery-poll log, resume timestamps
matching `pmset` DarkWake events to the second). Hourly runs then only execute
in brief wake windows; long local-lane inference (40-100s) overruns them and
the container is ceiling-killed mid-script. Not a bug — standard macOS sleep;
our own move to hourly + weekend + heavier local lanes made it visible. The
`dasd` Golden Gate leak was checked and ruled out on this machine.

**Mechanism:** fires at 06:00 (`StartCalendarInterval`; launchd runs it on the
next wake if asleep at 06:00) and at load (`RunAtLoad`). Computes seconds until
18:00 and `exec caffeinate -s -t <that>`, so the assertion auto-drops at 18:00.
Off AC it is a harmless no-op; outside the window it exits immediately. Verify:
`pmset -g assertions | grep PreventSystemSleep` (1 = held), log `/tmp/nanoclaw-awake.log`.

**Scope + residual gap:** covers the cases that matter (plugged in, lid open —
desk at work/home). Does NOT cover lid-closed-in-bag-on-battery (clamshell
forces sleep; `-s` is void off AC) — those runs freeze until the next
wake/plug-in, where the mail-check **orphan guard** (`mail-pending.json`)
replays them. Independent of the nanoclaw service (doesn't wrap
`service-run.sh`), so no SIGTERM-forwarding concern.

**Pause/remove:** `launchctl bootout gui/$UID ~/Library/LaunchAgents/com.euankennedy.nanoclaw-awake.plist`.
Deferred alternative for a hard 06:00 guarantee from deep sleep: add a
`sudo pmset repeat wakeorpoweron ... 05:58:00` scheduled wake (needs sudo).

## Apple FM `fm serve` LaunchAgent (2026-10-03)

`~/Library/LaunchAgents/com.euankennedy.fm-serve.plist` runs
`/usr/bin/fm serve --port 11435` (macOS 27 Apple Foundation Models,
on-device) at login with KeepAlive (logs to `/tmp/fm-serve.log`). Second
tier for the mail-check URL lane: `summariseUrl` in
`groups/dm-with-euan/lib/local-llm.mjs` tries LM Studio first, falls back
to Apple FM via this endpoint, and Claude remains the final fallback via
the normal escalation path. `summariseAttachment` gets the same fm rescue
mid-lane (gpt-oss primary; A/B in `NANOCLAW_FM_ATTACHMENT_REPLAY.md`).
Containers reach it at
`host.docker.internal:11435` (verified from the agent image). The lane
gate in `mail-check.mjs` stays open if either engine is healthy; the
email extract/draft lane remains LM-Studio-only (Apple FM failed the
extraction fixtures — 4/6 best vs gpt-oss-20b's 6/6, 3 Oct).

Gotchas: `fm serve` defaults to SSE streaming (`stream:false` is
load-bearing in `fmComplete`); no guardrails flag on serve (CLI-only),
and default guardrails can false-positive refuse — rate watchable via
`model:"apple-fm-system"` entries in `local-llm-log.jsonl`. ~8k-token
context ceiling, no cold load. Pause/resume:
`launchctl unload|load ~/Library/LaunchAgents/com.euankennedy.fm-serve.plist`.

Related (outside this repo): `~/Automation/screenshot-namer/` switched to
Apple FM via `LOCAL_MODEL_STRATEGY = "fm"` in `screenshot-namer.py`
(`"lms"` switches back to the intact LM Studio path; A/B page at
`~/Automation/screenshot-namer/fm-comparison.html`, Euan scored fm 9 /
qwen 7 / tie 4 on 3 Oct).

## Task-session idle ceiling (fork delta, 2026-09-30)

`src/reconcile-session.ts`: task-thread sessions use
`TASK_ABSOLUTE_CEILING_MS` (5 min) instead of the stock 30-min
`ABSOLUTE_CEILING_MS`; chat sessions are unchanged. Rationale: the scheduled
gates (mail-check, fireflies) run hourly, so their containers never survive to
the next fire anyway — the 30-min idle tail was pure dead time. Declared Bash
timeouts still stretch the ceiling; idle age counts from the last SDK event, so
long active wakes are unaffected. `decideStuckAction` gained an optional
`baseCeilingMs` arg (re-exported via `host-sweep.ts`); tests in
`src/host-sweep.test.ts` ("task ceiling" cases). Carry this delta through
future `/update-nanoclaw` merges alongside the `--script-timeout-ms` one.

## Persistent task-script log (fork delta, 2026-10-08)

`container/agent-runner/src/scheduling/task-script.ts`: every `[task-script]`
line (run, skip, error, timeout) plus the **tail** (last 4000 chars) of each
pre-task script's stderr is appended to `/workspace/agent/logs/task-scripts.log`
→ on the host at `groups/<folder>/logs/task-scripts.log` (rotates to `.1` at
1 MB). Why: containers are `--rm` and session-mode exits don't surface a
stderr tail, so on 8 Oct a mail-check run that died on a stalled Graph token
request left no trace — it had to be reconstructed from OneCLI's gateway log.
The console copy still goes to stderr (first 500 chars, as upstream). Loaded
from the mounted source, so no image rebuild is needed for changes here.

## Pomni's Telegram topics (2026-10-31, Still QL.2)

Pomni's scheduled reports post to topics in a "Pomni" Telegram supergroup
(`telegram:-1004369284676`, Topics on) instead of Euan's DM. No core change:
`src/delivery.ts` passes `thread_id` to the adapter as-is, and
`@chat-adapter/telegram` turns `telegram:<chat>:<topicId>` into
`message_thread_id` for text and documents.

**Operator setup (central DB, lost on a fresh install):**
- Messaging group `mg-1793436816845-piptqx`, registered by posting
  `/start@nanoclaw_euan_bot connect` in the group and **rejecting** the approval
  card. `denied_at` is set on purpose: @mentions there are dropped, and Pomni has
  no wiring to it. Delivery checks only `detached_at` and the destination row.
- Destination `pomni-topics` (Pomni → that group):
  `ncl destinations add --agent-group-id ag-1777515526404-pd3bg6 --local-name pomni-topics --target-type channel --target-id mg-1793436816845-piptqx`.
- The bot is a group admin with only "Manage topics". Topics were created with the raw
  Bot API `createForumTopic` (the adapter has no call for it); ids in
  `groups/dm-with-euan/telegram-topics.json`.

**Group folder (untracked):** `lib/telegram.mjs` is the one send path. Every
script uses it, it falls back to the DM when a stream has no topic, and it has a CLI
for the agent, because `send_message` can't target a topic: it would land in
General, since Telegram's inbound threads are nulled. Tests:
`tests/telegram.test.mjs`. Backup before the change:
`OneDrive-MojoSoup/nanoclaw-backups/2026-10-31-still-ql2/`, which also holds the
mail-check and fireflies task prompts as they were. To roll back, delete
`telegram-topics.json`: every stream then goes to the DM.

## Toolchain: pnpm 12, Node 24, test temp dirs (2026-11-04, from Still)

- **pnpm 12.17.0** via corepack (`packageManager`). pnpm 11 removed
  `onlyBuiltDependencies`, and pnpm 12 errors on it, so `pnpm-workspace.yaml` has an
  `allowBuilds` map: esbuild, protobufjs, sharp allowed as before, and
  `better-sqlite3: false`, which pnpm 10 skipped silently. Its prebuilt binary is
  used; without the entry `strictDepBuilds` fails the install. pnpm 11+ reads `.npmrc`
  for auth and registry only.
- **`.nvmrc` 24** (upstream: 22). `service-run.sh` runs nvm's default node, which is 24
  on this Mac since 4 Nov; the file now says so. `engines` still `>=22`.
- **`scripts/vitest-tmpdir.ts`** (globalSetup in `vitest.config.ts`): each test run
  gets `/tmp/nc-run-XXXXXX` as TMPDIR and removes it afterwards. A full run used to
  leave ~750 dirs in the macOS `$TMPDIR`. `/tmp`, not `$TMPDIR`: one more level under
  `/var/folders/...` pushes test sockets past the 104-byte Unix socket limit.
- Each local commit trips the upgrade tripwire on the next start: validate, then
  `pnpm exec tsx scripts/upgrade-state.ts set`, then restart (`docs/upgrade-recovery.md`).

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
- **OneCLI gateway upgraded 1.36.0 → 1.41.0** (2026-09-26) by editing the
  image tag in `~/.onecli/docker-compose.yml` and `docker compose pull && up
  -d`. Vault data lives in named volumes and survives. ⚠️ Do NOT upgrade past
  1.41.x — OneCLI 1.43+ removes the agent-grant API this NanoClaw version
  uses (see `.claude/skills/add-opencode/ONECLI-LEGACY.md`). Rollback:
  `ONECLI_VERSION`-style edit back to the old tag + `docker compose up -d`.
- **⚠️ Upgrade tripwire re-stamp:** the 2.4.0 boot tripwire records the exact
  git commit at update-finish time. Any local commit after that makes the next
  service start crash-loop with "install not on the sanctioned path". After
  committing local work, re-stamp before restarting:
  `pnpm exec tsx scripts/upgrade-state.ts set "" update-nanoclaw`
