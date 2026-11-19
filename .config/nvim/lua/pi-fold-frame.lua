-- A window-local frozen screen for explicit Pi fold commands. Never focused.
-- Close it after restoring the underlying view, or unconditionally after 1 s.
-- Private cell inspection is optional: text capture still works without colors.
local M = {}
local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("pi-fold-frame")
local highlights = {}
local attrs = {
  { "foreground", "fg" }, { "background", "bg" }, { "special", "sp" },
  { "bold", "bold" }, { "italic", "italic" }, { "underline", "underline" },
  { "undercurl", "undercurl" }, { "underdouble", "underdouble" },
  { "underdotted", "underdotted" }, { "underdashed", "underdashed" },
  { "strikethrough", "strikethrough" }, { "reverse", "reverse" },
}

local function info(win)
  local rows = vim.fn.getwininfo(win)
  return rows and rows[1]
end

local function highlight(cellattrs)
  local spec, key = {}, {}
  for _, pair in ipairs(attrs) do
    local value = cellattrs[pair[1]]
    if value ~= nil then
      spec[pair[2]] = value
      key[#key + 1] = pair[2] .. "=" .. tostring(value)
    end
  end
  if #key == 0 then return nil end
  key = table.concat(key, ",")
  if not highlights[key] then
    local name = "PiFoldFrame" .. tostring(vim.tbl_count(highlights) + 1)
    vim.api.nvim_set_hl(0, name, spec)
    highlights[key] = name
  end
  return highlights[key]
end

-- Coordinates are screen cells, not byte offsets. Skip the trailing cell of
-- wide glyphs; combining characters arrive as part of screenstring's result.
local function screen_row(row, col, width)
  local parts, runs, bytes, cell = {}, {}, 0, 0
  while cell < width do
    local text = vim.fn.screenstring(row, col + cell)
    if text == "" then text = " " end
    local attr
    if vim.api.nvim__inspect_cell then
      local ok, data = pcall(vim.api.nvim__inspect_cell, 1, row - 1, col + cell - 1)
      -- This API returns {text, RGB-attributes, ...}, NOT a keyed object.
      if ok and type(data) == "table" and type(data[2]) == "table" then
        attr = highlight(data[2])
      end
    end
    parts[#parts + 1] = text
    if attr then
      local last = runs[#runs]
      if last and last.name == attr and last.last == bytes then
        last.last = bytes + #text
      else
        runs[#runs + 1] = { first = bytes, last = bytes + #text, name = attr }
      end
    end
    bytes = bytes + #text
    cell = cell + math.max(1, vim.fn.strdisplaywidth(text))
  end
  return table.concat(parts), runs
end

-- Headless fallback exists for tests only. Actual UI snapshots use the screen,
-- which preserves leftcol, wide glyphs, terminal colors and window-local gutters.
local function snapshot(win, buf, wi, width, height)
  local lines, runs = {}, {}
  local attached = #vim.api.nvim_list_uis() > 0
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  for offset = 0, height - 1 do
    if attached then
      lines[offset + 1], runs[offset + 1] = screen_row(wi.winrow + offset, wi.wincol, width)
    else
      local row = view.topline + offset
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
      lines[offset + 1] = line
      runs[offset + 1] = {}
    end
  end
  return lines, runs, view
end

function M.hold(win, buf)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf
      or vim.api.nvim_get_current_win() ~= win then return nil end
  local wi = info(win)
  if not wi or (wi.winbar or 0) ~= 0 then return nil end
  local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
  if width < 1 or height < 1 then return nil end
  local lines, runs, view = snapshot(win, buf, wi, width, height)
  local fb = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fb, 0, -1, false, lines)
  vim.bo[fb].bufhidden = "wipe"
  vim.bo[fb].modifiable = false
  for row, colors in ipairs(runs) do
    for _, run in ipairs(colors) do
      vim.api.nvim_buf_set_extmark(fb, ns, row - 1, run.first,
        { end_row = row - 1, end_col = run.last, hl_group = run.name })
    end
  end
  local ok, fw = pcall(vim.api.nvim_open_win, fb, false, {
    relative = "win", win = win, row = 0, col = 0, width = width, height = height,
    focusable = false, mouse = false, noautocmd = true, style = "minimal",
    border = "none", zindex = 50,
  })
  if not ok then
    vim.api.nvim_buf_delete(fb, { force = true })
    return nil
  end
  vim.wo[fw].wrap = false
  vim.wo[fw].winblend = 0
  vim.wo[fw].winhighlight = "Normal:Normal,NormalFloat:Normal"
  local handle = { win = win, buf = buf, fw = fw, fb = fb, dead = false,
    ref = { row = view.lnum, topline = view.topline, leftcol = view.leftcol } }
  local group = vim.api.nvim_create_augroup("pi-fold-frame-" .. fw, { clear = true })
  local cap, poll = uv.new_timer(), uv.new_timer()
  local function drop(reason)
    if handle.dead then return end
    reason = type(reason) == "string" and reason or "context"
    handle.dead = true
    for _, timer in ipairs({ cap, poll }) do
      if timer and not timer:is_closing() then timer:stop(); timer:close() end
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if vim.api.nvim_win_is_valid(fw) then pcall(vim.api.nvim_win_close, fw, true) end
    if vim.api.nvim_buf_is_valid(fb) then pcall(vim.api.nvim_buf_delete, fb, { force = true }) end
    if handle.on_drop then handle.on_drop(reason) end
  end
  handle.drop = drop
  cap:start(1000, 0, vim.schedule_wrap(function() drop("timeout") end))
  vim.api.nvim_create_autocmd({ "WinClosed", "WinResized", "VimResized", "TabEnter", "WinLeave" }, {
    group = group, callback = vim.schedule_wrap(drop),
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group, callback = function()
      if vim.api.nvim_get_mode().mode ~= "nt" then drop() end
    end,
  })
  poll:start(25, 25, vim.schedule_wrap(function()
    if handle.dead then return end
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf)
        or vim.api.nvim_get_current_win() ~= win or vim.api.nvim_win_get_buf(win) ~= buf
        or vim.api.nvim_get_mode().mode ~= "nt"
        or vim.api.nvim_win_get_width(win) ~= width or vim.api.nvim_win_get_height(win) ~= height then
      drop()
    end
  end))
  return handle
end

return M
