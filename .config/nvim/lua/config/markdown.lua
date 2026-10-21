local workspace = require("config.workspace")
local terminals = require("config.terminals")
local minipairs = require("mini.pairs")

local M = {}
local in_fenced_block

local function current_buf()
  return vim.api.nvim_get_current_buf()
end

local function current_cursor()
  return unpack(vim.api.nvim_win_get_cursor(0))
end

local function current_line()
  return vim.api.nvim_get_current_line()
end

local function anchor_context(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  if vim.bo[bufnr].filetype ~= "markdown" then
    return nil
  end

  local row, col = current_cursor()
  if in_fenced_block(bufnr, row) then
    return nil
  end

  local line = current_line()
  local before = line:sub(1, col)
  local hash_col = before:match(".*()#[-_%wа-яА-ЯёЁ]*$")
  if not hash_col then
    return nil
  end

  local prefix = before:sub(1, hash_col - 1)
  if not prefix:match("%S") then
    return nil
  end

  return {
    row = row,
    col = col,
    line = line,
    hash_col = hash_col,
    base = before:sub(hash_col + 1),
  }
end

local function fence_marker(line)
  if line:match("^%s*```+") then
    return "`"
  end

  if line:match("^%s*~~~+") then
    return "~"
  end
end

in_fenced_block = function(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
  local active

  for _, line in ipairs(lines) do
    local marker = fence_marker(line)
    if marker then
      if active == marker then
        active = nil
      elseif not active then
        active = marker
      end
    end
  end

  return active ~= nil
end

local function slugify_heading(text)
  local slug = vim.trim(vim.fn.tolower(text or ""))
  slug = slug:gsub("[%[%]%(%)%{%}%,%.%!%?%:;\"'`~@#$%%^&*+=|<>/\\]", "")
  slug = slug:gsub("%s+", "-")
  slug = slug:gsub("%-+", "-")
  slug = slug:gsub("^%-+", "")
  slug = slug:gsub("%-+$", "")
  return slug
end

local function add_heading_item(items, seen, heading)
  local base = slugify_heading(heading)
  if base == "" then
    return
  end

  local count = seen[base] or 0
  seen[base] = count + 1

  local slug = count == 0 and base or ("%s-%d"):format(base, count)
  items[#items + 1] = {
    word = slug,
    abbr = slug,
    menu = heading,
  }
end

local function heading_items(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = {}
  local seen = {}
  local active_fence

  for index, line in ipairs(lines) do
    local marker = fence_marker(line)
    if marker then
      if active_fence == marker then
        active_fence = nil
      elseif not active_fence then
        active_fence = marker
      end
    elseif not active_fence then
      local hashes, atx = line:match("^%s*(#+)%s+(.-)%s*$")
      if hashes and atx then
        add_heading_item(items, seen, atx:gsub("%s*#+%s*$", ""))
      else
        local next_line = lines[index + 1]
        if next_line and line:match("%S") then
          if next_line:match("^%s*=+%s*$") or next_line:match("^%s%-+%s*$") then
            add_heading_item(items, seen, vim.trim(line))
          end
        end
      end
    end
  end

  return items
end

local function maybe_expand_fenced_block(bufnr, row)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  if not line then
    return
  end

  local indent = line:match("^(%s*)```$")
  if not indent then
    return
  end

  if in_fenced_block(bufnr, row - 1) then
    return
  end

  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, {
    indent .. "```",
    indent,
    indent .. "```",
  })
  vim.api.nvim_win_set_cursor(0, { row + 1, #indent })
end

local function anchor_completion_items(bufnr, base)
  local lowered = vim.fn.tolower(base or "")
  local items = {}

  for _, item in ipairs(heading_items(bufnr)) do
    if lowered == "" or vim.startswith(item.word, lowered) then
      items[#items + 1] = item
    end
  end

  return items
end

local function show_heading_anchor_completion(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end

  if vim.fn.pumvisible() == 1 then
    return
  end

  local context = anchor_context(bufnr)
  if not context then
    return
  end

  if #anchor_completion_items(bufnr, context.base) == 0 then
    return
  end

  local ok, blink = pcall(require, "blink.cmp")
  if not ok then
    return
  end

  blink.show({
    providers = { "omni" },
  })
end

local function notify_invalid_mdview()
  vim.notify("mdview supports only .md and .markdown files", vim.log.levels.WARN)
end

local function notify_invalid_live_preview()
  vim.notify("live-preview supports only .md and .markdown files", vim.log.levels.WARN)
end

local function current_path()
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
end

local function open_in_current_editor(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.cmd(("hide buffer %d"):format(buf))
end

local function preferred_editor_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[buf].buftype
      local ft = vim.bo[buf].filetype
      if bt ~= "terminal" and ft ~= "neo-tree" and ft ~= "neo-tree-popup" then
        return win
      end
    end
  end
end

local function open_in_editor(path)
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "t" then
    vim.cmd.stopinsert()
  end
  local win = preferred_editor_window()
  if win then
    vim.api.nvim_set_current_win(win)
  end
  open_in_current_editor(path)
end

function M.open_live_preview(path)
  path = vim.fn.fnamemodify(path or "", ":p")
  if not workspace.is_markdown(path) then
    notify_invalid_live_preview()
    return
  end

  vim.api.nvim_cmd({
    cmd = "LivePreview",
    args = { "start", path },
  }, {})
end

function M.open_current_buffer_in_live_preview()
  M.open_live_preview(current_path())
end

function M.open_tree_node_in_live_preview(state)
  local node = state and state.tree and state.tree:get_node() or nil
  if not node or node.type ~= "file" then
    notify_invalid_live_preview()
    return
  end

  M.open_live_preview(node.path)
end

function M.open_mdview(path)
  path = vim.fn.fnamemodify(path or "", ":p")
  if not workspace.is_markdown(path) then
    notify_invalid_mdview()
    return
  end

  vim.fn.jobstart({ "mdview", path }, {
    detach = true,
  })
end

function M.open_current_buffer_in_mdview()
  M.open_mdview(current_path())
end

function M.open_tree_node_in_mdview(state)
  local node = state.tree:get_node()
  if not node or node.type ~= "file" then
    notify_invalid_mdview()
    return
  end

  M.open_mdview(node.path)
end

function M.create_new_prompt(ctx)
  local ok, path = pcall(workspace.create_prompt, ctx)
  if not ok then
    vim.notify("Не удалось создать промпт: " .. tostring(path), vim.log.levels.ERROR)
    return nil
  end
  open_in_editor(path)
  return path
end

function M.open_prompt()
  local ctx = terminals.prompt_context()
  workspace.remember_prompt_context(ctx)
  local path = ctx.path
  if path then
    open_in_editor(path)
    return path
  end

  return M.create_new_prompt(ctx)
end

function M.open_scratch()
  local st = workspace.state()
  local buf = st.scratch_bufnr
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    vim.b[buf].nvim_tab_scratch = true
    st.scratch_bufnr = buf
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "t" then vim.cmd.stopinsert() end
  local win = preferred_editor_window()
  if win then vim.api.nvim_set_current_win(win) end
  vim.cmd("hide buffer " .. buf)
  st.last_file_win = vim.api.nvim_get_current_win()
  return buf
end

function M.send_prompt_buffer()
  local path = current_path()
  if not workspace.is_prompt_markdown(path) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local text = table.concat(lines, "\n")
  return terminals.paste_into_agent(text, {
    path = path,
    context_id = (workspace.context_for_path(path) or {}).id,
    bufnr = current_buf(),
  })
end

function M.handle_heading_anchor_trigger()
  local bufnr = current_buf()

  vim.schedule(function()
    show_heading_anchor_completion(bufnr)
  end)

  return "#"
end

function M.complete_anchor(findstart, base)
  local bufnr = current_buf()
  local context = anchor_context(bufnr)

  if findstart == 1 then
    if not context then
      return -2
    end

    return context.hash_col
  end

  if not context then
    return {}
  end

  return anchor_completion_items(bufnr, base)
end

function M.handle_backtick()
  local bufnr = current_buf()
  local row, col = current_cursor()
  local line = current_line()
  local before = line:sub(1, col)
  local after = line:sub(col + 1)

  if in_fenced_block(bufnr, row) then
    return "`"
  end

  if before:match("^%s*`*$") and after == "" then
    return "`"
  end

  return minipairs.closeopen("``", "^[^\\]")
end

function M.maybe_expand_current_fenced_block(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end

  if vim.bo[bufnr].filetype ~= "markdown" then
    return
  end

  local row = current_cursor()
  maybe_expand_fenced_block(bufnr, row)
end

return M
