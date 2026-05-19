#!/usr/bin/env python3
"""Grade spec-refinement iteration outputs against per-eval assertions."""
from __future__ import annotations
import json, re, sys
from pathlib import Path


def gather_text(run_dir: Path) -> str:
    blobs: list[str] = []
    outputs = run_dir / "outputs"
    sandbox = run_dir / "sandbox"
    for f in [outputs / "run_notes.md", outputs / "git-diff.patch", outputs / "git-status.txt"]:
        if f.exists():
            blobs.append(f.read_text(errors="ignore"))
    for sub in ("new-files", "modified-files"):
        d = outputs / sub
        if d.is_dir():
            for p in d.rglob("*"):
                if p.is_file():
                    blobs.append(p.read_text(errors="ignore"))
    for name in ("gate_reached.md", "route_decision.md"):
        f = sandbox / name
        if f.exists():
            blobs.append(f.read_text(errors="ignore"))
    return "\n".join(blobs)


def gather_artifacts(run_dir: Path) -> dict:
    sandbox = run_dir / "sandbox"
    porcelain = run_dir / "outputs" / "git-status.txt"
    new_paths, modified_paths = [], []
    if porcelain.exists():
        for line in porcelain.read_text(errors="ignore").splitlines():
            if line.startswith("??") or line.startswith("A ") or line.startswith("AM"):
                new_paths.append(line[3:].strip())
            elif line.startswith(" M") or line.startswith("M ") or line.startswith("MM"):
                modified_paths.append(line[3:].strip())

    sp001 = sandbox / "docs" / "notes" / "spec" / "sp001.md"
    sp001_modified = "docs/notes/spec/sp001.md" in modified_paths
    sp001_status, sp001_body = None, ""
    if sp001.exists():
        sp001_body = sp001.read_text(errors="ignore")
        m = re.search(r"^status:\s*(\w+)\s*$", sp001_body, re.M)
        sp001_status = m.group(1) if m else None

    sp001_has_plan = bool(re.search(r"^##\s*plan\s*$", sp001_body, re.M | re.I))
    sp001_has_tasks = bool(re.search(r"^##\s*tasks\s*$", sp001_body, re.M | re.I))
    sp001_task_headers = re.findall(r"^###\s+Task\s+\d+", sp001_body, re.M | re.I)
    h4_props = ["type", "effort", "depends", "files_touched", "success_criteria", "edge_cases", "test_plan"]
    h4_present = {p: bool(re.search(rf"^####\s+{p}\b", sp001_body, re.M | re.I)) for p in h4_props}
    sp001_has_bd_annotations = bool(re.search(r"^####\s*bd\s+\S", sp001_body, re.M | re.I))

    board = sandbox / "docs" / "board.md"
    board_modified = "docs/board.md" in modified_paths

    im002 = sandbox / "docs" / "notes" / "im002.md"
    im002_modified = "docs/notes/im002.md" in modified_paths
    im002_body = ""
    if im002.exists():
        im002_body = im002.read_text(errors="ignore")
    im002_specs_has_sp001 = bool(re.search(r"##\s*specs[\s\S]{0,300}\[\[sp001", im002_body, re.I))

    text_all = gather_text(run_dir)
    bd_called = bool(re.search(r"^\s*bd\s+(create|update|close|list|dep)\b", text_all, re.M))

    gate_exists = (sandbox / "gate_reached.md").exists()
    route_exists = (sandbox / "route_decision.md").exists()

    return {
        "sp001_modified": sp001_modified,
        "sp001_status": sp001_status,
        "sp001_body": sp001_body,
        "sp001_has_plan": sp001_has_plan,
        "sp001_has_tasks": sp001_has_tasks,
        "sp001_task_headers": sp001_task_headers,
        "h4_present": h4_present,
        "sp001_has_bd_annotations": sp001_has_bd_annotations,
        "board_modified": board_modified,
        "im002_modified": im002_modified,
        "im002_body": im002_body,
        "im002_specs_has_sp001": im002_specs_has_sp001,
        "bd_called": bd_called,
        "gate_exists": gate_exists,
        "route_exists": route_exists,
    }


