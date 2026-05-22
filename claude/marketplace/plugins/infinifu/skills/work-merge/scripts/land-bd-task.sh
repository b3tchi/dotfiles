#!/usr/bin/env bash
# land-bd-task.sh — per-task local landing for branch bd-<id>.<N>.
#
# Merges the approved iteration into base, runs tests, removes its worktree,
# then sweeps any sibling rejected iterations (`bd-<id>.*`) that still linger.
# Local operations only — no push, no PR. spec-retro handles remote sync.
#
# On test failure: hard-resets base and reopens the task as in_progress with a
# POST-MERGE FAIL note, leaving the worktree intact for the next implementer.
#
# Usage: land-bd-task.sh <bd-id> <iteration> [AKM_ROOT] [TEST_CMD]
#   bd-id      — numeric bd task id (without the leading `bd-`)
#   iteration  — N from the approved branch bd-<id>.<N>
#   AKM_ROOT   — defaults to $(akm-root) or current dir.
#   TEST_CMD   — defaults to $LAND_TEST_CMD env var, else empty.

set -euo pipefail

ID="${1:?missing bd id, e.g. land-bd-task.sh 42 0}"
ITER="${2:?missing iteration, e.g. land-bd-task.sh 42 0}"
AKM_ROOT="${3:-${AKM_ROOT:-$(akm-root 2>/dev/null || pwd)}}"
TEST_CMD="${4:-${LAND_TEST_CMD:-}}"

BRANCH="bd-${ID}.${ITER}"

if ! git -C "$AKM_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: $AKM_ROOT is not a git repo" >&2
  exit 1
fi

# Resolve base from origin/HEAD; fall back to local default if remote absent
BASE="$(git -C "$AKM_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's@^refs/remotes/origin/@@' || true)"
if [ -z "$BASE" ]; then
  BASE="$(git -C "$AKM_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo main)"
fi

if ! git -C "$AKM_ROOT" show-ref --quiet "refs/heads/$BRANCH"; then
  echo "ERROR: branch $BRANCH does not exist" >&2
  exit 1
fi

# Resolve worktree path for the approved iteration
WT="$(git -C "$AKM_ROOT" worktree list --porcelain \
      | awk -v b="refs/heads/$BRANCH" '/^worktree / {w=$2} $1=="branch" && $2==b {print w; exit}')"

echo "Landing $BRANCH into $BASE (worktree: ${WT:-none})"

git -C "$AKM_ROOT" checkout "$BASE"
git -C "$AKM_ROOT" pull --ff-only 2>/dev/null || true   # no remote / no upstream is fine

# Merge --no-ff to preserve the bd-task boundary in history
git -C "$AKM_ROOT" merge --no-ff "$BRANCH" -m "merge: $BRANCH"

# Post-merge test gate
if [ -n "$TEST_CMD" ]; then
  echo "Running post-merge tests: $TEST_CMD"
  if ! (cd "$AKM_ROOT" && eval "$TEST_CMD"); then
    echo "POST-MERGE TESTS FAILED — rolling back" >&2
    git -C "$AKM_ROOT" reset --hard ORIG_HEAD
    bd update "$ID" --status in_progress \
      --notes "POST-MERGE FAIL: tests failed after merging $BRANCH into $BASE. Integration gap — fix and re-audit." \
      >/dev/null
    exit 2   # caller (work-merge / work-audit) translates exit 2 to REJECTED
  fi
fi

# Approved-iteration cleanup
if [ -n "$WT" ] && [ "$WT" != "$AKM_ROOT" ]; then
  git -C "$AKM_ROOT" worktree remove "$WT"
fi
git -C "$AKM_ROOT" branch -d "$BRANCH"

# Sweep sibling iterations (rejected attempts that never got cleaned up)
SIBLINGS_REMOVED=0
while IFS= read -r sib; do
  [ -z "$sib" ] && continue
  sib_wt="$(git -C "$AKM_ROOT" worktree list --porcelain \
            | awk -v b="refs/heads/$sib" '/^worktree / {w=$2} $1=="branch" && $2==b {print w; exit}')"
  echo "Sweeping rejected sibling: $sib (worktree: ${sib_wt:-none})"
  if [ -n "$sib_wt" ] && [ "$sib_wt" != "$AKM_ROOT" ]; then
    git -C "$AKM_ROOT" worktree remove --force "$sib_wt"   # --force because rejected iterations may have uncommitted state
  fi
  git -C "$AKM_ROOT" branch -D "$sib"                       # -D because the rejected branch is NOT merged
  SIBLINGS_REMOVED=$((SIBLINGS_REMOVED + 1))
done < <(git -C "$AKM_ROOT" branch --list "bd-${ID}.*" --format='%(refname:short)')

git -C "$AKM_ROOT" worktree prune

echo "---"
echo "Landed: $BRANCH → $BASE (local). Approved worktree removed. $SIBLINGS_REMOVED sibling iteration(s) swept."
