#!/usr/bin/env python3
"""Markdown section scanning shared by the lifecycle-contract validators.

The lifecycle contract lives in prose, so a static check that only greps for a
phrase can pass on text that says the opposite ("never do X") or on text parked
in an anti-pattern list. These helpers attach every line to the heading stack
that owns it so the validators can require a match in a *normative* section and
allow a Claude-only tool mention inside a Claude-scoped branch.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re

HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*$")

# Headings whose bodies describe what NOT to do. A requirement satisfied only
# inside one of these is not a requirement — it is a warning about its absence.
NON_NORMATIVE = re.compile(
    r"anti[- ]?pattern|common excuses|red flag|pitfall|failure mode|"
    r"what not to do|mistakes",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Line:
    path: Path
    number: int
    text: str
    headings: tuple[str, ...]

    @property
    def section(self) -> str:
        return " > ".join(self.headings)

    @property
    def normative(self) -> bool:
        return not any(NON_NORMATIVE.search(h) for h in self.headings)

    def __str__(self) -> str:
        return f"{self.path.name}:{self.number}: {self.text.strip()[:120]}"


def scan(path: Path) -> list[Line]:
    """Return every line of `path` tagged with the heading stack owning it."""
    lines: list[Line] = []
    stack: list[tuple[int, str]] = []
    in_fence = False
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if raw.lstrip().startswith("```"):
            in_fence = not in_fence
            lines.append(Line(path, number, raw, tuple(t for _, t in stack)))
            continue
        match = None if in_fence else HEADING.match(raw)
        if match:
            level = len(match.group(1))
            while stack and stack[-1][0] >= level:
                stack.pop()
            stack.append((level, match.group(2)))
        lines.append(Line(path, number, raw, tuple(t for _, t in stack)))
    return lines


def find(path: Path, pattern: str, *, normative_only: bool = False) -> list[Line]:
    """Lines in `path` matching `pattern` (case-insensitive regex)."""
    rx = re.compile(pattern, re.IGNORECASE)
    return [
        line
        for line in scan(path)
        if rx.search(line.text) and (line.normative or not normative_only)
    ]


def blocks(path: Path) -> list[Line]:
    """Paragraphs of `path`, each collapsed to one whitespace-normalized Line.

    Skill prose is hard-wrapped at 80 columns, so a rule like "it does not use
    ft012 ... as runtime detection" routinely straddles a line break. Matching
    per line would read the tail half on its own and conclude the opposite of
    what the paragraph says. The reported line number is the paragraph's first.
    """
    grouped: list[Line] = []
    buffer: list[Line] = []

    def flush() -> None:
        if not buffer:
            return
        text = re.sub(r"\s+", " ", " ".join(line.text for line in buffer)).strip()
        grouped.append(
            Line(path, buffer[0].number, text, buffer[0].headings)
        )
        buffer.clear()

    for line in scan(path):
        if line.text.strip():
            buffer.append(line)
        else:
            flush()
    flush()
    return grouped


def find_block(path: Path, pattern: str, *, normative_only: bool = False) -> list[Line]:
    """Paragraphs in `path` matching `pattern` (case-insensitive regex)."""
    rx = re.compile(pattern, re.IGNORECASE)
    return [
        block
        for block in blocks(path)
        if rx.search(block.text) and (block.normative or not normative_only)
    ]
