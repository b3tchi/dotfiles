# Spec-retro run notes (sp001 — Acme sandbox)

## Skill invocation

Announced: "Using spec-retro skill to refresh the AKM graph post-merge."

## Preconditions verified

- `sp001.status: done`, lives under `docs/archive.md ## done`, footer `Index: [[archive]]` — work-merge precondition satisfied.
- `docs/board.md` no longer lists `sp001` — work-merge already moved it; spec-retro did NOT touch board or archive.
- `us003.status: done`, `im002.status: accepted` — work-merge already flipped statuses; spec-retro did NOT re-flip.
- All 3 child bd tasks CLOSED with audit-approved reasons.
- bd epic `wd0-261887-47d` was OPEN at entry; merge commit `4e8ddd3 ship sp001: rotate_secret + alias bookkeeping` present.

## Diff vs spec — what shipped

Walked `git show HEAD --name-status` against `sp001.## plan` / `## tasks` and re-read `src/lib/vault.py` + `tests/lib/test_vault.py`.

| Predicted | Shipped |
|---|---|
| `src/lib/vault.py` extended with `rotate_secret` | YES — `rotate_secret(name, new_value)` at vault.py:33, per-name `threading.Lock` via `_lock_for` at :26, alias bookkeeping via `_ALIASES` dict, `VaultError(RuntimeError)` at :10. |
| `src/lib/vault_rotate.py` orchestration module (overlap timer + scheduler + restart-resume) | NOT shipped. No file present. Versioned-alias retention left to backend vault. |
| `tests/lib/test_vault_rotate.py` (4 scheduler tests) | NOT shipped. |
| `tests/integration/test_rotate_synthetic.py` (synthetic-check hook) | NOT shipped. No `tests/integration/` directory. |
| 5 unit tests in `test_vault.py` | YES — all 5 present + a 6th edge case (empty-name). |
| `vault.secret(name)` returns latest after flip, concurrent rotate serializes, empty value rejected | YES — covered by the test suite. |

**Verdict:** the spec's split-module design (`vault_rotate.py` with explicit T+5min scheduler + synthetic-check) was collapsed during execution. The single-module shipped solution is consistent with us003's acceptance criteria (rotation correctness during single-region overlap) because the vault backend manages versioned-alias retention — but the synthetic-check AC was deferred entirely. This is the deviation that drives the new ADR.

## bd notes mined for discoveries

- Task 1 close note: `Deviations: none` (vault.py:36 rotate_secret meets criteria; 5 tests pass).
- Task 2 close note: closed AUDITED: APPROVED with no notes body → the orchestration scope shrank silently into vault.py; the audit accepted the collapse.
- Task 3 close note carries the explicit discovery: *"DISCOVERED during implementation: rotation correctness across regions is unverified — current synthetic check is single-region. Likely needs a follow-up us### for cross-region failover behavior."* → fed directly into us006 draft.
- A TODO is sitting in `src/lib/vault.py:49-51` (`set_timeout` is hardcoded to 5000ms, too short for the European region). Out of scope for this retro but worth a future story if it persists — not lifted into a us### today since it's a hardcoded constant, not a discovered capability, and the task notes did not surface it.

## Writes (in retro order: ADRs → ft → im → us)

### 1. New ADR — `docs/notes/adr0004.md`

- Title: *Credential rotation lives in vault.py — no separate orchestration module.*
- Category: `[[cat001]]` (security) — single-category per ADR schema.
- `status: Accepted`, `created: 2026-05-17`.
- Context records the original split plan and the two facts that drove the collapse (backend-managed retention + state-locality with locks).
- Decision: keep rotation in `vault.py`; do not ship `vault_rotate.py`, scheduler, or synthetic-check as part of sp001.
- Consequences: surface narrower; 5-minute overlap is now a backend contract not an in-process guarantee; observability deferred; forward-cited from `[[im002]]` and `[[us006]]`.
- Does NOT supersede an existing ADR — none of adr0001/0002/0003 covered this decision.

### 2. ft002 update (in-place widen — `docs/notes/ft002.md`)

- `## providing` widened to mention `rotate_secret` and live rotation alongside `secret`.
- `## api_surface` rewritten to document `secret`, `rotate_secret`, and `VaultError` with exception contract (`ValueError` on empty input, `VaultError` on backend failure).
- `## data_model` widened to note the in-memory `_ALIASES` + per-name lock map (impl detail; backend remains source of truth).
- `## sample` cross-references `[[im002]]` and `[[adr0004]]`.
- Surface widened *compatibly* — the read path is unchanged, rotate is new — so updated in place per the skill guidance ("feature widening: update in place; feature changing: supersede"). No supersession needed.
- `status: stable` preserved.

