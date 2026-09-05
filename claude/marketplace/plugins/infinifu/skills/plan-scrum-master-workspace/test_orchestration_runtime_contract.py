#!/usr/bin/env python3
"""Static contract checks for runtime-specific orchestration behavior."""
from __future__ import annotations

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLAN_SUPERVISED = ROOT / "plan-supervised" / "SKILL.md"
PLAN_SCRUM_MASTER = ROOT / "plan-scrum-master" / "SKILL.md"
ARCHITECTURE = ROOT / "plan-scrum-master" / "references" / "architecture.md"
AGENT_HEALTH = ROOT / "plan-scrum-master" / "references" / "agent-health.md"
FILES = [PLAN_SUPERVISED, PLAN_SCRUM_MASTER, ARCHITECTURE, AGENT_HEALTH]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def normalized(path: Path) -> str:
    return re.sub(r"\s+", " ", read(path))


class OrchestrationRuntimeContractTests(unittest.TestCase):
    def test_plan_supervised_has_explicit_pi_sequential_branch(self) -> None:
        text = normalized(PLAN_SUPERVISED)
        self.assertIn("Runtime adapter gate", text)
        self.assertIn("`AI_AGENT=pi`", text)
        self.assertIn("run the batch sequentially in the current conversation", text)
        self.assertIn("Do not claim that Claude `Agent` subagents were dispatched", text)

    def test_plan_scrum_master_preserves_claude_agent_branch(self) -> None:
        text = normalized(PLAN_SCRUM_MASTER)
        self.assertIn("Claude native branch", text)
        self.assertIn("named background subagents via the `Agent` tool", text)
        self.assertIn("completion notifications", text)
        self.assertIn("`SendMessage({to: \"impl-<bd-id>\"", text)
        self.assertIn("`TaskStop({task_id: \"impl-<bd-id>\"})`", text)

    def test_plan_scrum_master_pi_branch_fails_or_defers_multi_worker(self) -> None:
        text = normalized(PLAN_SCRUM_MASTER)
        self.assertIn("Pi branch (`AI_AGENT=pi`)", text)
        self.assertIn("must not dispatch Claude `Agent` subagents", text)
        self.assertIn("If no explicit Pi multi-worker adapter is installed", text)
        self.assertIn("unsupported until [[sp028]] or a later Pi adapter supplies it", text)

    def test_references_document_future_adapter_insertion_point(self) -> None:
        text = normalized(ARCHITECTURE)
        self.assertIn("Future Pi multi-worker adapter insertion point", text)
        self.assertIn("implements named worker dispatch, direct messaging, completion notification, resume, and stop semantics", text)
        self.assertIn("does not use [[ft012]] or Claude census output as runtime detection", text)

    def test_agent_health_claude_tools_are_claude_only(self) -> None:
        text = normalized(AGENT_HEALTH)
        self.assertIn("Claude native branch only", text)
        self.assertIn("Pi branch", text)
        self.assertIn("do not call `ListAgents` or `TaskStop`", text)
        self.assertIn("use the installed Pi adapter health surface", text)

    def test_no_file_treats_ft012_census_as_pi_runtime_detector(self) -> None:
        for path in FILES:
            text = normalized(path)
            forbidden = [
                "ft012 runtime detector",
                "ft012 as a runtime detector",
                "Claude census as a Pi runtime detector",
                "ListAgents detects Pi",
                "claude agents detects Pi",
            ]
            for phrase in forbidden:
                self.assertNotIn(phrase, text, path)


if __name__ == "__main__":
    unittest.main()
