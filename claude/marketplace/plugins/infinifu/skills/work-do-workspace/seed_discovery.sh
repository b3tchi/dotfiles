#!/usr/bin/env bash
# Seed: task references src/dates.py which doesn't exist; out-of-scope says
# "file a discovery" instead of implementing it.
set -euo pipefail
SANDBOX="${1:?sandbox dir required}"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"; cd "$SANDBOX"

git init -q
git config user.email "eval@example.com"; git config user.name "eval"

mkdir -p src tests
touch src/__init__.py tests/__init__.py
cat > src/slugs.py <<'EOF'
import re

def slugify(title: str) -> str:
    s = title.lower()
    s = re.sub(r"\s+", "-", s)
    s = "".join(c for c in s if c.isalnum() or c == "-")
    return s.strip("-")
EOF
cat > tests/test_slugs.py <<'EOF'
from src.slugs import slugify

def test_basic():
    assert slugify("Hello World") == "hello-world"
EOF
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
git add -A; git commit -q -m "seed: slugs module with existing slugify"

bd init --prefix eval --stealth >/dev/null

TASK=$(bd q "Implement title_slug_with_date")
bd update "$TASK" --design "$(cat <<'EOF'
## Goal
Add `title_slug_with_date(title: str, date: datetime) -> str` to `src/slugs.py`
that returns a slug prefixed with the date in `YYYY-MM-DD` form, like
`"2025-11-14-hello-world"`.

## Dependency
Use `src/dates.py::format_iso(date)` to format the date — that module should
already exist in this project.

## Success Criteria
- [ ] `title_slug_with_date("Hello World", date(2025, 11, 14)) == "2025-11-14-hello-world"`
- [ ] Existing `test_slugs.py` still passes.
- [ ] 2+ new tests covering date-prefix scenarios.

## Out of scope
- Do NOT implement `src/dates.py` if it is missing. File a discovery task via
  `bd create "Discovered: ..." --type task --design "..."` and link it with
  `bd dep add <new-id> <this-task-id> --type discovered-from`.
- Non-ASCII titles.
EOF
)"

echo "{\"task\": \"$TASK\", \"initial_commit_count\": 1}" > "$SANDBOX/seeded_ids.json"
echo "Seeded at $SANDBOX; TASK=$TASK"
