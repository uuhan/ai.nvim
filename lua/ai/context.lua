local config = require("ai.config")

local M = {}
local uv = vim.uv or vim.loop

local function split_lines(text)
  if text == "" then
    return {}
  end
  local lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function join_lines(lines)
  return table.concat(lines, "\n")
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function dirname(path)
  return vim.fs.dirname(path)
end

local function readable(path)
  return vim.fn.filereadable(path) == 1
end

local function read_file(path, max_chars)
  if not readable(path) then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local text = join_lines(lines)
  if max_chars and #text > max_chars then
    text = text:sub(1, max_chars) .. "\n[truncated]"
  end
  return text
end

function M.root(bufnr)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  local start = name ~= "" and dirname(name) or uv.cwd()
  local markers = config.get().project.markers

  if vim.fs and vim.fs.find then
    local found = vim.fs.find(markers, { upward = true, path = start })[1]
    if found then
      if vim.fn.isdirectory(found) == 1 and vim.fs.basename(found) == ".git" then
        return dirname(found)
      end
      return dirname(found)
    end
  end

  return uv.cwd()
end

function M.range_text(bufnr, line1, line2)
  bufnr = bufnr or 0
  line1 = clamp(line1, 1, vim.api.nvim_buf_line_count(bufnr))
  line2 = clamp(line2, line1, vim.api.nvim_buf_line_count(bufnr))
  local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
  return join_lines(lines), lines
end

function M.current_paragraph_range(bufnr)
  bufnr = bufnr or 0
  local total = vim.api.nvim_buf_line_count(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false)
  local start_line = row
  local end_line = row

  while start_line > 1 and lines[start_line - 1] ~= "" do
    start_line = start_line - 1
  end

  while end_line < total and lines[end_line + 1] ~= "" do
    end_line = end_line + 1
  end

  return start_line, end_line
end

function M.command_range(cmd)
  if cmd.range and cmd.range > 0 then
    return cmd.line1, cmd.line2
  end
  return M.current_paragraph_range(0)
end

function M.buffer_context(bufnr, max_chars)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = join_lines(lines)
  if max_chars and #text > max_chars then
    text = text:sub(1, max_chars) .. "\n[truncated]"
  end
  return {
    path = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    text = text,
  }
end

function M.rules(bufnr)
  local opts = config.get()
  if not opts.rules.enabled then
    return ""
  end

  local root = M.root(bufnr)
  local remaining = opts.rules.max_chars
  local chunks = {}

  for _, rel in ipairs(opts.rules.files) do
    if remaining <= 0 then
      break
    end
    local path = root .. "/" .. rel
    local text = read_file(path, remaining)
    if text and text ~= "" then
      table.insert(chunks, ("# %s\n%s"):format(rel, text))
      remaining = remaining - #text
    end
  end

  return table.concat(chunks, "\n\n")
end

function M.selection_context(cmd)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line1, line2 = M.command_range(cmd)
  local text, lines = M.range_text(bufnr, line1, line2)
  local last_line = lines[#lines] or ""
  return {
    bufnr = bufnr,
    root = M.root(bufnr),
    path = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    cursor_line = cursor[1],
    column = cursor[2] + 1,
    line1 = line1,
    line2 = line2,
    start_column = 1,
    end_column = #last_line + 1,
    text = text,
    lines = lines,
  }
end

function M.diagnostic_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local diagnostics = vim.diagnostic.get(bufnr, { lnum = row - 1 })
  local selected = diagnostics[1]

  for _, diagnostic in ipairs(diagnostics) do
    local start_col = diagnostic.col or 0
    local end_col = diagnostic.end_col or start_col
    if col >= start_col and col <= end_col then
      selected = diagnostic
      break
    end
  end

  if not selected then
    return nil
  end

  local start_line = clamp((selected.lnum or row - 1) + 1 - 8, 1, vim.api.nvim_buf_line_count(bufnr))
  local end_line = clamp((selected.end_lnum or selected.lnum or row - 1) + 1 + 8, start_line, vim.api.nvim_buf_line_count(bufnr))
  local text = M.range_text(bufnr, start_line, end_line)

  return {
    bufnr = bufnr,
    root = M.root(bufnr),
    path = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    cursor_line = row,
    column = col + 1,
    diagnostic = selected,
    context_start = start_line,
    context_end = end_line,
    text = text,
  }
end

function M.quickfix_context(max_items)
  local items = vim.fn.getqflist()
  if vim.tbl_isempty(items) then
    return ""
  end

  local out = {}
  for index, item in ipairs(items) do
    if max_items and index > max_items then
      table.insert(out, "[truncated]")
      break
    end
    local filename = item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr) or item.filename or ""
    table.insert(out, ("%s:%s:%s %s"):format(filename, item.lnum or 0, item.col or 0, item.text or ""))
  end
  return table.concat(out, "\n")
