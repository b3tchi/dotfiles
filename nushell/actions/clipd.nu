#!/usr/bin/env nu
# clipd.nu — Linux wrapper around clipd ([[ft018]], sp039 Task 9, adr0039's
# wrapper surface). clipd itself syncs nothing: it writes age-encrypted entries
# into a folder, and a Syncthing instance carries that folder between hosts.
# This script owns that instance and the folder.
#
#   clipd.nu setup                         idempotent; safe at every session start;
#                                          starts clipd's Syncthing unit if needed
#   clipd.nu peer add <name> <device-id> <age-recipient> [--address tcp://ip:port]
#   clipd.nu peer rm <device-id> <age-recipient>
#   clipd.nu status                        clipd status, exit code passed through
#   clipd.nu start <display>               start Syncthing, setup, then become the agent
#   clipd.nu stop                          stop Syncthing and every clipd agent
#
# A DEDICATED SYNCTHING (user decision, 2026-11-07). The spec's settings —
# discovery, relays and NAT off, LAN-only listen — are per instance, and the
# user's own Syncthing reaches a NAS through discovery and relays. So clipd has
# its own: home $XDG_STATE_HOME/clipd/syncthing (where `clipd status` reads its
# config), the clipd-syncthing user service, GUI 127.0.0.1:8385, sync port
# 22100. Nothing here ever touches another Syncthing.
#
# The folder lives on tmpfs ($XDG_RUNTIME_DIR/clipd/folder), so after a reboot
# it is gone, `.stfolder` marker included. setup recreates both and asks
# Syncthing to rescan, which clears its "folder marker missing" error.
#
# Peers: with discovery off, a peer is found only by address. Pin one side's
# address with --address (a Windows peer dials out to us, adr0039, so it can
# stay `dynamic` here). The age recipient is pinned locally through `clipd
# recipients`; nothing in the shared folder can add a recipient.
#
# Exit: 0 ok, 1 Syncthing refused a change, 2 usage or bad argument, 4 Syncthing
# not answering within CLIPD_SETUP_WAIT (default 30 s), 78 config unusable.
# `status` exits with clipd status's own code.
#
# env: CLIPD_BIN             clipd binary (default: clipd on PATH)
#      CLIPD_SYNCTHING_HOME  dedicated home (default $XDG_STATE_HOME/clipd/syncthing)
#      CLIPD_GUI_ADDRESS     GUI/REST address written at generation (127.0.0.1:8385)
#      CLIPD_LISTEN          sync listen address (default tcp://<lan-ip>:22100)
#      CLIPD_SYNCTHING_UNIT  user service to start/stop; empty = leave it alone
#      CLIPD_SETUP_WAIT      seconds to wait for Syncthing's REST API (30)
#      CLIPD_FOLDER, CLIPD_CONFIG_DIR, CLIPD_DISPLAY  as clipd reads them
#
# Test: clipd/test-clipd-setup.sh (throwaway Syncthing, Xvfb).

const FOLDER_ID = "clipd"
const DEFAULT_GUI = "127.0.0.1:8385"
const DEFAULT_PORT = 22100
const DEFAULT_UNIT = "clipd-syncthing.service"
const DEVICE_RE = '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$'
const RECIPIENT_RE = '^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$'

def die [code: int, msg: string] {
  print -e $"clipd.nu: ($msg)"
  exit $code
}

# $env.<name> when set and non-empty, else fallback.
def env-or [name: string, fallback: string]: nothing -> string {
  let v = ($env | get -o $name)
  if ($v == null) or ($v == "") { $fallback } else { $v }
}

