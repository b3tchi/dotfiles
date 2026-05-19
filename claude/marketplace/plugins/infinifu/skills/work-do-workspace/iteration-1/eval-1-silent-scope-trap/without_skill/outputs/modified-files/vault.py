"""Vault client. ft002 provides this surface today.

Adds versioned-alias bookkeeping for credential rotation (sp001 / im002).
The in-process state below is intentionally simple: it's the seam the real
vault driver will plug into, but is sufficient for unit tests of rotation
semantics.
"""

from __future__ import annotations

import threading
from typing import Dict, List, Optional


class VaultError(RuntimeError):
    pass


# Per-name lock table — guarantees concurrent rotate_secret calls for the same
# name serialize. A module-level lock guards lookup of the per-name lock so we
# don't race creating it.
_locks_guard = threading.Lock()
_locks: Dict[str, threading.Lock] = {}

# Versioned alias store. Each name maps to an ordered list of versions; the
# last entry is the "current" value returned by secret(). Older entries remain
# readable during the overlap window — the orchestration module (vault_rotate)
# is responsible for expiring them at T+5min.
_aliases: Dict[str, List[str]] = {}

# Optional fault injection hook. Tests set this to simulate vault unreachable.
# Production code never sets it; the default is "reachable".
_unreachable: bool = False


def _lock_for(name: str) -> threading.Lock:
    with _locks_guard:
        lock = _locks.get(name)
        if lock is None:
            lock = threading.Lock()
            _locks[name] = lock
        return lock


def _check_reachable() -> None:
    if _unreachable:
        raise VaultError("vault unreachable")


def secret(name: str) -> str:
    """Read the current value of a secret by name.

    Returns the most recently staged version for `name`. Raises VaultError
    if the vault is unreachable. If `rotate_secret` has not been called for
    `name`, falls back to the legacy placeholder read path so existing
    callers keep working.
    """
    _check_reachable()
    versions = _aliases.get(name)
    if versions:
        return versions[-1]
    return _read_alias(name)


def rotate_secret(name: str, new_value: str) -> None:
    """Stage a new versioned alias for `name` carrying `new_value`.

    Semantics:
    - Writes a new version; does NOT mutate or delete prior versions.
    - Subsequent `secret(name)` calls return `new_value` (alias flipped).
    - Prior versions remain in the version list for the overlap window;
      `vault_rotate` is responsible for expiring them at T+5min.
    - Concurrent calls for the same `name` serialize via a per-name lock.
    - Raises VaultError if vault is unreachable (no partial write).
    - Raises ValueError if `new_value` is empty or None.
    """
    if new_value is None or new_value == "":
        raise ValueError("new_value must be a non-empty string")

    lock = _lock_for(name)
    with lock:
        # Reachability check inside the lock so the failure mode is "no
        # partial write" — if we raise here, the version list is unchanged.
        _check_reachable()
        versions = _aliases.setdefault(name, [])
        versions.append(new_value)


def _versions(name: str) -> List[str]:
    """Internal: inspect the staged version list for `name` (for vault_rotate
    and tests). Returns a copy."""
    return list(_aliases.get(name, []))


def _expire_to(name: str, keep: str) -> None:
    """Internal: drop all versions except `keep` (used by vault_rotate at
    T+5min). No-op if `keep` not present."""
    with _lock_for(name):
        versions = _aliases.get(name, [])
        if keep in versions:
            _aliases[name] = [keep]


def _reset_for_tests() -> None:
    """Test-only helper: clear all in-memory rotation state and fault flags."""
    global _unreachable
    with _locks_guard:
        _locks.clear()
    _aliases.clear()
    _unreachable = False


def _set_unreachable(flag: bool) -> None:
    """Test-only helper: toggle the vault-unreachable fault injection."""
    global _unreachable
    _unreachable = flag


def _read_alias(name: str) -> str:
    # Placeholder: real implementation talks to vault.
    return f"<vault:{name}>"


def set_timeout(timeout_ms: int) -> None:
    """Configure the per-request timeout (broken: never persists)."""
    # FIXME: this assigns to a local that never escapes. Existing bug.
    _timeout = timeout_ms
