# spec-ready route decision — sp001

## Verdict

**BLOCK. Route to `infinifu:spec-refinement`.**

`spec-ready` cannot proceed on `sp001`. Per the skill's Disambiguation
rule (SKILL.md line 69):

> `sp###` at `status: spec` but `## tasks` missing or incomplete →
> route to `spec-refinement`. spec-ready cannot invent tasks.

## Evidence

Read of `docs/notes/spec/sp001.md`:

- Frontmatter: `status: spec` (correct stage for spec-ready *if* tasks
  existed).
- Body sections present: `## solves`, `## implements`, `## problem`,
  `## solution`.
- Body sections **absent**: `## plan`, `## tasks`.
- Number of `### Task N` blocks: **0**.
- Number of `#### bd <id>` annotations: **0** (vacuously — no tasks to
  carry them).

The AKM schema (`docs/notes/akm.md` Spec section) is explicit that
`## plan` lands at refinement and `## tasks` is populated with the
H3/H4 breakdown *before* spec-ready attaches bd ids. Neither has been
written, so the precondition spec-ready depends on — "an
already-written task breakdown" (SKILL.md Overview, Key Principles) —
is not met.

## What was NOT done (deliberately)

Per the skill's own Key Principles ("Tasks come from `## tasks`, not
from invention") and Out-of-scope contract ("Writing or revising
`## tasks` content — that's `spec-refinement`"):

- No `bd init` re-run, no `bd create` (epic or task) issued.
- No edits to `docs/notes/spec/sp001.md` — frontmatter status stayed
  `spec`, body untouched.
- No edits to `docs/board.md` — `[[sp001]]` stayed under `## spec`,
  not moved to `## ready`.
- No `#### bd` annotations invented.
- No dependency wiring attempted.

Rolling forward with invented tasks would violate the atomicity
principle (SKILL.md Key Principles: "Atomic operation … If any step
fails midway, roll back rather than leaving partial state.") and
would produce a fabricated task list with no design rationale behind
it — the exact failure mode `spec-refinement` exists to prevent.

## Required next step

Invoke `infinifu:spec-refinement` against `sp001`. That skill will:

1. Read `## problem` + `## solution` already present.
2. Run the SRE 8-category pass to produce `## plan` (file tree,
   conventions, anti-patterns, known limitations).
3. Decompose into `### Task N` blocks with the full H4 property set
   (`#### type`, `#### effort`, `#### depends`, `#### files_touched`,
   `#### success_criteria`, `#### edge_cases`, `#### test_plan`).
4. Hand back to the user for approval.

Only after that lands does `spec-ready` have something to bd-ify.
