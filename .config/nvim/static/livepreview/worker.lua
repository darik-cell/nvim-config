-- Minimal configuration for the detached preview process, independent of editor plugins.
vim.opt.runtimepath:append(vim.env.LIVE_PREVIEW_CONFIG)
vim.opt.runtimepath:append(vim.env.LIVE_PREVIEW_PLUGIN)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
require("config.live_preview_process").serve()
