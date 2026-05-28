---
name: category-write
description: Use when the user wants to create a new ADR taxonomy bucket — a Category zettel (`cat###.md`) that ADRs file under via their H1 `[[cat###]]` link and that any zettel can reuse as a tag. Emits a new `docs/notes/cat###.md` AKM zettel with the minimal Category schema (frontmatter `aliases`/`status: stable`/`created`, body `## name` and `## summary`, `Index: [[product]]` footer). This skill owns the Category schema (frontmatter shape, body, lifecycle); shared styling (atomicity, 80-char wrap, link discipline) is enforced by `infinifu:zettel-write`; `docs/notes/akm.md` carries only the top-level AKM model overview. Invoke this whenever someone says "create a category", "add a new ADR taxonomy bucket", "we need a `cat###` for X", "register a category for security/data/infra/...", "make a new tag bucket", or otherwise wants to mint the taxonomy bucket itself rather than apply existing tags. Pick this over `infinifu:tag-manage` (which manages H1 tag wikilinks on existing zettels — a different concept, not a bucket-minting tool) and over `infinifu:adr-write` (which *consumes* categories rather than creating them). Categories are stable, slow-changing, append-only — there is no draft/superseded lifecycle, just `stable` from birth.
---

<skill_overview>
Mint a new Category zettel — a taxonomy bucket for ADRs and a reusable tag for any zettel. Output: one file at `docs/notes/cat###.md` per the schema this skill owns (see `<schema>` block below). Categories are tiny: a name, a one-line summary of what kinds of decisions belong in the bucket, and that is the whole card.

**Announce at start:** "Using category-write skill to mint a new Category bucket."
</skill_overview>

<rigidity_level>
MEDIUM FREEDOM — the schema and the duplicate / sanity / rename-audit gates are non-negotiable because categories are referenced by potentially many ADRs across the lifetime of the workspace. The conversation to gather name and summary adapts to how much the user already supplied.
</rigidity_level>

<quick_reference>
| Step | Action | Output |
|------|--------|--------|
| 1 | Resolve `AKM_ROOT="$(akm-root)"`; bootstrap `$AKM_ROOT/docs/notes/` if missing | workspace ready |
| 2 | Duplicate check — scan existing `cat###` aliases under `$AKM_ROOT` | go / stop-and-point |
| 3 | Gather name (kebab noun phrase) + summary + scope_notes | three strings |
| 4 | Sanity-check bucket scope (is this really an ADR?) | go / push-back |
| 5 | Pipe composed body to `akm cat write <name> --stdin`; capture `Id: cat###` | `$AKM_ROOT/docs/notes/cat###.md` staged, id captured |
| 6 | Append `### [[cat###\|<name>]]` heading under product.md `## Architecture Decision Records` | hub linked |
| 7 | Commit on main (`git -C "$AKM_ROOT" commit`) | stable artifact landed |
| 8 | Confirm with rename-cost reminder | user signs off |

**Id allocation, frontmatter, H1, footer, and staging are the CLI's job** (`akm cat write`); this skill composes only the body sections and handles the product.md hub edit + commit.

**Schema source of truth:** this skill (`<schema>` block below); styling via `infinifu:zettel-write`.
</quick_reference>

<schema>

**Frontmatter.**

```yaml
aliases:
  - <category name>
status: stable
created: YYYY-MM-DD
```

**Body skeleton.**

```markdown
# Category [[product]]

## name
<category name>

## summary
<one-liner: what kinds of decisions belong here>

## scope_notes
<what is in vs out of this bucket; near-neighbors it must not absorb>

---

Index: [[product]]
```

**Required wikilinks.** `[[product]]` in H1, `Index: [[product]]` footer.
No other wikilinks in the H1 — Categories *are* the taxonomy layer; they
do not get tagged by other categories.

**Lifecycle.** Status is always `stable` from birth. No `draft` /
`proposed` / `deprecated` / `superseded` states. Categories are
append-only — if a category turns out to be wrong, the cure is a new
category plus a wikilink audit on the affected ADRs, not a status flip.
Rename of the *label* (aliases + `## name`) is cheap; rename of the
*slug* (file move) is forbidden — slugs are stable ids.

</schema>

<workspace_resolution>
Categories are shared taxonomy — they live on **main**, even from a feature-branch worktree. Resolve before any file op:

```bash
AKM_ROOT="$(akm-root)"
```

`akm-root` returns the main-worktree path (default branch); outside git, cwd. Anchor every path on `$AKM_ROOT` (`$AKM_ROOT/docs/notes/cat###.md`, `$AKM_ROOT/docs/product.md`). If `akm-root` errors, surface its stderr and abort — never silently land a category on the feature branch.

Categories are **stable from birth** — no `draft` / `proposed` / `superseded` lifecycle. This writer therefore **commits on main on creation**, not stages:

