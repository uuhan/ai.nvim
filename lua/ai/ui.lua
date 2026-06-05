local config = require("ai.config")
local context = require("ai.context")
local patch = require("ai.patch")
local popup = require("ai.popup")
local runner = require("ai.runner")

local M = {
  pending_edit = nil,
  pending_patch = nil,
  output_bufnr = nil,
  output_winid = nil,
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

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
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

local function map_buffer_keys(bufnr)
  local keys = config.get().ui.buffer_keymaps or {}
  local mappings = {
    apply = { rhs = function() require("ai.ui").apply_pending() end, desc = "AI apply pending edit or patch" },
    reject = { rhs = function() require("ai.ui").reject_pending() end, desc = "AI reject pending action" },
    next = { rhs = function() require("ai.commands").plan_next() end, desc = "AI preview next plan step" },
    patch = { rhs = function() require("ai.commands").plan_apply() end, desc = "AI preview next patch step" },
    run = { rhs = function() require("ai.commands").plan_run() end, desc = "AI preview next command step" },
    done = { rhs = function() require("ai.commands").plan_done() end, desc = "AI mark plan step done" },
    skip = { rhs = function() require("ai.commands").plan_skip() end, desc = "AI skip plan step" },
    close = {
      rhs = function()
        local winid = vim.api.nvim_get_current_win()
        pcall(vim.api.nvim_win_close, winid, true)
        if M.output_winid == winid then
          M.output_winid = nil
        end
      end,
      desc = "Close AI window",
    },
  }

  for name, spec in pairs(mappings) do
    local lhs = keys[name]
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, spec.rhs, {
        buffer = bufnr,
        nowait = true,
        silent = true,
        desc = spec.desc,
      })
    end
  end
end

local function focus_or_open_output()
  local opts = config.get().ui
  if opts.reuse_output and valid_buffer(M.output_bufnr) then
    if valid_window(M.output_winid) then
      vim.api.nvim_set_current_win(M.output_winid)
    else
      vim.cmd(opts.output_cmd)
      M.output_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M.output_winid, M.output_bufnr)
    end
    return M.output_bufnr
  end

  vim.cmd(opts.output_cmd)
  local bufnr = vim.api.nvim_get_current_buf()
  M.output_bufnr = bufnr
  M.output_winid = vim.api.nvim_get_current_win()
  return bufnr
end

function M.open_output(title, text, filetype)
  local bufnr = focus_or_open_output()
  set_scratch_options(bufnr, filetype)
  pcall(vim.api.nvim_buf_set_name, bufnr, "ai://" .. title)
  map_buffer_keys(bufnr)

  M.set_output(bufnr, title, text, filetype)
  return bufnr
end

function M.open_float_output(title, text, filetype)
  return popup.open(title, text, filetype)
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
  scroll_to_bottom(bufnr)
  return bufnr
end

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ai.nvim" })
end

function M.auto_apply_edits_enabled()
  return config.get().safety and config.get().safety.auto_apply_edits == true
end

function M.pending_action()
  if M.pending_edit then
    return {
      kind = "edit",
      title = "Pending AI edit preview",
      apply = ":AIApply",
      reject = ":AIReject",
      message = "Run `:AIApply` to apply this edit or `:AIReject` to discard it.",
    }
  end

  if M.pending_patch then
    return {
      kind = "patch",
      title = "Pending AI patch preview",
      apply = ":AIApply",
      reject = ":AIReject",
      message = "Run `:AIApply` to apply this patch or `:AIReject` to discard it.",
    }
  end

  if runner.pending then
    return {
      kind = "command",
      title = "Pending AI command preview",
      apply = ":AIRun",
      reject = ":AIReject",
      message = "Run `:AIRun` to execute this command or `:AIReject` to discard it.",
    }
  end

  return nil
end

function M.pending_notice()
  local action = M.pending_action()
  if not action then
    return ""
  end

  return table.concat({
    "",
    ("> [!TIP] %s"):format(action.title),
    "> " .. action.message,
  }, "\n")
end

local function preview_instruction(review_text)
  if M.auto_apply_edits_enabled() then
    return "safety.auto_apply_edits is enabled; applying this preview immediately."
  end
  return review_text
end

local function maybe_auto_apply_preview()
  if M.auto_apply_edits_enabled() then
    M.apply_pending()
    return true
  end
  return false
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

  M.pending_patch = nil
  runner.clear()
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
    preview_instruction("Inspect the proposed replacement, then run :AIApply or :AIReject."),
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
  maybe_auto_apply_preview()
end

function M.preview_patch(opts)
  local patch_text = patch.extract(opts.text or "") or opts.text or ""
  if patch_text == "" then
    M.notify("AI response did not include a unified diff.", vim.log.levels.WARN)
    if opts.output_bufnr then
      M.set_output(opts.output_bufnr, opts.title or "patch-response", opts.text or "")
    else
      M.open_output(opts.title or "patch-response", opts.text or "")
    end
    return
  end

  M.pending_edit = nil
  runner.clear()
  M.pending_patch = {
    patch = patch_text,
    title = opts.title or "patch",
    cwd = opts.cwd or context.root(0),
  }

  local text = table.concat({
    "# AI patch preview",
    "",
    preview_instruction("Inspect the patch, then run :AIApply or :AIReject."),
    "",
    "```diff",
    patch_text,
    "```",
  }, "\n")

  if opts.output_bufnr then
    M.set_output(opts.output_bufnr, opts.title or "patch-preview", text, "markdown")
  else
    M.open_output(opts.title or "patch-preview", text, "markdown")
  end
  maybe_auto_apply_preview()
end

function M.preview_command(opts)
  local pending, err = runner.preview(opts.command or "", {
    title = opts.title,
    cwd = opts.cwd,
  })

  if err then
    M.notify(err, vim.log.levels.ERROR)
    if opts.output_bufnr then
      M.set_output(opts.output_bufnr, opts.title or "command-error", err)
    end
    return
  end

  M.pending_edit = nil
  M.pending_patch = nil

  local text = table.concat({
    "# AI command preview",
    "",
    "Inspect the command, then run :AIRun or :AIReject.",
    "",
    "CWD: " .. pending.cwd,
    "",
    "```sh",
    pending.command,
    "```",
  }, "\n")

  if opts.output_bufnr then
    M.set_output(opts.output_bufnr, opts.title or "command-preview", text, "markdown")
  else
    M.open_output(opts.title or "command-preview", text, "markdown")
  end
end

function M.apply_pending()
  if M.pending_patch then
    local pending = M.pending_patch
    M.notify("Applying AI patch...")
    patch.apply(pending.patch, function(err)
      if err then
        M.notify(err, vim.log.levels.ERROR)
        return
      end
      M.pending_patch = nil
      M.notify("AI patch applied.")
    end, { cwd = pending.cwd })
    return
  end

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

function M.run_pending_command()
  M.notify("Running AI command...")
  runner.run(function(err, output)
    if err then
      M.notify(err, vim.log.levels.ERROR)
      M.open_output("command-error", err)
      return
    end
    M.open_output("command-output", output, "markdown")
  end)
end

function M.reject_pending()
  M.pending_edit = nil
  M.pending_patch = nil
  runner.clear()
  M.notify("AI pending action cleared.")
end

return M
