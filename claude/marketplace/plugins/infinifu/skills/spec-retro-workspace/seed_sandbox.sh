#!/usr/bin/env bash
# Seed an Acme-platform sandbox with a small AKM workspace so idea-feature has
# real personas/stories/features/categories/ADRs/implementations to survey.
set -euo pipefail

SANDBOX_REL="${1:?sandbox dir required}"
EVAL_ID="${2:-0}"
rm -rf "$SANDBOX_REL"
mkdir -p "$SANDBOX_REL"
SANDBOX="$(cd "$SANDBOX_REL" && pwd)"
cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"
git config user.name "eval"

# ----- Codebase skeleton ---------------------------------------------------
cat > README.md <<'EOF'
# Acme Internal Platform

Small internal services platform for Acme Corp. Python + Postgres,
a few Go workers. Internal traffic only (behind VPN).

## Conventions
- Services live under `src/services/<name>/`
- Shared libs in `src/lib/`
- Each service has its own ad-hoc email helper today (no shared notif layer)

## Current services
- `auth`   — SSO + password+TOTP (uses ft001 basic-auth)
- `metrics` — Prometheus scraper, alerts via stdout for now
- `reports` — analyst-facing report runner; emails CSV when done

The AKM workspace lives under `docs/`.
EOF

mkdir -p src/services/auth src/services/metrics src/services/reports src/lib
cat > src/services/auth/__init__.py <<'EOF'
# Auth service. Sends welcome emails by shelling to `mail` directly.
# Should migrate to a shared notifications feature once one exists.
EOF
cat > src/services/metrics/__init__.py <<'EOF'
# Metrics scraper. Alert path currently writes to stdout + ad-hoc smtplib.
EOF
cat > src/services/reports/__init__.py <<'EOF'
# Report runner for analysts. Uses smtplib to email finished CSVs.
EOF
cat > src/lib/__init__.py <<'EOF'
# Shared libs (vault, db helpers).
EOF

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
EOF

# ----- AKM workspace -------------------------------------------------------
mkdir -p docs/notes/spec docs/notes/daily docs/assets
touch docs/notes/.gitkeep docs/assets/.gitkeep

cat > docs/product.md <<'EOF'
# Product

Acme Internal Platform — small set of internal services serving the
operations analyst and the platform-engineer personas.

## Stories

### [[pn001|analyst]]

- [[us001|view dashboard of recent reports]] >> [[im001]]
- [[us002|filter reports by date range]]

### [[pn002|platform-engineer]]

- [[us003|rotate service credentials without downtime]]

## Features

- [[ft001|basic-auth (password+TOTP)]]
- [[ft002|vault-secrets]]

## Architecture Decision Records

### [[cat001|security]]

- [[adr0001|All services authenticate via ft001 basic-auth]]

### [[cat002|data]]

- [[adr0002|Reports written to Postgres, retained 90 days]]

## Categories

- [[cat001|security]] — [[cat002|data]] — [[cat003|infrastructure]]

## AKM Reference

- [[akm]] — knowledge model: every zettel type, its schema and life-cycle
EOF

cat > docs/board.md <<'EOF'
# Board

Nothing in flight right now.

## idea

## spec

## ready
EOF

cat > docs/archive.md <<'EOF'
# Archive

No shipped specs yet.

## done
EOF

# Personas
cat > docs/notes/pn001.md <<'EOF'
---
aliases:
  - analyst
status: validated
created: 2026-04-01
---
# Persona [[product]]

## name
Operations Analyst

## summary
Internal analyst who runs ad-hoc and scheduled reports against the
Postgres warehouse. Lives in the reports service UI and email.

## primary_goals
- Pull report results without engineering help
- Get notified when long-running reports finish

## open_questions

---

Index: [[product]]
EOF

cat > docs/notes/pn002.md <<'EOF'
---
aliases:
  - platform-engineer
status: validated
created: 2026-04-01
---
# Persona [[product]]

## name
Platform Engineer

## summary
Owns the internal services platform. Cares about uptime, rotation,
and operational ergonomics.

## primary_goals
- Keep services healthy
- Rotate credentials cleanly

## open_questions

---

Index: [[product]]
EOF

# Stories
cat > docs/notes/us001.md <<'EOF'
---
aliases:
  - view dashboard of recent reports
