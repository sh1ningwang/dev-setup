return {
  -- Catppuccin colorscheme
  {
    "catppuccin/nvim",
    name = "catppuccin",
    lazy = false,
    priority = 1000,
    opts = {
      flavour = "latte",
      integrations = {
        mini = { enabled = true },
      },
    },
  },

  -- Set Catppuccin as the LazyVim colorscheme
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "catppuccin",
    },
  },

  -- Disable tokyonight (installed by LazyVim but unused)
  { "folke/tokyonight.nvim", enabled = false },
}
