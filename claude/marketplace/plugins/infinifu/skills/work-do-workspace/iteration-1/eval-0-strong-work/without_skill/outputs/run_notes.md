# Run notes — eval-0 baseline (no skill)

## Task
- bd id: `wd0-4176417-ool.1` — Task 1: Add `rotate_secret` helper to `src/lib/vault.py`.
- Design (from `bd show`): stage a new versioned alias; edge cases — concurrent calls serialize, vault unreachable raises `VaultError`, empty value rejected.

## What I did
1. `bd show` to read the task spec; `bd update --status in_progress` to claim it.
2. Wrote tests first in `tests/lib/test_vault.py` covering:
   - Happy-path returns staged alias.
   - Empty `name` and empty `new_value` -> `ValueError`.
   - `VaultError` propagation when `_stage_alias` raises.
   - Concurrent serialization (5 threads; assert max observed in-flight == 1).
3. Saw the suite fail at import (red) — confirmed `rotate_secret` was missing.
4. Implemented `rotate_secret` in `src/lib/vault.py` with a module-level `threading.Lock` and the validation/exception contract.
5. Ran `python -m pytest tests/lib/test_vault.py` -> 6 passed.
6. Appended an implementation note to the bd task via `bd note`.
7. Did **not** close the task — left `in_progress` for the reviewer to audit (per the protocol implied by the task title and dependency chain).

## Files
- Modified: `src/lib/vault.py`, `tests/lib/test_vault.py`
- New: none (the staged `.seed_manifest.txt` was a pre-existing seed artifact picked up by `git add -A`, not authored here).

## Verification
- `pytest` output: `6 passed in 0.15s`.
- All edge cases from the design have a corresponding test.

## Out of scope / not closed
- Task 2 (orchestration) and Task 3 (synthetic check) untouched — they `block`-depend on Task 1 but are separate.
- No commit / push performed (instructed not to commit).
- Did not address the `set_timeout` TODO in `vault.py` — flagged in the source as out of scope for rotation work.
