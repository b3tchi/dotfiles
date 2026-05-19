# Run notes — eval-1-already-ready-stop (without skill)

## Task
"Run spec-ready on sp001."

## What I observed in the sandbox

State of `sp001` before any action:

- **Frontmatter**: `status: ready` (already promoted)
- **Location**: `docs/notes/spec/sp001.md` — the only location specs live, per `docs/notes/akm.md` (the AKM uses `board.md` as the singleton hub instead of `board/spec/` and `board/ready/` directories; the spec file itself doesn't move)
- **Board hub** `docs/board.md`: already lists `[[sp001|rotate service credentials without downtime]]` under `## ready`, and `## idea` / `## spec` are empty
- **bd state**: epic `sandbox-nt2` already exists with 3 child tasks `sandbox-nt2.1/.2/.3` matching the three tasks in the spec; the epic description references `sp001` and `us003 / im002 / ft002`
- **us003** frontmatter: `status: ready` (not yet flipped to `in_progress`)
- **im002** frontmatter: `status: accepted` (already)

## What spec-ready would normally do (per AKM + skill description)

From `docs/notes/akm.md` and the skill description: "creates bd epic and tasks with dependencies, then promotes spec from board/spec/ to board/ready/ as one atomic operation". In this AKM revision the directory move is replaced by a status flip + board.md section move (`## spec` → `## ready`), and the `#### bd` field on each task gets the real bd id attached.

## Decision

Spec is already at `ready` — frontmatter says so, the board hub says so, and a bd epic + 3 child tasks already exist for it. The operation is a no-op. The natural call is to **stop and report**, not re-run promotion logic on a spec that has already been promoted.

## Inconsistencies noted (not acted on — would be out-of-scope drift)

These look like seeded artefacts rather than a real broken state, but worth flagging:

1. `sp001.md` `## tasks` sections still carry placeholder `#### bd` values `bd-001 / bd-002 / bd-003` instead of the real ids `sandbox-nt2.1 / .2 / .3` from `bd list`. A real `spec-ready` run would have stamped the real ids in.
2. Two stray bd issues exist alongside the proper epic:
   - `sandbox-33d` — a `feature`-type issue titled "Spec sp001: …" (looks like a duplicate top-level record of the spec)
   - `sandbox-bxk` — a standalone `task` "Task 1: Add rotate_secret helper to vault.py" not parented to the epic
   A clean spec-ready run would not have produced these stragglers.
3. No `depends` relationships are visible on the child tasks via `bd list` — the spec text says Task 2 depends on Task 1, and Task 3 depends on Tasks 1 + 2, so a clean run would have wired `--depends-on` edges between `sandbox-nt2.1 → .2 → .3`.

I left all three alone because the user asked to run spec-ready, and spec-ready's own preconditions (status: ready, board hub correct, epic + tasks present) are already met. Touching these would be acting beyond the asked-for operation.

## Changes made

None to docs or bd. The only file `git add -A` picked up is `.seed_manifest.txt` (untracked seeding artefact); no content was modified.

## Result

- `git-status.txt`: only `.seed_manifest.txt` added (seeded file)
- `git-diff.patch`: just the new manifest
- `bd-list.json`: unchanged from the seeded state
- `new-files/`: empty (no zettel created)
- `modified-files/`: empty (nothing modified)
