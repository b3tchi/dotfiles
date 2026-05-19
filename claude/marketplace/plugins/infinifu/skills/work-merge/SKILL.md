---
name: work-merge
description: "You MUST use this when all of a spec's bd tasks are closed by work-audit and the work needs to land — 'merge sp007', 'land the rotate-credentials work', 'sp001 is approved, merge it', 'all tasks closed, time to merge', or any phrasing that names a `sp###` whose child bd tasks are all `closed` and now needs the AKM lifecycle flip + git landing. Stage 7 of the AKM lifecycle (work-merge). Verifies tests pass, closes the bd epic, flips `us###.status: ready → done`, flips `im###.status: proposed → accepted`, flips `sp###.status: ready → done` plus footer `Index: [[board]] → [[archive]]`, removes `[[sp###]]` from `docs/board.md`, adds it to `docs/archive.md ## done`, then guides the git landing (merge/PR/keep/discard). Does NOT rewrite `im###` body, NOT mint new ADRs, NOT mint new draft stories — those are `spec-retro` scope."
---

# Work Merge (sp### ready → done + archive)

## Overview

Stage 7 of the AKM lifecycle. Every child bd task of the spec has been closed by `work-audit`, the implementation is on a feature branch (or worktree), and the user wants the work to land. Two things happen here — and only here — atomically:

1. **AKM status flip + archive move:** `us###.status` → `done`, `im###.status` → `accepted`, `sp###.status` → `done` + footer flip `Index: [[board]] → [[archive]]`. Remove `[[sp###]]` from `docs/board.md`. Add to `docs/archive.md` under `## done`. Close the bd epic.
2. **Git landing:** verify tests pass, then present 4 options (merge locally / PR / keep / discard) and execute the chosen one. Cleanup worktree where appropriate.

**Out of scope (deliberately deferred to `spec-retro`):**

- Rewriting `im###.approach` / `## components` / `## data_model` / `## api_surface` to reflect shipped reality (proposed → accepted narrative refresh).
- Filing new ADRs for decisions that shifted during execution.
- Updating `ft###` zettels for features whose surface or constraints changed.
- Drafting new `us###` for follow-up work discovered during implementation.

That's the AKM knowledge-graph maintenance pass and it happens *after* merge.

**Announce at start:** "Using work-merge skill to land sp### and flip the lifecycle."

## AKM Workspace Resolution

Specs, board, archive, and the touched `us###` / `im###` are shared product knowledge — they live on **main**, even though work-merge usually runs from the feature-branch worktree. Resolve before any read or write:

```bash
AKM_ROOT="$(akm-root)"
```

`akm-root` returns the main-worktree path (default branch); outside git, cwd. Anchor every AKM path on `$AKM_ROOT` (`$AKM_ROOT/docs/notes/spec/sp<NNN>.md`, `$AKM_ROOT/docs/notes/us<NNN>.md`, `$AKM_ROOT/docs/notes/im<NNN>.md`, `$AKM_ROOT/docs/board.md`, `$AKM_ROOT/docs/archive.md`). If `akm-root` errors, surface its stderr and abort — never silently flip the AKM lifecycle on the feature branch.

work-merge is a **transition skill that commits on main** per the AKM commit policy. The lifecycle archive flip (statuses + board → archive move) lands as one **AKM admin commit on main**:

```bash
git -C "$AKM_ROOT" add docs/notes/spec/sp<NNN>.md docs/notes/us<NNN>.md docs/notes/im<NNN>.md docs/board.md docs/archive.md
git -C "$AKM_ROOT" commit -m "feat(akm): archive sp<NNN>"
```

**This is NOT the code-merge.** work-merge does not merge code — the actual source code lands separately on the feature worktree via the chosen git landing option (local merge, PR, etc., see "Process — git landing options" below). The AKM admin commit above only flips AKM state and closes the bd epic; subsequent `git merge` / `git push` / `gh pr create` operate on the feature worktree's branch, not `$AKM_ROOT`.

Commit-message convention: `feat(akm): archive sp<NNN>`. See the per-stage commit table in `docs/notes/akm.md#workspace-resolution`.

## AKM hooks

