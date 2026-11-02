#!/usr/bin/env bash
# install-kwi3-fragment.sh - give every Windows Terminal profile kwi3's font
# and a character cell of exactly kwi3's module, from WSL (kwi3-hoex.47):
#
#   %LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\kwi3\kwi3-cell.json
#
# A WT JSON fragment (https://learn.microsoft.com/windows/terminal/
# json-fragment-extensions): for each profile it names by GUID ("updates") it
# sets font.face/size/cellWidth/cellHeight, padding "0" and scrollbarState
# "hidden", so a WT tiled by kwi3 into a slot of whole modules holds whole
# rows and columns. Jan's settings.json is NEVER written: the fragment sits
# beside it, WT layers it under the user's own profile keys (a key the user
# sets in settings.json still wins), and removing the file undoes it. WT
# reads fragments when its settings load - a WT already running picks it up
# on its next settings reload, a new window at once.
#
#   winterm/install-kwi3-fragment.sh [--config <config.js>] [--dry-run]
#
# The values come from kwi3's config.js, RUN with kwi3.host "win32" by
# kwi3-fragment.js beside this file (its header has the mapping and the WT
# source it is taken from): by default the config.js the Windows host itself
# loads - %KWI3_CONFIG%, else %APPDATA%\kwi3\config.js, with its
# kwi3.include()s followed - so the terminal and the host read one file.
# --config names another (a Linux or Windows path). A config.js the host
# would not find is refused, named; so is one that throws or sets no
# "<family> <px>" font / [w, h] module. A change to font or module there
# takes a re-run of this script.
#
# The profiles: Windows PowerShell, Command Prompt and Azure Cloud Shell by
# their fixed GUIDs, and every "guid" in the profiles.list of WT's
# settings.json (read, never written:
# %LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\
# settings.json) - so a WSL distro's profile is covered. A profile added
# later takes a re-run.
#
# Idempotent: the fragment is generated, compared with what is installed and
# written (tmp + rename) only when it differs. --dry-run prints it and writes
# nothing.
#
# %LOCALAPPDATA% and %APPDATA% are read from Windows through cmd.exe, so an
# override passed in through WSLENV (LOCALAPPDATA=C:\a APPDATA=C:\b
# WSLENV=LOCALAPPDATA:APPDATA) installs there instead of the real profile
# (hotkeyd/install-win32.sh's rule). WT itself only ever reads the REAL
# %LOCALAPPDATA% (SHGetKnownFolderPath), so such an install is inert.
#
# Exit: 0 installed or unchanged; 1 the config.js could not be mapped;
# 2 refused (no config.js, a usage or setup error).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "install-kwi3-fragment.sh: $*" >&2; exit 2; }

config=""
dry=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ $# -ge 2 ] || die "--config needs a path"; config="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

command -v node >/dev/null || die "no node on PATH"
command -v wslpath >/dev/null || die "not WSL (no wslpath)"
CMD=/mnt/c/Windows/System32/cmd.exe
[ -x "$CMD" ] || die "no Windows interop ($CMD)"

winenv() {  # winenv NAME -> the Windows value, empty when unset
    local v
    v="$(env -C /mnt/c "$CMD" /d /c "echo %$1%" 2>/dev/null | tr -d '\r')"
    [ "$v" = "%$1%" ] && v=""
    printf '%s' "$v"
}

topath() {  # a Linux path, or a Windows one mapped into WSL
    case "$1" in
        [A-Za-z]:\\*|[A-Za-z]:/*|\\\\*) wslpath -u "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

if [ -z "$config" ]; then
    config="$(winenv KWI3_CONFIG)"
    if [ -z "$config" ]; then
        ad="$(winenv APPDATA)"
        [ -n "$ad" ] || die "cannot read %APPDATA% from Windows"
        config="$ad\\kwi3\\config.js"
    fi
fi
config_l="$(topath "$config")" || die "cannot map $config into WSL"
[ -f "$config_l" ] || die "REFUSED - no kwi3 config.js at $config (the Windows host's %KWI3_CONFIG%, else %APPDATA%\\kwi3\\config.js); name one with --config"

lad="$(winenv LOCALAPPDATA)"
[ -n "$lad" ] || die "cannot read %LOCALAPPDATA% from Windows"
lad_l="$(wslpath -u "$lad")" || die "cannot map $lad into WSL"

settings="$lad_l/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
guid_args=()
if [ -f "$settings" ]; then
    while IFS= read -r g; do
        guid_args+=(--guid "$g")
    done < <(grep -oE '"guid"[[:space:]]*:[[:space:]]*"\{[0-9A-Fa-f-]{36}\}"' "$settings" \
             | grep -oE '\{[0-9A-Fa-f-]{36}\}')
else
    echo "install-kwi3-fragment.sh: no WT settings.json at $settings - the stock profiles only" >&2
fi

frag="$(node "$HERE/kwi3-fragment.js" --config "$config_l" --source "$config" "${guid_args[@]}")" || exit 1

if [ "$dry" = 1 ]; then
    printf '%s\n' "$frag"
    exit 0
fi

dest_dir="$lad_l/Microsoft/Windows Terminal/Fragments/kwi3"
dest="$dest_dir/kwi3-cell.json"
dest_w="$lad\\Microsoft\\Windows Terminal\\Fragments\\kwi3\\kwi3-cell.json"
if [ -f "$dest" ] && [ "$(cat "$dest")" = "$frag" ]; then
    echo "install-kwi3-fragment.sh: $dest_w unchanged"
    exit 0
fi
mkdir -p "$dest_dir" || die "cannot create $(dirname "$dest_w")"
printf '%s\n' "$frag" > "$dest.new" || die "cannot write $dest_w.new"
mv -f "$dest.new" "$dest" || { rm -f "$dest.new"; die "cannot replace $dest_w"; }
n=$(printf '%s\n' "$frag" | grep -c '"updates"')
echo "install-kwi3-fragment.sh: wrote $dest_w ($n profile(s), from $config)"
