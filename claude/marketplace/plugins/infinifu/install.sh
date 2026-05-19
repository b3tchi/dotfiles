#!/usr/bin/env bash
set -euo pipefail

# Infinifu installer — auto-detects and installs for both Claude Code and OpenCode.ai
# Lifecycle skills framework with bd (beads) task tracking.
#
# Usage:
#   ./install.sh              # Auto-detect and install for all available targets
#   ./install.sh uninstall    # Uninstall from all targets

# Resolve to the main worktree so the path stays valid after worktrees are cleaned up.
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v git &>/dev/null && git -C "$_SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    # Pick first non-bare worktree (skip bare repos in bare+worktree setups)
    _MAIN_WORKTREE="$(git -C "$_SCRIPT_DIR" worktree list --porcelain \
        | awk 'BEGIN{RS=""} !/\nbare(\n|$)/ {sub(/^worktree /, ""); sub(/\n.*/, ""); print; exit}')"
    if [ -z "$_MAIN_WORKTREE" ]; then
        _MAIN_WORKTREE="$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel)"
    fi
    # Derive relative path of this script within the repo, then anchor to main worktree
    _REPO_ROOT="$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel)"
    _REL_PATH="${_SCRIPT_DIR#"$_REPO_ROOT"}"
    INFINIFU_DIR="${_MAIN_WORKTREE}${_REL_PATH}"
else
    INFINIFU_DIR="$_SCRIPT_DIR"
fi
unset _SCRIPT_DIR _MAIN_WORKTREE _REPO_ROOT _REL_PATH
ACTION="${1:-install}"

CLAUDE_DIR="$HOME/.claude"
OPENCODE_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"

# ============================================================================
# Helpers — OpenCode (symlink-based)
# ============================================================================

link_skills() {
    local config_dir="$1"
    mkdir -p "$config_dir/skills"
    [ -L "$config_dir/skills/infinifu" ] && rm -f "$config_dir/skills/infinifu"
    ln -s "$INFINIFU_DIR/skills" "$config_dir/skills/infinifu"
    echo "  Linked skills:   $config_dir/skills/infinifu"
}

link_commands() {
    local config_dir="$1"
    mkdir -p "$config_dir/commands"
    for f in "$config_dir/commands/"*-fnf.md; do
        [ -L "$f" ] && rm -f "$f"
    done
    [ -L "$config_dir/commands/infinifu" ] && rm -f "$config_dir/commands/infinifu"
    for f in "$INFINIFU_DIR/commands/"*.md; do
        ln -sf "$f" "$config_dir/commands/$(basename "$f")"
    done
    echo "  Linked commands: $(ls "$INFINIFU_DIR/commands/"*.md | wc -l) commands"
}

link_agents() {
    local config_dir="$1"
    mkdir -p "$config_dir/agents"
    for f in "$config_dir/agents/"*.md; do
        if [ -L "$f" ] && readlink "$f" | grep -q "$INFINIFU_DIR"; then
            rm -f "$f"
        fi
    done
    for f in "$INFINIFU_DIR/agents/"*.md; do
        ln -sf "$f" "$config_dir/agents/$(basename "$f")"
    done
    echo "  Linked agents:   $(ls "$INFINIFU_DIR/agents/"*.md | wc -l) agents"
}

unlink_skills() {
    local config_dir="$1"
    [ -L "$config_dir/skills/infinifu" ] && rm -f "$config_dir/skills/infinifu" && echo "  Removed skills symlink"
}

unlink_commands() {
    local config_dir="$1"
    for f in "$config_dir/commands/"*-fnf.md; do
        [ -L "$f" ] && rm -f "$f"
    done
    [ -L "$config_dir/commands/infinifu" ] && rm -f "$config_dir/commands/infinifu"
    echo "  Removed command symlinks"
}

unlink_agents() {
    local config_dir="$1"
    for f in "$config_dir/agents/"*.md; do
        if [ -L "$f" ] && readlink "$f" | grep -q "$INFINIFU_DIR"; then
            rm -f "$f"
        fi
    done
    [ -L "$config_dir/agents/infinifu" ] && rm -f "$config_dir/agents/infinifu"
    echo "  Removed agent symlinks"
}

