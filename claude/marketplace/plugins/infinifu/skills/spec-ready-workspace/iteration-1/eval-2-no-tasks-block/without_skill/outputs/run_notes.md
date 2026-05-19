# Run Notes — baseline (no skill), eval-2-no-tasks-block

## Task

Run "spec-ready" on `sp001` in the seeded Acme sandbox without using the
`infinifu:spec-ready` skill. Drive the workflow naturally from
codebase context (`docs/notes/akm.md`, `docs/board.md`, the existing
spec, and the existing `bd` issues).

## Starting state observed

- `docs/notes/spec/sp001.md` — `status: spec`, body had `## solves`,
  `## implements`, `## problem`, `## solution` only (no `## plan`, no
  `## tasks`). This is the "no-tasks-block" condition.
- `docs/board.md` — sp001 listed under `## spec`.
- bd state:
  - `sandbox-nt2` — open epic "Epic: rotate service credentials without
    downtime [sp001]"
  - `sandbox-nt2.1` — open child task "Add rotate_secret helper to
    vault.py"
  - `sandbox-nt2.2` — open child task "Add vault_rotate orchestration
    module" (blocked by nt2.1)
  - `sandbox-nt2.3` — open child task "Synthetic-check hook for rotation
    window" (blocked by nt2.1, nt2.2)
  - `sandbox-bxk` — closed as duplicate of nt2 / nt2.1 (pre-existing
    cleanup)

So the bd epic + task graph already existed; the gap was the spec body
itself (missing `## plan` + `## tasks` blocks with bd ids attached) and
the board placement.

## What I did

1. Read `docs/notes/akm.md` Spec section to learn the schema at the
   `ready` lifecycle stage (`## problem` at idea, `## solution` at spec,
   `## plan` + `## tasks` with attached `#### bd` at ready).
2. Pulled task design out of `bd list --json` for nt2.1 / nt2.2 / nt2.3
   (each task's `design` field already carried the SRE 8-category
   breakdown: type, effort, files_touched, success_criteria, edge_cases,
   test_plan). Mapped each to a `### Task N` block in the spec.
3. Wrote a `## plan` block covering file tree, conventions,
   anti-patterns, and known limitations — synthesized from the
   `## solution` already in the spec plus the `design` fields of the
   three tasks.
4. Wrote `## tasks` with three `### Task N` sub-sections, each carrying
   the eight required sub-headings plus `#### bd <id>` attaching the
   matching `sandbox-nt2.N` issue. `#### depends` reflects the existing
   bd blocks-edges.
5. Flipped `status: spec` → `status: ready` in the spec frontmatter.
6. Edited `docs/board.md` to move the sp001 entry from `## spec` to
   `## ready` and adjusted the one-liner accordingly.

## What I did NOT do

- Did not touch any bd issue. The epic and three tasks pre-existed, and
  `bxk` was already closed as a duplicate. There was nothing to create
  or relabel — just attach the existing ids in the spec body.
- Did not write code or tests. spec-ready is a doc + tracker
  reconciliation step; implementation comes later (per AKM lifecycle).
- Did not commit (per instructions).

## Files

- Modified: `docs/board.md`, `docs/notes/spec/sp001.md`
- New: `.seed_manifest.txt` shows up as untracked in `git status` but it
  is a seed-harness fixture, **not** authored by this run. I did not
  create it; `git add -A` simply staged everything that was untracked.
  It is mirrored under `new-files/` only because the post-action recipe
  said to copy NEW files.

## Caveats

- Without `infinifu:spec-ready` I had to infer the exact section order
  and the "attach `#### bd` last" convention from `akm.md`'s schema
  example. The output matches that schema (problem → solution → plan →
  tasks → footer) and tasks carry both `#### depends` and `#### bd`.
- bd has an "auto-export" warning when `.beads/` is gitignored; this is
  pre-existing harness noise, not caused by this run.
