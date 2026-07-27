#!/bin/sh
# hotkeyd-panic.sh — give the keyboard back to i3 (sp020 Task 10, ft011).
#
# usage: hotkeyd-panic.sh panic|resume|status [display]
#
# THE ESCAPE HATCH, REPLACING `hotkeyd.sh restart`. A restart helps when the
# daemon is DEAD and not at all when it is alive and WRONG — misgrabbing, stuck
# in a layer, or serving a table whose chords collide with i3's. Recovery has to
# mean "give the keyboard back to i3", so that is what this does:
#
#   panic:   hotkeyd.sh stop (every display)
#         -> link i3/config.d/zz-fallback-binds.conf into ~/.i3/config.d/
#         -> i3-msg reload
#   resume:  unlink -> i3-msg reload -> hotkeyd.sh start
#
# NO CONTESTED-CHORD WINDOW. X drops a client's passive grabs when the client
# goes, so stopping the daemon frees every chord it held before i3 is asked to
# re-parse anything; i3 then takes its own grabs on reload. At no point do two
# clients hold one chord. This is the same reasoning that made the Task 6 revert
# clean — stop the daemon, reload i3, every key works — with no ungrab
# bookkeeping anywhere.
#
# PANIC IS MACHINE-WIDE, NOT PER-DISPLAY. This is the Task 10 decision, and it
# is forced rather than chosen: `~/.i3/config.d/` is ONE directory, and both
# sessions reach it through the same `include ~/.i3/config.d/*.conf` line in the
# single shared `i3/config` entry point (adr0004 keeps :0 and :10 live at once).
# There is no per-display glob to scope the link with, and i3's `include` takes
# no conditionals — the only per-display fallback would be a second entry point,
# i.e. exactly the hand-synced config duplication ft003 exists to have deleted.
#
# Documenting "resume must precede any reload on the other display" would leave
# the hazard real and merely written down: panicking on :10 links a file :0's i3
# parses on its NEXT reload — a `$mod+Shift+c`, a quickshell restart, an xrdp
# reconnect — while :0's daemon still holds its grabs. That is the contested
# state the ordering argument above rules out, reintroduced by a config reload
# nobody connected to hotkeyd. So panic is machine-wide IN EFFECT, not just in
# the note:
#
#   * it stops the daemon on EVERY display that has one, not just the caller's,
#     so after panic no hotkeyd grabs exist anywhere and any later reload on any
#     display is safe;
#   * `hotkeyd.sh start` REFUSES while the link is present, so an autostart, an
#     `exec_always` on reload, or a reconnect cannot quietly rearm one display
#     into the contested state behind the fallback's back. Panic is sticky until
#     resume, which is the property that survives a reboot — the link is on
#     disk, the daemon's absence is not.
#
# WHY SH AND NOT NUSHELL — same as hotkeyd.sh: [[adr0015]] puts a thin shell
# launcher in front of the Python X clients, and this is the one script that has
# to run when the session is already broken. Adding a nushell hop to the
# recovery path is adding a dependency to the outage.
set -u

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LAUNCHER="$HERE/hotkeyd.sh"

# Both overridable for the suite, which drives a throwaway HOME and a fallback
# that actually binds something — the shipped one is empty by design (see its
# header), so a test using it could not observe ownership moving at all.
FALLBACK_SRC="${HOTKEYD_FALLBACK_SRC:-$HERE/../i3/config.d/zz-fallback-binds.conf}"
I3_CONFIG_D="${HOTKEYD_I3_CONFIG_D:-$HOME/.i3/config.d}"
LINK="$I3_CONFIG_D/zz-fallback-binds.conf"

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# Which displays panic stopped, so resume restarts exactly those. Machine-wide
# state for a machine-wide action; it lives in the runtime dir and is therefore
# allowed to vanish across a reboot — the LINK is the durable half, and resume
# falls back to the caller's display when the list is gone.
STATE="$RUNTIME/hotkeyd-panic.displays"

VERB="${1:-status}"
DPY="${2:-${DISPLAY:-}}"
DPY_BASE="${DPY%.*}"

