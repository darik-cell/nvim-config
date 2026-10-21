-- One durable snapshot per editor. A normal exit removes only its own snapshot.
local M = {}
local uv = vim.uv
local api = vim.api
local workspace = require("config.workspace")
local context

local function read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

local function process(pid)
  local text = read("/proc/" .. pid .. "/stat")
  if not text then return nil end
  local name, rest = text:match("^%d+ %((.*)%) (.*)$")
  if not rest then return nil end
  local fields = vim.split(rest, " ", { trimempty = true })
  return { name = name, state = fields[1], parent = tonumber(fields[2]), start = fields[20] }
end

local function identity()
  local pid = uv.os_getpid()
  local proc = process(pid)
  return { pid = pid, boot = vim.trim(read("/proc/sys/kernel/random/boot_id") or ""),
    start = proc and proc.start or "" }
end

local function alive(owner)
  if type(owner) ~= "table" or type(owner.pid) ~= "number" then return false end
  if owner.boot ~= context.owner.boot then return false end
  local proc = process(owner.pid)
  if proc then return proc.state ~= "Z" and proc.start == owner.start end
  -- /proc is used on Linux; the signal probe is a conservative fallback.
  return context.owner.boot == "" and uv.kill(owner.pid, 0) == 0
end

local function processes()
  local result = {}
  local scan = uv.fs_scandir("/proc")
  if not scan then return result end
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then break end
    local pid = tonumber(name)
    if pid then
      local stat = uv.fs_stat("/proc/" .. name)
      if stat and stat.uid == uv.os_get_passwd().uid then
        local proc = process(pid)
        if proc and proc.state ~= "Z" then result[pid] = proc end
      end
    end
  end
  return result
end

local function another_editor()
  local own = { [context.owner.pid] = true }
  -- Neovim 0.12 runs its built-in TUI as a separate frontend process.
  for _, ui in ipairs(api.nvim_list_uis()) do
    local channel = api.nvim_get_chan_info(ui.chan)
    local client = channel.client or {}
    if channel.stream == "stdio" and client.name == "nvim-tui" and client.type == "ui" then
      local pid = tonumber((client.attributes or {}).pid) or uv.os_getppid()
      own[pid] = true
    end
  end
  for pid, proc in pairs(processes()) do
    if not own[pid] and proc.name == "nvim" then return true end
  end
  return false
end

local function atomic_write(path, value)
  local tmp = path .. ".tmp"
  local fd = assert(uv.fs_open(tmp, "w", 384)) -- 0600: terminal history is private.
  local ok, err = pcall(function()
    local data = vim.json.encode(value)
    local offset = 0
    while offset < #data do
      offset = offset + assert(uv.fs_write(fd, data:sub(offset + 1), offset))
    end
    assert(uv.fs_fsync(fd))
  end)
  uv.fs_close(fd)
  if not ok then uv.fs_unlink(tmp); error(err) end
  assert(uv.fs_rename(tmp, path))
  local dirfd = uv.fs_open(vim.fs.dirname(path), "r", 0)
  if dirfd then uv.fs_fsync(dirfd); uv.fs_close(dirfd) end
end

local uuid = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

-- Read only filenames, never Codex conversations or authentication files.
local function codex_sessions(root_pid, tree)
  local ids, seen = {}, {}
  local function visit(pid)
    if seen[pid] then return end
    seen[pid] = true
    local proc = tree[pid]
    if proc and proc.name:find("codex", 1, true) then
      local scan = uv.fs_scandir("/proc/" .. pid .. "/fd")
      if scan then
        while true do
          local fd = uv.fs_scandir_next(scan)
          if not fd then break end
          local path = uv.fs_readlink("/proc/" .. pid .. "/fd/" .. fd) or ""
          local id = path:match("rollout%-.-(" .. uuid .. ")%.jsonl$")
          if id then ids[id] = true end
        end
      end
    end
    for child, info in pairs(tree) do if info.parent == pid then visit(child) end end
  end
  if root_pid then visit(root_pid) end
  local result = vim.tbl_keys(ids)
  table.sort(result)
  return result