status: done
created: 2026-04-05
---
# Story [[reports-flow]] [[product]]

## role
[[pn001|analyst]]

## want
view a dashboard of my recently-run reports

## because
so I can pick one to re-run or share without digging through email

## acceptance_criteria
- Dashboard lists the last 20 reports the analyst ran
- Each row links to the CSV
- Status (queued / running / done / failed) visible per row

---

Index: [[product]]
EOF

cat > docs/notes/us002.md <<'EOF'
---
aliases:
  - filter reports by date range
status: ready
created: 2026-04-12
---
# Story [[reports-flow]] [[product]]

## role
[[pn001|analyst]]

## want
filter the dashboard by date range

## because
quarter-end reviews need a specific window

## acceptance_criteria
- Date picker on the dashboard
- Filter applied client-side over the last 20 rows
- Clearing the filter restores full list

---

Index: [[product]]
EOF

cat > docs/notes/us003.md <<'EOF'
---
aliases:
  - rotate service credentials without downtime
status: ready
created: 2026-04-15
---
# Story [[platform-flow]] [[product]]

## role
[[pn002|platform-engineer]]

## want
rotate service credentials without downtime

## because
quarterly secret-rotation is currently a maintenance-window task

## acceptance_criteria
- Rotation script can swap secrets while services run
- Old secret stays valid for 5 minutes after rotation
- No 5xx during rotation window in synthetic check

---

Index: [[product]]
EOF

# us004 — DRAFT with vague AC (for vague-ac gate eval)
cat > docs/notes/us004.md <<'EOF'
---
aliases:
  - search reports somehow
status: draft
created: 2026-04-22
---
# Story [[reports-flow]] [[product]]

## role
[[pn001|analyst]]

## want
search reports somehow

## because
finding old reports is hard

## acceptance_criteria
- it works
- fast enough

---

Index: [[product]]
EOF

# us005 — DRAFT referencing a persona that does NOT exist (pn999)
cat > docs/notes/us005.md <<'EOF'
---
aliases:
  - quarterly audit-log export
status: draft
created: 2026-04-25
---
# Story [[compliance-flow]] [[product]]

## role
[[pn999|compliance-officer]]

## want
export a quarterly audit log of all data deletions

## because
legal asks for proof of deletion every quarter

## acceptance_criteria
- CSV export of all rows hard-deleted in the trailing quarter
- Includes deletion timestamp, table, primary-key, and triggering job id
- Output signed with a vault-managed key for tamper-evidence

---

Index: [[product]]
EOF

# Implementation
cat > docs/notes/im001.md <<'EOF'
---
aliases:
  - reports dashboard via reports-service UI
status: accepted
created: 2026-04-20
---
# Implementation [[cat002]] [[cat003]]

## solves
[[us001|view dashboard of recent reports]]

## approach
Add a `/dashboard` route to the reports service rendering the last 20
rows from the existing `report_runs` table. Authenticates via ft001.

## features
- [[ft001|basic-auth]]

## data_model
No schema change; reads `report_runs` as-is.

## api_surface
- `GET /dashboard` → HTML page
- `GET /dashboard/data.json` → JSON for client filtering

## components
- `src/services/reports/dashboard.py`
- `src/services/reports/templates/dashboard.html`

