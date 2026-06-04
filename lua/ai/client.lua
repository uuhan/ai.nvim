local config = require("ai.config")

local M = {}

local function json_encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  return vim.fn.json_encode(value)
end

local function json_decode(value)
  if vim.json and vim.json.decode then
    return vim.json.decode(value)
  end
  return vim.fn.json_decode(value)
end

local function trim_slashes(value)
  return (value:gsub("/+$", ""))
end

local function text_from_content(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return ""
  end

  local chunks = {}
  for _, part in ipairs(content) do
    if type(part) == "string" then
      table.insert(chunks, part)
    elseif type(part) == "table" then
      if type(part.text) == "string" then
        table.insert(chunks, part.text)
      elseif type(part.content) == "string" then
        table.insert(chunks, part.content)
      end
    end
  end
  return table.concat(chunks, "")
end

local function parse_chat_response(stdout)
  local ok, decoded = pcall(json_decode, stdout)
  if not ok then
    return nil, "Provider returned invalid JSON"
  end

  local choice = decoded.choices and decoded.choices[1]
  local message = choice and choice.message
  local content = message and message.content
  local text = text_from_content(content)
  if text == "" and not (message and message.tool_calls) then
    local finish_reason = choice and choice.finish_reason or "unknown"
    return nil, "Provider response did not include choices[1].message.content; finish_reason=" .. finish_reason
  end

  return text, nil, decoded, message
end

local function provider_url(provider)
  return trim_slashes(provider.base_url) .. provider.endpoint
end

local function supports_thinking(provider)
  if provider.thinking_supported ~= nil then
    return not not provider.thinking_supported
  end
  return type(provider.base_url) == "string" and provider.base_url:lower():find("deepseek", 1, true) ~= nil
end

local function thinking_body(value)
  if type(value) == "table" then
    return value
  end
  if value == true then
    return { type = "enabled" }
  end
  if value == false then
    return { type = "disabled" }
  end
  return nil
end

local function api_key(provider)
  if provider.api_key ~= nil then
    return provider.api_key
  end
  if provider.api_key_env and provider.api_key_env ~= "" then
    return vim.env[provider.api_key_env]
  end
  return nil
end

local function provider_headers(provider, key)
  local headers = {
    ["Content-Type"] = "application/json",
  }

  if key ~= "" then
    headers.Authorization = "Bearer " .. key
  end

  for name, value in pairs(provider.extra_headers or {}) do
    headers[name] = value
  end

  return headers
end

local function resolve_transport(provider)
  if type(provider.transport) == "table" then
    return provider.transport, nil
  end

  if type(provider.request) == "function" or type(provider.stream_request) == "function" then
    return {
      request = provider.request,
      stream = provider.stream_request,
    }, nil
  end

  local name = provider.transport or "curl"
  if name == "curl" then
    return require("ai.transports.curl"), nil
  end

  return nil, "Unknown AI provider transport: " .. tostring(name)
end

local function make_request(messages, opts, stream)
  opts = opts or {}
  local provider = vim.tbl_deep_extend("force", config.get().provider, opts.provider or {})
  local key = api_key(provider)

  if key == nil then
    local key_hint = provider.api_key_env and provider.api_key_env ~= "" and ("$" .. provider.api_key_env) or "provider.api_key"
    return nil, nil, nil, nil, "Missing API key. Set " .. key_hint .. " or configure provider.api_key."
  end

  local body = {
    model = opts.model or provider.model,
    messages = messages,
    stream = stream,
  }

  local temperature = opts.temperature
  if temperature == nil then
    temperature = provider.temperature
  end
  if temperature ~= nil and temperature ~= false then
    body.temperature = temperature
  end

  if opts.max_tokens or provider.max_tokens then
    body.max_tokens = opts.max_tokens or provider.max_tokens
  end

  if opts.tools then
    body.tools = opts.tools
  end

  if opts.tool_choice then
    body.tool_choice = opts.tool_choice
  end

  local thinking = opts.thinking
  if thinking == nil then
    thinking = provider.thinking
  end
  local thinking_config = thinking_body(thinking)
  if thinking_config and supports_thinking(provider) then
    body.thinking = thinking_config
  end

  local reasoning_effort = opts.reasoning_effort or provider.reasoning_effort
  if reasoning_effort and thinking_config and thinking_config.type == "enabled" then
    body.reasoning_effort = reasoning_effort
  end

  local transport, transport_err = resolve_transport(provider)
  if transport_err then
    return nil, nil, nil, nil, transport_err
  end

  return provider, body, {
    url = provider_url(provider),
    headers = provider_headers(provider, key or ""),
    body = body,
    body_json = json_encode(body),
    timeout_ms = provider.timeout_ms,
    curl = provider.curl,
    stream = stream,
    provider = provider,
  }, transport, nil
end

function M.chat(messages, opts, cb)
  local _, _, req, transport, err = make_request(messages, opts, false)
  if err then
    vim.schedule(function()
      cb(err)
    end)
    return
  end

  if type(transport.request) ~= "function" then
    vim.schedule(function()
      cb("AI provider transport does not support non-streaming requests.")
    end)
    return
  end

  return transport.request(req, function(request_err, stdout)
    if request_err then
      cb(request_err)
      return
    end

    local text, parse_err, raw, message = parse_chat_response(stdout or "")
    if parse_err then
      cb(parse_err)
      return
    end

    cb(nil, text, raw, message)
  end)
end

local function parse_stream_line(line, callbacks)
  if not line:match("^data:%s*") then
    return
  end

  local payload = line:gsub("^data:%s*", "")
  if payload == "[DONE]" then
    return
  end

  local ok, decoded = pcall(json_decode, payload)
  if not ok then
    return
  end

  if decoded.error then
    if callbacks.on_error then
      callbacks.on_error(decoded.error.message or vim.inspect(decoded.error))
    end
    return
  end

  local choice = decoded.choices and decoded.choices[1]
  local delta = choice and choice.delta
  local text = delta and text_from_content(delta.content)
  if text and text ~= "" and callbacks.on_delta then
    callbacks.on_delta(text)
  end

  local reasoning = delta and delta.reasoning_content
  if type(reasoning) == "string" and reasoning ~= "" and callbacks.on_reasoning_delta then
    callbacks.on_reasoning_delta(reasoning)
  end

  if delta and type(delta.tool_calls) == "table" and callbacks.on_tool_call_delta then
    callbacks.on_tool_call_delta(delta.tool_calls)
  end

  if choice and choice.finish_reason and callbacks.on_finish then
    callbacks.on_finish(choice.finish_reason)
  end
end

function M.chat_stream(messages, opts, callbacks)
  callbacks = callbacks or {}
  local _, _, req, transport, err = make_request(messages, opts, true)
  if err then
    vim.schedule(function()
      if callbacks.on_error then
        callbacks.on_error(err)
      end
    end)
    return
  end

  if type(transport.stream) ~= "function" then
    vim.schedule(function()
      if callbacks.on_error then
        callbacks.on_error("AI provider transport does not support streaming requests.")
      end
    end)
    return
  end

  local buffer = ""

  local function feed(chunk)
    buffer = buffer .. chunk
    while true do
      local index = buffer:find("\n", 1, true)
      if not index then
        break
      end
      local line = buffer:sub(1, index - 1):gsub("\r$", "")
      buffer = buffer:sub(index + 1)
      parse_stream_line(line, callbacks)
    end
  end

  return transport.stream(req, {
    on_chunk = feed,
    on_error = callbacks.on_error,
    on_done = function()
      if buffer ~= "" then
        parse_stream_line(buffer:gsub("\r$", ""), callbacks)
        buffer = ""
      end
      if callbacks.on_done then
        callbacks.on_done()
      end
    end,
  })
end

return M
