-- Run with -c 'luafile tests/test_prompt_view.lua' so terminal mode transitions execute.
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
vim.opt.runtimepath:prepend(root .. '/.config/nvim')
package.path = root .. '/.config/nvim/lua/?.lua;' .. package.path
package.loaded['mini.pairs'] = {}
package.loaded['config.tree'] = { open_tree = function() end, copy_cursor_path = function() end }
vim.opt.hidden, vim.opt.swapfile, vim.opt.shadafile = true, false, 'NONE'
vim.opt.shell = '/bin/sh'
vim.g.mapleader = ' '
require('config.keymaps')
require('config.autocmds')
local workspace = require('config.workspace')
local markdown = require('config.markdown')
local dirs, checks, job = {}, 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local co
local function pause() vim.defer_fn(function()
  local ok, err = coroutine.resume(co)
  if not ok then
    if job then pcall(vim.fn.jobstop, job) end
    for dir in pairs(dirs) do vim.fn.delete(dir, 'rf') end
    io.stderr:write(debug.traceback(co, tostring(err)) .. '\n'); vim.cmd('cquit 1')
  end
end, 100); coroutine.yield() end
local function key(s) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), 't', false); pause() end
local function mode() return vim.api.nvim_get_mode().mode:sub(1,1) end
local function view(win) return vim.api.nvim_win_call(win, vim.fn.winsaveview) end
local function same_view(win, v, where)
  local now = view(win)
  check(now.lnum == v.lnum and now.col == v.col and now.topline == v.topline,
    where .. ': expected ' .. vim.inspect(v) .. ', got ' .. vim.inspect(now))
end
local function move(win, line)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, {line, 0})
  vim.cmd('normal! zt')
  return view(win)
end
co = coroutine.create(function()
  job = vim.fn.termopen({'sh', '-c', 'for i in $(seq 1 150); do printf "row-%03d\\n" "$i"; done; sleep 60'})
  local term, term_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  pause()
  check(vim.api.nvim_buf_line_count(term) > 100, 'terminal scrollback unavailable')
  vim.cmd.stopinsert(); pause()
  local original = move(term_win, 40)
  key('<C-g>')
  local ctx = workspace.context_for_terminal(term)
  check(ctx and ctx.path, 'Ctrl+G did not open prompt')
  dirs[vim.fs.dirname(ctx.path)] = true
  same_view(term_win, original, 'open from scrolled normal')
  key('<C-g>')
  check(vim.api.nvim_get_current_win() == term_win and mode() ~= 't', 'normal toggle did not return normal terminal')
  same_view(term_win, original, 'close from scrolled normal')
  key('<C-g>'); key('<C-g>')
  same_view(term_win, original, 'repeat toggle')
  key('<C-g>'); key('<C-w>w')
  check(vim.api.nvim_get_current_win() == term_win and mode() ~= 't', 'Ctrl+W did not focus terminal normal')
  local latest = move(term_win, 60)
  key('<C-w>w'); key('<C-g>')
  check(mode() ~= 't', 'normal scroll switched to input')
  same_view(term_win, latest, 'latest scroll position')
  vim.cmd.startinsert(); pause()
  check(mode() == 't', 'terminal input did not start')
  key('<C-g>'); key('<C-g>')
  check(mode() == 't' and vim.api.nvim_get_current_win() == term_win, 'input toggle did not restore terminal input')
  -- Native window focus change, as with a mouse, must record the actual mode.
  key('<C-g>')
  local native_prompt = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(term_win); pause()
  check(mode() ~= 't', 'native focus did not leave terminal in normal mode')
  local native_latest = move(term_win, 70)
  vim.api.nvim_set_current_win(native_prompt); pause()
  key('<C-g>')
  check(mode() ~= 't' and vim.api.nvim_get_current_win() == term_win, 'native scroll did not preserve normal mode')
  same_view(term_win, native_latest, 'native focus scroll')
  -- Move source view synchronously before the scheduled restoration runs.
  local old_view = move(term_win, 45)
  markdown.toggle_prompt()
  local prompt_after_direct_open = vim.api.nvim_get_current_win()
  vim.api.nvim_win_call(term_win, function()
    vim.api.nvim_win_set_cursor(term_win, {75, 0})
    vim.cmd('normal! zt')
  end)
  local user_view = view(term_win)
  check(user_view.lnum ~= old_view.lnum, 'simulated scroll did not move cursor')
  pause()
  check(vim.api.nvim_get_current_win() == prompt_after_direct_open, 'restore stole prompt focus')
  same_view(term_win, user_view, 'immediate scroll before deferred restore')
  key('<C-g>')
  vim.cmd.stopinsert(); pause(); move(term_win, 40)
  key('<C-g>')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {'prompt text'})
  key('QQ')
  check(mode() == 't' and vim.api.nvim_get_current_win() == term_win, 'QQ did not return terminal input')
  vim.cmd.stopinsert(); pause(); move(term_win, 55)
  key('<C-g>')
  local other_tab
  markdown.toggle_prompt()
  vim.cmd.tabnew(); other_tab = vim.api.nvim_get_current_tabpage()
  pause()
  check(vim.api.nvim_get_current_tabpage() == other_tab, 'deferred restore stole tab focus')
  -- Long rows reflow on resize; check the anchored text and cursor visibility.
  local first_job = job
  vim.cmd.tabnew()
  job = vim.fn.termopen({'sh', '-c', 'for i in $(seq 1 90); do printf "long-%03d-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\n" "$i"; done; sleep 60'})
  local long_buf, long_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  pause(); vim.cmd.stopinsert(); pause()
  check(vim.api.nvim_buf_line_count(long_buf) > 70, 'long terminal scrollback unavailable')
  vim.api.nvim_win_set_cursor(long_win, {40, 7})
  vim.cmd('normal! zt')
  local anchored = vim.api.nvim_buf_get_lines(long_buf, 39, 40, false)[1]
  local long_before = view(long_win)
  key('<C-g>')
  local long_ctx = workspace.context_for_terminal(long_buf)
  check(long_ctx and long_ctx.path, 'long terminal prompt unavailable')
  dirs[vim.fs.dirname(long_ctx.path)] = true
  local long_open = view(long_win)
  local open_text = vim.api.nvim_buf_get_lines(long_buf, long_open.lnum - 1, long_open.lnum, false)[1]
  check(open_text == anchored and long_open.col == long_before.col, 'long-line cursor anchor changed on open')
  check(long_open.topline <= long_open.lnum and long_open.lnum < long_open.topline + vim.api.nvim_win_get_height(long_win), 'long-line cursor not visible on open')
  key('<C-g>')
  local long_after = view(long_win)
  local actual = vim.api.nvim_buf_get_lines(long_buf, long_after.lnum - 1, long_after.lnum, false)[1]
  check(actual == anchored and long_after.col == long_before.col, 'long-line cursor anchor changed across resize')
  check(long_after.topline <= long_after.lnum and long_after.lnum < long_after.topline + vim.api.nvim_win_get_height(long_win), 'long-line cursor not visible')
  pcall(vim.fn.jobstop, first_job)
  pcall(vim.fn.jobstop, job)
  for dir in pairs(dirs) do vim.fn.delete(dir, 'rf') end
  print(('PASS: %d terminal view assertions'):format(checks))
  vim.cmd('qa!')
end)
local ok, err = coroutine.resume(co)
if not ok then io.stderr:write(tostring(err) .. '\n'); vim.cmd('cquit 1') end
