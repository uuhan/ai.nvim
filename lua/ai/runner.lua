local config = require("ai.config")
local context = require("ai.context")

local M = {
  pending = nil,
}

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_code_fence(text)
  local body = trim(text or "")
  local first_line = body:match("^(.-)\n")
  if first_line and first_line:match("^```") and body:match("\n```%s*$") then
    body = body:gsub("^```[%w_+-]*\n", ""):gsub("\n```%s*$", "")
  end
  return trim(body)
end

local function first_command(text)
  local body = strip_code_fence(text)
  for line in body:gmatch("[^\n]+") do
    line = trim(line)
    if line ~= "" and not line:match("^#") then
      return line
    end
  end
  return body
end

local function is_blocked(command)
  if config.get().safety.allow_dangerous_commands then
    return false
  end

  for _, pattern in ipairs(config.get().safety.blocked_command_patterns or {}) do
    if command:match(pattern) then
      return true, pattern
    end
  end
  return false
end

function M.preview(command, opts)
  opts = opts or {}
  local cmd = first_command(command)
  if cmd == "" then
    return nil, "AI did not return a shell command."
  end

  M.pending = {
    command = cmd,
    cwd = opts.cwd or context.root(0),
    title = opts.title or "command",
  }

  return M.pending
end

function M.clear()
  M.pending = nil
end

function M.run(cb)
  local pending = M.pending
  if not pending then
    cb("No pending AI command.")
    return
  end

  if not vim.system then
    cb("ai.nvim requires Neovim with vim.system support.")
    return
  end

  local blocked, pattern = is_blocked(pending.command)
  if blocked then
    cb("Refusing to run command matching safety block: " .. pattern .. "\n\n" .. pending.command)
    return
  end

  local shell = vim.o.shell ~= "" and vim.o.shell or "sh"
  vim.system({ shell, "-lc", pending.command }, { cwd = pending.cwd, text = true }, function(obj)
    vim.schedule(function()
      local output = table.concat({
        "$ " .. pending.command,
        "",
        "# exit",
        tostring(obj.code),
        "",
        "# stdout",
        obj.stdout or "",
        "",
        "# stderr",
        obj.stderr or "",
      }, "\n")
      M.pending = nil
      cb(nil, output)
    end)
  end)
end

return M
