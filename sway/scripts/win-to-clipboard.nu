#!/usr/bin/env nu

# win-to-clipboard.nu — Sync Windows clipboard to Wayland
#
# Runs as a systemd user service. Launches a PowerShell monitor on the
# Windows side that detects clipboard changes when focus returns to WSLg.
# Reads its stdout stream and updates the Wayland clipboard via wl-copy.
#
# Protocol from PowerShell monitor:
#   TEXT:<base64-encoded-text>
#   IMAGE:<base64-encoded-png>

const CLIPBOARD_TO_WIN = "/tmp/clipboard-to-win"
const WIN_TO_CLIPBOARD = "/tmp/win-to-clipboard"
const CLIPBOARD_IMG = "/tmp/clipboard-sync-from-win.png"
const POWERSHELL = '/mnt/c/windows/System32/WindowsPowerShell/v1.0/powershell.exe'

let win_ps1 = (^wslpath -w $"($env.HOME)/.local/bin/win-clipboard-monitor.ps1" | str trim)

^$POWERSHELL -noprofile -executionpolicy bypass -file $win_ps1
| lines
| each {|line|
    # Guard against echo loop: if clipboard-to-win just ran, skip
    if ($CLIPBOARD_TO_WIN | path exists) {
        let modified = (ls -l $CLIPBOARD_TO_WIN | get 0.modified)
        let age_ms = ((date now) - $modified) / 1ms
        if $age_ms < 1000 {
            # Less than 1 second since Wayland clipboard was updated, skip
            return
        }
    }

    # Signal to clipboard-to-win that this copy came from Windows
    touch $WIN_TO_CLIPBOARD

    if ($line | str starts-with "IMAGE:") {
        let encoded = ($line | str substring 6..)
        $encoded | decode base64 | save -f $CLIPBOARD_IMG
        open $CLIPBOARD_IMG | wl-copy --type image/png
    } else if ($line | str starts-with "TEXT:") {
        let encoded = ($line | str substring 5..)
        $encoded | decode base64 | decode utf-8 | str replace -a "\r" "" | wl-copy
    }
}
