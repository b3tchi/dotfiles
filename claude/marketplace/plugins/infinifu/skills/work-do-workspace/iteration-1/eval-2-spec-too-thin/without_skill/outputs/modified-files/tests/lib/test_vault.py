"""Vault smoke + rotation tests.

Covers Task 1 of sp001 (wd2-4179068-rmh.1): `rotate_secret` helper.

Test plan (per spec):
- test_rotate_stages_new_alias — write-staging bug
- test_secret_returns_new_after_flip — stale-read bug
- test_concurrent_rotate_serializes — race condition
- test_vault_unreachable_raises — partial-write bug
- test_empty_value_rejected — input-validation bug
"""

import threading

import pytest

import vault
from vault import VaultError, rotate_secret, secret


@pytest.fixture(autouse=True)
def _reset_vault_state(monkeypatch):
    """Reset module-level alias + lock state between tests."""
    monkeypatch.setattr(vault, "_aliases", {}, raising=True)
    monkeypatch.setattr(vault, "_name_locks", {}, raising=True)
    monkeypatch.setattr(vault, "_locks_guard", threading.Lock(), raising=True)
    yield


def test_secret_returns_value():
    """Original smoke test — unrotated names fall through to the placeholder."""
    assert secret("foo") == "<vault:foo>"


def test_rotate_stages_new_alias():
    """`rotate_secret` records a new versioned alias without dropping prior ones."""
    rotate_secret("db/url", "v1")
    rotate_secret("db/url", "v2")
    # Both versions are retained in order — prior version still present.
    assert vault._aliases["db/url"] == ["v1", "v2"]


def test_secret_returns_new_after_flip():
    """`secret(name)` returns the most recently staged value."""
    assert secret("db/url") == "<vault:db/url>"  # pre-rotation placeholder
    rotate_secret("db/url", "first")
    assert secret("db/url") == "first"
    rotate_secret("db/url", "second")
    assert secret("db/url") == "second"


def test_concurrent_rotate_serializes():
    """Concurrent rotations of the *same* name must serialize, not interleave.

    The check: instrument `_write_alias` to record an `enter`/`exit` event
    pair and observe a small delay between them. If two rotations are
    serialized, every `enter` is immediately followed by its matching
    `exit` before the next `enter` is recorded. If they interleave, the
    pattern `enter:A, enter:B, exit:A, exit:B` (or similar) would appear.
    """
    observed_order: list[str] = []
    observed_lock = threading.Lock()

    original_write = vault._write_alias

    def slow_write(name: str, value: str):
        with observed_lock:
            observed_order.append(f"enter:{value}")
        # Hold inside the critical section long enough that a non-serialized
        # impl would let the other thread interleave between enter and exit.
        threading.Event().wait(0.05)
        with observed_lock:
            observed_order.append(f"exit:{value}")
        return original_write(name, value)

    vault._write_alias = slow_write
    try:
        t1 = threading.Thread(target=rotate_secret, args=("db/url", "A"))
        t2 = threading.Thread(target=rotate_secret, args=("db/url", "B"))
        t1.start()
        t2.start()
        t1.join(timeout=3)
        t2.join(timeout=3)
    finally:
        vault._write_alias = original_write

    # Each rotation's enter/exit pair must be adjacent — no interleave.
    assert len(observed_order) == 4, observed_order
    assert observed_order[0].startswith("enter:")
    assert observed_order[1] == observed_order[0].replace("enter:", "exit:")
    assert observed_order[2].startswith("enter:")
    assert observed_order[3] == observed_order[2].replace("enter:", "exit:")
    # Both values landed.
    assert set(vault._aliases["db/url"]) == {"A", "B"}


def test_concurrent_rotate_different_names_can_parallelize():
    """Different names must NOT serialize against each other.

    Per the spec: 'concurrent rotations of *different* secrets are queued'
    refers to the orchestration layer (Task 2). At the vault layer,
    per-name locks mean rotations of distinct names can proceed in
    parallel.
    """
    in_flight = []
    in_flight_lock = threading.Lock()
    max_concurrent = [0]

    original_write = vault._write_alias

    def slow_write(name: str, value: str):
        with in_flight_lock:
            in_flight.append(name)
            max_concurrent[0] = max(max_concurrent[0], len(in_flight))
        threading.Event().wait(0.05)
        with in_flight_lock:
            in_flight.remove(name)
        return original_write(name, value)

    vault._write_alias = slow_write
    try:
        t1 = threading.Thread(target=rotate_secret, args=("db/a", "v"))
        t2 = threading.Thread(target=rotate_secret, args=("db/b", "v"))
        t1.start()
        t2.start()
        t1.join(timeout=3)
        t2.join(timeout=3)
    finally:
        vault._write_alias = original_write

    # Both names should have been in flight simultaneously at some point.
    assert max_concurrent[0] == 2, f"different names did not parallelize: {max_concurrent[0]}"


def test_vault_unreachable_raises():
    """Write failure raises `VaultError` *and* leaves prior state intact."""
    rotate_secret("db/url", "v1")

    def boom(name: str, value: str):
        raise VaultError("vault unreachable")

    original_write = vault._write_alias
    vault._write_alias = boom
    try:
        with pytest.raises(VaultError):
            rotate_secret("db/url", "v2")
    finally:
        vault._write_alias = original_write

    # No partial write: alias list is unchanged, reads still return prior value.
    assert vault._aliases["db/url"] == ["v1"]
    assert secret("db/url") == "v1"


@pytest.mark.parametrize("bad_value", [None, ""])
def test_empty_value_rejected(bad_value):
    """Empty / None values are rejected at the API boundary."""
    with pytest.raises(ValueError):
        rotate_secret("db/url", bad_value)
    # And no state was created.
    assert "db/url" not in vault._aliases


def test_empty_name_rejected():
    with pytest.raises(ValueError):
        rotate_secret("", "v1")
