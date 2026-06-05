local context = require("ai.context")

local M = {}

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

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function looks_like_patch_line(line)
  return line:match("^diff %-%-git ")
    or line:match("^%-%-%- ")
    or line:match("^%+%+%+ ")
    or line:match("^@@ ")
end

local function is_patch_metadata_line(line)
  return line:match("^diff %-%-git ")
    or line:match("^index ")
    or line:match("^old mode ")
    or line:match("^new mode ")
    or line:match("^deleted file mode ")
    or line:match("^new file mode ")
    or line:match("^similarity index ")
    or line:match("^dissimilarity index ")
    or line:match("^rename from ")
    or line:match("^rename to ")
    or line:match("^copy from ")
    or line:match("^copy to ")
    or line:match("^%-%-%- ")
    or line:match("^%+%+%+ ")
end

local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if old_start == nil then
    return nil
  end

  return {
    old_start = tonumber(old_start) or 0,
    old_count = old_count ~= "" and tonumber(old_count) or 1,
    new_start = tonumber(new_start) or 0,
    new_count = new_count ~= "" and tonumber(new_count) or 1,
    old_seen = 0,
    new_seen = 0,
  }
end

local function extract_fenced_patch(text)
  for body in text:gmatch("```[%w_-]*\n(.-)\n```") do
    local candidate = trim(body)
    if candidate:match("^diff %-%-git ") or (candidate:match("^%-%-%- ") and candidate:match("\n%+%+%+ ")) then
      return candidate
    end
  end
  return nil
end

function M.extract(text)
  text = trim(text or "")
  if text == "" then
    return nil
  end

  local fenced = extract_fenced_patch(text)
  if fenced then
    text = fenced
  end

  local lines = split_lines(text)
  local start_index
  for index, line in ipairs(lines) do
    if line:match("^diff %-%-git ") or line:match("^%-%-%- ") then
      start_index = index
      break
    end
  end

  if not start_index then
    return nil
  end

  local out = {}
  local hunk
  for index = start_index, #lines do
    local line = lines[index]
    if index > start_index and line:match("^```") then
      break
    end

    if line == "" and #out > 0 then
      break
    end

    local next_hunk = parse_hunk_header(line)
    if line:match("^diff %-%-git ") then
      hunk = nil
      table.insert(out, line)
    elseif next_hunk then
      hunk = next_hunk
      table.insert(out, line)
    elseif hunk and line:match("^\\") then
      table.insert(out, line)
    elseif hunk and line:match("^[ %-%+]") then
      table.insert(out, line)
    elseif not hunk and is_patch_metadata_line(line) then
      table.insert(out, line)
    elseif line:match("^#") and not looks_like_patch_line(line) then
      break
    elseif #out > 0 then
      break
    else
      table.insert(out, line)
    end
  end

  local patch = trim(table.concat(out, "\n"))
  if patch:match("^diff %-%-git ") or (patch:match("^%-%-%- ") and patch:match("\n%+%+%+ ")) then
    return patch
  end
  return nil
end

local function clamp_cursors(bufnr)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      local cursor = vim.api.nvim_win_get_cursor(winid)
      pcall(vim.api.nvim_win_set_cursor, winid, { math.min(cursor[1], line_count), cursor[2] })
    end
  end
end

local function save_buffer_views(bufnr)
  local views = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      local ok, view = pcall(vim.api.nvim_win_call, winid, function()
        return vim.fn.winsaveview()
      end)
      if ok then
        table.insert(views, { winid = winid, view = view })
      end
    end
  end
  return views
end

local function restore_buffer_views(views, bufnr)
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  for _, saved in ipairs(views) do
    if vim.api.nvim_win_is_valid(saved.winid) then
      saved.view.lnum = math.min(saved.view.lnum or 1, line_count)
      saved.view.topline = math.min(saved.view.topline or 1, line_count)
      pcall(vim.api.nvim_win_call, saved.winid, function()
        vim.fn.winrestview(saved.view)
      end)
    end
  end
end