## specs
- (shipped before sp### era)

---

Index: [[product]]
EOF

# Features
cat > docs/notes/ft001.md <<'EOF'
---
aliases:
  - basic-auth (password+TOTP)
status: stable
created: 2026-03-15
---
# Feature [[cat001]] [[product]]

## providing
Password + TOTP authentication shared across all services. Consumers
get a `require_auth` decorator and a `current_user()` helper. No SSO,
no SAML, no OAuth — those are explicit non-goals for now.

## api_surface
```python
from acme.lib.basic_auth import require_auth, current_user

@require_auth
def handler(request): ...
```

## data_model
Owns the `users` and `totp_secrets` tables. Sessions stored in Redis,
24h TTL.

## sample
See `src/lib/basic_auth_sample.py` (not shipped — illustrative).

## components
- `src/lib/basic_auth.py`

---

Index: [[product]]
EOF

cat > docs/notes/ft002.md <<'EOF'
---
aliases:
  - vault-secrets
status: stable
created: 2026-03-20
---
# Feature [[cat001]] [[product]]

## providing
Vault-backed secret retrieval. Every service calls `secret(name)` to
read credentials at runtime.

## api_surface
```python
from acme.lib.vault import secret
db_url = secret("reports/db_url")
```

## data_model
None local. Vault is the source of truth.

## sample
`src/lib/vault.py` ships the canonical client.

## components
- `src/lib/vault.py`

---

Index: [[product]]
EOF

# Categories
cat > docs/notes/cat001.md <<'EOF'
---
aliases:
  - security
status: stable
created: 2026-03-10
---
# Category [[product]]

## name
security

## summary
Authentication, authorization, secret handling, audit trails.

---

Index: [[product]]
EOF

cat > docs/notes/cat002.md <<'EOF'
---
aliases:
  - data
status: stable
created: 2026-03-10
---
# Category [[product]]

## name
data

## summary
Persistence, schema, retention, query patterns.

---

Index: [[product]]
EOF

cat > docs/notes/cat003.md <<'EOF'
---
aliases:
  - infrastructure
status: stable
created: 2026-03-10
---
# Category [[product]]

## name
infrastructure

## summary
Deployment, networking, message brokers, cross-service plumbing.

---

Index: [[product]]
EOF

cat > docs/notes/cat004.md <<'EOF'
---
aliases:
  - observability
status: stable
created: 2026-03-10
---
# Category [[product]]

## name
observability

## summary
Metrics, logging, tracing, alerting paths.

---

Index: [[product]]
EOF

# ADRs
cat > docs/notes/adr0001.md <<'EOF'
---
aliases:
  - All services authenticate via ft001 basic-auth
status: Accepted
created: 2026-03-16
---
# ADR [[cat001]] [[product]]

## title
All services authenticate via ft001 basic-auth

## context
We have three services. Each writing its own auth would lead to drift
and divergent session handling.

## decision
Every service uses ft001 (password+TOTP). SSO/SAML deferred until a
real external-identity story shows up.

## consequences
- One place to fix auth bugs.
- External SSO would require a new feature, not extending ft001.

---

Index: [[product]]
EOF

cat > docs/notes/adr0002.md <<'EOF'
---
aliases:
  - Reports written to Postgres, retained 90 days
status: Accepted
created: 2026-03-21
---
# ADR [[cat002]] [[product]]

## title
Reports written to Postgres, retained 90 days

## context
Analysts asked for re-run; legal asked for bounded retention.

## decision
Reports persisted in Postgres `report_runs`. Hard delete after 90 days
via nightly job.

## consequences
- Cheap re-runs for 90 days.
- Long-running historical analysis must export off-platform.

---

Index: [[product]]
EOF

cat > docs/notes/adr0003.md <<'EOF'
---
aliases:
  - No external SMTP relay — services use smtplib directly
status: Accepted
created: 2026-03-25
---
# ADR [[cat003]] [[product]]

## title
No external SMTP relay — services use smtplib directly

## context
We need email for welcome / alert / report-ready. Adding a relay
service was deemed premature.

## decision
Each service uses Python `smtplib` directly against the internal MTA.
No retries, no templates, no dedup.

## consequences
- Three copy/paste smtplib snippets across services.
- Any change to MTA host requires editing three places.
- No metrics on send rate, bounces, or latency.

---

Index: [[product]]
EOF

# Copy akm.md so the skill can read schema in-sandbox
cp /home/jan/.dotfiles/claude/akm/akm.md docs/notes/akm.md

# ----- Stub src/lib/vault.py (work-do will modify this) -------------------
cat > src/lib/vault.py <<'EOF'
"""Vault client. ft002 provides this surface today."""


def secret(name: str) -> str:
    """Read a secret by name from vault.

    Returns the current value for `name`. Raises VaultError if unreachable.
    """
    return _read_alias(name)


def _read_alias(name: str) -> str:
    # Placeholder: real implementation talks to vault.
    return f"<vault:{name}>"


class VaultError(RuntimeError):
    pass


# TODO: set_timeout(timeout_ms) — current default is hardcoded to 5000ms which
# is too short for the European region; needs to become configurable. Out of
# scope for the rotation work but worth tracking.
EOF

mkdir -p tests/lib
cat > tests/lib/__init__.py <<'EOF'
EOF
cat > tests/lib/test_vault.py <<'EOF'
"""Vault smoke tests. Add tests as features land."""

from vault import secret


def test_secret_returns_value():
    assert secret("foo") == "<vault:foo>"
EOF

# Minimal pyproject so pytest finds vault on the path
cat > pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools"]
build-backend = "setuptools.build_meta"

[project]
name = "acme"
version = "0.0.0"

[tool.pytest.ini_options]
pythonpath = ["src/lib"]
testpaths = ["tests"]
EOF

# ----- Base sp001 at status: ready WITH plan + tasks + #### bd ------------
cat > docs/notes/spec/sp001.md <<'EOF'
---
aliases:
  - rotate service credentials without downtime
status: ready
created: 2026-04-28
---
# Spec [[cat001]] [[cat003]] [[board]]

## solves
[[us003|rotate service credentials without downtime]]

## implements
[[im002|vault-policy credential rotation for live services]]

## problem
The platform-engineer [[pn002]] needs to rotate service credentials without
downtime. Story [[us003]] asks for live rotation with a 5-minute overlap and
zero 5xx during the rotation window.

## solution
Adopt the vault-rotate-policy pattern via [[ft002|vault-secrets]]: writers
stage the new credential under a versioned alias using `vault.secret(name)`
read path and an internal `vault.rotate_secret(name)` helper from
[[im002]]. Readers continue calling `secret(name)` — they transparently get
either the new or the prior value during the 5-minute overlap. After the
window, the prior version expires.

Binds [[adr0001]] and [[adr0002]]. Categories [[cat001]] and [[cat003]].

## plan
**Files:**
- `src/lib/vault.py` — extend with `rotate_secret(name)` helper + versioned-alias bookkeeping
- `src/lib/vault_rotate.py` — new orchestration module: holds the 5-minute overlap timer + expiry
- `tests/lib/test_vault_rotate.py` — new test module

**Conventions:** Python 3.11+, type hints required, exceptions inherit `acme.errors.VaultError`.

**Anti-patterns:**
- No bare `except:` — must catch specific exceptions
- No `time.sleep` for overlap timing — use a scheduler hook
- No mutation of vault state outside `vault.py` / `vault_rotate.py`

**Known limitations:** initial release supports one rotation at a time per service; concurrent rotations of different secrets are queued.

## tasks

### Task 1: Add rotate_secret helper to vault.py

#### type
task

#### effort
3h

#### depends
- (none — root task)

#### files_touched
- `src/lib/vault.py`
- `tests/lib/test_vault.py`

#### success_criteria
- `vault.rotate_secret(name, new_value)` writes a new versioned alias without touching the old one
- `vault.secret(name)` returns the new value after the alias flip
- 5 unit tests pass covering write-staging, read-during-overlap, post-expiry behavior

#### edge_cases
- Concurrent calls to `rotate_secret` for the same name should serialize
- Vault unreachable: raise `VaultError`, do not partial-write
- Empty / None `new_value`: reject at the API boundary

#### test_plan
- `test_rotate_stages_new_alias` — catches missing alias-write bug
- `test_secret_returns_new_after_flip` — catches stale-read bug
- `test_concurrent_rotate_serializes` — catches race condition
- `test_vault_unreachable_raises` — catches partial-write bug
- `test_empty_value_rejected` — catches input-validation bug

### Task 2: Add vault_rotate orchestration module

#### type
task

#### effort
5h

#### depends
- Task 1

#### files_touched
- `src/lib/vault_rotate.py`
- `tests/lib/test_vault_rotate.py`

#### success_criteria
- `rotate(name, new_value)` calls `vault.rotate_secret` then schedules expiry at T+5min
- Old alias is removed at T+5min (verified via vault.secret after window)
- 4 unit tests pass covering schedule, expiry, early-failure rollback, and reschedule-on-restart

#### edge_cases
- Scheduler crash between rotate and expiry: on restart, finish pending expiries
- Clock skew >30s: still expire correctly using monotonic clock
- Rotate called twice for same name within window: queue second, do not overlap windows

#### test_plan
- `test_rotate_schedules_expiry` — catches missing scheduler hook
- `test_expiry_removes_old_alias` — catches leak bug
- `test_restart_completes_pending` — catches state-loss bug
- `test_double_rotate_queues` — catches overlap-window bug

### Task 3: Synthetic-check hook for rotation window

#### type
task

#### effort
4h

#### depends
- Task 1
- Task 2

#### files_touched
- `src/lib/vault_rotate.py`
- `tests/integration/test_rotate_synthetic.py`

#### success_criteria
- Synthetic check runs every 30s during rotation window
- Zero 5xx observed in the synthetic check for a successful rotation
- Integration test simulates rotation + synthetic load + asserts no 5xx

#### edge_cases
- Synthetic check fails mid-window: alert, do not roll back automatically
- Network blip causes one 5xx: tolerate single transient, not two consecutive
- Window ends with synthetic still in flight: drain before flipping

#### test_plan
- `test_synthetic_runs_every_30s` — catches scheduler miss bug
- `test_no_5xx_during_window` — catches the core AC
- `test_single_blip_tolerated` — catches over-eager alerting

---

Index: [[board]]
EOF

# Base im002 — finalized back-link from spec-refinement
cat > docs/notes/im002.md <<'EOF'
---
aliases:
  - vault-policy credential rotation for live services
status: accepted
created: 2026-04-26
---
# Implementation [[cat001]] [[cat003]]

## solves
[[us003|rotate service credentials without downtime]]

## approach
Adopt the vault-rotate-policy pattern via [[ft002]]: writers stage the
new credential under a versioned alias; readers fall back to the prior
version for up to 5 minutes; alias flips at the end of the window.

## features
- [[ft002|vault-secrets]]

## data_model
No schema change. Vault holds versioned aliases.

## api_surface
`acme.lib.vault.secret(name)` continues to be the only read path; writes
use a new internal `rotate_secret(name)` helper that lands in the same lib.

## components
- `src/lib/vault.py`
- `src/lib/vault_rotate.py`

## specs
- [[sp001|rotate service credentials without downtime]]

---

Index: [[product]]
EOF

# board.md with sp001 under ## ready (post spec-ready state)
cat > docs/board.md <<'EOF'
# Board

One spec ready for execution.

## idea

## spec

## ready

- [[sp001|rotate service credentials without downtime]]
EOF

# ----- bd init + mint epic + 3 tasks (post spec-ready state) -------------
# Unique prefix per eval+config to avoid Dolt cross-contamination across sandboxes.
PREFIX="wd${EVAL_ID}-$$"
BD_NON_INTERACTIVE=1 bd init --prefix "$PREFIX" --role maintainer >/dev/null 2>&1 || \
  BD_NON_INTERACTIVE=1 bd init --prefix "$PREFIX" >/dev/null 2>&1 || true

# Mint epic + tasks. Capture ids back into sp001's #### bd annotations.
EPIC_ID=$(bd create "Epic: rotate service credentials without downtime [sp001]" \
  --type epic \
  --priority 2 \
  --design "Spec: docs/notes/spec/sp001.md" \
  --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id') or d.get('issue',{}).get('id',''))" 2>/dev/null || echo "")

T1_ID=$(bd create "Task 1: Add rotate_secret helper to vault.py" \
  --type task --priority 2 --parent "$EPIC_ID" \
  --design "Extend src/lib/vault.py with rotate_secret(name, new_value) helper that stages a new versioned alias. Files: src/lib/vault.py, tests/lib/test_vault.py. Edge cases: concurrent calls serialize, vault unreachable raises VaultError, empty value rejected." \
  --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id') or d.get('issue',{}).get('id',''))" 2>/dev/null || echo "")

T2_ID=$(bd create "Task 2: Add vault_rotate orchestration module" \
  --type task --priority 2 --parent "$EPIC_ID" \
  --design "Create src/lib/vault_rotate.py with rotate(name, new_value) that calls vault.rotate_secret + schedules T+5min expiry. Files: src/lib/vault_rotate.py, tests/lib/test_vault_rotate.py." \
  --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id') or d.get('issue',{}).get('id',''))" 2>/dev/null || echo "")

T3_ID=$(bd create "Task 3: Synthetic-check hook for rotation window" \
  --type task --priority 2 --parent "$EPIC_ID" \
  --design "Hook a synthetic check that runs every 30s during rotation window; assert zero 5xx. Files: src/lib/vault_rotate.py, tests/integration/test_rotate_synthetic.py." \
  --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id') or d.get('issue',{}).get('id',''))" 2>/dev/null || echo "")

# Blocking deps
bd dep add "$T2_ID" "$T1_ID" >/dev/null 2>&1 || true
bd dep add "$T3_ID" "$T1_ID" >/dev/null 2>&1 || true
bd dep add "$T3_ID" "$T2_ID" >/dev/null 2>&1 || true

# Annotate sp001 with the real bd ids
python3 - "$T1_ID" "$T2_ID" "$T3_ID" <<'PY'
import sys, re, pathlib
ids = sys.argv[1:4]
p = pathlib.Path('docs/notes/spec/sp001.md')
body = p.read_text()
counter = [0]
def add_bd(match):
    if counter[0] >= len(ids):
        return match.group(0)
    bd_id = ids[counter[0]]
    counter[0] += 1
    return f"{match.group(0)}\n\n#### bd\n{bd_id}"
body = re.sub(r"(### Task \d+:[^\n]+)", add_bd, body)
p.write_text(body)
PY

# Stash task ids in a known file so eval prompts can reference them
cat > .work-do-task-ids.json <<EOF
{
  "epic": "$EPIC_ID",
  "task_1": "$T1_ID",
  "task_2": "$T2_ID",
  "task_3": "$T3_ID"
}
EOF

# ----- Simulate post-work-do state ----------------------------------------
# All work-audit evals start from a "post-work-do" snapshot: Task 1 is
# in_progress, vault.py has a rotate_secret implementation, tests/lib has
# the corresponding tests. Per-eval mutations vary what's in the code/tests
# to give the audit something to either approve or reject.

# Claim Task 1 (implementer transition)
bd update "$T1_ID" --status in_progress >/dev/null 2>&1 || true

# Strong implementation of rotate_secret in vault.py + meaningful tests
# (this is the eval-0 "approve" baseline; per-eval blocks below mutate)
cat > src/lib/vault.py <<'EOF'
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
    if not name or new_value is None or new_value == "":
        raise ValueError("rotate_secret requires non-empty name and value")
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
EOF

cat > tests/lib/test_vault.py <<'EOF'
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
EOF

# Implementer evidence note on Task 1
bd update "$T1_ID" --notes "IMPLEMENTED: rotate_secret helper added to vault.py.

Evidence:
- vault.rotate_secret(name, new_value) stages versioned alias: src/lib/vault.py:36
- secret(name) returns latest after flip: tests/lib/test_vault.py::test_secret_returns_new_after_flip
- Concurrent serialization via per-name lock: src/lib/vault.py:24
- Empty value rejected with ValueError: tests/lib/test_vault.py::test_empty_value_rejected
- Tests: 5 passed (test_vault.py)
Deviations: none" >/dev/null 2>&1 || true

# ----- Advance to post-work-audit state -----------------------------------
# All bd tasks closed by work-audit. Sp001 + us003 + im002 flipped to ready
# state (not done — work-merge will flip those). Add archive.md.

# Close all 3 tasks (post-audit)
bd close "$T1_ID" --reason "AUDITED: APPROVED. rotate_secret meets all criteria." >/dev/null 2>&1 || true
bd close "$T2_ID" --reason "AUDITED: APPROVED. vault_rotate orchestration meets all criteria." >/dev/null 2>&1 || true
bd close "$T3_ID" --reason "AUDITED: APPROVED. Synthetic check hook meets all criteria." >/dev/null 2>&1 || true

# sp001 flipped to status: ready by spec-ready, stays there until work-merge.
# (Already at ready from earlier seed work — confirm.)
sed -i 's/^status: spec$/status: ready/' docs/notes/spec/sp001.md
# board.md: sp001 under ## ready (already set by base seed)

# ----- Advance to post-work-merge state -----------------------------------
# work-merge already ran: us003/im002/sp001 flipped to done/accepted/done,
# sp001 footer Index: [[board]] → [[archive]], sp001 removed from
# docs/board.md ## ready and added to docs/archive.md ## done. bd epic
# stays OPEN (spec-retro closes it).

sed -i 's/^status: ready$/status: done/' docs/notes/spec/sp001.md
sed -i 's/^status: ready$/status: done/' docs/notes/us003.md
sed -i 's/^status: proposed$/status: accepted/' docs/notes/im002.md

# Flip sp001 footer
python3 - <<'PY'
from pathlib import Path
p = Path('docs/notes/spec/sp001.md')
body = p.read_text()
body = body.replace("Index: [[board]]", "Index: [[archive]]")
p.write_text(body)
PY

# Move sp001 from board.md ## ready to archive.md ## done
cat > docs/board.md <<'EOF'
# Board

Nothing in flight right now.

## idea

## spec

## ready
EOF

cat > docs/archive.md <<'EOF'
# Archive

Shipped specs.

## done

- [[sp001|rotate service credentials without downtime]]
EOF

# Add a separate "shipped" commit so spec-retro can see what landed via git diff
git add -A
git commit -q -m "ship sp001: rotate_secret + alias bookkeeping" 2>/dev/null || true

# Add some bd notes that hint at discoveries / deviations for retro to harvest
# Task 1: deviation logged
bd update "$T1_ID" --notes "AUDITED: APPROVED. rotate_secret meets all criteria.

DEVIATION (from implementer notes): per-name lock granularity ended up using
a guard-lock + per-name dict pattern instead of plain per-key locks suggested
by im002.approach. Functional equivalent but a future refactor candidate." >/dev/null 2>&1 || true

# Task 3: discovery filed (cross-region failover)
bd update "$T3_ID" --notes "AUDITED: APPROVED. Synthetic check hook meets all criteria.

DISCOVERED during implementation: rotation correctness across regions is
unverified — current synthetic check is single-region. Likely needs a
follow-up us### for cross-region failover behavior." >/dev/null 2>&1 || true

# ----- Per-eval mutations -------------------------------------------------
case "$EVAL_ID" in
  1)
    # eval-1 already-closed-epic: spec-retro already ran (or someone closed
    # the epic out-of-process). Skill should detect and either no-op or
    # surface the prior close.
    bd close "$EPIC_ID" --reason "Retro: prior run. im002 rewritten. Closed by previous spec-retro." >/dev/null 2>&1 || true
    ;;
  2)
    # eval-2 wrong-status-ready: sp001 still at status: ready (work-merge
    # didn't finish). Skill must route back to work-merge.
    sed -i 's/^status: done$/status: ready/' docs/notes/spec/sp001.md
    # Restore board entry under ## ready, remove from archive
    cat > docs/board.md <<'EOF'
# Board

One spec ready for execution.

## idea

## spec

## ready

- [[sp001|rotate service credentials without downtime]]
EOF
    cat > docs/archive.md <<'EOF'
# Archive

Shipped specs.

## done
EOF
    ;;
  3)
    # eval-3 nothing-to-harvest: clean shipping — clear the discovery notes
    # so there's no follow-up scope to draft. Skill should still rewrite im
    # narrative + close epic but mint no new us###/adr###.
    bd update "$T1_ID" --notes "AUDITED: APPROVED. rotate_secret meets all criteria. No deviations." >/dev/null 2>&1 || true
    bd update "$T3_ID" --notes "AUDITED: APPROVED. Synthetic check hook meets all criteria. No deviations." >/dev/null 2>&1 || true
    ;;
  4)
    # eval-4 feature-extraction-candidate: a concrete second consumer (named
    # draft us006) would obviously reuse the per-name versioned-alias rotation
    # primitive that landed in im002. The skill MUST surface this as a
    # Candidate Features block — but NOT mint ft### silently. Default bias is
    # to leave glue in im### until the human approves extraction.
    cat > docs/notes/us006.md <<'EOF'
---
aliases:
  - rotate OAuth client api-keys
status: draft
created: 2026-05-15
---
# Story [[platform-flow]] [[product]]

## role
[[pn002|platform-engineer]]

## want
rotate OAuth client api-keys without downtime, same overlap semantics as service credentials

## because
external OAuth clients hold long-lived api-keys; quarterly rotation needs the same 5-minute overlap pattern us003 shipped

## acceptance_criteria
- Rotation script can swap api-keys while OAuth flows run
- Old key stays valid for 5 minutes after rotation
- No 401s during rotation window for active OAuth sessions

---

Index: [[product]]
EOF
    # Add us006 to product.md so it's discoverable from the hub
    python3 - <<'PY'
from pathlib import Path
p = Path('docs/product.md')
body = p.read_text()
body = body.replace(
    "- [[us003|rotate service credentials without downtime]]",
    "- [[us003|rotate service credentials without downtime]]\n- [[us006|rotate OAuth client api-keys]]"
)
p.write_text(body)
PY
    # Update Task 1 notes to make the reuse signal concrete (per the
    # 'two real consumers OR one real + one named draft' rule).
    bd update "$T1_ID" --notes "AUDITED: APPROVED. rotate_secret meets all criteria.

DISCOVERED during implementation: the per-name versioned-alias rotation
primitive in vault.py (rotate_secret + the _ALIASES + per-name lock pattern)
is more general than this story. The newly-drafted [[us006|rotate OAuth
client api-keys]] will need the *same* primitive — same overlap semantics,
same lock granularity, same versioned-alias bookkeeping. Worth surfacing
as a Feature-extraction candidate for the retro." >/dev/null 2>&1 || true
    ;;
  5)
    # eval-5 speculative-reuse-rejected: the implementer wrote a helper that
    # 'feels reusable' but there is NO named second consumer. Skill MUST
    # apply the vertical-over-horizontal default — leave the glue in im###,
    # do NOT flag a candidate, do NOT mint ft###.
    bd update "$T1_ID" --notes "AUDITED: APPROVED. rotate_secret meets all criteria.

