---
name: work-do
description: Use when you are an agent that has been handed a single bd task ID to execute — read the task with bd show, mark in_progress, do the work through domain-tdd, record evidence in task notes, and report back for review. Do NOT close the task yourself; the reviewer (via work-audit) owns the close transition. Pair with plan-scrum-master (automated dispatch) or plan-supervised (user-supervised batches); also usable by a solo developer picking up `bd ready` manually.
---

# Do a bd Task

## Overview

Execute one bd task end-to-end: read the spec, do the work, verify, close with evidence, report back. This is the per-task protocol that agents follow when a dispatcher hands them a task ID — it is not for creating tasks (use `spec-ready`) or for deciding which tasks to run (use `plan-scrum-master` or `plan-supervised`).

**Core principle:** The bd task is the contract. You implement exactly what the task says, close it with evidence a reviewer can verify, and report back clearly. Discoveries become new bd tasks — you don't silently expand scope.

**Announce at start:** "I'm using the work-do skill to implement bd task `<id>`."

## When to use this skill

- You are an implementer agent dispatched by `plan-scrum-master`
- You are executing a batch task under `plan-supervised`
- You picked up an unblocked task from `bd ready` and want the standard protocol

## Prerequisites

Before starting:

1. You have been given (or chosen) a specific bd task ID
2. `bd show <id>` has a design field with enough detail to implement — if it doesn't, STOP and route back for refinement via `spec-refinement`
3. You are on the correct branch/worktree (if dispatched via `isolation: "worktree"`, this is already set up)

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

### Step 2: Claim the task

```bash
bd update <id> --status in_progress
```

Claiming signals to other agents that this task is yours. Do this **before** any code changes — if you crash, the next agent knows something was in flight.

### Step 3: Do the work

Implementation goes through `domain-tdd` — RED-GREEN-REFACTOR. Read that skill and follow it. The short version:

1. Write a failing test that encodes the task's success criterion
2. Run the test, watch it fail
3. Write the minimum code to pass
4. Run the test, watch it pass
5. Refactor if useful, keeping the test green

If the task is non-code (docs, config, tooling), skip TDD and apply the equivalent verification: run the thing, check the output, prove it works.

### Step 4: Log surprises to bd immediately

When something doesn't match the spec — a hidden constraint, a dependency that was wrong, an approach the spec suggested that didn't work — log it to bd **right now**, not in the final report:

```bash
bd update <id> --notes "DEVIATION: spec said X, actually needed Y because Z"
```

This is the single most important discipline. Deviations logged late get lost; deviations logged in the moment guide the next task and the retro.

### Step 5: Handle discoveries

If you find work that needs doing but isn't part of this task, **do not expand scope**. File a new task:

```bash
bd create "Discovered: <short description>" --type task --design "<what and why>"
bd dep add <new-id> <current-id> --type discovered-from
```

Then continue with the current task. Discovered work gets picked up later by a dispatcher.

### Step 6: Verify

Before reporting back, produce evidence the task is done:

- All task success criteria satisfied — cite them explicitly
- Tests green — paste the test runner output
- No regressions — run the broader suite if applicable
- `domain-verification` checklist applied if relevant

### Step 7: Record evidence on the task — do NOT close

Closing is the reviewer's transition, not yours. Leave the task `in_progress` and record your completion evidence in the task notes so the reviewer (running `work-audit`) can verify each claim:

```bash
bd update <id> --notes "IMPLEMENTED: <one-line summary>

Evidence:
- <criterion 1>: <file:line or command output>
- <criterion 2>: <file:line or command output>
- Tests: <test file, N passed>
- Deviations: <any logged in step 4, or 'none'>"
```

Why you don't close: if you close, `closed` just means "implementer thinks it's done" — which is the same information as `in_progress` + implementation notes. The reviewer owns the `in_progress → closed` transition so `closed` means "reviewed and approved". That gate collapses if the implementer grabs the close too.

### Step 8: Report back

Return a short report to whoever dispatched you:

```
Task <id>: <title> — ready for review

Summary: <one or two sentences on what was done>
Files changed: <list>
Tests: <N added, M modified, all green>
Deviations: <any, or 'none'>
Discoveries filed: <bd IDs, or 'none'>
```

Keep it tight. The dispatcher (scrum-master, or a user under plan-supervised) routes this to the reviewer; they don't need a walkthrough.

## When you hit a blocker

If you can't complete the task:

1. Leave it in `in_progress` (do NOT close it)
2. Log what you tried and why it's blocked:
   ```bash
   bd update <id> --notes "BLOCKED: <reason>. Tried: <list>. Needs: <what would unblock>"
   ```
3. Report back to the dispatcher with `status: blocked`
4. Optionally file a new bd task for the blocker so it can be scheduled

Do not close blocked tasks — closing is a reviewer transition and means "reviewed and approved". `in_progress` with a BLOCKED note is the honest state.

## Anti-patterns

- **Silent scope expansion.** Doing "related" work that wasn't in the task. File a new task instead.
- **Closing the task yourself.** `bd close` is the reviewer's job. Record implementation evidence in `bd update --notes` and leave state as `in_progress` for audit.
- **Skipping the deviation log.** Deviations you plan to mention "later" get forgotten. Log immediately in Step 4.
- **Starting before reading `bd show`.** The task body has context that the dispatcher's summary does not.
- **Editing the task's own spec mid-implementation to match what you did.** If the spec is wrong, log a deviation and close honestly — don't rewrite history.

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
