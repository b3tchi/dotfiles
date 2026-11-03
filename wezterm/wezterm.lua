local wezterm = require("wezterm")

local config = {
	--FONT
	font = wezterm.font("Iosevka Nerd Font Mono"), -- wsl_domains = wsl_domains,

	--WINDOW CONFIG
	enable_tab_bar = false,
	enable_scroll_bar = false,
	window_padding = {
		left = 0,
		right = 0,
		top = 0,
		bottom = 0,
	},

	--FIX for avoid glitches in terminal
	front_end = "WebGpu",
	webgpu_power_preference = "HighPerformance",

	--COLORSCHEME
	-- color_scheme = "Gruvbox Dark",
	color_scheme = "tokyonight_night",

	--MUX Disabled - testing in wezterm-with-mux
	--moving default shell under tmux
	-- default_prog = { "nu" },
}

if wezterm.target_triple == "x86_64-pc-windows-msvc" then
	-- local domains = wezterm.default_wsl_domains()
	--
	-- for idx, dom in ipairs(domains) do
	-- 	if dom.name == "WSL:arch" then
	-- 		-- dom.default_prog = { "C:\\Users\\jbecka\\scoop\\apps\\git\\2.49.0\\usr\\bin\\bash.exe" }
	-- 		dom.default_prog = "nu"
	-- 		dom.default_cwd = "~"
	-- 	end
	-- end
	--
	-- --FONTS
	-- config.wsl_domains = domains
	-- A new window is Windows PowerShell on the local domain; WSL is reached
	-- through `wsl.exe` ($mod+p's project picker starts it explicitly).
	config.default_prog = { "powershell.exe", "-NoLogo" }

	-- kwi3 (i3kwin-win32) tiles this window (kwi3-wv1u). "RESIZE": no
	-- caption drawn and WS_THICKFRAME kept - WezTerm makes it
	-- WS_OVERLAPPEDWINDOW and folds the caption into the client area
	-- (WM_NCCALCSIZE). "NONE" is a bare WS_POPUP, which the host types
	-- `utility` and never tiles. The host still sees WS_CAPTION in the
	-- style and draws its own titlebar above it until kwi3-i0fg.
	config.window_decorations = "RESIZE"
	-- kwi3 owns the window's size: a font zoom changes the cell, never the
	-- window.
	config.adjust_window_size_when_changing_font_size = false
	-- Closing the window (or kwi3 closing it) never asks for confirmation.
	config.window_close_confirmation = "NeverPrompt"

	-- Windows has IosevkaTerm Nerd Font (scoop nerd-fonts/IosevkaTerm-NF),
	-- not the Iosevka Nerd Font Mono above, which WezTerm reports as a
	-- configuration error and replaces with a fallback.
	config.font = wezterm.font("IosevkaTerm Nerd Font")

	-- Font and a cell of exactly kwi3's module, generated from kwi3's
	-- config.js by wezterm/install-kwi3-cell.sh (dotfiles). Absent: the font
	-- above and WezTerm's own cell.
	for _, dir in ipairs({ wezterm.config_dir, wezterm.home_dir .. "/.config/wezterm" }) do
		local path = dir .. "/kwi3-cell.lua"
		local ok, cell = pcall(dofile, path)
		if ok and type(cell) == "table" then
			wezterm.add_to_config_reload_watch_list(path)
			config.font = wezterm.font(cell.font_family)
			config.font_size = cell.font_size
			config.cell_width = cell.cell_width
			config.line_height = cell.line_height
			break
		end
	end
end

return config
