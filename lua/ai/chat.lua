local client = require("ai.client")
local config = require("ai.config")
local context = require("ai.context")
local session = require("ai.session")
local stream_buffer = require("ai.stream_buffer")
local target = require("ai.target")
local tools = require("ai.tools")
local ui = require("ai.ui")

local M = {
  history = {},
  messages_bufnr = nil,
  input_bufnr = nil,
  messages_winid = nil,
  input_winid = nil,
  layout = nil,
  active = false,
  active_request = nil,
  active_stream = nil,
  request_id = 0,
  status = "idle",
  status_detail = "",
  system_prompt = nil,
  target_bufnr = nil,
  last_editor_winid = nil,
  target_autocmd = false,
  suspend_target_capture = false,
}
M.placeholder_ns = vim.api.nvim_create_namespace "ai.nvim.chat.placeholder"
M.render_markdown_attached = false

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function stop_insert_mode()
  if vim.fn.mode():match("^[iR]") then
    pcall(vim.cmd.stopinsert)
  end
end

local render_history

local function sync_target_state()
  local state = target.state()
  M.target_bufnr = state.target_bufnr
  M.last_editor_winid = state.last_editor_winid
end

local function capture_target(winid)
  if M.suspend_target_capture then
    return
  end
  target.capture(winid)
  sync_target_state()
end

--- All history mutations go through here so chat persistence sees every
--- message. The session file is created lazily on the first write.
local function push_history(message)
  table.insert(M.history, message)

  local sessions_cfg = config.get().chat.sessions or {}
  if sessions_cfg.enabled == false then
    return
  end
  if not session.active() then
    session.begin(context.root(M.target_bufnr or 0))
  end
  session.append(message)
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
        table.insert(objects, {
          text = text:sub(start_index, index),
          start_index = start_index,
          end_index = index,
        })
        start_index = nil
      end
    end
  end

  return objects
end

local function limit_text_info(text, max_chars)
  text = text or ""
  max_chars = tonumber(max_chars) or config.get().chat.max_tool_result_chars or 20000
  if max_chars > 0 and #text > max_chars then
    return text:sub(1, max_chars) .. "\n[truncated]", true, #text
  end
  return text, false, #text
end

local function short_text(text, max_chars)
  local compact = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local limited, truncated = limit_text_info(compact, max_chars or 240)
  if truncated then
    return limited:gsub("\n%[truncated%]$", " ...")
  end
  return limited
end

local function display_limit()
  return config.get().chat.max_tool_result_chars
end

local function model_limit()
  return config.get().chat.max_tool_model_chars or 6000
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

-- Wrap a value in inline code so its contents (paths with ~, *, _, [] etc.) are
-- not interpreted as markdown — e.g. a home-dir `~` rendering as strikethrough.
local function inline_code(text)
  text = tostring(text or ""):gsub("[\r\n]+", " ")
  local longest = 0
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  local fence = string.rep("`", longest + 1)
  local pad = (text:match("^`") or text:match("`$")) and " " or ""
  return fence .. pad .. text .. pad .. fence
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

--- Follow output only while the cursor sits at the bottom of the messages
--- pane; once the user scrolls up to read, stop yanking the view down.
local function should_follow()
  if not valid_window(M.messages_winid) or not valid_buffer(M.messages_bufnr) then
    return true
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, M.messages_winid)
  if not ok then
    return true
  end
  local line_count = vim.api.nvim_buf_line_count(M.messages_bufnr)
  return cursor[1] >= line_count - 1
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
          if lines[cursor]:match("^> details:%s*$") or lines[cursor]:match("^> result:%s*$") then
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

local last_rendered_lines = nil

