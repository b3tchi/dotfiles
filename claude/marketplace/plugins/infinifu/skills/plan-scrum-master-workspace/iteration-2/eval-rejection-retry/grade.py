#!/usr/bin/env python3
"""Grade plan-scrum-master rejection-retry-loop eval."""
import json
import re
import subprocess
from pathlib import Path


def find_sandbox() -> Path:
    here = Path.cwd()
    for candidate in (here / "sandbox", here.parent / "sandbox", here / "with_skill" / "sandbox"):
        if candidate.exists():
            return candidate
    raise SystemExit(f"sandbox not found relative to {here}")


def find_chronicle() -> Path:
    here = Path.cwd()
    for candidate in (
        here / "chronicle.md",
        here / "outputs" / "chronicle.md",
        here.parent / "chronicle.md",
        here.parent / "outputs" / "chronicle.md",
    ):
        if candidate.exists():
            return candidate
    return Path("/dev/null")


def load_bd_issues(sandbox: Path):
    out = subprocess.check_output(
        ["bd", "list", "--all", "-n", "0", "--json"],
        cwd=str(sandbox), text=True,
    )
    return json.loads(out)


def grade():
    sandbox = find_sandbox()
    ids = json.loads((sandbox / "seeded_ids.json").read_text())
    issues = load_bd_issues(sandbox)
    t1_id = ids["t1_ready"]
    t1 = next((i for i in issues if i["id"] == t1_id), None)

    chronicle_path = find_chronicle()
    chronicle = chronicle_path.read_text() if chronicle_path.exists() else ""
    cl = chronicle.lower()

    counter_file = Path(ids["counter_dir"]) / t1_id
    attempts = int(counter_file.read_text().strip()) if counter_file.exists() else 0

    results = []

    results.append({
        "text": "chronicle.md exists and records both attempts",
        "passed": chronicle_path.exists() and len(chronicle.strip()) > 200,
        "evidence": f"exists={chronicle_path.exists()}; size={len(chronicle)}",
    })

    results.append({
        "text": "Reviewer was called exactly twice (attempt counter = 2)",
        "passed": attempts == 2,
        "evidence": f"counter_file={counter_file}; attempts={attempts}",
    })

    # Implementer claim count — bd notes should show one dispatch entry, not two
    t1_notes = t1.get("notes", "") if t1 else ""
    n_dispatch_mentions = len(re.findall(r"agent session", t1_notes, re.IGNORECASE))
    # Allow one dispatch entry (first), maybe one additional for resume note,
    # but should NOT show a second fresh "dispatched" entry.
    n_fresh_dispatches = len(re.findall(r"dispatched fresh implementer", t1_notes, re.IGNORECASE))
    results.append({
        "text": "Implementer claimed once — no fresh re-dispatch on first rejection",
        "passed": n_fresh_dispatches == 0,
        "evidence": f"notes_dispatch_mentions={n_dispatch_mentions}; fresh_dispatches={n_fresh_dispatches}",
    })

    sendmsg_evidence = any(k in cl for k in ["sendmessage", "send_message", "resumed the implementer", "resume agent", "continue session"])
    results.append({
        "text": "SendMessage used to resume the original implementer agent",
        "passed": sendmsg_evidence,
        "evidence": f"sendmessage_evidence={sendmsg_evidence}",
    })

    metadata_logged = any(k in t1_notes.lower() for k in ["agent session:", "worktree:", "branch:"])
    results.append({
        "text": "Agent session metadata logged to bd notes",
        "passed": metadata_logged,
        "evidence": f"metadata_keywords_in_notes={metadata_logged}",
    })

    # Reviewer rejection reason should appear in chronicle (relay verbatim)
    reason_relay = any(k in cl for k in ["half-even", "tie-breaking", "2.5 → 2", "3.5 → 4", "test_rounding"])
    results.append({
        "text": "Rejection reason relayed verbatim to resumed implementer",
        "passed": reason_relay,
        "evidence": f"reason_keywords_in_chronicle={reason_relay}",
    })

    results.append({
        "text": "Task closed by reviewer after second attempt",
        "passed": t1 and t1.get("status") == "closed",
        "evidence": f"t1.status={t1.get('status') if t1 else 'missing'}",
    })

    escalation_kw = any(k in cl for k in ["escalat", "blocked:", "agent alert", "need your decision"])
    results.append({
        "text": "No escalation raised (rejection count = 1, not 2)",
        "passed": not escalation_kw,
        "evidence": f"escalation_kw_present={escalation_kw}",
    })

    # Failure-escalation rule: retry should upgrade sonnet → opus.
    chronicle_lower = chronicle.lower()
    upgrade_evidence = (
        re.search(r"upgrad\w*.*opus", chronicle_lower)
        or re.search(r"sonnet\s*[-→>]+\s*opus", chronicle_lower)
        or re.search(r"retry.*opus", chronicle_lower)
        or "model: opus" in chronicle_lower and "attempt 2" in chronicle_lower
    )
    results.append({
        "text": "Retry attempt 2 upgraded worker model from sonnet to opus",
        "passed": bool(upgrade_evidence),
        "evidence": f"upgrade_evidence={bool(upgrade_evidence)}",
    })

    notes_lower = t1_notes.lower() if t1_notes else ""
    notes_upgrade = (
        "upgraded" in notes_lower
        or "opus" in notes_lower and "retry" in notes_lower
        or re.search(r"sonnet\s*[-→>]+\s*opus", notes_lower)
    )
    results.append({
        "text": "Model upgrade logged in bd notes for the retried task",
        "passed": bool(notes_upgrade),
        "evidence": f"notes_upgrade_logged={bool(notes_upgrade)}",
    })

    passed = sum(1 for r in results if r["passed"])
    total = len(results)
    summary_block = {
        "summary": {
            "passed": passed,
            "failed": total - passed,
            "total": total,
            "pass_rate": passed / total if total else 0,
        },
        "expectations": results,
    }

    timing_file = Path.cwd() / "timing.json"
    if timing_file.exists():
        summary_block["timing"] = json.loads(timing_file.read_text())

    (Path.cwd() / "grading.json").write_text(json.dumps(summary_block, indent=2))
    print(json.dumps(summary_block, indent=2))


if __name__ == "__main__":
    grade()
