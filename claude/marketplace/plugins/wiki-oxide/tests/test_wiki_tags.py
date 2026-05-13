"""wiki_tags must be LSP-backed; frontmatter tags are a documented gap.

Deviation from spec Task 7:
  The spec states markdown-oxide indexes frontmatter/heading tags as
  SymbolKind.Constant (14). Empirical probing shows the opposite:
  - SymbolKind.Constant (14) = inline body `#tag` markers
  - SymbolKind.Key (20) = file/heading anchors (filename#Heading)
  - Frontmatter `tags: [...]` entries = NOT indexed by markdown-oxide at all

  Consequently test_wiki_tags_returns_frontmatter_tags is replaced by
  test_wiki_tags_returns_inline_tags (inline body tags DO surface via kind
  14). The no-rg guard and error path tests are unchanged.
"""
from pathlib import Path

import pytest

from server import wiki_tags


def test_wiki_tags_returns_inline_tags(require_markdown_oxide, tmp_path: Path):
    """Inline body #tag markers surface via LSP as SymbolKind.Constant (14).

    Frontmatter tags are NOT indexed by markdown-oxide — they are absent from
    workspace/symbol results regardless of SymbolKind filter.
    """
    vault = tmp_path / "wiki"
    vault.mkdir()
    (vault / ".moxide.toml").write_text("")
    (vault / "tagged.md").write_text(
        "# Tagged\n\nSome content with #planned and #urgent tags.\n"
    )
    tags = wiki_tags(cwd=str(vault))
    assert isinstance(tags, list)
    assert any(t in ("#planned", "#urgent") for t in tags), (
        f"inline body tags not surfaced; got {tags}"
    )


def test_wiki_tags_empty_vault_returns_empty_list(require_markdown_oxide, tmp_path: Path):
    vault = tmp_path / "empty"
    vault.mkdir()
    (vault / ".moxide.toml").write_text("")
    assert wiki_tags(cwd=str(vault)) == []


def test_wiki_tags_no_rg(monkeypatch, require_markdown_oxide, fixture_vault: Path):
    import subprocess as sp
    real_run = sp.run

    def guarded(args, *a, **kw):
        if isinstance(args, list) and args and args[0] == "rg":
            raise AssertionError("wiki_tags must not invoke ripgrep")
        return real_run(args, *a, **kw)

    monkeypatch.setattr(sp, "run", guarded)
    wiki_tags(cwd=str(fixture_vault))


def test_wiki_tags_no_vault_returns_error(tmp_path: Path):
    result = wiki_tags(cwd=str(tmp_path))
    assert isinstance(result, list)
    assert result and result[0].startswith("error:")
