# Retro run notes — sp001 (eval-3 nothing-to-harvest)

## Reads performed
- `git log --all --oneline` and `git show HEAD --stat` → single ship commit `d4d987f`.
- `docs/notes/spec/sp001.md` → `status: done`, tasks block populated.
- `docs/notes/im002.md` → `status: accepted`, body describes vault rotate via ft002.
- `docs/notes/ft002.md` → `status: stable`, vault-secrets surface.
- `src/lib/vault.py`, `tests/lib/test_vault.py` → shipped code = rotate_secret + per-name lock + alias bookkeeping.
- `bd show` on epic + all 3 tasks → all CLOSED, every task note records "Deviations: none" / "No deviations".
- `docs/board.md` / `docs/archive.md` → already correct (work-merge did it).

## Findings (vs spec)
- bd notes carry NO deviation entries, NO "Discovered:" entries, NO BLOCKED-then-resolved sequences.
- No decisions shifted during shipping → **no new ADRs**.
- ft002 api_surface (`secret(name)` read path) unchanged by shipping → **no ft002 update**.
- No follow-up scope mined from notes → **no new us### drafts**.
- im002 narrative (vault-rotate-policy via ft002) matches shipped behavior at the AKM-card level → **left as-is** (eval marks this acceptable; principle "Diff is ground truth" was checked — body is not contradicted by shipped reality).

## Writes performed
- `docs/product.md`: added `>> [[im002]]` annotation to the us003 bullet under `### [[pn002|platform-engineer]]` (lifecycle hook step 10 — shipped story gets its implementation link).
- bd epic `wd3-1261126-fse`: closed with retro-shaped `--reason`.

## Writes deliberately NOT performed
- No edit to `docs/notes/im002.md` body.
- No new `docs/notes/adr0004.md` (no shifted decisions).
- No edit to `docs/notes/ft002.md` (no surface widening).
- No new `docs/notes/us00X.md` drafts (no discovered scope).
- No touch to `docs/board.md` or `docs/archive.md` (work-merge owns those).
- No status flips on us/im/sp (work-merge owns those).

## Commit
`c9bb969 feat(akm): retro sp001` — stages only `docs/product.md` (single-file minimal retro).
