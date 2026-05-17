"""Vault client. ft002 provides this surface today."""

from __future__ import annotations

import threading
from typing import Optional


# --- Versioned-alias bookkeeping --------------------------------------------
#
# `_aliases[name]` holds the ordered list of staged values for a secret. The
# tail is the live value returned by `secret(name)`; earlier entries are kept
# so readers mid-rotation can continue serving traffic during the overlap
# window. Removal happens elsewhere (vault_rotate orchestration, Task 2).

_aliases: dict[str, list[str]] = {}

# Per-name locks so two `rotate_secret` calls for the same name serialize.
_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


class VaultError(RuntimeError):
    """Raised when a vault operation cannot complete."""


def _lock_for(name: str) -> threading.Lock:
    with _locks_guard:
        lock = _locks.get(name)
        if lock is None:
            lock = threading.Lock()
            _locks[name] = lock
        return lock


def _stage_alias(name: str, value: str) -> None:
    """Append a new versioned alias for `name`. Patched in tests to inject
    failures (vault-unreachable) and concurrency probes."""
    _aliases.setdefault(name, [f"<vault:{name}>"]).append(value)


def secret(name: str) -> str:
    """Read a secret by name from vault.

    Returns the current value for `name`. Raises VaultError if unreachable.
    """
    versions = _aliases.get(name)
    if versions:
        return versions[-1]
    return _read_alias(name)


def rotate_secret(name: str, new_value: Optional[str]) -> None:
    """Stage `new_value` as the next versioned alias for `name`.

    The prior version is preserved so in-flight readers can finish during the
    overlap window managed by the rotation orchestrator. Concurrent calls
    for the same `name` serialize via a per-name lock; concurrent calls for
    *different* names proceed in parallel.

    Raises:
        VaultError: if `new_value` is empty/None, or if the underlying
            vault is unreachable. Partial writes are not retained.
    """
    if not new_value:
        raise VaultError("rotate_secret requires a non-empty new_value")

    # Ensure the base alias is present so readers have a value to fall back on
    # even before any rotation. This also makes the "no partial-write on
    # failure" guarantee observable.
    _aliases.setdefault(name, [f"<vault:{name}>"])

    lock = _lock_for(name)
    with lock:
        try:
            _stage_alias(name, new_value)
        except Exception as exc:
            # Wrap any underlying-client failure as VaultError without
            # leaving a partial alias behind. _stage_alias either appends
            # atomically or doesn't — if it raised before appending, the
            # list is unchanged.
            raise VaultError(f"vault unreachable while rotating {name!r}") from exc


def _read_alias(name: str) -> str:
    # Placeholder: real implementation talks to vault.
    return f"<vault:{name}>"


def set_timeout(timeout_ms: int) -> None:
    """Configure the per-request timeout (broken: never persists)."""
    # FIXME: this assigns to a local that never escapes. Existing bug.
    # Tracked separately as wd1-4177092-pdh (discovered-from t8l.1).
    _timeout = timeout_ms


# --- Test helpers -----------------------------------------------------------
#
# These are intentionally underscore-prefixed and meant for tests only. They
# expose internal state so success criteria can be asserted without leaking
# implementation details into the public API.


def _versions_for_tests(name: str) -> list[str]:
    return list(_aliases.get(name, []))


def _reset_aliases_for_tests() -> None:
    _aliases.clear()
    with _locks_guard:
        _locks.clear()