# ============================================================================
# Helpers — Claude Code (plugin-based)
# ============================================================================

claude_code_clean_legacy() {
    # Remove old symlink-based installation artifacts
    local removed=0

    # Remove old skill symlinks
    if [ -L "$CLAUDE_DIR/skills/infinifu" ]; then
        rm -f "$CLAUDE_DIR/skills/infinifu"
        echo "  Cleaned legacy skills symlink"
        removed=1
    fi

    # Remove old command symlinks
    for f in "$CLAUDE_DIR/commands/"*-fnf.md; do
        if [ -L "$f" ] && readlink "$f" | grep -q "$INFINIFU_DIR"; then
            rm -f "$f"
            removed=1
        fi
    done
    [ "$removed" -eq 1 ] && echo "  Cleaned legacy command symlinks"

    # Remove old agent symlinks
    local agents_removed=0
    for f in "$CLAUDE_DIR/agents/"*.md; do
        if [ -L "$f" ] && readlink "$f" | grep -q "$INFINIFU_DIR"; then
            rm -f "$f"
            agents_removed=1
        fi
    done
    [ "$agents_removed" -eq 1 ] && echo "  Cleaned legacy agent symlinks"

    # Remove old SessionStart hook from settings.json
    if [ -f "$CLAUDE_DIR/settings.json" ] && command -v jq &>/dev/null; then
        if jq -e '.hooks.SessionStart[]?.hooks[]?.command | test("infinifu")' "$CLAUDE_DIR/settings.json" &>/dev/null; then
            # Remove infinifu hook entries
            jq 'if .hooks.SessionStart then
                .hooks.SessionStart |= map(select(.hooks | all(.command | test("infinifu") | not)))
                | if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end
                | if .hooks == {} then del(.hooks) else . end
              else . end' \
                "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
                && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
            echo "  Cleaned legacy SessionStart hook from settings.json"
        fi
    fi
}

claude_code_install_plugin() {
    if ! command -v claude &>/dev/null; then
        echo "  WARNING: claude CLI not found — cannot install plugin"
        echo "  Install Claude Code first: https://docs.anthropic.com/en/docs/claude-code"
        return 1
    fi

    # Add local marketplace pointing to infinifu source
    if claude plugin marketplace list 2>&1 | grep -q "infinifu-dev"; then
        echo "  Marketplace already configured, updating..."
        claude plugin marketplace update infinifu-dev 2>&1 | sed 's/^/  /'
    else
        echo "  Adding local marketplace..."
        claude plugin marketplace add "$INFINIFU_DIR" 2>&1 | sed 's/^/  /'
    fi

    # Install or update the plugin
    if claude plugin list 2>&1 | grep -q "infinifu@infinifu-dev"; then
        echo "  Plugin already installed, updating..."
        claude plugin update "infinifu@infinifu-dev" 2>&1 | sed 's/^/  /'
    else
        echo "  Installing plugin..."
        claude plugin install "infinifu@infinifu-dev" 2>&1 | sed 's/^/  /'
    fi
}

claude_code_uninstall_plugin() {
    if ! command -v claude &>/dev/null; then
        echo "  WARNING: claude CLI not found — manual cleanup may be needed"
        return 0
    fi

    # Uninstall plugin
    if claude plugin list 2>&1 | grep -q "infinifu@infinifu-dev"; then
        claude plugin uninstall "infinifu@infinifu-dev" 2>&1 | sed 's/^/  /'
    else
        echo "  Plugin not installed"
    fi

    # Remove marketplace
    if claude plugin marketplace list 2>&1 | grep -q "infinifu-dev"; then
        claude plugin marketplace remove infinifu-dev 2>&1 | sed 's/^/  /'
    fi
}

# ============================================================================
# Helpers — shell scripts
# ============================================================================

