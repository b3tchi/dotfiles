#!/bin/sh
# hotkeyd-panic.sh — give the keyboard back to i3 (sp020 Task 10, ft011).
#
# usage: hotkeyd-panic.sh recover|panic|resume|status [display]
#
# `recover` IS THE ONE YOU PRESS ($mod+Shift+r, part of the i3 reload -
# dotfiles-3m12). "Something is wrong, get me back", escalating only as far as
# it has to:
#
#   recover: release every HELD modifier key and re-apply the layout (clears
#            locks) -> resume if panicked, else hotkeyd.sh restart
#         -> hotkeyd.sh status (the --health verdict) until it serves
#         -> still not serving, on an i3 display: panic, so i3 has the keyboard
#
# The first step is not decoration. An RDP reconnect's KbdSync once left
# ISO_Level5_Shift (keycode 8, on Mod3) held in xrdp's server; Mod3 then rode on
# every key and NO passive grab matched - the daemon's, i3's and the old panic
# chord's alike. Neither a restart nor panic can fix that; a release can.
#
# THE ESCAPE HATCH, REPLACING `hotkeyd.sh restart`. A restart helps when the
# daemon is DEAD and not at all when it is alive and WRONG — misgrabbing, stuck
# in a layer, or serving a table whose chords collide with i3's. Recovery has to
# mean "give the keyboard back to i3", so that is what this does:
#
#   panic:   hotkeyd.sh stop (every display)
#         -> link i3/config.d/zz-fallback-binds.conf into ~/.i3/config.d/
#         -> i3-msg reload
#   resume:  classify each recorded display (classify_display(), kwi3-55l.15)
#         -> unlink -> i3-msg reload -> hotkeyd.sh start, each display in its
#            OWN environment; X gone: skipped and forgotten; WM unanswering:
#            skipped and remembered
#         -> an i3 display did not come back: stop the i3 displays' daemons,
#            relink, reload - never leave an i3 display with neither
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
#     (On every display whose WM is i3, that is: a kwi3 display reads no
#     i3 config, so the link cannot rescue it and `start` does not refuse
#     there — kwi3-8wb.1, latch_applies() in hotkeyd.sh.)
#   * `resume` RELOADS EVERY LOCAL DISPLAY, not merely the ones panic recorded.
#     The link it removes was machine-wide, and removing a file does not retract
#     grabs i3 already holds; a display that reloaded into the fallback during
#     the panic window would otherwise keep those chords with the `start` latch
#     now gone. Only the recorded displays get a daemon back — the reload set is
#     a superset of the restart set, deliberately.
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

# Where local X servers announce themselves. Overridable for the same reason
# FALLBACK_SRC and I3_CONFIG_D are: the enumeration below is machine-wide by
# design, and a suite reading the real path would reload the CALLER'S own live
# sessions. Only display NUMBERS are read from here — i3-msg still resolves its
# socket the real way, from the root window of the DISPLAY it is handed.
X11_UNIX="${HOTKEYD_X11_UNIX:-/tmp/.X11-unix}"

# The kernel socket table, where a display whose server bound only an ABSTRACT
# socket is the ONLY place it can be seen (dotfiles-4ai2). Overridable for the
# same reason X11_UNIX is: a suite must be able to name its own displays
# without the enumeration reaching the caller's live sessions. Both halves are
# keyed to X11_UNIX, so overriding that alone already fences this one.
UNIX_PROC="${HOTKEYD_UNIX_PROC:-/proc/net/unix}"

