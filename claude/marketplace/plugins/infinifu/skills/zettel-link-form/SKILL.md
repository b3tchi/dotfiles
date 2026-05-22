---
name: zettel-link-form
description: Use whenever an AKM zettel mentions another thing by reference — owns the one rule that says which link shape to use (`[[wikilink]]` for AKM zettels, `[path](../../path)` markdown link for in-repo files, backticks for runtime/external paths). Pulled out as its own microskill because every typed writer (`infinifu:feature-write`, `infinifu:implementation-write`, `infinifu:story-map`, `infinifu:zettel-write`, `infinifu:adr-write`, plus future writers) hits the same choice on every reference in every body section (`## components`, `## sample`, `## api_surface`, prose) — duplicating the rule across each SKILL.md drifts. Load this before writing or editing any reference inside a `docs/notes/` zettel; consult it from the post-write audit; cite it by name from typed writers instead of restating the rule.
---

<skill_overview>
Three reference shapes coexist in every AKM zettel. They look similar at a glance, but each carries different navigability and graph semantics — choose the wrong shape and either the moxide LSP loses track of a graph edge or the markdown renderer fails to navigate to a real file. This skill is the one canonical place that defines the choice. Typed writers and audit checklists reference it rather than restating it.
</skill_overview>

<rigidity_level>
HARD RULE — there is one correct shape per target type. The rule is short enough to internalize, and the cost of inconsistency is concrete (broken graph traversal, dead renderer links, mixed bullets in the same section). No flexibility on the form itself; the only judgment call is *which category a given target falls into* — and the categories are exhaustive.
</rigidity_level>

<the_rule>

| Target | Shape | Why |
|--------|-------|-----|
| AKM zettel — `us###`, `im###`, `ft###`, `adr####`, `cat###`, `pn###`, `product`, named-slug generic card | `[[id]]` or `[[id\|label]]` | moxide LSP, `grep`, and graph traversal index by wikilink. The wikilink **is** the graph edge. Markdown-linking a zettel breaks the index. |
| In-repo file or directory — anything under the repo root (`src/...`, `nushell/...`, `docs/notes/foo.md` from prose, `tmux/tmux.conf`, etc.) | `[<path>](../../<path>)` from `docs/notes/<id>.md` | Markdown renderers and IDEs can navigate. The `../../` prefix is **constant** because every zettel under `docs/notes/` sits exactly two directory levels below the repo root; no math needed. |
| Runtime / external — `~/.config/...`, `/var/log/...`, `https://...`, env vars (`$EDITOR`), command snippets (`project list`), shell strings | backticks `` `...` `` | Not navigable from the note. Backticks are typography, not a link — they tell the reader "this is a literal string", not "go here". |

**Worked examples.**

```markdown
# Implementation [[cat001]] [[product]]               ← AKM zettel refs

## components
- [nushell/scripts/project/mod.nu](../../nushell/scripts/project/mod.nu)    ← in-repo path
- [tmux/tmux.conf](../../tmux/tmux.conf)                                    ← in-repo path
- `~/.config/project/projects.yaml` — runtime data store                    ← runtime
```

```markdown
Reuse the parser from [[ft004|import-pipeline]] — see              ← zettel ref
[src/parser/csv.ts](../../src/parser/csv.ts) for the entry point   ← in-repo
and the deployment doc at https://wiki.example.com/csv-import.     ← external
```

</the_rule>

<edge_cases>

- **Glob in `## components`.** Wrap the same way: `[src/auth/**](../../src/auth/**)`. The renderer will leave the href dangling — fine. The visual convention stays consistent and `grep '<path-fragment>'` still hits both halves of the bullet.
- **Path with spaces.** Wrap label and href the same; nothing special. Markdown link syntax handles them.
- **Path to another `docs/notes/X.md`.** Two valid interpretations:
  - Referring to the *AKM zettel* X (the concept) → wikilink `[[X]]`.
  - Referring to the *file* `docs/notes/X.md` (the on-disk artifact, e.g. when documenting a build step that touches the file) → markdown link `[docs/notes/X.md](../X.md)` (single `../` because the target is a sibling-dir, not a repo-root path). Rare; default to the wikilink.
