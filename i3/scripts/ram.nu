#!/usr/bin/env nu

let state_file = "/tmp/polybar_ram_hide"

def main [
	action: string = "display" 
	color: string = ""
] {
    if $action == "toggle" {
        if ($state_file | path exists) {
            rm $state_file
        } else {
            touch $state_file
        }
    } else if $action == "display" {
        if ($state_file | path exists) {
            let mem = sys mem
            print $"($mem.free / $mem.total | $in * 100 | into int)%"
        } else {
            let mem = sys mem
            print $"($mem.free / $mem.total | $in * 100 | into int)%%{($color)}($mem.free | into string | str replace ' GB' 'gb')"
        }
    }
}
