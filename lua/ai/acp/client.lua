local config = require("ai.config")
local profile = require("ai.acp.profile")
local rpc = require("ai.acp.rpc")
local tools = require("ai.tools")
local ui = require("ai.ui")

local M = {}

function M.new(opts)
  opts = opts or {}
  local acp = vim.tbl_deep_extend("force", config.get().acp or {}, opts)
  local self = { ready = false, session_id = nil, capabilities = nil, cwd = acp.cwd or vim.fn.getcwd() }
  local function emit(name, ...) if opts[name] then opts[name](...) end end

  --- Persona for the session profile. A function is resolved per session so a
  --- caller can fold in project rules that change with the target buffer.
  local function instructions()
    local value = opts.instructions or acp.instructions
    if type(value) == "function" then
      local ok, text = pcall(value)
      return (ok and type(text) == "string") and text or ""
    end
    return type(value) == "string" and value or ""
  end

  --- Run one declared tool for the agent. The tools are this client's own, so
  --- their own preview and confirmation UI is the approval step; the agent
  --- sends no permission request for them.
  local function client_tool_call(params, respond)
    local name = params and params.name
    if type(name) ~= "string" or name == "" then
      respond({ output = "ACP tool name is required", isError = true })
      return
    end
    tools.run(name, params.arguments or {}, function(err, result)
      if err then
        respond({ output = tostring(err), isError = true })
      else
        respond({ output = result == nil and vim.empty_dict() or result, isError = false })
      end
    end, { source = "acp" })
  end

  local function safe_path(path)
    if type(path) ~= "string" or path == "" then return nil, "ACP file path is required" end
    local absolute = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
    local root = vim.fn.fnamemodify(self.cwd, ":p"):gsub("/+$", "")
    if absolute ~= root and absolute:sub(1, #root + 1) ~= root .. "/" then
      return nil, "ACP file path is outside the session root: " .. absolute
    end
    return absolute
  end

  local function read_text_file(params)
    local path, path_err = safe_path(params and params.path)
    if not path then return nil, path_err end
    if vim.fn.filereadable(path) ~= 1 then return nil, "File is not readable: " .. path end
    local lines = vim.fn.readfile(path)
    local start = math.max(1, tonumber(params.line) or 1)
    local limit = tonumber(params.limit)
    local finish = #lines
    if limit and limit >= 0 then finish = math.min(finish, start + limit - 1) end
    return { content = table.concat(vim.list_slice(lines, start, finish), "\\n") }
  end

  local function preview_write_text_file(params, done)
    local path, path_err = safe_path(params and params.path)
    if not path then done(path_err); return end
    if type(params.content) ~= "string" then done("ACP file content is required"); return end
    local preview = {
      path = path,
      source = "acp",
      on_apply = function(err, info)
        if err then
          done(err)
          return
        end
        if info and not info.written then
          local bufnr = vim.fn.bufnr(path)
          local ok, write_err = pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd("silent keepalt write")
          end)
          if not ok then done("ACP file write failed: " .. tostring(write_err)); return end
        end
        done(nil, info or {})
      end,
    }
    if vim.fn.filereadable(path) == 1 then
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      preview.bufnr = bufnr
      preview.line1 = 1
      preview.line2 = vim.api.nvim_buf_line_count(bufnr)
      preview.original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      preview.replacement = params.content
      ui.preview_edit(preview)
    else
      preview.content = params.content
      ui.preview_create(preview)
    end
  end

  local terminals, terminal_counter = {}, 0
  local function blocked_command(command)
    if config.get().safety.allow_dangerous_commands then return nil end
    for _, pattern in ipairs(config.get().safety.blocked_command_patterns or {}) do
      if command:match(pattern) then return pattern end
    end
  end
  local function terminal_command(params)
    local command = params and params.command
    if type(command) ~= "string" or command == "" then return nil, "ACP terminal command is required" end
    local blocked = blocked_command(command)
    if blocked then return nil, "Command blocked by safety rule: " .. blocked end
    local argv = { command }
    if type(params.args) == "table" then vim.list_extend(argv, params.args) end
    return argv
  end
  local function terminal_output(term)
    return { output = (term.stdout or "") .. (term.stderr or ""), exitCode = term.exit_code, signal = term.signal }
  end

  local function create_terminal(params)
    local argv, err = terminal_command(params)
    if not argv then return nil, err end
    terminal_counter = terminal_counter + 1
    local id = "ai-nvim-term-" .. terminal_counter
    local term = { id = id, stdout = "", stderr = "", exit_code = nil, signal = nil }
    terminals[id] = term
    term.job = vim.system(argv, { cwd = params.cwd or self.cwd, text = true, env = params.env }, function(obj)
      vim.schedule(function()
        term.stdout, term.stderr = obj.stdout or "", obj.stderr or ""
        term.exit_code, term.signal = obj.code, obj.signal
        term.done = true
      end)
    end)
    return { terminalId = id }
  end
  local function get_terminal(params)
    local term = terminals[params and params.terminalId]
    if not term then return nil, "Unknown ACP terminal" end
    return term
  end

  local function wait_for_terminal(term, respond)
    if term.done then respond({ exitCode = term.exit_code, signal = term.signal }); return end
    vim.defer_fn(function() wait_for_terminal(term, respond) end, 50)
  end

  local function permission(params, respond)
    if opts.on_permission then opts.on_permission(params, respond); return end
    local options = params.options or {}
    local function selected(option)
      if not option then respond({ outcome = "cancelled" }); return end
      local option_id = option.optionId or option.option_id
      if option_id then respond({ outcome = { outcome = "selected", optionId = option_id } })
      else respond({ outcome = "cancelled" }) end
    end
    if acp.tool_policy == "allow" then
      for _, option in ipairs(options) do
        local text = ((option.optionId or "") .. " " .. (option.name or "")):lower()
        if text:find("allow", 1, true) or text:find("accept", 1, true) or text:find("yes", 1, true) then
          selected(option); return
        end
      end
      selected(options[1]); return
    end
    if type(vim.ui.select) ~= "function" then selected(nil); return end
    vim.ui.select(options, { prompt = (params.toolCall and params.toolCall.title) or "Allow ACP tool call?", format_item = function(item) return item.name or item.optionId or vim.inspect(item) end }, selected)
  end

  self.rpc = rpc.new({
    command = acp.command,
    args = acp.args,
    cwd = acp.cwd,
    on_stderr = function(text) emit("on_stderr", text) end,
    on_error = function(err) emit("on_error", err) end,
    on_request = function(id, method, params)
      if method == "fs/read_text_file" then
        local ok, result, err = pcall(read_text_file, params or {})
        if ok and result then
          self.rpc.respond(id, result)
        else
          self.rpc.respond(id, nil, { code = -32001, message = err or result })
        end
      elseif method == "fs/write_text_file" then
        preview_write_text_file(params or {}, function(err, result)
          if err then self.rpc.respond(id, nil, { code = -32001, message = err })
          else self.rpc.respond(id, result) end
        end)
      elseif method == "terminal/create" then
        local result, err = create_terminal(params or {})
        if result then self.rpc.respond(id, result) else self.rpc.respond(id, nil, { code = -32001, message = err }) end
      elseif method == "terminal/output" then
        local term, err = get_terminal(params or {})
        if term then self.rpc.respond(id, terminal_output(term)) else self.rpc.respond(id, nil, { code = -32001, message = err }) end
      elseif method == "terminal/wait_for_exit" then
        local term, err = get_terminal(params or {})
        if term then wait_for_terminal(term, function(result) self.rpc.respond(id, result) end)
        else self.rpc.respond(id, nil, { code = -32001, message = err }) end
      elseif method == "terminal/kill" then
        local term, err = get_terminal(params or {})
        if term and term.job then term.job:kill(15); self.rpc.respond(id, {})
        elseif term then self.rpc.respond(id, {}) else self.rpc.respond(id, nil, { code = -32001, message = err }) end
      elseif method == "terminal/release" then
        local term, err = get_terminal(params or {})
        if term then
          if term.job and not term.done then term.job:kill(15) end
          terminals[term.id] = nil
          self.rpc.respond(id, {})
        else self.rpc.respond(id, nil, { code = -32001, message = err }) end
      elseif method == "session/request_permission" then
        permission(params or {}, function(outcome) self.rpc.respond(id, outcome) end)
      elseif method == "_yaah/tools/call" then
        client_tool_call(params or {}, function(result) self.rpc.respond(id, result) end)
      else
        self.rpc.respond(id, nil, { code = -32601, message = "Unsupported ACP client method: " .. method })
      end
    end,
    on_notification = function(method, params)
      if method == "session/update" then emit("on_update", params)
      else emit("on_notification", method, params) end
    end,
    on_exit = function(code, signal)
      self.ready = false
      self.session_id = nil
      emit("on_exit", code, signal)
    end,
  })

  function self.start(callback)
    local ok, err = self.rpc.start()
    if not ok then
      emit("on_error", err)
      if callback then callback(err) end
      return nil
    end
    self.rpc.request("initialize", {
      protocolVersion = tonumber(acp.protocol_version) or 1,
      clientCapabilities = profile.client_capabilities(acp.client_capabilities),
      clientInfo = { name = "ai.nvim", version = acp.client_version or "0.1.0" },
    }, function(request_err, result)
      if request_err then
        emit("on_error", request_err)
        if callback then callback(request_err) end
        return
      end
      if not result or result.protocolVersion ~= 1 then
        local message = "Unsupported ACP protocol version: " .. tostring(result and result.protocolVersion)
        emit("on_error", message)
        if callback then callback(message) end
        return
      end
      self.ready = true
      self.capabilities = result.agentCapabilities
      emit("on_initialized", result)
      if callback then callback(nil, result) end
    end)
    return true
  end

  function self.new_session(params, callback)
    params = vim.tbl_extend("force", { cwd = acp.cwd or vim.fn.getcwd(), mcpServers = {} }, params or {})
    self.cwd = params.cwd
    if params._meta == nil then
      params._meta = profile.session_meta(instructions())
    end
    return self.rpc.request("session/new", params, function(err, result)
      if not err and result then self.session_id = result.sessionId end
      if callback then callback(err, result) end
    end)
  end

  function self.prompt(content, callback)
    if not self.session_id then
      local err = "ACP session has not been created"
      emit("on_error", err)
      if callback then callback(err) end
      return nil
    end
    local prompt = type(content) == "string" and { { type = "text", text = content } } or content
    return self.rpc.request("session/prompt", { sessionId = self.session_id, prompt = prompt }, callback)
  end

  function self.cancel(callback)
    if not self.session_id then return nil, "ACP session has not been created" end
    return self.rpc.request("session/cancel", { sessionId = self.session_id }, callback)
  end

  function self.close(callback)
    local done = function(err, result)
      self.rpc.stop()
      self.ready = false
      self.session_id = nil
      if callback then callback(err, result) end
    end
    if self.session_id then
      return self.rpc.request("session/close", { sessionId = self.session_id }, done)
    end
    done(nil)
  end

  return self
end

return M
