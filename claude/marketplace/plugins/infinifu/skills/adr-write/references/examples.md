# adr-write — worked examples

Load this file when actually composing the markdown for a new or superseding ADR. For the canonical schema (exact frontmatter shape, lifecycle status table, supersession invariants), see `docs/notes/akm.md` § *ADR — `adr####.md`* — this file shows *how to apply* that schema in practice, it doesn't reproduce it.

## Fresh ADR (Accepted)

`docs/notes/adr0008.md`:

```markdown
---
aliases:
  - use Postgres JSONB for the events store
status: Accepted
created: 2026-05-15
---
# ADR [[cat003]] [[product]]

## title
Use Postgres JSONB for the events store

## context
The pricing pipeline emits ~5k events/day. Options surveyed: a dedicated event store (EventStoreDB), a queue + cold storage (Kafka + S3), and Postgres with a JSONB column. The team already operates Postgres for the OLTP workload and has no current capacity to onboard a second persistence runtime.

## decision
Persist events to a single `events` table in the existing Postgres cluster, with payloads stored as JSONB indexed by event type and aggregate id. Use `LISTEN/NOTIFY` for downstream fan-out instead of introducing a broker.

## consequences
Locks the runtime to a single SQL dialect (Postgres-flavoured JSONB). Migration to a different store later means rewriting both the schema and any operator-side tooling that uses JSONB. Gains: zero new operational surface, native pub/sub via `LISTEN/NOTIFY` removes the need for a separate broker on day one, and the OLTP team already owns backups and on-call. Volume must be re-evaluated above ~50k events/day — the JSONB indexing strategy degrades past that point on the current hardware tier.

---

Index: [[product]]
```

**Conventions to mirror:**

- ISO `YYYY-MM-DD` for `created`.
- One alias entry only — the canonical decision one-liner (matches `## title` verbatim).
- Category wikilink form: `[[cat###]]` bare in the H1 — no pipe label. The category name is rendered from the linked file's H1.
- H1 order: `# ADR [[cat###]] [[product]]` — category first, then `[[product]]`.
- Body sections exactly `## title`, `## context`, `## decision`, `## consequences` — downstream readers (and a future `adr-read` skill) parse on these headings.
- Footer is a `---` horizontal rule then `Index: [[product]]` on its own line.
- `## superseded_by` is **only** present when `status: Superseded`; never an empty placeholder.

## Supersession — both files

When a new ADR overturns a prior one, two files are touched.

### 1. The new ADR

`docs/notes/adr0019.md`:

```markdown
---
aliases:
  - use ClickHouse for the events store
status: Accepted
created: 2027-02-03
---
# ADR [[cat003]] [[product]]

## title
Use ClickHouse for the events store

## context
Supersedes [[adr0008|use Postgres JSONB for the events store]]. Originally we chose Postgres JSONB because the team already operated Postgres and onboarding a second persistence runtime was out of capacity. That constraint no longer holds: event volume has grown to ~80k/day (past the ~50k threshold flagged in adr0008's consequences) and the platform team now has dedicated capacity for analytical infrastructure. JSONB indexing is degrading the OLTP workload it shares cluster space with.

## decision
Persist events to a dedicated ClickHouse cluster. Stream from Postgres via a one-way CDC bridge for the migration window; cut over reads first, then writes, then decommission the `events` table.

## consequences
New operational surface (ClickHouse cluster + CDC bridge) — the platform team owns it, but on-call rotation widens. Migration window means dual-write for ~6 weeks; rollback path is reverse the cutover order. Gains: analytical queries that timed out on JSONB indexes run in seconds; the OLTP cluster returns to its design capacity. Locks us into ClickHouse's SQL dialect and replication model for the analytical path.

---

Index: [[product]]
```

The opening sentence of `## context` cites the prior ADR and explains *what changed*. This makes the new ADR self-contained for readers who arrive without context.

### 2. Patch to the prior ADR

`docs/notes/adr0008.md` — only the frontmatter status and an appended `## superseded_by` section change. **The original `## title`, `## context`, `## decision`, and `## consequences` are untouched.**

```markdown
---
aliases:
  - use Postgres JSONB for the events store
status: Superseded                        # ← was: Accepted
created: 2026-05-15
---
# ADR [[cat003]] [[product]]

## title
Use Postgres JSONB for the events store

## context
[... unchanged ...]

## decision
[... unchanged ...]

## consequences
[... unchanged ...]

## superseded_by
[[adr0019|use ClickHouse for the events store]]

---

Index: [[product]]
```

This is the **only** edit pattern that touches an existing `Accepted` ADR. Treat it as a structural change, not a content change.

