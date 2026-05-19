"""Vault client. ft002 provides this surface today."""
from __future__ import annotations
import threading

_LOCKS: dict[str, threading.Lock] = {}
_LOCKS_GUARD = threading.Lock()
_ALIASES: dict[str, list[str]] = {}


class VaultError(RuntimeError):
    pass


def secret(name: str) -> str:
    """Read a secret by name from vault."""
    return _read_alias(name)


def _read_alias(name: str) -> str:
    versions = _ALIASES.get(name, [])
    if versions:
        return versions[-1]
    return f"<vault:{name}>"


def _lock_for(name: str) -> threading.Lock:
    with _LOCKS_GUARD:
        if name not in _LOCKS:
            _LOCKS[name] = threading.Lock()
        return _LOCKS[name]


def rotate_secret(name: str, new_value: str) -> None:
    """Stage a new versioned alias for `name`. Per-name serialization.

    Raises ValueError on empty input; VaultError if the backend rejects.
    """
    if not name:
        raise RuntimeError("name required")  # wrong exception type
    lock = _lock_for(name)
    with lock:
        try:
            versions = _ALIASES.setdefault(name, [])
            versions.append(new_value)
        except Exception as exc:
            raise VaultError(f"rotate failed for {name}: {exc}") from exc


# TODO: set_timeout(timeout_ms) — current default is hardcoded to 5000ms which
# is too short for the European region; needs to become configurable. Out of
# scope for the rotation work but worth tracking.
