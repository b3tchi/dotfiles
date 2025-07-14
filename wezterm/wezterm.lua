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
	--using tmux
	-- default_prog = { "nu" },
}

if wezterm.target_triple == "x86_64-pc-windows-msvc" then
	local wsl_domains = wezterm.default_wsl_domains()

	for idx, dom in ipairs(wsl_domains) do
		if dom.name == "WSL:arch" then
			-- dom.default_prog = { "C:\\Users\\jbecka\\scoop\\apps\\git\\2.49.0\\usr\\bin\\bash.exe" }
			dom.default_prog = "nu"
			dom.default_cwd = "~"
		end
	end

	--FONTS
	config.wsl_domains = wsl_domains
	config.default_domain = "WSL:arch"
end

return config
