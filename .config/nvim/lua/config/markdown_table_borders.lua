local M = {}

function M.setup()
  local renderer = require("render-markdown.render.markdown.table")
  local original_border = renderer.border

  function renderer:border(wrapped)
    original_border(self, wrapped)

    local rows, border = self.data.rows, self.config.border
    local parts = {}
    for _, col in ipairs(self.data.cols) do
      parts[#parts + 1] = border[11]:rep(col.width)
    end
    local text = border[4] .. table.concat(parts, border[5]) .. border[6]
    local line = self:line():pad(self.data.layout.col):text(text, self.config.row)
    local virtual_line = self:indent():line(true):extend(line):get()

    -- The header already has a delimiter; add separators between body rows.
    for i = 2, #rows - 1 do
      if wrapped[i] then
        table.insert(wrapped[i], virtual_line)
      else
        self.marks:add(self.config, "virtual_lines", rows[i].node.start_row, 0, {
          virt_lines = { virtual_line },
          virt_lines_above = false,
        })
      end
    end
  end
end

return M