```bash
git -C "$AKM_ROOT" add docs/notes/cat<NNN>.md docs/product.md
git -C "$AKM_ROOT" commit -m "feat(akm): add cat<NNN> <alias>"
```

Categories are append-only and immediately referenced by ADRs / Features / Implementations whose H1 must resolve, so the commit lands with the file. See the per-stage commit table in `docs/notes/akm.md#workspace-resolution`.
</workspace_resolution>

<when_to_use>
- "Create a category for security / data / observability / …"
- An ADR writer needs a `[[cat###]]` that does not yet exist
- A Feature or Implementation needs a category bucket to slot under
- Ad hoc: "we need a `cat###` for X"

**Don't use for:**
- Writing the ADR itself (the thing that *consumes* a category) → `infinifu:adr-write`
- Attaching free-form tag wikilinks like `[[catalog]]` to a story → `infinifu:tag-manage` (different layer: bare slugs vs numbered `cat###` buckets)
- Generic concept notes that don't belong to the ADR taxonomy → `infinifu:zettel-write`
- Renaming a category as a single-file edit — see the rename-audit rule below
</when_to_use>

<the_process>

```dot
digraph category_create {
    "Resolve AKM root" [shape=box];
    "Storage exists?" [shape=diamond];
    "Bootstrap docs/notes/" [shape=box];
    "Check for duplicate" [shape=diamond];
    "Stop — point to existing" [shape=box];
    "Gather name + summary + scope_notes" [shape=box];
    "Sanity-check bucket scope" [shape=diamond];
    "Push back on too-narrow" [shape=box];
    "akm cat write --stdin (allocates id, stages)" [shape=box];
    "Update product.md hub" [shape=box];
    "Commit on main" [shape=box];
    "Confirm with user" [shape=doublecircle];

    "Resolve AKM root" -> "Storage exists?";
    "Storage exists?" -> "Bootstrap docs/notes/" [label="no"];
    "Storage exists?" -> "Check for duplicate" [label="yes"];
    "Bootstrap docs/notes/" -> "Check for duplicate";
    "Check for duplicate" -> "Stop — point to existing" [label="match"];
    "Check for duplicate" -> "Gather name + summary + scope_notes" [label="none"];
    "Gather name + summary + scope_notes" -> "Sanity-check bucket scope";
    "Sanity-check bucket scope" -> "Push back on too-narrow" [label="too narrow"];
    "Push back on too-narrow" -> "Gather name + summary + scope_notes";
    "Sanity-check bucket scope" -> "akm cat write --stdin (allocates id, stages)" [label="ok"];
    "akm cat write --stdin (allocates id, stages)" -> "Update product.md hub";
    "Update product.md hub" -> "Commit on main";
    "Commit on main" -> "Confirm with user";
}
```

## Steps

1. **Storage bootstrap.** Resolve `AKM_ROOT="$(akm-root)"` first. Create `$AKM_ROOT/docs/notes/` if missing. If `$AKM_ROOT/docs/product.md` is missing, warn ("AKM workspace not initialized in `$AKM_ROOT`") and either proceed (zettel will reference a dangling `[[product]]`) or abort per the user's choice.
2. **Duplicate check.** `ls "$AKM_ROOT/docs/notes/"cat*.md`, read each frontmatter `aliases` and `## name`. If the requested name matches an existing alias (case-insensitive, including near-synonyms like `security` vs `auth-and-security`), stop and surface the match. Full procedure in `references/examples.md` → *Duplicate-check walkthrough*.
3. **Gather name + summary + scope_notes.** Name: short kebab-friendly noun phrase (`security`, `data`, `observability`). Summary: one sentence stating which kinds of architectural decisions belong here. Scope_notes: what is in vs out of the bucket and which near-neighbor categories it must not absorb. If all arrived upfront, write; if pieces are missing, ask one focused question per turn (`AskUserQuestion` when 2–4 names are in play). Good/bad summaries in `references/examples.md`.
4. **Sanity-check scope.** Is this a recurring axis of decision-making, or a single decision in disguise? Names like `use-postgres`, `logging-format-json-vs-text`, `rate-limit-on-public-api` are ADRs, not categories — the parent category already exists (`data`, `observability`, `api-design`). Push back once, then defer to the user.
5. **Write via the CLI.** Pipe the composed body (the three `## name / ## summary / ## scope_notes` sections only — no frontmatter, no H1, no footer) to the typed writer, which allocates the id, writes frontmatter + tagless H1 + footer, and stages the file on the default branch:

   ```bash
   printf '## name\n%s\n\n## summary\n%s\n\n## scope_notes\n%s\n' \
     "$name" "$summary" "$scope_notes" \
     | akm cat write "$name" --stdin
   ```

   Capture the allocated id from the structured `Id: cat###` first line of stdout. The CLI owns id allocation (max existing + 1, gaps never reused), frontmatter shape, the tagless `# Category [[product]]` H1, the `Index: [[product]]` footer, and `git add`. Do **not** hand-write the file. If the alias already exists the CLI short-circuits and prints the existing path — treat that as the duplicate-check failing and stop.
