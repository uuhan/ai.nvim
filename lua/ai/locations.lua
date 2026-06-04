local context = require("ai.context")

local M = {}

local function root_path(path, root)
  if path == "" then
    return path
  end
  if path:sub(1, 1) == "/" then
    return path
  end
  return (root or context.root(0)) .. "/" .. path
end

local function valid_path(path)
  return path ~= ""
    and not path:match("^https?://")
    and not path:match("^ai://")
    and not path:match("^%d+$")
    and not path:match("^%s")
end

function M.parse(text, root)
  local items = {}
  local seen = {}

  for line in (text or ""):gmatch("[^\n]+") do
    for path, lnum, col in line:gmatch("([%w_./%-]+):(%d+):?(%d*)") do
      if valid_path(path) then
        local key = path .. ":" .. lnum .. ":" .. col
        if not seen[key] then
          seen[key] = true
          table.insert(items, {
            filename = root_path(path, root),
            lnum = tonumber(lnum),
            col = tonumber(col) or 1,
            text = line:gsub("^%s+", ""),
          })
        end
      end
    end
  end

  return items
end

function M.populate(text, title, root)
  local items = M.parse(text, root)
  if vim.tbl_isempty(items) then
    return 0
  end

  vim.fn.setloclist(0, {}, " ", {
    title = title or "AI results",
    items = items,
  })
  pcall(vim.cmd, "lopen")
  return #items
end

return M
