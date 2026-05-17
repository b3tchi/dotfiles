# Run notes — baseline (no skill)

## Task
Refine sp001 from `spec` to `ready`: add `## plan` and `## tasks`
sections per the AKM spec schema. Solution was already chosen
(vault-rotate-policy via ft002 / im002), so this run only had to
produce the refinement artifacts.

## What I did

1. Surveyed the AKM workspace:
   - `docs/board.md` (sp001 listed under `## spec`)
   - `docs/notes/spec/sp001.md` (status: spec, `## solution` present)
   - `docs/notes/akm.md` (spec schema for `## plan` + `## tasks`)
   - Linked context: us003, im002, ft002, adr0001, adr0002, cat001,
     cat003, src/lib/.
2. Wrote the `## plan` section: file tree, conventions, anti-patterns,
   known limitations.
3. Wrote the `## tasks` section: 5 tasks following the AKM sub-section
   schema (type / effort / depends / files_touched / success_criteria /
   edge_cases / test_plan / bd).
4. Flipped `status: spec` → `status: ready` in sp001 frontmatter.
5. Moved sp001 on `docs/board.md` from `## spec` to `## ready`.
6. Left every `bd` field as `<pending — attached by spec-ready>` —
   per the AKM lifecycle owner column, attaching bd ids is the
   spec-ready skill's job, not refinement.

## Tasks produced

1. Extend `vault.py` with versioned read path (3h).
2. Implement `rotate_secret(name, new_value)` helper (3h).
3. Operator CLI script `scripts/rotate_secret.py` (2h).
4. End-to-end synthetic check: zero 5xx under load during rotation (4h).
5. Operator runbook + im002 back-link to sp001 (1h).

Total: ~13h, each task ≤ 4h, linear dependency chain (1 → 2 → 3 →
{4, 5}).

## Notes / observations

- Did **not** modify im002 to add the `[[sp001]]` back-link in its
  `## specs` section yet — left that as Task 5 (a deliverable of the
  refinement *execution* phase, not the refinement itself). The AKM
  schema does require the back-link eventually; whether spec-ready or
  the implementer should write it is ambiguous in the schema.
- Did not touch any source code under `src/`.
- `.seed_manifest.txt` showed up as untracked seed metadata; got
  staged by the `git add -A` instruction. Not authored by this run.

## Files changed

- `docs/board.md` — moved sp001 from `## spec` to `## ready`.
- `docs/notes/spec/sp001.md` — added `## plan` + `## tasks`; status
  spec → ready.

## What I did NOT do

- No `bd` issue creation (that's spec-ready's job).
- No actual source-code changes (refinement is planning, not coding).
- No new ADR, feature, or implementation zettel — solution was
  already locked at the spec stage.
