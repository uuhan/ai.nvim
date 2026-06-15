-- Tree-sitter helpers for code-structure context.
--
-- This module is purely syntactic (no language server required) and complements
-- the LSP-based context: tree-sitter answers "where does this function/class
-- start and end" quickly and locally, while LSP answers semantic questions
-- (types, definitions, diagnostics). All functions degrade gracefully to nil
-- when tree-sitter or a parser is unavailable.

local M = {}

-- Node types treated as an enclosing "code block" (function/class/method).
-- Used as a fallback when a language has no textobjects query installed.
local code_node_types = {
  arrow_function = true,
  anonymous_function = true,
  class_declaration = true,
  class_definition = true,
  closure_expression = true,
  constructor_declaration = true,
  ["function"] = true,
  function_declaration = true,
  function_definition = true,
  function_expression = true,
  function_item = true,
  generator_function = true,
  generator_function_declaration = true,
  lambda = true,
  local_function = true,
  method_declaration = true,
  method_definition = true,
}

local function has_treesitter()
  return vim.treesitter ~= nil and type(vim.treesitter.get_parser) == "function"
end

local function get_parser(bufnr)
  if not has_treesitter() then
    return nil
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  return parser
end

-- Ensure the buffer has an up-to-date tree before using `get_node`, which
-- otherwise relies on a previously-parsed tree (absent for a cold buffer).
local function ensure_parsed(bufnr)
  local parser = get_parser(bufnr)
  if not parser then
    return false
  end
  pcall(function()
    parser:parse()
  end)
  return true
end

-- Resolve a 0-based (row, col) for tree-sitter lookups. With an explicit 1-based
-- `line`, use its first non-blank column (more reliable than column 0 on
-- indented/blank lines); otherwise use the current window cursor.
local function resolve_pos(bufnr, line)
  if line then
    local row0 = line - 1
    local text = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ""
    return row0, #(text:match("^%s*") or "")
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  return cursor[1] - 1, cursor[2]
end

--- Whether a usable tree-sitter parser exists for the buffer.
function M.available(bufnr)
  return get_parser(bufnr or 0) ~= nil
end

-- Resolve the textobjects query for a language, tolerating older Neovim APIs.
local function get_textobjects_query(lang)
  if not (vim.treesitter and vim.treesitter.query) then
    return nil
  end
  local getter = vim.treesitter.query.get or vim.treesitter.query.get_query
  if type(getter) ~= "function" then
    return nil
  end
  local ok, query = pcall(getter, lang, "textobjects")
  if not ok or not query then
    return nil
  end
  return query
end

-- Smallest function/class textobject enclosing row0 (0-based) via the
-- nvim-treesitter "textobjects" query. Returns 0-based (start_row, end_row) or nil.
local function query_enclosing(bufnr, row0)
  local parser = get_parser(bufnr)
  if not parser then
    return nil
  end
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees or not trees[1] then
    return nil
  end

  local query = get_textobjects_query(parser:lang())
  if not query then
    return nil
  end

  local best_s, best_e
  local ok_iter = pcall(function()
    local root = trees[1]:root()
    for id, node in query:iter_captures(root, bufnr, 0, -1) do
      local name = query.captures[id]
      if name == "function.outer" or name == "class.outer" then
        local s, _, e = node:range()
        if s <= row0 and row0 <= e then
          if not best_s or (e - s) < (best_e - best_s) then
            best_s, best_e = s, e
          end
        end
      end
    end
  end)
  if not ok_iter or not best_s then
    return nil
  end
  return best_s, best_e
end

-- Fallback: walk up from the node at (row0, col0) until a code_node_types match.
-- Position is passed explicitly so this never depends on window state.
-- Returns 0-based (start_row, end_row) or nil.
local function walk_enclosing(bufnr, row0, col0)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, col0 } })
  if not ok or not node then
    return nil
  end

  while node do
    local type_ok, node_type = pcall(function()
      return node:type()
    end)
    if type_ok and code_node_types[node_type] then
      local range_ok, s, _, e = pcall(function()
        return node:range()
      end)
      if range_ok and s and e then
        return s, e
      end
    end

    local parent_ok, parent = pcall(function()
      return node:parent()
    end)
    if not parent_ok then
      return nil
    end
    node = parent
  end

  return nil
end

