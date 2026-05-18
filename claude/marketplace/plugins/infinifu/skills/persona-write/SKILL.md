---
name: persona-write
description: Use when the user wants to create, add, register, or define a Persona — a user role the system serves — and emit a new `docs/notes/pn###.md` AKM zettel with frontmatter (aliases/status/created) and body sections (name/summary/primary_goals/open_questions) per the schema in `docs/notes/akm.md`. Invoke this whenever someone says "create a persona", "add a new user role", "register persona X", "we have a new actor type", "who is the requestor", "pn### for X", or describes a fresh role/actor that stories will reference via `[[pn###|alias]]`. Pick this over `infinifu:story-write` when the request is about the role itself (not a want from that role) and over `infinifu:zettel-write` when the user has already named "persona" as the artifact — `zettel-write` is the routing orchestrator that delegates here for persona shapes.
---

<skill_overview>
Capture a single user role as a new AKM Persona zettel under `docs/notes/pn###.md`. Personas anchor stories via the `role` wikilink and group the backlog under `## Stories` subheadings in the [[product]] hub. They describe **who** the system serves — context, goals, and what we still don't know about them — not what that role wants done (that lives on the story). The skill exists so persona creation has one home: `infinifu:story-write` no longer inlines a minimal `pn###.md` fallback, it delegates here.
</skill_overview>

<rigidity_level>
MEDIUM FREEDOM — schema shape and id sequence are fixed because every story that references `[[pn###|alias]]` depends on them, and a wrong alias propagates into the hub's `## Stories` grouping. Content (summary, goals, open questions) is whatever the user actually knows; the `draft` status exists for the case where only the alias and one sentence of context are known.

Non-negotiable: (1) filename is `pn###.md`, three-digit zero-padded, max-of-existing + 1, gaps never reused; (2) `aliases[0]` is the canonical label every story links with via `[[pn###|<first-alias>]]`; (3) schema is `[[product]]` in the H1, `Index: [[product]]` footer, `## name` / `## summary` / `## primary_goals` / `## open_questions` in that order.
</rigidity_level>

<quick_reference>

| Field | Where | Rule |
|-------|-------|------|
| Filename | `$AKM_ROOT/docs/notes/pn###.md` | Three-digit zero-padded, sequential, max+1, no gap reuse |
| `aliases[0]` | frontmatter | Canonical short label (`requestor`, `approver`, `field-sales-rep`) — kebab-case, what stories link to |
| `status` | frontmatter | `draft` (open_questions populated) / `validated` (resolved) / `retired` (role no longer served) |
| `created` | frontmatter | ISO `YYYY-MM-DD` |
| H1 | body | `# Persona [[product]]` — no category tags, no flow tags |
| `## name` | body | Full role name in prose (`Field Sales Rep`, `Warehouse Approver`) |
| `## summary` | body | One paragraph: who, where, why they touch the system |
| `## primary_goals` | body | Bullets — role-shaped, not story-shaped |
| `## open_questions` | body | Bullets — unresolved discovery; empty for `validated` |
| Footer | body | `---` rule, then `Index: [[product]]` |

**Status transitions:**

| From → To | Trigger |
|-----------|---------|
| `draft` → `validated` | `## open_questions` empty or moved to ADR / decision log |
| `validated` → `retired` | Role no longer served — keep file, add `## retired`, leave existing story back-links |
| `draft` → `retired` | Persona dropped before validation — same treatment |

</quick_reference>

<when_to_use>
**Use when:**

