"""Vault smoke tests. Add tests as features land."""

import threading

import pytest

import vault
from vault import VaultError, rotate_secret, secret


def setup_function(_func):
    # Isolate each test: rotate_secret holds module-level state.
    vault._reset_for_tests()


def test_secret_returns_value():
    # Pre-rotation read path: legacy placeholder.
    assert secret("foo") == "<vault:foo>"


def test_rotate_stages_new_alias():
    # New version is staged; the previous (legacy) value is no longer the
    # one returned, but a prior staged version is preserved alongside.
    rotate_secret("db_password", "v1")
    rotate_secret("db_password", "v2")
    versions = vault._versions("db_password")
    assert versions == ["v1", "v2"], (
        "rotate_secret must append a versioned alias without dropping prior versions"
    )


def test_secret_returns_new_after_flip():
    rotate_secret("api_key", "old")
    assert secret("api_key") == "old"
    rotate_secret("api_key", "new")
    assert secret("api_key") == "new", "alias flip must make the new value current"
    # Prior version still in the version list (overlap window).
    assert "old" in vault._versions("api_key")


def test_concurrent_rotate_serializes():
    # Hammer the same name from many threads; the final version list must
    # contain every value exactly once, no lost writes.
    values = [f"v{i}" for i in range(50)]
    errors: list[BaseException] = []

    def worker(v: str) -> None:
        try:
            rotate_secret("shared", v)
        except BaseException as e:  # noqa: BLE001 — test harness
            errors.append(e)

    threads = [threading.Thread(target=worker, args=(v,)) for v in values]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert errors == []
    versions = vault._versions("shared")
    assert sorted(versions) == sorted(values), (
        "concurrent rotate_secret calls must all land — no lost writes"
    )


def test_vault_unreachable_raises():
    vault._set_unreachable(True)
    with pytest.raises(VaultError):
        rotate_secret("foo", "v1")
    # No partial write: nothing should have been staged.
    assert vault._versions("foo") == []


def test_empty_value_rejected():
    with pytest.raises(ValueError):
        rotate_secret("foo", "")
    with pytest.raises(ValueError):
        rotate_secret("foo", None)  # type: ignore[arg-type]
    assert vault._versions("foo") == []
