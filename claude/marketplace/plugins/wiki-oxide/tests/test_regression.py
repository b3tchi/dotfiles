"""Regression tests — the two original bugs that caused the ripgrep swap."""
import time
from pathlib import Path

import pytest

from server import wiki_search, wiki_preview


def test_cache_staleness(require_markdown_oxide, fixture_vault: Path):
    initial = wiki_search("delta", cwd=str(fixture_vault))
    assert not any("delta" in r.get("name", "").lower() for r in initial)
    (fixture_vault / "delta.md").write_text("# Delta\n\nFresh note.\n")
    time.sleep(0.1)
    later = wiki_search("delta", cwd=str(fixture_vault))
    assert any("delta" in r.get("name", "").lower() for r in later), (
        "cache staleness — delta.md created after first query but not visible"
    )


def test_hover_wedge_does_not_hang(require_markdown_oxide, fixture_vault: Path):
    deadline = time.time() + 30
    for i in range(50):
        if time.time() > deadline:
            pytest.fail(f"wiki_preview hung — only completed {i} of 50")
        result = wiki_preview("alpha", cwd=str(fixture_vault))
        assert "alpha" in result.get("name", "").lower()
