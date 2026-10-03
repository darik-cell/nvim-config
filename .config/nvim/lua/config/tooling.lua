local M = {}

M.treesitter = {
  "bash",
  "css",
  "diff",
  "html",
  "javascript",
  "json",
  "json5",
  "lua",
  "markdown",
  "markdown_inline",
  "query",
  "toml",
  "typescript",
  "vim",
  "vimdoc",
  "yaml",
}

M.lsp = {
  bashls = {
    mason = "bash-language-server",
  },
  cssls = {
    mason = "css-lsp",
  },
  html = {
    mason = "html-lsp",
  },
  jsonls = {
    mason = "json-lsp",
  },
  lua_ls = {
    mason = "lua-language-server",
    config = {
      settings = {
        Lua = {
          completion = {
            callSnippet = "Replace",
          },
          diagnostics = {
            globals = { "vim" },
          },
        },
      },
    },
  },
  taplo = {
    mason = "taplo",
  },
  yamlls = {
    mason = "yaml-language-server",
  },
}

local function sorted_keys(values)
  local keys = vim.tbl_keys(values)
  table.sort(keys)
  return keys
end

function M.lsp_names()
  return sorted_keys(M.lsp)
end

function M.mason_packages()
  local packages = {}
  for _, name in ipairs(M.lsp_names()) do
    packages[#packages + 1] = M.lsp[name].mason
  end
  return packages
end

function M.lsp_config(name)
  local spec = assert(M.lsp[name], ("Unknown LSP server: %s"):format(name))
  return vim.deepcopy(spec.config or {})
end

function M.install_treesitter(opts)
  opts = opts or {}

  local install_opts = vim.deepcopy(opts.install_opts or {})
  local task = require("nvim-treesitter").install(M.treesitter, install_opts)
  if opts.wait then
    return task:wait(opts.timeout or 600000)
  end

  return task
end

return M
