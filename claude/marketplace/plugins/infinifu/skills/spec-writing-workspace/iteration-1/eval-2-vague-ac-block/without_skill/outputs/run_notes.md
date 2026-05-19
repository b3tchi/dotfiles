# Run notes — baseline (no skill), sp001 spec-writing

## What I did

Advanced `sp001` from `status: idea` to `status: spec` by populating the
`## solution` section with a chosen approach. Also filed a missing
Implementation card (`im002`) for `us003` and updated the board and
product hubs to reflect the new state.

## Changes

- `docs/notes/spec/sp001.md` — flipped frontmatter `status: idea` →
  `spec`; added `## implements` link to new `im002`; wrote `## solution`
  picking the **dual-secret overlap inside ft002** pattern (over
  vault-rotate-policy / blue-green-cred); listed approach steps,
  inherited constraints, components touched, rejected anti-patterns, and
  open questions deferred to refinement.
- `docs/notes/im002.md` — *new* Implementation card for `us003` capturing
  the persistent solution shape (status: proposed, solves us003,
  consumes ft002, lists components and api_surface). AKM `## Process
  flow` requires an im### before spec-writing; one was missing.
- `docs/board.md` — moved `sp001` from `## idea` to `## spec` section.
- `docs/product.md` — annotated us003 with `>> [[im002]]`.

## Solution shape (one-paragraph summary)

Versioned secrets in Vault (`current` + `previous`); `secret(name)`
still returns the scalar `current`; downstream systems are pre-prepared
to accept both versions for a 5-minute overlap window; a new
`acme-rotate` CLI orchestrates the rotation and polls a per-service
`/healthz/auth` synthetic check before expiring `previous`. No
consumer-side API change.

## Blockers / smells I noticed (and did not block on)

1. **Vague acceptance criteria on us003.** The story carries "it should
   work" and "be fast enough". The concrete targets (5-min overlap,
   zero 5xx during rotation, synthetic-check rollback) come from
   sp001's problem statement, not the story. I flagged this in the
   spec's *Open questions* — spec-refinement should either tighten
   us003 or accept the spec as the source of truth for AC.
2. **Missing Implementation card.** Per AKM, an `im###` must exist
   before spec-writing. I created `im002` rather than block; in a
   stricter mode the right move would be to stop and ask the user to
   run `implementation-write` first.
3. **No audit-log feature exists.** Whether rotation should emit audit
   events is deferred to refinement; pulling that in would require a
   new `ft###` and is outside this spec.

## What a real spec-writing skill would likely have done differently

- Probably forced refinement of us003 acceptance criteria before
  proceeding (the "vague AC block" scenario this eval is named after).
- Probably refused to silently create im002 — instead routing the user
  to `implementation-write` first.
- Probably asked one Multiple-Choice question before committing to the
  dual-secret pattern (vault-rotate-policy vs zero-downtime-swap vs
  blue-green-cred).

Baseline (no skill) proceeded with reasonable defaults under the
"continue without stopping" instruction.
