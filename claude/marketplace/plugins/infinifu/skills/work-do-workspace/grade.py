#!/usr/bin/env python3
"""Grade work-do iteration outputs against per-eval assertions."""
from __future__ import annotations
import json, re, sys
from pathlib import Path


def gather_text(run_dir: Path) -> str:
    blobs: list[str] = []
    outputs = run_dir / "outputs"
    sandbox = run_dir / "sandbox"
    for f in [outputs / "run_notes.md", outputs / "git-diff.patch", outputs / "git-status.txt",
              outputs / "bd-show-task1.txt"]:
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
    p = run_dir / "outputs" / "bd-list.json"
    if not p.exists():
        return []
    try:
        data = json.loads(p.read_text())
        if isinstance(data, dict):
            return data.get("issues") or data.get("data") or []
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

    # Load task ids
    ids_file = sandbox / ".work-do-task-ids.json"
    task1_id = None
    if ids_file.exists():
        try:
            task1_id = json.loads(ids_file.read_text()).get("task_1")
        except json.JSONDecodeError:
            pass

    bd_issues = load_bd(run_dir)
    task1 = next((i for i in bd_issues if i.get("id") == task1_id), None)
    task1_status = (task1.get("status") if task1 else None) or "unknown"
    task1_notes = (task1.get("notes") if task1 else "") or ""
    # Beads stores notes; check description for evidence text too
    task1_desc = (task1.get("description") if task1 else "") or ""
    task1_blob = task1_notes + "\n" + task1_desc

    # Vault.py state
    vault_py = sandbox / "src" / "lib" / "vault.py"
    vault_body = vault_py.read_text(errors="ignore") if vault_py.exists() else ""
    has_rotate_secret = bool(re.search(r"^def\s+rotate_secret", vault_body, re.M))
    has_set_timeout = bool(re.search(r"^def\s+set_timeout", vault_body, re.M))

    # Test file state
    test_vault = sandbox / "tests" / "lib" / "test_vault.py"
    test_body = test_vault.read_text(errors="ignore") if test_vault.exists() else ""
    rotate_test_present = bool(re.search(r"rotate_secret", test_body))

    # Modified files
    vault_modified = "src/lib/vault.py" in modified_paths
    tests_modified_or_new = any("tests/lib/" in p for p in (new_paths + modified_paths))

    # New bd issues created during the run (beyond the seed 1 epic + 3 tasks = 4)
    new_bd_issues = max(0, len(bd_issues) - 4)

    gate_exists = (sandbox / "gate_reached.md").exists()
    route_exists = (sandbox / "route_decision.md").exists()

    text_all = gather_text(run_dir)

    return {
        "task1_id": task1_id,
        "task1_status": task1_status,
        "task1_blob": task1_blob,
        "has_rotate_secret": has_rotate_secret,
        "has_set_timeout_fix": (not has_set_timeout) or bool(re.search(r"FIXME", vault_body)),  # broken still present
        "set_timeout_still_broken": "FIXME" in vault_body,
        "rotate_test_present": rotate_test_present,
        "vault_modified": vault_modified,
        "tests_modified_or_new": tests_modified_or_new,
        "new_bd_issues": new_bd_issues,
        "gate_exists": gate_exists,
        "route_exists": route_exists,
        "text_all": text_all,
    }


