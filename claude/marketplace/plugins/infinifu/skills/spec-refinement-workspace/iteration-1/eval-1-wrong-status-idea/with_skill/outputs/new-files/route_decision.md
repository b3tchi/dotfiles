# Route Decision — spec-refinement on sp001

## Announcement

Using spec-refinement skill — SRE 8-category pass + ADR/Feature sanity.

## Status-check result

**BLOCKED — wrong lifecycle stage.**

`docs/notes/spec/sp001.md` frontmatter reports:

```yaml
status: idea
```

`spec-refinement` requires `status: spec` (per the skill's Entry-specific
checklist step 2 — *Verify status. Must be `status: spec`. Apply
Disambiguation if not.*).

## Body inspection (corroborates the frontmatter)

The body of `sp001.md` only contains:

- `## solves` → `[[us003]]`
- `## problem` (populated — captured during idea-brainstorming)

There is no `## solution` section. The skill's Disambiguation rule for
the closely related case is explicit:

> **`sp###` at `status: spec` but `## solution` missing/empty** → block.
> Route back to `spec-writing` to populate solution first.

Here we are one stage earlier — `status: idea`, body matches the
`idea` schema (only `## problem`). The exact Disambiguation row that
applies:

> **`sp###` at `status: idea`** → no solution chosen yet. Route to
> `spec-writing`.

## Decision

**Do NOT run the SRE 8-category pass. Do NOT draft `## plan` or
`## tasks`. Do NOT touch `sp001.md`, `im###`, `board.md`, or any other
file.** Spec-refinement is Stage 3 of the AKM lifecycle; Stage 2
(spec-writing) has not yet produced a `## solution`, so there is
nothing to refine into a plan + task breakdown.

## Next step (handoff)

Route the user to **`infinifu:spec-writing`** on `sp001`. That skill
will:

- Re-read `us003.acceptance_criteria` ([[us003]] is the source story).
- Survey ADRs under `[[cat001]]` (security) and `[[cat003]]`
  (infrastructure) — the H1 categories carried on `sp001` — for binding
  decisions (e.g. [[adr0001]] mandates ft001 basic-auth).
- Survey Features for reusable building blocks ([[ft001]] basic-auth,
  [[ft002]] vault-secrets — the latter is the obvious candidate for
  credential rotation).
- Either consume an existing `[[im###]]` or mint a new one for the
  rotation solution shape, then back-link it from `sp001.## implements`.
- Write `## solution` into `sp001.md`, flip `status: idea` → `status: spec`,
  and move the entry in `docs/board.md` from `## idea` to `## spec`.

Once `sp001` is at `status: spec` with `## solution` populated and an
`[[im###]]` referenced, `spec-refinement` can take over and produce
`## plan` + `## tasks` per the SRE 8-category discipline.

## Files touched by this skill invocation

None. The status-check gate fired before any edit was authorized.
This `route_decision.md` is a workspace artifact for the evaluation
harness, not part of the AKM schema.
