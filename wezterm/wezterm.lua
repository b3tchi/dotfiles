local wezterm = require 'wezterm';

local wsl_domains
local default_domain
local font_dirs
local font_locator
local font

if wezterm.target_triple == "x86_64-pc-windows-msvc" then

    wsl_domains = wezterm.default_wsl_domains()

    wsl_domains = {
        {
            name = 'WSL:Ubuntu-20.04',
            distribution = 'Ubuntu-20.04',
            -- username = "hunter", -- If omitted, the default user for that distribution will be used.
            default_cwd = "~",
            -- default_prog = {"zsh"},
        },
    }

    default_domain = "WSL:Ubuntu-20.04"

        --FONTS
    font_dirs = {"fonts"}
    font_locator = "ConfigDirsOnly"
    font = wezterm.font("Iosevka Nerd Font Mono")
else
    font_dirs = {}
    font_locator = ""

end

return {

    --WSL
    default_domain = default_domain,
    wsl_domains = wsl_domains,

    --WINDOW CONFIG
    enable_tab_bar = false,
    enable_scroll_bar = false,
    window_padding = {
        left = 0,
        right = 0,
        top = 0,
        bottom = 0,
    },

    --FONT
    font_dirs = font_dirs,
    font_locator = font_locator,
    font = font,

    --COLORSCHEME
    --color_scheme = "Gruvbox Dark",
    color_scheme = "tokionight",

    --KEYS
    keys = {
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

}
