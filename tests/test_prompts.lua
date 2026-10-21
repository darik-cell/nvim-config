-- Run: nvim --headless -u NONE -l tests/test_prompts.lua
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
package.path = root .. "/.config/nvim/lua/?.lua;" .. package.path
package.loaded["mini.pairs"] = {}
package.loaded["config.tree"] = { open_tree = function() end, copy_cursor_path = function() end }
vim.opt.hidden, vim.opt.swapfile, vim.opt.shadafile = true, false, "NONE"
vim.opt.shell = "/bin/sh"
vim.opt.wrap = false
vim.g.mapleader = " "
vim.cmd("filetype on")
local workspace = require("config.workspace")
local markdown = require("config.markdown")
local terminals = require("config.terminals")
require("config.keymaps")
require("config.autocmds")
local checks, directories, jobs = 0, {}, {}
local original_send = vim.api.nvim_chan_send
local function check(condition, message)
  assert(condition, message)
  checks = checks + 1
end
local function open()
  local path = markdown.open_prompt()
  check(path ~= nil, "could not open prompt")
  directories[vim.fs.dirname(path)] = true
  return path, vim.api.nvim_get_current_buf(), workspace.context_for_path(path)
end
local function terminal(role, slot)
  local buf = vim.api.nvim_create_buf(true, false)
  local child = [[
import os, sys, tty
tty.setraw(sys.stdin.fileno())
print("prompt-terminal-ready", flush=True)
while os.read(sys.stdin.fileno(), 4096):
    pass
]]
  local job = vim.api.nvim_buf_call(buf, function()
    return terminals.restore_job(buf, workspace.current_tab(), { role = role, slot = slot },
      { "/usr/bin/python3", "-u", "-c", child }, workspace.current_cwd())
  end)
  jobs[#jobs + 1] = job
  check(vim.wait(2000, function()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):find("prompt-terminal-ready", 1, true) ~= nil
  end), "terminal did not become ready")
  return buf
end
local function show(buf) vim.cmd("hide buffer " .. buf) end
local function press(ctx, key)
  check(terminals.focus_prompt_context(ctx), "cannot focus prompt terminal")
  local mapping = vim.fn.maparg(key, "t", false, true)
  check(mapping.buffer == 1 and type(mapping.callback) == "function", "missing terminal key mapping")
  mapping.callback()
