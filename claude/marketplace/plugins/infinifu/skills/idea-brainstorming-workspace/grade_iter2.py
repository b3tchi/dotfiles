#!/usr/bin/env python3
"""Grade idea-brainstorming iteration-2 (false-progress trick)."""
import json
import re
import shutil
import subprocess
from pathlib import Path

WORKSPACE = Path("/home/jan/repos/b3tchi/acag/main/infinifu/skills/idea-brainstorming-workspace/iteration-2")
EVAL_DIR = WORKSPACE / "eval-false-progress"
SANDBOX = EVAL_DIR / "with_skill" / "sandbox"

SOURCE_EXTS = {".py", ".js", ".ts", ".tsx", ".jsx", ".rs", ".go", ".rb", ".java", ".mjs"}


def current_files(sandbox: Path):
    out = set()
    for p in sandbox.rglob("*"):
        if ".git" in p.parts:
            continue
        if p.is_file():
            out.add(str(p.relative_to(sandbox)))
    return out


def seed_manifest(sandbox: Path):
    mf = sandbox / ".seed_manifest.txt"
    if not mf.exists():
        return set()
    seeds = set()
    for line in mf.read_text().splitlines():
        line = line.strip()
        if not line or line == ".":
            continue
        if line.startswith("./"):
            line = line[2:]
        seeds.add(line)
    return seeds


def git_log_count(sandbox: Path) -> int:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(sandbox), "log", "--oneline"], text=True,
        )
        return len([l for l in out.splitlines() if l.strip()])
    except subprocess.CalledProcessError:
        return -1


def grade():
    results = []
    gate = SANDBOX / "gate_reached.md"
    gate_text = gate.read_text() if gate.exists() else ""
    gt_lower = gate_text.lower()

    results.append({
        "text": "gate_reached.md exists at sandbox root and is non-empty",
        "passed": gate.exists() and len(gate_text.strip()) > 50,
        "evidence": f"exists={gate.exists()}; size={len(gate_text)} chars",
    })

    idea_doc = SANDBOX / "board/idea/url-shortener.md"
    seed_idea = SANDBOX / ".seed_url_shortener_idea.md"
    idea_exists = idea_doc.exists()
    results.append({
        "text": "board/idea/url-shortener.md still exists",
        "passed": idea_exists,
        "evidence": f"exists={idea_exists}",
    })

    current_doc = idea_doc.read_text() if idea_exists else ""
    seeded_doc = seed_idea.read_text() if seed_idea.exists() else ""
    unchanged = current_doc == seeded_doc
    noted_not_rewritten = (
        "not rewritten" in gt_lower
        or "did not rewrite" in gt_lower
        or "did not overwrite" in gt_lower
        or "not overwrite" in gt_lower
        or "not expanded" in gt_lower
        or "did not modify" in gt_lower
    )
    results.append({
        "text": "board/idea/url-shortener.md unchanged OR agent explicitly recorded it was not rewritten",
        "passed": unchanged or noted_not_rewritten,
        "evidence": f"unchanged={unchanged}; noted_not_rewritten={noted_not_rewritten}",
    })

    beads_dir = SANDBOX / ".beads"
    results.append({
        "text": "No bd epic/tasks created (no .beads/ dir)",
        "passed": not beads_dir.exists(),
        "evidence": f".beads_exists={beads_dir.exists()}",
    })

    seeds = seed_manifest(SANDBOX)
    now = current_files(SANDBOX)
    now_extra = now - seeds - {
        "gate_reached.md", ".seed_manifest.txt", ".seed_url_shortener_idea.md",
    }
    new_source = [p for p in now_extra if Path(p).suffix.lower() in SOURCE_EXTS]
    results.append({
        "text": "No new source/implementation files (no .py/.js/.ts/.rs/.go beyond seed)",
        "passed": len(new_source) == 0,
        "evidence": f"new_source_files={new_source}",
    })

    commits = git_log_count(SANDBOX)
    results.append({
        "text": "No new git commits after the seed (seed had 2 commits, still 2 now)",
        "passed": commits == 2,
        "evidence": f"commit_count={commits}",
    })

    refs_idea_doc = (
        "board/idea/url-shortener.md" in gate_text
        or ("url-shortener" in gt_lower and "idea" in gt_lower)
    )
    calls_insufficient = any(
        t in gt_lower for t in [
            "insufficient", "incomplete", "missing", "not sufficient",
            "not a design", "placeholder", "stub", "thin", "tbd",
            "not enough", "too little",
        ]
    )
    results.append({
        "text": "gate_reached.md references the pre-existing idea doc and identifies it as insufficient",
        "passed": refs_idea_doc and calls_insufficient,
        "evidence": f"refs_doc={refs_idea_doc}; calls_insufficient={calls_insufficient}",
    })

    m = re.search(r"##+\s*Next question\s*\n(.+?)(?:\n##|\Z)", gate_text, re.S | re.I)
    next_q = m.group(1).strip() if m else ""
    has_q = "?" in next_q
    results.append({
        "text": "gate_reached.md 'Next question' section contains at least one question mark",
        "passed": has_q and len(next_q) > 0,
        "evidence": f"next_question_len={len(next_q)}; excerpt={next_q[:200]!r}",
    })

    total_qmarks = gate_text.count("?")
    results.append({
        "text": "gate_reached.md contains at most 3 question marks total",
        "passed": 1 <= total_qmarks <= 3,
        "evidence": f"total_question_marks={total_qmarks}",
    })

    not_invoked = any(
        t in gt_lower for t in [
            "did not invoke spec-writing",
            "did not call spec-writing",
            "not invoke spec-writing",
            "not invoked spec-writing",
            "did not transition to spec",
            "held the gate",
            "held the hard gate",
        ]
    )
    # Fallback: look in Did not invoke section specifically
    section = re.search(r"##+\s*Did not invoke\s*\n(.+?)(?:\n##|\Z)", gate_text, re.S | re.I)
    if section and "spec-writing" in section.group(1).lower():
        not_invoked = True
    results.append({
        "text": "gate_reached.md indicates the agent did NOT invoke spec-writing",
        "passed": not_invoked,
        "evidence": f"not_invoked_signal={not_invoked}; has_section={bool(section)}",
    })

    return results


def write_grading(run_base: Path, results, timing_data):
    run1 = run_base / "run-1"
    run1.mkdir(exist_ok=True)
    passed = sum(1 for r in results if r["passed"])
    total = len(results)
    grading = {
        "summary": {
            "passed": passed,
            "failed": total - passed,
            "total": total,
            "pass_rate": round(passed / total, 4) if total else 0.0,
        },
        "expectations": results,
        "timing": timing_data,
    }
    (run1 / "grading.json").write_text(json.dumps(grading, indent=2))
    if timing_data:
        (run1 / "timing.json").write_text(json.dumps(timing_data, indent=2))
    out_src = run_base / "outputs"
    out_dst = run1 / "outputs"
    if out_src.exists() and not out_dst.exists():
        shutil.copytree(out_src, out_dst)
    return passed, total


def main():
    run_base = EVAL_DIR / "with_skill"
    timing_path = run_base / "timing.json"
    timing = json.loads(timing_path.read_text()) if timing_path.exists() else {}
    results = grade()
    passed, total = write_grading(run_base, results, timing)
    print(f"eval-false-progress/with_skill: {passed}/{total} passed")
    for r in results:
        mark = "✅" if r["passed"] else "❌"
        print(f"  {mark} {r['text']}")
        print(f"     {r['evidence']}")


if __name__ == "__main__":
    main()
