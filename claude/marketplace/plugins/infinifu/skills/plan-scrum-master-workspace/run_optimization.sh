#!/usr/bin/env bash
# Wrapper around skill-creator/scripts/run_loop.py.
#
# Why this exists: run_eval.py greps for the proxy command's uuid-suffixed
# name in the tool input claude -p emits. When the real plan-scrum-master
# skill is installed via the infinifu plugin, claude prefers the proper
# skill (e.g. infinifu:plan-scrum-master) and the proxy-name grep always
# fails, pinning recall at 0%. See dotfiles-ac9 for the bug analysis.
#
# Fix: hide the real SKILL.md from claude's plugin auto-discovery by
# renaming it for the duration of the run, and point run_loop at a stub
# SKILL.md staged outside the plugin tree (so claude can't find that
# either). The proxy command in ~/.claude/commands/ becomes the only
# carrier of the candidate description.
set -euo pipefail

REAL_SKILL_DIR="/home/jan/.dotfiles/claude/marketplace/plugins/infinifu/skills/plan-scrum-master"
REAL_SKILL_FILE="$REAL_SKILL_DIR/SKILL.md"
DISABLED_FILE="$REAL_SKILL_DIR/SKILL.md.disabled-for-eval"

STUB_DIR="${STUB_DIR:-/tmp/plan-scrum-master-eval-stub}"
STUB_SKILL_FILE="$STUB_DIR/SKILL.md"

WORKSPACE="$REAL_SKILL_DIR-workspace"
EVAL_SET="${EVAL_SET:-$WORKSPACE/trigger-eval.json}"
RESULTS_DIR="${RESULTS_DIR:-$WORKSPACE/optimization-runs}"
MODEL="${MODEL:-claude-opus-4-7}"
MAX_ITERATIONS="${MAX_ITERATIONS:-5}"
SKILL_CREATOR="/home/jan/.claude/plugins/cache/claude-plugins-official/skill-creator/unknown/skills/skill-creator"

cleanup() {
  local ec=$?
  if [ -f "$DISABLED_FILE" ] && [ ! -f "$REAL_SKILL_FILE" ]; then
    mv "$DISABLED_FILE" "$REAL_SKILL_FILE"
    echo "[wrapper] restored $REAL_SKILL_FILE" >&2
  fi
  rm -rf "$STUB_DIR"
  return "$ec"
}
trap cleanup EXIT INT TERM

# Sanity checks
if [ ! -f "$REAL_SKILL_FILE" ]; then
  echo "ERROR: $REAL_SKILL_FILE missing — already in a broken state?" >&2
  exit 2
fi
if [ -f "$DISABLED_FILE" ]; then
  echo "ERROR: $DISABLED_FILE already exists — prior run did not clean up." >&2
  exit 2
fi

# Stage the stub before disabling — extract description from the real
# SKILL.md, then write a stub whose frontmatter carries the same name
# and description so run_loop has a reasonable iteration-0 baseline.
mkdir -p "$STUB_DIR"
python3 - <<PY
import re
from pathlib import Path
src = Path("$REAL_SKILL_FILE").read_text()
m = re.search(r"^---\s*\n(.*?)\n---", src, re.DOTALL)
if not m:
    raise SystemExit("no frontmatter in real SKILL.md")
fm = m.group(1)
stub = f"---\n{fm}\n---\n\n# Stub for description-optimization eval run\n\nIntentionally empty — the real skill content lives at $REAL_SKILL_FILE.\n"
Path("$STUB_SKILL_FILE").write_text(stub)
PY
echo "[wrapper] staged stub at $STUB_SKILL_FILE" >&2

# Now disable the real skill (claude plugin loader can no longer find it).
mv "$REAL_SKILL_FILE" "$DISABLED_FILE"
echo "[wrapper] disabled real SKILL.md (renamed to .disabled-for-eval)" >&2
echo "[wrapper] running run_loop on stub at $STUB_DIR with eval-set=$EVAL_SET model=$MODEL max-iter=$MAX_ITERATIONS" >&2

cd "$SKILL_CREATOR"
# NOTE: no exec — we want the EXIT trap to fire and restore state.
python -m scripts.run_loop \
  --eval-set "$EVAL_SET" \
  --skill-path "$STUB_DIR" \
  --model "$MODEL" \
  --max-iterations "$MAX_ITERATIONS" \
  --verbose \
  --results-dir "$RESULTS_DIR" \
  --report auto \
  "$@"
