local workspace = require("config.workspace")

local M = {}
local get_terminal

local shell = vim.o.shell ~= "" and vim.o.shell or "sh"
local bottom_height_default = 14
local bottom_height_min = 3

local function state(tabpage)
  return workspace.state(tabpage)
end

local function clamp_bottom_height(height)
  local normalized = tonumber(height) or bottom_height_default
  normalized = math.floor(normalized)
  if normalized < bottom_height_min then
    return bottom_height_min
  end
  return normalized
end

local function saved_bottom_height(tabpage)
  return clamp_bottom_height(state(tabpage).bottom_terminal_height)
end

local function hl(name)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok then
    return {}
  end
  return value
end

local function rgb_components(color)
  return math.floor(color / 0x10000) % 0x100, math.floor(color / 0x100) % 0x100, color % 0x100
end

local function to_rgb(r, g, b)
  return r * 0x10000 + g * 0x100 + b
end

local function blend(from, to, alpha)
  local fr, fg, fb = rgb_components(from)
  local tr, tg, tb = rgb_components(to)

  local mix = function(start, target)
    return math.floor(start + (target - start) * alpha + 0.5)
  end

  return to_rgb(mix(fr, tr), mix(fg, tg), mix(fb, tb))
end

local function luminance(color)
  local r, g, b = rgb_components(color)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

local function contrast_fg(bg, dark, light)
  if luminance(bg) > 140 then
    return dark
  end
  return light
end

local function refresh_panel_highlights()
  local normal = hl("Normal")
  local normal_nc = hl("NormalNC")
  local status = hl("StatusLine")
  local status_nc = hl("StatusLineNC")
  local tabline = hl("TabLine")
  local title = hl("Title")
  local directory = hl("Directory")
  local function_hl = hl("Function")
  local search = hl("Search")

  local normal_bg = normal.bg or 0x1f1f1f
  local normal_fg = normal.fg or 0xd0d0d0
  local panel_base = status_nc.bg or tabline.bg or status.bg or blend(normal_bg, normal_fg, 0.12)
  local panel_bg = blend(normal_bg, panel_base, 0.78)
  local panel_nc_bg = blend(panel_bg, normal_bg, 0.3)
  local winbar_bg = blend(panel_bg, status.bg or panel_base, 0.45)
  local accent = title.fg or directory.fg or function_hl.fg or normal_fg
  local slot_fg = blend(tabline.fg or normal_nc.fg or normal_fg, normal_fg, 0.45)
  local active_bg = blend(panel_bg, accent, 0.72)
  local active_fg = contrast_fg(active_bg, search.fg or normal_bg, normal_fg)

  vim.api.nvim_set_hl(0, "TerminalPanelNormal", { bg = panel_bg, fg = normal_fg })
  vim.api.nvim_set_hl(0, "TerminalPanelNormalNC", { bg = panel_nc_bg, fg = normal_fg })
  vim.api.nvim_set_hl(0, "TerminalPanelWinBar", { bg = winbar_bg, fg = normal_fg })
  vim.api.nvim_set_hl(0, "TerminalPanelWinBarNC", { bg = winbar_bg, fg = slot_fg })
  vim.api.nvim_set_hl(0, "TerminalPanelSeparator", { fg = accent, bg = panel_bg })
  vim.api.nvim_set_hl(0, "TerminalPanelTitle", { bg = winbar_bg, fg = accent, bold = true })
  vim.api.nvim_set_hl(0, "TerminalPanelSlot", { bg = winbar_bg, fg = slot_fg })
  vim.api.nvim_set_hl(0, "TerminalPanelSlotActive", { bg = active_bg, fg = active_fg, bold = true })
end

local function current_mode()
  return vim.api.nvim_get_mode().mode
end

local function terminal_count_limit()
  return 10
end

local function slot_label(slot)
  return tostring(slot == 10 and 0 or slot)
end

