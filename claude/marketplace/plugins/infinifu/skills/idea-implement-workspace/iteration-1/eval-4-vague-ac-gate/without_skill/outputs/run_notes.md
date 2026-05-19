# Baseline run — no idea-implement skill

## Task
Move `us004` (draft, "search reports somehow") forward via the AKM workflow.

## State at start
- `us004` status: `draft`, acceptance criteria were "it works" / "fast enough" — vague, not testable.
- Sandbox already has the `[[reports-flow]]` story chain: `us001` (done, dashboard) with `im001`, `us002` (ready).
- Available primitives: `ft001` basic-auth, `cat001/002/003`, `adr0001`/`adr0002` (90-day retention) — relevant constraints.
- Board empty.

## Actions taken
Used the AKM "Process flow — implementing a Story" steps from `docs/notes/akm.md`:

1. **Refined `us004` acceptance criteria** (draft → ready). Replaced vague AC with seven concrete, testable items: substring title search, optional date range, server-side query against the full 90-day window, p95 ≤ 500 ms, unchanged behavior when params empty, auth-gated (ft001), aligns with `adr0002` retention.
2. **Minted `im002`** (proposed) — extends `im001`'s `/dashboard` route with `q`/`from`/`to` query params, ILIKE + range over `report_runs`, two new indexes (B-tree `run_at`, GIN trigram on `title`). Categories `cat002` data, `cat003` infrastructure. Consumes `ft001`.
3. **Created `sp001`** (idea) on the board — `## problem` populated per AKM idea-stage schema; `solves: us004`, `implements: im002`.
4. **Updated hubs** — `product.md` lists `us004 >> im002` under analyst; `board.md` lists `sp001` under `## idea`.

## What was *not* done (per AKM)
- Did not write `## solution` / `## plan` / `## tasks` on the spec — those land at the `spec` / `ready` lifecycle stages, not at `idea`.
- Did not create a bd epic — bd entry happens at `spec-ready`, after refinement.
- Did not touch any source code under `src/services/reports/` — implementation work follows spec ready, not idea.

## Files
- New: `docs/notes/im002.md`, `docs/notes/spec/sp001.md`
- Modified: `docs/notes/us004.md`, `docs/board.md`, `docs/product.md`
- (`.seed_manifest.txt` was untracked; got staged by `git add -A` — incidental, not intentional content.)

## Reasoning notes
The user said "let's run idea-implement to move it forward". The story was in `draft` with non-testable AC, so the first AKM gate (re-read acceptance_criteria; refine before moving on) had to fire before any implementation framing. After refining, the next steps in the AKM flow are: define categories, mint the implementation zettel, survey ADRs/features, prepare a spec — which is exactly what landed.
