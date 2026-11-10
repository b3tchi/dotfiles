#!/bin/sh
# install-nura.sh - the `kwi3` dot on the phone (postmarketOS/Nura, sp040):
# kwi3 on KWin instead of the X11 host, and kwi3 as the session at every start.
# kwi3/dot.yaml runs this on apk systems. Needs no doas.
#
# It runs the kwi3 repo's own installer, `i3kwin/install.sh --local`, which
# builds and installs the i3kwin KWin script (with this repo's
# kwi3/config.js bundled), the Kwi3.Rpc QML module and the kwi3keys plugin
# (cmake, on the phone), hotkeyd's phone build (`-tags phone`, from this
# dotfiles tree), krdp-launch.sh, kwi3-phone-session, kwi3-shot and the
# helpers, all under ~/.local. It never restarts a session: install.sh prints
# the `i3reload` / `systemctl --user restart krdp-kwin` it would take.
#
# SOURCE: the `kwin-host` branch of kwi3, not a release tag (Jan,
# 2026-10-30) - nothing on kwin-host is tagged until it merges. The clone is
# ~/.local/src/kwi3-kwin, apart from `kwi3`'s tag checkout in
# ~/.local/src/kwi3. It is fetched from $KWI3_REPO, GitHub over ssh (the
# `github` dot sets that up; kwi3 is private, so the https URL never
# worked), and only fast-forwarded. A push from the dev box still works:
#
#   git -C <kwi3 kwin-host worktree> push phone:.local/src/kwi3-kwin kwin-host
#
# (the clone accepts a push into its checked-out branch,
# receive.denyCurrentBranch=updateInstead, like ~/.dotfiles on the phone).
# A clone with local changes is refused by name, never reset.
#
# NEEDS on the phone: node (config.js syntax check, font family) and go
# (hotkeyd), plus cmake and the KWin/Qt headers install.sh's own build
# steps check for. Packages there need doas:
#
#   doas apk add nodejs go
#
# FONTS: Iosevka (kwi3/config.js's titlebar and bar font) and Iosevka Nerd
# Font (the bar's font off kwi3) go to ~/.local/share/fonts, Regular and
# Bold only, each skipped when fontconfig already has the family. No apk:
# that needs doas. The releases are pinned (IOSEVKA, NERD below); a failed
# download is a warning, the kwi3 build goes on.
#
# $KWI3_KWIN_BIN is passed through to install.sh unchanged (the kwin_wayland
# the plugin is stamped against, when it is not the first on PATH).
#
# NOT INSTALLED HERE, and needed for the whole session on a fresh phone: the
# quickshell, foot and fonts dots (rotz install quickshell foot fonts). sxmo
# is deliberately not pulled in: its dot force-links over ~/.config/sxmo.
set -u

SRC="$HOME/.local/src/kwi3-kwin"
BRANCH=kwin-host
REPO="${KWI3_REPO:-git@github.com:b3tchi/kwi3.git}"
DOTS="$HOME/.dotfiles"

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$SRC"
  git -C "$SRC" init -q -b "$BRANCH"
  git -C "$SRC" config receive.denyCurrentBranch updateInstead
  echo "kwi3: created $SRC (push $BRANCH into it from the dev box)"
fi
if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then
  echo "kwi3: $SRC has local changes -- refusing to touch it." >&2
  exit 1
fi
cur=$(git -C "$SRC" symbolic-ref --short HEAD 2>/dev/null || true)
if [ "$cur" != "$BRANCH" ]; then
  echo "kwi3: $SRC is on '$cur', not $BRANCH -- refusing to switch it." >&2
  exit 1
fi

if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15" \
  timeout 30 git -C "$SRC" fetch -q "$REPO" "$BRANCH" 2>/dev/null; then
  if ! git -C "$SRC" rev-parse -q --verify HEAD >/dev/null; then
    git -C "$SRC" reset -q --hard FETCH_HEAD
  elif ! git -C "$SRC" merge -q --ff-only FETCH_HEAD 2>/dev/null; then
    echo "kwi3: WARNING -- $REPO $BRANCH does not fast-forward $SRC; building what is there." >&2
  fi
else
  echo "kwi3: $REPO not reachable; building what was pushed to $SRC."
fi
if ! git -C "$SRC" rev-parse -q --verify HEAD >/dev/null; then
  echo "kwi3: $SRC has no commit yet. From the dev box:" >&2
  echo "kwi3:   git -C <kwi3 kwin-host worktree> push phone:.local/src/kwi3-kwin $BRANCH" >&2
  exit 1
fi
echo "kwi3: $BRANCH at $(git -C "$SRC" rev-parse --short HEAD)"

IOSEVKA=34.9.1
NERD=3.5.1
FONT_DIR="$HOME/.local/share/fonts"
fonts_new=""
# $1 family, $2 url, $3 archive kind (zip|txz), $4.. files to keep
font_get() {
  fam=$1 url=$2 kind=$3
  shift 3
  if fc-list : family | tr ',' '\n' | grep -qx "$fam"; then
    return 0
  fi
  tmp=$(mktemp -d)
  if ! curl -fsSL "$url" -o "$tmp/a"; then
    echo "kwi3: WARNING -- download of $fam failed ($url)" >&2
    rm -rf "$tmp"
    return 0
  fi
  mkdir -p "$FONT_DIR" "$tmp/x"
  if [ "$kind" = zip ]; then
    unzip -q -o "$tmp/a" -d "$tmp/x"
  else
    xz -dc "$tmp/a" | tar -x -C "$tmp/x"
  fi
  for f in "$@"; do
    src=$(find "$tmp/x" -name "$f" | head -n 1)
    if [ -n "$src" ]; then
      mv "$src" "$FONT_DIR/$f"
      fonts_new="$fonts_new $f"
    else
      echo "kwi3: WARNING -- $f not in $url" >&2
    fi
  done
  rm -rf "$tmp"
}
font_get Iosevka \
  "https://github.com/be5invis/Iosevka/releases/download/v$IOSEVKA/PkgTTC-Iosevka-$IOSEVKA.zip" \
  zip Iosevka-Regular.ttc Iosevka-Bold.ttc
font_get "Iosevka Nerd Font" \
  "https://github.com/ryanoasis/nerd-fonts/releases/download/v$NERD/Iosevka.tar.xz" \
  txz IosevkaNerdFont-Regular.ttf IosevkaNerdFont-Bold.ttf
if [ -n "$fonts_new" ]; then
  fc-cache -f "$FONT_DIR"
  echo "kwi3: fonts installed:$fonts_new"
fi

MISSING=""
command -v node >/dev/null 2>&1 || MISSING="$MISSING nodejs"
command -v go >/dev/null 2>&1 || MISSING="$MISSING go"
command -v wl-paste >/dev/null 2>&1 || MISSING="$MISSING wl-clipboard"
if [ -n "$MISSING" ]; then
  echo "kwi3: missing on this machine:$MISSING" >&2
  echo "kwi3: install them (doas apk add$MISSING) and re-run 'rotz install kwi3'." >&2
  exit 1
fi

sh "$SRC/i3kwin/install.sh" --local \
  --config "$DOTS/kwi3/config.js" \
  --hotkeyd-src "$DOTS" --hotkeyd-tags phone || exit 1

# kwi3 at every start, with the crash guard (a kwi3 that dies within 60 s
# leaves that start to SXMO). Back to SXMO: kwi3-phone-session disable.
# It applies at the next tinydm start; a running session is left alone.
"$HOME/.local/bin/kwi3-phone-session" enable
