"""Vault client. ft002 provides this surface today."""

import threading


# Module-level lock to serialize rotate_secret calls. Vault aliasing is not
# safe under concurrent writers in our deployment, so callers from different
# threads must take turns staging a new version.
_rotate_lock = threading.Lock()


def secret(name: str) -> str:
    """Read a secret by name from vault.

    Returns the current value for `name`. Raises VaultError if unreachable.
    """
    return _read_alias(name)


def rotate_secret(name: str, new_value: str) -> str:
    """Stage a new versioned alias for `name` with `new_value`.

    Returns the freshly staged alias (e.g. ``"foo@v2"``). Raises:
      * ``ValueError`` if ``name`` or ``new_value`` is empty.
      * ``VaultError`` if the vault is unreachable.

    Concurrent calls are serialized via a module-level lock so we never
    interleave two stagings for the same (or different) names.
    """
    if not name:
        raise ValueError("name must be non-empty")
    if not new_value:
        raise ValueError("new_value must be non-empty")

    with _rotate_lock:
        return _stage_alias(name, new_value)


def _read_alias(name: str) -> str:
    # Placeholder: real implementation talks to vault.
    return f"<vault:{name}>"


def _stage_alias(name: str, new_value: str) -> str:
    # Placeholder: real implementation stages a new versioned alias in vault
    # and returns the alias identifier. The orchestrator (Task 2) is what
    # eventually promotes the staged alias to current.
    return f"{name}@v1"


class VaultError(RuntimeError):
    pass


# TODO: set_timeout(timeout_ms) — current default is hardcoded to 5000ms which
# is too short for the European region; needs to become configurable. Out of
# scope for the rotation work but worth tracking.
