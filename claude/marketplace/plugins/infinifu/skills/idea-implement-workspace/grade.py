#!/usr/bin/env python3
"""Grade idea-implement iteration outputs against per-eval assertions."""
from __future__ import annotations

import json
import re
import sys
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
    notes = sandbox / "docs" / "notes"
    porcelain = run_dir / "outputs" / "git-status.txt"

    new_paths, modified_paths = [], []
    if porcelain.exists():
        for line in porcelain.read_text(errors="ignore").splitlines():
            line_stripped = line.strip()
            if line.startswith("??") or line.startswith("A ") or line.startswith("AM"):
                new_paths.append(line[3:].strip())
            elif line.startswith(" M") or line.startswith("M ") or line.startswith("MM"):
                modified_paths.append(line[3:].strip())

    new_sp_files = [p for p in new_paths if re.search(r"docs/notes/spec/sp\d{3}\.md", p)]
    new_us_files = [p for p in new_paths if re.search(r"docs/notes/us\d{3}\.md", p)]

    board_changed = any("docs/board.md" in p for p in (new_paths + modified_paths))

    sp_meta = []
    for sp_rel in new_sp_files:
        f = sandbox / sp_rel
        if f.exists():
            body = f.read_text(errors="ignore")
            sp_meta.append({
                "path": sp_rel,
                "has_status_idea": bool(re.search(r"^status:\s*idea\s*$", body, re.M)),
                "has_solves_us003": bool(re.search(r"##\s*solves[\s\S]{0,80}\[\[us003", body, re.I)),
                "has_solves_section": bool(re.search(r"^##\s*solves\s*$", body, re.M | re.I)),
                "has_problem_section": bool(re.search(r"^##\s*problem\s*$", body, re.M | re.I)),
                "body": body,
            })

    us003 = notes / "us003.md"
    us003_status = None
    us003_modified = "docs/notes/us003.md" in modified_paths
    if us003.exists():
        m = re.search(r"^status:\s*(\w+)\s*$", us003.read_text(errors="ignore"), re.M)
        if m:
            us003_status = m.group(1)

    us001 = notes / "us001.md"
    us001_modified = "docs/notes/us001.md" in modified_paths
    us001_status = None
    if us001.exists():
        m = re.search(r"^status:\s*(\w+)\s*$", us001.read_text(errors="ignore"), re.M)
        if m:
            us001_status = m.group(1)

    us002 = notes / "us002.md"
    us002_modified = "docs/notes/us002.md" in modified_paths
    us002_status = None
    if us002.exists():
        m = re.search(r"^status:\s*(\w+)\s*$", us002.read_text(errors="ignore"), re.M)
        if m:
            us002_status = m.group(1)

    us042_exists_in_new = any("us042" in p for p in new_paths)

    gate_exists = (sandbox / "gate_reached.md").exists()
    route_exists = (sandbox / "route_decision.md").exists()

    return {
        "new_sp_files": new_sp_files,
        "new_us_files": new_us_files,
        "board_changed": board_changed,
        "sp_meta": sp_meta,
        "us003_status": us003_status,
        "us003_modified": us003_modified,
        "us002_status": us002_status,
        "us002_modified": us002_modified,
        "us001_status": us001_status,
        "us001_modified": us001_modified,
        "us042_created": us042_exists_in_new,
        "gate_exists": gate_exists,
        "route_exists": route_exists,
    }


