"""Tests for the LspPool — one persistent LSP client per vault path."""
from pathlib import Path

import pytest

from server import LspPool


def test_pool_miss_then_hit(require_markdown_oxide, fixture_vault: Path):
    pool = LspPool()
    c1 = pool.get(fixture_vault)
    c2 = pool.get(fixture_vault)
    assert c1 is c2, "same vault must return same client"


def test_pool_two_vaults_two_clients(require_markdown_oxide, two_vaults: tuple[Path, Path]):
    a, b = two_vaults
    pool = LspPool()
    ca = pool.get(a)
    cb = pool.get(b)
    assert ca is not cb
    assert ca.cwd == a.resolve()
    assert cb.cwd == b.resolve()


def test_pool_respawns_after_process_death(require_markdown_oxide, fixture_vault: Path):
    pool = LspPool()
    c1 = pool.get(fixture_vault)
    assert c1.proc is not None
    c1.proc.terminate()
    c1.proc.wait(timeout=5)
    c2 = pool.get(fixture_vault)
    assert c2 is not c1, "dead client must be evicted and replaced"
