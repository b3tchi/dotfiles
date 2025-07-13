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

if vim.fn.has("wsl") == 1 then
	vim.g.clipboard = {
		name = "WslClipboard",
		copy = {
			["+"] = "/mnt/c/Windows/System32/clip.exe",
			["*"] = "/mnt/c/Windows/System32/clip.exe",

			-- ["+"] = "clip.exe",
			-- ["*"] = "clip.exe",
		},
		paste = {
			["+"] = 'powershell.exe -c [Console]::Out.Write($(Get-Clipboard -Raw).tostring().replace("`r", ""))',
			["*"] = 'powershell.exe -c [Console]::Out.Write($(Get-Clipboard -Raw).tostring().replace("`r", ""))',
		},
		cache_enabled = 0,
	}
end
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
