---
name: persona-read
description: Use when the user wants to see, list, find, or look up personas — the user roles the system serves. Reads AKM persona zettels (`docs/notes/pn###.md`) and returns a filtered table, a single persona detail, or a full render. Invoke this whenever someone asks "what personas do we have", "who are our users", "show me persona X", "list user roles", "which roles exist", "tell me about the requestor", or any phrasing that wants to view who the system serves.
---

# Persona Read

## Overview

Read persona zettels under `docs/notes/pn###.md` and present them in the format that best fits the user's question. Three output modes — pick one based on the query, don't combine.

**Announce at start:** "Using persona-read skill to surface roles."

## Data source

All reads go through the `akm` CLI — never resolve `AKM_ROOT` or parse
frontmatter by hand. The CLI is the single gatekeeper: it enforces the
strict main-worktree rule and returns canonical state.

```bash
akm list pn --json | from json         # all personas as structured rows
akm read pn001                          # full markdown of one persona
```

If `akm` refuses with exit 2, surface its stderr and stop.
If `akm list pn --json` returns `[]`: tell the user "No personas found.
Use persona-write to add one." Don't fabricate.

## Schema (this skill's slice)

```markdown
---
aliases:
  - <short role label>     # first alias = the slug stories reference
status: <draft|validated|retired>
created: YYYY-MM-DD
---
# Persona [[product]]

## name
<full role name>

## summary
<one-paragraph context>

## primary_goals
- <goal>

## open_questions
- <unresolved question>
```

**Key extraction rules:**

- `id` — filename slug (`pn001`).
- `label` — first entry under `aliases:` (this is what stories reference via `[[pn###|label]]`).
- `name` — text under `## name`.
- `summary` — paragraph under `## summary`.
- `primary_goals`, `open_questions` — bullets under those H2s.
- `status`, `created` — frontmatter scalars.

If a persona is missing any of these sections, render what's there and omit silently.

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
    "Specific id mentioned?" -> "Detail mode" [label="yes (e.g. pn001 or unique label match)"];
    "Specific id mentioned?" -> "Filter implied?" [label="no"];
    "Filter implied?" -> "Table mode" [label="yes"];
    "Filter implied?" -> "Render mode" [label="no"];
}
```

### Detail mode triggers
- Query contains `pn###` (case-insensitive).
- Query names one persona by label or full name.
- "show me persona X", "tell me about the X role".

### Table mode triggers
- Status filters: `draft`, `validated`, `retired`.
- Open-question filter: "personas with open questions".
- Keyword search: "personas about approval", "roles related to catalog".
- "List …", "how many … are validated".

### Render mode triggers
- "Show me the personas", "what user roles do we have", "print all personas".
- No filter and no specific id.

Ambiguous between table and render → prefer table.

## Reading the zettels

- **Detail** — `akm read <id>` (e.g. `akm read pn001`).
- **Table / Render** — `akm list pn --json | from json` returns
  type / id / name / status / created / categories. For body content
  (`## summary`, `## primary_goals`, etc.) that the list doesn't carry,
  fetch via `akm read <id>` per matching row.

`akm list` already sorts by `type status id` — natural ordering works.

## Mode 1: Detail

```markdown
## [id] — [label]

**Name:** [name]    **Status:** [status]    **Created:** [created]

[summary]

**Primary goals:**
- [goal 1]
- [goal 2]

**Open questions:**
- [question 1]
```

If `## open_questions` is empty or contains only placeholder dashes, omit the **Open questions** section.

If id not found: "Persona `pn001` not found. Closest matches: ..." and list 1-3 candidates by label similarity. Don't guess.

## Mode 2: Table

| id | status | label | summary |

Sort by id ascending. Truncate `summary` to ~60 chars with `…` if longer.

After the table: `N personas matched (X validated, Y draft, Z retired).`

If zero matched: state the filter explicitly. Example: "No personas with status=validated and label contains 'admin'."

## Mode 3: Render

Grouped by status: `draft` → `validated` → `retired`. Within each group sort by id ascending.

```markdown
# Personas

## Validated

### pn001 — requestor
**Name:** Field Sales Rep

<summary>

- <goal 1>
- <goal 2>

### pn002 — ...
```

End with: `Total: N personas (X validated, Y draft, Z retired).` Omit zero-count buckets.

## Filter Parsing

| User says | Match against |
|---|---|
| "draft", "pending", "open" | `status: draft` |
| "validated", "active" | `status: validated` |
| "retired", "deprecated" | `status: retired` |
| "with open questions" | `open_questions` non-empty |
| "about X", "related to Y" | any text field (label, name, summary, goals, questions; case-insensitive) |

Multiple filters compose with AND.

## What This Skill Does NOT Do

- It does not modify personas. To edit, use `persona-write` or edit the markdown directly.
- It does not validate wikilinks; moxide LSP is the source of truth.
- It does not estimate fit between personas and stories.

## When to Defer to Other Skills

- Add/edit a persona → `persona-write`.
- Find stories that target a persona → `story-read` (filter by role) or `story-find`.
- General zettel routing → `zettel-write`.
