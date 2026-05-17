# Run notes — eval-3-nothing-to-harvest / without_skill

Task: "sp001 just merged. Run spec-retro on sp001."

## Approach (no skill loaded)

Treated spec-retro as: validate what shipped against the spec/plan, capture
gaps as bd follow-ups, close the epic with a frank reason, write retro
findings into the spec, do NOT mutate process docs that would mask the gaps.

## Starting state

- Branch: `master`, single commit `0f36495 ship sp001: rotate_secret + alias bookkeeping`
- `docs/notes/spec/sp001.md` already `status: done`; already listed under `docs/archive.md`
- bd epic `wd3-269652-cdv` still OPEN, all 3 child tasks CLOSED with "AUDITED: APPROVED"
- `docs/board.md` empty (correct — nothing in flight)
- Tests pass: 5/5 in `tests/lib/test_vault.py`

## Findings (real gaps)

Compared spec plan/tasks vs what's on disk + bd close reasons:

| Task | bd status | Reality |
|---|---|---|
| 1 — `rotate_secret` helper | closed APPROVED | shipped, tests pass; **but `test_vault_unreachable_raises` from plan missing** |
| 2 — `vault_rotate.py` orchestration | closed APPROVED | **file does not exist on disk** |
| 3 — synthetic-check hook + integration test | closed APPROVED | **`vault_rotate.py` missing, `tests/integration/test_rotate_synthetic.py` missing** |

Acceptance-criteria check against us003:
- "Swap secrets while running" — partial (helper only, no orchestration)
- "Old secret stays valid 5min" — NOT MET (no expiry scheduler)
- "No 5xx during rotation in synthetic check" — NOT MET (no synthetic check)

Also: stray `# TODO: set_timeout(...)` left in `src/lib/vault.py` (unrelated
to sp001 scope).

Process finding: the work-audit pass approved Tasks 2 and 3 without
verifying the deliverable files existed. Captured in retro notes.

## Actions taken

1. Filed 4 follow-up bd issues:
   - `wd3-269652-eom` (P1) — missing `vault_rotate.py`
   - `wd3-269652-l16` (P1) — missing integration test
   - `wd3-269652-g11` (P2) — missing `test_vault_unreachable_raises`
   - `wd3-269652-qxc` (P3) — stray `set_timeout` TODO
2. Closed epic `wd3-269652-cdv` with explicit close reason referencing the
   four follow-ups and naming Task 1 as the only fully-shipped task.
3. Edited `docs/notes/spec/sp001.md` to add a `## retro` section before
   the `Index: [[archive]]` footer — captures shipped vs gaps, AC status,
   process finding, and rationale for keeping spec status `done`.

## Deliberate non-actions

- Did NOT reopen the closed child tasks — gap work is more naturally a fresh
  workstream (likely a new spec) than reanimating the old audit trail.
- Did NOT remove sp001 from `docs/archive.md` — it represents the closed
  workstream; new work lives under follow-up issues / a future spec.
- Did NOT add `>> [[im002]]` link on `us003` in `product.md` because the
  implementation is materially incomplete; that link should land with the
  follow-up work.
- Did NOT alter im002 status (`accepted`) — that's the design record, still
  valid as the design even though execution missed.
- Did NOT touch `docs/board.md` — it's empty/correct.
- Did NOT commit (per instructions).

## Files written / modified

- MODIFIED: `docs/notes/spec/sp001.md` (added `## retro` block)
- bd db: 4 new issues + 1 epic close transition

## Outputs

- `git-status.txt` — staged porcelain status
- `git-diff.patch` — full staged diff
- `bd-list.json` — final issue list
- `bd-show-epic.txt` — closed epic detail
- `changed/docs/notes/spec/sp001.md` — modified spec with retro section
