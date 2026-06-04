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

  local root = vim.fn.fnamemodify(context.root(0), ":p"):gsub("/$", "")
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

local function preview_buffer_replace(args)
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

  ui.preview_edit({
    bufnr = bufnr,
    path = path,
    line1 = start_line,
    line2 = end_line,
    original_lines = original_lines,
    replacement = args.replacement,
    title = string_arg(args, "title", "tool-preview-edit"),
  })

  if not ui.pending_edit then
    return nil, "Edit preview did not create a pending edit."
  end

  return {
    status = "previewed",
    action = "buffer_replace",
    bufnr = bufnr,
    path = path,
    start_line = start_line,
    end_line = end_line,
    original_line_count = #original_lines,
    replacement_line_count = #split_lines(args.replacement),
    message = "Inspect the preview and run :AIApply to apply or :AIReject to discard.",
  }
end

local function complete_sync(fn)
  return function(args, cb)
    local ok, result, err = pcall(fn, args or {})
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
  description = "Return the current Neovim mode, cwd, project root, current buffer, and visible windows.",
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
      target_buffer.cursor = target_cursor
      target_buffer.root = context.root(target_bufnr)
    end

    return {
      cwd = vim.fn.getcwd(),
      root = target_bufnr and context.root(target_bufnr) or context.root(0),
      mode = vim.api.nvim_get_mode().mode,
      current_winid = vim.api.nvim_get_current_win(),
      current_buffer = buffer_info(vim.api.nvim_get_current_buf()),
      target_winid = target_winid,
      target_buffer = target_buffer,
      windows = windows,
    }
  end),
})

register({
  name = "nvim_current_buffer",
  mode = "read",
  description = "Return metadata for the current buffer, including path, filetype, cursor, modified flag, and line count.",
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
    info.cursor = cursor_for_buffer(bufnr)
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
  description = "Read text from a loaded buffer by 1-based line range.",
  input_schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer", description = "Buffer number. Defaults to the current buffer." },
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
    local text, truncated = limit_text(join_lines(lines), args.max_chars)

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
  description = "Read the last visual selection marks from the current buffer when they are available.",
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
  description = "Read a file under the current project root. Relative paths are resolved from the root.",
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

    local text, truncated = limit_text(join_lines(lines), args.max_chars)
    return {
      root = root,
      path = path,
      text = text,
      truncated = truncated,
    }
  end),
})

register({
  name = "nvim_diagnostics",
  mode = "read",
  description = "Return Neovim diagnostics from the current buffer or all loaded buffers.",
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
        cb(err)
        return
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
  description = "Search project context for a query using the same rg-backed context path as :AIProject.",
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
  run = complete_sync(function(args)
    local patch_text = string_arg(args, "patch", "")
    if patch_text == "" then
      return nil, "patch is required"
    end

    ui.preview_patch({
      title = string_arg(args, "title", "tool-preview-patch"),
      text = patch_text,
      cwd = target_root(),
    })

    if not ui.pending_patch then
      return nil, "Patch preview did not create a pending patch."
    end

    return {
      status = "previewed",
      action = "patch",
      cwd = ui.pending_patch.cwd,
      message = "Inspect the preview and run :AIApply to apply or :AIReject to discard.",
    }
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
      bufnr = { type = "integer", description = "Buffer number. Defaults to the current buffer." },
      start_line = { type = "integer", description = "1-based inclusive start line to replace." },
      end_line = { type = "integer", description = "1-based inclusive end line to replace." },
      replacement = { type = "string", description = "Replacement text for the selected range. May be empty to delete the range." },
      title = { type = "string", description = "Optional preview title." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    return preview_buffer_replace(args)
  end),
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
  run = complete_sync(function(args)
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

    local result, err = preview_buffer_replace(vim.tbl_extend("force", args, { bufnr = bufnr }))
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
  description = "Preview a shell command in ai.nvim. It does not run the command; the user must run :AIRun.",
  input_schema = {
    type = "object",
    required = { "command" },
    properties = {
      command = { type = "string", description = "Shell command to preview." },
      title = { type = "string", description = "Optional preview title." },
    },
    additionalProperties = false,
  },
  run = complete_sync(function(args)
    local command = string_arg(args, "command", "")
    if command == "" then
      return nil, "command is required"
    end

    ui.preview_command({
      title = string_arg(args, "title", "tool-preview-command"),
      command = command,
      cwd = target_root(),
    })

    if not runner.pending then
      return nil, "Command preview did not create a pending command."
    end

    return {
      status = "previewed",
      action = "command",
      cwd = runner.pending.cwd,
      command = runner.pending.command,
      message = "Inspect the preview and run :AIRun to execute or :AIReject to discard.",
    }
  end),
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
    "Preview tools prepare an action for user review; they do not apply patches or run commands.",
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

function M.run(name, args, cb)
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

  local ok, err = pcall(spec.run, args or {}, finish)
  if not ok then
    finish(err)
  end
end

return M
