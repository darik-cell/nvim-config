local workspace = require("config.workspace")
local terminals = require("config.terminals")
local terminal_view = require("config.terminal_view")
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
  vim.notify("Предпросмотр поддерживает файлы .md, .markdown и .html", vim.log.levels.WARN)
end

local function current_path()
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
end

local function open_in_current_editor(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.cmd(("hide buffer %d"):format(buf))
end

local function preferred_editor_window(path)
  local fallback
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[buf].buftype
      local ft = vim.bo[buf].filetype
      if bt ~= "terminal" and ft ~= "neo-tree" and ft ~= "neo-tree-popup" then
        if path and vim.api.nvim_buf_get_name(buf) == path then
          return win
        end
        fallback = fallback or win
      end
    end
  end
  return fallback
end

function M.open_live_preview(path)
  path = vim.fn.fnamemodify(path or "", ":p")
  if not workspace.is_markdown(path) and not path:match("%.html$") then
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

local function save_prompt_buffer(buf)
  vim.api.nvim_buf_call(buf, function()
    if vim.bo.modified or not vim.uv.fs_stat(current_path()) then
      vim.cmd("silent write")
    end
  end)
end

local function prompt_window(ctx)
  local current = vim.api.nvim_get_current_win()
  local function matches(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.api.nvim_win_get_config(win).relative == ""
      and workspace.context_for_path(vim.api.nvim_buf_get_name(buf)) == ctx
  end
  if matches(current) then return current end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if matches(win) then return win end
  end
end

local function terminal_window(ctx)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == ""
      and vim.api.nvim_win_get_buf(win) == ctx.terminal_bufnr then
      return win
    end
  end
end

local function save_terminal_view(ctx)
  local win = terminal_window(ctx)
  if not win then return nil end
  if vim.api.nvim_get_current_win() == win then
    ctx.prompt_terminal_input = vim.api.nvim_get_mode().mode:sub(1, 1) == "t"
  end
  return terminal_view.capture(ctx, win)
end

local function restore_terminal_view(ctx, saved)
  terminal_view.restore(ctx, saved)
end

function M.remember_terminal_mode()
  if vim.bo.buftype ~= "terminal" then return end
  local ctx = workspace.context_for_terminal(current_buf())
  if ctx then
    ctx.prompt_terminal_input = vim.api.nvim_get_mode().mode:sub(1, 1) == "t"
  end
end

local function focus_window(win, terminal_input)
  vim.cmd.stopinsert()
  vim.api.nvim_set_current_win(win)
  local tab = vim.api.nvim_get_current_tabpage()
  vim.schedule(function()
    if vim.api.nvim_get_current_tabpage() ~= tab or vim.api.nvim_get_current_win() ~= win then return end
    if terminal_input then vim.cmd.startinsert() else vim.cmd.stopinsert() end
  end)
end

local function show_prompt(path, ctx)
  local saved = save_terminal_view(ctx)
  local win = prompt_window(ctx)
  if win then
    focus_window(win, false)
  else
    local source = terminal_window(ctx)
    if source then
      focus_window(source, false)
    elseif ctx.terminal_bufnr and vim.api.nvim_buf_is_valid(ctx.terminal_bufnr) then
      vim.cmd("leftabove vsplit")
      vim.api.nvim_win_set_buf(0, ctx.terminal_bufnr)
    else
      vim.notify("Терминал черновика недоступен", vim.log.levels.WARN)
      return nil
    end
    vim.cmd("wincmd H")
    vim.cmd("rightbelow vsplit")
  end
  open_in_current_editor(path)
  vim.bo.bufhidden = "hide"
  focus_window(vim.api.nvim_get_current_win(), false)
  if saved then ctx.prompt_terminal_input = saved.input end
  restore_terminal_view(ctx, saved)
  return path
end

local function hide_prompt(ctx, win, buf, force_input)
  local saved = save_terminal_view(ctx)
  buf = buf or vim.api.nvim_win_get_buf(win)
  local ok, err = pcall(save_prompt_buffer, buf)
  if not ok then
    vim.notify("Не удалось сохранить черновик: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  local terminal = ctx.terminal_bufnr
  if not terminal or not vim.api.nvim_buf_is_valid(terminal)
    or vim.b[terminal].terminal_job_id ~= ctx.job_id
    or not ctx.job_id or vim.fn.jobwait({ ctx.job_id }, 0)[1] ~= -1 then
    vim.notify("Терминал черновика не запущен", vim.log.levels.WARN)
    return false
  end
  local source = terminal_window(ctx)
  if not source then
    vim.api.nvim_win_set_buf(win, terminal)
    source = win
  end
  local terminal_input = force_input or ctx.prompt_terminal_input == true
  focus_window(source, terminal_input)
  if win ~= source and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    vim.api.nvim_win_close(win, false)
  end
  if not terminal_input then restore_terminal_view(ctx, saved) end
  return true
end

function M.create_new_prompt(ctx)
  local ok, path = pcall(workspace.create_prompt, ctx)
  if not ok then
    vim.notify("Не удалось создать промпт: " .. tostring(path), vim.log.levels.ERROR)
    return nil
  end
  return show_prompt(path, ctx)
end

function M.open_prompt(ctx)
  ctx = ctx or terminals.prompt_context()
  if not ctx.terminal_bufnr then
    local win
    if not terminals.started_agent() and (vim.api.nvim_buf_get_name(0) ~= "" or vim.bo.modified) then
      vim.cmd("leftabove vsplit")
      win = vim.api.nvim_get_current_win()
    end
    terminals.open_agent({ normal_mode = true, win = win })
    ctx = terminals.prompt_context()
  end
  workspace.remember_prompt_context(ctx)
  if ctx.path then return show_prompt(ctx.path, ctx) end
  return M.create_new_prompt(ctx)
end

function M.toggle_prompt()
  local ctx = terminals.prompt_context()
  local win = prompt_window(ctx)
  if win then return hide_prompt(ctx, win) end
  return M.open_prompt(ctx)
end

function M.cycle_agent_prompt()
  local ctx = terminals.prompt_context()
  local target
  local leaving_input
  if vim.bo.buftype == "terminal" then
    leaving_input = vim.api.nvim_get_mode().mode:sub(1, 1) == "t"
    ctx.prompt_terminal_input = leaving_input
    target = prompt_window(ctx)
  elseif workspace.context_for_path(current_path()) == ctx then
    ctx.prompt_terminal_input = false
    target = terminal_window(ctx)
  end
  if target then
    focus_window(target, false)
    if leaving_input ~= nil then ctx.prompt_terminal_input = leaving_input end
    return
  end
  vim.cmd.stopinsert()
  vim.cmd("wincmd w")
  focus_window(vim.api.nvim_get_current_win(), false)
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

  local buf, editor_win = current_buf(), vim.api.nvim_get_current_win()
  local ctx = workspace.context_for_path(path)
  if not ctx then
    return false
  end
  local ok, err = pcall(function()
    save_prompt_buffer(buf)
    local draft = ctx.path and vim.fn.bufnr(ctx.path) or -1
    if draft > 0 and draft ~= buf then
      save_prompt_buffer(draft)
    end
  end)
  if not ok then
    vim.notify("Не удалось сохранить черновик: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if not terminals.paste_into_agent(text, {
    path = path,
    context_id = ctx.id,
    bufnr = buf,
  }) then
    return false
  end
  return hide_prompt(ctx, editor_win, buf, true)
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
