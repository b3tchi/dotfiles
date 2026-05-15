#!/usr/bin/env python3
"""Grade the spec-refinement stress-all-categories eval.

Reads bd state via `bd list --all -n 0 --json` from inside the sandbox,
plus review_summary.md + seeded_ids.json. Writes grading.json in a format
aggregate_benchmark.py expects.
"""
import json
import re
import shutil
import subprocess
from pathlib import Path

WORKSPACE = Path("/home/jan/repos/b3tchi/acag/main/infinifu/skills/spec-refinement-workspace/iteration-1")
EVAL_DIR = WORKSPACE / "eval-stress-all"
SANDBOX = EVAL_DIR / "with_skill" / "sandbox"

PLACEHOLDER_PATTERNS = [
    r"\[detailed above\]",
    r"\[as specified\]",
    r"\[will be added\]",
    r"\[complete .* above\]",
]

EDGE_CASE_TERMS = [
    "unicode", "empty", "concurrent", "concurrency",
    "malformed", "edge case", "backtrack",
]

TAUTOLOGICAL_TEST_PATTERNS = [
    r"test_scan_result_has_scanner_id_field",
    r"test_scan_result_has_match_count_field",
    r"test_scan_result_derives_debug",
]


def load_bd_issues(sandbox: Path):
    out = subprocess.check_output(
        ["bd", "list", "--all", "-n", "0", "--json"],
        cwd=str(sandbox),
        text=True,
    )
    return json.loads(out)


def children_of(parent_id, issues):
    kids = []
    for i in issues:
        deps = i.get("dependencies") or []
        for d in deps:
            if d.get("type") == "parent-child" and d.get("depends_on_id") == parent_id:
                kids.append(i)
                break
    return kids


def has_concrete_criterion(design: str) -> bool:
    """Heuristic: a rewritten success criterion contains a command, a number
    with unit, or a named test function."""
    # Presence of shell/tool command
    if re.search(r"`[a-z][\w\- ]*(?:\s+[\w\-/.=]+)+`", design):
        return True
    # A named test identifier like test_something_specific
    if re.search(r"\btest_[a-z][a-z0-9_]{8,}\b", design):
        return True
    # A numeric target, e.g. "95% coverage", "100ms", "5+ tests"
    if re.search(r"\b\d+\s?(ms|s|%|tests?|warnings?|iterations?)\b", design, re.I):
        return True
    # A cargo/clippy/rg/bd command somewhere
    if re.search(r"\b(cargo|clippy|rg|bd|grep|rustfmt)\s+", design):
        return True
    return False