def clipd-bin [] { env-or CLIPD_BIN "clipd" }
def st-home [] {
  env-or CLIPD_SYNCTHING_HOME (env-or XDG_STATE_HOME ($env.HOME | path join ".local" "state") | path join "clipd" "syncthing")
}
def st-config [] { st-home | path join "config.xml" }
def config-dir [] {
  env-or CLIPD_CONFIG_DIR (env-or XDG_CONFIG_HOME ($env.HOME | path join ".config") | path join "clipd")
}
def folder-path [] {
  let f = (env-or CLIPD_FOLDER "")
  if $f != "" { return $f }
  let r = (env-or XDG_RUNTIME_DIR "")
  if $r == "" { die 78 "XDG_RUNTIME_DIR unset; set CLIPD_FOLDER" }
  $r | path join "clipd" "folder"
}

# The folder and its marker. Syncthing refuses a folder without `.stfolder`,
# and after a reboot neither exists. The parent is 0700: tmpfs, but shared.
def ensure-folder [] {
  let f = (folder-path)
  mkdir ($f | path join ".stfolder")
  ^chmod 700 ($f | path dirname)
}

# This device's age identity. clipd keygen refuses to overwrite one, which is
# the property that matters: replacing it would orphan every peer's pin.
def ensure-identity [] {
  let id = (config-dir | path join "identity.txt")
  if ($id | path exists) { return }
  let r = (do { ^(clipd-bin) keygen } | complete)
  if $r.exit_code != 0 {
    # Another start (the other display) made it first: that is the outcome
    # wanted, and keygen refusing to overwrite it is what kept it intact.
    if ($id | path exists) { return }
    die 78 $"clipd keygen failed: ($r.stderr | str trim)"
  }
  print $"clipd.nu: new identity; pin this recipient on every peer: ($r.stdout | str trim)"
}

# The dedicated home, generated once. `syncthing generate` writes Syncthing's
# defaults: listen on every interface, global discovery, relays, UPnP. Those
# are rewritten in config.xml HERE, before anything can start this instance,
# so it is LAN-only from its first second, not from the first setup that
# succeeds. Its listen address is loopback until setup finds the LAN address.
# The GUI address is written here too (not passed as a flag) so `clipd
# status` reads the same one. Generated in a temp dir and renamed into place,
# so config.xml existing means the home is complete.
def ensure-home [] {
  if (st-config | path exists) { return }
  let tmp = $"(st-home).new"
  rm -rf $tmp
  mkdir ($tmp | path dirname)
  let r = (with-env {STNODEFAULTFOLDER: "1"} { do { ^syncthing generate --home $tmp --no-port-probing } | complete })
  if $r.exit_code != 0 { die 78 $"syncthing generate failed: ($r.stderr | str trim | lines | last)" }
  let listen = (env-or CLIPD_LISTEN $"tcp://127.0.0.1:($DEFAULT_PORT)")
  let edits = [
    ['(<gui[^>]*>\s*<address>)[^<]*(</address>)' (env-or CLIPD_GUI_ADDRESS $DEFAULT_GUI)]
    ['(<listenAddress>)[^<]*(</listenAddress>)' $listen]
    ['(<globalAnnounceEnabled>)[^<]*(</globalAnnounceEnabled>)' "false"]
    ['(<localAnnounceEnabled>)[^<]*(</localAnnounceEnabled>)' "false"]
    ['(<relaysEnabled>)[^<]*(</relaysEnabled>)' "false"]
    ['(<natEnabled>)[^<]*(</natEnabled>)' "false"]
    ['(<startBrowser>)[^<]*(</startBrowser>)' "false"]
    ['(<crashReportingEnabled>)[^<]*(</crashReportingEnabled>)' "false"]
    ['(<urAccepted>)[^<]*(</urAccepted>)' "-1"]
    ['(<autoUpgradeIntervalH>)[^<]*(</autoUpgradeIntervalH>)' "0"]
  ]
  let cfg = ($tmp | path join "config.xml")
  mut xml = (open --raw $cfg)
  for e in $edits {
    # Exactly one match each: a Syncthing whose config.xml has changed shape
    # must fail here, not start with a default left in place.
    let n = ($xml | parse -r $e.0 | length)
    if $n != 1 { rm -rf $tmp; die 78 $"syncthing generate: expected one match for ($e.0), found ($n); not starting a default-configured instance" }
    $xml = ($xml | str replace -r $e.0 ('${1}' + $e.1 + '${2}'))
  }
  $xml | save -f $cfg
  rm -rf (st-home)
  mv $tmp (st-home)
}

