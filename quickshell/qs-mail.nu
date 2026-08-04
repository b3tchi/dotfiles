#!/usr/bin/env nu
# qs-mail.nu — watch a Maildir for new mail and emit subject lines on stdout.
#
# Long-running feeder for a status bar: one line per event, written the moment
# the MDA hard-links a message into a `new/` directory.  Maildir delivery is
# atomic by spec (write to `tmp/`, link into `new/`), so a file appearing in
# `new/` is always a complete message — no partial-read window to guard.
#
# Output is a single line per event on stdout, flushed immediately, so it can
# drive any bar that reads a pipe:
#
#   quickshell   Process { command: ["nu", ".../qs-mail.nu"]; stdout: SplitParser {} }
#   polybar      type = custom/script, tail = true
#   i3blocks     interval=persist
#
# For a bar that polls instead of tailing, use `--once`: prints the current
# state and exits.

# Extract the raw Subject header from a message file.
#
# Reads only the header block (everything before the first blank line) and
# unfolds RFC 5322 continuation lines — a long subject is wrapped across
# several physical lines, each continuation starting with space or tab.
def read-subject [file: path]: nothing -> string {
    # Headers are ASCII-safe; 64 KiB is far past any realistic header block.
    let raw = (try { open --raw $file | first 65536 | decode utf-8 } catch { return "" })

    let head = ($raw | str replace --all "\r\n" "\n" | split row "\n\n" | first)

    # Unfold: join a continuation line onto the previous one.
    let unfolded = ($head
        | lines
        | reduce --fold [] {|line, acc|
            if ($line | str starts-with " ") or ($line | str starts-with "\t") {
                if ($acc | is-empty) {
                    $acc
                } else {
                    let joined = ($acc | last) + " " + ($line | str trim)
                    ($acc | drop 1 | append $joined)
                }
            } else {
                $acc | append $line
            }
        })

    let subj = ($unfolded | where {|l| $l | str lowercase | str starts-with "subject:" })

    if ($subj | is-empty) {
        ""
    } else {
        $subj | first | str substring 8.. | str trim
    }
}

# Decode one RFC 2047 encoded-word: =?charset?B|Q?payload?=
def decode-word [word: string]: nothing -> string {
    let m = ($word | parse --regex '(?i)^=\?(?<cs>[^?]+)\?(?<enc>[BQ])\?(?<data>.*)\?=$')
    if ($m | is-empty) { return $word }

    let cs = ($m | first | get cs | str lowercase | split row "*" | first)
    let enc = ($m | first | get enc | str uppercase)
    let data = ($m | first | get data)

    let bytes = if $enc == "B" {
        try { $data | decode base64 } catch { return $word }
    } else {
        # Q-encoding: "_" is a space, "=XX" is a raw byte.  Rebuild the whole
        # payload as one hex string so a single `decode hex` yields the bytes —
        # a =XX pair may be one byte of a multi-byte UTF-8 sequence and must not
        # be decoded to text on its own.
        let chars = ($data | str replace --all "_" " " | split chars)
        let n = ($chars | length)
        mut hex = ""
        mut i = 0
        while $i < $n {
            let c = ($chars | get $i)
            if $c == "=" and ($i + 2) < $n {
                let pair = (($chars | get ($i + 1)) + ($chars | get ($i + 2)))
                if ($pair | str lowercase) =~ '^[0-9a-f]{2}$' {
                    $hex = $hex + $pair
                    $i = $i + 3
                    continue
                }
            }
            $hex = $hex + ($c | encode utf-8 | encode hex)
            $i = $i + 1
        }
        try { $hex | decode hex } catch { return $word }
    }

    try { $bytes | decode $cs } catch {
        try { $bytes | decode utf-8 } catch { $word }
    }
}

# Decode every encoded-word in a header value, leaving plain runs untouched.
def decode-header [value: string]: nothing -> string {
    # Whitespace *between* two adjacent encoded-words is not part of the text
    # (RFC 2047 §6.2) — drop it before decoding so split words rejoin cleanly.
    let joined = ($value | str replace --all --regex '\?=\s+=\?' '?==?')

    $joined
    | split row --regex '(?i)(?=(?:=\?[^?]+\?[BQ]\?))'
    | each {|chunk|
        let m = ($chunk | parse --regex '(?i)^(?<word>=\?[^?]+\?[BQ]\?.*?\?=)(?<rest>.*)$')
        if ($m | is-empty) {
            $chunk
        } else {
            (decode-word ($m | first | get word)) + ($m | first | get rest)
        }
    }
    | str join ""
}

# All `new/` directories under the maildir root: the top-level folder plus every
# Maildir++ subfolder (`.Archive/new`, `.Lists.nu/new`, ...).
def new-dirs [root: path]: nothing -> list<path> {
    glob $"($root)/**/new" --no-file --no-symlink
}

def unread [root: path]: nothing -> list<path> {
    new-dirs $root
    | each {|d| glob $"($d)/*" --no-dir }
    | flatten
}

def render [
    file: path
    count: int
    root: path
    format: string
    max_len: int
]: nothing -> string {
    let subject = if ($file | is-empty) {
        ""
    } else {
        let s = (decode-header (read-subject $file) | str replace --all --regex '\s+' " " | str trim)
        if ($s | str length) > $max_len {
            ($s | str substring ..<($max_len - 1)) + "…"
        } else {
            $s
        }
    }

    # Folder name as the MUA shows it: ".Lists.nu/new" -> "Lists.nu", top -> "INBOX".
    let folder = if ($file | is-empty) {
        ""
    } else {
        let rel = ($file | path dirname | path relative-to $root | path dirname)
        if $rel == "" { "INBOX" } else { $rel | str trim --left --char "." }
    }

    $format
    | str replace --all "{subject}" $subject
    | str replace --all "{count}" ($count | into string)
    | str replace --all "{folder}" $folder
}

# Newest unread message by mtime, or an empty path when the maildir is clear.
def newest [root: path]: nothing -> path {
    let files = (unread $root)
    if ($files | is-empty) {
        ""
    } else {
        $files | each {|f| {f: $f, t: (ls -D $f | first | get modified)} } | sort-by t | last | get f
    }
}

def main [
    --maildir: path = "~/Maildir"   # maildir root to watch
    --format: string = "{count} {subject}"  # {subject} {count} {folder}
    --empty: string = ""            # line emitted when nothing is unread
    --max-len: int = 60             # truncate the subject past this many chars
    --debounce: duration = 200ms    # coalesce bursts from a fetch run
    --once                          # print current state and exit (polling bars)
] {
    let root = ($maildir | path expand)

    if not ($root | path exists) {
        error make {msg: $"maildir not found: ($root)"}
    }

    let emit = {||
        let files = (unread $root)
        let line = if ($files | is-empty) {
            $empty
        } else {
            render (newest $root) ($files | length) $root $format $max_len
        }
        print $line
    }

    do $emit

    if $once { return }

    # Watch the root, not each new/ dir: folders are created and removed while
    # this runs (a new mailing-list folder, an MUA compacting), and a watcher
    # pinned to a dir that disappears goes silent with no error.  The glob keeps
    # the events down to deliveries and to new->cur moves the MUA makes on read.
    watch $root --glob "**/new/*" --debounce $debounce --quiet
    | each {|_| do $emit }
    | ignore
}
