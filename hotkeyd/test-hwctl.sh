#!/usr/bin/env bash
# test-hwctl.sh - hwctl's flag-file toggles and what `hwctl show` reports for
# them. The device tools it calls are stubbed away. Usage: hotkeyd/test-hwctl.sh
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
FLAG="$T/cfg/spacewar/no-autosuspend"
field() { sh "$H" show | tr ' ' '\n' | sed -n "s/^$1=//p"; }

check "autosuspend is on by default" "$(field autosuspend)" "on"
[ -e "$FLAG" ] && check "no flag by default" yes no || check "no flag by default" no no
sh "$H" autosuspend +
check "toggle: + turns it off" "$(field autosuspend)" "off"
[ -e "$FLAG" ] && check "off: the flag exists" yes yes || check "off: the flag exists" no yes
sh "$H" autosuspend -
check "toggle: - flips it back on" "$(field autosuspend)" "on"
[ -e "$FLAG" ] && check "on: the flag is gone" yes no || check "on: the flag is gone" no no
sh "$H" autosuspend + 
sh "$H" autosuspend +
check "toggle: + flips too" "$(field autosuspend)" "on"
check "autorotate still reported" "$(field autorotate)" "off"
sh "$H" nosuch + 2>/dev/null
check "unknown control: exit 2" "$?" "2"
sh "$H" autosuspend 2>/dev/null
check "no direction: exit 2" "$?" "2"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
