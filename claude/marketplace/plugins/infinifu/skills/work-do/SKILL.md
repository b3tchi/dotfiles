---
name: work-do
description: Use when you are an agent that has been handed a single bd task ID to execute — read the task with bd show, mark in_progress, do the work through domain-tdd, record evidence in task notes, and report back for review. Do NOT close the task yourself; the reviewer (via work-audit) owns the close transition. Pair with plan-scrum-master (automated dispatch) or plan-supervised (user-supervised batches); also usable by a solo developer picking up `bd ready` manually.
---

# Do a bd Task

## Overview

Execute one bd task end-to-end: read the spec, do the work, verify, close with evidence, report back. This is the per-task protocol that agents follow when a dispatcher hands them a task ID — it is not for creating tasks (use `spec-ready`) or for deciding which tasks to run (use `plan-scrum-master` or `plan-supervised`).

**Core principle:** The bd task is the contract. You implement exactly what the task says, report evidence a reviewer can verify, and surface discoveries. You do NOT write to bd from the worktree.

**Announce at start:** "I'm using the work-do skill to implement bd task `<id>`."

## BD STATE OWNERSHIP — workers do not write to bd

**You read bd. You never write bd.** All bd state transitions — claim, notes, blocked, discoveries, close — are applied by the **orchestrator** (the scrum-master, or the solo dev who dispatched you) from the main worktree. You emit a structured report; the orchestrator applies it serially.

Why: bd's shared Dolt server is sensitive to concurrent writes from parallel agents. Closes have been observed reverting on subsequent reads when multiple worktree-side writers race. Centralizing writes on main eliminates the race; the contract is "workers report, orchestrator writes."

Concretely:
- ❌ Do NOT run `bd update`, `bd close`, `bd create`, `bd dep add`, `bd remember` from the worktree.
- ✅ DO run `bd show`, `bd dep tree`, `bd list` — reads are safe.
- ✅ DO populate the structured report block at Step 8 — orchestrator parses it and applies all bd writes from main.

## When to use this skill

- You are an implementer agent dispatched by `plan-scrum-master`
- You are executing a batch task under `plan-supervised`
- You picked up an unblocked task from `bd ready` and want the standard protocol

## AKM hooks

Stage 5 of the AKM lifecycle — see `claude/akm/akm-lifecycle.md` for the full map and `claude/akm/akm.md` for typed-zettel schemas. Read-only on the PKM.

**Reads:**

- `us###.acceptance_criteria` — the ground-truth contract. When the bd task body is ambiguous, the story AC wins.
- `im###` (`approach`, `components`, `api_surface`, `data_model`) — solution shape for orientation.
- `sp###.tasks` block matching `#### bd <task-id>` — the structured task definition (effort, files_touched, edge_cases, test_plan) that informs execution.

**Writes:** none. All execution state lives in beads task notes; no zettel mutation in this stage.

## Prerequisites

Before starting:

1. You have been given (or chosen) a specific bd task ID
2. `bd show <id>` has a design field with enough detail to implement — if it doesn't, STOP and route back for refinement via `spec-refinement`
3. You will create a worktree at `.worktrees/bd-<id>.<N>` on branch `bd-<id>.<N>` as Step 2 (do NOT rely on `isolation: "worktree"` auto-creation — that generates an opaque dir name and the dir-to-task mapping is lost). `<N>` is the iteration (first attempt = `.0`, retries `.1`, `.2`, …). Worktree dir name and branch name are deliberately identical so `git worktree list` is self-documenting.

## The Process

### Step 1: Read the task

```bash
bd show <id>
```

Read the whole thing — title, design, success criteria, dependencies. If anything is unclear, STOP and ask before touching code. An unclear spec produces a wasted attempt.

Also check:

```bash
bd dep tree <id>   # anything upstream that must be verified first?
```

### Step 2: Create the worktree and branch at the right name

The orchestrator handles the bd claim (`open → in_progress`) when it dispatches you — you don't do it from the worktree. Just go straight to worktree creation.

