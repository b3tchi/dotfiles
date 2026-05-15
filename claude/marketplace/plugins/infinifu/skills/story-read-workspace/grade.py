#!/usr/bin/env python3
"""Grade story-read eval outputs against assertions."""
from __future__ import annotations

import json
import sys
from pathlib import Path

WORKSPACE = Path(__file__).parent


def grade_detail(outputs: Path) -> list[dict]:
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    low = resp.lower()
    return [
        {"text": "Output contains the id 2605-001", "passed": "2605-001" in resp, "evidence": ""},
        {"text": "Output renders the Connextra one-liner", "passed": ("as a" in low and "i want" in low and "so that" in low), "evidence": ""},
        {"text": "Output lists all acceptance criteria for that story (3 bullets)", "passed": (resp.count("CSV download includes") + resp.count("Empty result set") + resp.count("Download triggers")) == 3, "evidence": ""},
        {"text": "Output shows status field", "passed": "status" in low and "done" in low, "evidence": ""},
        {"text": "Output is in detail mode (single story), not table or render mode", "passed": "|---" not in resp and "## Draft" not in resp and "## Ready" not in resp and "## Done" not in resp, "evidence": ""},
        {"text": "Output does not include unrelated stories", "passed": "2605-002" not in resp and "2605-003" not in resp and "2605-004" not in resp and "2605-005" not in resp, "evidence": ""},
    ]


def grade_filter(outputs: Path) -> list[dict]:
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    has_table = "|---" in resp or "| --" in resp or "|-" in resp
    return [
        {"text": "Output is a markdown table or table-like structured listing", "passed": has_table, "evidence": ""},
        {"text": "Table includes only stories whose status is 'draft' (3 stories in fixture)", "passed": all(sid in resp for sid in ["2605-003", "2605-004", "2605-005"]), "evidence": ""},
        {"text": "Table excludes stories with status 'ready' or 'done'", "passed": "2605-001" not in resp and "2605-002" not in resp, "evidence": ""},
        {"text": "Table includes columns: id, status, role, title (or equivalent)", "passed": all(col in resp.lower() for col in ["id", "status", "role", "title"]), "evidence": ""},
        {"text": "Output includes a count summary line at the end (e.g. '3 stories matched')", "passed": "matched" in resp.lower() or "total" in resp.lower() or "3 " in resp, "evidence": ""},
    ]


GRADERS = {"eval-detail-by-id": grade_detail, "eval-filter-by-status": grade_filter}


def main():
    iteration = sys.argv[1] if len(sys.argv) > 1 else "iteration-1"
    iteration_dir = WORKSPACE / iteration
    summary = []
    for eval_dir in sorted(iteration_dir.iterdir()):
        if not eval_dir.is_dir() or not eval_dir.name.startswith("eval-"):
            continue
        grader = GRADERS.get(eval_dir.name)
        if not grader:
            continue
        outputs = eval_dir / "with_skill" / "outputs"
        results = grader(outputs)
        passed = sum(1 for r in results if r["passed"])
        total = len(results)
        out = eval_dir / "with_skill" / "grading.json"
        out.write_text(json.dumps({"eval_name": eval_dir.name, "expectations": results, "summary": f"{passed}/{total} passed"}, indent=2))
        summary.append((eval_dir.name, passed, total))
        print(f"{eval_dir.name}: {passed}/{total}")
    print("--- SUMMARY ---")
    for n, p, t in summary:
        print(f"  {n}: {p}/{t}")


if __name__ == "__main__":
    main()
