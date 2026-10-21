return {
  {
    "folke/flash.nvim",
    lazy = true,
    opts = {
      search = { multi_window = true },
      modes = {
        char = { enabled = false },
        search = { enabled = false },
      },
    },
    config = function(_, opts)
      require("flash").setup(opts)
      require("config.ace_jump").setup()
    end,
    keys = {
      {
        "<leader>f",
        function()
          require("config.ace_jump").jump()
        end,
        mode = "n",
        nowait = true,
        desc = "Jump across visible windows",
      },
      {
        "<leader>а",
        function()
          require("config.ace_jump").jump()
        end,
        mode = "n",
        nowait = true,
        desc = "Jump across visible windows",
      },
    },
  },
}
