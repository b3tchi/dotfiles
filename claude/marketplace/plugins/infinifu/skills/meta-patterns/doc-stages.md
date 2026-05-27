# Spec lifecycle (sp### status pipeline)

## Four statuses, one file per workstream

Every workstream is a single `sp###` zettel under `docs/notes/spec/`. The
zettel never moves between directories — its `status:` frontmatter flips
through four values as gates clear:

```
idea  →  spec  →  ready  →  done
```

`docs/board.md` carries an index keyed on the same status values — each
section (`## idea`, `## spec`, `## ready`) holds wikilinks
(`- [[sp###|alias]]`) to the active specs in that state. When a spec ships,
the wikilink moves from `docs/board.md ## ready` into `docs/archive.md
## done`. The filesystem layout stays flat (one `sp###.md` per workstream
in one directory); the section the user sees changes when state changes.

| Status   | Section in board.md | Created / advanced by                                       | Contents                                  |
|----------|---------------------|-------------------------------------------------------------|-------------------------------------------|
| `idea`   | `docs/board.md ## idea`   | `idea-brainstorming` (or one of the `idea-*` entry skills)  | `## problem` populated                    |
| `spec`   | `docs/board.md ## spec`   | `spec-writing` fills `## solution`                          | adds approach, ADR refs, consumed `ft###` |
| `ready`  | `docs/board.md ## ready`  | `spec-refinement` + `spec-ready` (bd epic + tasks minted)   | adds `## tasks` with `#### bd <id>` lines |
| `done`   | `docs/archive.md ## done` | `work-merge` (epic finale)                                  | shipped — body becomes historical record  |

## File naming

```
sp###.md     # zero-padded three-digit id, sequential, never reused
```

The zettel's first alias (`aliases: [- <name>]`) is the human-friendly
handle the user typed (e.g. `rotate-credentials`). `docs/board.md` wikilinks
use the `[[sp###|<alias>]]` form so renaming the alias doesn't break the
link.

## Gate rules

### Gate 1: idea → spec

- **Trigger:** User approves the design proposal in `## solution`.
- **Action:** `spec-writing` writes `## solution` on the sp###, flips
  `status: idea → spec`, moves the board.md wikilink from `## idea` to
  `## spec`. Stages on main; the commit happens at this gate.
- **Then:** `spec-refinement` runs the SRE 8-category review and writes
  `## tasks`.

### Gate 2: spec → ready

- **Trigger:** User approves the refined `## solution` + `## tasks`.
- **Action:** `spec-ready` mints the bd epic and child tasks, annotates
  each `### Task N` block in `## tasks` with a `#### bd <id>` line, flips
  `status: spec → ready`, moves the board.md wikilink from `## spec` to
  `## ready`. Commits on main.
- **Then:** Execution begins (`plan-scrum-master` or `plan-supervised`).

### Gate 3: ready → done

- **Trigger:** Last open bd task in the epic closes (via `work-audit`
  approval) and `work-merge` lands the branch.
- **Action:** `work-merge` runs the epic finale — flips
  `sp###.status: ready → done`, updates the footer
  `Index: [[board]] → [[archive]]`, moves the wikilink from
  `docs/board.md ## ready` into `docs/archive.md ## done`. Touches
  `us###` / `im###` / `ft###` statuses (`ready → done`, `proposed →
  accepted`) and closes the bd epic.
- **Then:** `spec-retro` does the post-merge knowledge-graph pass —
  rewrites `im###` body to match shipped reality, mints any new
  `adr####`, supersedes `ft###` whose surfaces widened.

## Rules

- Status only moves forward (`idea → spec → ready → done`). Reverts use
  `bd defer` on the epic plus a `spec-retro`-driven supersession; don't
  manually edit status back.
- Each gate requires explicit user approval at the human-gate point
  (`idea → spec` and `spec → ready`). The `ready → done` gate is
  automatic on epic completion.
- The bd epic id lives in `## tasks` via `#### bd <id>` annotations per
  task, not in the frontmatter — that keeps the zettel single-source for
  the AKM layer while bd Dolt stays the work-tracker source of truth.
- One `sp###` per workstream — `## problem` and `## solution` evolve in
  the same file as the spec progresses through statuses.
