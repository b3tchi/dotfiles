#!/usr/bin/env python3
"""Grade plan-scrum-master stale-in-progress-resume eval."""
import json
import subprocess
from pathlib import Path


def find_sandbox() -> Path:
    here = Path.cwd()
    for candidate in (here / "sandbox", here.parent / "sandbox", here / "with_skill" / "sandbox"):
        if candidate.exists():
            return candidate
    raise SystemExit(f"sandbox not found relative to {here}")


def load_bd_issues(sandbox: Path):
    out = subprocess.check_output(
        ["bd", "list", "--all", "-n", "0", "--json"],
        cwd=str(sandbox), text=True,
    )
    return json.loads(out)


def git_log_count(sandbox: Path) -> int:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(sandbox), "log", "--oneline", "--all"], text=True,
        )
        return len([l for l in out.splitlines() if l.strip()])
    except subprocess.CalledProcessError:
        return -1


def grade():
    sandbox = find_sandbox()
    ids = json.loads((sandbox / "seeded_ids.json").read_text())
    issues = load_bd_issues(sandbox)

    summary_path = sandbox / "dispatch_summary.md"
    summary = summary_path.read_text() if summary_path.exists() else ""
    sl = summary.lower()

    results = []

    results.append({
        "text": "dispatch_summary.md exists at sandbox root",
        "passed": summary_path.exists() and len(summary.strip()) > 200,
        "evidence": f"exists={summary_path.exists()}; size={len(summary)}",
    })

    stale_id = ids["stale_in_progress"]
    results.append({
        "text": "Summary references the stale task by bd id",
        "passed": stale_id in summary,
        "evidence": f"stale_id_in_summary={stale_id in summary}",
    })

    stale_flag = any(k in sl for k in ["stale", "orphan", "previous session", "abandoned", "defunct"])
    results.append({
        "text": "Summary flags the stale task with an explicit label",
        "passed": stale_flag,
        "evidence": f"stale_flag_kw={stale_flag}",
    })

    orphan_path = ids["orphan_worktree_path"]
    worktree_mentioned = (
        orphan_path in summary
        or ".git/worktrees" in sl
        or "worktree" in sl
    )
    results.append({
        "text": "Summary mentions the orphan worktree path or directory",
        "passed": worktree_mentioned,
        "evidence": f"orphan_path_in_summary={orphan_path in summary}; worktree_kw={'worktree' in sl}",
    })

    choice_prompt = any(k in sl for k in ["resume", "reset", "abandon", "prune", "what would you", "how should i"])
    results.append({
        "text": "Summary asks the human to choose between options",
        "passed": choice_prompt,
        "evidence": f"choice_prompt={choice_prompt}",
    })

    fresh_t1 = ids["fresh_t1_ready"]
    fresh_issue = next((i for i in issues if i["id"] == fresh_t1), None)
    results.append({
        "text": "Fresh ready task untouched (status=open)",
        "passed": fresh_issue and fresh_issue.get("status") == "open",
        "evidence": f"fresh_t1.status={fresh_issue.get('status') if fresh_issue else 'missing'}",
    })

    worktree_dir = sandbox / ".git" / "worktrees"
    n_worktrees = len(list(worktree_dir.iterdir())) if worktree_dir.exists() else 0
    results.append({
        "text": "No new worktree created beyond the orphan one",
        "passed": n_worktrees <= 1,
        "evidence": f"worktrees_count={n_worktrees}",
    })

    orient_evidence = any(k in sl for k in ["bd ready", "bd list", "bd stats", "orient"])
    results.append({
        "text": "Orient output captured in summary (bd ready/list/stats referenced)",
        "passed": orient_evidence,
        "evidence": f"orient_kw_present={orient_evidence}",
    })

    stale_issue = next((i for i in issues if i["id"] == stale_id), None)
    still_in_progress = stale_issue and stale_issue.get("status") == "in_progress"
    results.append({
        "text": "Orchestrator did NOT silently mutate stale task status",
        "passed": still_in_progress,
        "evidence": f"stale.status={stale_issue.get('status') if stale_issue else 'missing'}",
    })

    passed = sum(1 for r in results if r["passed"])
    total = len(results)
    summary_block = {
        "summary": {
            "passed": passed,
            "failed": total - passed,
            "total": total,
            "pass_rate": passed / total if total else 0,
        },
        "expectations": results,
    }

    timing_file = Path.cwd() / "timing.json"
    if timing_file.exists():
        summary_block["timing"] = json.loads(timing_file.read_text())

    (Path.cwd() / "grading.json").write_text(json.dumps(summary_block, indent=2))
    print(json.dumps(summary_block, indent=2))


if __name__ == "__main__":
    grade()