**Edge case — superseding an already-Superseded ADR.** Rare but valid: a chain. Ask the user whether to chain (point the new ADR's supersedes-cite at the immediate predecessor) or to point at the *head* of the existing supersession chain. Default to chaining — it preserves the linear history.

## Good vs bad `## consequences`

The negative side of consequences is the load-bearing part. ADRs without honest negatives lose value within a year.

**Good:**

> Locks the runtime to a single SQL dialect (Postgres-flavoured JSONB). Migration to a different store later means rewriting both the schema and any operator-side tooling that uses JSONB. Gains: native pub/sub via `LISTEN/NOTIFY` removes the need for a separate broker on day one.

**Bad:**

> Pros: fast, reliable. Cons: minor lock-in.

The bad version fails the audit-in-five-years test: a future engineer reading "minor lock-in" learns nothing about what is locked in or how to escape. Push back once if consequences read like a marketing summary — the whole point of the section is to surface what the team is buying into.

## Hub update — `docs/product.md`

After writing a new ADR, append the wikilink under the matching `[[cat###|<category>]]` H3 inside `## Architecture Decision Records`. Add the H3 if the category subheading doesn't exist yet.

```markdown
## Architecture Decision Records

### [[cat003|data]]

- [[adr0007|use SQLite for local-first sync]]
- [[adr0008|use Postgres JSONB for the events store]]    ← new
```

The hub wikilink form is `[[adr####|<title>]]` — pipe-separated with the title as the readable label. (This differs from the H1 form in the ADR itself, which uses the bare `[[cat###]]` for the category.)

**On supersession:** keep the prior ADR's hub entry in place but optionally suffix `— superseded` for human readers:

```markdown
- [[adr0007|use SQLite for local-first sync]]
- [[adr0008|use Postgres JSONB for the events store]] — superseded
- [[adr0019|use ClickHouse for the events store]]    ← new
```

The `Superseded` status in the prior ADR's frontmatter is the source of truth; the hub annotation is a courtesy for human scanners.

If `docs/product.md` doesn't exist, skip the hub update and tell the user: *"Hub `docs/product.md` not found; new ADR is on disk but not linked from the hub. Create the hub when ready."*

## Field-gathering guide

ADRs are short. Don't over-interview — the goal is to record the commitment that was already made (or is being made now), not to re-debate it. If the upstream design conversation hasn't happened, the right move is `infinifu:idea-brainstorming`, not a premature ADR.

- **If the user provided everything upfront** (title / context / decision / consequences in one message): write the ADR, don't ask anything, just confirm at the end.
- **If fields are missing:** ask only for the missing pieces. Use `AskUserQuestion` when 2–4 plausible framings exist (e.g., between two competing decisions to record); use free-text when open-ended.

**Field rules of thumb:**

- **title** — one declarative sentence. Reads as *"We choose X."* or *"Use X for Y."* Mirrors the alias.
- **context** — the forces in play: the problem, the constraints, the prior art surveyed, the options considered. This is what makes the decision auditable years later. Not a novel — 2–6 sentences usually.
- **decision** — what was chosen, in active voice. *"Use Postgres for the events store."* Not *"It is recommended that we consider using Postgres."*
- **consequences** — both directions: what gets easier (positive), what gets locked in or harder (negative). See the good-vs-bad section above.

## Picking the category — tie-breaker

The H1 carries exactly one `[[cat###]]`. Unlike Implementations and Features (which allow several taxonomy buckets), ADRs commit to a single primary category. The reason: ADRs surface in `docs/product.md` grouped under one heading, and a decision that "spans categories" usually compresses two decisions — split it.

**Lookup workflow:**

1. List existing categories: `ls docs/notes/cat*.md` (or in-process equivalent).
2. For each, read the frontmatter `aliases:` — the first alias is the canonical name (e.g. `security`, `data`, `infrastructure`, `testing`, `observability`).
3. If the user named a category that matches an existing alias (case-insensitive substring or exact), use that `cat###` id.
4. If no category matches, ask once: *"No existing category matches `<name>`. Pick from: <list of aliases>, or describe a new one (I'll create the `cat###` zettel)."*
5. If they want a new category, write a minimal `cat###.md` (status `stable`, just `## name` and `## summary`) — inline this cheaply rather than delegating; there's no `category-write` skill yet.

**Tie-breaker when two categories tempt:** prefer the category whose accepted ADR set this decision most directly extends. *Where would a future engineer look first to discover this decision?* That category wins.

## What this skill explicitly does NOT do

These are negative-space rules that catch real failure modes — keep them callable from the slim SKILL.md's critical_rules list.

- It does not run a design discussion. That's `infinifu:idea-brainstorming` — invoke that *before* this skill if the decision hasn't been made yet.
- It does not write user stories, features, implementations, personas, or categories — only ADRs.
- It does not edit the `## context` / `## decision` / `## consequences` of an `Accepted` ADR. Those are immutable; supersede instead.
- It does not retroactively re-justify a decision. The original `## context` stays as captured, even if it later reads as naive — that naivete is the historical record.
- It does not produce multiple ADRs from one capture. One decision per invocation; compound requests get rejected at the atomicity gate (delegated up to `infinifu:zettel-write` when invoked from there).
- It does not delete ADRs. `Deprecated` and `Superseded` are the retirement states — the file stays on disk forever.

## Why immutability matters

ADRs are the historical record of constraint-evolution. The implementation tree (`im###`) references categories, and `[[product]]` links to the live ADR set. Rewriting an old ADR rewrites that history and breaks back-references in retrospectives and audits. The discipline isn't fussiness — it's what makes the corpus trustworthy when someone five years later asks "why did we end up here?".

The only safe in-place edit on an `Accepted` ADR is *widening* `## consequences` to record a downstream effect the original author didn't foresee — never narrowing, never rewriting the decision narrative. If the change would alter the *meaning* of what was chosen, you are actually superseding; write a new ADR.
