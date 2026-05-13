"""Shared pytest fixtures for wiki-oxide MCP tests."""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

import pytest

# Make server.py importable as a module without running mcp.run().
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


@pytest.fixture
def require_markdown_oxide():
    """Skip the test if markdown-oxide is not on PATH."""
    if not shutil.which("markdown-oxide"):
        pytest.skip("markdown-oxide LSP binary not installed")


@pytest.fixture
def fixture_vault(tmp_path: Path) -> Path:
    """Create a small marker-tagged vault with a few interlinked notes."""
    vault = tmp_path / "docs" / "wiki"
    vault.mkdir(parents=True)
    (vault / ".moxide.toml").write_text("")
    (vault / "alpha.md").write_text(
        "# Alpha\n\nRefers to [[beta]].\n\n#topic-a\n"
    )
    (vault / "beta.md").write_text(
        "# Beta\n\nBacklink target for alpha.\n\n#topic-b\n"
    )
    (vault / "gamma.md").write_text(
        "# Gamma\n\nNo links here.\n"
    )
    return vault


@pytest.fixture
def two_vaults(tmp_path: Path) -> tuple[Path, Path]:
    """Two independent vaults in one project tree — for multi-vault tests."""
    repo = tmp_path / "repo"
    a = repo / "projects" / "a" / "docs" / "wiki"
    b = repo / "projects" / "b" / "docs" / "wiki"
    for v, label in ((a, "a"), (b, "b")):
        v.mkdir(parents=True)
        (v / ".moxide.toml").write_text("")
        (v / f"note-{label}.md").write_text(f"# Note {label}\n")
    return a, b
