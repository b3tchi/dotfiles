#!/usr/bin/env nu

# win-clipboard-sync — Stream Windows clipboard changes into Wayland
#
# Started by sway via `exec`. Spawns win-clipboard-watch.ps1 which polls
# GetClipboardSequenceNumber() and emits TEXT:<base64>/IMAGE:<base64> on change.
# Echo-loop prevention: see clipboard-to-win.nu — shared /tmp/clipboard-last-hash.

const POWERSHELL = '/mnt/c/windows/System32/WindowsPowerShell/v1.0/powershell.exe'
const HASH_FILE = "/tmp/clipboard-last-hash"
const CLIPBOARD_IMG = "/tmp/win-clipboard-sync.png"

def stored_hash [] {
    if ($HASH_FILE | path exists) { open $HASH_FILE | str trim } else { "" }
}

let win_ps1 = (^wslpath -w $"($env.HOME)/.local/bin/win-clipboard-watch.ps1" | str trim)

loop {
    try {
        ^$POWERSHELL -NoProfile -ExecutionPolicy Bypass -STA -File $win_ps1
        | lines
        | each {|line|
            if ($line | str starts-with "IMAGE:") {
                let encoded = ($line | str substring 6..)
                $encoded | decode base64 | save -f $CLIPBOARD_IMG
                let h = (open --raw $CLIPBOARD_IMG | hash md5)
                if $h == (stored_hash) { return }
                $h | save -f $HASH_FILE
                open $CLIPBOARD_IMG | wl-copy --type image/png
            } else if ($line | str starts-with "TEXT:") {
                let encoded = ($line | str substring 5..)
                let text = ($encoded | decode base64 | decode utf-8 | str replace -a "\r" "")
                let h = ($text | hash md5)
                if $h == (stored_hash) { return }
                $h | save -f $HASH_FILE
                $text | wl-copy
            }
        }
    }
    sleep 3sec
}
