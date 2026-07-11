---
name: work-merge
description: "Use this when work-audit has just APPROVED a single bd task — auto-triggered from work-audit on the approved verdict, or invoked manually as 'merge bd-42', 'land task bd-7'. Per-task local landing: merges branch `bd-<id>.<N>` into base, runs tests, removes the worktree. If the closed task was the last open child of its parent epic, the skill also runs the epic finale — flips `us###.status: ready → done`, `im###.status: proposed → accepted`, `sp###.status: ready → done` + footer `Index: [[board]] → [[archive]]`, relocates the spec file `docs/notes/spec/ → docs/notes/archive/spec/`, moves `[[sp###]]` from `docs/board.md` to `docs/archive.md ## done`, and closes the bd epic. All operations are LOCAL — no push, no PR. Remote sync is `spec-retro`'s job. Does NOT rewrite `im###` body, NOT mint new ADRs, NOT mint new draft stories — those are `spec-retro` scope."
---

# Work Merge (per-task local land + epic finale)

## Overview

Stage 7 of the AKM lifecycle, invoked per task. Triggered automatically by `work-audit` on its APPROVED verdict; a solo dev can also invoke it manually after a manual audit.

Two operations, gated by whether this task was the last open child of its parent epic:

1. **Always — per-task local land:**
   - Merge `bd-<id>.<N>` into base (`origin/HEAD`, e.g. `main`) with `--no-ff` to preserve the bd-task boundary in history.
   - Run the configured post-merge test command. Failure rolls the merge back and reopens the task as `in_progress` with a `POST-MERGE FAIL` note.
   - Remove the worktree (`git worktree remove`, no `--force`) and the local branch (`git branch -d`).
2. **Conditional — epic finale** (only if `bd list --parent <epic-id>` shows no open/in_progress/blocked children left):
   - Flip `us###.status: ready → done`, `im###.status: proposed → accepted`, `sp###.status: ready → done` + footer `Index: [[board]] → [[archive]]`.
   - Remove `[[sp###]]` from `$AKM_ROOT/docs/board.md`. Add to `$AKM_ROOT/docs/archive.md ## done`.
   - Close the bd epic with `bd close <epic-id>`.
   - Commit on `$AKM_ROOT`: `feat(akm): archive sp<NNN>`.

**LOCAL ONLY.** This skill never pushes, never opens a PR, never touches a remote. `spec-retro` pushes the AKM commits, archive move, and any new branches/refs once it has refreshed the knowledge graph.

**Out of scope (deferred to `spec-retro`):**

- `git push` / `git push --all` / `bd dolt push` — spec-retro syncs to remote.
- Rewriting `im###.approach` / `## components` / `## data_model` / `## api_surface` to reflect shipped reality.
- Filing new ADRs for decisions that shifted during execution.
- Updating `ft###` zettels for features whose surface or constraints changed.
- Drafting new `us###` for follow-up work discovered during implementation.

**Announce at start:** "Using work-merge to land bd-<id>.<N> (and run epic finale if last child)."

## AKM Workspace Resolution

The bd task and the AKM zettels are shared product knowledge — they live on **main**. work-merge typically runs from the main worktree (because `work-audit` already removed/will-remove the feature worktree); even if invoked from elsewhere, resolve the root first:

```bash
AKM_ROOT="$(akm-root)"
```

`akm-root` returns the main-worktree path (default branch); outside git, cwd. Anchor every AKM path on `$AKM_ROOT`. If `akm-root` errors, surface its stderr and abort.

work-merge is a **transition skill that commits on main** per the AKM commit policy. The epic-finale flip lands as one AKM admin commit on `$AKM_ROOT`:

```bash
git -C "$AKM_ROOT" commit -m "feat(akm): archive sp<NNN>"
```

Per-task land also commits a merge commit (`merge: bd-<id>.<N>`) on base. Both stay local until `spec-retro` pushes.

## AKM hooks

Stage 7 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`).

**Reads:**

- bd task `<id>` (status, parent epic id, design / criteria from work-audit's evidence).
- `bd list --parent <epic-id>` — to determine whether this is the last open child.
- On epic finale: `sp###`, `us###`, `im###` frontmatter; `docs/board.md`; `docs/archive.md`.

**Writes:**

