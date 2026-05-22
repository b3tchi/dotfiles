#!/usr/bin/env bash
# Install a worktree-skip gate into the bd-managed git hooks.
#
# Why: bd installs pre-commit / post-merge / post-checkout / pre-push /
# prepare-commit-msg hooks that auto-export dolt → .beads/issues.jsonl and
# auto-import the reverse. .git/hooks/ is shared across worktrees, so the
# hooks fire from any worktree. .beads/ lives only at $AKM_ROOT (main),
# so linked-worktree commits would:
#   1. dirty main's working tree without including the diff in their commit
#   2. race the jsonl rewrite if multiple worktrees commit concurrently
# This script adds a 3-line gate above the BEADS INTEGRATION block that
# short-circuits the hook when running from a linked worktree.
#
# Idempotent — safe to re-run after bd reinstalls or upgrades the integration.
#
# Run from anywhere; takes the repo root as $1, or current cwd.

set -euo pipefail

REPO="${1:-$(pwd)}"
HOOKS_DIR="$REPO/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "no .git/hooks in $REPO — not a git repo (or worktree, not main)" >&2
  exit 1
fi

GATE='# Skip bd hooks entirely when running from a linked worktree.
# Rationale: dolt is shared across worktrees, but .beads/issues.jsonl
# only lives in the main worktree. Re-exporting from a linked worktree
# would dirty main'\''s working tree without including the diff in the
# worktree commit, and concurrent worktree commits would race on the
# jsonl rewrite. bd state is committed from main only.
if [ "$(git rev-parse --git-dir 2>/dev/null)" != "$(git rev-parse --git-common-dir 2>/dev/null)" ]; then
  exit 0
fi
'

for hook in pre-commit post-merge post-checkout pre-push prepare-commit-msg; do
  f="$HOOKS_DIR/$hook"
  if [ ! -f "$f" ]; then
    echo "$hook: missing (bd hasn't installed it here) — skipping"
    continue
  fi
  if grep -q 'linked worktree' "$f"; then
    echo "$hook: already gated"
    continue
  fi
  python3 - "$f" "$GATE" <<'PY'
import sys, re
path, gate = sys.argv[1], sys.argv[2]
s = open(path).read()
if '# --- BEGIN BEADS INTEGRATION' not in s:
    print(f"{path}: no BEADS block — skipping", flush=True)
    sys.exit(0)
new = re.sub(r'(# --- BEGIN BEADS INTEGRATION)', gate + '\n' + r'\1', s, count=1)
open(path, 'w').write(new)
PY
  echo "$hook: gated"
done

echo
echo "Done. bd hooks now skip on linked worktrees. Main-worktree git events"
echo "still trigger the bd export / import."
