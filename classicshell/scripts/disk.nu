#!/usr/bin/env nu

let state_file = "/tmp/polybar_disk_hide"

def main [] {}

def "main toggle" [
] {
    if ($state_file | path exists) {
        rm $state_file
    } else {
        touch $state_file
    }
}

def "main display" [
	color: string = ""
] {
	let mem = (sys disks | where mount == '/' | first )
	if ($state_file | path exists) {
		print $"($mem.free / $mem.total | $in * 100 | into int)%"
	} else {
		print $"($mem.free / $mem.total | $in * 100 | into int)%%{($color)}($mem.free | into string | str replace ' GB' 'gb')"
	}
}