- User asks to create / add / register / define a persona or user role explicitly
- `infinifu:story-write` is about to write a story whose `role` references a `[[pn###]]` that doesn't exist yet — delegate here instead of inlining a stub
- A brainstorm or refinement session lands on a new actor that future stories will reference
- User wants to revise an existing persona — re-emit the same `pn###.md` with updated body (personas are mutable; unlike ADRs they don't supersede in place)

**Don't use for:**

- Capturing what a role *wants done* → that's a story, use `infinifu:story-write`
- Generic concept notes about user types / market segments that no story will reference → `infinifu:zettel-write`
- Tagging or H1 wikilink edits on existing zettels → `infinifu:tag-manage`
- Mapping stories to personas after the fact (the link lives on the story) → re-emit the story via `infinifu:story-write`
</when_to_use>

<workspace_resolution>
Personas are shared knowledge — they live on **main**, even from a feature-branch worktree. Resolve before any file op:

```bash
AKM_ROOT="$(akm-root)"
```

`akm-root` returns the main-worktree path (default branch); outside git, cwd. Anchor every path on `$AKM_ROOT` (`$AKM_ROOT/docs/notes/pn###.md`, `$AKM_ROOT/docs/product.md`). If `akm-root` errors, surface its stderr and abort — never silently land a persona on the feature branch.

Personas are a `draft → validated → retired` artifact and typically born as `draft`, so this writer **stages on main without committing**: `git -C "$AKM_ROOT" add docs/notes/pn<NNN>.md`. The next lifecycle commit happens when the persona is referenced from a `ready` story or flipped to `validated` by spec-refinement. See the per-stage commit table in `docs/notes/akm.md#workspace-resolution`.
</workspace_resolution>

<the_process>

```dot
digraph persona_create {
    "Resolve AKM root" [shape=box];
    "Storage exists?" [shape=diamond];
    "Bootstrap docs/notes/" [shape=box];
    "Existing persona?" [shape=diamond];
    "Re-emit same id" [shape=box];
    "Gather alias + body" [shape=box];
    "Generate id (pn###)" [shape=box];
    "Write pn###.md zettel" [shape=box];
    "Stage on main" [shape=box];
    "Confirm with user" [shape=doublecircle];

    "Resolve AKM root" -> "Storage exists?";
    "Storage exists?" -> "Bootstrap docs/notes/" [label="no"];
    "Storage exists?" -> "Existing persona?" [label="yes"];
    "Bootstrap docs/notes/" -> "Existing persona?";
    "Existing persona?" -> "Re-emit same id" [label="revising"];
    "Existing persona?" -> "Gather alias + body" [label="new"];
    "Re-emit same id" -> "Stage on main";
    "Gather alias + body" -> "Generate id (pn###)";
    "Generate id (pn###)" -> "Write pn###.md zettel";
    "Write pn###.md zettel" -> "Stage on main";
    "Stage on main" -> "Confirm with user";
}
```

1. **Check storage.** Resolve `$AKM_ROOT` first. If `$AKM_ROOT/docs/notes/` is missing, create it. If `$AKM_ROOT/docs/product.md` is missing, warn *"No `docs/product.md` found in `$AKM_ROOT`; AKM workspace not initialized."* and proceed with a dangling `[[product]]` (or abort if the user prefers).

2. **Generate id.** List `$AKM_ROOT/docs/notes/pn*.md`, extract numbers, max + 1, zero-pad to 3 digits. Start at `001` if none. Gaps from retired personas are **not** reused — wikilink stability is the point of the sequential id.

3. **Choose the canonical alias.** `aliases[0]` is what every story will use as label inside `[[pn###|alias]]`. Kebab-case, short, role-shaped (`requestor`, `approver`, `field-sales-rep`). Stable once chosen — see `references/examples.md` for why renaming is expensive. Add more aliases only if the user gave multiple equivalent phrasings.

4. **Gather body content.** Personas are small — don't over-interview. Ask only for what's missing, one focused question per turn:
   - `## name` — full role name in prose ("Field Sales Rep", "Warehouse Approver").
   - `## summary` — one paragraph (≤3 sentences): who, where, why they touch the system.
   - `## primary_goals` — 2–4 bullets, role-shaped (not story-shaped — push back once if they read like stories).
   - `## open_questions` — bullets of unresolved discovery. Empty iff `validated`.

5. **Set status.** Default to `draft`. Flip to `validated` only when `## open_questions` is empty (or migrated to an ADR / decision log). `validated` at write time is rare but legitimate when formalizing a long-running role.

6. **Write the zettel.** Compose `$AKM_ROOT/docs/notes/pn<NNN>.md` per the schema in `docs/notes/akm.md#persona--pnmd`. Do **not** touch `$AKM_ROOT/docs/product.md` — personas surface in the hub via stories, not directly (see `critical_rules`).

7. **Stage on main.** `git -C "$AKM_ROOT" add docs/notes/pn<NNN>.md`. No commit — the next lifecycle stage carries that.

8. **Confirm.** Show id + absolute file path (so the user sees the AKM root when invoked from a worktree), the canonical alias (*"Stories will reference this as `[[pn<NNN>|<alias>]]`"*), the name + one-line summary gist, the status, the open-questions count, the staging state on main, and note that the hub was **not** updated. Ask once: *"Anything to revise?"* If yes, edit in place.

See `references/examples.md` for fresh-persona, story-write-delegation, and revision walkthroughs.

</the_process>

<critical_rules>

- **One role per file.** Two roles ("approver and reviewer") split into two persona files with mutual `[[pn###]]` links in their summaries — not one compound persona.
- **First alias is forever.** It becomes the label on every story that references this persona. Renaming later requires re-emitting every linked story; push back once if the user proposes a vague or shifting label.
- **Goals are role-shaped.** *"Get product in customer hands"* belongs on the persona; *"upload a CSV to bulk-create orders"* belongs on a `us###`.
- **`open_questions` is honest, not stylistic.** Don't fabricate questions to look thorough; don't empty the field just to flip to `validated`. `draft` is a fine resting state.
- **Don't touch the hub.** `docs/product.md` only changes when a story references this persona — that's `infinifu:story-write`'s job. Personas are a supporting type with no `[[product]]` section of their own.
- **Retire, never delete.** A retired persona keeps its file (existing story back-links are history). Add a `## retired` section with date + reason. Ids are never reused.
- **No category tags in the H1.** Just `# Persona [[product]]`. Personas are supporting with no taxonomy.

</critical_rules>

<verification_checklist>

Before reporting complete:

- [ ] Filename is `pn<NNN>.md` — three digits, zero-padded, max-existing + 1, no gap reuse
- [ ] Frontmatter has `aliases:` (≥ 1, first is kebab-case short label), `status:`, `created:` (ISO date)
- [ ] H1 is exactly `# Persona [[product]]` — no extra tags
- [ ] Body sections in order: `## name`, `## summary`, `## primary_goals`, `## open_questions`
- [ ] `## summary` is one paragraph (no headings, no sub-bullets)
- [ ] `## primary_goals` are role-shaped, not story-shaped
- [ ] `## open_questions` empty *iff* `validated` (or `retired` with no follow-up)
- [ ] Footer is `---` rule then `Index: [[product]]` on its own line
- [ ] `$AKM_ROOT/docs/product.md` was **not** touched
- [ ] File was staged on main (`git -C "$AKM_ROOT" add docs/notes/pn<NNN>.md`) and no commit was created
- [ ] Confirmation surfaces the absolute path under `$AKM_ROOT` so the user sees where it landed
- [ ] Canonical alias shown back to the user so they can object before story-write uses it

</verification_checklist>

<integration>

**Called by:** `infinifu:story-write` (when a story's `role` references a `[[pn###]]` that doesn't exist — story-write hands off, this skill writes the persona file, returns `pn###` + canonical alias, story-write resumes); `infinifu:zettel-write` (orchestrator routes persona-shaped capture requests here); directly by the user when establishing a role upfront.

**Calls:** nothing — writes one file and returns. Deliberately does **not** update `docs/product.md` (story-write's responsibility).

**Complements:** `infinifu:story-write` (uses these personas as `role` links), `infinifu:story-read` / `infinifu:story-find` (resolve `[[pn###|alias]]` back to the persona file), `infinifu:tag-manage` (separate skill for H1 tags on stories — personas don't carry H1 tags so it doesn't apply).

</integration>

<references>

- `docs/notes/akm.md` — canonical AKM schema. Section `## Persona — pn###.md` is the source of truth for body shape, frontmatter keys, and lifecycle. **Load when in doubt about any schema detail** rather than duplicating it here.
- `references/examples.md` — three worked examples (fresh persona with open questions, story-write delegation handoff, revision/re-emit). **Load when** unclear how the workflow plays out end-to-end, especially for the alias-stability rationale or the status-lifecycle nuances.
- `infinifu:meta-skill-writing` — house style for this skill's own SKILL.md. **Load when refactoring** this file.

</references>
</content>
</invoke>