local M = {}
local active, watched = {}, {}
local key_ns = vim.api.nvim_create_namespace("prompt-terminal-view")

local function view(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

local function same_view(a, b)
  for _, key in ipairs({ "lnum", "col", "topline", "leftcol", "skipcol" }) do
    if a[key] ~= b[key] then return false end
  end
  return true
end

local function stop_timer(timer)
  if timer and not timer:is_closing() then timer:stop(); timer:close() end
end

local function cancel(state)
  if active[state.saved.buf] == state then active[state.saved.buf] = nil end
  stop_timer(state.timer)
  stop_timer(state.deadline)
  state.timer, state.deadline = nil, nil
end

-- Terminal row boundaries and padding change when a TUI redraws at a new width.
local function index(buf)
  local rows, parts, size = {}, {}, 0
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local text = line:gsub("%s", "")
    rows[row] = { start = size + 1, length = #text, line = line }
    parts[row] = text
    size = size + #text
  end
  return table.concat(parts), rows
end

local function position(rows, offset)
  local lo, hi = 1, #rows
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local row = rows[mid]
    if offset < row.start then
      hi = mid - 1
    elseif offset >= row.start + row.length then
      lo = mid + 1
    else
      local wanted, count = offset - row.start + 1, 0
      for byte in row.line:gmatch("()%S") do
        count = count + 1
        if count == wanted then return mid, byte - 1 end
      end
    end
  end
end

local function character_start(line, col)
  while col > 0 do
    local byte = line:byte(col + 1)
    if not byte or byte < 128 or byte >= 192 then break end
    col = col - 1
  end
  return col
end

function M.capture(ctx, win)
  if active[ctx.terminal_bufnr] then cancel(active[ctx.terminal_bufnr]) end
  ctx.prompt_view_generation = (ctx.prompt_view_generation or 0) + 1
  local saved = {
    win = win, buf = ctx.terminal_bufnr, job = ctx.job_id,
    tab = vim.api.nvim_get_current_tabpage(), generation = ctx.prompt_view_generation,
    input = ctx.prompt_terminal_input == true, view = view(win),
    tick = vim.api.nvim_buf_get_changedtick(ctx.terminal_bufnr), needles = {},
  }
  local text, rows = index(saved.buf)
  local anchor_row, anchor_col = saved.view.lnum, nil
  while rows[anchor_row] do
    local line = rows[anchor_row].line
    local first = anchor_row == saved.view.lnum and line:find("%S", saved.view.col + 1)
    if first then anchor_col = first - 1; break end
    for byte in line:gmatch("()%S") do anchor_col = byte - 1 end
    if anchor_col then anchor_col = character_start(line, anchor_col); break end
    anchor_row = anchor_row - 1
  end
  local row = rows[anchor_row]
  if row and anchor_col then
    saved.row_offset = saved.view.lnum - anchor_row
    saved.col_offset = saved.view.col - anchor_col
    local prefix = row.line:sub(1, anchor_col):gsub("%s", "")
    local cursor = row.start + #prefix
    for _, range in ipairs({ { 160, 200 }, { 64, 80 }, { 16, 32 } }) do
      local first, last = math.max(1, cursor - range[1]), math.min(#text, cursor + range[2])
      if last - first >= 23 then
        saved.needles[#saved.needles + 1] = { text = text:sub(first, last), offset = cursor - first }
      end
    end
  end
  return saved
end

local function valid(state)
  local ctx, saved = state.ctx, state.saved
  return active[saved.buf] == state and ctx.prompt_view_generation == saved.generation
    and ctx.job_id == saved.job and vim.api.nvim_get_current_tabpage() == saved.tab
    and vim.api.nvim_win_is_valid(saved.win) and vim.api.nvim_win_get_buf(saved.win) == saved.buf
    and not (vim.api.nvim_get_current_win() == saved.win and vim.api.nvim_get_mode().mode:sub(1, 1) == "t")
end

local function resolve(saved)
  local text, rows = index(saved.buf)
  for _, needle in ipairs(saved.needles) do
    local from, best, distance, tied = 1, nil, nil, false
    while true do
      local found = text:find(needle.text, from, true)
      if not found then break end
      local row, col = position(rows, found + needle.offset)
      if row then
        local delta = math.abs(row - (saved.view.lnum - (saved.row_offset or 0)))
        if not distance or delta < distance then
          best, distance, tied = { row, col }, delta, false
        elseif delta == distance then
          tied = true
        end
      end
      from = found + 1
    end
    if best then
      if tied then return nil end
      return best[1], best[2]
    end
  end
end

local function apply(state, first)
  if not valid(state) then cancel(state); return end
  local saved = state.saved
  local current, tick = view(saved.win), vim.api.nvim_buf_get_changedtick(saved.buf)
  if not first and tick == state.tick and not same_view(current, state.last_view) then
    cancel(state)
    return
  end
  if tick == saved.tick then
    vim.api.nvim_win_call(saved.win, function() vim.fn.winrestview(saved.view) end)
  else
    local row, col = resolve(saved)
    if row then
      row = math.min(vim.api.nvim_buf_line_count(saved.buf), row + (saved.row_offset or 0))
      col = saved.row_offset == 0 and math.max(0, col + saved.col_offset) or saved.view.col
      local line = vim.api.nvim_buf_get_lines(saved.buf, row - 1, row, false)[1] or ""
      col = character_start(line, math.min(col, #line))
      local restored = vim.deepcopy(saved.view)
      restored.lnum, restored.col, restored.curswant = row, col, col
      restored.topline = math.max(1, row - (saved.view.lnum - saved.view.topline))
      restored.skipcol = 0
      vim.api.nvim_win_call(saved.win, function() vim.fn.winrestview(restored) end)
    end
  end
  state.last_view, state.tick = view(saved.win), tick
end

local function queue(state)
  if not valid(state) then cancel(state); return end
  stop_timer(state.timer)
  state.timer = vim.defer_fn(function()
    state.timer = nil
    apply(state, false)
  end, 60)
end

function M.restore(ctx, saved)
  if not saved then return end
  if active[saved.buf] then cancel(active[saved.buf]) end
  local state = { ctx = ctx, saved = saved }
  active[saved.buf] = state
  if not watched[saved.buf] then
    watched[saved.buf] = vim.api.nvim_buf_attach(saved.buf, false, {
      on_lines = function(_, buf)
        local pending = active[buf]
        if pending then
          vim.schedule(function() if active[buf] == pending then queue(pending) end end)
        end
      end,
      on_detach = function(_, buf)
        watched[buf] = nil
        if active[buf] then cancel(active[buf]) end
      end,
    })
  end
  apply(state, true)
  if active[saved.buf] ~= state then return end
  queue(state)
  state.deadline = vim.defer_fn(function()
    state.deadline = nil
    cancel(state)
  end, 1500)
end

vim.on_key(function(key)
  local current = vim.api.nvim_get_current_win()
  local mouse = vim.fn.keytrans(key):find("Mouse", 1, true) or vim.fn.keytrans(key):find("ScrollWheel", 1, true)
  local mouse_win = mouse and vim.fn.getmousepos().winid
  for _, state in pairs(active) do
    if state.saved.win == current or state.saved.win == mouse_win then cancel(state) end
  end
end, key_ns)

return M
