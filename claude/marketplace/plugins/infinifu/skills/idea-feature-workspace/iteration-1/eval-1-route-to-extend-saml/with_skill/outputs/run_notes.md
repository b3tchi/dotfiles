# Run notes — eval-1-route-to-extend-saml (with_skill)

## What I surveyed

Read all of the seeded AKM zettels relevant to the request:

- **Features (`feature-read` keyword: auth / SSO / SAML).**
  - `ft001` basic-auth (password+TOTP): `providing` explicitly says
    *"No SSO, no SAML, no OAuth — those are explicit non-goals for
    now."* and lists `[[cat001]]`.
  - `ft002` vault-secrets: unrelated (`cat001` but secret retrieval,
    not auth flow).
  - **No existing SSO/SAML feature.**

- **ADRs under cat001 (`adr-read --category cat001`).**
  - `adr0001` "All services authenticate via ft001 basic-auth" —
    `consequences` carries the load-bearing line:
    *"External SSO would require a new feature, not extending ft001."*
  - This is the decisive ADR for the routing question.

- **Implementations (`implementation-read` keyword: auth).**
  - `im001` reports-dashboard consumes `ft001`. No ad-hoc SAML
    implementation anywhere — greenfield SSO.

- **Stories / personas (`story-find`, `persona-read`).**
  - `us001`/`us002` (analyst), `us003` (platform-engineer). No
    `us###` for SAML or external partner today.
  - The "external partner integration" mentioned by the user is an
    implied future story, not a captured `us###` yet.

- **Categories.** `cat001` security (primary fit); `cat003`
  infrastructure (possibly, if IdP federation is meaningful).

- **README + src layout.** Three services (`auth`, `metrics`,
  `reports`) currently use `ft001`. `auth` service is the most
  likely consumer for SAML; `reports`/`metrics` may stay on `ft001`.

## What I decided — proceed as feature (NOT re-route)

The user's phrasing ("add SAML SSO to our auth — basic-auth (ft001)
only does password+TOTP today") superficially sounds like an
**extension of `ft001`**, which would route to `idea-extend` per the
skill's Disambiguation section.

But the surveyed AKM context overrides that reading:

1. **`ft001` explicitly excludes SAML** in its `providing` section
   ("No SSO, no SAML, no OAuth — those are explicit non-goals for
   now"). SAML is *outside* the declared boundary of `ft001`, not a
   gap *inside* it.
2. **`adr0001` explicitly prescribes the routing:** "External SSO
   would require a new feature, not extending ft001." The decision
   log already settled this — re-routing to `idea-extend` would
   violate `adr0001`.
3. **Multiple plausible consumers**: existing services on `ft001`
   (auth/metrics/reports) plus the new external partner integration.
   A capability with >1 consumer fits the feature shape, not single-
   story `im###` glue.

So the user invoked the correct skill. No re-route needed.

## Why I stopped at the gate

`idea-brainstorming` (the shared basics loaded by `idea-feature`)
makes the design-approval gate non-negotiable: survey → one
clarifying question → propose 2-3 approaches → section-by-section
approval → only then mint `sp###`. Per eval instructions, in the
absence of a user I stop at the **first hard gate** and write
`gate_reached.md` documenting:

- routing decision (proceed as feature) with anchored ADR/feature
  evidence,
- the proposed `sp###.problem` shape (capability boundary,
  consumers, constraints, migration intent),
- the next clarifying question I would ask (MC with three
  variants on coexistence scope: A SAML-only-partner / B per-
  endpoint coexist / C SAML-strategic-default + ft001 deprecation),
- the artifacts that would be written *after* approval (`sp001.md`
  + `docs/board.md` under `## idea`).

I did NOT mint `sp###` (skill forbids without approval), did NOT
mint `ft###` (skill defers minting to `spec-writing`), and did NOT
modify `docs/board.md`.

## Files

- New: `sandbox/gate_reached.md` (the gate report).
- Untouched seed file `.seed_manifest.txt` was untracked in the
  sandbox before I started; `git add -A` picked it up but I didn't
  create it.

No other artifacts.
