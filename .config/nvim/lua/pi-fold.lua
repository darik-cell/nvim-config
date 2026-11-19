--[[
pi-fold — vim-style zo/zc folding for a pi session in a Neovim terminal buffer.

Works with pi's regular TUI + pi-tidy + the pi-fold.ts extension
(~/.pi/agent/extensions/pi-fold.ts), which provides:
    /zturn  T [open|close|toggle]  — whole turn (▸ summary ↔ ▾ rail + groups)
    /zgroup T I [open|close|toggle]— the tool group holding member I of turn T
    /zbox   T I [open|close|toggle]— one tool box (I-th member of turn T)

Keys (terminal-NORMAL mode, i.e. after Ctrl-\ Ctrl-N):
    zo  open the fold under the cursor:
          ▸ turn summary line  → /zturn T open
          ▸ N calls group line → /zgroup T G open   (rows only, NO box opens)
          ▾ anything           → already open, no-op
          a compact tool row   → /zbox T I open     (that box, and only it)
    zc  close the nearest open fold at the cursor:
          ▾ turn summary       → /zturn T close
          ▾ N calls group line → /zgroup T G close
          ▸ N calls group line → the enclosing turn is the nearest open fold:
                                 /zturn T close
          a compact tool row   → its box is already a row; the group is the
                                 nearest open fold: /zgroup T I close
          an expanded box (its `├─` top row or any line of its body)
                               → /zbox T I close   (box folds back to its row,
                                 group and turn stay open)
          any other line inside an open turn → /zturn T close

pi reprints the whole transcript on each toggle, so the cursor line number
shifts with the content — the marks are re-parsed from the buffer on every
key press, and every command names its target and direction, so a stale
buffer can only repeat an idempotent request, never toggle by accident.
Explicit reprints are covered by a window-local frozen frame (sibling
pi-fold-frame.lua). The cursor and target's screen row are restored underneath
before revealing the result: zc from a compact bash row leaves the cursor on
that group's collapsed `│ ▸ 2 calls …` header, not the top of the buffer.
During the frame, NORMAL keyboard input waits in an ordered queue and is
replayed after restore/reveal (or the hard 1-second deadline). Escape cancels
and clears the queue. Mouse/focus/mode changes and reload discard queued
input so it cannot execute in the wrong context; slow redraws can still be visible.

Passive redraws (subagent status updates re-rendering the whole transcript
with a screen + scrollback clear while you read in terminal-NORMAL) are
covered separately by the passive view keeper: it re-places the cursor and
topline on the same transcript content after such a rewrite, and always
yields to your own keys and to the zo/zc anchors above.

Setup:  require("pi-fold").setup()
Then run pi in a terminal: `:term pi` — mappings attach automatically to
buffers whose job is pi (or any terminal buffer; see setup()).

Caveat: commands are typed into pi's prompt, so use zo/zc while the prompt is
empty (otherwise the command text lands in your draft).

All parsing below is byte-based, the way Lua works: multibyte glyphs are
compared as whole literal strings (`s:sub(1, #p) == p`), never sliced with
byte offsets into the middle of a UTF-8 sequence.

Marker grammar (pi-tidy, icons on). Text after stripping the turn rail `│`:
    ▸ took … / ▾ took … / ▸ running …    turn summary (column 0, no rail)
    ▸ N calls … / ▾ N calls …            tool group header (member summary)
     ├─󰆍 bash ✓ …                        member row of an OPEN box (its top)
     │ 󰆍 bash ✓ ls …                     member row of a collapsed box
     │   … (2+ spaces)                   body of the box opened above it
     ├───…                               an always-shown box (edit/write)
     ├─ 󰚩 model HH:MM …                  assistant reply frame (not a member)
]]

local M = {}

-- ── byte-safe helpers ──────────────────────────────────────────────────────