- Local merge commit on base: `merge: bd-<id>.<N>`.
- Worktree removal + local branch deletion.
- On epic finale: `sp###.md` / `us###.md` / `im###.md` frontmatter, spec file relocated `docs/notes/spec/ → docs/notes/archive/spec/`, `board.md`, `archive.md`, one `feat(akm): archive sp<NNN>` commit on `$AKM_ROOT`.
- `bd close <epic-id>` on epic finale.

## Trigger contract

work-merge is invoked **per task**, with the bd task id, by `work-audit` after a successful APPROVED verdict. The id is the only required input.

```
work-merge <bd-id>
```

work-audit's Step 7 Approved path ends with this invocation. No manual user step is required between audit-approve and land.

For a solo developer running outside the scrum-master pipeline, invoke manually after a manual audit:

```
"merge bd-42"   →  work-merge skill fires
```

## Process

### Step 1 — Resolve context

```bash
AKM_ROOT="$(akm-root)"
ID="<bd-task-id>"
# The approved iteration is whichever branch was checked out in the worktree
# that work-audit just inspected. work-audit passes it through.
ITER="<N>"
EPIC="$(bd show "$ID" --json | jq -r '.parent_id // empty')"
SP="$(bd show "$EPIC" --json | jq -r '.notes // ""' | grep -oE 'sp[0-9]+' | head -1)"
```

Required: `$ID`, `$ITER`, `$AKM_ROOT`, `$EPIC`. Spec id `$SP` is only needed for the epic finale; resolve from the epic notes or design. If `$SP` can't be resolved when the finale fires, escalate to the human.

### Step 2 — Per-task local land

```bash
bash <skill-path>/work-merge/scripts/land-bd-task.sh "$ID" "$ITER" "$AKM_ROOT" "<test-command>"
```

Script behavior (`scripts/land-bd-task.sh`):

- Resolves worktree for `bd-<id>.<N>` via `git worktree list --porcelain`.
- `git checkout <base> && git pull --ff-only` (no-op if no upstream).
- `git merge --no-ff bd-<id>.<N> -m "merge: bd-<id>.<N>"`.
- Runs `<test-command>` if provided.
  - **Fail (exit 2):** `git reset --hard ORIG_HEAD`, reopens task as `in_progress` with `POST-MERGE FAIL` note, leaves worktree intact, exits 2. work-merge propagates this as REJECTED back to work-audit.
  - **Pass:** continues.
- Removes the approved worktree (`git worktree remove`, no `--force`) and deletes the approved branch (`git branch -d`).
- **Sweeps sibling iterations:** any other `bd-<id>.*` branches (rejected earlier attempts whose cleanup was skipped) get their worktrees removed `--force` and branches deleted `-D`. Rejected iterations never merge into base, so `-D` is required and safe.
- `git worktree prune`.

No push. The base branch has a new merge commit; it stays local until spec-retro.

### Step 3 — Last-child check

```bash
OPEN_CHILDREN=$(bd list --parent "$EPIC" --status open,in_progress,blocked --json | jq 'length')
```

- `OPEN_CHILDREN > 0` → report `TASK_LANDED`. Done. Other tasks still in flight.
- `OPEN_CHILDREN == 0` → continue to Step 4 (epic finale).

### Step 4 — Epic finale (last child only)

```bash
# Resolve us/im ids from the spec body
US="$(grep -oE 'solves: \[\[us[0-9]+' "$AKM_ROOT/docs/notes/spec/$SP.md" | grep -oE 'us[0-9]+')"
IM="$(grep -oE 'implements: \[\[im[0-9]+' "$AKM_ROOT/docs/notes/spec/$SP.md" | grep -oE 'im[0-9]+')"

bash <skill-path>/work-merge/scripts/archive-epic.sh "$SP" "$US" "$IM" "$EPIC" "$AKM_ROOT"
```

Script behavior (`scripts/archive-epic.sh`):

