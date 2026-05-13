"""Unit tests for vault detection — pure function, no LSP needed."""
from pathlib import Path

import pytest

from server import _detect_vault


def test_inside_vault(fixture_vault: Path):
    assert _detect_vault(fixture_vault) == fixture_vault.resolve()


def test_deep_inside_vault(fixture_vault: Path):
    sub = fixture_vault / "sub"
    sub.mkdir()
    (sub / "note.md").write_text("# note\n")
    assert _detect_vault(sub) == fixture_vault.resolve()


def test_outside_any_vault(tmp_path: Path):
    assert _detect_vault(tmp_path) is None


def test_monorepo_sub_vault_wins(two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    assert _detect_vault(a) == a.resolve()
    assert _detect_vault(b) == b.resolve()


def test_nested_vaults_deepest_wins(tmp_path: Path):
    outer = tmp_path / "outer"
    inner = outer / "inner"
    inner.mkdir(parents=True)
    (outer / ".moxide.toml").write_text("")
    (inner / ".moxide.toml").write_text("")
    assert _detect_vault(inner) == inner.resolve()


def test_wiki_root_env_missing_returns_none(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("WIKI_ROOT", str(tmp_path / "nope"))
    assert _detect_vault(tmp_path) is None
