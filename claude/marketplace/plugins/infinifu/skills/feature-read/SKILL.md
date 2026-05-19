---
name: feature-read
description: Use when the user wants to see, list, find, or look up Features — the reusable capabilities the system provides once and many Implementations consume. Reads AKM feature zettels (`docs/notes/ft###.md`) and returns a filtered table, a single feature detail, or a full render. Invoke this whenever someone asks "what features do we have", "list our shared services", "show me feature X", "which capabilities exist", "are there any deprecated features", "find features about notifications", or any phrasing that wants to view the catalog of horizontal building blocks.
---

# Feature Read

## Overview

Read feature zettels under `docs/notes/ft###.md` and present them in the format that best fits the user's question. Three output modes — pick one, don't combine.

**Announce at start:** "Using feature-read skill to surface capabilities."

## AKM Workspace Resolution

Readers always anchor on the main worktree's view of the AKM, never the
feature worktree's local copy (which may be stale or branch-divergent).
Resolve first:

```bash
AKM_ROOT="$(akm-root)"
```

All lookups anchor on `$AKM_ROOT/docs/notes/...`. If `akm-root` errors,
surface its stderr and fall back to cwd with the warning *"reading from
cwd worktree — may be stale; check out the default branch for canonical
view"*.

## Storage

**Backend:** AKM. Features live as individual markdown zettels in `$AKM_ROOT/docs/notes/ft###.md`. Schema is documented in `docs/notes/akm.md`; this skill only needs the slice below.

If `$AKM_ROOT/docs/notes/` has no `ft*.md` files: tell the user "No features found. Use feature-write to add one."

### Zettel slice this skill needs

```markdown
---
aliases:
  - <human-readable capability one-liner>
status: <proposed|stable|deprecated|superseded>
created: YYYY-MM-DD
---
# Feature [[cat###]] [[cat###]] [[product]]

## providing
<one-paragraph: what capability + who consumes it>

## api_surface
<how consumers invoke it>

## data_model
<own state, if any>

## sample
<sample snippet or pointer>

## components
- <module / file / path>

## superseded_by
[[ft###|<replacement>]]   # only when status = superseded
```

**Key extraction rules:**

- `id` — filename slug (`ft001`).
- `title` — first alias.
- `categories` — every `[[cat###]]` wikilink in the H1 except `[[product]]`. Render as slug.
- `providing` — paragraph under `## providing` (the headline capability).
- `api_surface`, `data_model`, `sample` — sections (free-form).
- `components` — bullets.
- `superseded_by` — wikilink under `## superseded_by`; only meaningful when status=superseded.

Omit silently if a section is missing.

## Mode Selection

```dot
digraph mode_select {
    "User query" [shape=oval];
    "Specific id mentioned?" [shape=diamond];
    "Filter implied?" [shape=diamond];
    "Detail mode" [shape=box];
    "Table mode" [shape=box];
    "Render mode" [shape=box];

    "User query" -> "Specific id mentioned?";
    "Specific id mentioned?" -> "Detail mode" [label="yes (ft### or unique title)"];
    "Specific id mentioned?" -> "Filter implied?" [label="no"];
    "Filter implied?" -> "Table mode" [label="yes"];
    "Filter implied?" -> "Render mode" [label="no"];
}
```

### Detail mode triggers
- Query contains `ft###` (case-insensitive).
- Names one feature by title.
- "show me feature X", "what does ft005 do".

### Table mode triggers
- Status filters: `proposed`, `stable`, `deprecated`, `superseded`.
- Category filters: "features in cat003", "security features".
- Keyword search: "features about notifications".
- "List features", "how many features are stable".

### Render mode triggers
- "Show me the feature catalog", "what capabilities do we have".
- No filter and no id.

## Reading the zettels

1. List ids: `ls "$AKM_ROOT/docs/notes/"ft*.md`.
2. Per mode:
   - **Detail** — single file.
   - **Table** — `head -30` is enough (frontmatter + H1 + `## providing` first line).
   - **Render** — full read.

## Mode 1: Detail

```markdown
## [id] — [title]

**Categories:** [cat001, cat002]    **Status:** [status]    **Created:** [created]

**Providing:** [providing paragraph]

**API surface:** [api_surface]

**Data model:** [data_model]

**Components:**
- [path 1]
- [path 2]

**Superseded by:** [ft###]    *(only if status = superseded)*
```

Drop sections that are empty.

If id not found: "Feature `ft001` not found. Closest matches: ..." with 1-3 candidates.

## Mode 2: Table

| id | status | categories | title | providing |

Sort by id ascending. Truncate `providing` to ~50 chars with `…`. Render `categories` as a comma-joined slug list.

After the table: `N features matched (X stable, Y proposed, Z deprecated, W superseded).` Omit zero buckets.

## Mode 3: Render

Grouped by status: `stable` → `proposed` → `deprecated` → `superseded`. Within each group sort by id ascending.

```markdown
# Feature Catalog

## Stable

### ft001 — notifications service
**Categories:** cat002 (data), cat004 (delivery)

**Providing:** ...

**API surface:** ...

### ft003 — ...
```

End: `Total: N features (X stable, Y proposed, Z deprecated, W superseded).`

## Filter Parsing

| User says | Match against |
|---|---|
| "proposed" | `status: proposed` |
| "stable", "active", "in use" | `status: stable` |
| "deprecated" | `status: deprecated` |
| "superseded", "replaced" | `status: superseded` |
| "in cat###", "category X" | H1 contains the category id or its alias |
| "about X", "for Y" | any text field (title, providing, api_surface, components) |

Multiple filters compose with AND.

## What This Skill Does NOT Do

- It does not modify features. To edit/supersede, use `feature-write`.
- It does not list consuming Implementations directly — that surfaces via moxide back-refs or `implementation-read --consumes ft###`. Defer to those tools.

## When to Defer to Other Skills

- Add / deprecate / supersede a feature → `feature-write`.
- See which Implementations consume a feature → `implementation-read`.
- Pick a feature to consume in a new spec → `spec-writing` (it surveys features for you).
