━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DISPATCH SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

I'm using the plan-scrum-master skill to orchestrate the pipeline.

## Board

| Metric | Count |
|---|---|
| Total tasks (this run) | 6 (2 epics + 4 child tasks) |
| Ready (epic A Task 1 + epic B Task 1) | 2 |
| In progress | 0 |
| Blocked (by dependency) | 2 (Task 2 of each epic) |
| Closed | 0 |

## Active epics

- **eval-fgq — Epic: Auth 2FA** (epic_2fa)
  - Targets: `src/services/auth/totp.py`, `src/services/auth/middleware/__init__.py`
  - Spec: `board/ready/auth-2fa.md`
  - Children:
    - `eval-ctz` — Auth 2FA - Task 1: TOTP generator → creates `src/services/auth/totp.py` (READY)
    - `eval-d7t` — Auth 2FA - Task 2: 2FA middleware → modifies `src/services/auth/middleware/__init__.py` (blocked on Task 1)

- **eval-7sj — Epic: Auth rate-limit** (epic_ratelimit)
  - Targets: `src/services/auth/limiter.py`, `src/services/auth/middleware/__init__.py`
  - Spec: `board/ready/auth-rate-limit.md`
  - Children:
    - `eval-tf0` — Auth rate-limit - Task 1: limiter module → creates `src/services/auth/limiter.py` (READY)
    - `eval-7sj.1` — Auth rate-limit - Task 2: wire into middleware → modifies `src/services/auth/middleware/__init__.py` (blocked on Task 1)

## Interference assessment

**eval-fgq (Auth 2FA) ↔ eval-7sj (Auth rate-limit): INTERFERING — must serialize.**

Both epics modify the same file:
- `src/services/auth/middleware/__init__.py`
  - Epic A Task 2 (`eval-d7t`) adds the 2FA challenge interceptor.
  - Epic B Task 2 (`eval-7sj.1`) wires the rate limiter in front of the auth check.

Running these epics concurrently would cause merge conflicts in worktrees the human would have to untangle (per `references/multi-epic.md`: "Either epic touches shared infra ... → interfering → serialize").

**Decision: serialize — finish Epic A's tasks (eval-fgq) before starting Epic B's (eval-7sj).** Tasks from Epic B will be dispatched only after Epic A is fully closed.

Note: Even Task 1 of each epic (`eval-ctz` creates `totp.py`, `eval-tf0` creates `limiter.py`) targets disjoint *new* files, but because the *epics* interfere on the shared middleware file, the conservative call per the skill is to serialize at the epic level — not interleave task-by-task. This avoids the situation where both Task 2s become ready simultaneously and collide.

## Ready queue (current)

- [eval-fgq] `eval-ctz` — Auth 2FA - Task 1: TOTP generator
- [eval-7sj] `eval-tf0` — Auth rate-limit - Task 1: limiter module   *(deferred — epic serialized behind eval-fgq)*

## Dependencies

- `eval-d7t` blocked by `eval-ctz` (Epic A internal chain)
- `eval-7sj.1` blocked by `eval-tf0` (Epic B internal chain)
- Inter-epic: Epic B held entirely behind Epic A by the interference rule above.

## Config (as requested)

| Setting | Value |
|---|---|
| `max_parallel` | **2** |
| `mode` | **waves** (pause for human feedback after each batch) |
| `worker_model` | **auto** |

Failure-escalation rule: with `worker_model: auto`, no model upgrade is needed on retry (auto already picks the right tier). Second failure on the same task escalates to human.

## First batch (serialized — ONE task despite max_parallel=2): → eval-ctz — Auth 2FA - Task 1: TOTP generator (epic eval-fgq) model: auto

**Only one task is dispatched in this batch.** Even though `max_parallel=2` and two tasks are technically `bd ready`, the interference check serializes the two epics — the rate-limit epic's Task 1 is held back until Epic A is finished.

After Epic A's tasks (eval-ctz then eval-d7t) close, the next batch will dispatch Epic B starting with `eval-tf0`.

## Confirmation gate

Proceed with this plan? Reply:
- **`yes` / `confirm` / `proceed`** — dispatch eval-ctz now (Epic A Task 1)
- **`adjust`** — change max_parallel / mode / worker_model, or override the serialization
- **`abort`** — stop, no agents dispatched

Waiting for your confirmation. No bd task has been claimed and no implementer has been dispatched.
