---
name: spec-ready
description: "You MUST use this when an existing spec has plan + tasks written and the user wants to attach beads ids and queue it for execution — 'mark sp007 ready', 'attach bd ids to sp012', 'sp001 is refined, get it ready for work-do', 'plan-prepare on sp004', or any phrasing that names a `sp###` at `status: spec` whose `## tasks` block is populated (H3 per task, H4 per property, no #### bd yet). Stage 4 of the AKM lifecycle (spec-ready). Mints a bd epic + child tasks from the existing task breakdown, annotates each `### Task N` block in the spec with `#### bd <id>`, flips spec status `spec → ready`, and moves the board entry from `## spec` to `## ready`. Does NOT write tasks (those came from spec-refinement), NOT execute work, NOT close issues — execution is `work-do` scope."
---

# Spec Ready (## tasks → bd + status ready)

## Overview

Stage 4 of the AKM lifecycle. A spec is at `status: spec` with `## plan` + `## tasks` populated by `spec-refinement`. The user wants the task breakdown to become actionable beads — one bd epic for the whole spec, one bd task per `### Task N` block — and the spec to flip onto the ready queue.

**Three deliverables, all atomic:**

1. **bd epic** for the spec (title references the spec id + the `us###` it solves).
2. **bd tasks** one per `### Task N` block, with `--parent <epic>` for child linking and `bd dep add` for blocking deps (read from `#### depends`).
3. **Annotate `#### bd <id>`** on every `### Task N` block in the spec file.
4. **Flip frontmatter** `status: spec → ready`.
5. **Move board entry** `[[sp###]]` from `## spec` to `## ready` in `docs/board.md`.

**Out of scope (deliberately):**

- Writing or revising `## tasks` content — that's `spec-refinement`. If `## tasks` is missing or incomplete, block.
- Executing the tasks — that's `work-do`. This skill mints ids; it does NOT call `bd update --status in_progress`, NOT call `bd close`, NOT touch source code.
- User-approval gates on the task list itself — that's the gate at the end of `spec-refinement`. By the time we land here, the breakdown is committed.

**Announce at start:** "Using spec-ready skill to mint beads and queue the spec."

## AKM hooks

Stage 4 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Lifecycle: read `sp###`, write `sp###.tasks` bd-id annotations, write `board.md` (`## spec → ## ready`), produce beads with dependencies as the artifact.

**Reads:**

- `sp###` — target spec at `status: spec`. Read `## plan` and `## tasks`. Every `### Task N` block must already carry `#### type`, `#### effort`, `#### depends`, `#### files_touched`, `#### success_criteria`, `#### edge_cases`, `#### test_plan`. None should already carry `#### bd <id>`.
- Source `us###` and consumed `[[im###]]` — only for the epic design text (one-line summary).

**Writes:**

- `sp###` — same file. For each `### Task N`, append a `#### bd <task-id>` line. Flip frontmatter `status: spec → ready`.
- `docs/board.md` — remove `[[sp###]]` from `## spec`, add to `## ready`.

**bd state:**

- One epic minted (title references the spec). Description carries a one-line summary + `Spec: docs/notes/spec/sp###.md`.
- One child task per `### Task N` block. Parent link via `bd create ... --parent <epic-id>`.
- Blocking deps from each task's `#### depends` H4 property — `bd dep add <later-task> <earlier-task>` per dependency edge.

## Entry-specific checklist

1. **Identify target spec.** User names a `sp###`. Verify `docs/notes/spec/sp###.md` exists.
2. **Verify status.** Must be `status: spec`. Apply Disambiguation if not.
3. **Read `## tasks` block.** Confirm every `### Task N` has the full H4 property set. If any block is missing properties or carries placeholder text, block — route back to `spec-refinement`.
4. **Confirm no `#### bd` annotations exist yet.** If any task already has a `#### bd <id>` line, the spec has already been processed — Disambiguation applies.
5. **Verify `bd` is initialized** in the workspace. If `.beads/` doesn't exist, run `bd init` once.
6. **Mint the epic.** One `bd create --type epic` for the whole spec. Title format: `Epic: <spec alias> [sp###]`. Use `--design` to embed the one-line goal + spec path.
7. **Mint each task** in `## tasks` order. For each `### Task N`:
   - `bd create "<task title>" --type task --parent <epic-id> --design "<H4 properties as design text>"`.
   - Capture the new bd id.
