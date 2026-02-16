#!/usr/bin/env nu

# Shared i3 workspace utilities
# Used by ws-switch.nu and project-picker.nu
#
# Workspace naming convention:
#   Single workspace:   "projectname"  (no suffix)
#   Multiple:           "projectname_1", "projectname_2", ...

# Get all i3 workspaces sorted in Polybar display order
# Polybar index-sort sorts by num ascending, preserving i3 order for equal num
export def sorted [] {
	i3-msg -t get_workspaces | from json | sort-by num
}

# Get the focused workspace
export def focused [] {
	sorted | where focused == true | first
}

# Find existing i3 workspaces for a project
# Matches both "name" (single) and "name_N" (multiple) patterns
export def for-project [name: string] {
	sorted | where { |ws| $ws.name == $name or $ws.name =~ $"^($name)_\\d+$" }
}

# Normalize project workspaces: if only one numbered workspace exists, rename to bare name
# e.g. "dotfiles_1" (alone) -> "dotfiles"
export def normalize [name: string] {
	let existing = for-project $name
	if ($existing | length) == 1 {
		let ws = ($existing | first | get name)
		if $ws != $name {
			i3-msg $"rename workspace \"($ws)\" to \"($name)\""
		}
	}
}

# Extract project name from a workspace name
# "dotfiles" -> "dotfiles", "dotfiles_1" -> "dotfiles", "3" -> null
export def project-name [ws_name: string] {
	if ($ws_name =~ '^.+_\d+$') {
		$ws_name | parse --regex '^(?P<project>.+)_\d+$' | first | get project
	} else if ($ws_name =~ '^\d+$') {
		# pure numeric workspace, not a project
		null
	} else {
		# bare name, could be a project
		$ws_name
	}
}
