# Run Notes — work-merge eval, iteration 1, eval-1-task-still-in-progress (with_skill)

## Skill under test
`infinifu:work-merge` at `/home/jan/.dotfiles/claude/marketplace/plugins/infinifu/skills/work-merge/SKILL.md`

## Task framing
User asked: "Run work-merge on sp001. Task ids in .work-do-task-ids.json. Working dir is the seeded Acme sandbox."

Expectation per eval description: Task 2 is still `in_progress`. work-merge must BLOCK on incomplete bd children. No AKM writes.

## Evidence gathered
- `bd list --all --json` (in outputs/bd-list.json):
  - `wd1-243541-qia.1` status = **closed** (AUDITED: APPROVED)
  - `wd1-243541-qia.2` status = **in_progress** ← blocker
  - `wd1-243541-qia.3` status = **closed** (AUDITED: APPROVED)
  - `wd1-243541-qia`   (epic) status = open
- `docs/notes/spec/sp001.md` frontmatter `status: ready`, footer `Index: [[board]]` — both unchanged.
- `docs/board.md` still lists `[[sp001|rotate service credentials without downtime]]` under `## ready`.

## Decision against the skill
Skill's Disambiguation section is explicit:

> "bd children not all closed → block; report which tasks are still `open` / `in_progress` / `blocked`. Route to `work-do` (for blocked or open) or `work-audit` (for in_progress with implementer evidence)."

And Key Principles: "AKM writes BEFORE git landing … No partial state."

→ BLOCK. No AKM writes performed. Wrote `sandbox/route_decision.md` documenting the block + routing recommendation.

## Skill behavior assessment
The work-merge skill specifies the correct behavior unambiguously:
1. Step 3 of "Entry-specific checklist" is exactly this check.
2. Disambiguation section names the exact case and prescribes routing.
3. The "No partial state" principle reinforces that no AKM writes should leak through.

The skill description was triggered correctly by "Run work-merge on sp001". The skill's gating logic correctly halted the lifecycle flip when a child task was non-closed.

## Files captured to outputs/
- `git-status.txt` — only `A  .seed_manifest.txt` (untracked seed file picked up by `git add -A`; no AKM file changes).
- `git-diff.patch` — diff of staged changes (only the seed manifest, no docs/* modifications).
- `bd-list.json` — full bd state including the in_progress task 2.
- `route_decision.md` — copied from sandbox/route_decision.md (the deliverable).
- `run_notes.md` — this file.

## What I deliberately did NOT do
- Did not flip `sp001.status`.
- Did not flip `us003.status` or `im002.status`.
- Did not edit `docs/board.md` or `docs/archive.md`.
- Did not run `bd close wd1-243541-qia`.
- Did not run tests, did not present git landing options, did not commit, did not push.
