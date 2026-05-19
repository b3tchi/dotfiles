# sp001 retro — baseline run (no skill)

## Entry state

- `sp001` already at `status: done`, listed in `docs/archive.md`.
- `docs/board.md` already cleared.
- `us003` already `done`, `im002` already `accepted`.
- bd epic `wd0-262950-60t` OPEN, all 3 child tasks CLOSED (3/3 — eligible for close).
- Only the seed commit `8c57034 ship sp001: rotate_secret + alias bookkeeping` exists; it shipped `src/lib/vault.py` + `tests/lib/test_vault.py` only.

## Findings (gap between spec and shipped reality)

1. **im002 over-claims components.** It listed `src/lib/vault_rotate.py` but the file does not exist in the repo — only `vault.py` shipped. The `## approach` paragraph also described an overlap timer + readers falling back to the prior version, neither of which is implemented (vault.py always returns the latest staged version).
2. **Tasks 2 and 3 closed without code.** bd audit notes mark them APPROVED, but no `vault_rotate.py` and no `tests/integration/test_rotate_synthetic.py` shipped. The "no 5xx during the rotation window" acceptance criterion on `us003` is therefore unverified in production.
3. **Task 3 NOTES surfaced a follow-up:** rotation correctness across regions is unverified (synthetic check is single-region).
4. **Vault TODO surfaced:** `set_timeout(timeout_ms)` configurability — out of scope for sp001 but left in code as a TODO.
5. **product.md was missing `>> [[im002]]` annotation** on the `us003` line (AKM convention — `us001` carries it).

## Actions applied

- **`docs/notes/im002.md`** — tightened `## approach`, `## api_surface`, and `## components` to match what actually shipped (vault.py rotate_secret only). Body now flags that orchestration is deferred and points at the follow-up stories.
- **`docs/product.md`** — added `>> [[im002]]` to the `us003` line; listed the three new draft stories under the platform-engineer persona.
- **`docs/notes/us006.md` (new, draft)** — verify credential rotation across regions (from Task 3 NOTES discovery).
- **`docs/notes/us007.md` (new, draft)** — configurable vault client timeout (from `vault.py` TODO).
- **`docs/notes/us008.md` (new, draft)** — automated overlap window + expiry for credential rotation (captures the deferred Task 2/3 scope so the work doesn't disappear with the closed epic).
- **bd epic `wd0-262950-60t`** — closed with retro summary referencing the new follow-ups.

## Untouched (intentionally)

- **ADRs `adr0001–adr0003`** — no decision shifted during sp001 execution; no new ADR filed.
- **Feature `ft002` (vault-secrets)** — constraint `providing`/`api_surface` did not change; the `rotate_secret` helper is captured on the consuming Implementation, not on the Feature (matches AKM "features serve Implementations" rule).
- **`board.md` / `archive.md`** — already in the correct post-merge state from the seed commit.
- **`us005`** — pre-existing dangling `[[pn999|compliance-officer]]` link unrelated to sp001; left alone.

## Notes on process

The retro could not retroactively repair the audit-pass for Tasks 2 and 3 — those are closed in bd history. The mitigation is that `us008` carries the still-owed work forward as draft scope for a future spec; without it the deferred orchestration would be invisible after the epic close.
