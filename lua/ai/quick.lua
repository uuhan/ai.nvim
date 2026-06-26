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

-- A progress handle (persistent spinner via fidget, notification fallback).
local function make_progress(title, message)
  local quick = config.get().quick or {}
  return require("ai.progress").handle({
    title = title,
    message = message,
    group = quick.group,
    use_fidget = quick.use_fidget,
  })
end

local function event_notifier(task)
  local quick = config.get().quick or {}
  local max_notify_chars = tonumber(quick.max_notify_chars) or 600
  local progress = make_progress(quick.title or "ai.nvim", "AI: " .. short_text(task, 60))
  local last_status = nil

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
        progress.report(text)
      end
    elseif event.type == "tool_call" then
      progress.report("Tool: " .. (event.tool or "unknown"))
    elseif event.type == "tool_result" then
      progress.report(short_text(("Tool result: %s"):format(event.summary or event.tool or "done"), 120))
    elseif event.type == "assistant" then
      local content = trim(event.content)
      if content == "" then
        return
      end
      if #content <= max_notify_chars then
        notify(content, vim.log.levels.INFO, { annote = "reply" })
      else
        notify(("AI reply ready: %d chars"):format(#content), vim.log.levels.INFO, { annote = "reply" })
        popup.open("quick-reply", content, "markdown")
      end
    elseif event.type == "finish" then
      if event.status == "error" then
        progress.finish(
          "failed" .. (event.detail and event.detail ~= "" and (": " .. event.detail) or ""),
          vim.log.levels.ERROR
        )
      elseif event.status == "stopped" then
        progress.finish("stopped", vim.log.levels.WARN)
      else
        progress.finish("done" .. (task ~= "" and (": " .. short_text(task, 80)) or ""))
      end
    end
  end
end

local function busy()
  if chat.active then
    notify("AI quick is busy. Stop the active request with :AIChatStop first.", vim.log.levels.WARN, { annote = "busy" })
    return true
  end
  return false
end

function M.run(text, opts)
  opts = opts or {}
  text = trim(text)
  if text == "" then
    return
  end

  if busy() then
    return
  end

  chat.start({ system_prompt = opts.system_prompt })
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

-- A single-line input popup anchored at the cursor. Closes on submit (<CR>),
-- cancel (<Esc>), or focus loss, and starts in insert mode so it never strands
-- the user in normal mode like the default vim.ui.input float can.
local function float_input(opts, on_submit)
  local quick = config.get().quick or {}
  local prompt = trim(quick.prompt) ~= "" and trim(quick.prompt) or "AI:"
  local default = tostring(opts.default or "")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  if default ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default })
  end

  local width = math.max(30, math.min(80, math.floor(vim.o.columns * 0.5)))
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 1,
    border = "rounded",
    style = "minimal",
    title = " " .. prompt:gsub("%s+$", "") .. " ",
    title_pos = "left",
    zindex = 70,
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    -- fall back to the native prompt if the float cannot be created
    vim.ui.input({ prompt = quick.prompt or "AI: ", default = opts.default }, on_submit)
    return
  end
  vim.wo[win].wrap = false

  local done = false
  local function finish(value)
    if done then
      return
    end
    done = true
    if vim.fn.mode():match("^[iR]") then
      vim.cmd.stopinsert()
    end
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    on_submit(value)
  end

  vim.keymap.set({ "i", "n" }, "<CR>", function()
    finish(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
  end, { buffer = buf, nowait = true, silent = true })

  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    finish(nil)
  end, { buffer = buf, nowait = true, silent = true })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    once = true,
    callback = function()
      finish(nil)
    end,
  })

  -- enter insert at end of any prefilled text
  vim.cmd(default ~= "" and "startinsert!" or "startinsert")
end

function M.input(opts)
  opts = opts or {}

  if busy() then
    return
  end

  local initial = trim(opts.initial)
  if initial ~= "" then
    M.run(initial, opts)
    return
  end

  local quick = config.get().quick or {}
  local function handle(value)
    value = trim(value)
    if value == "" then
      return
    end
    M.run(value, opts)
  end

  if quick.input == "native" then
    vim.ui.input({
      prompt = quick.prompt or "AI: ",
      default = opts.default,
    }, handle)
  else
    float_input(opts, handle)
  end
end

return M
