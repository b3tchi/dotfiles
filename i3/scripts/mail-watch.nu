#!/usr/bin/env nu
# mail-watch.nu — stream new-mail subject lines into polybar.
#
# Watches a Maildir tree and prints one status line every time the `new/`
# directories change.  Meant to back a `custom/script` module with `tail = true`
# (see the module snippet at the bottom of this file).
#
# Uses nushell's built-in `watch`, so there is no inotify-tools dependency; the
# same script runs unchanged wherever nu runs.
#
# Design notes:
#
#  * Only `*/new/*` counts.  Maildir delivery writes to `tmp/` and renames into
#    `new/`; the MUA moves a message to `cur/` once it has been seen.  So `new/`
#    IS the unread set — no state file, no database, nothing to keep in sync.
#  * Headers are read from the first 8 KiB of each file, never the whole thing.
#    A message with a 20 MB attachment must not cost 20 MB of reads on every
#    single filesystem event.
#  * Subjects are RFC 2047 decoded (=?utf-8?B?..?= / ?Q?..?=) so non-ASCII mail
#    does not show up as mojibake on the bar.
#  * Output is sanitised for polybar: `%{...}` is polybar's formatting-tag
#    syntax, so a subject containing it would inject colour/action tags into the
#    bar.  Neutralised below.

const MAILDIR = "~/Maildir"
const MAX_LEN = 60        # subject characters shown on the bar
const HEADER_BYTES = 8192 # bytes read per message when hunting for Subject:

# ------------------------------------------------------------------ decoding --

# Quoted-printable / RFC 2047 "Q" word: `_` is space, `=XX` is a raw byte.
# Bytes are collected and decoded as UTF-8 at the end, because one non-ASCII
# character is several `=XX` escapes that only mean something together.
def qp-decode [s: string]: nothing -> string {
    let chars = ($s | str replace --all "_" " " | split chars)
    let n = ($chars | length)
    mut bytes = []
    mut i = 0
    while $i < $n {
        let c = ($chars | get $i)
        let hex = if ($c == "=") and (($i + 2) < $n) {
            $"($chars | get ($i + 1))($chars | get ($i + 2))" | into int --radix 16 | default null
        } else {
            null
        }
        if $hex != null {
            $bytes = ($bytes | append ($hex | into binary --compact))
            $i = $i + 3
        } else {
            $bytes = ($bytes | append ($c | into binary))
            $i = $i + 1
        }
    }
    try { $bytes | bytes collect | decode utf-8 } catch { $s }
}

# Replace every RFC 2047 encoded-word in a header value with its plain text.
def rfc2047-decode [s: string]: nothing -> string {
    let words = ($s | parse --regex '(?<whole>=\?(?<charset>[^?]+)\?(?<enc>[BbQq])\?(?<text>[^?]*)\?=)')
    mut out = $s
    for w in $words {
        let plain = if (($w.enc | str lowercase) == "b") {
            try { $w.text | decode base64 | decode utf-8 } catch { $w.text }
        } else {
            qp-decode $w.text
        }
        $out = ($out | str replace --all $w.whole $plain)
    }
    # Encoded words sit adjacent with whitespace between them that is supposed
    # to vanish once decoded ("=?..?= =?..?=" is one logical string).
    $out
}

# ------------------------------------------------------------------- parsing --

def subject-of [file: path]: nothing -> string {
    let raw = try { open --raw $file | bytes at 0..<$HEADER_BYTES } catch { return "(unreadable)" }
    let text = try { $raw | decode utf-8 } catch {
        try { $raw | decode latin1 } catch { return "(undecodable)" }
    }
    # Header block ends at the first blank line; folded continuation lines
    # (leading space/tab) are joined back onto their header first.
    let head = ($text
        | str replace --all "\r\n" "\n"
        | split row "\n\n" | first
        | str replace --all --regex '\n[ \t]+' " ")
    let found = ($head | lines | where {|l| $l | str lowercase | str starts-with "subject:" })
    if ($found | is-empty) { return "(no subject)" }
    rfc2047-decode ($found | first | str substring 8.. | str trim)
}

# Polybar reads `%{...}` in a tail script's output as a formatting tag, and any
# newline as a new status line. Both have to go.
def sanitise [s: string]: nothing -> string {
    let flat = ($s | str replace --all --regex '[\r\n\t]+' " " | str replace --all "%{" "% {" | str trim)
    if ($flat | str length) > $MAX_LEN {
        $"($flat | str substring 0..<$MAX_LEN)…"
    } else {
        $flat
    }
}

# --------------------------------------------------------------------- state --

def unread [root: path]: nothing -> list {
    try {
        ls ($"($root)/**/new/*" | into glob)
        | where type == file
        | sort-by modified --reverse
    } catch {
        []
    }
}

def status-line [root: path]: nothing -> string {
    let msgs = (unread $root)
    let n = ($msgs | length)
    if $n == 0 {
        ""                                   # empty line: polybar hides the module
    } else {
        $"($n)  (sanitise (subject-of ($msgs | first | get name)))"
    }
}

# ---------------------------------------------------------------------- main --

def main [
    --once                    # print the current state and exit (for interval modules)
    --maildir: string = $MAILDIR
] {
    let root = ($maildir | path expand)

    if ($root | path type) != "dir" {
        print $"mail: no ($maildir)"
        return
    }

    print (status-line $root)

    if $once { return }

    # Debounce because a single delivery is several filesystem events (tmp
    # write, rename into new/, mtime bump on the directory).
    watch $root --recursive true --debounce 500ms --quiet
    | where {|e|
        ([($e.path? | default ""), ($e.new_path? | default "")]
        | any {|p| $p | str replace --all '\' '/' | str contains "/new/" })
    }
    | each {|_| print (status-line $root) }
    | ignore
}

# --- polybar module -----------------------------------------------------------
#
# [module/mail]
# type = custom/script
# exec = ~/.config/polybar/scripts/mail-watch.nu
# tail = true
# interval = 5          ; respawn if the script exits (e.g. Maildir not there yet)
# format-prefix = " "
# click-left = i3-msg -q exec "$TERMINAL -e neomutt"
#
# ...then add `mail` to the bar's modules-right list.