# THE TEST-ONLY PROCESS FENCE (dotfiles-hwds.23). Unset — which is every
# production path, and the guard in test-panic.sh asserts no shipped file sets
# it — `scoped` is `cat` and this script behaves exactly as it did.
#
# Set, it is an allow-list of displays this invocation may touch. It exists
# because the three overrides above fence only the FILES: HOME and
# HOTKEYD_I3_CONFIG_D move the link, HOTKEYD_X11_UNIX moves the enumeration
# `resume` reloads — and `target_displays` below reaches past all of them, by
# design, into every hotkeyd daemon on the machine, of either engine. That is
# correct for recovery and
# is NOT narrowed here: panic must stop every daemon or a later reload on
# another display re-enters the contested state (the dotfiles-hwds.12
# requirement-4 decision). It is wrong for a TEST, which then stops the caller's
# live :0/:10 daemons — real since autostart was armed — and a sibling
# worktree's besides (dotfiles-f2be).
#
# A FILTER, NOT A TARGET LIST. The enumeration still runs in full and still has
# to DISCOVER each daemon by pgrep; the scope only decides which discoveries are
# allowed through. So the suite's machine-wide cases stay real findings rather
# than restatements of a list they handed in — a `HOTKEYD_TARGET_DISPLAYS` that
# replaced the enumeration would make "panic stopped the daemon on the display
# it was not called with" tautological.
SCOPE="${HOTKEYD_PGREP_SCOPE:-}"

# Filter a newline-separated display list on stdin. Identity when SCOPE is
# unset, so production keeps a straight pipe through `cat`.
scoped() {
    if [ -z "$SCOPE" ]; then cat; return 0; fi
    while read -r d; do
        for s in $SCOPE; do
            [ "$s" = "$d" ] && { printf '%s\n' "$d"; break; }
        done
    done
}

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

SELF="$HERE/$(basename -- "$0")"

linked() { [ -L "$LINK" ] || [ -e "$LINK" ]; }

# The caller's display plus every display currently serving a hotkeyd daemon.
# Identified from the daemon's own --display argument for the same reason
# hotkeyd.sh does it: a pidfile can go stale and then lie about a daemon that is
# not there, which is precisely the state this script exists for.
#
# DUAL ARGV SHAPE (dotfiles-pwaj), THE SAME CORE hotkeyd.sh's daemon_pid() USES.
# The optional `(\.py)?` group matches EITHER python's `hotkeyd.py --display :N`
# or the Go rewrite's bare `hotkeyd --display :N` (sp021), so the blast radius
# panic computes does not depend on which engine hotkeyd.sh's per-display table
# happens to name. Hardcoding the python shape here — which is what this line
# used to do — made panic BLIND to a go daemon from the moment a display was cut
# over: the stop loop below would skip that display, the fallback would be linked
# and i3 reloaded over a daemon still holding its grabs, and the result is the
# CONTESTED state (two clients, one chord) this entire script exists to prevent,
# on the one display that had just been cut over. It is a live hazard the instant
# engine_for() names `go` for any display, not before.
#
# MIRRORED, NOT FACTORED INTO A SHARED FILE, and deliberately. This is the one
# script that has to run when the session is ALREADY BROKEN, so it takes no
# dependency a sourced sibling would add to the recovery path — the same
# reasoning the header gives for not putting a nushell hop in front of it. It is
# also how `linked()` is handled across these two files (dotfiles-hwds.21):
# factored WITHIN each file, mirrored ACROSS them. The drift that invites is
# caught by a static guard in test-panic.sh which reads the argv core out of both
# scripts and fails if they stop agreeing.
#
# Extraction is unchanged and needs no boundary anchor: no display appears in the
# pattern, and `[0-9][0-9]*` is greedy, so `--display :10` yields `:10` and can
# never be truncated to a colliding `:1`.
target_displays() {
    {
        [ -n "$DPY_BASE" ] && printf '%s\n' "$DPY_BASE"
        pgrep -af 'hotkeyd(\.py)? .*--display' 2>/dev/null \
            | sed -n 's/.*--display \(:[0-9][0-9]*\).*/\1/p'
    } | sort -u | scoped
}