local function set_messages(text, opts)
  if not valid_buffer(M.messages_bufnr) then
    return
  end
  local lines = split_lines(text)
  local follow = should_follow()

  -- During streaming only the tail changes; rewrite the differing suffix so
  -- existing folds and the renderer stay untouched and long chats stay smooth.
  local incremental = opts
    and opts.incremental
    and last_rendered_lines
    and vim.api.nvim_buf_line_count(M.messages_bufnr) == #last_rendered_lines

  vim.bo[M.messages_bufnr].modifiable = true
  if incremental then
    local prefix = 0
    local min_len = math.min(#last_rendered_lines, #lines)
    while prefix < min_len and last_rendered_lines[prefix + 1] == lines[prefix + 1] do
      prefix = prefix + 1
    end
    if prefix < #lines or #last_rendered_lines ~= #lines then
      vim.api.nvim_buf_set_lines(M.messages_bufnr, prefix, -1, false, vim.list_slice(lines, prefix + 1, #lines))
    end
    vim.bo[M.messages_bufnr].modifiable = false
  else
    vim.api.nvim_buf_set_lines(M.messages_bufnr, 0, -1, false, lines)
    vim.bo[M.messages_bufnr].modifiable = false
    enable_markdown_renderer()
    fold_tool_results(lines)
  end

  last_rendered_lines = lines
  if follow then
    scroll_messages()
  end
end

local function set_status(status, detail, extra)
  M.status = status or "idle"
  M.status_detail = detail or ""
  if valid_buffer(M.messages_bufnr) then
    set_messages(render_history(extra), { incremental = status == "streaming" })
  end
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

render_history = function(extra)
  local lines = {
    "# AI Chat",
    "",
    ("Status: `%s`%s"):format(M.status or "idle", M.status_detail ~= "" and (" - " .. M.status_detail) or ""),
    "",
  }

  if vim.tbl_isempty(M.history) then
    table.insert(lines, "Start typing in the input pane below.")
    table.insert(lines, "")
  end

  for _, message in ipairs(M.history) do
    if message.role == "user" then
      table.insert(lines, message.kind == "event" and "## Editor" or "## You")
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
        "summary: " .. inline_code(message.summary or status),
      }
      if message.display_truncated then
        table.insert(
          rows,
          ("visible result truncated: %d -> %d chars"):format(message.content_chars or #message.content, #message.content)
        )
      end
      if message.model_truncated then
        table.insert(
          rows,
          ("model backfill compressed: %d -> %d chars"):format(
            message.model_content_chars or #(message.model_content or ""),
            #(message.model_content or "")
          )
        )
      end
      table.insert(rows, "details:")
      table.insert(rows, message.error and "```text" or "```json")
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

  local pending_notice = ui.pending_notice()
  if pending_notice ~= "" then
    vim.list_extend(lines, split_lines(pending_notice))
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

  local native = config.get().chat.native_tools ~= false
  local lines = {
    "AIChat has access to Neovim harness tools.",
    "Use tools when editor, project, git, diagnostics, quickfix, symbol, reference, or preview context is needed.",
    "After receiving a tool result, either call another tool or answer the user normally.",
    "Stop calling tools once you have enough context to answer the user's request.",
  }

  if native then
    table.insert(lines, "Tool definitions are provided through the native tools API.")
  else
    table.insert(lines, "Call at most one tool per assistant message.")
  end

  vim.list_extend(lines, {
    "When the user asks you to change code, edit instead of only describing the edit: prefer nvim_edit_file for targeted string edits, nvim_create_file for new files, nvim_preview_buffer_replace or nvim_preview_file_replace for line-range rewrites, and nvim_preview_patch for multi-file diffs.",
    "Read tools prefix each line with its number and a tab; never include those prefixes in old_string, new_string, or replacement text.",
    "Use nvim_grep and nvim_glob for structured project searches.",
    "Only one preview (edit, patch, command, or file creation) can be pending at a time; creating a new preview discards an unapplied one.",
    "After creating a preview, finish your reply and wait; a follow-up message will report whether the user applied or rejected it.",
    "Do not claim that a preview tool ran a command unless its tool result says status=ran.",
  })

  if config.get().safety and config.get().safety.auto_apply_edits == true then
    table.insert(lines, "safety.auto_apply_edits is enabled; edit preview tools may apply edits immediately after creating the preview.")
  else
    table.insert(lines, "Preview edit tools only prepare pending user-reviewed edits; the user must run :AIApply.")
  end
  if config.get().safety and config.get().safety.auto_run_commands == true then
    table.insert(lines, "safety.auto_run_commands is enabled; command preview tools may run commands immediately after creating the preview.")
  else
    table.insert(lines, "Command preview tools only prepare pending commands; the user must run :AIRun.")
  end

  if native then
    vim.list_extend(lines, {
      "Prefer the provider's native tool/function call format.",
      "If native tool calls are unavailable, call one tool by replying with exactly one JSON object and no markdown:",
      [[{"tool":"nvim_read_buffer","args":{"start_line":1,"end_line":80}}]],
    })
  else
    vim.list_extend(lines, {
      "To call a tool, reply with exactly one JSON object and no markdown:",
      [[{"tool":"nvim_read_buffer","args":{"start_line":1,"end_line":80}}]],
      "",
      "Available tools:",
      tools.describe(),
    })
  end

  return table.concat(lines, "\n")
end

local function tool_result_message(message, body)
  local state = message.error and "failed" or "returned"
  return table.concat({
    ("Tool `%s` %s."):format(message.tool or "unknown", state),
    "",
    body or message.model_content or message.content or "",
  }, "\n")
end

local function compact_tool_result(call, err, result)
  if err then
    return limit_text_info(err, model_limit())
  end

  local text = json_encode(result)
  return limit_text_info(text, model_limit())
end

local function tool_result_summary(call, err, result)
  if err then
    return "error: " .. short_text(err, 220)
  end

  if type(result) ~= "table" then
    return short_text(json_encode(result), 240)
  end

  local parts = {}
  local function add(name, value)
    if value == nil or value == "" then
      return
    end
    table.insert(parts, ("%s=%s"):format(name, tostring(value)))
  end

  add("status", result.status)
  add("action", result.action)
  add("mode", result.mode)
  add("cwd", result.cwd and vim.fn.fnamemodify(result.cwd, ":~") or nil)
  add("root", result.root and vim.fn.fnamemodify(result.root, ":~") or nil)

  local path = result.path or result.name
  if path and path ~= "" then
    add("path", vim.fn.fnamemodify(path, ":~"))
  end

  if type(result.current_buffer) == "table" then
    local current = result.current_buffer.name
    if current == nil or current == "" then
      current = result.current_buffer.bufnr and ("#" .. result.current_buffer.bufnr) or nil
    end
    add("current_buffer", current and vim.fn.fnamemodify(current, ":~") or nil)
  end

  if result.start_line or result.end_line then
    add("range", ("%s-%s"):format(result.start_line or "?", result.end_line or "?"))
  end

  add("line_count", result.line_count)
  if type(result.windows) == "table" then
    add("windows", #result.windows)
  end
  if type(result.items) == "table" then
    add("items", #result.items)
  end
  if type(result.files) == "table" then
    add("files", #result.files)
  end
  add("total", result.total)
  if result.truncated then
    add("truncated", true)
  end
  if result.query then
    add("query", short_text(result.query, 80))
  end
  if result.message then
    table.insert(parts, short_text(result.message, 180))
  end

  if vim.tbl_isempty(parts) then
    return short_text(json_encode(result), 240)
  end
  return table.concat(parts, ", ")
end

local function native_tool_call_message(message)
  local req = {
    role = "assistant",
    content = message.content or "",
    tool_calls = {
      {
        id = message.tool_call_id,
        type = "function",
        ["function"] = {
          name = message.tool,
          arguments = json_encode(message.args or {}),
        },
      },
    },
  }
  if type(message.reasoning_content) == "string" then
    req.reasoning_content = message.reasoning_content
  end
  return req
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

  -- Only the most recent tool results are sent in full; older ones collapse
  -- to their one-line summary so long sessions do not flood the context.
  local keep_full = tonumber(config.get().chat.max_full_tool_results) or 4
  local tool_total = 0
  for _, message in ipairs(M.history) do
    if message.role == "tool" then
      tool_total = tool_total + 1
    end
  end

  local tool_seen = 0
  for _, message in ipairs(M.history) do
    if message.role == "user" or message.role == "assistant" then
      if message.kind == "tool_call" and message.native then
        table.insert(messages, native_tool_call_message(message))
      elseif message.kind == "tool_call" then
        table.insert(messages, { role = "assistant", content = message.content })
      else
        table.insert(messages, { role = message.role, content = message.content })
      end
    elseif message.role == "tool" then
      tool_seen = tool_seen + 1
      local body = message.model_content or message.content or ""
      if tool_total - tool_seen >= keep_full then
        body = "[compressed] " .. (message.summary or "older tool result omitted")
      end
      if message.native and message.tool_call_id then
        table.insert(messages, {
          role = "tool",
          tool_call_id = message.tool_call_id,
          content = body,
        })
      else
        table.insert(messages, { role = "user", content = tool_result_message(message, body) })
      end
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

  -- Mask fenced code blocks (same length, so indices stay valid) before
  -- scanning for embedded tool-call JSON: a fenced example like
  -- ```json {"tool":...} ``` quoted in prose must not be executed.
  local masked = body:gsub("```.-```", function(block)
    return string.rep(" ", #block)
  end)

  for _, object in ipairs(json_objects(masked)) do
    call = normalize(json_decode(object.text))
    if call then
      local preface = (body:sub(1, object.start_index - 1) .. body:sub(object.end_index + 1)):gsub("^%s+", ""):gsub("%s+$", "")
      call.preface = preface ~= "" and preface or nil
      return call
    end
  end

  return nil
end

local function parse_native_tool_calls(message)
  local calls = {}
  if type(message) ~= "table" or type(message.tool_calls) ~= "table" then
    return calls
  end

  for index, item in ipairs(message.tool_calls) do
    local fn = item["function"] or {}
    local name = fn.name
    if type(name) == "string" and name ~= "" then
      local args = {}
      if type(fn.arguments) == "string" and fn.arguments ~= "" then
        local decoded = json_decode(fn.arguments)
        if type(decoded) == "table" then
          args = decoded
        else
          args = {}
        end
      elseif type(fn.arguments) == "table" then
        args = fn.arguments
      end

      table.insert(calls, {
        tool = name,
        args = args,
        native = true,
        tool_call_id = item.id or ("ai_nvim_tool_" .. index),
        reasoning_content = message.reasoning_content,
      })
    end
  end

  return calls
end

local function append_stream_tool_call_delta(calls, deltas)
  if type(deltas) ~= "table" then
    return
  end

  for _, item in ipairs(deltas) do
    local position = tonumber(item.index)
    if position then
      position = position + 1
    else
      position = math.max(1, #calls)
    end

    local call = calls[position] or { ["function"] = {} }
    call.id = item.id or call.id
    call.type = item.type or call.type or "function"

    local fn = item["function"]
    if type(fn) == "table" then
      call["function"] = call["function"] or {}
      if type(fn.name) == "string" and fn.name ~= "" then
        local current = call["function"].name or ""
        if current == "" then
          call["function"].name = fn.name
        elseif current ~= fn.name and not current:find(fn.name, 1, true) then
          call["function"].name = current .. fn.name
        end
      end
      if type(fn.arguments) == "string" and fn.arguments ~= "" then
        call["function"].arguments = (call["function"].arguments or "") .. fn.arguments
      end
    end

    calls[position] = call
  end
end

local function stream_tool_call_message(calls, reasoning_content)
  local tool_calls = {}
  for _, call in ipairs(calls) do
    if call and call["function"] and call["function"].name then
      table.insert(tool_calls, call)
    end
  end
  return {
    tool_calls = tool_calls,
    reasoning_content = reasoning_content,
  }
end

local function append_tool_result(call, err, result)
  local content = err or json_encode(result)
  local display_content, display_truncated, display_chars = limit_text_info(content, display_limit())
  local model_content, model_truncated, model_chars = compact_tool_result(call, err, result)
  push_history({
    role = "tool",
    tool = call.tool,
    native = call.native,
    tool_call_id = call.tool_call_id,
    error = err ~= nil,
    summary = tool_result_summary(call, err, result),
    content = display_content,
    content_chars = display_chars,
    display_truncated = display_truncated,
    model_content = model_content,
    model_content_chars = model_chars,
    model_truncated = model_truncated,
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
  M.layout = nil
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

--- Record an editor event in the history without triggering a model request.
--- The model sees it as context on the next round.
function M.note_editor_event(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return false
  end
  push_history({ role = "user", kind = "event", content = text })
  if valid_buffer(M.messages_bufnr) then
    set_messages(render_history())
  end
  return true
end

--- Continue the chat loop after the user applied a pending preview.
--- Sends immediately when the chat is open and idle; otherwise records the
--- event so the model sees it on the next round.
function M.continue_with_apply_result(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return false
  end
  if M.active or not M.is_open() then
    return M.note_editor_event(text) and false
  end
  M.send(text, { kind = "event" })
  return true
end

function M.continue_with_command_output(output)
  output = (output or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if output == "" or M.active or not M.is_open() then
    return false
  end
  M.send(table.concat({
    "The approved shell command finished. Continue from this command output:",
    "",
    "```text",
    output,
    "```",
  }, "\n"), { kind = "event" })
  return true
end

local ensure_buffers

function M.toggle(opts)
  opts = opts or {}
  local layout = opts.layout or "side"
  if M.is_open() and M.layout == layout then
    M.close()
    return
  end

  M.open(opts)
end

function M.start(opts)
  opts = opts or {}
  capture_target()
  M.system_prompt = opts.system_prompt or M.system_prompt or function() return "You are an AI assistant embedded in Neovim." end
  ensure_buffers()
  return M
end

local function size_value(value, total, fallback, minimum)
  value = tonumber(value) or fallback
  local maximum = math.max(1, total - 2)
  minimum = math.min(minimum or 1, maximum)
  if value > 0 and value < 1 then
    value = math.floor(total * value)
  else
    value = math.floor(value)
  end
  return math.max(minimum, math.min(value, maximum))
end

local function configure_chat_windows()
  vim.wo[M.messages_winid].wrap = true
  vim.wo[M.messages_winid].number = false
  vim.wo[M.messages_winid].relativenumber = false

  vim.wo[M.input_winid].number = false
  vim.wo[M.input_winid].relativenumber = false
  vim.wo[M.input_winid].wrap = true
end

local function focus_messages()
  if valid_window(M.messages_winid) then
    vim.api.nvim_set_current_win(M.messages_winid)
    stop_insert_mode()
  end
end

local function open_side(chat_opts)
  -- Open splits with the chat buffers directly; a ":new" + win_set_buf swap
  -- would leave an orphaned unnamed buffer behind on every open.
  M.messages_winid = vim.api.nvim_open_win(M.messages_bufnr, true, {
    split = "right",
    win = -1,
    width = math.max(20, math.floor(tonumber(chat_opts.width) or 80)),
  })
  vim.wo[M.messages_winid].winfixwidth = true

  M.input_winid = vim.api.nvim_open_win(M.input_bufnr, true, {
    split = "below",
    win = M.messages_winid,
    height = math.max(1, math.floor(tonumber(chat_opts.input_height) or 3)),
  })
  vim.wo[M.input_winid].winfixheight = true
  M.layout = "side"
end

local function open_float(chat_opts)
  local popup = chat_opts.popup or {}
  local total_width = math.max(20, vim.o.columns)
  local total_height = math.max(10, vim.o.lines - vim.o.cmdheight - 1)
  local width = size_value(popup.width, total_width, math.min(100, total_width - 4), 30)
  local height = size_value(popup.height, total_height, math.min(34, total_height - 4), 10)
  local input_height = math.max(1, tonumber(chat_opts.input_height) or 3)
  local messages_height = math.max(3, height - input_height - 4)
  local row = math.max(0, math.floor((total_height - height) / 2))
  local col = math.max(0, math.floor((total_width - width) / 2))
  local border = popup.border or "rounded"

  M.messages_winid = vim.api.nvim_open_win(M.messages_bufnr, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = messages_height,
    border = border,
    style = "minimal",
    zindex = 50,
  })

  M.input_winid = vim.api.nvim_open_win(M.input_bufnr, true, {
    relative = "editor",
    row = row + messages_height + 2,
    col = col,
    width = width,
    height = input_height,
    border = border,
    style = "minimal",
    zindex = 60,
  })

  M.layout = "float"
end

function M.clear()
  M.history = {}
  M.status = "idle"
  M.status_detail = ""
  session.finish()
  set_messages(render_history())
end

--- Restore a persisted session. `which` is a session file path, or
--- "latest"/nil for the most recent session of the current project.
--- Further messages append to the restored session file.
function M.restore(which)
  local root = context.root(M.target_bufnr or 0)
  local path = which
  if path == nil or path == "latest" then
    local items = session.list(root)
    if vim.tbl_isempty(items) then
      return false, "No saved AI chat sessions for this project."
    end
    path = items[1].path
  end

  local meta, messages = session.load(path)
  if not meta then
    return false, messages
  end

  M.history = messages or {}
  session.resume_file(path, meta.root or root)
  M.status = "idle"
  M.status_detail = ""
  if valid_buffer(M.messages_bufnr) then
    set_messages(render_history())
  end
  return true
end

function M.stop()
  if not M.active then
    set_status("idle")
    return
  end

  M.request_id = M.request_id + 1
  if M.active_stream and type(M.active_stream.cancel) == "function" then
    pcall(M.active_stream.cancel)
  end
  M.active_stream = nil
  if M.active_request and type(M.active_request.kill) == "function" then
    pcall(function()
      M.active_request:kill(15)
    end)
  end
  M.active_request = nil
  M.active = false
  set_status("stopped", "request cancelled")
  if type(M.active_on_event) == "function" then
    pcall(M.active_on_event, { type = "finish", status = "stopped", detail = "request cancelled" })
  end
  M.active_on_event = nil
end

function M.send(text, send_opts)
  send_opts = send_opts or {}
  text = (text or input_text()):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" or M.active then
    return
  end

  -- AIChat has no external on_event; mirror AIQuick by reporting the request
  -- status as a right-corner spinner notification when chat.notify_status is on.
  local on_event = send_opts.on_event
  if not on_event and config.get().chat.notify_status ~= false then
    local progress = require("ai.progress").handle({ title = "AI Chat", message = "thinking…" })
    on_event = function(event)
      if type(event) ~= "table" then
        return
      end
      if event.type == "status" then
        local status_text = "AI " .. (event.status or "working")
        if event.detail and event.detail ~= "" then
          status_text = status_text .. ": " .. event.detail
        end
        progress.report(status_text)
      elseif event.type == "finish" then
        if event.status == "error" then
          progress.finish(
            "failed" .. (event.detail and event.detail ~= "" and (": " .. event.detail) or ""),
            vim.log.levels.ERROR
          )
        elseif event.status == "stopped" then
          progress.finish("stopped", vim.log.levels.WARN)
        else
          progress.finish("done")
        end
      end
    end
  end

  M.active_on_event = on_event

  local function emit(event)
    if type(on_event) ~= "function" then
      return
    end
    pcall(on_event, event)
  end

  local function update_status(status, detail, extra)
    set_status(status, detail, extra)
    emit({
      type = "status",
      status = status or "idle",
      detail = detail or "",
    })
  end

  M.request_id = M.request_id + 1
  local request_id = M.request_id
  M.active = true
  M.active_request = nil
  M.active_stream = nil
  push_history({ role = "user", kind = send_opts.kind, content = text })
  reset_input()
  update_status("thinking", "waiting for model", "## Assistant\n\n...")

  if config.get().chat.tools_enabled ~= false then
    local max_rounds = tonumber(config.get().chat.max_tool_rounds) or 20

    local function stale()
      return request_id ~= M.request_id
    end

    local function finish(status, detail, extra)
      if stale() then
        return
      end
      M.active_request = nil
      M.active_stream = nil
      M.active = false
      update_status(status or "idle", detail, extra)
      emit({
        type = "finish",
        status = status or "idle",
        detail = detail or "",
      })
    end

    local function append_assistant_text(content)
      content = (content or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if content ~= "" then
        push_history({ role = "assistant", content = content })
        emit({
          type = "assistant",
          content = content,
        })
      end
    end

    local function tool_call_content(call)
      return json_encode({
        tool = call.tool,
        args = call.args or {},
      })
    end

    local function execute_calls(calls, index, next_tool_round, done)
      if stale() then
        return
      end

      local call = calls[index]
      if not call then
        done(next_tool_round)
        return
      end

      push_history({
        role = "assistant",
        kind = "tool_call",
        tool = call.tool,
        args = call.args,
        content = call.native and "" or tool_call_content(call),
        native = call.native,
        tool_call_id = call.tool_call_id,
        reasoning_content = call.reasoning_content,
      })
      emit({
        type = "tool_call",
        tool = call.tool,
        args = call.args,
      })
      update_status("running tool", call.tool, tool_running_card(call.tool))

      if call.error then
        append_tool_result(call, call.error)
        emit({
          type = "tool_result",
          tool = call.tool,
          error = true,
          summary = call.error,
        })
        execute_calls(calls, index + 1, next_tool_round + 1, done)
        return
      end

      tools.run(call.tool, call.args, function(tool_err, result)
        if stale() then
          return
        end
        local summary = tool_result_summary(call, tool_err, result)
        append_tool_result(call, tool_err, result)
        emit({
          type = "tool_result",
          tool = call.tool,
          error = tool_err ~= nil,
          summary = summary,
        })
        update_status("thinking", "tool result ready")
        execute_calls(calls, index + 1, next_tool_round + 1, done)
      end, { source = send_opts.source or "chat" })
    end

    local request_next

    local function handle_response(tool_rounds, response, message, no_tools)
      local calls = no_tools and {} or parse_native_tool_calls(message)
      if #calls > 0 then
        append_assistant_text(response)
      elseif not no_tools then
        local text_call = parse_tool_call(response)
        if text_call then
          append_assistant_text(text_call.preface)
          calls = { text_call }
        end
      end

      if #calls == 0 then
        append_assistant_text(response)
        finish("idle")
        return
      end

      if tool_rounds + #calls > max_rounds then
        -- Don't throw away the whole conversation: tell the model the limit
        -- is reached and request one final tool-free answer.
        push_history({
          role = "user",
          kind = "event",
          content = ("The tool round limit (%d) was reached. Answer the user's request now using the information already gathered; do not call any more tools."):format(max_rounds),
        })
        request_next(tool_rounds, true)
        return
      end

      execute_calls(calls, 1, tool_rounds, function(next_tool_round)
        request_next(next_tool_round)
      end)
    end

    request_next = function(tool_rounds, no_tools)
      if stale() then
        return
      end

      local opts = {}
      if not no_tools and config.get().chat.native_tools ~= false then
        opts.tools = tools.openai_tools()
        opts.tool_choice = "auto"
      end

      update_status("thinking", "waiting for model", "## Assistant\n\n...")

      if config.get().provider.stream then
        local assistant = ""
        local reasoning_content = ""
        local stream_calls = {}
        local renderer
        local function clear_renderer()
          if M.active_stream == renderer then
            M.active_stream = nil
          end
        end
        renderer = stream_buffer.new({
          on_update = function(text)
            if stale() then
              renderer.cancel()
              clear_renderer()
              return
            end
            assistant = text
            update_status("streaming", "receiving response", "## Assistant\n\n" .. assistant)
          end,
          on_done = function(text)
            if stale() then
              clear_renderer()
              return
            end
            assistant = text
            clear_renderer()
            M.active_request = nil
            handle_response(tool_rounds, assistant, stream_tool_call_message(stream_calls, reasoning_content ~= "" and reasoning_content or nil), no_tools)
          end,
        })
        M.active_stream = renderer
        local request_handle = client.chat_stream(request_messages(), opts, {
          on_delta = function(delta)
            if stale() then
              renderer.cancel()
              clear_renderer()
              return
            end
            renderer.push(delta)
          end,
          on_reasoning_delta = function(delta)
            if stale() then
              return
            end
            reasoning_content = reasoning_content .. delta
          end,
          on_tool_call_delta = function(deltas)
            if stale() then
              return
            end
            append_stream_tool_call_delta(stream_calls, deltas)
            if assistant == "" and not renderer.has_pending() then
              update_status("streaming", "receiving tool call", "## Assistant\n\n...")
            end
          end,
          on_error = function(err)
            renderer.cancel()
            clear_renderer()
            finish("error", "stream failed", "## Error\n\n" .. err)
          end,
          on_done = function()
            if stale() then
              renderer.cancel()
              clear_renderer()
              return
            end
            renderer.finish()
          end,
        })
        if not stale() and M.active and M.active_stream == renderer then
          M.active_request = request_handle
        end
        return
      end

      opts.stream = false
      M.active_request = client.chat(request_messages(), opts, function(err, response, _, message)
        if stale() then
          return
        end

        M.active_request = nil
        if err then
          finish("error", "model request failed", "## Error\n\n" .. err)
          return
        end

        handle_response(tool_rounds, response, message, no_tools)
      end)
    end

    request_next(0)
    return
  end

  if config.get().provider.stream then
    local assistant = ""
    local renderer
    local function stale()
      return request_id ~= M.request_id
    end
    local function clear_renderer()
      if M.active_stream == renderer then
        M.active_stream = nil
      end
    end
    renderer = stream_buffer.new({
      on_update = function(text)
        if stale() then
          renderer.cancel()
          clear_renderer()
          return
        end
        assistant = text
        update_status("streaming", "receiving response", "## Assistant\n\n" .. assistant)
      end,
      on_done = function(text)
        if stale() then
          clear_renderer()
          return
        end
        assistant = text
        clear_renderer()
        M.active_request = nil
        M.active = false
        push_history({ role = "assistant", content = assistant })
        emit({
          type = "assistant",
          content = assistant,
        })
        update_status("idle")
        emit({
          type = "finish",
          status = "idle",
          detail = "",
        })
      end,
    })
    M.active_stream = renderer
    local request_handle = client.chat_stream(request_messages(), {}, {
      on_delta = function(delta)
        if stale() then
          renderer.cancel()
          clear_renderer()
          return
        end
        renderer.push(delta)
      end,
      on_error = function(err)
        if stale() then
          renderer.cancel()
          clear_renderer()
          return
        end
        renderer.cancel()
        clear_renderer()
        M.active_request = nil
        M.active = false
        update_status("error", "stream failed", "## Error\n\n" .. err)
        emit({
          type = "finish",
          status = "error",
          detail = "stream failed",
        })
      end,
      on_done = function()
        if stale() then
          renderer.cancel()
          clear_renderer()
          return
        end
        renderer.finish()
      end,
    })
    if not stale() and M.active and M.active_stream == renderer then
      M.active_request = request_handle
    end
    return
  end

  M.active_request = client.chat(request_messages(), {}, function(err, response)
    if request_id ~= M.request_id then
      return
    end
    M.active_request = nil
    M.active = false
    if err then
      update_status("error", "model request failed", "## Error\n\n" .. err)
      emit({
        type = "finish",
        status = "error",
        detail = "model request failed",
      })
      return
    end
    push_history({ role = "assistant", content = response })
    emit({
      type = "assistant",
      content = response,
    })
    update_status("idle")
    emit({
      type = "finish",
      status = "idle",
      detail = "",
    })
  end)
end

local function map_input_keys()
  local opts = { buffer = M.input_bufnr, silent = true, nowait = true }
  local close = function()
    vim.cmd.stopinsert()
    M.close()
  end
  local stop = function()
    vim.cmd.stopinsert()
    M.stop()
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
  -- <CR> sends, so provide explicit ways to insert a line break
  vim.keymap.set("i", "<S-CR>", "<CR>", vim.tbl_extend("force", opts, { desc = "AI chat newline" }))
  vim.keymap.set("i", "<C-j>", "<CR>", vim.tbl_extend("force", opts, { desc = "AI chat newline" }))
  vim.keymap.set("n", "<C-l>", M.clear, vim.tbl_extend("force", opts, { desc = "AI chat clear" }))
  vim.keymap.set({ "n", "i" }, "<C-c>", stop, vim.tbl_extend("force", opts, { desc = "AI chat stop" }))
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
  vim.keymap.set("n", "<C-c>", M.stop, vim.tbl_extend("force", opts, { desc = "AI chat stop" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "AI chat close" }))
  vim.keymap.set({ "n", "i" }, "<C-q>", M.close, vim.tbl_extend("force", opts, { desc = "AI chat close" }))
end

function ensure_buffers()
  if not M.target_autocmd then
    M.target_autocmd = true
    vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
      callback = function()
        capture_target()
      end,
    })
  end

  if not valid_buffer(M.messages_bufnr) then
    M.messages_bufnr = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, M.messages_bufnr, "ai://chat")
    set_scratch(M.messages_bufnr, "markdown", false)
    vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
      buffer = M.messages_bufnr,
      callback = stop_insert_mode,
    })
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
  local layout = opts.layout or "side"
  M.start(opts)

  local sessions_cfg = config.get().chat.sessions or {}
  if sessions_cfg.enabled ~= false
    and sessions_cfg.resume == "latest"
    and not M.session_resume_attempted
    and vim.tbl_isempty(M.history) then
    M.session_resume_attempted = true
    pcall(M.restore, "latest")
  end

  if valid_window(M.messages_winid) and valid_window(M.input_winid) then
    if M.layout ~= layout then
      M.close()
    else
      capture_target()
      focus_messages()
      return
    end
  end

  if not valid_buffer(M.messages_bufnr) or not valid_buffer(M.input_bufnr) then
    ensure_buffers()
  end

  if valid_window(M.messages_winid) and valid_window(M.input_winid) then
    capture_target()
    focus_messages()
    return
  end

  local chat_opts = config.get().chat
  M.suspend_target_capture = true
  local ok, err = pcall(function()
    if layout == "float" then
      open_float(chat_opts)
    else
      open_side(chat_opts)
    end
  end)
  M.suspend_target_capture = false
  if not ok then
    error(err)
  end

  configure_chat_windows()

  map_messages_keys()
  map_input_keys()
  set_messages(render_history())
  update_placeholder()
  focus_messages()
end

return M
