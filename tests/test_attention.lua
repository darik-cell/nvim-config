-- Run with: nvim --headless -u NONE -l tests/test_attention.lua
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
package.path = root .. "/.config/nvim/lua/?.lua;" .. package.path

local workspace = require("config.workspace")
local attention = require("config.attention")
local tabline = require("config.tabline")
local output, jobs = {}, {}
local real_uis, real_send = vim.api.nvim_list_uis, vim.api.nvim_ui_send
vim.env.KITTY_WINDOW_ID = "test"
vim.api.nvim_list_uis = function() return { {} } end
vim.api.nvim_ui_send = function(sequence) output[#output + 1] = sequence end
attention.setup()

local checks = 0
local function check(condition, message)
  assert(condition, message)
  checks = checks + 1
end

local child = [[
import json, sys, termios
attrs = termios.tcgetattr(sys.stdin.fileno())
attrs[3] &= ~termios.ECHO
termios.tcsetattr(sys.stdin.fileno(), termios.TCSANOW, attrs)
print('notification-test-ready', flush=True)
for line in sys.stdin:
    message, terminator = json.loads(line)
    sys.stdout.write(chr(27) + ']9;' + message + (chr(7) if terminator == 'BEL' else chr(27) + chr(92)))
    sys.stdout.flush()
]]

local function terminal()
  vim.cmd.tabnew()
  local tab, buf = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_buf()
  vim.b[buf].nvim_alt_agent_terminal = true
  local job = vim.fn.termopen({ "/usr/bin/python3", "-u", "-c", child })
  jobs[#jobs + 1] = job
  workspace.state(tab).agent_term = { bufnr = buf, job_id = job }
  check(vim.wait(2000, function()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):find("notification%-test%-ready") ~= nil
  end), "terminal child did not become ready")
  return { tab = tab, buf = buf, job = job }
end

local function send(term, message, expected, terminator)
  local before = #output
  vim.fn.chansend(term.job, vim.json.encode({ message, terminator or "BEL" }) .. "\n")
  check(vim.wait(2000, function() return #output > before end), "OSC 9 event was not received")
  check(attention.status(term.tab) == expected, "wrong status for " .. message)
  local title = expected == "ready" and "Ответ готов" or "Дать разрешение"
  check(output[#output]:find(";" .. title .. "\27\\", 1, true) ~= nil, "wrong desktop title")
  check(output[#output]:find(message, 1, true) == nil, "original text leaked into desktop notification")
end

local function run()
  local first, second = terminal(), terminal()
  vim.cmd.tabnew() -- Keep both agent buffers in the background.

  send(first, "Исправил обработчик и проверил результат.", "ready")
  send(second, "Approval requested: private command", "question")
  check(attention.status(first.tab) == "ready", "second tab changed first tab's status")
  check(tabline.render():find("✓", 1, true) ~= nil, "ready mark is absent")
  check(tabline.render():find("?", 1, true) ~= nil, "question mark is absent")

  for _, preview in ipairs({
    "Agent turn complete",
    "Done. Approval requested: is a notification prefix.",
    "Ответ готов. Question: находится внутри ответа.",
    "Server: the connection was restored.",
  }) do
    send(first, preview, "ready", "ST")
  end
  for _, request in ipairs({
    "Approval requested: private command",
    "Codex wants to edit private/path",
    "Approval requested by private-server",
    "Plan mode prompt: private title",
    "Question: private question",
  }) do
    send(second, request, "question", "ST")
  end

  local before = #output
  attention.receive(first.buf, "\27]7;file:///unrelated")
  check(#output == before, "non-notification OSC produced a desktop notification")
  vim.b[first.buf].nvim_alt_agent_terminal = false
  attention.receive(first.buf, "\27]9;Done")
  check(#output == before, "unmarked terminal produced a desktop notification")
  vim.b[first.buf].nvim_alt_agent_terminal = true

  vim.api.nvim_set_current_tabpage(first.tab)
  check(attention.status(first.tab) == nil, "viewed terminal was not acknowledged")
  check(attention.status(second.tab) == "question", "another tab was acknowledged")
end

local ok, err = xpcall(run, debug.traceback)
for _, job in ipairs(jobs) do vim.fn.jobstop(job) end
vim.api.nvim_list_uis, vim.api.nvim_ui_send = real_uis, real_send
if not ok then error(err) end
print(("PASS: %d assertions with real OSC 9 terminal output"):format(checks))
