#!/usr/bin/env python3
"""Grade idea-feature iteration outputs against per-eval assertions.

For each eval_metadata.json under iteration-<N>/, examine the with_skill and
without_skill runs (outputs/ + sandbox/) and produce grading.json with the
viewer-expected schema: {"expectations": [{"text", "passed", "evidence"}], ...}.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def gather_text(run_dir: Path) -> str:
    """Concatenate all relevant text from a run's outputs + sandbox edits."""
    blobs: list[str] = []
    outputs = run_dir / "outputs"
    sandbox = run_dir / "sandbox"

    # outputs/run_notes.md, outputs/git-diff.patch, outputs/git-status.txt
    for f in [
        outputs / "run_notes.md",
        outputs / "git-diff.patch",
        outputs / "git-status.txt",
    ]:
        if f.exists():
            blobs.append(f.read_text(errors="ignore"))

    # Anything under outputs/new-files or outputs/modified-files
    for sub in ("new-files", "modified-files"):
        d = outputs / sub
        if d.is_dir():
            for p in d.rglob("*"):
                if p.is_file():
                    blobs.append(p.read_text(errors="ignore"))

    # Top-level signal files written into sandbox root
    for name in ("gate_reached.md", "route_decision.md"):
        f = sandbox / name
        if f.exists():
            blobs.append(f.read_text(errors="ignore"))

    return "\n".join(blobs)


def gather_artifacts(run_dir: Path) -> dict:
    """Return artifact-level facts about the run."""
    sandbox = run_dir / "sandbox"
    notes = sandbox / "docs" / "notes"
    spec_dir = notes / "spec"
    board = sandbox / "docs" / "board.md"

    # New files via git porcelain
    porcelain = (run_dir / "outputs" / "git-status.txt")
    new_paths: list[str] = []
    if porcelain.exists():
        for line in porcelain.read_text(errors="ignore").splitlines():
            if line.startswith("?? ") or line.startswith("A  ") or line.startswith("AM "):
                new_paths.append(line[3:].strip())

    new_sp_files = [p for p in new_paths if re.search(r"docs/notes/spec/sp\d{3}\.md", p)]
    new_ft_files = [p for p in new_paths if re.search(r"docs/notes/ft\d{3}\.md", p)]
    new_us_files = [p for p in new_paths if re.search(r"docs/notes/us\d{3}\.md", p)]
    new_im_files = [p for p in new_paths if re.search(r"docs/notes/im\d{3}\.md", p)]

    board_changed = False
    if porcelain.exists():
        for line in porcelain.read_text(errors="ignore").splitlines():
            if "docs/board.md" in line and not line.startswith("?? "):
                board_changed = True

    sp_meta = []
    for sp_rel in new_sp_files:
        f = sandbox / sp_rel
        if f.exists():
            body = f.read_text(errors="ignore")
            sp_meta.append({
                "path": sp_rel,
                "has_status_idea": bool(re.search(r"^status:\s*idea\s*$", body, re.M)),
                "has_problem_section": bool(re.search(r"^##\s*problem\s*$", body, re.M | re.I)),
                "body": body,
            })

    gate_exists = (sandbox / "gate_reached.md").exists()
    route_exists = (sandbox / "route_decision.md").exists()

    return {
        "new_sp_files": new_sp_files,
        "new_ft_files": new_ft_files,
        "new_us_files": new_us_files,
        "new_im_files": new_im_files,
        "board_changed": board_changed,
        "sp_meta": sp_meta,
        "gate_exists": gate_exists,
        "route_exists": route_exists,
    }


def has_any(text: str, *needles: str) -> tuple[bool, str]:
    hits = [n for n in needles if re.search(rf"\b{re.escape(n)}\b", text, re.I)]
    return bool(hits), ", ".join(hits) if hits else "(no match)"


def has_any_phrase(text: str, *patterns: str) -> tuple[bool, str]:
    hits = [p for p in patterns if re.search(p, text, re.I)]
    return bool(hits), ", ".join(hits) if hits else "(no match)"


