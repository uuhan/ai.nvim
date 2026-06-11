local config = require("ai.config")
local context = require("ai.context")

--- Append-only JSONL persistence for AIChat history.
--- One file per session under <dir>/<urlencoded-project-root>/.
--- First line is a meta record; each following line is one history message.
local M = {
  current = nil,
}

local counter = 0

local function sessions_opts()
  local chat = config.get().chat or {}
  return chat.sessions or {}
end

local function enabled()
  return sessions_opts().enabled ~= false
end

local function base_dir()
  local dir = sessions_opts().dir
  if type(dir) == "string" and dir ~= "" then
    return dir
  end
  return vim.fn.stdpath("state") .. "/ai.nvim/sessions"
end

local function slug(root)
  return (root:gsub("[^%w%-_.]", function(char)
    return ("%%%02X"):format(char:byte())
  end))
end

--- context.root can return a relative path (e.g. "." when the current buffer
--- is an ai:// scratch buffer); normalize so the same project always maps to
--- the same session directory.
local function normalize_root(root)
  root = root or context.root(0)
  return (vim.fn.fnamemodify(root, ":p"):gsub("/+$", ""))
end

local function root_dir(root)
  return base_dir() .. "/" .. slug(root)
end

local function json_encode(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded
  end
  return nil
end

local function json_decode(line)
  local ok, decoded = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok then
    return decoded
  end
  return nil
end

local function append_line(path, line)
  local file = io.open(path, "a")
  if not file then
    return false
  end
  file:write(line, "\n")
  file:close()
  return true
end

function M.active()
  return M.current ~= nil
end

--- Start a new session for the project root. The file is created lazily on
--- the first append so empty sessions never touch disk.
function M.begin(root)
  if not enabled() then
    return nil
  end

  root = normalize_root(root)
  counter = counter + 1
  M.current = {
    root = root,
    path = ("%s/%s-%d-%04d.jsonl"):format(root_dir(root), os.date("%Y%m%d-%H%M%S"), vim.fn.getpid(), counter),
    started = false,
  }
  M.prune(root, tonumber(sessions_opts().keep) or 20)
  return M.current
end

--- Continue appending to an existing session file (after a restore).
function M.resume_file(path, root)
  M.current = {
    root = normalize_root(root),
    path = path,
    started = true,
  }
end

function M.finish()
  M.current = nil
end

function M.append(message)
  if not enabled() or not M.current then
    return false
  end

  local active = M.current
  if not active.started then
    local ok = pcall(vim.fn.mkdir, vim.fn.fnamemodify(active.path, ":h"), "p")
    if not ok then
      return false
    end
    local meta = json_encode({
      type = "meta",
      version = 1,
      root = active.root,
      created = os.date("%Y-%m-%dT%H:%M:%S"),
      provider = config.get().provider.base_url,
      model = config.get().provider.model,
    })
    if not meta or not append_line(active.path, meta) then
      return false
    end
    active.started = true
  end

  local encoded = json_encode({ type = "message", data = message })
  if not encoded then
    return false
  end
  return append_line(active.path, encoded)
end

--- Returns (meta, messages) or (nil, err). Damaged lines are skipped so a
--- crash mid-write loses at most the final record.
function M.load(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "Could not read session file: " .. tostring(path)
  end

  local meta
  local messages = {}
  for _, line in ipairs(lines) do
    local record = json_decode(line)
    if type(record) == "table" then
      if record.type == "meta" then
        meta = record
      elseif record.type == "message" and type(record.data) == "table" then
        table.insert(messages, record.data)
      end
    end
  end

  if not meta then
    return nil, "Session file has no metadata: " .. tostring(path)
  end
  return meta, messages
end

--- List sessions for the project root, newest first.
function M.list(root)
  root = normalize_root(root)
  local paths = vim.fn.glob(root_dir(root) .. "/*.jsonl", false, true)
  table.sort(paths, function(left, right)
    return left > right
  end)

  local items = {}
  for _, path in ipairs(paths) do
    local meta, messages = M.load(path)
    if meta then
      local preview = ""
      for _, message in ipairs(messages) do
        if message.role == "user" and message.kind ~= "event" and type(message.content) == "string" then
          preview = message.content:gsub("%s+", " "):sub(1, 60)
          break
        end
      end
      table.insert(items, {
        path = path,
        created = meta.created,
        count = #messages,
        preview = preview,
      })
    end
  end
  return items
end

function M.prune(root, keep)
  keep = math.max(0, tonumber(keep) or 20)
  local paths = vim.fn.glob(root_dir(normalize_root(root)) .. "/*.jsonl", false, true)
  table.sort(paths, function(left, right)
    return left > right
  end)

  for index = keep + 1, #paths do
    local path = paths[index]
    if not (M.current and M.current.path == path) then
      pcall(vim.fn.delete, path)
    end
  end
end

return M
