# Run notes — idea-feature eval (SAML SSO)

## Decision: proceed (not route)

Stopped at the design-approval gate per `idea-brainstorming` hard gate. Wrote `gate_reached.md` only — no `sp###` minted, no `docs/board.md` mutation. Awaiting user approval / routing-redirect before invoking `spec-writing`.

## Surveyed AKM ids (concrete, no inventions)

| Type | Id | Relevance |
|---|---|---|
| Feature | [[ft001]] | Dedup candidate (auth). Rejected — explicit non-goals list excludes SAML/SSO. |
| Feature | [[ft002]] | vault-secrets — will be consumed for SP cert / IdP metadata storage. |
| Implementation | [[im001]] | Existing consumer of [[ft001]] (reports dashboard). Not a consumer of the proposed feature. |
| Category | [[cat001]] | security — primary bucket for the proposed `ft###`. |
| Category | [[cat002]] | data — surveyed, not bound. |
| Category | [[cat003]] | infrastructure — surveyed, not bound. |
| ADR | [[adr0001]] | **Binding.** `consequences` pre-decides: "External SSO would require a new feature, not extending ft001." |
| ADR | [[adr0002]] | data retention ([[cat002]]) — not bound. |
| ADR | [[adr0003]] | smtplib ([[cat003]]) — not bound. |
| Persona | [[pn001]] | analyst — internal user, not the partner persona driving this request. |

## Routing vs proceed analysis

Two competing signals weighed:

1. **Disambiguation rule** ("modification to an existing feature → idea-extend"). Surface-level: SAML touches "auth", [[ft001]] is "auth" → looks like extend.
2. **Project context** (the ADR + the feature's own non-goals).

Resolution: **project context wins**. Two binding pieces:

- [[ft001]]`.providing` lists SSO/SAML/OAuth as **explicit non-goals**. SAML is *outside* the capability boundary, not an addition to it. Extending [[ft001]] to swallow SAML would widen `## providing` beyond its declared shape.
- [[adr0001]]`.consequences` is an **accepted decision** that this exact case (external SSO) is "a new feature, not extending ft001."

So the disambiguation rule's surface match is overridden by a documented decision. Correct routing: `idea-feature` → mint new `ft###` at spec-writing time.

## ADR considerations

- [[adr0001]] is **binding and adjudicating** — it pre-decided this routing dispute. The skill correctly favoured the explicit ADR over the surface-similarity disambiguation rule.
- [[adr0001]] also constrains the *shape* of coexistence: the new feature must run parallel to [[ft001]], not replace it. Services keep `require_auth` (from [[ft001]]) for internal users; SAML provides a second identity path for the partner.
- No other ADRs bind this proposal.

## Granularity & sizing decisions

- **Atomic `ft###`.** SAML SSO is one capability (one `## providing`, one `## api_surface`, one lifecycle). Not a stack — OAuth / OIDC / LDAP would be separate `ft###` if needed.
- **One `sp###`** per skill step 8 (single atomic `ft###`, no parallel non-trivial work).

## Surfaced risk (flagged in gate document)

The "feature with one consumer is not a feature" principle applies — only one near-term consumer is named (future partner-integration `im###`, not yet written). Gate document asks the user a one-question MC to disambiguate:

- A: multiple SSO consumers coming → mint `ft###`
- B: only this one foreseeable → route to `idea-implement` instead (SAML as `im###` glue)
- C: unsure → keep `idea-feature` but defer `ft###` mint to spec-writing

This is the correct application of the skill's "stage-1 goals: problem-formulation + duplication-mitigation" principle — surface the reusability question before the gate closes.

## Wikilink discipline (skill step 9)

All ids appearing in `gate_reached.md` resolve to real files in `docs/notes/`. Nothing invented. The proposed `## problem` sketch references [[ft001]], [[ft002]], [[adr0001]], [[cat001]], [[im001]], [[pn001]] — every relevant surveyed id has a wikilink, not bare prose.

## Files written

- `sandbox/gate_reached.md` (new) — design gate document with routing rationale, AKM survey, proposed `sp###` shape, open question for user.
- Nothing under `docs/notes/spec/`, nothing in `docs/board.md`, nothing in `docs/notes/` — the hard gate held.
