#!/usr/bin/env python3
"""ft013: the explicit runtime-selection contract is stated and branch-scoped.

Two things are asserted here. First, that the shared adapter reference actually
carries the three-outcome selection rule and that skills cite it instead of
restating it. Second — the part a phrase grep cannot do — that every mention of
a Claude-only orchestration tool in the lifecycle skills is scoped to the Claude
branch, so a reader in Pi cannot follow an unqualified `Agent` instruction.
"""
from __future__ import annotations

from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mdscan import blocks, find, find_block  # noqa: E402

SKILLS = Path(__file__).resolve().parents[1]
ADAPTER = SKILLS / "meta-patterns" / "runtime-adapter.md"
BOOTSTRAP = SKILLS / "meta-bootstrap" / "SKILL.md"
SCRUM_MASTER = SKILLS / "plan-scrum-master" / "SKILL.md"
SUPERVISED = SKILLS / "plan-supervised" / "SKILL.md"
ARCHITECTURE = SKILLS / "plan-scrum-master" / "references" / "architecture.md"
AGENT_HEALTH = SKILLS / "plan-scrum-master" / "references" / "agent-health.md"

# Files that describe orchestration and are read by both runtimes.
ORCHESTRATION = [SCRUM_MASTER, SUPERVISED, ARCHITECTURE, AGENT_HEALTH]

# Claude-only harness surfaces. Naming one without saying it is Claude-only is
# the defect: a Pi reader would try to call it.
CLAUDE_TOOLS = r"\b(Agent tool|`Agent`|SendMessage|ListAgents|TaskStop)\b"

# A mention is scoped when its own line, or a heading above it, ties it to the
# Claude branch or explicitly withholds it from Pi.
SCOPING = (
    "claude",
    "pi branch",
    "under pi",
    "in pi",
    "must not",
    "do not",
    "does not use",
    "unsupported",
    "adapter",
)


def is_scoped(line) -> bool:
    haystack = (line.text + " " + line.section).lower()
    return any(marker in haystack for marker in SCOPING)


class RuntimeSelectionContractTests(unittest.TestCase):
    def test_adapter_reference_states_all_three_runtime_outcomes(self) -> None:
        self.assertTrue(ADAPTER.exists(), f"missing shared contract: {ADAPTER}")
        text = ADAPTER.read_text(encoding="utf-8")
        for required in (
            "AI_AGENT=pi",
            "unsupported-runtime",
        ):
            self.assertIn(required, text, f"{ADAPTER.name} omits {required}")
        self.assertTrue(
            find_block(ADAPTER, r"native (Agent|agent).*(surface|tool)"),
            "adapter does not name the Claude native surface as a selector",
        )
        self.assertTrue(
            find_block(
                ADAPTER, r"fail closed|fail-closed|Do not silently fall through"
            ),
            "adapter does not require fail-closed selection",
        )

    def test_adapter_reference_keeps_durable_state_runtime_neutral(self) -> None:
        text = ADAPTER.read_text(encoding="utf-8")
        for store in ("`akm`", "`bd`", "Git"):
            self.assertIn(store, text, f"adapter omits durable store {store}")

    def test_adapter_reference_gates_completion_on_validation(self) -> None:
        lines = find_block(ADAPTER, r"cannot report completion|not complete")
        self.assertTrue(lines, "adapter does not gate completion on validation")
        text = ADAPTER.read_text(encoding="utf-8")
        for field in ("result", "validation", "resume command"):
            self.assertIn(field, text, f"completion envelope omits {field}")

    def test_skills_cite_the_shared_adapter_instead_of_restating_it(self) -> None:
        for path in (BOOTSTRAP, SCRUM_MASTER, SUPERVISED):
            self.assertTrue(
                find_block(path, r"runtime-adapter\.md"),
                f"{path.parent.name} does not cite meta-patterns/runtime-adapter.md",
            )

    def test_claude_only_tools_are_never_mentioned_unscoped(self) -> None:
        unscoped = [
            line
            for path in ORCHESTRATION
            for line in find(path, CLAUDE_TOOLS)
            if not is_scoped(line)
        ]
        self.assertEqual(
            [],
            [str(line) for line in unscoped],
            "Claude-only tool named without a Claude/Pi scope marker",
        )

    def test_every_orchestration_file_has_a_pi_branch(self) -> None:
        for path in ORCHESTRATION:
            self.assertTrue(
                find_block(path, r"AI_AGENT=pi|Pi branch"),
                f"{path.name} documents Claude behavior with no Pi branch",
            )

    def test_pi_branch_rules_are_normative_not_only_anti_patterns(self) -> None:
        # Edge case: a static check must not pass because the rule appears only
        # in a warning or anti-pattern list.
        normative = [
            line
            for path in (SCRUM_MASTER, SUPERVISED)
            for line in find_block(path, r"AI_AGENT=pi", normative_only=True)
        ]
        self.assertTrue(
            normative,
            "AI_AGENT=pi appears only inside anti-pattern/warning sections",
        )

    def test_no_file_claims_claude_census_detects_the_runtime(self) -> None:
        for path in ORCHESTRATION:
            for line in blocks(path):
                lowered = line.text.lower()
                if "ft012" not in lowered and "census" not in lowered:
                    continue
                self.assertRegex(
                    lowered,
                    r"does not use|not a pi runtime detector|not a runtime detector"
                    r"|claude agent-surface health|claude native branch",
                    f"{line} treats the Claude census as a runtime detector",
                )


