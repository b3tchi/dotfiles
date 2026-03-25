def main [] {

}

const config_path = '~/.config/project/projects.yaml'

export-env {
	$env.PROJECT_CONFIG_PATH = ($config_path | path expand)

	# Auto-cd to project directory by detecting WM workspace name
	# Uses wm-ipc.nu to query i3/sway for the focused workspace,
	# then looks up the project path in projects.yaml
	let wm_ipc_path = ('~/.local/bin/wm-ipc.nu' | path expand)
	let project_name = if ($wm_ipc_path | path exists) {
		try {
			const wm_ipc = '~/.local/bin/wm-ipc.nu'
			use $wm_ipc *
			let ws_name = (ipc "-t get_workspaces" | from json | where focused == true | first | get name)
			# Extract project name: "dotfiles_1" -> "dotfiles", "3" -> null
			if ($ws_name =~ '^.+_\d+$') {
				$ws_name | parse --regex '^(?P<project>.+)_\d+$' | first | get project
			} else if ($ws_name =~ '^\d+$') {
				null
			} else {
				$ws_name
			}
		} catch {
			null
		}
	} else {
		# Fallback: check $env.PROJECT (set by bashrc)
		$env | get -o PROJECT | default null
	}

	if ($project_name != null) {
		let path = ($config_path | path expand)
		if ($path | path exists) {
			let projects = (open $path | get -o projects | default {})
			if ($project_name in ($projects | columns)) {
				let project_path = ($projects | get $project_name | get path)
				if ($project_path | path exists) {
					cd $project_path
				}
			}
		}
	}
}

# read projects registry, return empty record if file missing
def data [] {
	let path = ($config_path | path expand)
	if ($path | path exists) {
		open $path | get -o projects | default {}
	} else {
		{}
	}
}

# save projects registry
def save_data [projects: record] {
	let path = ($config_path | path expand)
	let dir = ($path | path dirname)
	if not ($dir | path exists) {
		mkdir $dir
	}
	{ projects: $projects } | to yaml | save --force $path
}

def project_names [] {
	data | columns
}

# list all registered projects
export def 'list' [] {
	let projects = data
	if ($projects | columns | is-empty) {
		print "No projects registered"
		return
	}

	# get active tmux session groups
	let active_groups = if (which tmux | is-not-empty) {
		tmux list-sessions -F "#{session_group}" 2>/dev/null
		| lines
		| where $it != ""
		| uniq
	} else {
		[]
	}

	$projects | columns | each { |name|
		let p = ($projects | get $name)
		let active = if ($name in $active_groups) { "*" } else { "" }
		{
			name: $name
			path: $p.path
			active: $active
		}
	}
}

# register a project
export def 'add' [
	name: string          # project name (used as tmux session group name)
	path?: string         # project path (default: current directory)
] {
	let project_path = if ($path | is-empty) { $env.PWD } else { $path | path expand }

	if not ($project_path | path exists) {
		print $"Path does not exist: ($project_path)"
		return
	}

	mut projects = data

	if ($name in ($projects | columns)) {
		print $"Project '($name)' already exists"
		return
	}

	$projects = ($projects | insert $name { path: $project_path })
	save_data $projects

	print $"Project '($name)' registered at ($project_path)"
}

# unregister a project
export def 'remove' [
	name: string@project_names # project name to remove
] {
	mut projects = data

	if not ($name in ($projects | columns)) {
		print $"Project '($name)' does not exist"
		return
	}

	$projects = ($projects | reject $name)
	save_data $projects

	print $"Project '($name)' removed"
}

# open the projects config file in $EDITOR
export def 'config' [] {
	let path = ($config_path | path expand)
	let dir = ($path | path dirname)
	if not ($dir | path exists) {
		mkdir $dir
	}
	if not ($path | path exists) {
		{ projects: {} } | to yaml | save $path
	}
	^$env.EDITOR $path
}

# navigate to project and create/attach tmux session
export def --env 'go' [
	name: string@project_names # project to navigate to
] {
	let projects = data

	if not ($name in ($projects | columns)) {
		print $"Project '($name)' does not exist"
		return
	}

	let project_path = ($projects | get $name | get path)

	if not ($project_path | path exists) {
		print $"Project path does not exist: ($project_path)"
		return
	}

	# cd to project directory
	cd $project_path

	# check if we are inside tmux
	if ($env | get -o TMUX | is-empty) {
		# outside tmux: create and attach session
		tmux-start attach 0 $name
	} else {
		# inside tmux: check if session group exists
		let existing = (tmux list-sessions -F "#{session_group}" 2>/dev/null
			| lines
			| where $it == $name)

		if ($existing | is-not-empty) {
			# session group exists, find an attached session or the first one
			let session = (tmux list-sessions -F "#{session_name} #{session_group}" 2>/dev/null
				| lines
				| parse "{session_name} {group}"
				| where group == $name
				| first
				| get session_name)

			tmux switch-client -t $session
		} else {
			# create new session group and switch
			let target = (tmux-start start 0 $name | str trim)
			tmux switch-client -t $target
		}
	}
}
