local workspace = require("config.workspace")
local attention = require("config.attention")

local M = {}

function M.render()
  local parts = {}
  local current = vim.api.nvim_get_current_tabpage()

  for index, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    local digit = index == 10 and 0 or index
    local label = ("%d %s"):format(digit, workspace.tab_title(tabpage))
    local hl = tabpage == current and "%#TabLineSel#" or "%#TabLine#"
    local status = attention.status(tabpage)
    local mark = ""
    if status == "ready" then
      mark = "%#TabLineReady# ✓" .. hl
    elseif status == "question" then
      mark = "%#TabLineQuestion# ?" .. hl
    end
    parts[#parts + 1] = ("%%%dT%s %s%s "):format(index, hl, label:gsub("%%", "%%%%"), mark)
  end

  parts[#parts + 1] = "%#TabLineFill#%T"
  return table.concat(parts)
end

function M.setup()
  vim.opt.tabline = "%!v:lua.require'config.tabline'.render()"
end

return M
