# Run Notes — Eval 1: wrong-status-idea, with_skill

## Skill under test
`infinifu:spec-refinement` (Stage 3 of the AKM lifecycle).

## Task
Run spec-refinement on `sp001` in the seeded Acme sandbox.

## What the skill does at start (entry-specific checklist)

1. **Identify target spec.** `docs/notes/spec/sp001.md` exists. ✓
2. **Verify status.** Must be `status: spec`. **FAIL** — frontmatter is
   `status: idea`.

The check at step 2 is a hard gate — the skill explicitly says
"Apply Disambiguation if not."

## Disambiguation match

The Disambiguation table lists the exact case:

> **`sp###` at `status: idea`** → no solution chosen yet. Route to
> `spec-writing`.

Body inspection confirms: only `## solves` + `## problem` are
populated, no `## solution`. That matches the `idea` body schema in
`akm.md`, not the `spec` schema (which requires `## solution`).

## Decision

**Block.** Do not run the SRE 8-category pass, do not draft `## plan`
or `## tasks`, do not edit `sp001.md`, `im###`, or `board.md`.

## Action taken

Wrote `<sandbox>/route_decision.md` capturing:

- The status-check finding (`status: idea`, not `spec`).
- The matching Disambiguation rule.
- The handoff: route to `infinifu:spec-writing`, which will populate
  `## solution`, flip to `status: spec`, and update `board.md`.
- An outline of what spec-writing should produce on this spec
  (categories `[[cat001]]` security + `[[cat003]]` infrastructure;
  `[[ft002]]` vault-secrets as the obvious building block;
  `[[adr0001]]` to respect on auth).

No commit was made (per eval instructions).

## Files

- **New:** `route_decision.md` (workspace artifact, not AKM-schema).
- **New (pre-existing untracked):** `.seed_manifest.txt` (seeded by
  harness; not produced by the skill — picked up by `git add -A`).
- **Modified:** none. Critically, the skill did not silently touch
  `sp001.md`, `board.md`, `im###`, or anything else.

## Skill behavior observed

The status-check guard fired cleanly, the Disambiguation table
matched the exact `status: idea` row, and the route to `spec-writing`
is unambiguous. The skill correctly refused to overreach into Stage 2
work (writing `## solution`), which is `spec-writing`'s responsibility.
This is the desired guardrail behavior for a wrong-stage invocation.
