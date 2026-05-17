# Run Notes — eval-1-already-ready-stop / with_skill

## Verdict

**spec-ready correctly stopped before any mutation.** Both disambiguation gates fired (`status: ready` + tasks already annotated with `#### bd`), and the skill explicitly routes both conditions to `work-do`. No bd calls, no spec edits, no board edits.

## Evidence path

1. Read `SKILL.md` for spec-ready.
2. Read seed: `docs/notes/akm.md`, `docs/board.md`, `docs/notes/spec/sp001.md`.
3. Status-check (skill checklist step 2): `sp001.status` is `ready`, not `spec`. **FAIL.**
4. Annotation-check (skill checklist step 4): all three `### Task N` blocks already carry `#### bd` lines (`bd-001`, `bd-002`, `bd-003`). **FAIL.**
5. Cross-referenced disambiguation table — both failures land on `work-do`.
6. Wrote `route_decision.md` documenting the stop + recommendation.

## Observed sandbox state (background)

- `docs/board.md` already lists `[[sp001]]` under `## ready` (not `## spec`), matching the spec's frontmatter — consistent with a prior spec-ready run.
- `bd list` shows partial state: epic `sandbox-nt2` + one child `sandbox-nt2.1` (Task 1 only). Tasks 2 + 3 are missing in bd. Spec annotations use stale placeholder ids (`bd-001/002/003`) that don't match the real bd ids (`sandbox-nt2.x`). This is a smell from the prior partial run, but it is **not** spec-ready's job to reconcile — re-running the skill would only make duplication worse.

## What this proves about the skill

- The Disambiguation section is *load-bearing*. It catches the "already processed" case cleanly with two independent signals (status flag + annotation presence), so a single missed signal still gates correctly.
- The "Atomic operation" + "No execution" principles motivate the stop: spec-ready has no idempotency on `bd create`, so re-running on a ready spec is unsafe by design.
- The skill does *not* attempt to repair a partial prior run — and that is the right call. Repair belongs to either manual reconciliation or `spec-refinement`, both explicitly listed as adjacent scopes the skill defers to.

## Artifacts produced in sandbox

- `route_decision.md` (new file at sandbox root) — only artifact.

## Artifacts NOT produced (correct non-actions)

- No mutation of `docs/notes/spec/sp001.md` (no annotation churn, no status flip).
- No mutation of `docs/board.md` (no spurious section move).
- No new `bd create`, no `bd dep add`.

## Outputs captured

- `outputs/git-status.txt` — two `A` entries: `.seed_manifest.txt` (pre-existing untracked seed file) + `route_decision.md` (the decision artifact). No `M` rows for any spec/board file — confirming no in-place mutations.
- `outputs/git-diff.patch` — diff of staged additions (the two A files).
- `outputs/bd-list.json` — bd state captured *after* the run, identical to pre-run state (still the same `sandbox-nt2` + `sandbox-nt2.1`).
- `outputs/new-files/route_decision.md` — copy of the decision artifact.
- `outputs/modified-files/` — empty (no in-place modifications, by design).

## No commit made

Per the eval protocol, the run captures `git add -A` state but does not commit.
