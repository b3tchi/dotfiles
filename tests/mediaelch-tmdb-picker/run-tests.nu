#!/usr/bin/env nu
let out = (do { ^$nu.current-exe ($env.FILE_PWD | path join cases.nu) } | complete)
if $out.exit_code != 0 {
    print $out.stdout
    print $out.stderr
    exit 1
}
let results = ($out.stdout | from json)
for r in $results { print $"($r.status) ($r.name)" }
exit 0
