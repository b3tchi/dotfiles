# Nushell Environment Config File
#
# version = 0.82.1

# def create_left_prompt [] {
#     mut home = ""
#     try {
#         if $nu.os-info.name == "windows" {
#             $home = $env.USERPROFILE
#         } else {
#             $home = $env.HOME
#         }
#     }

#     let dir = ([
#         ($env.PWD | str substring 0..($home | str length) | str replace $home "~"),
#         ($env.PWD | str substring ($home | str length)..)
#     ] | str join)

#     let path_color = (if (is-admin) { ansi red_bold } else { ansi green_bold })
#     let separator_color = (if (is-admin) { ansi light_red_bold } else { ansi light_green_bold })
#     let path_segment = $"($path_color)($dir)"

#     $path_segment | str replace --all (char path_sep) $"($separator_color)/($path_color)"
# }

# def create_right_prompt [] {
#     # create a right prompt in magenta with green separators and am/pm underlined
#     let time_segment = ([
#         (ansi reset)
#         (ansi magenta)
#         (date now | date format '%Y/%m/%d %r')
#     ] | str join | str replace --all "([/:])" $"(ansi green)${1}(ansi magenta)" |
#         str replace --all "([AP]M)" $"(ansi magenta_underline)${1}")

#     let last_exit_code = if ($env.LAST_EXIT_CODE != 0) {([
#         (ansi rb)
#         ($env.LAST_EXIT_CODE)
#     ] | str join)
#     } else { "" }

#     ([$last_exit_code, (char space), $time_segment] | str join)
# }

# # Use nushell functions to define your right and left prompt
# $env.PROMPT_COMMAND = {|| create_left_prompt }
# # $env.PROMPT_COMMAND_RIGHT = {|| create_right_prompt }
$env.EDITOR = 'nvim'
#
# The prompt indicators are environmental variables that represent
# the state of the prompt
$env.PROMPT_INDICATOR = {|| " > " }
$env.PROMPT_INDICATOR_VI_INSERT = {|| " : " }
$env.PROMPT_INDICATOR_VI_NORMAL = {|| " > " }
$env.PROMPT_MULTILINE_INDICATOR = {|| "::: " }

# Specifies how environment variables are:
# - converted from a string to a value on Nushell startup (from_string)
# - converted from a value back to a string when running external commands (to_string)
# Note: The conversions happen *after* config.nu is loaded
$env.ENV_CONVERSIONS = {
    "PATH": {
        from_string: { |s| $s | split row (char esep) | path expand --no-symlink }
        to_string: { |v| $v | path expand --no-symlink | str join (char esep) }
    }
    "Path": {
        from_string: { |s| $s | split row (char esep) | path expand --no-symlink }
        to_string: { |v| $v | path expand --no-symlink | str join (char esep) }
    }
}

$env.TEMP = $nu.temp-dir
$env.PATH = ($env.PATH | split row (char esep) | prepend ($env.HOME | path join '.local' 'bin') | uniq )
#filter out native paths
if $nu.os-info.kernel_version =~ 'microsoft-standard-WSL' {
	# prune inherited /mnt/c noise, then append the Windows paths we want —
	# append (not filter) so they exist even when the session was spawned
	# without Windows PATH injection (tmux server, sway/WSLg, ssh).
	# System32 is NOT added directly (4000+ files pollute completions) —
	# curated symlinks live in ~/.local/bin/win (wsl/cmd/explorer/clip/
	# notepad/powershell), add more with: ln -s /mnt/c/... ~/.local/bin/win/
	let win_path = [
		($env.HOME | path join '.local' 'bin' 'win')
		'/mnt/c/Users/jbecka/scoop/shims'
		'/mnt/c/Users/jbecka/scoop/apps/vscode/current/bin'
	]
	$env.PATH = ($env.PATH | split row (char esep)
		| where $it !~ '/mnt/c'
		| append $win_path
		| uniq
		)

    # Prepend ~/.local/bin so custom xdg-open wrapper is found first
    # Set browser for CLI tools (pac, dotnet, etc.)
    $env.BROWSER = '/home/jan/.local/bin/xdg-open'
}

