"""wiki_references must be LSP-backed and per-call-vault aware."""
from pathlib import Path

import pytest

from server import wiki_references


def test_wiki_references_finds_backlinks(require_markdown_oxide, fixture_vault: Path):
    refs = wiki_references("beta", cwd=str(fixture_vault))
    assert any("alpha" in r.get("path", "") for r in refs)


def test_wiki_references_no_self_link(require_markdown_oxide, fixture_vault: Path):
    refs = wiki_references("alpha", cwd=str(fixture_vault))
    assert not any("alpha.md" in r.get("path", "") for r in refs)


def test_wiki_references_no_rg(monkeypatch, require_markdown_oxide, fixture_vault: Path):
    import subprocess as sp
    real_run = sp.run

    def guarded(args, *a, **kw):
        if isinstance(args, list) and args and args[0] == "rg":
            raise AssertionError("wiki_references must not invoke ripgrep")
        return real_run(args, *a, **kw)

    monkeypatch.setattr(sp, "run", guarded)
    wiki_references("beta", cwd=str(fixture_vault))