# EVERY local X display, whether or not it ever ran a daemon — the blast radius
# of the ONE shared `~/.i3/config.d/`, which is what the link and the unlink both
# actually reach (dotfiles-hwds.20). `target_displays` is the set panic must STOP
# daemons on; this is the set a config change must be RELOADED on, and they are
# not the same set. Best-effort by construction: a display with no i3, or one
# belonging to another user, just fails its `i3-msg` and is skipped.
# BOTH SOCKET NAMESPACES, OR THE LIVE SESSION IS MISSED (dotfiles-4ai2). An X
# server's unix socket is a FILE at $X11_UNIX/X<n>, an ABSTRACT name
# @$X11_UNIX/X<n> that exists only in /proc/net/unix, or both — and which one
# it gets is not the server's choice: on a WSLg host $X11_UNIX is a read-only
# tmpfs bind-mounted from /mnt/wslg holding WSLg's own X0 and nothing else, so
# xrdp's Xorg on :10 — the session with the human in front of it — can create
# no file and binds only the abstract socket. Enumerating the directory alone
# reloaded WSLg's unattended :0 and left :10 holding the very grabs `resume`
# exists to retract: the silent-miss direction dotfiles-hwds.12 forbids.
#
# The abstract half is matched LITERALLY as "@$X11_UNIX/X<digits>" (index(),
# not a regex — ".X11-unix" carries metacharacters), so a socket under any
# other directory is not a display here, and a suite that redirects X11_UNIX
# still excludes the caller's real sessions from BOTH halves. An unreadable
# /proc/net/unix degrades to the file listing: fewer displays reloaded is the
# same situation as a session that is simply not up.
abstract_displays() {
    [ -r "$UNIX_PROC" ] || return 0
    awk -v pfx="@$X11_UNIX/X" '
        {
            for (i = NF; i >= 1; i--) {
                if (index($i, pfx) == 1) {
                    n = substr($i, length(pfx) + 1)
                    if (n ~ /^[0-9]+$/) print ":" n
                    break
                }
            }
        }
    ' "$UNIX_PROC" 2>/dev/null
}

all_displays() {
    {
        for s in "$X11_UNIX"/X*; do
            [ -e "$s" ] || continue      # empty glob leaves the pattern itself
            n="${s##*/X}"
            case "$n" in ''|*[!0-9]*) continue ;; esac
            printf ':%s\n' "$n"
        done
        abstract_displays
    } | sort -u | scoped                 # no-op in production; see SCOPE above
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
        # `timeout 5` (kwi3-3m9): an i3-msg aimed at a display whose server is
        # gone does not fail, it hangs on the connect - minutes, not seconds -
        # and this loop runs in the middle of an outage.
        env -u I3SOCK DISPLAY="$d" timeout 5 i3-msg reload >/dev/null 2>&1 \
            && printf 'hotkeyd-panic: reloaded i3 on %s\n' "$d"
    done
}

