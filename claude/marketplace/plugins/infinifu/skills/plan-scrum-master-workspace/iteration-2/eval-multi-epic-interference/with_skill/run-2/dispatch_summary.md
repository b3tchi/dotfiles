# Dispatch Summary

I'm using the plan-scrum-master skill to orchestrate the pipeline. **STOPPING at the human-confirmation gate — no agents dispatched, no tasks claimed.**

## Board

| Metric | Count |
|---|---|
| Total tasks | 6 |
| Ready | 4 (incl. 2 epics) |
| In progress | 0 |
| Blocked | 2 (dependency-blocked children) |
| Closed | 0 |

## Active Epics

| Epic ID | Title | Targets |
|---|---|---|
| `eval-6re` (epic_2fa) | Epic: Auth 2FA | `src/services/auth/totp.py`, `src/services/auth/middleware/__init__.py` |
| `eval-50w` (epic_ratelimit) | Epic: Auth rate-limit | `src/services/auth/limiter.py`, `src/services/auth/middleware/__init__.py` |

## Interference Assessment

| Pair | Verdict | Shared paths |
|---|---|---|
| `eval-6re` ↔ `eval-50w` | **INTERFERING — CONFLICT** | `src/services/auth/middleware/__init__.py` |

**Classification: INTERFERING.** Both epics' second tasks (`eval-wup`, `eval-qkk`) modify the same file: `src/services/auth/middleware/__init__.py`. Per `references/multi-epic.md`, when epics touch overlapping files they MUST be serialized — running them in parallel worktrees would cause merge conflicts a human would have to untangle.

**Decision: SERIALIZE — not parallelized.** Despite `max_parallel=2`, the first batch contains only **1 task** from a single epic. The other epic waits until the first finishes (or at least clears the shared file).

## Ready Queue

| Task ID | Epic | Title | Status |
|---|---|---|---|
| `eval-gwe` | `eval-6re` (2FA) | Auth 2FA - Task 1: TOTP generator | ready |
| `eval-0iv` | `eval-50w` (rate-limit) | Auth rate-limit - Task 1: limiter module | ready |
| `eval-wup` | `eval-6re` (2FA) | Auth 2FA - Task 2: 2FA middleware | blocked on `eval-gwe` |
| `eval-qkk` | `eval-50w` (rate-limit) | Auth rate-limit - Task 2: wire into middleware | blocked on `eval-0iv` |

## Dependencies

- `eval-wup` depends on `eval-gwe` (2FA chain)
- `eval-qkk` depends on `eval-0iv` (rate-limit chain)
- **Cross-epic conflict** on `src/services/auth/middleware/__init__.py` between `eval-wup` and `eval-qkk` — drives serialization of the two epics.

## Config

| Setting | Value |
|---|---|
| `max_parallel` | 2 |
| `mode` | waves |
| `worker_model` | auto |

Failure-escalation rule: on rejection/error/blocked, retry upgrades to `opus`. With `worker_model=auto`, model selection per task is auto and retry stays on the upgraded path.

## First Batch (serialized — 1 task only despite max_parallel=2)

| → Task | Epic | Title | Model |
|---|---|---|---|
| `eval-gwe` | `eval-6re` (2FA) | Auth 2FA - Task 1: TOTP generator | auto |

Batch size = 1. The rate-limit epic waits for the next wave.

## Gate

**Proceed? (yes / adjust config / abort)**

Awaiting human confirmation. No `Agent` calls made. No `bd update` mutations performed. No worktrees created. No git activity beyond the seed commit.
