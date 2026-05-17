#!/usr/bin/env python3
"""Grade work-merge iteration outputs against per-eval assertions."""
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


def load_bd(run_dir: Path) -> tuple[list[dict], bool]:
    """Return (issues, parse_ok). parse_ok=False means file present but unparseable."""
    p = run_dir / "outputs" / "bd-list.json"
    if not p.exists():
        return [], False
    raw = p.read_text(errors="ignore")
    # bd may append warning text after JSON. Try greedy balanced [..] extract.
    depth = 0
    end = -1
    for i, ch in enumerate(raw):
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    candidates = ([raw[:end]] if end > 0 else []) + [raw]
    for text in candidates:
        try:
            data = json.loads(text)
            if isinstance(data, dict):
                return data.get("issues") or data.get("data") or [], True
            if isinstance(data, list):
                return data, True
        except json.JSONDecodeError:
            continue
    return [], False


def status_of(path: Path) -> str | None:
    if not path.exists():
        return None
    body = path.read_text(errors="ignore")
    m = re.search(r"^status:\s*(\w+)\s*$", body, re.M)
    return m.group(1) if m else None


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
    sp001_body = sp001.read_text(errors="ignore") if sp001.exists() else ""
    sp001_status = status_of(sp001)
    sp001_footer_archive = bool(re.search(r"^Index:\s*\[\[archive\]\]", sp001_body, re.M))

    us003_status = status_of(sandbox / "docs" / "notes" / "us003.md")
    im002_status = status_of(sandbox / "docs" / "notes" / "im002.md")

    board = sandbox / "docs" / "board.md"
    board_text = board.read_text(errors="ignore") if board.exists() else ""
    ready_section = re.search(r"##\s*ready\b.*?(?=^##|\Z)", board_text, re.S | re.M | re.I)
    sp001_under_ready = bool(ready_section and "sp001" in ready_section.group(0))

    archive = sandbox / "docs" / "archive.md"
    archive_text = archive.read_text(errors="ignore") if archive.exists() else ""
    done_section = re.search(r"##\s*done\b.*", archive_text, re.S | re.I)
    sp001_under_done = bool(done_section and "sp001" in done_section.group(0))

    archive_modified = "docs/archive.md" in modified_paths
    board_modified = "docs/board.md" in modified_paths
    sp001_modified = "docs/notes/spec/sp001.md" in modified_paths
    us003_modified = "docs/notes/us003.md" in modified_paths
    im002_modified = "docs/notes/im002.md" in modified_paths

    bd_issues, bd_parse_ok = load_bd(run_dir)
    epic = next((i for i in bd_issues if (i.get("issue_type") or i.get("type")) == "epic"), None)
    epic_status_from_list = (epic.get("status") if epic else None)
    # Default bd list excludes closed — only infer closed when list parsed AND empty (real signal)
    epic_closed = (epic_status_from_list in ("closed", "done")) or (
        bd_parse_ok and epic is None and len(bd_issues) > 0  # other issues visible but epic gone = closed
    )

    text_all = gather_text(run_dir)
    presented_4_options = bool(re.search(r"(merge.{0,40}locally|push.{0,40}PR|keep.{0,40}as.is|discard).{0,200}(merge.{0,40}locally|push.{0,40}PR|keep.{0,40}as.is|discard)", text_all, re.I | re.S)) or text_all.lower().count("option") >= 3 or sum(1 for kw in ["1. merge", "2. push", "3. keep", "4. discard"] if kw.lower() in text_all.lower()) >= 3

    return {
        "sp001_modified": sp001_modified,
        "sp001_status": sp001_status,
        "sp001_footer_archive": sp001_footer_archive,
        "us003_modified": us003_modified,
        "us003_status": us003_status,
        "im002_modified": im002_modified,
        "im002_status": im002_status,
        "board_modified": board_modified,
        "sp001_under_ready": sp001_under_ready,
        "archive_modified": archive_modified,
        "sp001_under_done": sp001_under_done,
        "epic_closed": epic_closed,
        "presented_4_options": presented_4_options,
        "text_all": text_all,
    }


