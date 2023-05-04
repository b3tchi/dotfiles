local wezterm = require 'wezterm';
local config = {}

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

config.font = wezterm.font('Iosevka Term', {stretch="Expanded", weight="Regular"})
config.enable_tab_bar = false
config.enable_scroll_bar = false
config.window_padding = {
    left = 0,
    right = 0,
    top = 0,
    bottom = 0,
}

config.colors = {
    foreground = "#c0caf5",
    background = "#1a1b26",
    cursor_bg = "#c0caf5",
    cursor_border = "#c0caf5",
    cursor_fg = "#1a1b26",
    selection_bg = "#33467c",
    selection_fg = "#c0caf5",

    ansi = {"#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6" },
    brights = {"#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5" },

}

return config