--- 1-based (line1, line2) of the function/class enclosing the given position,
--- or nil. Prefers the textobjects query (language-agnostic, well maintained)
--- and falls back to node-type matching when no query is available.
---
--- `line` (1-based) is optional. When omitted it uses the current window's
--- cursor — so callers passing a non-current buffer MUST supply `line` to avoid
--- reading an unrelated window's position.
function M.enclosing_range(bufnr, line)
  bufnr = bufnr or 0
  if not has_treesitter() then
    return nil, nil
  end
  ensure_parsed(bufnr)

  local row0, col0 = resolve_pos(bufnr, line)

  local s, e = query_enclosing(bufnr, row0)
  if not s then
    s, e = walk_enclosing(bufnr, row0, col0)
  end
  if not s then
    return nil, nil
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  return math.max(1, math.min(total, s + 1)), math.max(1, math.min(total, e + 1))
end

local function get_node_text(node, bufnr)
  local getter = vim.treesitter.get_node_text
    or (vim.treesitter.query and vim.treesitter.query.get_node_text)
  if type(getter) ~= "function" then
    return nil
  end
  local ok, text = pcall(getter, node, bufnr)
  if ok then
    return text
  end
  return nil
end

-- Derive a symbol name: prefer the node's `name` field (reliable across
-- languages), fall back to the trimmed first line. Avoids depending on a
-- particular textobjects capture name, which varies per grammar.
-- Returns (name, named) where `named` is true when the name came from a real
-- `name` field — used to tell genuine symbols from grammar wrapper artifacts.
local function node_name(bufnr, node)
  local ok, fields = pcall(function()
    return node:field("name")
  end)
  if ok and fields and fields[1] then
    local text = get_node_text(fields[1], bufnr)
    if text and text ~= "" then
      return (vim.trim(text:gsub("%s+", " "))), true
    end
  end

  local s = node:range()
  local line = vim.api.nvim_buf_get_lines(bufnr, s, s + 1, false)[1] or ""
  line = vim.trim(line)
  if #line > 80 then
    line = line:sub(1, 80) .. "…"
  end
  return line, false
end

local function kind_of(node_type)
  if node_type:match("class") or node_type:match("struct") or node_type:match("interface") then
    return "class"
  end
  return "function"
end

-- Symbols via the textobjects query (@function.outer / @class.outer).
local function query_symbols(bufnr, max_items)
  local parser = get_parser(bufnr)
  if not parser then
    return nil
  end
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees or not trees[1] then
    return nil
  end
  local query = get_textobjects_query(parser:lang())
  if not query then
    return nil
  end

  local items = {}
  local seen = {}
  local ok = pcall(function()
    local root = trees[1]:root()
    for id, node in query:iter_captures(root, bufnr, 0, -1) do
      local cap = query.captures[id]
      local kind
      if cap == "function.outer" then
        kind = "function"
      elseif cap == "class.outer" then
        kind = "class"
      end
      if kind then
        local s, sc, e, ec = node:range()
        local key = s .. ":" .. sc .. ":" .. e .. ":" .. ec
        if not seen[key] then
          seen[key] = true
          local name, named = node_name(bufnr, node)
          items[#items + 1] = {
            kind = kind,
            name = name,
            named = named,
            line1 = s + 1,
            line2 = e + 1,
            scol = sc,
            ecol = ec,
          }
          if #items >= max_items then
            return
          end
        end
      end
    end
  end)
  if not ok then
    return nil
  end
  return items
end

-- Fallback: walk the whole tree collecting code_node_types nodes.
local function walk_symbols(bufnr, max_items)
  local parser = get_parser(bufnr)
  if not parser then
    return {}
  end
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees or not trees[1] then
    return {}
  end

  local items = {}
  local seen = {}
  local function visit(node)
    if #items >= max_items then
      return
    end
    local node_type = node:type()
    if code_node_types[node_type] then
      local s, sc, e, ec = node:range()
      local key = s .. ":" .. sc .. ":" .. e .. ":" .. ec
      if not seen[key] then
        seen[key] = true
        local name, named = node_name(bufnr, node)
        items[#items + 1] = {
          kind = kind_of(node_type),
          name = name,
          named = named,
          line1 = s + 1,
          line2 = e + 1,
          scol = sc,
          ecol = ec,
        }
      end
    end
    for child in node:iter_children() do
      if #items >= max_items then
        return
      end
      visit(child)
    end
  end
  pcall(function()
    visit(trees[1]:root())
  end)
  return items
end

