# category-write — examples and deep procedures

Load this when minting a non-trivial category, when the duplicate check
returns a near-match, when the user asks to rename a category, or when
you need a worked schema example without re-reading `docs/notes/akm.md`.

The canonical schema lives in `docs/notes/akm.md` (Category section).
This file is the *applied* version — examples and procedures, not the
schema definition.

---

## Worked zettel example

`docs/notes/cat003.md`:

```markdown
---
aliases:
  - security
status: stable
created: 2026-05-15
---
# Category [[product]]

## name
security

## summary
Decisions about authentication, authorization, secrets handling, threat models, and audit trails.

---

Index: [[product]]
```

**Conventions illustrated above:**

- ISO `YYYY-MM-DD` for `created`.
- One alias entry (the name) is the minimum. Add a second alias only if
  the user explicitly named a synonym they expect ADR authors to reach
  for — e.g. `aliases: [security, authn-and-authz]`. Aliases let
  `[[security]]` and `[[authn-and-authz]]` both resolve to the same
  `cat003`.
- H1 is exactly `# Category [[product]]` — no other wikilinks. Resist
  the temptation to add `[[meta]]` or `[[taxonomy]]` flavor wikilinks;
  categories are the taxonomy, they do not need to be tagged.
- Footer is a `---` horizontal rule then `Index: [[product]]` on its
  own line.

---

## Good vs bad summaries

The summary's job: an ADR author skimming summaries should immediately
know whether their decision files under this category or a sibling.

**Good:**

- *"Decisions about how data is stored, modeled, queried, and migrated."*
- *"Decisions about how the system is observed, monitored, and alerted on."*
- *"Decisions about authentication, authorization, secrets handling, threat models, and audit trails."*

**Bad:**

- *"Security stuff."* — what kind? what does an ADR author do with this?
- *"Anything related to the auth flow, the IAM service, the rate-limiting middleware, the user role hierarchy, and the audit trail integration."* — that is at least three categories.
- *"Catch-all for the platform team."* — buckets are by decision-shape, not by org chart.

If the summary needs a paragraph, the bucket is probably too broad or
you are writing the wrong zettel type (an ADR or a Feature, not a
Category).

---

## Sanity-check: is this really an ADR?

A category that is too narrow is a hidden ADR — it groups one or two
decisions and then never grows. The bucket should plausibly hold at
least a handful of ADRs over the workspace lifetime.

**Push back once** if the proposed name reads like a single decision
rather than a recurring axis:

| Proposed name | What it actually is | Where it belongs |
|---|---|---|
| `use-postgres` | ADR `adr####` | category `data` |
| `logging-format-json-vs-text` | ADR `adr####` | category `observability` |
| `rate-limit-on-public-api` | ADR `adr####` | category `api-design` or `security` |
| `single-page-app-vs-mpa` | ADR `adr####` | category `frontend` or `architecture` |

The cure is to route the user to `infinifu:adr-write` with the existing
or proposed parent category, not to mint a one-shot category.

After one round of push-back, defer to the user — they may know
something you do not about the workspace's future decision shape.

---

## Duplicate-check walkthrough

A new category that overlaps an existing one fragments the taxonomy.
ADRs end up split across `[[cat003|security]]` and
`[[cat017|security-and-auth]]` for no good reason.

**Procedure before generating an id:**

1. **List.** `ls docs/notes/cat*.md`.
2. **Scan.** For each, read frontmatter `aliases` (the human label) and
   the `## name` body section. Build a quick mental table of all
   category labels in the workspace.
3. **Compare.** Does the requested name match an existing alias —
   case-insensitively, or as a near-synonym? Near-synonyms include:
   - same word, different separator (`api-design` vs `api_design`)
   - additive variants (`security` vs `auth-and-security`)
   - role-substitutions (`infra` vs `infrastructure`)
   - direction-substitutions (`testing` vs `quality`)
4. **Stop if match.** Surface the existing category and ask the user
   whether to reuse:

   > *"Category `cat003` already covers this (alias: `security`). Use
   > the existing one, or describe how the new bucket is genuinely
   > distinct."*

