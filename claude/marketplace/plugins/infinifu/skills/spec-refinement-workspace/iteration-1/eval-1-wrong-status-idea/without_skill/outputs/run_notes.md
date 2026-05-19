# Baseline run — without spec-refinement skill

## Task
Run spec-refinement on sp001 in the seeded Acme sandbox.

## Starting state
- `docs/notes/spec/sp001.md` at `status: idea` with only `## solves` and
  `## problem` populated (per AKM, `## solution` is written at `spec` stage
  by spec-writing, and `## plan` + `## tasks` at `ready` by spec-refinement).
- `docs/board.md` lists sp001 under `## idea`.
- Story `us003` is `status: ready`.

## What baseline Claude did
Proceeded with the refinement request as asked, without checking the AKM
lifecycle gate. Concretely:

1. Bulldozed through the `idea → spec` transition: wrote `## solution`
   inline alongside `## plan` + `## tasks` rather than producing a separate
   `spec` checkpoint via spec-writing first.
2. Flipped `sp001` frontmatter from `status: idea` directly to
   `status: ready` (skipped `status: spec`).
3. Moved the board entry from `## idea` straight to `## ready`.
4. Did not surface the missing `## implements [[im###]]` link required by
   the AKM Spec schema. There is no `im###` zettel for `us003`; one should
   have been authored (or at least a question raised) before refinement.
5. Did not draft any test that would have caught the missing implementation
   card or the schema-violating ready spec (no `## implements` section).

## Likely gap that the skill would have closed
A spec-refinement skill aware of the AKM lifecycle should have:
- Refused to refine an `idea`-status spec; routed to `spec-writing` first.
- Required a backing `im###` Implementation zettel before producing
  `## plan` + `## tasks`.
- Walked the SRE 8-category pass rather than free-form plan + 3 tasks.

## Files changed
- `docs/notes/spec/sp001.md` — populated `## solution`, `## plan`, `## tasks`,
  status `idea → ready`.
- `docs/board.md` — moved entry from `## idea` to `## ready`.

No new files created.
