#!/usr/bin/env python3
"""Grade the idea-brainstorming hard-gate eval."""
import json
import re
import shutil
import subprocess
from pathlib import Path

WORKSPACE = Path("/home/jan/repos/b3tchi/acag/main/infinifu/skills/idea-brainstorming-workspace/iteration-1")
EVAL_DIR = WORKSPACE / "eval-hard-gate"
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

    results.append({
        "text": "gate_reached.md exists at sandbox root and is non-empty",
        "passed": gate.exists() and len(gate_text.strip()) > 50,
        "evidence": f"exists={gate.exists()}; size={len(gate_text)} chars",
    })

    seeds = seed_manifest(SANDBOX)
    now = current_files(SANDBOX)
    # Exclude the gate file itself + outputs notes + seed manifest
    now_extra = now - seeds - {
        "gate_reached.md", ".seed_manifest.txt",
    }
    # No new source files
    new_source = [
        p for p in now_extra
        if Path(p).suffix.lower() in SOURCE_EXTS
    ]
    results.append({
        "text": "No source/implementation files were created (no new .py/.js/.ts/.rs/.go files beyond seed)",
        "passed": len(new_source) == 0,
        "evidence": f"new_source_files={new_source}",
    })

    # No design doc
    design_docs = [
        p for p in now_extra
        if p.startswith(("board/idea/", "board/spec/")) and p.endswith(".md")
    ]
    results.append({
        "text": "No design doc was written to board/idea/ or board/spec/",
        "passed": len(design_docs) == 0,
        "evidence": f"design_docs={design_docs}",
    })

    # No bd project
    beads_dir = SANDBOX / ".beads"
    results.append({
        "text": "No bd epic/tasks were created (no .beads/ dir)",
        "passed": not beads_dir.exists(),
        "evidence": f".beads_exists={beads_dir.exists()}",
    })

    gt_lower = gate_text.lower()
    mentions_context = ("readme" in gt_lower) or ("src/" in gt_lower) or ("src/services" in gt_lower) or ("acme" in gt_lower)
    results.append({
        "text": "gate_reached.md shows project context was actually explored (references README/src/Acme)",
        "passed": mentions_context,
        "evidence": f"mentions_context={mentions_context}; first_300={gate_text[:300]!r}",
    })

    # Extract the "Next question" section
    m = re.search(r"##+\s*Next question\s*\n(.+?)(?:\n##|\Z)", gate_text, re.S | re.I)
    next_q = m.group(1).strip() if m else ""
    has_q = "?" in next_q
    results.append({
        "text": "gate_reached.md 'Next question' section contains at least one question mark",
        "passed": has_q and len(next_q) > 0,
        "evidence": f"next_question_len={len(next_q)}; has_question_mark={has_q}; excerpt={next_q[:200]!r}",
    })

    total_qmarks = gate_text.count("?")
    results.append({
        "text": "gate_reached.md contains at most 3 question marks total (one-question-at-a-time rule)",
        "passed": 1 <= total_qmarks <= 3,
        "evidence": f"total_question_marks={total_qmarks}",
    })

    # git log should still be 1 commit (the seed)
    commits = git_log_count(SANDBOX)
    results.append({
        "text": "No new git commits after the seed (agent stopped before committing anything)",
        "passed": commits == 1,
        "evidence": f"commit_count={commits}",
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
    print(f"eval-hard-gate/with_skill: {passed}/{total} passed")
    for r in results:
        mark = "✅" if r["passed"] else "❌"
        print(f"  {mark} {r['text']}")
        print(f"     {r['evidence']}")


if __name__ == "__main__":
    main()
