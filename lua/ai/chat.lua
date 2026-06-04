local client = require("ai.client")
local config = require("ai.config")

local M = {
  history = {},
  messages_bufnr = nil,
  input_bufnr = nil,
  messages_winid = nil,
  input_winid = nil,
  active = false,
  system_prompt = nil,
}
M.placeholder_ns = vim.api.nvim_create_namespace "ai.nvim.chat.placeholder"

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function split_lines(text)
  local lines = vim.split((text or ""):gsub("\r\n", "\n"), "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  if vim.tbl_isempty(lines) then
    return { "" }
  end
  return lines
end

local function set_scratch(bufnr, filetype, modifiable)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype
  vim.bo[bufnr].modifiable = modifiable
end

local function scroll_messages()
  if not valid_window(M.messages_winid) or not valid_buffer(M.messages_bufnr) then
    return
  end
  local line_count = math.max(1, vim.api.nvim_buf_line_count(M.messages_bufnr))
  pcall(vim.api.nvim_win_set_cursor, M.messages_winid, { line_count, 0 })
end

local function set_messages(text)
  if not valid_buffer(M.messages_bufnr) then
    return
  end
  vim.bo[M.messages_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.messages_bufnr, 0, -1, false, split_lines(text))
  vim.bo[M.messages_bufnr].modifiable = false
  scroll_messages()
end

local function raw_input_text()
  if not valid_buffer(M.input_bufnr) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(M.input_bufnr, 0, -1, false), "\n")
end

