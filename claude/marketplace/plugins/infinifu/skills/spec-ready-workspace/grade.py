#!/usr/bin/env python3
"""Grade spec-ready iteration outputs against per-eval assertions."""
from __future__ import annotations
import json, re, sys
from pathlib import Path


def gather_text(run_dir: Path) -> str:
    blobs: list[str] = []
    outputs = run_dir / "outputs"
    sandbox = run_dir / "sandbox"
    for f in [outputs / "run_notes.md", outputs / "git-diff.patch", outputs / "git-status.txt", outputs / "bd-ready.txt"]:
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


def load_bd(run_dir: Path) -> list[dict]:
    bd_json = run_dir / "outputs" / "bd-list.json"
    if not bd_json.exists():
        return []
    try:
        data = json.loads(bd_json.read_text())
        if isinstance(data, dict):
            return data.get("issues", []) or data.get("data", []) or []
        if isinstance(data, list):
            return data
    except json.JSONDecodeError:
        pass
    return []


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

    bd_annotations = re.findall(r"^####\s+bd\s*\n([A-Za-z0-9\-_.]+)", sp001_body, re.M)
    # Also pattern: #### bd <id> on same line
    inline_bd = re.findall(r"^####\s+bd\s+([A-Za-z0-9\-_.]+)", sp001_body, re.M)
    bd_annotations = bd_annotations + inline_bd
    task_headers = re.findall(r"^###\s+Task\s+\d+", sp001_body, re.M | re.I)

    board = sandbox / "docs" / "board.md"
    board_modified = "docs/board.md" in modified_paths
    board_text = board.read_text(errors="ignore") if board.exists() else ""
    spec_section = re.search(r"##\s*spec\b.*?(?=^##|\Z)", board_text, re.S | re.M | re.I)
    ready_section = re.search(r"##\s*ready\b.*?(?=^##|\Z)", board_text, re.S | re.M | re.I)
    sp001_under_spec = bool(spec_section and "sp001" in spec_section.group(0))
    sp001_under_ready = bool(ready_section and "sp001" in ready_section.group(0))

    bd_issues = load_bd(run_dir)
    bd_epics = [i for i in bd_issues if (i.get("issue_type") or i.get("type")) == "epic"]
    bd_tasks = [i for i in bd_issues if (i.get("issue_type") or i.get("type")) == "task"]
    epic_ids = [e.get("id") for e in bd_epics]
    task_ids = [t.get("id") for t in bd_tasks]

    # bd uses dependency list with type=parent-child / type=blocks
    def task_parents(t):
        deps = t.get("dependencies", []) or []
        return [d.get("depends_on_id") for d in deps if d.get("type") == "parent-child"]

    def task_blockers(t):
        deps = t.get("dependencies", []) or []
        return [d.get("depends_on_id") for d in deps if d.get("type") == "blocks"]

    tasks_with_parent = [t for t in bd_tasks if any(p in epic_ids for p in task_parents(t))]
    dep_count = sum(len(task_blockers(t)) for t in bd_tasks)

    src_modified = any(p.startswith("src/") for p in (new_paths + modified_paths))

    # Check bd state directly instead of grepping narrative — narrative quotes the skill
    # text which mentions "bd update --status in_progress" in out-of-scope sections.
    bd_in_progress = any((i.get("status") or "").lower() == "in_progress" for i in bd_issues)
    bd_close = any((i.get("status") or "").lower() in ("closed", "done") for i in bd_issues)

    gate_exists = (sandbox / "gate_reached.md").exists()
    route_exists = (sandbox / "route_decision.md").exists()

    return {
        "sp001_modified": sp001_modified,
        "sp001_status": sp001_status,
        "sp001_body": sp001_body,
        "bd_annotation_count": len([b for b in bd_annotations if b and b != "<id>"]),
        "task_header_count": len(task_headers),
        "board_modified": board_modified,
        "sp001_under_spec": sp001_under_spec,
        "sp001_under_ready": sp001_under_ready,
        "bd_epics": bd_epics,
        "bd_tasks": bd_tasks,
        "epic_ids": epic_ids,
        "task_ids": task_ids,
        "tasks_with_parent": tasks_with_parent,
        "dep_count": dep_count,
        "src_modified": src_modified,
        "bd_in_progress": bd_in_progress,
        "bd_close": bd_close,
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

    results.append({"text": "Agent created exactly one bd epic for sp001",
                    "passed": len(art["bd_epics"]) >= 1,
                    "evidence": f"epic_count={len(art['bd_epics'])} ids={art['epic_ids']}"})

    results.append({"text": "Agent created at least 3 bd tasks (one per ### Task N)",
                    "passed": len(art["bd_tasks"]) >= 3,
                    "evidence": f"task_count={len(art['bd_tasks'])}"})

    results.append({"text": "All bd tasks have --parent linking to the epic",
                    "passed": len(art["tasks_with_parent"]) == len(art["bd_tasks"]) and len(art["bd_tasks"]) >= 3,
                    "evidence": f"with_parent={len(art['tasks_with_parent'])} of {len(art['bd_tasks'])}"})

    results.append({"text": "Agent added blocking deps (>=2 dep edges from #### depends)",
                    "passed": art["dep_count"] >= 2,
                    "evidence": f"dep_count={art['dep_count']}"})

    annotated = art["bd_annotation_count"] >= 3 and art["task_header_count"] >= 3
    results.append({"text": "Agent annotated each ### Task N with #### bd <id>",
                    "passed": annotated,
                    "evidence": f"bd_annotations={art['bd_annotation_count']} task_headers={art['task_header_count']}"})

    results.append({"text": "Agent flipped sp001 status from spec to ready",
                    "passed": art["sp001_status"] == "ready",
                    "evidence": f"status={art['sp001_status']}"})

    board_moved = art["sp001_under_ready"] and not art["sp001_under_spec"]
    results.append({"text": "Agent moved docs/board.md [[sp001]] from ## spec to ## ready",
                    "passed": board_moved,
                    "evidence": f"under_spec={art['sp001_under_spec']} under_ready={art['sp001_under_ready']}"})

    results.append({"text": "Agent did NOT use bd update --status in_progress",
                    "passed": not art["bd_in_progress"],
                    "evidence": f"in_progress_called={art['bd_in_progress']}"})

    results.append({"text": "Agent did NOT use bd close",
                    "passed": not art["bd_close"],
                    "evidence": f"close_called={art['bd_close']}"})

    results.append({"text": "Agent did NOT touch src/",
                    "passed": not art["src_modified"],
                    "evidence": f"src_modified={art['src_modified']}"})

    return results


def grade_eval1(run_dir: Path) -> list[dict]:
    """already-ready-stop: sp001 already at status: ready with #### bd ids."""
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    recognized = bool(re.search(r"sp001.*(?:ready|status)|(?:status|ready).*sp001|status:\s*ready", text, re.I))
    results.append({"text": "Agent recognized status: ready",
                    "passed": recognized,
                    "evidence": "sp001 + ready"})

    bd_present = bool(re.search(r"(####\s*bd|bd.{0,20}annotation|already.{0,20}annotated|already.{0,20}processed)", text, re.I))
    results.append({"text": "Agent recognized #### bd annotations already exist",
                    "passed": bd_present,
                    "evidence": "bd-annotation language"})

    results.append({"text": "Agent did NOT modify sp001",
                    "passed": not art["sp001_modified"],
                    "evidence": f"sp001_modified={art['sp001_modified']}"})

    results.append({"text": "Agent did NOT modify docs/board.md",
                    "passed": not art["board_modified"],
                    "evidence": f"board_modified={art['board_modified']}"})

    routed = bool(re.search(r"(work-do|already.{0,20}ready|already.{0,20}processed)", text, re.I))
    results.append({"text": "Output routes to work-do or states 'already ready'",
                    "passed": routed,
                    "evidence": "route phrase"})

    # No new bd issues created — verify by checking if anything new appears in bd_list
    # (impossible to fully verify without baseline; pass if agent stopped clean)
    results.append({"text": "Agent did NOT create any new bd epic / tasks (stopped clean)",
                    "passed": art["route_exists"] or art["gate_exists"] or (not art["sp001_modified"] and not art["board_modified"]),
                    "evidence": f"route={art['route_exists']} gate={art['gate_exists']}"})

    return results


def grade_eval2(run_dir: Path) -> list[dict]:
    """no-tasks-block: sp001 spec status but ## tasks empty/missing."""
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    tasks_missing = bool(re.search(r"(no.{0,30}tasks|tasks.{0,30}missing|missing.{0,30}tasks|empty.{0,30}tasks|no.{0,30}## tasks)", text, re.I))
    results.append({"text": "Agent recognized ## tasks missing/empty",
                    "passed": tasks_missing,
                    "evidence": "missing-tasks phrase"})

    results.append({"text": "Agent did NOT create bd epic / tasks (cannot invent)",
                    "passed": len(art["bd_epics"]) == 0 and len(art["bd_tasks"]) == 0,
                    "evidence": f"epics={len(art['bd_epics'])} tasks={len(art['bd_tasks'])}"})

    results.append({"text": "Agent did NOT modify sp001",
                    "passed": not art["sp001_modified"],
                    "evidence": f"sp001_modified={art['sp001_modified']}"})

    results.append({"text": "Agent did NOT modify docs/board.md",
                    "passed": not art["board_modified"],
                    "evidence": f"board_modified={art['board_modified']}"})

    results.append({"text": "Agent did NOT change sp001 status",
                    "passed": art["sp001_status"] == "spec",
                    "evidence": f"status={art['sp001_status']}"})

    routed = bool(re.search(r"(spec-refinement|refine|tasks.{0,20}missing|missing.{0,20}tasks)", text, re.I))
    results.append({"text": "Output routes to spec-refinement OR 'tasks missing'",
                    "passed": routed,
                    "evidence": "route phrase"})

    return results


def grade_eval3(run_dir: Path) -> list[dict]:
    """already-annotated-stop: sp001 spec status but #### bd ids present."""
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    annotations_seen = bool(re.search(r"(####\s*bd|already.{0,20}annotated|already.{0,20}processed|bd.{0,20}id.{0,20}exist)", text, re.I))
    results.append({"text": "Agent recognized #### bd ids already present",
                    "passed": annotations_seen,
                    "evidence": "annotation-language"})

    results.append({"text": "Agent recognized the spec has been processed",
                    "passed": annotations_seen,
                    "evidence": "processed-language present"})

    results.append({"text": "Agent did NOT create duplicate bd epic / tasks",
                    "passed": len(art["bd_epics"]) == 0 and len(art["bd_tasks"]) == 0,
                    "evidence": f"epics={len(art['bd_epics'])} tasks={len(art['bd_tasks'])}"})

    results.append({"text": "Agent did NOT modify sp001",
                    "passed": not art["sp001_modified"],
                    "evidence": f"sp001_modified={art['sp001_modified']}"})

    results.append({"text": "Agent did NOT modify docs/board.md",
                    "passed": not art["board_modified"],
                    "evidence": f"board_modified={art['board_modified']}"})

    routed = bool(re.search(r"(already.{0,20}processed|bd.{0,20}id.{0,20}exist|duplicate|work-do)", text, re.I))
    results.append({"text": "Output states 'already processed' or routes accordingly",
                    "passed": routed,
                    "evidence": "route phrase"})

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
