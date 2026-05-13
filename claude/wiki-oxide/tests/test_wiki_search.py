"""wiki_search must be LSP-backed and per-call-vault aware."""
from pathlib import Path

import pytest

from server import wiki_search


def test_wiki_search_finds_note_by_name(require_markdown_oxide, fixture_vault: Path):
    results = wiki_search("alpha", cwd=str(fixture_vault))
    assert any(r.get("name", "").lower().startswith("alpha") for r in results)


def test_wiki_search_finds_note_by_heading(require_markdown_oxide, fixture_vault: Path):
    results = wiki_search("Beta", cwd=str(fixture_vault))
    assert any("beta" in r.get("name", "").lower() for r in results)


def test_wiki_search_two_vaults_no_cross_leak(require_markdown_oxide, two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    ra = wiki_search("note-a", cwd=str(a))
    rb = wiki_search("note-a", cwd=str(b))
    assert any("note-a" in r.get("name", "").lower() for r in ra)
    assert not any("note-a" in r.get("name", "").lower() for r in rb)


def test_wiki_search_no_rg_invocation(monkeypatch, require_markdown_oxide, fixture_vault: Path):
    import subprocess as sp
    real_run = sp.run

    def guarded(args, *a, **kw):
        if isinstance(args, list) and args and args[0] == "rg":
            raise AssertionError("wiki_search must not invoke ripgrep")
        return real_run(args, *a, **kw)

    monkeypatch.setattr(sp, "run", guarded)
    wiki_search("alpha", cwd=str(fixture_vault))