local function push_history(tabpage, slot)
  local history = state(tabpage).terminal_history
  local filtered = {}
  for _, existing in ipairs(history) do
    if existing ~= slot then
      filtered[#filtered + 1] = existing
    end
  end
  filtered[#filtered + 1] = slot
  state(tabpage).terminal_history = filtered
end

local function remove_from_history(tabpage, slot)
  local history = state(tabpage).terminal_history
  local filtered = {}
  for _, existing in ipairs(history) do
    if existing ~= slot then
      filtered[#filtered + 1] = existing
    end
  end
  state(tabpage).terminal_history = filtered
end

local function previous_slot(tabpage)
  local history = state(tabpage).terminal_history
  for index = #history, 1, -1 do
    local slot = history[index]
    if get_terminal(slot, tabpage) then
      return slot
    end
  end
end

local function first_existing_slot(tabpage)
  for slot = 1, terminal_count_limit() do
    if get_terminal(slot, tabpage) then
      return slot
    end
  end
end

local function channel_for(term)
  if term.job_id then
    return term.job_id
  end

  if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
    return vim.b[term.bufnr].terminal_job_id
  end
end

local function valid_tab_win(win, tabpage)
  return win
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_tabpage(win) == (tabpage or workspace.current_tab())
    and vim.api.nvim_win_get_config(win).relative == ""
end

local function is_regular_file_window(win, tabpage)
  if not valid_tab_win(win, tabpage) then
    return false
  end

  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" and not vim.b[buf].nvim_tab_scratch then
    return false
  end

  local ft = vim.bo[buf].filetype
  if ft == "neo-tree" or ft == "neo-tree-popup" then
    return false
  end

  if vim.w[win].nvim_alt_bottom_window then
    return false
  end

  return true
end

get_terminal = function(slot, tabpage)
  local st = state(tabpage)
  local term = st.terminals[slot]
  if not term then
    return nil
  end

  if not term.bufnr or not vim.api.nvim_buf_is_valid(term.bufnr) then
    st.terminals[slot] = nil
    return nil
  end

  return term
end

local function bottom_window(tabpage)
  local st = state(tabpage)
  local win = st.bottom_win
  if not valid_tab_win(win, tabpage) then
    st.bottom_win = nil
    return nil
  end

  if not vim.w[win].nvim_alt_bottom_window then
    st.bottom_win = nil
    return nil
  end

  return win
end

local function bottom_split_base_window()
  local tabpage = workspace.current_tab()
  local current = vim.api.nvim_get_current_win()
  if valid_tab_win(current, tabpage) and vim.api.nvim_win_get_config(current).relative == "" then
    return current
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if valid_tab_win(win, tabpage) then
      return win
    end
  end

  return current
end

local function apply_bottom_window_state(win)
  if not valid_tab_win(win) then
    return
  end

  refresh_panel_highlights()
  vim.w[win].nvim_alt_bottom_window = true
  vim.api.nvim_win_call(win, function()
    vim.wo.winfixheight = true
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.signcolumn = "no"
    vim.wo.winhighlight = table.concat({
      "Normal:TerminalPanelNormal",
      "NormalNC:TerminalPanelNormalNC",
      "WinBar:TerminalPanelWinBar",
      "WinBarNC:TerminalPanelWinBarNC",
      "WinSeparator:TerminalPanelSeparator",
    }, ",")
    vim.wo.winbar = "%!v:lua.require'config.terminals'.winbar()"
  end)
end

local function visible_bottom_slot(tabpage)
  local win = bottom_window(tabpage)
  if not win then
    return nil
  end

  local buf = vim.api.nvim_win_get_buf(win)
  return vim.b[buf].nvim_alt_terminal_slot
end

local function remember_bottom_height(tabpage, win)
  tabpage = tabpage or workspace.current_tab()
  win = win or bottom_window(tabpage)
  if not valid_tab_win(win, tabpage) then
    return
  end

  state(tabpage).bottom_terminal_height = clamp_bottom_height(vim.api.nvim_win_get_height(win))
end

local function ensure_bottom_window()
  local st = state()
  local win = bottom_window()
  if win then
    return win
  end

  local base = bottom_split_base_window()
  vim.api.nvim_set_current_win(base)
  vim.cmd(("botright %dsplit"):format(saved_bottom_height()))
  win = vim.api.nvim_get_current_win()
  st.bottom_win = win
  apply_bottom_window_state(win)
  return win
end

local function update_bottom_terminal_locals(term, slot)
  if not term.bufnr or not vim.api.nvim_buf_is_valid(term.bufnr) then
    return
  end

  vim.bo[term.bufnr].bufhidden = "hide"
  vim.b[term.bufnr].nvim_alt_terminal = true
  vim.b[term.bufnr].nvim_alt_bottom_terminal = true
  vim.b[term.bufnr].nvim_alt_terminal_slot = slot
  vim.b[term.bufnr].nvim_alt_terminal_role = "shell"
  vim.b[term.bufnr].nvim_alt_terminal_tab = term.tabpage
  M.attach_prompt_keys(term.bufnr)
  vim.keymap.set("t", "<Esc>", [[<C-\><C-n><Cmd>lua require('config.terminals').focus_last_file_window()<CR>]], {
    buffer = term.bufnr,
    silent = true,
    nowait = true,
    desc = "Focus last file window",
  })
end

local function focus_mode(normal_mode)
  vim.schedule(function()
    if normal_mode then
      vim.cmd.stopinsert()
    else
      vim.cmd.startinsert()
    end
  end)
end

local function create_bottom_terminal(slot)
  local st = state()
  local win = ensure_bottom_window()
  local bufnr = vim.api.nvim_create_buf(false, false)
  local tabpage = workspace.current_tab()
  local term = {
    bufnr = bufnr,
    job_id = nil,
    _nvim_alt_slot = slot,
    _nvim_alt_role = "shell",
    tabpage = tabpage,
  }

  st.terminals[slot] = term
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_buf(win, bufnr)
  update_bottom_terminal_locals(term, slot)
  term.job_id = vim.fn.termopen(shell, {
    cwd = workspace.current_cwd(),
    on_exit = function()
      vim.schedule(function()
        M.on_bottom_terminal_exit(tabpage, slot, bufnr)
      end)
    end,
  })
  update_bottom_terminal_locals(term, slot)
  return term
end

local function ensure_terminal(slot)
  local term = get_terminal(slot)
  if term then
    return term
  end

  return create_bottom_terminal(slot)
end

local function show_bottom_terminal(slot, opts)
  opts = opts or {}

  local st = state()
  local term = ensure_terminal(slot)
  local win = ensure_bottom_window()
  st.last_terminal_slot = slot
  st.bottom_win = win
  push_history(workspace.current_tab(), slot)

  vim.api.nvim_set_current_win(win)
  if vim.api.nvim_win_get_buf(win) ~= term.bufnr then
    vim.api.nvim_win_set_buf(win, term.bufnr)
  end

  apply_bottom_window_state(win)
  vim.cmd.redrawstatus()
  focus_mode(opts.normal_mode == true)
  return term
end

local function hide_bottom_window()
  local st = state()
  local win = bottom_window()
  if not win then
    return false
  end

  remember_bottom_height(workspace.current_tab(), win)

  local current = vim.api.nvim_get_current_win()
  local close_window = function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, false)
    end
    if st.bottom_win == win then
      st.bottom_win = nil
    end
  end

  if current == win and current_mode():sub(1, 1) == "t" then
    vim.cmd.stopinsert()
    vim.schedule(close_window)
  else
    close_window()
  end

  return true
end

local function next_free_slot()
  for slot = 1, terminal_count_limit() do
    if not get_terminal(slot) then
      return slot
    end
  end
end

local function agent_is_running(term)
  if not term or not term.job_id then
    return false
  end

  local status = vim.fn.jobwait({ term.job_id }, 0)[1]
  return status == -1
end

local function tracked_agent_window(tabpage)
  local st = state(tabpage)
  local win = st.agent_win
  if valid_tab_win(win, tabpage) then
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].nvim_alt_agent_terminal then
      return win
    end
  end

  st.agent_win = nil

  local term = st.agent_term
  if not term or not term.bufnr or not vim.api.nvim_buf_is_valid(term.bufnr) then
    return nil
  end

  for _, candidate in ipairs(vim.fn.win_findbuf(term.bufnr)) do
    if valid_tab_win(candidate, tabpage) then
      st.agent_win = candidate
      return candidate
    end
  end

  return nil
end

local function preferred_agent_window()
  local current = vim.api.nvim_get_current_win()
  local fallback

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(workspace.current_tab())) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[buf].buftype
      local ft = vim.bo[buf].filetype

      if bt ~= "terminal" and ft ~= "neo-tree" then
        return win
      end

      if not fallback and ft ~= "neo-tree" then
        fallback = win
      end

      if not fallback then
        fallback = win
      end
    end
  end

  return fallback or current
