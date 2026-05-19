# spec-ready run notes — sp001

## Skill applied
`infinifu:spec-ready` (iteration-1, eval-0-strong-ready, with_skill).

## bd ids minted

| Role | bd id | Title |
|---|---|---|
| Epic | `sandbox-nt2` | Epic: rotate service credentials without downtime [sp001] |
| Task 1 | `sandbox-nt2.1` | Add rotate_secret helper to vault.py |
| Task 2 | `sandbox-nt2.2` | Add vault_rotate orchestration module |
| Task 3 | `sandbox-nt2.3` | Synthetic-check hook for rotation window |

All three tasks were minted with `--parent sandbox-nt2`, confirmed via `bd list --parent sandbox-nt2` showing the tree.

## Blocking deps wired (from `#### depends` in sp001.md)

| Later task | depends on | bd dep add |
|---|---|---|
| `sandbox-nt2.2` (Task 2) | `sandbox-nt2.1` (Task 1) | added |
| `sandbox-nt2.3` (Task 3) | `sandbox-nt2.1` (Task 1) | added |
| `sandbox-nt2.3` (Task 3) | `sandbox-nt2.2` (Task 2) | added |

Task 1 has `#### depends: - (none — root task)` → no deps wired.

## Spec annotations (additive, all H4 properties preserved)

`docs/notes/spec/sp001.md` got three new `#### bd` blocks appended at the end of each `### Task N`:
- Task 1 → `sandbox-nt2.1`
- Task 2 → `sandbox-nt2.2`
- Task 3 → `sandbox-nt2.3`

## Status flip

`docs/notes/spec/sp001.md` frontmatter: `status: spec` → `status: ready`.

## Board move

`docs/board.md`:
- Removed `[[sp001|rotate service credentials without downtime]]` from `## spec`.
- Added it under `## ready` (same wikilink, same label).

## Out-of-scope guardrails honored

- No `bd update --status in_progress` calls.
- No `bd close` calls.
- No edits under `src/` or `tests/`.
- No re-writes of `## tasks` content; bd annotations are purely additive.

## Verification

- `bd list --parent sandbox-nt2` → epic + 3 tasks listed as a tree.
- `bd ready` → shows root tasks (Task 1 sandbox-nt2.1 unblocked; Task 2 & 3 not in ready output because they have blocking deps).

## Caveat — pre-existing seed bd entries

The sandbox seed shipped a `.beads/issues.jsonl` containing two leftover entries (`sandbox-33d` "Spec sp001: rotate service credentials without downtime" and `sandbox-bxk` "Task 1: Add rotate_secret helper to vault.py"). The live bd DB was empty at the start of the run (`bd ready` returned "No open issues"). The very first `bd create` triggered an auto-import of the jsonl that brought those two ghost entries back alongside the freshly-minted ones.

Per the spec-ready disambiguation rules, the skill checks **the spec file** for prior `#### bd <id>` annotations to decide whether a spec has already been processed. The spec file had none — so the skill correctly proceeded with minting. The ghost entries in bd are a sandbox-seed artifact, not a skill-contract violation, and would need cleanup outside this skill's scope (manual `bd close` or seed regeneration).

## Files captured

- `outputs/git-status.txt` — staged tree summary (2 modifications + 1 untracked seed manifest).
- `outputs/git-diff.patch` — full staged diff.
- `outputs/bd-list.json` — bd issue dump (includes ghost seed entries).
- `outputs/bd-ready.txt` — `bd ready` output post-run.
- `outputs/modified-files/docs/board.md`
- `outputs/modified-files/docs/notes/spec/sp001.md`
- `outputs/new-files/` — empty; the skill creates no new files.

Not committed per instructions.
