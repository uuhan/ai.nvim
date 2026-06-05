local client = require("ai.client")
local config = require("ai.config")
local stream_buffer = require("ai.stream_buffer")

local M = {
  output_bufnr = nil,
  output_winid = nil,
  input_bufnr = nil,
  input_winid = nil,
  title = nil,
  filetype = "markdown",
  messages = nil,
  text = "",
  active_request = nil,
  active_stream = nil,
}

M.placeholder_ns = vim.api.nvim_create_namespace("ai.nvim.response_session.placeholder")
M.autocmd_group = vim.api.nvim_create_augroup("ai.nvim.response_session", {})

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

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

local function scratch(bufnr, filetype, modifiable)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = modifiable ~= false
  vim.bo[bufnr].filetype = filetype or "text"
end

local function dimensions()
  local columns = math.max(1, vim.o.columns)
  local lines = math.max(1, vim.o.lines - vim.o.cmdheight)
  local max_width = math.max(20, columns - 4)
  local max_height = math.max(10, lines - 6)
  local width = math.min(max_width, math.max(50, math.floor(columns * 0.72)))
  local total_height = math.min(max_height, math.max(12, math.floor(lines * 0.62)))
  local input_height = math.min(math.max(1, config.get().chat.input_height or 3), math.max(1, total_height - 6))
  local output_height = math.max(6, total_height - input_height - 2)
  local row = math.max(0, math.floor((vim.o.lines - total_height - 4) / 3))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  return width, output_height, input_height, row, col
end

local function set_output(text)
  if not valid_buffer(M.output_bufnr) then
    return
  end
  vim.bo[M.output_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.output_bufnr, 0, -1, false, split_lines(text))
  vim.bo[M.output_bufnr].modifiable = false
  if config.get().ui.auto_scroll and valid_window(M.output_winid) then
    local line_count = math.max(1, vim.api.nvim_buf_line_count(M.output_bufnr))
    pcall(vim.api.nvim_win_set_cursor, M.output_winid, { line_count, 0 })
  end
end

local function input_text()
  if not valid_buffer(M.input_bufnr) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(M.input_bufnr, 0, -1, false), "\n")
end

local function clear_input()
  if not valid_buffer(M.input_bufnr) then
    return
  end
  vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
end

