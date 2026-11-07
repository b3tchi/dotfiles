#!/bin/sh
# clip-store-wl.sh - clipboard history capture for a KWin (Wayland) session: the
# phone screen, kwi3-kwin. clip-store.sh's twin, which is X11 only (clipnotify,
# xclip). Same store, so qs-clip.sh and the picker read it the same way:
#
#   store dir   $XDG_RUNTIME_DIR/clip-store/<wayland display>/    0700, tmpfs
#   entry       NNNNNN.clip (text) or NNNNNN.img (PNG), one counter for both
#
# See clip-store.sh's header for the contract; only the transport differs.
# Differences that are not transport: image/bmp is not converted (that is an
# xrdp-chansrv quirk), and no display fan-out, because wl-copy has one session.
#
# wl-paste --watch needs the compositor's data-control protocol, which KWin
# offers. It runs this script again, as --event, for every clipboard change.
#
# SECURITY, same gate as clip-store.sh: the offered types are read first, and a
# password-manager hint means the payload is never fetched. wl-paste also says so
# itself (CLIPBOARD_STATE=sensitive). The types are checked again after the read,
# failing closed, for an owner that changed in between. Plaintext on tmpfs for the
# session's lifetime, and a secret copied with no hint is stored like anything
# else: the same exposure as the X11 store.
#
# usage: clip-store-wl.sh <wayland-display>     watch until the compositor exits
#        clip-store-wl.sh --event <display>     one clipboard change (internal)
# env:   CLIP_STORE_CAP      max text entries kept (default 100)
#        CLIP_STORE_IMG_CAP  max image entries kept (default 20)
#        CLIP_STORE_TIMEOUT  seconds before one wl-paste is abandoned (2)
# exit:  78 (EX_CONFIG) when the display or XDG_RUNTIME_DIR is missing, 69 when
#        wl-paste is, 0 on losing the single-instance race.
set -u

EVENT=0
if [ "${1:-}" = --event ]; then
    EVENT=1
    shift
fi
DPY="${1:-}"
CAP="${CLIP_STORE_CAP:-100}"
IMG_CAP="${CLIP_STORE_IMG_CAP:-20}"
T="${CLIP_STORE_TIMEOUT:-2}"

if [ -z "$DPY" ]; then
    echo "clip-store-wl.sh: no display: pass the Wayland display as \$1" >&2
    exit 78
fi
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    echo "clip-store-wl.sh: XDG_RUNTIME_DIR is unset; refusing to fall back to a persistent path" >&2
    exit 78
fi
if ! command -v wl-paste >/dev/null 2>&1; then
    echo "clip-store-wl.sh: wl-paste not found; install wl-clipboard" >&2
    exit 69
fi

export WAYLAND_DISPLAY="$DPY"
umask 077
ROOT="$XDG_RUNTIME_DIR/clip-store"
STORE="$ROOT/$DPY"
mkdir -p "$STORE" || exit 1
chmod 700 "$ROOT" "$STORE"

if [ "$EVENT" = 0 ]; then
    # One watcher per display. wl-paste keeps fd 9, so the lock lasts as long as
    # the watch does.
    exec 9>"$ROOT/$DPY.lock" || exit 1
    flock -n 9 || exit 0
    # Off stdout: wl-paste picks the type to watch from its output file's name, so
    # a session's *.log there means text, and an image-only clipboard never fires
    # an event. Nothing is written to stdout anyway. Errors stay on stderr.
    exec wl-paste --watch sh "$0" --event "$DPY" >/dev/null
fi

# ------------------------------------------------------------- one change ---

# Nothing is read from what wl-paste hands over on stdin: the type is chosen below.
exec </dev/null

case "${CLIPBOARD_STATE:-data}" in
data) ;;
*) exit 0 ;; # sensitive, or nothing there: clear, nil
esac

# Unique names: wl-paste does not wait for one event to end before the next.
TGT="$STORE/.tgt.$$"
WIP="$STORE/.wip.$$.tmp"
trap 'rm -f "$TGT" "$WIP"' EXIT

types() { timeout "$T" wl-paste --list-types >"$TGT" 2>/dev/null; }
hinted() {
    grep -qFx -e 'x-kde-passwordManagerHint' \
        -e 'application/x-kde-passwordManagerHint' "$TGT"
}
has_type() { grep -qFx "$1" "$TGT"; }

# Newest entry of one kind: pathname expansion is sorted, so the last match.
newest() {
    _n=""
    for _f in "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9]."$1"; do
        [ -e "$_f" ] && _n="$_f"
    done
    printf '%s' "$_n"
}

# Highest number in use across both kinds. Leading zeros stripped: $((000008))
# is an octal error in POSIX sh.
max_seq() {
    _m=0
    for _f in "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9].clip \
        "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9].img; do
        [ -e "$_f" ] || continue
        _b="${_f##*/}"
        _b="${_b%.*}"
        _v="${_b#"${_b%%[!0]*}"}"
        [ -n "$_v" ] || _v=0
        [ "$_v" -gt "$_m" ] && _m="$_v"
    done
    printf '%s' "$_m"
}

# ln, not mv: it fails on an existing name, so two events cost a retry, never an
# entry.
store() { # <extension>
    _s=$(($(max_seq) + 1))
    _try=0
    while [ "$_try" -lt 100 ]; do
        if ln "$WIP" "$STORE/$(printf '%06d' "$_s").$1" 2>/dev/null; then
            return 0
        fi
        _s=$((_s + 1))
        _try=$((_try + 1))
    done
    return 1
}

prune() { # <extension> <cap>
    while :; do
        _c=0
        _o=""
        for _f in "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9]."$1"; do
            [ -e "$_f" ] || continue
            _c=$((_c + 1))
            [ -n "$_o" ] || _o="$_f"
        done
        [ "$_c" -le "$2" ] && break
        rm -f "$_o"
    done
}

types || exit 0
hinted && exit 0

# Text first: a mixed owner (a browser's image with a URL) stays text, as on X11.
TYPE=""
KIND=""
for _t in 'text/plain;charset=utf-8' text/plain UTF8_STRING STRING TEXT; do
    if has_type "$_t"; then
        TYPE="$_t"
        KIND=clip
        break
    fi
done
if [ -z "$TYPE" ] && has_type image/png; then
    TYPE=image/png
    KIND=img
    CAP="$IMG_CAP"
fi
[ -n "$TYPE" ] || exit 0

timeout "$T" wl-paste --no-newline --type "$TYPE" >"$WIP" 2>/dev/null || exit 0
[ -s "$WIP" ] || exit 0

# The second half of the gate. Fails closed.
types || exit 0
hinted && exit 0

_last=$(newest "$KIND")
if [ -n "$_last" ] && cmp -s "$WIP" "$_last"; then
    exit 0
fi

store "$KIND" || exit 0
prune "$KIND" "$CAP"