- **Path to `docs/product.md` or `docs/board.md`.** These are AKM hub zettels — use the wikilink (`[[product]]`, `[[board]]`). Never markdown-link them; the moxide LSP relies on the wikilink to count hub references.
- **Generic concept slug for a card that doesn't exist yet.** Still a wikilink `[[bus-factor]]` — moxide will surface it as a dangling link, which is the prompt to write the card. Don't markdown-link a future zettel.
- **External docs hosted in the repo** (`README.md`, `CHANGELOG.md` at repo root). In-repo paths — markdown link `[README.md](../../README.md)`.

</edge_cases>

<anti_patterns>

- ❌ `[[nushell/scripts/project/mod.nu]]` — wikilink to a code path. The moxide LSP will treat it as an unresolved zettel and surface a dangling-link diagnostic forever.
- ❌ `[ft004](../../docs/notes/ft004.md)` — markdown link to an AKM zettel. Breaks graph traversal: the `[[ft004]]` wikilink count is wrong, and refactoring the slug won't pick up this reference.
- ❌ `` `src/parser/csv.ts` `` — bare backticks for an in-repo path. Readable but not clickable; readers can't jump to the file from the rendered note.
- ❌ `[~/.config/project/projects.yaml](../../~/.config/project/projects.yaml)` — markdown link to a runtime path. The `../../` resolves to nonsense; users running the project don't have the file at that path. Use backticks.
- ❌ Mixing shapes inside one `## components` block (some bullets markdown-linked, some bare-backtick). Hides drift and forces every reader to second-guess each bullet. When editing such a section, normalize all bullets in the same edit.

</anti_patterns>

<when_to_use>

- **On write** — every typed writer (`infinifu:feature-write`, `infinifu:implementation-write`, `infinifu:adr-write`, `infinifu:story-write`, `infinifu:persona-write`, `infinifu:category-write`, `infinifu:zettel-write` for generic cards) loads this rule when emitting body sections that may contain any kind of reference.
- **On audit** — the post-write checklist in `infinifu:zettel-write` cites this skill in its link-form check.
- **On edit** — `infinifu:story-map` consults this rule when appending or removing bullets in `## components`, and normalizes neighboring legacy entries in the same edit.
- **On read** — when you encounter a zettel whose references look wrong (wikilink to a code path, bare backtick to a repo file, markdown link to a hub), this skill is the canonical reference for which shape it *should* be.

</when_to_use>

<verification_checklist>

Before reporting a zettel write or edit complete:

- [ ] Every AKM zettel reference uses `[[…]]` (with or without pipe-label) — never `[label](../path/to/zettel.md)`.
- [ ] Every in-repo path uses `[<path>](../../<path>)` — never bare backticks for files in the working tree, never wikilinks to file paths.
- [ ] Runtime / external paths stay in backticks — never wrapped in markdown link syntax.
- [ ] Inside any single bulleted section (especially `## components`), all bullets follow the same shape — no mixed forms left to confuse the next reader.
- [ ] The `../../` prefix on in-repo links is literal (no `./`, no absolute path, no `$AKM_ROOT`-anchored variant) — the constant prefix is the load-bearing invariant.

</verification_checklist>

<integration>

**Called by:** `infinifu:zettel-write` (post-write audit), `infinifu:feature-write` (body emission), `infinifu:implementation-write` (body emission), `infinifu:story-map` (attach mode), `infinifu:adr-write` (body emission), and every other typed writer that emits references.

**Complements:** `infinifu:zettel-write` (orchestrator + shared discipline — this skill is the link-form sub-rule extracted out so each writer cites it instead of duplicating).

**Reference:** `docs/notes/akm.md` — top-level AKM model. The schema-invariants section there mentions link form by target type and points here for the rule.

</integration>
