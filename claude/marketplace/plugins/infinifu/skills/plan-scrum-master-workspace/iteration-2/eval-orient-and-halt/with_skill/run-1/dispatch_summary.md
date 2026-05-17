# DISPATCH SUMMARY

I'm using the plan-scrum-master skill to orchestrate the pipeline.

## Board

| Metric        | Count |
|---------------|-------|
| Total tasks   | 7     |
| Ready         | 4     |
| In progress   | 1     |
| Blocked       | 2     |
| Closed        | 0     |

Note: `bd ready` lists 4 issues — 2 epics + 2 leaf tasks. The 2 epics are excluded from the dispatch queue (they get activated by status update, not by a worker).

## Stale `in_progress` from previous session (FLAG)

- **eval-6c1** — `Refactor: legacy config reader` — status `in_progress` with no active agent. This is a **stale** task from a **previous session**. Per skill protocol the scrum-master does NOT silently retry it — the worktree state from the prior session is unknown.

  **Need decision before proceeding:** resume (re-dispatch the original implementer), reset (return to `open` and re-queue), or close-out (mark cancelled / blocked). This is independent of the new epics and does not block wave 1.

## Active epics

| Epic ID    | Title                       | Targets                                                   |
|------------|-----------------------------|-----------------------------------------------------------|
| eval-nkz   | Epic: Auth 2FA              | `src/services/auth/`, `src/models/totp.py`, `tests/services/auth/` |
| eval-lla   | Epic: Billing invoice PDF   | `src/services/billing/`, `tests/services/billing/`        |

## Interference assessment

**eval-nkz ↔ eval-lla: NONE — can parallel. Non-interfering. No overlap.**

Reasoning (see `references/multi-epic.md`):
- eval-nkz writes only under `src/services/auth/` + `src/models/totp.py` + `tests/services/auth/`.
- eval-lla writes only under `src/services/billing/` + `tests/services/billing/`.
- No overlapping files, no overlapping directories, no conflict on shared infra.
- Verdict: **non-interfering** → safe to mix tasks from both epics in the same batch up to `max_parallel`.

## Ready queue

| Task ID  | Title                                          | Epic     | Status |
|----------|------------------------------------------------|----------|--------|
| eval-5jc | Auth 2FA - Task 1: TOTP generator              | eval-nkz | open   |
| eval-ddg | Billing PDF - Task 1: PDF template renderer    | eval-lla | open   |
| eval-1qw | Auth 2FA - Task 2: 2FA challenge endpoint      | eval-nkz | blocked by eval-5jc |
| eval-835 | Billing PDF - Task 2: Invoice PDF endpoint     | eval-lla | blocked by eval-ddg |

## Dependencies

Both epics have a 2-task chain: Task 1 unblocks Task 2. In wave 1 we can run Task 1 of each epic in parallel. Wave 2 (after both close) will be Task 2 of each epic.

## Config

- `max_parallel`: **2** (two implementer agents in parallel per batch).
- `mode`: **waves** (dispatch one batch, report, **wait for human feedback** before next wave).
- `worker_model`: **auto** (per-task complexity verdict drives model choice — see reasoning per task below).

**Failure-escalation rule (always on):** if any worker hits error / first rejection / `blocked`, the retry re-evaluates under `auto` and will tend to land on `opus`. Applies only to the retry dispatch; subsequent fresh tasks return to per-task `auto` selection.

## First batch (exactly max_parallel = 2)
→ eval-5jc: Auth 2FA - Task 1: TOTP generator (epic eval-nkz) model: sonnet [auto: medium complexity — single new file `src/services/auth/totp.py` + matching test, pyotp is well-known, clear testable success criteria, no cross-domain integration; reasoning chose sonnet because complexity is medium].
→ eval-ddg: Billing PDF - Task 1: PDF template renderer (epic eval-lla) model: sonnet [auto: medium complexity — single new file `src/services/billing/pdf.py` + matching test, weasyprint + Jinja2 mainstream, no cross-domain integration; reasoning chose sonnet because complexity is medium, would upgrade to opus on retry].

**Reviewer model rule:** each reviewer matches or exceeds its implementer's model (per `references/worker-models.md`). Both reviewers therefore start at model: sonnet (or upgrade if a retry has bumped the implementer side to opus).

## What happens on confirmation

1. For each picked task's parent epic (eval-nkz, eval-lla) — flip epic `open → in_progress` and bump epic + all child tasks `P2 → P1`.
2. Dispatch both implementers in **one** message, each with `isolation: "worktree"` and `run_in_background: true`.
3. Wait for the auto-notification when each agent completes — no polling, no sleeps.
4. Relay each implementer report to a reviewer agent.
5. Because `mode = waves`, after batch 1 closes I report and **stop**, waiting for your go-ahead before dispatching wave 2 (Task 2 of each epic).

## STOP — Human confirmation gate

**Please confirm before I dispatch anything. Proceed?**

I have not claimed any task, not activated any epic, not created any worktree, and not written any code. Two decisions are needed:

1. **Stale task `eval-6c1`**: resume / reset to open / close-out? (independent of the new batch but should be handled.)
2. **First batch as listed above (eval-5jc + eval-ddg, both sonnet under auto)**: proceed, adjust config (`max_parallel`, `mode`, `worker_model`), or abort?

Reply with `proceed` / `confirm` (or adjustments) and I will run Step 3.
