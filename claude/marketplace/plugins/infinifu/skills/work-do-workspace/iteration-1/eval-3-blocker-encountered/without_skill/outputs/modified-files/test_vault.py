"""Vault tests covering basic read + rotate_secret behavior.

Per sp001 / im002: writers stage a new versioned alias via rotate_secret(name,
new_value); readers continue to call secret(name) and transparently see the
prior value until the alias flips, then the new value afterwards. The 5-minute
overlap window itself is owned by src/lib/vault_rotate.py (Task 2); vault.py
just exposes the write-staging and alias-flip primitives plus serialization
per-name.
"""

from __future__ import annotations

import threading
from unittest.mock import patch

import pytest

import vault
from vault import VaultError, rotate_secret, secret


@pytest.fixture(autouse=True)
def _reset_vault_state():
    """Each test starts with empty vault state."""
    vault._reset_for_tests()
    yield
    vault._reset_for_tests()


def test_secret_returns_value():
    # Backwards-compat: pre-existing behavior keeps working when no rotation
    # has occurred. Reads fall through to the legacy alias path.
    assert secret("foo") == "<vault:foo>"


def test_rotate_stages_new_alias():
    # rotate_secret writes the new value under a fresh versioned alias and
    # does NOT touch the old alias. Catches a "wrote-over-old-alias" bug.
    rotate_secret("db/password", "new-value")

    aliases = vault._aliases_for("db/password")
    assert "new-value" in aliases
    assert len(aliases) == 1  # only the staged version, old alias path is legacy


def test_secret_returns_new_after_flip():
    # After rotate_secret + alias flip, secret(name) returns the new value.
    # Catches a stale-read bug where the read path keeps returning the legacy
    # placeholder.
    rotate_secret("db/password", "new-value")
    vault._flip_alias("db/password")  # simulates end of overlap window
    assert secret("db/password") == "new-value"


def test_concurrent_rotate_serializes():
    # Concurrent rotate_secret calls for the SAME name must serialize — they
    # cannot interleave, or we could lose a version. Catches a race on the
    # alias-write step.
    observed_during = []

    real_stage = vault._stage_version

    def slow_stage(name, value):
        observed_during.append(("enter", value))
        # Hold the critical section long enough for the other thread to race.
        # If serialization works, the second thread blocks here.
        import time

        time.sleep(0.05)
        observed_during.append(("exit", value))
        return real_stage(name, value)

    with patch.object(vault, "_stage_version", side_effect=slow_stage):
        t1 = threading.Thread(target=rotate_secret, args=("k", "v1"))
        t2 = threading.Thread(target=rotate_secret, args=("k", "v2"))
        t1.start()
        t2.start()
        t1.join()
        t2.join()

    # The exit of one call must precede the enter of the other — no interleaving.
    # i.e. observed_during is [enter A, exit A, enter B, exit B], never
    # [enter A, enter B, ...].
    assert observed_during[0][0] == "enter"
    assert observed_during[1][0] == "exit"
    assert observed_during[2][0] == "enter"
    assert observed_during[3][0] == "exit"
    # And both versions landed.
    assert set(vault._aliases_for("k")) == {"v1", "v2"}


def test_vault_unreachable_raises():
    # When the underlying vault write fails, rotate_secret must raise VaultError
    # and NOT leave a half-staged alias. Catches the partial-write bug.
    with patch.object(vault, "_stage_version", side_effect=VaultError("down")):
        with pytest.raises(VaultError):
            rotate_secret("svc/api-key", "new")

    assert vault._aliases_for("svc/api-key") == []


def test_empty_value_rejected():
    # Empty / None new_value is rejected at the API boundary. Catches input-
    # validation bugs that would write a useless empty credential.
    with pytest.raises(ValueError):
        rotate_secret("svc/api-key", "")
    with pytest.raises(ValueError):
        rotate_secret("svc/api-key", None)  # type: ignore[arg-type]
    # And nothing was staged on either rejected call.
    assert vault._aliases_for("svc/api-key") == []
