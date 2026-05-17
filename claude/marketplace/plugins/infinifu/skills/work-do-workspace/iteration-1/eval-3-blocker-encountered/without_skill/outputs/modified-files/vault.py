"""Vault client. ft002 provides this surface today.

This module owns the alias-write primitive used by the credential-rotation
work in sp001 / im002: writers stage a new value under a versioned alias via
`rotate_secret(name, new_value)`; readers continue to call `secret(name)`.
The 5-minute overlap window itself is owned by `vault_rotate` (sp001 Task 2);
this module exposes only the write-staging + alias-flip primitives and the
per-name serialization that keeps concurrent rotations safe.
"""

from __future__ import annotations

import threading
from typing import Dict, List

# Versioned aliases staged per secret name. Empty list = no staged version
# yet, fall back to the legacy read path.
_aliases: Dict[str, List[str]] = {}

# The currently-active value for each name once the overlap window has flipped.
# Before the flip, secret(name) returns the legacy placeholder so live readers
# keep working — that's the whole point of the 5-minute overlap.
_active: Dict[str, str] = {}

# Per-name lock so concurrent rotate_secret(name=k) calls serialize but
# rotate_secret(name=a) and rotate_secret(name=b) can run in parallel.
_locks: Dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


class VaultError(RuntimeError):
    pass


def secret(name: str) -> str:
    """Read a secret by name from vault.

    Returns the current value for `name`. Raises VaultError if unreachable.
    After a rotation has flipped, returns the new value; before the flip,
    returns the legacy alias so existing readers keep working.
    """
    if name in _active:
        return _active[name]
    return _read_alias(name)


def rotate_secret(name: str, new_value: str) -> None:
    """Stage `new_value` under a fresh versioned alias for `name`.

    Per im002: the old alias is left untouched so readers can continue to
    serve the prior value during the overlap window. The actual alias flip
    is owned by vault_rotate (sp001 Task 2) and exposed here as
    _flip_alias for callers that have completed their overlap.

    Raises:
        ValueError: if new_value is empty or None.
        VaultError: if the underlying vault write fails; no partial state is
            left behind.
    """
    if not new_value:
        raise ValueError("new_value must be a non-empty string")

    lock = _lock_for(name)
    with lock:
        # _stage_version is the seam mocked in tests; it raises VaultError on
        # failure, and we let that propagate without recording any state.
        _stage_version(name, new_value)
        _aliases.setdefault(name, []).append(new_value)


def _stage_version(name: str, value: str) -> None:
    """Write a new versioned alias to vault. Real impl talks to vault.

    Mocked in tests to inject failures or observe the critical section.
    """
    # Placeholder: real implementation issues a versioned-alias write to vault.
    return None


def _flip_alias(name: str) -> None:
    """Promote the most-recently-staged version to active.

    Called by vault_rotate at the end of the 5-minute overlap window. After
    this, secret(name) returns the staged value.
    """
    staged = _aliases.get(name)
    if not staged:
        raise VaultError(f"no staged version for {name!r}")
    _active[name] = staged[-1]


def _read_alias(name: str) -> str:
    # Placeholder: real implementation talks to vault.
    return f"<vault:{name}>"


def _lock_for(name: str) -> threading.Lock:
    with _locks_guard:
        lock = _locks.get(name)
        if lock is None:
            lock = threading.Lock()
            _locks[name] = lock
        return lock


def _aliases_for(name: str) -> List[str]:
    """Test-only inspector for staged aliases."""
    return list(_aliases.get(name, []))


def _reset_for_tests() -> None:
    """Test-only: clear all in-memory rotation state."""
    _aliases.clear()
    _active.clear()
    with _locks_guard:
        _locks.clear()


# TODO: set_timeout(timeout_ms) — current default is hardcoded to 5000ms which
# is too short for the European region; needs to become configurable. Out of
# scope for the rotation work but worth tracking.
