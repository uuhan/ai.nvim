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
  if text == "" then
    return nil, "Provider response did not include choices[1].message.content"
  end

  return text, nil, decoded
end

local function provider_url(provider)
  return trim_slashes(provider.base_url) .. provider.endpoint
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

function M.chat(messages, opts, cb)
  opts = opts or {}
  local provider = vim.tbl_deep_extend("force", config.get().provider, opts.provider or {})
  local key = api_key(provider)

  if key == nil then
    vim.schedule(function()
      local key_hint = provider.api_key_env and provider.api_key_env ~= "" and ("$" .. provider.api_key_env) or "provider.api_key"
      cb("Missing API key. Set " .. key_hint .. " or configure provider.api_key.")
    end)
    return
  end

  if not vim.system then
    vim.schedule(function()
      cb("ai.nvim requires Neovim with vim.system support.")
    end)
    return
  end

  local body = {
    model = opts.model or provider.model,
    messages = messages,
    stream = false,
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
  }

  if key ~= "" then
    table.insert(args, "-H")
    table.insert(args, "Authorization: Bearer " .. key)
  end

  for name, value in pairs(provider.extra_headers or {}) do
    table.insert(args, "-H")
    table.insert(args, name .. ": " .. value)
  end

  vim.system(args, { text = true, stdin = json_encode(body) }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        local stderr = obj.stderr or ""
        local stdout = obj.stdout or ""
        cb(("Provider request failed (%s):\n%s%s"):format(obj.code, stderr, stdout))
        return
      end

      local text, err, raw = parse_chat_response(obj.stdout or "")
      if err then
        cb(err)
        return
      end

      cb(nil, text, raw)
    end)
  end)
end

return M
