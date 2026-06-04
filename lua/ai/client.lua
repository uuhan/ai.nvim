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

local function make_request(messages, opts, stream)
  opts = opts or {}
  local provider = vim.tbl_deep_extend("force", config.get().provider, opts.provider or {})
  local key = api_key(provider)

  if key == nil then
    local key_hint = provider.api_key_env and provider.api_key_env ~= "" and ("$" .. provider.api_key_env) or "provider.api_key"
    return nil, nil, nil, "Missing API key. Set " .. key_hint .. " or configure provider.api_key."
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

  local args = {
    provider.curl,
    "-sS",
    "--fail-with-body",
    "--max-time",
    tostring(math.max(1, math.floor((provider.timeout_ms or 60000) / 1000))),
    "-X",
    "POST",
    provider_url(provider),
    "-H",
    "Content-Type: application/json",
    "--data-binary",
    "@-",
  }

  if stream then
    table.insert(args, 2, "-N")
  end

  if key ~= "" then
    table.insert(args, "-H")
    table.insert(args, "Authorization: Bearer " .. key)
  end

  for name, value in pairs(provider.extra_headers or {}) do
    table.insert(args, "-H")
    table.insert(args, name .. ": " .. value)
  end

  return provider, body, args, nil
end

function M.chat(messages, opts, cb)
  if not vim.system then
    vim.schedule(function()
      cb("ai.nvim requires Neovim with vim.system support.")
    end)
    return
  end

  local _, body, args, err = make_request(messages, opts, false)
  if err then
    vim.schedule(function()
      cb(err)
    end)
    return
  end

  local job = vim.system(args, { text = true, stdin = json_encode(body) }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        local stderr = obj.stderr or ""
        local stdout = obj.stdout or ""
        cb(("Provider request failed (%s):\n%s%s"):format(obj.code, stderr, stdout))
        return
      end

      local text, err, raw, message = parse_chat_response(obj.stdout or "")
      if err then
        cb(err)
        return
      end

      cb(nil, text, raw, message)
    end)
  end)
  return job
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
  local _, body, args, err = make_request(messages, opts, true)
  if err then
    vim.schedule(function()
      if callbacks.on_error then
        callbacks.on_error(err)
      end
    end)
    return
  end

  local buffer = ""
  local stderr = {}

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

  local job = vim.fn.jobstart(args, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if data and #data > 0 then
        vim.schedule(function()
          feed(table.concat(data, "\n"))
        end)
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        table.insert(stderr, table.concat(data, "\n"))
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if buffer ~= "" then
          parse_stream_line(buffer:gsub("\r$", ""), callbacks)
          buffer = ""
        end
        if code ~= 0 then
          if callbacks.on_error then
            callbacks.on_error(("Provider stream failed (%s):\n%s"):format(code, table.concat(stderr, "\n")))
          end
          return
        end
        if callbacks.on_done then
          callbacks.on_done()
        end
      end)
    end,
  })

  if job <= 0 then
    vim.schedule(function()
      if callbacks.on_error then
        callbacks.on_error("Failed to start curl stream.")
      end
    end)
    return
  end

  vim.fn.chansend(job, json_encode(body))
  vim.fn.chanclose(job, "stdin")
  return {
    kill = function()
      pcall(vim.fn.jobstop, job)
    end,
  }
end

return M
