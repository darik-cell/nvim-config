-- Run: nvim --headless -u NONE -c 'luafile tests/test_prompt_resize.lua'
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
vim.opt.runtimepath:prepend(root .. '/.config/nvim')
package.path = root .. '/.config/nvim/lua/?.lua;' .. package.path
package.loaded['mini.pairs'] = {}
package.loaded['config.tree'] = {open_tree = function() end, copy_cursor_path = function() end}
vim.opt.hidden, vim.opt.swapfile, vim.opt.shadafile = true, false, 'NONE'
vim.g.mapleader = ' '
require('config.keymaps'); require('config.autocmds')
local workspace = require('config.workspace')
local jobs, dirs, checks = {}, {}, 0
local co
local function cleanup() for _, job in ipairs(jobs) do pcall(vim.fn.jobstop, job) end; for dir in pairs(dirs) do vim.fn.delete(dir, 'rf') end end
local function check(ok, msg) assert(ok, msg); checks = checks + 1 end
local function wait(ms) vim.defer_fn(function()
  local ok, err = coroutine.resume(co)
  if not ok then cleanup(); io.stderr:write(debug.traceback(co, tostring(err)) .. '\n'); vim.cmd('cquit 1') end
end, ms); coroutine.yield() end
local function key(k) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 't', false); wait(100) end
local function find(buf, pattern)
  for n, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local col = line:find(pattern, 1, true)
    if col then return n, col-1 end
  end
end
local function assert_anchor(buf, win, msg)
  local pos = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_buf_get_lines(buf, pos[1]-1, pos[1], false)[1] or ''
  check(line:find('открытии', 1, true) ~= nil, msg .. ': ' .. line)
  check(pos[2] == line:find('открытии', 1, true) - 1, msg .. ': cursor byte column changed')
end
co = coroutine.create(function()
  local job = vim.fn.termopen({'python3', '-u', root .. '/tests/fixtures/resize_tui.py'})
  jobs[#jobs+1] = job
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  wait(350); vim.cmd.stopinsert(); wait(80)
  local row, col = find(buf, 'открытии')
  check(row ~= nil, 'fixture anchor missing')
  vim.api.nvim_win_set_cursor(win, {row, col}); vim.cmd('normal! zt')
  key('<C-g>'); local ctx = workspace.context_for_terminal(buf)
  check(ctx and ctx.path, 'prompt missing'); dirs[vim.fs.dirname(ctx.path)] = true
  wait(1100); assert_anchor(buf, win, 'normal open anchor moved')
  key('<C-g>'); wait(1100); assert_anchor(buf, win, 'normal close anchor moved')
  check(vim.api.nvim_get_current_win() == win, 'normal close lost focus')
  -- Editing prompt while redraw is pending must not cancel background anchoring.
  key('<C-g>')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {'editing while terminal resizes'})
  local prompt_win = vim.api.nvim_get_current_win()
  wait(1100); assert_anchor(buf, win, 'prompt edit cancelled anchor')
  check(vim.api.nvim_get_current_win() == prompt_win, 'anchor stole prompt focus')
  key('<C-g>'); wait(1100)
  -- Explicit user movement wins over the asynchronous restoration.
  key('<C-g>')
  prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, {10, 0}); vim.cmd('normal! zt')
  local chosen = vim.api.nvim_win_get_cursor(win)[1]
  wait(1100)
  check(vim.api.nvim_get_current_win() == win, 'restore stole user focus')
  check(vim.api.nvim_win_get_cursor(win)[1] == chosen, 'restore overwrote user scroll')
  vim.api.nvim_set_current_win(prompt_win); key('<C-g>')
  -- Opening from terminal input follows the live screen as output arrives,
  -- rather than anchoring old text like the normal-mode reading cases above.
  vim.cmd.tabnew()
  local job2 = vim.fn.termopen({'python3', '-u', root .. '/tests/fixtures/resize_tui.py'})
  jobs[#jobs+1] = job2
  local buf2, win2 = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  wait(350); vim.cmd.startinsert(); wait(100)
  check(vim.api.nvim_get_mode().mode:sub(1,1) == 't', 'fixture input mode unavailable')
  key('<C-g>')
  local ctx2 = workspace.context_for_terminal(buf2)
  check(ctx2 and ctx2.path, 'input-origin prompt missing'); dirs[vim.fs.dirname(ctx2.path)] = true
  wait(1100)
  local input_view = vim.api.nvim_win_call(win2, vim.fn.winsaveview)
  local visible = table.concat(vim.api.nvim_buf_get_lines(buf2, input_view.topline - 1,
    input_view.topline - 1 + vim.api.nvim_win_get_height(win2), false), '')
  check(visible:find('redraw-33', 1, true) ~= nil, 'input-origin live output not visible')
  key('<C-g>'); wait(100)
  check(vim.api.nvim_get_mode().mode:sub(1,1) == 't' and vim.api.nvim_get_current_win() == win2, 'input close lost terminal input')
  -- Pi replays its transcript on resize. An empty editor must not be
  -- anchored to one of the many identical decorative borders in history.
  vim.cmd.tabnew()
  local job3 = vim.fn.termopen({'python3', '-u', root .. '/tests/fixtures/pi_resize_tui.py'})
  jobs[#jobs+1] = job3
  local buf3, win3 = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  wait(350); vim.cmd.startinsert(); wait(100)
  local before = vim.api.nvim_win_call(win3, vim.fn.winsaveview)
  local tail = vim.api.nvim_buf_line_count(buf3) - before.lnum
  check(tail == 2, 'Pi-like empty editor cursor unavailable')
  for attempt = 1, 2 do
    key('<C-g>')
    local ctx3 = workspace.context_for_terminal(buf3)
    check(ctx3 and ctx3.path, 'Pi-like prompt missing')
    dirs[vim.fs.dirname(ctx3.path)] = true
    local draft_win = vim.api.nvim_get_current_win()
    wait(1100)
    local current = vim.api.nvim_win_call(win3, vim.fn.winsaveview)
    local count = vim.api.nvim_buf_line_count(buf3)
    check(current.lnum == count - tail, 'empty Pi editor jumped into old transcript: ' .. vim.inspect(current))
    local screen = table.concat(vim.api.nvim_buf_get_lines(buf3, current.topline - 1,
      math.min(count, current.topline - 1 + vim.api.nvim_win_get_height(win3)), false), '')
    check(screen:find('model status width', 1, true) ~= nil, 'Pi live viewport not visible')
    check(vim.api.nvim_get_current_win() == draft_win, 'Pi restoration stole draft focus')
    check(vim.api.nvim_get_mode().mode:sub(1,1) ~= 't', 'Pi restoration entered terminal input')
    key('<C-g>'); wait(1100)
    check(vim.api.nvim_get_mode().mode:sub(1,1) == 't' and vim.api.nvim_get_current_win() == win3,
      'Pi-like close lost terminal input')
  end
  cleanup(); print(('PASS: %d resize assertions'):format(checks)); vim.cmd('qa!')
end)
local ok, err = coroutine.resume(co)
if not ok then cleanup(); io.stderr:write(tostring(err)..'\n'); vim.cmd('cquit 1') end
