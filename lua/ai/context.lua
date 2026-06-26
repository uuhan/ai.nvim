local config = require("ai.config")
local treesitter = require("ai.treesitter")

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

local function code_symbol_kinds()
  local kind = vim.lsp and vim.lsp.protocol and vim.lsp.protocol.SymbolKind or {}
  return {
    [kind.Class or 5] = true,
    [kind.Method or 6] = true,
    [kind.Constructor or 9] = true,
    [kind.Function or 12] = true,
    [kind.Struct or 23] = true,
  }
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
  local project = config.get().project or {}

  if vim.fs and vim.fs.find then
    -- Prefer the git repository root so a monorepo/workspace member resolves to
    -- the top-level project, not the nearest nested manifest (Cargo.toml,
    -- package.json, Makefile, ...). Set project.prefer_git_root = false to use
    -- the nearest marker instead.
    if project.prefer_git_root ~= false then
      local git = vim.fs.find({ ".git" }, { upward = true, path = start })[1]
      if git then
        return dirname(git)
      end
    end
    local found = vim.fs.find(project.markers, { upward = true, path = start })[1]
    if found then
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

local function lsp_supports(bufnr, method)
  if not vim.lsp or type(vim.lsp.buf_request_sync) ~= "function" then
    return false
  end

  local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
  if type(get_clients) ~= "function" then
    return false
  end

  local ok, clients = pcall(get_clients, { bufnr = bufnr })
  if not ok or type(clients) ~= "table" then
    return false
  end

  for _, client in ipairs(clients) do
    if type(client.supports_method) ~= "function" then
      return true
    end
    local supported_ok, supported = pcall(function()
      return client:supports_method(method, { bufnr = bufnr })
    end)
    if supported_ok and supported then
      return true
    end
  end

  return false
end

local function symbol_range(symbol)
  local range = symbol.range or (symbol.location and symbol.location.range)
  if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
    return nil, nil
  end
  if type(range.start.line) ~= "number" or type(range["end"].line) ~= "number" then
    return nil, nil
  end
  return range.start.line + 1, range["end"].line + 1
end

local function smaller_range(left, right)
  if not left then
    return right
  end
  if not right then
    return left
  end
  if (right.line2 - right.line1) < (left.line2 - left.line1) then
    return right
  end
  return left
end

local function find_enclosing_symbol(symbols, cursor_line, allowed_kinds, best)
  if type(symbols) ~= "table" then
    return best
  end

  for _, symbol in ipairs(symbols) do
    local line1, line2 = symbol_range(symbol)
    if line1 and line2 and cursor_line >= line1 and cursor_line <= line2 then
      if allowed_kinds[symbol.kind] then
        best = smaller_range(best, { line1 = line1, line2 = line2 })
      end
      best = find_enclosing_symbol(symbol.children, cursor_line, allowed_kinds, best)
    end
  end

  return best
end

function M.current_lsp_symbol_range(bufnr)
  bufnr = bufnr or 0
  local method = "textDocument/documentSymbol"
  if not lsp_supports(bufnr, method) then
    return nil, nil
  end

  local ok, responses = pcall(vim.lsp.buf_request_sync, bufnr, method, {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  }, 300)
  if not ok or type(responses) ~= "table" then
    return nil, nil
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local allowed_kinds = code_symbol_kinds()
  local best
  for _, response in pairs(responses) do
    best = find_enclosing_symbol(response.result, cursor_line, allowed_kinds, best)
  end

  if not best then
    return nil, nil
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  return clamp(best.line1, 1, total), clamp(best.line2, 1, total)
end

function M.current_code_range(bufnr)
  return treesitter.enclosing_range(bufnr or 0)
end

function M.command_range(cmd, bufnr)
  if cmd.range and cmd.range > 0 then
    return cmd.line1, cmd.line2
  end
  bufnr = bufnr or 0

  -- Resolve the enclosing range via LSP and tree-sitter; order is configurable.
  -- "treesitter_first" (default) avoids the synchronous documentSymbol call.
  local strategy = (config.get().context or {}).range_strategy or "treesitter_first"
  local providers
  if strategy == "lsp_first" then
    providers = { M.current_lsp_symbol_range, M.current_code_range }
  else
    providers = { M.current_code_range, M.current_lsp_symbol_range }
  end

  for _, provider in ipairs(providers) do
    local line1, line2 = provider(bufnr)
    if line1 and line2 then
      return line1, line2
    end
  end

  return M.current_paragraph_range(bufnr)
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

