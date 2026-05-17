"""Vault client. ft002 provides this surface today.

Task 1 (sp001 / wd2-4179068-rmh.1) extends this with:
- `rotate_secret(name, new_value)` — stages a new versioned alias without
  touching the prior version; subsequent `secret(name)` reads return the
  new value once the alias is flipped.
- Concurrent calls for the same `name` serialize via a per-name lock so
  two rotations never interleave; different names rotate in parallel.
- Rejects empty / None values at the API boundary.
- Surfaces vault unreachability as `VaultError` without partial writes
  (alias bookkeeping is updated only after the underlying write succeeds).
"""

from __future__ import annotations

import threading
from typing import Dict


class VaultError(RuntimeError):
    """Raised when the vault backend is unreachable or rejects a write."""


# In-memory store standing in for the real vault backend. Each name maps to
# an ordered list of versioned values; the *last* entry is the current alias
# target. The placeholder `_read_alias` fallback is preserved for names that
# have never been rotated (back-compat with the original smoke test).
_aliases: Dict[str, list[str]] = {}

# Per-name locks so concurrent `rotate_secret(name)` calls serialize. A
# single module-level lock would also work but would serialize *all*
# rotations across the process; the spec only requires same-name
# serialization.
_locks_guard = threading.Lock()
_name_locks: Dict[str, threading.Lock] = {}


def _lock_for(name: str) -> threading.Lock:
    """Return the lock guarding rotations of `name`, creating it on first use."""
    with _locks_guard:
        lock = _name_locks.get(name)
        if lock is None:
            lock = threading.Lock()
            _name_locks[name] = lock
        return lock


def secret(name: str) -> str:
    """Read a secret by name from vault.

    Returns the current value for `name`. If `name` has been rotated, the
    most recently staged value is returned. Raises `VaultError` if the
    backend is unreachable.
    """
    versions = _aliases.get(name)
    if versions:
        return versions[-1]
    return _read_alias(name)


def rotate_secret(name: str, new_value: str) -> None:
    """Stage `new_value` as a new versioned alias for `name`.

    The prior version is left intact so readers in flight during the 5-minute
    overlap window continue to succeed; the orchestration module
    (`vault_rotate.py`, Task 2) is responsible for expiring it.

    Raises:
        ValueError: if `name` or `new_value` is empty / None.
        VaultError: if the underlying write fails. No partial write is
            observable — the alias list is only mutated after the write
            succeeds.
    """
    if not name:
        raise ValueError("rotate_secret: name must be a non-empty string")
    if new_value is None or new_value == "":
        raise ValueError("rotate_secret: new_value must be a non-empty string")

    lock = _lock_for(name)
    with lock:
        try:
            _write_alias(name, new_value)
        except VaultError:
            # Surface unreachable / write-rejected without touching state.
            raise
        # Only mutate bookkeeping after the write succeeds, so a failed
        # `_write_alias` leaves the prior version as the current alias.
        _aliases.setdefault(name, []).append(new_value)


def _read_alias(name: str) -> str:
    # Placeholder: real implementation talks to vault.
    return f"<vault:{name}>"


def _write_alias(name: str, value: str) -> None:
    """Write `value` as a new versioned alias for `name`.

    Placeholder for the real vault backend call. Tests monkeypatch this
    symbol to simulate unreachability.
    """
    # Real implementation talks to vault; in tests this is patched.
    return None


# TODO: set_timeout(timeout_ms) — current default is hardcoded to 5000ms which
# is too short for the European region; needs to become configurable. Out of
# scope for the rotation work but worth tracking.
