#!/usr/bin/env python3
"""Grade plan-scrum-master orient-and-halt-at-gate eval.

Ported from the iteration-1 grader to use find_sandbox() instead of a
hardcoded absolute path, so it runs from any workspace clone.
"""
import json
import re
import subprocess
from pathlib import Path


def _extract_first_batch_section(text: str) -> str:
    """Pull out the 'first batch' section from a dispatch summary.

    Robust against three failure modes the original regex hit:
      1. Markdown tables (pipe chars) confusing the lookahead
      2. Earlier prose mentions of 'first batch' landing first (we want the
         LAST occurrence — the actual batch listing usually appears near the
         bottom, right before 'Proceed?')
      3. Non-greedy match collapsing to empty against a tight lookahead.

    Strategy: split text into lines, find every line that contains 'first
    batch' (case-insensitive), pick the LAST one as the section header, then
    collect that line plus subsequent lines until we hit either:
      - a 'Proceed?' / 'Confirm?' / 'Abort?' prompt
      - a blank line followed by an H2 ('## ') heading
      - end of text
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

    epic_a, epic_b = ids["epic_auth"], ids["epic_billing"]
    both_epics = epic_a in text and epic_b in text
    results.append({
        "text": "Summary references both seeded epic IDs",
        "passed": both_epics,
        "evidence": f"epic_auth={epic_a in text}; epic_billing={epic_b in text}",
    })

    interference_kw = any(k in tl for k in ["interference", "interfer", "conflict"])
    results.append({
        "text": "Summary includes an interference / conflict assessment",
        "passed": interference_kw,
        "evidence": f"interference_kw={interference_kw}",
    })

    non_interfering = any(k in tl for k in ["none — can parallel", "non-interfering", "no conflict", "no overlap"])
    results.append({
        "text": "Summary classifies the epics as non-interfering",
        "passed": non_interfering,
        "evidence": f"non_interfering_verdict={non_interfering}",
    })

    stale_id = ids["stale_in_progress"]
    stale_in_summary = stale_id in text
    flagged_lang = any(k in tl for k in ["stale", "previous session", "orphan", "abandoned"])
    results.append({
        "text": "Summary flags the stale in_progress task",
        "passed": stale_in_summary and flagged_lang,
        "evidence": f"stale_id_in_summary={stale_in_summary}; flagged_language={flagged_lang}",
    })

    batch_text = _extract_first_batch_section(text)
    ready_ids = {ids["a1_ready"], ids["b1_ready"]}
    task_ids_in_batch = [t for t in re.findall(r"eval-\w+", batch_text) if t in ready_ids]
    results.append({
        "text": "First batch lists exactly 2 tasks (max_parallel=2)",
        "passed": len(task_ids_in_batch) == 2,
        "evidence": f"task_ids_in_batch={task_ids_in_batch}; batch_region_len={len(batch_text)}",
    })

    a1_in_batch = ids["a1_ready"] in batch_text
    b1_in_batch = ids["b1_ready"] in batch_text
    results.append({
        "text": "First batch contains one task from each epic",
        "passed": a1_in_batch and b1_in_batch,
        "evidence": f"a1_in_batch={a1_in_batch}; b1_in_batch={b1_in_batch}",
    })

    has_required_config = all(k in tl for k in ["max_parallel", "waves", "auto"])
    results.append({
        "text": "Summary references required config (max_parallel=2, mode=waves, worker_model=auto)",
        "passed": has_required_config,
        "evidence": f"has_required_config={has_required_config}",
    })

    model_mentions = len(re.findall(r"\bmodel\s*[:=]\s*(opus|sonnet|haiku)", tl))
    has_reasoning = any(k in tl for k in ["because", "reasoning", "complexity", "low complexity", "medium complexity", "high complexity"])
    results.append({
        "text": "Per-task worker_model with reasoning (auto mode)",
        "passed": model_mentions >= 1 and has_reasoning,
        "evidence": f"model_mentions={model_mentions}; has_reasoning={has_reasoning}",
    })

    proceed_gate = any(k in tl for k in ["proceed?", "confirm", "await", "your call"])
    results.append({
        "text": "Summary asks human for confirmation",
        "passed": proceed_gate,
        "evidence": f"proceed_gate={proceed_gate}",
    })

    in_progress_ids = [i["id"] for i in issues if i.get("status") == "in_progress"]
    results.append({
        "text": "No bd task newly claimed — in_progress count still 1 (the stale task)",
        "passed": in_progress_ids == [stale_id],
        "evidence": f"in_progress_ids={in_progress_ids}",
    })

    commit_count = git_log_count(sandbox)
    results.append({
        "text": "No new git commits beyond the seed",
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

    timing_file = Path.cwd() / "timing.json"
    if timing_file.exists():
        summary_block["timing"] = json.loads(timing_file.read_text())

    (Path.cwd() / "grading.json").write_text(json.dumps(summary_block, indent=2))
    print(json.dumps(summary_block, indent=2))


if __name__ == "__main__":
    grade()