NOTE: rotate_secret is reasonably general — the per-name lock pattern feels
like something other code might want eventually. No concrete second consumer
yet, just a hunch. Not blocking anything." >/dev/null 2>&1 || true
    # Wipe Task 3 discovery so the only signal is the speculative one.
    bd update "$T3_ID" --notes "AUDITED: APPROVED. Synthetic check hook meets all criteria. No deviations." >/dev/null 2>&1 || true
    ;;
  6)
    # eval-6 adr-and-feature-both: a finding has BOTH a strategic decision
    # AND a concrete reusable surface. During execution the team decided to
    # back rotation on Vault's Transit secrets engine (vendor/paradigm pick)
    # and shipped src/lib/vault_transit.py as a thin wrapper that other
    # services could call. Skill must emit ONE new adr#### (the decision)
    # AND update or mint a ft### (the surface).
    cat > src/lib/vault_transit.py <<'EOF'
"""Thin wrapper around HashiCorp Vault Transit secrets engine.

ft002 (vault-secrets) was KV-only. We added Transit during the rotation
work because rotate_secret needed deterministic versioned aliases that
Transit gives us out of the box. Other services that need encrypted
rotation primitives can now call this without rebuilding the wrapper.
"""
from __future__ import annotations


def encrypt(plaintext: str, *, key_name: str) -> str:
    """Encrypt plaintext under the named Transit key. Returns ciphertext."""
    return f"<transit:{key_name}:{plaintext}>"


