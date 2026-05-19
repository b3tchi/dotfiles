# Run Notes: spec-retro eval 2 (wrong status: ready)

## Skill behavior observed

The `spec-retro` SKILL.md disambiguation block fired correctly on the first pass. Two of its bullets matched the sandbox state simultaneously:

1. `sp001.status: ready` → "route back to the appropriate stage; spec-retro is post-merge only."
2. Board entry still under `docs/board.md ## ready` (and bd epic still open) → "work-merge didn't finish its archive move; route back to `work-merge`."

Both point at the same remediation: hand off to `infinifu:work-merge`.

## State seen in sandbox

- `docs/notes/spec/sp001.md` frontmatter: `status: ready` (not `done`).
- `docs/board.md` contains `- [[sp001|...]]` under `## ready`; `## idea`, `## spec` are empty.
- `docs/archive.md ## done` is empty — no archive move happened.
- `git log` shows two linear commits on `master`, no merge commit:
  - `69c19fa seed: Acme platform + AKM + bd workspace skeleton (eval 2)`
  - `13cb665 ship sp001: rotate_secret + alias bookkeeping`
- bd: epic `wd2-266312-i5s` is open (1 issue, 0 in_progress, 0 closed).
- Sandbox child tasks for the epic are not present in the local bd export (only the epic row showed up in `bd list`); they were never imported / never created. This is consistent with a workflow that stalled before work-merge.

## Actions taken

- Read `spec-retro/SKILL.md` end-to-end to confirm the disambiguation behavior.
- Inspected `sp001.md`, `docs/board.md`, `docs/archive.md`, `git log`, `bd list`.
- Did **not** read or modify `im002.md`, `ft001.md`, `ft002.md`, `adr0001..3.md`, or any `us###.md`.
- Did **not** call `bd close`, `bd update`, or any AKM write skill.
- Wrote `<sandbox>/route_decision.md` documenting the decision and reasoning.
- Captured outputs: `git-status.txt`, `git-diff.patch`, `bd-list.json`, `bd-show-epic.txt`, `route_decision.md`.
- Did **not** commit.

## Verdict on the skill

Pass. The disambiguation cases in `SKILL.md` are explicit enough that the only correct action is to refuse the retro and name the upstream skill (`work-merge`). The skill does not require reading any zettel bodies to make the call — the frontmatter `status:` check plus the board/archive cross-check is sufficient and was performed first.

## NEW/MODIFIED files in sandbox

- `A  .seed_manifest.txt` — pre-existing seed artifact, untracked at session start; staged by `git add -A` per capture protocol. Not authored by this run.
- `A  route_decision.md` — authored by this run.

No `im###` / `ft###` / `adr####` / `us###` / `sp###` / `board.md` / `archive.md` mutations.
