#!/usr/bin/env nu

# i3 project workspace picker
# Called by i3 keybinding ($mod+p / $mod+Shift+p)
# Uses rofi to select a project, then switches to or creates an i3 workspace
#
# Naming: single workspace = "projectname", multiple = "projectname_1", "projectname_2"

const ws_list = '~/.config/polybar/scripts/ws-list.nu'
use $ws_list *

const config_path = '~/.config/project/projects.yaml'

# read projects registry
def get-projects [] {
	let path = ($config_path | path expand)
	if ($path | path exists) {
		open $path | get -o projects | default {}
	} else {
		{}
	}
}

def main [
	--new (-n) # force create new workspace even if one exists
] {
	let projects = get-projects

	if ($projects | columns | is-empty) {
		return
	}

	# normalize workspace names before building the list
	# (cleans up orphaned _N names when only one workspace remains)
	$projects | columns | each { |name| normalize $name } | ignore

	# detect current project (to exclude from switch list)
	let current_project = (project-name (focused).name)

	# build rofi lines: "name  [ws, ws_1, ws_2]" or "name"
	# for switch mode ($mod+p): skip the project we're already on
	# for new mode ($mod+Shift+p): show all projects including current
	let project_list = if $new {
		$projects | columns
	} else {
		$projects | columns | where { |name| $name != $current_project }
	}
	let lines = ($project_list | each { |name|
		let pws = for-project $name
		if ($pws | is-empty) {
			$name
		} else {
			let ws_names = ($pws | get name | str join ", ")
			$"($name)  [($ws_names)]"
		}
	} | str join "\n")

	# show rofi picker
	let selected = ($lines | rofi -dmenu -p "Project" -i | str trim)

	if ($selected | is-empty) {
		return
	}

	# extract project name (strip workspace info suffix if present)
	let name = ($selected | split row "  " | first | str trim)

	let existing = for-project $name

	if $new {
		if ($existing | length) == 0 {
			i3-msg $"workspace ($name)" | ignore
		} else {
			# rename bare name to _1 if needed
			if ($existing | any { |ws| $ws.name == $name }) {
				i3-msg $"rename workspace \"($name)\" to \"($name)_1\"" | ignore
			}
			# find max existing index and create next
			let next = ($existing | each { |ws|
				if $ws.name == $name { 1 } else { $ws.name | str replace $"($name)_" "" | into int }
			} | math max) + 1
			i3-msg $"workspace ($name)_($next)" | ignore
		}
	} else {
		if ($existing | is-empty) {
			i3-msg $"workspace ($name)" | ignore
		} else {
			i3-msg $"workspace ($existing | first | get name)" | ignore
		}
	}
}