local function update_placeholder()
  if not valid_buffer(M.input_bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(M.input_bufnr, M.placeholder_ns, 0, -1)
  local placeholder = config.get().response.placeholder
  if not placeholder or placeholder == "" then
    return
  end

  if input_text():gsub("%s+", "") ~= "" then
    return
  end

  pcall(vim.api.nvim_buf_set_extmark, M.input_bufnr, M.placeholder_ns, 0, 0, {
    virt_text = { { placeholder, "Comment" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })
end

local function watch_input()
  if not valid_buffer(M.input_bufnr) then
    return
  end

  vim.api.nvim_clear_autocmds({ group = M.autocmd_group, buffer = M.input_bufnr })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
    group = M.autocmd_group,
    buffer = M.input_bufnr,
    callback = update_placeholder,
  })
end

local function focus_input()
  if valid_window(M.input_winid) then
    vim.api.nvim_set_current_win(M.input_winid)
    vim.cmd.startinsert()
  end
end

function M.stop()
  if M.active_stream and type(M.active_stream.cancel) == "function" then
    pcall(M.active_stream.cancel)
  end
  M.active_stream = nil

  if M.active_request and type(M.active_request.kill) == "function" then
    pcall(function()
      M.active_request:kill(15)
    end)
  end
  M.active_request = nil
end

function M.close()
  if vim.fn.mode():match("^[iR]") then
    pcall(vim.cmd.stopinsert)
  end
  M.stop()
  for _, winid in ipairs({ M.input_winid, M.output_winid }) do
    if valid_window(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
  M.input_winid = nil
  M.output_winid = nil
end

local function map_keys()
  local close = function()
    if vim.fn.mode():match("^[iR]") then
      vim.cmd.stopinsert()
    end
    M.close()
  end

  if valid_buffer(M.output_bufnr) then
    vim.keymap.set("n", "q", close, { buffer = M.output_bufnr, nowait = true, silent = true, desc = "Close AI result" })
    vim.keymap.set("n", "<Esc>", close, { buffer = M.output_bufnr, nowait = true, silent = true, desc = "Close AI result" })
    vim.keymap.set({ "n", "i" }, "<C-q>", close, { buffer = M.output_bufnr, nowait = true, silent = true, desc = "Close AI result" })
    vim.keymap.set("n", "i", focus_input, { buffer = M.output_bufnr, nowait = true, silent = true, desc = "Focus AI follow-up input" })
  end

  if valid_buffer(M.input_bufnr) then
    vim.keymap.set("n", "q", close, { buffer = M.input_bufnr, nowait = true, silent = true, desc = "Close AI result" })
    vim.keymap.set({ "n", "i" }, "<C-q>", close, { buffer = M.input_bufnr, nowait = true, silent = true, desc = "Close AI result" })
    vim.keymap.set("n", "<Esc>", close, { buffer = M.input_bufnr, nowait = true, silent = true, desc = "Close AI result" })
    vim.keymap.set({ "n", "i" }, "<C-c>", M.stop, { buffer = M.input_bufnr, nowait = true, silent = true, desc = "Stop AI follow-up" })
    vim.keymap.set("n", "<CR>", M.send, { buffer = M.input_bufnr, nowait = true, silent = true, desc = "Send AI follow-up" })
    vim.keymap.set("i", "<CR>", function()
      vim.cmd.stopinsert()
      M.send()
    end, { buffer = M.input_bufnr, nowait = true, silent = true, desc = "Send AI follow-up" })
  end
end

function M.open(title, text, filetype)
  M.close()
  M.title = title
  M.filetype = filetype or "markdown"
  M.text = text or ""
  M.messages = nil

  local width, output_height, input_height, row, col = dimensions()
  M.output_bufnr = valid_buffer(M.output_bufnr) and M.output_bufnr or vim.api.nvim_create_buf(false, true)
  M.input_bufnr = valid_buffer(M.input_bufnr) and M.input_bufnr or vim.api.nvim_create_buf(false, true)
  scratch(M.output_bufnr, M.filetype, false)
  scratch(M.input_bufnr, "text", true)
  pcall(vim.api.nvim_buf_set_name, M.output_bufnr, "ai://" .. title)
  pcall(vim.api.nvim_buf_set_name, M.input_bufnr, "ai://" .. title .. "-input")

  M.output_winid = vim.api.nvim_open_win(M.output_bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = output_height,
    border = "rounded",
    style = "minimal",
    title = " AI " .. title .. " ",
    title_pos = "left",
    zindex = 60,
  })
  M.input_winid = vim.api.nvim_open_win(M.input_bufnr, false, {
    relative = "editor",
    row = row + output_height + 2,
    col = col,
    width = width,
    height = input_height,
    border = "rounded",
    style = "minimal",
    title = config.get().response.input_title,
    title_pos = "left",
    zindex = 61,
  })

  vim.wo[M.output_winid].wrap = true
  vim.wo[M.output_winid].linebreak = true
  vim.wo[M.output_winid].conceallevel = 2
  vim.wo[M.input_winid].wrap = true
  vim.wo[M.input_winid].linebreak = true

  set_output(M.text)
  clear_input()
  watch_input()
  map_keys()
  update_placeholder()
  return M.output_bufnr
end

function M.set(bufnr, title, text, filetype)
  if bufnr ~= M.output_bufnr or not valid_buffer(M.output_bufnr) then
    return M.open(title, text, filetype)
  end
  M.title = title
  M.filetype = filetype or M.filetype or "markdown"
  M.text = text or ""
  scratch(M.output_bufnr, M.filetype, false)
  pcall(vim.api.nvim_buf_set_name, M.output_bufnr, "ai://" .. title)
  set_output(M.text)
  return M.output_bufnr
end

function M.attach(bufnr, messages, assistant_text, req_opts)
  if bufnr ~= M.output_bufnr or not valid_buffer(M.output_bufnr) then
    return
  end

  M.messages = vim.deepcopy(messages or {})
  if assistant_text and assistant_text ~= "" then
    table.insert(M.messages, { role = "assistant", content = assistant_text })
  end
  M.req_opts = vim.deepcopy(req_opts or {})
  focus_input()
end

function M.send()
  if M.active_request or M.active_stream then
    return
  end

  local prompt = input_text():gsub("^%s+", ""):gsub("%s+$", "")
  if prompt == "" or not M.messages then
    return
  end

  clear_input()
  update_placeholder()
  table.insert(M.messages, { role = "user", content = prompt })
  local prefix = M.text .. "\n\n## You\n\n" .. prompt .. "\n\n## Assistant\n\n"
  M.text = prefix
  set_output(M.text .. "...")

  local req_opts = vim.deepcopy(M.req_opts or {})
  local use_stream = req_opts.stream
  if use_stream == nil then
    use_stream = config.get().provider.stream
  end

  if use_stream then
    local assistant = ""
    local renderer
    renderer = stream_buffer.new({
      on_update = function(text)
        assistant = text
        set_output(prefix .. assistant)
      end,
      on_done = function(text)
        assistant = text
        M.active_stream = nil
        M.active_request = nil
        M.text = prefix .. assistant
        table.insert(M.messages, { role = "assistant", content = assistant })
        set_output(M.text)
        focus_input()
      end,
    })
    M.active_stream = renderer
    local request_handle = client.chat_stream(M.messages, req_opts, {
      on_delta = function(delta)
        renderer.push(delta)
      end,
      on_error = function(err)
        renderer.cancel()
        M.active_stream = nil
        M.active_request = nil
        M.text = prefix .. "Error: " .. err
        set_output(M.text)
      end,
      on_done = function()
        renderer.finish()
      end,
    })
    if M.active_stream == renderer then
      M.active_request = request_handle
    end
    return
  end

  req_opts.stream = false
  local pending = true
  local request_handle = client.chat(M.messages, req_opts, function(err, response)
    pending = false
    M.active_request = nil
    if err then
      M.text = prefix .. "Error: " .. err
      set_output(M.text)
      return
    end
    M.text = prefix .. response
    table.insert(M.messages, { role = "assistant", content = response })
    set_output(M.text)
    focus_input()
  end)
  if pending then
    M.active_request = request_handle
  end
end

function M.is_open()
  return valid_window(M.output_winid) and valid_window(M.input_winid)
end

return M