--- A tree-sitter symbol outline of the buffer as indented text, e.g.
---   class Foo [3-40]
---     function bar [5-10]
--- Empty string when tree-sitter is unavailable. Bounded by `opts.max_chars`.
function M.outline(bufnr, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  local items = treesitter.symbols(bufnr, { max_items = opts.max_items or 200 })
  if #items == 0 then
    return ""
  end

  -- `a` encloses `b` when its full (row, col) range contains b's. Using columns
  -- (not just end line) keeps same-line siblings from nesting under each other.
  local function encloses(a, b)
    local start_ok = a.line1 < b.line1 or (a.line1 == b.line1 and a.scol <= b.scol)
    local end_ok = a.line2 > b.line2 or (a.line2 == b.line2 and a.ecol >= b.ecol)
    return start_ok and end_ok
  end

  local budget = opts.max_chars or 4000
  local stack = {}
  local lines = {}
  for _, item in ipairs(items) do
    while #stack > 0 and not encloses(stack[#stack], item) do
      table.remove(stack)
    end
    local indent = string.rep("  ", #stack)
    local line = ("%s%s %s [%d-%d]"):format(indent, item.kind, item.name, item.line1, item.line2)
    if #line > budget then
      lines[#lines + 1] = indent .. "…"
      break
    end
    budget = budget - #line - 1
    lines[#lines + 1] = line
    stack[#stack + 1] = item
  end
  return table.concat(lines, "\n")
end

--- Structural context around a selection: top-level imports plus the chain of
--- enclosing function/class signatures. Returns formatted text (possibly empty),
--- bounded by `opts.max_import_chars`. Gives the model the selection's
--- surroundings (where types come from, what it belongs to) without sending the
--- whole file.
function M.scope_context(bufnr, line, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  local parts = {}

  local imports = treesitter.imports(bufnr, { max_items = opts.max_imports or 80 })
  if #imports > 0 then
    local budget = opts.max_import_chars or 1500
    local lines = {}
    for _, imp in ipairs(imports) do
      if #imp.text > budget then
        lines[#lines + 1] = "…"
        break
      end
      budget = budget - #imp.text - 1
      lines[#lines + 1] = imp.text
    end
    if #lines > 0 then
      parts[#parts + 1] = "Imports:\n" .. table.concat(lines, "\n")
    end
  end

  local scopes = treesitter.enclosing_scopes(bufnr, line, { max_depth = opts.max_depth or 8 })
  if #scopes > 0 then
    local max_sig = opts.max_signature_chars or 160
    local budget = opts.max_scope_chars or 800
    local lines = {}
    for depth, scope in ipairs(scopes) do
      local indent = string.rep("  ", depth - 1)
      local sig = scope.signature
      if #sig > max_sig then
        sig = sig:sub(1, max_sig) .. "…"
      end
      local line_text = ("%s%s [%d-%d]"):format(indent, sig, scope.line1, scope.line2)
      if #line_text > budget then
        lines[#lines + 1] = indent .. "…"
        break
      end
      budget = budget - #line_text - 1
      lines[#lines + 1] = line_text
    end
    parts[#parts + 1] = "Enclosing scope:\n" .. table.concat(lines, "\n")
  end

  return table.concat(parts, "\n\n")
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

function M.selection_context(cmd, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line1, line2 = M.command_range(cmd, bufnr)
  local text, lines = M.range_text(bufnr, line1, line2)
  local last_line = lines[#lines] or ""
  -- Capture scope context synchronously here, so it reflects the same buffer
  -- state as `text` even if the buffer is edited while async context (LSP) runs.
  -- Callers that don't build a selection prompt can pass `scope = false` to skip
  -- the extra tree-sitter parse/scan.
  local scope_context = ""
  if opts.scope ~= false and (config.get().context or {}).scope_context ~= false then
    scope_context = M.scope_context(bufnr, line1)
  end
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
    scope_context = scope_context,
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

local search_stopwords = {}
for _, word in ipairs({
  "the", "and", "for", "with", "this", "that", "these", "those", "from", "into",
  "how", "what", "why", "where", "when", "which", "who", "whose",
  "does", "did", "done", "doing",
  "can", "could", "should", "would", "will", "shall", "may", "might", "must",
  "are", "was", "were", "been", "being",
  "you", "your", "our", "their", "its",
  "have", "has", "had", "having",
  "not", "but", "all", "any", "some", "one", "more", "most", "other",
  "use", "used", "using", "make", "made", "work", "works", "working",
  "please", "help", "find", "show", "tell", "explain", "about", "like", "look",
  "code", "file", "files", "project", "function", "functions", "implement",
}) do
  search_stopwords[word] = true
end

local function term_score(term)
  if search_stopwords[term:lower()] or term:match("^%d+$") then
    return nil
  end

  local score = math.min(#term, 24)
  if term:match("[_%./:%-]") then
    score = score + 12
  end
  if term:match("%l%u") or (term:match("%u") and term:match("%l")) then
    score = score + 8
  end
  return score
end

local function extract_terms(prompt)
  local scored = {}
  local seen = {}
  local order = 0

  for raw in prompt:gmatch("[%w_./:-]+") do
    local term = raw:gsub("^[./:%-]+", ""):gsub("[./:%-]+$", "")
    if #term >= 3 and not seen[term:lower()] then
      local score = term_score(term)
      if score then
        seen[term:lower()] = true
        order = order + 1
        table.insert(scored, { term = term, score = score, order = order })
      end
    end
  end

  table.sort(scored, function(left, right)
    if left.score ~= right.score then
      return left.score > right.score
    end
    return left.order < right.order
  end)

  local terms = {}
  for _, item in ipairs(scored) do
    table.insert(terms, item.term)
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

  local selected = vim.list_slice(terms, 1, 3)
  local per_term_budget = math.max(2000, math.floor(opts.max_context_chars / (#selected + 1)))
  local chunks = {
    "# project root",
    root,
    "# search terms",
    table.concat(selected, ", "),
  }
  local matched = false
  local index = 0

  local function finish()
    if not matched then
      table.insert(chunks, "# search results")
      table.insert(chunks, "No rg matches. Current buffer context is included instead.")
      table.insert(chunks, M.buffer_context(0, opts.max_context_chars).text)
    end
    cb(nil, trim_context(table.concat(chunks, "\n"), opts.max_context_chars))
  end

  local function next_term()
    index = index + 1
    local term = selected[index]
    if not term then
      finish()
      return
    end

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
      if not err and matches and matches ~= "" then
        matched = true
        table.insert(chunks, "# rg results: " .. term)
        table.insert(chunks, trim_context(matches, per_term_budget))
      end
      next_term()
    end)
  end

  next_term()
end

return M