end

function M.capture()
  local snapshot = { version = 1, owner = context.owner, saved_at = os.time(),
    cwd = vim.fn.getcwd(-1, -1), buffers = {}, tabs = {}, active_tab = vim.fn.tabpagenr(),
    prompt_contexts = workspace.snapshot_prompt_contexts() }
  local tree = processes()
  local function buffer(buf)
    local key = tostring(buf)
    if snapshot.buffers[key] then return key end
    local bt = vim.bo[buf].buftype
    local item = { name = api.nvim_buf_get_name(buf), kind = bt, listed = vim.bo[buf].buflisted,
      filetype = vim.bo[buf].filetype, original_path = vim.b[buf].session_original_path }
    if bt == "terminal" or vim.b[buf].session_terminal_history then
      item.kind = "terminal"
      item.lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      item.exact_resume_ids = {}
      for id in table.concat(item.lines, "\n"):gmatch("codex%s+resume%s+(" .. uuid .. ")") do
        if not vim.tbl_contains(item.exact_resume_ids, id) then item.exact_resume_ids[#item.exact_resume_ids + 1] = id end
      end
      if #item.exact_resume_ids == 0 then item.exact_resume_ids = vim.b[buf].session_exact_resume_ids or {} end
      item.role = vim.b[buf].nvim_alt_terminal_role
      item.slot = vim.b[buf].nvim_alt_terminal_slot
      item.prompt_context_id = (workspace.context_for_terminal(buf) or {}).id
      local job = vim.b[buf].terminal_job_id
      local ok, pid = pcall(vim.fn.jobpid, job or -1)
      item.cwd = ok and uv.fs_readlink("/proc/" .. pid .. "/cwd") or nil
      item.resume_ids = codex_sessions(ok and pid or nil, tree)
      -- Retain the captured command if the restored shell has not resumed it yet.
      if #item.resume_ids == 0 then item.resume_ids = vim.b[buf].session_resume_ids or {} end
    elseif vim.b[buf].nvim_tab_scratch then
      item.kind = "scratch"
      item.lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    elseif bt == "" and api.nvim_buf_is_loaded(buf) then
      if item.name == "" or vim.bo[buf].modified then
        item.lines = api.nvim_buf_get_lines(buf, 0, -1, false)
        item.modified = vim.bo[buf].modified
      end
    else
      item.kind = "placeholder"
    end
    snapshot.buffers[key] = item
    return key
  end
  local function layout(node, tabnr)
    if node[1] == "leaf" then
      local win = node[2]
      local info = vim.fn.getwininfo(win)[1]
      local winnr = info.winnr
      return { kind = "leaf", id = win, buffer = buffer(api.nvim_win_get_buf(win)),
        width = api.nvim_win_get_width(win), height = api.nvim_win_get_height(win),
        view = api.nvim_win_call(win, vim.fn.winsaveview),
        cwd = vim.fn.haslocaldir(winnr, tabnr) == 1 and vim.fn.getcwd(winnr, tabnr) or nil }
    end
    local result = { kind = node[1], children = {} }
    for _, child in ipairs(node[2]) do result.children[#result.children + 1] = layout(child, tabnr) end
    return result
  end
  for nr, tab in ipairs(api.nvim_list_tabpages()) do
    local st = workspace.state(tab)
    local slots = {}
    for slot, term in pairs(st.terminals) do
      if term.bufnr and api.nvim_buf_is_valid(term.bufnr) then slots[tostring(slot)] = buffer(term.bufnr) end
    end
    snapshot.tabs[#snapshot.tabs + 1] = { cwd = workspace.current_cwd(tab), slots = slots,
      agent = st.agent_term and api.nvim_buf_is_valid(st.agent_term.bufnr) and buffer(st.agent_term.bufnr) or nil,
      last_slot = st.last_terminal_slot, terminal_history = vim.deepcopy(st.terminal_history),
      layout = layout(vim.fn.winlayout(nr), nr), active_win = api.nvim_tabpage_get_win(tab),
      last_prompt_context = st.last_prompt_context,
      scratch = st.scratch_bufnr and api.nvim_buf_is_valid(st.scratch_bufnr) and buffer(st.scratch_bufnr) or nil,
      bottom_height = st.bottom_terminal_height }
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and (vim.bo[buf].buflisted or vim.bo[buf].buftype == "terminal") then buffer(buf) end
  end
  return snapshot
end

function M.save()
  if not context or context.restoring or context.stopping or not context.started then return false end
  local ok, err = pcall(function() atomic_write(context.path, M.capture()) end)
  if not ok and not context.warned then
    context.warned = true
    vim.notify("Не удалось сохранить сессию Neovim: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

local function valid_layout(node, buffers)
  if type(node) ~= "table" then return false end
  if node.kind == "leaf" then
    return type(buffers[node.buffer]) == "table" and type(node.width) == "number" and type(node.height) == "number"
  end
  if node.kind ~= "row" and node.kind ~= "col" then return false end
  if type(node.children) ~= "table" or #node.children == 0 then return false end
  for _, child in ipairs(node.children) do if not valid_layout(child, buffers) then return false end end
  return true
end

function M.pending()
  local entries = {}
  for _, path in ipairs(vim.fn.glob(context.dir .. "/*.json", false, true)) do
    if path ~= context.path then
      local ok, value = pcall(vim.json.decode, read(path) or "")
      local valid = ok and type(value) == "table" and value.version == 1
        and type(value.buffers) == "table" and type(value.tabs) == "table" and #value.tabs > 0
      if valid then
        for _, tab in ipairs(value.tabs) do
          if not valid_layout(tab.layout, value.buffers) then valid = false; break end
        end
      end
      if valid and not alive(value.owner) then entries[#entries + 1] = { path = path, data = value }
      elseif not valid and not context.bad[path] then
        context.bad[path] = true
        vim.notify("Повреждённый снимок сессии оставлен для ручного восстановления: " .. path, vim.log.levels.WARN)
      end
    end
  end
  table.sort(entries, function(a, b)
    local at, bt = a.data.saved_at or 0, b.data.saved_at or 0
    return at == bt and a.path < b.path or at < bt
  end)
  return entries
end

local function cd(command, path)
  if path and vim.fn.isdirectory(path) == 1 then
    vim.cmd(command .. " " .. vim.fn.fnameescape(path))
  end
end

local function terminal_history(buf, item, fallback_cwd, tab)
  local history = vim.fn.tempname()
  local fd = assert(uv.fs_open(history, "w", 384))
  local lines = vim.deepcopy(item.lines or {})
  lines[#lines + 1] = ""
  lines[#lines + 1] = "── История терминала до сбоя; ниже — новая оболочка ──"
  local ids = item.resume_ids or {}
  for _, id in ipairs(item.exact_resume_ids or {}) do lines[#lines + 1] = "Сохранённая команда: codex resume " .. id end
  for _, id in ipairs(ids) do lines[#lines + 1] = "Найденная сессия (кандидат): codex resume " .. id end
  if item.role == "agent" or #ids > 0 then
    lines[#lines + 1] = "Выбор сохранённого разговора: codex resume --all"
  end
  assert(uv.fs_write(fd, table.concat(lines, "\n") .. "\n", 0))
  uv.fs_close(fd)
  context.histories[#context.histories + 1] = history
  api.nvim_buf_call(buf, function()
    vim.bo[buf].buftype = ""
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.bo[buf].modified = false
    vim.bo[buf].scrollback = math.max(vim.o.scrollback, #lines + 1000)
    local cwd = item.cwd and vim.fn.isdirectory(item.cwd) == 1 and item.cwd or fallback_cwd
    if not cwd or vim.fn.isdirectory(cwd) ~= 1 then cwd = uv.cwd() end
    -- Old output is data supplied to cat, never shell commands. Only a new shell starts.
    local job = require("config.terminals").restore_job(buf, tab, item,
      { "/bin/sh", "-c", 'cat -- "$1"; exec "$2"', "nvim-recovery", history, vim.o.shell }, cwd)
    assert(job > 0, "Не удалось открыть восстановленный терминал")
    vim.b[buf].session_resume_ids = ids
    vim.b[buf].session_exact_resume_ids = item.exact_resume_ids or {}
    vim.b[buf].nvim_alt_terminal_role = item.role
    vim.b[buf].nvim_alt_terminal_slot = item.slot
    vim.b[buf].nvim_alt_bottom_terminal = item.role == "shell"
    vim.b[buf].nvim_alt_agent_terminal = item.role == "agent"
    vim.b[buf].nvim_alt_terminal = item.role ~= nil
  end)
  -- Ensure the replacement snapshot includes the transcript before retiring backups.
  assert(vim.wait(3000, function()
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("История терминала до сбоя", 1, true) ~= nil
  end, 10), "Не удалось вывести сохранённую историю терминала")
end

local function blank_start()
  local buf = api.nvim_get_current_buf()
  return #api.nvim_list_tabpages() == 1 and #api.nvim_tabpage_list_wins(0) == 1
    and api.nvim_buf_get_name(buf) == "" and vim.bo[buf].buftype == "" and not vim.bo[buf].modified
    and api.nvim_buf_line_count(buf) == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

function M.restore(entries)
  context.restoring = true
  vim.g.nvim_session_restoring = true
  local ok, err = pcall(function()
    local reuse = blank_start()
    local modified = {}
    for _, entry in ipairs(entries) do
      local snapshot, buffers = entry.data, {}
      workspace.restore_prompt_contexts(snapshot.prompt_contexts)
      local terminal_items, terminal_cwds, terminal_tabs = {}, {}, {}
      for key, item in pairs(snapshot.buffers) do
        local buf
        if item.kind == "" and item.name ~= "" then
          buf = vim.fn.bufadd(item.name)
          vim.fn.bufload(buf)
          -- Divergent unsaved copies from separate editors must not overwrite one another.
          if item.lines and (vim.bo[buf].modified or modified[buf]) then
            buf = api.nvim_create_buf(true, false)
            vim.b[buf].session_original_path = item.name
          end
        else
          buf = api.nvim_create_buf(item.listed == true, item.kind ~= "")
        end
        buffers[key] = buf
        if item.kind == "scratch" then
          vim.bo[buf].bufhidden = "hide"
          vim.bo[buf].swapfile = false
          vim.b[buf].nvim_tab_scratch = true
        end
        if item.original_path then vim.b[buf].session_original_path = item.original_path end
        if item.kind == "terminal" then
          terminal_items[buf] = item
        elseif item.lines then
          api.nvim_buf_set_lines(buf, 0, -1, false, item.lines)
          vim.bo[buf].filetype = item.filetype or ""
          modified[buf] = item.modified == true
          vim.bo[buf].modified = false -- mark only after all window changes/autosaves finish
        elseif item.kind ~= "" then
          api.nvim_buf_set_lines(buf, 0, -1, false, { "Окно до сбоя: " .. item.name,
            "Панель плагина можно открыть заново обычной командой." })
          vim.bo[buf].modified = false
        end
      end
      local selected_tab
      for nr, tabdata in ipairs(snapshot.tabs) do
        if not reuse then vim.cmd("tablast | tabnew") end
        reuse = false
        local tab = api.nvim_get_current_tabpage()
        cd("tcd", tabdata.cwd)
        local st = workspace.state(tab)
        st.last_prompt_context = tabdata.last_prompt_context
        st.scratch_bufnr = tabdata.scratch and buffers[tabdata.scratch] or nil
        -- Migrate earlier snapshots whose prompt belonged to the whole tab.
        if tabdata.prompt_path or tabdata.prompt_directory then
          local ctx = workspace.new_prompt_context(tabdata.cwd, { path = tabdata.prompt_path,
            directory = tabdata.prompt_directory, sequence = tabdata.prompt_sequence })
          workspace.remember_prompt_context(ctx, tab)
          if tabdata.agent then terminal_items[buffers[tabdata.agent]].prompt_context_id = ctx.id end
        end
        st.bottom_terminal_height = tabdata.bottom_height or 14
        st.last_terminal_slot = tabdata.last_slot
        st.terminal_history = tabdata.terminal_history or {}
        for _, key in pairs(tabdata.slots or {}) do
          terminal_tabs[buffers[key]] = tab
          terminal_cwds[buffers[key]] = tabdata.cwd
        end
        if tabdata.agent then
          terminal_tabs[buffers[tabdata.agent]] = tab
          terminal_cwds[buffers[tabdata.agent]] = tabdata.cwd
        end
        local windows, leaves = {}, {}
        local function build(node, win)
          if node.kind == "leaf" then
            local buf = buffers[node.buffer]
            api.nvim_win_set_buf(win, buf)
            windows[node.id] = win
            leaves[#leaves + 1] = { data = node, win = win }
            if terminal_items[buf] then terminal_cwds[buf] = tabdata.cwd; terminal_tabs[buf] = tab end
            return
          end
          local siblings = { win }
          for i = 2, #node.children do
            api.nvim_set_current_win(siblings[i - 1])
            vim.cmd(node.kind == "row" and "rightbelow vsplit" or "rightbelow split")
            siblings[i] = api.nvim_get_current_win()
          end
          for i, child in ipairs(node.children) do build(child, siblings[i]) end
        end
        build(tabdata.layout, api.nvim_get_current_win())
        for _, leaf in ipairs(leaves) do
          local win, data = leaf.win, leaf.data
          pcall(api.nvim_win_set_width, win, data.width)
          pcall(api.nvim_win_set_height, win, data.height)
          api.nvim_win_call(win, function() cd("lcd", data.cwd); vim.fn.winrestview(data.view or {}) end)
          local buf = api.nvim_win_get_buf(win)
          local item = terminal_items[buf]
          if item and item.role == "shell" and type(item.slot) == "number" then
            st.terminals[item.slot] = { bufnr = buf }
            st.bottom_win = win
            vim.w[win].nvim_alt_bottom_window = true
          elseif item and item.role == "agent" then
            st.agent_term = { bufnr = buf }
            st.agent_win = win
          elseif vim.bo[buf].buftype == "" then st.last_file_win = win end
        end
        if windows[tabdata.active_win] then api.nvim_set_current_win(windows[tabdata.active_win]) end
        if nr == snapshot.active_tab then selected_tab = tab end
      end
      for buf, item in pairs(terminal_items) do
        terminal_history(buf, item, terminal_cwds[buf] or snapshot.cwd, terminal_tabs[buf])
      end
      if selected_tab then api.nvim_set_current_tabpage(selected_tab) end
      for _, tab in ipairs(api.nvim_list_tabpages()) do
        local st = workspace.state(tab)
        for _, term in pairs(st.terminals) do term.job_id = vim.b[term.bufnr].terminal_job_id end
        if st.agent_term then st.agent_term.job_id = vim.b[st.agent_term.bufnr].terminal_job_id end
      end
    end
    for buf, value in pairs(modified) do vim.bo[buf].modified = value end
  end)
  context.restoring = false
  vim.g.nvim_session_restoring = false
  context.started = true
  if not ok then
    vim.notify("Не удалось полностью восстановить сессию; снимки сохранены: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  -- Commit the merged replacement before removing any of the crashed instances.
  if not M.save() then return false end
  for _, entry in ipairs(entries) do uv.fs_unlink(entry.path) end
  vim.cmd.redrawtabline()
  return true
end

local function release_lock()
  if context.claim then uv.fs_unlink(context.lock); context.claim = false end
end

local function claim()
  local fd = uv.fs_open(context.lock, "wx", 384)
  if not fd then
    local ok, owner = pcall(vim.json.decode, read(context.lock) or "")
    -- An empty lock may belong to a concurrent creator; don't steal it.
    if not ok then
      local stat = uv.fs_stat(context.lock)
      if not stat or os.time() - stat.mtime.sec < 30 then return false end
    elseif alive(owner) then return false end
    uv.fs_unlink(context.lock)
    fd = uv.fs_open(context.lock, "wx", 384)
    if not fd then return false end
  end
  uv.fs_write(fd, vim.json.encode(context.owner), 0)
  uv.fs_close(fd)
  context.claim = true
  return true
end

function M.offer()
  if context.restoring or another_editor() or not claim() then return end
  local ok, err = pcall(function()
    local entries = M.pending()
    if #entries == 0 then return end
    local tabs = 0
    for _, entry in ipairs(entries) do tabs = tabs + #entry.data.tabs end
    local choice = vim.fn.confirm(("Найдена сессия после сбоя: %d экземпляров Neovim, %d вкладок. Восстановить вместе?")
      :format(#entries, tabs), "&Восстановить\n&Позже\n&Удалить снимки", 1)
    if choice == 1 then M.restore(entries)
    elseif choice == 3 then for _, entry in ipairs(entries) do uv.fs_unlink(entry.path) end end
  end)
  release_lock()
  if not ok then vim.notify("Ошибка восстановления сессии: " .. tostring(err), vim.log.levels.ERROR) end
end

function M.setup(opts)
  opts = opts or {}
  -- RPC helpers, batch jobs, and tests must never consume interactive sessions.
  if not opts.headless and #api.nvim_list_uis() == 0 then return end
  if context then return end
  local dir = opts.dir or (vim.fn.stdpath("state") .. "/crash-sessions")
  vim.fn.mkdir(dir, "p", 448) -- 0700
  local owner = identity()
  local id = tostring(owner.pid) .. "-" .. tostring(uv.hrtime())
  context = { dir = dir, owner = owner, path = dir .. "/" .. id .. ".json",
    lock = dir .. "/recovery.lock", histories = {}, bad = {}, started = false }
  local group = api.nvim_create_augroup("nvim-crash-recovery", { clear = true })
  local debounce, periodic = uv.new_timer(), uv.new_timer()
  local function queue()
    if context.stopping or context.restoring then return end
    debounce:start(300, 0, vim.schedule_wrap(M.save))
  end
  api.nvim_create_autocmd({ "TabNew", "TabClosed", "TabEnter", "WinNew", "WinClosed", "WinResized",
    "BufWinEnter", "BufDelete", "BufWritePost", "DirChanged", "TextChanged", "TextChangedI", "TermClose" },
    { group = group, callback = queue })
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    context.stopping = true
    debounce:stop(); debounce:close()
    periodic:stop(); periodic:close()
    release_lock()
    -- Nonzero v:dying means a fatal signal, not a deliberate :quit.
    if vim.v.dying == 0 then uv.fs_unlink(context.path) end
    for _, path in ipairs(context.histories) do uv.fs_unlink(path) end
  end })
  api.nvim_create_user_command("SessionSave", M.save, { desc = "Save crash recovery snapshot now" })
  api.nvim_create_user_command("SessionRecover", M.offer, { desc = "Offer to merge crashed editor sessions" })
  api.nvim_create_user_command("SessionResume", function()
    local command = "codex resume --all"
    if vim.bo.buftype ~= "terminal" then
      vim.notify("Выполните SessionResume в восстановленном терминале", vim.log.levels.WARN)
      return
    end
    api.nvim_chan_send(vim.b.terminal_job_id, command .. "\r")
    vim.cmd.startinsert()
  end, { desc = "Resume Codex in the recovered terminal" })
  local function start()
    if context.started then return end
    if opts.prompt ~= false then M.offer() end
    context.started = true
    M.save()
    periodic:start(opts.interval or 5000, opts.interval or 5000, vim.schedule_wrap(M.save))
  end
  if vim.v.vim_did_enter == 1 then vim.schedule(start)
  else api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = function() vim.schedule(start) end }) end
end

return M
