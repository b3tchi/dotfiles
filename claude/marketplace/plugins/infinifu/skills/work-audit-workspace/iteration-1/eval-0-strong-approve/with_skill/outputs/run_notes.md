# work-audit run notes — eval-0-strong-approve

## Task audited
- ID: `wd0-1285-8zl.1`
- Title: Task 1: Add rotate_secret helper to vault.py
- Epic: `wd0-1285-8zl` (sp001 — rotate service credentials without downtime)
- Pre-audit state: `in_progress` with implementer IMPLEMENTED notes
- Post-audit state: `closed` with AUDITED: APPROVED notes

## Verdict
**APPROVED** — closed via `bd close wd0-1285-8zl.1 --reason "AUDITED: APPROVED ..."`.

## Skill walk
Walked all 7 work-audit steps:

1. Loaded task via `bd show wd0-1285-8zl.1`. Pulled design, success_criteria, edge_cases, test_plan from sp001.md (### Task 1) and AC from us003.md.
2. Read files with Read tool: `src/lib/vault.py` (full), `tests/lib/test_vault.py` (full). Verified `git status` shows the implementer's work is staged into the seed commit (no working-tree drift).
3. Automated checks:
   - `rg "TODO|FIXME|XXX|HACK|raise NotImplementedError|\\.skip\\b|@pytest\\.mark\\.skip"` → 2 hits.
     - `vault.py:11` `pass` is the canonical empty-class body for `VaultError(RuntimeError)` — not a stub.
     - `vault.py:49` `# TODO: set_timeout(...)` is **pre-existing seed scaffolding** (verified via `git show HEAD:src/lib/vault.py`) and explicitly marked `Out of scope for the rotation work`. Not introduced by this task.
   - `rg "except\\s*:|time\\.sleep|was:|previously:|_old|_legacy|deprecated"` → 0 hits. Anti-patterns clean.
4. Success criteria verified with evidence (table below).
5. New tests audited (table below) — 5 tests, all meaningful, all answer "what bug would this catch?".
6. Design deviation check — minor test-plan swap, implementation otherwise matches design.
7. Verdict + `bd close` with audit evidence.

## Success criteria (evidence)
| Criterion | Evidence | Result |
|---|---|---|
| `rotate_secret(name, new_value)` writes new versioned alias without touching old | `src/lib/vault.py:33-46` uses `_ALIASES.setdefault(name, []).append(new_value)` — prior entries are preserved; `versions[-1]` returns latest | Met |
| `secret(name)` returns new value after flip | `src/lib/vault.py:19-23`; `test_secret_returns_new_after_flip` passes | Met |
| 5 unit tests pass | `python -m pytest tests/lib/test_vault.py -v` → `5 passed in 0.03s` | Met |

## Edge cases (per spec)
| Edge case | In code? | In tests? |
|---|---|---|
| Concurrent rotate serializes | Yes — per-name lock at `vault.py:26-30` used in `rotate_secret` | Yes — `test_concurrent_rotate_serializes` (5 threads, all 5 versions land) |
| Vault unreachable raises VaultError | Yes — `vault.py:45-46` wraps backend exceptions | Not directly tested; `vault.py` is an in-process stub with no injectable backend, so the unreachable scenario is hard to exercise. Acceptable. |
| Empty / None new_value rejected | Yes — `vault.py:38-39` | Yes — `test_empty_value_rejected` + bonus `test_empty_name_rejected` |

## Test audit (5 new tests)
| Test | Bug it catches | Assertion meaningful? |
|---|---|---|
| `test_rotate_stages_new_alias` | Missing alias-write (would return `<vault:name>` placeholder) | Yes |
| `test_secret_returns_new_after_flip` | Stale-read bug (returning `versions[0]`) | Yes |
| `test_concurrent_rotate_serializes` | Race / lost writes on concurrent rotate | Yes — `len(_ALIASES["token"]) == 5` |
| `test_empty_value_rejected` | Missing input validation (empty value) | Yes |
| `test_empty_name_rejected` | Missing input validation (empty name) | Yes |

## Anti-pattern checks
- Bare `except:` — none.
- `time.sleep` for overlap timing — none.
- Mutation of vault state outside `vault.py` — N/A (Task 1 only touches `vault.py`).

## Deviations
- **Test plan swap (minor):** spec's test_plan listed `test_vault_unreachable_raises`; implementer shipped `test_empty_name_rejected` instead. Same total count (5), both tests meaningful. Defensible given the in-process stub.
- Implementer's `Deviations: none` note was a minor under-report — the swap is a deviation. Not severe enough to reject; success_criteria are all met with evidence.

## Files inspected
- `/home/jan/.../with_skill/sandbox/src/lib/vault.py`
- `/home/jan/.../with_skill/sandbox/tests/lib/test_vault.py`
- `/home/jan/.../with_skill/sandbox/docs/notes/spec/sp001.md`
- `/home/jan/.../with_skill/sandbox/docs/notes/us003.md`

## bd state transitions
- Before: `wd0-1285-8zl.1` = IN_PROGRESS
- After: `wd0-1285-8zl.1` = CLOSED with full audit-evidence note

## Captured artifacts
- `git-status.txt` — `A .seed_manifest.txt` (test-harness fingerprint file only)
- `git-diff.patch` — staged diff (.seed_manifest.txt only — no code changes in this audit step; implementer's code is in the seed commit)
- `bd-list.json` — full bd state with task closed
- `bd-show-task1.txt` — final task view with AUDITED: APPROVED note
- `new-files/.seed_manifest.txt` — copy of the new file
