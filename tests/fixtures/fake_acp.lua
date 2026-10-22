-- Minimal ACP agent for the smoke suite: enough of the protocol to prove that
-- ai.nvim negotiates the session profile and answers `_yaah/tools/call`.
--
-- Run as `nvim -l tests/fixtures/fake_acp.lua`. It reports what it received
-- through one agent_message_chunk so the client side can assert on it.
-- `_yaah/complete` answers with a report too; pass `--no-complete` to run an
-- agent without that extension.
local TOOL_REQUEST_ID = 9001
local completes = not vim.tbl_contains(_G.arg or {}, "--no-complete")

local function send(message)
  io.stdout:write(vim.json.encode(message) .. "\n")
  io.stdout:flush()
end

local profile_tools = 0
local profile_instructions = ""
local prompt_id = nil
local held_completion = nil
local cancelled_completions = 0

--- A session carries the client's tool catalog whether it is new or restored.
local function take_profile(params)
  local profile = (params._meta or {})["yaah.dev/session-profile"]
  if profile then
    profile_tools = #(profile.tools or {})
    profile_instructions = profile.instructions or ""
  end
end

for line in io.lines() do
  local ok, message = pcall(vim.json.decode, line)
  if ok and type(message) == "table" then
    local method, id, params = message.method, message.id, message.params or {}
    if method == "initialize" then
      local meta = (params.clientCapabilities or {})._meta or {}
      send({
        jsonrpc = "2.0",
        id = id,
        result = {
          protocolVersion = 1,
          agentInfo = { name = "fake-acp", version = "0" },
          agentCapabilities = {
            loadSession = true,
            profile = meta["yaah.dev/session-profile"] == true,
            _meta = completes and { ["yaah.dev/complete"] = { version = 1 } } or nil,
          },
        },
      })
    elseif method == "session/new" then
      take_profile(params)
      send({ jsonrpc = "2.0", id = id, result = { sessionId = "fake-session" } })
    elseif method == "session/load" then
      -- Only the one session is ours; anything else is gone, which is what a
      -- restart looks like to a client holding a stale id.
      if params.sessionId == "fake-session" then
        take_profile(params)
        -- A real agent replays the stored conversation before it answers.
        send({
          jsonrpc = "2.0",
          method = "session/update",
          params = {
            sessionId = "fake-session",
            update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "replayed" } },
          },
        })
        send({ jsonrpc = "2.0", id = id, result = vim.empty_dict() })
      else
        send({ jsonrpc = "2.0", id = id, error = { code = -32602, message = "unknown session" } })
      end
    elseif method == "session/prompt" then
      prompt_id = id
      send({
        jsonrpc = "2.0",
        id = TOOL_REQUEST_ID,
        method = "_yaah/tools/call",
        params = {
          sessionId = "fake-session",
          toolCallId = "call-1",
          name = "nvim_editor_state",
          arguments = vim.empty_dict(),
        },
      })
    elseif method == "session/cancel" then
      if prompt_id then
        send({ jsonrpc = "2.0", id = prompt_id, result = { stopReason = "cancelled" } })
        prompt_id = nil
      end
    elseif method == "_yaah/complete" and completes then
      local roles, last = {}, ""
      for _, turn in ipairs(params.messages or {}) do
        table.insert(roles, turn.role)
        last = turn.content
      end
      if last == "wait for cancel" then
        held_completion = { id = id, requestId = params.requestId }
      else
        local report = table.concat({
          "roles=" .. table.concat(roles, ","),
          "model=" .. tostring(params.model),
          "thinking=" .. tostring(params.thinking),
          "cancelled=" .. cancelled_completions,
        }, " ")
        -- `no stream` stands for an agent configured not to stream.
        if last ~= "no stream" then
          local half = math.floor(#report / 2)
          for _, chunk in ipairs({ report:sub(1, half), report:sub(half + 1) }) do
            send({
              jsonrpc = "2.0",
              method = "_yaah/complete/update",
              params = {
                requestId = params.requestId,
                update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = chunk } },
              },
            })
          end
        end
        send({ jsonrpc = "2.0", id = id, result = { text = report, stopReason = "end_turn", usage = vim.NIL } })
      end
    elseif method == "_yaah/complete/cancel" and id == nil then
      if held_completion and held_completion.requestId == params.requestId then
        cancelled_completions = cancelled_completions + 1
        send({ jsonrpc = "2.0", id = held_completion.id, result = { text = "", stopReason = "cancelled" } })
        held_completion = nil
      end
    elseif method == "session/close" then
      send({ jsonrpc = "2.0", id = id, result = vim.empty_dict() })
    elseif message.id == TOOL_REQUEST_ID then
      local result = message.result or {}
      local output = type(result.output) == "table" and result.output or {}
      local report = table.concat({
        "tools=" .. profile_tools,
        "instructions=" .. (profile_instructions ~= "" and "yes" or "no"),
        "isError=" .. tostring(result.isError == true),
        "cwd=" .. tostring(output.cwd ~= nil),
      }, " ")
      send({
        jsonrpc = "2.0",
        method = "session/update",
        params = {
          sessionId = "fake-session",
          update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = report } },
        },
      })
      if prompt_id then
        send({ jsonrpc = "2.0", id = prompt_id, result = { stopReason = "end_turn" } })
        prompt_id = nil
      end
    elseif id ~= nil and method ~= nil then
      send({ jsonrpc = "2.0", id = id, error = { code = -32601, message = "unsupported: " .. method } })
    end
  end
end
