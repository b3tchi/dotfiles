#!/usr/bin/env python3
"""Grade work-do tdd-and-evidence-protocol eval."""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

WORKSPACE = Path("/home/jan/repos/b3tchi/acag/main/infinifu/skills/work-do-workspace/iteration-1")
EVAL_DIR = WORKSPACE / "eval-tdd-evidence"
SANDBOX = EVAL_DIR / "with_skill" / "sandbox"


def load_bd_issues(sandbox: Path):
    out = subprocess.check_output(
        ["bd", "list", "--all", "-n", "0", "--json"],
        cwd=str(sandbox), text=True,
    )
    return json.loads(out)


def bd_comments(sandbox: Path, issue_id: str):
    try:
        out = subprocess.check_output(
            ["bd", "comments", issue_id, "--json"],
            cwd=str(sandbox), text=True, stderr=subprocess.STDOUT,
        )
        return json.loads(out)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return []


def bd_show_text(sandbox: Path, issue_id: str) -> str:
    try:
        return subprocess.check_output(
            ["bd", "show", issue_id],
            cwd=str(sandbox), text=True, stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError as e:
        return e.output or ""


def git_log_count(sandbox: Path) -> int:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(sandbox), "log", "--oneline"], text=True,
        )
        return len([l for l in out.splitlines() if l.strip()])
    except subprocess.CalledProcessError:
        return -1


def run_pytest(sandbox: Path):
    try:
        out = subprocess.check_output(
            [sys.executable, "-m", "pytest", "tests/test_slugs.py", "-v"],
            cwd=str(sandbox), text=True, stderr=subprocess.STDOUT, timeout=60,
        )
        return 0, out
    except subprocess.CalledProcessError as e:
        return e.returncode, e.output or ""
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"


def call_slugify(sandbox: Path, arg: str):
    snippet = f"import sys; sys.path.insert(0, 'src'); from slugs import slugify; print(slugify({arg!r}))"
    try:
        out = subprocess.check_output(
            [sys.executable, "-c", snippet],
            cwd=str(sandbox), text=True, stderr=subprocess.STDOUT, timeout=10,
        )
        return out.strip()
    except subprocess.CalledProcessError as e:
        return f"ERROR: {e.output.strip()}"
    except subprocess.TimeoutExpired:
        return "TIMEOUT"


