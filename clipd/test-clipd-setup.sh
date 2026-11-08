#!/usr/bin/env bash
# test-clipd-setup.sh — end-to-end test of nushell/actions/clipd.nu (sp039
# Task 9) against a throwaway Syncthing.
#
# Never touches the user's own instances: XDG_STATE_HOME, XDG_RUNTIME_DIR and
# CLIPD_CONFIG_DIR all point into $TMP, so clipd.nu generates its dedicated
# Syncthing home there, and that instance gets free ports picked at start. The
# agent scenario runs on a throwaway Xvfb (TEST_DISPLAY, default :183; live
# :0/:10/:40 refused). Every process is recorded at spawn and killed by pid.
#
# usage: clipd/test-clipd-setup.sh
# env:   TEST_DISPLAY=:183  KEEP_TMP=1 (debug: keep $TMP)
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLIPD_NU="$HERE/../nushell/actions/clipd.nu"
DPY="${TEST_DISPLAY:-:183}"
TMP="${TMPDIR:-/tmp}/clipd-setup-test.$$"

case "$DPY" in
  :40|:10|:0) echo "FATAL: refusing to test on live display $DPY" >&2; exit 1 ;;
esac

PASS=0
FAIL=0
PIDS=()
ST_PID=""

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
scenario() { printf '\n[%s]\n' "$1"; }

spawn() { "$@" & SPAWNED=$!; PIDS+=("$SPAWNED"); }

cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null; done
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

for b in nu syncthing curl jq go python3 age Xvfb xclip clipnotify; do
  command -v "$b" >/dev/null 2>&1 || { echo "FATAL: $b not found" >&2; exit 1; }
