local config = require("ai.config")
local context = require("ai.context")
local runner = require("ai.runner")
local target = require("ai.target")
local ui = require("ai.ui")

local M = {}

local registry = {}
local order = {}

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

local symbol_kind_names = vim.lsp and vim.lsp.protocol and vim.lsp.protocol.SymbolKind or {}

local function register(spec)
  registry[spec.name] = spec
  table.insert(order, spec)
end

local function copy_spec(spec)
  return {
    name = spec.name,
    description = spec.description,
    mode = spec.mode,
    input_schema = vim.deepcopy(spec.input_schema),
  }
end

local function normalize_json_schema(value, key)
  if type(value) ~= "table" then
    return value
  end

  if vim.tbl_isempty(value) then
    if key == "properties" or key == "$defs" or key == "definitions" then
      return vim.empty_dict()
    end
    return {}
  end

  local normalized = {}
  for child_key, child_value in pairs(value) do
    normalized[child_key] = normalize_json_schema(child_value, child_key)
  end
  return normalized
end

local function join_lines(lines)
  return table.concat(lines, "\n")
end

local function numbered_lines(lines, start_line)
  local out = {}
  for index, line in ipairs(lines or {}) do
    table.insert(out, ("%d\t%s"):format(start_line + index - 1, line))
  end
  return out
end

local function split_lines(text)
  local lines = vim.split((text or ""):gsub("\r\n", "\n"), "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function number_arg(args, key, default, min_value, max_value)
  local value = tonumber(args[key]) or default
  if min_value then
    value = math.max(min_value, value)
  end
  if max_value then
    value = math.min(max_value, value)
  end
  return math.floor(value)
end

local function string_arg(args, key, default)
  local value = args[key]
  if value == nil or value == "" then
    return default
  end
  return tostring(value)
end

local function bool_arg(args, key, default)
  if args[key] == nil then
    return default
  end
  return not not args[key]
end

local function limit_text(text, max_chars)
  max_chars = tonumber(max_chars) or config.get().project.max_context_chars
  if max_chars > 0 and #text > max_chars then
    return text:sub(1, max_chars) .. "\n[truncated]", true
  end
  return text, false
end

local function option(bufnr, name, default)
  local ok, value = pcall(function()
    return vim.bo[bufnr][name]
  end)
  if not ok then
    return default
  end
  return value
end

local function valid_loaded_buffer(bufnr)
  local err
  bufnr, err = target.resolve_buffer(bufnr)
  if not bufnr then
    return nil, err
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "Invalid buffer: " .. tostring(bufnr)
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, "Buffer is not loaded: " .. tostring(bufnr)
  end
  return bufnr
end

local function target_root()
  local bufnr = target.resolve_buffer()
  return context.root(bufnr or 0)
end

local function buffer_info(bufnr)
  local loaded = vim.api.nvim_buf_is_loaded(bufnr)
  return {
    bufnr = bufnr,
    name = vim.api.nvim_buf_get_name(bufnr),
    filetype = loaded and option(bufnr, "filetype", "") or "",
    listed = loaded and option(bufnr, "buflisted", false) or false,
    loaded = loaded,
    modified = loaded and option(bufnr, "modified", false) or false,
    line_count = loaded and vim.api.nvim_buf_line_count(bufnr) or 0,
  }
end

local function window_info(winid)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local pos = vim.api.nvim_win_get_position(winid)
  local info = {
    winid = winid,
    current = winid == vim.api.nvim_get_current_win(),
    bufnr = bufnr,
    name = vim.api.nvim_buf_get_name(bufnr),
    filetype = option(bufnr, "filetype", ""),
    width = vim.api.nvim_win_get_width(winid),
    height = vim.api.nvim_win_get_height(winid),
    row = pos[1],
    col = pos[2],
  }

  pcall(vim.api.nvim_win_call, winid, function()
    info.cursor = vim.api.nvim_win_get_cursor(winid)
    info.topline = vim.fn.line("w0")
    info.botline = vim.fn.line("w$")
  end)

  return info
end

local function cursor_for_buffer(bufnr)
  local winid = target.resolve_window()
  if winid and vim.api.nvim_win_get_buf(winid) == bufnr then
    return vim.api.nvim_win_get_cursor(winid), winid
  end

  if vim.api.nvim_get_current_buf() == bufnr then
    return vim.api.nvim_win_get_cursor(0), vim.api.nvim_get_current_win()
  end

  return nil, nil
end

local function buffer_line_text(bufnr, line)
  if not line then
    return nil
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, line - 1, line, false)
  if not ok or not lines or not lines[1] then
    return nil
  end
  return lines[1]
end

local function attach_cursor_info(info, cursor, winid)
  if not cursor then
    return info
  end

  info.cursor = cursor
  info.cursor_winid = winid
  info.cursor_line_text = buffer_line_text(info.bufnr, cursor[1])
  return info
end

local function diagnostic_item(bufnr, diagnostic)
  return {
    bufnr = bufnr,
    path = vim.api.nvim_buf_get_name(bufnr),
    lnum = (diagnostic.lnum or 0) + 1,
    col = (diagnostic.col or 0) + 1,
    end_lnum = diagnostic.end_lnum and diagnostic.end_lnum + 1 or nil,
    end_col = diagnostic.end_col and diagnostic.end_col + 1 or nil,
    severity = severity_names[diagnostic.severity] or tostring(diagnostic.severity or ""),
    source = diagnostic.source,
    code = diagnostic.code,
    message = diagnostic.message or "",
  }
end

local function list_entry(item)
  local path = item.filename or ""
  if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
    path = vim.api.nvim_buf_get_name(item.bufnr)
  end
  return {
    bufnr = item.bufnr,
    path = path,
    lnum = item.lnum or 0,
    col = item.col or 0,
    end_lnum = item.end_lnum,
    end_col = item.end_col,
    type = item.type,
    valid = item.valid,
    text = item.text or "",
  }
end

