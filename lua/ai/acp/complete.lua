--- Stateless completions over the ACP backend (`_yaah/complete`).
---
--- One-shot commands and their follow-ups already send the whole conversation
--- with every request, so they need no ACP session: the agent answers the
--- messages and keeps nothing. Its process is started on first use and kept for
--- later requests. It is separate from the chat's agent, whose process goes away
--- whenever the chat is reset, so a reset never cuts off a running command.
---
--- An agent that does not advertise the extension leaves these requests on the
--- HTTP provider; so do requests the extension cannot express (tools, or
--- messages that are not plain text).
local config = require("ai.config")
local rpc = require("ai.acp.rpc")

local M = {}

local EXTENSION = "yaah.dev/complete"
local ROLES = { system = true, user = true, assistant = true }

local state = {
  rpc = nil,
  ready = false,
  supported = false,
  waiting = nil,
  streams = {},
  counter = 0,
}

local function settle(err)
  local waiting = state.waiting or {}
  state.waiting = nil
  for _, callback in ipairs(waiting) do
    callback(err)
  end
end

local function on_notification(method, params)
  if method ~= "_yaah/complete/update" or type(params) ~= "table" then return end
  local stream = state.streams[params.requestId]
  local update = params.update or {}
  local text = type(update.content) == "table" and update.content.text or nil
  if not stream or type(text) ~= "string" or text == "" then return end
  if update.sessionUpdate == "agent_message_chunk" then
    stream.on_text(text)
  elseif update.sessionUpdate == "agent_thought_chunk" and stream.on_reasoning then
    stream.on_reasoning(text)
  end
end

--- The running agent, or a new one built from the current configuration.
local function agent()
  if state.rpc then return state.rpc end
  local acp = config.get().acp or {}
  local client
  client = rpc.new({
    command = acp.command,
    args = acp.args,
    cwd = acp.cwd,
    on_notification = on_notification,
    on_request = function(id)
      client.respond(id, nil, { code = -32601, message = "ai.nvim completions take no client callbacks" })
    end,
    on_exit = function()
      if state.rpc ~= client then return end
      -- Pending requests have already failed; the next one starts a new agent.
      state.rpc = nil
      state.ready = false
      state.streams = {}
      settle("ACP agent exited before it was ready")
    end,
  })
  state.rpc = client
  return client
end

--- Start the agent and learn whether it serves completions. An agent that
--- fails to start or to initialize is dropped, so the next request retries
--- from the current configuration.
local function ensure(callback)
  if state.ready then
    callback(nil)
    return
  end
  if state.waiting then
    table.insert(state.waiting, callback)
    return
  end
  state.waiting = { callback }
  local client = agent()
  local function fail(err)
    if state.rpc == client then state.rpc = nil end
    client.stop()
    settle(err)
  end
  local ok, err = client.start()
  if not ok then
    fail(err)
    return
  end
  local acp = config.get().acp or {}
  client.request("initialize", {
    protocolVersion = tonumber(acp.protocol_version) or 1,
    clientCapabilities = vim.empty_dict(),
    clientInfo = { name = "ai.nvim", version = acp.client_version or "0.1.0" },
  }, function(request_err, result)
    if request_err then
      fail(request_err)
      return
    end
    if not result or result.protocolVersion ~= 1 then
      fail("Unsupported ACP protocol version: " .. tostring(result and result.protocolVersion))
      return
    end
    local meta = (result.agentCapabilities or {})._meta or {}
    state.supported = meta[EXTENSION] ~= nil
    state.ready = true
    settle(nil)
  end)
end

--- The messages as plain text turns, or nil when any of them is not one.
local function conversation(messages)
  local turns = {}
  for _, message in ipairs(messages or {}) do
    if not ROLES[message.role] or type(message.content) ~= "string" then return nil end
    table.insert(turns, { role = message.role, content = message.content })
  end
  return turns
end

--- Whether this request goes to the agent rather than the HTTP provider.
function M.handles(messages, opts)
  return config.get().backend == "acp" and not (opts and opts.tools) and conversation(messages) ~= nil
end

local finish_reasons = { end_turn = "stop", max_tokens = "length", refusal = "content_filter" }

--- Run one completion. `handlers.fallback()` sends the request over HTTP when
--- the agent lacks the extension and returns that request's handle;
--- `handlers.on_text` / `on_reasoning` receive streamed chunks;
--- `handlers.on_result(err, result)` settles it. A killed request reports
--- nothing more: its caller has already moved on.
function M.request(messages, handlers)
  local handle = { killed = false }
  local id

  function handle.kill()
    if handle.killed then return end
    handle.killed = true
    if handle.inner and type(handle.inner.kill) == "function" then
      pcall(function() handle.inner:kill(15) end)
    elseif id and state.rpc then
      state.streams[id] = nil
      state.rpc.notify("_yaah/complete/cancel", { requestId = id })
    end
  end

  ensure(function(err)
    if handle.killed then return end
    if err then
      handlers.on_result(err)
      return
    end
    if not state.supported then
      handle.inner = handlers.fallback()
      return
    end
    local acp = config.get().acp or {}
    state.counter = state.counter + 1
    id = ("ai-nvim-%d"):format(state.counter)
    state.streams[id] = { on_text = handlers.on_text, on_reasoning = handlers.on_reasoning }
    state.rpc.request("_yaah/complete", {
      requestId = id,
      messages = conversation(messages),
      model = acp.model,
      thinking = acp.thinking,
    }, function(request_err, result)
      state.streams[id] = nil
      if handle.killed then return end
      if request_err then
        handlers.on_result(request_err)
      elseif type(result) ~= "table" or type(result.text) ~= "string" then
        handlers.on_result("ACP completion returned no text")
      elseif result.stopReason == "cancelled" then
        handlers.on_result("ACP completion was cancelled")
      else
        result.finish_reason = finish_reasons[result.stopReason] or result.stopReason
        handlers.on_result(nil, result)
      end
    end)
  end)

  return handle
end

--- Stop the agent; the next completion starts a new one.
function M.stop()
  local client = state.rpc
  state.rpc = nil
  if client then client.stop() end
  state.ready = false
  state.supported = false
  state.streams = {}
end

return M
