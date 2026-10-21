local M = {
  state_by_tab = {},
  prompt_contexts = {},
  terminal_contexts = {},
}

local editor_id = ("%d-%s"):format(vim.uv.os_getpid(), tostring(vim.uv.hrtime()))
local context_number = 0

function M.current_tab()
  return vim.api.nvim_get_current_tabpage()
end

function M.state(tabpage)
  tabpage = tabpage or M.current_tab()

  if not M.state_by_tab[tabpage] then
    M.state_by_tab[tabpage] = {
      terminals = {},
      last_terminal_slot = nil,
      terminal_history = {},
      last_file_win = nil,
      bottom_win = nil,
      bottom_terminal_height = 14,
      agent_term = nil,
      agent_win = nil,
    }
  end

  return M.state_by_tab[tabpage]
end

function M.current_cwd(tabpage)
  tabpage = tabpage or M.current_tab()
  local tabnr = vim.api.nvim_tabpage_get_number(tabpage)
  local ok, cwd = pcall(vim.fn.getcwd, -1, tabnr)
  if ok and cwd ~= "" then
    return cwd
  end

  return vim.uv.cwd() or vim.loop.cwd()
end

function M.tab_title(tabpage)
  return vim.fs.basename(M.current_cwd(tabpage))
end

function M.is_markdown(path)
  if not path or path == "" then
    return false
  end

  local lowered = path:lower()
  return lowered:match("%.md$") ~= nil or lowered:match("%.markdown$") ~= nil
end

function M.prompt_base(cwd)
  local home = vim.fs.normalize(vim.fn.expand("~"))
  cwd = vim.fs.normalize(cwd)
  if cwd == home then return "/tmp" end
  if cwd:sub(1, #home + 1) == home .. "/" then
    return vim.fs.joinpath("/tmp", cwd:sub(#home + 2))
  end
  return vim.fs.joinpath("/tmp/_outside-home", (cwd:gsub("^/+", "")))
end

function M.new_prompt_context(cwd, saved)
  context_number = context_number + 1
  saved = saved or {}
  local ctx = {
    id = saved.id or (editor_id .. "-" .. context_number), cwd = cwd,
    directory = saved.directory, path = saved.path, sequence = saved.sequence or 0,
  }
  M.prompt_contexts[ctx.id] = ctx
  return ctx
end

function M.bind_prompt_context(ctx, bufnr, job_id)
  ctx.terminal_bufnr, ctx.job_id, ctx.submission = bufnr, job_id, nil
  M.terminal_contexts[bufnr] = ctx.id
end

function M.context_for_terminal(bufnr)
  local ctx = M.prompt_contexts[M.terminal_contexts[bufnr]]
  if ctx and vim.api.nvim_buf_is_valid(bufnr) and ctx.job_id == vim.b[bufnr].terminal_job_id then return ctx end
end

function M.terminal_prompt_context(bufnr, job_id, cwd)
  local ctx = M.context_for_terminal(bufnr)
  if not ctx or ctx.job_id ~= job_id then
    ctx = M.new_prompt_context(cwd)
    M.bind_prompt_context(ctx, bufnr, job_id)
  end
  return ctx
end

function M.remember_prompt_context(ctx, tabpage)
  M.state(tabpage).last_prompt_context = ctx.id
end

function M.last_prompt_context(tabpage)
  return M.prompt_contexts[M.state(tabpage).last_prompt_context]
end

function M.context_for_path(path)
  path = vim.fs.normalize(path or "")
  for _, ctx in pairs(M.prompt_contexts) do
    if ctx.path == path or (ctx.directory and path:sub(1, #ctx.directory + 1) == ctx.directory .. "/") then return ctx end
  end
end

function M.snapshot_prompt_contexts()
  local result = {}
  for id, ctx in pairs(M.prompt_contexts) do
    result[id] = { id = id, cwd = ctx.cwd, directory = ctx.directory, path = ctx.path, sequence = ctx.sequence }
  end
  return result
end

function M.restore_prompt_contexts(contexts)
  for id, saved in pairs(contexts or {}) do
    saved.id = id
    M.new_prompt_context(saved.cwd, saved)
  end
end

function M.prompt_dir(ctx)
  ctx.directory = ctx.directory or vim.fs.joinpath(M.prompt_base(ctx.cwd), "session-" .. ctx.id)
  return ctx.directory
end

function M.ensure_prompt_dir(ctx)
  local dir = M.prompt_dir(ctx)
  vim.fn.mkdir(dir, "p", 448)
  return dir
end

function M.make_prompt_name(timestamp)
  timestamp = timestamp or os.time()
  local months = { "января", "февраля", "марта", "апреля", "мая", "июня",
    "июля", "августа", "сентября", "октября", "ноября", "декабря" }
  local weekdays = { ["0"] = "ВС", ["1"] = "ПН", ["2"] = "ВТ", ["3"] = "СР",
    ["4"] = "ЧТ", ["5"] = "ПТ", ["6"] = "СБ" }
  return ("%s-%s-%s-%s.md"):format(os.date("%d", timestamp), months[tonumber(os.date("%m", timestamp))],
    weekdays[os.date("%w", timestamp)], os.date("%H:%M", timestamp))
end

-- Reserve the file atomically; update draft/sequence only after creation succeeds.
function M.create_prompt(ctx)
  local dir = M.ensure_prompt_dir(ctx)
  local name = M.make_prompt_name()
  local index = 0
  while true do
    local candidate = index == 0 and name or name:gsub("%.md$", ("-%02d.md"):format(index))
    local path = vim.fs.joinpath(dir, candidate)
    local fd, err, code = vim.uv.fs_open(path, "wx", 384)
    if fd then
      vim.uv.fs_close(fd)
      ctx.sequence = ctx.sequence + 1
      ctx.path, ctx.submission = path, nil
      return path
    end
    if code ~= "EEXIST" then error(err) end
    index = index + 1
  end
end

function M.mark_prompt_sent(path, ctx)
  if ctx.path == vim.fn.fnamemodify(path, ":p") then
    ctx.path, ctx.submission = nil, nil
  end
end

function M.is_prompt_markdown(path)
  path = vim.fn.fnamemodify(path or "", ":p")
  if not M.is_markdown(path) then
    return false
  end

  path = vim.fs.normalize(path)
  if path:match("/%.ai/prompts/") then
    return true
  end

  return M.context_for_path(path) ~= nil
end

function M.new_tab()
  local cwd = M.current_cwd()
  vim.cmd.tabnew()
  vim.cmd(("tcd %s"):format(vim.fn.fnameescape(cwd)))
end

function M.close_other_tabs()
  vim.cmd.tabonly()
end

function M.goto_tab(index)
  local target = index == 0 and 10 or index
  if target > vim.fn.tabpagenr("$") then
    return
  end

  vim.cmd(("tabnext %d"):format(target))
end

return M
