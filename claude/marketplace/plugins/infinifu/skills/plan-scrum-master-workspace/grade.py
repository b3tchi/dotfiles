#!/usr/bin/env python3
"""Grade plan-scrum-master orient-and-halt-at-gate eval."""
import json
import re
import shutil
import subprocess
from pathlib import Path

WORKSPACE = Path("/home/jan/repos/b3tchi/acag/main/infinifu/skills/plan-scrum-master-workspace/iteration-1")
EVAL_DIR = WORKSPACE / "eval-orient-and-halt"
SANDBOX = EVAL_DIR / "with_skill" / "sandbox"


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
    results = []
    ids = json.loads((SANDBOX / "seeded_ids.json").read_text())
    issues = load_bd_issues(SANDBOX)

    summary = SANDBOX / "dispatch_summary.md"
    text = summary.read_text() if summary.exists() else ""
    tl = text.lower()

    results.append({
        "text": "dispatch_summary.md exists at sandbox root and is non-empty",
        "passed": summary.exists() and len(text.strip()) > 200,
        "evidence": f"exists={summary.exists()}; size={len(text)}",
    })

    epic_a = ids["epic_auth"]; epic_b = ids["epic_billing"]
    both_epics = epic_a in text and epic_b in text
    results.append({
        "text": "Summary references both seeded epic IDs",
        "passed": both_epics,
        "evidence": f"epic_auth_in_summary={epic_a in text}; epic_billing_in_summary={epic_b in text}",
    })

    interference_kw = any(k in tl for k in ["interference", "interfer", "conflict"])
    results.append({
        "text": "Summary includes an interference / conflict assessment",
        "passed": interference_kw,
        "evidence": f"interference_kw_in_summary={interference_kw}",
    })

    # Look for NONE / non-interfering verdict near the two epic IDs
    non_interfering = bool(re.search(
        r"(none|non-?interfer|can\s+parallel|no\s+conflict|no\s+overlap|parallelizable)",
        tl,
    ))
    results.append({
        "text": "Summary classifies the epics as non-interfering",
        "passed": non_interfering,
        "evidence": f"non_interfering_verdict_found={non_interfering}",
    })

    stale_id = ids["stale_in_progress"]
    stale_flagged = stale_id in text and any(
        k in tl for k in ["stale", "previous session", "prior session", "in_progress from", "escalate", "reset", "resume"]
    )
    results.append({
        "text": "Summary flags the stale in_progress task from a prior session",
        "passed": stale_flagged,
        "evidence": f"stale_id_in_summary={stale_id in text}; flagged_language={stale_flagged}",
    })

    # Look for the "First batch:" section, count arrow-style entries or task IDs inside it
    # Accept either "First batch" heading with 2 bd-style IDs listed
    m = re.search(
        r"first\s*batch[^\n]*\n(.+?)(?:\n\s*━|\n\s*={3,}|\n\s*---|\n\s*##\s|\n\s*⚠|\n\s*escalat|\n\s*proceed\?|\n\s*confirm|\n\s*reviewer model|\Z)",
        text, re.I | re.S,
    )
    batch_text = m.group(1) if m else ""
    # Count task IDs in batch region
    ready_task_ids = [ids["a1_ready"], ids["b1_ready"]]
    in_batch = sum(1 for tid in ready_task_ids if tid in batch_text)
    # Also count how many eval-* bd IDs appear in batch, excluding epic IDs
    all_ids_in_batch = set(re.findall(r"eval-[a-z0-9]+", batch_text))
    epic_ids = {ids["epic_auth"], ids["epic_billing"]}
    task_ids_in_batch = all_ids_in_batch - epic_ids
    results.append({
        "text": "First batch lists exactly 2 tasks (max_parallel=2)",
        "passed": len(task_ids_in_batch) == 2,
        "evidence": f"task_ids_in_batch={sorted(task_ids_in_batch)}; batch_region_len={len(batch_text)}",
    })
    results.append({
        "text": "First batch contains one task from each epic (a1_ready + b1_ready)",
        "passed": in_batch == 2,
        "evidence": f"a1_in_batch={ids['a1_ready'] in batch_text}; b1_in_batch={ids['b1_ready'] in batch_text}",
    })

    has_config = (
        re.search(r"max_parallel\s*[:=]\s*2", tl) is not None
        and re.search(r"mode\s*[:=]\s*waves", tl) is not None
        and re.search(r"worker_model\s*[:=]\s*auto", tl) is not None
    )
    results.append({
        "text": "Summary references required config (max_parallel=2, mode=waves, worker_model=auto)",
        "passed": has_config,
        "evidence": f"has_required_config={has_config}",
    })

    # Look for model selection in the batch section: sonnet/opus/haiku with rationale
    model_mentions = sum(
        1 for tok in ["sonnet", "opus", "haiku"]
        if re.search(rf"\b{tok}\b", tl)
    )
    # Need at least one model choice AND justifying language
    reasoning_words = any(k in tl for k in ["reason", "rationale", "because", "single-domain", "cross-domain", "medium", "high", "low", "complexity"])
    results.append({
        "text": "Per-task worker_model is specified with reasoning (auto mode)",
        "passed": model_mentions >= 1 and reasoning_words,
        "evidence": f"model_mentions={model_mentions}; has_reasoning={reasoning_words}",
    })

    proceed_gate = any(
        k in tl for k in ["proceed?", "proceed (", "confirm?", "(yes / adjust", "yes / adjust / abort", "await your", "awaiting", "waiting for"]
    )
    results.append({
        "text": "Summary asks human for confirmation (Proceed?/confirm/await)",
        "passed": proceed_gate,
        "evidence": f"proceed_gate={proceed_gate}",
    })

    in_progress = [i for i in issues if i.get("status") == "in_progress"]
    only_stale = (len(in_progress) == 1 and in_progress[0]["id"] == stale_id)
    results.append({
        "text": "No bd task was newly claimed — in_progress count still 1 (the stale task)",
        "passed": only_stale,
        "evidence": f"in_progress_ids={[i['id'] for i in in_progress]}",
    })

    # seed has 1 commit; agent should not add any
    commits = git_log_count(SANDBOX)
    results.append({
        "text": "No new git commits beyond the seed (seed had 1, still 1)",
        "passed": commits == 1,
        "evidence": f"commit_count={commits}",
    })

    wt_dir = SANDBOX / ".git" / "worktrees"
    results.append({
        "text": "No git worktrees were created",
        "passed": not wt_dir.exists(),
        "evidence": f"worktrees_dir_exists={wt_dir.exists()}",
    })

    return results


