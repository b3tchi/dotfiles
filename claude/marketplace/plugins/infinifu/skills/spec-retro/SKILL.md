---
name: spec-retro
description: Use when development work is merged or PR created — runs a delivery retrospective, validates documentation, identifies skill improvements, closes bd epic, and archives spec to board/done/
---

# Spec Retro

The closing act of the lifecycle. Not just housekeeping — a structured retrospective that extracts learnings, improves docs and skills, and leaves the codebase better than it was found.

**Announce at start:** "I'm using the spec-retro skill to run the delivery retrospective."

## AKM hooks

Stage 8 of the AKM lifecycle — see `claude/akm/akm-lifecycle.md` for the full map and `claude/akm/akm.md` for typed-zettel schemas. Update the PKM from shipped reality and harvest discovered scope.

**Reads:** shipped diff, `im###`, `ft###`, `adr####`.

**Writes:**

- `im###` body — rewrite `## approach` / `## components` / `## data_model` / `## api_surface` to match what actually shipped. The `accepted` card is now the source of truth.
- `ft###` — update widened constraints; supersede via `## superseded_by` when a contract genuinely changed (features are append-only in spirit).
- `adr####` — mint a *new* ADR for each decision that shifted during execution (ADRs are immutable; the retro produces new entries, not edits).
- `us###` — file fresh drafts for newly-discovered scope. The retro is the cheapest moment to capture them.
- Close the beads epic.

## When to Use

- After `work-merge` completes with Option 1 (merge) or Option 2 (PR)
- NOT for Option 3 (keep as-is) or Option 4 (discard) — work is not complete

## The Process

### Step 1: Validate Delivery

Verify the work is actually complete — not just merged, but correct.

- [ ] All bd tasks under the epic are closed (`bd list --parent <epic-id>`)
- [ ] Tests pass on the base branch
- [ ] No TODOs or known issues left untracked — if found, file `bd create "Discovered: ..."` before closing

```bash
bd list --parent <epic-id> --status open   # Should return nothing
```

If open tasks remain: close them or file follow-up issues before proceeding.

### Step 2: Retrospective — What Happened

First, pull the evidence from bd — don't rely on memory:

```bash
bd show <epic-id>                          # Epic notes and description
bd list --parent <epic-id> --status closed # All completed tasks
bd list --parent <epic-id>                 # Any with notes, blockers, discoveries
```

For each task, check for recorded signals:
```bash
bd show <task-id>   # Notes, reason, blockers, discoveries filed during work
```

Look for:
- Tasks that were reopened or had `--status blocked`
- Issues created as `Discovered:` during execution
- Rejection notes from reviewers
- Tasks whose `--reason` on close mentions a workaround or deviation

**From this evidence, answer:**

**What went wrong or was harder than expected?**
- Did the spec miss anything? (missing steps, wrong file paths, bad assumptions)
- Did tests fail unexpectedly? Why?
- Did the implementation deviate from the spec? Was the spec wrong or the implementation?
- Were there blockers or surprises not anticipated in the plan?

**What went well?**
- What in the spec was especially useful?
- What patterns or approaches worked cleanly?

**What should be prevented next time?**
- Was there a class of mistake that a skill or doc update could prevent?
- Was there a missing check, validation, or gate that would have caught the issue earlier?

### Step 3: Act on Findings

For each finding from Step 2, take one of these actions:

| Finding type | Action |
|---|---|
| Spec had wrong file path / bad assumption | Update the spec before archiving (it's the historical record) |
| A skill was missing or incomplete | Update the skill, or file `bd create "Improve skill: ..."` |
| A doc (AGENTS.md, CLAUDE.md, recipe) was out of date | Update it now |
| A pattern worth preserving | Add to relevant docs or skills |
| A follow-up task discovered | `bd create "Follow-up: ..." --type task` |

**Do not defer doc and skill updates** — this is the moment with the most context. Defer = forget.

### Step 4: Reconcile Product Stories

Do this **before** closing the epic — the close reason should reflect any partial-met or revised stories.

If `product/stories.yaml` does not exist, skip this step entirely. Don't create one just to mark something done.

If it does exist, the shipped epic may satisfy one or more user stories. Walking the stories now (while context is fresh) is far cheaper than reconciling drift weeks later from a stale backlog.

1. **Identify candidate stories** — check the bd epic description and any `board/idea|spec/<topic>.md` doc for referenced story ids. If none referenced, invoke `story-find` against the topic area to surface plausible matches.
2. **Verify against acceptance criteria** — for each candidate, check whether every criterion is met. Use the same evidence (bd notes, test results, the merged diff) you collected for the retrospective.
3. **Classify each candidate:**
   - **Fully met** → set `status: done` on that story id in `product/stories.yaml`.
   - **Partially met** → leave status as-is. Note the gap in the retro summary so the remaining work stays visible.
   - **Exceeded scope** (delivery added behavior the story never described) → invoke `story-write` to capture the new capability as a separate story, or update the existing story's acceptance criteria. Don't silently expand what the original story claimed.
4. **Capture the decisions** so Step 6's summary can list them.

### Step 5: Close the Epic

```bash
bd close <epic-id> --reason "Shipped: <one-line summary>. Stories: <ids closed or 'n/a'>. Retro: <one-line on key learning>"
# bd 1.0 auto-exports .beads/issues.jsonl; proceed straight to the archive commit below.
```

### Step 6: Archive the Spec

```bash
git mv <board>/ready/<topic>.md <board>/done/<topic>.md
git add .beads/
git commit -m "chore: retro and archive <topic> [<epic-id>]"
git push
```

### Step 7: Retro Summary

Output a short summary:

```
## Retro: <topic>

**Delivered:** <what shipped>
**What went wrong:** <key issues>
**What was improved:** <docs/skills updated>
**Stories closed:** <story ids marked done, or "none">
**Stories partial / revised:** <ids + gap, or "none">
**Follow-up filed:** <bd IDs if any>
**Epic closed:** <epic-id>
```

## Quick Reference

| Trigger | Action |
|---------|--------|
| Merge or PR created | Full retro → reconcile stories → close epic → `git mv ready/ → done/` |
| Open tasks remain | File follow-ups, then close |
| Doc is stale | Update it now, not later |
| Skill has a gap | Update skill or file improvement issue |
| Story fully met | Set `status: done` in `product/stories.yaml` |
| Story partially met | Leave as-is, note gap in retro summary |
| Delivery exceeded story | `story-write` a new story or revise criteria — don't expand silently |
| Work kept as-is | Skip — not done yet |
| Work discarded | Skip — nothing to archive |

## Common Mistakes

**Skipping the retrospective and just doing the file move**
- Retro is the point. The file move is a side effect.

**Deferring doc/skill updates**
- "I'll update it later" = never. Do it now while context is fresh.

**Closing the epic before all tasks are verified**
- Check `bd list --parent <epic-id> --status open` first.

## Integration

**Called after:**
- `work-merge` Option 1 or 2

**May update:**
- Skills in `~/.config/Claude/skills/` or equivalent
- `AGENTS.md`, `CLAUDE.md`, recipe docs
- The spec itself (as historical record) before archiving
- `product/stories.yaml` — bump matching story status to `done`, or revise criteria when delivery exceeded scope (Step 4)

**May invoke:**
- `story-find` — to locate stories that might be satisfied by the shipped epic
- `story-write` — when delivery exceeded what any existing story described, to capture the new capability

**Pairs with:**
- `spec-ready` — the opening act
- `work-merge` — branch integration just before this