link_scripts() {
    mkdir -p "$HOME/.local/bin"
    for src in "$INFINIFU_DIR/scripts/"*.nu; do
        [ -f "$src" ] || continue
        local name found
        name="$(basename "$src" .nu)"
        ln -sf "$src" "$HOME/.local/bin/$name"
        echo "  Linked script:   ~/.local/bin/$name -> ${src#$HOME/}"
        found="$(command -v "$name" 2>/dev/null || true)"
        if [ -z "$found" ]; then
            echo "  WARNING: '$name' not on PATH — add ~/.local/bin to PATH"
        elif [ "$found" != "$HOME/.local/bin/$name" ]; then
            echo "  WARNING: 'which $name' resolved to $found (expected ~/.local/bin/$name)"
        else
            echo "  Verified:        which $name -> $found"
        fi
    done
}

unlink_scripts() {
    for src in "$INFINIFU_DIR/scripts/"*.nu; do
        [ -f "$src" ] || continue
        local name target
        name="$(basename "$src" .nu)"
        target="$HOME/.local/bin/$name"
        if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
            rm -f "$target"
            echo "  Removed script:  ~/.local/bin/$name"
        fi
    done
}

# ============================================================================
# Uninstall
# ============================================================================

if [ "$ACTION" = "uninstall" ] || [ "$ACTION" = "--uninstall" ]; then
    echo "Uninstalling infinifu..."
    echo ""
    installed=0

    # --- Shell scripts ---
    echo "Shell scripts:"
    unlink_scripts
    echo ""

    # --- Claude Code ---
    if [ -d "$CLAUDE_DIR" ]; then
        echo "Claude Code ($CLAUDE_DIR):"
        claude_code_uninstall_plugin
        claude_code_clean_legacy
        installed=1
        echo ""
    fi

    # --- OpenCode ---
    if [ -d "$OPENCODE_DIR" ]; then
        echo "OpenCode ($OPENCODE_DIR):"
        unlink_skills "$OPENCODE_DIR"
        unlink_commands "$OPENCODE_DIR"
        unlink_agents "$OPENCODE_DIR"

        if [ -L "$OPENCODE_DIR/plugins/infinifu.js" ]; then
            rm -f "$OPENCODE_DIR/plugins/infinifu.js"
            echo "  Removed plugin symlink"
        fi
        installed=1
        echo ""
    fi

    if [ "$installed" -eq 0 ]; then
        echo "Nothing to uninstall — no Claude Code or OpenCode config directories found."
    else
        echo "Infinifu uninstalled. Restart your tools to apply."
    fi
    echo ""
    echo "Note: The infinifu source directory was not removed:"
    echo "  $INFINIFU_DIR"
    exit 0
fi

# ============================================================================
# Install
# ============================================================================

echo "Installing infinifu from: $INFINIFU_DIR"
echo ""

# --- Prerequisites ---

# Helper: ensure bd has CGO support (dynamically linked).
# bd 1.0 prebuilt Linux binaries are already CGO-enabled (dynamically linked), so this normally
# does nothing. It's retained as a safety net in case a user is carrying a statically linked bd
# from the 0.50 era — without CGO, bd runs in "server mode" and needs an external dolt daemon,
# which is slower and adds a moving part.
ensure_cgo_bd() {
    local bd_path
    bd_path="$(command -v bd 2>/dev/null)" || return 1
    if file "$bd_path" 2>/dev/null | grep -q "statically linked"; then
        echo "  bd binary lacks CGO (statically linked) — rebuilding via go install..."
        if command -v go &>/dev/null; then
            # bd 1.0+ module path is github.com/gastownhall/beads; binary lives under /cmd/bd.
            # Prefer CGO_ENABLED=1 with the gms_pure_go build tag (embedded dolt); fall back to CGO=0
            # (server-mode-only) if the C toolchain is missing.
            if ! CGO_ENABLED=1 GOFLAGS="${GOFLAGS:+$GOFLAGS }-tags=gms_pure_go" \
                 go install github.com/gastownhall/beads/cmd/bd@latest 2>&1 | sed 's/^/  /'; then
                echo "  CGO=1 build failed; retrying with CGO=0 (server-mode-only, requires dolt on PATH)..."
                CGO_ENABLED=0 go install github.com/gastownhall/beads/cmd/bd@latest 2>&1 | sed 's/^/  /' || true
            fi
            if [ -x "$HOME/go/bin/bd" ]; then
                mkdir -p "$HOME/.local/bin"
                cp "$HOME/go/bin/bd" "$HOME/.local/bin/bd"
                echo "  Replaced with freshly built bd."
                return 0
            fi
        fi
        echo "  WARNING: Could not rebuild bd. Install Go + C toolchain or fetch a CGO-enabled prebuilt."
        return 1
    fi
    return 0
}

