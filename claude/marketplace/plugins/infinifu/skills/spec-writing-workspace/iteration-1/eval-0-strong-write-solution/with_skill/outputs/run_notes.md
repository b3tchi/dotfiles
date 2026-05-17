# Run notes — eval-0-strong-write-solution

## Surveyed ids

- **Spec**: `sp001` (status `idea`, solves `[[us003]]`, problem populated).
- **Story**: `us003` (status `ready`, AC testable: live swap, 5-min overlap, no 5xx in synthetic check).
- **Categories (from spec H1)**: `cat001` (security), `cat003` (infrastructure).
- **ADRs surveyed via picked categories**:
  - `adr0001` (Accepted, cat001) — all services authenticate via `ft001` basic-auth. Not in conflict with rotation; auth mechanism unchanged.
  - `adr0003` (Accepted, cat003) — services use `smtplib` directly. Orthogonal to credential rotation; no conflict.
  - `adr0002` (Accepted, cat002 data) — out of category scope; the spec's `## problem` mentioned it but only as inherited context for Postgres retention, not a binding decision for the rotation surface. Did not list it in `## solution`.
- **Features surveyed**:
  - `ft002` (vault-secrets) — bound as the consumed feature. `secret(name)` is the existing indirection point that makes overlap rotation a no-op for consumers.
  - `ft001` (basic-auth) — present but not a rotation surface; inherited via consumers, not consumed by the rotation flow itself, so not listed in `## solution`.
- **Dedup**: grepped `docs/notes/im*.md` for `us003` — no existing `im###` solves `us003`. Clean mint will happen downstream at spec-refinement; no supersession candidate.

## Solution shape proposed

**Dual-secret overlap-window rotation on top of [[ft002|vault-secrets]].**
Write the new credential as a new vault version alongside the current one,
let services continue resolving via the existing `secret(name)` lazy surface,
keep the old value readable for 5 minutes, then revoke it. Pattern picked
over blue-green credential cycling (heavier deploy churn, would require a new
deployment-topology ADR, doesn't leverage `ft002`) and over app-coordinated
reload endpoints (would force changes to every consumer and add a new
auth-cred surface). Trade-offs spelled out in `## solution`. Reference
discipline: `[[ft002]]`, `[[ft001]]`, `[[adr0001]]`, `[[adr0003]]`, `[[cat001]]`,
`[[cat003]]`, `[[us003]]` all appear as wikilinks.

## Status flip

- `docs/notes/spec/sp001.md` frontmatter `status: idea` → `status: spec`.

## Board move

- `docs/board.md`: removed `[[sp001|rotate service credentials without downtime]]` from `## idea`; added the same wikilink under `## spec`.

## Out of scope (per skill contract)

- No `## plan` section (file tree, conventions) — that's spec-refinement.
- No bd epic / task ids — that's spec-ready.
- No new `im###` minted — that happens at spec-refinement once tasks are concrete enough to anchor.

## Hard gates

None reached. AC clean, problem populated, no ADR conflict, no dedup hit. No `gate_reached.md` written.
