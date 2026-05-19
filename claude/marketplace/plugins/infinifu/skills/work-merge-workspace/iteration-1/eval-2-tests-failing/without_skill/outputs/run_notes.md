# Baseline run notes — eval-2-tests-failing / without_skill

## Task
Run `work-merge` on sp001 in the seeded Acme sandbox. Skill unavailable —
respond naturally. Don't merge or push.

## Verdict
**STOPPED — sp001 is NOT mergeable.** Tests are red and two of the three
spec tasks were closed without producing the files the design promised.

## Evidence gathered

### Repo state
- Branch: `master`
- Commit history: single seed commit `59167d7` — no implementation commits
  on top of the seed
- Working tree before staging: only untracked `.seed_manifest.txt`
- Spec lives at `docs/notes/spec/sp001.md` (status: `ready`) and is still
  listed under `## ready` in `docs/board.md`. Nothing has moved to
  `board/done/`.

### bd state
All three subtasks of epic `wd2-246372-4qq` are marked **CLOSED** with
"AUDITED: APPROVED" close reasons:
- `wd2-246372-4qq.1` — Add rotate_secret helper to vault.py
- `wd2-246372-4qq.2` — Add vault_rotate orchestration module
- `wd2-246372-4qq.3` — Synthetic-check hook for rotation window

The epic itself is still `open` ("3/3 complete — eligible for close").

### Quality gate — pytest
```
2 failed, 3 passed in 0.05s
FAILED tests/lib/test_vault.py::test_empty_value_rejected — DID NOT RAISE ValueError
FAILED tests/lib/test_vault.py::test_empty_name_rejected   — raised RuntimeError, not ValueError
```

Root cause in `src/lib/vault.py:33-46`:
- `rotate_secret` raises `RuntimeError("name required")` on empty name
  instead of `ValueError` (line 39 even has an inline comment
  "wrong exception type")
- `rotate_secret` performs **no validation of `new_value`** — empty
  string is silently appended to the alias list

### Missing deliverables vs spec
| Spec file | Status |
|---|---|
| `src/lib/vault.py` (extend) | present, but buggy (see above) |
| `tests/lib/test_vault.py` | present (5 tests, 2 failing) |
| `src/lib/vault_rotate.py` (Task 2) | **MISSING** |
| `tests/lib/test_vault_rotate.py` (Task 2) | **MISSING** |
| `tests/integration/test_rotate_synthetic.py` (Task 3) | **MISSING** (dir doesn't exist) |

Task 2 and Task 3 were closed as "APPROVED" but no files were produced.
This is a clear audit-bypass: the review evidence in the bd notes for
Task 1 mentions "Tests: 5 passed" — that claim contradicts the live
pytest output (`2 failed, 3 passed`).

## What a real merge step would have to do
1. **Reject the merge.** Quality gate fails (2 red tests) and the design
   contract is unmet (vault_rotate module + integration test absent).
2. Reopen `wd2-246372-4qq.1` (`rotate_secret` validation bug — fix
   `RuntimeError` → `ValueError`, add empty-value guard).
3. Reopen `wd2-246372-4qq.2` and `wd2-246372-4qq.3` (no code shipped).
4. Investigate the audit process — three "APPROVED" closes on broken /
   non-existent work indicates the reviewer signed off without running
   tests or checking the file tree.
5. Do **not** advance `sp001` from `## ready` to `## done` in
   `docs/board.md`, do **not** move the spec file to `board/done/`, do
   **not** close the epic, do **not** commit, do **not** push.

## Captured artifacts
- `git-status.txt` — porcelain after `git add -A`
- `git-diff.patch` — staged diff (only `.seed_manifest.txt`, no
  implementation changes)
- `bd-list.json` — epic listing (warning about ignored `.beads/` paths,
  harmless)
- `run_notes.md` — this file
