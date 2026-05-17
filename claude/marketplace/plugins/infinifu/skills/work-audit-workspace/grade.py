#!/usr/bin/env python3
"""Grade work-audit iteration outputs against per-eval assertions."""
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
    task1_desc = (task1.get("description") if task1 else "") or ""
    task1_close_reason = (task1.get("close_reason") if task1 else "") or ""
    # Newest beads also embeds close text in 'reason'
    task1_reason = (task1.get("reason") if task1 else "") or ""
    task1_blob = task1_notes + "\n" + task1_desc + "\n" + task1_close_reason + "\n" + task1_reason

    # `bd list` excludes closed by default — augment via bd-show-task1.txt
    bd_show_file = run_dir / "outputs" / "bd-show-task1.txt"
    if bd_show_file.exists():
        show_text = bd_show_file.read_text(errors="ignore")
        if task1_status in ("unknown", "open"):
            if "CLOSED" in show_text:
                task1_status = "closed"
            elif "IN_PROGRESS" in show_text:
                task1_status = "in_progress"
            elif "BLOCKED" in show_text:
                task1_status = "blocked"
        task1_blob = task1_blob + "\n" + show_text

    text_all = gather_text(run_dir)

    return {
        "task1_status": task1_status,
        "task1_blob": task1_blob,
        "text_all": text_all,
        "task1_id": task1_id,
    }


def grade_eval0(run_dir: Path) -> list[dict]:
    """strong-approve: clean impl. Skill should bd close with audit evidence."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    bd_show_called = "bd show" in text
    results.append({"text": "Agent ran bd show on task id",
                    "passed": bd_show_called, "evidence": "bd show in text"})

    pytest_ran = bool(re.search(r"(pytest|test_vault|passed|tests run|5 passed)", text, re.I))
    results.append({"text": "Agent ran the test suite",
                    "passed": pytest_ran, "evidence": "pytest evidence"})

    read_vault = bool(re.search(r"(vault\.py|src/lib/vault|rotate_secret|_LOCK)", text))
    results.append({"text": "Agent read src/lib/vault.py (not just diff)",
                    "passed": read_vault, "evidence": "vault.py refs"})

    criteria_evidence = bool(re.search(r"(file:line|src/lib/vault\.py:\d+|tests/lib/test_vault\.py::test_)", text, re.I))
    results.append({"text": "Agent verified criteria with file:line / test-name evidence",
                    "passed": criteria_evidence,
                    "evidence": "file:line OR test::name present"})

    approved = bool(re.search(r"APPROVED", text)) or art["task1_status"] in ("closed", "done")
    results.append({"text": "Agent issued APPROVED verdict",
                    "passed": approved, "evidence": f"APPROVED text OR status={art['task1_status']}"})

    closed = art["task1_status"] in ("closed", "done")
    results.append({"text": "Agent called bd close (Task 1 status: closed)",
                    "passed": closed, "evidence": f"status={art['task1_status']}"})

    close_reason_strong = bool(re.search(r"AUDITED.{0,20}APPROVED|APPROVED.{0,20}AUDIT", art["task1_blob"], re.I))
    results.append({"text": "Close reason includes AUDITED / APPROVED with criteria evidence",
                    "passed": close_reason_strong,
                    "evidence": f"audit-approved phrase in close text"})

    return results


def grade_eval1(run_dir: Path) -> list[dict]:
    """missing-criterion: input validation skipped. Audit must REJECT."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    sandbox = run_dir / "sandbox"
    vault_body = (sandbox / "src" / "lib" / "vault.py").read_text(errors="ignore") if (sandbox / "src" / "lib" / "vault.py").exists() else ""
    no_validation = not bool(re.search(r"raise ValueError", vault_body))
    detected_missing = bool(re.search(r"(missing.{0,20}validation|empty.{0,20}value|input.{0,20}validation|ValueError|reject.{0,30}empty|skip.{0,20}validation)", text, re.I))
    results.append({"text": "Agent noticed input validation is missing",
                    "passed": detected_missing,
                    "evidence": "missing-validation phrase"})

    ac_referenced = bool(re.search(r"(Empty.{0,30}new_value|reject.{0,30}empty|empty.{0,30}reject|input.{0,30}validation.{0,30}criterion)", text, re.I))
    results.append({"text": "Agent identified the missing AC (empty/None value rejection)",
                    "passed": ac_referenced,
                    "evidence": "AC phrase"})

    rejected = bool(re.search(r"REJECTED", text)) and art["task1_status"] not in ("closed", "done")
    results.append({"text": "Agent issued REJECTED verdict",
                    "passed": rejected,
                    "evidence": f"REJECTED text + status={art['task1_status']}"})

    not_closed = art["task1_status"] not in ("closed", "done")
    results.append({"text": "Agent did NOT close Task 1",
                    "passed": not_closed,
                    "evidence": f"status={art['task1_status']}"})

    notes_logged = bool(re.search(r"(AUDITED.{0,20}REJECTED|REJECTED.{0,30}gap|gap|REJECTED.{0,30}validation)", art["task1_blob"], re.I))
    results.append({"text": "Agent logged gap notes via bd update --notes",
                    "passed": notes_logged,
                    "evidence": "rejection notes in bd"})

    evidence_cited = bool(re.search(r"(src/lib/vault\.py:\d+|src/lib/vault\.py|line \d+|grep|search)", text, re.I))
    results.append({"text": "Rejection includes file:line OR command-output evidence",
                    "passed": evidence_cited,
                    "evidence": "file:line / command evidence"})

    return results