end

local function mark_agent_buffer(bufnr, tabpage)
  vim.bo[bufnr].bufhidden = "hide"
  vim.b[bufnr].nvim_alt_terminal = true
  vim.b[bufnr].nvim_alt_agent_terminal = true
  vim.b[bufnr].nvim_alt_terminal_role = "agent"
  vim.b[bufnr].nvim_alt_terminal_tab = tabpage or workspace.current_tab()
  vim.b[bufnr].nvim_alt_terminal_slot = vim.NIL
  M.attach_prompt_keys(bufnr)
end

local function apply_agent_window_state(win, bufnr)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.winfixheight = false
  vim.wo.winhighlight = ""
  vim.wo.winbar = ""
  state().agent_win = win
end

local function ensure_agent_term()
  local st = state()
  local term = st.agent_term

  if term and vim.api.nvim_buf_is_valid(term.bufnr) and agent_is_running(term) then
    return term
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  mark_agent_buffer(bufnr)

  term = {
    bufnr = bufnr,
    job_id = nil,
    tabpage = workspace.current_tab(),
  }

  st.agent_term = term
  return term
end

local function open_agent_terminal(opts)
  opts = opts or {}

  local term = ensure_agent_term()
  local win = tracked_agent_window()
  local cwd = workspace.current_cwd()

  if not win then
    win = preferred_agent_window()
  end

  apply_agent_window_state(win, term.bufnr)

  if not agent_is_running(term) then
    term.job_id = vim.fn.termopen(shell, { cwd = cwd })
    mark_agent_buffer(term.bufnr)
    apply_agent_window_state(win, term.bufnr)
  end

  focus_mode(opts.normal_mode == true)
  return term
