# Run notes — spec-writing on sp001

## Inputs surveyed

- **Spec target:** `docs/notes/spec/sp001.md` — `status: idea`, `## problem`
  populated, `## solves [[us003]]`. Categories in H1: `[[cat001]]` (security)
  and `[[cat003]]` (infrastructure).
- **Source story:** `docs/notes/us003.md` — `status: ready`. AC are concrete
  and testable:
  1. Rotation script can swap secrets while services run.
  2. Old secret stays valid for 5 minutes after rotation.
  3. No 5xx during rotation window in synthetic check.
- **Categories:** `cat001` (security) + `cat003` (infrastructure) — both
  stable, both relevant.
- **Binding ADRs under those categories:**
  - `adr0001` (cat001, Accepted) — services authenticate via `ft001`.
    Rotation does not touch auth → no conflict.
  - `adr0003` (cat003, Accepted) — smtplib direct. Orthogonal to rotation.
  - `adr0002` (cat002, Accepted) — Postgres retention. Cited in `## problem`
    for completeness; not binding on rotation shape.
  No `Accepted` ADR conflicts with the natural solution → no supersession
  candidate filed.
- **Candidate feature:** `ft002` (vault-secrets, stable) — provides
  `secret(name)`. Confirmed as the consumed feature.

## Dedup check (skill step 8)

`docs/notes/im*.md` scan:

| im### | status   | solves      | approach summary                                  |
| ----- | -------- | ----------- | ------------------------------------------------- |
| im001 | accepted | [[us001]]   | `/dashboard` route on reports service             |
| im002 | accepted | **[[us003]]** | **vault-rotate-policy via ft002, 5-min overlap** |

**Hit: `im002` already solves `us003`** with the exact shape sp001 was
about to propose: versioned alias in vault, prior-version readable for up
to 5 minutes, alias flip at end of window, `secret(name)` read path
unchanged, new `rotate_secret(name)` helper in `src/lib/vault.py`. That
maps 1-for-1 onto the three acceptance criteria of `us003`.

## Decision recorded in `## solution`

**Adopt the existing `im002` — do not mint a new implementation card,
do not supersede.** Rationale named in `## solution`:

- `im002.status: accepted` and its approach already satisfies every AC.
- No `Accepted` ADR conflicts with the chosen shape.
- The only consumed feature is `[[ft002]]`, which `im002` already lists.
- Trade-off is named explicitly: vault-policy over zero-downtime-swap and
  blue-green-cred — keeps rotation in the existing vault client, costs
  the 5-minute dual-version retention already supported by `ft002`.

This avoids the duplication the skill's step-8 dedup check is meant to
catch and honors the lifecycle goal "ensure no duplication or propose
possible made solution".

## Writes applied

- `docs/notes/spec/sp001.md`
  - Frontmatter `status: idea` → `status: spec`.
  - Added `## implements [[im002|vault-policy credential rotation for live services]]`
    between `## solves` and `## problem` (per AKM Spec schema).
  - Appended `## solution` body section with the dedup decision, ADR
    references (`[[adr0001]]`, `[[adr0002]]`), bound feature (`[[ft002]]`),
    category alignment (`[[cat001]]`, `[[cat003]]`), and the named
    trade-off.
- `docs/board.md`
  - Moved `[[sp001|...]]` entry from `## idea` → `## spec`.
  - Updated the intro paragraph from "idea stage" to "spec stage".

## Out of scope (deferred to spec-refinement)

- `## plan` (file tree, conventions, anti-patterns).
- `## tasks` (rotation script, synthetic-check hook, secret-overlap
  verification).
- bd epic + task ids (spec-ready).

## Reference discipline check

`## solution` carries wikilinks for: `[[im002]]`, `[[us003]]`, `[[ft002]]`,
`[[adr0001]]`, `[[adr0002]]`, `[[ft001]]`, `[[cat001]]`, `[[cat003]]`. No
prose-only refs.
