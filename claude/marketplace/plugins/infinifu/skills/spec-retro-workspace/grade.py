#!/usr/bin/env python3
"""Grade spec-retro iteration outputs against per-eval assertions."""
from __future__ import annotations
import json, re, sys
from pathlib import Path


def gather_text(run_dir: Path) -> str:
    blobs: list[str] = []
    outputs = run_dir / "outputs"
    sandbox = run_dir / "sandbox"
    for f in [outputs / "run_notes.md", outputs / "git-diff.patch", outputs / "git-status.txt",
              outputs / "bd-show-epic.txt"]:
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
    p = run_dir / "outputs" / "bd-list.json"
    if not p.exists():
        return [], False
    raw = p.read_text(errors="ignore")
    depth = 0; end = -1
    for i, ch in enumerate(raw):
        if ch == "[": depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    for text in ([raw[:end]] if end > 0 else []) + [raw]:
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
    if not path.exists(): return None
    m = re.search(r"^status:\s*(\w+)\s*$", path.read_text(errors="ignore"), re.M)
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

    sp001_status = status_of(sandbox / "docs" / "notes" / "spec" / "sp001.md")
    us003_status = status_of(sandbox / "docs" / "notes" / "us003.md")
    im002_status = status_of(sandbox / "docs" / "notes" / "im002.md")

    sp001_modified = "docs/notes/spec/sp001.md" in modified_paths
    us003_modified = "docs/notes/us003.md" in modified_paths
    im002_modified = "docs/notes/im002.md" in modified_paths
    ft002_modified = "docs/notes/ft002.md" in modified_paths
    board_modified = "docs/board.md" in modified_paths
    archive_modified = "docs/archive.md" in modified_paths

    new_us_files = [p for p in new_paths if re.search(r"docs/notes/us\d{3}\.md", p)]
    new_adr_files = [p for p in new_paths if re.search(r"docs/notes/adr\d{4}\.md", p)]

    # Check newly drafted us### has status: draft
    new_us_drafts = []
    for p in new_us_files:
        full = sandbox / p
        if full.exists() and "status: draft" in full.read_text(errors="ignore"):
            new_us_drafts.append(p)

    bd_issues, bd_parse_ok = load_bd(run_dir)
    # Epic status — bd list default excludes closed; use bd-show-epic.txt as fallback
    epic = next((i for i in bd_issues if (i.get("issue_type") or i.get("type")) == "epic"), None)
    epic_status = (epic.get("status") if epic else None)
    bd_show_epic = run_dir / "outputs" / "bd-show-epic.txt"
    if bd_show_epic.exists():
        show_text = bd_show_epic.read_text(errors="ignore")
        if epic_status is None:
            if "CLOSED" in show_text:
                epic_status = "closed"
            elif "OPEN" in show_text:
                epic_status = "open"

    text_all = gather_text(run_dir)

    return {
        "sp001_status": sp001_status,
        "us003_status": us003_status,
        "im002_status": im002_status,
        "sp001_modified": sp001_modified,
        "us003_modified": us003_modified,
        "im002_modified": im002_modified,
        "ft002_modified": ft002_modified,
        "board_modified": board_modified,
        "archive_modified": archive_modified,
        "new_us_files": new_us_files,
        "new_us_drafts": new_us_drafts,
        "new_adr_files": new_adr_files,
        "epic_status": epic_status,
        "text_all": text_all,
    }


def grade_eval0(run_dir: Path) -> list[dict]:
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    git_used = bool(re.search(r"(git log|git diff|merge-base|HEAD)", text, re.I))
    results.append({"text": "Agent ran git log / git diff for shipped reality",
                    "passed": git_used, "evidence": "git command in text"})

    surveyed = all(kw in text for kw in ["im002"]) and bool(re.search(r"(ft002|adr000[12]|bd show|bd list)", text, re.I))
    results.append({"text": "Agent read im002 + ft002 + adr + bd notes",
                    "passed": surveyed, "evidence": "context-survey present"})

    results.append({"text": "Agent rewrote im002 body",
                    "passed": art["im002_modified"], "evidence": f"im002_modified={art['im002_modified']}"})

    results.append({"text": "Agent updated ft002 (widen api_surface)",
                    "passed": art["ft002_modified"], "evidence": f"ft002_modified={art['ft002_modified']}"})

    results.append({"text": "Agent drafted new us### at status: draft for follow-up",
                    "passed": len(art["new_us_drafts"]) >= 1,
                    "evidence": f"new_us_drafts={art['new_us_drafts']}"})

    results.append({"text": "Agent closed the bd epic",
                    "passed": art["epic_status"] in ("closed", "done"),
                    "evidence": f"epic_status={art['epic_status']}"})

    results.append({"text": "Agent did NOT touch docs/board.md or docs/archive.md",
                    "passed": not (art["board_modified"] or art["archive_modified"]),
                    "evidence": f"board_mod={art['board_modified']} archive_mod={art['archive_modified']}"})

    no_status_flips = not (art["sp001_modified"] and art["sp001_status"] != "done") \
                      and not (art["us003_modified"] and art["us003_status"] != "done") \
                      and (art["im002_status"] in ("accepted", None))
    results.append({"text": "Agent did NOT change sp001/us003/im002 frontmatter status",
                    "passed": no_status_flips,
                    "evidence": f"sp={art['sp001_status']} us={art['us003_status']} im={art['im002_status']}"})

    return results


