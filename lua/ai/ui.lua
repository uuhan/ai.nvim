local config = require("ai.config")

local M = {
  pending_edit = nil,
}

local function split_lines(text)
  text = text:gsub("\r\n", "\n")
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function join_lines(lines)
  return table.concat(lines, "\n")
end

local function set_scratch_options(bufnr, filetype)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = filetype or config.get().ui.filetype
end

function M.open_output(title, text, filetype)
  vim.cmd(config.get().ui.output_cmd)
  local bufnr = vim.api.nvim_get_current_buf()
  set_scratch_options(bufnr, filetype)
  vim.api.nvim_buf_set_name(bufnr, "ai://" .. title)

  M.set_output(bufnr, title, text, filetype)
  return bufnr
end

function M.set_output(bufnr, title, text, filetype)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return M.open_output(title, text, filetype)
  end

  set_scratch_options(bufnr, filetype)
  pcall(vim.api.nvim_buf_set_name, bufnr, "ai://" .. title)

  local lines = split_lines(text)
  if vim.tbl_isempty(lines) then
    lines = { "" }
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  return bufnr
end

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ai.nvim" })
end

local function strip_code_fence(text)
  local body = text:gsub("^%s+", ""):gsub("%s+$", "")
  local first_line = body:match("^(.-)\n")
  if first_line and first_line:match("^```") and body:match("\n```%s*$") then
    body = body:gsub("^```[%w_+-]*\n", ""):gsub("\n```%s*$", "")
  end
  return body
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

function M.preview_edit(opts)
  local replacement = strip_code_fence(opts.replacement or "")
  local replacement_lines = split_lines(replacement)

  M.pending_edit = {
    bufnr = opts.bufnr,
    path = opts.path,
    line1 = opts.line1,
    line2 = opts.line2,
    original_lines = opts.original_lines,
    replacement_lines = replacement_lines,
  }

  local original = join_lines(opts.original_lines)
  local proposed = join_lines(replacement_lines)
  local diff
  if vim.diff then
    diff = vim.diff(original .. "\n", proposed .. "\n", {
      result_type = "unified",
      ctxlen = 3,
    })
  end

  if not diff or diff == "" then
    diff = table.concat({
      "--- original",
      original,
      "+++ proposed",
      proposed,
    }, "\n")
  end

  local title = ("AI edit preview: %s:%d-%d"):format(opts.path ~= "" and opts.path or "[No Name]", opts.line1, opts.line2)
  local text = table.concat({
    "# " .. title,
    "",
    "Inspect the proposed replacement, then run :AIApply or :AIReject.",
    "",
    "```diff",
    diff,
    "```",
  }, "\n")

  if opts.output_bufnr then
    M.set_output(opts.output_bufnr, "edit-preview", text, "markdown")
  else
    M.open_output("edit-preview", text, "markdown")
  end
end

function M.apply_pending()
  local edit = M.pending_edit
  if not edit then
    M.notify("No pending AI edit.", vim.log.levels.WARN)
    return
  end
  if not vim.api.nvim_buf_is_valid(edit.bufnr) then
    M.pending_edit = nil
    M.notify("Target buffer no longer exists.", vim.log.levels.ERROR)
    return
  end

  local current = vim.api.nvim_buf_get_lines(edit.bufnr, edit.line1 - 1, edit.line2, false)
  if not same_lines(current, edit.original_lines) then
    M.notify("Target text changed after preview; refusing to apply stale edit.", vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_buf_set_lines(edit.bufnr, edit.line1 - 1, edit.line2, false, edit.replacement_lines)
  M.pending_edit = nil
  M.notify("AI edit applied.")
end

function M.reject_pending()
  M.pending_edit = nil
  M.notify("AI edit cleared.")
end

return M
