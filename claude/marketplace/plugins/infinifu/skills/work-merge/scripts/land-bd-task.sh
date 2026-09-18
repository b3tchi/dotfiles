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
# If the merge changed a lockfile, deps are synced before the test gate runs —
# otherwise base's installed deps are stale and the gate fails on a missing
# module, producing a false POST-MERGE FAIL for a good merge.
#
# Usage: land-bd-task.sh <bd-id> <iteration> [AKM_ROOT] [TEST_CMD]
#   bd-id      — numeric bd task id (without the leading `bd-`)
#   iteration  — N from the approved branch bd-<id>.<N>
#   AKM_ROOT   — defaults to $(akm-root) or current dir.
#   TEST_CMD   — defaults to $LAND_TEST_CMD env var, else empty.
#
# Env:
#   LAND_TEST_CMD     — fallback for TEST_CMD.
#   LAND_INSTALL_CMD  — force the dep-sync command instead of detecting it.
#   LAND_SKIP_INSTALL — set to 1 to skip dep sync entirely.

set -euo pipefail

ID="${1:?missing bd id, e.g. land-bd-task.sh 42 0}"
ITER="${2:?missing iteration, e.g. land-bd-task.sh 42 0}"
AKM_ROOT="${3:-${AKM_ROOT:-$(akm-root 2>/dev/null || pwd)}}"
TEST_CMD="${4:-${LAND_TEST_CMD:-}}"

BRANCH="bd-${ID}.${ITER}"

# ── Status ownership (dotfiles-luzj, second failure mode) ────────────────
# work-audit CLOSES the task and then fires this script, so on every rollback
# path below the `bd update --status in_progress` overwrites a close this
# script never made. That is the right behaviour for a genuine POST-MERGE
# failure — the task really is rejected again — but it is invisible: on
# dotfiles-rsdg.2 a SPURIOUS rollback (the dep-sync bug above) reopened a
# closed task, the retry landed the merge, and nothing re-closed it, so base
# carried the merge while the board showed the task open under a misleading
# POST-MERGE FAIL note. Nobody noticed until a dependent task would not
# unblock.
#
# This script does not guess its way out of that: closing is the auditor's
# transition, not the script's. What it does instead is make both halves
# LOUD — a rollback says it undid a close, and a successful land that leaves
# the task un-closed says so on stdout, where the caller reads the result.
prior_status() {
  bd show "$ID" --json 2>/dev/null | jq -r '.[0].status // ""' 2>/dev/null || true
}
PRIOR_STATUS="$(prior_status)"

reopened_suffix() {
  if [ "$PRIOR_STATUS" = "closed" ]; then
    printf ' NOTE: this rollback REOPENED a task that was already closed — the auditor'"'"'s close has been undone, and a successful re-run will NOT restore it. Re-close the task after the retry lands.'
  fi
}

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

# ── Dependency sync ──────────────────────────────────────────────────────
# A merge that changed a lockfile leaves base's INSTALLED deps stale: the tree
# now declares a dependency that isn't on disk. The test gate then fails at
# config/import time (e.g. vitest: ERR_MODULE_NOT_FOUND) and we roll back a
# perfectly good merge, blaming the implementer for a false POST-MERGE FAIL.
# Only run when the merge actually touched a lockfile — this is not a
# blanket install on every land.
#
# Overrides:
#   LAND_INSTALL_CMD=<cmd>   run this instead of the auto-detected command.
#                            Still gated on a lockfile actually changing — it
#                            overrides WHAT runs, never WHETHER.
#   LAND_LOCKFILES="a b"     extra lockfile basenames to recognise, for
#                            ecosystems this script doesn't know. Pair with
#                            LAND_INSTALL_CMD to say how to install them.
#   LAND_SKIP_INSTALL=1      opt out entirely.
# Emits one `<dir>\t<cmd>` line per changed lockfile, where <dir> is that
# lockfile's OWN directory relative to the repo root ("." at the root).
#
# dotfiles-v8fw / dotfiles-luzj: this used to emit a bare command and the
# caller ran it at the repo root, which is only correct for a single-module
# repo. This repo has seven Go modules, all in subdirectories, and no root
# `go.mod` — so `go mod download` at the root died with "go: no modules
# specified" and rolled back a merge that was fine. A lockfile describes the
# deps of the project it sits in, so the sync belongs in that project's
# directory; the root is just the special case where they coincide. The same
# reasoning covers a JS monorepo whose packages carry their own lockfiles.
#
# Every match is emitted rather than the first (the old `return 0` after one
# hit): a merge that changes two modules' lockfiles has to sync both, and
# stopping at the first left the second stale — a latent second bug this shape
# removes rather than defers.
detect_install_targets() {
  local f extra cmd
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    cmd=""
    for extra in ${LAND_LOCKFILES:-}; do
      if [ "${f##*/}" = "$extra" ]; then cmd="${LAND_INSTALL_CMD:-}" ; break ; fi
    done
    if [ -z "$cmd" ]; then
      case "${f##*/}" in
        package-lock.json|npm-shrinkwrap.json) cmd="npm ci" ;;
        yarn.lock)                             cmd="yarn install --frozen-lockfile" ;;
        pnpm-lock.yaml)                        cmd="pnpm install --frozen-lockfile" ;;
        bun.lockb|bun.lock)                    cmd="bun install --frozen-lockfile" ;;
        go.sum)                                cmd="go mod download" ;;
        Gemfile.lock)                          cmd="bundle install" ;;
        composer.lock)                         cmd="composer install" ;;
        uv.lock)                               cmd="uv sync" ;;
        poetry.lock)                           cmd="poetry install" ;;
        Pipfile.lock)                          cmd="pipenv sync" ;;
        # Cargo.lock is deliberately absent: `cargo test` resolves and builds
        # deps itself, so a separate install step is redundant.
        *)                                     continue ;;
      esac
    fi
    [ -z "$cmd" ] && continue
    # LAND_INSTALL_CMD overrides WHAT runs, never WHETHER — the gate stays "a
    # lockfile actually changed", exactly as before.
    printf '%s\t%s\n' "$(dirname "$f")" "${LAND_INSTALL_CMD:-$cmd}"
  done <<< "$1" | sort -u
}