def grade_eval1(run_dir: Path) -> list[dict]:
    """already-closed-epic: epic CLOSED before skill runs."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    detected = bool(re.search(r"(already.{0,20}closed|prior retro|epic.{0,20}closed|previously.{0,20}closed)", text, re.I))
    results.append({"text": "Agent detected epic already closed",
                    "passed": detected, "evidence": "already-closed phrase"})

    # Epic stays closed (didn't try to re-close or reopen)
    results.append({"text": "Agent did NOT re-close (or reopen) the epic",
                    "passed": art["epic_status"] in ("closed", "done"),
                    "evidence": f"epic_status={art['epic_status']}"})

    no_writes = not (art["im002_modified"] or art["ft002_modified"] or len(art["new_us_files"]) > 0 or len(art["new_adr_files"]) > 0)
    results.append({"text": "Agent did NOT rewrite im002 / mint new us / adr / ft updates",
                    "passed": no_writes,
                    "evidence": f"im_mod={art['im002_modified']} ft_mod={art['ft002_modified']} new_us={len(art['new_us_files'])} new_adr={len(art['new_adr_files'])}"})

    routed = bool(re.search(r"(already.{0,20}closed|already.{0,20}ran|retro.{0,20}ran|prior.{0,20}retro)", text, re.I))
    results.append({"text": "Output explicitly states 'already closed' / 'retro already ran'",
                    "passed": routed, "evidence": "no-op phrase"})

    results.append({"text": "Agent did NOT touch docs/board.md or docs/archive.md",
                    "passed": not (art["board_modified"] or art["archive_modified"]),
                    "evidence": f"board={art['board_modified']} archive={art['archive_modified']}"})

    return results


def grade_eval2(run_dir: Path) -> list[dict]:
    """wrong-status-ready: sp001 not at status:done. Route back to work-merge."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    detected = bool(re.search(r"(status.{0,20}ready|not.{0,20}done|sp001.{0,20}ready|work-merge.{0,20}didn't)", text, re.I))
    results.append({"text": "Agent recognized sp001 status is ready (not done)",
                    "passed": detected, "evidence": "status-ready phrase"})

    no_writes = not (art["im002_modified"] or art["ft002_modified"] or len(art["new_us_files"]) > 0 or len(art["new_adr_files"]) > 0)
    results.append({"text": "Agent did NOT rewrite im002 / mint new us / adr / ft updates",
                    "passed": no_writes,
                    "evidence": f"im={art['im002_modified']} ft={art['ft002_modified']} new_us={len(art['new_us_files'])} new_adr={len(art['new_adr_files'])}"})

    results.append({"text": "Agent did NOT close the bd epic",
                    "passed": art["epic_status"] not in ("closed", "done"),
                    "evidence": f"epic_status={art['epic_status']}"})

    routed = bool(re.search(r"(work-merge|route.{0,20}back|not.{0,20}done|not.{0,20}merged|status.{0,20}ready)", text, re.I))
    results.append({"text": "Output routes back to work-merge OR states 'not done'",
                    "passed": routed, "evidence": "route phrase"})

    results.append({"text": "Agent did NOT touch docs/board.md or docs/archive.md",
                    "passed": not (art["board_modified"] or art["archive_modified"]),
                    "evidence": f"board={art['board_modified']} archive={art['archive_modified']}"})

    return results


def grade_eval3(run_dir: Path) -> list[dict]:
    """nothing-to-harvest: clean retro, close epic, no follow-ups."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    git_used = bool(re.search(r"(git log|git diff|merge-base|HEAD)", text, re.I))
    results.append({"text": "Agent ran git log / git diff",
                    "passed": git_used, "evidence": "git evidence"})

    surveyed = bool(re.search(r"(im002|ft002|bd show|bd list)", text, re.I))
    results.append({"text": "Agent read im002 / ft002 / bd notes",
                    "passed": surveyed, "evidence": "survey evidence"})

    # Either rewrite or leave alone — both OK
    results.append({"text": "Agent may have rewritten im002 body OR left as-is",
                    "passed": True, "evidence": f"im002_modified={art['im002_modified']} (acceptable either way)"})

    results.append({"text": "Agent did NOT draft new us###",
                    "passed": len(art["new_us_drafts"]) == 0,
                    "evidence": f"new_us={art['new_us_drafts']}"})

    results.append({"text": "Agent did NOT mint new adr####",
                    "passed": len(art["new_adr_files"]) == 0,
                    "evidence": f"new_adr={art['new_adr_files']}"})

    results.append({"text": "Agent closed the bd epic",
                    "passed": art["epic_status"] in ("closed", "done"),
                    "evidence": f"epic_status={art['epic_status']}"})

    results.append({"text": "Agent did NOT touch docs/board.md or docs/archive.md",
                    "passed": not (art["board_modified"] or art["archive_modified"]),
                    "evidence": f"board={art['board_modified']} archive={art['archive_modified']}"})

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
