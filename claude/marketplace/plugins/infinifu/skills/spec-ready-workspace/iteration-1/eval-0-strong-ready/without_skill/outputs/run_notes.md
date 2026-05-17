# Run notes — baseline (no skill)

Task: run `spec-ready` for sp001 in the seeded Acme sandbox without the
`infinifu:spec-ready` skill loaded.

## What I did

1. Inspected the sandbox and read `docs/notes/spec/sp001.md` to see plan
   + 3 refined tasks.
2. Read `docs/notes/akm.md` for the spec lifecycle conventions: at
   `ready`, each task gets a `#### bd <id>` line attached, status flips
   `spec → ready`, and `docs/board.md` moves the listing from `## spec`
   to `## ready`.
3. Ran `bd list` — found a pre-seeded epic `sandbox-nt2` with three
   children (`sandbox-nt2.1`/`.2`/`.3`) already wired with the right
   dependency chain (1→2, 1+2→3). My initial `bd create` calls produced
   duplicates (`sandbox-33d`, `sandbox-bxk`) which I then closed with a
   "duplicate of pre-existing" reason.
4. Updated `docs/notes/spec/sp001.md`:
   - frontmatter `status: spec` → `status: ready`
   - added `bd_epic: sandbox-nt2` to frontmatter
   - appended `#### bd sandbox-nt2.1`, `#### bd sandbox-nt2.2`,
     `#### bd sandbox-nt2.3` after each task's `#### test_plan`.
5. Updated `docs/board.md`: moved the sp001 bullet from `## spec` to
   `## ready` and adjusted the intro sentence to read
   "One spec in flight at ready stage."

## Outcome

- `bd ready` lists `sandbox-nt2.1` and the epic `sandbox-nt2` as
  workable (the other two tasks correctly blocked by their depends-on).
- spec sp001 carries bd ids on every task; board reflects ready state.
- Two stray bd issues left in closed state (`sandbox-33d`,
  `sandbox-bxk`) — closed with a reason, no impact on the ready queue.

## Caveats vs the documented skill

I did not know up front that the sandbox was pre-seeded with the bd
epic + tasks, so I created my own first before discovering them via
`bd list`. A skill that first probes `bd list --json` for an existing
epic on the spec would skip that wasted step. I also picked a
free-form `bd_epic:` frontmatter key — the AKM schema for `sp###` does
not explicitly mandate that key; the per-task `#### bd <id>` lines are
the documented mechanism. The epic-level link is convenient but may
not match the canonical convention.
