local M = {}
local alphabet = "asdfghjklqwertyuiopzxcvbnm"

local function highlights()
  vim.api.nvim_set_hl(0, "AceJumpLabel", { fg = "#ffffff", bg = "#008b9e", bold = true })
  vim.api.nvim_set_hl(0, "AceJumpMatch", { fg = "#008b9e", underline = true })
end

function M.setup()
  highlights()
  local group = vim.api.nvim_create_augroup("AceJumpHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
end

local function label_options()
  return {
    uppercase = false,
    after = { 0, 1 },
    before = { 0, -2 },
    style = "overlay",
    format = function(opts)
      if opts.after ~= (opts.match.label_side == "right") then
        return {}
      end
      return { { (opts.match.label1 .. opts.match.label2):upper(), "AceJumpLabel" } }
    end,
  }
end

local function concealed_columns(win, row)
  if vim.wo[win].conceallevel == 0 then
    return
  end
  return vim.api.nvim_win_call(win, function()
    local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
    local columns = {}
    local byte, col = 0, 1
    local has_conceal = false
    for _, char in ipairs(vim.fn.split(line, "\\zs")) do
      local hidden = vim.fn.synconcealed(row, byte + 1)[1] ~= 0
      columns[byte] = { col = col, hidden = hidden }
      has_conceal = has_conceal or hidden
      -- Underestimate concealed replacements and tabs: suppressing an extra
      -- hint is preferable to placing two hints over the same visible cells.
      if not hidden then
        col = col + (char == "\t" and 1 or vim.fn.strdisplaywidth(char))
      end
      byte = byte + #char
    end
    columns[byte] = { col = col, hidden = false }
    return has_conceal and columns or nil
  end)
end

local function fits(cells, col)
  return not cells[col - 1] and not cells[col] and not cells[col + 1] and not cells[col + 2]
end

function M.jump()
  local flash = require("flash")
  local offset_pos = require("flash.util").offset_pos
  local warned = false
  -- Flash consumes one label key at a time, so select a prefix group first,
  -- then select the destination within that captured group.
  return flash.jump({
    labels = alphabet,
    search = { mode = "exact", multi_window = true, max_length = false },
    jump = { autojump = false },
    highlight = {
      backdrop = false,
      groups = { match = "AceJumpMatch", current = "AceJumpMatch" },
    },
    prompt = { prefix = { { "Ace Jump: ", "FlashPromptIcon" } } },
    label = label_options(),
    labeler = function(matches, state)
      for _, match in ipairs(matches) do
        match.label = false
        match.label1 = nil
        match.label2 = nil
        match.label_side = nil
      end
      if state.pattern:empty() then
        return
      end
      local candidates = {}
      local occupied = {}
      local protected = {}
      local windows = {}
      local concealed = {}
      local function positions(win, row)
        local key = win .. ":line:" .. row
        if concealed[key] == nil then
          concealed[key] = concealed_columns(win, row) or false
        end
        return concealed[key], key
      end
      local function reserve(cells, key, first, last)
        cells[key] = cells[key] or {}
        for col = first, last do
          cells[key][col] = true
        end
      end
      -- A hint must not cover another searched character, even if that
      -- character cannot receive a hint of its own.
      for _, match in ipairs(matches) do
        local win = match.win
        windows[win] = windows[win] or vim.fn.getwininfo(win)[1]
        local info = windows[win]
        if info and not match.fold then
          local first = vim.fn.screenpos(win, match.pos[1], match.pos[2] + 1)
          local last = vim.fn.screenpos(win, match.end_pos[1], match.end_pos[2] + 1)
          if first.row > 0 and last.row >= first.row then
            for row = first.row, last.row do
              reserve(protected, win .. ":" .. row,
                row == first.row and first.col or info.wincol + info.textoff,
                row == last.row and last.endcol or info.wincol + info.width - 1)
            end
          end
          local columns, key = positions(win, match.pos[1])
          local start = columns and columns[match.pos[2]]
          local after = offset_pos(vim.api.nvim_win_get_buf(win), match.end_pos, { 0, 1 })
          local finish = columns and after[1] == match.pos[1] and columns[after[2]]
          if start and finish then
            reserve(protected, key, start.col, finish.col - 1)
          end
        end
      end
      for _, match in ipairs(matches) do
        local win = match.win
        local info = windows[win]
        local cursor = vim.api.nvim_win_get_cursor(win)
        local at_cursor = win == state.win and cursor[1] == match.pos[1] and cursor[2] == match.pos[2]
        if info and not match.fold and not at_cursor then
          for _, side in ipairs({ "right", "left" }) do
            local boundary = side == "right" and match.end_pos or match.pos
            local offset = side == "right" and 1 or -2
            local anchor = offset_pos(vim.api.nvim_win_get_buf(win), boundary, { 0, offset })
            local row, col = anchor[1], anchor[2]
            local screen = vim.fn.screenpos(win, row, col + 1)
            local edge = vim.fn.screenpos(win, boundary[1], boundary[2] + 1)
            local outside = side == "right" and screen.col > edge.endcol
              or side == "left" and screen.col + 1 < edge.col
            local key = win .. ":" .. screen.row
            local cells = occupied[key] or {}
            local targets = protected[key] or {}
            local columns, line_key = positions(win, row)
            local position = columns and columns[col]
            local target = columns and columns[boundary[2]]
            local line_cells = occupied[line_key] or {}
            local line_targets = protected[line_key] or {}
            local concealed_fits = not columns or (position and target and not position.hidden
              and not target.hidden and fits(line_cells, position.col)
              and not line_targets[position.col] and not line_targets[position.col + 1])
            if screen.row > 0 and screen.row == edge.row and outside
              and screen.col >= info.wincol + info.textoff
              and screen.col + 1 <= info.wincol + info.width - 1
              and fits(cells, screen.col) and not targets[screen.col] and not targets[screen.col + 1]
              and concealed_fits then
              match.label_side = side
              candidates[#candidates + 1] = match
              reserve(occupied, key, screen.col, screen.col + 1)
              if position then
                reserve(occupied, line_key, position.col, position.col + 1)
              end
              break
            end
          end
        end
      end
      if #candidates > #alphabet * #alphabet then
        if not warned then
          warned = true
          vim.schedule(function()
            vim.notify("Too many Ace Jump matches; type more search text", vim.log.levels.INFO)
          end)
        end
        return
      end
      for index, match in ipairs(candidates) do
        local first = math.floor((index - 1) / #alphabet) + 1
        local second = (index - 1) % #alphabet + 1
        match.label1 = alphabet:sub(first, first)
        match.label2 = alphabet:sub(second, second)
        match.label = match.label1
      end
    end,
    action = function(match, state)
      local candidates = {}
      for _, candidate in ipairs(state.results) do
        if candidate.label and candidate.label1 == match.label1 then
          candidates[#candidates + 1] = vim.tbl_extend("force", {}, candidate, { label = candidate.label2 })
        end
      end
      state:hide()
      flash.jump({
        labels = alphabet,
        search = { multi_window = true, max_length = false },
        jump = { autojump = false },
        highlight = { backdrop = false, matches = false },
        prompt = { prefix = { { "Ace Jump " .. match.label1:upper() .. ": ", "FlashPromptIcon" } } },
        label = label_options(),
        matcher = function(win)
          return vim.tbl_filter(function(candidate)
            return candidate.win == win
          end, candidates)
        end,
        labeler = function(matches)
          for _, candidate in ipairs(matches) do
            candidate.label = candidate.label2
          end
        end,
      })
    end,
  })
end

return M
