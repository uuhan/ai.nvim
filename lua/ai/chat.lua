local client = require("ai.client")
local config = require("ai.config")
local tools = require("ai.tools")

local M = {
  history = {},
  messages_bufnr = nil,
  input_bufnr = nil,
  messages_winid = nil,
  input_winid = nil,
  active = false,
  system_prompt = nil,
}
M.placeholder_ns = vim.api.nvim_create_namespace "ai.nvim.chat.placeholder"
M.render_markdown_attached = false

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function split_lines(text)
  local lines = vim.split((text or ""):gsub("\r\n", "\n"), "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  if vim.tbl_isempty(lines) then
    return { "" }
  end
  return lines
end

local function json_encode(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded
  end
  return vim.inspect(value)
end

local function json_decode(text)
  local ok, decoded = pcall(vim.json.decode, text)
  if ok then
    return decoded
  end
  return nil
end

local function strip_code_fence(text)
  local body = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local first_line = body:match("^(.-)\n")
  if first_line and first_line:match("^```") and body:match("\n```%s*$") then
    body = body:gsub("^```[%w_+-]*\n", ""):gsub("\n```%s*$", "")
  end
  return body:gsub("^%s+", ""):gsub("%s+$", "")
end

local function json_objects(text)
  local objects = {}
  local depth = 0
  local start_index = nil
  local in_string = false
  local escaped = false

  for index = 1, #text do
    local char = text:sub(index, index)
    if in_string then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == "\"" then
        in_string = false
      end
    elseif char == "\"" then
      in_string = true
    elseif char == "{" then
      if depth == 0 then
        start_index = index
      end
      depth = depth + 1
    elseif char == "}" and depth > 0 then
      depth = depth - 1
      if depth == 0 and start_index then
        table.insert(objects, text:sub(start_index, index))
        start_index = nil
      end
    end
  end

  return objects
end

local function limit_text(text, max_chars)
  text = text or ""
  max_chars = tonumber(max_chars) or config.get().chat.max_tool_result_chars or 20000
  if max_chars > 0 and #text > max_chars then
    return text:sub(1, max_chars) .. "\n[truncated]"
  end
  return text
end

local function set_scratch(bufnr, filetype, modifiable)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype
  vim.bo[bufnr].modifiable = modifiable
end

local function enable_markdown_renderer()
  M.render_markdown_attached = false
  if config.get().chat.render_markdown == false or not valid_window(M.messages_winid) then
    return
  end

  local ok, renderer = pcall(require, "render-markdown")
  if not ok or type(renderer.buf_enable) ~= "function" then
    return
  end

  local enabled = pcall(vim.api.nvim_win_call, M.messages_winid, function()
    renderer.buf_enable()
  end)
  M.render_markdown_attached = enabled
end

local function add_callout(lines, kind, title, rows)
  table.insert(lines, ("> [!%s] %s"):format(kind, title))
  for _, row in ipairs(rows) do
    if row == "" then
      table.insert(lines, ">")
    else
      table.insert(lines, "> " .. row)
    end
  end
end

local function tool_running_card(tool)
  local lines = {}
  add_callout(lines, "NOTE", "Tool call: " .. (tool or "unknown"), { "status: running" })
  return table.concat(lines, "\n")
end

local function scroll_messages()
  if not valid_window(M.messages_winid) or not valid_buffer(M.messages_bufnr) then
    return
  end
  local line_count = math.max(1, vim.api.nvim_buf_line_count(M.messages_bufnr))
  pcall(vim.api.nvim_win_set_cursor, M.messages_winid, { line_count, 0 })
end

local function fold_tool_results(lines)
  if config.get().chat.fold_tool_results == false or not valid_window(M.messages_winid) then
    return
  end

  pcall(vim.api.nvim_win_call, M.messages_winid, function()
    vim.wo.foldmethod = "manual"
    vim.wo.foldenable = true
    vim.wo.foldlevel = 99
    vim.cmd("silent! normal! zE")

    local index = 1
    while index <= #lines do
      local line = lines[index]
      if line:match("^> %[!%u+%] Tool result:") then
        local start_line
        local end_line = index
        local cursor = index + 1

        while cursor <= #lines and lines[cursor]:match("^>") do
          if lines[cursor]:match("^> result:%s*$") then
            start_line = cursor + 1
          end
          end_line = cursor
          cursor = cursor + 1
        end

        if start_line and start_line < end_line then
          vim.cmd(("%d,%dfold"):format(start_line, end_line))
          vim.cmd(("silent! %dfoldclose"):format(start_line))
        end

        index = cursor
      else
        index = index + 1
      end
    end
  end)
end

local function set_messages(text)
  if not valid_buffer(M.messages_bufnr) then
    return
  end
  local lines = split_lines(text)
  vim.bo[M.messages_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.messages_bufnr, 0, -1, false, lines)
  vim.bo[M.messages_bufnr].modifiable = false
  enable_markdown_renderer()
  fold_tool_results(lines)
  scroll_messages()
end

local function raw_input_text()
  if not valid_buffer(M.input_bufnr) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(M.input_bufnr, 0, -1, false), "\n")
end

local function update_placeholder()
  if not valid_buffer(M.input_bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(M.input_bufnr, M.placeholder_ns, 0, -1)
  local placeholder = config.get().chat.placeholder
  if not placeholder or placeholder == "" then
    return
  end

  if raw_input_text():gsub("%s+", "") == "" then
    pcall(vim.api.nvim_buf_set_extmark, M.input_bufnr, M.placeholder_ns, 0, 0, {
      virt_text = { { placeholder, "Comment" } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end
end

local function render_history(extra)
  local lines = {
    "# AI Chat",
    "",
  }

  if vim.tbl_isempty(M.history) then
    table.insert(lines, "Start typing in the input pane below.")
    table.insert(lines, "")
  end

  for _, message in ipairs(M.history) do
    if message.role == "user" then
      table.insert(lines, "## You")
    elseif message.role == "assistant" then
      if message.kind == "tool_call" then
        table.insert(lines, "## Tool")
      else
        table.insert(lines, "## Assistant")
      end
    elseif message.role == "tool" then
      table.insert(lines, "## Tool")
    else
      table.insert(lines, "## " .. message.role)
    end
    table.insert(lines, "")

    if message.kind == "tool_call" then
      local rows = { "args:" }
      if message.args then
        table.insert(rows, "```json")
        vim.list_extend(rows, split_lines(json_encode(message.args)))
        table.insert(rows, "```")
      end
      add_callout(lines, "NOTE", "Tool call: " .. (message.tool or "unknown"), rows)
    elseif message.role == "tool" then
      local status = message.error and "failed" or "returned"
      local kind = message.error and "ERROR" or "INFO"
      local rows = {
        "status: " .. status,
        "result:",
        message.error and "```text" or "```json",
      }
      vim.list_extend(rows, split_lines(message.content))
      table.insert(rows, "```")
      add_callout(lines, kind, ("Tool result: %s (%s)"):format(message.tool or "unknown", status), rows)
    else
      vim.list_extend(lines, split_lines(message.content))
    end
    table.insert(lines, "")
  end

  if extra and extra ~= "" then
    vim.list_extend(lines, split_lines(extra))
  end

  return table.concat(lines, "\n")
end

local function reset_input()
  if not valid_buffer(M.input_bufnr) then
    return
  end
  vim.bo[M.input_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
  vim.bo[M.input_bufnr].modifiable = true
  update_placeholder()
end

local function input_text()
  return raw_input_text():gsub("^%s+", ""):gsub("%s+$", "")
end

local function harness_prompt()
  if config.get().chat.tools_enabled == false then
    return ""
  end

  return table.concat({
    "AIChat has access to Neovim harness tools.",
    "Use tools when editor, project, git, diagnostics, quickfix, or preview context is needed.",
    "To call a tool, reply with exactly one JSON object and no markdown:",
    [[{"tool":"nvim_read_buffer","args":{"start_line":1,"end_line":80}}]],
    "After receiving a tool result, either call another tool or answer the user normally.",
    "Stop calling tools once you have enough context to answer the user's request.",
    "Call at most one tool per assistant message.",
    "Do not claim that a preview tool applied a patch or ran a command.",
    "Preview tools only prepare pending user-reviewed actions; the user must run :AIApply or :AIRun.",
    "",
    "Available tools:",
    tools.describe(),
  }, "\n")
end

local function tool_result_message(message)
  local state = message.error and "failed" or "returned"
  return table.concat({
    ("Tool `%s` %s."):format(message.tool or "unknown", state),
    "",
    message.content or "",
  }, "\n")
end

local function request_messages()
  local system = M.system_prompt()
  local harness = harness_prompt()
  if harness ~= "" then
    system = system .. "\n\n" .. harness
  end

  local messages = {
    { role = "system", content = system },
  }

  for _, message in ipairs(M.history) do
    if message.role == "user" or message.role == "assistant" then
      table.insert(messages, { role = message.role, content = message.content })
    elseif message.role == "tool" then
      table.insert(messages, { role = "user", content = tool_result_message(message) })
    end
  end

  return messages
end

local function parse_tool_call(text)
  local function normalize(decoded)
    if type(decoded) ~= "table" or type(decoded.tool) ~= "string" then
      return nil
    end

    local args = decoded.args
    if args == nil then
      args = {}
    end
    if type(args) ~= "table" then
      return {
        tool = decoded.tool,
        args = {},
        error = "`args` must be a JSON object.",
      }
    end

    return {
      tool = decoded.tool,
      args = args,
    }
  end

  local body = strip_code_fence(text)
  local call = normalize(json_decode(body))
  if call then
    return call
  end

  for _, object in ipairs(json_objects(body)) do
    call = normalize(json_decode(object))
    if call then
      return call
    end
  end

  return nil
end

local function append_tool_result(call, err, result)
  local content = err or json_encode(result)
  table.insert(M.history, {
    role = "tool",
    tool = call.tool,
    error = err ~= nil,
    content = limit_text(content, config.get().chat.max_tool_result_chars),
  })
end

function M.close()
  local seen = {}
  local windows = {}

  local function add_winid(winid)
    if valid_window(winid) and not seen[winid] then
      seen[winid] = true
      table.insert(windows, winid)
    end
  end

  add_winid(M.input_winid)
  add_winid(M.messages_winid)

  if valid_buffer(M.input_bufnr) then
    for _, winid in ipairs(vim.fn.win_findbuf(M.input_bufnr)) do
      add_winid(winid)
    end
  end

  if valid_buffer(M.messages_bufnr) then
    for _, winid in ipairs(vim.fn.win_findbuf(M.messages_bufnr)) do
      add_winid(winid)
    end
  end

  for _, winid in ipairs(windows) do
    pcall(vim.api.nvim_win_close, winid, true)
  end

  M.input_winid = nil
  M.messages_winid = nil
end

function M.is_open()
  if valid_window(M.input_winid) or valid_window(M.messages_winid) then
    return true
  end

  if valid_buffer(M.input_bufnr) and #vim.fn.win_findbuf(M.input_bufnr) > 0 then
    return true
  end

  if valid_buffer(M.messages_bufnr) and #vim.fn.win_findbuf(M.messages_bufnr) > 0 then
    return true
  end

  return false
end

function M.toggle(opts)
  if M.is_open() then
    M.close()
    return
  end

  M.open(opts)
end

function M.clear()
  M.history = {}
  set_messages(render_history())
end

function M.send(text)
  text = (text or input_text()):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" or M.active then
    return
  end

  M.active = true
  table.insert(M.history, { role = "user", content = text })
  reset_input()
  set_messages(render_history("## Assistant\n\n..."))

  if config.get().chat.tools_enabled ~= false then
    local max_rounds = tonumber(config.get().chat.max_tool_rounds) or 20

    local function request_next(tool_rounds)
      client.chat(request_messages(), { stream = false }, function(err, response)
        if err then
          M.active = false
          set_messages(render_history("## Error\n\n" .. err))
          return
        end

        local call = parse_tool_call(response)
        if not call then
          M.active = false
          table.insert(M.history, { role = "assistant", content = response })
          set_messages(render_history())
          return
        end

        if tool_rounds >= max_rounds then
          M.active = false
          set_messages(render_history("## Error\n\nAIChat stopped after reaching the tool round limit."))
          return
        end

        table.insert(M.history, {
          role = "assistant",
          kind = "tool_call",
          tool = call.tool,
          args = call.args,
          content = response,
        })
        set_messages(render_history(tool_running_card(call.tool)))

        if call.error then
          append_tool_result(call, call.error)
          set_messages(render_history("## Assistant\n\n..."))
          request_next(tool_rounds + 1)
          return
        end

        tools.run(call.tool, call.args, function(tool_err, result)
          append_tool_result(call, tool_err, result)
          set_messages(render_history("## Assistant\n\n..."))
          request_next(tool_rounds + 1)
        end)
      end)
    end

    request_next(0)
    return
  end

  if config.get().provider.stream then
    local assistant = ""
    client.chat_stream(request_messages(), {}, {
      on_delta = function(delta)
        assistant = assistant .. delta
        set_messages(render_history("## Assistant\n\n" .. assistant))
      end,
      on_error = function(err)
        M.active = false
        set_messages(render_history("## Error\n\n" .. err))
      end,
      on_done = function()
        M.active = false
        table.insert(M.history, { role = "assistant", content = assistant })
        set_messages(render_history())
      end,
    })
    return
  end

  client.chat(request_messages(), {}, function(err, response)
    M.active = false
    if err then
      set_messages(render_history("## Error\n\n" .. err))
      return
    end
    table.insert(M.history, { role = "assistant", content = response })
    set_messages(render_history())
  end)
end

local function map_input_keys()
  local opts = { buffer = M.input_bufnr, silent = true, nowait = true }
  local close = function()
    vim.cmd.stopinsert()
    M.close()
  end
  vim.keymap.set("n", "<CR>", function() M.send() end, vim.tbl_extend("force", opts, { desc = "AI chat send" }))
  vim.keymap.set("i", "<CR>", function()
    vim.cmd.stopinsert()
    M.send()
  end, vim.tbl_extend("force", opts, { desc = "AI chat send" }))
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd.stopinsert()
    M.send()
  end, vim.tbl_extend("force", opts, { desc = "AI chat send" }))
  vim.keymap.set("n", "<C-l>", M.clear, vim.tbl_extend("force", opts, { desc = "AI chat clear" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "AI chat close" }))
  vim.keymap.set({ "n", "i" }, "<C-q>", close, vim.tbl_extend("force", opts, { desc = "AI chat close" }))
end

local function map_messages_keys()
  local opts = { buffer = M.messages_bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "i", function()
    if valid_window(M.input_winid) then
      vim.api.nvim_set_current_win(M.input_winid)
      vim.cmd.startinsert()
    end
  end, vim.tbl_extend("force", opts, { desc = "AI chat focus input" }))
  vim.keymap.set("n", "<CR>", function()
    if valid_window(M.input_winid) then
      vim.api.nvim_set_current_win(M.input_winid)
      vim.cmd.startinsert()
    end
  end, vim.tbl_extend("force", opts, { desc = "AI chat focus input" }))
  vim.keymap.set("n", "<C-l>", M.clear, vim.tbl_extend("force", opts, { desc = "AI chat clear" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "AI chat close" }))
  vim.keymap.set({ "n", "i" }, "<C-q>", M.close, vim.tbl_extend("force", opts, { desc = "AI chat close" }))
end

local function ensure_buffers()
  if not valid_buffer(M.messages_bufnr) then
    M.messages_bufnr = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, M.messages_bufnr, "ai://chat")
    set_scratch(M.messages_bufnr, "markdown", false)
  end

  if not valid_buffer(M.input_bufnr) then
    M.input_bufnr = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, M.input_bufnr, "ai://chat-input")
    set_scratch(M.input_bufnr, "text", true)
    reset_input()
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
      buffer = M.input_bufnr,
      callback = update_placeholder,
    })
  end
end

function M.open(opts)
  opts = opts or {}
  M.system_prompt = opts.system_prompt or M.system_prompt or function() return "You are an AI assistant embedded in Neovim." end
  ensure_buffers()

  if valid_window(M.messages_winid) and valid_window(M.input_winid) then
    vim.api.nvim_set_current_win(M.input_winid)
    vim.cmd.startinsert()
    return
  end

  local chat_opts = config.get().chat
  vim.cmd(("botright vertical %dnew"):format(chat_opts.width))
  M.messages_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.messages_winid, M.messages_bufnr)
  vim.wo[M.messages_winid].wrap = true
  vim.wo[M.messages_winid].number = false
  vim.wo[M.messages_winid].relativenumber = false
  vim.wo[M.messages_winid].winfixwidth = true

  vim.api.nvim_set_current_win(M.messages_winid)
  vim.cmd(("belowright %dnew"):format(chat_opts.input_height))
  M.input_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_winid, M.input_bufnr)
  vim.api.nvim_win_set_height(M.input_winid, chat_opts.input_height)
  vim.wo[M.input_winid].number = false
  vim.wo[M.input_winid].relativenumber = false
  vim.wo[M.input_winid].wrap = true
  vim.wo[M.input_winid].winfixheight = true

  map_messages_keys()
  map_input_keys()
  set_messages(render_history())
  update_placeholder()
  vim.cmd.startinsert()
end

return M