def write_grading(run_base: Path, results, timing_data):
    run1 = run_base / "run-1"
    run1.mkdir(exist_ok=True)
    passed = sum(1 for r in results if r["passed"])
    total = len(results)
    grading = {
        "summary": {
            "passed": passed,
            "failed": total - passed,
            "total": total,
            "pass_rate": round(passed / total, 4) if total else 0.0,
        },
        "expectations": results,
        "timing": timing_data,
    }
    (run1 / "grading.json").write_text(json.dumps(grading, indent=2))
    if timing_data:
        (run1 / "timing.json").write_text(json.dumps(timing_data, indent=2))
    out_src = run_base / "outputs"
    out_dst = run1 / "outputs"
    if out_src.exists() and not out_dst.exists():
        shutil.copytree(out_src, out_dst)
    return passed, total


def main():
    run_base = EVAL_DIR / "with_skill"
    timing_path = run_base / "timing.json"
    timing = json.loads(timing_path.read_text()) if timing_path.exists() else {}
    results = grade()
    passed, total = write_grading(run_base, results, timing)
    print(f"eval-orient-and-halt/with_skill: {passed}/{total} passed")
    for r in results:
        mark = "✅" if r["passed"] else "❌"
        print(f"  {mark} {r['text']}")
        print(f"     {r['evidence']}")


if __name__ == "__main__":
    main()
