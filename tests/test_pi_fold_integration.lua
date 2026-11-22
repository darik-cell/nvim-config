-- Run: PI_TIDY_ENTRY=/path/to/pi-tidy/src/index.ts nvim --headless -u NONE -l tests/test_pi_fold_integration.lua
-- Uses Pi 1.6+ and pi-tidy 0.11+, a synthetic session and a stub clipboard. No model requests.
local root = vim.fn.getcwd()
local tidy = assert(vim.env.PI_TIDY_ENTRY, "set PI_TIDY_ENTRY to the pi-tidy extension entry point")
assert(vim.fn.filereadable(tidy) == 1, tidy .. " is not readable")
vim.opt.rtp:prepend(root .. "/.config/nvim")
vim.o.columns = 83
vim.o.lines = 70
local fold = require("pi-fold")
local dir = vim.fn.tempname()
local jobs = {}

local function test(style)
  local cwd = dir .. "/" .. style
  local profile = cwd .. "/profile"
  vim.fn.mkdir(profile, "p")
  local clipboard = cwd .. "/clipboard"
  local timestamp = "2026-11-22T10:12:44.000Z"
  local code = "echo 'long " .. string.rep("unwrapped ", 12) .. "end'\n  echo indented"
  local answer = "ProseWithToken before the code.\n\n```bash\n" .. code .. "\n```\n\nAfterTheCode."
  local function assistant(content, reason, time)
    return {
      role = "assistant", content = content, api = "openai-responses",
      provider = "openai", model = "gpt-5.2", stopReason = reason, timestamp = time,
      usage = { input = 9, output = 18, cacheRead = 0, cacheWrite = 0, totalTokens = 27,
        cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 } },
    }
  end
  local records = {
    { type = "session", version = 3, id = "65954f8b-31d7-4e85-a365-c6a3fb95b5fd", cwd = cwd, timestamp = timestamp },
    { type = "message", id = "abcd1111", parentId = vim.NIL, timestamp = timestamp,
      message = { role = "user", content = "Show the code", timestamp = 1795342363000 } },
    { type = "message", id = "abcd2222", parentId = "abcd1111", timestamp = timestamp, message = assistant({
      { type = "toolCall", id = "call_1", name = "bash", arguments = { command = "echo SYNTHETIC_TOOL" } },
    }, "toolUse", 1795342364000) },
    { type = "message", id = "abcd3333", parentId = "abcd2222", timestamp = timestamp, message = {
      role = "toolResult", toolCallId = "call_1", toolName = "bash", content = { { type = "text", text = "SYNTHETIC_TOOL" } },
      isError = false, timestamp = 1795342365000,
    } },
    { type = "message", id = "abcd4444", parentId = "abcd3333", timestamp = timestamp,
      message = assistant({ { type = "text", text = answer } }, "stop", 1795342366000) },
  }
  local session = cwd .. "/session.jsonl"
  assert(vim.fn.writefile(vim.tbl_map(vim.json.encode, records), session) == 0)
  assert(vim.fn.writefile({ vim.json.encode({ tidy = { style = style, icons = false }, quietStartup = true }) },
    profile .. "/settings.json") == 0)
  assert(vim.fn.writefile({ "#!/bin/sh", 'exec cat > "$PI_FOLD_TEST_CLIPBOARD"' }, cwd .. "/wl-copy") == 0)
  assert(vim.fn.setfperm(cwd .. "/wl-copy", "rwx------") == 1)

  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  local job = vim.fn.jobstart({ "pi", "--offline", "--no-extensions", "--session", session,
    "-e", tidy, "-e", root .. "/pi/extensions/pi-fold.ts" }, {
    term = true, cwd = cwd, env = {
      NVIM = vim.v.servername, PI_CODING_AGENT_DIR = profile, PI_FOLD_TEST_CLIPBOARD = clipboard,
      PATH = cwd .. ":" .. vim.env.PATH, WAYLAND_DISPLAY = "pi-fold-stub", DISPLAY = "",
      PI_CLIPBOARD_OSC52 = "0", SSH_CONNECTION = "", SSH_CLIENT = "", MOSH_CONNECTION = "", TERMUX_VERSION = "",
      OPENAI_API_KEY = "offline-test-not-a-key",
    },
  })
  assert(job > 0)
  jobs[job] = true
  fold.attach(buf)
  local function lines() return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
  local function find(text)
    local rows = lines()
    for i = #rows, 1, -1 do if rows[i]:find(text, 1, true) then return i end end
  end
  local function wait_for(fn, what)
    assert(vim.wait(5000, fn, 25), style .. ": " .. what .. "\n" .. table.concat(lines(), "\n"))
  end
  local function keys(where, input)
    vim.api.nvim_win_set_cursor(0, { assert(find(where), where), 0 })
    vim.api.nvim_feedkeys(input, "mx", false)
  end
  wait_for(function() return find("AfterTheCode.") and find("▸ took") end, "folded turn did not render")
  vim.api.nvim_chan_send(job, "/zturn 1 open\r")
  wait_for(function() return find("▾ took") and find("▸ 1 call") end, "turn did not open")
  vim.api.nvim_chan_send(job, "/zgroup 1 1 open\r")
  wait_for(function() return find("▾ 1 call") and find("bash ✓") end, "tool group did not open")

  local draft = "UNSENT_DRAFT"
  vim.api.nvim_chan_send(job, draft)
  wait_for(function() return find(draft) end, "draft did not render")

  local function copy(where, kind, expected)
    local target = fold._copy_target(lines(), assert(find(where), where))
    assert(target == kind, style .. ": expected " .. kind .. " under " .. where .. ", got " .. tostring(target))
    keys(where, (vim.g.mapleader or "\\") .. "cp")
    assert(vim.api.nvim_win_get_cursor(0)[1] == find(where), "copy mapping moved the terminal cursor")
    wait_for(function()
      return vim.fn.filereadable(clipboard) == 1 and table.concat(vim.fn.readfile(clipboard, "b"), "\n") == expected
    end, "clipboard content did not match the original " .. kind)
    assert(find(draft), "copy modified or submitted the prompt draft")
    vim.fn.delete(clipboard)
  end
  copy("echo indented", "code", code)
  copy("ProseWithToken", "reply", answer)
  vim.fn.jobstop(job)
  assert(vim.fn.jobwait({ job }, 2000)[1] ~= -1, "Pi fixture did not exit")
  jobs[job] = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end

local ok, err = xpcall(function() test("rail"); test("frame") end, debug.traceback)
for job in pairs(jobs) do pcall(vim.fn.jobstop, job) end
vim.fn.delete(dir, "rf")
if not ok then error(err) end
print("pi-fold integration: copied code and Markdown in both styles, leaving the draft intact")