# fnm — per-project Node version manager (binary in ~/.local/bin).
# Loads the per-session multishell; no `fnm default` is set, so fresh shells
# fall through to system node (pacman). The PWD hook in config.nu switches to
# the pinned version in dirs that carry .node-version / .nvmrc.
let fnm_bin = ($env.HOME | path join '.local' 'bin' 'fnm')
if ($fnm_bin | path exists) {
	# Absolute path: `which` can't resolve during env.nu eval (PATH not yet list-form).
	# Direct $env assignment: load-env does not persist from env.nu's eval context.
	let fnm_env = (^$fnm_bin env --json | from json)
	$env.FNM_MULTISHELL_PATH = $fnm_env.FNM_MULTISHELL_PATH
	$env.FNM_DIR = $fnm_env.FNM_DIR
	$env.FNM_ARCH = $fnm_env.FNM_ARCH
	$env.FNM_NODE_DIST_MIRROR = $fnm_env.FNM_NODE_DIST_MIRROR
	$env.FNM_VERSION_FILE_STRATEGY = $fnm_env.FNM_VERSION_FILE_STRATEGY
	$env.FNM_RESOLVE_ENGINES = $fnm_env.FNM_RESOLVE_ENGINES
	$env.FNM_LOGLEVEL = $fnm_env.FNM_LOGLEVEL
	$env.FNM_COREPACK_ENABLED = $fnm_env.FNM_COREPACK_ENABLED
	$env.PATH = ($env.PATH | split row (char esep) | prepend ($fnm_env.FNM_MULTISHELL_PATH | path join 'bin') | uniq)
}

# Directories to search for scripts when calling source or use
$env.NU_LIB_DIRS = [
    ($nu.default-config-dir | path join 'apps')
    ($nu.default-config-dir | path join 'scripts') 
]


# Directories to search for plugin binaries when calling register
$env.NU_PLUGIN_DIRS = [
	($nu.current-exe | path dirname)	
]
 #   # ($nu.default-config-dir | path join 'plugins') # add <nushell-config-dir>/plugins

# To add entries to PATH (on Windows you might use Path), you can use the following pattern:
# $env.PATH = ($env.PATH | split row (char esep) | prepend '/some/path')
if $nu.os-info.name != "windows" {
	$env.GPG_TTY = (tty)
}

# Claude Code - fullscreen rendering to reduce flicker and memory usage
$env.CLAUDE_CODE_NO_FLICKER = '1'
$env.CLAUDE_CODE_SCROLL_SPEED = '3'

# Yazi - force sixel image preview under foot (foot has no kitty graphics protocol)
if ($env.TERM? | default '') =~ 'foot' {
	$env.YAZI_IMAGE_PROTOCOL = 'sixel'
}

# bd (beads) - shared dolt sql-server across all repos (one server, port 3308)
# instead of the default per-repo random-port server. State: ~/.beads/shared-server/
$env.BEADS_DOLT_SERVER_MODE = '1'
$env.BEADS_DOLT_SHARED_SERVER = '1'

# gopass age auto-unlock from passphrase file
let gopass_pw_file = if $nu.os-info.kernel_version =~ 'microsoft-standard-WSL' {
	'/mnt/c/Users/jbecka/.gopass-age-password'
} else {
	$'($env.HOME)/.gopass-age-password'
}
if ($gopass_pw_file | path exists) {
	$env.GOPASS_AGE_PASSWORD = (open $gopass_pw_file | str trim)
}

# carapace
$env.CARAPACE_BRIDGES = 'zsh,fish,bash,inshellisense' # optional
mkdir ~/.cache/carapace
carapace _carapace nushell | str replace --all 'get -i' 'get -o'   | save --force ~/.cache/carapace/init.nu