-- Drop wrapper-duplicate nodes. Some grammars expose a single function as a
-- nested node that begins on the same line as its outer node (e.g. lua's
-- `local function f()` yields a `function_declaration` plus an inner
-- `function_definition` for the signature). The artifact has no real `name`
-- field, so it only falls back to first-line text. We therefore drop a node
-- only when it is UNNAMED and another node on the same start line strictly
-- contains it — which spares genuine nested/sibling symbols (they either have a
-- name, or start on a different line) including same-line K&R nesting where the
-- inner function has its own name.
local function strictly_contains(a, b)
  local start_ok = a.line1 < b.line1 or (a.line1 == b.line1 and a.scol <= b.scol)
  local end_ok = a.line2 > b.line2 or (a.line2 == b.line2 and a.ecol >= b.ecol)
  if not (start_ok and end_ok) then
    return false
  end
  -- strictly wider on at least one edge
  return a.line1 < b.line1 or a.scol < b.scol or a.line2 > b.line2 or a.ecol > b.ecol
end

local function drop_wrapper_duplicates(items)
  local out = {}
  for _, item in ipairs(items) do
    local redundant = false
    if not item.named then
      for _, other in ipairs(items) do
        if other ~= item and other.line1 == item.line1 and strictly_contains(other, item) then
          redundant = true
          break
        end
      end
    end
    if not redundant then
      out[#out + 1] = item
    end
  end
  return out
end

--- A flat list of code symbols (functions/classes) in the buffer, each
--- `{ kind, name, line1, line2 }` (1-based). Prefers the textobjects query and
--- falls back to node-type walking. Returns an empty list when unavailable.
function M.symbols(bufnr, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  if not has_treesitter() then
    return {}
  end
  local max_items = opts.max_items or 200

  local items = query_symbols(bufnr, max_items)
  if not items or #items == 0 then
    items = walk_symbols(bufnr, max_items)
  end

  items = drop_wrapper_duplicates(items)
  table.sort(items, function(a, b)
    if a.line1 ~= b.line1 then
      return a.line1 < b.line1
    end
    return a.line2 > b.line2
  end)
  return items
end

-- Top-level import/use/include node types across common grammars.
local import_node_types = {
  import_statement = true, -- js/ts/python
  import_from_statement = true, -- python
  import_declaration = true, -- go/java
  use_declaration = true, -- rust
  preproc_include = true, -- c/c++
  using_declaration = true, -- c++
  using_directive = true, -- c#
}

--- Top-level import/use/include statements, each `{ text, line1, line2 }`.
--- Empty when tree-sitter is unavailable. Only the top level is scanned, which
--- covers the vast majority of languages (imports live at file scope).
function M.imports(bufnr, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  if not has_treesitter() then
    return {}
  end
  local parser = get_parser(bufnr)
  if not parser then
    return {}
  end
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees or not trees[1] then
    return {}
  end
  local max_items = opts.max_items or 80

  local items = {}
  pcall(function()
    for child in trees[1]:root():iter_children() do
      if import_node_types[child:type()] then
        local s, _, e = child:range()
        local text = get_node_text(child, bufnr)
        if text and text ~= "" then
          items[#items + 1] = { text = vim.trim(text), line1 = s + 1, line2 = e + 1 }
          if #items >= max_items then
            return
          end
        end
      end
    end
  end)
  return items
end

--- The chain of functions/classes enclosing `line` (1-based), outermost-first.
--- Each `{ kind, name, signature, line1, line2 }` where `signature` is the
--- trimmed first line of the node. `line` defaults to the current window cursor,
--- so pass it explicitly for non-current buffers.
function M.enclosing_scopes(bufnr, line, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  if not has_treesitter() then
    return {}
  end
  ensure_parsed(bufnr)

  local row0, col0 = resolve_pos(bufnr, line)

  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, col0 } })
  if not ok or not node then
    return {}
  end

  local max_depth = opts.max_depth or 8
  local inner_to_outer = {}
  while node do
    if code_node_types[node:type()] then
      local s, _, e = node:range()
      local name = node_name(bufnr, node)
      local sig = vim.api.nvim_buf_get_lines(bufnr, s, s + 1, false)[1] or ""
      inner_to_outer[#inner_to_outer + 1] = {
        kind = kind_of(node:type()),
        name = name,
        signature = vim.trim(sig),
        line1 = s + 1,
        line2 = e + 1,
      }
      if #inner_to_outer >= max_depth then
        break
      end
    end
    local parent_ok, parent = pcall(function()
      return node:parent()
    end)
    if not parent_ok then
      break
    end
    node = parent
  end

  -- No wrapper dedup here: the ancestor chain is strictly nested, so it never
  -- holds the same-line sibling wrapper artifacts that symbols() must remove.
  -- Applying that dedup would wrongly drop a legitimate inline anonymous scope
  -- (e.g. an IIFE/arrow on the same line as its enclosing function).
  local scopes = {}
  for i = #inner_to_outer, 1, -1 do
    scopes[#scopes + 1] = inner_to_outer[i]
  end
  return scopes
end

return M
