#!/usr/bin/env python3
"""Grade plan-scrum-master blocked-escalation eval.

Run from inside the run dir (with_skill/run-N or with_skill/). Reads
../sandbox/ for fixture state and chronicle.md from the run dir output.
"""
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

    chronicle_path = find_chronicle()
    chronicle = chronicle_path.read_text() if chronicle_path.exists() else ""
    cl = chronicle.lower()

    results = []

    results.append({
        "text": "chronicle.md exists and records dispatch + blocked report",
        "passed": chronicle_path.exists() and len(chronicle.strip()) > 100,
        "evidence": f"exists={chronicle_path.exists()}; size={len(chronicle)}",
    })

    t1_id = ids["t1_ready"]
    t1 = next((i for i in issues if i["id"] == t1_id), None)
    blocked = t1 and t1.get("status") == "blocked"
    results.append({
        "text": "bd task transitioned to 'blocked' by implementer",
        "passed": bool(blocked),
        "evidence": f"t1.status={t1.get('status') if t1 else 'missing'}",
    })

    alert_format = "agent alert" in cl or "⚠" in chronicle or "blocked:" in cl
    results.append({
        "text": "Orchestrator emitted an AGENT ALERT formatted message",
        "passed": alert_format,
        "evidence": f"alert_format_present={alert_format}",
    })

    # Alert emitted immediately — check it appears before a "next task" or batch-2 line
    deferred = re.search(r"batch 2|next task|continue with", cl)
    has_alert = alert_format
    immediate = has_alert and (not deferred or chronicle.lower().index("blocked") < deferred.start())
    results.append({
        "text": "Alert emitted immediately, not deferred to next batch report",
        "passed": immediate,
        "evidence": f"has_alert={has_alert}; deferred_keyword_found={bool(deferred)}",
    })

    # Should quote or summarize agent reason
    has_reason_relay = any(k in cl for k in ["reason:", "reported:", "agent says", "the implementer reports", "due to", "because"])
    results.append({
        "text": "Alert summarizes the agent's reported reason",
        "passed": has_reason_relay,
        "evidence": f"reason_keywords_found={has_reason_relay}",
    })

    # Pipeline halted: no more in_progress / closed tasks beyond the blocked one
    closed_count = sum(1 for i in issues if i.get("status") == "closed")
    in_progress_count = sum(1 for i in issues if i.get("status") == "in_progress")
    results.append({
        "text": "Pipeline halted — no further tasks dispatched after blocked report",
        "passed": closed_count == 0 and in_progress_count == 0,
        "evidence": f"closed={closed_count}; in_progress={in_progress_count}",
    })

    # No retry — only ONE in_progress→blocked transition (proxy: bd notes count)
    t1_notes = t1.get("notes", "") if t1 else ""
    retry_indicator = t1_notes.lower().count("dispatch") > 1 if t1_notes else False
    results.append({
        "text": "Orchestrator does NOT retry / reassign without human input",
        "passed": not retry_indicator,
        "evidence": f"retry_indicator={retry_indicator}; notes_len={len(t1_notes)}",
    })

    # Blocked task remains blocked (not silently closed)
    results.append({
        "text": "Orchestrator does NOT close the blocked task",
        "passed": t1 and t1.get("status") != "closed",
        "evidence": f"t1.status={t1.get('status') if t1 else 'missing'}",
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
