#!/bin/sh
# test-i3exit.sh - which command each i3exit verb runs, per session.
#
# Every command i3exit can reach is a stub that only records its argv, and the
# system i3exit is replaced through I3EXIT_SYS, so this never suspends, reboots
# or logs anything out. Run: sh hotkeyd/test-i3exit.sh

HERE=$(cd "$(dirname "$0")" && pwd)
I3EXIT="$HERE/i3exit"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"
CALLS="$TMP/calls"
mkdir -p "$STUBS"

for cmd in systemctl loginctl dm-tool notify-send; do
    printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$cmd" "$CALLS" >"$STUBS/$cmd"
    chmod +x "$STUBS/$cmd"
done
printf '#!/bin/sh\necho "sys $*" >>"%s"\n' "$CALLS" >"$TMP/sys-i3exit"
chmod +x "$TMP/sys-i3exit"

# Refuse to run at all unless the stubs win PATH lookup.
[ "$(PATH="$STUBS:$PATH" command -v systemctl)" = "$STUBS/systemctl" ] || {
    echo "stubs do not shadow systemctl - not running" >&2
    exit 2
}

FAILS=0
RUNS=0

# check NAME WANT_RC WANT_CALLS ENV... -- VERB
check() {
    _name=$1 _want_rc=$2 _want=$3
    shift 3
    _env=""
    while [ "$1" != "--" ]; do
        _env="$_env $1"
        shift
    done
    shift
    : >"$CALLS"
    # shellcheck disable=SC2086
    env -i PATH="$STUBS:/usr/bin:/bin" I3EXIT_SYS="$TMP/sys-i3exit" $_env \
        sh "$I3EXIT" "$@" >/dev/null 2>&1
    _rc=$?
    _got=$(cat "$CALLS")
    RUNS=$((RUNS + 1))
    if [ "$_rc" != "$_want_rc" ] || [ "$_got" != "$_want" ]; then
        FAILS=$((FAILS + 1))
        echo "FAIL $_name: rc=$_rc (want $_want_rc) calls=[$_got] (want [$_want])"
    else
        echo "ok   $_name"
    fi
}

KWIN="WAYLAND_DISPLAY=kwi3-kwin XDG_SESSION_ID=5 KWI3SOCK=/nonexistent/kwi3.sock"

# --- kwi3-kwin: no system i3exit involved ---
check "kwin logout ends this login session" 0 "loginctl terminate-session 5" $KWIN -- logout
check "kwin suspend" 0 "systemctl suspend" $KWIN -- suspend
check "kwin hibernate" 0 "systemctl hibernate" $KWIN -- hibernate
check "kwin reboot" 0 "systemctl reboot" $KWIN -- reboot
check "kwin shutdown powers off" 0 "systemctl poweroff" $KWIN -- shutdown
check "kwin switch_user goes to the greeter" 0 "dm-tool switch-to-greeter" $KWIN -- switch_user

# Nothing here can lock, so it must say so rather than look like it worked.
check "kwin lock reports failure, locks nothing" 1 \
    "notify-send -u critical i3exit No screen locker in this session - the screen is NOT locked" \
    $KWIN -- lock
check "kwin unknown verb runs nothing" 1 "" $KWIN -- frobnicate
check "kwin no verb runs nothing" 1 "" $KWIN --
check "kwin logout without a session id runs nothing" 1 "" \
    WAYLAND_DISPLAY=kwi3-kwin KWI3SOCK=/nonexistent/kwi3.sock -- logout

# --- every other session: exactly what it did before ---
PHONE="WAYLAND_DISPLAY=kwi3-phone XDG_SESSION_ID=5"
for verb in lock suspend hibernate reboot shutdown switch_user logout; do
    check "phone $verb stays with the system i3exit" 0 "sys $verb" $PHONE -- "$verb"
    check "X11 $verb stays with the system i3exit" 0 "sys $verb" DISPLAY=:0 -- "$verb"
done
check "kwi3 X11 logout with no i3kwin-x11 does not log out" 1 "" \
    DISPLAY=:0 KWI3SOCK=/nonexistent/kwi3.sock -- logout
check "phone kwi3 logout with no i3kwin-x11 does not log out" 1 "" \
    WAYLAND_DISPLAY=kwi3-phone KWI3SOCK=/nonexistent/kwi3.sock XDG_SESSION_ID=5 -- logout

echo "$((RUNS - FAILS))/$RUNS passed"
[ "$FAILS" = 0 ]
