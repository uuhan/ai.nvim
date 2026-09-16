-- Minimal ACP agent for the smoke suite: enough of the protocol to prove that
-- ai.nvim negotiates the session profile and answers `_yaah/tools/call`.
--
-- Run as `nvim -l tests/fixtures/fake_acp.lua`. It reports what it received
-- through one agent_message_chunk so the client side can assert on it.
local TOOL_REQUEST_ID = 9001

local function send(message)
  io.stdout:write(vim.json.encode(message) .. "\n")
  io.stdout:flush()
end

local profile_tools = 0
local profile_instructions = ""
local prompt_id = nil

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
          agentCapabilities = { profile = meta["yaah.dev/session-profile"] == true },
        },
      })
    elseif method == "session/new" then
      local profile = (params._meta or {})["yaah.dev/session-profile"]
      if profile then
        profile_tools = #(profile.tools or {})
        profile_instructions = profile.instructions or ""
      end
      send({ jsonrpc = "2.0", id = id, result = { sessionId = "fake-session" } })
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
