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
    check(vim.fn.maparg("<C-g>", mode, false, true).callback == markdown.toggle_prompt, "wrong Ctrl+G mapping")
  end
  check(vim.fn.maparg(" gp", "n", false, true).callback == markdown.open_scratch, "wrong gp mapping")
  local home = vim.fs.normalize(vim.fn.expand("~"))
  check(workspace.prompt_base(home .. "/work/test") == "/tmp/work/test", "home hierarchy not mirrored")
  check(workspace.prompt_base(home) == "/tmp", "home root not mirrored")
  check(workspace.prompt_base(home .. "-other/test"):find("/tmp/_outside-home/", 1, true) == 1, "home boundary ignored")
  check(workspace.make_prompt_name(os.time({ year = 2026, month = 10, day = 21, hour = 12, min = 30 }))
    == "21-октября-СР-12:30.md", "original filename format not restored")

  for _, mode in ipairs({ "n", "i", "t" }) do
    check(type(vim.fn.maparg("<C-w>w", mode, false, true).callback) == "function", "missing Ctrl+W W mapping")
  end
  local agent = terminal("agent")
  show(agent)
  local agent_win = vim.api.nvim_get_current_win()
  markdown.toggle_prompt()
  local first, buf, ctx = vim.api.nvim_buf_get_name(0), vim.api.nvim_get_current_buf(), workspace.context_for_path(vim.api.nvim_buf_get_name(0))
  check(ctx and ctx.terminal_bufnr == agent, "prompt not bound to initiating terminal")
  directories[vim.fs.dirname(first)] = true
  local editor_win = vim.api.nvim_get_current_win()
  check(editor_win ~= agent_win and vim.api.nvim_win_get_position(editor_win)[2] > vim.api.nvim_win_get_position(agent_win)[2], "prompt not in right split")
  check(vim.wo.wrap and vim.wo.linebreak, "prompt opened without soft wrap")
  check(vim.uv.fs_stat(first).mode % 512 == 384, "wrong file permissions")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved draft", "second line" })
  markdown.toggle_prompt()
  check(not vim.api.nvim_win_is_valid(editor_win), "Ctrl+G did not close prompt pane")
  check(vim.api.nvim_get_current_buf() == agent and ctx.path == first, "toggle lost terminal or draft")
  check(table.concat(vim.fn.readfile(first), "\n") == "unsaved draft\nsecond line", "toggle failed to save draft")
  markdown.toggle_prompt()
  editor_win = vim.api.nvim_get_current_win()
  check(vim.api.nvim_get_current_buf() == buf and ctx.path == first, "toggle did not reopen same draft")
  check(vim.api.nvim_get_current_line() == "unsaved draft", "toggle lost text")
  press(ctx, "<CR>")
  check(ctx.path == first, "Enter without QQ retired draft")
  vim.api.nvim_set_current_win(editor_win)
  vim.api.nvim_chan_send = function() error("simulated paste failure") end
  check(markdown.send_prompt_buffer() == false, "failed paste reported success")
  vim.api.nvim_chan_send = original_send
  check(ctx.path == first and vim.api.nvim_win_is_valid(editor_win), "failed paste closed or retired draft")
  vim.api.nvim_set_current_win(editor_win)
  local payload, target
  vim.api.nvim_chan_send = function(chan, text) target, payload = chan, text; return original_send(chan, text) end
  check(markdown.send_prompt_buffer(), "QQ failed")
  vim.api.nvim_chan_send = original_send
  check(target == ctx.job_id and payload == "\27[200~unsaved draft\nsecond line\27[201~", "QQ target/payload changed")
  check(not vim.api.nvim_win_is_valid(editor_win) and ctx.path == first, "QQ did not hide pane or retired early")
  check(vim.api.nvim_get_current_buf() == agent, "QQ did not focus source terminal")
  press(ctx, "<C-c>"); press(ctx, "<CR>")
  check(ctx.path == first, "Ctrl+C did not cancel retirement")
  markdown.toggle_prompt(); editor_win = vim.api.nvim_get_current_win()
  check(vim.api.nvim_get_current_buf() == buf, "cancelled draft not reused")
  check(markdown.send_prompt_buffer(), "QQ after cancel failed")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited after QQ" })
  press(ctx, "<CR>")
  check(ctx.path == first, "edited draft retired")
  markdown.toggle_prompt(); check(markdown.send_prompt_buffer(), "QQ after edit failed")
  vim.api.nvim_chan_send = function() error("simulated Enter failure") end
  press(ctx, "<CR>"); vim.api.nvim_chan_send = original_send
  check(ctx.path == first, "failed Enter retired draft")
  markdown.toggle_prompt(); check(markdown.send_prompt_buffer(), "QQ before successful Enter failed")
  local win_count = #vim.api.nvim_tabpage_list_wins(0)
  press(ctx, "<CR>")
  check(ctx.path == nil and #vim.api.nvim_tabpage_list_wins(0) == win_count, "Enter did not retire or opened a split")
  press(ctx, "<CR>"); check(ctx.path == nil, "later Enter created a draft")
  markdown.toggle_prompt()
  local next_first, fresh_buf = ctx.path, vim.api.nvim_get_current_buf()
  check(next_first and next_first ~= first, "Ctrl+G did not create fresh draft")
  check(vim.api.nvim_get_current_line() == "", "fresh draft not empty")
  vim.api.nvim_buf_set_lines(fresh_buf, 0, -1, false, { "second draft" })
  check(markdown.send_prompt_buffer(), "second draft QQ failed")
  press(ctx, "<CR>"); check(ctx.path == nil, "second draft not retired")
  check(table.concat(vim.fn.readfile(next_first), "\n") == "second draft", "second draft not saved")

  local bottom = terminal("shell", 1)
  show(bottom); markdown.toggle_prompt()
  local other, other_buf = vim.api.nvim_buf_get_name(0), vim.api.nvim_get_current_buf()
  local other_ctx = workspace.context_for_path(other)
  directories[vim.fs.dirname(other)] = true
  check(ctx.id ~= other_ctx.id, "terminals share context")
  vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "bottom prompt" })
  check(markdown.send_prompt_buffer(), "bottom QQ failed")
  press(ctx, "<CR>"); check(other_ctx.path == other, "wrong terminal retired draft")
  press(other_ctx, "<CR>"); check(other_ctx.path == nil, "bottom Enter did not retire draft")
  show(agent); markdown.toggle_prompt()
  local fail_path, fail_buf = ctx.path, vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(fail_buf, 0, -1, false, { "keep on save failure" })
  vim.bo[fail_buf].readonly = true
  local sends = 0
  vim.api.nvim_chan_send = function(...) sends = sends + 1; return original_send(...) end
  check(not markdown.send_prompt_buffer(), "readonly save reported success")
  vim.api.nvim_chan_send = original_send
  vim.bo[fail_buf].readonly = false
  check(sends == 0 and ctx.path == fail_path, "save failure pasted or retired draft")
  check(vim.api.nvim_buf_get_lines(fail_buf, 0, -1, false)[1] == "keep on save failure", "save failure lost text")
  markdown.toggle_prompt()
  check(table.concat(vim.fn.readfile(fail_path), "\n") == "keep on save failure", "toggle did not save restored draft")
  -- Unrelated editor must survive repeated prompt toggles and cycling.
  vim.cmd("rightbelow vsplit")
  local unrelated_win = vim.api.nvim_get_current_win()
  local unrelated_buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(unrelated_win, unrelated_buf)
  vim.api.nvim_buf_set_lines(unrelated_buf, 0, -1, false, { "other editor" })
  vim.api.nvim_set_current_win(agent_win)
  markdown.toggle_prompt()
  local reopened_win = vim.api.nvim_get_current_win()
  check(vim.api.nvim_win_get_buf(unrelated_win) == unrelated_buf, "toggle replaced unrelated editor")
  markdown.cycle_agent_prompt()
  check(vim.api.nvim_get_current_buf() == agent, "cycle did not focus agent")
  markdown.cycle_agent_prompt()
  check(vim.api.nvim_get_current_win() == reopened_win, "cycle did not focus visible prompt")
  markdown.toggle_prompt()
  local without_prompt = #vim.api.nvim_tabpage_list_wins(0)
  markdown.cycle_agent_prompt()
  check(#vim.api.nvim_tabpage_list_wins(0) == without_prompt, "cycle recreated hidden prompt")
  check(vim.api.nvim_win_get_buf(unrelated_win) == unrelated_buf, "cycle replaced unrelated editor")

  -- Opening from a named modified file must not displace its editor.
  vim.cmd.tabnew()
  local file_win, file_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local file_path = vim.fn.tempname() .. ".txt"
  vim.api.nvim_buf_set_name(file_buf, file_path)
  vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { "unsaved ordinary file" })
  check(vim.bo[file_buf].modified, "ordinary file must start modified")
  markdown.toggle_prompt()
  local opened_ctx = workspace.context_for_path(vim.api.nvim_buf_get_name(0))
  check(opened_ctx and opened_ctx.terminal_bufnr, "file Ctrl+G did not create agent context")
  directories[vim.fs.dirname(opened_ctx.path)] = true
  jobs[#jobs + 1] = opened_ctx.job_id
  check(vim.api.nvim_win_is_valid(file_win) and vim.api.nvim_win_get_buf(file_win) == file_buf, "file Ctrl+G displaced original editor")
  check(vim.api.nvim_buf_get_lines(file_buf, 0, 1, false)[1] == "unsaved ordinary file", "file Ctrl+G lost modification")
  local opened_prompt_win = vim.api.nvim_get_current_win()
  local agent_wins = vim.fn.win_findbuf(opened_ctx.terminal_bufnr)
  check(#agent_wins > 0 and vim.api.nvim_win_get_position(agent_wins[1])[2] < vim.api.nvim_win_get_position(opened_prompt_win)[2], "new agent is not left of prompt")
  vim.api.nvim_win_close(agent_wins[1], true)
  -- Source window can disappear; Ctrl+G keeps the remaining window alive and restores the terminal.
  vim.api.nvim_win_close(file_win, true)
  check(markdown.toggle_prompt(), "toggle failed after source window closed")
  check(vim.api.nvim_win_is_valid(opened_prompt_win) and vim.api.nvim_get_current_buf() == opened_ctx.terminal_bufnr, "toggle did not restore source in last window")
  vim.cmd.tabclose()
  vim.fn.delete(file_path)

  vim.cmd.tabnew()
  local dead_terminal = terminal("agent")
  show(dead_terminal); markdown.toggle_prompt()
  local dead_editor = vim.api.nvim_get_current_win()
  local dead_buf, dead_path = vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_name(0)
  directories[vim.fs.dirname(dead_path)] = true
  vim.api.nvim_buf_set_lines(dead_buf, 0, -1, false, { "survive dead terminal" })
  local dead_job = vim.b[dead_terminal].terminal_job_id
  vim.fn.jobstop(dead_job)
  vim.wait(2000, function() return vim.fn.jobwait({ dead_job }, 0)[1] ~= -1 end, 10)
  check(not markdown.toggle_prompt(), "dead terminal toggle reported success")
  check(vim.api.nvim_win_is_valid(dead_editor) and vim.api.nvim_win_get_buf(dead_editor) == dead_buf, "dead terminal toggle hid draft")
  check(table.concat(vim.fn.readfile(dead_path), "\n") == "survive dead terminal", "dead terminal toggle lost text")
  vim.cmd.tabclose()

  local first_tab = workspace.current_tab()
  vim.cmd.tabnew()
  local second_tab = workspace.current_tab()
  vim.wait(50)
  check(workspace.current_tab() == second_tab, "scheduled paste stole tab focus")
  vim.api.nvim_set_current_tabpage(first_tab)

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
