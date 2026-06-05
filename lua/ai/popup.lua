local config = require("ai.config")

local M = {
  bufnr = nil,
  winid = nil,
}

local function split_lines(text)
  text = (text or ""):gsub("\r\n", "\n")
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  if vim.tbl_isempty(lines) then
    return { "" }
  end
  return lines
end

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function set_scratch_options(bufnr, filetype)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = filetype or config.get().ui.filetype
end

local function dimensions()
  local columns = math.max(1, vim.o.columns)
  local lines = math.max(1, vim.o.lines - vim.o.cmdheight)
  local max_width = math.max(20, columns - 4)
  local max_height = math.max(4, lines - 6)
  local width = math.min(max_width, math.max(44, math.floor(columns * 0.62)))
  local height = math.min(max_height, math.max(8, math.floor(lines * 0.5)))
  return width, height
end

local function scroll_to_bottom(bufnr)
  if not config.get().ui.auto_scroll then
    return
  end

  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
      pcall(vim.api.nvim_win_set_cursor, winid, { line_count, 0 })
    end
  end
end

function M.close()
  if valid_window(M.winid) then
    pcall(vim.api.nvim_win_close, M.winid, true)
  end
  M.winid = nil
end

local function map_keys(bufnr)
  local close_key = (config.get().ui.buffer_keymaps or {}).close
  if close_key and close_key ~= "" then
    vim.keymap.set("n", close_key, M.close, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = "Close AI popup",
    })
  end

  vim.keymap.set("n", "<Esc>", M.close, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = "Close AI popup",
  })
end

function M.set(bufnr, title, text, filetype)
  if not valid_buffer(bufnr) then
    return M.open(title, text, filetype)
  end

  set_scratch_options(bufnr, filetype)
  pcall(vim.api.nvim_buf_set_name, bufnr, "ai://" .. title)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, split_lines(text))
  vim.bo[bufnr].modifiable = false
  scroll_to_bottom(bufnr)
  return bufnr
end

function M.open(title, text, filetype)
  M.close()

  local bufnr = valid_buffer(M.bufnr) and M.bufnr or vim.api.nvim_create_buf(false, true)
  set_scratch_options(bufnr, filetype)
  pcall(vim.api.nvim_buf_set_name, bufnr, "ai://" .. title)

  local width, height = dimensions()
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 3)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = " AI " .. title .. " ",
    title_pos = "left",
    zindex = 60,
  })

  M.bufnr = bufnr
  M.winid = winid
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].conceallevel = 2
  map_keys(bufnr)
  M.set(bufnr, title, text, filetype)
  return bufnr
end

function M.is_open()
  return valid_window(M.winid)
end

return M
