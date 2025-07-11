local wezterm = require("wezterm")
local mux = wezterm.mux

local wsl_domains
local default_domain
local font_dirs
local font_locator
local font

if wezterm.target_triple == "x86_64-pc-windows-msvc" then
	wsl_domains = wezterm.default_wsl_domains()

	--    wsl_domains = {
	--        {
	--            name = 'wsl',
	--            distribution = 'Ubuntu-20.04',
	--            default_cwd = "~",
	--        }
	--    }

	for idx, dom in ipairs(wsl_domains) do
		if dom.name == "WSL:arch" then
			-- dom.default_prog = { "C:\\Users\\jbecka\\scoop\\apps\\git\\2.49.0\\usr\\bin\\bash.exe" }
			dom.default_prog = "nu"
			dom.default_cwd = "~"
		end
	end

	-- default_domain = "local" --windows

	--FONTS
	-- font_dirs = { "fonts" }
	-- else
	-- font_dirs = {}
	-- font_locator = ""
end

-- font_dirs = {}
-- font_locator = ""
font = wezterm.font("Iosevka Nerd Font Mono")
-- wezterm.on('gui-startup', function(cmd)

--     local args = {}
--     if cmd then
--       args = cmd.args
--     end

--     -- Set a workspace for coding on a current project
--     -- Top pane is for the editor, bottom pane is for the build tool
--     -- local project_dir = wezterm.home_dir .. '/wezterm'
--     local tab, build_pane, window = mux.spawn_window {
--       workspace = 'default',
--     --   cwd = project_dir,
--       args = args,
--     }

-- --   local tab, pane, window = mux.spawn_window(cmd or {})
--   -- Create a split occupying the right 1/3 of the screen
--   --pane:split { size = 0.3 }
--   -- Create another split in the right of the remaining 2/3
--   -- of the space; the resultant split is in the middle
--   -- 1/3 of the display and has the focus.
--   print('ongui')
--   --pane:split { size = 0.5 }
-- end)

return {
	--WSL
	-- default_domain = default_domain,
	-- wsl_domains = wsl_domains,

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

	--FONT
	-- font_dirs = font_dirs,
	-- font_locator = font_locator,
	font = font,

	--COLORSCHEME
	-- color_scheme = "Gruvbox Dark",
	color_scheme = "tokyonight_night",

	default_domain = "WSL:arch",

	--MUX Testing
	-- exit_behavior= "Hold",
	-- default_prog = { 'nu' }
	default_prog = { "nu" },
	--KEYS
	--[[keys = {
        {
            key = 'c',
            mods = 'CTRL',
            action = wezterm.action_callback(function(window, pane)
                if pane:is_alt_screen_active() then
                    window:perform_action(wezterm.action.SendKey{ key='c', mods='CTRL' }, pane)
                else
                    window:perform_action(wezterm.action{ CopyTo = 'ClipboardAndPrimarySelection' }, pane)
                end
            end),
        },
        { key = 'v', mods = 'CTRL', action = wezterm.action{ PasteFrom = 'Clipboard' } },
    },
    ]]
}