5. **Proceed if clear.** Only generate the id and write the file when
   the user confirms the new bucket is non-overlapping.

If the user insists the new bucket is distinct, write it — but capture
the distinguishing dimension in the summary so the difference is
visible to future ADR authors.

---

## Rename audit (workspace-wide procedure)

If the user asks to *rename* an existing category, treat it as a
workspace-wide operation, not a single-file edit. Categories are
referenced by potentially many ADRs across the workspace lifetime.

### 1. Confirm intent

Renames are rare and expensive. Ask:

> *"This will require updating every ADR that links `[[cat<NNN>]]`.
> Confirm rename from `<old>` to `<new>`?"*

### 2. Audit consumers

Grep the workspace:

```bash
# every ADR (and any other zettel) that references the category
rg -l '\[\[cat<NNN>' docs/
rg -l '\[\[<old-alias>' docs/
```

Both forms matter: `[[cat003]]` is slug-based, `[[security]]` is
alias-based — moxide resolves both to `cat003.md`.

### 3. Decide: slug vs label

Two kinds of "rename" exist, with very different costs:

| Kind | What changes | Cost | Allowed? |
|---|---|---|---|
| Label rename | `aliases` + `## name` | low — `[[cat003]]` still resolves; piped labels like `[[cat003\|<old>]]` need updating | yes (default) |
| Slug rename | move `cat003.md` to a new filename | catastrophic — every `[[cat003]]` wikilink breaks workspace-wide | **forbidden** — slugs are stable ids |

### 4. Default to label-only rename

- Update `aliases` and `## name` in the category zettel.
- For each ADR (and Feature / Implementation / Story) whose H1 used the
  piped form `[[cat003|<old-label>]]`, update the label half. Bare
  `[[cat003]]` references need no edit.
- If the workspace also used `[[<old-alias>]]` as a bare alias-link,
  decide whether to keep the old alias in `aliases` (so both names
  resolve) or to remove it (and update every consumer that used the
  alias form).

### 5. Report the audit

In the confirmation, list every file touched so the user can
spot-check. Renames are precisely the moment where a missed consumer
becomes a silent broken link.

### 6. Deprecation request — push back

If the request is to *deprecate* a category rather than rename it,
refuse. The AKM schema does not define a deprecated-category state
because the bucket is referenced by ADRs you cannot retroactively
unlink. The cure is to stop filing new ADRs under it, not to mark the
category itself dead.

---

## Hub update — `docs/product.md`

The hub groups ADRs by category under `## Architecture Decision
Records`. A new category gets a new subsection there — initially empty
(no ADRs yet) but ready for the first ADR to land.

Append:

```markdown
## Architecture Decision Records

### [[cat001|data]]

- [[adr0001|use-postgres]]
- [[adr0004|partition-by-tenant]]

### [[cat003|security]]    ← new
```

The hub wikilink form for category headings is `### [[cat###|<name>]]`
— pipe-separated, with the alias as the label for readability.

If `docs/product.md` does not exist, skip the hub update and tell the
user *"Hub `docs/product.md` not found; new category is on disk but
not linked from the hub. Create the hub when ready."*

---

## What this skill does NOT do

- It does not write ADRs. That is `infinifu:adr-write` (which consumes
  categories).
- It does not manage H1 tag wikilinks on other zettels. That is
  `infinifu:tag-manage` — a different concept (tag-manage attaches
  existing-or-new bare wikilinks like `[[catalog]]` to stories /
  features; this skill mints `cat###` numbered taxonomy buckets).
- It does not create features, implementations, stories, personas.
  Each of those has its own typed writer.
- It does not delete or supersede categories. There is no lifecycle
  beyond `stable`; the bucket exists or does not.
- It does not retroactively re-categorize ADRs. If a category split or
  merge is needed, that is an explicit cross-zettel refactor (audit
  every affected ADR, update their H1 wikilink, possibly file a new
  ADR documenting the taxonomy change).
