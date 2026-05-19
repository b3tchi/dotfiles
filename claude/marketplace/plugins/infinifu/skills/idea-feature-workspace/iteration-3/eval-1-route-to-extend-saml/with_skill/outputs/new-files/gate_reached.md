# Design gate — SAML SSO for external partner integration

**Skill:** `infinifu:idea-feature` (proceeding, not routing).
**Status:** awaiting user approval before minting `sp###`.

## Routing rationale (why proceed, not re-route to `idea-extend`)

The disambiguation rule "modification to an existing feature → idea-extend" looks like it could fire against [[ft001]] (basic-auth, password+TOTP). It does **not** fire here because two pieces of project context pre-adjudicate the question against extending [[ft001]]:

1. [[ft001]]`.providing` is explicit: *"Password + TOTP authentication shared across all services. … No SSO, no SAML, no OAuth — those are explicit non-goals for now."* SAML is not inside [[ft001]]'s capability boundary; it is a different identity mechanism.
2. [[adr0001]]`.consequences` is explicit: *"External SSO would require a new feature, not extending ft001."* This is a binding accepted decision under [[cat001]] (security).

Therefore the surface-level similarity (both are "auth") is overridden by an explicit accepted ADR plus the feature's own non-goals list. The correct entry type is `idea-feature` — mint a new `ft###` for SAML SSO at spec-writing time, do not edit [[ft001]].

## AKM survey (concrete ids — no inventions)

**Features (`feature-read`).** Two exist:

- [[ft001]] — basic-auth (password+TOTP). Dedup candidate; rejected per above. SAML is not in scope.
- [[ft002]] — vault-secrets. Adjacent (secret retrieval) but unrelated to identity. Will be **consumed** by the SAML feature for SP metadata / signing-cert storage rather than duplicated.

No close-match feature exists → dedup check passes → proceed.

**Categories (`category-read`).** [[cat001]] (security — *"Authentication, authorization, secret handling, audit trails."*) is the primary bucket. No second bucket warranted (no data-retention shape, no infra-only shape).

**ADRs (`adr-read --category cat001`).** [[adr0001]] is the only security-category ADR. Binding on this proposal:

- Constrains *how* the new feature relates to existing services: it must coexist with [[ft001]], not replace it, until external-identity stories move on. Services keep `require_auth` from [[ft001]] for internal users; SAML provides a parallel identity path for the partner.
- Pre-decides the routing (see §1) — *a new feature*, not an extension.

[[adr0002]] (data retention, [[cat002]]) and [[adr0003]] (SMTP, [[cat003]]) do not bind this proposal.

**Implementations (`implementation-read`).** Only [[im001]] exists (reports dashboard). It currently consumes [[ft001]]. It is **not** a consumer of SAML in any plausible reading — the analyst persona ([[pn001]]) authenticates internally, not via partner SSO. Consequence: **today there are zero existing `im###` consumers of the proposed feature.**

This is the "feature with one consumer is not a feature" red flag from the skill's Key Principles. Two mitigations:

- The user's framing explicitly names a *new external partner integration* as the driver — that is a yet-to-be-written `us###` (partner persona, new flow). The expected consumer is `im###` glue for that future story, not an existing `im###`. We will list it in `## problem` as "future `im###` for partner integration (no `us###` minted yet)" rather than invent an id.
- Long-term, anywhere external identity becomes a goal, the same `ft###` is the reusable building block. The reusability claim is plausible but not yet evidenced by multiple in-flight stories. We **flag this explicitly** in the proposal so the user can decide: proceed and accept the one-near-term-consumer risk, or pause until a second consumer is concretely named.

## Granularity check (atomic `ft###`?)

SAML SSO as a single capability has one `## providing` paragraph (federated identity via SAML 2.0 SP-initiated flow), one `## api_surface` (likely a `@require_saml` decorator + ACS endpoint + metadata endpoint), one lifecycle. It is **one** atomic feature, not a stack. We are not packing OAuth, OIDC, LDAP, MFA into one bucket — those would be separate `ft###` minted on demand.

## Migration sketch

No existing ad-hoc SAML implementations to migrate (none exist). [[ft001]] stays untouched. The new `ft###` provides a parallel identity path; services that need partner access add the new decorator alongside (or instead of) `@require_auth`.

## Proposed sp### shape (single sp###, status: idea)

**Title (alias):** "SAML SSO for external partner integration"

**`## problem` (sketch — to be finalized at mint):**

> External partner integration needs federated identity. Current [[ft001|basic-auth (password+TOTP)]] explicitly excludes SSO as a non-goal, and [[adr0001]] decided that external SSO requires a new feature rather than extending [[ft001]]. This sp### captures the problem of providing SAML 2.0 SP-initiated authentication as a new horizontal capability under [[cat001|security]], to be minted as a new `ft###` at spec-writing time. The new feature will coexist with [[ft001]] (internal users keep password+TOTP) and will consume [[ft002|vault-secrets]] for SP signing-cert and IdP metadata storage. Near-term consumer: a future `im###` for the partner-integration story (not yet written — `us###` will be minted alongside this work or as a sibling spec). Reusability evidence is currently thin (one near-term consumer); this is flagged for the user's decision at the design gate. Binding ADRs: [[adr0001]]. Migration targets: none ([[ft001]] untouched, no ad-hoc SAML elsewhere).

**Sizing call (step 8):** one sp###. Single atomic `ft###` to mint, no parallel non-trivial work streams.

**`## idea` board entry:** `[[sp001|SAML SSO for external partner integration]]` (would become sp001 since no existing sp### in `docs/notes/spec/`).

## Open questions for user (one at a time per shared cadence)

The shared `idea-brainstorming` process asks one MC question per turn. The first I would ask after presenting routing rationale:

> The new SAML feature has only one named near-term consumer (a future partner-integration `im###`). The Key Principle "a feature with one consumer is not a feature" suggests this could end up being `im###` glue, not a real `ft###`. Which of these reflects reality?
>
> A. **Multiple SSO consumers are coming** (other partners, customer portal, etc.) — proceed and mint `ft###`.
> B. **Only this one partner integration is foreseeable** — consider routing to `idea-implement`: write the partner story `us###` first, treat SAML as `im###` glue, mint `ft###` later if a second consumer appears.
> C. **Unsure — keep as `idea-feature` but defer minting** the `ft###` until spec-writing has more clarity (this is the default skill behavior anyway).

This is the design-gate stop. No `sp###` written, no `docs/board.md` mutation, no implementation skill invoked. Per the hard gate, awaiting user approval (or routing redirect) before proceeding to `spec-writing`.

---

## Reference discipline check

Wikilinks used in this gate document (every surveyed id):

- Features: [[ft001]], [[ft002]]
- Implementations: [[im001]]
- Categories: [[cat001]], [[cat002]], [[cat003]]
- ADRs: [[adr0001]], [[adr0002]], [[adr0003]]
- Personas: [[pn001]]

No invented ids. All references resolve to existing files in `docs/notes/`.
