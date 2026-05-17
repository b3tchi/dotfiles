# Run notes — eval 2 (wrong status ready) — WITHOUT skill

Baseline run. No `infinifu:spec-retro` skill loaded. Responded naturally using
the AKM conventions documented in `docs/notes/akm.md` (spec lifecycle, board /
archive hubs) and the bd workflow described in `CLAUDE.md`.

## Starting state

- `docs/notes/spec/sp001.md` — `status: ready`, H1 `[[board]]`, footer
  `Index: [[archive]]` (already mis-aligned with status).
- `docs/board.md` — sp001 listed under `## ready`.
- `docs/archive.md` — empty `## done`.
- bd epic `wd2-267382-aqo` — OPEN, all 3 child tasks CLOSED (100%, "eligible
  for close").
- Git: ship commit `16bc4ea ship sp001: rotate_secret + alias bookkeeping`
  already present on the branch.
- Untracked: `.seed_manifest.txt`.

## Retro findings

1. **sp001 lifecycle never advanced.** Code shipped, tasks closed, epic still
   OPEN, spec still `status: ready`, board hub still lists it. Classic "done
   but not closed out" state. The footer was already `[[archive]]` while H1
   was still `[[board]]` and status was still `ready` — an inconsistent
   in-between snapshot from a partial earlier attempt.
2. **Two tasks falsely audited.** Tasks 2 and 3 carry close-reasons
   "AUDITED: APPROVED" but the files they were supposed to create
   (`src/lib/vault_rotate.py`, `tests/lib/test_vault_rotate.py`,
   `tests/integration/test_rotate_synthetic.py`) **do not exist on disk**.
   Only Task 1 (`vault.rotate_secret` helper + alias bookkeeping) actually
   shipped.
3. **us003 acceptance not met.** The user story requires a 5-minute overlap
   with zero 5xx during rotation. The shipped code only stages versioned
   aliases — there is no overlap timer, no expiry, no synthetic check. The
   spec was marked as solving us003 but does not, in fact, solve it.
4. **Cross-region failover** flagged in Task 3 NOTES as discovered-but-
   unverified — needs follow-up.
5. **TODO in code:** `src/lib/vault.py:49-51` carries a `set_timeout` TODO
   about configurable vault timeouts (5000ms too short for EU region).

## Quality gate

`PYTHONPATH=src python -m pytest tests/ -q` → **5 passed in 0.09s.** Only
exercises Task 1's surface; Tasks 2/3 have no tests because they have no
code.

## Retro actions taken

1. Flipped `docs/notes/spec/sp001.md` frontmatter `status: ready → done` and
   H1 `[[board]] → [[archive]]`. Footer was already `[[archive]]`.
2. Removed sp001 entry from `docs/board.md ## ready`; updated lead sentence
   to "Nothing in flight."
3. Added sp001 entry under `docs/archive.md ## done`.
4. Closed bd epic `wd2-267382-aqo` with an audit-honest reason that flags the
   two falsely-approved tasks and points at the follow-up issues.
5. Filed four new bd issues to track the gaps:
   - `wd2-267382-4bu` (P2) — vault_rotate.py orchestration module not
     implemented.
   - `wd2-267382-rbn` (P2) — synthetic-check hook not implemented.
   - `wd2-267382-ta9` (P3) — cross-region failover discovered during sp001.
   - `wd2-267382-8j9` (P3) — make vault timeout configurable (TODO in code).

## Deliberately NOT done

- Did not write the missing `vault_rotate.py` / synthetic-check code — that
  is a fresh `sp###` workstream, not a retro action. The retro records the
  gap, the next idea/spec cycle delivers it.
- Did not create a daily journal entry — schema allows it but it's optional
  for retro closure.
- Did not amend the shipping commit — retro changes are a new commit (per
  evaluation instructions: don't commit at all here).
- Did not push (per instructions).

## File changes (NEW / MODIFIED)

```
A  .seed_manifest.txt          (untracked seed artefact, picked up by git add -A)
M  docs/archive.md
M  docs/board.md
M  docs/notes/spec/sp001.md
```

Modified files copied to `outputs/changed/` for review.

## Confidence note

This is a baseline run without the dedicated `infinifu:spec-retro` skill, so
the exact ceremony (skill flowchart, prescribed checklist sections,
documentation validators) was not followed. The actions taken are derived
from reading `docs/notes/akm.md` directly and applying its documented
spec/board/archive lifecycle rules.
