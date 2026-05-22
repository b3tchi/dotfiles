#!/usr/bin/env bash
# sweep-merged-worktrees.sh — spec-retro safety-net pass.
#
# Removes git worktrees on `bd-<id>` branches whose branch is already merged
# into the repo's default base (origin/HEAD). Conservative by design:
#   - touches only branches matching `^bd-` (skips user / ad-hoc worktrees)
#   - touches only branches already merged into origin/<base> (skips Option 3
#     keep-as-is and any in-flight work)
#   - uses `git worktree remove` without --force (refuses if the tree has
#     uncommitted / untracked files — investigate manually before forcing)
#   - uses `git branch -d` (safe), not -D
#
# Usage: sweep-merged-worktrees.sh [AKM_ROOT]
#   AKM_ROOT defaults to $(akm-root) or current dir.
#
# Output: one line per bd-<id> worktree (MERGED / KEEP / SKIP), then a summary.

set -euo pipefail

AKM_ROOT="${1:-${AKM_ROOT:-$(akm-root 2>/dev/null || pwd)}}"

if [ ! -d "$AKM_ROOT/.git" ] && ! git -C "$AKM_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: $AKM_ROOT is not a git repo" >&2
  exit 1
fi

# Refresh remote view so "merged" is accurate
git -C "$AKM_ROOT" fetch --prune >/dev/null 2>&1 || {
  echo "WARN: fetch failed — proceeding with stale view" >&2
}

BASE="$(git -C "$AKM_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's@^refs/remotes/origin/@@')"
if [ -z "$BASE" ]; then
  echo "ERROR: cannot resolve origin/HEAD — set with: git remote set-head origin -a" >&2
  exit 1
fi

removed=0
kept=0
skipped=0

# Walk every worktree on a bd-<id> branch (porcelain pairs `worktree <p>` then
# optional `branch refs/heads/<name>` per entry).
while IFS=$'\t' read -r wt branch; do
  # Skip main worktree as a safety belt
  if [ "$wt" = "$AKM_ROOT" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  if git -C "$AKM_ROOT" merge-base --is-ancestor "$branch" "origin/$BASE" 2>/dev/null; then
    echo "MERGED: $wt ($branch) — removing"
    if git -C "$AKM_ROOT" worktree remove "$wt" 2>/dev/null; then
      git -C "$AKM_ROOT" branch -d "$branch" 2>/dev/null || true
      removed=$((removed + 1))
    else
      echo "  SKIP: worktree has uncommitted/untracked files — investigate before forcing" >&2
      skipped=$((skipped + 1))
    fi
  else
    echo "KEEP:   $wt ($branch) — not merged into $BASE"
    kept=$((kept + 1))
  fi
done < <(
  git -C "$AKM_ROOT" worktree list --porcelain | awk '
    /^worktree / {w = $2}
    /^branch refs\/heads\/bd-/ {
      sub("refs/heads/", "", $2)
      print w "\t" $2
    }
  '
)

git -C "$AKM_ROOT" worktree prune

echo "---"
echo "Sweep: $removed removed, $kept kept, $skipped skipped (base: $BASE)"
