#!/usr/bin/env bash
# test-clip-store-wl.sh - the Wayland half of clipboard history: the capture
# (clip-store-wl.sh --event) and qs-clip.sh's list/set when the session has
# WAYLAND_DISPLAY and no DISPLAY. No compositor: wl-paste and wl-copy are stubs
# reading a fake selection from files.
#
# Usage: i3/scripts/test-clip-store-wl.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
W="$here/clip-store-wl.sh"
QC="$here/../../quickshell/qs-clip.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
no() { fail=$((fail + 1)); echo "FAIL - $1${2:+: $2}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got '$2', wanted '$3'"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sel" "$T/run"
export WL_SEL="$T/sel" XDG_RUNTIME_DIR="$T/run"
unset DISPLAY
STORE="$T/run/clip-store/kwi3-test"

# Fake selection: $WL_SEL/types (one per line), $WL_SEL/payload, and
# $WL_SEL/types2, which replaces types after the first listing (a password
# manager taking the selection mid-read). Every payload read is logged.
cat >"$T/bin/wl-paste" <<'STUB'
#!/bin/sh
case " $* " in
*" -l "*|*" --list-types "*)
    cat "$WL_SEL/types"
    [ -e "$WL_SEL/types2" ] && mv "$WL_SEL/types2" "$WL_SEL/types"
    exit 0 ;;
esac
echo "$*" >>"$WL_SEL/reads"
cat "$WL_SEL/payload"
STUB
cat >"$T/bin/wl-copy" <<'STUB'
#!/bin/sh
echo "$*" >"$WL_SEL/copy.args"
cat >"$WL_SEL/copy.bytes"
echo "$WAYLAND_DISPLAY" >"$WL_SEL/copy.display"
STUB
chmod +x "$T/bin/wl-paste" "$T/bin/wl-copy"
export PATH="$T/bin:$PATH"

event() { CLIPBOARD_STATE="${STATE:-data}" sh "$W" --event kwi3-test </dev/null; }
sel() { printf '%b' "$1" >"$WL_SEL/types"; printf '%b' "$2" >"$WL_SEL/payload"; rm -f "$WL_SEL/reads" "$WL_SEL/types2"; }
entries() { (cd "$STORE" 2>/dev/null && ls -1 | tr '\n' ' '); }

# --- capture
sel 'text/plain;charset=utf-8\ntext/plain\n' 'first\n  line\n'
event
check "text: stored as the first entry" "$(entries)" "000001.clip "
printf 'first\n  line\n' >"$T/want"
cmp -s "$STORE/000001.clip" "$T/want" && ok "text: bytes exact, trailing newline kept" || no "text: bytes exact, trailing newline kept"
check "store is private" "$(stat -c %a "$STORE")" "700"
event
check "dedup: same text is not a new entry" "$(entries)" "000001.clip "
sel 'UTF8_STRING\nSTRING\n' 'second'
event
check "text: X-style target names count as text" "$(entries)" "000001.clip 000002.clip "

sel 'image/png\n' '\x89PNGdata'
event
check "image: stored as .img on the shared counter" "$(entries)" "000001.clip 000002.clip 000003.img "
event
check "dedup: same image is not a new entry" "$(entries)" "000001.clip 000002.clip 000003.img "
sel 'image/png\ntext/plain\n' 'mixed'
event
check "mixed owner: captured as text" "$(entries)" "000001.clip 000002.clip 000003.img 000004.clip "
sel 'application/x-unknown\n' 'blob'
event
check "unknown type: nothing stored" "$(entries)" "000001.clip 000002.clip 000003.img 000004.clip "
sel 'text/plain\n' ''
event
check "empty selection: nothing stored" "$(entries)" "000001.clip 000002.clip 000003.img 000004.clip "

