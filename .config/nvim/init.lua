vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("config.options")

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local lazy_url = "https://github.com/folke/lazy.nvim.git"
local lockpath = vim.fs.joinpath(vim.fn.stdpath("config"), "lazy-lock.json")

local function command(args, context)
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    error(table.concat({
      context,
      result.stderr and vim.trim(result.stderr) or "",
    }, "\n"))
  end
  return vim.trim(result.stdout or "")
end

local function lazy_commit()
  local ok, lines = pcall(vim.fn.readfile, lockpath)
  if not ok then
    error(("Cannot read lazy.nvim lockfile at %s: %s"):format(lockpath, lines))
  end

  local decoded_ok, lock = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(lock) ~= "table" then
    error(("Cannot decode lazy.nvim lockfile at %s: %s"):format(lockpath, lock))
  end

  local entry = lock["lazy.nvim"]
  local commit = entry and entry.commit
  if type(commit) ~= "string" or #commit ~= 40 or not commit:match("^%x+$") then
    error(("lazy-lock.json does not contain a valid lazy.nvim commit: %s"):format(tostring(commit)))
  end
  return commit
end

local locked_lazy_commit = lazy_commit()
local lazy_runtime = vim.fs.joinpath(lazypath, "lua", "lazy", "init.lua")
if not vim.uv.fs_stat(lazypath) then
  vim.fn.mkdir(vim.fs.dirname(lazypath), "p")
  command({ "git", "clone", "--filter=blob:none", "--no-checkout", lazy_url, lazypath }, "Cannot clone lazy.nvim")
end

local has_commit = vim.system({ "git", "-C", lazypath, "cat-file", "-e", locked_lazy_commit .. "^{commit}" }):wait()
if has_commit.code ~= 0 then
  command(
    { "git", "-C", lazypath, "fetch", "--filter=blob:none", "--depth=1", "origin", locked_lazy_commit },
    ("Cannot fetch locked lazy.nvim commit %s"):format(locked_lazy_commit)
  )
end

local current_lazy_commit = command({ "git", "-C", lazypath, "rev-parse", "HEAD" }, "Cannot inspect lazy.nvim")
if current_lazy_commit ~= locked_lazy_commit or not vim.uv.fs_stat(lazy_runtime) then
  command(
    { "git", "-C", lazypath, "checkout", "--detach", locked_lazy_commit },
    ("Cannot checkout locked lazy.nvim commit %s"):format(locked_lazy_commit)
  )
end

local verified_lazy_commit = command({ "git", "-C", lazypath, "rev-parse", "HEAD" }, "Cannot verify lazy.nvim")
if verified_lazy_commit ~= locked_lazy_commit then
  error(("lazy.nvim checkout mismatch: expected %s, got %s"):format(locked_lazy_commit, verified_lazy_commit))
end

vim.opt.rtp:prepend(lazypath)

require("lazy").setup("plugins", {
  defaults = {
    lazy = false,
  },
  install = {
    colorscheme = { "darcula-dark" },
  },
  checker = {
    enabled = false,
  },
  change_detection = {
    notify = false,
  },
})

require("config.tabline").setup()
require("config.attention").setup()
require("config.keymaps")
require("config.autocmds")
