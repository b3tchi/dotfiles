# Route decision — idea-feature → idea-extend

## Request

> "We need to add SAML SSO to our auth — basic-auth (ft001) only does
> password+TOTP today and the new external partner integration needs SAML."

## Decision

**Re-route to `infinifu:idea-extend` on `[[ft001]]`.** Do not proceed with
`idea-feature`.

## Why (per `idea-feature` Disambiguation + dedup check)

The skill's own checklist gates this:

1. **Dedup check (step 1).** `feature-read` filtered by "auth" / "SSO"
   surfaces `[[ft001|basic-auth (password+TOTP)]]` as the close match.
   The user explicitly anchored the request to `ft001` by id. The skill
   says: "Close match → re-route to `idea-extend` on that `ft###` and
   stop."

2. **Disambiguation rule.** "Modification to an existing feature →
   re-route to `idea-extend` framed against the `ft###`." The phrasing
   "add SAML SSO to our auth" + "ft001 only does password+TOTP today" is
   a modification request, not a fresh horizontal capability.

`idea-feature` is for capabilities **decoupled from any single existing
feature**. SAML SSO is being framed as a delta to the existing auth
building block (`ft001`) — that delta-against-existing-feature shape is
exactly what `idea-extend` is for.

## What the downstream `idea-extend` conversation should surface

The AC delta is non-trivial because the existing system already encoded
a decision against this path:

- **`[[adr0001]]` (Accepted)** — "All services authenticate via ft001
  basic-auth" — `## consequences` explicitly says: *"External SSO would
  require a new feature, not extending ft001."*
- **`[[ft001]].## providing`** — explicit non-goal: *"No SSO, no SAML,
  no OAuth — those are explicit non-goals for now."*

So `idea-extend` on `ft001` will hit a hard design fork immediately:

- **Option A:** Revisit `adr0001`. New ADR superseding it, then widen
  `ft001` to cover SAML (or supersede `ft001` with a new `ft###` that
  unifies basic + SAML).
- **Option B:** Honor `adr0001`. The extend conversation concludes
  *"this isn't an extend at all — it needs a new `ft###`"*, and the
  flow re-routes a second time to `idea-feature` with the user's
  framing corrected. At that point the `idea-feature` survey can land
  cleanly: new capability, distinct consumer (the external partner
  integration), no overlap with `ft001`'s password+TOTP contract.

That fork is `idea-extend`'s job to drive (it has the existing-feature
context to frame the trade-off). `idea-feature` should not silently
mint a parallel `ft###` while the user's request still names `ft001`
as the thing being changed — that would skip the ADR conversation and
leave two coexisting auth features without a documented relationship.

## Next step

Invoke `infinifu:idea-extend` with target `ft001` and the AC delta
"support SAML SSO for the external partner integration alongside the
existing password+TOTP flow."
