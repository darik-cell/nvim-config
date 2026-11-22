-- From the repository root: nvim --headless -u NONE -l tests/test_pi_fold_copy.lua
vim.opt.rtp:prepend(vim.fn.getcwd() .. "/.config/nvim")
local copy_target = require("pi-fold")._copy_target

local lines = {
  "╭─ model 19:04 ───────────────╮",
  "│ Prose                       │",
  "├─ bash 󰆒 ──────────────────┤",
  "│   echo 'one                 │",
  "│ two'                        │",
  "├────────────────────────────┤",
  "│ More prose                  │",
  "├─ json copied ──────────────┤",
  "│   {}                       │",
  "├────────────────────────────┤",
  "╰────────────────────────────╯",
  "not a frame",
  "╭─ ▧ ./path copy ────────────╮",
  "│ file                       │",
  "╰────────────────────────────╯",
}

local function expect(row, kind, count, hash)
  local actual_kind, actual_count, actual_hash = copy_target(lines, row)
  assert(actual_kind == kind, ("row %d: expected %s, got %s"):format(row, tostring(kind), tostring(actual_kind)))
  assert(actual_count == count)
  if hash then assert(actual_hash == hash) end
end

local bash = vim.fn.sha256("bash\n" .. lines[4] .. "\n" .. lines[5])
for row = 3, 6 do expect(row, "code", 2, bash) end
local active_chip_header = lines[3]
lines[3] = active_chip_header:gsub("󰆒", vim.fn.nr2char(0xF00C)) -- after a mouse copy in pi-tidy
for row = 3, 6 do expect(row, "code", 2, bash) end
lines[3] = active_chip_header
for row = 8, 10 do expect(row, "code", 1) end
for _, row in ipairs({ 1, 2, 7, 11 }) do expect(row, "reply", 9) end
for row = 12, 15 do expect(row, nil) end

-- pi-tidy 0.11 defaults to rails. The reply rule starts at column zero (or
-- at the open run's corner); the code rules are inset just like the text.
for _, rail in ipairs({ { "──", " ", "─" }, { "├─", "│", "╰" } }) do
  lines = {
    rail[1] .. " model 19:04 ──────────────────────",
    rail[2] .. " Prose",
    rail[2] .. "─ bash 󰆒 ────────────────────────",
    rail[2] .. "  echo 'one",
    rail[2] .. "──────────────────────────────────",
    rail[2] .. " More prose",
    rail[3] .. "──────────────────────────────────",
    "not a frame",
  }
  for row = 3, 5 do expect(row, "code", 1, vim.fn.sha256("bash\n" .. lines[4])) end
  for _, row in ipairs({ 1, 2, 6, 7 }) do expect(row, "reply", 5) end
  expect(8, nil)
end

lines = { "▾ took 10s", "├─ code copy ──────────", "│  plain text   ", "├──────────────────────" }
expect(3, "code", 1, vim.fn.sha256("code\n│  plain text"))
table.remove(lines)
expect(3, nil) -- do not copy a frame that was truncated
print("pi-fold copy tests passed")
