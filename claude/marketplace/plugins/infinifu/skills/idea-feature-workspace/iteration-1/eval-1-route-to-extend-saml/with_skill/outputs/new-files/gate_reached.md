# Gate reached — idea-feature

Using idea-feature skill to scope a new horizontal capability.

## Routing decision: proceed as feature (no re-route)

The phrasing "add SAML SSO to our auth — basic-auth (ft001) only does
password+TOTP today" sounds at first like a modification to `ft001`
that would warrant `idea-extend`. The surveyed AKM context overrules
that reading:

- **`ft001` providing** explicitly says: *"No SSO, no SAML, no OAuth —
  those are explicit non-goals for now."* SAML is outside the
  declared capability boundary of `ft001`, not a gap inside it.
- **`adr0001` consequences** explicitly prescribes the routing:
  *"External SSO would require a new feature, not extending ft001."*
  The decision log already settled this question — extending `ft001`
  would violate `adr0001`.
- **Multiple plausible consumers** (the existing `auth`, `metrics`,
  `reports` services that currently use `ft001`, plus the new
  external-partner integration that triggered the request) — a
  capability with >1 consumer fits the feature shape, not single-story
  `im###` glue.

So this is genuinely a feature ask: mint a *new* `ft###` for SAML SSO,
keep `ft001` as the password+TOTP feature, and let consumers pick the
auth feature appropriate to their entry point.

## Survey summary (grounded in real ids)

| Read | Hit | Notes |
|---|---|---|
| `feature-read` keyword: auth/SSO/SAML | `ft001`, `ft002` | `ft001` explicitly excludes SAML; `ft002` unrelated. **No existing SSO feature.** |
| `adr-read --category cat001` | `adr0001` | Prescribes "external SSO = new feature." Binding constraint. |
| `category-read` | `cat001` security | The capability lives here. Possibly `cat003` infrastructure if federation routing matters. |
| `story-find` keyword: auth/login/partner | (none) | No `us###` for SAML yet. Consumers are the *services* (auth, metrics, reports) + the implied external-partner integration story not yet captured. |
| `implementation-read` keyword: auth | `im001` consumes `ft001` | No ad-hoc SAML implementation today. Migration list is empty — this is greenfield SSO. |

## Proposed shape (would land in `sp###.problem` after approval)

- **Capability boundary.** A new `ft###` "saml-sso" provides
  SAML-2.0-based SSO with an external IdP. Surface mirrors `ft001`
  shape (`@require_auth_saml` decorator + `current_user()` parity)
  so callers don't branch per auth flavor at handler level.
- **Sits next to `ft001`, not inside it.** Per `adr0001`. Consumers
  pick: legacy / internal-only paths stay on `ft001` (password+TOTP);
  external-partner paths use the new SAML feature. A small router
  helper may live as glue in the `auth` service if both flows must
  coexist on the same endpoint.
- **Categories.** `[[cat001|security]]` primary; possibly
  `[[cat003|infrastructure]]` if IdP federation / metadata exchange
  is meaningful enough.
- **Constraints inherited.** Anything `cat001`-bound from `adr0001`
  (single-auth-per-service intent) is *explicitly relaxed* by this
  new feature — surfacing that as either a new ADR or a
  `consequences` note on a follow-up ADR is part of the design phase.
- **Consumers (concrete, surveyed).**
  - `auth` service (today on `ft001`) — adds SAML entry path.
  - The implied external-partner integration story (no `us###` yet;
    would be captured alongside the spec).
  - `reports` / `metrics` services may stay on `ft001` until/unless
    a partner-facing surface demands SAML there.
- **`ft###` is NOT minted here.** Per the skill, the capability
  boundary is still under discussion; spec-writing mints the
  `ft###`. This card lands only the `sp###` with `## problem`.

## Hard gate — stopping here

Per `idea-brainstorming` the entry-skill must:

1. Survey AKM context (done above).
2. Ask **one** clarifying question (multiple-choice preferred).
3. Propose 2-3 design approaches.
4. Get section-by-section design approval.
5. Only then mint `sp###` and update `docs/board.md`.

I'm stopping before step 2 (the first user-facing gate) since this is
an automated eval with no user.

## Next clarifying question (would be asked now)

The biggest open shape question is whether SAML coexists with
`ft001` per-service or replaces it for partner-facing surfaces.
That decides the `ft###` API surface and whether any `[[im###]]`
migration is in scope. Proposed MC:

> The new external partner integration needs SAML. Which best
> describes the target scope?
>
> A. **SAML-only for the partner-facing surface.** Internal services
>    stay on `ft001`. New `ft###` lives alongside `ft001`; no
>    migration of existing `im###`. (Smallest blast radius; matches
>    `adr0001` literally.)
>
> B. **SAML + `ft001` coexist per-endpoint.** Some endpoints accept
>    either flow (e.g. the `auth` service grows a SAML route while
>    keeping password+TOTP). Routing glue lives in the `auth`
>    service. (Moderate; needs a small router helper.)
>
> C. **SAML becomes the strategic default; `ft001` is the legacy
>    path.** New consumers default to SAML; `ft001` enters
>    `deprecated` after the partner ships. (Largest; triggers a
>    supersession discussion and likely a new ADR overturning
>    `adr0001`.)

After the answer, I'd present 2-3 anchored design options, get
section-by-section approval, then mint `sp###` with
`## problem` covering capability boundary + consumers +
constraints + (any) migration intent, plus append the new
`[[sp###|saml-sso]]` under `## idea` in `docs/board.md`.

## Artifacts that would be written after approval

- New: `docs/notes/spec/sp001.md` (frontmatter `status: idea`,
  H1 `# Spec [[cat001]] [[board]]`, body has only `## problem`).
- Modified: `docs/board.md` — `[[sp001|saml-sso capability]]`
  appended under `## idea`.

No `ft###` minted here; that lands at `spec-writing` time per the
skill's AKM hooks.
