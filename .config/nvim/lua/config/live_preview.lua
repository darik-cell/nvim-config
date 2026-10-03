local M = {}

local endpoint = "/__livepreview/task"
local asset_prefix = "/live-preview-config/"
local assets = {
  [asset_prefix .. "light.css"] = "light.css",
  [asset_prefix .. "task-list.js"] = "task-list.js",
}

local page_paths = {}
local page_tokens = {}
local installed = false

local function normalized_path(path)
  if not path or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function canonical_path(path)
  return path and (vim.uv.fs_realpath(path) or vim.fs.normalize(path)) or nil
end

local function new_token()
  local random = vim.uv.random(32)
  if random then
    return vim.fn.sha256(random)
  end

  return vim.fn.sha256(table.concat({
    tostring(vim.uv.hrtime()),
    tostring(vim.uv.os_getpid()),
    tostring({}),
  }, ":"))
end

local function task_marker(line)
  local prefix, marker, suffix = line:match("^(%s*[-+*]%s+)%[([ xX])%](.*)$")
  if not prefix then
    prefix, marker, suffix = line:match("^(%s*%d+[.)]%s+)%[([ xX])%](.*)$")
  end
  if not prefix or (suffix ~= "" and not suffix:match("^%s")) then
    return nil
  end

  return {
    marker = marker,
    marker_offset = #prefix + 1,
  }
end

local function toggled_line(line, checked)
  local task = task_marker(line)
  if not task then
    return nil, "The selected source line is no longer a Markdown task"
  end

  local replacement = checked and "x" or " "
  local marker_index = task.marker_offset + 1
  if task.marker == replacement or (checked and task.marker == "X") then
    return line, nil, task.marker_offset
  end

  return line:sub(1, marker_index - 1) .. replacement .. line:sub(marker_index + 1), nil, task.marker_offset
end

local update_file

local function find_loaded_buffer(path)
  local normalized_target = vim.fs.normalize(path)
  local target = canonical_path(path)
  local aliases = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fs.normalize(name) == normalized_target then
        return bufnr
      end
      if name ~= "" and canonical_path(name) == target then
        table.insert(aliases, bufnr)
      end
    end
  end

  if #aliases == 1 then
    return aliases[1]
  elseif #aliases > 1 then
    return nil, "Multiple loaded buffers point to this Markdown file"
  end
end

local function update_loaded_buffer(path, bufnr, line_number, checked, expected_hash)
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    return nil, "The Markdown buffer is read-only", 423
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, line_number, line_number + 1, false)
  local current = lines[1]
  if not current then
    return nil, "The task line no longer exists", 409
  end
  if vim.fn.sha256(current) ~= expected_hash then
    return nil, "The Markdown changed after this preview was rendered", 409
  end

  local replacement, err = toggled_line(current, checked)
  if not replacement then
    return nil, err, 422
  end

  local was_modified = vim.bo[bufnr].modified
  if not was_modified then
    local disk_result, disk_err, disk_code = update_file(path, line_number, checked, expected_hash)
    if not disk_result then
      return nil, disk_err, disk_code
    end
  end

  if replacement ~= current then
    vim.api.nvim_buf_set_lines(bufnr, line_number, line_number + 1, false, { replacement })
  end
  if not was_modified then
    vim.bo[bufnr].modified = false
  end

  return {
    checked = checked,
    saved = not was_modified,
    line = replacement,
    hash = vim.fn.sha256(replacement),
  }
end

local function raw_line_bounds(content, target_line)
  local current_line = 0
  local start_index = 1
  local index = 1
  local length = #content

  while current_line < target_line do
    if index > length then
      return nil
    end

    local byte = content:byte(index)
    if byte == 10 then
      current_line = current_line + 1
      start_index = index + 1
    elseif byte == 13 then
      current_line = current_line + 1
      if content:byte(index + 1) == 10 then
        index = index + 1
      end
      start_index = index + 1
    end
    index = index + 1
  end

  index = start_index
  while index <= length do
    local byte = content:byte(index)
    if byte == 10 or byte == 13 then
      break
    end
    index = index + 1
  end

  return start_index, index - 1
end

