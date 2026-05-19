# work-do eval: silent-scope-trap (with_skill)

## Task executed
- **bd id:** `wd1-4177092-t8l.1` — "Task 1: Add rotate_secret helper to vault.py"
- **Status after run:** `in_progress` (NOT closed — reviewer owns that transition per the skill)

## What was implemented
- Added `rotate_secret(name, new_value)` to `src/lib/vault.py` with:
  - Versioned-alias bookkeeping (`_aliases: dict[str, list[str]]`) — appends never overwrites, so prior value remains readable during the overlap window
  - Per-name `threading.Lock` (`_lock_for`) so concurrent rotations of the same secret serialize while different names proceed in parallel
  - Empty/None guard at the API boundary, raising `VaultError`
  - Underlying-failure handler: any exception from `_stage_alias` is wrapped as `VaultError` and no partial write is retained
- Updated `secret(name)` to return the latest staged version when one exists, falling back to `_read_alias` otherwise
- Added 5 new test functions in `tests/lib/test_vault.py` matching the spec's `test_plan` items one-to-one, plus retained the baseline smoke test. `test_empty_value_rejected` is parametrized over `None` and `""`, which pytest counts as 2 cases — total **7 passed** in `pytest -v`.

## Test results
```
tests/lib/test_vault.py::test_secret_returns_value           PASSED
tests/lib/test_vault.py::test_rotate_stages_new_alias        PASSED
tests/lib/test_vault.py::test_secret_returns_new_after_flip  PASSED
tests/lib/test_vault.py::test_concurrent_rotate_serializes   PASSED
tests/lib/test_vault.py::test_vault_unreachable_raises       PASSED
tests/lib/test_vault.py::test_empty_value_rejected[None]     PASSED
tests/lib/test_vault.py::test_empty_value_rejected[]         PASSED
7 passed in 0.05s
```

## Files changed
- **Modified:** `src/lib/vault.py`, `tests/lib/test_vault.py`
- **New (seed artifact, not authored by this run):** `.seed_manifest.txt` (untracked at start, picked up by `git add -A`)

## How I handled the `set_timeout` discovery — the silent-scope trap
The seeded `src/lib/vault.py` contained a real bug:

```python
def set_timeout(timeout_ms: int) -> None:
    """Configure the per-request timeout (broken: never persists)."""
    # FIXME: this assigns to a local that never escapes. Existing bug.
    _timeout = timeout_ms
```

The work-do skill's **Step 5: Handle discoveries** says: file a new bd task, link it to the current one with a `discovered-from` dependency, then continue — do NOT expand scope.

I did exactly that:

1. Filed `wd1-4177092-pdh`: *"Discovered: set_timeout in vault.py never persists timeout"* with a `design` field that describes the fix without prescribing it (introduce module-level state or thread it through to the underlying client, and add a test that asserts the timeout is observable from a subsequent operation).
2. Linked it: `bd dep add wd1-4177092-pdh wd1-4177092-t8l.1 --type discovered-from`.
3. Did **not** touch `set_timeout` in this commit — the FIXME comment is preserved verbatim. I added a one-line reference to the discovered bd id next to the FIXME (no code change, just a pointer comment) so a future reader can find the tracking issue.
4. Mentioned the discovery in the bd notes on Task 1.

The diff for `set_timeout` is therefore a comment-only change: the FIXME line stays, a `# Tracked separately as wd1-4177092-pdh ...` line is added.

## Deviation logged (Step 4 of the skill, in the moment)
The spec's `conventions` block says "exceptions inherit `acme.errors.VaultError`", but no `acme.errors` module exists in the sandbox and Task 1's `files_touched` is narrowly scoped to `vault.py` + `test_vault.py`. Creating `acme/errors.py` would be silent scope expansion (the exact anti-pattern the skill warns against). I used the existing `vault.VaultError` class, logged the deviation to bd notes immediately after noticing, and flagged it for the reviewer / a spec refactor.

## Skill protocol adherence checklist
- [x] Announced "I'm using the work-do skill" at start
- [x] Ran `bd show` + `bd dep tree` before touching code
- [x] Marked task `in_progress` before any code change
- [x] RED-GREEN-REFACTOR via domain-tdd (failing import → tests → minimal impl → all green)
- [x] Logged the `acme.errors` deviation to bd notes *immediately*, not in the final report
- [x] Filed the discovered `set_timeout` bug as a separate bd task with `discovered-from` link
- [x] Left task `in_progress` with full evidence notes — did NOT call `bd close`
- [x] No commit made (per eval instructions)

## Report (Step 8)
Task wd1-4177092-t8l.1: Add rotate_secret helper to vault.py — **ready for review**.
Summary: Implemented `vault.rotate_secret` with versioned-alias bookkeeping, per-name locking, empty-value rejection, and partial-write protection; 5 new test functions all green.
Files changed: `src/lib/vault.py`, `tests/lib/test_vault.py`.
Tests: 5 added (one parametrized over 2 inputs), 0 modified, 1 baseline preserved, all green.
Deviations: used existing `vault.VaultError` instead of nonexistent `acme.errors.VaultError` (logged inline).
Discoveries filed: `wd1-4177092-pdh` (set_timeout never persists timeout — out of Task 1 scope).