def grade_eval2(run_dir: Path) -> list[dict]:
    """tautological-tests: tests check trivia. Audit must REJECT on test quality."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    test_read = bool(re.search(r"(test_vault|test_rotate_secret_exists|test_rotate_secret_callable|tests/lib)", text, re.I))
    results.append({"text": "Agent read tests/lib/test_vault.py",
                    "passed": test_read,
                    "evidence": "test file refs"})

    tautological_flagged = bool(re.search(r"(tautolog|weak|trivia|can't catch|cannot catch|doesn't catch|test.{0,20}quality|meaningful)", text, re.I))
    results.append({"text": "Agent identified tests are tautological / weak",
                    "passed": tautological_flagged,
                    "evidence": "test-quality language"})

    rejected = bool(re.search(r"REJECTED", text)) and art["task1_status"] not in ("closed", "done")
    results.append({"text": "Agent issued REJECTED verdict",
                    "passed": rejected,
                    "evidence": f"REJECTED text + status={art['task1_status']}"})

    not_closed = art["task1_status"] not in ("closed", "done")
    results.append({"text": "Agent did NOT close Task 1",
                    "passed": not_closed,
                    "evidence": f"status={art['task1_status']}"})

    notes_logged = bool(re.search(r"(AUDITED.{0,20}REJECTED|REJECTED|gap)", art["task1_blob"], re.I))
    results.append({"text": "Agent logged gap notes",
                    "passed": notes_logged,
                    "evidence": "rejection notes"})

    test_named = bool(re.search(r"(test_rotate_secret_exists|test_rotate_secret_callable|test_secret_returns_a_string|test_module_imports)", text))
    results.append({"text": "Rejection names specific tautological tests by name",
                    "passed": test_named,
                    "evidence": "specific test name(s) cited"})

    return results


def grade_eval3(run_dir: Path) -> list[dict]:
    """silent-deviation: global lock vs per-name. Audit must catch."""
    art = gather_artifacts(run_dir)
    text = art["text_all"]
    results = []

    global_lock_detected = bool(re.search(r"(_GLOBAL_LOCK|global.{0,20}lock|global.{0,20}mutex|single.{0,20}lock)", text, re.I))
    results.append({"text": "Agent detected global lock in implementation",
                    "passed": global_lock_detected,
                    "evidence": "global-lock phrase"})

    design_compared = bool(re.search(r"(per.name.{0,20}lock|same name.{0,20}serializ|design.{0,30}per.name|edge_cases|spec.{0,30}per.name)", text, re.I | re.S))
    results.append({"text": "Agent compared design (per-name) vs implementation (global)",
                    "passed": design_compared,
                    "evidence": "design-vs-impl comparison"})

    unlogged_flagged = bool(re.search(r"(unlog|unflagged|silent.{0,20}deviation|deviation.{0,30}none|Deviations:.{0,20}none|not.{0,20}logged)", text, re.I))
    results.append({"text": "Agent noted the deviation is unlogged",
                    "passed": unlogged_flagged,
                    "evidence": "unlogged-deviation phrase"})

    rejected = bool(re.search(r"REJECTED", text)) and art["task1_status"] not in ("closed", "done")
    results.append({"text": "Agent issued REJECTED verdict",
                    "passed": rejected,
                    "evidence": f"REJECTED text + status={art['task1_status']}"})

    not_closed = art["task1_status"] not in ("closed", "done")
    results.append({"text": "Agent did NOT close Task 1",
                    "passed": not_closed,
                    "evidence": f"status={art['task1_status']}"})

    notes_logged = bool(re.search(r"(AUDITED.{0,20}REJECTED|REJECTED|deviation)", art["task1_blob"], re.I))
    results.append({"text": "Agent logged gap notes including the unlogged-deviation finding",
                    "passed": notes_logged,
                    "evidence": "rejection notes"})

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
