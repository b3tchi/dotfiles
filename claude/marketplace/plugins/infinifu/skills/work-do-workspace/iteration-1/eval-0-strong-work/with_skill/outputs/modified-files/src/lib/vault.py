"""Vault client. ft002 provides this surface today."""

from __future__ import annotations

import threading
from typing import Dict

# Module-level state: {name: {version_int: value_str}}.
# Mutated only inside _LOCK. Tests reset via _reset_state().
_STATE: Dict[str, Dict[int, str]] = {}
_LOCK = threading.Lock()


class VaultError(RuntimeError):
    pass


def secret(name: str) -> str:
    """Read a secret by name from vault.

    Returns the current value for `name`. Raises VaultError if unreachable.
    """
    aliases = _STATE.get(name)
    if aliases:
        # Highest version wins — that's the "flipped" alias.
        latest_version = max(aliases)
        return aliases[latest_version]
    return _read_alias(name)


def rotate_secret(name: str, new_value: str) -> int:
    """Stage a new versioned alias for `name` without touching prior versions.

    Returns the new version number. Raises:
      ValueError if `new_value` is empty or None (input-validation gate).
      VaultError if the backend write fails (no partial state mutation).
    """
    # Boundary validation before taking the lock.
    if new_value is None or new_value == "":
        raise ValueError("new_value must be a non-empty string")

    # Serialize rotations to prevent lost writes / interleaved versions.
    with _LOCK:
        try:
            version = _stage_new_alias(name, new_value)
        except VaultError:
            raise
        except Exception as exc:  # backend connectivity, etc.
            # Wrap unexpected errors as VaultError so callers have a stable type.
            # State is unchanged because _stage_new_alias failed before commit.
            raise VaultError(f"vault rotate failed for {name!r}: {exc}") from exc
        return version


def _stage_new_alias(name: str, value: str) -> int:
    """Write a new versioned alias entry; return the new version number.

    Caller must hold _LOCK.
    """
    aliases = _STATE.setdefault(name, {})
    next_version = max(aliases, default=0) + 1
    aliases[next_version] = value
    return next_version


def _alias_snapshot(name: str) -> Dict[int, str]:
    """Return a shallow copy of the alias map for `name` (test helper)."""
    return dict(_STATE.get(name, {}))


def _reset_state() -> None:
    """Clear all aliases (test helper)."""
    with _LOCK:
        _STATE.clear()


def _read_alias(name: str) -> str:
    # Placeholder: real implementation talks to vault.
    return f"<vault:{name}>"


# TODO: set_timeout(timeout_ms) — current default is hardcoded to 5000ms which
# is too short for the European region; needs to become configurable. Out of
# scope for the rotation work but worth tracking.
