#!/usr/bin/env nu

# clipboard-to-win.nu — Sync Wayland clipboard to Windows
#
# Called by: wl-paste --watch clipboard-to-win
# When the Wayland clipboard changes, wl-paste invokes this script
# with clipboard content on stdin.
#
# Supports text and image (PNG) clipboard content.

const WIN_TO_CLIPBOARD = "/tmp/win-to-clipboard"
const CLIPBOARD_TO_WIN = "/tmp/clipboard-to-win"
const CLIPBOARD_IMG = "/tmp/clipboard-sync.png"
const POWERSHELL = '/mnt/c/windows/System32/WindowsPowerShell/v1.0/powershell.exe'

# If win-to-clipboard just set the Wayland clipboard, skip to avoid echo loop
if ($WIN_TO_CLIPBOARD | path exists) {
    rm $WIN_TO_CLIPBOARD
    exit 0
}

# Detect what's on the Wayland clipboard
let types = (wl-paste --list-types | lines)

if ("image/png" in $types) {
    # Image path: save PNG from Wayland clipboard, then set on Windows clipboard
    wl-paste --type image/png | save -f $CLIPBOARD_IMG
    touch $CLIPBOARD_TO_WIN

    # Convert WSL path to Windows UNC path for PowerShell
    let win_img = (^wslpath -w $CLIPBOARD_IMG | str trim)
    let win_ps1 = (^wslpath -w $"($env.HOME)/.local/bin/clipboard-to-win-image.ps1" | str trim)

    ^$POWERSHELL -noprofile -executionpolicy bypass -file $win_ps1 $win_img

} else if ("text/plain" in $types or "TEXT" in $types or "STRING" in $types or "UTF8_STRING" in $types) {
    # Text path: pipe stdin to clip.exe
    touch $CLIPBOARD_TO_WIN
    $in | ^/mnt/c/windows/system32/clip.exe
}
