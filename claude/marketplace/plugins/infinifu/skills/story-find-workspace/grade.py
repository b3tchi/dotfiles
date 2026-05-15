#!/usr/bin/env python3
"""Grade story-find eval outputs against assertions."""
from __future__ import annotations

import json
import sys
from pathlib import Path

WORKSPACE = Path(__file__).parent


def grade_export(outputs: Path) -> list[dict]:
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    return [
        {"text": "Output identifies story 2605-001 (CSV export) as a match", "passed": "2605-001" in resp, "evidence": ""},
        {"text": "Output identifies story 2605-004 (PDF export) as a match", "passed": "2605-004" in resp, "evidence": ""},
        {"text": "Output does NOT include story 2605-002 (password reset)", "passed": "2605-002" not in resp, "evidence": ""},
        {"text": "Output does NOT include story 2605-005 (2FA)", "passed": "2605-005" not in resp, "evidence": ""},
        {"text": "Each matched story renders acceptance criteria as a checklist", "passed": "[x]" in resp or "[ ]" in resp, "evidence": ""},
        {"text": "2605-001 (status=done) shows checkboxes as [x] for all criteria", "passed": resp.count("[x]") >= 3, "evidence": f"[x] count={resp.count('[x]')}"},
        {"text": "2605-004 (status=draft) shows checkboxes as [ ] for all criteria", "passed": resp.count("[ ]") >= 3, "evidence": f"[ ] count={resp.count('[ ]')}"},
        {"text": "Output includes a coverage summary line at the end", "passed": "coverage" in resp.lower() or "matched stories" in resp.lower(), "evidence": ""},
    ]


def grade_auth(outputs: Path) -> list[dict]:
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    return [
        {"text": "Output identifies story 2605-005 (two-factor auth) as a match", "passed": "2605-005" in resp, "evidence": ""},
        {"text": "Output identifies story 2605-002 (password reset) as a match", "passed": "2605-002" in resp, "evidence": ""},
        {"text": "Output does NOT include story 2605-003 (archive reports)", "passed": "2605-003" not in resp, "evidence": ""},
        {"text": "Each matched story shows status field", "passed": resp.lower().count("status:") >= 2 or resp.lower().count("**status:**") >= 2, "evidence": ""},
        {"text": "Each matched story renders acceptance criteria as checklist with [ ] or [x]", "passed": ("[ ]" in resp or "[x]" in resp), "evidence": ""},
        {"text": "For each story, output indicates whether it is validated/done or unverified", "passed": "unverified" in resp.lower() or "validated" in resp.lower(), "evidence": ""},
        {"text": "Output ends with a coverage summary", "passed": "coverage" in resp.lower() or "matched stories" in resp.lower(), "evidence": ""},
    ]


GRADERS = {"eval-find-export-stories": grade_export, "eval-validate-auth-coverage": grade_auth}


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