8. **Wire blocking deps.** For each `### Task N`, read its `#### depends` H4. For every dependency reference, call `bd dep add <this-task-id> <earlier-task-id>`.
9. **Annotate the spec.** For each `### Task N`, append `#### bd <task-id>` (matching the new bd id). Preserve all other H4 properties; the annotation is additive.
10. **Flip status.** `sp###.status: spec → ready`.
11. **Move board entry.** Remove `[[sp###]]` line from `## spec` in `docs/board.md`; add it under `## ready`. Same wikilink, same label.
12. **Verify.** `bd list --parent <epic-id>` should show every task. `bd ready` should show the root tasks (no `#### depends` → unblocked at start).

## Disambiguation

- **`sp###` does not exist** → block; nothing to ready.
- **`sp###` at `status: idea`** → route to `spec-writing`.
- **`sp###` at `status: spec` but `## tasks` missing or incomplete** → route to `spec-refinement`. spec-ready cannot invent tasks.
- **`sp###` at `status: spec` but tasks already carry `#### bd` annotations** → spec has been processed before; either close the matter or route to `work-do` (execution).
- **`sp###` at `status: ready`** → already done. Route to `work-do`.
- **`sp###` at `status: done`** → shipped. Nothing to do.

## Key Principles (entry-specific)

- **One epic per spec.** The bd epic represents the spec's deliverable workstream. Tasks are children. No nested epics.
- **Tasks come from `## tasks`, not from invention.** This skill mints ids for an *already-written* breakdown. If the breakdown is missing or sketchy, block — fixing it is `spec-refinement`'s job.
- **Blocking deps from `#### depends`.** Don't guess execution order; the property is there for exactly this reason. Walk every task's `#### depends` once and call `bd dep add` for each edge.
- **`#### bd <id>` is additive.** Do not delete or reformat the other H4 properties. The annotation lives alongside `#### type`, `#### effort`, etc.
- **Atomic operation.** Mint epic + tasks + deps + annotations + status flip + board move = one logical commit. If any step fails midway, roll back rather than leaving partial state.
- **No execution.** This skill stops at "ready". The first `bd update --status in_progress` belongs to `work-do`.

## Integration

**Calls:**

- `infinifu:spec-read` — fetch target sp### + verify status/body.
- `bd` CLI — `bd init`, `bd create`, `bd dep add`, `bd list --parent`, `bd ready` for verification.
- `infinifu:meta-patterns` — full bd command reference if you need a specific invocation.

**Out of scope (do NOT call from here):**

- `bd update --status in_progress` / `bd close` — execution belongs to `work-do`.
- `spec-refinement` — it ran upstream; only re-invoke if step 3 blocks on incomplete tasks.
- Source-code changes of any kind. spec-ready does not touch `src/`.
- `infinifu:spec-retro` — that's after merge, not after queueing.

## bd command shapes

For convenience — the exact shapes this skill uses. Full reference in `infinifu:meta-patterns`.

```bash
# 1. Init (only if .beads/ missing)
bd init

# 2. Epic
bd create "Epic: <spec alias> [sp###]" \
  --type epic \
  --design "$(cat <<EOF
## Goal
<one-line summary from sp###>

## Spec
docs/notes/spec/sp###.md
EOF
)"
# capture as <epic-id>

# 3. Per task (in ## tasks order)
bd create "<task title from ### Task N: ...>" \
  --type task \
  --parent <epic-id> \
  --design "$(cat <<EOF
#### type
<value>

#### effort
<value>

#### files_touched
<list>

#### success_criteria
<list>

#### edge_cases
<list>

#### test_plan
<list>
EOF
)"
# capture as <task-N-id>

# 4. Blocking deps (per #### depends reference)
bd dep add <later-task-id> <earlier-task-id>

# 5. Verify
bd list --parent <epic-id>
bd ready
```
