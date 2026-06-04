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
    return fenced
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
  for index = start_index, #lines do
    local line = lines[index]
    if index > start_index and line:match("^```") then
      break
    end
    if line:match("^#") and not looks_like_patch_line(line) then
      break
    end
    table.insert(out, line)
  end

  local patch = trim(table.concat(out, "\n"))
  if patch:match("^diff %-%-git ") or (patch:match("^%-%-%- ") and patch:match("\n%+%+%+ ")) then
    return patch
  end
  return nil
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

function M.apply(patch_text, cb, opts)
  opts = opts or {}
  local root = opts.cwd or context.root(0)
  local patch = M.extract(patch_text) or patch_text
  if patch:sub(-1) ~= "\n" then
    patch = patch .. "\n"
  end

  system_text({ "git", "apply", "--check", "--whitespace=nowarn", "-" }, { cwd = root, stdin = patch }, function(check_err)
    if check_err then
      cb("Patch check failed:\n" .. check_err)
      return
    end

    system_text({ "git", "apply", "--whitespace=nowarn", "-" }, { cwd = root, stdin = patch }, function(apply_err)
      if apply_err then
        cb("Patch apply failed:\n" .. apply_err)
        return
      end
      vim.cmd("checktime")
      cb(nil, "Patch applied.")
    end)
  end)
end

return M
