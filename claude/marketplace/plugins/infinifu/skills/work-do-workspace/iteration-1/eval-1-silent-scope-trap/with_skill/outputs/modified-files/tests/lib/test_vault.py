"""Vault smoke tests. Add tests as features land."""

import threading
from unittest.mock import patch

import pytest

import vault
from vault import VaultError, rotate_secret, secret


def setup_function(_func):
    # Reset module-level alias state between tests so each test is isolated.
    vault._reset_aliases_for_tests()


def test_secret_returns_value():
    # Baseline read path still works for names with no staged rotation.
    assert secret("foo") == "<vault:foo>"


# --- success_criteria-aligned tests for rotate_secret -----------------------


def test_rotate_stages_new_alias():
    """rotate_secret writes a new versioned alias without touching the old one.

    Maps to: success_criteria #1 and test_plan `test_rotate_stages_new_alias`.
    """
    # Before rotation, secret() returns the underlying alias placeholder.
    assert secret("db_password") == "<vault:db_password>"

    rotate_secret("db_password", "new-pw")

    # The prior alias must still be readable during the overlap window —
    # rotate_secret stages, it does not destroy.
    versions = vault._versions_for_tests("db_password")
    assert len(versions) == 2, f"expected two staged versions, got {versions!r}"
    assert versions[-1] == "new-pw"
    assert versions[0] == "<vault:db_password>"  # prior value preserved


def test_secret_returns_new_after_flip():
    """secret(name) returns the new value after the alias flip.

    Maps to: success_criteria #2 and test_plan `test_secret_returns_new_after_flip`.
    """
    rotate_secret("api_key", "v2-key")

    assert secret("api_key") == "v2-key"


def test_concurrent_rotate_serializes():
    """Concurrent rotate_secret calls for the same name must serialize, not race.

    Maps to: edge_case "Concurrent calls to rotate_secret for the same name
    should serialize" and test_plan `test_concurrent_rotate_serializes`.
    """
    observed_mid_writes = []
    original_stage = vault._stage_alias

    def slow_stage(name, value):
        # Capture the in-flight version list while the lock is held. If two
        # threads run this concurrently, we would see len > 2 here for a
        # single rotation step, which proves the lock is missing.
        observed_mid_writes.append(len(vault._versions_for_tests(name)))
        original_stage(name, value)

    threads = []
    with patch.object(vault, "_stage_alias", side_effect=slow_stage):
        for value in ("a", "b", "c", "d"):
            t = threading.Thread(target=rotate_secret, args=("svc", value))
            threads.append(t)
            t.start()
        for t in threads:
            t.join()

    # End state: one base version + 4 staged rotations == 5 versions exactly.
    # If the lock is missing, two threads can read the same pre-write length
    # and write at the same index, collapsing versions.
    assert len(vault._versions_for_tests("svc")) == 5
    # And the final value must be one of the inputs (not corrupted).
    assert secret("svc") in {"a", "b", "c", "d"}


def test_vault_unreachable_raises():
    """If the underlying vault is unreachable, rotate_secret raises VaultError
    and does not leave a partial write.

    Maps to: edge_case "Vault unreachable: raise VaultError, do not partial-write"
    and test_plan `test_vault_unreachable_raises`.
    """

    def boom(_name, _value):
        raise ConnectionError("vault unreachable")

    with patch.object(vault, "_stage_alias", side_effect=boom):
        with pytest.raises(VaultError):
            rotate_secret("billing", "new-secret")

    # Partial-write guard: no versions should have been recorded for `billing`.
    assert vault._versions_for_tests("billing") == ["<vault:billing>"]


@pytest.mark.parametrize("bad_value", [None, ""])
def test_empty_value_rejected(bad_value):
    """Empty / None new_value must be rejected at the API boundary.

    Maps to: edge_case "Empty / None new_value: reject at the API boundary"
    and test_plan `test_empty_value_rejected`.
    """
    with pytest.raises(VaultError):
        rotate_secret("anything", bad_value)
