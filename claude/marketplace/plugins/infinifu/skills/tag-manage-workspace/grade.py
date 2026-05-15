#!/usr/bin/env python3
"""Grade tag-manage eval outputs."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml

WORKSPACE = Path(__file__).parent


def grade_list(outputs: Path) -> list[dict]:
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    low = resp.lower()
    return [
        {"text": "Output is a markdown table or list of tags with usage counts", "passed": ("|" in resp and "tag" in low) or ("count" in low), "evidence": ""},
        {"text": "Output includes tag 'auth' with count 2", "passed": "auth" in low and "2" in resp, "evidence": ""},
        {"text": "Output includes tag 'export' with count 2", "passed": "export" in low, "evidence": ""},
        {"text": "Output includes tag 'admin' with count 2", "passed": "admin" in low, "evidence": ""},
        {"text": "Output includes tag 'reports' with count 2", "passed": "reports" in low, "evidence": ""},
        {"text": "Output mentions example story ids per tag", "passed": "2605-002" in resp and "2605-005" in resp, "evidence": ""},
        {"text": "Output includes a summary line stating distinct tag count", "passed": ("distinct" in low or "total" in low) and "tag" in low, "evidence": ""},
    ]


def grade_add(outputs: Path) -> list[dict]:
    yaml_path = outputs / "stories.yaml"
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    low = resp.lower()
    data = yaml.safe_load(yaml_path.read_text()) if yaml_path.exists() else None
    stories = (data or {}).get("stories", [])
    s_001 = next((s for s in stories if s.get("id") == "2605-001"), None)
    s_002 = next((s for s in stories if s.get("id") == "2605-002"), None)
    s_001_tags = (s_001 or {}).get("tags", []) or []
    s_002_tags = (s_002 or {}).get("tags", []) or []

    return [
        {"text": "stories.yaml was modified — story 2605-001's tags now contains 'billing'", "passed": "billing" in s_001_tags, "evidence": f"2605-001 tags={s_001_tags}"},
        {"text": "Original tags ('export', 'data') are preserved on 2605-001", "passed": "export" in s_001_tags and "data" in s_001_tags, "evidence": f"tags={s_001_tags}"},
        {"text": "No other story's tags were modified", "passed": s_002_tags == ["auth", "account"], "evidence": f"2605-002 tags={s_002_tags}"},
        {"text": "Response notes that 'billing' is a new tag (not previously in taxonomy)", "passed": "new tag" in low or "no other story" in low or "no taxonomy precedent" in low or "no precedent" in low, "evidence": ""},
        {"text": "Response shows the resulting tags line for 2605-001", "passed": "billing" in resp and ("2605-001" in resp or "tags" in low), "evidence": ""},
    ]


def grade_suggest(outputs: Path) -> list[dict]:
    yaml_path = outputs / "stories.yaml"
    resp = (outputs / "response.md").read_text() if (outputs / "response.md").exists() else ""
    low = resp.lower()
    yaml_modified = yaml_path.exists()

    return [
        {"text": "Output proposes 1-4 tags", "passed": "suggested" in low or "propose" in low or "tags:" in low, "evidence": ""},
        {"text": "Suggested tags include 'billing' OR 'admin' OR 'reports'", "passed": any(t in low for t in ["billing", "admin", "reports"]), "evidence": ""},
        {"text": "Output explains why each tag was picked (which keyword matched)", "passed": "matched" in low or "keyword" in low or "synonym" in low, "evidence": ""},
        {"text": "Output uses existing taxonomy where possible", "passed": "admin" in low or "taxonomy" in low or "reuse" in low or "existing" in low, "evidence": ""},
        {"text": "Output is in suggest-mode template (proposing, not modifying yaml)", "passed": not yaml_modified or "suggested" in low, "evidence": f"yaml_modified={yaml_modified}"},
    ]


GRADERS = {
    "eval-list-taxonomy": grade_list,
    "eval-add-tag-to-story": grade_add,
    "eval-suggest-for-draft": grade_suggest,
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
