#!/usr/bin/env bash
# install-kwi3-cell.sh - give WezTerm on Windows kwi3's font and a character
# cell of exactly kwi3's module, from WSL (kwi3-wv1u):
#
#   %USERPROFILE%\.config\wezterm\kwi3-cell.lua
#
# A Lua table (font_family, font_size, cell_width, line_height) that
# wezterm.lua's Windows branch loads when it is there (pcall(dofile), and
# watched for reloads), so a WezTerm tiled by kwi3 into a slot of whole
# modules holds whole rows and columns. Removing the file undoes it.
# wezterm.lua itself is linked by wezterm/dot.yaml and never written here.
#
#   wezterm/install-kwi3-cell.sh [--config <config.js>] [--font-dir <dir>]... [--dry-run]
#
# The values come from kwi3's config.js exactly as winterm/
# install-kwi3-fragment.sh takes them (kwi3-cell.js runs it through
# winterm/kwi3-fragment.js, kwi3.host "win32"): by default the config.js
# the Windows host itself loads - %KWI3_CONFIG%, else
# %APPDATA%\kwi3\config.js, its kwi3.include()s followed. --config names
# another. WezTerm sizes its cell as a MULTIPLE of the font's own, so the
# font file is read too: the family config.js names, looked up in
# %LOCALAPPDATA%\Microsoft\Windows\Fonts and %SystemRoot%\Fonts (or only
# the --font-dir directories given). kwi3-cell.js's header has the mapping.
# A change to font or module in config.js, or a new font version, takes a
# re-run.
#
# Idempotent: generated, compared with what is installed and written (tmp +
# rename) only when it differs. --dry-run prints it and writes nothing.
#
# %USERPROFILE%, %LOCALAPPDATA%, %APPDATA% and %KWI3_CONFIG% are read from
# Windows through cmd.exe, so an override passed in through WSLENV
# (USERPROFILE=C:\a WSLENV=USERPROFILE) installs there instead.
#
# Exit: 0 installed or unchanged; 1 the config.js or the font could not be
# mapped; 2 refused (no config.js, a usage or setup error).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "install-kwi3-cell.sh: $*" >&2; exit 2; }

config=""
dry=0
font_dirs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ $# -ge 2 ] || die "--config needs a path"; config="$2"; shift 2 ;;
        --font-dir) [ $# -ge 2 ] || die "--font-dir needs a path"; font_dirs+=("$2"); shift 2 ;;
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

# The config.js the Windows host loads (install-kwi3-fragment.sh's rule).
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

if [ ${#font_dirs[@]} -eq 0 ]; then
    lad="$(winenv LOCALAPPDATA)"
    sr="$(winenv SystemRoot)"
    [ -n "$lad" ] && font_dirs+=("$lad\\Microsoft\\Windows\\Fonts")
    [ -n "$sr" ] && font_dirs+=("$sr\\Fonts")
    [ ${#font_dirs[@]} -gt 0 ] || die "cannot read %LOCALAPPDATA% or %SystemRoot% from Windows"
fi
dir_args=()
for d in "${font_dirs[@]}"; do
    dir_args+=(--font-dir "$(topath "$d")")
done

up="$(winenv USERPROFILE)"
[ -n "$up" ] || die "cannot read %USERPROFILE% from Windows"
up_l="$(wslpath -u "$up")" || die "cannot map $up into WSL"

lua="$(node "$HERE/kwi3-cell.js" --config "$config_l" --source "$config" "${dir_args[@]}")" || exit 1

if [ "$dry" = 1 ]; then
    printf '%s\n' "$lua"
    exit 0
fi

dest_dir="$up_l/.config/wezterm"
dest="$dest_dir/kwi3-cell.lua"
dest_w="$up\\.config\\wezterm\\kwi3-cell.lua"
if [ -f "$dest" ] && [ "$(cat "$dest")" = "$lua" ]; then
    echo "install-kwi3-cell.sh: $dest_w unchanged"
    exit 0
fi
mkdir -p "$dest_dir" || die "cannot create $(dirname "$dest_w")"
printf '%s\n' "$lua" > "$dest.new" || die "cannot write $dest_w.new"
mv -f "$dest.new" "$dest" || { rm -f "$dest.new"; die "cannot replace $dest_w"; }
echo "install-kwi3-cell.sh: wrote $dest_w (from $config)"
