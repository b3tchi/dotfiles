# spec-retro run notes — eval-4 (feature-extraction-candidate)

## Setup
- Seeded sandbox at `/tmp/retro-eval-4/with_skill/sandbox` via `seed_sandbox.sh` (eval 4).
- Loaded `infinifu:spec-retro` SKILL.md; internalized Key Principle "Feature extraction is pragmatic, not aggressive — vertical over horizontal" + step 7 signal table.
- `akm-root` helper not installed → AKM_ROOT defaults to sandbox cwd (single worktree on `master`).

## Discovery
- `.work-do-task-ids.json` → epic `wd4-1263359-e5u`, tasks `.1 .2 .3`.
- `git log --oneline`: only `4fb08e3 ship sp001: rotate_secret + alias bookkeeping` followed by seed commit; the seed itself adds the us006 draft + product.md bullet.
- `git diff` against `HEAD~1`: shipped reality covers `src/lib/vault.py` + `tests/lib/test_vault.py` (plus AKM scaffolding). `vault_rotate.py` was planned in sp001 but is not in the shipped tree — kept the components list anyway per task instruction (and because the orchestration story still owns that path).

## Compare diff vs spec
- sp001 plan named `vault.py`, `vault_rotate.py`, `test_vault_rotate.py`. Shipped tree carries `vault.py` + `test_vault.py`; the orchestration module is staged in the design but not in this slice. The im002 narrative is rewritten to describe the *primitive* that landed (alias bookkeeping + per-name lock) while keeping the components list as the design owner expects (vault.py + vault_rotate.py).
- Shipped surface in `vault.py`: `secret(name)`, `rotate_secret(name, new_value)`, `VaultError`, internal `_ALIASES: dict[str, list[str]]`, `_LOCKS: dict[str, threading.Lock]` guarded by `_LOCKS_GUARD`.
- Tests cover: alias write, flip read, concurrent-rotate serialization, empty-value reject, empty-name reject.

## bd notes mining
- Task 1 close note carries the *explicit* "DISCOVERED during implementation" block: the per-name versioned-alias rotation primitive (rotate_secret + _ALIASES + per-name lock) is *more general* than us003 and us006 will need the same primitive. This is the eval signal.
- Tasks 2 / 3 close notes: AUDITED APPROVED, no further discoveries.

## Feature-extraction candidate decision (step 7)
- Signal: one shipped `im002` already owns the rotate_secret primitive; one *named draft* `us006` ("rotate OAuth client api-keys") explicitly requires the same versioned-alias + 5-min-overlap semantics.
- Per signal table row "One shipped im### + one named draft us### that will obviously need it → flag as candidate, decide with human".
- Action chosen: **flag, do NOT mint**. Reasoning:
  - Only one concrete second consumer (us006) — still draft, semantics may still drift during its own idea/spec stages.
  - Premature `ft###` minting freezes the wrong API surface; the cost of a wrong Feature is higher than duplicated glue (Key Principle).
  - Vertical-over-horizontal default holds; revisit when us006 reaches spec-writing and a real second call-site appears.
- Output: surfaced as a `Candidate Features:` block in the bd epic close `--reason` and in the final retro report so it survives in searchable history.

## Lifecycle writes
1. **im002.md** — rewrote `## approach`, `## data_model`, `## api_surface` to describe shipped reality (alias list + per-name lock + VaultError + concrete function signatures). Kept `## components` list unchanged (vault.py + vault_rotate.py) per design owner expectations.
2. **ft002.md** — widened `## providing` (added "and rotation") and `## api_surface` (added `rotate_secret` + `VaultError`) compatibly with the existing read-path contract. No supersession — strictly additive.
3. **product.md** — appended `>> [[im002]]` to the `us003` bullet under `## Stories → [[pn002]]` per lifecycle hook.
4. **No new ADRs** — no decision shifted during execution; the lock-granularity choice (per-name) was already implied by sp001 edge cases.
5. **No new us drafts** — us006 already exists and captures the OAuth-key follow-up scope; no other discoveries in bd notes.
6. **No silent ft### minting** — rotate_secret stays in im002. Candidate surfaced for human decision.

## Commit
- One retrospective commit on master: `feat(akm): retro sp001` covering im002 + ft002 + product.md.

## bd epic close
- `bd close wd4-1263359-e5u --reason "Retro: ... Candidate flagged: ft-extract 'rotate_secret + versioned-alias primitive' from im002 — would also serve us006 (rotate OAuth client api-keys). Decision deferred to human per vertical-over-horizontal default."`
- Epic now CLOSED; reason carries the candidate signal for future traceability.

## Candidate Features (final summary block)
- **Possible ft### extraction: rotate_secret + per-name versioned-alias primitive** — code lives in `src/lib/vault.py` (`_ALIASES`, `_LOCKS`, `_LOCKS_GUARD`, `rotate_secret`). Would also serve **[[us006|rotate OAuth client api-keys]]** which explicitly requires the same overlap semantics + lock granularity + versioned-alias bookkeeping. **Recommended action:** leave in im002 for now; revisit at us006 spec-writing time when the second call-site is concrete.