Stage 7 of the AKM lifecycle (see `claude/akm/akm-lifecycle.md`). Status flips and archive move are the lifecycle-mandated writes; the git landing layer is the operational vehicle that gets the code into the base branch.

**Reads:**

- `sp###` — target spec at `status: ready`. Read frontmatter + the `## tasks` block so every `#### bd <id>` annotation can be verified closed.
- `us###` — the story this spec solves. Will flip `status: ready → done`.
- `im###` — the implementation this spec executes. Will flip `status: proposed → accepted`.
- bd state — every task under the spec's epic must be `closed`. If any is `open` / `in_progress` / `blocked`, block.

**Writes:**

- `$AKM_ROOT/docs/notes/spec/sp###.md` — flip frontmatter `status: ready → done`. Flip footer line `Index: [[board]]` → `Index: [[archive]]`.
- `$AKM_ROOT/docs/notes/us###.md` — flip frontmatter `status: ready → done`.
- `$AKM_ROOT/docs/notes/im###.md` — flip frontmatter `status: proposed → accepted`. Body narrative left alone (spec-retro owns the refresh).
- `$AKM_ROOT/docs/board.md` — remove the `[[sp###]]` line from `## ready`.
- `$AKM_ROOT/docs/archive.md` — add `[[sp###]]` under `## done` (chronological at the bottom).
- bd epic — close with summary reason (e.g., "Merged via sp###").

## Entry-specific checklist

1. **Resolve AKM root.** `AKM_ROOT="$(akm-root)"` — every AKM path anchors on it. Abort with the helper's stderr if it errors.
2. **Identify target spec.** User names a `sp###`. Verify `$AKM_ROOT/docs/notes/spec/sp###.md` exists.
3. **Verify status.** Must be `status: ready`. Apply Disambiguation if not.
4. **Verify bd children all closed.** `bd list --parent <epic-id>` or `bd dep tree <epic-id>` should show every child task `closed`. Any non-closed child blocks — work-audit didn't approve everything yet.
5. **Read the spec body** — `## solves [[us###]]`, `## implements [[im###]]`, `## tasks` (for bd id list).
6. **Run tests** in the feature branch / worktree. All green is the precondition for any of the subsequent writes. Failing tests block; route the user back to fix.
7. **AKM writes (atomic, on main):**
   - Flip `$AKM_ROOT/docs/notes/us###.md` frontmatter `status: ready → done`.
   - Flip `$AKM_ROOT/docs/notes/im###.md` frontmatter `status: proposed → accepted`. Leave body alone.
   - Flip `$AKM_ROOT/docs/notes/spec/sp###.md` frontmatter `status: ready → done`. Flip footer `Index: [[board]] → [[archive]]`.
   - Remove `[[sp###|<title>]]` from `$AKM_ROOT/docs/board.md ## ready`.
   - Add `[[sp###|<title>]]` under `$AKM_ROOT/docs/archive.md ## done`.
   - Close the bd epic via `bd close <epic-id> --reason "Merged via sp###. All N tasks closed by work-audit."`
8. **Commit on main (AKM admin commit).** Stage and commit the five touched AKM files in one shot — this is the lifecycle commit for the archive flip. Code merge happens separately in step 9.
   ```bash
   git -C "$AKM_ROOT" add docs/notes/spec/sp<NNN>.md docs/notes/us<NNN>.md docs/notes/im<NNN>.md docs/board.md docs/archive.md
   git -C "$AKM_ROOT" commit -m "feat(akm): archive sp<NNN>"
   ```
9. **Git landing (operational vehicle, on the feature worktree — NOT `$AKM_ROOT`):** present the 4-option menu to the user (Merge / PR / Keep / Discard). Execute the chosen path. This is where the actual code lands; the AKM admin commit in step 8 is separate.
10. **Worktree cleanup** where appropriate (Options 1 + 4).
11. **Hand off to `spec-retro`** with a one-line pointer — the user runs spec-retro next to refresh `im###` narrative + file any new ADRs / `ft###` updates / draft `us###`.

## Disambiguation

