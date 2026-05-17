# Baseline run — no skill loaded

## Task
Run `idea-implement` on `us001` (view dashboard of recent reports) in the seeded Acme sandbox. Skill is unavailable; respond naturally.

## Inspection findings
- `docs/notes/us001.md`: `status: done`, mapped on `docs/product.md` as `[[us001]] >> [[im001]]`.
- `docs/notes/im001.md`: `status: accepted`, `solves [[us001]]`, components `src/services/reports/dashboard.py` + `src/services/reports/templates/dashboard.html`.
- `src/services/reports/` only has `__init__.py` — code stubs only; this is normal for the seed and not a hotfix trigger here.
- `docs/board.md` is empty (no in-flight specs).

## Decision
Reject the request. `idea-implement` is the entry point for a *new* user-facing behavior the system doesn't yet have. `us001` is already an existing story with `status: done` and an accepted implementation `im001`. Creating a fresh `us###` / `sp###` would duplicate the backlog and corrupt the AKM lifecycle.

Routing options surfaced to the user:
- If they want to **change** the dashboard's behavior → `idea-extend` (modifies the existing us001 + im001).
- If the dashboard is **broken in production** → `idea-hotfix` (problem capture for the shipped code).
- If they want to **review what shipped** → `story-read us001` and `implementation-read im001`.

## Actions taken in the sandbox
None. No notes added, no spec created, no source modified. Only the pre-existing untracked `.seed_manifest.txt` was staged by the post-task `git add -A` step.

## Files
- New: none
- Modified: none
