# Run Notes — spec-writing eval (eval-1-already-spec-stop)

## Skill under test

`infinifu:spec-writing` — Stage 2 of AKM lifecycle. Expected to choose
the solution shape for a spec at `status: idea` whose `## problem` is
populated.

## Status check (skill step 2)

Read `docs/notes/spec/sp001.md` frontmatter:

```
status: spec
```

The spec is **already** at `status: spec`. The skill's own
Disambiguation section names this case explicitly:

> **`sp###` at `status: spec`** → solution already chosen. Route to
> `spec-refinement` to add `## plan` + `## tasks`.

Additional confirmation (cross-checks beyond the frontmatter):

- `## solution` body section is **populated** in `sp001.md` (lines 31-35):
  "Adopt the vault-rotate-policy pattern via [[ft002]]: writers stage
  the new credential under a versioned alias, readers fall back to the
  prior version for up to 5 minutes, then the alias flips. Binds
  [[adr0001]] and [[adr0002]]; no new ADR needed."
- `docs/board.md` lists `[[sp001]]` under `## spec`, **not** `## idea`.
  Both the body and the board agree the solution has been written and
  the lifecycle flip has happened.

## Decision

**Stopped spec-writing. Routed to `infinifu:spec-refinement`.**

Rationale: re-running spec-writing on a spec already at `status: spec`
would either (a) silently no-op or (b) wrongly re-flip and duplicate
`## solution`. Both violate the skill's own contract that the spec
"must already exist at `status: idea`". The correct next stage is
`spec-refinement` which appends `## plan` + `## tasks` against the
existing solution.

## Writes performed

- **New:** `route_decision.md` (sandbox root) — cites the actual
  status (`spec`) and names the correct next skill
  (`spec-refinement`).

## Writes NOT performed (deliberately)

- `docs/notes/spec/sp001.md` — untouched; no body or frontmatter
  changes.
- `docs/board.md` — untouched; board listing already correctly under
  `## spec`.
- No new zettels (no `im###`, no `adr####`, no `ft###`).
- No bd commands run.

## Skill evaluation

The spec-writing skill's Disambiguation section handled this cleanly
on the first read. The signal was unambiguous (frontmatter status,
body section presence, board placement all agreeing) and the
SKILL.md tells the agent exactly where to route. No ambiguity, no
recovery needed — this is the well-behaved "already past this
stage" case.