def grade_eval0(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)

    results = []

    # 1: references ft001/ft002
    ok, ev = has_any(text, "ft001", "ft002")
    results.append({"text": "Agent surveyed existing features — output references ft001 and/or ft002 explicitly",
                    "passed": ok, "evidence": f"matches: {ev}"})

    # 2: cat003 or cat004
    ok, ev = has_any(text, "cat003", "cat004")
    results.append({"text": "Agent picked a real existing category — references cat003 or cat004",
                    "passed": ok, "evidence": f"matches: {ev}"})

    # 3: at least 2 of auth/metrics/reports
    consumers = [c for c in ("auth", "metrics", "reports") if re.search(rf"\b{c}\b", text, re.I)]
    results.append({"text": "Agent identified concrete consumers — names at least 2 of auth/metrics/reports",
                    "passed": len(consumers) >= 2, "evidence": f"consumers found: {consumers}"})

    # 4: adr0003
    ok, ev = has_any(text, "adr0003")
    results.append({"text": "Agent surfaced migration target adr0003 (ad-hoc smtplib decision)",
                    "passed": ok, "evidence": f"matches: {ev}"})

    # 5: no new ft### file
    results.append({"text": "Agent did NOT mint a new ft###.md (skill rule — ft### only at spec-writing)",
                    "passed": not art["new_ft_files"], "evidence": f"new ft files: {art['new_ft_files']}"})

    # 6: sp###.md emission shape (if any)
    if art["sp_meta"]:
        sp = art["sp_meta"][0]
        good = sp["path"].startswith("docs/notes/spec/") and sp["has_status_idea"] and sp["has_problem_section"]
        results.append({"text": "If sp###.md was emitted: docs/notes/spec/, status: idea, body has ## problem",
                        "passed": good,
                        "evidence": f"path={sp['path']} status_idea={sp['has_status_idea']} problem={sp['has_problem_section']}"})
    else:
        results.append({"text": "If sp###.md was emitted: docs/notes/spec/, status: idea, body has ## problem",
                        "passed": True, "evidence": "no sp### emitted (vacuously true)"})

    # 7: board.md updated with sp### reference under ## idea
    if art["sp_meta"]:
        board_text = (run_dir / "sandbox" / "docs" / "board.md").read_text(errors="ignore")
        sp_id = re.search(r"sp\d{3}", art["sp_meta"][0]["path"]).group(0)
        idea_section = re.search(r"##\s*idea\b.*?(?=^##|\Z)", board_text, re.S | re.M | re.I)
        has_ref = bool(idea_section and sp_id in idea_section.group(0))
        results.append({"text": "docs/board.md updated with [[sp###]] reference under ## idea",
                        "passed": has_ref, "evidence": f"sp_id={sp_id} found_under_idea={has_ref}"})
    else:
        results.append({"text": "docs/board.md updated with [[sp###]] reference under ## idea",
                        "passed": True, "evidence": "no sp### emitted (vacuously true)"})

    # 8: granularity question raised
    ok, ev = has_any_phrase(text, r"\bsplit\b", r"\bdecompose\b", r"\bdecomposition\b",
                            r"\bmultiple features?\b", r"\batomic\b", r"\bgranular(?:ity)?\b",
                            r"\brouter\b.*\btransport", r"\bone feature\b")
    results.append({"text": "Agent raised the granularity question (one notif feature vs router+transport split)",
                    "passed": ok, "evidence": f"phrases: {ev}"})

    # 9: wikilink reference discipline in sp### body
    if art["sp_meta"]:
        body = art["sp_meta"][0]["body"]
        link_kinds = {
            "ft": bool(re.search(r"\[\[ft\d{3}", body)),
            "im": bool(re.search(r"\[\[im\d{3}", body)),
            "cat": bool(re.search(r"\[\[cat\d{3}", body)),
            "adr": bool(re.search(r"\[\[adr\d{4}", body)),
        }
        present = [k for k, v in link_kinds.items() if v]
        results.append({"text": "sp### ## problem carries wikilink references to surveyed ids (ft/im/cat/adr) — at least 3 kinds present",
                        "passed": len(present) >= 3,
                        "evidence": f"link kinds present: {present}"})
    else:
        results.append({"text": "sp### ## problem carries wikilink references to surveyed ids (ft/im/cat/adr) — at least 3 kinds present",
                        "passed": True, "evidence": "no sp### emitted (vacuously true)"})

    return results