# WHICH WM EACH RECORDED DISPLAY RUNS, AND SO WHICH ENVIRONMENT ITS DAEMON
# GETS (kwi3-55l.15). `resume` restarts every display panic recorded, and it
# used to do so in the CALLER's environment. The caller's $KWI3SOCK names the
# caller's kwi3 and nobody else's: reached from kwi3's panic chord on :40
# (recover -> resume), it was handed to `start :0` and `start :10` too.
# Before kwi3-vfg those daemons then dispatched every chord typed on :0/:10 to
# :40's kwi3; since kwi3-vfg `start` refuses them (78) - AFTER resume had
# already unlinked the fallback, so both i3 displays ended with neither the
# fallback's binds nor a daemon.
#
# So each display is CLASSIFIED, before anything is torn down, and each class
# gets its own treatment in `resume` below. classify_display() prints one of:
#
#   gone          its X server does not answer at all (x_state) - the session
#                 ended since the panic (logout, xrdp session closed, a kwi3
#                 session that died with its X). Nothing to give a keyboard
#                 back to: skipped, named, DROPPED from the panic record, and
#                 never a reason to re-panic anyone. Checked FIRST, so no
#                 other probe waits on a dead server.
#   i3            its own i3 answers (DISPLAY pinned, no I3SOCK, as
#                 latch_applies() asks). Started with $KWI3SOCK UNSET, the i3
#                 IPC path. The ONLY class whose failed start may relink the
#                 fallback: the link is what rescues an i3 display, and nothing
#                 else.
#   kwi3 <sock>   no i3, and the socket kwi3-session-env.sh's
#                 kwi3_rpcsock_path() would compute for it,
#                 "kwi3-<n>.rpc.sock", ANSWERS JSON-RPC as kwi3 - looked for
#                 beside the caller's $KWI3SOCK first (when the caller IS this
#                 display, that is the caller's own socket: the single-display
#                 resume; and a kwi3 started with a non-default directory puts
#                 every session's socket there), then in
#                 ${XDG_RUNTIME_DIR:-/tmp}, the convention's own default.
#                 Started with $KWI3SOCK = <sock>.
#   unknown       X answers (or refuses us authorization), but no i3 answers
#                 and a kwi3 socket FILE for it exists and does not answer -
#                 a kwi3 session whose WM died - or the X server would not
#                 let us in. A daemon started with $KWI3SOCK unset there sends
#                 its chords nowhere, and every later `start` then reports
#                 "already running". So it is NOT started: skipped loudly,
#                 kept in the record so a later `resume` retries it, resume
#                 exits 1 - and the i3 displays are NOT re-panicked for it.
#   none          X answers, no i3, no kwi3 socket for it at all - a bare X
#                 display (test-panic.sh's second display, or a session whose
#                 WM this script has no probe for). Started exactly as before
#                 kwi3-55l.15, $KWI3SOCK unset; its failure is reported (rc 1)
#                 but, not being i3, relinks nothing.
#
# Asked, never inherited: a set-but-foreign $KWI3SOCK is exactly the misroute
# above.
#
# MIRRORED, NOT SOURCED - the same rule as target_displays(): this script runs
# when the session is already broken, and kwi3-session-env.sh lives in the
# kwi3 checkout (and exports as a side effect). rpc_answers()'s python body is
# hotkeyd.sh's kwi3_answers() body; test-panic.sh guards the two against
# drifting apart.
CALLER_KWI3SOCK="${KWI3SOCK:-}"

rpc_answers() { # <socket path>
    [ -S "$1" ] || return 1
    timeout 2 python3 - "$1" >/dev/null 2>&1 <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1.5)
s.connect(sys.argv[1])
s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"workspace.list"}\n')
buf = b""
while b"\n" not in buf and len(buf) < 1 << 20:
    chunk = s.recv(65536)
    if not chunk:
        sys.exit(1)
    buf += chunk
r = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
ok = (isinstance(r, dict) and r.get("jsonrpc") == "2.0" and r.get("id") == 1
      and r.get("error") is None and isinstance(r.get("result"), list))
sys.exit(0 if ok else 1)
PY
}

# Is <display>'s X server there? Prints alive | gone | noauth.
#
# BOUNDED, because an X connection to a server that is gone does not fail -
# it HANGS: xlib falls back from the unix socket to TCP and waits on a connect
# nothing answers (measured: `xset -display :<unused> q` and python-xlib both
# sat until killed). 2s is the same cap every other probe here uses.
#
# An AUTHORIZATION refusal is a server that IS there and would not let us in
# (another user's session, a missing XAUTHORITY) - it prints "Authorization
# required" and exits at once. That must not read as gone: gone drops the
# display from the panic record, and a live session dropped from it never gets
# its daemon back. No xset on the box: "alive", i.e. no display is ever
# dropped on the strength of a missing tool.
x_state() { # <display>
    command -v xset >/dev/null 2>&1 || { echo alive; return 0; }
    _o="$(timeout 2 xset -display "$1" q 2>&1 >/dev/null)" && {
        echo alive; return 0; }
    case "$_o" in
        *[Aa]uthoriz*) echo noauth ;;
        *)             echo gone ;;
    esac
}

