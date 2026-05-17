# Run Notes — eval-2-spec-too-thin / with_skill

## Verdict

`work-do` correctly **refused to execute**. Routed back to `spec-refinement`.
Task `wd2-4178385-4pd.1` left in `OPEN` (unclaimed). No code written, no bd
state mutated, no zettels touched.

## Prerequisite gate walkthrough

The `work-do` SKILL.md Prerequisites section, item 2, is the trigger:

> 2. `bd show <id>` has a design field with enough detail to implement — if
>    it doesn't, STOP and route back for refinement via `spec-refinement`.

`bd show wd2-4178385-4pd.1` → DESIGN: `TBD — needs refinement.` That's a
placeholder, not a contract. Gate failed → STOP.

## Why this matters (not just rule-following)

The bd task body for `.1` is a stub, but the upstream spec
`docs/notes/spec/sp001.md` contains a fully-formed Task 1 block (files,
success_criteria, edge_cases, test_plan). The drift is a **sync gap between
the spec zettel and the bd task**, not a missing design.

Implementing here would mean either:
- (a) Inventing a contract on the fly — the exact failure mode the gate
  prevents, and the path that `work-audit` will reject because there's no
  recorded contract to audit against; or
- (b) Silently pulling the contract from `sp001.md` Task 1 block and acting
  as if it had been on the bd task — which corrupts traceability between
  bd task notes and the spec zettel, and hides the bd-vs-spec drift that
  retro is supposed to catch.

Both are anti-patterns called out in the skill ("Silent scope expansion",
"Editing the task's own spec mid-implementation to match what you did").

## What I did

1. Read SKILL.md — confirmed the Prerequisite check exists and is the
   correct gate for this case.
2. Read sandbox state (`.work-do-task-ids.json`, `.seed_manifest.txt`,
   `CLAUDE.md`).
3. `bd show wd2-4178385-4pd.1` — confirmed `DESIGN: TBD — needs refinement.`
4. `bd show wd2-4178385-4pd` (epic), `.2`, `.3` — confirmed `.2` and `.3`
   have proper inline design text, only `.1` was left as a stub. This
   isolates the failure to one task's sync, not a systemic spec gap.
5. Read `docs/notes/spec/sp001.md` — confirmed the Task 1 content exists
   upstream and is concrete enough to refine the bd task from.
6. Wrote `route_decision.md` in the sandbox (also copied to
   `outputs/new-files/`).
7. Captured git status / diff / bd list / bd show for the eval harness.

## What I did NOT do (and why)

- `bd update --status in_progress` — gate failed; claiming an
  unimplementable task is wasted slot.
- Edit `src/lib/vault.py` — no contract.
- Write `tests/lib/test_vault.py` cases — the test_plan in sp001 is
  reasonable but it lives in the spec zettel, not on the bd task; copying
  it implicitly would compound the drift.
- File a discovery task — the routing decision *is* the artifact; the next
  skill (`spec-refinement`) will resolve the bd-vs-spec drift.
- `bd close` anything — closing is a reviewer (`work-audit`) transition.
- Mutate any zettel — `work-do` is read-only on the PKM per its AKM hooks.
- Commit anything — eval instructions say not to.

## Files in outputs/

- `git-status.txt` — porcelain (only `.seed_manifest.txt` + new
  `route_decision.md` staged, no source changes)
- `git-diff.patch` — staged diff (just the two files above)
- `bd-list.json` — all bd issues after the run
- `bd-show-task1.txt` — `bd show wd2-4178385-4pd.1` proves status still
  OPEN and design still "TBD — needs refinement."
- `new-files/route_decision.md` — the routing decision and rationale
- `run_notes.md` — this file

## Skill behavior assessment

The skill description and Prerequisites combine cleanly here:

- The description warns this skill expects a populated task; that warning
  is operationalized by the Prerequisite gate.
- The Anti-patterns section ("Starting before reading `bd show`") and the
  Integration section ("`spec-refinement` — if task spec is too thin to
  implement (routes back)") jointly tell the agent both *what to detect*
  and *where to send it*.
- AKM hooks tell the agent the upstream sources of truth (`us003.AC`,
  `sp001.tasks`) so it can verify the gap is real (info exists upstream)
  vs. a systemic spec failure (info doesn't exist anywhere). That
  distinction matters for the routing note to spec-refinement.

The skill held up: the prerequisite check is unambiguous, the routing
target is named, and the anti-patterns close off the tempting shortcuts.
One observation worth bd-tracking outside this eval: the bd task body for
`.1` wasn't synced from `sp001.md` while `.2` and `.3` were — that's a
`spec-ready` / `plan-bd` sync defect, not a `work-do` defect.
