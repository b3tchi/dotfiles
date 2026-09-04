#!/usr/bin/env python3
"""Behavior tests for work-merge archive-epic.sh."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SKILLS_DIR = Path(__file__).resolve().parents[1]
SCRIPT = SKILLS_DIR / "work-merge" / "scripts" / "archive-epic.sh"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def frontmatter(alias: str, status: str, kind: str = "Note", links: str = "[[product]]") -> str:
    return f"""---
aliases:
  - {alias}
status: {status}
created: 2026-01-01
---
# {kind} {links}

## body
content

---

Index: [[product]]
"""


def init_workspace(root: Path) -> Path:
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
    write(root / "docs/board.md", "# Board\n\n## ready\n\n- [[sp001|ship thing]]\n")
    write(root / "docs/archive.md", "# Archive\n\n## done\n")
    write(root / "docs/notes/us001.md", frontmatter("story", "ready", "Story"))
    write(root / "docs/notes/im001.md", frontmatter("implementation", "proposed", "Implementation"))
    write(root / "docs/notes/ft001.md", frontmatter("feature", "proposed", "Feature"))
    write(
        root / "bd",
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [ \"${BD_FAIL_CLOSE:-0}\" = 1 ] && [ \"$1\" = close ]; then exit 42; fi\n"
        "exit 0\n",
    )
    (root / "bd").chmod(0o755)
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "seed"], cwd=root, check=True)
    return root


def run_archive(root: Path, *args: str, fail_close: bool = False) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PATH"] = f"{root}:{env['PATH']}"
    if fail_close:
        env["BD_FAIL_CLOSE"] = "1"
    return subprocess.run(
        ["bash", str(SCRIPT), *args, str(root)],
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def status(path: Path) -> str:
    for line in path.read_text().splitlines():
        if line.startswith("status: "):
            return line.split(": ", 1)[1]
    raise AssertionError(f"no status in {path}")


class ArchiveEpicTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = init_workspace(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def docs_snapshot(self) -> dict[Path, str]:
        return {p.relative_to(self.root): p.read_text() for p in (self.root / "docs").rglob("*.md")}

    def write_spec(self, alias: str, body: str) -> None:
        write(
            self.root / "docs/notes/spec/sp001.md",
            frontmatter(alias, "ready", "Spec", "[[cat001]] [[board]]")
            .replace("## body\ncontent", body)
            .replace("Index: [[product]]", "Index: [[board]]"),
        )

    def commit_spec(self, message: str) -> None:
        subprocess.run(["git", "add", "docs/notes/spec/sp001.md"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", message], cwd=self.root, check=True)

    def test_feature_only_finale_accepts_feature_without_story_or_implementation(self) -> None:
        self.write_spec("ship feature", "## problem\nShip proposed [[ft001]] without a story-backed implementation.")
        self.commit_spec("feature spec")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/ft001.md"), "accepted")
        self.assertFalse((self.root / "docs/notes/spec/sp001.md").exists())
        archived_spec = self.root / "docs/notes/archive/spec/sp001.md"
        self.assertEqual(status(archived_spec), "done")
        self.assertIn("Index: [[archive]]", archived_spec.read_text())
        self.assertNotIn("sp001", (self.root / "docs/board.md").read_text())
        self.assertIn("[[sp001|ship thing]]", (self.root / "docs/archive.md").read_text())
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "ready")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "proposed")

    def test_story_backed_finale_still_flips_story_and_implementation(self) -> None:
        self.write_spec("ship story", "## solves\n[[us001]]\n\n## implements\n[[im001]]")
        self.commit_spec("story spec")

        result = run_archive(self.root, "sp001", "us001", "im001", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "done")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "accepted")
        self.assertEqual(status(self.root / "docs/notes/ft001.md"), "proposed")
        self.assertEqual(status(self.root / "docs/notes/archive/spec/sp001.md"), "done")

    def test_ambiguous_lineage_fails_before_any_archive_mutation(self) -> None:
        self.write_spec("ambiguous", "## solves\n[[us001]]\n\n## problem\nMissing implementation and feature deliverable.")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous", (result.stderr + result.stdout).lower())
        self.assertEqual(self.docs_snapshot(), before)

    def test_failure_during_archive_rolls_back_file_mutations(self) -> None:
        self.write_spec("ship feature", "## problem\nShip proposed [[ft001]].")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1", fail_close=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rolled back", (result.stderr + result.stdout).lower())
        self.assertEqual(self.docs_snapshot(), before)
        self.assertFalse((self.root / "docs/notes/archive/spec/sp001.md").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
