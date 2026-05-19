# Run notes — eval 3, without_skill (baseline)

## Task

Run spec-writing on `sp001` (status: idea) in the Acme sandbox without using
the `infinifu:spec-writing` skill.

## Key finding

`docs/notes/im002.md` already exists for the same story (`us003`) with
`status: accepted`. The AKM doc states "a story should not be specced
until an implementation card exists for it" — one already does, and it
has already chosen the **vault-rotate-policy** pattern. The right move
at spec-writing stage is to reference `im002` via `## implements`, not
to mint a new `im###`.

## Changes

1. `docs/notes/spec/sp001.md`
   - frontmatter `status: idea` → `status: spec`
   - added `## implements [[im002|vault-policy credential rotation for live services]]`
   - added `## solution` section grounded in im002 + ft002 + adr0001 + adr0002,
     mapped to us003 acceptance criteria, scoped out adr0003 / SSO / vault DR.

2. `docs/notes/im002.md`
   - `## specs` list updated from placeholder to `[[sp001|…]]` back-link.

3. `docs/board.md`
   - moved `sp001` from `## idea` to `## spec`, updated header sentence.

## Files not changed

- No new `im###` was minted (dedup against the existing accepted im002).
- No new ADRs / Features / Categories.
- No source code touched — `## plan` / `## tasks` belong to later stages
  (spec-refinement / spec-ready), not spec-writing.

## Anti-pattern avoided

Spawning a new `im003` "rotate-secret implementation" duplicating im002.
The seed appears designed to test exactly this dedup trap: sp001's
`## problem` body invites a pattern choice across three options, but
im002 already locked in `vault-rotate-policy`.