end

local function paste(text, term)
  local chan = channel_for(term)
  if not chan then
    vim.notify("Terminal channel is not ready yet", vim.log.levels.WARN)
    return false
  end

  local payload = "\27[200~" .. text .. "\27[201~"
  local ok, err = pcall(vim.api.nvim_chan_send, chan, payload)
  if not ok then
    vim.notify("Не удалось передать промпт: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

-- Start a fresh shell in a restored buffer, keeping the existing tab/slot layout.
function M.restore_job(bufnr, tabpage, item, argv, cwd)
  local st = tabpage and state(tabpage) or nil
  vim.b[bufnr].nvim_alt_terminal_tab = tabpage
  local term = { bufnr = bufnr, tabpage = tabpage, _nvim_alt_slot = item.slot, _nvim_alt_role = item.role }
  if item.role == "shell" and st and type(item.slot) == "number" then
    st.terminals[item.slot] = term
    update_bottom_terminal_locals(term, item.slot)
  elseif item.role == "agent" and st then
    st.agent_term = term
    mark_agent_buffer(bufnr, tabpage)
  end
  term.job_id = vim.fn.jobstart(argv, { term = true, cwd = cwd, on_exit = function()
    if item.role == "shell" and tabpage then
      vim.schedule(function() M.on_bottom_terminal_exit(tabpage, item.slot, bufnr) end)
    end
  end })
  local ctx = workspace.prompt_contexts[item.prompt_context_id]
  if ctx then
    workspace.bind_prompt_context(ctx, bufnr, term.job_id)
    M.attach_prompt_keys(bufnr)
  end
  if item.role == "shell" and st then update_bottom_terminal_locals(term, item.slot) end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if valid_tab_win(win, tabpage) then
      if item.role == "shell" then
        vim.api.nvim_win_call(win, function() apply_bottom_window_state(win) end)
      elseif item.role == "agent" then
        vim.wo[win].number = false
        vim.wo[win].relativenumber = false
        vim.wo[win].signcolumn = "no"
      end
    end
  end
  return term.job_id
end

function M.is_bottom_window(win)
  return bottom_window() == (win or vim.api.nvim_get_current_win())
end

function M.in_bottom_window()
  return M.is_bottom_window()
end

function M.focus_last_file_window()
  local st = state()
  local win = st.last_file_win

  if is_regular_file_window(win) then
    vim.api.nvim_set_current_win(win)
    return true
  end

  for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(workspace.current_tab())) do
    if is_regular_file_window(candidate) then
      st.last_file_win = candidate
      vim.api.nvim_set_current_win(candidate)
      return true
    end
  end

  return false
