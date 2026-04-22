#!/usr/bin/env nu

# clipboard-to-win.nu — Long-running Wayland → Windows clipboard sync
#
# Started by sway via `exec`. Polls the Wayland clipboard every 500ms and
# pushes changes to Windows. Replaces `wl-paste --watch` which can silently
# lose its compositor subscription after long uptime (the process stays
# alive but stops firing callbacks).
#
# Echo-loop prevention via /tmp/clipboard-last-hash (shared with
# win-clipboard-sync.nu): if the current Wayland content hashes to the same
# value, we either just pulled it from Windows or already pushed it.

const CLIPBOARD_IMG = "/tmp/clipboard-sync.png"
const HASH_FILE = "/tmp/clipboard-last-hash"
const POWERSHELL = '/mnt/c/windows/System32/WindowsPowerShell/v1.0/powershell.exe'

def stored_hash [] {
    if ($HASH_FILE | path exists) { open $HASH_FILE | str trim } else { "" }
}

loop {
    try {
        let types = (wl-paste --list-types | complete | get stdout | lines)

        if ("image/png" in $types) {
            wl-paste --type image/png | save -f $CLIPBOARD_IMG
            let h = (open --raw $CLIPBOARD_IMG | hash md5)
            if $h != (stored_hash) {
                $h | save -f $HASH_FILE
                let win_img = (^wslpath -w $CLIPBOARD_IMG | str trim)
                let win_ps1 = (^wslpath -w $"($env.HOME)/.local/bin/clipboard-to-win-image.ps1" | str trim)
                ^$POWERSHELL -noprofile -executionpolicy bypass -file $win_ps1 $win_img
            }
        } else if ("text/plain" in $types or "TEXT" in $types or "STRING" in $types or "UTF8_STRING" in $types) {
            let text = (wl-paste)
            let h = ($text | hash md5)
            if $h != (stored_hash) {
                $h | save -f $HASH_FILE
                $text | ^/mnt/c/windows/system32/clip.exe
            }
        }
    }
    sleep 500ms
}