# --- dolt (optional — only required when bd is server-mode-only, i.e. built with CGO=0) ---
# bd 1.0 prebuilt Linux binaries are CGO-enabled and embed dolt, so external dolt is not required
# for default use. We still install it as a safety net so both build modes work and so advanced
# users can run `bd dolt ...` subcommands.
#
# We also enforce a minimum dolt version — pre-1.0 builds have protocol and schema quirks that
# can leave bd's server startup in a half-initialized state.
DOLT_MIN_VERSION="1.0.0"

# Echo the installed dolt version (e.g. "1.86.3"), or empty if dolt is missing or unparseable.
current_dolt_version() {
    command -v dolt &>/dev/null || return 0
    dolt version 2>/dev/null | grep -oE 'dolt version [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $3}' || true
}

# dolt_version_lt A B — exit 0 iff A is strictly lower than B (semver-ish, via `sort -V`).
dolt_version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

install_dolt_latest() {
    local detected arch url
    detected=$(curl -fsSL https://api.github.com/repos/dolthub/dolt/releases/latest 2>/dev/null \
        | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    if [ -z "$detected" ]; then
        echo "  WARNING: Could not detect latest dolt version."
        echo "  Install manually from: https://docs.dolthub.com/introduction/installation"
        return 1
    fi
    arch="amd64"
    case "$(uname -m)" in
        aarch64|arm64) arch="arm64" ;;
    esac
    url="https://github.com/dolthub/dolt/releases/download/v${detected}/dolt-linux-${arch}.tar.gz"
    if curl -fsSL "$url" -o /tmp/dolt.tar.gz 2>/dev/null \
        && tar xzf /tmp/dolt.tar.gz -C /tmp/ 2>/dev/null; then
        mkdir -p "$HOME/.local/bin"
        cp "/tmp/dolt-linux-${arch}/bin/dolt" "$HOME/.local/bin/dolt"
        rm -rf /tmp/dolt.tar.gz /tmp/dolt-linux-*
        echo "  dolt $detected installed to ~/.local/bin/dolt"
        return 0
    fi
    echo "  WARNING: dolt download failed."
    echo "  Install manually from: https://docs.dolthub.com/introduction/installation"
    return 1
}

INSTALLED_DOLT_VERSION="$(current_dolt_version)"
if [ -z "$INSTALLED_DOLT_VERSION" ]; then
    echo "dolt not found. Installing..."
    install_dolt_latest || true
    echo ""
elif dolt_version_lt "$INSTALLED_DOLT_VERSION" "$DOLT_MIN_VERSION"; then
    echo "dolt $INSTALLED_DOLT_VERSION is older than required $DOLT_MIN_VERSION. Upgrading..."
    install_dolt_latest || true
    echo ""
fi

