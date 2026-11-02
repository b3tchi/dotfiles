#!/usr/bin/env bash
# install-win32.sh - build hotkeyd for Windows from WSL and install it where
# the kwi3 Win32 host runs it (sp012 Task 7, kwi3-hoex.7):
#
#   %LOCALAPPDATA%\hotkeyd\bin\hotkeyd.exe
#
# and copies the kwi3 runner's program list from this checkout,
# kwi3/runner-list.json, to where kwi3-run.exe reads it (sp012 Task 13,
# kwi3-hoex.13):
#
#   %APPDATA%\kwi3\runner-list.json
#
# and (kwi3-hoex.38) the nushell project registry - WSL's own
# ~/.config/project/projects.yaml, the file `project add` writes, or
# $PROJECT_CONFIG_PATH (the variable nushell's project module sets) - to
# where kwi3-run.exe's `projects` verb ($mod+p) reads it:
#
#   %APPDATA%\project\projects.yaml
#
# Jan 2026-11-02: a Windows copy, never read through \\wsl.localhost at run
# time. No registry in WSL is a WARNING and the install goes on ($mod+p
# then shows "no project registry"). Beside it, %APPDATA%\project\wsl.txt
# names the distro and the user this script runs as ("distro <name>",
# "user <name>"): a bare wsl.exe starts the default distro as ITS default
# user - root on Jan's box (Lxss DefaultUid 0) - whose home has no
# `project go`, so kwi3-run's `wsl.exe -d <distro> -u <user>` comes from it.
#
# A copy, not a link: an edit to the list takes a re-run of this script. The
# list is copied first, before the build, and does not wait on the stale-image
# rule below (kwi3-run.exe reads the file, it does not run from it). A
# checkout without the list is refused before anything is touched.
#
#   hotkeyd/install-win32.sh
#
# The build is GOOS=windows -tags win32 (the Windows chord table,
# host_win32.go) with -ldflags -H=windowsgui (no console window: the host
# starts it, and `hotkeyd recover` restarts it, detached). The built binary
# validates its own compiled table (--check) before anything is copied.
#
# STALE IMAGE RULE (the kwi3 Win32 rig's, kwi3-xkzt). Windows will not let
# a running image be replaced, and a half-done replace is worse than none.
# So before copying, the script asks Windows (Get-CimInstance Win32_Process,
# matched on the FULL ExecutablePath, never the name) for any process
# running from the install path, and REFUSES - exit 2, every such pid and
# command line named, nothing copied - while one is. It never ends a
# process. Stop the daemon first - `hotkeyd.exe stop [--display DESKTOP]`
# (kwi3-hoex.30) - and `hotkeyd.exe recover` starts it from the new image
# afterwards, with the old one's arguments. A query that fails refuses too: an install it cannot
# check is not done.
#
# %LOCALAPPDATA% and %APPDATA% are read from Windows through cmd.exe, so an
# override passed in through WSLENV (LOCALAPPDATA=C:\a APPDATA=C:\b
# WSLENV=LOCALAPPDATA:APPDATA) installs there instead of the real profile.
#
# After an install, `"%LOCALAPPDATA%\hotkeyd\bin\hotkeyd.exe" --health`
# says whether this desktop's daemon serves (exit 0), or which check fails:
# the lock's pid, the control socket, the active layer's chords, kwi3rpc.
#
# Exit: 0 installed; 1 the build or --check failed; 2 refused (an image
# running, the process query failed, no kwi3/runner-list.json in this
# checkout) or a setup error (no go, not WSL).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "install-win32.sh: $*" >&2; exit 2; }

command -v go >/dev/null || die "no go on PATH"
command -v wslpath >/dev/null || die "not WSL (no wslpath)"
CMD=/mnt/c/Windows/System32/cmd.exe
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[ -x "$CMD" ] || die "no Windows interop ($CMD)"
[ -x "$PS" ] || die "no powershell.exe ($PS)"

lad_win="$(env -C /mnt/c "$CMD" /d /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')"
case "$lad_win" in
    ""|%LOCALAPPDATA%) die "cannot read %LOCALAPPDATA% from Windows" ;;
esac
dest_win="$lad_win\\hotkeyd\\bin\\hotkeyd.exe"
dest="$(wslpath -u "$dest_win")" || die "cannot map $dest_win into WSL"

# The runner list, from this checkout (hotkeyd/../kwi3/runner-list.json).
list_src="$(dirname "$HERE")/kwi3/runner-list.json"
[ -f "$list_src" ] || die "REFUSED - no runner list at $list_src; nothing installed"
ad_win="$(env -C /mnt/c "$CMD" /d /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r')"
case "$ad_win" in
    ""|%APPDATA%) die "cannot read %APPDATA% from Windows" ;;
esac
list_win="$ad_win\\kwi3\\runner-list.json"
list_dest="$(wslpath -u "$list_win")" || die "cannot map $list_win into WSL"
mkdir -p "$(dirname "$list_dest")" || die "cannot create $(dirname "$list_win")"
cp "$list_src" "$list_dest.new" || die "cannot write $list_win.new"
mv -f "$list_dest.new" "$list_dest" || { rm -f "$list_dest.new"; die "cannot replace $list_win"; }
echo "install-win32.sh: copied $list_src to $list_win"

# The project registry (kwi3-hoex.38), the same way: before the build, so a
# `project add` reaches $mod+p with a re-run even while the daemon runs.
proj_src="${PROJECT_CONFIG_PATH:-$HOME/.config/project/projects.yaml}"
proj_win="$ad_win\\project\\projects.yaml"
if [ -f "$proj_src" ]; then
    proj_dest="$(wslpath -u "$proj_win")" || die "cannot map $proj_win into WSL"
    mkdir -p "$(dirname "$proj_dest")" || die "cannot create $(dirname "$proj_win")"
    cp "$proj_src" "$proj_dest.new" || die "cannot write $proj_win.new"
    mv -f "$proj_dest.new" "$proj_dest" || { rm -f "$proj_dest.new"; die "cannot replace $proj_win"; }
    echo "install-win32.sh: copied $proj_src to $proj_win"