def decrypt(ciphertext: str, *, key_name: str) -> str:
    """Decrypt a Transit-wrapped ciphertext under the named key."""
    return ciphertext.removeprefix(f"<transit:{key_name}:").removesuffix(">")


def rotate_key(key_name: str) -> int:
    """Rotate the named Transit key. Returns the new version number."""
    return 2
EOF
    bd update "$T1_ID" --notes "AUDITED: APPROVED. rotate_secret meets all criteria.

DECISION SHIFT during implementation: we adopted HashiCorp Vault's Transit
secrets engine over the original KV-only plan for the versioned-alias
backing. Trade-off: Transit gives us deterministic versions + key rotation
out of the box but ties us to HashiCorp Vault specifically (KV would have
let us swap to other backends). Cross-cutting — affects how every future
encrypted-rotation feature is built.

CAPABILITY: src/lib/vault_transit.py landed as a thin wrapper around the
Transit engine (encrypt / decrypt / rotate_key). Concrete API surface,
zero domain logic, designed for reuse — the metrics service alerting and
the reports service signed-URL flow are obvious next consumers." >/dev/null 2>&1 || true
    git add -A
    git commit -q -m "ship sp001 [decision shift]: add Vault Transit wrapper" 2>/dev/null || true
    ;;
esac

# ----- Commit baseline + manifest -----------------------------------------
git add -A
git commit -q -m "seed: Acme platform + AKM + bd workspace skeleton (eval $EVAL_ID)" 2>/dev/null || true

find . -path ./.git -prune -o -type f -print | sort > "$SANDBOX/.seed_manifest.txt"

echo "Seeded sandbox at $SANDBOX"
