# Route Decision: spec-ready on sp001

## Verdict

**STOP — do not run `spec-ready` on `sp001`.**

No bd issues will be minted. No spec mutations will be made. No board move will occur.

## Evidence

Per `spec-ready` SKILL.md step 4 ("Confirm no `#### bd` annotations exist yet") and
the Disambiguation rule ("`sp###` at `status: spec` but tasks already carry `#### bd`
annotations → spec has been processed before"), the precondition for running this
skill is violated.

Inspection of `docs/notes/spec/sp001.md`:

- Frontmatter `status: spec` (matches the gate for entry).
- Every `### Task N` block in `## tasks` already carries a `#### bd` H4 property:
  - `### Task 1: Add rotate_secret helper to vault.py` → `#### bd\nbd-001`
  - `### Task 2: Add vault_rotate orchestration module` → `#### bd\nbd-002`
  - `### Task 3: Synthetic-check hook for rotation window` → `#### bd\nbd-003`

This is the exact "already processed" signature the skill is required to detect.

## Why this matters

If `spec-ready` ran anyway, it would:

1. Mint a duplicate bd epic + 3 duplicate child tasks (bd would issue fresh ids;
   the old `bd-001` / `bd-002` / `bd-003` annotations would diverge from the new
   real bd ids).
2. Append a second `#### bd <new-id>` line to each `### Task N`, leaving two
   conflicting bd-id annotations per task — neither readable by `work-do` nor
   recoverable without manual cleanup.
3. Flip `status: spec → ready` and move the board entry, freezing the divergent
   state into the lifecycle.

The atomic-operation principle in the skill ("If any step fails midway, roll back
rather than leaving partial state") applies *before* the first mutation here:
the precondition failed, so no mutation is taken.

## Routing options (per Disambiguation)

The skill names two exits for this state:

1. **Close the matter** — if `bd-001` / `bd-002` / `bd-003` are the real ids
   from a prior, valid run, the only thing missing is the `status` flip and the
   board move. Verify those bd ids exist (`bd show bd-001`, etc.) and finish the
   half-done transition by hand (frontmatter `spec → ready`, move the board
   bullet `## spec → ## ready`). Do **not** re-mint.
2. **Route to `work-do`** — if the existing annotations are correct and the spec
   is *meant* to be on the ready queue (i.e. it was already promoted and the
   status/board edits were missed), the next stage is execution. Hand each
   `bd-00N` to `work-do` rather than re-running `spec-ready`.

In this evaluation sandbox the bd ids `bd-001` / `bd-002` / `bd-003` are
placeholder-shaped (sequential, no project prefix) and `bd list` shows an empty
queue — so option 1 (close the matter / treat as a placeholder seed) is the
likely real-world fit, but the choice belongs to a human operator, not this
skill run.

## What I did not do

- No `bd init` (sandbox already has `.beads/`).
- No `bd create` (would create duplicates).
- No `bd dep add` (depends on duplicates that won't be created).
- No edit to `docs/notes/spec/sp001.md` (status stays `spec`; bd annotations
  untouched).
- No edit to `docs/board.md` (bullet stays under `## spec`).
- No source-code changes (out of scope for spec-ready regardless).
