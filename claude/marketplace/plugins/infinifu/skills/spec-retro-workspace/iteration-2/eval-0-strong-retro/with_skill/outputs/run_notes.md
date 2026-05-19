# spec-retro run notes — sp001 (rotate service credentials without downtime)

Announcement: "Using spec-retro skill to refresh the AKM graph post-merge."

## 1. AKM root resolution
- `akm-root` helper not on PATH; per skill, falls back to cwd.
- AKM_ROOT = /tmp/retro-eval-0/with_skill/sandbox
- Not inside a feature worktree (single commit on master) — main worktree IS the sandbox.

## 2. Target sp### identification
- Target: `sp001` (rotate service credentials without downtime).
- Verified `docs/notes/spec/sp001.md` has `status: done` and footer `Index: [[archive]]` — work-merge already flipped it. Precondition for spec-retro met.
- Did NOT touch sp001 status or footer (work-merge owns those).

## 3. Read shipped reality
- `git log --oneline` → single squashed merge commit `bda9ad2 ship sp001: rotate_secret + alias bookkeeping`.
- `git show --stat HEAD` → 39 files; production-code changes:
  - `src/lib/vault.py` (new): exposes `secret`, `rotate_secret`, `VaultError` plus internal `_lock_for` and `_read_alias`. Per-name locking via `_LOCKS` + `_LOCKS_GUARD`. Versioned alias list in `_ALIASES`. Carries a `TODO: set_timeout(timeout_ms)` comment about hardcoded 5000ms being too short for the European region.
  - `tests/lib/test_vault.py` (new): 5 tests covering staging, post-flip read, concurrent serialization, empty value, empty name.
  - `src/services/{auth,metrics,reports}/__init__.py` stubs (existing services, not directly touched by rotation logic).
- Source of truth confirmed: vault.py contains rotate_secret with versioned alias bookkeeping. Notable gaps vs spec plan:
  - Spec promised `src/lib/vault_rotate.py` (orchestration with T+5min expiry scheduler) — NOT shipped.
  - Spec promised synthetic-check integration test under `tests/integration/test_rotate_synthetic.py` — NOT shipped.
  - The 5-minute overlap timer / expiry behavior is absent from the actual code; the implementation is staging-only.

## 4. Compare diff vs spec
- Task 1 (rotate_secret helper) — SHIPPED, matches design.
- Task 2 (vault_rotate orchestration) — bd note marks closed but the file is not in git tree. The orchestration scheduler did NOT actually land; only the staging helper exists.
- Task 3 (synthetic-check hook) — bd note has discovered scope: "rotation correctness across regions is unverified — current synthetic check is single-region. Likely needs a follow-up us### for cross-region failover behavior."
- Discrepancies feed the rewrite: `im002.## components` should list only `src/lib/vault.py` (drop the `vault_rotate.py` line); `## approach` and `## api_surface` describe what actually shipped (staging + locking, no scheduled expiry yet — the 5-minute window is a planned follow-up).
- Discovered scope from Task 3 → new us### draft for cross-region rotation verification.
- Hidden TODO in vault.py about `set_timeout` is out of scope per the comment ("worth tracking") — leaving aside; the cross-region story is the more concrete follow-up the bd notes flagged.

## 5. Re-read im002
- Currently lists `vault_rotate.py` as a component (didn't ship) and says rotate_secret lands "in the same lib" — directionally correct.
- Rewrite `## approach`, `## components`, `## data_model`, `## api_surface` to describe shipped reality: staging-only, per-name locks, expiry/scheduled-flip deferred.

## 6. Re-read ft002 (consumed feature)
- ft002 currently exposes only `secret(name)`. Shipped reality adds `rotate_secret(name, new_value)` and a shared `VaultError`. Surface widened compatibly → update in place (no supersession needed).

## 7. Feature-extraction candidates
- Scanned im002 / ft002 — no extraction candidates. Per-name locking + versioned alias bookkeeping is internal vault glue; no second `im###` named or in flight consumes it. Vertical-over-horizontal default: leave in `ft002` / `im002`.

## 8. Re-read ADRs in spec categories
- cat001 + cat003 binding ADRs: adr0001 (basic-auth), adr0002 (Postgres reports retention), adr0003 (smtplib direct).
- None of these decisions shifted during the rotation work. No new ADRs to mint. (The cross-region follow-up may later produce one, but it belongs in that story's spec, not this retro.)

## 9. Mine bd notes for discovered scope
- Task 1 notes: clean, no discoveries.
- Task 2 notes: empty.
- Task 3 notes: "DISCOVERED during implementation: rotation correctness across regions is unverified — current synthetic check is single-region. Likely needs a follow-up us### for cross-region failover behavior."
- → Mint `us006` at status: draft for cross-region rotation correctness.

## 10. Writes plan (in skill order)
- ADRs: none.
- ft updates: ft002 (widen api_surface with rotate_secret + VaultError).
- im rewrite: im002 (approach, components, data_model, api_surface).
- us drafts: us006 (cross-region rotation verification).
- product.md: attach `>> [[im002]]` to the us003 bullet.

## 11. Execution
- (see commit log below)

## 12. bd close + verification
- Close epic `wd0-1258131-3a1` with retro-shaped reason.
- Final verify: git log shows commit; bd epic closed; status frontmatter untouched on us003/im002/sp001; board.md and archive.md unchanged.