Create the worktree + branch in one shot — both named `bd-<id>.<N>` where `<N>` is the iteration. First attempt = `.0`; each retry (after work-audit rejection) increments. Example: `bd-42.0` on first attempt, `bd-42.1` after the first rejection. The iteration suffix exists so rejected attempts and the approved attempt coexist as separate branches without name collisions; the matching worktree dir name makes `git worktree list` and `ls .worktrees` self-documenting.

Pick the next iteration:

```bash
ID=<bd-id>
AKM_ROOT="$(akm-root)"
# Highest existing bd-<id>.N branch, or empty if none
PREV=$(git -C "$AKM_ROOT" branch --list "bd-${ID}.*" --format='%(refname:short)' \
       | awk -F. '{print $NF}' | sort -n | tail -1)
NEXT=$(( ${PREV:--1} + 1 ))     # if PREV empty → 0
BRANCH="bd-${ID}.${NEXT}"
WT="$AKM_ROOT/.worktrees/$BRANCH"
```

Create with the right name from the start (do NOT rename / move later):

```bash
git -C "$AKM_ROOT" worktree add "$WT" -b "$BRANCH"
cd "$WT"
```

(For the directory selection rules — `.worktrees` vs `worktrees` vs `~/.config/infinifu/worktrees/<project>` — see `infinifu:domain-git-worktrees`. The convention here assumes the project-local `.worktrees/` location; substitute as appropriate.)

**If you were dispatched into a `isolation: "worktree"` auto-created worktree** (opaque name): the auto-worktree is a mistake under this convention. ExitWorktree it (`action: remove` if untouched, otherwise hand back with `keep` and log a deviation) and create a properly-named worktree as above. The dir-to-task mapping is load-bearing for the work-merge sweep + spec-retro safety-net sweep — opaque names break it.

**If you are resuming after rejection** (`SendMessage` continuing the same agent): you are already in the previous iteration's worktree on the previous iteration's branch. The previous iteration was rejected, so its worktree + branch will be swept on the next successful land. Pick the next `<N>` and create a fresh worktree + branch per the picker above; do your work in the new worktree.

Verify with `git branch --show-current` and `pwd` before continuing.

### Step 3: Do the work

Implementation goes through `domain-tdd` — RED-GREEN-REFACTOR. Read that skill and follow it. The short version:

1. Write a failing test that encodes the task's success criterion
2. Run the test, watch it fail
3. Write the minimum code to pass
4. Run the test, watch it pass
5. Refactor if useful, keeping the test green

If the task is non-code (docs, config, tooling), skip TDD and apply the equivalent verification: run the thing, check the output, prove it works.

### Step 4: Record surprises in a scratchpad

When something doesn't match the spec — a hidden constraint, a dependency that was wrong, an approach the spec suggested that didn't work — capture it in a local scratchpad **right now**, not in the final report from memory.

A scratchpad is just a file in the worktree (e.g. `/tmp/work-do-<id>-deviations.md`) where you append `DEVIATION: spec said X, actually needed Y because Z` lines as they happen. At Step 8 you fold the scratchpad into the structured report's `deviations:` block. The orchestrator writes these into bd notes from main.

This is the single most important discipline. Deviations recorded late get lost; deviations recorded in the moment guide the next task and the retro.

### Step 5: Handle discoveries

If you find work that needs doing but isn't part of this task, **do not expand scope**. **Do not create a bd task yourself** — instead, append the discovery to your scratchpad with enough detail for the orchestrator to file it:

```text
DISCOVERY:
  title: <short description>
  type: task
  design: <what and why; enough for someone to pick it up>
  depends-on: <current-id>   # so the orchestrator wires `bd dep add`
```

The orchestrator parses the discovery block from your final report and runs `bd create` + `bd dep add` from main. Continue with the current task — discovered work gets scheduled later.

### Step 6: Verify

Before reporting back, produce evidence the task is done:

- All task success criteria satisfied — cite them explicitly
- Tests green — paste the test runner output
- No regressions — run the broader suite if applicable
- `domain-verification` checklist applied if relevant

### Step 7: Gather evidence for the report (do NOT touch bd)

Closing is the reviewer's transition, not yours — and even your `IMPLEMENTED:` notes are applied by the orchestrator from main, not by you from the worktree. Collect the evidence; you'll emit it in Step 8.

