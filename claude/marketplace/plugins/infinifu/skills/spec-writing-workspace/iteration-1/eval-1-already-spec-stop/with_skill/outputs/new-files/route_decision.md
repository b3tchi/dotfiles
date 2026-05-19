# Route Decision — spec-writing on sp001

**Skill invoked:** `infinifu:spec-writing`
**Target:** `sp001` — rotate service credentials without downtime
**File:** `docs/notes/spec/sp001.md`

## Status check (skill step 2)

Read frontmatter of `docs/notes/spec/sp001.md`:

```yaml
---
aliases:
  - rotate service credentials without downtime
status: spec
created: 2026-04-28
---
```

**Actual status:** `spec`
**Required status for spec-writing:** `idea`

The spec is **not** at `status: idea`. Additional confirmation:

- `## solution` body section is already populated (vault-rotate-policy
  pattern via `[[ft002]]`, binds `[[adr0001]]` and `[[adr0002]]`).
- `docs/board.md` lists `[[sp001]]` under `## spec`, not `## idea`.

Both signals agree: the solution shape has already been chosen and
the spec has already been flipped `idea → spec`. spec-writing's
output (`## solution` + status flip) would duplicate work that is
already in the file.

## Disambiguation applied

From `SKILL.md` Disambiguation section:

> **`sp###` at `status: spec`** → solution already chosen. Route to
> `spec-refinement` to add `## plan` + `## tasks`.

## Decision

**Stop spec-writing. Route to `infinifu:spec-refinement`.**

spec-refinement is the next AKM lifecycle stage (3 of 5). It reads
the existing `## problem` + `## solution` and appends:

- `## plan` — file tree, conventions, anti-patterns
- `## tasks` — concrete subtask breakdown with dependencies

After spec-refinement, `spec-ready` will mint the bd epic + task ids
and promote the spec `spec → ready`, moving the board entry from
`## spec` to `## ready`.

## No writes performed

- `docs/notes/spec/sp001.md` — unchanged
- `docs/board.md` — unchanged
- No new zettels created
- Only this `route_decision.md` was emitted, per evaluation
  instructions
