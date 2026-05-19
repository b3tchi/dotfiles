# Run notes — eval-2-route-to-implement-single-consumer / without_skill

## Task
"Add a quarterly retention purge tool — only the platform-engineer
persona uses it, and only once a quarter when legal asks for the
deletion proof. Use the infinifu:idea-feature skill."

## Skill availability
The `infinifu:idea-feature` skill was unavailable in this run, so I
worked from the AKM model directly (`docs/notes/akm.md`).

## Routing call (the load-bearing decision)
The request *named* `idea-feature`, but the shape described is:

- single consumer (`pn002` platform-engineer only)
- once-a-quarter cadence
- wraps the existing retention rule (`adr0002`) rather than a new
  horizontal capability

That is a vertical user-story flow, not a horizontal reusable
capability. Per the AKM `Feature — ft###.md` definition ("decoupled
from stories on purpose: a feature is a building block, not a
deliverable... many Implementations consume"), minting `ft###`
here would be wrong — there is no second consumer in sight and the
"feature" would just be the story itself in disguise.

So I routed to the `idea-implement` shape instead: a fresh user
story (`us###`) plus a board-stage spec (`sp###`) at `status: idea`
with `## problem` populated. Spec-writing is the right place to
confirm or pivot before any `ft###` is minted.

I called this out explicitly in `sp001.md`'s `## problem` so the
next agent/human sees the routing reasoning.

## Artifacts written

### New
- `docs/notes/us004.md` — story for the platform-engineer want,
  status `draft`, acceptance criteria covering on-demand invocation,
  deletion proof, reproducibility, and operator-only access.
- `docs/notes/spec/sp001.md` — spec at `status: idea` with
  `## problem` populated, scope notes (initial table `report_runs`),
  out-of-scope list, and open questions for the spec stage.

### Modified
- `docs/product.md` — added `us004` under `pn002` per AKM hub rules.
- `docs/board.md` — added `sp001` under `## idea`.

## What I did NOT do
- No `ft###` minted (premature — wait for the spec stage to confirm
  reuse).
- No `im###` minted (idea stage; implementation cards are written
  *after* problem clarification, *before* spec-writing).
- No code under `src/` (idea stage; problem-only).
- No `adr####` (no new architectural decision yet; the work is
  bounded by the existing `adr0002`).
- No bd epic / tasks (that's the spec-ready stage, not idea).
