# Run Notes — eval-4-dedup-existing-feature / with_skill

## Skill invoked

`infinifu:idea-feature` (per user task). Also loaded
`infinifu:idea-brainstorming` for shared process basics, per the
entry-skill's instruction.

## Dedup check process

Step 1 of the `idea-feature` entry-specific checklist is **dedup
check** via `feature-read`. The skill's Disambiguation block is
explicit: *"Modification to an existing feature → re-route to
`idea-extend` framed against the `ft###`."* I performed the check by
direct inspection of `docs/notes/ft*.md` (the read skills were not
available as invokable tools in this sandbox, so I substituted file
reads — same effect).

## Decision

**RE-ROUTE.** Do not mint a new `sp###` or `ft###`. The capability
described by the user — a shared library replacing ad-hoc vault CLI
shell-outs for DB creds + API tokens — is already provided by:

- **[[ft002]] vault-secrets** (`status: stable`)
  - api_surface: `from acme.lib.vault import secret`
  - component: `src/lib/vault.py`
  - category: [[cat001|security]]

The actual user problem is **adoption / migration**: services are
still doing ad-hoc vault CLI shell-outs instead of importing
`acme.lib.vault.secret`. That's an `idea-extend` scope against
[[ft002]] (either pure migration across the consuming `im###`
implementations, or an `api_surface` widening if API-token retrieval
isn't covered yet).

Minting a fresh `ft###` here would split the secret-retrieval
contract across two zettel — exactly the failure mode the dedup gate
exists to prevent. The Disambiguation rule fires; I stopped before
zettel emission.

## Zettel ids surveyed

- Features: [[ft001]] basic-auth (non-match), [[ft002]] vault-secrets
  (**dedup hit**).
- Stories: [[us001]], [[us002]], [[us003]] (us003 is the most plausible
  ft002 consumer — quarterly secret rotation).
- Implementations: [[im001]] reports dashboard (uses ft001, no vault
  ad-hoc visible).
- Categories: [[cat001]] security (binding), [[cat002]] data,
  [[cat003]] infrastructure, [[cat004]] observability.
- ADRs: [[adr0001]] (auth, adjacent), [[adr0002]] (reports retention,
  unrelated), [[adr0003]] (smtplib direct — analogous "ad-hoc
  copy/paste" anti-pattern in a different domain, informative).

## Code-level evidence

`src/lib/__init__.py` literally states *"Shared libs (vault, db
helpers)"* — the vault lib slot is the documented location for the
ft002 component. Service stubs (`auth`, `metrics`, `reports`) do not
currently surface the ad-hoc vault shell-out the user describes, but
that does not change the verdict: the canonical place to put a
shared secrets lib already exists and already has a contract.

## Artifacts produced

- `sandbox/route_decision.md` — the re-route memo with full citation
  table (committed via `git add -A`).
- No `sp###` minted. No `ft###` minted. No `docs/board.md` edit.

## Hand-off

User should invoke `infinifu:idea-extend` against [[ft002]] with the
framing: *"replace ad-hoc vault CLI shell-outs in auth / metrics /
reports with `acme.lib.vault.secret(name)`; widen ft002 api_surface
only if API-token retrieval is out of current scope."*
