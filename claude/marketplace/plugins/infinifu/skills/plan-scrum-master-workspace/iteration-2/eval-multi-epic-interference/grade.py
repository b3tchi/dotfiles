#!/usr/bin/env python3
"""Grade plan-scrum-master multi-epic-interference eval.

Run from inside `with_skill/` (the run directory). Reads ../sandbox/ for
the seeded fixture state and the dispatch_summary.md the orchestrator
should have written.
"""
import json
import re
import subprocess
import sys
from pathlib import Path


def _extract_first_batch_section(text: str) -> str:
    """See orient-and-halt/grade.py for the design rationale.

    Pulls the section starting from the LAST occurrence of 'first batch'
    until 'Proceed?'/'Confirm?'/'Abort?' or an H2 heading or end of text.
    Robust against markdown tables, earlier prose mentions, and tight
    lookaheads.
    """
    lines = text.splitlines()
    header_indices = [i for i, ln in enumerate(lines) if re.search(r"first\s+batch", ln, re.IGNORECASE)]
    if not header_indices:
        return ""
    start = header_indices[-1]
    end = len(lines)
    for j in range(start + 1, len(lines)):
        ln = lines[j].strip().lower()
        if ln.startswith("proceed?") or ln.startswith("confirm?") or ln.startswith("abort?"):
            end = j
            break
        if ln.startswith("## "):
            end = j
            break
    return "\n".join(lines[start:end])


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
            ["git", "-C", str(sandbox), "log", "--oneline"], text=True,
        )
        return len([l for l in out.splitlines() if l.strip()])
    except subprocess.CalledProcessError:
        return -1


def grade():
    sandbox = find_sandbox()
    ids = json.loads((sandbox / "seeded_ids.json").read_text())
    issues = load_bd_issues(sandbox)

    summary_path = sandbox / "dispatch_summary.md"
    text = summary_path.read_text() if summary_path.exists() else ""
    tl = text.lower()

    results = []

    results.append({
        "text": "dispatch_summary.md exists at sandbox root and is non-empty",
        "passed": summary_path.exists() and len(text.strip()) > 200,
        "evidence": f"exists={summary_path.exists()}; size={len(text)}",
    })

    epic_a = ids["epic_2fa"]
    epic_b = ids["epic_ratelimit"]
    both = epic_a in text and epic_b in text
    results.append({
        "text": "Summary references both seeded epic IDs",
        "passed": both,
        "evidence": f"epic_2fa={epic_a in text}; epic_ratelimit={epic_b in text}",
    })

    interference_kw = any(k in tl for k in ["interference", "interfer", "conflict", "overlap"])
    results.append({
        "text": "Summary includes an interference / conflict assessment",
        "passed": interference_kw,
        "evidence": f"interference_kw_in_summary={interference_kw}",
    })

    classified_conflicting = any(
        k in tl for k in ["conflict", "interfering", "shared file", "overlap", "must serialize"]
    )
    classified_non = any(
        k in tl for k in ["none — can parallel", "non-interfering", "no conflict"]
    )
    results.append({
        "text": "Summary classifies the epics as INTERFERING (shared file detected)",
        "passed": classified_conflicting and not classified_non,
        "evidence": f"conflicting={classified_conflicting}; non={classified_non}",
    })

    shared_file = ids["shared_file"]
    shared_mentioned = shared_file in text or "middleware" in tl
    results.append({
        "text": "Summary mentions the shared file path or directory",
        "passed": shared_mentioned,
        "evidence": f"shared_file_in_summary={shared_file in text}; middleware_keyword={'middleware' in tl}",
    })

    serial_kw = any(k in tl for k in ["serialize", "serial", "one at a time", "sequential"])
    results.append({
        "text": "Summary states epics will be serialized",
        "passed": serial_kw,
        "evidence": f"serialize_kw={serial_kw}",
    })

    # First batch must list exactly 1 task (serialized) even though max_parallel=2.
    batch_text = _extract_first_batch_section(text)
    task_ids_in_batch = re.findall(r"eval-\w+", batch_text)
    # filter to ready task ids
    ready_ids = {ids["a1_ready"], ids["b1_ready"]}
    in_batch = [t for t in task_ids_in_batch if t in ready_ids]
    results.append({
        "text": "First batch lists exactly 1 task (serialized despite max_parallel=2)",
        "passed": len(in_batch) == 1,
        "evidence": f"batch_ids={in_batch}; batch_region_len={len(batch_text)}",
    })

    has_config = all(k in tl for k in ["max_parallel", "waves", "auto"])
    results.append({
        "text": "Summary references required config",
        "passed": has_config,
        "evidence": f"has_required_config={has_config}",
    })

    proceed_gate = any(k in tl for k in ["proceed?", "confirm", "await", "your call"])
    results.append({
        "text": "Summary asks human for confirmation",
        "passed": proceed_gate,
        "evidence": f"proceed_gate={proceed_gate}",
    })

    in_progress_ids = [i["id"] for i in issues if i.get("status") == "in_progress"]
    results.append({
        "text": "No bd task was newly claimed (no in_progress)",
        "passed": len(in_progress_ids) == 0,
        "evidence": f"in_progress_ids={in_progress_ids}",
    })

    commit_count = git_log_count(sandbox)
    results.append({
        "text": "No new git commits beyond the seed commit",
        "passed": commit_count == 1,
        "evidence": f"commit_count={commit_count}",
    })

    worktrees = (sandbox / ".git" / "worktrees").exists()
    results.append({
        "text": "No git worktrees were created",
        "passed": not worktrees,
        "evidence": f"worktrees_dir_exists={worktrees}",
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

    # Read timing if exists
    timing_file = Path.cwd() / "timing.json"
    if timing_file.exists():
        summary_block["timing"] = json.loads(timing_file.read_text())

    out = Path.cwd() / "grading.json"
    out.write_text(json.dumps(summary_block, indent=2))
    print(json.dumps(summary_block, indent=2))


if __name__ == "__main__":
    grade()