def grade_eval0(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    results.append({"text": "Agent read sp001 and confirmed status: spec",
                    "passed": bool(re.search(r"sp001.*spec|spec.*sp001|status:\s*spec", text, re.I)),
                    "evidence": "sp001 + spec"})

    results.append({"text": "Agent re-read us003 AC",
                    "passed": bool(re.search(r"us003.*(?:AC|acceptance|criteria)|(?:AC|acceptance|criteria).*us003", text, re.I | re.S)),
                    "evidence": "us003 + AC ref"})

    results.append({"text": "Agent read im002",
                    "passed": bool(re.search(r"im002", text, re.I)),
                    "evidence": "im002 mentioned"})

    adrs = re.findall(r"adr000[12]", text, re.I)
    results.append({"text": "Agent surveyed adr0001 / adr0002",
                    "passed": bool(adrs),
                    "evidence": f"adrs: {sorted(set(adrs))}"})

    ft_with_surface = bool(re.search(r"ft002", text, re.I)) and bool(re.search(r"(api.surface|api_surface)", text, re.I))
    results.append({"text": "Agent surveyed ft002 including api_surface",
                    "passed": ft_with_surface,
                    "evidence": "ft002 + api_surface"})

    results.append({"text": "Agent appended ## plan to sp001",
                    "passed": art["sp001_has_plan"],
                    "evidence": f"has_plan={art['sp001_has_plan']}"})

    results.append({"text": "Agent appended ## tasks with H3 headers",
                    "passed": art["sp001_has_tasks"] and len(art["sp001_task_headers"]) >= 1,
                    "evidence": f"has_tasks={art['sp001_has_tasks']} task_headers={art['sp001_task_headers']}"})

    h4_count = sum(1 for v in art["h4_present"].values() if v)
    results.append({"text": "Tasks include >=4 H4 properties",
                    "passed": h4_count >= 4,
                    "evidence": f"h4 present: {[k for k,v in art['h4_present'].items() if v]}"})

    results.append({"text": "Tasks do NOT include #### bd id annotations",
                    "passed": not art["sp001_has_bd_annotations"],
                    "evidence": f"bd_annotations={art['sp001_has_bd_annotations']}"})

    results.append({"text": "Agent did NOT use bd commands",
                    "passed": not art["bd_called"],
                    "evidence": f"bd_called={art['bd_called']}"})

    results.append({"text": "Agent did NOT change sp001 status",
                    "passed": art["sp001_status"] == "spec",
                    "evidence": f"status={art['sp001_status']}"})

    results.append({"text": "Agent did NOT modify docs/board.md",
                    "passed": not art["board_modified"],
                    "evidence": f"board_modified={art['board_modified']}"})

    results.append({"text": "Agent finalized im002 ## specs back-link",
                    "passed": art["im002_modified"] and art["im002_specs_has_sp001"],
                    "evidence": f"im002_modified={art['im002_modified']} has_sp001={art['im002_specs_has_sp001']}"})

    return results


def grade_eval1(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    recognized_idea = bool(re.search(r"sp001.*idea|idea.*sp001|status:\s*idea", text, re.I))
    results.append({"text": "Agent read sp001 and recognized status: idea",
                    "passed": recognized_idea,
                    "evidence": "sp001 + idea"})

    solution_missing = bool(re.search(r"(no.{0,20}solution|solution.{0,20}missing|solution.{0,20}empty|missing.{0,20}solution|without.{0,20}solution)", text, re.I))
    results.append({"text": "Agent recognized ## solution missing",
                    "passed": solution_missing,
                    "evidence": "missing-solution phrase"})

    no_plan_tasks = not (art["sp001_has_plan"] or art["sp001_has_tasks"])
    results.append({"text": "Agent did NOT append ## plan or ## tasks",
                    "passed": no_plan_tasks,
                    "evidence": f"has_plan={art['sp001_has_plan']} has_tasks={art['sp001_has_tasks']}"})

    no_status_change = art["sp001_status"] == "idea"
    results.append({"text": "Agent did NOT modify sp001 frontmatter",
                    "passed": no_status_change,
                    "evidence": f"status={art['sp001_status']}"})

    results.append({"text": "Agent did NOT modify docs/board.md",
                    "passed": not art["board_modified"],
                    "evidence": f"board_modified={art['board_modified']}"})

    routed = bool(re.search(r"(spec-writing|cannot.{0,20}refine|route.{0,20}back|missing.{0,20}solution)", text, re.I))
    results.append({"text": "Output routes to spec-writing OR 'solution missing'",
                    "passed": routed,
                    "evidence": "route phrase"})

    return results


def grade_eval2(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    adr0001_seen = bool(re.search(r"adr0001", text, re.I))
    results.append({"text": "Agent surveyed adr0001",
                    "passed": adr0001_seen,
                    "evidence": "adr0001 referenced"})

    conflict_detected = adr0001_seen and bool(re.search(r"(conflict|violat|supersede|bypass|override|contradict)", text, re.I))
    results.append({"text": "Agent detected conflict between solution and adr0001",
                    "passed": conflict_detected,
                    "evidence": "adr0001 + conflict-language"})

    flagged_explicit = bool(re.search(r"(adr0001[\s\S]{0,200}(?:conflict|violat|supersede|bypass))|((?:conflict|violat|supersede|bypass)[\s\S]{0,200}adr0001)", text, re.I))
    results.append({"text": "Output flags conflict (adr0001 + conflict/violate/supersede nearby)",
                    "passed": flagged_explicit,
                    "evidence": "proximity match"})

    addressed = art["gate_exists"] or art["route_exists"] or bool(re.search(r"(supersede.{0,40}adr|new ADR.{0,40}supersed|file.{0,40}ADR|Task.{0,80}supersed)", text, re.I))
    results.append({"text": "Either supersession task in breakdown OR skill stops",
                    "passed": addressed,
                    "evidence": f"gate={art['gate_exists']} route={art['route_exists']}"})

    not_silent = conflict_detected or addressed
    results.append({"text": "Did NOT silently implement conflicting solution",
                    "passed": not_silent,
                    "evidence": "conflict acknowledged"})

    return results


def grade_eval3(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    ft002_seen = bool(re.search(r"ft002", text, re.I))
    surface_read = ft002_seen and bool(re.search(r"(api.surface|api_surface|providing)", text, re.I))
    results.append({"text": "Agent surveyed ft002 and read api_surface / providing",
                    "passed": surface_read,
                    "evidence": "ft002 + api_surface/providing"})

    set_ttl_flagged = bool(re.search(r"set_default_ttl|set.default.ttl", text, re.I)) and bool(re.search(r"(not.{0,30}in|missing|extension|extend|new.{0,30}surface|outside)", text, re.I))
    results.append({"text": "Agent detected vault.set_default_ttl() not in ft002.api_surface",
                    "passed": set_ttl_flagged,
                    "evidence": "set_default_ttl + extension/not-in"})

    audit_flagged = bool(re.search(r"audit.log|audit-log", text, re.I)) and bool(re.search(r"(not.{0,30}in|missing|extension|extend|providing)", text, re.I))
    results.append({"text": "Agent detected audit-log behavior not in ft002.providing",
                    "passed": audit_flagged,
                    "evidence": "audit + extension/not-in"})

    extension_flagged = bool(re.search(r"(extension|extend.{0,20}feature|extend.{0,20}ft002|feature-extension|idea-extend.{0,30}ft002)", text, re.I))
    results.append({"text": "Output flags feature-extension",
                    "passed": ft002_seen and extension_flagged,
                    "evidence": "ft002 + extension phrase"})

    addressed = art["gate_exists"] or art["route_exists"] or bool(re.search(r"(idea-extend.{0,60}ft002|Task.{0,80}idea-extend|route.{0,60}idea-extend)", text, re.I))
    results.append({"text": "Either breakdown routes to idea-extend on ft002 OR skill stops",
                    "passed": addressed,
                    "evidence": f"gate={art['gate_exists']} route={art['route_exists']}"})

    not_silent = extension_flagged or addressed
    results.append({"text": "Did NOT silently call non-existent ft002 surface",
                    "passed": not_silent,
                    "evidence": "extension acknowledged"})

    return results


GRADERS = {0: grade_eval0, 1: grade_eval1, 2: grade_eval2, 3: grade_eval3}


def main(iter_dir: Path):
    eval_dirs = sorted([d for d in iter_dir.iterdir() if d.is_dir() and d.name.startswith("eval-")])
    for ed in eval_dirs:
        meta_file = ed / "eval_metadata.json"
        if not meta_file.exists():
            continue
        meta = json.loads(meta_file.read_text())
        eid = meta["eval_id"]
        grader = GRADERS.get(eid)
        if not grader:
            continue
        for cfg in ("with_skill", "without_skill"):
            run_dir = ed / cfg
            if not run_dir.exists():
                continue
            results = grader(run_dir)
            passed = sum(1 for r in results if r["passed"])
            total = len(results)
            pass_rate = passed / total if total else 0.0
            run1 = run_dir / "run-1"
            run1.mkdir(exist_ok=True)
            grading = {
                "eval_id": eid,
                "eval_name": meta["eval_name"],
                "config": cfg,
                "summary": {"pass_rate": pass_rate, "passed": passed, "failed": total - passed, "total": total},
                "expectations": results,
            }
            (run1 / "grading.json").write_text(json.dumps(grading, indent=2))
            src_timing = run_dir / "timing.json"
            if src_timing.exists():
                (run1 / "timing.json").write_text(src_timing.read_text())
            print(f"{ed.name}/{cfg}: {passed}/{total} ({pass_rate*100:.0f}%)")


if __name__ == "__main__":
    iter_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "iteration-1"
    main(iter_dir.resolve())
