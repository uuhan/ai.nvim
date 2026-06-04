local M = {
  target_bufnr = nil,
  last_editor_winid = nil,
}

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

function M.is_ai_buffer(bufnr)
  if not valid_buffer(bufnr) then
    return false
  end
  return vim.api.nvim_buf_get_name(bufnr):match("^ai://") ~= nil
end

local function editor_buffer(bufnr)
  return valid_buffer(bufnr) and vim.bo[bufnr].buftype == "" and not M.is_ai_buffer(bufnr)
end

function M.capture(winid)
  winid = winid or vim.api.nvim_get_current_win()
  if not valid_window(winid) then
    return M.target_bufnr, M.last_editor_winid
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not editor_buffer(bufnr) then
    return M.target_bufnr, M.last_editor_winid
  end

  M.target_bufnr = bufnr
  M.last_editor_winid = winid
  return bufnr, winid
end

function M.capture_current()
  return M.capture(vim.api.nvim_get_current_win())
end

function M.resolve_window()
  local current_winid = vim.api.nvim_get_current_win()
  if valid_window(current_winid) and editor_buffer(vim.api.nvim_win_get_buf(current_winid)) then
    M.capture(current_winid)
    return current_winid
  end

  if valid_window(M.last_editor_winid) and editor_buffer(vim.api.nvim_win_get_buf(M.last_editor_winid)) then
    M.capture(M.last_editor_winid)
    return M.last_editor_winid
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if valid_window(winid) and editor_buffer(vim.api.nvim_win_get_buf(winid)) then
      M.capture(winid)
      return winid
    end
  end

  return nil
end

function M.resolve_buffer(bufnr)
  local explicit = tonumber(bufnr)
  if explicit and explicit ~= 0 then
    if not valid_buffer(explicit) then
      return nil, "Invalid or unloaded buffer: " .. tostring(bufnr)
    end
    return explicit
  end

  local winid = M.resolve_window()
  if winid then
    return vim.api.nvim_win_get_buf(winid)
  end

  if editor_buffer(M.target_bufnr) then
    return M.target_bufnr
  end

  local current = vim.api.nvim_get_current_buf()
  if valid_buffer(current) then
    return current
  end

  return nil, "No loaded buffer available."
end

function M.state()
  return {
    target_bufnr = editor_buffer(M.target_bufnr) and M.target_bufnr or nil,
    last_editor_winid = valid_window(M.last_editor_winid) and M.last_editor_winid or nil,
  }
end

return M