classify_display() { # <display>
    _x="$(x_state "$1")"
    [ "$_x" = gone ] && { echo gone; return 0; }
    [ "$_x" = noauth ] && { echo unknown; return 0; }
    _n="${1#:}"; _n="${_n%%.*}"
    _name="kwi3-$_n.rpc.sock"
    env -u I3SOCK DISPLAY="$1" timeout 2 i3-msg -t get_version \
        >/dev/null 2>&1 && { echo i3; return 0; }
    _dead=0
    for _c in ${CALLER_KWI3SOCK:+"$(dirname -- "$CALLER_KWI3SOCK")/$_name"} \
              "${XDG_RUNTIME_DIR:-/tmp}/$_name"; do
        rpc_answers "$_c" && { printf 'kwi3 %s\n' "$_c"; return 0; }
        [ -S "$_c" ] && _dead=1
    done
    [ "$_dead" -eq 1 ] && echo unknown || echo none
}

# Starts <display>'s daemon with $KWI3SOCK = <sock>, or unset when <sock> is
# empty. The caller's $HOTKEYD_I3SOCK (main.go's i3 socket override) is
# dropped for every display but the caller's own, for the same reason: it
# names ONE display's WM.
start_for() { # <display> <kwi3sock or empty>
    if [ "$1" = "$DPY_BASE" ]; then _drop=""; else _drop="-u HOTKEYD_I3SOCK"; fi
    if [ -n "$2" ]; then
        env $_drop KWI3SOCK="$2" "$LAUNCHER" start "$1"
    else
        env $_drop -u KWI3SOCK "$LAUNCHER" start "$1"
    fi
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
        # Filtered as well, not merely inherited-clean. A state file written by
        # an earlier, unscoped run — or a stale one left by another checkout in
        # a shared runtime dir — would otherwise walk straight past the fence
        # into `hotkeyd.sh start` on someone else's display. No-op in
        # production, where SCOPE is unset.
        targets="$(printf '%s\n' "$targets" | scoped)"
        [ -n "$targets" ] || die "no display: pass one, or set DISPLAY" 2

        # Each display's class, decided BEFORE the unlink - see
        # classify_display(). One "<display> <class> [<kwi3sock>]" line each.
        plan=""; gone=""
        for d in $targets; do
            c="$(classify_display "$d")"
            plan="$plan$d $c
"
            case "$c" in gone) gone="$gone $d" ;; esac
        done
        # The displays still worth reloading, remembering and re-panicking: a
        # gone one is none of those (and an `i3-msg` at it is a wait on a
        # server that will not answer - kwi3-3m9).
        live="$(printf '%s\n' "$plan" | awk 'NF && $2 != "gone" {print $1}')"

        # Unlink FIRST, then reload: i3 must have dropped the fallback's grabs
        # before a daemon is allowed to ask for them. NOT because the daemon
        # would be refused if it asked first — dotfiles-f224 measured core and
        # XI2 passive grabs into separate conflict domains, so the daemon's XI2
        # request is granted regardless and simply wins delivery. Being granted
        # is the problem: i3 would still hold the same chord, with no error
        # raised on either side, which is the double ownership Task 10 exists to
        # eliminate. Ordering is what keeps ownership single, because nothing in
        # the protocol does it any more.
        rm -f "$LINK"
        rm -f "$STATE"

        # THE UNLINK IS MACHINE-WIDE, SO THE RELOAD MUST BE (dotfiles-hwds.20).
        # `$targets` is what panic STOPPED — the caller plus displays that had a
        # daemon. It is not "every display sharing the config.d", and the gap is
        # load-bearing: a display with no daemon is never recorded, yet it reads
        # the same directory and can have reloaded into the fallback at any point
        # in the panic window, for a reason nobody connected to hotkeyd (a
        # `$mod+Shift+c`, a quickshell restart, an xrdp reconnect). Removing the
        # file does not retract grabs i3 has ALREADY taken — only a reload does —
        # so reloading just `$targets` would leave that display holding the
        # fallback's chords with the `start` latch now gone, and the next daemon
        # there would contend with them.
        #
        # Reloading a display that never saw the fallback is a no-op; NOT
        # reloading one that did is the contested state. So the reload set is the
        # union, and it stays a superset of the RESTART set below — resume must
        # not start a daemon on a display that never had one.
        reload_i3 "$(printf '%s\n%s\n' "$live" "$(all_displays)" | sort -u)"
        rc=0; failed=""; skipped=""; relink=0
        while read -r d c s; do
            [ -n "$d" ] || continue
            case "$c" in
                gone)
                    printf 'hotkeyd-panic: %s: its X server is gone -- skipped, '\