def grade():
    results = []
    ids = json.loads((SANDBOX / "seeded_ids.json").read_text())
    tid = ids["task"]
    issues = load_bd_issues(SANDBOX)
    by_id = {i["id"]: i for i in issues}
    task = by_id.get(tid, {})

    results.append({
        "text": "Task status is in_progress (claimed) and NOT closed",
        "passed": task.get("status") == "in_progress",
        "evidence": f"status={task.get('status')}",
    })

    slugs = SANDBOX / "src" / "slugs.py"
    slugs_text = slugs.read_text() if slugs.exists() else ""
    has_slugify = bool(re.search(r"def\s+slugify\s*\(", slugs_text))
    results.append({
        "text": "src/slugs.py exists and defines slugify(...)",
        "passed": slugs.exists() and has_slugify,
        "evidence": f"exists={slugs.exists()}; has_slugify_def={has_slugify}",
    })

    tests = SANDBOX / "tests" / "test_slugs.py"
    test_text = tests.read_text() if tests.exists() else ""
    test_fns = re.findall(r"^def\s+test_\w+", test_text, re.M)
    results.append({
        "text": "tests/test_slugs.py exists and contains at least 4 pytest tests",
        "passed": tests.exists() and len(test_fns) >= 4,
        "evidence": f"exists={tests.exists()}; test_fn_count={len(test_fns)}",
    })

    rc, out = run_pytest(SANDBOX)
    # Extract pass/fail summary
    m = re.search(r"(\d+)\s+passed", out)
    passed_n = int(m.group(1)) if m else 0
    failed = "failed" in out.lower() and "0 failed" not in out.lower()
    results.append({
        "text": "pytest tests/test_slugs.py -v passes cleanly (rc=0, ≥4 tests passed)",
        "passed": rc == 0 and passed_n >= 4,
        "evidence": f"rc={rc}; passed={passed_n}; tail={out.strip().splitlines()[-1] if out.strip() else '(empty)'}",
    })

    hw = call_slugify(SANDBOX, "Hello World")
    results.append({
        "text": "slugify('Hello World') == 'hello-world'",
        "passed": hw == "hello-world",
        "evidence": f"got={hw!r}",
    })
    ms = call_slugify(SANDBOX, "  Multi   space!!! ")
    results.append({
        "text": "slugify('  Multi   space!!! ') == 'multi-space'",
        "passed": ms == "multi-space",
        "evidence": f"got={ms!r}",
    })
    fx = call_slugify(SANDBOX, "---foo---")
    results.append({
        "text": "slugify('---foo---') == 'foo'",
        "passed": fx == "foo",
        "evidence": f"got={fx!r}",
    })

    # Evidence note — check comments + bd show text
    comments = bd_comments(SANDBOX, tid)
    comments_text = " ".join(
        str(c.get("body") or c.get("text") or c.get("content") or c)
        for c in comments
    )
    full_text = (comments_text + "\n" + bd_show_text(SANDBOX, tid)).upper()
    has_evidence_note = "IMPLEMENTED" in full_text or "EVIDENCE" in full_text
    results.append({
        "text": "Task has at least one note/comment containing 'IMPLEMENTED' or 'Evidence'",
        "passed": has_evidence_note,
        "evidence": f"comment_count={len(comments)}; has_evidence_marker={has_evidence_note}",
    })

    commits = git_log_count(SANDBOX)
    results.append({
        "text": "Agent made at least one git commit beyond the seed (seed=1)",
        "passed": commits >= 2,
        "evidence": f"commit_count={commits}",
    })

    # Out-of-scope check: no non-ASCII in *code* (not comments), OR a discovery task was filed.
    # Strip line comments so a stray em-dash in a comment doesn't count.
    def strip_py_comments(src: str) -> str:
        return "\n".join(re.sub(r"(?<!['\"])#.*$", "", line) for line in src.splitlines())
    non_ascii_test = (
        bool(re.search(r"[^\x00-\x7F]", strip_py_comments(test_text)))
        or bool(re.search(r"[^\x00-\x7F]", strip_py_comments(slugs_text)))
    )
    discovery_tasks = [
        i for i in issues
        if i["id"] != tid and i.get("status") != "closed" and (
            "discover" in (i.get("title") or "").lower()
            or "unicode" in (i.get("title") or "").lower()
            or any(d.get("type") == "discovered-from" for d in (i.get("dependencies") or []))
        )
    ]
    # Pass if: no non-ascii content (respected out-of-scope) OR a discovery task exists
    results.append({
        "text": "Did not silently implement unicode (no non-ASCII in code) OR a discovery task was filed",
        "passed": (not non_ascii_test) or len(discovery_tasks) >= 1,
        "evidence": f"non_ascii_in_code={non_ascii_test}; discovery_tasks={[d['id'] for d in discovery_tasks]}",
    })

    report = EVAL_DIR / "with_skill" / "outputs" / "report.md"
    run_notes = EVAL_DIR / "with_skill" / "outputs" / "run_notes.md"
    has_report = report.exists() and len(report.read_text().strip()) > 100
    has_notes = run_notes.exists() and len(run_notes.read_text().strip()) > 100
    results.append({
        "text": "A report.md or run_notes.md was written to outputs/ describing the work",
        "passed": has_report or has_notes,
        "evidence": f"report_exists={report.exists()}; run_notes_exists={run_notes.exists()}",
    })

    return results


def write_grading(run_base: Path, results, timing_data):
    run1 = run_base / "run-1"
    run1.mkdir(exist_ok=True)
    passed = sum(1 for r in results if r["passed"])
    total = len(results)
    grading = {
        "summary": {
            "passed": passed, "failed": total - passed, "total": total,
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
    print(f"eval-tdd-evidence/with_skill: {passed}/{total} passed")
    for r in results:
        mark = "✅" if r["passed"] else "❌"
        print(f"  {mark} {r['text']}")
        print(f"     {r['evidence']}")


if __name__ == "__main__":
    main()