# The first-run steps, serialised. i3 starts :0 and :10 together, and two
# unlocked first runs race keygen (the loser used to exit 78 and its display
# got no agent) and `syncthing generate` (a corrupt cert.pem).
def ensure-all [] {
  if (which flock | is-empty) {
    ensure-folder; ensure-identity; ensure-home
    return
  }
  let lockdir = (st-home | path dirname)
  mkdir $lockdir
  let r = (do { ^flock -w 60 ($lockdir | path join "ensure.lock") $nu.current-exe $env.CURRENT_FILE ensure } | complete)
  print -n $r.stdout
  if $r.exit_code != 0 {
    print -n -e $r.stderr
    exit $r.exit_code
  }
}

def "main ensure" [] {
  ensure-folder
  ensure-identity
  ensure-home
}

def unit [] {
  let u = ($env | get -o CLIPD_SYNCTHING_UNIT)
  if $u == null { $DEFAULT_UNIT } else { $u }
}

# Starts clipd's Syncthing unit, so setup and peer work on their own. A unit
# that will not start is a log line: the wait that follows reports exit 4.
def ensure-running [] {
  let u = (unit)
  if ($u == "") or (which systemctl | is-empty) { return }
  let r = (do { ^systemctl --user start $u } | complete)
  if $r.exit_code != 0 { print -e $"clipd.nu: systemctl --user start ($u) failed: ($r.stderr | str trim)" }
}

def api [] {
  let raw = (open --raw (st-config))
  let key = ($raw | parse -r '<apikey>([^<]+)</apikey>' | get -o 0.capture0)
  let addr = ($raw | parse -r '<gui[^>]*>\s*<address>([^<]+)</address>' | get -o 0.capture0)
  if ($key == null) or ($addr == null) { die 78 $"(st-config): no GUI address or API key" }
  {base: $"http://($addr)", headers: {X-API-Key: $key}}
}

def wait-up [a: record] {
  let secs = (env-or CLIPD_SETUP_WAIT "30" | into int)
  let deadline = ((date now) + ($secs * 1sec))
  loop {
    let up = (try { http get -H $a.headers -m 2sec $"($a.base)/rest/system/ping" | ignore; true } catch { false })
    if $up { return }
    if (date now) > $deadline { die 4 $"Syncthing not answering on ($a.base) after ($secs) s" }
    sleep 300ms
  }
}

def rget [a: record, path: string] {
  http get -H $a.headers -m 5sec $"($a.base)($path)"
}

# A config write. Anything but 2xx is fatal: a half-applied setup must say so.
def rsend [a: record, method: string, path: string, body: any = null] {
  let url = $"($a.base)($path)"
  let json = ($body | to json)
  let r = match $method {
    "PUT" => (http put -f -e -H $a.headers -t application/json -m 5sec $url $json)
    "PATCH" => (http patch -f -e -H $a.headers -t application/json -m 5sec $url $json)
    "POST" => (http post -f -e -H $a.headers -t application/json -m 5sec $url $json)
    "DELETE" => (http delete -f -e -H $a.headers -m 5sec $url)
  }
  if $r.status >= 300 { die 1 $"Syncthing refused ($method) ($path): HTTP ($r.status) ($r.body | to text | str trim)" }
}

# The fields of want whose value differs in cur.
def changed [cur: record, want: record]: nothing -> record {
  $want | transpose k v
  | where {|f| ($cur | get -o $f.k) != $f.v }
  | reduce -f {} {|f, acc| $acc | insert $f.k $f.v }
}