local function strip_patch_path(raw)
  if not raw or raw == "" then
    return nil
  end

  local path = raw:gsub("\t.*$", "")
  if path == "/dev/null" then
    return "/dev/null"
  end
  if path:sub(1, 2) == "a/" or path:sub(1, 2) == "b/" then
    path = path:sub(3)
  end
  if path == "" then
    return nil
  end
  return path
end

local function absolute_path(root, path)
  if not path or path == "" or path == "/dev/null" then
    return nil
  end
  return vim.fn.fnamemodify(path:sub(1, 1) == "/" and path or (root .. "/" .. path), ":p")
end

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end
  for index, line in ipairs(left) do
    if line ~= right[index] then
      return false
    end
  end
  return true
end

local function slice(lines, start_index, count)
  local out = {}
  for index = 1, count do
    table.insert(out, lines[start_index + index])
  end
  return out
end

local function replace_slice(lines, start_index, remove_count, replacement)
  local out = {}
  for index = 1, start_index do
    table.insert(out, lines[index])
  end
  for _, line in ipairs(replacement) do
    table.insert(out, line)
  end
  for index = start_index + remove_count + 1, #lines do
    table.insert(out, lines[index])
  end
  return out
end

local function find_matching_slice(lines, needle, preferred_start)
  if #needle == 0 or #lines < #needle then
    return nil, 0
  end

  local best_start
  local best_distance
  local matches = 0
  for start_index = 0, #lines - #needle do
    if same_lines(slice(lines, start_index, #needle), needle) then
      matches = matches + 1
      local distance = math.abs(start_index - preferred_start)
      if not best_distance or distance < best_distance then
        best_start = start_index
        best_distance = distance
      end
    end
  end

  return best_start, matches
end

local function add_hunk_line(file, line)
  local hunk = file.current_hunk
  if not hunk then
    return
  end

  if line:match("^\\") then
    return
  end
  if not line:match("^[ %-%+]") then
    file.current_hunk = nil
    return
  end

  table.insert(hunk.lines, line)
  local prefix = line:sub(1, 1)
  if prefix == " " then
    hunk.old_seen = hunk.old_seen + 1
    hunk.new_seen = hunk.new_seen + 1
  elseif prefix == "-" then
    hunk.old_seen = hunk.old_seen + 1
  elseif prefix == "+" then
    hunk.new_seen = hunk.new_seen + 1
  end

end

local function parse_files(patch_text)
  local files = {}
  local current

  local function ensure_file()
    if not current then
      current = { hunks = {} }
    end
    return current
  end

  local function finish_file()
    if current then
      current.current_hunk = nil
      table.insert(files, current)
      current = nil
    end
  end

  for _, line in ipairs(split_lines(patch_text)) do
    local diff_old, diff_new = line:match("^diff %-%-git%s+(.+)%s+(.+)$")
    local hunk = parse_hunk_header(line)
    if diff_old and diff_new then
      finish_file()
      current = {
        old_path = strip_patch_path(diff_old),
        new_path = strip_patch_path(diff_new),
        hunks = {},
      }
    elseif hunk then
      hunk.lines = {}
      local file = ensure_file()
      table.insert(file.hunks, hunk)
      file.current_hunk = hunk
    elseif current and current.current_hunk then
      add_hunk_line(current, line)
    elseif line:match("^%-%-%- ") then
      ensure_file().old_path = strip_patch_path(line:match("^%-%-%- (.+)$"))
    elseif line:match("^%+%+%+ ") then
      ensure_file().new_path = strip_patch_path(line:match("^%+%+%+ (.+)$"))
    end
  end

  finish_file()
  return files
end

local function hunk_lines(hunk)
  local old_lines = {}
  local new_lines = {}

  for _, line in ipairs(hunk.lines or {}) do
    local prefix = line:sub(1, 1)
    local body = line:sub(2)
    if prefix == " " then
      table.insert(old_lines, body)
      table.insert(new_lines, body)
    elseif prefix == "-" then
      table.insert(old_lines, body)
    elseif prefix == "+" then
      table.insert(new_lines, body)
    end
  end

  return old_lines, new_lines, nil
end

local function ensure_buffer(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    bufnr = vim.fn.bufadd(path)
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "Invalid buffer for " .. path
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, "Could not load buffer for " .. path
  end
  vim.bo[bufnr].buflisted = true
  return bufnr, nil
end

local function apply_file(root, file)
  local path = absolute_path(root, file.new_path ~= "/dev/null" and file.new_path or file.old_path)
  if not path then
    return nil, "Patch file path is missing."
  end
  if file.new_path == "/dev/null" then
    return nil, "Deleting files is not supported by buffer apply: " .. vim.fn.fnamemodify(path, ":.")
  end
  if vim.tbl_isempty(file.hunks) then
    return nil, "Patch has no hunks for " .. vim.fn.fnamemodify(path, ":.")
  end

  local bufnr, err = ensure_buffer(path)
  if not bufnr then
    return nil, err
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local clear_empty_new_file = false
  if file.old_path == "/dev/null" and #lines == 1 and lines[1] == "" and vim.fn.filereadable(path) ~= 1 then
    lines = {}
    clear_empty_new_file = true
  end

  local operations = {}
  local offset = 0
  for _, hunk in ipairs(file.hunks) do
    local old_lines, new_lines, hunk_err = hunk_lines(hunk)
    if hunk_err then
      return nil, ("%s: %s"):format(vim.fn.fnamemodify(path, ":."), hunk_err)
    end

    local start_index = hunk.old_count == 0 and (hunk.old_start + offset) or (hunk.old_start - 1 + offset)
    start_index = math.max(0, start_index)
    local current = slice(lines, start_index, #old_lines)
    if not same_lines(current, old_lines) then
      local relocated_start, matches = find_matching_slice(lines, old_lines, start_index)
      if not relocated_start then
        return nil, ("Patch context mismatch in %s at line %d."):format(vim.fn.fnamemodify(path, ":."), start_index + 1)
      end
      if matches > 1 and #old_lines < 2 then
        return nil,
          ("Patch context mismatch in %s at line %d; found %d possible matches."):format(
            vim.fn.fnamemodify(path, ":."),
            start_index + 1,
            matches
          )
      end
      start_index = relocated_start
    end

    table.insert(operations, {
      start_index = start_index,
      remove_count = #old_lines,
      replacement = new_lines,
    })
    lines = replace_slice(lines, start_index, #old_lines, new_lines)
    offset = offset + #new_lines - #old_lines
  end

  local modifiable = vim.bo[bufnr].modifiable
  local views = save_buffer_views(bufnr)
  vim.bo[bufnr].modifiable = true
  local changed = false
  if clear_empty_new_file then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    changed = true
  end
  for _, operation in ipairs(operations) do
    if changed then
      pcall(vim.cmd, "undojoin")
    end
    vim.api.nvim_buf_set_lines(bufnr, operation.start_index, operation.start_index + operation.remove_count, false, operation.replacement)
    changed = true
  end
  vim.bo[bufnr].modifiable = modifiable
  clamp_cursors(bufnr)
  restore_buffer_views(views, bufnr)
  return bufnr, nil
end

function M.apply(patch_text, cb, opts)
  opts = opts or {}
  local root = opts.cwd or context.root(0)
  local patch = M.extract(patch_text) or patch_text
  if patch:sub(-1) ~= "\n" then
    patch = patch .. "\n"
  end

  local files = parse_files(patch)
  if vim.tbl_isempty(files) then
    cb("Patch apply failed:\nNo file hunks found.")
    return
  end

  local applied = {}
  for _, file in ipairs(files) do
    local bufnr, err = apply_file(root, file)
    if err then
      cb("Patch apply failed:\n" .. err)
      return
    end
    table.insert(applied, bufnr)
  end

  cb(nil, ("Patch applied to %d buffer(s). Save modified buffers to write files."):format(#applied))
end

return M
