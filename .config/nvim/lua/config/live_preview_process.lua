local M = {}
local uv = vim.uv
local worker_channel, worker_port
local editor_channel, editor_socket
local sources = {}
local clients = {}
local idle_deadline
local timer, listener
local shutting_down = false

local function now()
  return uv.hrtime() / 1e9
end

local function grace(seconds)
  idle_deadline = now() + seconds
end

local function rpc(code, ...)
  if not editor_socket then
    return false
  end
  if not editor_channel then
    local ok, channel = pcall(vim.fn.sockconnect, "pipe", editor_socket, { rpc = true })
    if not ok or channel == 0 then
      editor_socket = nil
      return false
    end
    editor_channel = channel
  end
  local ok, result = pcall(vim.rpcrequest, editor_channel, "nvim_exec_lua", code, { ... })
  if not ok then
    pcall(vim.fn.chanclose, editor_channel)
    editor_channel, editor_socket = nil, nil
  end
  return ok, result
end

function M.read_source(path)
  local ok, content = rpc('return require("config.live_preview").read_source(...)', path)
  if ok and content ~= vim.NIL then
    return content
  end
  return require("livepreview.utils").read_file(path)
end

function M.update_source(path, line, checked, hash)
  local ok, result = rpc([[
    local result, err, code = require("config.live_preview").update_source(...)
    return { result = result, error = err, code = code }
  ]], path, line, checked, hash)
  if ok then
    return result.result, result.error, result.code
  end
  return require("config.live_preview").update_source(path, line, checked, hash)
end

function M.track_source(path, content)
  sources[path] = content
end

local function forget(client)
  if clients[client] then
    clients[client] = nil
    if not next(clients) then
      grace(5)
    end
  end
  if not client:is_closing() then
    client:close()
  end
end

local function broadcast(message)
  local body = vim.json.encode(message)
  local length = #body
  local header
  if length < 126 then
    header = string.char(0x81, length)
  elseif length < 65536 then
    header = string.char(0x81, 126, math.floor(length / 256), length % 256)
  else
    header = string.char(0x81, 127, 0, 0, 0, 0,
      math.floor(length / 16777216) % 256, math.floor(length / 65536) % 256,
      math.floor(length / 256) % 256, length % 256)
  end
  for client in pairs(clients) do
    if client:is_closing() then
      forget(client)
    else
      local ok = pcall(client.write, client, header .. body, function(err)
        if err then
          forget(client)
        end
      end)
      if not ok then
        forget(client)
      end
    end
  end
end

function M.register(socket)
  editor_socket = socket
  grace(60)
  return listener:getsockname().port
end

function M.prepare(path)
  if vim.env.LIVE_PREVIEW_WORKER == "1" then
    grace(60)
    return
  end
  vim.rpcnotify(worker_channel, "nvim_exec_lua", 'require("config.live_preview_process").prepare(...)', { path })
end

function M.scroll(path, cursor)
  if vim.env.LIVE_PREVIEW_WORKER == "1" then
    broadcast({ type = "scroll", filepath = path, cursor = cursor })
  elseif worker_channel then
    pcall(vim.rpcnotify, worker_channel, "nvim_exec_lua",
      'require("config.live_preview_process").scroll(...)', { path, cursor })
  end
end

function M.shutdown()
  if shutting_down then
    return
  end
  shutting_down = true
  if timer then
    timer:stop()
    timer:close()
  end
  for client in pairs(clients) do
    forget(client)
  end
  if listener and not listener:is_closing() then
    listener:close()
  end
  vim.schedule(function()
    vim.cmd("qa!")
  end)
end

function M.serve()
  require("livepreview.config").set({ sync_scroll = false })
  require("config.live_preview").setup_worker()
  local server = require("livepreview.server").Server:new("/")
  local handler = require("livepreview.server.handler")
  listener = server.server
  assert(listener:bind("127.0.0.1", 0))
  assert(listener:listen(128, function(err)
    if err then
      return
    end
    local client = uv.new_tcp()
    listener:accept(client)
    client:keepalive(true, 30)
    handler.client(client, function(read_err, request)
      if read_err or not request then
        forget(client)
        return
      end
      local info = handler.request(client, request)
      if info then
        if not info.handled then
          handler.serve_file(client, server:routes(info.path), info.if_none_match, info.accept)
        end
      elseif not client:is_closing() then
        clients[client] = true
        -- Browser sends only a close frame. Close immediately rather than waiting
        -- for TCP EOF while the browser waits for the WebSocket close handshake.
        client:read_start(function()
          forget(client)
        end)
      end
    end)
  end))
  grace(60)
  timer = uv.new_timer()
  timer:start(500, 500, vim.schedule_wrap(function()
    if shutting_down then
      return
    end
    if not next(clients) then
      if now() >= idle_deadline then
        M.shutdown()
      end
      return
    end
    for path, previous in pairs(sources) do
      local content = M.read_source(path)
      if content and content ~= previous then
        sources[path] = content
        broadcast({ type = "update", filepath = path, content = content })
      end
    end
  end))
end

function M.is_running()
  if not worker_channel then
    return false
  end
  local ok = pcall(vim.rpcrequest, worker_channel, "nvim_get_api_info")
  if not ok then
    worker_channel, worker_port = nil, nil
  end
  return ok
end

function M.start()
  if M.is_running() then
    return worker_port
  end
  local config_root = vim.fn.stdpath("config")
  local socket = vim.fn.tempname() .. ".preview.sock"
  if not editor_socket then
    editor_socket = vim.fn.serverstart(vim.fn.tempname() .. ".preview-editor.sock")
  end
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "--noplugin", "-i", "NONE",
    "-u", vim.fs.joinpath(config_root, "static", "livepreview", "worker.lua"), "--listen", socket }, {
    detach = true,
    env = {
      LIVE_PREVIEW_WORKER = "1",
      LIVE_PREVIEW_CONFIG = config_root,
      LIVE_PREVIEW_PLUGIN = require("livepreview.utils").get_plugin_path(),
    },
  })
  if job <= 0 then
    return nil, "Cannot launch the preview process"
  end
  local ready = vim.wait(5000, function()
    local ok, channel = pcall(vim.fn.sockconnect, "pipe", socket, { rpc = true })
    if ok and channel > 0 then
      worker_channel = channel
      return true
    end
  end, 50)
  if not ready then
    vim.fn.jobstop(job)
    return nil, "Preview process did not start within five seconds"
  end
  local ok, port = pcall(vim.rpcrequest, worker_channel, "nvim_exec_lua",
    'return require("config.live_preview_process").register(...)', { editor_socket })
  if not ok then
    vim.fn.jobstop(job)
    worker_channel = nil
    return nil, port
  end
  worker_port = port
  return port
end

function M.url(path)
  -- Keep the full filesystem path in the URL so ../ and nested links work
  -- using the browser's normal URL resolution, without traversing a link graph.
  local encoded = vim.uri_encode(path):gsub("%%2[Ff]", "/")
  return ("http://127.0.0.1:%d%s"):format(worker_port, encoded)
end

function M.stop()
  if worker_channel then
    pcall(vim.rpcnotify, worker_channel, "nvim_exec_lua",
      'require("config.live_preview_process").shutdown()', {})
    pcall(vim.fn.chanclose, worker_channel)
    worker_channel, worker_port = nil, nil
  end
end

return M
