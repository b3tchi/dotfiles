#!/usr/bin/env python3
"""Grade spec-writing iteration outputs against per-eval assertions."""
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

    sp001_has_solution = bool(re.search(r"^##\s*solution\s*$", sp001_body, re.M | re.I))

    # Out-of-scope artifacts the skill must NOT touch
    new_im_files = [p for p in new_paths if re.search(r"docs/notes/im\d{3}\.md", p)]
    im002_modified = "docs/notes/im002.md" in modified_paths
    product_modified = "docs/product.md" in modified_paths
    us003_modified = "docs/notes/us003.md" in modified_paths

    board = sandbox / "docs" / "board.md"
    board_modified = "docs/board.md" in modified_paths
    board_text = board.read_text(errors="ignore") if board.exists() else ""
    idea_section = re.search(r"##\s*idea\b.*?(?=^##|\Z)", board_text, re.S | re.M | re.I)
    spec_section = re.search(r"##\s*spec\b.*?(?=^##|\Z)", board_text, re.S | re.M | re.I)
    sp001_under_idea = bool(idea_section and "sp001" in idea_section.group(0))
    sp001_under_spec = bool(spec_section and "sp001" in spec_section.group(0))

    text_all = gather_text(run_dir)
    bd_called = bool(re.search(r"^\s*bd\s+(create|update|close|list)\b", text_all, re.M))

    gate_exists = (sandbox / "gate_reached.md").exists()
    route_exists = (sandbox / "route_decision.md").exists()

    return {
        "sp001_modified": sp001_modified,
        "sp001_status": sp001_status,
        "sp001_body": sp001_body,
        "sp001_has_solution": sp001_has_solution,
        "board_modified": board_modified,
        "sp001_under_idea": sp001_under_idea,
        "sp001_under_spec": sp001_under_spec,
        "bd_called": bd_called,
        "gate_exists": gate_exists,
        "route_exists": route_exists,
        "new_paths": new_paths,
        "modified_paths": modified_paths,
        "new_im_files": new_im_files,
        "im002_modified": im002_modified,
        "product_modified": product_modified,
        "us003_modified": us003_modified,
    }