### 3. im002 rewrite (`docs/notes/im002.md`)

- `## approach` rewritten to describe the shipped single-module shape and explicitly note the collapse-of-scope referencing `[[adr0004]]`.
- `## data_model` rewritten to describe `_ALIASES` and the `_LOCKS` / `_LOCKS_GUARD` mechanism that actually shipped.
- `## api_surface` rewritten to list the three concrete entry points (`secret`, `rotate_secret`, `VaultError`) with their contracts.
- `## components` corrected: only `src/lib/vault.py` + `tests/lib/test_vault.py` (the planned `vault_rotate.py` + `tests/integration/test_rotate_synthetic.py` did not ship, so they are NOT listed — components reflect shipped reality).
- `## features` continues to wikilink `[[ft002]]`; `## specs` continues to wikilink `[[sp001]]`; categories `[[cat001]] [[cat003]]` preserved; `solves [[us003]]` preserved.
- Frontmatter untouched: `status: accepted` retained (spec-retro is forbidden from flipping status).

### 4. us006 draft (`docs/notes/us006.md`)

- Sourced from Task 3 close note (cross-region discovery).
- `status: draft`, `created: 2026-05-17`, persona `[[pn002|platform-engineer]]` (same as us003 — extends platform-engineer's rotation story).
- Tag wikilink `[[platform-flow]]` matches the convention used on us003.
- `## because` explicitly back-references `[[sp001]]` and `[[adr0004]]` so future readers can trace why this scope was discovered (synthetic check + cross-region were both deferred).
- 4 acceptance_criteria covering propagation bound, per-region synthetic check, no-auto-rollback alerting, and an integration test.
- Lands at `status: draft` so the next `idea-implement` cycle picks it up — not silently pulled into the closing epic.

## bd epic close

```
bd close wd0-261887-47d --reason "Retro: rotate_secret + alias bookkeeping shipped (single-region). Rewrote im002 to match shipped (no vault_rotate.py — collapsed into vault.py), minted adr0004 (rotation lives in vault.py; no separate orchestration module), updated ft002 api_surface (rotate_secret + VaultError), drafted us006 (cross-region rotation verification follow-up)."
```

Epic transitioned to CLOSED with retro-shaped reason carrying counts and names.

## Out-of-scope verifications (skipped per skill rules)

- Did NOT edit `docs/board.md` (already clean — work-merge removed sp001).
- Did NOT edit `docs/archive.md` (sp001 already listed under `## done`).
- Did NOT re-flip any `status:` field on us003 / im002 / sp001.
- Did NOT touch branch / PR / worktree state.
- Did NOT run tests (work-merge gated on green).
- Did NOT update `docs/product.md` — its `## Architecture Decision Records` section under `[[cat001|security]]` currently lists only adr0001; adding adr0004 there would be a downstream hub-refresh, which spec-retro does not call out in its writes list. Flagging here for the team if they want hub coverage automated in a future skill iteration.

## File-level summary

NEW (2):
- `docs/notes/adr0004.md`
- `docs/notes/us006.md`

MODIFIED (2):
- `docs/notes/im002.md`
- `docs/notes/ft002.md`

bd state: epic CLOSED. No commit created (per instructions).

## Skill performance notes (for evaluators)

What the skill enabled well:
- The "diff is ground truth, spec is history" principle pointed cleanly at the right rewrite — the spec's predicted file set was wrong, and the skill made it natural to reshape im002 around what actually shipped rather than what was planned.
- The four-write ordering (ADRs → ft → im → us) made the cross-references resolve cleanly on the first pass (im002 could cite adr0004 because the ADR was written first; us006 could cite adr0004 for the same reason).
- The explicit out-of-scope list (no board / archive / status flips / tests) saved time — the skill description is unambiguous about what work-merge owns.

What was ambiguous:
- The skill writes list does NOT include `docs/product.md` hub refresh, but a new ADR (adr0004) genuinely belongs under `## Architecture Decision Records ### [[cat001|security]]` in product.md per the AKM. Either spec-retro should be extended to refresh the hub, or there should be a sibling skill (e.g. `product-hub-refresh`) that runs at the same lifecycle stage. Flagged in run_notes rather than silently edited.
- "Mine bd notes for discovered scope" worked, but the deviation in Task 2 (silent scope collapse — no `vault_rotate.py` shipped) was only inferable from the diff, not from the task close note (which was just "AUDITED: APPROVED" with no body). The skill's reliance on task notes alone would miss this — having to cross-reference `git show --name-status` against the spec's `## plan` was what surfaced it. The skill text already says "Diff is ground truth" so the principle is present; the checklist step 3 ("Compare diff vs spec") covers it; just noting that bd notes alone are insufficient for catching silent scope shrinkage.
