# implementation-write — template, examples, checklist

Load when composing the file, validating a draft, or seeing an unfamiliar edge case.

## Full zettel template

```markdown
---
aliases:
  - <human-readable solution one-liner>
status: proposed
created: YYYY-MM-DD
---
# Implementation [[cat###]] [[cat###]] [[product]]

## solves
[[us###|<story-alias>]]

## approach
<one paragraph: pattern, key trade-off, binding ADRs/Features mentioned in prose>

## features
- [[ft###|<feature-alias>]]
- [[ft###|<feature-alias>]]

## data_model
<schema deltas this implementation owns; features carry their own state>

## api_surface
<endpoints / payloads / contracts this implementation adds — exclude what features already expose>

## components
- <story-specific glue: module / file / path>
- <story-specific glue: module / file / path>

## specs
- [[<spec-topic>|<spec-title>]]

## superseded_by
[[im###|<replacement>]]        # only when status = superseded

---

Index: [[product]]
```

**Conventions:**

- ISO `YYYY-MM-DD` for `created`.
- Story wikilink form: `[[us###|alias]]` — pipe-separated, alias label after.
- Category wikilinks in H1: bare slugs in double brackets, no pipe needed.
- Feature wikilinks in `## features`: `[[ft###|alias]]` form for readability.
- Section ordering matches `akm.md` — moxide LSP parses on these headings.
- Footer: `---` rule then `Index: [[product]]` on its own line.

## Example 1 — fresh implementation for a `ready` story

**Input:** *"draft the implementation for us014 — we'll lean on the existing import-pipeline feature and add a samples-specific staging table."*

**Anchor:** read `docs/notes/us014.md`, status `ready`, alias *"bulk import requests from spreadsheet"*. Passes the gate.

**Categories:** data (`cat003`) + integration (`cat007`) — the card touches schema and an external file format.

**Survey:** scan ADRs under `data` and `integration` — `[[adr0007]]` (event-sourced persistence) is `Accepted` and binds the write path. Survey Features — `[[ft004|import-pipeline]]` is `stable` and exposes a generic row-parser; reuse.

**File:** `docs/notes/im007.md`

```markdown
---
aliases:
  - samples bulk import via staging table
status: proposed
created: 2026-05-15
---
# Implementation [[cat003]] [[cat007]] [[product]]

## solves
[[us014|bulk import requests from spreadsheet]]

## approach
Stage parsed rows in a per-upload table, run validators against the staging set, then promote valid rows into the canonical event log per [[adr0007]]. Reuse [[ft004]] for row parsing and contract enforcement; the staging table is the only schema this card owns. Trade-off: two-phase ingest doubles write amplification but keeps the canonical log clean of half-validated rows.

## features
- [[ft004|import-pipeline]]

## data_model
- `sample_import_staging(import_id, row_no, payload jsonb, validation_state)` — owned by this implementation; truncated 24h after promotion.

## api_surface
- `POST /samples/import` — multipart upload; returns import_id and async validation handle.
- `GET /samples/import/:id` — returns row-level validation state and promotion progress.

## components
- src/samples/import.ts
- src/samples/staging-table.sql
- migrations/2026-05-15-create-sample-import-staging.sql

## specs
- (none yet — `board/spec/samples-bulk-import.md` once drafted)

---

Index: [[product]]
```

**Hub update:** annotate the `us014` bullet under its persona heading:

```markdown
### [[pn001|requestor]]

- [[us001|order samples for upcoming client work]]
- [[us014|bulk import requests from spreadsheet]] >> [[im007]]    ← new annotation
```

## Example 2 — story is still `draft`, push back

**Input:** *"write the implementation for us020"*

**Anchor:** read `docs/notes/us020.md`, status `draft`, acceptance criteria contains *"TBD"*.

**Action — push back once:**

> *"`us020` is still `draft` and its acceptance criteria are unfinished. Implementations should anchor on a `ready` story so the approach isn't chasing a moving target. Want me to route to `infinifu:story-write` to refine `us020` first?"*

Don't proceed silently. Either the user re-routes to `story-write`, or they explicitly accept the risk that the approach may need revising.

## Example 3 — Implementation needs a missing Feature

**Input:** *"im### for us031, the notification fan-out is the core of it"*

**Survey:** no `[[ft###]]` exists for notification fan-out — only `[[ft002|email-sender]]` which is single-recipient.

**Decision:** notification fan-out will serve at least three planned stories (`us031`, `us033`, `us041`). Genuinely reusable.

**Action:** pause this skill and route:

> *"This needs a `ft###` for notification fan-out first — it'll serve us033 and us041 too. Routing to `feature-write` for the Feature card, then I'll resume im### for us031."*

Contrast: if the capability only ever serves *this* story, the code belongs in `## components` of this card. Reserve Feature elevation for the second consumer.

## Verification checklist

Before reporting the card complete:

- [ ] `## solves [[us###]]` present, links to a real `us###.md` with status `ready` (or status mismatch acknowledged with the user)
- [ ] H1 has ≥1 `[[cat###]]` and ends with `[[product]]`
- [ ] Frontmatter `aliases` (≥1), `status` (default `proposed`), `created` ISO date
- [ ] Every `[[ft###]]` in `## features` resolves to a real file; status acknowledged for `proposed`/`deprecated` Features
- [ ] `## approach` is one paragraph (≤5 sentences), names pattern + trade-off, mentions binding ADRs/Features in prose
- [ ] `## data_model` / `## api_surface` / `## components` describe deltas only, not Feature internals
- [ ] `## components` entries are concrete file/module paths (not vague labels)
- [ ] `Index: [[product]]` footer present
- [ ] Filename is `docs/notes/im<NNN>.md`, sequential next id (max + 1, gaps preserved)
- [ ] `docs/product.md` story bullet annotated with `>> [[im###]]` (or hub-missing message shown)
- [ ] moxide LSP shows no unresolved diagnostics for the new wikilinks (or dangles are deliberate and noted)
</content>
