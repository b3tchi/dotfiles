#!/usr/bin/env bash
# Seed: task's spec says CACHE_TTL is in minutes, but src/config.py defines it
# in seconds. Agent must detect, log DEVIATION, and implement correctly.
set -euo pipefail
SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"; cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"; git config user.name "eval"

mkdir -p src tests
touch src/__init__.py tests/__init__.py
cat > src/config.py <<'EOF'
# All durations in this module are in SECONDS.
CACHE_TTL = 3600  # seconds — 1 hour
REFRESH_INTERVAL = 300  # seconds — 5 minutes
EOF
cat > pyproject.toml <<'EOF'
[project]
name = "cache-thing"
version = "0.1.0"
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.beads/
.venv/
.pytest_cache/
EOF
git add -A; git commit -q -m "seed: config module with CACHE_TTL in seconds"

bd init --prefix eval --stealth >/dev/null

TASK=$(bd q "Implement cache_expires_at")
bd update "$TASK" --design "$(cat <<'EOF'
## Goal
Add `cache_expires_at(now: datetime) -> datetime` to `src/cache.py`.
Return `now + CACHE_TTL minutes` where `CACHE_TTL` is imported from `src/config.py`.

## Success Criteria
- [ ] `cache_expires_at(datetime(2025, 1, 1, 12, 0, 0))` returns a datetime exactly
      one CACHE_TTL later than the input.
- [ ] At least 3 pytest tests in `tests/test_cache.py`.
- [ ] pytest passes.

## Notes
Per the product spec, `CACHE_TTL` is defined in minutes.

## Anti-patterns
- No silent scope expansion.
- Do NOT rewrite `src/config.py` to change CACHE_TTL's units — the config is
  authoritative.
EOF
)"

echo "{\"task\": \"$TASK\", \"initial_commit_count\": 1}" > "$SANDBOX/seeded_ids.json"
echo "Seeded at $SANDBOX; TASK=$TASK"