def grade_eval0(run_dir: Path) -> list[dict]:
    """strong-merge: clean state; full lifecycle flip + git options."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    pytest_ran = bool(re.search(r"(pytest|5 passed|passed in 0\.0|test_vault.*pass)", text, re.I))
    results.append({"text": "Agent ran tests and verified pass",
                    "passed": pytest_ran, "evidence": "pytest evidence"})

    bd_verified = bool(re.search(r"(bd list|all.{0,20}closed|children.{0,20}closed|epic.{0,20}closed|tasks closed)", text, re.I))
    results.append({"text": "Agent verified all bd children closed",
                    "passed": bd_verified, "evidence": "bd-verify language"})

    results.append({"text": "Agent flipped sp001 status from ready to done",
                    "passed": art["sp001_status"] == "done",
                    "evidence": f"status={art['sp001_status']}"})

    results.append({"text": "Agent flipped sp001 footer Index from [[board]] to [[archive]]",
                    "passed": art["sp001_footer_archive"],
                    "evidence": f"footer_archive={art['sp001_footer_archive']}"})

    results.append({"text": "Agent flipped us003 status from ready to done",
                    "passed": art["us003_status"] == "done",
                    "evidence": f"us003_status={art['us003_status']}"})

    results.append({"text": "Agent flipped im002 status from proposed to accepted",
                    "passed": art["im002_status"] == "accepted",
                    "evidence": f"im002_status={art['im002_status']}"})

    results.append({"text": "Agent removed [[sp001]] from docs/board.md ## ready",
                    "passed": art["board_modified"] and not art["sp001_under_ready"],
                    "evidence": f"board_modified={art['board_modified']} under_ready={art['sp001_under_ready']}"})

    results.append({"text": "Agent added [[sp001]] to docs/archive.md ## done",
                    "passed": art["archive_modified"] and art["sp001_under_done"],
                    "evidence": f"archive_modified={art['archive_modified']} under_done={art['sp001_under_done']}"})

    results.append({"text": "Agent closed the bd epic",
                    "passed": art["epic_closed"],
                    "evidence": f"epic_closed={art['epic_closed']}"})

    results.append({"text": "Agent presented the 4 git-landing options (or executed one)",
                    "passed": art["presented_4_options"],
                    "evidence": f"options_presented={art['presented_4_options']}"})

    return results


def grade_block(run_dir: Path, expected_routing_phrase: str, eval_id: int) -> list[dict]:
    """Common shape for the 3 blocking evals."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    if eval_id == 1:
        signal = bool(re.search(r"(task.{0,30}in_progress|task.{0,30}not.{0,20}closed|incomplete.{0,20}children|task.{0,20}2)", text, re.I))
        results.append({"text": "Agent detected Task 2 is still in_progress",
                        "passed": signal, "evidence": "in_progress signal"})
    elif eval_id == 2:
        signal = bool(re.search(r"(test.{0,20}fail|fail.{0,20}test|pytest.{0,30}fail|FAILED|2 failed)", text, re.I))
        results.append({"text": "Agent detected test failures",
                        "passed": signal, "evidence": "test-fail signal"})
    elif eval_id == 3:
        signal = bool(re.search(r"(status.{0,20}spec|sp001.{0,20}spec|not.{0,20}ready|wrong.{0,20}status)", text, re.I))
        results.append({"text": "Agent recognized sp001 not at status: ready",
                        "passed": signal, "evidence": "wrong-status signal"})

    # Check zettel files weren't modified by the agent (more robust than checking status,
    # since seed may pre-flip im002)
    no_zettel_writes = not (art["sp001_modified"] or art["us003_modified"] or art["im002_modified"])
    results.append({"text": "Agent did NOT modify sp001 / us003 / im002 zettels",
                    "passed": no_zettel_writes,
                    "evidence": f"sp_mod={art['sp001_modified']} us_mod={art['us003_modified']} im_mod={art['im002_modified']}"})

    results.append({"text": "Agent did NOT modify docs/board.md",
                    "passed": not art["board_modified"],
                    "evidence": f"board_modified={art['board_modified']}"})

    results.append({"text": "Agent did NOT modify docs/archive.md (sp001 NOT added to ## done)",
                    "passed": not art["sp001_under_done"],
                    "evidence": f"sp001_under_done={art['sp001_under_done']}"})

    results.append({"text": "Agent did NOT close the bd epic",
                    "passed": not art["epic_closed"],
                    "evidence": f"epic_closed={art['epic_closed']}"})

    results.append({"text": f"Output routes back appropriately ({expected_routing_phrase})",
                    "passed": bool(re.search(expected_routing_phrase, text, re.I)),
                    "evidence": "routing phrase present"})

    return results


def grade_eval1(run_dir: Path) -> list[dict]:
    return grade_block(run_dir, r"(work-audit|in_progress|tasks.{0,20}not.{0,20}complete|incomplete)", 1)


def grade_eval2(run_dir: Path) -> list[dict]:
    return grade_block(run_dir, r"(fix.{0,20}test|test.{0,20}fail|blocked.{0,20}test|cannot.{0,20}proceed|pytest.{0,30}fail)", 2)


def grade_eval3(run_dir: Path) -> list[dict]:
    return grade_block(run_dir, r"(spec-refinement|spec-ready|not.{0,20}ready|status.{0,20}spec)", 3)


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
