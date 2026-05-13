"""Each MCP tool must accept an optional cwd argument and route to that vault."""
from pathlib import Path

import pytest

from server import wiki_list, wiki_root


def test_wiki_root_with_explicit_cwd(fixture_vault: Path):
    assert wiki_root(cwd=str(fixture_vault)) == str(fixture_vault.resolve())


def test_wiki_root_picks_correct_vault_per_call(two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    assert wiki_root(cwd=str(a)) == str(a.resolve())
    assert wiki_root(cwd=str(b)) == str(b.resolve())


def test_wiki_list_with_explicit_cwd(fixture_vault: Path):
    files = wiki_list(cwd=str(fixture_vault))
    assert "alpha.md" in files
    assert "beta.md" in files


def test_wiki_root_no_marker_returns_error(tmp_path: Path):
    result = wiki_root(cwd=str(tmp_path))
    assert isinstance(result, str)
    assert result.startswith("error:")
