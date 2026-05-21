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
				let entry = ($projects | get $project_name)
				# Remote entries (ssh field present) must not auto-cd locally.
				# Remote is opt-in via explicit 'project go'; skip silently here.
				let is_remote = ('ssh' in $entry) and ($entry | get ssh | describe) == 'string' and not ($entry | get ssh | is-empty)
				if not $is_remote {
					let project_path = ($entry | get path)
					if ($project_path | path exists) {
						cd $project_path
					}
				}
			}
		}
	}
}

# validate and normalise a single project entry read from yaml
# - ssh absent or null or "" → treated as local (ssh key removed)
# - ssh non-empty string → valid remote profile, kept as-is
# - ssh any other type (int, list, record…) → error loud at parse time
def parse_project_entry [name: string, entry: record] {
	if 'ssh' not-in $entry {
		return $entry
	}
	let ssh_val = $entry | get ssh
	let ssh_type = $ssh_val | describe
	if $ssh_type == 'nothing' {
		# ssh: null → treat as absent (local entry)
		return ($entry | reject ssh)
	}
	if $ssh_type == 'string' {
		if ($ssh_val | is-empty) {
			# ssh: "" → treat as absent (local entry)
			return ($entry | reject ssh)
		}
		# valid non-empty ssh profile name
		return $entry
	}
	# malformed: non-string, non-null value → fail loud
	error make { msg: $"project '($name)': ssh field must be a string, got: ($ssh_type)" }
}

# read projects registry, return empty record if file missing
# each entry is validated: ssh field must be a string when present;
# null / empty-string ssh is normalised away (treated as local).
def data [] {
	let path = ($config_path | path expand)
	if ($path | path exists) {
		let raw = open $path | get -o projects | default {}
		$raw | columns | reduce --fold {} { |name, acc|
			let entry = ($raw | get $name)
			let parsed = (parse_project_entry $name $entry)
			$acc | insert $name $parsed
		}
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
		let ssh = ($p | get -o ssh | default "")
		{
			name: $name
			path: $p.path
			ssh: $ssh
			active: $active
		}
	}
}

# register a project
export def 'add' [
	name: string          # project name (used as tmux session group name)
	path?: string         # project path (default: current directory; ignored when --ssh set — path is required for remote)
	--ssh: string         # ssh profile name; when set, registers a remote entry (path is required)
] {
	# Validate --ssh constraints before touching anything.
	# $ssh is `nothing` when flag is absent; a string (possibly "") when provided.
	let ssh_provided = ($ssh | describe) != "nothing"
	if $ssh_provided {
		if ($ssh | str trim | is-empty) {
			error make { msg: "ssh profile name cannot be empty" }
		}
		if ($path | is-empty) {
			error make { msg: "path required when --ssh set" }
		}
	}

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

	let entry = if $ssh_provided {
		{ path: $project_path, ssh: $ssh }
	} else {
		{ path: $project_path }
	}

	$projects = ($projects | insert $name $entry)
	save_data $projects

	if $ssh_provided {
		print $"Project '($name)' registered at ($project_path) [ssh: ($ssh)]"
	} else {
		print $"Project '($name)' registered at ($project_path)"
	}
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
# Local project (no ssh): cd to path, create/attach local tmux session group.
# Remote project (ssh set): delegate entirely to tmux-to-workstation connect; no local cd.
export def --env 'go' [
	name: string@project_names # project to navigate to
] {
	let projects = data

	if not ($name in ($projects | columns)) {
		print $"Project '($name)' does not exist"
		return
	}

	let entry = ($projects | get $name)

	# Guard: path field is mandatory regardless of local/remote
	if 'path' not-in $entry {
		error make { msg: $"invalid project entry: ($name)" }
	}

	let project_path = ($entry | get path)
	let ssh_profile  = ($entry | get -o ssh | default null)

	# --- Remote dispatch (ssh field present) ---
	if $ssh_profile != null {
		# Delegate entirely: tmux-to-workstation owns the thin-session lifecycle.
		# Do NOT cd locally — the path lives on the remote host.
		tmux-to-workstation connect -g $name --cwd $project_path -- $ssh_profile
		return
	}

	# --- Local dispatch (no ssh field) ---
	if not ($project_path | path exists) {
		print $"Project path does not exist: ($project_path)"
		return
	}

	# cd to project directory (local only)
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
