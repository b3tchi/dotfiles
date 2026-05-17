━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  DISPATCH SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Board

- Total tasks:    7
- Open:           6
- Ready to work:  4
- In progress:    1  ⚠ (stale — see below)
- Blocked:        2
- Closed:         0

## ⚠ Stale in-progress task (prior session)

- **eval-d7u** — "Refactor: legacy config reader" — status `in_progress`, P2
  - Targets `src/lib/config.py` (pydantic-settings migration).
  - No agent is currently running for it in this session — this is a leftover from a previous run.
  - **Recommendation:** decide whether to **resume** (re-attach an agent), **reset** (`bd update eval-d7u --status open`), or **leave alone** before we dispatch. Stale `in_progress` may mean a previous agent crashed mid-merge; the worktree state is unknown.
  - This skill will NOT auto-resume it. Per the scrum-master protocol, stale in_progress requires human decision.

## Active epics

| Epic | Title | Targets (file paths) |
|---|---|---|
| **eval-1z3** | Epic: Auth 2FA | `src/services/auth/` , `tests/services/auth/` |
| **eval-kqp** | Epic: Billing invoice PDF | `src/services/billing/` , `tests/services/billing/` |

## Interference assessment

**eval-1z3 ↔ eval-kqp: NONE — can parallel.**

- Auth epic touches only `src/services/auth/**` + `tests/services/auth/**`.
- Billing epic touches only `src/services/billing/**` + `tests/services/billing/**`.
- No shared files, no shared directories, no shared modules. Safe to dispatch one task from each epic in the same wave.

## Ready queue

| Task | Epic | Title |
|---|---|---|
| eval-tx4 | eval-1z3 (Auth) | Auth 2FA - Task 1: TOTP generator |
| eval-7p1 | eval-kqp (Billing) | Billing PDF - Task 1: PDF template renderer |
| eval-xws | eval-1z3 (Auth) | Auth 2FA - Task 2: 2FA challenge endpoint *(blocked-by eval-tx4 — not actually ready yet)* |
| eval-kid | eval-kqp (Billing) | Billing PDF - Task 2: Invoice PDF endpoint *(blocked-by eval-7p1 — not actually ready yet)* |

(Note: `bd ready` surfaced eval-xws and eval-kid, but `bd show` confirms they have BLOCKS edges from eval-tx4 / eval-7p1 respectively, so the genuinely unblocked Task-1 tasks are eval-tx4 and eval-7p1.)

## Dependencies

- **Auth chain:** eval-tx4 → eval-xws (Task-2 blocked by Task-1).
- **Billing chain:** eval-7p1 → eval-kid (Task-2 blocked by Task-1).
- No cross-epic dependencies.

## Config (as requested)

| Setting | Value |
|---|---|
| `max_parallel` | **2** |
| `mode` | **waves** (halt for human feedback after each batch) |
| `worker_model` | **auto** (model chosen per-task by complexity heuristic) |

**Failure-escalation rule:** since `worker_model` is `auto`, no fixed sonnet→opus upgrade is forced on retry — `auto` already routes each task to the model that fits. The retry will simply re-evaluate complexity (typically biasing toward `opus` once a task has failed once).

## First batch (max_parallel = 2)

One task from each non-interfering epic, per the multi-epic parallelism rule:

- → **eval-tx4** — Auth 2FA Task 1: TOTP generator (epic eval-1z3) — model: sonnet
  - Reasoning (auto mode): small, well-scoped module (`src/services/auth/totp.py`) + 4 unit tests around standard crypto primitives. Auto routes to sonnet as the cheap-but-capable fit; on a failure the retry will escalate to opus.
- → **eval-7p1** — Billing PDF Task 1: PDF template renderer (epic eval-kqp) — model: sonnet
  - Reasoning (auto mode): small, well-scoped renderer module (`src/services/billing/pdf.py`) + 3 unit tests. Template rendering is bounded scope. Auto picks sonnet for the first attempt; retry would escalate to opus.

(If either task were significantly larger, more cross-cutting, or required novel architectural choices, `auto` would have picked `opus` from the start.)

## Halt

**STOP — awaiting human confirmation at the gate.**

- No epic state transitions have been performed (eval-1z3 and eval-kqp remain `open` / P2).
- No tasks have been claimed (still 1 in_progress — the stale eval-d7u — exactly as on entry).
- No agents have been dispatched.
- No worktrees created, no git activity.

**Proceed?** Options:
- `yes` — dispatch eval-tx4 + eval-7p1 as the first wave (after you tell me what to do about stale eval-d7u).
- `adjust config` — change max_parallel / mode / worker_model.
- `reorder` — swap which tasks go first.
- `abort` — stop the pipeline.

Please also confirm how to handle **eval-d7u** (resume / reset to open / leave as-is) before we proceed.
