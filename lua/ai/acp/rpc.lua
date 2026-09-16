local M = {}

local function encode(value)
  if vim.json and vim.json.encode then return vim.json.encode(value) end
  return vim.fn.json_encode(value)
end

local function decode(value)
  if vim.json and vim.json.decode then return vim.json.decode(value) end
  return vim.fn.json_decode(value)
end

local function schedule(fn, ...)
  local args = { ... }
  vim.schedule(function() fn(unpack(args)) end)
end

function M.new(opts)
  opts = opts or {}
  local self = { job = nil, next_id = 0, pending = {}, buffer = "" }

  local function fail_pending(message)
    local pending = self.pending
    self.pending = {}
    for _, item in pairs(pending) do
      if item.callback then schedule(item.callback, message) end
    end
  end

  local function dispatch(line)
    if line == "" then return end
    local ok, message = pcall(decode, line)
    if not ok or type(message) ~= "table" then
      if opts.on_error then schedule(opts.on_error, "ACP returned invalid JSON: " .. line) end
      return
    end
    if message.id ~= nil then
      local item = self.pending[tostring(message.id)]
      if item then
        self.pending[tostring(message.id)] = nil
        if item.callback then
          if message.error then
            schedule(item.callback, message.error.message or vim.inspect(message.error))
          else
            schedule(item.callback, nil, message.result)
          end
        end
      end
      return
    end
    if message.method and opts.on_notification then
      schedule(opts.on_notification, message.method, message.params)
    end
  end

  local function on_stdout(_, data)
    if not data or #data == 0 then return end
    self.buffer = self.buffer .. table.concat(data, "\n")
    while true do
      local index = self.buffer:find("\n", 1, true)
      if not index then break end
      local line = self.buffer:sub(1, index - 1):gsub("\r$", "")
      self.buffer = self.buffer:sub(index + 1)
      dispatch(line)
    end
  end

  function self.start()
    if self.job then return true end
    local argv = { opts.command or "yaah" }
    vim.list_extend(argv, opts.args or {})
    local job = vim.fn.jobstart(argv, {
      cwd = opts.cwd,
      stdin = "pipe",
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = on_stdout,
      on_stderr = function(_, data)
        if opts.on_stderr and data and #data > 0 then
          schedule(opts.on_stderr, table.concat(data, "\n"))
        end
      end,
      on_exit = function(_, code, signal)
        self.job = nil
        fail_pending(("ACP agent exited (%s, signal %s)"):format(code, signal))
        if opts.on_exit then schedule(opts.on_exit, code, signal) end
      end,
    })
    if job <= 0 then return nil, "Failed to start ACP agent: " .. table.concat(argv, " ") end
    self.job = job
    return true
  end

  function self.request(method, params, callback)
    if not self.job then
      if callback then schedule(callback, "ACP agent is not running") end
      return nil
    end
    self.next_id = self.next_id + 1
    local id = self.next_id
    self.pending[tostring(id)] = { callback = callback }
    local ok, line = pcall(encode, { jsonrpc = "2.0", id = id, method = method, params = params or {} })
    if not ok then
      self.pending[tostring(id)] = nil
      if callback then schedule(callback, "Failed to encode ACP request: " .. tostring(line)) end
      return nil
    end
    vim.fn.chansend(self.job, line .. "\n")
    return id
  end

  function self.stop()
    if self.job then pcall(vim.fn.jobstop, self.job) end
    self.job = nil
    fail_pending("ACP agent stopped")
  end

  return self
end

return M
