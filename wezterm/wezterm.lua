local wezterm = require 'wezterm';

if wezterm.target_triple == "x86_64-pc-windows-msvc" then
  print("windows")
else
  print("linux")
end

return {
  font = wezterm.font('Iosevka Term', {stretch="Expanded", weight="Regular"}),
  enable_tab_bar = false,
  enable_scroll_bar = false,
  window_padding = {
    left = 0,
    right = 0,
    top = 0,
    bottom = 0,
  }
}