die() { printf 'hotkeyd-panic.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

linked() { [ -L "$LINK" ] || [ -e "$LINK" ]; }

# The caller's display plus every display currently serving a hotkeyd daemon.
# Identified from the daemon's own --display argument for the same reason
# hotkeyd.sh does it: a pidfile can go stale and then lie about a daemon that is
# not there, which is precisely the state this script exists for.
target_displays() {
    {
        [ -n "$DPY_BASE" ] && printf '%s\n' "$DPY_BASE"
        pgrep -af 'hotkeyd\.py .*--display' 2>/dev/null \
            | sed -n 's/.*--display \(:[0-9][0-9]*\).*/\1/p'
    } | sort -u
}

# Best-effort per display: a display with no X server or no i3 is not an error
# here. Panic must not abort halfway because one xrdp session is disconnected —
# a half-applied recovery is worse than either end state.
reload_i3() {
    for d in $1; do
        # `env -u I3SOCK`, the dotfiles-hwds.6 lesson again: i3 exports its own
        # socket path into every process it execs, and THIS SCRIPT IS EXECED BY
        # AN i3 BIND. Inheriting that value would point every iteration of this
        # loop at the caller's i3 — panic on :10 would reload :10 twice and
        # never touch :0, silently leaving the display it was supposed to rescue
        # holding stale binds. Unset, i3-msg resolves the socket from the root
        # window of the DISPLAY it was given, which is per-display by
        # construction.
        env -u I3SOCK DISPLAY="$d" i3-msg reload >/dev/null 2>&1 \
            && printf 'hotkeyd-panic: reloaded i3 on %s\n' "$d"
    done
}

case "$VERB" in
    panic)
        [ -f "$FALLBACK_SRC" ] || die "no fallback table at $FALLBACK_SRC" 2

        targets="$(target_displays)"
        [ -n "$targets" ] || die "no display: pass one, or set DISPLAY" 2

        # 1. grabs die with the process, before anything is asked to re-parse
        for d in $targets; do
            "$LAUNCHER" stop "$d" || die "could not stop the daemon on $d" 1
        done

        # 2. link the fallback. mkdir -p and ln -sfn are both idempotent, so a
        # second panic is a no-op rather than a duplicate or an error — and a
        # second panic is exactly what a person does when the first appeared not
        # to work.
        if ! mkdir -p "$I3_CONFIG_D" 2>/dev/null; then
            die "cannot create $I3_CONFIG_D" 2
        fi
        [ -w "$I3_CONFIG_D" ] || die "$I3_CONFIG_D is not writable" 2
        ln -sfn "$FALLBACK_SRC" "$LINK" || die "could not link $LINK" 1
        printf '%s\n' "$targets" > "$STATE" 2>/dev/null || true

        # 3. i3 parses the fallback and takes passive grabs on what it names
        reload_i3 "$targets"
        printf 'hotkeyd: PANICKED — i3 owns the keyboard (%s).\n' \
            "$(printf '%s' "$targets" | tr '\n' ' ')"
        printf 'hotkeyd: resume with: %s resume\n' "$0"
        ;;

    resume)
        if [ -s "$STATE" ]; then
            targets="$(cat "$STATE")"
        else
            targets="$DPY_BASE"
        fi
        [ -n "$targets" ] || die "no display: pass one, or set DISPLAY" 2

        # Unlink FIRST, then reload: i3 must have dropped the fallback's grabs
        # before a daemon is allowed to ask for them, or the start races i3 for
        # chords it still owns and loses them to BadAccess.
        rm -f "$LINK"
        rm -f "$STATE"
        reload_i3 "$targets"
        rc=0
        for d in $targets; do
            "$LAUNCHER" start "$d"
            # 3 is the launcher's "already running", which is the state resume
            # is trying to reach — a resume that was never preceded by a panic,
            # or one run twice, must not report failure for having found the
            # daemon already up. Anything else is a real failure to come back.
            case $? in 0|3) ;; *) rc=1 ;; esac
        done
        [ "$rc" -eq 0 ] || die "the daemon did not come back on every display" 1
        printf 'hotkeyd: resumed on %s\n' "$(printf '%s' "$targets" | tr '\n' ' ')"
        ;;

    status)
        if linked; then
            printf 'hotkeyd: PANICKED — fallback linked at %s\n' "$LINK"
            exit 0
        fi
        printf 'hotkeyd: not panicked (no fallback link at %s)\n' "$LINK"
        exit 1
        ;;

    *)
        die "unknown verb: $VERB (panic|resume|status)" 64
        ;;
esac