# The LAN address to listen on, or null when there is none (no IPv4 route).
def listen-address [] {
  let l = (env-or CLIPD_LISTEN "")
  if $l != "" { return $l }
  let r = (do { ^ip -4 route get 1.1.1.1 } | complete)
  let src = ($r.stdout | parse -r 'src (\S+)' | get -o 0.capture0)
  if ($r.exit_code != 0) or ($src == null) { return null }
  $"tcp://($src):($DEFAULT_PORT)"
}

# Options and folder as the spec has them; writes only what differs, so a
# rerun changes nothing. Returns the names of what it changed.
#
# With no LAN address every other option is still applied and the listen
# address is left as it is (loopback on a fresh home); the caller reports it.
def configure [a: record, listen: any]: nothing -> list<string> {
  mut done = []
  mut want_opts = {
    globalAnnounceEnabled: false
    localAnnounceEnabled: false
    relaysEnabled: false
    natEnabled: false
    startBrowser: false
    urAccepted: -1
    crashReportingEnabled: false
    autoUpgradeIntervalH: 0
  }
  if $listen != null { $want_opts = ($want_opts | insert listenAddresses [$listen]) }
  let opts = (changed (rget $a /rest/config/options) $want_opts)
  if ($opts | is-not-empty) {
    rsend $a PATCH /rest/config/options $opts
    $done = ($done | append $"options: ($opts | columns | str join ', ')")
  }

  let want = {
    path: (folder-path)
    type: "sendreceive"
    fsWatcherEnabled: true
    fsWatcherDelayS: 1
    rescanIntervalS: 3600
    maxConflicts: 0
  }
  let cur = (rget $a /rest/config/folders | where id == $FOLDER_ID | get -o 0)
  if $cur == null {
    let me = (rget $a /rest/system/status | get myID)
    rsend $a PUT $"/rest/config/folders/($FOLDER_ID)" ($want | merge {
      id: $FOLDER_ID, label: $FOLDER_ID, devices: [{deviceID: $me}], versioning: {type: ""}
    })
    $done = ($done | append "folder: created")
  } else {
    mut diff = (changed $cur $want)
    if ($cur.versioning.type != "") { $diff = ($diff | insert versioning {type: ""}) }
    if ($diff | is-not-empty) {
      rsend $a PATCH $"/rest/config/folders/($FOLDER_ID)" $diff
      $done = ($done | append $"folder: ($diff | columns | str join ', ')")
    }
  }
  $done
}

def folder-state [a: record]: nothing -> string {
  try { rget $a $"/rest/db/status?folder=($FOLDER_ID)" | get -o state | default "" } catch { "" }
}

def "main setup" [] {
  ensure-all
  ensure-running
  let a = (api)
  wait-up $a
  let listen = (listen-address)
  mut done = (configure $a $listen)
  # A folder whose marker vanished (reboot) sits in an error state until it is
  # scanned again; the rescan interval is an hour, so ask now.
  if (folder-state $a) == "error" {
    rsend $a POST $"/rest/db/scan?folder=($FOLDER_ID)"
    $done = ($done | append "folder: rescanned after error")
  }
  if ($done | is-empty) {
    print "clipd.nu: setup: Syncthing config unchanged"
  } else {
    $done | each {|d| print $"clipd.nu: setup: ($d)" } | ignore
  }
  if $listen == null { die 78 "no LAN address (no IPv4 default route), so Syncthing keeps its previous listen address; set CLIPD_LISTEN or rerun setup once the network is up" }
}

def check-peer-args [device_id: string, recipient: string] {
  if not ($device_id =~ $DEVICE_RE) { die 2 $"not a Syncthing device id: ($device_id)" }
  if not ($recipient =~ $RECIPIENT_RE) { die 2 $"not an age X25519 recipient: ($recipient)" }
}

