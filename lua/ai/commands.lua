local client = require("ai.client")
local config = require("ai.config")
local context = require("ai.context")
local ui = require("ai.ui")

local M = {
  chat_history = {},
}

local function system_prompt()
  local rules = context.rules(0)
  local base = [[You are an AI pair programmer embedded in Neovim.
Be concrete, minimal, and editor-aware.
When asked to edit code, preserve behavior unless the user asks otherwise.
Prefer small patches and explain tradeoffs only when they matter.]]

  if rules ~= "" then
    return base .. "\n\nProject rules:\n" .. rules
  end
  return base
end

local function messages(user_content, extra_system)
  local sys = system_prompt()
  if extra_system and extra_system ~= "" then
    sys = sys .. "\n\n" .. extra_system
  end
  return {
    { role = "system", content = sys },
    { role = "user", content = user_content },
  }
end

local function request_output(title, req_messages, opts, bufnr)
  bufnr = bufnr or ui.open_output(title, "Requesting AI response...")
  ui.set_output(bufnr, title, "Requesting AI response...")
  client.chat(req_messages, opts or {}, function(err, text)
    if err then
      ui.set_output(bufnr, title .. "-error", err)
      return
    end
    ui.set_output(bufnr, title, text)
  end)
end

local function selection_prompt(cmd, instruction)
  local sel = context.selection_context(cmd)
  return sel, table.concat({
    instruction,
    "",
    ("File: %s"):format(sel.path ~= "" and sel.path or "[No Name]"),
    ("Filetype: %s"):format(sel.filetype ~= "" and sel.filetype or "unknown"),
    ("Lines: %d-%d"):format(sel.line1, sel.line2),
    "",
    "```" .. (sel.filetype ~= "" and sel.filetype or "text"),
    sel.text,
    "```",
  }, "\n")
end

local function edit_selection(cmd, instruction)
  local sel, prompt = selection_prompt(cmd, table.concat({
    instruction,
    "",
    "Return only the complete replacement text for the selected range.",
    "Do not include explanation, markdown fences, or diff markers.",
  }, "\n"))

  local bufnr = ui.open_output("edit-request", "Requesting replacement...")
  client.chat(messages(prompt), {}, function(err, text)
    if err then
      ui.set_output(bufnr, "edit-error", err)
      return
    end
    ui.preview_edit({
      bufnr = sel.bufnr,
      path = sel.path,
      line1 = sel.line1,
      line2 = sel.line2,
      original_lines = sel.lines,
      replacement = text,
      output_bufnr = bufnr,
    })
  end)
end

local function ask_selection(cmd, instruction, title)
  local _, prompt = selection_prompt(cmd, instruction)
  request_output(title, messages(prompt))
end

local function user_prompt(cmd, fallback)
  local args = cmd.args or ""
  if args == "" then
    return fallback
  end
  return args
end

local function full_buffer_prompt(cmd, instruction)
  local buf = context.buffer_context(0, config.get().project.max_context_chars)
  return table.concat({
    instruction,
    "",
    ("File: %s"):format(buf.path ~= "" and buf.path or "[No Name]"),
    ("Filetype: %s"):format(buf.filetype ~= "" and buf.filetype or "unknown"),
    "",
    "```" .. (buf.filetype ~= "" and buf.filetype or "text"),
    buf.text,
    "```",
    "",
    "User request:",
    user_prompt(cmd, "Analyze this buffer."),
  }, "\n")
end

local function create_command(name, fn, opts)
  opts = vim.tbl_extend("force", {
    nargs = "*",
    range = true,
  }, opts or {})

  pcall(vim.api.nvim_del_user_command, name)
  vim.api.nvim_create_user_command(name, fn, opts)
end

function M.ai(cmd)
  local prompt = user_prompt(cmd, "Explain this code and call out any important risks.")
  ask_selection(cmd, "User request:\n" .. prompt, "selection")
end

function M.explain(cmd)
  ask_selection(cmd, "Explain the selected code clearly. Include purpose, important control flow, and edge cases.", "explain")
end

function M.refactor(cmd)
  edit_selection(cmd, user_prompt(cmd, "Refactor this code for clarity while preserving behavior."))
end

function M.fix(cmd)
  edit_selection(cmd, user_prompt(cmd, "Fix bugs in this code while preserving the public contract."))
end

function M.edit(cmd)
  edit_selection(cmd, user_prompt(cmd, "Improve this code while preserving behavior."))
end

function M.test(cmd)
  ask_selection(cmd, "Suggest focused tests for this code. Include test names and cases, not broad testing advice.", "tests")
end

function M.buffer(cmd)
  request_output("buffer", messages(full_buffer_prompt(cmd, "Answer using the current buffer as context.")))
end

function M.file(cmd)
  M.buffer(cmd)
end

function M.summarize_file()
  local buf = context.buffer_context(0, config.get().project.max_context_chars)
  local prompt = table.concat({
    "Summarize this file for a developer who is editing it in Neovim.",
    "Focus on structure, important symbols, responsibilities, and risky areas.",
    "",
    ("File: %s"):format(buf.path ~= "" and buf.path or "[No Name]"),
    ("Filetype: %s"):format(buf.filetype ~= "" and buf.filetype or "unknown"),
    "",
    "```" .. (buf.filetype ~= "" and buf.filetype or "text"),
    buf.text,
    "```",
  }, "\n")
  request_output("file-summary", messages(prompt))
end

