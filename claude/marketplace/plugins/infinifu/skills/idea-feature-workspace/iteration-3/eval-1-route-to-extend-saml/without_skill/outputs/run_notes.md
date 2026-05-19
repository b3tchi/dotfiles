# Run notes — eval-1-route-to-extend-saml (without_skill)

## Task

User asked to add SAML SSO to auth, noting `ft001` only does
password+TOTP today. They requested `infinifu:idea-feature` (the AKM
stage-1 *feature add* entry skill). That skill was **not loaded** for
this baseline run — I had to infer the right shape from the AKM
catalog at `docs/notes/akm.md`.

## Reasoning summary

1. **Survey first.** Read `akm.md`, `product.md`, `board.md`, all
   existing `ft###`, `adr####`, `cat###`, `us###`, `im###`, `pn###` to
   understand the workspace shape and naming conventions before
   writing anything.

2. **Routing.** This is a horizontal capability (auth/SAML) the system
   will provide once and many implementations may consume, so it
   matches the *idea-feature* entry-type (not idea-implement, which
   would be a user-facing story, and not idea-extend, which would
   adjust shipped behavior of an existing `us###`).

3. **Extend ft001 vs new feature.** The seed makes the answer explicit:
   - `ft001.providing` lists *"No SSO, no SAML, no OAuth"* as
     non-goals.
   - `adr0001.consequences` says *"External SSO would require a new
     feature, not extending ft001."*
   So the right shape is a **new sibling `ft###`** under `cat001`,
   not a modification of `ft001`.

4. **Stage-1 discipline.** Per `akm.md`, `idea-feature` produces a
   new `sp###` spec at `status: idea` with `## problem` populated and
   the *intent* to mint a new `ft###` at the spec stage. It does NOT
   mint the `ft###` zettel yet (that's spec-writing's job). I held
   the line on this even though it was tempting to draft the feature
   file directly.

5. **Artifacts created.**
   - `docs/notes/spec/sp001.md` — first spec, `status: idea`,
     categories `[[cat001]] [[cat003]]`, problem framed around the
     adr0001 trade-off, with explicit out-of-scope and open questions
     to resolve at the spec stage.
   - `docs/board.md` — listed `sp001` under `## idea`.

## Things skipped on purpose

- Did NOT mint `ft003` (or whatever the SAML feature id will be) —
  spec stage owns that.
- Did NOT mint a new `us###` — the request didn't describe a single
  persona's want; a feature is the right shape and stories can come
  later for partner-facing flows.
- Did NOT file a new ADR superseding `adr0001` — flagged it as an
  open question in `sp001`, to resolve when the spec is written.
- Did NOT touch `product.md` — `ft###` will be added there when
  minted at spec stage.

## Files

- New: `docs/notes/spec/sp001.md`
- Modified: `docs/board.md`
- (Untracked seed artifact left alone: `.seed_manifest.txt`)
