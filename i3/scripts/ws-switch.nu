#!/usr/bin/env nu

# Switch to workspace by display order (matching Polybar i3 module with index-sort)
# Usage: ws-switch.nu <index>         — switch to Nth workspace (1-based)
# Usage: ws-switch.nu <index> move    — move container to Nth workspace
# Usage: ws-switch.nu <index> follow  — move container to Nth workspace and follow

const ws_list = '~/.config/polybar/scripts/ws-list.nu'
use $ws_list *

const config_path = '~/.config/project/projects.yaml'

def get-project-names [] {
	let path = ($config_path | path expand)
	if ($path | path exists) {
		open $path | get -o projects | default {} | columns
	} else {
		[]
	}
}

def normalize-all [] {
	get-project-names | each { |name| normalize $name } | ignore
}

def main [
	index: int       # 1-based position in Polybar display order
	action?: string  # "move" to move container, "follow" to move and follow
] {
	# normalize orphaned _N names before resolving index
	normalize-all

	let workspaces = sorted

	if $index < 1 or $index > ($workspaces | length) {
		return
	}

	let target = ($workspaces | get ($index - 1))

	match $action {
		"move" => {
			i3-msg $"move container to workspace ($target.name)" | ignore
			normalize-all
		},
		"follow" => {
			i3-msg $"move container to workspace ($target.name); workspace ($target.name)" | ignore
			normalize-all
		},
		_ => {
			if not $target.focused {
				i3-msg $"workspace ($target.name)" | ignore
			}
		}
	}
}
