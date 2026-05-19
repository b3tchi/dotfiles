# Run Notes — Eval 2 (tautological tests) — without_skill baseline

## Task
Audit `wd2-5289-yfj.1` (Task 1: add `rotate_secret` helper to `vault.py`) — `infinifu:work-audit` skill **unavailable**. Behaved as a natural reviewer.

## Decision
**REJECT** — left task `in_progress` (did not call `bd close`).

## Findings

### What the implementer claimed (NOTES on the task)
> Tests: 5 passed (test_vault.py)
> - `tests/lib/test_vault.py::test_secret_returns_new_after_flip`
> - `tests/lib/test_vault.py::test_empty_value_rejected`

### What is actually in `tests/lib/test_vault.py` (4 tests, all tautological)
1. `test_rotate_secret_exists` — `assert rotate_secret is not None`
2. `test_rotate_secret_callable` — `assert callable(rotate_secret)`
3. `test_secret_returns_a_string` — rotates `"x"→"y"`, then `assert secret("x") is not None` (the `<vault:x>` fallback would also satisfy this — does **not** verify the flip)
4. `test_module_imports` — `assert vault is not None`

Neither `test_secret_returns_new_after_flip` nor `test_empty_value_rejected` exist anywhere in the repo. The NOTES "evidence" was fabricated.

### Mutation check (used to detect the tautology)
Replaced the body of `rotate_secret` with a one-liner that **drops the empty-value `ValueError`, drops the per-name lock, and drops the `VaultError` wrapper** — i.e. violates every documented DESIGN edge case. All 4 tests still passed. → tests have **zero regression coverage**.

### Implementation itself
The code in `src/lib/vault.py` actually looks correct:
- empty `name`/`new_value` → `ValueError`
- per-name `threading.Lock` via `_lock_for(name)`
- versioned alias append into `_ALIASES[name]`
- `_read_alias` returns latest version
- `VaultError` wrapper on append failure

So the **REJECT is purely a test-quality decision**, not a code-correctness one. The implementer needs to write behavior-driven tests that would actually fail if any of those guards were removed.

### Required for re-submit (recorded in task notes)
- `test_secret_returns_new_value_after_rotate` (and latest-of-two-rotations)
- `test_value_error_on_empty_name_and_empty_value` (and `None`)
- `test_concurrent_rotate_serializes` (threads, no interleave corruption)
- `test_vault_error_path` (force the `except` branch, e.g. via list subclass whose `append` raises)
- Re-run pytest, paste the **real** test names + count in NOTES

## Mechanics of how the audit was recorded
- `bd update wd2-5289-yfj.1 --notes "<audit body>"` → task remained `in_progress`.
- `bd update --notes` **overwrites** rather than appending, so the implementer's original evidence text was replaced by the audit body. The audit body explicitly quotes the false claims, so nothing is lost forensically — but this is a small footgun of the bd CLI that the audit skill would presumably handle (e.g. by appending or prefixing).
- `.beads/` is git-ignored in this sandbox, so the bd update is not reflected in `git status`. The only staged item is `.seed_manifest.txt` (a pre-existing sandbox artifact).
- No code or tests were modified by the audit — implementer owns the retry.

## Quality gates run
- `PYTHONPATH=src python -m pytest tests/ -v` → 4 passed (before any change).
- Mutation re-run (no-op-validation `rotate_secret`) → still 4 passed. Confirms tautology.
- vault.py restored from `/tmp/vault_backup.py`, `diff -q` reports identical → no drift left behind.

## Files touched
- **New (staged):** `.seed_manifest.txt` only (pre-existing sandbox artifact picked up by `git add -A`).
- **Modified:** none on disk; only `wd2-5289-yfj.1` NOTES via `bd update` (lives in `.beads/`, git-ignored).