def grade_eval0(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    results.append({"text": "Agent read us003 and confirmed status: draft",
                    "passed": bool(re.search(r"us003.*draft|draft.*us003", text, re.I | re.S)),
                    "evidence": "draft + us003 mentioned together" if re.search(r"us003.*draft|draft.*us003", text, re.I | re.S) else "weak"})

    results.append({"text": "Agent surveyed pn002 (persona referenced by us003.role)",
                    "passed": bool(re.search(r"pn002", text, re.I)),
                    "evidence": "pn002 referenced" if re.search(r"pn002", text, re.I) else "missing"})

    cats = re.findall(r"cat\d{3}", text, re.I)
    results.append({"text": "Agent surveyed at least one cat###",
                    "passed": bool(cats),
                    "evidence": f"cats found: {sorted(set(cats))}"})

    adrs = re.findall(r"adr\d{4}", text, re.I)
    results.append({"text": "Agent surveyed at least one adr####",
                    "passed": bool(adrs),
                    "evidence": f"adrs found: {sorted(set(adrs))}"})

    fts = re.findall(r"ft\d{3}", text, re.I)
    results.append({"text": "Agent surveyed at least one ft###",
                    "passed": bool(fts),
                    "evidence": f"ft found: {sorted(set(fts))}"})

    promoted = art["us003_modified"] and art["us003_status"] == "ready"
    results.append({"text": "Agent promoted us003 from draft to ready (file modified, status: ready)",
                    "passed": promoted,
                    "evidence": f"us003_modified={art['us003_modified']} status={art['us003_status']}"})

    sp_ok = bool(art["sp_meta"]) and art["sp_meta"][0]["has_status_idea"]
    results.append({"text": "Agent emitted a new sp###.md under docs/notes/spec/ with status: idea",
                    "passed": sp_ok,
                    "evidence": f"sp_files={art['new_sp_files']} status_idea={sp_ok}"})

    solves_us003 = bool(art["sp_meta"]) and art["sp_meta"][0]["has_solves_us003"]
    results.append({"text": "sp###.md body contains ## solves [[us003]] back-link",
                    "passed": solves_us003,
                    "evidence": f"solves_us003={solves_us003}"})

    if art["sp_meta"]:
        body = art["sp_meta"][0]["body"]
        link_kinds = {
            "us": bool(re.search(r"\[\[us\d{3}", body)),
            "pn": bool(re.search(r"\[\[pn\d{3}", body)),
            "cat": bool(re.search(r"\[\[cat\d{3}", body)),
            "ft": bool(re.search(r"\[\[ft\d{3}", body)),
            "adr": bool(re.search(r"\[\[adr\d{4}", body)),
        }
        present = [k for k, v in link_kinds.items() if v]
        results.append({"text": "sp### ## problem carries wikilinks to at least 3 of: us, pn, cat, ft, adr",
                        "passed": len(present) >= 3,
                        "evidence": f"link kinds present: {present}"})
    else:
        results.append({"text": "sp### ## problem carries wikilinks to at least 3 of: us, pn, cat, ft, adr",
                        "passed": False, "evidence": "no sp### emitted"})

    if art["sp_meta"]:
        sp_id = re.search(r"sp\d{3}", art["sp_meta"][0]["path"]).group(0)
        board_text = (run_dir / "sandbox" / "docs" / "board.md").read_text(errors="ignore")
        idea_section = re.search(r"##\s*idea\b.*?(?=^##|\Z)", board_text, re.S | re.M | re.I)
        has_ref = bool(idea_section and sp_id in idea_section.group(0))
        results.append({"text": "docs/board.md updated with [[sp###]] under ## idea",
                        "passed": has_ref,
                        "evidence": f"sp_id={sp_id} found_under_idea={has_ref}"})
    else:
        results.append({"text": "docs/board.md updated with [[sp###]] under ## idea",
                        "passed": False, "evidence": "no sp### emitted"})

    return results


def grade_eval1(run_dir: Path) -> list[dict]:
    """already-ready-stop: us002 is status: ready, skill should stop."""
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    recognized = bool(re.search(r"us002.*(?:ready|status)|(?:ready|status).*us002", text, re.I | re.S))
    results.append({"text": "Agent read us002 and recognized status: ready",
                    "passed": recognized,
                    "evidence": "us002 + ready mentioned" if recognized else "weak"})

    not_repromoted = not art["us002_modified"]
    results.append({"text": "Agent did NOT re-promote / re-emit us002",
                    "passed": not_repromoted,
                    "evidence": f"us002_modified={art['us002_modified']} status={art['us002_status']}"})

    results.append({"text": "Agent did NOT mint a new sp###.md",
                    "passed": not art["sp_meta"],
                    "evidence": f"sp_count={len(art['sp_meta'])}"})

    results.append({"text": "docs/board.md NOT modified",
                    "passed": not art["board_changed"],
                    "evidence": f"board_changed={art['board_changed']}"})

    explicit = bool(re.search(r"(already ready|already.{0,20}ready|spec-writing|nothing to promote|already.{0,20}status:?\s*ready)", text, re.I))
    results.append({"text": "Output explicitly states us002 is already ready (or routes to spec-writing)",
                    "passed": explicit,
                    "evidence": "matching phrase present" if explicit else "missing"})

    return results


def grade_eval2(run_dir: Path) -> list[dict]:
    """done-story-reject: us001 is status: done, skill should route to idea-extend."""
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    recognized = bool(re.search(r"us001.*done|done.*us001", text, re.I | re.S))
    results.append({"text": "Agent read us001 and recognized status: done",
                    "passed": recognized,
                    "evidence": "us001 + done mentioned" if recognized else "weak"})

    not_repromoted = not art["us001_modified"]
    results.append({"text": "Agent did NOT re-promote / re-emit us001",
                    "passed": not_repromoted,
                    "evidence": f"us001_modified={art['us001_modified']} status={art['us001_status']}"})

    results.append({"text": "Agent did NOT mint a new sp###.md",
                    "passed": not art["sp_meta"],
                    "evidence": f"sp_count={len(art['sp_meta'])}"})

    results.append({"text": "docs/board.md NOT modified",
                    "passed": not art["board_changed"],
                    "evidence": f"board_changed={art['board_changed']}"})

    routed = bool(re.search(r"(idea-extend|cannot promote done|done.{0,20}story|use idea-extend|route to extend)", text, re.I))
    results.append({"text": "Output routes to idea-extend OR explicitly states done story can't be promoted",
                    "passed": routed,
                    "evidence": "matching phrase present" if routed else "missing"})

    return results


def grade_eval3(run_dir: Path) -> list[dict]:
    """missing-story-reject: us042 doesn't exist, skill should route to story-write."""
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    recognized = bool(re.search(r"us042.*(?:not exist|missing|does not|no such|doesn't exist)", text, re.I | re.S))
    results.append({"text": "Agent verified us042 does not exist",
                    "passed": recognized,
                    "evidence": "missing-language phrase present" if recognized else "weak"})

    not_created = not art["us042_created"]
    results.append({"text": "Agent did NOT invent / write a new us042.md",
                    "passed": not_created,
                    "evidence": f"us042_created={art['us042_created']}"})

    results.append({"text": "Agent did NOT mint a new sp###.md",
                    "passed": not art["sp_meta"],
                    "evidence": f"sp_count={len(art['sp_meta'])}"})

    results.append({"text": "docs/board.md NOT modified",
                    "passed": not art["board_changed"],
                    "evidence": f"board_changed={art['board_changed']}"})

    routed = bool(re.search(r"(story-write|create.{0,30}story|create.{0,30}draft|first.{0,30}story|fresh.{0,20}story)", text, re.I))
    results.append({"text": "Output routes to story-write OR states 'create story first'",
                    "passed": routed,
                    "evidence": "matching phrase present" if routed else "missing"})

    return results


def grade_eval4(run_dir: Path) -> list[dict]:
    """vague-ac-gate: us004 is draft with vague AC. Skill must hold gate, not promote."""
    text = gather_text(run_dir)
    sandbox = run_dir / "sandbox"
    notes = sandbox / "docs" / "notes"

    porcelain = (run_dir / "outputs" / "git-status.txt")
    new_paths, modified_paths = [], []
    if porcelain.exists():
        for line in porcelain.read_text(errors="ignore").splitlines():
            if line.startswith("??") or line.startswith("A ") or line.startswith("AM"):
                new_paths.append(line[3:].strip())
            elif line.startswith(" M") or line.startswith("M ") or line.startswith("MM"):
                modified_paths.append(line[3:].strip())
    new_sp_files = [p for p in new_paths if re.search(r"docs/notes/spec/sp\d{3}\.md", p)]
    board_changed = any("docs/board.md" in p for p in (new_paths + modified_paths))
    us004 = notes / "us004.md"
    us004_status = None
    us004_modified = "docs/notes/us004.md" in modified_paths
    if us004.exists():
        m = re.search(r"^status:\s*(\w+)\s*$", us004.read_text(errors="ignore"), re.M)
        us004_status = m.group(1) if m else None
    gate_exists = (sandbox / "gate_reached.md").exists()

    results = []

    recognized_draft = bool(re.search(r"us004.*draft|draft.*us004", text, re.I | re.S))
    results.append({"text": "Agent read us004 and confirmed status: draft",
                    "passed": recognized_draft,
                    "evidence": "us004 + draft mentioned" if recognized_draft else "weak"})

    vague_detected = bool(re.search(r"(vague|not testable|untestable|unclear|too generic|not measurable|fast enough|it works|too thin|insufficient|unspecified)", text, re.I))
    results.append({"text": "Agent recognized AC are vague / not testable",
                    "passed": vague_detected,
                    "evidence": "vague-language phrase present" if vague_detected else "missing"})

    not_promoted = not us004_modified or us004_status == "draft"
    results.append({"text": "Agent did NOT promote us004 to status: ready",
                    "passed": not_promoted,
                    "evidence": f"us004_modified={us004_modified} status={us004_status}"})

    results.append({"text": "Agent did NOT mint a new sp###.md",
                    "passed": not new_sp_files,
                    "evidence": f"sp_files={new_sp_files}"})

    results.append({"text": "docs/board.md NOT modified",
                    "passed": not board_changed,
                    "evidence": f"board_changed={board_changed}"})

    gate_signal = gate_exists or bool(re.search(r"(gate|clarifying question|cannot promote|hold the gate|design-approval|ask the user)", text, re.I))
    results.append({"text": "Agent hit the gate (gate_reached.md OR explicit gate-language)",
                    "passed": gate_signal,
                    "evidence": f"gate_reached={gate_exists} gate-language={bool(re.search(r'(gate|clarifying|cannot promote)', text, re.I))}"})

    return results


def grade_eval5(run_dir: Path) -> list[dict]:
    """persona-missing: us005 references pn999 (not present). Skill must mint persona or stop."""
    text = gather_text(run_dir)
    sandbox = run_dir / "sandbox"
    notes = sandbox / "docs" / "notes"

    porcelain = (run_dir / "outputs" / "git-status.txt")
    new_paths, modified_paths = [], []
    if porcelain.exists():
        for line in porcelain.read_text(errors="ignore").splitlines():
            if line.startswith("??") or line.startswith("A ") or line.startswith("AM"):
                new_paths.append(line[3:].strip())
            elif line.startswith(" M") or line.startswith("M ") or line.startswith("MM"):
                modified_paths.append(line[3:].strip())
    new_sp_files = [p for p in new_paths if re.search(r"docs/notes/spec/sp\d{3}\.md", p)]
    new_pn_files = [p for p in new_paths if re.search(r"docs/notes/pn\d{3}\.md", p)]
    us005_modified = "docs/notes/us005.md" in modified_paths
    us005 = notes / "us005.md"
    us005_status = None
    if us005.exists():
        m = re.search(r"^status:\s*(\w+)\s*$", us005.read_text(errors="ignore"), re.M)
        us005_status = m.group(1) if m else None
    gate_exists = (sandbox / "gate_reached.md").exists()
    route_exists = (sandbox / "route_decision.md").exists()

    results = []

    recognized_draft = bool(re.search(r"us005.*draft|draft.*us005", text, re.I | re.S))
    results.append({"text": "Agent read us005 and confirmed status: draft",
                    "passed": recognized_draft,
                    "evidence": "us005 + draft" if recognized_draft else "weak"})

    persona_missing_flagged = bool(re.search(r"(pn999.*(?:not exist|missing|does not|no such|doesn't exist|isn't|absent))|((?:not exist|missing).*pn999)", text, re.I | re.S))
    results.append({"text": "Agent identified pn999 (compliance-officer) is missing",
                    "passed": persona_missing_flagged,
                    "evidence": "pn999 + missing-language phrase" if persona_missing_flagged else "missing"})

    not_promoted_early = (not us005_modified) or us005_status == "draft" or new_pn_files
    results.append({"text": "Agent did NOT promote us005 to ready before pn### is in place",
                    "passed": not_promoted_early,
                    "evidence": f"us005_modified={us005_modified} status={us005_status} new_pn={new_pn_files}"})

    persona_action = bool(new_pn_files) or gate_exists or route_exists or bool(re.search(r"(persona-write|mint.{0,20}persona|create.{0,20}pn\d{3}|need.{0,20}persona)", text, re.I))
    results.append({"text": "Agent minted persona OR routed to persona-write OR hit gate requesting mint",
                    "passed": persona_action,
                    "evidence": f"new_pn={new_pn_files} gate={gate_exists} route={route_exists}"})

    not_silent = persona_missing_flagged or new_pn_files or gate_exists or route_exists
    results.append({"text": "Agent did NOT silently proceed past the missing-persona gap",
                    "passed": not_silent,
                    "evidence": "missing-persona acknowledged" if not_silent else "silent proceed"})

    # Persona-mint acknowledged before sp### emission
    if new_sp_files and not (new_pn_files or gate_exists or route_exists):
        results.append({"text": "Persona-mint is acknowledged before any sp###.md emission",
                        "passed": False, "evidence": "sp### emitted but no persona-action signal"})
    else:
        results.append({"text": "Persona-mint is acknowledged before any sp###.md emission",
                        "passed": True,
                        "evidence": f"sp_count={len(new_sp_files)} new_pn={new_pn_files} gate={gate_exists} route={route_exists}"})

    return results


GRADERS = {0: grade_eval0, 1: grade_eval1, 2: grade_eval2, 3: grade_eval3, 4: grade_eval4, 5: grade_eval5}


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
