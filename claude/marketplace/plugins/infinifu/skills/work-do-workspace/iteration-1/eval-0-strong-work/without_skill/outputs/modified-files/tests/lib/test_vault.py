"""Vault smoke tests. Add tests as features land."""

import threading
from unittest.mock import patch

import pytest

import vault
from vault import VaultError, rotate_secret, secret


def test_secret_returns_value():
    assert secret("foo") == "<vault:foo>"


def test_rotate_secret_stages_versioned_alias():
    """rotate_secret stages a new versioned alias for `name`."""
    with patch.object(vault, "_stage_alias") as stage:
        stage.return_value = "foo@v2"
        alias = rotate_secret("foo", "new-value")
    assert alias == "foo@v2"
    stage.assert_called_once_with("foo", "new-value")


def test_rotate_secret_rejects_empty_value():
    with pytest.raises(ValueError):
        rotate_secret("foo", "")


def test_rotate_secret_rejects_empty_name():
    with pytest.raises(ValueError):
        rotate_secret("", "v")


def test_rotate_secret_raises_vault_error_when_unreachable():
    def boom(name, value):
        raise VaultError("vault unreachable")

    with patch.object(vault, "_stage_alias", side_effect=boom):
        with pytest.raises(VaultError):
            rotate_secret("foo", "v")


def test_rotate_secret_serializes_concurrent_calls():
    """Concurrent rotate_secret calls must serialize via the module lock.

    We assert mutual exclusion by recording max concurrency seen inside the
    critical section; with a real lock it must be 1.
    """
    in_flight = 0
    max_seen = 0
    enter_lock = threading.Lock()

    def slow_stage(name, value):
        nonlocal in_flight, max_seen
        with enter_lock:
            in_flight += 1
            if in_flight > max_seen:
                max_seen = in_flight
        # Hold long enough that any unserialized caller would overlap.
        # We use a small sleep but verified by max_seen instead of timing.
        import time

        time.sleep(0.02)
        with enter_lock:
            in_flight -= 1
        return f"{name}@v1"

    with patch.object(vault, "_stage_alias", side_effect=slow_stage):
        threads = [
            threading.Thread(target=rotate_secret, args=("foo", "v"))
            for _ in range(5)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

    assert max_seen == 1, f"expected serialization, observed {max_seen} concurrent"
