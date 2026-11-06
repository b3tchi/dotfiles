#!/bin/sh
# deploy-kwin-host.sh - build kwi3's kwin-host branch and install it for the
# kwi3-kwin login session on THIS machine. No root.
#
#   deploy-kwin-host.sh [kwi3-worktree]
#
# Default worktree: ~/.local/src/kwi3/.worktrees/kwin-host.
#
# Why not `i3kwin/install.sh --local`: it copies with plain cp into ~/.local/bin,
# where kwi3-msg, kwi3-x11-session, kwi3-session-env.sh and kwi3-recover are
# symlinks into the release checkout. cp follows them, so it would overwrite the
# scripts the X11 kwi3 session runs with kwin-host's. This runs the same build
# scripts, and puts everything the X11 session could also find somewhere it does
# not look:
#
#   ~/.local/lib/kwi3-kwin/bin          helpers and hotkeyd (kwi3-kwin-session
#                                       puts it first on PATH, for itself only)
#   ~/.local/lib/kwi3/qml               Kwi3.Rpc module (module-build.sh default)
#   ~/.local/lib/qt6/plugins/kwin       kwi3keys plugin (plugin-build.sh default)
#   ~/.local/share/kwin/scripts/i3kwin  the KWin script package
#
# hotkeyd comes from dotfiles' origin/kwin-host, because main has no
# internal/kwin. It is exported with git archive, so the dotfiles checkout stays
# on its branch.
#
# Also applies kwinrc-settings.sh, which edits ~/.config/kwinrc and
# ~/.config/kdeglobals. Both are backed up once, as <file>.pre-kwi3-kwin.
set -eu

SRC=${1:-$HOME/.local/src/kwi3/.worktrees/kwin-host}
DOTFILES=${KWI3_DOTFILES:-$HOME/.dotfiles}
BIN=$HOME/.local/lib/kwi3-kwin/bin

[ -f "$SRC/i3kwin/install.sh" ] || { echo "deploy: no kwi3 tree at $SRC" >&2; exit 1; }

# A fixed path, never mktemp: module-build.sh and plugin-build.sh keep their CMake
# caches in ~/.cache/kwi3-build, and CMake refuses a cache whose source moved.
stage=${XDG_CACHE_HOME:-$HOME/.cache}/kwi3-build/stage
rm -rf "$stage"
mkdir -p "$stage"

echo "==> building packages from $SRC ($(git -C "$SRC" describe --always --dirty))"
sh "$SRC/i3kwin/install.sh" --build "$stage"
cp "$SRC/i3kwin/phone/module-build.sh" "$SRC/i3kwin/phone/plugin-build.sh" "$stage/"

echo "==> building hotkeyd from dotfiles origin/kwin-host"
mkdir "$stage/hk"
git -C "$DOTFILES" archive origin/kwin-host hotkeyd | tar -x -C "$stage/hk"
GOTOOLCHAIN="${GOTOOLCHAIN:-local}" CGO_ENABLED=0 \
    go -C "$stage/hk/hotkeyd" build -trimpath -o "$stage/hotkeyd" ./cmd/hotkeyd

# Same order as install.sh: nothing is installed until both native builds pass.
echo "==> checking build tools"
sh "$stage/module-build.sh" check "$stage"
sh "$stage/plugin-build.sh" check "$stage"
echo "==> building the kwi3keys plugin"
sh "$stage/plugin-build.sh" build "$stage"
echo "==> building and installing the Kwi3.Rpc module"
sh "$stage/module-build.sh" build "$stage"
echo "==> installing the kwi3keys plugin"
sh "$stage/plugin-build.sh" install "$stage"

echo "==> installing the i3kwin KWin script"
kpackagetool6 --type KWin/Script --upgrade "$stage/i3kwin" >/dev/null 2>&1 ||
    kpackagetool6 --type KWin/Script --install "$stage/i3kwin"

echo "==> installing helpers and hotkeyd into $BIN"
mkdir -p "$BIN"
# tmp + mv: never write over a running binary or a script a session is reading.
put() {
    cp "$1" "$BIN/.$2.new"
    chmod "$3" "$BIN/.$2.new"
    mv -f "$BIN/.$2.new" "$BIN/$2"
}
put "$stage/hotkeyd" hotkeyd 755
for f in i3act i3reload i3spawn i3tree; do
    put "$SRC/i3kwin/phone/bin/$f" "$f" 755
done
put "$SRC/i3kwin/bin/kwi3-msg" kwi3-msg 755
put "$SRC/krdp/phone/bin/kwi3-shot" kwi3-shot 755
# Sourced, not executed, by the helpers beside them.
put "$SRC/i3kwin/phone/bin/kwi3-rpcsock.sh" kwi3-rpcsock.sh 644
put "$SRC/i3kwin/session/kwi3-session-env.sh" kwi3-session-env.sh 644

echo "==> applying kwinrc settings"
for f in kwinrc kdeglobals; do
    rc=$HOME/.config/$f
    if [ -f "$rc" ] && [ ! -e "$rc.pre-kwi3-kwin" ]; then
        cp -p "$rc" "$rc.pre-kwi3-kwin"
        echo "    backed up $rc"
    fi
done
sh "$SRC/i3kwin/phone/config/kwinrc-settings.sh"

echo "==> done"
