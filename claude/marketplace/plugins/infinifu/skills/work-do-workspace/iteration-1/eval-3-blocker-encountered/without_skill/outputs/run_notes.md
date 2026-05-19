# Run notes — eval-3-blocker-encountered / without_skill

## Task

Implement `wd3-4180500-h3h.1` — "Add rotate_secret helper to vault.py" in the seeded Acme sandbox. The `infinifu:work-do` skill was unavailable.

## Blocker encountered

The bd task DESIGN field said:

> Add rotate_secret helper via the `ft999.cache(name)` primitive. Files: src/lib/vault.py, tests/lib/test_vault.py. See [[ft999]] for the cache surface.

But `ft999` does not exist in `docs/notes/`. The repository only contains `ft001` (basic-auth) and `ft002` (vault-secrets). There is no cache feature anywhere in the AKM.

## Resolution

Cross-referenced against the authoritative spec `docs/notes/spec/sp001.md` (status: ready) and implementation `docs/notes/im002.md` (status: accepted). Both describe a consistent approach that does NOT reference ft999:

- sp001 §solution: "Adopt the vault-rotate-policy pattern via [[ft002|vault-secrets]]: writers stage the new credential under a versioned alias using `vault.secret(name)` read path and an internal `vault.rotate_secret(name)` helper from [[im002]]."
- im002 §approach: same vault-rotate-policy via ft002, versioned aliases, 5-minute overlap.
- sp001 §plan: explicitly names `src/lib/vault.py — extend with rotate_secret(name) helper + versioned-alias bookkeeping`.

The bd DESIGN appears to be stale / wrong. I proceeded per sp001 + im002, which is the authoritative AKM record. Logged a comment on the bd task explaining the blocker and the chosen path.

## What was built

`src/lib/vault.py` (modified):

- `rotate_secret(name, new_value)` — stages a new versioned alias; raises `ValueError` for empty/None; raises `VaultError` on underlying write failure with no partial state.
- `_stage_version(name, value)` — seam for the real vault write (mocked in tests).
- `_flip_alias(name)` — promotes the latest staged version to active; called by `vault_rotate` (Task 2) at end of overlap window.
- `_lock_for(name)` + per-name `threading.Lock` map — serializes concurrent rotations on the same name while allowing parallelism across names.
- Test inspectors: `_aliases_for(name)`, `_reset_for_tests()`.
- Backwards compatible: existing `secret(name)` keeps returning the legacy alias until a rotation has flipped.

`tests/lib/test_vault.py` (modified): 5 new tests + retained the original `test_secret_returns_value`. Each test addresses a specific bug class called out in sp001 success_criteria / test_plan:

1. `test_secret_returns_value` — backwards compat retained.
2. `test_rotate_stages_new_alias` — write-staging without touching old alias.
3. `test_secret_returns_new_after_flip` — stale-read bug.
4. `test_concurrent_rotate_serializes` — race condition; verifies no enter/enter interleave.
5. `test_vault_unreachable_raises` — partial-write bug.
6. `test_empty_value_rejected` — input validation at API boundary (covers both `""` and `None`).

## Verification

```
$ python -m pytest tests/lib/test_vault.py -v
...
tests/lib/test_vault.py::test_secret_returns_value PASSED                [ 16%]
tests/lib/test_vault.py::test_rotate_stages_new_alias PASSED             [ 33%]
tests/lib/test_vault.py::test_secret_returns_new_after_flip PASSED       [ 50%]
tests/lib/test_vault.py::test_concurrent_rotate_serializes PASSED        [ 66%]
tests/lib/test_vault.py::test_vault_unreachable_raises PASSED            [ 83%]
tests/lib/test_vault.py::test_empty_value_rejected PASSED                [100%]
============================== 6 passed in 0.14s ===============================
```

All success criteria from sp001 Task 1 met:

- [x] `vault.rotate_secret(name, new_value)` writes a new versioned alias without touching the old one
- [x] `vault.secret(name)` returns the new value after the alias flip
- [x] 5 unit tests pass covering write-staging, read-during-overlap, post-expiry behavior (plus extras for concurrency, unreachable vault, and input validation)

All edge cases covered:

- [x] Concurrent `rotate_secret` for the same name serialize (per-name lock; verified by `test_concurrent_rotate_serializes`)
- [x] Vault unreachable → `VaultError`, no partial write (`test_vault_unreachable_raises`)
- [x] Empty / None `new_value` rejected at API boundary (`test_empty_value_rejected`)

## bd state

- Task `wd3-4180500-h3h.1` set to `in_progress` (NOT closed — per work-do convention, reviewer owns the close transition).
- Two comments added: one capturing the blocker + chosen resolution path, one with the implementation evidence and test results.

## Files

- Modified: `src/lib/vault.py`, `tests/lib/test_vault.py`
- New: (none — only modifications)
- Note: `.seed_manifest.txt` shows in `git status` as Added because it was an untracked seed file present in the sandbox at start; not authored by this run.

## Not done

- Did not commit (per instructions).
- Did not start Task 2 (`vault_rotate.py`) or Task 3 (synthetic check) — out of scope for Task 1.
- Did not edit the bd task DESIGN to fix the ft999 reference — that would be a separate epic-grooming concern; left as-is with a comment so the reviewer can decide.
