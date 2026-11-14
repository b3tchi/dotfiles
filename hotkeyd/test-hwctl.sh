#!/usr/bin/env bash
# test-hwctl.sh - hwctl's auto-suspend stepper, brightness steps, rotation on
# both backends (xrandr under X11, kscreen-doctor under Wayland), and what
# `hwctl show` reports for them. The device tools it calls are stubbed away. Usage: hotkeyd/test-hwctl.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
H="$here/hwctl"
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); echo "ok   - $1"
    else
        fail=$((fail + 1)); echo "FAIL - $1: got '$2', wanted '$3'"
    fi
}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
unset WAYLAND_DISPLAY
for c in pactl kscreen-doctor rfkill systemctl xrandr; do
    printf '#!/bin/sh\nexit 1\n' >"$T/bin/$c"
    chmod +x "$T/bin/$c"
done
export PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/cfg"
CONF="$T/cfg/spacewar/autosuspend"
field() { sh "$H" show | tr ' ' '\n' | sed -n "s/^$1=//p"; }
step() { sh "$H" autosuspend "$1"; field autosuspend; }

check "no setting: shows the default" "$(field autosuspend)" "1min"
[ -e "$CONF" ] && check "show writes nothing" yes no || check "show writes nothing" no no
check "+ from the default" "$(step +)" "10min"
check "the setting is stored" "$(cat "$CONF")" "10min"
check "+ steps up" "$(step +)" "1hr"
check "+ steps to off" "$(step +)" "off"
check "+ wraps to the shortest" "$(step +)" "30s"
check "+ from 30s" "$(step +)" "1min"
check "- steps down" "$(step -)" "30s"
check "- wraps to off" "$(step -)" "off"
check "- from off" "$(step -)" "1hr"
check "- again" "$(step -)" "10min"
echo garbage >"$CONF"
check "garbage setting: shows the default" "$(field autosuspend)" "1min"
check "garbage setting: + steps from the default" "$(step +)" "10min"
check "autorotate still reported" "$(field autorotate)" "off"
sh "$H" nosuch + 2>/dev/null
check "unknown control: exit 2" "$?" "2"
sh "$H" autosuspend 2>/dev/null
check "no direction: exit 2" "$?" "2"

# --- brightness: round 10 % steps, whatever the device's scale. This scale is the
# phone's kind: 5 % of it, truncated, is what used to read as a 4 % floor.
BL="$T/backlight/panel"
mkdir -p "$BL"
export HWCTL_BACKLIGHT="$T/backlight"
bl() { echo "$1" >"$BL/max_brightness"; echo "$2" >"$BL/brightness"; }
bstep() { sh "$H" brightness "$1"; field brightness; }

bl 4095 2048
check "show: rounds to the nearest percent" "$(field brightness)" "50%"
check "+ from 50%" "$(bstep +)" "60%"
check "+ again" "$(bstep +)" "70%"
check "- steps down" "$(bstep -)" "60%"
bl 4095 1433
check "between steps: + goes to the next round one" "$(bstep +)" "40%"
bl 4095 1433
check "between steps: - goes to the previous round one" "$(bstep -)" "30%"
bl 4095 820
check "down to the floor" "$(bstep -)" "10%"
check "the floor holds" "$(bstep -)" "10%"
check "stored value is a real 10%" "$(cat "$BL/brightness")" "410"
bl 4095 40
check "below the floor: - comes up to it" "$(bstep -)" "10%"
bl 4095 40
check "below the floor: + comes up to it" "$(bstep +)" "10%"
bl 4095 3890
check "+ up to the top" "$(bstep +)" "100%"
check "the top holds" "$(bstep +)" "100%"
check "stored value is the device's max" "$(cat "$BL/brightness")" "4095"
bl 255 128
check "a small scale: + from 50%" "$(bstep +)" "60%"
check "a small scale: stored" "$(cat "$BL/brightness")" "153"

