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

  -- Icon highlight overrides via Catppuccin integration
  {
    "nvim-tree/nvim-web-devicons",
    opts = function(_, opts)
      opts.color_icons = true
    end,
  },
}