end

function M.all_diagnostics_context(max_items)
  local out = {}
  local count = 0

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local diagnostics = vim.diagnostic.get(bufnr)
      for _, diagnostic in ipairs(diagnostics) do
        count = count + 1
        if max_items and count > max_items then
          table.insert(out, "[truncated]")
          return table.concat(out, "\n")
        end

        local filename = vim.api.nvim_buf_get_name(bufnr)
        table.insert(out, ("%s:%s:%s %s"):format(
          filename,
          (diagnostic.lnum or 0) + 1,
          (diagnostic.col or 0) + 1,
          diagnostic.message or ""
        ))
      end
    end
  end

  return table.concat(out, "\n")
end

local function system_text(args, opts, cb)
  if not vim.system then
    vim.schedule(function()
      cb("ai.nvim requires Neovim with vim.system support.")
    end)
    return
  end
  vim.system(args, vim.tbl_extend("force", { text = true }, opts or {}), function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        cb((obj.stderr or "") .. (obj.stdout or ""))
        return
      end
      cb(nil, obj.stdout or "")
    end)
  end)
end

function M.system_text(args, opts, cb)
  system_text(args, opts, cb)
end

function M.git_diff(cb, root_override)
  local root = root_override or M.root(0)
  system_text({ "git", "status", "--short" }, { cwd = root }, function(status_err, status)
    if status_err then
      cb(status_err)
      return
    end
    system_text({ "git", "diff", "--no-ext-diff" }, { cwd = root }, function(diff_err, diff)
      if diff_err then
        cb(diff_err)
        return
      end
      system_text({ "git", "diff", "--cached", "--no-ext-diff" }, { cwd = root }, function(cached_err, cached)
        if cached_err then
          cb(cached_err)
          return
        end

        local text = table.concat({
          "# git status --short",
          status,
          "# git diff",
          diff,
          "# git diff --cached",
          cached,
        }, "\n")

        cb(nil, text)
      end)
    end)
  end)
end

local function extract_terms(prompt)
  local terms = {}
  local seen = {}

  local function add(term)
    term = term:gsub("^%s+", ""):gsub("%s+$", "")
    if #term < 3 or seen[term] then
      return
    end
    seen[term] = true
    table.insert(terms, term)
  end

  for term in prompt:gmatch("[%w_./:-]+") do
    add(term)
  end

  local word = vim.fn.expand("<cword>")
  if word and word ~= "" then
    add(word)
  end

  return terms
end

local function trim_context(text, max_chars)
  if #text <= max_chars then
    return text
  end
  return text:sub(1, max_chars) .. "\n[truncated]"
end

function M.project_context(prompt, cb, root_override)
  local root = root_override or M.root(0)
  local opts = config.get().project
  local terms = extract_terms(prompt)

  if vim.tbl_isempty(terms) then
    system_text({ "rg", "--files" }, { cwd = root }, function(err, files)
      if err then
        cb(nil, "# project root\n" .. root .. "\n\n# current buffer\n" .. M.buffer_context(0, opts.max_context_chars).text)
        return
      end
      local list = vim.list_slice(split_lines(files), 1, opts.max_file_list)
      cb(nil, "# project root\n" .. root .. "\n\n# files\n" .. join_lines(list))
    end)
    return
  end

  local term = terms[1]
  system_text({
    "rg",
    "--line-number",
    "--context",
    "2",
    "--smart-case",
    "--max-count",
    tostring(opts.max_rg_matches),
    "--",
    term,
  }, { cwd = root }, function(err, matches)
    local chunks = {
      "# project root",
      root,
      "# search term",
      term,
    }

    if err or matches == "" then
      table.insert(chunks, "# search results")
      table.insert(chunks, "No rg matches. Current buffer context is included instead.")
      table.insert(chunks, M.buffer_context(0, opts.max_context_chars).text)
    else
      table.insert(chunks, "# rg results")
      table.insert(chunks, matches)
    end

    cb(nil, trim_context(table.concat(chunks, "\n"), opts.max_context_chars))
  end)
end

return M
