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

# The three files this task (sp037 T2) rewrites. plan-supervised belongs to a
# parallel task (T3) and must not be touched or asserted on for the neutral
# rewrite here -- only the ft012 regression test below still reads it.
NEUTRAL_FILES = [PLAN_SCRUM_MASTER, ARCHITECTURE, AGENT_HEALTH]

# Vocabulary fixed by sp037 T1 in runtime-adapter.md's ## operation binding.
OPERATIONS = [
    "dispatch",
    "send work",
    "await",
    "reject/resume",
    "accept and clean",
    "tear down",
    "inspect",
]

# Hedge strings the pre-T2 text used to gate behavior on which runtime was
# selected. None of these may reappear in ANY neutral file -- their presence
# means the rewrite regressed back to branching prose.
FORBIDDEN_HEDGES_ANY_FILE = [
    "unsupported until [[sp028]]",
    "If no explicit Pi multi-worker adapter is installed",
    "Future Pi multi-worker adapter insertion point",
    "fails clearly or defers multi-worker dispatch",
    "| Step | Pi command | Claude equivalent |",
    "Pi branch (`AI_AGENT=pi`)",
]

# "Claude native branch only:" specifically gated the three orchestration
# paragraphs (dispatch, reviewer dispatch, retry) in SKILL.md and the health
# surface in agent-health.md -- all three neutral files must now read the
# same on every runtime. A Claude-only deep-dive reference is itself the
# drift shape sp037 exists to remove (runtime-adapter.md is the one file
# T4's lint exempts), so architecture.md is held to this bar too.
FORBIDDEN_CLAUDE_ONLY_HEDGE_FILES = [PLAN_SCRUM_MASTER, AGENT_HEALTH, ARCHITECTURE]

# Runtime-specific tool/CLI names that must live only in the operation
# binding table (runtime-adapter.md), never restated in any of the three
# neutral files -- including architecture.md, which used to be the
# Claude-native deep dive but is now held to the same bar as the others.
FORBIDDEN_TOOL_NAMES = [
    "pi-worker spawn",
    "pi-worker send",
    "pi-worker wait",
    "pi-worker resume",
    "pi-worker accept",
    "pi-worker stop",
    "pi-worker inspect",
    "pi-worker workers",
    "`Agent` tool",
    "`Agent`-tool",
    "`SendMessage`",
    "`TaskStop`",
    "`ListAgents`",
    "`agentId`",
    "`subagent_type`",
]
NO_TOOL_NAME_FILES = [PLAN_SCRUM_MASTER, AGENT_HEALTH, ARCHITECTURE]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def normalized(path: Path) -> str:
    return re.sub(r"\s+", " ", read(path))


class OrchestrationRuntimeContractTests(unittest.TestCase):
    def test_orchestration_files_cite_the_binding_not_a_tool(self) -> None:
        """Each rewritten file points at the operation binding instead of
        branching in prose or naming a runtime-specific tool itself."""
        for path in NEUTRAL_FILES:
            text = read(path)
            norm = normalized(path)
            self.assertIn(
                "runtime-adapter.md",
                text,
                f"{path} must cite meta-patterns/runtime-adapter.md",
            )
            for hedge in FORBIDDEN_HEDGES_ANY_FILE:
                self.assertNotIn(hedge, norm, f"{path} still contains hedge: {hedge!r}")
            if path in FORBIDDEN_CLAUDE_ONLY_HEDGE_FILES:
                self.assertNotIn(
                    "Claude native branch only",
                    norm,
                    f"{path} still gates behavior with 'Claude native branch only'",
                )
            if path in NO_TOOL_NAME_FILES:
                for tool in FORBIDDEN_TOOL_NAMES:
                    self.assertNotIn(tool, norm, f"{path} names a runtime tool: {tool!r}")

    def test_claude_native_semantics_survive(self) -> None:
        """Compatibility regression: the native dispatch, resume-not-redispatch,
        and stop semantics must still be derivable from the neutral body plus
        the binding -- this fails if the rewrite lost a Claude behavior."""
        skill = normalized(PLAN_SCRUM_MASTER)
        binding = normalized(
            ROOT / "meta-patterns" / "runtime-adapter.md"
        )

        # Named-worker addressing survives in the neutral body.
        self.assertIn("impl-<bd-id>", skill)
        self.assertIn("rev-<bd-id>", skill)

        # Every operation this skill relies on is named somewhere in the body.
        for op in OPERATIONS:
            self.assertIn(
                op,
                skill,
                f"operation {op!r} is not named anywhere in plan-scrum-master/SKILL.md",
            )

        # The binding itself still carries the concrete Claude surface for
        # each of those operations -- i.e. the native semantics were moved,
        # not deleted.
        self.assertIn("Agent", binding)
        self.assertIn("SendMessage", binding)
        self.assertIn("TaskStop", binding)
        self.assertIn("ListAgents", binding)

        # architecture.md's "why inline only" rationale survives the tool-name
        # strip: nested dispatch is still described as structurally blocked,
        # in operation terms rather than by naming the Agent tool.
        arch = normalized(ARCHITECTURE)
        self.assertIn("no nested-agent recursion", arch)
        self.assertIn("dispatch", arch)
        self.assertIn("wrapper", arch)

    def test_parallelism_is_not_scoped_to_one_runtime(self) -> None:
        """max_parallel / waves / blockers-only / worker_model must not be
        tied to a single runtime anywhere in the orchestrator body."""
        skill = normalized(PLAN_SCRUM_MASTER)
        self.assertNotIn("Claude native branch:** dispatch up to", skill)
        self.assertNotIn(
            "Pi branch:** if no explicit Pi multi-worker adapter is installed, do not dispatch multiple",
            skill,
        )
        self.assertIn("none of them is a", skill)
        self.assertIn("Claude-only or Pi-only setting", skill)

    def test_resume_targets_the_original_worker(self) -> None:
        """The retry instruction must say resume the ORIGINAL worker, never
        a redispatch -- the specific flattening the neutral rewrite risks."""
        skill = normalized(PLAN_SCRUM_MASTER)
        self.assertIn("Resume the ORIGINAL implementer", skill)
        self.assertIn("never a fresh dispatch", skill)
        self.assertIn("same worker, in the same worktree, with its full context", skill)

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
