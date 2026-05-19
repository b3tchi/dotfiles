# Route Decision: spec-retro on sp001

**Decision:** Route back to `work-merge`. Do NOT run spec-retro.

## Evidence

| Check | Expected (spec-retro precondition) | Actual | Pass |
|---|---|---|---|
| `sp001` frontmatter `status:` | `done` | `ready` | NO |
| Board placement of `[[sp001]]` | absent from `docs/board.md` | listed under `docs/board.md ## ready` | NO |
| Archive placement of `[[sp001]]` | listed under `docs/archive.md ## done` | absent (`## done` is empty) | NO |
| bd epic `wd2-266312-i5s` status | closed | open | NO |
| Merge commit on branch | merge commit landed by work-merge | only `ship sp001: rotate_secret + alias bookkeeping` exists on a single linear branch (`master`), no merge | NO |

## Disambiguation rule matched

From `infinifu:spec-retro` SKILL.md, "Disambiguation" section:

> - **`sp###` at `status: idea` / `spec` / `ready`** → route back to the appropriate stage; spec-retro is post-merge only.
> - **`sp###` at `status: done` but board entry still on `docs/board.md ## ready`** → work-merge didn't finish its archive move; route back to `work-merge`.

`sp001` is at `status: ready` AND the board entry is still under `## ready` AND the bd epic is open. This is a `work-merge` did-not-run / did-not-finish situation. Spec-retro is Stage 8 (post-merge) — it has no precondition satisfied here.

## What spec-retro will NOT do (per "Out of scope" + "Key Principles")

- Will NOT flip `sp001.status` from `ready` to `done` — that is work-merge's job.
- Will NOT move `[[sp001]]` from `docs/board.md ## ready` to `docs/archive.md ## done` — work-merge's job.
- Will NOT close bd epic `wd2-266312-i5s` — premature; retro closes only after the four lifecycle writes, which themselves require a shipped diff to compare against.
- Will NOT rewrite `im002` body — the `## approach` / `## components` / `## data_model` / `## api_surface` rewrite uses the shipped diff as ground truth; without work-merge landing, there is no merge-base to diff against.
- Will NOT touch `ft001` / `ft002` — feature surface widening must be observed in shipped code.
- Will NOT mint new `adr####` — decisions that shifted during execution are discovered by diffing shipped vs spec; without a shipped state there is nothing to compare.
- Will NOT draft new `us###` for follow-up scope — discoveries are mined from closed bd task notes, which require the epic's tasks to be closed first.

## Recommended next action for the user

Run `infinifu:work-merge` on the `sp001` branch. It will:

1. Verify tests green (its precondition).
2. Land the branch (Option 1 local merge, or Option 2 PR).
3. Flip `us003.status`, `im002.status: accepted`, `sp001.status: done`.
4. Move `[[sp001]]` line from `docs/board.md ## ready` to `docs/archive.md ## done`.
5. Hand off to `spec-retro` once the merge commit exists and statuses are flipped.

Only after work-merge completes should spec-retro re-run.