local function update_placeholder()
  if not valid_buffer(M.input_bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(M.input_bufnr, M.placeholder_ns, 0, -1)
  local placeholder = config.get().chat.placeholder
  if not placeholder or placeholder == "" then
    return
  end

  if raw_input_text():gsub("%s+", "") == "" then
    pcall(vim.api.nvim_buf_set_extmark, M.input_bufnr, M.placeholder_ns, 0, 0, {
      virt_text = { { placeholder, "Comment" } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end
end

local function render_history(extra)
  local lines = {
    "# AI Chat",
    "",
  }

  if vim.tbl_isempty(M.history) then
    table.insert(lines, "Start typing in the input pane below.")
    table.insert(lines, "")
  end

  for _, message in ipairs(M.history) do
    if message.role == "user" then
      table.insert(lines, "## You")
    elseif message.role == "assistant" then
      table.insert(lines, "## Assistant")
    else
      table.insert(lines, "## " .. message.role)
    end
    table.insert(lines, "")
    vim.list_extend(lines, split_lines(message.content))
    table.insert(lines, "")
  end

  if extra and extra ~= "" then
    vim.list_extend(lines, split_lines(extra))
  end

  return table.concat(lines, "\n")
end

local function reset_input()
  if not valid_buffer(M.input_bufnr) then
    return
  end
  vim.bo[M.input_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
  vim.bo[M.input_bufnr].modifiable = true
  update_placeholder()
end

local function input_text()
  return raw_input_text():gsub("^%s+", ""):gsub("%s+$", "")
end

local function request_messages()
  local messages = {
    { role = "system", content = M.system_prompt() },
  }
  vim.list_extend(messages, M.history)
  return messages
end

function M.close()
  if valid_window(M.input_winid) then
    pcall(vim.api.nvim_win_close, M.input_winid, true)
  end
  if valid_window(M.messages_winid) then
    pcall(vim.api.nvim_win_close, M.messages_winid, true)
  end
  M.input_winid = nil
  M.messages_winid = nil
end

function M.clear()
  M.history = {}
  set_messages(render_history())
end

function M.send(text)
  text = (text or input_text()):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" or M.active then
    return
  end

  M.active = true
  table.insert(M.history, { role = "user", content = text })
  reset_input()
  set_messages(render_history("## Assistant\n\n..."))

  if config.get().provider.stream then
    local assistant = ""
    client.chat_stream(request_messages(), {}, {
      on_delta = function(delta)
        assistant = assistant .. delta
        set_messages(render_history("## Assistant\n\n" .. assistant))
      end,
      on_error = function(err)
        M.active = false
        set_messages(render_history("## Error\n\n" .. err))
      end,
      on_done = function()
        M.active = false
        table.insert(M.history, { role = "assistant", content = assistant })
        set_messages(render_history())
      end,
    })
    return
  end

  client.chat(request_messages(), {}, function(err, response)
    M.active = false
    if err then
      set_messages(render_history("## Error\n\n" .. err))
      return
    end
    table.insert(M.history, { role = "assistant", content = response })
    set_messages(render_history())
  end)
end

local function map_input_keys()
  local opts = { buffer = M.input_bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function() M.send() end, vim.tbl_extend("force", opts, { desc = "AI chat send" }))
  vim.keymap.set("i", "<CR>", function()
    vim.cmd.stopinsert()
    M.send()
  end, vim.tbl_extend("force", opts, { desc = "AI chat send" }))
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd.stopinsert()
    M.send()
  end, vim.tbl_extend("force", opts, { desc = "AI chat send" }))
  vim.keymap.set("n", "<C-l>", M.clear, vim.tbl_extend("force", opts, { desc = "AI chat clear" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "AI chat close" }))
end

local function map_messages_keys()
  local opts = { buffer = M.messages_bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "i", function()
    if valid_window(M.input_winid) then
      vim.api.nvim_set_current_win(M.input_winid)
      vim.cmd.startinsert()
    end
  end, vim.tbl_extend("force", opts, { desc = "AI chat focus input" }))
  vim.keymap.set("n", "<CR>", function()
    if valid_window(M.input_winid) then
      vim.api.nvim_set_current_win(M.input_winid)
      vim.cmd.startinsert()
    end
  end, vim.tbl_extend("force", opts, { desc = "AI chat focus input" }))
  vim.keymap.set("n", "<C-l>", M.clear, vim.tbl_extend("force", opts, { desc = "AI chat clear" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "AI chat close" }))
end

local function ensure_buffers()
  if not valid_buffer(M.messages_bufnr) then
    M.messages_bufnr = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, M.messages_bufnr, "ai://chat")
    set_scratch(M.messages_bufnr, "markdown", false)
  end

  if not valid_buffer(M.input_bufnr) then
    M.input_bufnr = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, M.input_bufnr, "ai://chat-input")
    set_scratch(M.input_bufnr, "text", true)
    reset_input()
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
      buffer = M.input_bufnr,
      callback = update_placeholder,
    })
  end
end

function M.open(opts)
  opts = opts or {}
  M.system_prompt = opts.system_prompt or M.system_prompt or function() return "You are an AI assistant embedded in Neovim." end
  ensure_buffers()

  if valid_window(M.messages_winid) and valid_window(M.input_winid) then
    vim.api.nvim_set_current_win(M.input_winid)
    vim.cmd.startinsert()
    return
  end

  local chat_opts = config.get().chat
  vim.cmd(("botright vertical %dnew"):format(chat_opts.width))
  M.messages_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.messages_winid, M.messages_bufnr)
  vim.wo[M.messages_winid].wrap = true
  vim.wo[M.messages_winid].number = false
  vim.wo[M.messages_winid].relativenumber = false
  vim.wo[M.messages_winid].winfixwidth = true

  vim.api.nvim_set_current_win(M.messages_winid)
  vim.cmd(("belowright %dnew"):format(chat_opts.input_height))
  M.input_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_winid, M.input_bufnr)
  vim.api.nvim_win_set_height(M.input_winid, chat_opts.input_height)
  vim.wo[M.input_winid].number = false
  vim.wo[M.input_winid].relativenumber = false
  vim.wo[M.input_winid].wrap = true
  vim.wo[M.input_winid].winfixheight = true

  map_messages_keys()
  map_input_keys()
  set_messages(render_history())
  update_placeholder()
  vim.cmd.startinsert()
end

return M
