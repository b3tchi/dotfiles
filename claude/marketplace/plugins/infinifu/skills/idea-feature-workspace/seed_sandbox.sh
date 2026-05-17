#!/usr/bin/env bash
# Seed an Acme-platform sandbox with a small AKM workspace so idea-feature has
# real personas/stories/features/categories/ADRs/implementations to survey.
set -euo pipefail

SANDBOX_REL="${1:?sandbox dir required}"
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

# ----- Commit baseline + manifest -----------------------------------------
git add -A
git commit -q -m "seed: Acme platform + AKM workspace skeleton"

find . -path ./.git -prune -o -type f -print | sort > "$SANDBOX/.seed_manifest.txt"

echo "Seeded sandbox at $SANDBOX"