# --- rotation under X11: xrandr, on the primary output. The stub keeps each
# output's rotation in a file ($XR/<output>, empty = normal) and logs every set.
XR="$T/xrandr"
mkdir -p "$XR"
: >"$XR/eDP-1"
: >"$XR/HDMI-1"
PRIMARY=" primary"
cat >"$T/bin/xrandr" <<'STUB'
#!/bin/sh
d=$HWCTL_TEST_XR
if [ "$1" = --query ]; then
    [ -e "$d/none" ] && { echo "Screen 0: minimum 8 x 8"; exit 0; }
    p=$(cat "$d/primary" 2>/dev/null)
    echo "Screen 0: minimum 8 x 8, current 3840 x 1080, maximum 32767 x 32767"
    echo "eDP-1 connected 1920x1080+1920+0 $(cat "$d/eDP-1") (normal left inverted right x axis y axis) 344mm x 194mm"
    echo "HDMI-1 connected$p 1920x1080+0+0 $(cat "$d/HDMI-1") (normal left inverted right x axis y axis) 527mm x 296mm"
    echo "DP-1 disconnected (normal left inverted right x axis y axis)"
    exit 0
fi
[ "$1" = --output ] && [ "$3" = --rotate ] || exit 1
echo "$2 $4" >>"$d/log"
if [ "$4" = normal ]; then : >"$d/$2"; else echo "$4" >"$d/$2"; fi
STUB
chmod +x "$T/bin/xrandr"
export HWCTL_TEST_XR="$XR"
echo "$PRIMARY" >"$XR/primary"
rstep() { sh "$H" rotation "$1"; field rotation; }

check "x11 show: unrotated reads normal" "$(field rotation)" "normal"
check "x11 + rotates clockwise" "$(rstep +)" "right"
check "x11 the primary output is the one rotated" "$(tail -n 1 "$XR/log")" "HDMI-1 right"
check "x11 the other output is untouched" "$(cat "$XR/eDP-1")" ""
check "x11 + again" "$(rstep +)" "inverted"
check "x11 + again" "$(rstep +)" "left"
check "x11 + wraps to normal" "$(rstep +)" "normal"
check "x11 - rotates counter-clockwise" "$(rstep -)" "left"
check "x11 - again" "$(rstep -)" "inverted"
check "x11 - again" "$(rstep -)" "right"
check "x11 - back to normal" "$(rstep -)" "normal"
: >"$XR/primary"
sh "$H" rotation +
check "x11 no primary: the first active output" "$(tail -n 1 "$XR/log")" "eDP-1 right"
: >"$XR/none"
check "x11 no active output: show reads -" "$(field rotation)" "-"
sh "$H" rotation + 2>/dev/null
check "x11 no active output: rotation fails" "$?" "1"

# --- rotation under Wayland: kscreen-doctor (1 none, 2 left, 4 inverted,
# 8 right) on the first ENABLED output, and xrandr is never asked.
KS="$T/kscreen"
mkdir -p "$KS"
echo 1 >"$KS/rot"
cat >"$T/bin/kscreen-doctor" <<'STUB'
#!/bin/sh
d=$HWCTL_TEST_KS
if [ "$1" = -j ]; then
    echo '{"outputs":[{"name":"DSI-1","enabled":false,"rotation":1},{"name":"DSI-2","enabled":true,"rotation":'"$(cat "$d/rot")"'}]}'
    exit 0
fi
echo "$1" >>"$d/log"
case "$1" in
*.none) echo 1 ;; *.left) echo 2 ;; *.inverted) echo 4 ;; *.right) echo 8 ;;
esac >"$d/rot"
STUB
chmod +x "$T/bin/kscreen-doctor"
printf '#!/bin/sh\necho called >>"$HWCTL_TEST_KS/xrandr-called"\nexit 1\n' >"$T/bin/xrandr"
export HWCTL_TEST_KS="$KS"
if command -v jq >/dev/null 2>&1; then
    export WAYLAND_DISPLAY=wayland-test
    check "wayland show: none reads normal" "$(field rotation)" "normal"
    check "wayland + rotates clockwise" "$(rstep +)" "right"
    check "wayland: the enabled output, kscreen's verb" "$(tail -n 1 "$KS/log")" "output.DSI-2.rotation.right"
    check "wayland - back" "$(rstep -)" "normal"
    check "wayland: normal is kscreen's none" "$(tail -n 1 "$KS/log")" "output.DSI-2.rotation.none"
    check "wayland: xrandr never asked" "$([ -e "$KS/xrandr-called" ] && echo yes || echo no)" "no"
    unset WAYLAND_DISPLAY
else
    echo "skip - wayland rotation: no jq on PATH"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