OPERATIONS = (
    "dispatch",
    "send work",
    "await",
    "reject/resume",
    "accept and clean",
    "tear down",
    "inspect",
)


def extract_section(text: str, heading_pattern: str) -> str:
    """Body text of the first heading whose title matches `heading_pattern`,
    stopping at the next heading of equal or shallower level."""
    lines = text.splitlines()
    start = None
    level = None
    for i, line in enumerate(lines):
        match = re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
        if match and re.search(heading_pattern, match.group(2), re.IGNORECASE):
            start = i + 1
            level = len(match.group(1))
            break
    if start is None:
        return ""
    end = len(lines)
    for j in range(start, len(lines)):
        match = re.match(r"^(#{1,6})\s+", lines[j])
        if match and len(match.group(1)) <= level:
            end = j
            break
    return "\n".join(lines[start:end])


def parse_table(section_text: str) -> list[dict[str, str]]:
    """Parse a GitHub-flavored markdown table into a list of row dicts keyed
    by header cell text. Assumes the first `|`-row is the header and the
    second is the `---` separator."""
    rows = [
        line.strip()
        for line in section_text.splitlines()
        if line.strip().startswith("|")
    ]
    if len(rows) < 3:
        return []
    header = [cell.strip() for cell in rows[0].strip("|").split("|")]
    parsed = []
    for row in rows[2:]:
        cells = [cell.strip() for cell in row.strip("|").split("|")]
        parsed.append(dict(zip(header, cells)))
    return parsed


class OperationBindingContractTests(unittest.TestCase):
    """T1: the operation binding table is the single place a runtime tool or
    CLI verb is named, with a filled cell per runtime for every operation."""

    def _binding_rows(self) -> list[dict[str, str]]:
        text = ADAPTER.read_text(encoding="utf-8")
        section = extract_section(text, r"^operation binding$")
        self.assertTrue(section, "## operation binding section not found")
        rows = parse_table(section)
        self.assertTrue(rows, "## operation binding has no table")
        return rows

    def _pi_column(self, header) -> str:
        for key in header:
            if key.lower().startswith("pi"):
                return key
        raise AssertionError(f"no Pi column found among {list(header)}")

    def test_operation_binding_has_a_cell_for_every_runtime(self) -> None:
        rows = self._binding_rows()
        names = [row.get("Operation", "").strip().lower() for row in rows]
        self.assertEqual(
            list(OPERATIONS),
            names,
            "operation binding rows do not match the fixed vocabulary",
        )
        pi_key = self._pi_column(rows[0].keys())
        for row in rows:
            self.assertTrue(
                row.get("Claude native", "").strip(),
                f"{row.get('Operation')} has an empty Claude native cell",
            )
            self.assertTrue(
                row.get(pi_key, "").strip(),
                f"{row.get('Operation')} has an empty Pi cell",
            )

    def test_pi_spawn_cell_names_the_flags_spawn_refuses_without(self) -> None:
        rows = self._binding_rows()
        pi_key = self._pi_column(rows[0].keys())
        dispatch = next(row for row in rows if row["Operation"].strip().lower() == "dispatch")
        cell = dispatch[pi_key]
        for flag in ("--isolation", "--role", "--subject", "--skill"):
            self.assertIn(
                flag, cell, f"dispatch Pi cell is missing {flag}: {cell!r}"
            )

    def test_binding_names_where_run_comes_from(self) -> None:
        run_blocks = find_block(ADAPTER, r"\$RUN")
        self.assertTrue(run_blocks, "adapter never explains $RUN")
        combined = " ".join(block.text.lower() for block in run_blocks)
        for required in ("run", "field", "spawn", "json"):
            self.assertIn(
                required,
                combined,
                f"$RUN explanation does not tie it to spawn's JSON output ({required} missing)",
            )

    def test_unsupported_runtime_is_scoped_to_neither_runtime(self) -> None:
        text = ADAPTER.read_text(encoding="utf-8")
        self.assertNotIn(
            "Multi-worker behavior requires",
            text,
            "Pi paragraph still gates multi-worker behavior on an adapter",
        )
        pi_section = extract_section(text, r"^Pi:")
        self.assertTrue(pi_section, "Pi adapter-outcomes subsection not found")
        self.assertNotRegex(
            pi_section,
            r"unsupported",
            "Pi subsection still conditions its own behavior on unsupported-runtime",
        )
        unsupported_section = extract_section(text, r"^Unsupported runtime$")
        self.assertTrue(unsupported_section, "Unsupported runtime subsection not found")
        self.assertNotIn(
            "multi-worker",
            unsupported_section.lower(),
            "unsupported-runtime scoped to more than the neither-runtime case",
        )


if __name__ == "__main__":
    unittest.main()