# --- secrets: the payload must never even be read
before=$(entries)
sel 'text/plain\nx-kde-passwordManagerHint\n' 'hunter2'
event
check "secret hint: nothing stored" "$(entries)" "$before"
[ -e "$WL_SEL/reads" ] && no "secret hint: payload never read" || ok "secret hint: payload never read"
sel 'text/plain\napplication/x-kde-passwordManagerHint\n' 'hunter2'
event
check "secret hint, prefixed spelling: nothing stored" "$(entries)" "$before"
sel 'text/plain\n' 'hunter2'
STATE=sensitive event
check "CLIPBOARD_STATE=sensitive: nothing stored" "$(entries)" "$before"
[ -e "$WL_SEL/reads" ] && no "CLIPBOARD_STATE=sensitive: payload never read" || ok "CLIPBOARD_STATE=sensitive: payload never read"
STATE=clear event
STATE=nil event
check "cleared selection: nothing stored" "$(entries)" "$before"
sel 'text/plain\n' 'hunter2'
printf 'text/plain\nx-kde-passwordManagerHint\n' >"$WL_SEL/types2"
event
check "owner turned password manager mid-read: dropped" "$(entries)" "$before"
leftover=$(cd "$STORE" && ls -A | grep -v -E '^[0-9]{6}\.(clip|img)$')
check "no work files left behind" "$leftover" ""

# --- caps
rm -rf "$STORE"
for i in 1 2 3 4; do sel 'text/plain\n' "t$i"; CLIP_STORE_CAP=2 event; done
check "cap: oldest text pruned" "$(entries)" "000003.clip 000004.clip "
for i in 1 2; do sel 'image/png\n' "i$i"; CLIP_STORE_CAP=2 CLIP_STORE_IMG_CAP=1 event; done
check "cap: kinds pruned separately" "$(entries)" "000003.clip 000004.clip 000006.img "

# --- refusals
sh "$W" >/dev/null 2>&1
check "no display: exit 78" "$?" "78"
env -u XDG_RUNTIME_DIR sh "$W" kwi3-test >/dev/null 2>&1
check "no XDG_RUNTIME_DIR: exit 78, no persistent fallback" "$?" "78"

# --- qs-clip.sh in a Wayland session
qc() { WAYLAND_DISPLAY=kwi3-test sh "$QC" "$@"; }
out=$(qc list); rc=$?
check "list: reads the store of WAYLAND_DISPLAY" "$rc" "0"
check "list: newest first, image labelled" "$(printf '%s' "$out" | cut -f1,2 | tr '\t\n' '= ')" "000006.img=[image] 000004.clip=t4 000003.clip=t3 "
printf 'a\nb\n\n' >"$STORE/000004.clip"
qc set 000004.clip; check "set text: exit 0" "$?" "0"
cmp -s "$STORE/000004.clip" "$WL_SEL/copy.bytes" && ok "set text: bytes exact" || no "set text: bytes exact"
check "set text: typed as text" "$(cat "$WL_SEL/copy.args")" "--type text/plain;charset=utf-8"
check "set text: this session's display" "$(cat "$WL_SEL/copy.display")" "kwi3-test"
qc set 000006.img; check "set image: exit 0" "$?" "0"
check "set image: typed as png" "$(cat "$WL_SEL/copy.args")" "--type image/png"
cmp -s "$STORE/000006.img" "$WL_SEL/copy.bytes" && ok "set image: bytes exact" || no "set image: bytes exact"
rm -f "$WL_SEL/copy.bytes"
qc set 000099.clip 2>/dev/null; check "set unknown id: exit 1" "$?" "1"
[ -e "$WL_SEL/copy.bytes" ] && no "set unknown id: nothing published" || ok "set unknown id: nothing published"
qc set ../x 2>/dev/null; check "set bad id: exit 1" "$?" "1"
sh "$QC" list >/dev/null 2>&1; check "list with no display at all: exit 1" "$?" "1"
out=$(DISPLAY=:77 WAYLAND_DISPLAY=kwi3-test sh "$QC" list); check "DISPLAY still wins when both are set" "$out" ""

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
