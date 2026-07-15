---
name: work-do
description: Use when you are an agent that has been handed a single bd task ID to execute — read the task with bd show, mark in_progress, do the work through domain-tdd, commit it to the task branch, record evidence in task notes, and report back for review. Do NOT close the task yourself; the reviewer (via work-audit) owns the close transition. Do NOT report ready without committing — work-merge merges the branch, not your worktree, so uncommitted work is a silent no-op merge. Pair with plan-scrum-master (automated dispatch) or plan-supervised (user-supervised batches); also usable by a solo developer picking up `bd ready` manually.
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

### Step 2: Claim, then create the worktree and branch at the right name

```bash
bd update <id> --status in_progress
```

Claiming signals to other agents that this task is yours. Do this **before** any code changes — if you crash, the next agent knows something was in flight.

Then create the worktree + branch in one shot — both named `bd-<id>.<N>` where `<N>` is the iteration. First attempt = `.0`; each retry (after work-audit rejection) increments. Example: `bd-42.0` on first attempt, `bd-42.1` after the first rejection. The iteration suffix exists so rejected attempts and the approved attempt coexist as separate branches without name collisions; the matching worktree dir name makes `git worktree list` and `ls .worktrees` self-documenting.

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

### Step 7: Commit to the branch — the work does not exist until you do

Everything so far lives as uncommitted changes in your worktree. **`work-merge` merges your BRANCH — it cannot see your working tree.** An uncommitted worktree means the branch has zero commits over base, the merge is a silent no-op, and the only thing standing between you and lost work is `git worktree remove` refusing to delete dirty state.

```bash
git -C "$WT" add -A
git -C "$WT" commit -m "<type>(<scope>): <what changed> [<spec-id> T<n>]"
git -C "$WT" log --oneline "$(git -C "$WT" merge-base HEAD @{upstream} 2>/dev/null || echo main)"..HEAD
```

The last line is the check that matters: **it must print at least one commit.** If it prints nothing, you have not committed — fix that before going near Step 9.

Rules:

- **Commit before reporting ready. Always.** Not "if it feels done", not "the reviewer can handle it". The reviewer must never author the diff it audits — that collapses the review gate exactly like closing your own task does (Step 8).
- Stage deliberately. `git add -A` is fine in a clean task worktree; if you generated scratch files, artifacts, or debug output, don't sweep them in.
- Multiple commits are fine. A rejected-then-fixed iteration typically stacks a second commit on the first — that's good history, and the reviewer diffs your fix against what it already approved.
- Do **not** push. `work-merge` lands locally; `spec-retro` owns remote sync.
- Do **not** merge into base yourself.

### Step 8: Record evidence on the task — do NOT close

Closing is the reviewer's transition, not yours. Leave the task `in_progress` and record your completion evidence in the task notes so the reviewer (running `work-audit`) can verify each claim:

```bash
bd update <id> --notes "IMPLEMENTED: <one-line summary>

Evidence:
- <criterion 1>: <file:line or command output>
- <criterion 2>: <file:line or command output>
- Tests: <test file, N passed>
- Commits: <sha(s) on bd-<id>.<N>>
- Deviations: <any logged in step 4, or 'none'>"
```

Why you don't close: if you close, `closed` just means "implementer thinks it's done" — which is the same information as `in_progress` + implementation notes. The reviewer owns the `in_progress → closed` transition so `closed` means "reviewed and approved". That gate collapses if the implementer grabs the close too.

### Step 9: Report back

Return a short report to whoever dispatched you:

```
Task <id>: <title> — ready for review

Branch: bd-<id>.<N>
Commits: <sha(s)>          # MUST be non-empty — see Step 7
Worktree: <absolute path>
Summary: <one or two sentences on what was done>
Files changed: <list>
Tests: <N added, M modified, all green>
Deviations: <any, or 'none'>
Discoveries filed: <bd IDs, or 'none'>
```

Branch, commits, and worktree let the reviewer (and the later worktree-sweep in spec-retro) act mechanically without re-querying you. **A report with a branch but no commit sha is the failure mode this contract exists to catch** — `work-audit` will bounce it straight back.

Keep it tight. The dispatcher (scrum-master, or a user under plan-supervised) routes this to the reviewer; they don't need a walkthrough.

## When you hit a blocker

If you can't complete the task:

1. Leave it in `in_progress` (do NOT close it)
2. **Commit whatever partial work exists** to your branch (`git -C "$WT" add -A && git -C "$WT" commit -m "wip(<scope>): <where you got to> [BLOCKED]"`). A blocked task is the case where losing the work hurts most — the next agent (or you, resumed) picks up from the commit, not from a worktree that may get swept. If there is genuinely nothing to commit, say so explicitly in the note.
3. Log what you tried and why it's blocked:
   ```bash
   bd update <id> --notes "BLOCKED: <reason>. Tried: <list>. Needs: <what would unblock>. WIP committed: <sha or 'nothing to commit'>"
   ```
4. Report back to the dispatcher with `status: blocked`
5. Optionally file a new bd task for the blocker so it can be scheduled

Do not close blocked tasks — closing is a reviewer transition and means "reviewed and approved". `in_progress` with a BLOCKED note is the honest state.

## Anti-patterns

- **Reporting ready with an uncommitted worktree.** `work-merge` merges the BRANCH; it cannot see your working tree. Uncommitted work = a branch with zero commits = a no-op merge, and the work survives only because `git worktree remove` refuses to delete dirty state. Observed in the wild: the reviewer noticed, committed the diff on the implementer's behalf to unblock the land, and thereby authored the artifact it had just approved — collapsing the review gate. Commit in Step 7; report the sha in Step 9.
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
