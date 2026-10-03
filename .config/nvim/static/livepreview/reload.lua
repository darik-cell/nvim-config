-- :luafile ~/.config/nvim/static/livepreview/reload.lua
-- Load directly from disk so stale Lua loader caches cannot retain the old server.
require("lazy").load({ plugins = { "live-preview.nvim" } })
require("livepreview").close()
local root = vim.fn.stdpath("config")
package.loaded["config.live_preview_process"] = dofile(root .. "/lua/config/live_preview_process.lua")
package.loaded["config.live_preview"] = dofile(root .. "/lua/config/live_preview.lua")
require("config.live_preview").setup({ dynamic_root = true })
vim.notify("Live preview configuration reloaded; open the Markdown preview again")
