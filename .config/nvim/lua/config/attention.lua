local workspace = require("config.workspace")

local M = {}
local focused = true
local notification_ids = {}
local pid = vim.fn.getpid()
local labels = { ready = "Ответ готов", question = "Дать разрешение" }
local request_prefixes = {
  "Approval requested: ",
  "Codex wants to edit ",
  "Approval requested by ",
  "Plan mode prompt: ",
  "Question: ",
}

local function notification_kind(message)
  -- OSC 9 omits the event type, so recognize Codex's request display prefixes.
  for _, prefix in ipairs(request_prefixes) do
    if message:sub(1, #prefix) == prefix then
      return "question"
    end
  end
  -- Completion notifications contain a preview of the assistant's response.
  -- "Agent turn complete" is only the fallback for an empty response.
  return "ready"
end

local function owner(bufnr)
  for tab, state in pairs(workspace.state_by_tab) do
    if vim.api.nvim_tabpage_is_valid(tab) and state.agent_term and state.agent_term.bufnr == bufnr then
      return tab
    end
  end
end

local function identifier(tab)
  return ("nvim-attention-%d-%d"):format(pid, tab)
end

local function kitty(sequence)
  if vim.env.KITTY_WINDOW_ID and #vim.api.nvim_list_uis() > 0 then
    vim.api.nvim_ui_send(sequence)
    return true
  end
  return false
end

local function dismiss(tab)
  kitty("\27]99;i=" .. identifier(tab) .. ":p=close;\27\\")
end

local function notify(tab, kind)
  local icon = kind == "ready" and "info" or "question"
  local sequence = ("\27]99;i=%s:a=focus,report:s=c2lsZW50:n=%s;%s\27\\")
    :format(identifier(tab), vim.base64.encode(icon), labels[kind])
  if kitty(sequence) then
    return
  end

  if vim.fn.executable("notify-send") == 1 then
    local args = { "notify-send", "--app-name=Terminal", "--icon=utilities-terminal", "--print-id" }
    if notification_ids[tab] then
      args[#args + 1] = "--replace-id=" .. notification_ids[tab]
    end
    args[#args + 1] = labels[kind]
    vim.system(args, { text = true }, function(result)
      if result.code == 0 then
        vim.schedule(function()
          notification_ids[tab] = tonumber(result.stdout)
        end)
      end
    end)
  end
end

function M.status(tab)
  return workspace.state_by_tab[tab] and workspace.state_by_tab[tab].attention
end

function M.receive(bufnr, sequence)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].nvim_alt_agent_terminal then
    return
  end
  local message = sequence:match("^\27%]9;(.*)")
  if not message then
    return
  end
  message = message:gsub("\27\\$", ""):gsub("\7$", "")
  local tab = owner(bufnr)
  if not tab then
    return
  end
  local kind = notification_kind(message)
  workspace.state(tab).attention = kind
  vim.cmd.redrawtabline()
  notify(tab, kind)
end

function M.acknowledge(bufnr)
  if not focused then
    return
  end
  local tab = owner(bufnr)
  if tab and tab == vim.api.nvim_get_current_tabpage() and M.status(tab) then
    workspace.state(tab).attention = nil
    dismiss(tab)
    vim.cmd.redrawtabline()
  end
end

function M.activate(sequence)
  local response_pid, tab = sequence:match("^\27%]99;i=nvim%-attention%-(%d+)%-(%d+);")
  tab = tonumber(tab)
  if tonumber(response_pid) ~= pid or not tab or not vim.api.nvim_tabpage_is_valid(tab) then
    return
  end
  local state = workspace.state_by_tab[tab]
  if not state or not state.agent_term or not vim.api.nvim_buf_is_valid(state.agent_term.bufnr) then
    return
  end
  focused = true
  vim.api.nvim_set_current_tabpage(tab)
  require("config.terminals").open_agent()
  M.acknowledge(state.agent_term.bufnr)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("nvim-attention", { clear = true })
  local function highlights()
    vim.api.nvim_set_hl(0, "TabLineReady", { fg = "#a8cc8c", bg = "#3a3a3a", bold = true })
    vim.api.nvim_set_hl(0, "TabLineQuestion", { fg = "#ffc66d", bg = "#3a3a3a", bold = true })
  end
  highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  vim.api.nvim_create_autocmd("TermRequest", {
    group = group,
    callback = function(ev)
      local sequence = ev.data.sequence
      vim.schedule(function() M.receive(ev.buf, sequence) end)
    end,
  })
  vim.api.nvim_create_autocmd("TermResponse", {
    group = group,
    callback = function(ev)
      local sequence = ev.data.sequence
      vim.schedule(function() M.activate(sequence) end)
    end,
  })
  vim.api.nvim_create_autocmd("FocusLost", { group = group, callback = function() focused = false end })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      focused = true
      M.acknowledge(vim.api.nvim_get_current_buf())
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TermEnter" }, {
    group = group,
    callback = function() M.acknowledge(vim.api.nvim_get_current_buf()) end,
  })
  vim.api.nvim_create_autocmd({ "TermClose", "BufWipeout" }, {
    group = group,
    callback = function(ev)
      local tab = owner(ev.buf)
      if tab then
        workspace.state(tab).attention = nil
        dismiss(tab)
        vim.cmd.redrawtabline()
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      for tab, state in pairs(workspace.state_by_tab) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          state.attention = nil
          notification_ids[tab] = nil
          dismiss(tab)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for tab in pairs(workspace.state_by_tab) do
        if M.status(tab) then
          dismiss(tab)
        end
      end
    end,
  })
  vim.on_key(function()
    if vim.api.nvim_get_mode().mode == "t" then
      local bufnr = vim.api.nvim_get_current_buf()
      if M.status(vim.api.nvim_get_current_tabpage()) then
        vim.schedule(function() M.acknowledge(bufnr) end)
      end
    end
  end, vim.api.nvim_create_namespace("nvim-attention-keys"))
end

return M
