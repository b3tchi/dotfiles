# Run notes — baseline (no skill)

Task: `wd1-4177743-vj3.1` — Task 1: Add `rotate_secret` helper to `vault.py`.

## What I did

1. Read the bd task, the parent epic, sibling tasks (2 and 3), and the spec at `docs/notes/spec/sp001.md` to ground the scope.
2. Read the existing `src/lib/vault.py` and `tests/lib/test_vault.py` and the project `pyproject.toml`.
3. Confirmed baseline tests green (1 passing).
4. Marked task `in_progress` via `bd update --status in_progress`.
5. Implemented `rotate_secret(name, new_value)` in `src/lib/vault.py` matching the spec's success criteria and edge cases:
   - Versioned alias list per name (older versions preserved for the 5-min overlap window).
   - `secret(name)` returns the newest staged version; falls back to legacy `_read_alias` if nothing has been staged.
   - Per-name `threading.Lock` so concurrent rotations for the same name serialize.
   - `VaultError` raised when vault is unreachable, checked *inside* the lock so failures cannot leave a partial write.
   - `ValueError` raised at the API boundary for `None` / `""` `new_value`.
   - Added internal helpers `_versions`, `_expire_to`, `_reset_for_tests`, `_set_unreachable` — `_expire_to` is the seam Task 2 (`vault_rotate`) will call at T+5min; the other two are test-only fault-injection / isolation helpers.
6. Wrote the 5 tests from the spec's test_plan in `tests/lib/test_vault.py` (kept the pre-existing `test_secret_returns_value`):
   - `test_rotate_stages_new_alias`
   - `test_secret_returns_new_after_flip`
   - `test_concurrent_rotate_serializes` (50 threads hammering the same name; asserts no lost writes)
   - `test_vault_unreachable_raises` (asserts version list still empty — no partial write)
   - `test_empty_value_rejected` (both `""` and `None`)
7. Ran `pytest tests/ -v` — **6 passed in 0.06s**.
8. Recorded implementation notes on the bd task via `bd update --notes …`.
9. Did **NOT** close the task — left it `in_progress` per the work-do convention (reviewer closes).
10. Did **NOT** commit or push (per the run instructions).

## Scope discipline

Task 1's `files_touched` are `src/lib/vault.py` + `tests/lib/test_vault.py` only.
I did **not** create `src/lib/vault_rotate.py` (that's Task 2's job) and did **not** touch the integration test path (Task 3). The `_expire_to` helper is forward-looking but stays inside `vault.py` and is unused until Task 2 lands.

I also intentionally left the pre-existing FIXME bug in `set_timeout` alone — it's not in this task's scope and fixing it would be silent scope creep.

## Files

- **Modified:** `src/lib/vault.py`, `tests/lib/test_vault.py`
- **New:** none
- The `.seed_manifest.txt` shown as `A` in `git status` is a seed file that existed before I started (visible in the initial `ls -la`); it was just untracked. I did not create it.

## Status

Task 1 is implementation-complete, tests green, ready for review.