function M.fix_diagnostic()
  local diag = context.diagnostic_context()
  if not diag then
    ui.notify("No diagnostic on the current line.", vim.log.levels.WARN)
    return
  end

  local prompt = table.concat({
    "Fix or explain the following Neovim LSP diagnostic.",
    "Prefer a minimal patch. If a patch is useful, show it as a unified diff.",
    "",
    ("File: %s"):format(diag.path ~= "" and diag.path or "[No Name]"),
    ("Filetype: %s"):format(diag.filetype ~= "" and diag.filetype or "unknown"),
    ("Diagnostic: %s"):format(diag.diagnostic.message or ""),
    ("Context lines: %d-%d"):format(diag.context_start, diag.context_end),
    "",
    "```" .. (diag.filetype ~= "" and diag.filetype or "text"),
    diag.text,
    "```",
  }, "\n")

  request_output("diagnostic-fix", messages(prompt))
end

function M.fix_quickfix()
  local qf = context.quickfix_context(80)
  if qf == "" then
    ui.notify("Quickfix list is empty.", vim.log.levels.WARN)
    return
  end
  local prompt = table.concat({
    "Review these quickfix entries and propose the smallest fixes.",
    "Group related errors and include file/line references.",
    "",
    qf,
  }, "\n")
  request_output("quickfix-fix", messages(prompt))
end

local function git_request(title, instruction)
  local bufnr = ui.open_output(title, "Reading git diff...")
  context.git_diff(function(err, diff)
    if err then
      ui.set_output(bufnr, title .. "-error", err)
      return
    end
    if diff:gsub("%s+", "") == "#gitstatus--short#gitdiff#gitdiff--cached" then
      ui.set_output(bufnr, title, "No git changes found.")
      return
    end

    request_output(title, messages(table.concat({
      instruction,
      "",
      diff,
    }, "\n")), nil, bufnr)
  end)
end

function M.review_diff()
  git_request("diff-review", "Review this git diff. Prioritize correctness bugs, regressions, missing tests, and security issues. Use file/line references when possible.")
end

function M.explain_diff()
  git_request("diff-explain", "Explain what changed in this git diff. Keep it concise and developer-facing.")
end

function M.find_bug_in_diff()
  git_request("diff-bugs", "Look for likely bugs in this git diff. Be strict. If there are no clear bugs, say so.")
end

function M.commit_message()
  git_request("commit-message", "Write a concise commit message for this diff. Return only the commit message.")
end

function M.project(cmd)
  local prompt = user_prompt(cmd, "Answer the question using project context.")
  local bufnr = ui.open_output("project", "Searching project context...")
  context.project_context(prompt, function(err, project_context)
    if err then
      ui.set_output(bufnr, "project-error", err)
      return
    end
    request_output("project", messages(table.concat({
      "Answer the user question using the project context below.",
      "Cite file paths or line references when the context includes them.",
      "",
      "Question:",
      prompt,
      "",
      "Project context:",
      project_context,
    }, "\n")), nil, bufnr)
  end)
end

function M.chat(cmd)
  local prompt = cmd.args or ""

  local function send(message)
    if message == nil or message == "" then
      return
    end
    table.insert(M.chat_history, { role = "user", content = message })
    local req = {
      { role = "system", content = system_prompt() },
    }
    vim.list_extend(req, M.chat_history)
    local bufnr = ui.open_output("chat", "Requesting AI response...")
    client.chat(req, {}, function(err, text)
      if err then
        ui.set_output(bufnr, "chat-error", err)
        return
      end
      table.insert(M.chat_history, { role = "assistant", content = text })
      ui.set_output(bufnr, "chat", text)
    end)
  end

  if prompt ~= "" then
    send(prompt)
    return
  end

  vim.ui.input({ prompt = "AI> " }, send)
end

function M.chat_reset()
  M.chat_history = {}
  ui.notify("AI chat history cleared.")
end

function M.show_rules()
  local rules = context.rules(0)
  if rules == "" then
    rules = "No project rule files found."
  end
  ui.open_output("rules", rules)
end

function M.show_config()
  local opts = vim.deepcopy(config.get())
  if opts.provider.api_key then
    opts.provider.api_key = "[redacted]"
  end
  ui.open_output("config", vim.inspect(opts), "lua")
end

function M.setup()
  create_command("AI", M.ai)
  create_command("AIExplain", M.explain)
  create_command("AIRefactor", M.refactor)
  create_command("AIFix", M.fix)
  create_command("AIEdit", M.edit)
  create_command("AITest", M.test)
  create_command("AIBuffer", M.buffer, { range = false })
  create_command("AIFile", M.file, { range = false })
  create_command("AISummarizeFile", M.summarize_file, { nargs = 0, range = false })
  create_command("AIFixDiagnostic", M.fix_diagnostic, { nargs = 0, range = false })
  create_command("AIFixQuickfix", M.fix_quickfix, { nargs = 0, range = false })
  create_command("AIReviewDiff", M.review_diff, { nargs = 0, range = false })
  create_command("AIExplainDiff", M.explain_diff, { nargs = 0, range = false })
  create_command("AIFindBugInDiff", M.find_bug_in_diff, { nargs = 0, range = false })
  create_command("AICommitMessage", M.commit_message, { nargs = 0, range = false })
  create_command("AIProject", M.project, { range = false })
  create_command("AIAskProject", M.project, { range = false })
  create_command("AIChat", M.chat, { range = false })
  create_command("AIChatReset", M.chat_reset, { nargs = 0, range = false })
  create_command("AIApply", ui.apply_pending, { nargs = 0, range = false })
  create_command("AIReject", ui.reject_pending, { nargs = 0, range = false })
  create_command("AIRules", M.show_rules, { nargs = 0, range = false })
  create_command("AIConfig", M.show_config, { nargs = 0, range = false })
end

return M
