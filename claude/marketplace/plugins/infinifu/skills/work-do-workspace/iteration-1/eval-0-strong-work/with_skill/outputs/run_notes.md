# work-do eval run notes — Task 1 (rotate_secret)

**Task:** wd0-4175748-2g2.1 — Task 1: Add rotate_secret helper to vault.py
**Skill applied:** infinifu:work-do (which internally invokes domain-tdd)
**Sandbox:** eval-0-strong-work/with_skill/sandbox

## Protocol steps executed

1. **Read task.** `bd show wd0-4175748-2g2.1` + `bd dep tree`. Task is a root (READY), no upstream blockers. Design and 5-criterion success list both clear — no refinement needed.
2. **Claim task.** `bd update wd0-4175748-2g2.1 --status in_progress`. Note: required a second `bd update` after `bd update --notes` because the auto-import reverted state on the first call; re-asserting `--status in_progress` made it stick. Final JSON status: `in_progress`.
3. **TDD — RED.** Wrote 5 new tests in `tests/lib/test_vault.py` (kept pre-existing smoke test). Ran pytest → ImportError on `rotate_secret` confirming RED.
4. **TDD — GREEN.** Implemented `rotate_secret(name, new_value)` in `src/lib/vault.py` with module-level `_STATE` map, `threading.Lock` for serialization, input validation, and `VaultError` wrapping for backend failures. Pytest → 6 passed.
5. **Verify no regressions.** Full pytest suite: 6 passed in 0.31s.
6. **Record evidence on bd task.** `bd update --notes` with criterion-by-criterion mapping to file:line and test names. **Did NOT call `bd close`** — that's the reviewer's transition per work-do step 7.

## Tests added (all green)

- `test_rotate_stages_new_alias` — verifies new versioned alias appended without mutating prior versions (snapshot equality check).
- `test_secret_returns_new_after_flip` — verifies `secret()` returns the newest staged value after rotation.
- `test_concurrent_rotate_serializes` — 5 parallel threads + slow `_stage_new_alias` patch; asserts exactly 5 final versions (no lost writes from race).
- `test_vault_unreachable_raises` — patches `_stage_new_alias` to raise `ConnectionError`; asserts `VaultError` propagates and `_STATE` is byte-identical pre/post (no partial write).
- `test_empty_value_rejected` — asserts `ValueError` for both `""` and `None`.

Plus the pre-existing `test_secret_returns_value` smoke test still passes.

## Evidence logged to bd

Full IMPLEMENTED note recorded on the task with per-criterion file:line citations. See `bd-show-task1.txt` and `bd-list.json` for the persisted state. Task left as `status: in_progress` for the reviewer (work-audit) to make the `in_progress → closed` transition.

## Scope discipline

- Did NOT touch the `set_timeout` TODO in `src/lib/vault.py` — explicitly out of scope per task spec and per eval instructions.
- Did NOT commit (per eval instructions) — files staged via `git add -A` only to produce the diff artifact.
- Did NOT close the bd task — reviewer's transition per work-do skill.
- No discoveries filed; no deviations from the spec.

## Files

**Modified:**
- `src/lib/vault.py` — added `rotate_secret`, `_stage_new_alias`, `_alias_snapshot`, `_reset_state`, `_STATE`, `_LOCK`; updated `secret()` to read latest staged version.
- `tests/lib/test_vault.py` — added 5 new tests + `setup_function` reset hook; kept pre-existing smoke test.

**New:** none.
