local chat = require("ai.chat")
local config = require("ai.config")
local popup = require("ai.popup")

local M = {}

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function short_text(text, max_chars)
  local compact = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  max_chars = tonumber(max_chars) or 120
  if #compact > max_chars then
    return compact:sub(1, max_chars) .. "..."
  end
  return compact
end

local function notify(message, level, opts)
  opts = opts or {}
  local quick = config.get().quick or {}
  local notify_opts = {
    title = quick.title or "ai.nvim",
    group = quick.group or "ai.nvim.quick",
    key = opts.key,
    annote = opts.annote,
    ttl = opts.ttl,
    skip_history = opts.skip_history,
  }

  if quick.use_fidget ~= false then
    local ok, fidget = pcall(require, "fidget")
    if ok and type(fidget.notify) == "function" then
      fidget.notify(message, level or vim.log.levels.INFO, notify_opts)
      return
    end
  end

  vim.notify(message, level or vim.log.levels.INFO, notify_opts)
end

local function event_notifier(task)
  local uv = vim.uv or vim.loop
  local id = ("ai.nvim.quick.%d"):format(uv.hrtime())
  local last_status = nil
  local quick = config.get().quick or {}
  local max_notify_chars = tonumber(quick.max_notify_chars) or 600

  return function(event)
    if type(event) ~= "table" then
      return
    end

    if event.type == "status" then
      local text = "AI " .. (event.status or "working")
      if event.detail and event.detail ~= "" then
        text = text .. ": " .. event.detail
      end
      if text ~= last_status then
        last_status = text
        notify(text, vim.log.levels.INFO, { key = id .. ".status", annote = "quick", skip_history = true })
      end
    elseif event.type == "tool_call" then
      notify("Tool call: " .. (event.tool or "unknown"), vim.log.levels.INFO, {
        key = id .. ".tool",
        annote = "tool",
        skip_history = true,
      })
    elseif event.type == "tool_result" then
      local level = event.error and vim.log.levels.ERROR or vim.log.levels.INFO
      notify(short_text(("Tool result: %s"):format(event.summary or event.tool or "done"), 180), level, {
        key = id .. ".tool",
        annote = event.error and "error" or "tool",
        skip_history = true,
      })
    elseif event.type == "assistant" then
      local content = trim(event.content)
      if content == "" then
        return
      end
      if #content <= max_notify_chars then
        notify(content, vim.log.levels.INFO, { key = id .. ".reply", annote = "reply" })
      else
        notify(("AI reply ready: %d chars"):format(#content), vim.log.levels.INFO, {
          key = id .. ".reply",
          annote = "reply",
        })
        popup.open("quick-reply", content, "markdown")
      end
    elseif event.type == "finish" then
      if event.status == "error" then
        notify("AI quick failed" .. (event.detail and event.detail ~= "" and (": " .. event.detail) or ""), vim.log.levels.ERROR, {
          key = id .. ".status",
          annote = "error",
        })
      elseif event.status == "stopped" then
        notify("AI quick stopped", vim.log.levels.WARN, { key = id .. ".status", annote = "stopped" })
      else
        notify("AI quick done" .. (task ~= "" and (": " .. short_text(task, 80)) or ""), vim.log.levels.INFO, {
          key = id .. ".status",
          annote = "done",
        })
      end
    end
  end
end

function M.run(text, opts)
  opts = opts or {}
  text = trim(text)
  if text == "" then
    return
  end

  if chat.active then
    notify("AI quick is busy. Stop the active request with :AIChatStop first.", vim.log.levels.WARN, { annote = "busy" })
    return
  end

  chat.start({ system_prompt = opts.system_prompt })
  notify("AI quick: " .. short_text(text, 120), vim.log.levels.INFO, { annote = "quick", skip_history = true })
  local quick = config.get().quick or {}
  local instruction = trim(quick.instruction)
  local message = text
  if instruction ~= "" then
    message = table.concat({
      instruction,
      "",
      "User task:",
      text,
    }, "\n")
  end
  chat.send(message, {
    on_event = event_notifier(text),
    source = "quick",
  })
end

function M.input(opts)
  opts = opts or {}
  chat.start({ system_prompt = opts.system_prompt })

  local initial = trim(opts.initial)
  if initial ~= "" then
    M.run(initial, opts)
    return
  end

  local quick = config.get().quick or {}
  vim.ui.input({
    prompt = quick.prompt or "AI: ",
    default = opts.default,
  }, function(value)
    value = trim(value)
    if value == "" then
      return
    end
    M.run(value, opts)
  end)
end

return M