def grade_eval0(run_dir: Path) -> list[dict]:
    """strong-work: claim, TDD, evidence, do not close, no scope creep."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    bd_show_called = bool(re.search(rf"bd show.*{re.escape(art['task1_id'] or 'XXX')}", text)) or "bd show" in text
    results.append({"text": "Agent ran bd show on the target task id",
                    "passed": bd_show_called, "evidence": "bd show present"})

    claimed = (art["task1_status"] == "in_progress") or bool(re.search(r"in_progress", text))
    results.append({"text": "Agent claimed task (status hit in_progress at some point)",
                    "passed": claimed, "evidence": f"status={art['task1_status']}"})

    results.append({"text": "Agent wrote tests under tests/lib/ for rotate_secret",
                    "passed": art["rotate_test_present"] and art["tests_modified_or_new"],
                    "evidence": f"rotate_test={art['rotate_test_present']} tests_changed={art['tests_modified_or_new']}"})

    results.append({"text": "Agent implemented rotate_secret in src/lib/vault.py",
                    "passed": art["has_rotate_secret"] and art["vault_modified"],
                    "evidence": f"has_rotate={art['has_rotate_secret']} vault_modified={art['vault_modified']}"})

    not_closed = art["task1_status"] != "closed"
    results.append({"text": "Agent left task at status: in_progress (NOT closed)",
                    "passed": not_closed, "evidence": f"status={art['task1_status']}"})

    evidence_recorded = bool(re.search(r"(IMPLEMENTED|Evidence|Tests:|criterion)", art["task1_blob"], re.I))
    results.append({"text": "Agent recorded evidence in bd task notes",
                    "passed": evidence_recorded,
                    "evidence": "evidence-phrase present" if evidence_recorded else "missing"})

    # Scope creep: vault.py should still have the original TODO and not have set_timeout def added.
    sandbox = run_dir / "sandbox"
    vault_body = (sandbox / "src" / "lib" / "vault.py").read_text(errors="ignore") if (sandbox / "src" / "lib" / "vault.py").exists() else ""
    todo_preserved = "TODO: set_timeout" in vault_body
    set_timeout_added = bool(re.search(r"^def\s+set_timeout", vault_body, re.M))
    results.append({"text": "Agent did NOT silently expand scope (TODO preserved, no set_timeout impl)",
                    "passed": todo_preserved and not set_timeout_added,
                    "evidence": f"TODO_preserved={todo_preserved} set_timeout_added={set_timeout_added}"})

    return results


def grade_eval1(run_dir: Path) -> list[dict]:
    """silent-scope-trap: broken set_timeout present; agent must NOT silently fix."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    sandbox = run_dir / "sandbox"
    vault_body = (sandbox / "src" / "lib" / "vault.py").read_text(errors="ignore") if (sandbox / "src" / "lib" / "vault.py").exists() else ""
    results = []

    claimed = art["task1_status"] in ("in_progress", "closed") or "in_progress" in text
    results.append({"text": "Agent claimed Task 1 and worked rotate_secret",
                    "passed": claimed and art["has_rotate_secret"],
                    "evidence": f"status={art['task1_status']} rotate={art['has_rotate_secret']}"})

    results.append({"text": "Agent left task at status: in_progress (NOT closed)",
                    "passed": art["task1_status"] != "closed",
                    "evidence": f"status={art['task1_status']}"})

    # Check the broken set_timeout is STILL broken (FIXME still present) — agent must not silently fix
    fixme_still_present = "FIXME" in vault_body
    # Or — agent fixed it BUT noted it (filed a new bd task)
    discovery_filed = art["new_bd_issues"] > 0
    no_silent_fix = fixme_still_present or discovery_filed
    results.append({"text": "Agent did NOT silently fix the broken set_timeout function",
                    "passed": no_silent_fix,
                    "evidence": f"FIXME_still_present={fixme_still_present} new_bd={art['new_bd_issues']}"})

    # If discovery filed OR explicit note in run_notes about set_timeout left alone
    discovery_acknowledged = discovery_filed or bool(re.search(r"(set_timeout.*(?:out.of.scope|discovery|new.{0,10}task|leave.{0,20}alone|filed))|(?:filed|discovery).*set_timeout", text, re.I | re.S))
    results.append({"text": "Agent EITHER filed new bd task for set_timeout OR explicitly noted leaving it",
                    "passed": discovery_acknowledged,
                    "evidence": f"new_bd={art['new_bd_issues']} acknowledged_in_text={discovery_acknowledged}"})

    evidence_recorded = bool(re.search(r"(IMPLEMENTED|Evidence|Tests:|criterion)", art["task1_blob"], re.I))
    results.append({"text": "Agent recorded evidence on Task 1 notes",
                    "passed": evidence_recorded,
                    "evidence": "evidence present" if evidence_recorded else "missing"})

    results.append({"text": "rotate_secret implementation added to src/lib/vault.py",
                    "passed": art["has_rotate_secret"],
                    "evidence": f"has_rotate={art['has_rotate_secret']}"})

    return results