- **`sp###` does not exist** → block; nothing to merge.
- **`sp###` at `status: idea`** → route to `spec-writing` (no solution yet).
- **`sp###` at `status: spec`** → route to `spec-refinement` (no plan/tasks yet).
- **`sp###` at `status: done`** → already merged; nothing to do here. If the user wants narrative refresh, route to `spec-retro`.
- **bd children not all closed** → block; report which tasks are still `open` / `in_progress` / `blocked`. Route to `work-do` (for blocked or open) or `work-audit` (for in_progress with implementer evidence).
- **Tests failing on the feature branch** → block; route the user to fix before any AKM write. Do NOT do partial writes (status flip without tests passing leaves the system inconsistent).

## Key Principles (entry-specific)

- **AKM writes BEFORE git landing.** If you push first and the AKM writes fail later, the board lies about what's shipped. Status flip + archive move come first, in the same logical commit; git landing follows.
- **No partial state.** All AKM writes happen as one logical operation. If any step fails (file write, bd close), roll back rather than leave half-flipped state.
- **Spec-retro handles narrative, not status.** This skill flips statuses and moves entries; spec-retro rewrites the `im###` story to match shipped reality and files any new ADRs / `ft###` updates. Keep the two passes separate so neither slows the other.
- **Tests are a hard precondition.** Failing tests on the feature branch is a block — do not perform any AKM write against broken code. The board claims "done" should mean "shipped and green".
- **Don't mint zettels here.** New ADRs / new `us###` drafts / `ft###` revisions belong to spec-retro. work-merge is purely status + archive + landing.

## Process — git landing options

After AKM writes complete, present exactly these 4 options:

```
Implementation complete. AKM lifecycle flipped (sp### → done, board → archive).
How do you want the code to land?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (handle later)
4. Discard this work (rolls back the AKM writes too)

Which option?
```

### Option 1 — Merge locally

```bash
git checkout <base-branch>
git pull
git merge <feature-branch>
<test command>     # verify tests on merged result
git branch -d <feature-branch>
```

Cleanup worktree if applicable.

### Option 2 — Push + PR

```bash
git push -u origin <feature-branch>
gh pr create --title "<title>" --body "$(cat <<'EOF'
## Summary
<2-3 bullets>

Spec: $AKM_ROOT/docs/notes/spec/sp###.md
EOF
)"
```

Cleanup worktree if applicable.

### Option 3 — Keep as-is

Report: "Keeping branch <name>. Worktree preserved at <path>. AKM lifecycle has flipped to done — if the work isn't actually shipping, run Option 4 instead."

### Option 4 — Discard

**Requires typed "discard" confirmation.** Then:

```bash
git checkout <base-branch>
git branch -D <feature-branch>
```

**Rollback the AKM writes** (status flips, archive move, bd epic close) — discard means the work isn't shipping, so the board must reflect that. Confirm with the user which sp### status to restore (`ready` if the breakdown still applies, `spec` if the solution shape is wrong, etc). Revert the AKM admin commit on main:

```bash
git -C "$AKM_ROOT" revert HEAD   # reverts the feat(akm): archive sp<NNN> commit
```

Or edit the five files back to pre-flip state and `git -C "$AKM_ROOT" commit -m "feat(akm): unarchive sp<NNN>"` if a clean reverse is preferable to a revert.

## Integration

**Calls:**

- `bd list --parent <epic-id>` / `bd dep tree` — verify every child is closed.
- `bd close <epic-id> --reason "..."` — close the epic.
- `test-runner` agent — quality gate for tests before AKM writes.

**Called by:**

- `infinifu:plan-scrum-master` — after all pipeline tasks pass `work-audit`.
- `infinifu:plan-supervised` — after the final batch completes.
- Solo developer landing their own work after manual `work-audit`.

**Pairs with:**

- `infinifu:domain-git-worktrees` — for worktree cleanup.
- `infinifu:spec-retro` — the next step after Options 1 or 2; refreshes `im###` narrative + files new ADRs / `us###` drafts / `ft###` updates.

**Out of scope (do NOT call from here):**

- `spec-retro` for the archive move — work-merge owns the archive move per lifecycle.
- `implementation-write` / `adr-write` / `story-write` — narrative refresh belongs to spec-retro.
- Source code changes — work-merge does not edit `src/`.
