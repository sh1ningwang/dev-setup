local wezterm = require("wezterm")

local config = wezterm.config_builder()

-- Font
config.font = wezterm.font("JetBrainsMono Nerd Font")
config.font_size = 12.0

-- Color scheme (built-in)
config.color_scheme = "Catppuccin Latte"

-- WSL: default to WSL shell on Windows, otherwise use bash
if wezterm.target_triple == "x86_64-pc-windows-msvc" then
  config.default_domain = "WSL:Ubuntu"
else
  config.default_prog = { "/bin/bash", "-l" }
end

-- Right-click to paste
config.mouse_bindings = {
  {
    event = { Down = { streak = 1, button = "Right" } },
    mods = "NONE",
    action = wezterm.action.PasteFrom("Clipboard"),
  },
}

-- Hide tab bar when only one tab is open
config.hide_tab_bar_if_only_one_tab = true

-- Window
config.window_padding = {
  left = 8,
  right = 8,
  top = 8,
  bottom = 8,
}

return config
