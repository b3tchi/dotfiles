# feature-write — schema, examples, lifecycle

Depth material for `feature-write`. The canonical schema source is
`docs/notes/akm.md` § Feature — this file mirrors it for fast lookup and adds a
worked example plus lifecycle/edit-mode rationale.

## Storage bootstrap

One zettel per Feature at `docs/notes/ft###.md`. If `docs/notes/` does not
exist, create it. If `docs/product.md` does not exist, warn the user:

> "No `docs/product.md` found; AKM workspace not initialized — Feature will
> reference a dangling `[[product]]`. Create the hub manually or via the
> project's `epic-create` skill first."

Then either proceed (file lands, hub link dangles) or abort if the user
prefers.

## Gathering the capability shape

Features are short. Don't over-interview — capture the contract the user has
in mind. Full design conversations belong upstream in
`infinifu:idea-brainstorming`.

**Elicit (if missing):**

- **`providing`** — *what capability, who/what consumes it.* Elevator pitch.
- **`api_surface`** — *how consumers invoke it.* Function signature,
  endpoint, message contract. *"You call it somehow"* is not an api surface.
- **`data_model`** — *own state.* "Stateless" is fine; otherwise schema
  sketch + retention + ownership.
- **`sample`** — tiny snippet or path to a sample file. A Feature nobody can
  show how to use is still an idea.
- **`components`** — modules / paths / packages that implement the
  capability. The entry point for `infinifu:story-map` traceability.

If two or more pieces stay vague after one round of asking, the capability
isn't ready — suggest `infinifu:idea-brainstorming` first.

## H1 categories — why ≥1 and why several is fine

The H1 carries one or more `[[cat###]]` buckets plus `[[product]]`:

```markdown
# Feature [[cat003]] [[cat007]] [[product]]
```

Unlike ADRs (exactly one category), Features may list several when the
capability genuinely spans buckets — an audit-log feature touches both data
and security. Minimum is one. Procedure:

1. List existing categories: `ls docs/notes/cat*.md`; read frontmatter
   `aliases:` for canonical labels.
2. User-named match → use that `cat###`. User listed categories verbatim →
   use them.
3. No match and a new bucket is genuinely needed → send the user to
   `infinifu:category-write` first. Don't fabricate dangling `[[cat###]]`
   links.

## Feature dependencies (`depends_on`)

When a Feature builds on another (notifications → templating; audit-log →
database-access), record it as a `## depends_on` body section listing
upstream `[[ft###]]` wikilinks. Only include the section when there is at
least one dependency — don't leave an empty heading. This pattern is
documented in `akm.md` ("Features may `depends_on` another Feature when
capabilities layer").

## ID generation

`ft` + three-digit zero-padded sequential (`ft001`, `ft002`, …). Not
date-bucketed — pure sequential keeps `[[ft001]]` stable forever.

1. `ls docs/notes/ft*.md` → extract numeric portion → `max + 1`, zero-padded
   to 3. No existing Features: start at `001`.
2. Gaps stay gaps. A superseded `ft003` keeps its file; the replacement gets
   a fresh id (never `ft003` again).

## Schema (canonical source: `docs/notes/akm.md` § Feature)

```markdown
---
aliases:
  - <human-readable capability one-liner>
status: <proposed|stable|deprecated|superseded>
created: YYYY-MM-DD
---
# Feature [[cat###]] [[cat###]] [[product]]

## providing
<one paragraph: what capability this provides, who/what consumes it>

## api_surface
<how consumers invoke it: function, endpoint, message contract>

## data_model
<own state, if any — schema, retention, ownership; "stateless" is fine>

## sample
<sample code snippet or link to a sample file showing how to implement / consume>

## components
- [<module / file / path>](../../<module / file / path>)
- [<module / file / path>](../../<module / file / path>)

## depends_on            ← only when this Feature layers on others
- [[ft###|<feature>]]

## superseded_by         ← only when status = superseded
[[ft###|<replacement>]]

---

Index: [[product]]
```

## Worked example — `docs/notes/ft004.md`

```markdown
---
aliases:
  - audit log — append-only event record
status: stable
created: 2026-05-15
---
# Feature [[cat003|data]] [[cat007|security]] [[product]]

## providing
Append-only record of state-changing events (actor, timestamp, payload).
Consumers: any Implementation mutating user-visible data. 7-year retention is
part of the contract — no opt-out.

## api_surface
`audit.record(event_type: str, actor_id: str, payload: dict) -> event_id: uuid`.
Synchronous append; failure raises `AuditWriteError` and the caller aborts
the surrounding transaction (no silent drop).

## data_model
`audit_events` table: `id uuid pk`, `event_type text`, `actor_id text`,
`payload jsonb`, `recorded_at timestamptz`. Monthly partitions; 7-year
retention enforced by drop job. No updates, no deletes.

## sample
`event_id = record("request.approved", actor_id=user.id, payload={"request_id": req.id})`

## components
- [services/audit/recorder.py](../../services/audit/recorder.py)
- [services/audit/schema.sql](../../services/audit/schema.sql)
- [infra/retention/audit_drop.cron](../../infra/retention/audit_drop.cron)

## depends_on
- [[ft002|database-access]]

---

Index: [[product]]
```

## Lifecycle status values

| Status | Meaning |
|--------|---------|
| `proposed` | design under discussion; no production consumers yet |
| `stable` | at least one Implementation consumes it; constraints are the contract |
| `deprecated` | no longer recommended; existing consumers stay until migrated; no forward link |
| `superseded` | replaced; `## superseded_by [[ft###]]` body section carries the chain |

New Features default to `proposed`. Promote to `stable` once a real
Implementation lists this Feature in its `features:` section.

## Editing / superseding / deprecating

Features are append-only in spirit, like ADRs and Implementations. Three
legitimate edit modes:

- **Tighten (rare).** Reality demanded a narrower invariant — edit
  `providing` / `api_surface` in place, keep `status: stable`. Downstream
  Implementations that already met the looser contract still meet the
  tighter one.
- **Deprecate.** No replacement, but new consumers shouldn't pick this up.
  Flip `status: deprecated`; body stays for existing consumers; no forward
  link. Migrate-or-keep is the consuming Implementation's call.
- **Supersede.** Write the new `ft###` first. On the old Feature: flip
  `status: superseded` and add `## superseded_by [[ft<new>|<alias>]]` in the
  body. Never delete — the chain is part of the graph.

**Forbidden:** widening `providing` / `api_surface` on a `stable` Feature in
place. Downstream Implementations rely on the contract as written; widening
silently breaks the promise that constraints inherited by reference are
stable. Widening means a new Feature and a supersede chain.

## Updating `docs/product.md` (the hub)

The hub lists Features under `## Features` as a flat bullet list. Wikilink
form is `[[ft###|<alias>]]` — first frontmatter alias as label.

- **Create.** Append to the bullet list.
- **Supersede.** Remove the old entry, add the new one. The old file stays
  on disk; the hub points at the live Feature.
- **Deprecate.** Leave the entry (existing consumers still need to find it),
  or annotate per project taste; do not remove silently.

If `docs/product.md` doesn't exist, skip and tell the user: "Hub not found;
Feature is on disk but not linked from the hub."

## Confirmation step — what to show

After writing, the confirmation step renders five items:

1. Feature id + file path
2. `providing` restatement (one line)
3. H1 categories + any `depends_on`
4. `components` paths
5. Hub update status (added / skipped because hub missing)

Then ask once: *"Anything to revise?"* — yes → edit in place using the same
id; no → report complete.
</content>