done
[ -r "$CLIPD_NU" ] || { echo "FATAL: $CLIPD_NU missing" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/run" "$TMP/cfg" "$TMP/home"
chmod 700 "$TMP/run"
(cd "$HERE" && go build -o "$TMP/bin/clipd" ./cmd/clipd) || { echo "FATAL: build failed" >&2; exit 1; }

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
GUI_PORT="$(free_port)"
SYNC_PORT="$(free_port)"
HOMEDIR="$TMP/state/clipd/syncthing"
FOLDER="$TMP/run/clipd/folder"
LISTEN="tcp://127.0.0.1:$SYNC_PORT"

# Everything clipd.nu and clipd see. HOME is the throwaway one, so even a
# bug that ignored the XDG paths could not reach the user's real config.
E=(env HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/run"
   XDG_CONFIG_HOME="$TMP/home/.config" CLIPD_CONFIG_DIR="$TMP/cfg" CLIPD_DEVICE=testhost
   CLIPD_GUI_ADDRESS="127.0.0.1:$GUI_PORT" CLIPD_LISTEN="$LISTEN" CLIPD_SYNCTHING_UNIT=
   STNODEFAULTFOLDER=1)
cnu() { "${E[@]}" nu "$CLIPD_NU" "$@"; }

apikey() { sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$HOMEDIR/config.xml"; }
rest() { local p="$1"; shift; curl -s -H "X-API-Key: $(apikey)" "$@" "http://127.0.0.1:$GUI_PORT$p"; }
config_json() { rest /rest/config | jq -S 'del(.version)'; }

start_syncthing() {
  spawn "${E[@]}" syncthing serve --home "$HOMEDIR" --no-browser --no-restart >"$TMP/st.log" 2>&1
  ST_PID=$SPAWNED
}
stop_syncthing() { kill "$ST_PID" 2>/dev/null; wait "$ST_PID" 2>/dev/null; ST_PID=""; }

# --------------------------------------------------------------- scenarios --

scenario "setup with Syncthing down"
t0=$(date +%s%N)
code=0; "${E[@]}" CLIPD_SETUP_WAIT=2 nu "$CLIPD_NU" setup >"$TMP/s0.out" 2>&1 || code=$?
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
assert_eq "exit 4" 4 "$code"
if [ "$ms" -lt 8000 ]; then pass "bounded wait (${ms} ms, CLIPD_SETUP_WAIT=2)"; else fail "bounded wait" "< 8000 ms" "$ms ms"; fi
assert_eq "folder created anyway" yes "$([ -d "$FOLDER" ] && echo yes || echo no)"
assert_eq ".stfolder marker created" yes "$([ -d "$FOLDER/.stfolder" ] && echo yes || echo no)"
assert_eq "dedicated home generated" yes "$([ -s "$HOMEDIR/config.xml" ] && echo yes || echo no)"
assert_eq "its GUI on CLIPD_GUI_ADDRESS" "127.0.0.1:$GUI_PORT" \
  "$(sed -n '/<gui /,/<\/gui>/s:.*<address>\(.*\)</address>.*:\1:p' "$HOMEDIR/config.xml")"
for opt in globalAnnounceEnabled localAnnounceEnabled relaysEnabled natEnabled startBrowser crashReportingEnabled; do
  assert_eq "fresh home: $opt false before Syncthing ever runs" false \
    "$(sed -n "s:.*<$opt>\(.*\)</$opt>.*:\1:p" "$HOMEDIR/config.xml")"
done
assert_eq "fresh home: listens only where told, before Syncthing ever runs" "$LISTEN" \
  "$(sed -n 's:.*<listenAddress>\(.*\)</listenAddress>.*:\1:p' "$HOMEDIR/config.xml")"
assert_eq "fresh home: usage reporting declined" -1 "$(sed -n 's:.*<urAccepted>\(.*\)</urAccepted>.*:\1:p' "$HOMEDIR/config.xml")"
assert_eq "age identity created" yes "$([ -s "$TMP/cfg/identity.txt" ] && echo yes || echo no)"
assert_eq "the user's HOME untouched" "" "$(ls -A "$TMP/home" | grep -v '^\.config$')"

scenario "setup with Syncthing up"
start_syncthing
code=0; cnu setup >"$TMP/s1.out" 2>&1 || code=$?
assert_eq "exit 0" 0 "$code"
O="$(rest /rest/config/options)"
assert_eq "global discovery off" false "$(jq -r .globalAnnounceEnabled <<<"$O")"
assert_eq "local discovery off" false "$(jq -r .localAnnounceEnabled <<<"$O")"
assert_eq "relays off" false "$(jq -r .relaysEnabled <<<"$O")"
assert_eq "NAT off" false "$(jq -r .natEnabled <<<"$O")"
assert_eq "listens on the LAN address only" "[\"$LISTEN\"]" "$(jq -c .listenAddresses <<<"$O")"
assert_eq "usage reporting declined" -1 "$(jq -r .urAccepted <<<"$O")"
F="$(rest /rest/config/folders/clipd)"
assert_eq "folder path" "$FOLDER" "$(jq -r .path <<<"$F")"
assert_eq "send-receive" sendreceive "$(jq -r .type <<<"$F")"
assert_eq "versioning off" "" "$(jq -r .versioning.type <<<"$F")"
assert_eq "watcher delay 1 s" 1 "$(jq -r '.fsWatcherDelayS | floor' <<<"$F")"
assert_eq "watcher on" true "$(jq -r .fsWatcherEnabled <<<"$F")"
assert_eq "rescan 3600 s" 3600 "$(jq -r .rescanIntervalS <<<"$F")"
assert_eq "no conflict copies" 0 "$(jq -r .maxConflicts <<<"$F")"
assert_eq "only the clipd folder" '["clipd"]' "$(rest /rest/config/folders | jq -c '[.[].id]')"

scenario "setup is idempotent"
before="$(config_json)"
code=0; cnu setup >"$TMP/s2.out" 2>&1 || code=$?
assert_eq "exit 0" 0 "$code"
assert_eq "REST config unchanged by the second run" "$before" "$(config_json)"
assert_eq "...and it says so" yes "$(grep -q 'unchanged' "$TMP/s2.out" && echo yes || echo no)"

scenario "reboot: folder gone under a running Syncthing"
rm -rf "$FOLDER"
rest /rest/db/scan?folder=clipd -X POST >/dev/null 2>&1   # let Syncthing notice
sleep 2
code=0; cnu setup >"$TMP/s3.out" 2>&1 || code=$?
assert_eq "exit 0" 0 "$code"
assert_eq "folder restored" yes "$([ -d "$FOLDER/.stfolder" ] && echo yes || echo no)"
state=""
for i in $(seq 1 40); do
  state="$(rest "/rest/db/status?folder=clipd" | jq -r .state)"
  [ "$state" = idle ] && break
  sleep 0.25
done
assert_eq "folder idle again, no manual action" idle "$state"
assert_eq "no folder errors" 0 "$(rest "/rest/folder/errors?folder=clipd" | jq '.errors // [] | length')"

scenario "no IPv4 route: every other LAN-only option still applied"
mkdir -p "$TMP/noroute"
printf '#!/bin/sh\necho "RTNETLINK answers: Network is unreachable" >&2\nexit 2\n' > "$TMP/noroute/ip"
chmod +x "$TMP/noroute/ip"
rest /rest/config/options | jq '.relaysEnabled = true | .globalAnnounceEnabled = true | .natEnabled = true' \
  | rest /rest/config/options -X PUT -H 'Content-Type: application/json' --data-binary @- >"$TMP/put.out"
assert_eq "precondition: relays switched back on" true "$(rest /rest/config/options | jq -r .relaysEnabled)"
code=0; "${E[@]}" CLIPD_LISTEN= PATH="$TMP/noroute:$TMP/bin:$PATH" nu "$CLIPD_NU" setup >"$TMP/noroute.out" 2>&1 || code=$?
assert_eq "exit 78" 78 "$code"
O="$(rest /rest/config/options)"
assert_eq "relays off anyway" false "$(jq -r .relaysEnabled <<<"$O")"
assert_eq "global discovery off anyway" false "$(jq -r .globalAnnounceEnabled <<<"$O")"
assert_eq "NAT off anyway" false "$(jq -r .natEnabled <<<"$O")"
assert_eq "listen address left as it was" "[\"$LISTEN\"]" "$(jq -c .listenAddresses <<<"$O")"
assert_eq "says why" yes "$(grep -q 'no LAN address' "$TMP/noroute.out" && echo yes || echo no)"

scenario "setup starts clipd's Syncthing unit itself"
mkdir -p "$TMP/fakesysd"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$TMP/systemctl.log" > "$TMP/fakesysd/systemctl"
chmod +x "$TMP/fakesysd/systemctl"
: > "$TMP/systemctl.log"
code=0; "${E[@]}" CLIPD_SYNCTHING_UNIT=clipd-test.service PATH="$TMP/fakesysd:$TMP/bin:$PATH" nu "$CLIPD_NU" setup >/dev/null 2>&1 || code=$?
assert_eq "exit 0" 0 "$code"
assert_eq "systemctl --user start <unit>" "--user start clipd-test.service" "$(cat "$TMP/systemctl.log")"

# A second identity and device stand in for a peer.
PEER_CFG="$TMP/peercfg"; mkdir -p "$PEER_CFG"
PEER_AGE="$(env CLIPD_CONFIG_DIR="$PEER_CFG" "$TMP/bin/clipd" keygen)"
PEER_ID="$(env HOME="$TMP/home" STNODEFAULTFOLDER=1 syncthing generate --home "$TMP/peerst" --no-port-probing 2>&1 \
  | sed -n 's/.*device=\([A-Z0-9-]*\).*/\1/p' | head -1)"

scenario "peer add pins both, once"
code=0; cnu peer add laptop "$PEER_ID" "$PEER_AGE" >/dev/null 2>&1 || code=$?
assert_eq "exit 0" 0 "$code"
code=0; cnu peer add laptop "$PEER_ID" "$PEER_AGE" >/dev/null 2>&1 || code=$?
assert_eq "second add exit 0" 0 "$code"
assert_eq "one device entry" 1 "$(rest /rest/config/devices | jq --arg d "$PEER_ID" '[.[] | select(.deviceID == $d)] | length')"
assert_eq "device named" laptop "$(rest "/rest/config/devices/$PEER_ID" | jq -r .name)"
assert_eq "folder shared with it once" 1 "$(rest /rest/config/folders/clipd | jq --arg d "$PEER_ID" '[.devices[] | select(.deviceID == $d)] | length')"
assert_eq "recipient pinned once" 1 "$(grep -cxF "$PEER_AGE" "$TMP/cfg/recipients.txt")"
assert_eq "no auto-accept of folders" false "$(rest "/rest/config/devices/$PEER_ID" | jq -r .autoAcceptFolders)"
code=0; cnu peer add desk "$PEER_ID" "$PEER_AGE" --address tcp://192.0.2.7:22100 >/dev/null 2>&1 || code=$?
assert_eq "--address pins a static address" '["tcp://192.0.2.7:22100"]' "$(rest "/rest/config/devices/$PEER_ID" | jq -c .addresses)"

scenario "peer add refuses bad input and writes nothing"
before="$(config_json)"; rbefore="$(cat "$TMP/cfg/recipients.txt")"
code=0; cnu peer add bad NOT-A-DEVICE-ID "$PEER_AGE" >/dev/null 2>&1 || code=$?
assert_eq "bad device id → exit 2" 2 "$code"
code=0; cnu peer add bad "$PEER_ID" age1notarecipient >/dev/null 2>&1 || code=$?
assert_eq "bad recipient → exit 2" 2 "$code"
assert_eq "config unchanged" "$before" "$(config_json)"
assert_eq "recipients unchanged" "$rbefore" "$(cat "$TMP/cfg/recipients.txt")"

scenario "status reads the dedicated instance"
code=0; "${E[@]}" "$TMP/bin/clipd" status >"$TMP/status.out" 2>&1 || code=$?
assert_eq "exit 3 (peer pinned, never seen), not 4" 3 "$code"
code=0; cnu status >/dev/null 2>&1 || code=$?
assert_eq "clipd.nu status passes clipd's exit through" 3 "$code"

scenario "peer rm"
code=0; cnu peer rm "$PEER_ID" "$PEER_AGE" >/dev/null 2>&1 || code=$?
assert_eq "exit 0" 0 "$code"
assert_eq "device gone" 0 "$(rest /rest/config/devices | jq --arg d "$PEER_ID" '[.[] | select(.deviceID == $d)] | length')"
assert_eq "unshared" 0 "$(rest /rest/config/folders/clipd | jq --arg d "$PEER_ID" '[.devices[] | select(.deviceID == $d)] | length')"
assert_eq "recipient unpinned" 0 "$(grep -cxF "$PEER_AGE" "$TMP/cfg/recipients.txt")"

scenario "start runs setup and the agent; a second start exits 0"
spawn Xvfb "$DPY" -screen 0 320x240x24 >/dev/null 2>&1
XVFB_PID=$SPAWNED
for i in $(seq 1 40); do timeout 1 xclip -display "$DPY" -selection clipboard -o >/dev/null 2>&1; [ $? -ne 1 ] && break; sleep 0.1; done
spawn "${E[@]}" DISPLAY=:77 nu "$CLIPD_NU" start "$DPY" >"$TMP/start1.out" 2>&1
START_PID=$SPAWNED
for i in $(seq 1 60); do [ -e "$FOLDER/hb-testhost.age" ] && break; sleep 0.1; done
assert_eq "agent wrote its heartbeat" yes "$([ -e "$FOLDER/hb-testhost.age" ] && echo yes || echo no)"
assert_eq "start became the agent (exec)" yes "$(kill -0 "$START_PID" 2>/dev/null && tr '\0' ' ' </proc/$START_PID/cmdline | grep -q 'clipd agent x' && echo yes || echo no)"
code=0; timeout 20 "${E[@]}" nu "$CLIPD_NU" start "$DPY" >"$TMP/start2.out" 2>&1 || code=$?
assert_eq "second start exits 0" 0 "$code"
assert_eq "...because an agent already serves $DPY" yes "$(grep -q 'another agent serves' "$TMP/start2.out" && echo yes || echo no)"
code=0; "${E[@]}" nu "$CLIPD_NU" start >/dev/null 2>&1 || code=$?
assert_eq "start without a display → exit 78" 78 "$code"
kill "$START_PID" 2>/dev/null; wait "$START_PID" 2>/dev/null

stop_syncthing

scenario "two first setups at once (i3 starts :0 and :10 together)"
bad=0
for i in 1 2 3 4 5; do
  R="$TMP/race$i"; mkdir -p "$R/state" "$R/run" "$R/cfg"; chmod 700 "$R/run"
  RE=(env HOME="$TMP/home" PATH="$TMP/bin:$PATH" XDG_STATE_HOME="$R/state" XDG_RUNTIME_DIR="$R/run"
      CLIPD_CONFIG_DIR="$R/cfg" CLIPD_GUI_ADDRESS="127.0.0.1:$GUI_PORT" CLIPD_LISTEN="$LISTEN"
      CLIPD_SYNCTHING_UNIT= CLIPD_SETUP_WAIT=1 STNODEFAULTFOLDER=1)
  "${RE[@]}" nu "$CLIPD_NU" setup >"$R/a.out" 2>&1 & pa=$!
  "${RE[@]}" nu "$CLIPD_NU" setup >"$R/b.out" 2>&1 & pb=$!
  wait "$pa"; ca=$?; wait "$pb"; cb=$?
  # Syncthing is not running, so 4 is right for both; 78 means a lost race.
  [ "$ca" = 4 ] && [ "$cb" = 4 ] || { bad=$((bad + 1)); echo "    run $i: exits $ca/$cb: $(cat "$R/a.out" "$R/b.out" | grep -v 'not answering' | head -2)"; }
  syncthing device-id --home "$R/state/clipd/syncthing" >/dev/null 2>&1 || { bad=$((bad + 1)); echo "    run $i: unreadable cert"; }
  [ -s "$R/cfg/identity.txt" ] || { bad=$((bad + 1)); echo "    run $i: no identity"; }
done
assert_eq "5 concurrent pairs: both exit 4, one valid identity and cert" 0 "$bad"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
