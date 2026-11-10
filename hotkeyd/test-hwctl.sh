#!/usr/bin/env bash
# test-hwctl.sh - hwctl's auto-suspend stepper and what `hwctl show` reports for
# it. The device tools it calls are stubbed away. Usage: hotkeyd/test-hwctl.sh
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
for c in pactl kscreen-doctor jq rfkill systemctl; do
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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
