#!/usr/bin/env python3
"""Grade spec-writing impl-plan-from-approved-design eval."""
import json
import re
import shutil
import subprocess
from pathlib import Path

WORKSPACE = Path("/home/jan/repos/b3tchi/acag/main/infinifu/skills/spec-writing-workspace/iteration-1")
EVAL_DIR = WORKSPACE / "eval-impl-plan"
SANDBOX = EVAL_DIR / "with_skill" / "sandbox"


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
    spec = SANDBOX / "board/spec/url-shortener.md"
    seed_design = SANDBOX / ".seed_design.md"
    spec_text = spec.read_text() if spec.exists() else ""
    seed_text = seed_design.read_text() if seed_design.exists() else ""

    modified = spec.exists() and spec_text != seed_text and len(spec_text) > 500
    results.append({
        "text": "board/spec/url-shortener.md still exists and was modified from seed",
        "passed": modified,
        "evidence": f"exists={spec.exists()}; size={len(spec_text)}; changed={spec_text != seed_text}",
    })

    header_re = re.compile(r"^#\s+[^\n]*\bImplementation\s+Plan\b", re.I | re.M)
    has_header = bool(header_re.search(spec_text))
    results.append({
        "text": "Spec starts with '# <Feature> Implementation Plan' header",
        "passed": has_header,
        "evidence": f"matched={bool(header_re.search(spec_text))}; first_line={spec_text.splitlines()[0][:120] if spec_text else ''!r}",
    })

    for_claude = bool(re.search(
        r"For Claude:[^\n]*(plan-scrum-master|plan-supervised)",
        spec_text, re.I,
    ))
    results.append({
        "text": "Spec contains 'For Claude:' handoff line referencing plan-scrum-master or plan-supervised",
        "passed": for_claude,
        "evidence": f"matched={for_claude}",
    })

    has_goal = bool(re.search(r"\*\*Goal:\*\*", spec_text))
    has_arch = bool(re.search(r"\*\*Architecture:\*\*", spec_text))
    has_stack = bool(re.search(r"\*\*Tech\s*Stack:\*\*", spec_text, re.I))
    results.append({
        "text": "Header includes Goal:, Architecture:, Tech Stack: fields (all three)",
        "passed": has_goal and has_arch and has_stack,
        "evidence": f"goal={has_goal}; architecture={has_arch}; tech_stack={has_stack}",
    })

    tasks = re.findall(r"^#{2,3}\s+Task\s+\d+\s*[:\.]", spec_text, re.M | re.I)
    results.append({
        "text": "Spec contains at least 3 tasks (## or ### Task N: headings)",
        "passed": len(tasks) >= 3,
        "evidence": f"task_headings={len(tasks)}",
    })

    has_failing_test = bool(re.search(
        r"```(?:python|py)\b[^`]*\bassert\b[^`]*```",
        spec_text, re.S,
    )) or bool(re.search(
        r"```(?:python|py)\b[^`]*\bdef\s+test_",
        spec_text, re.S,
    ))
    results.append({
        "text": "At least one task contains a failing-test code block (pytest def test_ or assert)",
        "passed": has_failing_test,
        "evidence": f"matched={has_failing_test}",
    })

    impl_code_blocks = re.findall(r"```(?:python|py)\b([^`]+)```", spec_text, re.S)
    non_test_impl = [b for b in impl_code_blocks if "def test_" not in b and "def " in b]
    has_impl = len(non_test_impl) > 0 or bool(re.search(
        r"```(?:python|py)\b[^`]*\bclass\s+\w+", spec_text, re.S,
    ))
    results.append({
        "text": "At least one task contains an implementation code block (non-test Python code)",
        "passed": has_impl,
        "evidence": f"impl_blocks_with_def={len(non_test_impl)}",
    })

    path_re = re.compile(r"src/services/shortener/[A-Za-z0-9_/\-\.]+\.py")
    paths = set(path_re.findall(spec_text))
    results.append({
        "text": "At least one task specifies exact shortener path (src/services/shortener/<file>.py)",
        "passed": len(paths) >= 1,
        "evidence": f"paths_matched={sorted(paths)}",
    })

    has_commit = bool(re.search(r"\bgit\s+commit\b", spec_text))
    results.append({
        "text": "At least one task includes a git commit command",
        "passed": has_commit,
        "evidence": f"matched={has_commit}",
    })

    has_pytest_with_expectation = bool(re.search(
        r"pytest[^\n]+\n[^\n]*Expected:\s*(FAIL|PASS)",
        spec_text, re.I,
    )) or bool(re.search(
        r"Expected:\s*(FAIL|PASS)", spec_text, re.I,
    ))
    results.append({
        "text": "At least one task includes a run-the-test command with Expected: FAIL or PASS annotation",
        "passed": has_pytest_with_expectation,
        "evidence": f"matched={has_pytest_with_expectation}",
    })

    beads = SANDBOX / ".beads"
    results.append({
        "text": "No bd tasks created (no .beads/ dir)",
        "passed": not beads.exists(),
        "evidence": f".beads_exists={beads.exists()}",
    })

    seeds = seed_manifest(SANDBOX)
    now = current_files(SANDBOX)
    now_extra = now - seeds - {".seed_manifest.txt", ".seed_design.md"}
    new_py = [
        p for p in now_extra
        if p.endswith(".py") and not p.startswith("board/")
    ]
    results.append({
        "text": "No new .py source or test files (agent wrote spec only, no implementation)",
        "passed": len(new_py) == 0,
        "evidence": f"new_py_files={new_py}",
    })

    commits = git_log_count(SANDBOX)
    results.append({
        "text": "No new git commits after the seed (seed had 1 commit, still 1 now)",
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
    print(f"eval-impl-plan/with_skill: {passed}/{total} passed")
    for r in results:
        mark = "✅" if r["passed"] else "❌"
        print(f"  {mark} {r['text']}")
        print(f"     {r['evidence']}")


if __name__ == "__main__":
    main()
