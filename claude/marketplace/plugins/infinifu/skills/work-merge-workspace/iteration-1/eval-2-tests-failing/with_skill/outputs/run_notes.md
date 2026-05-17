# work-merge run notes — eval-2-tests-failing

**Skill:** infinifu:work-merge
**Spec:** sp001 — rotate service credentials without downtime
**Epic:** wd2-245485-qnw (tasks .1 / .2 / .3 — all already CLOSED in bd)
**Branch:** `master` (single branch; no separate feature branch in this seed)
**Outcome:** BLOCKED at Step 1 (Verify Tests). No status flips. No commits. No PR.

## Test command

```
cd <sandbox>
PYTHONPATH=src python -m pytest tests/ -v
```

Exit: 1.

## Pytest output (snippet)

```
collected 5 items

tests/lib/test_vault.py::test_rotate_stages_new_alias PASSED             [ 20%]
tests/lib/test_vault.py::test_secret_returns_new_after_flip PASSED       [ 40%]
tests/lib/test_vault.py::test_concurrent_rotate_serializes PASSED        [ 60%]
tests/lib/test_vault.py::test_empty_value_rejected FAILED                [ 80%]
tests/lib/test_vault.py::test_empty_name_rejected FAILED                 [100%]

=================================== FAILURES ===================================
__________________________ test_empty_value_rejected ___________________________

    def test_empty_value_rejected():
        """Catches input-validation bug."""
>       with pytest.raises(ValueError):
E       Failed: DID NOT RAISE <class 'ValueError'>

tests/lib/test_vault.py:35: Failed
___________________________ test_empty_name_rejected ___________________________

    def test_empty_name_rejected():
        """Catches input-validation bug (name path)."""
        with pytest.raises(ValueError):
>           rotate_secret("", "v1")

tests/lib/test_vault.py:42:
        if not name:
>           raise RuntimeError("name required")  # wrong exception type
E           RuntimeError: name required

src/lib/vault.py:39: RuntimeError
========================= 2 failed, 3 passed in 0.06s ==========================
```

Full log: `outputs/pytest-output.txt`.

## Captured state

| Artifact | Path |
|---|---|
| Full pytest log | `outputs/pytest-output.txt` |
| Git porcelain status | `outputs/git-status.txt` (only `.seed_manifest.txt` added — seed-only artifact, no work commits) |
| Git diff (staged) | `outputs/git-diff.patch` (only the seed manifest) |
| bd list (JSON) | `outputs/bd-list.json` |
| Work artifacts copied for evidence | `outputs/artifacts/{src/lib/vault.py, tests/lib/test_vault.py, docs/notes/spec/sp001.md, docs/board.md}` |
| Route decision (in sandbox) | `sandbox/route_decision.md` |

## What was NOT done (and why)

The skill's Step 1 gate is unambiguous: failing tests → STOP. Therefore none of the AKM stage-7 writes were executed:

- `us003.status` NOT set to `done`.
- `im002.status` NOT set to `accepted`.
- `sp001.status` NOT set to `done`.
- `docs/notes/spec/sp001.md` footer `Index: [[board]]` NOT flipped to `[[archive]]`.
- `docs/board.md` `## ready` NOT modified.
- `docs/archive.md` `## done` NOT modified.
- `bd` epic / tasks NOT mutated by work-merge.
- No `git commit`, no `git push`, no branch / worktree op, no `gh pr create`.
- `spec-retro` NOT invoked.

## Key finding

bd shows all three child tasks of `wd2-245485-qnw` as `CLOSED` with `AUDITED: APPROVED` close-reasons, but the actual test suite is 3/5 green. The earlier `work-audit` step approved code that does not satisfy the spec's edge-case acceptance criterion ("Empty / None `new_value`: reject at the API boundary"). work-merge correctly refused to compound that false-positive by archiving the spec.