fi
# The WSL target beside it, always: the distro (the \\wsl.localhost\<distro>
# root wslpath names) and this user.
wsl_distro="$(wslpath -w / 2>/dev/null | sed -n 's/^\\\\wsl[^\\]*\\\([^\\]*\)\\*$/\1/p')"
wsl_user="$(id -un)"
[ -n "$wsl_distro" ] && [ -n "$wsl_user" ] || die "cannot name this WSL distro ($(wslpath -w / 2>&1)) or user"
wsl_win="$ad_win\\project\\wsl.txt"
wsl_dest="$(wslpath -u "$wsl_win")" || die "cannot map $wsl_win into WSL"
mkdir -p "$(dirname "$wsl_dest")" || die "cannot create $(dirname "$wsl_win")"
printf '# written by dotfiles hotkeyd/install-win32.sh: kwi3-run projects starts wsl.exe -d <distro> -u <user>\r\ndistro %s\r\nuser %s\r\n' \
    "$wsl_distro" "$wsl_user" >"$wsl_dest.new" || die "cannot write $wsl_win.new"
mv -f "$wsl_dest.new" "$wsl_dest" || { rm -f "$wsl_dest.new"; die "cannot replace $wsl_win"; }
echo "install-win32.sh: wrote $wsl_win (distro $wsl_distro, user $wsl_user)"
if [ ! -f "$proj_src" ]; then
    echo "install-win32.sh: WARNING: no project registry at $proj_src - $proj_win not written; \$mod+p shows \"no project registry\" until it exists and this is re-run" >&2
fi

stage="$(mktemp -d)" || die "cannot create a staging directory"
trap 'rm -rf "$stage"' EXIT
built="$stage/hotkeyd.exe"

echo "install-win32.sh: building hotkeyd.exe (GOOS=windows -tags win32 -H=windowsgui)"
if ! GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go -C "$HERE" build -trimpath \
        -tags win32 -ldflags '-H=windowsgui' -o "$built" ./cmd/hotkeyd; then
    echo "install-win32.sh: build failed" >&2
    exit 1
fi

# --check runs the built image itself (validates the compiled table; no
# chord, no socket, no daemon). Run from the Windows side of the staging
# copy: a Windows image is never run from the \\wsl.localhost share.
win_tmp="$(env -C /mnt/c "$CMD" /d /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')"
[ -n "$win_tmp" ] || die "cannot read %TEMP% from Windows"
check_dir="$(wslpath -u "$win_tmp")/hotkeyd-install-$$"
mkdir -p "$check_dir" || die "cannot create $check_dir"
cp "$built" "$check_dir/hotkeyd.exe" || die "cannot stage the --check copy"
check_out="$(env -C "$check_dir" "$check_dir/hotkeyd.exe" --check 2>&1)"
check_rc=$?
rm -rf "$check_dir"
if [ "$check_rc" -ne 0 ]; then
    printf '%s\n' "$check_out" >&2
    echo "install-win32.sh: the built hotkeyd.exe refused its own table (--check exit $check_rc); hotkeyd.exe not installed" >&2
    exit 1
fi
printf '%s\n' "$check_out"

# The stale-image rule: who runs from the install path right now?
script='$ErrorActionPreference = "Stop"
$want = $env:HOTKEYD_INSTALL_DEST
Get-CimInstance Win32_Process |
  Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $want) } |
  ForEach-Object { "P`t{0}`t{1}" -f $_.ProcessId, $_.CommandLine }
"hotkeyd-install: end"'
enc="$(printf '%s' "$script" | iconv -f utf-8 -t utf-16le | base64 -w0)" || die "cannot encode the process query"
out="$(env -C /mnt/c HOTKEYD_INSTALL_DEST="$dest_win" WSLENV="HOTKEYD_INSTALL_DEST${WSLENV:+:$WSLENV}" \
        timeout 60 "$PS" -NoProfile -NonInteractive -EncodedCommand "$enc" 2>&1 | tr -d '\r')"
if ! printf '%s\n' "$out" | grep -qx 'hotkeyd-install: end'; then
    printf '%s\n' "$out" >&2
    echo "install-win32.sh: REFUSED - cannot ask Windows which processes run $dest_win; hotkeyd.exe not installed" >&2
    exit 2
fi
running="$(printf '%s\n' "$out" | grep '^P	' || true)"
if [ -n "$running" ]; then
    echo "install-win32.sh: REFUSED - $dest_win is running; hotkeyd.exe not installed:" >&2
    printf '%s\n' "$running" | while IFS=$'\t' read -r _ pid cmdline; do
        echo "  pid $pid: $cmdline" >&2
    done
    echo "install-win32.sh: nothing is ended here. Stop it first with \"$dest_win\" stop (add --display <desktop> for a daemon on another desktop), re-run this, then \"$dest_win\" recover starts the new image with the old one's arguments" >&2
    exit 2
fi

mkdir -p "$(dirname "$dest")" || die "cannot create $(dirname "$dest_win")"
cp "$built" "$dest.new" || die "cannot write $dest_win.new"
mv -f "$dest.new" "$dest" || { rm -f "$dest.new"; die "cannot replace $dest_win"; }
echo "install-win32.sh: installed $dest_win"
echo "install-win32.sh: check it with: \"$dest_win\" --health"
