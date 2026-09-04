#!/usr/bin/env python3
"""Executable contract tests for feature-add spec-retro grading."""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

GRADE_PATH = Path(__file__).with_name("grade.py")


def load_grade_module():
    spec = importlib.util.spec_from_file_location("spec_retro_grade", GRADE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def seed_run(run_dir: Path, *, fake_lineage: bool) -> None:
    sandbox = run_dir / "sandbox"
    outputs = run_dir / "outputs"
    write(sandbox / "docs/notes/ft013.md", "---\nstatus: accepted\n---\n# Feature\n\n## api_surface\nPi worker resume command is shipped.\n")
    write(sandbox / "docs/notes/archive/spec/sp027.md", "---\nstatus: done\n---\n# Spec\n\n## solution\nDeliver [[ft013]].\n")
    if fake_lineage:
        write(sandbox / "docs/notes/us999.md", "---\nstatus: draft\n---\n# Story\n")
        write(sandbox / "docs/notes/im999.md", "---\nstatus: accepted\n---\n# Implementation\n")
        diff = "M docs/notes/ft013.md\nA docs/notes/us999.md\nA docs/notes/im999.md\n"
        notes = "Updated ft013 but created fake us999/im999 lineage for feature-add retro."
    else:
        diff = "M docs/notes/ft013.md\n"
        notes = "Ran git diff for shipped reality. Feature-add retro: refreshed delivered ft013 surface; no us### or im### lineage invented."
    write(outputs / "git-status.txt", diff)
    write(outputs / "run_notes.md", notes)
    write(outputs / "bd-show-epic.txt", "CLOSED\nRetro: feature-add ft013 surface refreshed.\n")


class FeatureAddRetroGraderTests(unittest.TestCase):
    def test_feature_add_retro_grader_accepts_ft_refresh_without_fake_lineage(self) -> None:
        grade = load_grade_module()
        self.assertIn(7, grade.GRADERS)
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td)
            seed_run(run_dir, fake_lineage=False)
            results = grade.grade_eval7(run_dir)
        self.assertTrue(all(item["passed"] for item in results), results)

    def test_feature_add_retro_grader_rejects_invented_story_or_implementation_lineage(self) -> None:
        grade = load_grade_module()
        self.assertIn(7, grade.GRADERS)
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td)
            seed_run(run_dir, fake_lineage=True)
            results = grade.grade_eval7(run_dir)
        fake_lineage_check = next(item for item in results if "no fake us###/im###" in item["text"])
        self.assertFalse(fake_lineage_check["passed"], results)


if __name__ == "__main__":
    unittest.main(verbosity=2)
