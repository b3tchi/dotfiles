"""End-to-end: one MCP server, two vaults, no cross-leak."""
from pathlib import Path

import pytest

from server import wiki_search, wiki_list, _pool


def test_multi_vault_round_trip(require_markdown_oxide, two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    files_a = wiki_list(cwd=str(a))
    files_b = wiki_list(cwd=str(b))
    assert files_a == ["note-a.md"]
    assert files_b == ["note-b.md"]

    sa = wiki_search("note", cwd=str(a))
    sb = wiki_search("note", cwd=str(b))
    names_a = {r.get("name", "").lower() for r in sa}
    names_b = {r.get("name", "").lower() for r in sb}
    assert any("note-a" in n for n in names_a)
    assert not any("note-b" in n for n in names_a)
    assert any("note-b" in n for n in names_b)
    assert not any("note-a" in n for n in names_b)

    assert len(_pool._clients) >= 2
