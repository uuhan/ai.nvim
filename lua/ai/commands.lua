local agent = require("ai.agent")
local client = require("ai.client")
local config = require("ai.config")
local context = require("ai.context")
local locations = require("ai.locations")
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

local function request_output(title, req_messages, opts, bufnr, on_success)
  opts = opts or {}
  bufnr = bufnr or ui.open_output(title, "Requesting AI response...")
  ui.set_output(bufnr, title, "Requesting AI response...")

  local use_stream = opts.stream
  if use_stream == nil then
    use_stream = config.get().provider.stream
  end

  if use_stream then
    local text = ""
    client.chat_stream(req_messages, opts, {
      on_delta = function(delta)
        text = text .. delta
        ui.set_output(bufnr, title, text)
      end,
      on_error = function(err)
        ui.set_output(bufnr, title .. "-error", err)
      end,
      on_done = function()
        if on_success then
          on_success(text, bufnr)
        end
      end,
    })
    return
  end

  client.chat(req_messages, opts, function(err, text)
    if err then
      ui.set_output(bufnr, title .. "-error", err)
      return
    end
    ui.set_output(bufnr, title, text)
    if on_success then
      on_success(text, bufnr)
    end
  end)
end

local function request_patch(title, req_messages, bufnr)
  local cwd = context.root(0)
  bufnr = bufnr or ui.open_output(title, "Requesting AI patch...")
  ui.set_output(bufnr, title, "Requesting AI patch...")
  client.chat(req_messages, {}, function(err, text)
    if err then
      ui.set_output(bufnr, title .. "-error", err)
      return
    end
    ui.preview_patch({
      title = title,
      text = text,
      cwd = cwd,
      output_bufnr = bufnr,
    })
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

local function rel_path(path)
  local root = context.root(0)
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
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
    "Fix the following Neovim LSP diagnostic.",
    "Return only a unified diff that can be applied with git apply.",
    "Use paths relative to the project root.",
    "",
    ("Project root: %s"):format(context.root(0)),
    ("File: %s"):format(diag.path ~= "" and rel_path(diag.path) or "[No Name]"),
    ("Filetype: %s"):format(diag.filetype ~= "" and diag.filetype or "unknown"),
    ("Diagnostic: %s"):format(diag.diagnostic.message or ""),
    ("Context lines: %d-%d"):format(diag.context_start, diag.context_end),
    "",
    "```" .. (diag.filetype ~= "" and diag.filetype or "text"),
    diag.text,
    "```",
  }, "\n")

  request_patch("diagnostic-fix", messages(prompt))
end

function M.fix_all_diagnostics()
  local diagnostics = context.all_diagnostics_context(120)
  if diagnostics == "" then
    ui.notify("No diagnostics found in loaded buffers.", vim.log.levels.WARN)
    return
  end

  local prompt = table.concat({
    "Fix these Neovim LSP diagnostics.",
    "Return only a unified diff that can be applied with git apply.",
    "Use paths relative to the project root.",
    "",
    ("Project root: %s"):format(context.root(0)),
    "",
    diagnostics,
  }, "\n")

  request_patch("diagnostics-fix-all", messages(prompt))
end

function M.fix_quickfix()
  local qf = context.quickfix_context(80)
  if qf == "" then
    ui.notify("Quickfix list is empty.", vim.log.levels.WARN)
    return
  end
  local prompt = table.concat({
    "Fix these quickfix entries.",
    "Return only a unified diff that can be applied with git apply.",
    "Use paths relative to the project root.",
    "",
    ("Project root: %s"):format(context.root(0)),
    "",
    qf,
  }, "\n")
  request_patch("quickfix-fix", messages(prompt))
end

local function git_request(title, instruction, on_success)
  local root = context.root(0)
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
    }, "\n")), nil, bufnr, function(text, output_bufnr)
      if on_success then
        on_success(text, output_bufnr, root)
      end
    end)
  end, root)
end

function M.review_diff()
  git_request("diff-review", "Review this git diff. Prioritize correctness bugs, regressions, missing tests, and security issues. Use file/line references when possible.", function(text, _, root)
    local count = locations.populate(text, "AI diff review", root)
    if count > 0 then
      ui.notify(("Added %d AI review locations."):format(count))
    end
  end)
end

function M.explain_diff()
  git_request("diff-explain", "Explain what changed in this git diff. Keep it concise and developer-facing.")