# --- bd (beads CLI) — bd 1.0+ ---
# The canonical repo is gastownhall/beads. GitHub redirects steveyegge/beads for now,
# but point installs at the real location to avoid future breakage.
if ! command -v bd &>/dev/null; then
    echo "bd (beads) CLI not found. Installing bd 1.0+..."
    if curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash; then
        # If bd ended up outside PATH (e.g. ~/go/bin), symlink it into ~/.local/bin
        if ! command -v bd &>/dev/null; then
            mkdir -p "$HOME/.local/bin"
            for search_dir in "$HOME/go/bin"; do
                if [ -x "$search_dir/bd" ]; then
                    echo "  Symlinking $search_dir/bd -> ~/.local/bin/bd"
                    ln -sf "$search_dir/bd" "$HOME/.local/bin/bd"
                    break
                fi
            done
        fi
        echo "  bd installed successfully."
    else
        echo "WARNING: bd (beads) auto-install failed."
        echo "  Install manually from: https://github.com/gastownhall/beads"
        echo "  Continuing without bd — task tracking features won't work."
    fi
    echo ""
fi

# Verify bd has CGO support (required for dolt backend)
if command -v bd &>/dev/null; then
    ensure_cgo_bd
    echo ""
fi

# --- perles (beads TUI) ---
if ! command -v perles &>/dev/null; then
    echo "perles (beads TUI) not found. Installing..."
    if curl -sSL https://raw.githubusercontent.com/zjrosen/perles/main/install.sh | bash; then
        # If perles ended up outside PATH (e.g. ~/go/bin), symlink it into ~/.local/bin
        if ! command -v perles &>/dev/null; then
            mkdir -p "$HOME/.local/bin"
            for search_dir in "$HOME/go/bin"; do
                if [ -x "$search_dir/perles" ]; then
                    echo "  Symlinking $search_dir/perles -> ~/.local/bin/perles"
                    ln -sf "$search_dir/perles" "$HOME/.local/bin/perles"
                    break
                fi
            done
        fi
        echo "  perles installed successfully."
    else
        echo "WARNING: perles auto-install failed."
        echo "  Install manually from: https://github.com/zjrosen/perles"
        echo "  Continuing without perles — beads TUI won't be available."
    fi
    echo ""
fi

installed=0

# --- Shell scripts (symlinked to ~/.local/bin) ---
echo "Shell scripts:"
link_scripts
echo ""

# --- Claude Code (plugin install handled by ~/.dotfiles/claude/dot.yaml via rotz) ---
# This script only handles legacy-symlink cleanup; the plugin install/update lives
# in the dotfiles rotz config (install_plugin infinifu@dotfiles) so it stays in
# sync with the other dotfiles plugins.
if [ -d "$CLAUDE_DIR" ]; then
    echo "Claude Code ($CLAUDE_DIR): legacy cleanup only — plugin install handled by rotz."

    # Remove conflicting superpowers plugin
    if command -v claude &>/dev/null && claude plugin list 2>&1 | grep -q "superpowers"; then
        echo "  Removing conflicting superpowers plugin..."
        claude plugin uninstall superpowers 2>&1 | sed 's/^/  /' || true
    fi
    [ -e "$CLAUDE_DIR/plugins/superpowers.js" ] && rm -f "$CLAUDE_DIR/plugins/superpowers.js"
    [ -L "$CLAUDE_DIR/skills/superpowers" ] && rm -f "$CLAUDE_DIR/skills/superpowers"

    # Clean up legacy symlink-based installation (pre-plugin era)
    claude_code_clean_legacy

    installed=1
    echo ""
fi

# --- OpenCode (symlink-based) ---
if [ -d "$OPENCODE_DIR" ]; then
    echo "OpenCode ($OPENCODE_DIR):"

    # Remove conflicting superpowers
    [ -e "$OPENCODE_DIR/plugins/superpowers.js" ] && rm -f "$OPENCODE_DIR/plugins/superpowers.js"
    [ -L "$OPENCODE_DIR/skills/superpowers" ] && rm -f "$OPENCODE_DIR/skills/superpowers"
    [ -d "$OPENCODE_DIR/superpowers" ] && rm -rf "$OPENCODE_DIR/superpowers"

    link_skills "$OPENCODE_DIR"
    link_commands "$OPENCODE_DIR"
    link_agents "$OPENCODE_DIR"

    # Symlink JS plugin
    mkdir -p "$OPENCODE_DIR/plugins"
    [ -L "$OPENCODE_DIR/plugins/infinifu.js" ] && rm -f "$OPENCODE_DIR/plugins/infinifu.js"
    ln -s "$INFINIFU_DIR/plugins/infinifu.js" "$OPENCODE_DIR/plugins/infinifu.js"
    echo "  Linked plugin:   $OPENCODE_DIR/plugins/infinifu.js"

    # Install plugin dependency
    if [ ! -f "$OPENCODE_DIR/package.json" ]; then
        echo '{"dependencies": {"@opencode-ai/plugin": "latest"}}' > "$OPENCODE_DIR/package.json"
    fi
    if command -v bun &>/dev/null; then
        (cd "$OPENCODE_DIR" && bun install --silent 2>/dev/null) || true
    elif command -v npm &>/dev/null; then
        (cd "$OPENCODE_DIR" && npm install --silent 2>/dev/null) || true
    fi

    installed=1
    echo ""