def grade():
    ids_path = SANDBOX / "seeded_ids.json"
    ids = json.loads(ids_path.read_text())
    issues = load_bd_issues(SANDBOX)
    by_id = {i["id"]: i for i in issues}

    epic_id = ids["epic"]
    task_a = by_id.get(ids["task_a_placeholder"], {})
    task_b = by_id.get(ids["task_b_oversized"], {})
    task_c = by_id.get(ids["task_c_no_edges"], {})
    task_d = by_id.get(ids["task_d_tautological"], {})

    rs = SANDBOX / "review_summary.md"
    rs_text = rs.read_text() if rs.exists() else ""
    rs_lower = rs_text.lower()

    results = []

    # 1. review_summary.md exists with content for all 4 tasks
    seeded_ids_in_summary = sum(
        1 for tid in [ids["task_a_placeholder"], ids["task_b_oversized"],
                      ids["task_c_no_edges"], ids["task_d_tautological"]]
        if tid in rs_text
    )
    results.append({
        "text": "review_summary.md exists at sandbox root and references all 4 seeded task IDs",
        "passed": rs.exists() and seeded_ids_in_summary == 4,
        "evidence": f"exists={rs.exists()}; seeded_ids_referenced={seeded_ids_in_summary}/4; size={len(rs_text)} chars",
    })

    # 2. Task A placeholder removed
    a_design = task_a.get("design", "") or ""
    placeholder_hits = [p for p in PLACEHOLDER_PATTERNS if re.search(p, a_design, re.I)]
    results.append({
        "text": "Task A: placeholder text ([detailed above], [as specified], [will be added]) removed",
        "passed": len(placeholder_hits) == 0 and len(a_design) > 0,
        "evidence": f"design_len={len(a_design)}; placeholder_hits={placeholder_hits}",
    })

    # 3. Task A has concrete criteria
    results.append({
        "text": "Task A: at least one concrete / verifiable success criterion present",
        "passed": has_concrete_criterion(a_design),
        "evidence": f"concrete_criterion_heuristic={'pass' if has_concrete_criterion(a_design) else 'fail'}; design_excerpt={a_design[:200]!r}",
    })

    # 4. Task B has >=3 children
    b_kids = children_of(ids["task_b_oversized"], issues)
    results.append({
        "text": "Task B (40h oversized): broken down into >=3 child subtasks",
        "passed": len(b_kids) >= 3,
        "evidence": f"children={len(b_kids)}: {[k['id'] for k in b_kids]}",
    })

    # 5. Task B design rewritten to coordinator
    b_design = task_b.get("design", "") or ""
    coord_terms = ["coordinator", "coordinate", "parent", "subtask", "child", "children"]
    coord_hits = [t for t in coord_terms if t in b_design.lower()]
    results.append({
        "text": "Task B: parent design updated to coordinator-style summary",
        "passed": len(coord_hits) > 0,
        "evidence": f"coordinator_terms_found={coord_hits}",
    })

    # 6. Task C now mentions edge cases
    c_design = task_c.get("design", "") or ""
    c_hits = [t for t in EDGE_CASE_TERMS if t in c_design.lower()]
    results.append({
        "text": "Task C: design now mentions >=2 edge-case terms {unicode, empty, concurrent, malformed, edge case, backtrack}",
        "passed": len(c_hits) >= 2,
        "evidence": f"edge_terms_found={c_hits}",
    })

    # 7. Task D either rewritten or flagged REJECT in summary
    d_design = task_d.get("design", "") or ""
    still_tautological = any(re.search(p, d_design) for p in TAUTOLOGICAL_TEST_PATTERNS)
    task_d_id = ids["task_d_tautological"]
    # Look for REJECT verdict near task D id in review summary
    idx = rs_text.find(task_d_id)
    d_section = rs_text[idx: idx + 600] if idx != -1 else ""
    d_rejected = "REJECT" in d_section.upper() or "NEEDS REVISION" in d_section.upper()
    results.append({
        "text": "Task D (tautological tests): design rewritten with real tests, OR flagged REJECT/REVISION in review_summary",
        "passed": (not still_tautological) or d_rejected,
        "evidence": f"still_tautological={still_tautological}; review_verdict_in_section={d_rejected}; section_excerpt={d_section[:150]!r}",
    })

    # 8. No task was closed or in_progress
    seeded_children = [by_id.get(ids[k]) for k in ("task_a_placeholder", "task_b_oversized", "task_c_no_edges", "task_d_tautological")]
    active = [t for t in seeded_children if t and t.get("status") in ("in_progress", "closed")]
    results.append({
        "text": "No seeded task was marked in_progress or closed",
        "passed": len(active) == 0,
        "evidence": f"active_seeded={[(t['id'], t.get('status')) for t in active]}",
    })

    # 9. Epic still has >=4 direct children
    epic_kids = children_of(epic_id, issues)
    results.append({
        "text": "Epic still has >=4 direct children (original 4 tasks, subtasks allowed deeper)",
        "passed": len(epic_kids) >= 4,
        "evidence": f"epic_children={len(epic_kids)}: {[k['id'] for k in epic_kids]}",
    })

    return results


def write_grading(run_base: Path, results, timing_data):
    run1 = run_base / "run-1"
    run1.mkdir(exist_ok=True)
    passed = sum(1 for r in results if r["passed"])
    total = len(results)
    pass_rate = passed / total if total else 0.0
    grading = {
        "summary": {
            "passed": passed,
            "failed": total - passed,
            "total": total,
            "pass_rate": round(pass_rate, 4),
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
    print(f"eval-stress-all/with_skill: {passed}/{total} passed")
    for r in results:
        mark = "✅" if r["passed"] else "❌"
        print(f"  {mark} {r['text']}")
        print(f"     {r['evidence']}")


if __name__ == "__main__":
    main()
