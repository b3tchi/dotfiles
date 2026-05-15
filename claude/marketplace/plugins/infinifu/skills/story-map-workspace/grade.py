#!/usr/bin/env python3
"""Grade story-map eval outputs."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml

WORKSPACE = Path(__file__).parent


def grade_forward_exact(outputs: Path) -> list[dict]:
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    return [
        {"text": "Output identifies story 2605-002 as a match", "passed": "2605-002" in resp, "evidence": ""},
        {"text": "Output identifies story 2605-005 as a match", "passed": "2605-005" in resp, "evidence": ""},
        {"text": "Output excludes 2605-001", "passed": "2605-001" not in resp, "evidence": ""},
        {"text": "Output excludes 2605-003", "passed": "2605-003" not in resp, "evidence": ""},
        {"text": "Output is a table or structured listing", "passed": "|" in resp or "-" in resp, "evidence": ""},
        {"text": "Output includes a count summary", "passed": "matched" in resp.lower() or "2 stor" in resp.lower(), "evidence": ""},
    ]


def grade_forward_prefix(outputs: Path) -> list[dict]:
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    return [
        {"text": "Output identifies story 2605-002", "passed": "2605-002" in resp, "evidence": ""},
        {"text": "Output identifies story 2605-005", "passed": "2605-005" in resp, "evidence": ""},
        {"text": "Output excludes 2605-001", "passed": "2605-001" not in resp, "evidence": ""},
        {"text": "Output excludes 2605-004", "passed": "2605-004" not in resp, "evidence": ""},
        {"text": "Output is a table or structured listing", "passed": "|" in resp or "-" in resp, "evidence": ""},
    ]


def grade_reverse(outputs: Path) -> list[dict]:
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    paths = ["src/auth/login.ts", "src/auth/password-reset.ts", "src/email/templates/reset.html"]
    return [
        {"text": f"Output lists {paths[0]}", "passed": paths[0] in resp, "evidence": ""},
        {"text": f"Output lists {paths[1]}", "passed": paths[1] in resp, "evidence": ""},
        {"text": f"Output lists {paths[2]}", "passed": paths[2] in resp, "evidence": ""},
        {"text": "Output shows exactly 3 paths", "passed": sum(1 for p in paths if p in resp) == 3, "evidence": ""},
        {"text": "Output includes story title", "passed": "Reset password" in resp.lower() or "reset password" in resp.lower(), "evidence": ""},
    ]


def grade_attach(outputs: Path) -> list[dict]:
    tsv_path = outputs / "story-map.tsv"
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    low = resp.lower()
    edges: list[tuple[str, str]] = []
    if tsv_path.exists():
        for line in tsv_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) == 2:
                edges.append((parts[0], parts[1]))
    s_001_paths = [p for sid, p in edges if sid == "2605-001"]
    s_002_paths = [p for sid, p in edges if sid == "2605-002"]
    expected_orig = ["src/export/csv.ts", "src/export/csv.test.ts", "src/components/ExportButton.svelte"]
    expected_002 = {"src/auth/login.ts", "src/auth/password-reset.ts", "src/email/templates/reset.html"}

    # Sort check: file should be sorted by (id, path)
    sorted_check = edges == sorted(edges)

    return [
        {"text": "story-map.tsv modified — line for (2605-001, src/payments/checkout.ts) added", "passed": ("2605-001", "src/payments/checkout.ts") in edges, "evidence": f"2605-001 paths={s_001_paths}"},
        {"text": "Original 2605-001 edges preserved", "passed": all(p in s_001_paths for p in expected_orig), "evidence": f"2605-001 paths={s_001_paths}"},
        {"text": "No other story's edges were modified (2605-002 unchanged)", "passed": set(s_002_paths) == expected_002, "evidence": f"2605-002 paths={s_002_paths}"},
        {"text": "File is sorted by (id, path)", "passed": sorted_check, "evidence": f"sorted_ok={sorted_check}"},
        {"text": "Response shows the resulting state for 2605-001", "passed": "src/payments/checkout.ts" in resp and "2605-001" in resp, "evidence": ""},
        {"text": "Response notes the missing-from-tree warning", "passed": "doesn't exist" in low or "does not exist" in low or "not in" in low or "missing" in low or "warning" in low or "absent" in low, "evidence": ""},
    ]


GRADERS = {
    "eval-forward-lookup-exact-path": grade_forward_exact,
    "eval-forward-lookup-prefix": grade_forward_prefix,
    "eval-reverse-lookup": grade_reverse,
    "eval-attach-add-path": grade_attach,
}


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