end

function M.winbar()
  local st = state()
  local current_slot = vim.b.nvim_alt_terminal_slot or st.last_terminal_slot
  local labels = {
    "%#TerminalPanelTitle# TERMINALS ",
  }

  for slot = 1, terminal_count_limit() do
    if get_terminal(slot) then
      local slot_hl = slot == current_slot and "%#TerminalPanelSlotActive#" or "%#TerminalPanelSlot#"
      local slot_text = slot == current_slot and ("[%s]"):format(slot_label(slot)) or slot_label(slot)
      labels[#labels + 1] = slot_hl .. " " .. slot_text .. " "
    end
  end

  labels[#labels + 1] = "%#TerminalPanelWinBar#%*"
  return table.concat(labels, "")
end

-- Closing a tab must dispose its hidden terminals as well as its visible ones.
function M.cleanup_tab(tabpage)
  local candidates = {}
  local function collect(term)
    if term then
      candidates[term.bufnr or term] = term
    end
  end

  local st = workspace.state_by_tab[tabpage]
  if st then
    for _, term in pairs(st.terminals) do
      collect(term)
    end
    collect(st.agent_term)
    st.terminals = {}
    st.agent_term = nil
    st.terminal_history = {}
    st.last_terminal_slot = nil
    st.bottom_win = nil
    st.agent_win = nil
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[bufnr].nvim_alt_terminal_tab == tabpage and not candidates[bufnr] then
      collect({ bufnr = bufnr })
    end
  end

  local function surviving_owner(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      local owner = vim.api.nvim_win_get_tabpage(win)
      if owner ~= tabpage then
        return owner
      end
    end
    for owner, other in pairs(workspace.state_by_tab) do
      if owner ~= tabpage and vim.api.nvim_tabpage_is_valid(owner) then
        if other.agent_term and other.agent_term.bufnr == bufnr then
          return owner
        end
        for _, term in pairs(other.terminals) do
          if term.bufnr == bufnr then
            return owner
          end
        end
      end
    end
  end

  for _, term in pairs(candidates) do
    local owner = surviving_owner(term.bufnr)
    if owner then
      vim.b[term.bufnr].nvim_alt_terminal_tab = owner
    else
      local job_id = channel_for(term)
      if job_id then
        pcall(vim.fn.jobstop, job_id)
      end
      if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
        pcall(vim.api.nvim_buf_delete, term.bufnr, { force = true })
      end
    end
  end
end

function M.on_bottom_terminal_exit(tabpage, slot, bufnr)
  local st = workspace.state_by_tab[tabpage]
  if not vim.api.nvim_tabpage_is_valid(tabpage) or not st then
    return
  end
  local term = st.terminals[slot]
  if not term or term.bufnr ~= bufnr then
    return
  end

  remember_bottom_height(tabpage)
  local was_visible = visible_bottom_slot(tabpage) == slot
  st.terminals[slot] = nil
  remove_from_history(tabpage, slot)

  if st.last_terminal_slot == slot or not get_terminal(st.last_terminal_slot, tabpage) then
    st.last_terminal_slot = previous_slot(tabpage) or first_existing_slot(tabpage)
  end

  if was_visible then
    local target = st.last_terminal_slot or first_existing_slot(tabpage)
    if target then
      local current_tab = workspace.current_tab()
      local switch_back = current_tab ~= tabpage
      if switch_back then
        vim.api.nvim_set_current_tabpage(tabpage)
      end
      show_bottom_terminal(target, { normal_mode = false })
      if switch_back and vim.api.nvim_tabpage_is_valid(current_tab) then
        vim.api.nvim_set_current_tabpage(current_tab)
      end
    else
      local win = bottom_window(tabpage)
      if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
      end
      if st.bottom_win == win then
        st.bottom_win = nil
      end
    end
  end

  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  vim.cmd.redrawstatus()
end

function M.reopen_last()
  local st = state()
  local win = bottom_window()
  if win then
    hide_bottom_window()
    return
  end

  local slot = st.last_terminal_slot
  if slot and get_terminal(slot) then
    show_bottom_terminal(slot, { normal_mode = false })
    return
  end

  M.new_terminal()
end

function M.new_terminal()
  local slot = next_free_slot()
  if not slot then
    vim.notify("All 10 terminal tabs are already used in this tab", vim.log.levels.WARN)
    return
  end

  show_bottom_terminal(slot, { normal_mode = false })
end

function M.goto_slot(slot)
  if slot == 0 then
    slot = 10
  end

  if not get_terminal(slot) then
    return
  end

  show_bottom_terminal(slot, { normal_mode = false })
end

function M.open_agent(opts)
  opts = opts or {}
  open_agent_terminal({
    normal_mode = opts.normal_mode ~= false,
  })
end

function M.started_agent()
  local term = state().agent_term
  if not term or not term.bufnr or not vim.api.nvim_buf_is_valid(term.bufnr) then
    return nil
  end

  if not agent_is_running(term) then
    return nil
  end

  return term
end

function M.focus_started_agent(opts)
  opts = opts or {}
  local term = M.started_agent()
  if not term then
    return nil
  end

  local win = tracked_agent_window()
  if not win then
    win = preferred_agent_window()
  end

  apply_agent_window_state(win, term.bufnr)
  focus_mode(opts.normal_mode == true)
  return term
end

function M.attach_prompt_keys(bufnr)
  vim.keymap.set("t", "<CR>", function() M.send_terminal_key("\r") end,
    { buffer = bufnr, desc = "Submit pasted prompt" })
  vim.keymap.set("t", "<C-c>", function() M.send_terminal_key("\3") end,
    { buffer = bufnr, desc = "Cancel pending prompt submission" })
end

local function context_from_terminal(bufnr)
  local job = vim.b[bufnr].terminal_job_id
  local ok, pid = pcall(vim.fn.jobpid, job or -1)
  local cwd = ok and vim.uv.fs_readlink("/proc/" .. pid .. "/cwd") or nil
  local ctx = workspace.terminal_prompt_context(bufnr, job, cwd or workspace.current_cwd())
  M.attach_prompt_keys(bufnr)
  return ctx
end

function M.prompt_context()
  if vim.bo.buftype == "terminal" then return context_from_terminal(vim.api.nvim_get_current_buf()) end
  local ctx = workspace.context_for_path(vim.api.nvim_buf_get_name(0)) or workspace.last_prompt_context()
  if ctx then return ctx end
  local term = M.started_agent() or state().terminals[state().last_terminal_slot]
  if term and term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then return context_from_terminal(term.bufnr) end
  return workspace.new_prompt_context(workspace.current_cwd())
end

function M.focus_prompt_context(ctx)
  local buf, job = ctx.terminal_bufnr, ctx.job_id
  if not buf or not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].terminal_job_id ~= job
    or not job or vim.fn.jobwait({ job }, 0)[1] ~= -1 then return false end
  for slot, term in pairs(state().terminals) do
    if term.bufnr == buf then M.goto_slot(slot); return true end
  end
  if state().agent_term and state().agent_term.bufnr == buf then
    return M.focus_started_agent({ normal_mode = false }) ~= nil
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if valid_tab_win(win) then vim.api.nvim_set_current_win(win); focus_mode(false); return true end
  end
  vim.api.nvim_set_current_win(preferred_agent_window())
  vim.cmd("hide buffer " .. buf)
  focus_mode(false)
  return true
end

-- Only an Enter in the same live terminal can complete a queued QQ paste.
function M.send_terminal_key(key)
  local tab, buf = workspace.current_tab(), vim.api.nvim_get_current_buf()
  local ctx = workspace.context_for_terminal(buf)
  local queued = ctx and ctx.submission
  if ctx then ctx.submission = nil end
  local chan = vim.b[buf].terminal_job_id
  local ok, err = pcall(vim.api.nvim_chan_send, chan or -1, key)
  if not ok then
    vim.notify("Не удалось передать клавишу в терминал: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  if key == "\r" and queued and queued.tab == tab and queued.job_id == chan
    and ctx.job_id == chan and vim.fn.jobwait({ chan }, 0)[1] == -1
    and ctx.path == queued.path and vim.api.nvim_buf_is_valid(queued.bufnr)
    and vim.api.nvim_buf_get_name(queued.bufnr) == queued.path
    and table.concat(vim.api.nvim_buf_get_lines(queued.bufnr, 0, -1, false), "\n") == queued.text then
    workspace.mark_prompt_sent(queued.path, ctx)
  end
  return true
end

function M.paste_into_agent(text, prompt)
  local ctx = prompt and workspace.prompt_contexts[prompt.context_id]
  if not ctx then return false end
  if not ctx.terminal_bufnr then
    local term = M.started_agent() or state().terminals[state().last_terminal_slot]
    if term and term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
      workspace.bind_prompt_context(ctx, term.bufnr, vim.b[term.bufnr].terminal_job_id)
      M.attach_prompt_keys(term.bufnr)
    end
  end
  if not M.focus_prompt_context(ctx) then
    vim.notify("Терминал промпта не запущен. Откройте терминал и нажмите Ctrl+G.", vim.log.levels.WARN)
    return false
  end

  local tab = workspace.current_tab()
  ctx.submission = nil
  local chan, buf = ctx.job_id, ctx.terminal_bufnr
  if not paste(text, { job_id = chan }) then return false end
  if ctx.path == prompt.path then
    ctx.submission = {
      path = prompt.path, bufnr = prompt.bufnr, text = text,
      tab = tab, job_id = chan,
    }
  end
  vim.schedule(function()
    if workspace.current_tab() ~= tab or workspace.context_for_terminal(buf) ~= ctx
      or ctx.job_id ~= chan or vim.api.nvim_get_current_buf() ~= buf
      or vim.fn.jobwait({ chan }, 0)[1] ~= -1 then return end
    vim.cmd.startinsert()
  end)
  return true
end

function M.on_term_open()
  vim.b.nvim_alt_terminal_tab = vim.b.nvim_alt_terminal_tab or workspace.current_tab()
  if vim.b.nvim_alt_agent_terminal then
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.signcolumn = "no"
    vim.wo.winfixheight = false
    vim.wo.winhighlight = ""
    vim.wo.winbar = ""
    return
  end

  if not vim.b.nvim_alt_bottom_terminal then
    return
  end

  apply_bottom_window_state(vim.api.nvim_get_current_win())
end

function M.refresh_panel_style()
  refresh_panel_highlights()
  vim.cmd.redrawstatus()
end

return M
