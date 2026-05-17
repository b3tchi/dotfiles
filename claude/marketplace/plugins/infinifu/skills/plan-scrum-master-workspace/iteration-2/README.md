# plan-scrum-master eval suite — iteration-2

## Coverage map

| # | Eval | Tests | Status |
|---|------|-------|--------|
| 0 | `eval-orient-and-halt` | Orient → dispatch summary → halt at human-confirmation gate | **ready** (carried over from iteration-1, seed + grader) |
| 1 | `eval-multi-epic-interference` | Two epics touching a shared file must serialize, not parallelize | **ready** (seed + grader written this iteration) |
| 2 | `eval-rejection-retry` | First reviewer rejection → resume same implementer via `SendMessage`, not fresh dispatch | **stub** (assertions drafted, fixture not yet wired) |
| 3 | `eval-blocked-escalation` | Implementer reports blocked → immediate AGENT ALERT, pipeline halts | **stub** (assertions drafted) |
| 4 | `eval-wave-mode-pause` | mode=waves → halt after batch 1, do not auto-continue | **stub** (assertions drafted) |
| 5 | `eval-stale-in-progress-resume` | Detect orphan in_progress + orphan worktree, ask human before doing anything | **stub** (assertions drafted) |

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

## Stubs — what's needed to flesh them out

Each stub's `eval_metadata.json` documents what the fixture needs. Common shared infra to build:

1. **Controllable reviewer shim** — a wrapper around `infinifu:code-reviewer` that flips approval based on a counter file in the sandbox. Needed for `eval-rejection-retry`.
2. **Worktree orphan generator** — script that fakes a `.git/worktrees/stale-<id>` directory pointing at a dead branch. Needed for `eval-stale-in-progress-resume`.
3. **Multi-epic 4-task fixture** — extend the iteration-1 seeder. Needed for `eval-wave-mode-pause`.
4. **Insufficient-design task** — seed with `design = "TBD"`. Needed for `eval-blocked-escalation`.

## Telemetry note

iteration-1 benchmark.md showed `Config B: 0 ± 0 runs` because no baseline was actually run. `timing.json` in `with_skill/run-1/` did get captured (36955 tokens / 77.7s) so the per-run mechanism works — the bug was at the aggregation step (no baseline subagent ever spawned). When running iteration-2, dispatch **both** with-skill AND baseline subagents in the same turn per the skill-creator playbook so both branches have timing data.

## Original grade.py path bug

The workspace-level `grade.py` (one level up) hardcodes `/home/jan/repos/b3tchi/acag/main/...` — a stale absolute path. The new `eval-multi-epic-interference/grade.py` uses `find_sandbox()` to resolve relative to cwd. Apply the same pattern to a refreshed `eval-orient-and-halt/grade.py` before re-running iteration-1 fixtures here.
