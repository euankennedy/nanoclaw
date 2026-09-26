---
name: process-meeting
description: "Fetch one Fireflies meeting transcript and write its decisions, actions and key updates into a specific Obsidian vault note, via the Obsidian MCP only. Used by the scheduled meetings-to-vault task and on demand. Inputs: a Fireflies transcript id and a destination note path."
---

# Process Meeting to Vault

Take one Fireflies meeting and file its outcomes into a nominated vault note. The
meetings-to-vault scheduled task calls this once per meeting after routing has chosen the
destination. It can also be run on demand.

## Hard rules

- **Vault access is ONLY via the Obsidian MCP tools (`mcp__obsidian__*`).** Never read or write
  the vault through the filesystem, even though the folder is mounted.
- **Never overwrite `_active-context.md`, `_inbox.md`, or `_memory.md` wholesale.** Use
  `patch_note` (append) only.
- **Creating a new note is only allowed when the caller has explicitly confirmed a new
  destination.** When filing to an existing note, do not invent new structure.
- Australian English. No em dashes (use commas, colons, full stops).

## Inputs

- `transcriptId` — the Fireflies id (from the scheduled task's `scriptOutput`, or given directly).
- `dest` — vault-relative note path, e.g. `projects/tmr/01246/index` or
  `areas/mojo-soup/iso27001/index`. Normalise: if it has no `.md`, append `.md`.
- `label` (optional) — a human label for confirmations, e.g. "TMR 01246".
- `createIfMissing` (optional, default false) — set true only when the caller confirmed a new note.

## Workflow

### 1. Fetch the transcript
Run the helper (auth is injected by OneCLI):
```
node /workspace/agent/fetch-transcript.mjs <transcriptId>
```
- Exit code 2 means the transcript is not ready yet. Stop and report "not ready" so the caller
  leaves it unprocessed for the next poll. Do not write anything.
- Otherwise parse the JSON: `{ title, date, attendees, summary, actionItems, keywords, transcript }`.

### 2. Extract
From the summary and transcript, pull:
- **Key updates:** status changes, progress, issues, escalations (concise bullets).
- **Decisions:** what was agreed.
- **Actions:** who does what by when. Use the helper's `actionItems` as the starting point and
  refine against the transcript.
Keep it tight. This is a working record, not a transcript dump.

### 3. Resolve the destination note

**If `dest` is under a project (`projects/<client>/<code>/...`):** meeting notes ALWAYS go in that
project's `comms-log.md`, never in `index.md`. See `projects/README.md` for the full convention
(`index.md` = stable overview; `comms-log.md` = running meeting log). Set the write target to
`projects/<client>/<code>/comms-log.md` regardless of what `dest` names.
- If the project is **new** (no `index.md`), scaffold it per `projects/README.md`:
  - `write_note` `index.md` — a short overview stub: frontmatter (`title`, `tags: [project, <client>]`,
    `client`, `project_number`, `status`, `last_updated`), a one-line description, and a
    `## Related Notes` link to `[[projects/<client>/<code>/comms-log]]`. Fill only what the meeting
    makes clear; do not invent commercials or dates.
  - `write_note` `comms-log.md` — frontmatter + heading, ready for the dated section.
- If the project exists but `comms-log.md` is missing, create it (frontmatter + heading).

**Otherwise (`areas/…`, a thread, or `_inbox`):** the write target is `dest` itself (append `.md`).
- If it is missing and `createIfMissing` is true → `write_note` with frontmatter per the area format
  (`title`, `tags`, `last_updated`) then a one-line purpose. For a running-log BAU thread that purpose
  line is enough; the dated section becomes the first entry.
- If it is missing and `createIfMissing` is false → stop and report that the note does not exist
  (the caller must confirm a new note first).

### 4. Write the dated section
`patch_note` on the **write target** from step 3 to append (do not replace existing content):
```markdown

---

## <Meeting Title> — <DD Mon YYYY>

**Attendees:** <names>

**Key updates:**
- <bullet>

**Decisions:**
- <bullet>

**Actions:**
- [ ] <Person> — <task> — due <date if mentioned>
```
Cross-link with `[[wikilinks]]` to related project/client/people notes where the names are clear.

### 5. Update `_active-context.md` if the meeting shifts Euan's live state
`_active-context.md` (vault root) is Euan's single source of truth: sections **Working On**,
**Current Priority**, **Open Blockers**, **Recent Decisions**, **Open Actions**. Update it ONLY when
the meeting genuinely moves one of these, and only for things involving **Euan or a Mojo Soup
commitment** (not every attendee's action). Be conservative — most meetings need no change here.

Add via `patch_note` (surgical append under the right heading, NEVER overwrite the file):
- A new or changed **blocker** for Euan / a client → one bullet under **Open Blockers**.
- A **decision** that changes direction → one dated bullet under **Recent Decisions**.
- A **new action owned by Euan** → one bullet under **Open Actions**.
- A real shift in focus → a line under **Working On** / **Current Priority**.

Mark each added line so Euan can spot and curate automated entries, e.g. end with
`— via [[projects/<client>/<code>/comms-log]] (auto)`. When in doubt, leave it out and let the item
sit in the comms-log only. Do not touch `_active-context.md` for routine status updates.

### 6. Capture leftovers
Anything significant that does not belong in the write target or `_active-context.md` → append a
short dated line to `_inbox.md` (patch, never wholesale) for later triage.

### 7. Report back
One line: what was written where, how many actions captured, whether `_active-context.md` was
updated, and whether anything went to `_inbox.md`. The scheduled task uses this for its Telegram
confirmation, so Euan can review any active-context change.