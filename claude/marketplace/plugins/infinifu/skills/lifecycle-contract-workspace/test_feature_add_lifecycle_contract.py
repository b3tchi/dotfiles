#!/usr/bin/env python3
"""sp027: feature-add lifecycle neither requires nor invents `us###` / `im###`.

Every lifecycle stage that used to treat "a spec has a source story and a
consumed implementation" as universal must now state both shapes: feature-add
specs whose deliverable is a proposed `ft###`, and story-backed specs whose
story acceptance criteria stay binding. This asserts both halves per stage —
dropping either one is the regression. It also pins the `work-*` payload
contract: the worker gets a bd ticket id, not a copied task body.
"""
from __future__ import annotations

from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mdscan import find_block  # noqa: E402

SKILLS = Path(__file__).resolve().parents[1]
ADAPTER = SKILLS / "meta-patterns" / "runtime-adapter.md"

# Stages that resolve lineage. Each must describe both shapes.
LINEAGE_STAGES = [
    SKILLS / "spec-writing" / "SKILL.md",
    SKILLS / "spec-refinement" / "SKILL.md",
    SKILLS / "spec-ready" / "SKILL.md",
    SKILLS / "work-do" / "SKILL.md",
    SKILLS / "work-audit" / "SKILL.md",
    SKILLS / "work-merge" / "SKILL.md",
    SKILLS / "spec-retro" / "SKILL.md",
]

# Stages a dispatcher hands a task to. work-audit reviews an already-claimed
# task, so the dispatch-payload rule does not apply to it.
WORK_STAGES = [
    SKILLS / "work-do" / "SKILL.md",
    SKILLS / "work-audit" / "SKILL.md",
]
DISPATCHED_STAGES = [SKILLS / "work-do" / "SKILL.md"]

FABRICATE = r"(do not|don't|never)[^.]{0,80}(fabricat|invent)"
STORY_BINDING = r"story-backed|acceptance criteria|acceptance_criteria"


class FeatureAddLifecycleTests(unittest.TestCase):
    def test_every_lineage_stage_documents_the_feature_add_shape(self) -> None:
        for path in LINEAGE_STAGES:
            self.assertTrue(
                find_block(path, r"feature-add", normative_only=True),
                f"{path.parent.name} has no normative feature-add lineage rule",
            )

    def test_every_lineage_stage_forbids_fabricating_story_lineage(self) -> None:
        for path in LINEAGE_STAGES:
            hits = find_block(path, FABRICATE, normative_only=True)
            relevant = [h for h in hits if "us###" in h.text or "im###" in h.text
                        or "story" in h.text.lower()]
            self.assertTrue(
                relevant,
                f"{path.parent.name} does not forbid fabricating us###/im### links",
            )

    def test_story_backed_path_survives_alongside_feature_add(self) -> None:
        # Edge case: both shapes coexist in one skill; adding the feature-add
        # branch must not delete the story-backed requirement.
        for path in LINEAGE_STAGES:
            self.assertTrue(
                find_block(path, STORY_BINDING, normative_only=True),
                f"{path.parent.name} dropped its story-backed lineage rule",
            )

    def test_ambiguous_lineage_blocks_before_mutation(self) -> None:
        for path in WORK_STAGES + [SKILLS / "work-merge" / "SKILL.md"]:
            raised = find_block(path, r"ambiguous", normative_only=True)
            self.assertTrue(
                raised, f"{path.parent.name} never mentions ambiguous lineage"
            )
            self.assertTrue(
                any(
                    re.search(r"block|reject|abort|escalate", block.text, re.I)
                    for block in raised
                ),
                f"{path.parent.name} raises ambiguous lineage without blocking on it",
            )

    def test_work_stage_payload_is_the_bd_ticket_id_only(self) -> None:
        for path in DISPATCHED_STAGES:
            self.assertTrue(
                find_block(
                    path,
                    r"(only|exactly)[^.]{0,80}bd task id"
                    r"|bd task id[^.]{0,60}(only|exactly)",
                    normative_only=True,
                ),
                f"{path.parent.name} does not pin the payload to the bd task id",
            )

    def test_work_stage_resolves_its_contract_with_bd_show(self) -> None:
        for path in WORK_STAGES:
            self.assertTrue(
                find_block(path, r"bd show <id>", normative_only=True),
                f"{path.parent.name} does not resolve the contract via bd show",
            )

    def test_shared_adapter_states_the_work_payload_rule_once(self) -> None:
        self.assertTrue(
            find_block(
                ADAPTER,
                r"bd[^.]{0,40}(task|ticket) id|`bd` owns task state",
            ),
            "runtime-adapter.md does not carry the work payload / task contract rule",
        )


if __name__ == "__main__":
    unittest.main()