fi

# --- Neither found ---
if [ "$installed" -eq 0 ]; then
    echo "No Claude Code (~/.claude) or OpenCode (~/.config/opencode) config found."
    echo "Install Claude Code or OpenCode first, then re-run this script."
    exit 1
fi

# --- Done ---

echo "Infinifu installed successfully."
echo ""
echo "Restart your tools, then verify by asking:"
echo '  "do you have infinifu powers?"'
echo ""
echo "Skills are auto-dispatched based on context. You can also use slash commands:"
echo ""
echo "  Story phase:"
echo "    /story-write-fnf             - Capture user story (Connextra format)"
echo "    /story-read-fnf              - List, search, or show stories"
echo "    /story-find-fnf              - Find stories by area, with acceptance status"
echo "    /story-map-fnf               - Map repo paths to stories"
echo "    /story-mine-fnf              - Reverse-engineer stories from codebase"
echo "    /tag-manage-fnf              - Inspect or edit story tag taxonomy"
echo ""
echo "  Idea phase:"
echo "    /idea-brainstorm-fnf         - Explore requirements and design"
echo "    /idea-refactor-fnf           - Diagnose smells, design refactor"
echo ""
echo "  Spec phase:"
echo "    /spec-write-fnf              - Create implementation spec"
echo "    /spec-refinement-fnf         - Refine subtasks, catch corner cases"
echo "    /plan-track-fnf              - Create bd epic and tasks from spec"
echo ""
echo "  Plan phase:"
echo "    /plan-supervised-fnf         - Agent batches; user reviews each batch"
echo "    /plan-dispatch-fnf           - Dispatch scrum-master to bd ready tasks"
echo ""
echo "  Work phase:"
echo "    /domain-tdd-fnf                - Test-driven development"
echo "    /domain-bug-fixing-fnf         - Bug discovery through fix"
echo "    /domain-debug-systematic-fnf   - Systematic debugging"
echo "    /domain-debug-root-cause-fnf   - Trace to original trigger"
echo "    /domain-debug-tools-fnf        - Debug with tools and research"
echo "    /work-refactor-execute-fnf   - Execute refactor safely"
echo "    /domain-git-worktrees-fnf      - Isolated git worktrees"
echo ""
echo "  Review phase:"
echo "    /work-review-fnf             - Review against spec"
echo "    /domain-review-requesting-fnf  - Prepare for review"
echo "    /domain-review-receiving-fnf   - Process review feedback"
echo ""
echo "  Test phase:"
echo "    /work-test-analyze-fnf       - Audit test quality"
echo "    /domain-test-anti-patterns-fnf - Prevent test anti-patterns"
echo "    /domain-verification-fnf  - Verify before claiming done"
echo ""
echo "  Ship phase:"
echo "    /work-ship-fnf               - Push, sync, hand off"
echo "    /spec-retro-fnf              - Delivery retrospective"
echo ""
echo "  Meta:"
echo "    /meta-skill-writing-fnf      - Create or edit skills"
echo ""
echo "To update after source changes:"
echo "  claude plugin marketplace update infinifu-dev"
echo "  claude plugin update infinifu@infinifu-dev"
