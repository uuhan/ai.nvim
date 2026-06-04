local M = {}

local function build_args(req, stream)
  local args = {
    req.curl or "curl",
    "-sS",
    "--fail-with-body",
    "--max-time",
    tostring(math.max(1, math.floor((req.timeout_ms or 60000) / 1000))),
    "-X",
    "POST",
    req.url,
    "--data-binary",
    "@-",
  }

  if stream then
    table.insert(args, 2, "-N")
  end

  for name, value in pairs(req.headers or {}) do
    table.insert(args, "-H")
    table.insert(args, name .. ": " .. value)
  end

  return args
end

function M.request(req, cb)
  if not vim.system then
    vim.schedule(function()
      cb("ai.nvim requires Neovim with vim.system support.")
    end)
    return
  end

  local job = vim.system(build_args(req, false), { text = true, stdin = req.body_json }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        cb(("Provider request failed (%s):\n%s%s"):format(obj.code, obj.stderr or "", obj.stdout or ""))
        return
      end
      cb(nil, obj.stdout or "")
    end)
  end)
  return job
end

function M.stream(req, callbacks)
  callbacks = callbacks or {}
  local stderr = {}
  local job = vim.fn.jobstart(build_args(req, true), {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if data and #data > 0 then
        vim.schedule(function()
          if callbacks.on_chunk then
            callbacks.on_chunk(table.concat(data, "\n"))
          end
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

  vim.fn.chansend(job, req.body_json)
  vim.fn.chanclose(job, "stdin")
  return {
    kill = function()
      pcall(vim.fn.jobstop, job)
    end,
  }
end

return M
