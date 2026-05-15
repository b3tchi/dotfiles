#!/usr/bin/env python3
"""Grade story-write eval outputs against assertions in evals.json.

Writes grading.json under each eval dir.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml


WORKSPACE = Path(__file__).parent
EVALS_FILE = WORKSPACE / "evals.json"


def load_yaml(path: Path):
    if not path.exists():
        return None
    with path.open() as f:
        return yaml.safe_load(f)


def grade_eval_0(outputs_dir: Path) -> list[dict]:
    """eval-full-info-upfront."""
    stories_path = outputs_dir / "stories.yaml"
    response_path = outputs_dir / "response.md"
    results = []

    data = load_yaml(stories_path)
    valid_yaml = data is not None and isinstance(data, dict) and "stories" in data
    stories = data.get("stories", []) if valid_yaml else []

    results.append({
        "text": "product/stories.yaml exists at sandbox root",
        "passed": stories_path.exists(),
        "evidence": f"path={stories_path}, exists={stories_path.exists()}",
    })
    results.append({
        "text": "stories.yaml is valid YAML with a top-level stories: list",
        "passed": valid_yaml and isinstance(stories, list),
        "evidence": f"keys={list(data.keys()) if data else None}",
    })
    results.append({
        "text": "Exactly one story entry was added",
        "passed": len(stories) == 1,
        "evidence": f"count={len(stories)}",
    })

    if not stories:
        for missing in [
            "id matches yymm-NNN pattern (regex ^\\d{4}-\\d{3}$)",
            "role field equals 'data analyst' (case-insensitive)",
            "want field describes exporting CSV",
            "so_that field mentions sharing with stakeholders",
            "acceptance_criteria has exactly 3 items matching what the user provided",
            "status equals 'draft'",
            "created field is an ISO date YYYY-MM-DD",
            "title field is present and <= 80 chars",
        ]:
            results.append({"text": missing, "passed": False, "evidence": "no story"})
        return results

    s = stories[0]
    sid = str(s.get("id", ""))
    role = str(s.get("role", "")).lower()
    want = str(s.get("want", "")).lower()
    so_that = str(s.get("so_that", "")).lower()
    ac = s.get("acceptance_criteria", []) or []
    status = str(s.get("status", ""))
    created = str(s.get("created", ""))
    title = str(s.get("title", ""))

    results.append({
        "text": "id matches yymm-NNN pattern (regex ^\\d{4}-\\d{3}$)",
        "passed": bool(re.match(r"^\d{4}-\d{3}$", sid)),
        "evidence": f"id={sid!r}",
    })
    results.append({
        "text": "role field equals 'data analyst' (case-insensitive)",
        "passed": role.strip() == "data analyst",
        "evidence": f"role={role!r}",
    })
    results.append({
        "text": "want field describes exporting CSV",
        "passed": "csv" in want and "export" in want,
        "evidence": f"want={want!r}",
    })
    results.append({
        "text": "so_that field mentions sharing with stakeholders",
        "passed": "stakeholder" in so_that or "share" in so_that,
        "evidence": f"so_that={so_that!r}",
    })
    results.append({
        "text": "acceptance_criteria has exactly 3 items matching what the user provided",
        "passed": isinstance(ac, list) and len(ac) == 3,
        "evidence": f"ac_count={len(ac) if isinstance(ac, list) else 'not-list'}",
    })
    results.append({
        "text": "status equals 'draft'",
        "passed": status == "draft",
        "evidence": f"status={status!r}",
    })
    results.append({
        "text": "created field is an ISO date YYYY-MM-DD",
        "passed": bool(re.match(r"^\d{4}-\d{2}-\d{2}$", created)),
        "evidence": f"created={created!r}",
    })
    results.append({
        "text": "title field is present and <= 80 chars",
        "passed": bool(title) and len(title) <= 80,
        "evidence": f"title={title!r} (len={len(title)})",
    })
    tags = s.get("tags", []) or []
    results.append({
        "text": "tags field is a non-empty list",
        "passed": isinstance(tags, list) and len(tags) >= 1,
        "evidence": f"tags={tags!r}",
    })
    results.append({
        "text": "tags include 'export' or 'data'",
        "passed": isinstance(tags, list) and any(t.lower() in ("export", "data") for t in tags),
        "evidence": f"tags={tags!r}",
    })
    return results


def grade_eval_1(outputs_dir: Path) -> list[dict]:
    """eval-partial-info-needs-gathering — admin bulk-archive."""
    stories_path = outputs_dir / "stories.yaml"
    data = load_yaml(stories_path)
    stories = (data or {}).get("stories", []) if data else []
    results = []

    results.append({
        "text": "product/stories.yaml exists with one story added",
        "passed": stories_path.exists() and len(stories) == 1,
        "evidence": f"exists={stories_path.exists()}, count={len(stories)}",
    })
    if not stories:
        for missing in [
            "role mentions 'admin'",
            "want describes bulk-archive of old reports",
            "so_that field is non-empty and provides a motivation (not 'TBD' or empty)",
            "acceptance_criteria has at least 1 item",
            "status equals 'draft'",
            "id matches yymm-NNN pattern",
        ]:
            results.append({"text": missing, "passed": False, "evidence": "no story"})
        return results
    s = stories[0]
    role = str(s.get("role", "")).lower()
    want = str(s.get("want", "")).lower()
    so_that = str(s.get("so_that", ""))
    ac = s.get("acceptance_criteria", []) or []
    status = str(s.get("status", ""))
    sid = str(s.get("id", ""))

    results.append({"text": "role mentions 'admin'", "passed": "admin" in role, "evidence": f"role={role!r}"})
    results.append({"text": "want describes bulk-archive of old reports", "passed": ("archive" in want and "report" in want), "evidence": f"want={want!r}"})
    results.append({"text": "so_that field is non-empty and provides a motivation (not 'TBD' or empty)", "passed": bool(so_that.strip()) and "TBD" not in so_that.upper(), "evidence": f"so_that={so_that!r}"})
    results.append({"text": "acceptance_criteria has at least 1 item", "passed": isinstance(ac, list) and len(ac) >= 1, "evidence": f"ac_count={len(ac) if isinstance(ac, list) else 'not-list'}"})
    results.append({"text": "status equals 'draft'", "passed": status == "draft", "evidence": f"status={status!r}"})
    results.append({"text": "id matches yymm-NNN pattern", "passed": bool(re.match(r"^\d{4}-\d{3}$", sid)), "evidence": f"id={sid!r}"})
    tags = s.get("tags", []) or []
    results.append({"text": "tags field is a non-empty list", "passed": isinstance(tags, list) and len(tags) >= 1, "evidence": f"tags={tags!r}"})
    results.append({"text": "tags include 'admin' or 'reports'", "passed": isinstance(tags, list) and any(t.lower() in ("admin", "reports") for t in tags), "evidence": f"tags={tags!r}"})
    return results


def grade_eval_2(outputs_dir: Path) -> list[dict]:
    """eval-fresh-project-first-story — password reset."""
    sandbox = outputs_dir.parent / "sandbox"
    product_dir = sandbox / "product"
    stories_path = outputs_dir / "stories.yaml"
    data = load_yaml(stories_path)
    stories = (data or {}).get("stories", []) if data else []
    results = []

    results.append({"text": "product/ directory was created", "passed": product_dir.is_dir(), "evidence": f"path={product_dir}, exists={product_dir.is_dir()}"})
    results.append({"text": "product/stories.yaml was created (did not exist before)", "passed": stories_path.exists(), "evidence": f"exists={stories_path.exists()}"})
    results.append({"text": "Exactly one story entry exists", "passed": len(stories) == 1, "evidence": f"count={len(stories)}"})
    if not stories:
        for missing in [
            "id ends with '-001' (first story of the month)",
            "role contains 'user' or 'logged-in user'",
            "want describes password reset",
            "so_that mentions account access / lockout",
            "acceptance_criteria has at least 1 testable item",
        ]:
            results.append({"text": missing, "passed": False, "evidence": "no story"})
        return results
    s = stories[0]
    sid = str(s.get("id", ""))
    role = str(s.get("role", "")).lower()
    want = str(s.get("want", "")).lower()
    so_that = str(s.get("so_that", "")).lower()
    ac = s.get("acceptance_criteria", []) or []

    results.append({"text": "id ends with '-001' (first story of the month)", "passed": sid.endswith("-001"), "evidence": f"id={sid!r}"})
    results.append({"text": "role contains 'user' or 'logged-in user'", "passed": "user" in role, "evidence": f"role={role!r}"})
    results.append({"text": "want describes password reset", "passed": "password" in want and "reset" in want, "evidence": f"want={want!r}"})
    results.append({"text": "so_that mentions account access / lockout", "passed": ("lock" in so_that or "account" in so_that or "access" in so_that), "evidence": f"so_that={so_that!r}"})
    results.append({"text": "acceptance_criteria has at least 1 testable item", "passed": isinstance(ac, list) and len(ac) >= 1, "evidence": f"ac_count={len(ac) if isinstance(ac, list) else 'not-list'}"})
    tags = s.get("tags", []) or []
    results.append({"text": "tags field is a non-empty list", "passed": isinstance(tags, list) and len(tags) >= 1, "evidence": f"tags={tags!r}"})
    results.append({"text": "tags include 'auth' or 'account'", "passed": isinstance(tags, list) and any(t.lower() in ("auth", "account", "authentication") for t in tags), "evidence": f"tags={tags!r}"})
    return results


GRADERS = {
    "eval-full-info-upfront": grade_eval_0,
    "eval-partial-info-needs-gathering": grade_eval_1,
    "eval-fresh-project-first-story": grade_eval_2,
}


def main():
    iteration = sys.argv[1] if len(sys.argv) > 1 else "iteration-1"
    iteration_dir = WORKSPACE / iteration
    summary = []
    for eval_dir in sorted(iteration_dir.iterdir()):
        if not eval_dir.is_dir() or not eval_dir.name.startswith("eval-"):
            continue
        grader = GRADERS.get(eval_dir.name)
        if grader is None:
            print(f"skip {eval_dir.name} (no grader)")
            continue
        outputs = eval_dir / "with_skill" / "outputs"
        results = grader(outputs)
        passed = sum(1 for r in results if r["passed"])
        total = len(results)
        grading = {
            "eval_name": eval_dir.name,
            "expectations": results,
            "summary": f"{passed}/{total} passed",
        }
        out_path = eval_dir / "with_skill" / "grading.json"
        out_path.write_text(json.dumps(grading, indent=2))
        summary.append((eval_dir.name, passed, total))
        print(f"{eval_dir.name}: {passed}/{total} passed -> {out_path}")
    print("\n--- SUMMARY ---")
    for name, p, t in summary:
        print(f"  {name}: {p}/{t}")


if __name__ == "__main__":
    main()
