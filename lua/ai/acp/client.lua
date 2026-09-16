local config = require("ai.config")
local rpc = require("ai.acp.rpc")

local M = {}

function M.new(opts)
  opts = opts or {}
  local acp = vim.tbl_deep_extend("force", config.get().acp or {}, opts)
  local self = { ready = false, session_id = nil, capabilities = nil }
  local function emit(name, ...) if opts[name] then opts[name](...) end end

  self.rpc = rpc.new({
    command = acp.command,
    args = acp.args,
    cwd = acp.cwd,
    on_stderr = function(text) emit("on_stderr", text) end,
    on_error = function(err) emit("on_error", err) end,
    on_notification = function(method, params)
      if method == "session/update" then emit("on_update", params)
      else emit("on_notification", method, params) end
    end,
    on_exit = function(code, signal)
      self.ready = false
      self.session_id = nil
      emit("on_exit", code, signal)
    end,
  })

  function self.start(callback)
    local ok, err = self.rpc.start()
    if not ok then
      emit("on_error", err)
      if callback then callback(err) end
      return nil
    end
    self.rpc.request("initialize", {
      protocolVersion = tonumber(acp.protocol_version) or 1,
      clientCapabilities = acp.client_capabilities,
      clientInfo = { name = "ai.nvim", version = acp.client_version or "0.1.0" },
    }, function(request_err, result)
      if request_err then
        emit("on_error", request_err)
        if callback then callback(request_err) end
        return
      end
      if not result or result.protocolVersion ~= 1 then
        local message = "Unsupported ACP protocol version: " .. tostring(result and result.protocolVersion)
        emit("on_error", message)
        if callback then callback(message) end
        return
      end
      self.ready = true
      self.capabilities = result.agentCapabilities
      emit("on_initialized", result)
      if callback then callback(nil, result) end
    end)
    return true
  end

  function self.new_session(params, callback)
    params = vim.tbl_extend("force", { cwd = acp.cwd or vim.fn.getcwd(), mcpServers = {} }, params or {})
    return self.rpc.request("session/new", params, function(err, result)
      if not err and result then self.session_id = result.sessionId end
      if callback then callback(err, result) end
    end)
  end

  function self.prompt(content, callback)
    if not self.session_id then
      local err = "ACP session has not been created"
      emit("on_error", err)
      if callback then callback(err) end
      return nil
    end
    local prompt = type(content) == "string" and { { type = "text", text = content } } or content
    return self.rpc.request("session/prompt", { sessionId = self.session_id, prompt = prompt }, callback)
  end

  function self.cancel(callback)
    if not self.session_id then return nil, "ACP session has not been created" end
    return self.rpc.request("session/cancel", { sessionId = self.session_id }, callback)
  end

  function self.close(callback)
    local done = function(err, result)
      self.rpc.stop()
      self.ready = false
      self.session_id = nil
      if callback then callback(err, result) end
    end
    if self.session_id then
      return self.rpc.request("session/close", { sessionId = self.session_id }, done)
    end
    done(nil)
  end

  return self
end

return M