update_file = function(path, line_number, checked, expected_hash)
  local fd, open_err = vim.uv.fs_open(path, "r+", 438)
  if not fd then
    return nil, "Cannot open the Markdown file: " .. tostring(open_err), 500
  end

  local function close_file()
    if fd then
      pcall(vim.uv.fs_close, fd)
      fd = nil
    end
  end

  local stat, stat_err = vim.uv.fs_fstat(fd)
  if not stat then
    close_file()
    return nil, "Cannot inspect the Markdown file: " .. tostring(stat_err), 500
  end
  if stat.type ~= "file" then
    close_file()
    return nil, "The Markdown path is not a regular file", 422
  end

  local content, read_err = vim.uv.fs_read(fd, stat.size, 0)
  if not content then
    close_file()
    return nil, "Cannot read the Markdown file: " .. tostring(read_err), 500
  end

  local start_index, end_index = raw_line_bounds(content, line_number)
  if not start_index then
    close_file()
    return nil, "The task line no longer exists", 409
  end

  local current = content:sub(start_index, end_index)
  if vim.fn.sha256(current) ~= expected_hash then
    close_file()
    return nil, "The Markdown changed after this preview was rendered", 409
  end

  local replacement, err, marker_offset = toggled_line(current, checked)
  if not replacement then
    close_file()
    return nil, err, 422
  end

  if replacement ~= current then
    local latest, latest_err = vim.uv.fs_read(fd, #current, start_index - 1)
    if not latest then
      close_file()
      return nil, "Cannot re-read the Markdown file: " .. tostring(latest_err), 500
    end
    if latest ~= current then
      close_file()
      return nil, "The Markdown changed while the task was being updated", 409
    end

    local marker = checked and "x" or " "
    local file_offset = start_index - 1 + marker_offset
    local written, write_err = vim.uv.fs_write(fd, marker, file_offset)
    if written ~= 1 then
      close_file()
      return nil, "Cannot write the Markdown file: " .. tostring(write_err), 500
    end
    pcall(vim.uv.fs_fsync, fd)
  end

  close_file()
  return {
    checked = checked,
    saved = true,
    line = replacement,
    hash = vim.fn.sha256(replacement),
  }
end

function M.update_source(path, line_number, checked, expected_hash)
  local bufnr, buffer_err = find_loaded_buffer(path)
  if buffer_err then
    return nil, buffer_err, 409
  end
  if bufnr then
    return update_loaded_buffer(path, bufnr, line_number, checked, expected_hash)
  end

  return update_file(path, line_number, checked, expected_hash)
end

local function parse_headers(request)
  local headers = {}
  for line in request:gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end
  return headers
end

local function parse_query(target)
  local path, query = target:match("^([^?]+)%??(.*)$")
  local params = {}
  for pair in query:gmatch("[^&]+") do
    local name, value = pair:match("^([^=]+)=(.*)$")
    if name then
      params[name] = value
    end
  end
  return path, params
end

local function remove_client(server, client)
  for index = #server.connecting_clients, 1, -1 do
    if server.connecting_clients[index] == client then
      table.remove(server.connecting_clients, index)
      break
    end
  end
end

local function finish_client(server, client)
  remove_client(server, client)
  if client:is_closing() then
    return
  end

  local ok, shutdown = pcall(client.shutdown, client, function()
    if not client:is_closing() then
      client:close()
    end
  end)
  if (not ok or not shutdown) and not client:is_closing() then
    client:close()
  end
end

local function send_json(handler, server, client, status, payload)
  if client:is_closing() then
    remove_client(server, client)
    return
  end

  handler.send_http_response(client, status, "application/json; charset=UTF-8", vim.json.encode(payload), {
    ["Cache-Control"] = "no-store",
    ["X-Content-Type-Options"] = "nosniff",
  })
  finish_client(server, client)
end

local function handle_toggle(handler, server, client, token, params)
  local path = page_paths[token or ""]
  if not path then
    send_json(handler, server, client, "403 Forbidden", { ok = false, error = "Invalid preview token" })
    return
  end

  local line_number = tonumber(params.line)
  if not line_number or line_number < 0 or line_number > 10000000 or line_number ~= math.floor(line_number) then
    send_json(handler, server, client, "400 Bad Request", { ok = false, error = "Invalid source line" })
    return
  end

  local checked
  if params.checked == "1" then
    checked = true
  elseif params.checked == "0" then
    checked = false
  else
    send_json(handler, server, client, "400 Bad Request", { ok = false, error = "Invalid checkbox state" })
    return
  end

  local expected_hash = params.hash
  if not expected_hash or #expected_hash ~= 64 or not expected_hash:match("^%x+$") then
    send_json(handler, server, client, "400 Bad Request", { ok = false, error = "Invalid source hash" })
    return
  end

  local result, err, code = require("config.live_preview_process").update_source(
    path, line_number, checked, expected_hash:lower()
  )
  if not result then
    local statuses = {
      [409] = "409 Conflict",
      [422] = "422 Unprocessable Content",
      [423] = "423 Locked",
    }
    send_json(handler, server, client, statuses[code] or "500 Internal Server Error", {
      ok = false,
      error = err,
    })
    return
  end

  result.ok = true
  send_json(handler, server, client, "200 OK", result)
end

local function inject_preview_ui(html, token)
  if not token then
    return html
  end

  local body_open = '<div class="markdown-body">\n'
  local body_start = html:find(body_open, 1, true)
  if body_start then
    local body_end = body_start + #body_open - 1
    html = html:sub(1, body_start - 1) .. '<div class="markdown-body">' .. html:sub(body_end + 1)
  end

  local body_close = '            </div>\n            <script defer src="/live-preview.nvim/static/mermaid/main.js">'
  local close_start, close_end = html:find(body_close, 1, true)
  if close_start then
    local replacement = '</div>\n            <script defer src="/live-preview.nvim/static/mermaid/main.js">'
    html = html:sub(1, close_start - 1) .. replacement .. html:sub(close_end + 1)
  end

  local main_script = "<script defer src='/live-preview.nvim/static/markdown/main.js'></script>"
  local task_script = '<script defer src="' .. asset_prefix .. 'task-list.js"></script>'
  local start_index, end_index = html:find(main_script, 1, true)
  if start_index then
    html = html:sub(1, start_index - 1) .. task_script .. main_script .. html:sub(end_index + 1)
  end

  local head = table.concat({
    '<meta http-equiv="Cache-Control" content="no-store">',
    '<meta name="live-preview-token" content="' .. token .. '">',
    '<link rel="stylesheet" href="/live-preview.nvim/static/highlight/github.min.css">',
    '<link rel="stylesheet" href="' .. asset_prefix .. 'light.css">',
  }, "\n")
  local head_index = html:find("</head>", 1, true)
  if head_index then
    html = html:sub(1, head_index - 1) .. head .. "\n" .. html:sub(head_index)
  end

  return html
end

-- Called over RPC by the detached worker; keep unsaved editor content authoritative.
function M.read_source(path)
  local bufnr, err = find_loaded_buffer(path)
  if err then
    error(err)
  end
  if bufnr then
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end
  return vim.NIL
end

function M.setup_worker()
  local template = require("livepreview.template")
  local server = require("livepreview.server")
  local handler = require("livepreview.server.handler")
  local utils = require("livepreview.utils")
  local assets_root = vim.fs.joinpath(vim.env.LIVE_PREVIEW_CONFIG, "static", "livepreview")
  local original_routes = server.Server.routes
  server.Server.routes = function(self, path)
    if path == "/live-preview.nvim/static/ws-client.js" then
      return vim.fs.joinpath(assets_root, "ws-client.js")
    end
    local asset = assets[path]
    if asset then
      return vim.fs.joinpath(assets_root, asset)
    end
    return original_routes(self, path)
  end

  local original_request = handler.request
  handler.request = function(client, raw_request)
    local target = raw_request:match("^POST ([^%s]+) HTTP/%d%.%d")
    if target then
      local path, params = parse_query(target)
      if path == endpoint then
        local token = parse_headers(raw_request)["x-livepreview-token"]
        vim.schedule(function()
          local ok, err = xpcall(function()
            handle_toggle(handler, server, client, token, params)
          end, debug.traceback)
          if not ok then
            vim.notify("live-preview checkbox error: " .. err, vim.log.levels.ERROR)
            pcall(send_json, handler, server, client, "500 Internal Server Error", {
              ok = false, error = "Unexpected error while updating Markdown",
            })
          end
        end)
        -- The caller must distinguish asynchronous HTTP from WebSocket upgrades.
        return { handled = true }
      end
      handler.send_http_response(client, "405 Method Not Allowed", "text/plain", "Method not allowed")
      return { handled = true }
    end
    local result = original_request(client, raw_request)
    if result then
      -- Split before decoding: an encoded question mark belongs to the filename.
      local request_path = raw_request:match("^GET ([^%s?]+)") or "/"
      result.path = vim.uri_decode(request_path)
    end
    return result
  end

  local original_serve_file = handler.serve_file
  handler.serve_file = function(client, file_path, if_none_match, accept)
    if utils.supported_filetype(file_path) ~= "markdown" or not (accept or ""):match("text/html") then
      return original_serve_file(client, file_path, if_none_match, accept)
    end
    vim.schedule(function()
      local path = normalized_path(file_path)
      local process = require("config.live_preview_process")
      local content = process.read_source(path)
      if not content then
        handler.send_http_response(client, "404 Not Found", "text/plain", "Markdown file not found")
        return
      end
      local token = page_tokens[path] or new_token()
      page_tokens[path], page_paths[token] = token, path
      process.track_source(path, content)
      local body = inject_preview_ui(template.md2html(content), token)
      handler.send_http_response(client, "200 OK", "text/html; charset=UTF-8", body, {
        ["Cache-Control"] = "no-store",
      })
    end)
  end
end

function M.setup(opts)
  require("livepreview.config").set(opts or {})
  if installed then
    return
  end
  installed = true
  local process = require("config.live_preview_process")
  local livepreview = require("livepreview")
  local utils = require("livepreview.utils")
  local open_browser = utils.open_browser
  local pending_path
  livepreview.start = function(path)
    local port, err = process.start()
    if not port then
      vim.notify("live-preview: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    pending_path = normalized_path(path)
    process.prepare(pending_path)
    require("livepreview.config").config.port = port
    return true
  end
  utils.open_browser = function(url, browser)
    if pending_path then
      url = process.url(pending_path)
      pending_path = nil
    end
    return open_browser(url, browser)
  end
  livepreview.is_running = process.is_running
  livepreview.close = function()
    -- The plugin calls close from VimLeavePre; tabs own the detached worker.
    if vim.v.exiting == vim.NIL then
      process.stop()
    end
  end
  if require("livepreview.config").config.sync_scroll then
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
      group = vim.api.nvim_create_augroup("DetachedLivePreviewScroll", { clear = true }),
      callback = function()
        process.scroll(vim.api.nvim_buf_get_name(0), vim.api.nvim_win_get_cursor(0))
      end,
    })
  end
end

return M
