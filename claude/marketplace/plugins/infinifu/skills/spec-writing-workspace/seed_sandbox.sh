#!/usr/bin/env bash
# Seed a sandbox with a FULLY brainstormed design at board/spec/url-shortener.md —
# simulates the state after idea-brainstorming has moved the file from board/idea/
# and spec-writing is the next skill to run.
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"
git config user.name "eval"

cat > README.md <<'EOF'
# Acme Internal Platform

Python + FastAPI + Postgres services, Go workers, VPN-only. Secrets via Vault.

## Conventions
- Services under `src/services/<name>/` (e.g. `src/services/auth/`)
- Shared models: `src/models/` (SQLAlchemy)
- Tests in `tests/services/<name>/`
- Each service owns its own Alembic migrations at `src/services/<name>/migrations/`

## Test runner
`pytest tests/ -v` from repo root.

## Current services
- `auth`: SSO proxy (SAML)
- `metrics`: Prometheus scraper
EOF

mkdir -p src/services/auth src/services/metrics src/models tests/services/auth tests/services/metrics
echo "# SSO proxy service." > src/services/auth/__init__.py
echo "# Prometheus scraper." > src/services/metrics/__init__.py
echo "# Shared SQLAlchemy models." > src/models/__init__.py

cat > pyproject.toml <<'EOF'
[project]
name = "acme-platform"
version = "0.1.0"
dependencies = ["fastapi", "sqlalchemy", "psycopg2-binary", "pydantic", "hashids"]

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF

cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
.venv/
EOF

mkdir -p board/spec

# Fully brainstormed design (pretend idea-brainstorming already produced it
# and moved it here).
cat > board/spec/url-shortener.md <<'EOF'
# URL Shortener — Design

## Goal
Internal URL shortener for Acme employees: compress long internal links (Jira,
Confluence, dashboards) into `go/<slug>` shortlinks they can paste into Slack,
email, or docs. VPN-only; no public exposure.

## Non-goals
- Public link hosting
- Analytics / click tracking
- User-generated vanity slugs in iteration 1 (auto-generated only)

## Architecture
- New FastAPI service at `src/services/shortener/` (sibling of `auth` and `metrics`).
- Postgres table `short_links` holding `(slug, target_url, created_by, created_at)`.
- Slug generation via hashids (auto, 6-char alphanumeric, collision retry).
- Resolve endpoint: `GET /go/{slug}` — 302 redirect to target; 404 on unknown slug.
- Create endpoint: `POST /links` — body `{target_url}`; auth via existing SSO JWT.

## Data flow
1. Authenticated user POSTs `/links` with a target URL.
2. Service validates URL (must be `https://*.acme.corp`), mints a slug, inserts row.
3. Returns `{slug, short_url: https://go.acme.corp/<slug>}`.
4. Any employee GETs `https://go.acme.corp/<slug>` → 302 to target.

## Error handling
- Invalid URL (not `https://*.acme.corp`) → 400 with clear message.
- Collision after 5 retries → 503.
- Unknown slug on resolve → 404.
- Unauth on create → 401 (handled by existing SSO middleware).

## Testing approach
- Unit tests for slug generation (deterministic given seed; collisions retried).
- Unit tests for URL validation (allow-list regex).
- Integration tests for both endpoints using FastAPI TestClient + pytest-postgres.
- Migration test: schema matches SQLAlchemy model.

## Out-of-scope (future)
- Analytics, TTL, vanity slugs, edit/delete endpoints.

---

*Status: design approved by user in idea-brainstorming. Ready for spec-writing.*
EOF

git add -A
git commit -q -m "chore: promote url-shortener from idea to spec"

find . -path ./.git -prune -o -type f -print | sort > "$SANDBOX/.seed_manifest.txt"
cp board/spec/url-shortener.md "$SANDBOX/.seed_design.md"

echo "Seeded sandbox at $SANDBOX"
git log --oneline
