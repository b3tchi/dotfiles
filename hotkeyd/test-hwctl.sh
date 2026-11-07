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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