if [ "${LAND_SKIP_INSTALL:-}" != "1" ]; then
  CHANGED_FILES="$(git -C "$AKM_ROOT" diff --name-only ORIG_HEAD HEAD || true)"
  INSTALL_TARGETS="$(detect_install_targets "$CHANGED_FILES")"
  # A herestring, not a pipe: the loop must run in THIS shell so a failing
  # sync can `exit 2` the script rather than only its own subshell.
  while IFS=$'\t' read -r sync_dir sync_cmd; do
    [ -z "${sync_cmd:-}" ] && continue
    echo "Lockfile changed in ${sync_dir} — syncing deps there: $sync_cmd"
    if ! (cd "$AKM_ROOT/$sync_dir" && eval "$sync_cmd"); then
      echo "POST-MERGE DEP SYNC FAILED — rolling back" >&2
      git -C "$AKM_ROOT" reset --hard ORIG_HEAD
      bd update "$ID" --status in_progress \
        --append-notes "POST-MERGE FAIL (dep sync): '$sync_cmd' failed in '${sync_dir}' after merging $BRANCH into $BASE. The merge changed a lockfile whose deps do not install. Not a test failure — the dependency change itself is broken.$(reopened_suffix)" \
        >/dev/null
      exit 2
    fi
  done <<< "$INSTALL_TARGETS"
fi

# ── Go artifact rebuild (dotfiles-xwg0) ─────────────────────────────────
# A merge that changes a Go module's source leaves its COMPILED artifact
# stale: `go test` (the usual TEST_CMD) exercises source, not the installed
# binary, so the existing test gate says nothing about it. This bit twice in
# one session before anyone built a gate for it (agent-monitor, then
# akm-graph) — a human caught it, not a gate, both times.
#
# Scoped to modules the merge actually touched (`go-stale rebuild --since
# ORIG_HEAD`, using ORIG_HEAD exactly as the dep-sync diff above does) so an
# unrelated merge doesn't pay to rebuild all seven artifacts. Same
# rollback contract as the dep-sync and test gates: a build failure means
# the merge itself is bad, so it is treated the same as a failing test, not
# swallowed.
#
# Env:
#   LAND_SKIP_GO_REBUILD=1   opt out entirely.
GO_STALE="$AKM_ROOT/nushell/actions/go-stale"
if [ "${LAND_SKIP_GO_REBUILD:-}" != "1" ] && [ -x "$GO_STALE" ] && command -v nu >/dev/null 2>&1; then
  if ! nu "$GO_STALE" rebuild --repo "$AKM_ROOT" --since ORIG_HEAD; then
    echo "POST-MERGE GO REBUILD FAILED — rolling back" >&2
    git -C "$AKM_ROOT" reset --hard ORIG_HEAD
    bd update "$ID" --status in_progress \
      --append-notes "POST-MERGE FAIL (go rebuild): 'go-stale rebuild --since ORIG_HEAD' failed after merging $BRANCH into $BASE. A Go module this merge touched no longer builds — not a test failure, the source change itself is broken.$(reopened_suffix)" \
      >/dev/null
    exit 2
  fi
fi

# Post-merge test gate
if [ -n "$TEST_CMD" ]; then
  echo "Running post-merge tests: $TEST_CMD"
  if ! (cd "$AKM_ROOT" && eval "$TEST_CMD"); then
    echo "POST-MERGE TESTS FAILED — rolling back" >&2
    git -C "$AKM_ROOT" reset --hard ORIG_HEAD
    bd update "$ID" --status in_progress \
      --append-notes "POST-MERGE FAIL: tests failed after merging $BRANCH into $BASE. Integration gap — fix and re-audit.$(reopened_suffix)" \
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

# The land succeeded. If the task is not closed, say so HERE rather than
# leaving the caller to infer it from an exit code that only reports the
# merge. A task reopened by an earlier rollback (see "Status ownership"
# above) reaches this line still `in_progress`, and that is exactly the
# state that went unnoticed on dotfiles-rsdg.2.
FINAL_STATUS="$(prior_status)"
if [ -n "$FINAL_STATUS" ] && [ "$FINAL_STATUS" != "closed" ]; then
  echo "NOTE: bd task $ID is '$FINAL_STATUS', not closed. The merge landed; the close is the auditor's transition and has not happened. If an earlier attempt rolled back, it reopened the task and this successful run did not restore the close — do it now, or a dependent task will not unblock."
fi
