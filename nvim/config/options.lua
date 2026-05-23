-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
local opt = vim.opt

--remove semi transparent completion window
opt.pumblend = 0

--intednt tab to 4
vim.o.tabstop = 4
vim.o.shiftwidth = 4
vim.o.expandtab = false

-- Clipboard provider — picks based on what's actually available, so the same
-- config works on WSL/Sway (Wayland), Manjaro/i3 (X11), and Termux:X11.
-- WSL note: SSH sessions strip WAYLAND_DISPLAY/XDG_RUNTIME_DIR but the socket
-- at /run/user/$UID/wayland-0 is still reachable, so we detect by socket and
-- inject env when calling wl-copy/wl-paste. The Wayland↔Win sync daemons
-- (see sway/scripts/clipboard-to-win.nu) handle propagation to Windows.
local uid = tostring(vim.uv.getuid())
local wl_sock = "/run/user/" .. uid .. "/wayland-0"
local has_wayland_env = (os.getenv("WAYLAND_DISPLAY") ~= nil)
local has_wayland = (vim.uv.fs_stat(wl_sock) ~= nil) or has_wayland_env

-- Only override clipboard provider when WAYLAND_DISPLAY is missing (SSH session
-- on a Wayland host). With env present, nvim's built-in auto-detection picks
-- the right socket — forcing wayland-0 here would hit the WSLg compositor
-- instead of the active sway/Hyprland one (different clipboards).
if not has_wayland_env and has_wayland and vim.fn.executable("wl-copy") == 1 then
	local env_prefix = {
		"env",
		"WAYLAND_DISPLAY=wayland-0",
		"XDG_RUNTIME_DIR=/run/user/" .. uid,
	}
	local function with_env(cmd)
		local out = {}
		for _, v in ipairs(env_prefix) do table.insert(out, v) end
		for _, v in ipairs(cmd) do table.insert(out, v) end
		return out
	end
	vim.g.clipboard = {
		name = "WaylandSSH",
		copy = {
			["+"] = with_env({ "wl-copy" }),
			["*"] = with_env({ "wl-copy", "--primary" }),
		},
		paste = {
			["+"] = with_env({ "wl-paste", "--no-newline" }),
			["*"] = with_env({ "wl-paste", "--no-newline", "--primary" }),
		},
		cache_enabled = 1,
	}
elseif vim.fn.executable("xclip") == 1 then
	vim.g.clipboard = {
		name = "xclip-x11",
		copy = {
			["+"] = { "xclip", "-selection", "clipboard", "-i" },
			["*"] = { "xclip", "-selection", "primary", "-i" },
		},
		paste = {
			["+"] = { "xclip", "-selection", "clipboard", "-o" },
			["*"] = { "xclip", "-selection", "primary", "-o" },
		},
		cache_enabled = 0,
	}
end
-- LazyVim sets clipboard="" when SSH_CONNECTION is set (it expects OSC 52).
-- We have a working provider above (where supported), so re-enable unnamedplus
-- so plain y/p reach the + register instead of dying in the unnamed register.
vim.opt.clipboard = "unnamedplus"
-- --
-- path to the Nushell executable
vim.opt.sh = "nu"

-- WARN: disable the usage of temp files for shell commands
-- because Nu doesn't support `input redirection` which Neovim uses to send buffer content to a command:
--      `{shell_command} < {temp_file_with_selected_buffer_content}`
-- When set to `false` the stdin pipe will be used instead.
-- NOTE: some info about `shelltemp`: https://github.com/neovim/neovim/issues/1008
vim.opt.shelltemp = false

-- string to be used to put the output of shell commands in a temp file
-- 1. when 'shelltemp' is `true`
-- 2. in the `diff-mode` (`nvim -d file1 file2`) when `diffopt` is set
--    to use an external diff command: `set diffopt-=internal`
vim.opt.shellredir = "out+err> %s"

-- flags for nu:
-- * `--stdin`       redirect all input to -c
-- * `--no-newline`  do not append `\n` to stdout
-- * `--commands -c` execute a command
vim.opt.shellcmdflag = "--stdin --no-newline -c"

-- disable all escaping and quoting
vim.opt.shellxescape = ""
vim.opt.shellxquote = ""
vim.opt.shellquote = ""

-- string to be used with `:make` command to:
-- 1. save the stderr of `makeprg` in the temp file which Neovim reads using `errorformat` to populate the `quickfix` buffer
-- 2. show the stdout, stderr and the return_code on the screen
-- NOTE: `ansi strip` removes all ansi coloring from nushell errors
vim.opt.shellpipe =
	"| complete | update stderr { ansi strip } | tee { get stderr | save --force --raw %s } | into record"

--WINDOWS PYTHON WORKAROUND
if vim.fn.has("win32") then
	-- vim.g.loaded_python_provider = 1 -- not needed to install
	-- vim.g.python3_host_prog = vim.fn.getenv("USERPROFILE")
	vim.g.python3_host_prog = "C:\\Users\\jbecka" .. "\\AppData\\Local\\Programs\\Python\\Python313\\python.exe"
end
