#!/usr/bin/env bash
# Seed a small Python project with a single bd task the agent must implement.
set -euo pipefail

SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"
git config user.name "eval"

cat > README.md <<'EOF'
# Slugger

Tiny utility library.
EOF

mkdir -p src tests
touch src/__init__.py tests/__init__.py

cat > pyproject.toml <<'EOF'
[project]
name = "slugger"
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

git add -A
git commit -q -m "seed: empty slugger project"

bd init --prefix eval --stealth >/dev/null

TASK=$(bd q "Implement slug generator")
bd update "$TASK" --design "$(cat <<'EOF'
## Goal
Implement `slugify(title: str) -> str` at `src/slugs.py`.

## Behavior
- Lowercase the input.
- Replace each run of whitespace with a single hyphen.
- Strip leading and trailing hyphens.
- Drop any character that is not ASCII alphanumeric or a hyphen.

## Success Criteria
- [ ] `tests/test_slugs.py` contains at least 4 tests (basic, punctuation, multi-space, already-a-slug).
- [ ] `slugify("Hello World")` returns `"hello-world"`.
- [ ] `slugify("  Multi   space!!! ")` returns `"multi-space"`.
- [ ] `slugify("---foo---")` returns `"foo"`.
- [ ] `pytest tests/test_slugs.py -v` passes (0 failures).

## Out of scope
- Unicode / non-ASCII handling. If you run into it, file a discovery — do NOT silently implement it in this task.

## Anti-patterns
- No `eval` / `exec`.
- No TODO comments without a follow-up bd id.
EOF
)"

cat > "$SANDBOX/seeded_ids.json" <<EOF
{
  "task": "$TASK",
  "initial_status": "open",
  "initial_commit_count": 1
}
EOF

echo "Seeded sandbox at $SANDBOX"
echo "Task ID: $TASK"
bd show "$TASK" | head -20
