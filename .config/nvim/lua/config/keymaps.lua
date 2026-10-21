local markdown = require("config.markdown")
local terminals = require("config.terminals")
local tree = require("config.tree")
local workspace = require("config.workspace")

local map = vim.keymap.set
local ctrl_aliases = {
  ["<C-в>"] = "<C-d>",
  ["<C-г>"] = "<C-u>",
  ["<C-а>"] = "<C-f>",
  ["<C-и>"] = "<C-b>",
  ["<C-у>"] = "<C-e>",
  ["<C-н>"] = "<C-y>",
  ["<C-щ>"] = "<C-o>",
  ["<C-ш>"] = "<C-i>",
  ["<C-ъ>"] = "<C-]>",
  ["<C-е>"] = "<C-t>",
  ["<C-ц>"] = "<C-w>",
}

map({ "n", "v" }, "<Esc>", "<cmd>nohlsearch<CR><Esc>", { silent = true })
map("i", "jj", "<Esc>")
map("i", "оо", "<Esc>")
map("t", "jj", [[<C-\><C-n>]])
map("t", "оо", [[<C-\><C-n>]])
for lhs, rhs in pairs(ctrl_aliases) do
  map("n", lhs, rhs, { silent = true, desc = ("Russian alias for %s"):format(rhs) })
end
map({ "n", "v" }, "j", function()
  return vim.v.count == 0 and "gj" or "j"
end, { expr = true, silent = true })
map({ "n", "v" }, "k", function()
  return vim.v.count == 0 and "gk" or "k"
end, { expr = true, silent = true })
map({ "n", "v" }, "о", function()
  return vim.v.count == 0 and "gj" or "j"
end, { expr = true, silent = true })
map({ "n", "v" }, "л", function()
  return vim.v.count == 0 and "gk" or "k"
end, { expr = true, silent = true })
map("n", "Q", "gq")
map("n", "QQ", markdown.send_prompt_buffer, { desc = "Send prompt buffer to agent terminal" })
map("n", "ЙЙ", markdown.send_prompt_buffer, { desc = "Send prompt buffer to agent terminal" })
map("n", "<leader>j", tree.open_tree, { desc = "Open floating tree" })
map("n", "<leader>cp", tree.copy_cursor_path, { desc = "Copy absolute path" })
map("n", "<leader>ga", function()
  terminals.open_agent({ normal_mode = true })
end, { desc = "Open agent terminal" })
map("n", "<leader>пф", function()
  terminals.open_agent({ normal_mode = true })
end, { desc = "Open agent terminal" })
map("n", "<leader>gp", markdown.open_scratch, { desc = "Open tab scratch buffer" })
map("n", "<leader>пз", markdown.open_scratch, { desc = "Open tab scratch buffer" })
map("n", "<leader>m", markdown.open_current_buffer_in_live_preview, { desc = "Open current markdown in live preview" })
map("n", "<leader>M", markdown.open_current_buffer_in_mdview, { desc = "Open current markdown in mdview" })
map("n", "<leader>tn", workspace.new_tab, { desc = "New tab" })
map("n", "<leader>tq", "<cmd>tabclose<CR>", { desc = "Close tab" })
map("n", "<leader>to", workspace.close_other_tabs, { desc = "Close other tabs" })
map({ "n", "i", "t" }, "<C-g>", markdown.open_prompt, { desc = "Open current prompt draft" })
map({ "n", "i", "t" }, "<C-п>", markdown.open_prompt, { desc = "Open current prompt draft" })

for _, lhs in ipairs({ "<C-`>", "<C-ё>" }) do
  map({ "n", "i", "v", "t" }, lhs, terminals.reopen_last, { desc = "Reopen last terminal" })
end

for _, lhs in ipairs({ "<C-~>", "<C-Ё>" }) do
  map({ "n", "i", "v", "t" }, lhs, terminals.new_terminal, { desc = "New terminal" })
end

map({ "n", "t" }, "<leader>`", terminals.new_terminal, { desc = "New terminal" })

for index = 1, 10 do
  local lhs = ("<M-%s>"):format(index == 10 and 0 or index)
  map("n", lhs, function()
    if terminals.in_bottom_window() then
      terminals.goto_slot(index == 10 and 0 or index)
      return
    end

    workspace.goto_tab(index == 10 and 0 or index)
  end, { desc = ("Go to tab %d"):format(index == 10 and 0 or index) })
  map({ "v", "i" }, lhs, function()
    workspace.goto_tab(index == 10 and 0 or index)
  end, { desc = ("Go to tab %d"):format(index == 10 and 0 or index) })
  map("t", lhs, function()
    if not terminals.in_bottom_window() then
      return
    end

    terminals.goto_slot(index == 10 and 0 or index)
  end, { desc = ("Go to terminal %d"):format(index == 10 and 0 or index) })
end