'and dropped from the panic record\n' "$d" >&2
                    continue ;;
                unknown)
                    printf 'hotkeyd-panic: %s: X is up but neither its i3 nor '\
'its kwi3 answers -- NOT starting a daemon that would send its keys nowhere; '\
'kept in the panic record, resume again once its window manager is back\n' \
                        "$d" >&2
                    rc=1; skipped="$skipped $d"
                    continue ;;
            esac
            start_for "$d" "$s"
            # 3 is the launcher's "already running", which is the state resume
            # is trying to reach — a resume that was never preceded by a panic,
            # or one run twice, must not report failure for having found the
            # daemon already up. Anything else is a real failure to come back.
            case $? in
                0|3) ;;
                *)  rc=1; failed="$failed $d"
                    # Only a display POSITIVELY identified as i3 is one the
                    # fallback can rescue - and so the only kind whose failure
                    # may put it back for everyone.
                    [ "$c" = i3 ] && relink=1 ;;
            esac
        done <<PLAN
$plan
PLAN
        if [ "$relink" -eq 1 ]; then
            # NEVER NEITHER (kwi3-55l.15). The unlink had to come first (see
            # above), so an i3 display whose start then failed holds nothing:
            # no daemon, and a fallback its i3 has just reloaded away. The
            # link is ONE machine-wide file, so it cannot be restored for that
            # display alone - and restoring it while any i3 display's daemon
            # is up is the contested state. So the i3 half of the panic is
            # re-applied the way `panic` applies it: stop the daemon on every
            # i3 display, THEN link, record, reload. Every other class keeps
            # its daemon: the link reaches only i3's config (kwi3-8wb.1), so
            # nothing there can contest it. The record is every LIVE target -
            # a gone display is not written back, so it cannot make the next
            # resume fail the same way forever.
            while read -r d c s; do
                [ "$c" = i3 ] || continue
                "$LAUNCHER" stop "$d" >/dev/null 2>&1
            done <<PLAN
$plan
PLAN
            ln -sfn "$FALLBACK_SRC" "$LINK" \
                || die "the daemon did not come back on$failed, and $LINK could not be relinked" 1
            printf '%s\n' "$live" > "$STATE" 2>/dev/null || true
            reload_i3 "$(printf '%s\n%s\n' "$live" "$(all_displays)" | sort -u)"
            die "the daemon did not come back on the i3 display(s)$failed -- \
the i3 fallback is linked again, so i3 keeps the keyboard on every i3 \
display; resume again once that is fixed" 1
        fi
        # An `unknown` display is remembered so a later resume retries it; it
        # is the only thing left to resume, so it is all the record holds.
        [ -z "$skipped" ] \
            || printf '%s\n' $skipped > "$STATE" 2>/dev/null || true
        [ "$rc" -eq 0 ] || die "the daemon did not come back on$failed$skipped" 1
        printf 'hotkeyd: resumed on %s\n' "$(printf '%s' "$live" | tr '\n' ' ')"
        [ -z "$gone" ] || printf 'hotkeyd: skipped (X server gone):%s\n' "$gone"
        ;;

    recover)
        [ -n "$DPY_BASE" ] || die "no display: pass one, or set DISPLAY" 2

        # 1. Unstick. By the server's MODIFIER MAP, never a keysym list: the
        # key that stuck was a keycode nobody would have listed. Every held key
        # in that map gets a press+release through XTEST - a lone release is
        # dropped, the XTEST device never pressed it - which clears it on the
        # master keyboard the grabs are matched against. Best-effort: with no
        # python-xlib this step is skipped out loud, not fatal.
        DISPLAY="$DPY_BASE" python3 - <<'EOF' 2>/dev/null \
            || printf 'hotkeyd: recover: could not check for stuck modifiers on %s\n' "$DPY_BASE"