def grade_eval1(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    ok, ev = has_any(text, "ft001")
    results.append({"text": "Agent surveyed ft001 (basic-auth)", "passed": ok, "evidence": ev})

    ok, ev = has_any(text, "adr0001")
    results.append({"text": "Agent surveyed adr0001", "passed": ok, "evidence": ev})

    # Used adr0001 to drive routing — look for adr0001 + (new feature / not extend / external SSO)
    drove = bool(re.search(r"adr0001", text, re.I)) and bool(
        re.search(r"(new feature|not extending|external sso|sibling feature|requires? a new)", text, re.I))
    results.append({"text": "Agent used adr0001 to drive the routing decision (genuine new-feature ask, not extend)",
                    "passed": drove, "evidence": "adr0001 + new-feature phrase match" if drove else "weak signal"})

    ok, ev = has_any(text, "cat001", "cat003")
    results.append({"text": "Agent identified a real category — cat001 or cat003",
                    "passed": ok, "evidence": ev})

    # Stopped at gate OR no sp### emitted
    stopped = art["gate_exists"] or not art["sp_meta"]
    results.append({"text": "Agent stopped at design-approval gate (gate_reached.md exists OR no sp###.md)",
                    "passed": stopped,
                    "evidence": f"gate_reached={art['gate_exists']} sp_count={len(art['sp_meta'])}"})

    results.append({"text": "Agent did NOT mint a new ft###.md",
                    "passed": not art["new_ft_files"], "evidence": f"new ft: {art['new_ft_files']}"})

    if art["sp_meta"]:
        sp = art["sp_meta"][0]
        good = sp["path"].startswith("docs/notes/spec/") and sp["has_status_idea"] and sp["has_problem_section"]
        results.append({"text": "If sp###.md was emitted: docs/notes/spec/, status: idea, has ## problem",
                        "passed": good,
                        "evidence": f"path={sp['path']} status_idea={sp['has_status_idea']} problem={sp['has_problem_section']}"})
    else:
        results.append({"text": "If sp###.md was emitted: docs/notes/spec/, status: idea, has ## problem",
                        "passed": True, "evidence": "no sp### emitted"})

    return results


def grade_eval2(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    ok, ev = has_any(text, "pn002")
    results.append({"text": "Agent identified pn002 (platform-engineer) as the single plausible consumer",
                    "passed": ok, "evidence": ev})

    # Concludes single-consumer → re-route to idea-implement
    routed = bool(re.search(r"idea-implement", text, re.I)) and bool(
        re.search(r"(single consumer|one consumer|one story|im### glue|not a feature|not.{0,20}feature)", text, re.I))
    results.append({"text": "Agent concluded single-consumer and re-routed to idea-implement",
                    "passed": routed, "evidence": "idea-implement + single-consumer language" if routed else "weak"})

    # route_decision.md exists OR run_notes mentions idea-implement
    notes = (run_dir / "outputs" / "run_notes.md")
    notes_text = notes.read_text(errors="ignore") if notes.exists() else ""
    explicit = art["route_exists"] or "idea-implement" in notes_text.lower()
    results.append({"text": "route_decision.md exists OR run_notes.md explicitly states idea-implement",
                    "passed": explicit,
                    "evidence": f"route_decision={art['route_exists']} notes_mentions={('idea-implement' in notes_text.lower())}"})

    results.append({"text": "Agent did NOT emit a new sp###.md under docs/notes/spec/",
                    "passed": not art["sp_meta"], "evidence": f"sp_count={len(art['sp_meta'])}"})

    results.append({"text": "docs/board.md NOT modified",
                    "passed": not art["board_changed"], "evidence": f"board_changed={art['board_changed']}"})

    results.append({"text": "Agent did NOT mint a new ft###.md",
                    "passed": not art["new_ft_files"], "evidence": f"new ft: {art['new_ft_files']}"})

    return results


def grade_eval3(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    # 1: 3+ distinct capabilities named
    caps = [c for c in ("metrics", "logging", "tracing", "alerting", "dashboards") if re.search(rf"\b{c}\b", text, re.I)]
    results.append({"text": "Agent identified at least 3 distinct capabilities (metrics/logging/tracing/alerting/dashboards)",
                    "passed": len(caps) >= 3, "evidence": f"capabilities found: {caps}"})

    # 2: granularity flagged
    ok, ev = has_any_phrase(text, r"\bsplit\b", r"\bdecompose\b", r"\bdecomposition\b",
                            r"\bgranular(?:ity)?\b", r"\bmultiple features?\b", r"\batomic\b",
                            r"\btoo coarse\b", r"\bone feature\b")
    results.append({"text": "Agent explicitly flagged the granularity problem",
                    "passed": ok, "evidence": f"phrases: {ev}"})

    # 3: cat003 or cat004
    ok, ev = has_any(text, "cat003", "cat004")
    results.append({"text": "Agent surveyed real categories — cat003 or cat004",
                    "passed": ok, "evidence": ev})

    # 4: if sp### emitted, ## problem names multiple sub-capabilities
    if art["sp_meta"]:
        sp_body = art["sp_meta"][0]["body"]
        sub_caps = [c for c in ("metrics", "logging", "tracing", "alerting", "dashboards") if re.search(rf"\b{c}\b", sp_body, re.I)]
        results.append({"text": "If sp###.md emitted: ## problem names multiple sub-capabilities (non-monolithic)",
                        "passed": len(sub_caps) >= 3, "evidence": f"caps in sp body: {sub_caps}"})
    else:
        results.append({"text": "If sp###.md emitted: ## problem names multiple sub-capabilities (non-monolithic)",
                        "passed": True, "evidence": "no sp### emitted"})

    # 5: no new ft###
    results.append({"text": "Agent did NOT silently mint a new ft###.md spanning all capabilities",
                    "passed": not art["new_ft_files"], "evidence": f"new ft: {art['new_ft_files']}"})

    # 6: proposes split or asks split-question
    proposes_split = bool(re.search(r"(split|decompose|multiple features?|3-5|3-feature|5 features?|two-step)", text, re.I))
    results.append({"text": "Agent proposes splitting into multiple sp###/features OR surfaces split-question",
                    "passed": proposes_split,
                    "evidence": "split/decompose language present" if proposes_split else "absent"})

    # 7: wikilink reference discipline in sp### body
    if art["sp_meta"]:
        body = art["sp_meta"][0]["body"]
        link_kinds = {
            "ft": bool(re.search(r"\[\[ft\d{3}", body)),
            "im": bool(re.search(r"\[\[im\d{3}", body)),
            "cat": bool(re.search(r"\[\[cat\d{3}", body)),
            "adr": bool(re.search(r"\[\[adr\d{4}", body)),
        }
        present = [k for k, v in link_kinds.items() if v]
        results.append({"text": "sp### body carries wikilink references to surveyed ids — at least 2 kinds present",
                        "passed": len(present) >= 2,
                        "evidence": f"link kinds present: {present}"})
    else:
        results.append({"text": "sp### body carries wikilink references to surveyed ids — at least 2 kinds present",
                        "passed": True, "evidence": "no sp### emitted"})

    return results


def grade_eval4(run_dir: Path) -> list[dict]:
    text = gather_text(run_dir)
    art = gather_artifacts(run_dir)
    results = []

    ok, ev = has_any(text, "ft002")
    results.append({"text": "Agent ran the dedup check — references ft002 (vault-secrets) by id",
                    "passed": ok, "evidence": ev})

    # Recognized ft002 covers the surface
    recognized = bool(re.search(r"ft002", text, re.I)) and bool(
        re.search(r"(already (provides|exists|covers)|duplicate|dedup|same capability|exact(?:ly)? what|covers this)", text, re.I))
    results.append({"text": "Agent recognized ft002 already provides this capability",
                    "passed": recognized,
                    "evidence": "ft002 + dedup-language match" if recognized else "weak/missing"})

    # Re-routed to idea-extend on ft002
    routed = bool(re.search(r"idea-extend", text, re.I)) and bool(re.search(r"ft002", text, re.I))
    results.append({"text": "Agent re-routed to idea-extend on ft002",
                    "passed": (routed or art["route_exists"]),
                    "evidence": f"idea-extend+ft002 in text={routed} route_decision={art['route_exists']}"})

    results.append({"text": "Agent did NOT emit a new sp###.md under docs/notes/spec/",
                    "passed": not art["sp_meta"], "evidence": f"sp_count={len(art['sp_meta'])}"})

    results.append({"text": "docs/board.md NOT modified",
                    "passed": not art["board_changed"], "evidence": f"board_changed={art['board_changed']}"})

    results.append({"text": "Agent did NOT mint a new ft###.md",
                    "passed": not art["new_ft_files"], "evidence": f"new ft: {art['new_ft_files']}"})

    return results


GRADERS = {
    0: grade_eval0,
    1: grade_eval1,
    2: grade_eval2,
    3: grade_eval3,
    4: grade_eval4,
}


def main(iter_dir: Path):
    eval_dirs = sorted([d for d in iter_dir.iterdir() if d.is_dir() and d.name.startswith("eval-")])
    for ed in eval_dirs:
        meta_file = ed / "eval_metadata.json"
        if not meta_file.exists():
            print(f"skip {ed.name} — no eval_metadata.json")
            continue
        meta = json.loads(meta_file.read_text())
        eid = meta["eval_id"]
        grader = GRADERS.get(eid)
        if not grader:
            print(f"skip {ed.name} — no grader for eval_id {eid}")
            continue
        for cfg in ("with_skill", "without_skill"):
            run_dir = ed / cfg
            if not run_dir.exists():
                continue
            results = grader(run_dir)
            passed = sum(1 for r in results if r["passed"])
            total = len(results)
            pass_rate = passed / total if total else 0.0

            # Schema the aggregator expects: summary{}, expectations[], plus run-1/ layout.
            run1 = run_dir / "run-1"
            run1.mkdir(exist_ok=True)

            grading = {
                "eval_id": eid,
                "eval_name": meta["eval_name"],
                "config": cfg,
                "summary": {
                    "pass_rate": pass_rate,
                    "passed": passed,
                    "failed": total - passed,
                    "total": total,
                },
                "expectations": results,
            }
            (run1 / "grading.json").write_text(json.dumps(grading, indent=2))

            # Mirror timing into run-1/ for the aggregator.
            src_timing = run_dir / "timing.json"
            if src_timing.exists():
                (run1 / "timing.json").write_text(src_timing.read_text())

            print(f"{ed.name}/{cfg}: {passed}/{total} ({pass_rate*100:.0f}%)")


if __name__ == "__main__":
    iter_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "iteration-1"
    main(iter_dir.resolve())