Per criterion: file path + line range (or command output) proving the criterion was met. Per test added/modified: test name + what bug it would catch. Note any deviations from your scratchpad.

Why you don't close (and don't even write `IMPLEMENTED:` notes from here): bd's shared Dolt server races on concurrent writes. Centralizing all writes on main via the orchestrator removes the race. Functionally `closed` still means "reviewed and approved" because the reviewer (work-audit) still drives the close decision — the orchestrator is just the actor that types the command.

### Step 8: Emit the structured report

Return the structured report below to your dispatcher. The block is parseable — the orchestrator extracts `notes_to_append`, `discoveries`, and the status transition, then applies each to bd from the main worktree.

```yaml
# work-do report — bd <id>
status_transition: in_progress → ready_for_review   # or "in_progress → blocked" with reason below

branch: bd-<id>.<N>
worktree: <absolute path>
summary: <one or two sentences on what was done>
files_changed:
  - <path>
  - <path>
tests:
  added: <N>
  modified: <M>
  outcome: all green   # or list failures

notes_to_append: |
  IMPLEMENTED: <one-line summary>

  Evidence:
  - <criterion 1>: <file:line or command output>
  - <criterion 2>: <file:line or command output>
  - Tests: <test file, N passed>
  - Deviations: <any from scratchpad, or 'none'>

discoveries:
  - title: <short description>
    type: task
    design: <what and why>
    depends-on: <id>            # current task id, so orchestrator can bd dep add
  # …additional discoveries…
  # if none, omit the key or write `discoveries: []`

blocked_reason: |
  # populate ONLY if status_transition is "in_progress → blocked"
  # describe what you tried, what's blocking, what would unblock
```

The orchestrator (scrum-master or solo dev) parses this and applies — from `$AKM_ROOT`, serially:

```bash
# Notes
bd update <id> --notes "$(extract notes_to_append)"

# Discoveries
for d in discoveries: do
  bd create "$d.title" --type "$d.type" --design "$d.design"
  bd dep add <new-id> "$d.depends-on" --type discovered-from
done

# Status transition (only on blocked — ready_for_review stays in_progress for the reviewer)
if blocked: bd update <id> --status blocked
```

Keep the report tight. Branch and worktree lines let the reviewer act mechanically without re-querying you.

## When you hit a blocker

If you can't complete the task:

1. Do NOT write to bd. Set `status_transition: in_progress → blocked` in the Step 8 report.
2. Populate `blocked_reason:` with: what you tried, what's blocking, what would unblock.
3. If the blocker itself is a new piece of work, list it under `discoveries:` so the orchestrator can file a separate bd task and wire the dependency.
4. Send the report. The orchestrator applies `bd update --status blocked` and any discovery filings from main.

Do not close blocked tasks — closing is a reviewer transition and means "reviewed and approved". `in_progress` with a BLOCKED note is the honest state; the orchestrator writes that note.

## Anti-patterns

- **Silent scope expansion.** Doing "related" work that wasn't in the task. Append a `DISCOVERY:` scratchpad entry instead; orchestrator files the new task.
- **Writing to bd from the worktree.** `bd close`, `bd update`, `bd create`, `bd dep add` from a feature worktree races against other agents on the shared Dolt server and has been observed reverting state. Emit the report block; orchestrator writes.
- **Skipping the deviation scratchpad.** Deviations you plan to remember "later" get forgotten. Append to the scratchpad immediately in Step 4.
- **Starting before reading `bd show`.** The task body has context that the dispatcher's summary does not.
- **Editing the task's own spec mid-implementation to match what you did.** If the spec is wrong, record a deviation in the scratchpad — don't rewrite history.

## Integration

**Called by:**
- `plan-scrum-master` — dispatches implementer agents in parallel
- `plan-supervised` — dispatches implementers one at a time between user checkpoints
- Solo users picking up `bd ready` and wanting the standard protocol

**Calls:**
- `domain-tdd` — the RED-GREEN-REFACTOR loop for any code work
- `domain-verification` — evidence-gathering before close
- `spec-refinement` — if task spec is too thin to implement (routes back)

**Pairs with:**
- `domain-git-worktrees` — if not already in an isolated worktree
- `spec-ready` — for bd command reference
