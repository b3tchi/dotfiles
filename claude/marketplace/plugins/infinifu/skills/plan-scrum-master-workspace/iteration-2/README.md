# plan-scrum-master eval suite — iteration-2

## Coverage map

| # | Eval | Tests | Status |
|---|------|-------|--------|
| 0 | `eval-orient-and-halt` | Orient → dispatch summary → halt at human-confirmation gate | **ready** (seed + grader, smoke-tested) |
| 1 | `eval-multi-epic-interference` | Two epics touching a shared file must serialize, not parallelize | **ready** (seed + grader, smoke-tested) |
| 2 | `eval-rejection-retry` | First reviewer rejection → resume same implementer via `SendMessage`, not fresh dispatch | **ready** (seed + reviewer shim + grader, shim flips reject→approve on attempt counter) |
| 3 | `eval-blocked-escalation` | Implementer reports blocked → immediate AGENT ALERT, pipeline halts | **ready** (seed + grader, smoke-tested) |
| 4 | `eval-wave-mode-pause` | mode=waves → halt after batch 1, do not auto-continue | **ready** (seed + grader, smoke-tested) |
| 5 | `eval-stale-in-progress-resume` | Detect orphan in_progress + orphan worktree, ask human before doing anything | **ready** (seed creates real orphan worktree metadata + dead branch, grader) |

## Why these six

The original iteration-1 only covered the orient/halt path. The five additions hit the load-bearing behaviors that are unique to this skill:

- **interference detection** — only place the orchestrator decides what NOT to parallelize.
- **rejection retry via SendMessage** — the SKILL.md prescribes resuming the original agent (it has full worktree + context). A fresh dispatch would silently work but waste tokens and lose state.
- **blocked escalation** — health-monitoring guarantee; a stuck agent must surface fast.
- **wave-mode pause** — the only mode-specific behavior that needs to be tested.
- **stale in_progress** — recovery path that is easy to do wrong (silent reset is dangerous).

## Running the ready evals

Each eval directory has `seed_sandbox.sh` (fixture) and `eval_metadata.json` (prompt + assertions). The skill-creator pattern is:

```bash
# Per eval (parallel via Agent tool):
SANDBOX=/tmp/plan-scrum-master-eval-<eval_id>/with_skill/sandbox
bash <eval-dir>/seed_sandbox.sh "$SANDBOX"
# then dispatch claude-with-skill subagent with:
#   prompt = eval_metadata.json.prompt
#   working dir = $SANDBOX
#   skill loaded = ../../skills/plan-scrum-master/SKILL.md
# capture outputs + timing.json into <eval-dir>/with_skill/run-N/

# Grade:
cd <eval-dir>/with_skill/run-N
python ../grade.py  # writes grading.json

# Aggregate:
python -m scripts.aggregate_benchmark <workspace>/iteration-2 --skill-name plan-scrum-master
```

Note: the skill-creator workflow also wants a baseline configuration. For an orchestrator skill the "no skill" baseline is meaningless (the model would not know how to dispatch). The realistic baseline is **iteration-1's SKILL.md** — the pre-refactor version. Snapshot it into `<workspace>/skill-snapshot/` before running and point the baseline subagent at the snapshot.

## Fixture infrastructure (all built)

1. **Controllable reviewer shim** — `eval-rejection-retry/seed_sandbox.sh` writes `review_shim.sh` in the sandbox. Tracks per-task attempts in `.review_attempts/<task-id>`. Attempt 1 → JSON `verdict: reject` with a specific reason (tie-breaking tests missing). Attempt 2 → `verdict: approve`. Reviewer agent should call the shim and parse the JSON.
2. **Orphan worktree generator** — `eval-stale-in-progress-resume/seed_sandbox.sh` creates a real branch + worktree, then deletes the worktree directory on disk while leaving `.git/worktrees/<name>/` metadata. This is the canonical "dangling worktree" state that `git worktree prune` would clean — orchestrator must NOT silently prune.
3. **Multi-epic 4-task fixture** — `eval-wave-mode-pause/seed_sandbox.sh` seeds 2 non-interfering epics (auth + billing) × 2 independent ready tasks each. Targets explicitly non-overlapping files within each epic.
4. **Insufficient-design task** — `eval-blocked-escalation/seed_sandbox.sh` seeds one task with `design: "Implement the thing. TBD."` — too vague for an implementer to act on, should produce a blocked status.

## Telemetry note

iteration-1 benchmark.md showed `Config B: 0 ± 0 runs` because no baseline was actually run. `timing.json` in `with_skill/run-1/` did get captured (36955 tokens / 77.7s) so the per-run mechanism works — the bug was at the aggregation step (no baseline subagent ever spawned). When running iteration-2, dispatch **both** with-skill AND baseline subagents in the same turn per the skill-creator playbook so both branches have timing data.

## Original grade.py path bug

The workspace-level `grade.py` (one level up) hardcodes `/home/jan/repos/b3tchi/acag/main/...` — a stale absolute path. The new `eval-multi-epic-interference/grade.py` uses `find_sandbox()` to resolve relative to cwd. Apply the same pattern to a refreshed `eval-orient-and-halt/grade.py` before re-running iteration-1 fixtures here.