def grade_eval0(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    results.append({"text": "Agent read sp001 and confirmed status: idea",
                    "passed": bool(re.search(r"sp001.*idea|idea.*sp001", text, re.I | re.S)),
                    "evidence": "sp001 + idea mentioned"})

    results.append({"text": "Agent re-read us003 acceptance_criteria",
                    "passed": bool(re.search(r"(acceptance.criteria|us003.*AC|AC.*us003|us003.*criteria)", text, re.I)),
                    "evidence": "AC reference present"})

    results.append({"text": "Agent surveyed ft002 as binding feature candidate",
                    "passed": bool(re.search(r"ft002", text, re.I)),
                    "evidence": "ft002 mentioned"})

    adrs = re.findall(r"adr000[12]", text, re.I)
    results.append({"text": "Agent surveyed adr0001 and/or adr0002",
                    "passed": bool(adrs),
                    "evidence": f"adrs: {sorted(set(adrs))}"})

    results.append({"text": "Agent appended ## solution section to sp001",
                    "passed": art["sp001_has_solution"],
                    "evidence": f"has_solution={art['sp001_has_solution']}"})

    body = art["sp001_body"]
    solution_block = re.search(r"##\s*solution\s*$([\s\S]*?)(?=^##|\Z)", body, re.M | re.I)
    if solution_block:
        sol_text = solution_block.group(1)
        link_kinds = {
            "ft": bool(re.search(r"\[\[ft\d{3}", sol_text)),
            "adr": bool(re.search(r"\[\[adr\d{4}", sol_text)),
            "cat": bool(re.search(r"\[\[cat\d{3}", sol_text)),
        }
        present = [k for k, v in link_kinds.items() if v]
        results.append({"text": "## solution carries wikilinks (at least 2 of ft/adr/cat)",
                        "passed": len(present) >= 2,
                        "evidence": f"link kinds: {present}"})
    else:
        results.append({"text": "## solution carries wikilinks (at least 2 of ft/adr/cat)",
                        "passed": False, "evidence": "no ## solution"})

    flipped = art["sp001_status"] == "spec"
    results.append({"text": "sp001 flipped from status: idea to status: spec",
                    "passed": flipped,
                    "evidence": f"status={art['sp001_status']}"})

    board_moved = art["sp001_under_spec"] and not art["sp001_under_idea"]
    results.append({"text": "board.md moved [[sp001]] from ## idea to ## spec",
                    "passed": board_moved,
                    "evidence": f"under_idea={art['sp001_under_idea']} under_spec={art['sp001_under_spec']}"})

    no_plan_tasks = not (bool(re.search(r"^##\s*plan\s*$", body, re.M | re.I)) or bool(re.search(r"^##\s*tasks\s*$", body, re.M | re.I)))
    results.append({"text": "Agent did NOT write ## plan / ## tasks",
                    "passed": no_plan_tasks,
                    "evidence": f"absent={no_plan_tasks}"})

    results.append({"text": "Agent did NOT use bd",
                    "passed": not art["bd_called"],
                    "evidence": f"bd_called={art['bd_called']}"})

    results.append({"text": "Agent did NOT mint a new im###.md (deferred to spec-refinement)",
                    "passed": not art["new_im_files"],
                    "evidence": f"new_im={art['new_im_files']}"})

    results.append({"text": "Agent did NOT modify docs/product.md (out of scope)",
                    "passed": not art["product_modified"],
                    "evidence": f"product_modified={art['product_modified']}"})

    results.append({"text": "Agent did NOT modify us003 (out of scope at this stage)",
                    "passed": not art["us003_modified"],
                    "evidence": f"us003_modified={art['us003_modified']}"})

    return results


def grade_eval1(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    recognized = bool(re.search(r"sp001.*(?:spec|status)|(?:status|spec).*sp001", text, re.I | re.S))
    results.append({"text": "Agent read sp001 and recognized status: spec",
                    "passed": recognized,
                    "evidence": "sp001 + spec"})

    not_re_emitted = (not art["sp001_modified"]) or art["sp001_status"] == "spec"
    results.append({"text": "Agent did NOT re-write / re-emit ## solution",
                    "passed": not_re_emitted,
                    "evidence": f"sp001_modified={art['sp001_modified']} status={art['sp001_status']}"})

    results.append({"text": "Agent did NOT change sp001 status",
                    "passed": art["sp001_status"] == "spec",
                    "evidence": f"status={art['sp001_status']}"})

    results.append({"text": "board.md NOT modified",
                    "passed": (not art["board_modified"]) or (art["sp001_under_spec"] and not art["sp001_under_idea"]),
                    "evidence": f"board_modified={art['board_modified']}"})

    routed = bool(re.search(r"(spec-refinement|already.{0,20}spec|already at spec)", text, re.I))
    results.append({"text": "Output routes to spec-refinement or 'already spec'",
                    "passed": routed,
                    "evidence": "matching phrase"})

    return results


def grade_eval2(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    results.append({"text": "Agent read sp001 + us003 AC",
                    "passed": bool(re.search(r"us003.*(?:AC|acceptance|criteria)|(?:AC|acceptance|criteria).*us003", text, re.I | re.S)),
                    "evidence": "AC reference"})

    vague_detected = bool(re.search(r"(vague|not testable|untestable|unclear|too generic|not measurable|fast enough|it should work|insufficient|unspecified|too thin)", text, re.I))
    results.append({"text": "Agent recognized AC are vague",
                    "passed": vague_detected,
                    "evidence": "vague-language present"})

    no_solution = not art["sp001_has_solution"]
    results.append({"text": "Agent did NOT write ## solution section",
                    "passed": no_solution,
                    "evidence": f"has_solution={art['sp001_has_solution']}"})

    results.append({"text": "Agent did NOT flip sp001 status to spec",
                    "passed": art["sp001_status"] != "spec",
                    "evidence": f"status={art['sp001_status']}"})

    results.append({"text": "docs/board.md NOT modified",
                    "passed": not art["board_modified"],
                    "evidence": f"board_modified={art['board_modified']}"})

    routed_back = bool(re.search(r"(idea-implement|idea-extend|refine.{0,20}AC|block.{0,20}AC|AC.{0,20}refine|route.{0,20}back)", text, re.I))
    results.append({"text": "Output routes back for AC refinement",
                    "passed": routed_back,
                    "evidence": "route-back phrase"})

    return results


def grade_eval3(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    im002_referenced = bool(re.search(r"im002", text, re.I))
    results.append({"text": "Agent found im002 already solves us003",
                    "passed": im002_referenced,
                    "evidence": "im002 mentioned"})

    surfaced = im002_referenced and bool(re.search(r"(duplicate|supersede|existing|already solves|dedup)", text, re.I))
    results.append({"text": "Agent surfaced duplicate (im002 + dedup language)",
                    "passed": surfaced,
                    "evidence": "im002 + dedup-language"})

    if art["sp001_has_solution"]:
        sol_block = re.search(r"##\s*solution\s*$([\s\S]*?)(?=^##|\Z)", art["sp001_body"], re.M | re.I)
        sol_text = sol_block.group(1) if sol_block else ""
        references_im002 = "im002" in sol_text.lower()
        results.append({"text": "Did NOT silently write duplicate solution",
                        "passed": references_im002,
                        "evidence": f"solution_references_im002={references_im002}"})
    else:
        results.append({"text": "Did NOT silently write duplicate solution",
                        "passed": True,
                        "evidence": "no solution written"})

    stopped_or_decided = art["gate_exists"] or art["route_exists"] or (
        art["sp001_has_solution"] and "im002" in art["sp001_body"].lower()
    )
    results.append({"text": "Explicit supersession decision OR stop / user-decision route",
                    "passed": stopped_or_decided,
                    "evidence": f"gate={art['gate_exists']} route={art['route_exists']}"})

    if art["sp001_has_solution"]:
        results.append({"text": "If ## solution written, references [[im002]] as supersession candidate",
                        "passed": "im002" in art["sp001_body"].lower(),
                        "evidence": "im002 in body" if "im002" in art["sp001_body"].lower() else "missing"})
    else:
        results.append({"text": "If ## solution written, references [[im002]] as supersession candidate",
                        "passed": True,
                        "evidence": "no solution"})

    # Scope discipline
    results.append({"text": "Agent did NOT mint a duplicate im###.md (no new im### files)",
                    "passed": not art["new_im_files"],
                    "evidence": f"new_im={art['new_im_files']}"})

    results.append({"text": "Agent did NOT modify docs/product.md (out of scope)",
                    "passed": not art["product_modified"],
                    "evidence": f"product_modified={art['product_modified']}"})

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