local function project_path(path)
  if type(path) ~= "string" or path == "" then
    return nil, "path is required"
  end

  local root = vim.fn.fnamemodify(target_root(), ":p"):gsub("/$", "")
  root = vim.fs.normalize(root)
  local expanded = vim.fn.expand(path)
  local resolved = expanded
  if not resolved:match("^/") then
    resolved = root .. "/" .. resolved
  end
  resolved = vim.fs.normalize(vim.fn.fnamemodify(resolved, ":p"))

  if resolved ~= root and resolved:sub(1, #root + 1) ~= root .. "/" then
    return nil, "Refusing to read outside project root: " .. resolved
  end

  return resolved, root
end

local function json_encode(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded
  end
  return vim.inspect(value)
end

local function buffer_uri(bufnr)
  if vim.uri_from_bufnr then
    return vim.uri_from_bufnr(bufnr)
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return vim.uri_from_fname(name)
end

local function range_info(range)
  if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
    return nil
  end
  return {
    start_line = (range.start.line or 0) + 1,
    start_col = (range.start.character or 0) + 1,
    end_line = (range["end"].line or range.start.line or 0) + 1,
    end_col = (range["end"].character or range.start.character or 0) + 1,
  }
end

local function path_from_uri(uri)
  if type(uri) ~= "string" or uri == "" then
    return ""
  end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if ok then
    return path
  end
  return uri
end

local function line_slice(lines, line, context_lines)
  if vim.tbl_isempty(lines) then
    return 1, 1, {}
  end
  line = math.max(1, math.min(tonumber(line) or 1, #lines))
  context_lines = math.max(0, tonumber(context_lines) or 3)
  local start_line = math.max(1, line - context_lines)
  local end_line = math.min(#lines, line + context_lines)
  return start_line, end_line, vim.list_slice(lines, start_line, end_line)
end

local function snippet_for_path(path, line, context_lines, max_chars)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local lines
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  elseif vim.fn.filereadable(path) == 1 then
    local ok, file_lines = pcall(vim.fn.readfile, path)
    if ok then
      lines = file_lines
    end
  end

  if not lines then
    return nil
  end

  local start_line, end_line, selected = line_slice(lines, line, context_lines)
  local text, truncated = limit_text(join_lines(selected), max_chars or 4000)
  return {
    start_line = start_line,
    end_line = end_line,
    text = text,
    truncated = truncated,
  }
end

local function open_project_file(args)
  local path, root = project_path(args.path)
  if not path then
    return nil, root
  end
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "File is not readable: " .. path
  end

  local open_mode = string_arg(args, "open_mode", "current")
  local command_by_mode = {
    current = "edit",
    split = "split",
    vsplit = "vsplit",
    tab = "tabedit",
  }
  local command = command_by_mode[open_mode]
  if not command then
    return nil, "open_mode must be one of: current, split, vsplit, tab"
  end

  local winid = target.resolve_window()
  if winid and vim.api.nvim_win_is_valid(winid) and open_mode ~= "tab" then
    vim.api.nvim_set_current_win(winid)
  end

  local ok, err = pcall(vim.cmd, command .. " " .. vim.fn.fnameescape(path))
  if not ok then
    return nil, tostring(err)
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local line = number_arg(args, "line", 1, 1, line_count)
  local line_text = buffer_line_text(bufnr, line) or ""
  local col = number_arg(args, "col", 1, 1, math.max(1, #line_text + 1))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, col - 1 })
  target.capture_current()

  local info = buffer_info(bufnr)
  attach_cursor_info(info, vim.api.nvim_win_get_cursor(0), vim.api.nvim_get_current_win())
  return {
    root = root,
    path = path,
    open_mode = open_mode,
    buffer = info,
  }
end

local function cursor_position(args, bufnr)
  local cursor = cursor_for_buffer(bufnr)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local line = number_arg(args, "line", cursor and cursor[1] or 1, 1, line_count)
  local column = number_arg(args, "column", cursor and cursor[2] + 1 or 1, 1, 1000000)
  return line, column
end

local function position_params(args, bufnr)
  local line, column = cursor_position(args, bufnr)
  return {
    textDocument = { uri = buffer_uri(bufnr) },
    position = {
      line = line - 1,
      character = column - 1,
    },
  }, line, column
end

local function range_params(args, bufnr)
  local line, column = cursor_position(args, bufnr)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local start_line = number_arg(args, "start_line", line, 1, line_count)
  local end_line = number_arg(args, "end_line", start_line, start_line, line_count)
  local start_col = number_arg(args, "start_column", column, 1, 1000000)
  local end_col = number_arg(args, "end_column", start_col, start_col, 1000000)
  return {
    textDocument = { uri = buffer_uri(bufnr) },
    range = {
      start = { line = start_line - 1, character = start_col - 1 },
      ["end"] = { line = end_line - 1, character = end_col - 1 },
    },
  }, start_line, start_col, end_line, end_col
end

local function language_clients(bufnr, method)
  if not vim.lsp or type(vim.lsp.buf_request_all) ~= "function" then
    return {}
  end

  local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
  if type(get_clients) ~= "function" then
    return {}
  end

  local ok, clients = pcall(get_clients, { bufnr = bufnr })
  if not ok or type(clients) ~= "table" then
    return {}
  end

  local supported = {}
  for _, client in ipairs(clients) do
    if type(client.supports_method) ~= "function" then
      table.insert(supported, client)
    else
      local supported_ok, has_method = pcall(function()
        return client:supports_method(method, { bufnr = bufnr })
      end)
      if supported_ok and has_method then
        table.insert(supported, client)
      end
    end
  end
  return supported
end

local function language_unavailable(bufnr)
  return {
    available = false,
    bufnr = bufnr,
    path = vim.api.nvim_buf_get_name(bufnr),
    filetype = option(bufnr, "filetype", ""),
    message = "No language intelligence is available for the target buffer.",
  }
end

local function language_request(bufnr, method, params, cb, mapper)
  if vim.tbl_isempty(language_clients(bufnr, method)) then
    cb(nil, language_unavailable(bufnr))
    return
  end

  local done = false
  local function finish(err, result)
    if done then
      return
    end
    done = true
    cb(err, result)
  end

  vim.defer_fn(function()
    finish(nil, {
      available = false,
      bufnr = bufnr,
      path = vim.api.nvim_buf_get_name(bufnr),
      filetype = option(bufnr, "filetype", ""),
      message = "Language intelligence request timed out.",
    })
  end, 5000)

  local ok, request_err = pcall(vim.lsp.buf_request_all, bufnr, method, params, function(responses)
    local mapper_ok, result = pcall(mapper, responses or {})
    if not mapper_ok then
      finish(result)
      return
    end
    finish(nil, result)
  end)

  if not ok then
    finish("Language intelligence request failed: " .. tostring(request_err))
  end
end

local function markdown_from_language_contents(contents)
  local lines = {}
  if vim.lsp and vim.lsp.util and type(vim.lsp.util.convert_input_to_markdown_lines) == "function" then
    local ok, converted = pcall(vim.lsp.util.convert_input_to_markdown_lines, contents)
    if ok and type(converted) == "table" then
      lines = converted
    end
  end

  if vim.tbl_isempty(lines) then
    if type(contents) == "string" then
      lines = split_lines(contents)
    elseif type(contents) == "table" and type(contents.value) == "string" then
      lines = split_lines(contents.value)
    elseif type(contents) == "table" then
      for _, item in ipairs(contents) do
        if type(item) == "string" then
          vim.list_extend(lines, split_lines(item))
        elseif type(item) == "table" and type(item.value) == "string" then
          vim.list_extend(lines, split_lines(item.value))
        end
      end
    end
  end

  local compact = {}
  for _, line in ipairs(lines) do
    if line ~= "" or not vim.tbl_isempty(compact) then
      table.insert(compact, line)
    end
  end
  while #compact > 0 and compact[#compact] == "" do
    table.remove(compact, #compact)
  end
  return join_lines(compact)
end

local function language_errors(responses)
  local errors = {}
  for _, response in pairs(responses) do
    if response.err then
      table.insert(errors, tostring(response.err.message or response.err))
    end
  end
  return errors
end

local function location_item(location, opts)
  opts = opts or {}
  local uri = location.uri or location.targetUri
  local range = location.range or location.targetSelectionRange or location.targetRange
  if not uri or not range then
    return nil
  end

  local path = path_from_uri(uri)
  local position = range_info(range)
  if not position then
    return nil
  end

  local item = {
    path = path,
    uri = uri,
    lnum = position.start_line,
    col = position.start_col,
    end_lnum = position.end_line,
    end_col = position.end_col,
  }
  if opts.include_snippet ~= false then
    item.snippet = snippet_for_path(path, item.lnum, opts.context_lines, opts.max_chars)
  end
  return item
end

local function collect_location_items(responses, opts)
  local items = {}
  local total = 0
  for _, response in pairs(responses) do
    local result = response.result
    if type(result) == "table" then
      if result.uri or result.targetUri then
        result = { result }
      end
      for _, location in ipairs(result) do
        local item = location_item(location, opts)
        if item then
          total = total + 1
          if #items < opts.max_items then
            table.insert(items, item)
          end
        end
      end
    end
  end
  return items, total
end

local function symbol_kind_name(kind)
  return symbol_kind_names[kind] or tostring(kind or "")
end

local function symbol_item(symbol, fallback_uri, depth)
  local location = symbol.location or {}
  local uri = location.uri or fallback_uri
  local range = symbol.selectionRange or symbol.range or location.range
  local position = range_info(range)
  return {
    name = symbol.name or "",
    detail = symbol.detail,
    kind = symbol_kind_name(symbol.kind),
    container = symbol.containerName,
    path = path_from_uri(uri),
    lnum = position and position.start_line or nil,
    col = position and position.start_col or nil,
    end_lnum = position and position.end_line or nil,
    end_col = position and position.end_col or nil,
    depth = depth or 0,
  }
end

local function flatten_symbols(symbols, fallback_uri, items, max_items, depth)
  for _, symbol in ipairs(symbols or {}) do
    if #items >= max_items then
      return
    end
    table.insert(items, symbol_item(symbol, fallback_uri, depth))
    if type(symbol.children) == "table" then
      flatten_symbols(symbol.children, fallback_uri, items, max_items, (depth or 0) + 1)
    end
  end
end

local function count_symbols(symbols)
  local count = 0
  for _, symbol in ipairs(symbols or {}) do
    count = count + 1
    if type(symbol.children) == "table" then
      count = count + count_symbols(symbol.children)
    end
  end
  return count
end

local function code_action_item(action, index)
  local command = action.command
  if type(command) == "table" then
    command = command.title or command.command
  end

  return {
    index = index,
    title = action.title or command or "",
    kind = action.kind,
    preferred = action.isPreferred or nil,
    disabled = action.disabled and action.disabled.reason or nil,
    has_edit = action.edit ~= nil,
    command = type(command) == "string" and command or nil,
  }
end

local function replaced_pending_note(replaced)
  if not replaced then
    return ""
  end
  return (" Note: this discarded a previous pending %s preview that was never applied."):format(replaced)
end

local function preview_buffer_replace(args, opts)
  opts = opts or {}
  if type(args.replacement) ~= "string" then
    return nil, "replacement is required"
  end

  local bufnr, err = valid_loaded_buffer(args.bufnr)
  if not bufnr then
    return nil, err
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if args.start_line == nil then
    return nil, "start_line is required"
  end
  if args.end_line == nil then
    return nil, "end_line is required"
  end

  local start_line = number_arg(args, "start_line", 1, 1, line_count)
  local end_line = number_arg(args, "end_line", line_count, start_line, line_count)
  local original_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local path = vim.api.nvim_buf_get_name(bufnr)

  local replaced_action = ui.pending_action()
  local replaced = replaced_action and replaced_action.kind or nil

  local auto = ui.preview_edit({
    bufnr = bufnr,
    path = path,
    line1 = start_line,
    line2 = end_line,
    original_lines = original_lines,
    replacement = args.replacement,
    title = string_arg(args, "title", "tool-preview-edit"),
    source = opts.source,
  })

  local result = {
    action = "buffer_replace",
    bufnr = bufnr,
    path = path,
    start_line = start_line,
    end_line = end_line,
    original_line_count = #original_lines,
    replacement_line_count = #split_lines(args.replacement),
    replaced_pending = replaced,
  }

  if auto then
    if auto.err then
      result.status = "apply_failed"
      result.auto_applied = false
      result.error = auto.err
      result.message = "safety.auto_apply_edits is enabled but applying failed: " .. auto.err
      return result
    end
    result.status = "applied"
    result.auto_applied = true
    result.written = auto.info and auto.info.written or false
    result.message = (auto.info and auto.info.message or "The edit was applied.") .. replaced_pending_note(replaced)
    return result
  end

  if not ui.pending_edit then
    return nil, "Edit preview did not create a pending edit."
  end

  result.status = "previewed"
  result.auto_applied = false
  result.message = "Inspect the preview and run :AIApply to apply or :AIReject to discard." .. replaced_pending_note(replaced)
  return result
end

local function complete_sync(fn)
  return function(args, cb, opts)
    local ok, result, err = pcall(fn, args or {}, opts or {})
    if not ok then
      cb(result)
      return
    end
    cb(err, result)
  end
end

register({
  name = "nvim_editor_state",
  mode = "read",
  description = "Return editor state, including actual focused buffer, target editor buffer, project root, and visible windows.",
  input_schema = {
    type = "object",
    properties = {},
    additionalProperties = false,
  },
  run = complete_sync(function()
    local windows = {}
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(winid) then
        table.insert(windows, window_info(winid))
      end
    end

    local target_bufnr = target.resolve_buffer()
    local target_cursor, target_winid
    local target_buffer
    if target_bufnr then
      target_cursor, target_winid = cursor_for_buffer(target_bufnr)
      target_buffer = buffer_info(target_bufnr)
      attach_cursor_info(target_buffer, target_cursor, target_winid)
      target_buffer.root = context.root(target_bufnr)
    end

    local current_winid = vim.api.nvim_get_current_win()
    local current_buffer = buffer_info(vim.api.nvim_get_current_buf())
    attach_cursor_info(current_buffer, vim.api.nvim_win_get_cursor(current_winid), current_winid)

    return {
      cwd = vim.fn.getcwd(),
      root = target_bufnr and context.root(target_bufnr) or context.root(0),
      mode = vim.api.nvim_get_mode().mode,
      current_winid = current_winid,
      current_buffer = current_buffer,
      target_winid = target_winid,
      target_buffer = target_buffer,
      windows = windows,
    }
  end),
})

register({
  name = "nvim_current_buffer",
  mode = "read",
  description = "Return metadata for the target editor buffer, including path, filetype, cursor, modified flag, and line count.",
  input_schema = {
    type = "object",
    properties = {},
    additionalProperties = false,
  },
  run = complete_sync(function()
    local bufnr, err = valid_loaded_buffer()
    if not bufnr then
      return nil, err
    end
    local info = buffer_info(bufnr)
    local cursor, winid = cursor_for_buffer(bufnr)
    attach_cursor_info(info, cursor, winid)
    info.root = context.root(bufnr)
    return info
  end),
})

register({
  name = "nvim_list_buffers",
  mode = "read",
  description = "List loaded buffers with metadata useful for choosing what to inspect next.",
  input_schema = {
    type = "object",
    properties = {
      listed_only = { type = "boolean", description = "Only include listed buffers. Defaults to true." },
      max_items = { type = "integer", description = "Maximum number of buffers to return. Defaults to 80." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    local listed_only = bool_arg(args, "listed_only", true)
    local max_items = number_arg(args, "max_items", 80, 1, 500)
    local items = {}
    local total = 0

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        local info = buffer_info(bufnr)
        if not listed_only or info.listed then
          total = total + 1
          if #items < max_items then
            table.insert(items, info)
          end
        end
      end
    end

    return {
      items = items,
      total = total,
      truncated = total > #items,
    }
  end),
})

register({
  name = "nvim_read_buffer",
  mode = "read",
  description = "Read text from a loaded buffer by 1-based line range. Each output line is prefixed with its line number and a tab.",
  input_schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer", description = "Buffer number. Defaults to the target editor buffer." },
      start_line = { type = "integer", description = "1-based inclusive start line. Defaults to 1." },
      end_line = { type = "integer", description = "1-based inclusive end line. Defaults to the last line." },
      max_chars = { type = "integer", description = "Maximum returned text length. Defaults to project.max_context_chars." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    local bufnr, err = valid_loaded_buffer(args.bufnr)
    if not bufnr then
      return nil, err
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local start_line = number_arg(args, "start_line", 1, 1, line_count)
    local end_line = number_arg(args, "end_line", line_count, start_line, line_count)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    local text, truncated = limit_text(join_lines(numbered_lines(lines, start_line)), args.max_chars)

    return {
      bufnr = bufnr,
      path = vim.api.nvim_buf_get_name(bufnr),
      filetype = option(bufnr, "filetype", ""),
      start_line = start_line,
      end_line = end_line,
      line_count = line_count,
      text = text,
      truncated = truncated,
    }
  end),
})

register({
  name = "nvim_current_selection",
  mode = "read",
  description = "Read the last visual selection marks from the target editor buffer when they are available.",
  input_schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer", description = "Buffer number. Defaults to the target editor buffer." },
      max_chars = { type = "integer", description = "Maximum returned text length. Defaults to project.max_context_chars." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    local bufnr, err = valid_loaded_buffer(args.bufnr)
    if not bufnr then
      return nil, err
    end
    local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
    local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")
    if start_mark[1] == 0 or end_mark[1] == 0 then
      return {
        available = false,
        message = "No visual selection marks are available.",
      }
    end

    local start_line = math.min(start_mark[1], end_mark[1])
    local end_line = math.max(start_mark[1], end_mark[1])
    local text, truncated = limit_text(context.range_text(bufnr, start_line, end_line), args.max_chars)

    return {
      available = true,
      bufnr = bufnr,
      path = vim.api.nvim_buf_get_name(bufnr),
      filetype = option(bufnr, "filetype", ""),
      start_line = start_line,
      end_line = end_line,
      text = text,
      truncated = truncated,
    }
  end),
})

register({
  name = "nvim_read_file",
  mode = "read",
  description = "Read a file under the current project root. Relative paths are resolved from the root. Each output line is prefixed with its line number and a tab.",
  input_schema = {
    type = "object",
    required = { "path" },
    properties = {
      path = { type = "string", description = "Project-relative path, or an absolute path inside the project root." },
      max_chars = { type = "integer", description = "Maximum returned text length. Defaults to project.max_context_chars." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    local path, root = project_path(args.path)
    if not path then
      return nil, root
    end
    if vim.fn.filereadable(path) ~= 1 then
      return nil, "File is not readable: " .. path
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
      return nil, "Failed to read file: " .. path
    end

    local text, truncated = limit_text(join_lines(numbered_lines(lines, 1)), args.max_chars)
    return {
      root = root,
      path = path,
      line_count = #lines,
      text = text,
      truncated = truncated,
    }
  end),
})

register({
  name = "nvim_open_file",
  mode = "editor",
  description = "Open an existing project file in Neovim and make it the target editor buffer. It does not modify the file.",
  input_schema = {
    type = "object",
    required = { "path" },
    properties = {
      path = { type = "string", description = "Project-relative path, or an absolute path inside the project root." },
      line = { type = "integer", description = "1-based line to place the cursor on. Defaults to 1." },
      col = { type = "integer", description = "1-based column to place the cursor on. Defaults to 1." },
      open_mode = { type = "string", enum = { "current", "split", "vsplit", "tab" }, description = "How to open the file. Defaults to current." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    return open_project_file(args)
  end),
})

register({
  name = "nvim_symbol_hover",
  mode = "read",
  description = "Return language-aware documentation for the symbol at a target buffer position.",
  input_schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer", description = "Buffer number. Defaults to the target editor buffer." },
      line = { type = "integer", description = "1-based line. Defaults to the target cursor line." },
      column = { type = "integer", description = "1-based column. Defaults to the target cursor column." },
      max_chars = { type = "integer", description = "Maximum returned text length. Defaults to project.max_context_chars." },
    },
    additionalProperties = false,
  },
  run = function(args, cb)
    local bufnr, err = valid_loaded_buffer(args.bufnr)
    if not bufnr then
      cb(err)
      return
    end

    local params, line, column = position_params(args, bufnr)
    language_request(bufnr, "textDocument/hover", params, cb, function(responses)
      local parts = {}
      for _, response in pairs(responses) do
        local result = response.result
        if type(result) == "table" and result.contents then
          local text = markdown_from_language_contents(result.contents)
          if text ~= "" then
            table.insert(parts, text)
          end
        end
      end

      local text, truncated = limit_text(table.concat(parts, "\n\n"), args.max_chars)
      return {
        available = true,
        bufnr = bufnr,
        path = vim.api.nvim_buf_get_name(bufnr),
        filetype = option(bufnr, "filetype", ""),
        line = line,
        column = column,
        text = text,
        truncated = truncated,
        errors = language_errors(responses),
      }
    end)
  end,
})

register({
  name = "nvim_symbol_definition",
  mode = "read",
  description = "Find definitions for the symbol at a target buffer position and return locations with nearby code.",
  input_schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer", description = "Buffer number. Defaults to the target editor buffer." },
      line = { type = "integer", description = "1-based line. Defaults to the target cursor line." },
      column = { type = "integer", description = "1-based column. Defaults to the target cursor column." },
      max_items = { type = "integer", description = "Maximum locations to return. Defaults to 20." },
      context_lines = { type = "integer", description = "Nearby lines to include around each location. Defaults to 3." },
      max_chars = { type = "integer", description = "Maximum snippet length per location. Defaults to 4000." },
    },
    additionalProperties = false,
  },
  run = function(args, cb)
    local bufnr, err = valid_loaded_buffer(args.bufnr)
    if not bufnr then
      cb(err)
      return
    end

    local max_items = number_arg(args, "max_items", 20, 1, 200)
    local params, line, column = position_params(args, bufnr)
    language_request(bufnr, "textDocument/definition", params, cb, function(responses)
      local items, total = collect_location_items(responses, {
        max_items = max_items,
        context_lines = number_arg(args, "context_lines", 3, 0, 20),
        max_chars = args.max_chars,
      })
      return {
        available = true,
        bufnr = bufnr,
        path = vim.api.nvim_buf_get_name(bufnr),
        line = line,
        column = column,
        items = items,
        total = total,
        truncated = total > #items,
        errors = language_errors(responses),
      }
    end)
  end,
})

register({
  name = "nvim_symbol_references",
  mode = "read",
  description = "Find references for the symbol at a target buffer position and return locations with nearby code.",
  input_schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer", description = "Buffer number. Defaults to the target editor buffer." },
      line = { type = "integer", description = "1-based line. Defaults to the target cursor line." },
      column = { type = "integer", description = "1-based column. Defaults to the target cursor column." },
      include_declaration = { type = "boolean", description = "Include the declaration location. Defaults to true." },
      max_items = { type = "integer", description = "Maximum locations to return. Defaults to 80." },
      context_lines = { type = "integer", description = "Nearby lines to include around each location. Defaults to 2." },
      max_chars = { type = "integer", description = "Maximum snippet length per location. Defaults to 4000." },
    },
    additionalProperties = false,
  },
  run = function(args, cb)
    local bufnr, err = valid_loaded_buffer(args.bufnr)
    if not bufnr then
      cb(err)
      return
    end

    local max_items = number_arg(args, "max_items", 80, 1, 500)
    local params, line, column = position_params(args, bufnr)
    params.context = { includeDeclaration = bool_arg(args, "include_declaration", true) }
    language_request(bufnr, "textDocument/references", params, cb, function(responses)
      local items, total = collect_location_items(responses, {
        max_items = max_items,
        context_lines = number_arg(args, "context_lines", 2, 0, 20),
        max_chars = args.max_chars,
      })
      return {
        available = true,
        bufnr = bufnr,
        path = vim.api.nvim_buf_get_name(bufnr),
        line = line,
        column = column,
        items = items,
        total = total,
        truncated = total > #items,
        errors = language_errors(responses),
      }
    end)
  end,
})

register({
  name = "nvim_document_symbols",
  mode = "read",
  description = "Return the symbol outline for the target buffer.",
  input_schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer", description = "Buffer number. Defaults to the target editor buffer." },
      max_items = { type = "integer", description = "Maximum symbols to return. Defaults to 200." },
    },
    additionalProperties = false,
  },
  run = function(args, cb)
    local bufnr, err = valid_loaded_buffer(args.bufnr)
    if not bufnr then
      cb(err)
      return
    end

    local uri = buffer_uri(bufnr)
    local max_items = number_arg(args, "max_items", 200, 1, 2000)
    language_request(bufnr, "textDocument/documentSymbol", { textDocument = { uri = uri } }, cb, function(responses)
      local items = {}
      local total = 0
      for _, response in pairs(responses) do
        local result = response.result
        if type(result) == "table" then
          total = total + count_symbols(result)
          flatten_symbols(result, uri, items, max_items, 0)
        end
      end
      return {
        available = true,
        bufnr = bufnr,
        path = vim.api.nvim_buf_get_name(bufnr),
        items = items,
        total = total,
        truncated = #items >= max_items,
        errors = language_errors(responses),
      }
    end)
  end,
})

register({
  name = "nvim_workspace_symbols",
  mode = "read",
  description = "Search language-aware workspace symbols by query.",
  input_schema = {
    type = "object",
    required = { "query" },
    properties = {
      query = { type = "string", description = "Symbol search query." },
      bufnr = { type = "integer", description = "Buffer number used to choose the project context. Defaults to the target editor buffer." },
      max_items = { type = "integer", description = "Maximum symbols to return. Defaults to 80." },
    },
    additionalProperties = false,
  },
  run = function(args, cb)
    local query = string_arg(args, "query", "")
    if query == "" then
      cb("query is required")
      return
    end

    local bufnr, err = valid_loaded_buffer(args.bufnr)
    if not bufnr then
      cb(err)
      return
    end

    local max_items = number_arg(args, "max_items", 80, 1, 500)
    language_request(bufnr, "workspace/symbol", { query = query }, cb, function(responses)
      local items = {}
      local total = 0
      for _, response in pairs(responses) do
        local result = response.result
        if type(result) == "table" then
          for _, symbol in ipairs(result) do
            total = total + 1
            if #items < max_items then
              table.insert(items, symbol_item(symbol, symbol.location and symbol.location.uri or symbol.uri, 0))
            end
          end
        end
      end
      return {
        available = true,
        bufnr = bufnr,
        query = query,
        items = items,
        total = total,
        truncated = total > #items,
        errors = language_errors(responses),
      }
    end)
  end,
})

register({
  name = "nvim_code_actions",
  mode = "read",
  description = "List code actions available for a target buffer range. This only reports actions; it does not apply them.",
  input_schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer", description = "Buffer number. Defaults to the target editor buffer." },
      line = { type = "integer", description = "1-based cursor line used when start_line is not provided." },
      column = { type = "integer", description = "1-based cursor column used when start_column is not provided." },
      start_line = { type = "integer", description = "1-based start line. Defaults to cursor line." },
      start_column = { type = "integer", description = "1-based start column. Defaults to cursor column." },
      end_line = { type = "integer", description = "1-based end line. Defaults to start_line." },
      end_column = { type = "integer", description = "1-based end column. Defaults to start_column." },
      only = { type = "array", items = { type = "string" }, description = "Optional action categories to include." },
      max_items = { type = "integer", description = "Maximum actions to return. Defaults to 40." },
    },
    additionalProperties = false,
  },
  run = function(args, cb)
    local bufnr, err = valid_loaded_buffer(args.bufnr)
    if not bufnr then
      cb(err)
      return
    end

    local params, start_line, start_col, end_line, end_col = range_params(args, bufnr)
    local diagnostics = {}
    local diagnostic_from = vim.lsp and vim.lsp.diagnostic and vim.lsp.diagnostic.from
    if type(diagnostic_from) == "function" then
      for _, diagnostic in ipairs(vim.diagnostic.get(bufnr, { lnum = start_line - 1 })) do
        local ok, converted = pcall(diagnostic_from, diagnostic)
        if ok and converted then
          table.insert(diagnostics, converted)
        end
      end
    end
    params.context = {
      diagnostics = diagnostics,
      only = type(args.only) == "table" and args.only or nil,
    }

    local max_items = number_arg(args, "max_items", 40, 1, 200)
    language_request(bufnr, "textDocument/codeAction", params, cb, function(responses)
      local items = {}
      local total = 0
      for _, response in pairs(responses) do
        local result = response.result
        if type(result) == "table" then
          for _, action in ipairs(result) do
            total = total + 1
            if #items < max_items then
              table.insert(items, code_action_item(action, total))
            end
          end
        end
      end
      return {
        available = true,
        bufnr = bufnr,
        path = vim.api.nvim_buf_get_name(bufnr),
        range = {
          start_line = start_line,
          start_col = start_col,
          end_line = end_line,
          end_col = end_col,
        },
        items = items,
        total = total,
        truncated = total > #items,
        message = "These actions were not applied.",
        errors = language_errors(responses),
      }
    end)
  end,
})

register({
  name = "nvim_diagnostics",
  mode = "read",
  description = "Return diagnostics from the target editor buffer or all loaded buffers.",
  input_schema = {
    type = "object",
    properties = {
      scope = { type = "string", enum = { "current", "all" }, description = "Diagnostic scope. Defaults to current." },
      bufnr = { type = "integer", description = "Buffer number for current scope. Defaults to the target editor buffer." },
      max_items = { type = "integer", description = "Maximum diagnostics to return. Defaults to 120." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    local scope = string_arg(args, "scope", "current")
    local max_items = number_arg(args, "max_items", 120, 1, 1000)
    local items = {}
    local total = 0

    local buffers = {}
    if scope == "all" then
      buffers = vim.api.nvim_list_bufs()
    else
      local bufnr, err = valid_loaded_buffer(args.bufnr)
      if not bufnr then
        return nil, err
      end
      buffers = { bufnr }
    end

    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
          total = total + 1
          if #items < max_items then
            table.insert(items, diagnostic_item(bufnr, diagnostic))
          end
        end
      end
    end

    return {
      scope = scope,
      items = items,
      total = total,
      truncated = total > #items,
    }
  end),
})

register({
  name = "nvim_quickfix",
  mode = "read",
  description = "Return entries from the global quickfix list.",
  input_schema = {
    type = "object",
    properties = {
      max_items = { type = "integer", description = "Maximum entries to return. Defaults to 120." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    local max_items = number_arg(args, "max_items", 120, 1, 1000)
    local qf = vim.fn.getqflist()
    local items = {}
    for index, item in ipairs(qf) do
      if index > max_items then
        break
      end
      table.insert(items, list_entry(item))
    end

    return {
      items = items,
      total = #qf,
      truncated = #qf > #items,
    }
  end),
})

register({
  name = "nvim_location_list",
  mode = "read",
  description = "Return entries from the location list for the current window.",
  input_schema = {
    type = "object",
    properties = {
      max_items = { type = "integer", description = "Maximum entries to return. Defaults to 120." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    local max_items = number_arg(args, "max_items", 120, 1, 1000)
    local loclist = vim.fn.getloclist(0)
    local items = {}
    for index, item in ipairs(loclist) do
      if index > max_items then
        break
      end
      table.insert(items, list_entry(item))
    end

    return {
      winid = vim.api.nvim_get_current_win(),
      items = items,
      total = #loclist,
      truncated = #loclist > #items,
    }
  end),
})

register({
  name = "nvim_git_diff",
  mode = "read",
  description = "Return git status, unstaged diff, and staged diff for the current project root.",
  input_schema = {
    type = "object",
    properties = {
      max_chars = { type = "integer", description = "Maximum returned text length. Defaults to project.max_context_chars." },
    },
    additionalProperties = false,
  },
  run = function(args, cb)
    local root = target_root()
    context.git_diff(function(err, text)
      if err then
        cb(err)
        return
      end
      local limited, truncated = limit_text(text or "", args.max_chars)
      cb(nil, {
        root = root,
        text = limited,
        truncated = truncated,
      })
    end, root)
  end,
})

register({
  name = "nvim_project_files",
  mode = "read",
  description = "List project files using ripgrep's file walker from the current project root.",
  input_schema = {
    type = "object",
    properties = {
      max_items = { type = "integer", description = "Maximum files to return. Defaults to project.max_file_list." },
    },
    additionalProperties = false,
  },
  run = function(args, cb)
    local root = target_root()
    local max_items = number_arg(args or {}, "max_items", config.get().project.max_file_list, 1, 2000)
    context.system_text({ "rg", "--files" }, { cwd = root }, function(err, files)
      if err then
        cb(err)
        return
      end
      local all = vim.split(files or "", "\n", { plain = true, trimempty = true })
      cb(nil, {
        root = root,
        files = vim.list_slice(all, 1, max_items),
        total = #all,
        truncated = #all > max_items,
      })
    end)
  end,
})

register({
  name = "nvim_project_search",
  mode = "read",
  description = "Search project context for a query using the same rg-backed context path as :AISearchProject.",
  input_schema = {
    type = "object",
    required = { "query" },
    properties = {
      query = { type = "string", description = "Search query or task text." },
      max_chars = { type = "integer", description = "Maximum returned text length. Defaults to project.max_context_chars." },
    },
    additionalProperties = false,
  },
  run = function(args, cb)
    local query = string_arg(args or {}, "query", "")
    if query == "" then
      cb("query is required")
      return
    end
    local root = target_root()
    context.project_context(query, function(err, project_context)
      if err then
        cb(err)
        return
      end
      local text, truncated = limit_text(project_context or "", args.max_chars)
      cb(nil, {
        root = root,
        query = query,
        text = text,
        truncated = truncated,
      })
    end, root)
  end,
})

register({
  name = "nvim_preview_patch",
  mode = "preview",
  description = "Preview a unified diff in ai.nvim. It does not apply the patch; the user must run :AIApply.",
  input_schema = {
    type = "object",
    required = { "patch" },
    properties = {
      patch = { type = "string", description = "Unified diff to preview." },
      title = { type = "string", description = "Optional preview title." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args, opts)
    opts = opts or {}
    local patch_text = string_arg(args, "patch", "")
    if patch_text == "" then
      return nil, "patch is required"
    end

    local replaced_action = ui.pending_action()
    local replaced = replaced_action and replaced_action.kind or nil
    local previous_pending = ui.pending_patch
    local cwd = target_root()

    local auto = ui.preview_patch({
      title = string_arg(args, "title", "tool-preview-patch"),
      text = patch_text,
      cwd = cwd,
      source = opts.source,
    })

    local result = {
      action = "patch",
      cwd = ui.pending_patch and ui.pending_patch.cwd or cwd,
      replaced_pending = replaced,
    }

    if auto then
      if auto.err then
        result.status = "apply_failed"
        result.auto_applied = false
        result.error = auto.err
        result.message = "safety.auto_apply_edits is enabled but applying failed: " .. auto.err
        return result
      end
      result.status = "applied"
      result.auto_applied = true
      result.written = auto.info and auto.info.written or false
      result.message = (auto.info and auto.info.message or "The patch was applied.") .. replaced_pending_note(replaced)
      return result
    end

    if not ui.pending_patch or ui.pending_patch == previous_pending then
      return nil, "Patch preview did not create a pending patch; the response may not contain a valid unified diff."
    end

    result.status = "previewed"
    result.auto_applied = false
    result.message = "Inspect the preview and run :AIApply to apply or :AIReject to discard." .. replaced_pending_note(replaced)
    return result
  end),
})

register({
  name = "nvim_preview_buffer_replace",
  mode = "preview",
  description = "Preview replacing a 1-based line range in a loaded buffer. It does not apply the edit; the user must run :AIApply.",
  input_schema = {
    type = "object",
    required = { "start_line", "end_line", "replacement" },
    properties = {
      bufnr = { type = "integer", description = "Buffer number. Defaults to the target editor buffer." },
      start_line = { type = "integer", description = "1-based inclusive start line to replace." },
      end_line = { type = "integer", description = "1-based inclusive end line to replace." },
      replacement = { type = "string", description = "Replacement text for the selected range. May be empty to delete the range." },
      title = { type = "string", description = "Optional preview title." },
    },
    additionalProperties = false,
  },
  run = complete_sync(preview_buffer_replace),
})

register({
  name = "nvim_preview_file_replace",
  mode = "preview",
  description = "Preview replacing a 1-based line range in a project file. It does not apply the edit; the user must run :AIApply.",
  input_schema = {
    type = "object",
    required = { "path", "start_line", "end_line", "replacement" },
    properties = {
      path = { type = "string", description = "Project-relative path, or an absolute path inside the project root." },
      start_line = { type = "integer", description = "1-based inclusive start line to replace." },
      end_line = { type = "integer", description = "1-based inclusive end line to replace." },
      replacement = { type = "string", description = "Replacement text for the selected range. May be empty to delete the range." },
      title = { type = "string", description = "Optional preview title." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args, opts)
    local path, root = project_path(args.path)
    if not path then
      return nil, root
    end
    if vim.fn.filereadable(path) ~= 1 then
      return nil, "File is not readable: " .. path
    end

    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 then
      bufnr = vim.fn.bufadd(path)
    end
    vim.fn.bufload(bufnr)

    local result, err = preview_buffer_replace(vim.tbl_extend("force", args, { bufnr = bufnr }), opts)
    if err then
      return nil, err
    end
    result.action = "file_replace"
    result.root = root
    result.path = path
    return result
  end),
})

register({
  name = "nvim_preview_command",
  mode = "preview",
  description = "Preview a shell command in ai.nvim. It only runs automatically when safety.auto_run_commands is enabled; otherwise the user must run :AIRun.",
  input_schema = {
    type = "object",
    required = { "command" },
    properties = {
      command = { type = "string", description = "Shell command to preview." },
      title = { type = "string", description = "Optional preview title." },
    },
    additionalProperties = false,
  },
  run = function(args, cb, opts)
    opts = opts or {}
    local command = string_arg(args, "command", "")
    if command == "" then
      cb("command is required")
      return
    end

    ui.preview_command({
      title = string_arg(args, "title", "tool-preview-command"),
      command = command,
      cwd = target_root(),
      source = opts.source,
    })

    if not runner.pending then
      cb("Command preview did not create a pending command.")
      return
    end

    local pending = runner.pending
    if not (config.get().safety and config.get().safety.auto_run_commands == true) then
      cb(nil, {
        status = "previewed",
        action = "command",
        auto_run = false,
        cwd = pending.cwd,
        command = pending.command,
        message = "Inspect the preview and run :AIRun to execute or :AIReject to discard.",
      })
      return
    end

    runner.run(function(err, output)
      if err then
        cb(err)
        return
      end
      cb(nil, {
        status = "ran",
        action = "command",
        auto_run = true,
        cwd = pending.cwd,
        command = pending.command,
        output = output,
        message = "safety.auto_run_commands is enabled; the command was executed.",
      })
    end)
  end,
})

function M.list()
  local specs = {}
  for _, spec in ipairs(order) do
    table.insert(specs, copy_spec(spec))
  end
  return specs
end

function M.get(name)
  local spec = registry[name]
  if not spec then
    return nil
  end
  return copy_spec(spec)
end

function M.names()
  local names = {}
  for _, spec in ipairs(order) do
    table.insert(names, spec.name)
  end
  return names
end

function M.openai_tools()
  local tools = {}
  for _, spec in ipairs(order) do
    table.insert(tools, {
      type = "function",
      ["function"] = {
        name = spec.name,
        description = spec.description,
        parameters = normalize_json_schema(spec.input_schema),
      },
    })
  end
  return tools
end

function M.describe()
  local lines = {}
  for _, spec in ipairs(order) do
    table.insert(lines, ("%s (%s): %s"):format(spec.name, spec.mode, spec.description))
    table.insert(lines, "input_schema: " .. json_encode(spec.input_schema))
  end
  return table.concat(lines, "\n")
end

function M.render()
  local lines = {
    "# AI harness tools",
    "",
    "These tools expose bounded Neovim/editor context to the AI harness.",
    "Preview tools prepare an action for user review by default. Safety settings can enable automatic edit application or command execution.",
  }

  for _, spec in ipairs(order) do
    table.insert(lines, "")
    table.insert(lines, "## " .. spec.name)
    table.insert(lines, "")
    table.insert(lines, ("Mode: %s"):format(spec.mode))
    table.insert(lines, "")
    table.insert(lines, spec.description)
    table.insert(lines, "")
    table.insert(lines, "```json")
    table.insert(lines, json_encode(spec.input_schema))
    table.insert(lines, "```")
  end

  return table.concat(lines, "\n")
end

function M.result_text(result)
  return vim.inspect(result)
end

function M.run(name, args, cb, opts)
  if type(cb) ~= "function" then
    error("ai.tools.run requires a callback")
  end

  local spec = registry[name]
  if not spec then
    cb("Unknown AI tool: " .. tostring(name))
    return
  end

  local done = false
  local function finish(err, result)
    if done then
      return
    end
    done = true
    cb(err, result)
  end

  local ok, err = pcall(spec.run, args or {}, finish, opts or {})
  if not ok then
    finish(err)
  end
end

return M