6. **Update the hub.** Append `### [[cat###|<name>]]` under `## Architecture Decision Records` in `$AKM_ROOT/docs/product.md`, initially with no ADR bullets. Skip and warn if the hub does not exist.
7. **Commit on main.** Categories are stable from birth — land the staged file (already `git add`ed by the CLI) and the hub edit in one commit:

   ```bash
   git -C "$AKM_ROOT" add docs/notes/cat<NNN>.md docs/product.md
   git -C "$AKM_ROOT" commit -m "feat(akm): add cat<NNN> <alias>"
   ```

   If the hub was not updated (no `product.md`), commit only the zettel.
8. **Confirm.** Report id, absolute file path under `$AKM_ROOT`, name, summary, hub-status, the commit sha, and the rename-cost reminder ("Renaming this later means auditing every ADR that links `[[cat<NNN>]]`"). Ask once: "Anything to revise?"

</the_process>

<critical_rules>

- **Status is always `stable`.** There is no `draft` / `proposed` / `superseded` lifecycle for categories. If a category turns out to be wrong, the cure is a new category plus a wikilink audit on the affected ADRs, not a status flip.
- **No deprecation either.** The AKM schema does not define a deprecated-category state because the bucket is referenced by ADRs you cannot retroactively unlink. Push back hard if the user asks to deprecate; route them to "stop filing new ADRs under it" instead.
- **Tagless H1.** `# Category [[product]]` and nothing else. Categories *are* the taxonomy layer — they do not get tagged by other categories. This is the only zettel type with a single-wikilink H1.
- **Run the duplicate check before generating an id.** A second `security` bucket fragments every future ADR search across `[[cat003|security]]` and `[[cat017|security-and-auth]]`. The check is cheap; the fragmentation is forever.
- **Run the sanity check before writing.** A category that is too narrow is a hidden ADR. If the proposed name reads like a single decision, route to `infinifu:adr-write` with the existing parent category rather than minting a one-shot bucket.
- **Rename is a workspace-wide audit, not a single-file edit.** Renaming the *label* (aliases + `## name`) is cheap because wikilinks `[[cat###]]` still resolve. Renaming the *slug* (moving `cat003.md`) is forbidden — slugs are stable ids. Either way, grep `[[cat<NNN>` and `[[<old-alias>` across the workspace and surface every consumer in the confirmation. Full procedure in `references/examples.md` → *Rename audit*.
- **Gaps are never reused.** `cat003` missing means `cat003` is gone forever. Always take max + 1.
- **Exactly three body sections.** The canonical Category body is `## name / ## summary / ## scope_notes` — nothing more. `## examples` or `## related` belong on the ADRs that file under this category, not on the category itself.
- **Don't hand-write the file.** Id allocation, frontmatter, the tagless H1, and the footer are the CLI's job (`akm cat write --stdin`). The skill composes only the three body sections and pipes them in. Raw `docs/notes/cat###.md` writes are the drift this migration removed.

</critical_rules>

<integration>

**Called by:**
- `infinifu:adr-write` — when an ADR's H1 needs a `[[cat###]]` bucket that does not yet exist, the ADR writer pauses, invokes this skill to mint the category, then resumes.
- `infinifu:feature-write` and `infinifu:implementation-write` — when an H1 `[[cat###]]` is missing.
- Ad hoc by the user with phrases like "we need a `cat###` for X".

**Calls:** nothing. Leaf writer. The hub update is an inline edit to `docs/product.md`.

**Complements:**
- `infinifu:adr-write` — the primary downstream consumer.
- `infinifu:tag-manage` — distinct layer (bare-slug tags vs numbered `cat###` buckets); the two coexist as separate parts of the taxonomy.

</integration>

<references>
Load these on demand, not preemptively.

- `references/examples.md` — worked zettel example, duplicate-check walkthrough, good/bad summaries, rename-audit procedure. Load when minting a non-trivial category, when the duplicate check returns a near-match, or when the user asks to rename a category.
- `docs/notes/akm.md` (in the target workspace) — top-level AKM model + lifecycle process flow. Load when needing cross-type perspective (how Categories relate to ADRs / Features / Implementations). Schema details live in the `<schema>` block above, not here.
- `infinifu:zettel-write` — cross-type styling rules (atomicity, 80-char wrap, link discipline, post-write audit). Load when the styling rule is unclear; this skill owns the Category schema, that one owns shared discipline.
</references>
