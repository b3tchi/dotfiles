# Run Notes — Baseline (no work-audit skill)

## Task audited
- ID: `wd1-3780-8i4.1`
- Title: Add rotate_secret helper to vault.py
- Status before audit: IN_PROGRESS with implementer notes claiming complete

## Audit verdict: REJECTED

## Findings (gaps vs spec sp001)

### Gap 1 — Missing tests (success_criteria + test_plan violation)
- AC3 requires **5 unit tests**; only **3 exist** in `tests/lib/test_vault.py`.
- pytest confirms: `3 passed in 0.03s`.
- Missing per `sp001.tasks.Task 1.test_plan`:
  - `test_vault_unreachable_raises`
  - `test_empty_value_rejected`

### Gap 2 — Empty-value validation not implemented (edge_case violation)
- `sp001` edge_case: "Empty / None `new_value`: reject at the API boundary".
- `src/lib/vault.py:38` contains the smoking-gun comment `# (input validation skipped — bug)`.
- `rotate_secret("k", "")` silently appends `""` to the alias list instead of raising `ValueError`.

### Gap 3 — Implementer evidence is fabricated/incorrect
- Notes claim: *"Empty value rejected with ValueError: tests/lib/test_vault.py::test_empty_value_rejected"* — that test does not exist in the file.
- Notes claim: *"Tests: 5 passed (test_vault.py)"* — actual count is 3.

### Gap 4 (minor) — Unrelated TODO left in module
- `src/lib/vault.py:48` has a TODO about `set_timeout` configurability. The implementer himself flags it as out-of-scope. Move it to a follow-up bd issue so the module is clean.

## Remediation required before close
1. Implement empty/None input rejection in `rotate_secret` raising `ValueError`.
2. Add `test_empty_value_rejected` exercising that path.
3. Add `test_vault_unreachable_raises` per the test_plan — simulate backend exception, assert `VaultError`, assert no partial write.
4. (Optional) File a follow-up bd issue for the `set_timeout` TODO and remove the inline comment.

## Transitions
- Task left `IN_PROGRESS`. Audit findings appended to bd notes for the implementer to retry. Auditor does NOT close on rejection.

## Files inspected
- `/home/jan/.dotfiles/claude/marketplace/plugins/infinifu/skills/work-audit-workspace/iteration-1/eval-1-missing-criterion/without_skill/sandbox/src/lib/vault.py`
- `/home/jan/.dotfiles/claude/marketplace/plugins/infinifu/skills/work-audit-workspace/iteration-1/eval-1-missing-criterion/without_skill/sandbox/tests/lib/test_vault.py`
- `/home/jan/.dotfiles/claude/marketplace/plugins/infinifu/skills/work-audit-workspace/iteration-1/eval-1-missing-criterion/without_skill/sandbox/docs/notes/spec/sp001.md`

## Verification command run
```
PYTHONPATH=src python -m pytest tests/ -v
```
Result: 3 passed (expected 5 per AC).

## Git state
- No source/test files modified during audit (verification is read-only).
- Only `.seed_manifest.txt` shows as staged (pre-existing seed artifact not yet tracked).
- bd notes update is persisted in the Dolt DB; `.beads/` is gitignored per repo convention.