import sys
from Xlib import X, display as xdisplay
from Xlib.ext import xtest
d = xdisplay.Display()
down = d.query_keymap()
held = sorted({c for grp in d.get_modifier_mapping() for c in grp
               if c and down[c // 8] & (1 << (c % 8))})
for c in held:
    xtest.fake_input(d, X.KeyPress, c)
    xtest.fake_input(d, X.KeyRelease, c)
d.sync()
if held:
    print("hotkeyd: recover: released stuck modifier key(s): %s" % " ".join(map(str, held)))
EOF
        # Locks (the ISO_Level5 LOCK variant of the same fault): recompiling
        # the keymap resets the locked state. Re-apply exactly what is loaded -
        # layout, variant, model and options - so recover never changes it.
        if command -v setxkbmap >/dev/null 2>&1; then
            q="$(DISPLAY="$DPY_BASE" setxkbmap -query 2>/dev/null)"
            field() { printf '%s\n' "$q" | sed -n "s/^$1: *//p"; }
            l="$(field layout)"; v="$(field variant)"; m="$(field model)"; o="$(field options)"
            [ -n "$l" ] && DISPLAY="$DPY_BASE" setxkbmap -layout "$l" \
                ${v:+-variant "$v"} ${m:+-model "$m"} -option "" ${o:+-option "$o"} 2>/dev/null
        fi

        # 2. Resume if panicked - `start` is refused while the link is there -
        # else restart.
        # resume's own verdict is KEPT (kwi3-55l.15): it restarts every display
        # panic recorded, and step 3 below asks only about this one. A resume
        # that left another display without its daemon must not let recover
        # exit 0 on the strength of this display alone.
        resume_rc=0
        if linked; then
            "$SELF" resume "$DPY_BASE" || resume_rc=$?
        else
            "$LAUNCHER" restart "$DPY_BASE"
        fi

        # 3. The verdict is the launcher's own status (heartbeat, grabs,
        # display), not an exit code: a daemon can start and not serve.
        n=0
        while :; do
            "$LAUNCHER" status "$DPY_BASE" >/dev/null 2>&1 && {
                [ "$resume_rc" -eq 0 ] || die "serving again on $DPY_BASE, \
but resume did not bring every recorded display back (see above)" 1
                printf 'hotkeyd: recovered on %s\n' "$DPY_BASE"; exit 0; }
            n=$((n + 1)); [ "$n" -ge 10 ] && break
            sleep 0.5
        done

        # 4. Still not serving. On an i3 display, panic: i3 takes the keyboard
        # from the fallback. A kwi3 display reads no i3 config (kwi3-8wb.1), so
        # there is nothing to fall back TO - say so rather than link uselessly.
        ver="$(env -u I3SOCK DISPLAY="$DPY_BASE" timeout 2 i3-msg -t get_version 2>/dev/null)"
        case "$ver" in
            *'"human_readable"'*kwi3*|'')
                die "hotkeyd is not serving on $DPY_BASE and this display has no i3 to fall back to" 1 ;;
        esac
        "$SELF" panic "$DPY_BASE"
        die "hotkeyd did not come back on $DPY_BASE - PANICKED, i3 has the keyboard" 1
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
        die "unknown verb: $VERB (recover|panic|resume|status)" 64
        ;;
esac
