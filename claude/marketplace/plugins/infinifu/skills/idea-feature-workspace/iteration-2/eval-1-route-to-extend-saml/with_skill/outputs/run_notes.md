# Run notes — eval-1-route-to-extend-saml (with_skill, iteration 2)

## Decision

**Re-routed to `infinifu:idea-extend` on `[[ft001]]`. No `sp###` minted.
No `idea-feature` zettel written.** Decision captured in
`sandbox/route_decision.md`.

## Why

The skill's Dedup check (step 1) and Disambiguation rule both fire:

- User explicitly named `ft001` as the thing being modified ("basic-auth
  (ft001) only does password+TOTP today").
- `feature-read` on auth/SSO surfaces `ft001` as the close match.
- Disambiguation: *"Modification to an existing feature → re-route to
  idea-extend framed against the ft###."*

Per the skill: "Close match → re-route to `idea-extend` on that `ft###`
and stop."

## Zettels surveyed

**Features** (`feature-read`)
- `ft001` — basic-auth (password+TOTP). Status `stable`. `## providing`
  explicitly lists "no SSO, no SAML, no OAuth" as non-goals.
- `ft002` — vault-secrets. Unrelated.

**ADRs** (`adr-read --category cat001`)
- `adr0001` — "All services authenticate via ft001 basic-auth"
  (Accepted). `## consequences` explicitly says *"External SSO would
  require a new feature, not extending ft001."*
- `adr0002` (cat002) — unrelated (Postgres retention).
- `adr0003` (cat003) — unrelated (smtplib).

**Categories** (`category-read`)
- `cat001` security — primary bucket for auth/SAML.
- `cat002` data, `cat003` infrastructure, `cat004` observability — not
  primary.

**Implementations** (`implementation-read`)
- `im001` — reports dashboard, consumes `ft001`. Downstream consumer of
  any auth change, but no ad-hoc SAML implementation exists. Not a
  migration candidate.

**Stories** (`story-read`)
- `us001` (done), `us002` (ready), `us003` (ready) — none mention
  external partner / SAML / SSO. The "new external partner integration"
  consumer cited by the user has no backing `us###` yet.

**Personas**
- `pn001` analyst, `pn002` platform-engineer. No external-partner persona.

## Notable AKM signal

The project encoded an explicit pre-existing decision against this
exact extension path:

1. `ft001.## providing` lists SAML as a non-goal.
2. `adr0001.## consequences` says SAML belongs in a *new* feature, not
   in `ft001`.

That means whichever skill takes this conversation next (`idea-extend`
on `ft001`) will immediately hit a fork: either revisit `adr0001` with
a superseding ADR (and then extend / supersede `ft001`), or honor
`adr0001` and bounce back to `idea-feature` to mint a brand-new SAML
feature decoupled from `ft001`.

That decision belongs in `idea-extend` because it's a delta-against-
known-feature conversation, not a fresh-capability conversation. The
user's request named `ft001` — `idea-feature` would have to silently
ignore that anchor to proceed.

Also missing: the "external partner integration" `us###` doesn't exist.
The downstream extend / feature conversation should also surface that a
new `us###` (and possibly a new `pn###` for "external partner") may be
needed before the spec is meaningful.

## Hard-gate status

Hard gate **not reached** — re-routed before brainstorming. No design
proposed, no zettel minted, no board change. The HARD-GATE is honored
by handing off to the correct entry skill.

## Outputs

- `sandbox/route_decision.md` — re-route rationale (also copied to
  `outputs/new-files/`).
- `outputs/git-status.txt`, `outputs/git-diff.patch` — staged state
  (only the new `route_decision.md` plus pre-existing
  `.seed_manifest.txt` that the sandbox left untracked).
- No `gate_reached.md` written — the run terminated at the
  Disambiguation step, before any hard gate.
