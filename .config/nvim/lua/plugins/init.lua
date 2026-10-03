return {
  {
    "folke/lazydev.nvim",
    ft = "lua",
    opts = {},
  },
  {
    "xiantang/darcula-dark.nvim",
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("darcula-dark")
    end,
  },
  {
    "nvim-tree/nvim-web-devicons",
    lazy = true,
  },
  {
    "nvim-lualine/lualine.nvim",
    dependencies = {
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      require("lualine").setup({
        options = {
          theme = "auto",
          globalstatus = true,
          section_separators = { left = "", right = "" },
          component_separators = { left = "|", right = "|" },
        },
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", "diff", "diagnostics" },
          lualine_c = {
            {
              "filename",
              path = 1,
            },
          },
          lualine_x = { "encoding", "filetype" },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
      })
    end,
  },
  {
    "echasnovski/mini.pairs",
    version = false,
    config = function()
      require("mini.pairs").setup()
    end,
  },
  {
    "ibhagwan/fzf-lua",
    dependencies = {
      "nvim-tree/nvim-web-devicons",
    },
    opts = {
      "default-title",
      winopts = {
        height = 0.95,
        width = 0.95,
        border = "rounded",
        preview = {
          border = "rounded",
          layout = "flex",
        },
      },
      oldfiles = {
        cwd_only = true,
      },
      fzf_colors = true,
    },
  },
  {
    "brianhuster/live-preview.nvim",
    cmd = "LivePreview",
    config = function()
      require("config.live_preview").setup({
        dynamic_root = true,
      })
    end,
  },
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      local tree = require("config.tree")
      local events = require("neo-tree.events")
      local fs_source = require("neo-tree.sources.filesystem")
      local renderer = require("neo-tree.ui.renderer")
      local utils = require("neo-tree.utils")

      require("neo-tree").setup({
        close_if_last_window = false,
        open_files_in_last_window = false,
        popup_border_style = "rounded",
        enable_git_status = true,
        enable_diagnostics = true,
        window = {
          position = "float",
          popup = {
            size = {
              height = "80%",
              width = "65%",
            },
            position = "50%",
          },
          mappings = {
            ["<leader>m"] = function(state)
              require("config.markdown").open_tree_node_in_live_preview(state)
            end,
            ["<leader>M"] = function(state)
              require("config.markdown").open_tree_node_in_mdview(state)
            end,
          },
        },
        filesystem = {
          bind_to_cwd = false,
          window = {
            mappings = {
              ["<CR>"] = tree.open_selected,
              ["o"] = { tree.open_selected, nowait = true },
              ["z"] = "none",
              ["zz"] = function()
                tree.scroll("zz")
              end,
              ["z."] = function()
                tree.scroll("z.")
              end,
              ["z<cr>"] = function()
                tree.scroll("z<CR>")
              end,
              ["я<cr>"] = function()
                tree.scroll("z<CR>")
              end,
              ["x"] = "close_node",
              ["ч"] = "close_node",
              ["X"] = "cut_to_clipboard",
              ["Ч"] = "cut_to_clipboard",
              ["p"] = tree.focus_parent,
              ["з"] = tree.focus_parent,
              ["<leader>p"] = "paste_from_clipboard",
              ["."] = tree.set_root_and_tcd,
              ["<leader>cp"] = tree.copy_selected_path,
              ["oc"] = "none",
              ["od"] = "none",
              ["og"] = "none",
              ["om"] = "none",
              ["on"] = "none",
              ["os"] = "none",
              ["ot"] = "none",
              ["/"] = "none",
              ["g/"] = "fuzzy_finder",
            },
            fuzzy_finder_mappings = {
              ["<C-j>"] = tree.fuzzy_next_match,
              ["<C-k>"] = tree.fuzzy_prev_match,
            },
          },
          follow_current_file = {
            enabled = true,
          },
          filtered_items = {
            hide_dotfiles = false,
            hide_gitignored = false,
          },
        },
      })

      local original_reset_search = fs_source.reset_search
      fs_source.reset_search = function(state, refresh, open_current_node)
        if not open_current_node then
          return original_reset_search(state, refresh, open_current_node)
        end

        require("neo-tree.sources.filesystem.lib.filter_external").cancel()
        state.fuzzy_finder_mode = nil
        state.use_fzy = nil
        state.fzy_sort_result_scores = nil
        state.sort_function_override = nil

        if refresh == nil then
          refresh = true
        end
        if state.open_folders_before_search then
          state.force_open_folders = vim.deepcopy(state.open_folders_before_search)
        else
          state.force_open_folders = nil
        end
        state.search_pattern = nil
        state.open_folders_before_search = nil

        local success, node = pcall(state.tree.get_node, state.tree)
        if not (success and node) then
          if refresh then
            require("neo-tree.sources.manager").refresh("filesystem")
          end
          return
        end

        local path = node:get_id()
        renderer.position.set(state, path)
        if node.type == "directory" then
          path = utils.remove_trailing_slash(path)
          fs_source.navigate(state, nil, path, function()
            pcall(renderer.focus_node, state, path, false)
          end)
        else
          tree.open_path(path)
          if refresh and state.current_position ~= "current" and state.current_position ~= "float" then
            fs_source.navigate(state, nil, path)
          end
        end

        if refresh then
          require("neo-tree.sources.manager").refresh("filesystem")
        end
      end

      local fuzzy_highlight_event = {
        event = events.AFTER_RENDER,
        id = "nvim-alt.neo-tree.fuzzy-highlight",
        handler = function(state)
          tree.highlight_fuzzy_matches(state)
        end,
      }
      pcall(events.unsubscribe, fuzzy_highlight_event)
      events.subscribe(fuzzy_highlight_event)
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      local tooling = require("config.tooling")

      require("nvim-treesitter").setup({})
      tooling.install_treesitter()
    end,
  },
  {
    "mason-org/mason.nvim",
    config = function()
      require("mason").setup()
    end,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    dependencies = {
      "mason-org/mason.nvim",
      "neovim/nvim-lspconfig",
    },
    config = function()
      local tooling = require("config.tooling")

      require("mason-lspconfig").setup({
        ensure_installed = tooling.lsp_names(),
        automatic_enable = false,
      })
    end,
  },
  {
    "L3MON4D3/LuaSnip",
    dependencies = {
      "rafamadriz/friendly-snippets",
    },
    config = function()
      require("luasnip.loaders.from_vscode").lazy_load()
    end,
  },
  {
    "Saghen/blink.cmp",
    version = "*",
    dependencies = {
      "L3MON4D3/LuaSnip",
    },
    opts = {
      keymap = {
        preset = "default",
        ["<C-j>"] = { "select_next", "fallback_to_mappings" },
        ["<C-k>"] = { "select_prev", "fallback_to_mappings" },
        ["<CR>"] = { "fallback" },
        ["<Tab>"] = { "select_and_accept", "snippet_forward", "fallback" },
      },
      completion = {
        documentation = {
          auto_show = true,
        },
        menu = {
          border = "rounded",
        },
      },
      snippets = {
        preset = "luasnip",
      },
      sources = {
        default = { "lsp", "path", "snippets", "buffer" },
        per_filetype = {
          markdown = { inherit_defaults = true, "omni" },
        },
      },
    },
  },
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "mason-org/mason-lspconfig.nvim",
      "Saghen/blink.cmp",
    },
    config = function()
      local capabilities = require("blink.cmp").get_lsp_capabilities()
      local tooling = require("config.tooling")

      for _, server in ipairs(tooling.lsp_names()) do
        local config = tooling.lsp_config(server)
        config.capabilities = capabilities
        vim.lsp.config(server, config)
        vim.lsp.enable(server)
      end
    end,
  },
}
