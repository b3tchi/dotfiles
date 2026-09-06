#!/usr/bin/env bash
set -euo pipefail

# pi-workers installer — links the `pi-worker` CLI and registers the Pi package.
#
# Usage:
#   ./install.sh              # install
#   ./install.sh uninstall    # remove

# Resolve to the main worktree so the path stays valid after worktrees are
# cleaned up.
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v git &>/dev/null && git -C "$_SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    _MAIN_WORKTREE="$(git -C "$_SCRIPT_DIR" worktree list --porcelain \
        | awk 'BEGIN{RS=""} !/\nbare(\n|$)/ {sub(/^worktree /, ""); sub(/\n.*/, ""); print; exit}')"
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
    # Nushell resolves a relative `use` against the SYMLINK's directory, not the
    # target's, so the module has to sit beside the link or the CLI cannot parse.
    ln -sf "$PKG_DIR/scripts/stage-registry.nu" "$HOME/.local/bin/stage-registry.nu"
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
        local mod="$HOME/.local/bin/stage-registry.nu"
        [ -L "$mod" ] && [ "$(readlink "$mod")" = "$PKG_DIR/scripts/stage-registry.nu" ] && rm -f "$mod"
        echo "  Removed CLI:     ~/.local/bin/pi-worker"
    fi
}

# Pi has no extension drop-directory: a package is registered with
# `pi install <source>`, which appends to packages[] in Pi's settings. The probe
# is the BINARY, not a config dir, because Pi creates its config lazily.
pi_lists_package() {
    pi list 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qxF "$PKG_DIR"
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
    echo "Done. The stage registry, if you installed one, was left alone."
    exit 0
fi

echo "Installing pi-workers..."
check_deps || exit 1
link_cli
register_pi_package
echo ""
echo "  Verify with: pi-worker doctor"
echo "  A consumer must install a stage registry (PI_WORKER_STAGES or"
echo "  \${XDG_CONFIG_HOME:-~/.config}/pi-workers/stages.json) before spawning."
echo "pi-workers installed."
