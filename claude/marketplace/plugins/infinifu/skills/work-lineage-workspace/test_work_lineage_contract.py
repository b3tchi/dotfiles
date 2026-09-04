#!/usr/bin/env python3
"""Static contract checks for work-do/work-audit lineage behavior."""
from __future__ import annotations

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORK_DO = ROOT / "work-do" / "SKILL.md"
WORK_AUDIT = ROOT / "work-audit" / "SKILL.md"


def read(name: Path) -> str:
    return name.read_text(encoding="utf-8")


def normalized(text: str) -> str:
    return re.sub(r"\s+", " ", text)


class WorkLineageContractTests(unittest.TestCase):
    def test_work_do_payload_is_only_bd_id_and_contract_is_bd_show(self) -> None:
        text = normalized(read(WORK_DO))
        self.assertRegex(text, r"[Dd]irect work content is only the bd task ID")
        self.assertIn("must resolve the contract with `bd show <id>`", text)

    def test_work_do_supports_feature_add_lineage_without_story_or_implementation(self) -> None:
        text = normalized(read(WORK_DO))
        self.assertIn("Feature-add task", text)
        self.assertIn("owning ready `sp###` plus the proposed or owning `ft###`", text)
        self.assertIn("Do not require `us###.acceptance_criteria` or `im###`", text)

    def test_work_do_preserves_story_backed_acceptance_binding(self) -> None:
        text = normalized(read(WORK_DO))
        self.assertIn("Story-backed task", text)
        self.assertIn("must bind to its source `us###.acceptance_criteria`", text)
        self.assertIn("missing source story or implementation is ambiguous lineage", text)

    def test_work_audit_feature_only_criteria_bind_to_spec_and_feature(self) -> None:
        text = normalized(read(WORK_AUDIT))
        self.assertIn("Feature-add audit", text)
        self.assertIn("verify criteria against the owning ready `sp###` and `ft###`", text)
        self.assertIn("does not require a story acceptance-criteria file", text)

    def test_work_audit_blocks_ambiguous_lineage_before_mutation(self) -> None:
        text = normalized(read(WORK_AUDIT))
        self.assertIn("Ambiguous lineage gate", text)
        self.assertIn("reject before reading source changes, closing, merging, or editing AKM", text)
        self.assertIn("missing or non-ready spec", text)


if __name__ == "__main__":
    unittest.main()