- Flips `us###.status: ready → done`, `im###.status: proposed → accepted`, `sp###.status: ready → done`.
- Flips `sp###` footer line `Index: [[board]] → [[archive]]`.
- `git mv`s the delivered spec `docs/notes/spec/sp###.md → docs/notes/archive/spec/sp###.md` (the archive mirror; `spec/` then holds only active specs). akm id-allocation + alias lookup span both dirs, so the id stays reserved and the spec stays findable via `akm read`.
- Removes `[[sp###...]]` line from `$AKM_ROOT/docs/board.md`.
- Inserts `[[sp###...]]` under `$AKM_ROOT/docs/archive.md ## done`.
- `bd close <epic-id> --reason "Merged via sp###. All child tasks closed by work-audit."`
- `git -C "$AKM_ROOT" add ... && git commit -m "feat(akm): archive sp<NNN>"`.

All local. No push.

### Step 5 — Report

After per-task land only:

```
work-merge: TASK_LANDED bd-<id>.<N>

Base: <base-branch> (local, +1 merge commit)
Worktree: removed (was <path>)
Branch: deleted (bd-<id>.<N>)
Epic <epic-id>: <N> open children remaining
```

After epic finale:

```
work-merge: TASK_LANDED + EPIC_DONE bd-<id>.<N>

Base: <base-branch> (local, +1 merge commit)
Worktree: removed
Branch: deleted (bd-<id>.<N>)
AKM flip: us### → done, im### → accepted, sp### → done
Board → archive: sp### moved
Epic <epic-id>: closed
Local commits pending push: <count from git log @{u}..HEAD if upstream, else N>

Next: run spec-retro for sp### — it refreshes the AKM graph and pushes everything to remote.
```

## Disambiguation

- **Task not yet closed by work-audit** → block; this skill is post-approval only. The implementer should be running `work-audit` first.
- **Branch `bd-<id>.<N>` doesn't exist** → block; the implementer didn't follow the naming convention. Manual recovery: have implementer rename the branch, then re-run.
- **Post-merge tests fail** → script rolls back, reopens task, returns REJECTED. work-audit (or the user) re-dispatches the implementer.
- **Worktree has uncommitted changes** → `git worktree remove` refuses. Investigate before forcing — usually an in-flight discovery that wasn't filed as a separate task. File it, commit / stash / discard, then re-run.
- **Epic finale fires but `sp###` id can't be resolved from epic notes** → escalate; finale needs the spec id to flip statuses. Manual recovery: provide the id, re-run with explicit sp.

## Key Principles

- **Local only.** Every command here mutates the local repo. Push lives in spec-retro so the AKM refresh and the code land remotely as one batch.
- **Per-task land, not per-spec.** Each `bd-<id>.<N>` lands as it passes audit. Worktrees are ephemeral — they vanish before the next task starts, so the stale-worktree problem doesn't exist.
- **`--no-ff` preserves bd boundaries.** `git log --first-parent <base>` shows one commit per bd task — readable history.
- **Test gate before cleanup.** Worktree is the only place to recover from a bad merge. Remove it only after post-merge tests pass.
- **No partial epic finale.** If the AKM flip starts and any of the file edits / bd close fails, the script aborts; nothing is left half-flipped. Recovery is manual (rare; the operations are simple file edits + one bd command).
- **Spec-retro is the next caller.** On epic finale, the report points the human/dispatcher at spec-retro for graph refresh + push. work-merge does not call spec-retro itself.

## Integration

**Triggered by:**

- `infinifu:work-audit` — auto-invokes work-merge on APPROVED verdict (per task).
- Solo dev — manual invocation after manual audit.

**Calls:**

- `scripts/land-bd-task.sh` — per-task merge + test + worktree cleanup.
- `scripts/archive-epic.sh` — last-child epic finale (AKM flip + board→archive + bd close epic + AKM commit).
- `bd list --parent <epic-id>` / `bd show` / `bd close` — task / epic queries and state writes.

**Hands off to:**

- `infinifu:spec-retro` — only when EPIC_DONE was reported. spec-retro refreshes the AKM graph (im### body rewrite, new ADRs, ft### updates, us### drafts) and pushes everything to remote.

**Out of scope (do NOT call from here):**

- `spec-retro` — work-merge announces, does not invoke. The user (or dispatcher) runs spec-retro.
- `implementation-write` / `adr-write` / `story-write` — narrative refresh belongs to spec-retro.
- `git push` / `gh pr create` / `bd dolt push` — spec-retro owns remote sync.
- Source code changes — work-merge does not edit `src/`.