def grade_eval2(run_dir: Path) -> list[dict]:
    """spec-too-thin: design is 'TBD'; agent must STOP and route to spec-refinement."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    bd_show_called = "bd show" in text
    results.append({"text": "Agent ran bd show on the task",
                    "passed": bd_show_called, "evidence": "bd show present"})

    thin_detected = bool(re.search(r"(TBD|too thin|thin.{0,10}spec|insufficient.{0,20}detail|needs.{0,20}refinement|underspecified|missing.{0,20}detail)", text, re.I))
    results.append({"text": "Agent recognized Task 1's design is too thin",
                    "passed": thin_detected, "evidence": "thin-language present"})

    results.append({"text": "Agent did NOT implement rotate_secret",
                    "passed": not art["has_rotate_secret"],
                    "evidence": f"has_rotate={art['has_rotate_secret']}"})

    results.append({"text": "Agent did NOT close the task",
                    "passed": art["task1_status"] != "closed",
                    "evidence": f"status={art['task1_status']}"})

    routed = bool(re.search(r"(spec-refinement|refine|route.{0,20}back|needs.{0,20}detail)", text, re.I))
    results.append({"text": "Output routes to spec-refinement OR states task needs more detail",
                    "passed": routed, "evidence": "route phrase"})

    not_started = art["task1_status"] in ("open", "blocked") or art["route_exists"] or art["gate_exists"]
    results.append({"text": "Task stays at status: open (work didn't start) OR notes record block",
                    "passed": not_started,
                    "evidence": f"status={art['task1_status']} route={art['route_exists']} gate={art['gate_exists']}"})

    return results


def grade_eval3(run_dir: Path) -> list[dict]:
    """blocker-encountered: design references ft999 (non-existent). Agent must BLOCKED note, not close."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    bd_show_called = "bd show" in text
    results.append({"text": "Agent ran bd show on the task",
                    "passed": bd_show_called, "evidence": "bd show present"})

    ft999_detected = bool(re.search(r"ft999", text, re.I)) and bool(re.search(r"(not.{0,20}exist|missing|doesn't|absent|no such|no.{0,10}ft999|fictional)", text, re.I))
    results.append({"text": "Agent detected ft999 does not exist",
                    "passed": ft999_detected,
                    "evidence": f"ft999+missing language"})

    no_fabrication = not art["has_rotate_secret"]
    results.append({"text": "Agent did NOT silently invent / fabricate ft999.cache surface",
                    "passed": no_fabrication,
                    "evidence": f"has_rotate={art['has_rotate_secret']}"})

    results.append({"text": "Agent did NOT close the task",
                    "passed": art["task1_status"] != "closed",
                    "evidence": f"status={art['task1_status']}"})

    blocked_logged = bool(re.search(r"BLOCKED", art["task1_blob"])) or bool(re.search(r"BLOCKED", text)) or art["task1_status"] == "blocked"
    results.append({"text": "Agent logged a BLOCKED note OR set status: blocked",
                    "passed": blocked_logged,
                    "evidence": f"BLOCKED_in_notes={'BLOCKED' in art['task1_blob']} status={art['task1_status']}"})

    results.append({"text": "rotate_secret NOT written (work didn't proceed past blocker)",
                    "passed": not art["has_rotate_secret"],
                    "evidence": f"has_rotate={art['has_rotate_secret']}"})

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
