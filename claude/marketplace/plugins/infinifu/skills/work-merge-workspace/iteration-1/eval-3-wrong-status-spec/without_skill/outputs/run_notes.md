# Baseline run notes — eval 3 (wrong-status-spec), without skill

## Task
"Run work-merge on sp001." Skill unavailable; respond naturally; do not merge/push.

## Sandbox state inspected

- Branch: `master`, single seed commit; only untracked file = `.seed_manifest.txt`
- Spec: `docs/notes/spec/sp001.md` — frontmatter `status: spec`, file lives in `spec/` board folder
- Epic `wd3-248201-jid`: status **OPEN**, all 3 children closed → "3/3 complete (100%) — eligible for close"
- Task 1 `wd3-248201-jid.1`: closed, AUDITED APPROVED. Implementation present on disk (`src/lib/vault.py`, `tests/lib/test_vault.py`)
- Task 2 `wd3-248201-jid.2`: closed, AUDITED APPROVED. **File missing on disk** — `src/lib/vault_rotate.py` does not exist
- Task 3 `wd3-248201-jid.3`: closed, AUDITED APPROVED. **File missing on disk** — `tests/integration/test_rotate_synthetic.py` does not exist (no `tests/integration/` dir)

## Anomalies observed (not acted on — baseline run)

1. **Wrong spec status / location.** `sp001.md` is in `docs/notes/spec/` with `status: spec`, but all tasks are closed and audit-approved. Expected location at merge time would be `docs/notes/board/done/` (or equivalent) with `status: done`. The spec needs promotion: `spec → ready → done`.
2. **Epic not closed.** Even though `bd` reports "eligible for close", the epic `wd3-248201-jid` is still `open`.
3. **Phantom closed tasks.** Tasks 2 and 3 are bd-closed with "AUDITED: APPROVED" but the artifacts they claim to deliver (`src/lib/vault_rotate.py`, `tests/integration/test_rotate_synthetic.py`) are not on disk. Either the audit was wrong, or files were lost between audit and now.

## Response to user (natural, no skill)

Walked through the state, surfaced the three anomalies above, and outlined what a real work-merge would have to do: fix the spec frontmatter `status` to `done`, move `sp001.md` from `spec/` to the `done/` archive folder, run tests + lint as quality gates, commit + (optionally) push, close the epic. Flagged the missing implementation files as a blocker — refused to merge an epic whose tasks claim to be done but whose code is missing. Did not run any git mutation or `bd close` per instructions.

## Captured artifacts

- `git-status.txt` — only `.seed_manifest.txt` added (pre-existing seed artifact)
- `git-diff.patch` — diff for `.seed_manifest.txt`
- `bd-list.json` — full bd issue list at end of run (epic still open, 3 tasks closed)
- No new files copied from sandbox — baseline made no modifications