end

function M.find_bug_in_diff()
  git_request("diff-bugs", "Look for likely bugs in this git diff. Be strict. If there are no clear bugs, say so. Use file:line references for findings.", function(text, _, root)
    local count = locations.populate(text, "AI diff bugs", root)
    if count > 0 then
      ui.notify(("Added %d AI bug locations."):format(count))
    end
  end)
end

function M.commit_message()
  git_request("commit-message", "Write a concise commit message for this diff. Return only the commit message.")
end

function M.project(cmd)
  local prompt = user_prompt(cmd, "Answer the question using project context.")
  local root = context.root(0)
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
  end, root)
end

local function command_request(title, prompt)
  local cwd = context.root(0)
  local bufnr = ui.open_output(title, "Requesting shell command...")
  client.chat(messages(prompt), {}, function(err, text)
    if err then
      ui.set_output(bufnr, title .. "-error", err)
      return
    end
    ui.preview_command({
      title = title,
      command = text,
      cwd = cwd,
      output_bufnr = bufnr,
    })
  end)
end

local function command_prompt(cmd, mode)
  local task = user_prompt(cmd, "Generate a useful command for the current project.")
  local constraints = {
    "Generate exactly one shell command for the user's task.",
    "Return only the command, with no markdown and no explanation.",
    "Do not include destructive commands.",
    "Assume the command will be reviewed before execution.",
  }

  if mode == "git" then
    table.insert(constraints, "The command must be a git command.")
  end

  return table.concat(vim.list_extend(constraints, {
    "",
    ("Project root: %s"):format(context.root(0)),
    ("Shell: %s"):format(vim.o.shell ~= "" and vim.o.shell or "sh"),
    "",
    "User task:",
    task,
  }), "\n")
end

function M.cmd(cmd)
  command_request("command", command_prompt(cmd, "shell"))
end

function M.shell(cmd)
  M.cmd(cmd)
end

function M.git_cmd(cmd)
  command_request("git-command", command_prompt(cmd, "git"))
end

local function agent_prompt(task, root, buf, diagnostics, quickfix, git_diff, project_context)
  return table.concat({
    "Create a step-by-step AI agent plan for this Neovim coding task.",
    "Return only a JSON object. Do not include markdown.",
    "Do not assume actions were already performed.",
    "Do not include destructive shell commands.",
    "Prefer inspect steps before patch or command steps when information is incomplete.",
    "Patch steps must include a unified diff in the `patch` field if and only if the patch is already clear from the provided context.",
    "Command or test steps must include exactly one shell command in the `command` field.",
    "",
    "JSON schema:",
    [[{"task":"string","summary":"string","steps":[{"type":"inspect|patch|command|test","title":"string","details":"string","patch":"optional unified diff","command":"optional shell command"}]}]],
    "",
    "Project root:",
    root,
    "",
    "User task:",
    task,
    "",
    "Current buffer:",
    ("File: %s"):format(buf.path ~= "" and buf.path or "[No Name]"),
    ("Filetype: %s"):format(buf.filetype ~= "" and buf.filetype or "unknown"),
    "```" .. (buf.filetype ~= "" and buf.filetype or "text"),
    buf.text,
    "```",
    "",
    "Diagnostics:",
    diagnostics ~= "" and diagnostics or "No diagnostics.",
    "",
    "Quickfix:",
    quickfix ~= "" and quickfix or "Quickfix list is empty.",
    "",
    "Git context:",
    git_diff ~= "" and git_diff or "No git context.",
    "",
    "Project search context:",
    project_context ~= "" and project_context or "No project search context.",
  }, "\n")
end

