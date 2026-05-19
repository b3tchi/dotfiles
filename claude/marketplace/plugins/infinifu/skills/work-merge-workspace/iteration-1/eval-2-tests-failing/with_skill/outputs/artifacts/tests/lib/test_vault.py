"""Vault tests — post-work-do snapshot."""
import threading
import pytest
from vault import secret, rotate_secret, VaultError


def test_rotate_stages_new_alias():
    """Catches missing alias-write bug."""
    rotate_secret("db-url", "v1")
    assert secret("db-url") == "v1"


def test_secret_returns_new_after_flip():
    """Catches stale-read bug."""
    rotate_secret("api-key", "old")
    rotate_secret("api-key", "new")
    assert secret("api-key") == "new"


def test_concurrent_rotate_serializes():
    """Catches race condition — N threads write, all values land."""
    seen: list[str] = []
    def worker(v: str):
        rotate_secret("token", v)
    threads = [threading.Thread(target=worker, args=(f"v{i}",)) for i in range(5)]
    for t in threads: t.start()
    for t in threads: t.join()
    # All 5 versions should be staged (no lost write)
    from vault import _ALIASES
    assert len(_ALIASES["token"]) == 5


def test_empty_value_rejected():
    """Catches input-validation bug."""
    with pytest.raises(ValueError):
        rotate_secret("foo", "")


def test_empty_name_rejected():
    """Catches input-validation bug (name path)."""
    with pytest.raises(ValueError):
        rotate_secret("", "v1")
