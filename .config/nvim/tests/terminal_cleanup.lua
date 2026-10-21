-- Run without loading plugins or touching an existing editor session:
-- nvim --headless -u NONE -i NONE -l .config/nvim/tests/terminal_cleanup.lua
local script = debug.getinfo(1, "S").source:sub(2)
local config = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ":p")))
package.path = config .. "/lua/?.lua;" .. package.path
package.loaded["config.markdown"] = {}
vim.opt.hidden = true
vim.o.shell = "/bin/sh"

local workspace = require("config.workspace")
local terminals = require("config.terminals")
require("config.autocmds")
local jobs = {}
local passed = 0

local function check(value, message)
  assert(value, message)
end

local function running(term)
  return vim.fn.jobwait({ term.job_id }, 0)[1] == -1
end

local function stopped(term)
  check(vim.wait(4000, function() return not running(term) end, 10), "terminal job still running")
  check(not vim.api.nvim_buf_is_valid(term.bufnr), "terminal buffer still exists")
end

local function new_tab()
  vim.cmd.tabnew()
  return vim.api.nvim_get_current_tabpage()
end

local function spawn(tab, role, slot, argv)
  local buf = vim.api.nvim_create_buf(false, true)
  local job
  vim.api.nvim_buf_call(buf, function()
    job = terminals.restore_job(buf, tab, { role = role, slot = slot }, argv or { "/bin/sh" }, "/tmp")
  end)
  check(job > 0, "failed to start test job")
  local term = { bufnr = buf, job_id = job }
  jobs[#jobs + 1] = job
  if not argv then check(running(term), "test job did not start") end
  return term
end

local function close_tab(tab)
  vim.api.nvim_set_current_tabpage(tab)
  vim.cmd("tabclose!")
end

local function test(name, body)
  body()
  check(vim.v.errmsg == "", "unexpected Neovim error: " .. vim.v.errmsg)
  passed = passed + 1
  print("PASS " .. name)
end

local ok, err = xpcall(function()
  test("closing a tab stops visible, hidden and agent terminals; other tabs survive", function()
    local survivor_tab = vim.api.nvim_get_current_tabpage()
    local survivor = spawn(survivor_tab, "shell", 1)
    local tab = new_tab()
    local visible = spawn(tab, "shell", 1)
    local hidden = spawn(tab, "shell", 2)
    local agent = spawn(tab, "agent")
    vim.api.nvim_set_current_buf(visible.bufnr)
    close_tab(tab)
    stopped(visible)
    stopped(hidden)
    stopped(agent)
    check(running(survivor), "closed another tab terminal")
    check(vim.api.nvim_buf_is_valid(survivor.bufnr), "deleted another tab buffer")
    check(workspace.state_by_tab[tab] == nil, "closed tab state was recreated")
    terminals.on_bottom_terminal_exit(tab, 1, visible.bufnr)
    check(workspace.state_by_tab[tab] == nil, "late exit recreated closed tab state")
  end)

  test(":q hides a terminal while its tab remains open", function()
    local tab = new_tab()
    local term = spawn(tab, "shell", 1)
    vim.cmd.split()
    vim.api.nvim_set_current_buf(term.bufnr)
    vim.cmd.quit()
    check(vim.api.nvim_tabpage_is_valid(tab), "tab unexpectedly closed")
    check(running(term), "closing a window stopped its terminal")
    check(vim.api.nvim_buf_is_valid(term.bufnr), "hidden terminal was deleted")
    close_tab(tab)
    stopped(term)
  end)

  test(":q stops terminals when it closes the last window of a tab", function()
    local tab = new_tab()
    local term = spawn(tab, "agent")
    vim.api.nvim_set_current_buf(term.bufnr)
    vim.cmd.quit()
    check(not vim.api.nvim_tabpage_is_valid(tab), "tab did not close")
    stopped(term)
  end)

  test("ownership finds untracked terminals and falls back to terminal_job_id", function()
    local tab = new_tab()
    local forgotten = spawn(tab, "agent")
    local current = spawn(tab, "agent")
    local bottom = spawn(tab, "shell", 1)
    workspace.state(tab).terminals[1].job_id = nil
    local duplicate = workspace.state(tab).terminals[1]
    workspace.state(tab).terminals[2] = duplicate
    close_tab(tab)
    stopped(forgotten)
    stopped(current)
    stopped(bottom)
    terminals.cleanup_tab(tab)
  end)

  test("restoring into a non-current tab preserves terminal ownership", function()
    local tab = new_tab()
    vim.cmd.tabprevious()
    local term = spawn(tab, nil)
    check(vim.b[term.bufnr].nvim_alt_terminal_tab == tab, "restore assigned wrong owner")
    close_tab(tab)
    stopped(term)
  end)

  test("terminal shared with a surviving tab remains alive", function()
    local keeper = new_tab()
    local tab = new_tab()
    local term = spawn(tab, "agent")
    workspace.state(keeper).agent_term = { bufnr = term.bufnr, job_id = term.job_id }
    close_tab(tab)
    check(running(term), "shared terminal stopped")
    check(vim.b[term.bufnr].nvim_alt_terminal_tab == keeper, "shared terminal ownership not transferred")
    close_tab(keeper)
    stopped(term)
  end)

  test("stale buffers and exited jobs tolerate cleanup", function()
    local tab = new_tab()
    local exited = spawn(tab, "agent", nil, { "/bin/sh", "-c", "exit 0" })
    check(vim.wait(4000, function() return not running(exited) end, 10), "short job did not exit")
    local deleted = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_delete(deleted, { force = true })
    workspace.state(tab).terminals[1] = { bufnr = deleted }
    close_tab(tab)
    stopped(exited)
    terminals.cleanup_tab(tab)
  end)

  test("ordinary terminal and its foreground child stop on tab closure", function()
    local tab = new_tab()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local job = vim.fn.jobstart({ "/bin/bash", "--noprofile", "--norc" }, { term = true })
    jobs[#jobs + 1] = job
    local term = { bufnr = buf, job_id = job }
    local pid = vim.fn.jobpid(job)
    vim.fn.chansend(job, "sleep 300\n")
    local child
    check(vim.wait(4000, function()
      local file = io.open(("/proc/%d/task/%d/children"):format(pid, pid), "r")
      if not file then return false end
      local text = file:read("*a")
      file:close()
      child = tonumber(text:match("%d+"))
      return child ~= nil
    end, 10), "foreground child did not start")
    close_tab(tab)
    stopped(term)
    check(vim.wait(4000, function()
      local file = io.open(("/proc/%d/stat"):format(child), "r")
      if not file then return true end
      local stat = file:read("*a")
      file:close()
      return stat:match("%) Z ") ~= nil
    end, 10), "foreground child survived closing the tab")
    check(workspace.state_by_tab[tab] == nil, "ordinary terminal recreated tab state")
  end)
end, debug.traceback)

-- Only jobs created by this isolated test instance are stopped here.
for _, job in ipairs(jobs) do
  pcall(vim.fn.jobstop, job)
end
vim.wait(100, function() return false end, 10)
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print(("All %d terminal cleanup tests passed"):format(passed))
  vim.cmd("qa!")
end
