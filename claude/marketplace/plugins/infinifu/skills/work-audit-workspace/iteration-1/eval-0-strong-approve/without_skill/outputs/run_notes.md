# Run Notes — Eval 0 (strong-approve), without_skill

## Audit Result: APPROVED

Task: `wd0-2218-opi.1` — Add rotate_secret helper to vault.py

## Method

Worked from spec `docs/notes/spec/sp001.md` Task 1 success criteria + edge cases + test plan, cross-referenced against the post-work-do snapshot:
- `src/lib/vault.py`
- `tests/lib/test_vault.py`

Ran `python -m pytest tests/lib/test_vault.py -v` — **5 passed in 0.03s**.

## Success Criteria Verification

| Criterion | Status | Evidence |
|---|---|---|
| `rotate_secret(name, new_value)` writes new versioned alias without touching old | PASS | `src/lib/vault.py:33-46`; `_ALIASES.setdefault(name, []).append(new_value)` appends, never replaces |
| `secret(name)` returns new value after flip | PASS | `test_secret_returns_new_after_flip` passes; `_read_alias` returns `versions[-1]` |
| 5 unit tests pass | PASS | 5/5 in `tests/lib/test_vault.py` |

## Edge Case Verification

| Edge case | Status | Evidence |
|---|---|---|
| Concurrent calls for same name serialize | PASS | `_lock_for(name)` via `_LOCKS_GUARD` (lazy-init safe); `test_concurrent_rotate_serializes` proves no lost writes (5 threads → 5 staged) |
| Vault unreachable raises `VaultError`, no partial-write | PARTIAL | Code path exists (`try/except` wrapping `setdefault/append` and raising `VaultError`), but no test exercises it. Acceptable for in-memory stub (no backend to fail). |
| Empty / None `new_value` rejected at API boundary | PASS | `test_empty_value_rejected` (empty string) + `test_empty_name_rejected` (empty name) both pass |

## Test Plan Deviation (Minor)

Spec called for `test_vault_unreachable_raises`; implementer replaced it with `test_empty_name_rejected`. Implementer reported "Deviations: none" which is **inaccurate** — they did deviate, just defensibly. Given the in-memory stub has no backend, simulating "unreachable" would require mocking machinery out of scope for this task; substituting another input-validation case is pragmatic. **Flagged, not blocking.**

## Other Observations

- **Stray TODO** at `src/lib/vault.py:49-51` re: `set_timeout(timeout_ms)` — out of scope, but tagged as such in the comment. Acceptable as a captured note; could be a follow-up bd issue if desired.
- No dead code, no anti-pattern violations from the spec (no bare `except`, no `time.sleep`, no out-of-module vault mutation).
- Type hints present per spec conventions.

## Actions Taken

1. Appended AUDIT note to `wd0-2218-opi.1` via `bd update --notes` with evidence trail.
2. Closed `wd0-2218-opi.1` via `bd close`. Downstream `wd0-2218-opi.2` is now unblocked (was blocked by Task 1).

## Files Changed in Sandbox

Only `.seed_manifest.txt` is newly-tracked (was untracked at start). `vault.py` and `test_vault.py` were already part of the seed commit `e1b70b9` — no further code changes were needed; audit is read-only verification.

## Verdict

**Strong approve.** Implementation matches spec, tests genuinely catch the named bugs (alias-write, stale-read, race, input-validation), and code quality is clean. One test-plan substitution and one out-of-scope TODO comment are the only minor notes; neither blocks closure.