function M.agent(cmd)
  local task = user_prompt(cmd, "Plan the next useful coding step.")
  local root = context.root(0)
  local bufnr = ui.open_output("agent", "Collecting agent context...")
  local buf = context.buffer_context(0, math.floor(config.get().project.max_context_chars / 2))
  local diagnostics = context.all_diagnostics_context(120)
  local quickfix = context.quickfix_context(80)

  context.git_diff(function(git_err, git_diff)
    if git_err then
      git_diff = "Git context unavailable:\n" .. git_err
    end

    ui.set_output(bufnr, "agent", "Searching project context...")
    context.project_context(task, function(project_err, project_ctx)
      if project_err then
        project_ctx = "Project context unavailable:\n" .. project_err
      end

      ui.set_output(bufnr, "agent", "Requesting AI plan...")
      client.chat(messages(agent_prompt(task, root, buf, diagnostics, quickfix, git_diff or "", project_ctx or ""), [[You are planning editor actions for ai.nvim.
Return machine-readable JSON only.
The plan must be reviewable and must not automatically modify files or run commands.]]), { stream = false }, function(err, text)
        if err then
          ui.set_output(bufnr, "agent-error", err)
          return
        end

        local plan, parse_err = agent.parse(text)
        if not plan then
          ui.set_output(bufnr, "agent-error", parse_err .. "\n\n" .. text)
          return
        end

        agent.set(plan, { task = task, cwd = root })
        local rendered = agent.render()
        if parse_err then
          rendered = rendered .. "\n\n" .. parse_err
        end
        ui.set_output(bufnr, "agent-plan", rendered)
      end)
    end, root)
  end, root)
end

local function agent_step(fn)
  local _, err = fn()
  if err then
    ui.notify(err, vim.log.levels.ERROR)
  end
end

function M.plan_next()
  agent_step(agent.preview_next)
end

function M.plan_apply()
  agent_step(agent.preview_next_patch)
end

function M.plan_run()
  agent_step(agent.preview_next_command)
end

function M.plan_done()
  local step, err = agent.mark_done()
  if err then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end
  ui.notify("Marked AI plan step done: " .. step.title)
  ui.open_output("agent-plan", agent.render())
end

function M.plan_skip()
  local step, err = agent.skip()
  if err then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end
  ui.notify("Skipped AI plan step: " .. step.title)
  ui.open_output("agent-plan", agent.render())
end

function M.plan_show()
  ui.open_output("agent-plan", agent.render())
end

function M.plan_reset()
  agent.reset()
  ui.notify("AI plan cleared.")
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
    if config.get().provider.stream then
      local text = ""
      client.chat_stream(req, {}, {
        on_delta = function(delta)
          text = text .. delta
          ui.set_output(bufnr, "chat", text)
        end,
        on_error = function(err)
          ui.set_output(bufnr, "chat-error", err)
        end,
        on_done = function()
          table.insert(M.chat_history, { role = "assistant", content = text })
        end,
      })
      return
    end

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
  create_command("AIFixAllDiagnostics", M.fix_all_diagnostics, { nargs = 0, range = false })
  create_command("AIFixQuickfix", M.fix_quickfix, { nargs = 0, range = false })
  create_command("AIReviewDiff", M.review_diff, { nargs = 0, range = false })
  create_command("AIExplainDiff", M.explain_diff, { nargs = 0, range = false })
  create_command("AIFindBugInDiff", M.find_bug_in_diff, { nargs = 0, range = false })
  create_command("AICommitMessage", M.commit_message, { nargs = 0, range = false })
  create_command("AIProject", M.project, { range = false })
  create_command("AIAskProject", M.project, { range = false })
  create_command("AICmd", M.cmd, { range = false })
  create_command("AIShell", M.shell, { range = false })
  create_command("AIGit", M.git_cmd, { range = false })
  create_command("AIAgent", M.agent, { range = false })
  create_command("AIPlanNext", M.plan_next, { nargs = 0, range = false })
  create_command("AIPlanApply", M.plan_apply, { nargs = 0, range = false })
  create_command("AIPlanRun", M.plan_run, { nargs = 0, range = false })
  create_command("AIPlanDone", M.plan_done, { nargs = 0, range = false })
  create_command("AIPlanSkip", M.plan_skip, { nargs = 0, range = false })
  create_command("AIPlanShow", M.plan_show, { nargs = 0, range = false })
  create_command("AIPlanReset", M.plan_reset, { nargs = 0, range = false })
  create_command("AIChat", M.chat, { range = false })
  create_command("AIChatReset", M.chat_reset, { nargs = 0, range = false })
  create_command("AIApply", ui.apply_pending, { nargs = 0, range = false })
  create_command("AIRun", ui.run_pending_command, { nargs = 0, range = false })
  create_command("AIReject", ui.reject_pending, { nargs = 0, range = false })
  create_command("AIRules", M.show_rules, { nargs = 0, range = false })
  create_command("AIConfig", M.show_config, { nargs = 0, range = false })
end

return M
