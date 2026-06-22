local config = require("ai.config")
local context = require("ai.context")
local patch = require("ai.patch")
local popup = require("ai.popup")
local runner = require("ai.runner")
local target = require("ai.target")

local M = {
  pending_edit = nil,
  pending_patch = nil,
  pending_create = nil,
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
      -- output_cmd creates a window holding a fresh unnamed buffer; suspend
      -- target capture so the placeholder cannot steal the target, and delete
      -- it after swapping in the reused output buffer.
      target.with_suspended(function()
        vim.cmd(opts.output_cmd)
        M.output_winid = vim.api.nvim_get_current_win()
        local placeholder = vim.api.nvim_win_get_buf(M.output_winid)
        vim.api.nvim_win_set_buf(M.output_winid, M.output_bufnr)
        if placeholder ~= M.output_bufnr
          and vim.api.nvim_buf_is_valid(placeholder)
          and vim.api.nvim_buf_get_name(placeholder) == ""
          and not vim.bo[placeholder].modified then
          pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
        end
      end)
    end
    return M.output_bufnr
  end

  local bufnr
  target.with_suspended(function()
    vim.cmd(opts.output_cmd)
    bufnr = vim.api.nvim_get_current_buf()
    M.output_bufnr = bufnr
    M.output_winid = vim.api.nvim_get_current_win()
  end)
  return bufnr
end

local function set_winbar(bufnr, value)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(function()
        vim.wo[win].winbar = value
      end)
    end
  end
end

-- Close the window(s) showing a preview buffer. Used after a preview is
-- accepted or rejected so the (now stale) preview does not linger.
local function close_preview(bufnr)
  if not bufnr then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      if popup.winid == win then
        popup.close()
      else
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
end

-- The fixed accept/reject/close winbar hint shown on a preview window, built
-- from the configured buffer keymaps.
local function preview_hint()
  local keys = config.get().ui.buffer_keymaps or {}
  return ("%%#Title# %s accept · %s reject · %s close %%*"):format(
    keys.apply or "a",
    keys.reject or "r",
    keys.close or "q"
  )
end

-- Render a write preview (edit/patch/create). With no output_bufnr (a standalone
-- command) it opens a floating popup with the accept/reject winbar hint and
-- returns the bufnr to close on apply/reject. With an output_bufnr (a chat tool
-- call) it renders into that buffer as before and returns nil — that window is
-- managed by the caller, so we must not close it.
local function render_write_preview(opts, title, text, filetype)
  filetype = filetype or "markdown"
  -- A preview is "unmanaged" only when a chat tool renders into a buffer it owns
  -- (the conversation window): then we must not add a winbar or close it. A chat
  -- tool that opens its own popup (no output_bufnr) is still managed/closable, so
  -- apply/reject can close it instead of leaking a window.
  local managed = not (opts.source == "chat" and opts.output_bufnr)

  local bufnr = opts.output_bufnr
  if bufnr then
    if opts.output == "popup" then
      popup.set(bufnr, title, text, filetype)
    else
      M.set_output(bufnr, title, text, filetype)
    end
  else
    bufnr = popup.open(title, text, filetype)
  end

  if managed then
    set_winbar(bufnr, preview_hint())
    return bufnr
  end
  return nil
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
  -- Clear any action hint left over from a previous command/patch preview so a
  -- reused output window does not keep showing stale shortcuts.
  set_winbar(bufnr, "")
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

  if M.pending_create then
    return {
      kind = "create",
      title = "Pending AI file creation preview",
      apply = ":AIApply",
      reject = ":AIReject",
      message = "Run `:AIApply` to create this file or `:AIReject` to discard it.",
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

local function auto_write_edits_enabled()
  return config.get().safety and config.get().safety.auto_write_edits == true
end

local function auto_write_new_files_enabled()
  local safety = config.get().safety or {}
  return safety.auto_write_new_files ~= false
end

local function write_applied_buffers(bufnrs)
  if not auto_write_edits_enabled() then
    return false, {}
  end

  local errors = {}
  for _, bufnr in ipairs(bufnrs or {}) do
    if vim.api.nvim_buf_is_valid(bufnr)
      and vim.bo[bufnr].modified
      and vim.bo[bufnr].buftype == ""
      and vim.api.nvim_buf_get_name(bufnr) ~= "" then
      local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent keepalt update")
      end)
      if not ok then
        table.insert(errors, ("%s: %s"):format(vim.api.nvim_buf_get_name(bufnr), err))
      end
    end
  end
  return true, errors
end

local function disk_state_note(written, write_errors)
  if not written then
    return "Buffers are modified but not written to disk yet; the user must save them (or enable safety.auto_write_edits)."
  end
  if write_errors and #write_errors > 0 then
    return "Some buffers could not be written to disk:\n" .. table.concat(write_errors, "\n")
  end
  return "Modified buffers were written to disk."
end

local function continue_chat(source, text)
  if source ~= "chat" then
    return
  end
  local ok, chat = pcall(require, "ai.chat")
  if ok and type(chat.continue_with_apply_result) == "function" then
    chat.continue_with_apply_result(text)
  end
end

local function note_chat_event(source, text)
  if source ~= "chat" then
    return
  end
  local ok, chat = pcall(require, "ai.chat")
  if ok and type(chat.note_editor_event) == "function" then
    chat.note_editor_event(text)
  end
end

local function maybe_auto_apply_preview()
  if not M.auto_apply_edits_enabled() then
    return nil
  end

  local captured
  M.apply_pending(function(err, info)
    captured = { err = err, info = info }
  end)
  return captured or { err = "Auto apply did not complete." }
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
  M.pending_create = nil
  runner.clear()
  M.pending_edit = {
    bufnr = opts.bufnr,
    path = opts.path,
    line1 = opts.line1,
    line2 = opts.line2,
    original_lines = opts.original_lines,
    replacement_lines = replacement_lines,
    source = opts.source,
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

  M.pending_edit.output_bufnr = render_write_preview(opts, "edit-preview", text)
  return maybe_auto_apply_preview()
end

function M.preview_patch(opts)
  local patch_text = patch.extract(opts.text or "") or opts.text or ""
  if patch_text == "" then
    M.notify("AI response did not include a unified diff.", vim.log.levels.WARN)
    if opts.output_bufnr then
      if opts.output == "popup" then
        popup.set(opts.output_bufnr, opts.title or "patch-response", opts.text or "", "markdown")
      else
        M.set_output(opts.output_bufnr, opts.title or "patch-response", opts.text or "")
      end
    elseif opts.output == "popup" then
      popup.open(opts.title or "patch-response", opts.text or "", "markdown")
    else
      M.open_output(opts.title or "patch-response", opts.text or "")
    end
    return
  end

  M.pending_edit = nil
  M.pending_create = nil
  runner.clear()
  M.pending_patch = {
    patch = patch_text,
    title = opts.title or "patch",
    cwd = opts.cwd or context.root(0),
    source = opts.source,
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

  M.pending_patch.output_bufnr = render_write_preview(opts, opts.title or "patch-preview", text)
  return maybe_auto_apply_preview()
end

--- Preview creating a new project file. Applying loads the content into a new
--- buffer and writes it to disk when safety.auto_write_new_files is set (the
--- default); otherwise the file stays in the buffer until saved.
function M.preview_create(opts)
  local content_lines = split_lines(opts.content or "")

  M.pending_edit = nil
  M.pending_patch = nil
  runner.clear()
  M.pending_create = {
    path = opts.path,
    lines = content_lines,
    source = opts.source,
  }

  local filetype = vim.filetype.match({ filename = opts.path }) or "text"
  local text = table.concat({
    "# AI file creation preview: " .. opts.path,
    "",
    preview_instruction("Inspect the new file content, then run :AIApply or :AIReject."),
    "",
    "```" .. filetype,
    table.concat(content_lines, "\n"),
    "```",
  }, "\n")

  M.pending_create.output_bufnr = render_write_preview(opts, "create-preview", text)
  return maybe_auto_apply_preview()
end

function M.preview_command(opts)
  local pending, err = runner.preview(opts.command or "", {
    title = opts.title,
    cwd = opts.cwd,
    source = opts.source,
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
  M.pending_create = nil

  -- A chat tool call already shows the command in the conversation; don't open a
  -- separate preview window that would cover the chat. The pending command stays
  -- registered (runner.preview above), so auto-run / :AIRun still work.
  if opts.source == "chat" then
    return
  end

  local keys = config.get().ui.buffer_keymaps or {}
  local accept_key = keys.apply or "a"
  local reject_key = keys.reject or "r"
  local close_key = keys.close or "q"
  local lines = {
    "# AI command preview",
    "",
    ("Press %s to accept (run) or %s to reject. (:AIRun / :AIReject also work.)"):format(accept_key, reject_key),
    "",
  }
  if opts.note and opts.note ~= "" then
    for _, line in ipairs(vim.split(opts.note, "\n", { plain = true })) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, {
    "CWD: " .. pending.cwd,
    "",
    "```sh",
    pending.command,
    "```",
  })
  local text = table.concat(lines, "\n")

  local bufnr = opts.output_bufnr
  if bufnr then
    M.set_output(bufnr, opts.title or "command-preview", text, "markdown")
  else
    bufnr = M.open_output(opts.title or "command-preview", text, "markdown")
  end

  -- Remember the preview window so it can be closed once the command runs.
  pending.output_bufnr = bufnr

  -- A fixed top-of-window hint so the accept/reject shortcuts are visible
  -- without scrolling. set_output above cleared any previous winbar first.
  local hint = ("%%#Title# %s accept · %s reject · %s close %%*"):format(accept_key, reject_key, close_key)
  set_winbar(bufnr, hint)
end

--- Apply the pending edit or patch.
--- cb(err, info) is optional; info = { kind, message, written, write_errors, path }.
--- Without cb (user-initiated :AIApply), the outcome is also fed back to AIChat
--- when the preview was created from a chat tool call.
function M.apply_pending(cb)
  if type(cb) ~= "function" then
    cb = nil
  end

  if M.pending_patch then
    local pending = M.pending_patch
    M.notify("Applying AI patch...")
    patch.apply(pending.patch, function(err, message, bufnrs)
      if err then
        M.notify(err, vim.log.levels.ERROR)
        if cb then
          cb(err)
        else
          continue_chat(pending.source, "Applying the patch preview failed:\n" .. err)
        end
        return
      end

      M.pending_patch = nil
      close_preview(pending.output_bufnr)
      local written, write_errors = write_applied_buffers(bufnrs)
      local full_message = (message or "AI patch applied.") .. " " .. disk_state_note(written, write_errors)
      M.notify(full_message)
      local info = {
        kind = "patch",
        message = full_message,
        written = written and #write_errors == 0,
        write_errors = write_errors,
      }
      if cb then
        cb(nil, info)
      else
        continue_chat(pending.source, "The user applied the patch preview. " .. full_message)
      end
    end, { cwd = pending.cwd })
    return
  end

  if M.pending_create then
    local pending = M.pending_create

    local function create_fail(err)
      M.notify(err, vim.log.levels.ERROR)
      if cb then
        cb(err)
      else
        continue_chat(pending.source, "Creating the file failed: " .. err)
      end
    end

    if vim.fn.filereadable(pending.path) == 1 then
      M.pending_create = nil
      create_fail("File already exists: " .. pending.path)
      return
    end

    local parent = vim.fs.dirname(pending.path)
    if parent and parent ~= "" and vim.fn.isdirectory(parent) == 0 then
      local ok = pcall(vim.fn.mkdir, parent, "p")
      if not ok then
        create_fail("Could not create directory: " .. parent)
        return
      end
    end

    local bufnr = vim.fn.bufadd(pending.path)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].buflisted = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, pending.lines)
    M.pending_create = nil
    close_preview(pending.output_bufnr)

    -- A create preview should produce a real file by default. When
    -- auto_write_new_files is enabled, write it regardless of auto_write_edits
    -- (which only gates in-place edits to existing files).
    local written, write_errors
    if auto_write_new_files_enabled() then
      write_errors = {}
      local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent keepalt write")
      end)
      written = ok
      if not ok then
        table.insert(write_errors, ("%s: %s"):format(pending.path, err))
      end
    else
      written, write_errors = write_applied_buffers({ bufnr })
    end
    local full_message = ("AI file created: %s (%d lines). %s"):format(
      pending.path,
      #pending.lines,
      disk_state_note(written, write_errors)
    )
    M.notify(full_message)
    local info = {
      kind = "create",
      path = pending.path,
      bufnr = bufnr,
      message = full_message,
      written = written and #write_errors == 0,
      write_errors = write_errors,
    }
    if cb then
      cb(nil, info)
    else
      continue_chat(pending.source, "The user applied the file creation preview. " .. full_message)
    end
    return
  end

  local edit = M.pending_edit
  if not edit then
    -- Accept a pending command (e.g. :AICommit) so the same accept key works
    -- for command previews. Only for user-initiated accepts (no cb), never for
    -- chat tool applies.
    if not cb and runner.pending then
      M.run_pending_command()
      return
    end
    M.notify("No pending AI edit.", vim.log.levels.WARN)
    if cb then
      cb("No pending AI edit.")
    end
    return
  end

  local function fail(err)
    M.notify(err, vim.log.levels.ERROR)
    if cb then
      cb(err)
    else
      continue_chat(edit.source, "Applying the edit preview failed: " .. err)
    end
  end

  if not vim.api.nvim_buf_is_valid(edit.bufnr) then
    M.pending_edit = nil
    fail("Target buffer no longer exists.")
    return
  end

  local current = vim.api.nvim_buf_get_lines(edit.bufnr, edit.line1 - 1, edit.line2, false)
  if not same_lines(current, edit.original_lines) then
    fail("Target text changed after preview; refusing to apply stale edit.")
    return
  end

  vim.api.nvim_buf_set_lines(edit.bufnr, edit.line1 - 1, edit.line2, false, edit.replacement_lines)
  M.pending_edit = nil
  close_preview(edit.output_bufnr)
  local written, write_errors = write_applied_buffers({ edit.bufnr })
  local full_message = ("AI edit applied to %s:%d-%d. %s"):format(
    edit.path ~= "" and edit.path or "[No Name]",
    edit.line1,
    edit.line2,
    disk_state_note(written, write_errors)
  )
  M.notify(full_message)
  local info = {
    kind = "edit",
    path = edit.path,
    message = full_message,
    written = written and #write_errors == 0,
    write_errors = write_errors,
  }
  if cb then
    cb(nil, info)
  else
    continue_chat(edit.source, "The user applied the edit preview. " .. full_message)
  end
end

function M.run_pending_command()
  M.notify("Running AI command...")
  runner.run(function(err, output, pending, result)
    if err then
      M.notify(err, vim.log.levels.ERROR)
      return
    end
    -- The command ran (whatever its exit code); drop the stale preview window.
    close_preview(pending and pending.output_bufnr)
    if result and result.code ~= 0 then
      local detail = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
      M.notify(
        ("AI command failed (exit %d)%s"):format(result.code, detail ~= "" and (": " .. detail) or ""),
        vim.log.levels.ERROR
      )
    else
      local detail = vim.trim((result and result.stdout) or "")
      M.notify(detail ~= "" and detail or "AI command finished.")
    end
    if pending and pending.source == "chat" then
      local ok, chat = pcall(require, "ai.chat")
      if ok and type(chat.continue_with_command_output) == "function" then
        chat.continue_with_command_output(output)
      end
    end
  end)
end

function M.reject_pending()
  local action = M.pending_action()
  local source = (M.pending_edit and M.pending_edit.source)
    or (M.pending_patch and M.pending_patch.source)
    or (M.pending_create and M.pending_create.source)
    or (runner.pending and runner.pending.source)
  close_preview(
    (M.pending_edit and M.pending_edit.output_bufnr)
      or (M.pending_patch and M.pending_patch.output_bufnr)
      or (M.pending_create and M.pending_create.output_bufnr)
      or (runner.pending and runner.pending.output_bufnr)
  )
  M.pending_edit = nil
  M.pending_patch = nil
  M.pending_create = nil
  runner.clear()
  M.notify("AI pending action cleared.")
  if action then
    note_chat_event(source, ("The user rejected the pending %s preview without applying it."):format(action.kind))
  end
end

return M
