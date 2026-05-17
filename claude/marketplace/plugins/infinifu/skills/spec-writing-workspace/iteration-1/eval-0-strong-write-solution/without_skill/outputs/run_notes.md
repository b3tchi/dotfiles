# Run notes — sp001 spec-writing (no skill loaded)

## What was done

Advanced `sp001` from `idea` → `spec` per the AKM lifecycle:

1. **`docs/notes/spec/sp001.md`** — flipped `status: idea` → `status: spec`,
   added `## implements [[im002|...]]` link, and wrote the full `## solution`
   section. Considered the three candidates the problem listed
   (vault-rotate-policy, blue-green-cred, zero-downtime-swap) and chose
   dual-secret overlap inside ft002. Listed inherited ADRs (adr0001 auth,
   adr0002 retention, adr0003 minimal-infra preference), affected
   components, and explicit open questions for spec-refinement.

2. **`docs/notes/im002.md` (new)** — created the persistent Implementation
   zettel that sp001 implements. Per AKM §"Process flow", a story should
   not be specced until an `im###` card exists, so I minted one with
   `status: proposed`. Carries `solves: [[us003]]`, consumed feature
   `[[ft002]]`, H1 categories `[[cat001]] [[cat003]]`, and back-link
   `## specs - [[sp001]]`.

3. **`docs/board.md`** — moved sp001 from `## idea` to `## spec`.

4. **`docs/product.md`** — annotated us003 with `>> [[im002]]` per AKM
   product-hub convention.

## Reasoning highlights

- Chose dual-secret overlap over vault-rotate-policy and blue-green-cred
  with explicit rejection rationale, anchored in adr0001/adr0002/adr0003.
- Widened ft002 contract rather than introducing a new feature — keeps
  the `secret(name)` surface stable across the three services and avoids
  a parallel notifications-style feature mint. Noted that ft002's
  api_surface zettel will need updating when this ships.
- Synthetic check + rollback are surfaced as solution-level concerns but
  pinned for spec-refinement, not over-specified at spec stage.
- Did NOT write the `## plan` / `## tasks` sections — those belong to
  spec-refinement / spec-ready per the AKM schema lifecycle column.

## Files

- New: `docs/notes/im002.md`
- Modified: `docs/notes/spec/sp001.md`, `docs/board.md`, `docs/product.md`
- Also staged: `.seed_manifest.txt` (was untracked in seed; included by
  `git add -A`).
