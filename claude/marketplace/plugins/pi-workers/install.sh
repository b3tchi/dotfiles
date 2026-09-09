#!/usr/bin/env bash
set -euo pipefail

# pi-workers installer — links the `pi-worker` CLI and registers the Pi package.
#
# Usage:
#   ./install.sh              # install
#   ./install.sh uninstall    # remove

# Resolve to the main worktree so the path stays valid after worktrees are
# cleaned up.
#
# Asked of git directly rather than by parsing `worktree list --porcelain`. The
# listing was piped into an `awk` that exits on the first record, and past one
# write buffer git is still writing when awk closes the pipe: SIGPIPE, which
# `set -euo pipefail` turns into this script's exit status. Measured: 3891 bytes
# of listing installed fine, 6135 bytes failed every time — so the installer
# worked in a quiet repo and refused, with a bare `141` and no message, in a
# busy one. It cost a day of looking at it as a flaky test.
#
# `--git-common-dir` is the same question without the pipe: every linked
# worktree shares the main worktree's git dir, so its parent IS the main
# worktree. The `--is-inside-work-tree` guard above means this is never asked of
# a bare repo, where the common dir is the repository itself and has no worktree
# to be the parent of.
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v git &>/dev/null && git -C "$_SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    _MAIN_WORKTREE="$(dirname "$(git -C "$_SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir)")"
    _REPO_ROOT="$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel)"
    _REL_PATH="${_SCRIPT_DIR#"$_REPO_ROOT"}"
    PKG_DIR="${_MAIN_WORKTREE:-$_REPO_ROOT}${_REL_PATH}"
else
    PKG_DIR="$_SCRIPT_DIR"
fi
unset _SCRIPT_DIR _MAIN_WORKTREE _REPO_ROOT _REL_PATH
ACTION="${1:-install}"

# Dependencies the CLI cannot run without, checked BEFORE anything is linked:
# a half-install that puts a CLI on PATH which then dies on first use is worse
# than no install, because the operator discovers it at the point of use.
# `pi` is deliberately NOT required — the bus and its tests run without it.
check_deps() {
    local missing=""
    command -v nu >/dev/null 2>&1 || missing="$missing nu(nushell)"
    command -v tmux >/dev/null 2>&1 || missing="$missing tmux"
    if [ -n "$missing" ]; then
        echo "  ERROR: pi-workers needs:$missing" >&2
        echo "  Nothing was linked. Install the above, then re-run." >&2
        return 1
    fi
}

link_cli() {
    mkdir -p "$HOME/.local/bin"
    ln -sf "$PKG_DIR/scripts/pi-worker.nu" "$HOME/.local/bin/pi-worker"
    echo "  Linked CLI:      ~/.local/bin/pi-worker"
    local found
    found="$(command -v pi-worker 2>/dev/null || true)"
    if [ -z "$found" ]; then
        echo "  WARNING: 'pi-worker' not on PATH — add ~/.local/bin to PATH"
    elif [ "$found" != "$HOME/.local/bin/pi-worker" ]; then
        echo "  WARNING: 'which pi-worker' resolved to $found"
    else
        echo "  Verified:        which pi-worker -> $found"
    fi
}

unlink_cli() {
    local target="$HOME/.local/bin/pi-worker"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$PKG_DIR/scripts/pi-worker.nu" ]; then
        rm -f "$target"
        # Cleanup for an install from before the stage registry retired
        # (sp029 T8) — a stale link left by an older version of this script.
        local mod="$HOME/.local/bin/stage-registry.nu"
        [ -L "$mod" ] && [ "$(readlink "$mod")" = "$PKG_DIR/scripts/stage-registry.nu" ] && rm -f "$mod"
        echo "  Removed CLI:     ~/.local/bin/pi-worker"
    fi
}

# Pi has no extension drop-directory: a package is registered with
# `pi install <source>`, which appends to packages[] in Pi's settings. The probe
# is the BINARY, not a config dir, because Pi creates its config lazily.
#
# Captured whole and matched in the shell, NOT piped into `grep -qxF`: grep
# exits at the match, and everything upstream of it then takes a SIGPIPE for
# the rest of the list. Under `set -euo pipefail` that is 141, which reads as
# "not registered" — so a long package list made this register the package a
# second time. A wrong answer is worse than an abort, because nothing reports
# it. (Same defect as the worktree listing above, one function along.)
pi_lists_package() {
    local listed line
    listed="$(pi list 2>/dev/null || true)"
    while IFS= read -r line; do
        # Trim with parameter expansion rather than a subprocess per line:
        # strip the longest leading run of non-space (leaving the indent), then
        # remove that indent — and the mirror image for the trailing side.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ "$line" = "$PKG_DIR" ] && return 0
    done <<<"$listed"
    return 1
}

register_pi_package() {
    if ! command -v pi >/dev/null 2>&1; then
        echo "  Pi not detected (no 'pi' on PATH) — skipping package registration."
        echo "  The pi-worker CLI works without it; only the in-agent extension needs Pi."
        return 0
    fi
    if pi_lists_package; then
        echo "  Pi package already registered — nothing to do."
        return 0
    fi
    if pi install "$PKG_DIR" 2>&1 | sed 's/^/  /'; then
        echo "  Registered Pi package: $PKG_DIR"
        echo "  NOTE: Pi must trust this project before it will load a local extension."
    else
        echo "  WARNING: 'pi install' failed; register manually with: pi install $PKG_DIR" >&2
    fi
}

unregister_pi_package() {
    command -v pi >/dev/null 2>&1 || return 0
    pi_lists_package || return 0
    pi remove "$PKG_DIR" 2>&1 | sed 's/^/  /'
    echo "  Removed Pi package: $PKG_DIR"
}

if [ "$ACTION" = "uninstall" ] || [ "$ACTION" = "--uninstall" ]; then
    echo "Uninstalling pi-workers..."
    unlink_cli
    unregister_pi_package
    echo "Done."
    exit 0
fi

echo "Installing pi-workers..."
check_deps || exit 1
link_cli
register_pi_package
echo ""
echo "  Verify with: pi-worker doctor"
echo "  spawn requires --isolation worktree|main — there is no default."
echo "pi-workers installed."