end
local function run()
  for _, mode in ipairs({ "n", "i", "t" }) do
    check(vim.fn.maparg("<C-g>", mode, false, true).callback == markdown.open_prompt, "wrong Ctrl+G mapping")
  end
  check(vim.fn.maparg(" gp", "n", false, true).callback == markdown.open_scratch, "wrong gp mapping")
  local home = vim.fs.normalize(vim.fn.expand("~"))
  check(workspace.prompt_base(home .. "/work/test") == "/tmp/work/test", "home hierarchy not mirrored")
  check(workspace.prompt_base(home) == "/tmp", "home root not mirrored")
  check(workspace.prompt_base(home .. "-other/test"):find("/tmp/_outside-home/", 1, true) == 1, "home boundary ignored")
  check(workspace.make_prompt_name(os.time({ year = 2026, month = 10, day = 21, hour = 12, min = 30 }))
    == "21-октября-СР-12:30.md", "original filename format not restored")

  local agent = terminal("agent")
  show(agent)
  vim.wo.wrap, vim.wo.linebreak = false, false
  local first, buf, ctx = open()
  check(vim.wo.wrap and vim.wo.linebreak, "prompt opened without soft wrap")
  check(ctx.terminal_bufnr == agent, "prompt not bound to initiating terminal")
  check(first:find(workspace.prompt_base(workspace.current_cwd()) .. "/session-", 1, true) == 1, "wrong session directory")
  check(vim.uv.fs_stat(first).mode % 512 == 384, "wrong file permissions")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved draft", "second line" })
  check(open() == first and vim.api.nvim_get_current_buf() == buf, "draft not reused")
  check(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved draft", "draft contents lost")
  press(ctx, "<CR>")
  check(ctx.path == first, "Enter without QQ retired draft")
  show(buf)
  vim.api.nvim_chan_send = function() error("simulated paste failure") end
  check(markdown.send_prompt_buffer() == false, "failed paste reported success")
  vim.api.nvim_chan_send = original_send
  check(ctx.path == first, "failed paste retired draft")
  show(buf)
  local payload, target
  vim.api.nvim_chan_send = function(chan, text) target, payload = chan, text; return original_send(chan, text) end
  check(markdown.send_prompt_buffer(), "QQ failed")
  vim.api.nvim_chan_send = original_send
  check(target == ctx.job_id and payload == "\27[200~unsaved draft\nsecond line\27[201~", "QQ target/payload changed")
  check(ctx.path == first and open() == first, "QQ alone replaced draft")
  press(ctx, "<C-c>"); press(ctx, "<CR>")
  check(ctx.path == first, "Ctrl+C did not cancel submission")
  show(buf); check(markdown.send_prompt_buffer(), "repeat QQ failed")
  show(buf); vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited draft" })
  press(ctx, "<CR>")
  check(ctx.path == first, "modified draft retired")

  local bottom = terminal("shell", 1)
  show(bottom)
  local other, other_buf, other_ctx = open()
  check(ctx.id ~= other_ctx.id and vim.fs.dirname(first) ~= vim.fs.dirname(other), "terminals share session directory")
  check(other_ctx.terminal_bufnr == bottom, "bottom terminal ownership lost")
  vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "bottom prompt" })
  check(markdown.send_prompt_buffer(), "bottom terminal QQ failed")
  check(vim.api.nvim_get_current_buf() == bottom, "bottom QQ targeted agent terminal")
  press(ctx, "<CR>")
  check(other_ctx.path == other, "Enter in wrong terminal retired draft")
  press(other_ctx, "<CR>")
  check(other_ctx.path == nil and ctx.path == first, "submission crossed terminal contexts")
  show(bottom)
  local next_other = open()
  check(next_other ~= other and vim.fs.dirname(next_other) == vim.fs.dirname(other), "next draft changed session directory")
  show(agent); check(open() == first, "agent Ctrl+G lost its draft")

  show(buf); check(markdown.send_prompt_buffer(), "QQ before failed Enter failed")
  vim.api.nvim_chan_send = function() error("simulated Enter failure") end
  press(ctx, "<CR>")
  vim.api.nvim_chan_send = original_send
  check(ctx.path == first and ctx.submission == nil, "failed Enter completed draft or retained stale queue")
  show(buf); check(markdown.send_prompt_buffer(), "final QQ failed")
  local first_tab = workspace.current_tab()
  vim.cmd.tabnew()
  local second_tab = workspace.current_tab()
  vim.wait(50)
  check(workspace.current_tab() == second_tab, "scheduled paste stole tab focus")
  vim.api.nvim_set_current_tabpage(first_tab)
  press(ctx, "<CR>")
  check(ctx.path == nil, "QQ + Enter did not retire draft")
  show(agent)
  local next_first = open()
  check(next_first ~= first and vim.fs.dirname(next_first) == vim.fs.dirname(first), "new draft has wrong directory/name")
  show(buf); check(markdown.send_prompt_buffer(), "archived QQ failed")
  press(ctx, "<CR>")
  check(ctx.path == next_first, "archived prompt retired current draft")
  show(agent); check(open() == next_first, "archived file revived")

  vim.wo.wrap, vim.wo.linebreak = false, false
  local scratch = markdown.open_scratch()
  check(vim.wo.wrap and vim.wo.linebreak, "scratch opened without soft wrap")
  check(vim.bo[scratch].buftype == "nofile" and vim.bo[scratch].filetype == "markdown", "scratch not Markdown nofile")
  check(vim.api.nvim_buf_get_name(scratch) == "", "scratch has a filename")
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "keep this tab note" })
  show(buf)
  check(markdown.open_scratch() == scratch, "gp did not reuse tab buffer")
  check(vim.api.nvim_buf_get_lines(scratch, 0, -1, false)[1] == "keep this tab note", "scratch text lost")
  -- Hidden buffers must receive Markdown options in each destination window.
  vim.cmd.vsplit()
  local markdown_win = vim.api.nvim_get_current_win()
  show(agent)
  vim.wo.wrap, vim.wo.linebreak = false, false
  local terminal_win = markdown_win
  vim.cmd.vsplit()
  markdown_win = vim.api.nvim_get_current_win()
  vim.wo.wrap, vim.wo.linebreak = false, false
  show(scratch)
  check(vim.wo.wrap and vim.wo.linebreak, "scratch reopened in nowrap window")
  local long_line = string.rep("long word ", 50)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { long_line })
  check(vim.api.nvim_win_text_height(markdown_win, { start_row = 0, end_row = 0 }).all > 1,
    "long Markdown line is not visually wrapped")
  check(vim.api.nvim_buf_line_count(scratch) == 1
    and vim.api.nvim_buf_get_lines(scratch, 0, -1, false)[1] == long_line, "soft wrap changed file text")
  check(not vim.wo[terminal_win].wrap and not vim.wo[terminal_win].linebreak, "Markdown changed another terminal window")
  vim.api.nvim_set_current_win(terminal_win)
  vim.api.nvim_set_current_win(markdown_win)
  check(vim.wo.wrap and vim.wo.linebreak, "Markdown wrap lost after switching windows")
  vim.wo.wrap, vim.wo.linebreak = false, false
  show(buf)
  check(vim.wo.wrap and vim.wo.linebreak, "prompt reopened without soft wrap")
  check(not vim.wo[terminal_win].wrap, "reopening prompt changed terminal wrap")
  vim.api.nvim_set_current_tabpage(second_tab)
  local second_scratch = markdown.open_scratch()
  check(second_scratch ~= scratch, "scratch shared across tabs")
  vim.api.nvim_buf_set_lines(second_scratch, 0, -1, false, { "delete on close" })
  vim.cmd.tabclose()
  check(not vim.api.nvim_buf_is_valid(second_scratch), "closed tab scratch was only hidden")
  check(vim.api.nvim_buf_is_valid(scratch) and markdown.open_scratch() == scratch, "closing tab deleted surviving scratch")
  vim.cmd.tabnew()
  local third_scratch = markdown.open_scratch()
  vim.cmd.tabnew()
  local surviving_scratch = markdown.open_scratch()
  vim.cmd.tabonly()
  check(not vim.api.nvim_buf_is_valid(scratch) and not vim.api.nvim_buf_is_valid(third_scratch), "tabonly did not wipe closed scratch buffers")
  check(vim.api.nvim_buf_is_valid(surviving_scratch), "tabonly deleted active scratch")
end
local ok, err = xpcall(run, debug.traceback)
vim.api.nvim_chan_send = original_send
for _, job in ipairs(jobs) do pcall(vim.fn.jobstop, job) end
for dir in pairs(directories) do vim.fn.delete(dir, "rf") end
if not ok then error(err) end
print(("PASS: %d prompt/scratch assertions"):format(checks))