local function startswith(s, p)
  return s:sub(1, #p) == p
end

-- Drop stray control bytes (OSC/CSI leftovers), keep everything else.
local function clean(line)
  return (line:gsub("^%c+", ""))
end

-- The turn rail is a single `│` glued to the row (pi-tidy's railRows).
local RAIL = "│"

local function strip_rail(s)
  if startswith(s, RAIL) then
    return s:sub(#RAIL + 1)
  end
  return s
end

local TURN_FOLDED = { "▸ took", "▸ running" }
local TURN_OPEN = { "▾ took", "▾ running" }

local function turn_marker(line)
  for _, p in ipairs(TURN_FOLDED) do
    if startswith(line, p) then
      return "▸"
    end
  end
  for _, p in ipairs(TURN_OPEN) do
    if startswith(line, p) then
      return "▾"
    end
  end
  return nil
end

-- NOTE: Lua patterns are byte-based and have NO alternation — `|` is a
-- literal char there, and multibyte glyphs must never go inside a `[...]`
-- class (it would match single bytes of them). Whole-glyph literals only.

-- `▸ 3 calls` / `▾ 3 calls` (a leading space is tolerated: the rail is glued
-- to the glyph; a hovered closed header widens ▸ to ▶).
local function group_header(rest)
  local n = rest:match("^▸ (%d+) calls?") or rest:match("^ ▸ (%d+) calls?")
  if n then
    return "▸", tonumber(n)
  end
  n = rest:match("^▾ (%d+) calls?") or rest:match("^ ▾ (%d+) calls?")
  if n then
    return "▾", tonumber(n)
  end
  n = rest:match("^▶ (%d+) calls?") or rest:match("^ ▶ (%d+) calls?")
  if n then
    return "▸", tonumber(n)
  end
  return nil
end

local STATUS = { ["✓"] = true, ["✗"] = true, ["⋯"] = true, ["⊘"] = true }

-- The first tokens of a member row: `[icon] name status`. Returns the tool
-- name, or nil when the row is something else (a `thinking` row, a nested
-- job row with its own ▸/▾ lead, a wrapped second row without a status …).
local function member_row_name(row)
  local t = {}
  for tok in row:gmatch("%S+") do
    t[#t + 1] = tok
    if #t == 3 then
      break
    end
  end
  local name
  if t[2] and STATUS[t[2]] then
    name = t[1] -- `bash ✓ …` (icons off)
  elseif t[3] and STATUS[t[3]] then
    name = t[2] -- `󰆍 bash ✓ …` (icons on)
  end
  if name and name ~= "thinking" then
    return name
  end
  return nil
end

local function compact_member(rest)
  local row = rest:match("^ │ ([^ ].*)$")
  if not row then
    return false
  end
  return member_row_name(row) ~= nil
end

-- An open member box's top row: the tick gutter ` ├─` glued to the row
-- (no space: `├─󰆍 bash …`). A space after the joint is a reply frame or a
-- custom entry box; a continuing `─` is an always-shown box's border.
-- (Prefix compares stay whole-glyph: Lua's sub() counts bytes, and one byte
-- of a multibyte glyph never equals the glyph.)
local function tick_member_top(rest)
  if not startswith(rest, " ├─") then
    return false
  end
  local after = rest:sub(#" ├─" + 1)
  return after ~= "" and not startswith(after, " ") and not startswith(after, "─")
end

local function is_body(rest)
  -- ` │` + 2+ spaces: an open box's body, its nested rows, a thought body.
  return rest:match("^ │  ") ~= nil
end

--- One pass over the transcript lines. Every line gets:
---   kind = "turn" | "group" | "member" | "body" | "other"
---   turn = 1-based turn ordinal (0 before the first turn summary)
---   marker = "▸" | "▾" (turn/group lines)
---   before = members of this turn that precede the line
---   member = 1-based ordinal of the member this line belongs to
--- Group headers of folded groups count their whole membership; open groups
--- are counted member by member from their rows, so `before` stays correct
--- under any mixture of opened and closed groups.
function M._analyze_lines(lines)
  local meta = {}
  local turn = 0
  local members = 0
  local current_member = nil -- ordinal of the member whose box body we are in

  for ln, raw in ipairs(lines) do
    local line = clean(raw)
    local tm = turn_marker(line)
    if tm then
      turn = turn + 1
      members = 0
      current_member = nil
      meta[ln] = { turn = turn, kind = "turn", marker = tm }
    else
      local rest = strip_rail(line)
      local marker, n = group_header(rest)
      if marker then
        meta[ln] = { turn = turn, kind = "group", marker = marker, before = members }
        current_member = nil
        if marker == "▸" then
          members = members + n
        end
      elseif tick_member_top(rest) then
        members = members + 1
        current_member = members
        meta[ln] = { turn = turn, kind = "member", open = true, member = members }
      elseif compact_member(rest) then
        members = members + 1
        current_member = members
        meta[ln] = { turn = turn, kind = "member", open = false, member = members }
      elseif is_body(rest) and current_member then
        meta[ln] = { turn = turn, kind = "body", member = current_member }
      else
        meta[ln] = { turn = turn, kind = "other" }
      end
    end
  end
  return meta
end

local function analyze(buf)
  return M._analyze_lines(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

-- ── cursor anchoring ───────────────────────────────────────────────────────
-- pi answers every /z… command by reprinting the whole transcript (and may
-- clear the scrollback), so old line numbers never survive the re-render and
-- the window cursor ends up wherever the rewrite left it. dispatch() instead
-- records a SEMANTIC anchor — turn ordinal + member ordinal (or the group's
-- first member) plus the state the target must show AFTER the reprint — and
-- one bounded watcher (a single scheduled timer, no loops, no on_lines
-- bookkeeping) re-parses the buffer until that target line exists, then puts
-- the cursor on it and stops:
--   close box          → that box's own compact row
--   close group        → that group's `▸ N calls` header (from its ▾ header,
--                         or from any of its compact rows)
--   close turn         → the `▸ took` summary
--   open box/group/turn→ the box top / `▾` header / `▾` summary
-- The watcher never steals focus (buffer and window must still be current,
-- stays in NORMAL mode, sends no keys), gives up silently on a bounded
-- timeout or a quiet buffer, and cancels the moment the cursor moves while
-- the buffer is idle — that is the user driving, not the reprint.

local ANCHOR_TICK_MS = 120
local ANCHOR_MAX_TICKS = 60 -- ≈7s hard bound, then silent give-up
local ANCHOR_QUIET_TICKS = 10 -- ≈1.2s settled without target: no reprint coming
local ANCHOR_SETTLE_TICKS = 2 -- ≈240ms of quiet with cursor on target: done

local anchor = nil -- the one active watcher, or nil

-- ── freeze frame for explicit zo/zc ────────────────────────────────────
-- The reprint's visible up-then-down jump is hidden behind a frozen copy
-- of the pre-command frame (pi-fold-frame.lua, non-focusable win-relative
-- float) created before the command is sent. Load failure or a window that
-- cannot be snapshotted degrades silently to the plain cursor anchor.
local pfframe
local frame = nil -- the live handle, or nil (nil = plain anchor only)
local frame_drop, frame_show, frame_restore -- fwd: defined after anchor_start
local chansend_pi -- fwd: defined with dispatch below (send_fold uses it)
local function frame_load()
  local src = debug.getinfo(2, "S").source:sub(2)
  local dir = src:match("^(.*)/[^/]+$")
  if not dir then
    return nil
  end
  local ok, mod = pcall(dofile, dir .. "/pi-fold-frame.lua")
  if ok and type(mod) == "table" and type(mod.hold) == "function" then
    return mod
  end
  return nil
end
pfframe = frame_load() -- absent/unusable: zo/zc fall back to the plain anchor

-- Forward refs into the passive view keeper (defined below, after the
-- anchor machinery): the anchor owns the view while it runs, then hands the
-- reading position to the keeper.
local keeper_seed, keeper_cancel

local uv = vim.uv or vim.loop

local function anchor_signature(buf)
  -- changedtick bumps on every terminal write; line count catches trims
  local ok, tick = pcall(vim.api.nvim_buf_get_changedtick, buf)
  local n = vim.api.nvim_buf_line_count(buf)
  return (ok and tick or 0) .. ":" .. n
end

--- The buffer line the anchor is waiting for, or nil. Matched semantically
--- (turn ordinal, member ordinal / group member-start, marker + open state),
--- never by text: headers and rows repeat across turns and groups.
local function anchor_target_line(buf, spec)
  local meta = analyze(buf)
  for ln, m in pairs(meta) do
    if m.turn == spec.turn then
      if spec.kind == "turn" then
        if m.kind == "turn" and m.marker == spec.marker then
          return ln
        end
      elseif spec.kind == "group" then
        if m.kind == "group" and m.marker == spec.marker
            and (m.before or 0) + 1 == spec.member then
          return ln
        end
      elseif m.kind == "member" and m.member == spec.member
          and m.open == spec.open then
        return ln
      end
    end
  end
  return nil
end

local function anchor_stop(reason)
  local buf = anchor and anchor.buf
  frame_drop(reason or "complete") -- reveal before replaying any queued keys
  if anchor and anchor.timer then
    pcall(function()
      anchor.timer:close()
    end)
  end
  anchor = nil
  -- the explicit target landed (or gave up): the passive keeper's next
  -- snapshot must start from THIS position, never the pre-command one
  if buf and keeper_seed then
    keeper_seed(buf)
  end
end

local function anchor_tick()
  local buf, win = anchor.buf, anchor.win
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return true
  end
  -- never pull focus back: the user left the terminal buffer/window
  if vim.api.nvim_get_current_buf() ~= buf or vim.api.nvim_get_current_win() ~= win
      or vim.api.nvim_get_mode().mode ~= "nt" then
    return true
  end
  anchor.ticks = anchor.ticks + 1
  if anchor.ticks > ANCHOR_MAX_TICKS then
    return true
  end
  local sig = anchor_signature(buf)
  local printing = sig ~= anchor.sig
  if printing then
    anchor.quiet = 0
  else
    anchor.quiet = anchor.quiet + 1
  end
  anchor.sig = sig
  local pos = vim.api.nvim_win_get_cursor(win)
  if not printing and (pos[1] ~= anchor.pos[1] or pos[2] ~= anchor.pos[2]) then
    return true -- idle buffer, moving cursor: the user is navigating
  end
  anchor.pos = pos
  local ln = anchor_target_line(buf, anchor)
  if frame then
    if frame.dead then
      frame = nil -- handle ended itself (1 s cap / lifecycle): plain anchor
    elseif ln and anchor.quiet >= 1 then
      -- reprint settled with the target present: put it back at its
      -- pre-command screen row, then reveal the real window
      frame_restore(win, ln)
      return true
    end
    return false -- still frozen: nothing user-visible to do under the frame
  end
  if ln then
    if pos[1] ~= ln and (printing or not anchor.placed) then
      -- only move the cursor while pi is (still) printing, or once ever
      pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
      anchor.placed = true
    end
    if anchor.quiet >= ANCHOR_SETTLE_TICKS then
      return true -- reprint settled with the cursor on the target
    end
  elseif anchor.quiet >= ANCHOR_QUIET_TICKS then
    return true -- pi settled without our target (no-op / draft prompt): give up
  end
  return false
end

--- Record `spec` and place the cursor on its target line once the reprinted
--- buffer shows it. Supersedes any watcher still running.
local function anchor_start(spec, buf)
  anchor_stop("superseded")
  if keeper_cancel then
    keeper_cancel(buf) -- explicit zo/zc target outranks any passive restore
  end
  anchor = {
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    turn = spec.turn,
    kind = spec.kind,
    member = spec.member,
    marker = spec.marker,
    open = spec.open,
    ticks = 0,
    quiet = 0,
    placed = false,
    sig = anchor_signature(buf),
    pos = vim.api.nvim_win_get_cursor(0),
  }
  local timer = uv.new_timer()
  anchor.timer = timer
  timer:start(ANCHOR_TICK_MS, ANCHOR_TICK_MS, vim.schedule_wrap(function()
    if not anchor or anchor.timer ~= timer then
      return
    end
    if anchor_tick() then
      anchor_stop()
    end
  end))
end

-- ── freeze frame bodies (need anchor_start above) ─────────────────────

frame_drop = function(reason)
  if frame then
    local h = frame
    frame = nil
    if h and not h.dead then
      pcall(h.drop, reason or "cancel")
    end
  end
end

--- The fold target's pre-command line (any marker state: the ▾ header of a
--- group about to collapse, the member row about to fold …), so the reveal
--- keeps the target at ITS screen row, not the cursor's.
local function frame_ref_row(buf, spec)
  local meta = analyze(buf)
  local found = nil
  for ln, m in pairs(meta) do
    if m.turn == spec.turn then
      local hit = false
      if spec.kind == "turn" then
        hit = m.kind == "turn"
      elseif spec.kind == "group" then
        hit = m.kind == "group" and (m.before or 0) + 1 == spec.member
      elseif spec.kind == "member" then
        hit = m.kind == "member" and m.member == spec.member
      end
      if hit and (not found or ln < found) then
        found = ln
      end
    end
  end
  return found
end

--- Freeze the current view of the pi window (no-op when impossible).
frame_show = function(buf, spec)
  frame_drop("superseded")
  if not pfframe or vim.api.nvim_get_mode().mode ~= "nt" then
    return
  end
  -- Flush prior user navigation before taking the screen snapshot. No Pi
  -- command has been sent yet, so this cannot expose the reprint itself.
  vim.cmd("redraw")
  local ok, h = pcall(pfframe.hold, vim.api.nvim_get_current_win(), buf)
  if not ok then return end -- snapshot failure must never break folding
  if h and spec then
    local ln = frame_ref_row(buf, spec)
    if ln then
      h.ref.row = ln
    end
  end
  frame = h
  if h then
    h.keys = {}
    local generation, owner = _G.__pifold_keeper_gen, anchor
    h.on_drop = function(reason)
      if frame == h then frame = nil end
      local keys = table.concat(h.keys)
      h.keys = {}
      if reason ~= "complete" and reason ~= "timeout" then return end
      if reason == "timeout" and anchor == owner then
        anchor_stop("timeout") -- no late cursor move ahead of released input
      end
      if keys == "" then return end
      vim.schedule(function()
        if generation ~= _G.__pifold_keeper_gen
            or not vim.api.nvim_buf_is_valid(h.buf)
            or not vim.api.nvim_win_is_valid(h.win)
            or vim.api.nvim_get_current_win() ~= h.win
            or vim.api.nvim_get_current_buf() ~= h.buf
            or vim.api.nvim_get_mode().mode ~= "nt" then return end
        -- Original typed keycodes, remapped normally, inserted before newer
        -- typeahead. If a queued fold starts a new frame, its remaining keys
        -- will naturally wait in that new frame's queue.
        vim.api.nvim_feedkeys(keys, "mit", false)
      end)
    end
  end
end

--- Restore `ln` at its preserved screen-relative row (as far as the buffer
--- end allows) — the reveal happens in the same redraw as frame_drop.
frame_restore = function(win, ln)
  local h = frame
  if not h or h.dead then
    return
  end
  local count = vim.api.nvim_buf_line_count(h.buf)
  local wh = vim.api.nvim_win_get_height(win)
  local topline = math.max(1, math.min(ln - (h.ref.row - h.ref.topline), math.max(1, count - wh + 1)))
  pcall(vim.fn.winrestview, {
    lnum = ln,
    col = 0,
    topline = topline,
    topfill = 0,
    leftcol = h.ref.leftcol,
    curswant = 0,
  })
end

--- Test hook: the live freeze-frame handle (truthy) or nil.
function M._frame_active()
  return (frame and not frame.dead) and frame or nil
end

--- Send one /z… command under a freeze frame. anchor_start first (it
--- supersedes any older watcher and snapshots the pre-command buffer), then
--- the frozen overlay, then chansend: pi's reply can never race the frame.
local function send_fold(buf, cmd, spec)
  anchor_start(spec, buf)
  frame_show(buf, spec)
  chansend_pi(cmd)
end

-- ── passive view keeper ─────────────────────────────────────────────────
-- pi's TUI periodically re-renders the whole transcript with a screen clear
-- + scrollback wipe (ESC[2J ESC[H ESC[3J from fullRender(true)) whenever a
-- change lands above its own viewport — routinely while subagents stream.
-- Nvim then deletes the scrollback the terminal-NORMAL cursor is parked in
-- and clamps it to line 1, even though the replay holds the same content.
-- The keeper snapshots the reading position (semantic anchor + verified
-- line text + view offset) whenever it settles, recognizes that destructive
-- rewrite from buffer change events, and afterwards re-places cursor and
-- topline in the same window. It never acts when the user typed during the
-- rewrite (their keys always win), when the window is not the current one
-- (no focus stealing), when the mode left terminal-NORMAL (insert stays
-- natural), or while an explicit zo/zc anchor owns the reprint.

local KEEPER_SETTLE_MS = 90 -- debounce: a replay's chunks coalesce into one restore
local KEEPER_MAX_LATENCY_MS = 400 -- hard cap: continuous output must not starve a restore
local KEEPER_RETRY_MS = 2500 -- how long to keep retrying for a late replay chunk
local KEEPER_RECHECK_MS = 1000 -- a shell may later start pi without much output
local KEEPER_TAIL_MARGIN = 2 -- cursor this close to the buffer end: follow output instead
local KEEPER_CAPTURE_MS = 250 -- cursor moved → quiet → adopt the new spot as the snapshot
local KEEPER_SCAN_LINES = 300 -- bounded "is this a pi transcript?" scan

local keeper = { bufs = {}, last_key = 0 }

-- Reload safety: a stale module instance's timers/watchers must die when a
-- new one loads; old callbacks self-detach via the generation check, and the
-- namespaced on_key registration replaces the previous one.
if _G.__pifold_keeper_shutdown then
  pcall(_G.__pifold_keeper_shutdown)
end
_G.__pifold_keeper_gen = (_G.__pifold_keeper_gen or 0) + 1
keeper.gen = _G.__pifold_keeper_gen
keeper.ns = vim.api.nvim_create_namespace("pi-fold-keeper")
keeper.on_key = function(key, typed)
  if keeper.gen ~= _G.__pifold_keeper_gen then
    return
  end
  if frame and not frame.dead then
    local h = frame
    local mouse = vim.fn.keytrans(key):find("Mouse", 1, true)
        or vim.fn.keytrans(key):find("ScrollWheel", 1, true)
    if vim.api.nvim_get_current_win() ~= h.win
        or vim.api.nvim_get_current_buf() ~= h.buf
        or vim.api.nvim_get_mode().mode ~= "nt" or mouse then
      frame_drop("context") -- never replay keys into another window/mode
    elseif key == "\27" or typed == "\27" then
      frame_drop("cancel")
      anchor_stop("cancel")
      keeper_cancel(h.buf)
      return "" -- Escape is the emergency cancel, not a queued command
    else
      -- on_key runs AFTER mappings. Save `typed` (pre-mapping bytes) once,
      -- discard every mapped expansion; replay can then apply the mapping
      -- exactly once. <Cmd> is discarded as a whole by Neovim's on_key API.
      if typed and typed ~= "" then h.keys[#h.keys + 1] = typed end
      return ""
    end
  end
  keeper.last_key = vim.loop.now()
  local buf = vim.api.nvim_get_current_buf()
  if anchor and anchor.buf == buf then
    anchor_stop()
  end
  local st = keeper.bufs[buf]
  if st and st.pending then
    keeper_cancel(buf)
  end
  -- The old CursorMoved path waits for 250 ms without terminal writes. A
  -- streaming reply may never provide that gap, so genuine user navigation
  -- needs a separate post-key snapshot (never a post-output clamp snapshot).
  if st then
    keeper.key_serial = (keeper.key_serial or 0) + 1
    local serial, win = keeper.key_serial, vim.api.nvim_get_current_win()
    vim.schedule(function()
      if keeper.gen == _G.__pifold_keeper_gen and keeper.key_serial == serial
          and keeper.bufs[buf] == st and not st.pending and not anchor
          and vim.api.nvim_get_current_win() == win
          and vim.api.nvim_get_current_buf() == buf
          and vim.api.nvim_get_mode().mode == "nt" then
        keeper_seed(buf)
      end
    end)
  end
end

--- Timing digits change between renders; the line's identity does not.
function M._keeper_digit_blind(s)
  return (s:gsub("%d+", "#"))
end

--- Snap a 0-based byte column onto a UTF-8 character boundary (a replay can
--- land mid-glyph when the line content shifted). Byte math only, like the
--- rest of the parser.
function M._keeper_utf8_col(text, col)
  if col <= 0 then
    return 0
  end
  local n = #text
  if col >= n then
    return n
  end
  local i = col + 1
  while i > 1 do
    local b = text:byte(i)
    if b < 0x80 or b > 0xBF then -- ASCII or a UTF-8 lead byte
      break
    end
    i = i - 1
  end
  return i - 1
end

-- A plain assistant reply can have NO took/group markers. Its final frame
-- has a model label and time; a user frame has only an icon and time.
local function reply_header(line)
  if not startswith(line, "╭─ ") and not startswith(line, "├─ ") then return nil end
  local label = line:sub(#"╭─ " + 1):match("^(.-)%s+%d%d:%d%d")
  if not label or not label:find("%a") then return nil end
  return (label:gsub("%s+%d%d%d%d%-%d%d%-%d%d$", ""):gsub("%s+%d%d%-%d%d$", ""))
end

-- Strip only drawing rails/borders, not meaningful punctuation or digits.
-- This lets a reading anchor survive the plain-stream -> settled-frame step.
local function reading_text(line)
  line = clean(line)
  local header = reply_header(line)
  if header then return "[assistant] " .. header end
  if startswith(line, "│ ") then line = line:sub(#"│ " + 1) end
  if line:sub(-#"│") == "│" then line = line:sub(1, -#"│" - 1) end
  return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Plain prose has no tool ordinal. Match its content plus nearby context,
-- accepting an unfinished line that has gained a suffix. Never pick the
-- first of several identical lines just because it happens to be first.
local function reading_resolve(lines, snap)
  local want = reading_text(snap.text)
  if #want < 8 then return nil end -- whitespace and short/common labels aren't identity
  local best, score, tied
  for row, raw in ipairs(lines) do
    local text = reading_text(raw)
    local exact = text == want
    local growing = #want >= 12 and text:sub(1, #want) == want
    if exact or growing then
      local context = 0
      for _, near in ipairs(snap.context or {}) do
        if lines[row + near.offset] and reading_text(lines[row + near.offset]) == near.text then
          context = context + 1
        end
      end
      -- A changing prefix needs a stable neighbor as corroboration.
      if exact or context > 0 then
        local s = context * 2 + (exact and 1 or 0)
        if not score or s > score then best, score, tied = row, s, false
        elseif s == score then tied = true end
      end
    end
  end
  if best and not tied then return best, "reading" end
  return nil
end

--- Recognize Pi even before the first tool call and before a reply settles.
--- A pi launched inside an existing shell still reports /bin/bash as its job.
function M._keeper_is_pi(lines)
  for _, raw in ipairs(lines) do
    local line = clean(raw)
    if turn_marker(line) or group_header(strip_rail(line)) or reply_header(line)
        or (line:find("escape interrupt", 1, true) and line:find("ctrl+c/ctrl+d", 1, true))
        or line:find("Pi can explain its own features and look up its docs", 1, true) then
      return true
    end
  end
  return false
end

--- Where in `lines` does reading position `snap` live after a replay?
--- Marker lines (turn/group/member) match semantically — turn ordinal,
--- member ordinal / group member-start, marker + open state — so duplicate
--- header texts never select the wrong occurrence; the match is verified
--- against the snapshot's own text (digit-blind for turn/group timing).
--- Member text must match exactly; a shared tool prefix is not identity. Prose and body
--- lines match by exact text at the same offset inside the same semantic
--- unit. Returns the 1-based row, or nil when nothing verifies (history
--- truncated, target replaced): the caller must then stay put, not jump to
--- unrelated content.
function M._keeper_resolve(lines, snap)
  if not snap then
    return nil
  end
  if snap.turn == 0 then
    return reading_resolve(lines, snap)
  end
  local meta = M._analyze_lines(lines)
  local want = snap.text
  local wantb = M._keeper_digit_blind(want)
  local member_first, turn_first = nil, nil
  for ln, m in pairs(meta) do
    if m.turn == snap.turn then
      if snap.kind == "turn" and m.kind == "turn" and m.marker == snap.marker then
        if M._keeper_digit_blind(clean(lines[ln])) == wantb then
          return ln, "semantic"
        end
      elseif snap.kind == "group" and m.kind == "group" and m.marker == snap.marker
          and (m.before or 0) + 1 == snap.member then
        if M._keeper_digit_blind(clean(lines[ln])) == wantb then
          return ln, "semantic"
        end
      elseif snap.kind == "member" and m.kind == "member" and m.member == snap.member
          and m.open == snap.open then
        local t = clean(lines[ln])
        if t == want then
          return ln, "semantic"
        end
      elseif snap.kind == "body" and m.kind == "member" and m.member == snap.member
          and (not snap.unit_text or clean(lines[ln]) == snap.unit_text) then
        local t = ln + snap.off -- ln is the box top; snap.off = row − box top
        if lines[t] and clean(lines[t]) == want then
          return t, "body"
        end
      elseif m.kind == "turn" then
        if not turn_first or ln < turn_first then
          turn_first = ln
        end
      end
      if snap.member and m.kind == "member" and m.member == snap.member
          and (not snap.unit_text or clean(lines[ln]) == snap.unit_text) then
        if not member_first or ln < member_first then
          member_first = ln
        end
      end
    end
  end
  -- prose / "other" lines: same semantic unit (member box or turn), same
  -- offset, same text; a bounded look-around tolerates a line inserted above
  local unit = snap.member and member_first or turn_first
  if unit then
    local t = unit + snap.off
    if lines[t] and clean(lines[t]) == want then
      return t, "text"
    end
    if #want >= 8 then
      local last = math.min(#lines, unit + snap.off + 40)
      for ln = unit, last do
        local m = meta[ln]
        if ln > unit and m and (m.kind == "turn" or m.kind == "group" or m.kind == "member") then
          break
        end
        if clean(lines[ln]) == want then
          return ln, "text-scan"
        end
      end
    end
  end
  if snap.kind == "other" then
    return reading_resolve(lines, snap)
  end
  return nil
end

local function kstate(buf)
  local st = keeper.bufs[buf]
  if not st then
    st = { snap = nil, pending = nil }
    keeper.bufs[buf] = st
  end
  return st
end

local function keeper_win(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
  return nil
end

local function keeper_topline(win)
  local info = vim.fn.getwininfo(win)
  if info and info[1] and info[1].topline then
    return info[1].topline
  end
  return 1
end

--- Record the current reading position as the pre-change snapshot. Only
--- ever called from moments the user's view is settled: entering
--- terminal-NORMAL, a quiet cursor move (user navigation), a completed
--- restore, or a finished explicit anchor — never from a change event, whose
--- content is already the post-clear buffer.
local keeper_recognize
local function keeper_capture(buf, win)
  local st = kstate(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= buf then
    st.snap = nil
    return
  end
  local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok then
    st.snap = nil
    return
  end
  local row, col = pos[1], pos[2]
  local count = vim.api.nvim_buf_line_count(buf)
  keeper_recognize(buf, st)
  local context = {}
  for offset = -2, 2 do
    if offset ~= 0 and row + offset > 0 and row + offset <= count then
      local text = reading_text(vim.api.nvim_buf_get_lines(buf, row + offset - 1, row + offset, false)[1] or "")
      if #text >= 8 and text:find("[%w\128-\255]") then
        context[#context + 1] = { offset = offset, text = text }
      end
    end
  end
  local meta = analyze(buf)
  local m = meta[row] or {}
  local text = clean(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "")
  -- semantic identity of the line; a group header's is the ordinal of its
  -- first member (same identity dispatch() uses for /zgroup)
  local member = m.member
  if not member and m.kind == "group" then
    member = (m.before or 0) + 1
  end
  -- the semantic unit the line belongs to (member box top / turn summary):
  -- prose lines restore relative to it, immune to line-number drift
  local unit_first = row
  if m.turn and m.turn > 0 then
    if m.member then
      for ln = row, 1, -1 do
        local u = meta[ln]
        if u and u.kind == "turn" then
          break -- crossed into the previous turn: no unit top above
        elseif u and u.turn == m.turn and u.kind == "member" and u.member == m.member then
          unit_first = ln
          break
        end
      end
    else
      for ln = row, 1, -1 do
        local u = meta[ln]
        if u and u.kind == "turn" and u.turn == m.turn then
          unit_first = ln
          break
        end
      end
    end
  end
  local topline, leftcol = keeper_topline(win), 0
  if vim.api.nvim_get_current_win() == win then
    local v = vim.fn.winsaveview()
    topline, leftcol = v.topline, v.leftcol
  end
  st.snap = {
    buf = buf,
    win = win,
    row = row,
    col = col,
    topline = topline,
    leftcol = leftcol,
    text = text,
    context = context,
    turn = m.turn or 0,
    kind = m.kind,
    member = member,
    marker = m.marker,
    open = m.open,
    unit_first = unit_first,
    unit_text = m.member and clean(vim.api.nvim_buf_get_lines(buf, unit_first - 1, unit_first, false)[1] or "") or nil,
    off = row - unit_first,
    line_count = count,
    tail = row >= count - KEEPER_TAIL_MARGIN,
  }
end

--- Adopt the current view as the next snapshot (used by anchor handoff and
--- after a restore). Safe no-op when the buffer is not being kept.
keeper_seed = function(buf)
  local st = keeper.bufs[buf]
  if not st or anchor then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == buf
      and vim.api.nvim_get_mode().mode == "nt" then
    keeper_capture(buf, win)
  end
end

keeper_cancel = function(buf)
  local st = keeper.bufs[buf]
  if not st then
    return
  end
  st.pending = nil
  if st.timer then
    st.timer:stop()
  end
end

--- (Re)start the one verify timer for `buf` so it fires at `due` (ms clock).
local keeper_verify
local function keeper_arm_timer(buf, st, due)
  if not st.timer then
    st.timer = uv.new_timer()
    st.verify = vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(buf) then
        keeper_verify(buf)
      end
    end)
  end
  local delay = math.max(1, due - vim.loop.now())
  st.timer:stop()
  st.timer:start(delay, 0, st.verify)
end

keeper_verify = function(buf)
  local st = keeper.bufs[buf]
  local p = st and st.pending
  if not p then
    return
  end
  local function drop()
    st.pending = nil
    if st.timer then
      st.timer:stop()
    end
  end
  if anchor then
    drop() -- an explicit zo/zc target owns the reprint
    return
  end
  if keeper.last_key > p.first then
    drop() -- the user typed during the rewrite: their position wins
    return
  end
  local snap = p.snap
  local win = snap.win
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= buf
      or vim.api.nvim_get_current_buf() ~= buf
      or vim.api.nvim_get_current_win() ~= win then
    drop() -- never steal focus or reach into a background window/tab
    return
  end
  if vim.api.nvim_get_mode().mode ~= "nt" then
    drop() -- terminal-insert (and anything else) stays natural
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local pos = vim.api.nvim_win_get_cursor(win)
  if pos[1] == snap.row and keeper_topline(win) == snap.topline
      and count == snap.line_count then
    drop() -- view undisturbed: the change was benign (a header/status edit)
    return
  end
  p.attempts = p.attempts + 1
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Clearing scrollback destroys native tail-follow too. At the live footer
  -- preserve distance from the END, not blank text or a decorative border
  -- that may occur hundreds of times in file previews/history.
  local row = snap.tail and math.max(1, count - (snap.line_count - snap.row))
      or M._keeper_resolve(lines, snap)
  if not row then
    if vim.loop.now() < p.first + KEEPER_RETRY_MS then
      -- the replay is still delivering chunks and the target line sits in a
      -- later one: retry on the settle cadence, bounded by the deadline
      keeper_arm_timer(buf, st, vim.loop.now() + KEEPER_SETTLE_MS)
    else
      drop() -- target gone (truncated history / replaced): give up safely
    end
    return
  end
  drop()
  local col = M._keeper_utf8_col(clean(lines[row] or ""), snap.col)
  local h = vim.api.nvim_win_get_height(win)
  local topline = math.max(1, math.min(row + (snap.topline - snap.row), math.max(1, count - h + 1)))
  pcall(vim.fn.winrestview, {
    lnum = row,
    col = col,
    topline = topline,
    topfill = 0,
    leftcol = snap.leftcol,
    curswant = col,
  })
  keeper_capture(buf, win) -- the restored view is the next pre-change state
end

--- Bounded recognition of a pi-tidy transcript by content (a pi under a
--- shell reports job /bin/bash, so the keeper cannot use the job command;
--- plain shell output never carries turn summaries or group headers).
--- Re-run on NORMAL entry and after substantial growth: pi may start inside
--- an existing shell long after the buffer first looked plain.
keeper_recognize = function(buf, st)
  local count = vim.api.nvim_buf_line_count(buf)
  local scan = vim.api.nvim_buf_get_lines(buf, 0, math.min(count, KEEPER_SCAN_LINES), false)
  if count > KEEPER_SCAN_LINES * 2 then
    local tailscan =
      vim.api.nvim_buf_get_lines(buf, count - KEEPER_SCAN_LINES, -1, false)
    for _, l in ipairs(tailscan) do
      scan[#scan + 1] = l
    end
  end
  st.is_pi = M._keeper_is_pi(scan)
  st.pi_checked_at = vim.loop.now()
end

local function keeper_on_lines(buf, line, last_line, new_last_line)
  local st = keeper.bufs[buf]
  if not st or anchor then
    return -- no keeper state, or an explicit zo/zc anchor owns the buffer
  end
  if vim.api.nvim_get_mode().mode ~= "nt" then
    return -- insert mode follows the emulator cursor by design
  end
  if st.is_pi == nil
      or (not st.is_pi and vim.loop.now() - (st.pi_checked_at or 0) >= KEEPER_RECHECK_MS) then
    keeper_recognize(buf, st)
  end
  if not st.is_pi or not st.snap then
    return
  end
  if not st.pending then
    -- arm only on the destructive signature: a shrinking line count, or a
    -- wholesale rewrite of the top of a buffer bigger than the window
    local win = keeper_win(buf)
    if not win or win ~= vim.api.nvim_get_current_win() then
      return -- only the window being read is worth restoring
    end
    local h = vim.api.nvim_win_get_height(win)
    local shrink = new_last_line < last_line and (line <= 1 or new_last_line < last_line - 2)
    local wholesale = line <= 1 and new_last_line > h
    if not (shrink or wholesale or st.snap.tail) then
      return -- history reading: ordinary append/status writes need no move
    end
    -- Tail readers must follow later replay chunks/appends as well: a clear
    -- may arrive separately, before the rest of the document is delivered.
    st.pending = { first = vim.loop.now(), snap = st.snap, attempts = 0 }
  end
  -- any further write while pending is another chunk of the same replay:
  -- push the verify out — first attempt hard-capped so continuous output
  -- cannot starve it, later retries on the settle cadence
  local now = vim.loop.now()
  local p = st.pending
  local due = p.attempts == 0
      and math.min(now + KEEPER_SETTLE_MS, p.first + KEEPER_MAX_LATENCY_MS)
      or (now + KEEPER_SETTLE_MS)
  keeper_arm_timer(buf, st, due)
  -- A completed clear+replay often arrives in a single buffer event. Restore
  -- on the next safe main-loop turn, before the normal UI flush, rather than
  -- deliberately exposing line 1 for the 90 ms settle timer. Partial replays
  -- still use the existing bounded retry path if the target isn't here yet.
  if not st.fast_queued then
    st.fast_queued = true
    vim.schedule(function()
      st.fast_queued = nil
      if keeper.gen == _G.__pifold_keeper_gen and keeper.bufs[buf] == st
          and st.pending and vim.api.nvim_buf_is_valid(buf) then
        keeper_verify(buf)
      end
    end)
  end
end

local function keeper_detach(buf)
  local st = keeper.bufs[buf]
  if not st then
    return
  end
  keeper.bufs[buf] = nil
  if st.timer then
    pcall(function()
      st.timer:close()
    end)
  end
  if st.cap_timer then
    pcall(function()
      st.cap_timer:close()
    end)
  end
  -- the buffer watcher self-detaches by seeing keeper.bufs[buf] gone
  pcall(vim.api.nvim_clear_autocmds, { buffer = buf, group = "pi-fold-keeper" })
end

local function keeper_attach(buf)
  local st = kstate(buf)
  if st.attached then
    return
  end
  st.attached = true
  if not keeper.autocmds_made then
    -- one shared autocmd set per module instance; clearing the group also
    -- drops the previous instance's autocmds after a reload (its buffer
    -- watchers self-detach via the generation check)
    keeper.autocmds_made = true
    vim.api.nvim_create_augroup("pi-fold-keeper", { clear = true })
    -- global (buffer-local + pattern is not allowed for ModeChanged): the
    -- callback guards on the current buffer itself
    vim.api.nvim_create_autocmd("ModeChanged", {
      group = "pi-fold-keeper",
      pattern = "*:nt", -- entering terminal-NORMAL (e.g. C-\ C-N)
      callback = function()
        if keeper.gen ~= _G.__pifold_keeper_gen then
          return
        end
        local cur = vim.api.nvim_get_current_buf()
        local s = keeper.bufs[cur]
        if not s then
          return
        end
        s.pending = nil
        if s.timer then
          s.timer:stop()
        end
        s.is_pi = nil -- recheck: pi may have started since the last look
        -- fresh terminal-NORMAL entry: where reading starts is the snapshot
        local w = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == cur then
          keeper_capture(cur, w)
        end
      end,
    })
  end
  pcall(vim.api.nvim_buf_attach, buf, false, {
    -- args: ("lines", buf, changedtick, first_line, last_line, new_last_line,
        -- byte_count) — the first is the event name, NOT the buffer
    on_lines = function(_, b, _, line, last_line, new_last_line)
      if keeper.gen ~= _G.__pifold_keeper_gen then
        return true -- stale watcher from a previous module instance: detach
      end
      if not keeper.bufs[b] then
        return true -- state dropped (TermClose/detach): stop watching
      end
      keeper_on_lines(b, line, last_line, new_last_line)
    end,
    on_detach = function(a, b)
      if keeper.gen ~= _G.__pifold_keeper_gen then
        return true
      end
      local bnum = (type(a) == "number") and a or b
      if bnum and keeper.bufs[bnum] then
        keeper.bufs[bnum] = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = "pi-fold-keeper",
    buffer = buf,
    callback = function()
      local s = keeper.bufs[buf]
      if not s or s.pending or vim.api.nvim_get_mode().mode ~= "nt" then
        return -- a move during a replay may be the clamp, not the user
      end
      if vim.api.nvim_get_current_buf() ~= buf then
        return
      end
      -- quiet settle after a cursor move = the user navigating: adopt the
      -- new reading spot (debounced; a write during the window keeps the
      -- previous good snapshot instead of a transient position)
      if s.cap_timer and not s.cap_timer:is_closing() then
        s.cap_timer:stop()
      end
      if not s.cap_timer then
        s.cap_timer = uv.new_timer()
      end
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local sig = anchor_signature(buf)
      s.cap_timer:start(KEEPER_CAPTURE_MS, 0, vim.schedule_wrap(function()
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        local s2 = keeper.bufs[buf]
        if not s2 or s2.pending or vim.api.nvim_get_mode().mode ~= "nt" then
          return
        end
        local w = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_get_buf(w) ~= buf
            or anchor_signature(buf) ~= sig
            or vim.api.nvim_win_get_cursor(w)[1] ~= row then
          return
        end
        keeper_capture(buf, w)
      end))
    end,
  })
  vim.api.nvim_create_autocmd({ "TermClose", "BufUnload" }, {
    group = "pi-fold-keeper",
    buffer = buf,
    callback = function()
      keeper_detach(buf)
    end,
  })
end

_G.__pifold_keeper_shutdown = function()
  anchor_stop("shutdown")
  vim.on_key(nil, keeper.ns)
  for b in pairs(keeper.bufs) do
    keeper_detach(b)
  end
end

-- namespaced: a reload replaces the previous registration instead of piling
-- up inert callbacks (create_namespace() is idempotent per name)
vim.on_key(keeper.on_key, keeper.ns)

--- First member ordinal of the group governing line `row` (the cursor's own
--- header, else the nearest group header above it in the same turn).
local function group_start(meta, row)
  local t = meta[row].turn
  for ln = row, 1, -1 do
    local m = meta[ln]
    if m and m.turn == t and m.kind == "group" then
      return (m.before or 0) + 1
    end
  end
  return meta[row].member
end

chansend_pi = function(cmd)
  local chan = vim.b.terminal_job_id
  if not chan then
    vim.notify("pi-fold: not a terminal buffer", vim.log.levels.WARN)
    return
  end
  vim.fn.chansend(chan, cmd .. "\r")
end

function M.dispatch(mode) -- "open" | "close"
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local meta = analyze(buf)
  local here = meta[row]
  if not here or here.turn == 0 then
    return
  end

  if mode == "open" then
    if here.kind == "turn" and here.marker == "▸" then
      send_fold(buf, ("/zturn %d open"):format(here.turn), { turn = here.turn, kind = "turn", marker = "▾" })
    elseif here.kind == "group" and here.marker == "▸" then
      -- Open the group only: one row per call, no box output.
      send_fold(buf, ("/zgroup %d %d open"):format(here.turn, here.before + 1),
        { turn = here.turn, kind = "group", member = here.before + 1, marker = "▾" })
    elseif here.kind == "member" and not here.open then
      send_fold(buf, ("/zbox %d %d open"):format(here.turn, here.member),
        { turn = here.turn, kind = "member", member = here.member, open = true })
    end
    -- ▾ turns, ▾ groups, open boxes and body lines: already open, no-op.
    return
  end

  -- close: the nearest open fold at the cursor
  if here.kind == "turn" then
    if here.marker == "▾" then
      send_fold(buf, ("/zturn %d close"):format(here.turn), { turn = here.turn, kind = "turn", marker = "▸" })
    end
    return
  end
  if here.kind == "group" then
    if here.marker == "▾" then
      send_fold(buf, ("/zgroup %d %d close"):format(here.turn, here.before + 1),
        { turn = here.turn, kind = "group", member = here.before + 1, marker = "▸" })
    else
      -- A folded group inside an open turn: the turn is the nearest open fold.
      send_fold(buf, ("/zturn %d close"):format(here.turn), { turn = here.turn, kind = "turn", marker = "▸" })
    end
    return
  end
  if here.kind == "member" then
    if here.open then
      send_fold(buf, ("/zbox %d %d close"):format(here.turn, here.member),
        { turn = here.turn, kind = "member", member = here.member, open = false })
    else
      -- The box is already a row; its group is the nearest open fold.
      send_fold(buf, ("/zgroup %d %d close"):format(here.turn, here.member),
        { turn = here.turn, kind = "group", member = group_start(meta, row), marker = "▸" })
    end
    return
  end
  if here.kind == "body" then
    send_fold(buf, ("/zbox %d %d close"):format(here.turn, here.member),
      { turn = here.turn, kind = "member", member = here.member, open = false })
    return
  end
  -- Reply text and anything else inside an open turn: fold the turn.
  send_fold(buf, ("/zturn %d close"):format(here.turn), { turn = here.turn, kind = "turn", marker = "▸" })
end

local function job_is_pi(buf)
  -- nvim: b:terminal_job_id is the job/channel id; job_info() takes it directly
  local chan = vim.b[buf].terminal_job_id
  if chan then
    local ok, info = pcall(vim.fn.job_info, chan)
    local cmd = ok and type(info) == "table" and info.cmd or nil
    if type(cmd) == "table" then
      for _, arg in ipairs(cmd) do
        if arg:match("([^/]+)$") == "pi" then
          return true
        end
      end
    end
  end
  -- fallback: the terminal buffer name carries the command — "term://…:pi",
  -- "term://…:pi --session …"; nvim's job_info() leaves cmd empty for :terminal jobs
  local name = vim.api.nvim_buf_get_name(buf)
  return name:match("term://.*:pi$") ~= nil or name:match("term://.*:pi %S") ~= nil
end

--- Attach zo/zc mappings to a terminal buffer (default: current).
--- `force` skips the pi-job check — useful when pi runs inside a shell
--- (the terminal's job is /bin/bash, not pi); dispatch() is a no-op unless
--- the cursor line parses as a pi-tidy marker anyway.
function M.attach(buf, force)
  buf = buf or vim.api.nvim_get_current_buf()
  if not force and not job_is_pi(buf) then
    vim.notify("pi-fold: this buffer's job is not pi", vim.log.levels.WARN)
    return
  end
  local opts = { buffer = buf, silent = true }
  vim.keymap.set("n", "zo", function()
    M.dispatch("open")
  end, opts)
  vim.keymap.set("n", "zc", function()
    M.dispatch("close")
  end, opts)
  keeper_attach(buf) -- passive view keeper (no-op on non-pi content)
end

function M.setup(opts)
  opts = opts or {}
  -- pi may run directly as the terminal job (:term pi) or inside a shell
  -- opened there (:term, then `pi`). In the latter case the job is /bin/bash,
  -- so by default we attach to every terminal buffer; dispatch() no-ops
  -- unless the cursor sits on a pi-tidy marker line. Set { only_pi = true }
  -- to attach only when the job itself is pi.
  local only_pi = opts.only_pi == true
  vim.api.nvim_create_autocmd("TermOpen", {
    group = vim.api.nvim_create_augroup("pi-fold", { clear = true }),
    callback = function(args)
      vim.schedule(function()
        if only_pi then
          if job_is_pi(args.buf) then
            M.attach(args.buf, true)
          end
        else
          M.attach(args.buf, true)
        end
      end)
    end,
  })
  -- re-arm on :source/reload: attach to terminals that already exist (their
  -- old watchers were shut down at module load)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ok, is_term = pcall(function()
      return vim.b[b].terminal_job_id ~= nil
    end)
    if ok and is_term then
      M.attach(b, true)
    end
  end
end

return M
