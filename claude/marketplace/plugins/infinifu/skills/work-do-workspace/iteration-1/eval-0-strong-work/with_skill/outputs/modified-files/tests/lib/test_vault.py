"""Vault smoke tests. Add tests as features land."""

from __future__ import annotations

import threading
from unittest.mock import patch

import pytest

import vault
from vault import VaultError, rotate_secret, secret


def setup_function(_func):
    """Reset vault state between tests."""
    vault._reset_state()


def test_secret_returns_value():
    # Pre-existing smoke test — no value staged, falls back to placeholder.
    assert secret("foo") == "<vault:foo>"


def test_rotate_stages_new_alias():
    """rotate_secret writes a new versioned alias without touching the old one."""
    # Stage an initial value so we have a "prior" to preserve.
    rotate_secret("db_password", "v1")
    # Capture the prior alias map before the second rotation.
    prior_aliases = vault._alias_snapshot("db_password")

    rotate_secret("db_password", "v2")

    new_aliases = vault._alias_snapshot("db_password")
    # The new versioned alias must exist in addition to the prior one.
    assert len(new_aliases) == len(prior_aliases) + 1
    # The prior alias entry must be untouched (same version → same value).
    for version, value in prior_aliases.items():
        assert new_aliases[version] == value


def test_secret_returns_new_after_flip():
    """vault.secret(name) returns the new value after the alias flip."""
    rotate_secret("api_key", "old-token")
    assert secret("api_key") == "old-token"

    rotate_secret("api_key", "new-token")
    assert secret("api_key") == "new-token"


def test_concurrent_rotate_serializes():
    """Concurrent rotate_secret calls for the same name serialize, no interleaving."""
    observed_during_critical_section: list[int] = []
    name = "shared"

    original_stage = vault._stage_new_alias

    def slow_stage(n: str, value: str) -> int:
        # Record how many threads are inside the critical section concurrently.
        observed_during_critical_section.append(1)
        try:
            # Yield to other threads — if no lock, they'll pile in here.
            import time as _t
            _t.sleep(0.05)
            return original_stage(n, value)
        finally:
            observed_during_critical_section.pop()

    threads = [
        threading.Thread(target=rotate_secret, args=(name, f"v{i}"))
        for i in range(5)
    ]

    with patch.object(vault, "_stage_new_alias", side_effect=slow_stage):
        for t in threads:
            t.start()
        for t in threads:
            t.join()

    # After all rotations, exactly 5 versioned aliases must exist (no lost writes).
    assert len(vault._alias_snapshot(name)) == 5


def test_vault_unreachable_raises():
    """When the vault backend is unreachable, raise VaultError and do not partial-write."""
    def boom(_name: str, _value: str) -> int:
        raise ConnectionError("vault down")

    before = dict(vault._STATE)  # full state snapshot

    with patch.object(vault, "_stage_new_alias", side_effect=boom):
        with pytest.raises(VaultError):
            rotate_secret("db_password", "v1")

    # No partial write: state is byte-identical to before.
    assert vault._STATE == before


def test_empty_value_rejected():
    """Empty or None new_value is rejected at the API boundary."""
    with pytest.raises(ValueError):
        rotate_secret("db_password", "")
    with pytest.raises(ValueError):
        rotate_secret("db_password", None)  # type: ignore[arg-type]
