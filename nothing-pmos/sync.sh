#!/bin/sh
# nothing-pmos/sync.sh - bring the device's clone of the nothing-pmos repo up
# to date and run its installer (see nothing-pmos/dot.yaml): install.sh on the
# phone (spacewar), pipa/install.sh on the Xiaomi Pad 6 (picked by device tree).
#
# The clone ~/.local/src/nothing-pmos (branch main) is fetched from
# $NOTHING_PMOS_REPO (GitHub over ssh, set up by the `github` dot) and only
# ever fast-forwarded. It also still accepts a push from the dev box
# (receive.denyCurrentBranch=updateInstead), so a phone without GitHub access
# works as before:
#
#   git -C <nothing-pmos worktree> push phone:.local/src/nothing-pmos main
#
# A clone with local changes or on another branch is refused, never reset or
# switched. A clone with commits GitHub lacks is kept, with a warning.
set -u

SRC="$HOME/.local/src/nothing-pmos"
BRANCH=main
REPO="${NOTHING_PMOS_REPO:-git@github.com:b3tchi/nothing-pmos.git}"

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$SRC"
  git -C "$SRC" init -q -b "$BRANCH"
  git -C "$SRC" config receive.denyCurrentBranch updateInstead
  echo "nothing-pmos: created $SRC"
fi
if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then
  echo "nothing-pmos: $SRC has local changes -- refusing to touch it." >&2
  exit 1
fi
cur=$(git -C "$SRC" symbolic-ref --short HEAD 2>/dev/null || true)
if [ "$cur" != "$BRANCH" ]; then
  echo "nothing-pmos: $SRC is on '$cur', not $BRANCH -- refusing to switch it." >&2
  exit 1
fi

# BatchMode: no password or host-key prompt can hang an unattended run.
if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15" \
  timeout 60 git -C "$SRC" fetch -q "$REPO" "$BRANCH" 2>/dev/null; then
  if ! git -C "$SRC" rev-parse -q --verify HEAD >/dev/null; then
    git -C "$SRC" reset -q --hard FETCH_HEAD
  elif ! git -C "$SRC" merge -q --ff-only FETCH_HEAD 2>/dev/null; then
    echo "nothing-pmos: WARNING -- $REPO $BRANCH does not fast-forward $SRC; installing what is there." >&2
  fi
else
  echo "nothing-pmos: $REPO not reachable; installing what is in $SRC."
fi
if ! git -C "$SRC" rev-parse -q --verify HEAD >/dev/null; then
  echo "nothing-pmos: $SRC has no commit yet. Run the github dot, or from the dev box:" >&2
  echo "nothing-pmos:   git -C <nothing-pmos worktree> push phone:.local/src/nothing-pmos $BRANCH" >&2
  exit 1
fi
echo "nothing-pmos: $BRANCH at $(git -C "$SRC" rev-parse --short HEAD)"

# One installer per device, picked by the device tree: the Xiaomi Pad 6 has
# pipa/install.sh, everything else (the phone) the top-level install.sh,
# which itself refuses anything that is not a spacewar.
if tr '\0' '\n' <"${NOTHING_PMOS_DT:-/proc/device-tree/compatible}" 2>/dev/null |
  grep -qx 'xiaomi,pipa'; then
  sh "$SRC/pipa/install.sh"
else
  sh "$SRC/install.sh"
fi
