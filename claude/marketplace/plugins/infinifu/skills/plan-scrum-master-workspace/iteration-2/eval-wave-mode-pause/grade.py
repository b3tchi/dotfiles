#!/usr/bin/env python3
"""Grade plan-scrum-master wave-mode-pause eval."""
import json
import re
import subprocess
from pathlib import Path


def find_sandbox() -> Path:
    here = Path.cwd()
    for candidate in (here / "sandbox", here.parent / "sandbox", here / "with_skill" / "sandbox"):
        if candidate.exists():
            return candidate
    raise SystemExit(f"sandbox not found relative to {here}")


def find_chronicle() -> Path:
    here = Path.cwd()
    for candidate in (
        here / "chronicle.md",
        here / "outputs" / "chronicle.md",
        here.parent / "chronicle.md",
        here.parent / "outputs" / "chronicle.md",
    ):
        if candidate.exists():
            return candidate
    return Path("/dev/null")


def load_bd_issues(sandbox: Path):
    out = subprocess.check_output(
        ["bd", "list", "--all", "-n", "0", "--json"],
        cwd=str(sandbox), text=True,
    )
    return json.loads(out)


def grade():
    sandbox = find_sandbox()
    ids = json.loads((sandbox / "seeded_ids.json").read_text())
    issues = load_bd_issues(sandbox)

    chronicle_path = find_chronicle()
    chronicle = chronicle_path.read_text() if chronicle_path.exists() else ""
    cl = chronicle.lower()

    results = []

    results.append({
        "text": "chronicle.md exists",
        "passed": chronicle_path.exists() and len(chronicle.strip()) > 100,
        "evidence": f"exists={chronicle_path.exists()}; size={len(chronicle)}",
    })

    ready_ids = {ids["a1_ready"], ids["a2_ready"], ids["b1_ready"], ids["b2_ready"]}
    closed = [i["id"] for i in issues if i.get("status") == "closed" and i["id"] in ready_ids]
    in_progress = [i["id"] for i in issues if i.get("status") == "in_progress" and i["id"] in ready_ids]
    untouched = [i["id"] for i in issues if i.get("status") == "open" and i["id"] in ready_ids]

    results.append({
        "text": "Exactly 2 tasks dispatched in first batch",
        "passed": len(closed) + len(in_progress) == 2,
        "evidence": f"closed={len(closed)}; in_progress={len(in_progress)}",
    })

    results.append({
        "text": "Both batch tasks reached 'closed' (reviewer approved)",
        "passed": len(closed) == 2,
        "evidence": f"closed_ids={closed}",
    })

    progress_report = re.search(r"\b(2\s*/\s*4|2 of 4|pipeline.*2.*done)\b", cl)
    results.append({
        "text": "Orchestrator emitted progress report after batch 1",
        "passed": bool(progress_report),
        "evidence": f"progress_report_kw={bool(progress_report)}",
    })

    feedback_prompt = any(k in cl for k in ["ready for feedback", "awaiting your", "waiting for human", "approve next batch", "feedback?", "your call"])
    results.append({
        "text": "Orchestrator said 'Ready for feedback' or equivalent",
        "passed": feedback_prompt,
        "evidence": f"feedback_prompt={feedback_prompt}",
    })

    results.append({
        "text": "Remaining 2 ready tasks untouched (still open)",
        "passed": len(untouched) == 2,
        "evidence": f"untouched={untouched}",
    })

    # Waiting state: chronicle should END in a feedback-prompt-like line, not a new dispatch
    tail = chronicle.strip().split("\n")[-5:] if chronicle.strip() else []
    tail_text = "\n".join(tail).lower()
    tail_indicates_wait = any(k in tail_text for k in ["feedback", "awaiting", "wait", "your call", "proceed?"])
    tail_indicates_new_dispatch = any(k in tail_text for k in ["dispatching bd-", "starting bd-", "batch 2"])
    results.append({
        "text": "Run ended in waiting state (no batch-2 dispatch)",
        "passed": tail_indicates_wait and not tail_indicates_new_dispatch,
        "evidence": f"tail_wait={tail_indicates_wait}; tail_new_dispatch={tail_indicates_new_dispatch}",
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