def "main peer add" [
  name: string
  device_id: string
  recipient: string
  --address: string = "dynamic"   # tcp://ip:port when discovery cannot find it
] {
  check-peer-args $device_id $recipient
  if ($name | str trim) == "" { die 2 "peer name is empty" }
  ensure-all
  ensure-running
  let a = (api)
  wait-up $a
  configure $a (listen-address) | ignore

  let want = {name: $name, addresses: [$address], autoAcceptFolders: false}
  let cur = (http get -f -e -H $a.headers -m 5sec $"($a.base)/rest/config/devices/($device_id)")
  if ($cur.status == 404) or ((changed $cur.body $want) | is-not-empty) {
    rsend $a PUT $"/rest/config/devices/($device_id)" ($want | insert deviceID $device_id)
  }
  let folder = (rget $a $"/rest/config/folders/($FOLDER_ID)")
  if not ($folder.devices | any {|d| $d.deviceID == $device_id }) {
    rsend $a PATCH $"/rest/config/folders/($FOLDER_ID)" {devices: ($folder.devices | append {deviceID: $device_id})}
  }
  let r = (do { ^(clipd-bin) recipients add $recipient } | complete)
  if $r.exit_code != 0 { die 1 $"clipd recipients add: ($r.stderr | str trim)" }
  print $"clipd.nu: peer ($name) pinned"
}

def "main peer rm" [device_id: string, recipient: string] {
  check-peer-args $device_id $recipient
  ensure-all
  ensure-running
  let a = (api)
  wait-up $a
  let folder = (rget $a $"/rest/config/folders/($FOLDER_ID)")
  if ($folder.devices | any {|d| $d.deviceID == $device_id }) {
    rsend $a PATCH $"/rest/config/folders/($FOLDER_ID)" {devices: ($folder.devices | where deviceID != $device_id)}
  }
  let cur = (http get -f -e -H $a.headers -m 5sec $"($a.base)/rest/config/devices/($device_id)")
  if $cur.status == 200 { rsend $a DELETE $"/rest/config/devices/($device_id)" }
  # 1 = was not pinned: already the state asked for.
  let r = (do { ^(clipd-bin) recipients rm $recipient } | complete)
  if $r.exit_code > 1 { die 1 $"clipd recipients rm: ($r.stderr | str trim)" }
  print "clipd.nu: peer removed"
}

def "main peer" [] { usage }

def "main status" [] {
  let r = (do { ^(clipd-bin) status } | complete)
  print -n $r.stdout
  print -n -e $r.stderr
  exit $r.exit_code
}

# Starts the dedicated Syncthing, runs setup, then replaces itself with the
# agent for <display>. setup failing (Syncthing down) costs a log line, not
# the agent: entries still land in the folder and sync once Syncthing is up.
# A second start for the same display exits 0 (the agent's per-display lock).
def "main start" [display?: string] {
  let d = ($display | default (env-or CLIPD_DISPLAY ""))
  if $d == "" { die 78 "start: display required (argument or CLIPD_DISPLAY); inherited DISPLAY is never used" }
  ensure-all
  let s = (do { ^$nu.current-exe $env.CURRENT_FILE setup } | complete)
  print -n $s.stdout
  if $s.exit_code != 0 { print -e $"clipd.nu: start: setup exited ($s.exit_code), starting the agent anyway: ($s.stderr | str trim)" }
  exec (clipd-bin) agent x $d
}

def "main stop" [] {
  let u = (unit)
  if ($u != "") and (which systemctl | is-not-empty) { ^systemctl --user stop $u }
  let uid = (^id -u | str trim)
  do -i { ^pkill -u $uid -f '(^|/)clipd agent x( |$)' }
  print "clipd.nu: stopped"
}

def usage [] {
  print -e "usage: clipd.nu setup | peer add <name> <device-id> <age-recipient> [--address tcp://ip:port] | peer rm <device-id> <age-recipient> | status | start <display> | stop"
  exit 2
}

def main [] { usage }
