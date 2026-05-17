# Run notes — sp001 spec-refinement (baseline, no skill)

## What I did
Refined `sp001` from `status: spec` to `status: ready` by adding `## plan` +
`## tasks`, per the AKM Spec schema in `docs/notes/akm.md`. Updated
`docs/board.md` to move sp001 from `## spec` to `## ready`, and added the
back-link from `docs/notes/im002.md` `## specs` → `[[sp001]]`.

## Refinement findings (scope drift caught)
The spec body carried two creep additions from spec-writing that did not
belong in this story:

1. **`vault.set_default_ttl(seconds=300)` global mutator** — would widen
   the stable `ft002` Feature contract for a single consumer, introduce
   hidden module-level state, and is unnecessary because per-call TTL
   covers every real use case. Rejected and documented in
   `## plan → Out of scope`. Tasks instead carry `ttl_seconds=300` as a
   per-call argument with explicit `ValueError` on `<= 0`.

2. **Audit-log channel bolted onto `ft002`** — `ft002` currently has no
   audit-log surface; extending it for one consumer is exactly the
   Feature-widening anti-pattern. Replaced with structured-logging line
   emitted by `rotate_secret` itself (already-in-use JSON log format).
   If a real cross-cutting audit-log story emerges (e.g. `us005`),
   *that* is the moment to mint an audit-log Feature.

Both rejections preserved in the spec body under
`## plan → Out of scope` so the decision trail is visible.

## Tasks emitted
5 tasks, total ~9.5h, all ≤3h. Dependencies form a DAG:
T1 (vault helper) → T2 (audit log) / T3 (CLI) / T4 (overlap test) → T5 (zettel hygiene).

## Files
- Modified: `docs/notes/spec/sp001.md` (status spec→ready, plan + 5 tasks)
- Modified: `docs/board.md` (sp001 moved spec→ready)
- Modified: `docs/notes/im002.md` (specs back-link populated)
- New: none
- The `.seed_manifest.txt` line in `git status --porcelain` is a
  pre-existing untracked seed file, not authored in this run.

## Not done (would normally be next steps)
- `spec-ready` would attach `bd` task ids under each `#### bd` section
  and create the bd epic — out of scope for *refinement* per the AKM
  lifecycle (refinement is the SRE-pass that lands plan + tasks; bd
  carving is a separate skill).
