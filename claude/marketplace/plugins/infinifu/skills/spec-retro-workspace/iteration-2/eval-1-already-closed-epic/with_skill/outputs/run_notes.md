# spec-retro run notes — eval-1 (already-closed-epic)

## Target
- Spec: `sp001` (rotate service credentials without downtime)
- Bd epic: `wd1-1258499-dir`

## Detection

Ran the entry-checklist preconditions and hit the Disambiguation rule "**bd epic already closed**" immediately:

```
$ bd show wd1-1258499-dir
✓ wd1-1258499-dir [EPIC] · Epic: rotate service credentials without downtime [sp001]   [● P2 · CLOSED]
Close reason: Retro: prior run. im002 rewritten. Closed by previous spec-retro.
```

Signals confirming this was a prior `spec-retro` close (not an out-of-process accident):

1. `status: closed` on the epic.
2. `close_reason` is **retro-shaped** — it explicitly names the retro action ("im002 rewritten"), the actor ("previous spec-retro"), and the framing ("Retro: prior run").
3. All three child tasks are `closed` with `AUDITED: APPROVED` reasons — the upstream `work-audit` + `work-merge` already ran (preconditions for the prior retro were satisfied).
4. `closed_at` on the epic (`2026-05-19T00:57:29Z`) post-dates the task closes (`...22Z`/`...23Z`/`...24Z`) — consistent with retro running after `work-merge` closed each task.

Per the skill's Disambiguation table:
> **bd epic already closed** → either retro already ran (idempotent re-run is fine if you just want to verify) or someone closed the epic out-of-process. Verify with `bd show <epic-id> --reason` and either proceed (if reason was retro-shaped) or restore.

The reason **is** retro-shaped → idempotent no-op path.

## Decision

**No-op.** Surface the prior retro and stop. Specifically:

- Did **NOT** re-close the epic (already closed; re-closing would be either a no-op or an error and would clobber the original close_reason if `--reason` were re-set).
- Did **NOT** rewrite `docs/notes/im002.md`. The prior retro already wrote shipped-reality into it; rewriting again with no new diff is churn.
- Did **NOT** mint any new `adr####.md`. ADRs are immutable; no new decision shifted on *this* invocation.
- Did **NOT** update any `ft###.md`. No new consumer surface visible from this run.
- Did **NOT** draft any new `us###.md`. Follow-up scope was the prior retro's responsibility, not this one's.
- Did **NOT** edit `docs/board.md` or `docs/archive.md`. Those belong to `work-merge`, not `spec-retro` — out of scope regardless of retro state.
- Did **NOT** touch `docs/product.md`. The `>> [[im###]]` annotation was the prior retro's lifecycle hook write.
- Did **NOT** create a `feat(akm): retro sp001` commit. Nothing changed in the working tree; an empty commit would lie about state.

## Working-tree state

`git status --porcelain` is empty after this run. The sandbox is unchanged from seed.

## Note on `akm-root`

The skill instructs `AKM_ROOT="$(akm-root)"`. The `akm-root` helper is not on PATH in this sandbox; the skill says to "surface its stderr and abort — never silently land retro mutations on the feature branch." Since this run is a no-op anyway (no AKM writes attempted), the missing helper is moot — there is nothing to land. The detection of the prior close happens before any AKM read/write needing the resolved root.
