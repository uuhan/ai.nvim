local agent = require("ai.agent")
local chat_panel = require("ai.chat")
local client = require("ai.client")
local config = require("ai.config")
local context = require("ai.context")
local locations = require("ai.locations")
local popup = require("ai.popup")
local stream_buffer = require("ai.stream_buffer")
local tools = require("ai.tools")
local ui = require("ai.ui")

local M = {}
local rel_path

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

local function configured_system_prompt()
  local prompt = config.get().system_prompt
  if type(prompt) == "function" then
    local ok, value = pcall(prompt)
    if not ok then
      return ""
    end
    prompt = value
  end

  if type(prompt) == "table" then
    local lines = {}
    for _, item in ipairs(prompt) do
      if type(item) == "string" and item ~= "" then
        table.insert(lines, item)
      end
    end
    prompt = table.concat(lines, "\n")
  end

  if type(prompt) ~= "string" then
    return ""
  end

  return (prompt:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function system_prompt()
  local rules = context.rules(0)
  local user_prompt = configured_system_prompt()
  local base = [[You are an AI pair programmer embedded in Neovim.
Be concrete, minimal, and editor-aware.
When asked to edit code, preserve behavior unless the user asks otherwise.
Prefer small patches and explain tradeoffs only when they matter.]]

  if user_prompt ~= "" then
    base = base .. "\n\nUser system instructions:\n" .. user_prompt
  end

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

local function provider_opts(opts)
  local out = vim.tbl_extend("force", {}, opts or {})
  out.output = nil
  out.filetype = nil
  return out
end

local function open_response_output(title, text, opts)
  opts = opts or {}
  if opts.output == "popup" then
    return popup.open(title, text, opts.filetype or "markdown")
  end
  return ui.open_output(title, text, opts.filetype)
end

local function set_response_output(bufnr, title, text, opts)
  opts = opts or {}
  if opts.output == "popup" then
    return popup.set(bufnr, title, text, opts.filetype or "markdown")
  end
  return ui.set_output(bufnr, title, text, opts.filetype)
end

local function request_output(title, req_messages, opts, bufnr, on_success)
  opts = opts or {}
  local req_opts = provider_opts(opts)
  bufnr = bufnr or open_response_output(title, "Requesting AI response...", opts)
  set_response_output(bufnr, title, "Requesting AI response...", opts)

  local use_stream = req_opts.stream
  if use_stream == nil then
    use_stream = config.get().provider.stream
  end

  if use_stream then
    local renderer
    renderer = stream_buffer.new({
      on_update = function(text)
        set_response_output(bufnr, title, text, opts)
      end,
      on_done = function(text)
        if on_success then
          on_success(text, bufnr)
        end
      end,
    })
    client.chat_stream(req_messages, req_opts, {
      on_delta = function(delta)
        renderer.push(delta)
      end,
      on_error = function(err)
        renderer.cancel()
        set_response_output(bufnr, title .. "-error", err, opts)
      end,
      on_done = function()
        renderer.finish()
      end,
    })
    return
  end

  client.chat(req_messages, req_opts, function(err, text)
    if err then
      set_response_output(bufnr, title .. "-error", err, opts)
      return
    end
    set_response_output(bufnr, title, text, opts)
    if on_success then
      on_success(text, bufnr)
    end
  end)
end

local function request_patch(title, req_messages, bufnr, cwd)
  cwd = cwd or context.root(0)
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

local function build_selection_prompt(sel, instruction, semantic_context)
  local lines = {
    instruction,
    "",
    ("File: %s"):format(sel.path ~= "" and sel.path or "[No Name]"),
    ("Filetype: %s"):format(sel.filetype ~= "" and sel.filetype or "unknown"),
    ("Lines: %d-%d"):format(sel.line1, sel.line2),
    "",
    "```" .. (sel.filetype ~= "" and sel.filetype or "text"),
    sel.text,
    "```",
  }

  if semantic_context and semantic_context ~= "" then
    vim.list_extend(lines, {
      "",
      "Language context:",
      semantic_context,
    })
  end

  return table.concat(lines, "\n")
end

local function run_context_tool(name, args, cb)
  tools.run(name, args or {}, function(err, result)
    if err then
      cb(nil)
      return
    end
    cb(result)
  end)
end

local function format_location_items(result, max_items, root)
  if type(result) ~= "table" or result.available == false or type(result.items) ~= "table" or vim.tbl_isempty(result.items) then
    return nil
  end

  local lines = {}
  for index, item in ipairs(result.items) do
    if max_items and index > max_items then
      table.insert(lines, "[truncated]")
      break
    end
    table.insert(lines, ("%s:%s:%s"):format(item.path ~= "" and rel_path(item.path, root) or "[No Name]", item.lnum or 0, item.col or 0))
    if item.snippet and item.snippet.text and item.snippet.text ~= "" then
      table.insert(lines, "```text")
      table.insert(lines, item.snippet.text)
      table.insert(lines, "```")
    end
  end
  return table.concat(lines, "\n")
end

local function format_symbols(result, max_items, root)
  if type(result) ~= "table" or result.available == false or type(result.items) ~= "table" or vim.tbl_isempty(result.items) then
    return nil
  end

  local lines = {}
  for index, item in ipairs(result.items) do
    if max_items and index > max_items then
      table.insert(lines, "[truncated]")
      break
    end
    local indent = string.rep("  ", tonumber(item.depth) or 0)
    local location = item.lnum and (" " .. rel_path(item.path or "", root) .. ":" .. item.lnum) or ""
    table.insert(lines, ("%s- %s `%s`%s"):format(indent, item.kind ~= "" and item.kind or "Symbol", item.name or "", location))
  end
  return table.concat(lines, "\n")
end

local function diagnostics_for_range(sel)
  local bufnr = sel.bufnr or 0
  local root = sel.root or context.root(bufnr)
  local diagnostics = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    local lnum = (diagnostic.lnum or 0) + 1
    if lnum >= sel.line1 and lnum <= sel.line2 then
      table.insert(diagnostics, ("%s:%s:%s [%s] %s"):format(
        sel.path ~= "" and rel_path(sel.path, root) or "[No Name]",
        lnum,
        (diagnostic.col or 0) + 1,
        severity_names[diagnostic.severity] or tostring(diagnostic.severity or ""),
        diagnostic.message or ""
      ))
    end
  end
  return table.concat(diagnostics, "\n")
end

local function format_code_actions(result, max_items)
  if type(result) ~= "table" or result.available == false or type(result.items) ~= "table" or vim.tbl_isempty(result.items) then
    return nil
  end

  local lines = {}
  for index, item in ipairs(result.items) do
    if max_items and index > max_items then
      table.insert(lines, "[truncated]")
      break
    end
    local suffix = item.kind and item.kind ~= "" and (" (" .. item.kind .. ")") or ""
    table.insert(lines, ("- %s%s"):format(item.title or "", suffix))
  end
  return table.concat(lines, "\n")
end

local function collect_selection_language_context(sel, opts, cb)
  opts = opts or {}
  local sections = {}
  local tasks = {}
  local line = tonumber(sel.cursor_line) or sel.line1
  local column = tonumber(sel.column) or 1
  local start_column = tonumber(sel.start_column) or 1
  local end_column = tonumber(sel.end_column) or start_column
  local root = sel.root or context.root(sel.bufnr or 0)
  local common = {
    bufnr = sel.bufnr,
    line = line,
    column = column,
  }

  if opts.hover then
    table.insert(tasks, function(done)
      run_context_tool("nvim_symbol_hover", vim.tbl_extend("force", common, { max_chars = 1800 }), function(result)
        if result and result.available ~= false and result.text and result.text ~= "" then
          table.insert(sections, "Symbol documentation:\n" .. result.text)
        end
        done()
      end)
    end)
  end

  if opts.definition then
    table.insert(tasks, function(done)
      run_context_tool("nvim_symbol_definition", vim.tbl_extend("force", common, {
        max_items = 3,
        context_lines = 2,
        max_chars = 1200,
      }), function(result)
        local text = format_location_items(result, 3, root)
        if text then
          table.insert(sections, "Definitions:\n" .. text)
        end
        done()
      end)
    end)
  end

  if opts.document_symbols then
    table.insert(tasks, function(done)
      run_context_tool("nvim_document_symbols", {
        bufnr = sel.bufnr,
        max_items = 40,
      }, function(result)
        local text = format_symbols(result, 40, root)
        if text then
          table.insert(sections, "Current file symbols:\n" .. text)
        end
        done()
      end)
    end)
  end

  if opts.diagnostics then
    local diagnostics = diagnostics_for_range(sel)
    if diagnostics ~= "" then
      table.insert(sections, "Diagnostics in selected range:\n" .. diagnostics)
    end
  end

  if opts.code_actions then
    table.insert(tasks, function(done)
      run_context_tool("nvim_code_actions", {
        bufnr = sel.bufnr,
        line = line,
        column = column,
        start_line = sel.line1,
        start_column = start_column,
        end_line = sel.line2,
        end_column = end_column,
        max_items = 12,
      }, function(result)
        local text = format_code_actions(result, 12)
        if text then
          table.insert(sections, "Available code actions:\n" .. text)
        end
        done()
      end)
    end)
  end

  local index = 1
  local function next_task()
    local task = tasks[index]
    index = index + 1
    if not task then
      cb(table.concat(sections, "\n\n"))
      return
    end
    task(next_task)
  end
  next_task()
end

local function collect_diagnostic_language_context(diag, cb)
  local sel = {
    bufnr = diag.bufnr or 0,
    root = diag.root,
    path = diag.path,
    filetype = diag.filetype,
    line1 = (diag.diagnostic.lnum or 0) + 1,
    line2 = (diag.diagnostic.end_lnum or diag.diagnostic.lnum or 0) + 1,
    cursor_line = (diag.diagnostic.lnum or 0) + 1,
    column = (diag.diagnostic.col or 0) + 1,
    start_column = (diag.diagnostic.col or 0) + 1,
    end_column = (diag.diagnostic.end_col or diag.diagnostic.col or 0) + 1,
    text = diag.text,
    lines = {},
  }

  local sections = {
    "Selected diagnostic:",
    ("%s:%s:%s %s"):format(
      diag.path ~= "" and rel_path(diag.path, diag.root) or "[No Name]",
      sel.line1,
      (diag.diagnostic.col or 0) + 1,
      diag.diagnostic.message or ""
    ),
  }

  collect_selection_language_context(sel, {
    hover = true,
    definition = true,
    code_actions = true,
  }, function(language_context)
    if language_context ~= "" then
      table.insert(sections, language_context)
    end
    cb(table.concat(sections, "\n\n"))
  end)
end

local function edit_selection(cmd, instruction)
  local sel = context.selection_context(cmd)
  local edit_instruction = table.concat({
    instruction,
    "",
    "Return only the complete replacement text for the selected range.",
    "Do not include explanation, markdown fences, or diff markers.",
  }, "\n")

  local bufnr = ui.open_output("edit-request", "Collecting language context...")
  collect_selection_language_context(sel, {
    hover = true,
    definition = true,
    diagnostics = true,
    code_actions = true,
  }, function(language_context)
    local prompt = build_selection_prompt(sel, edit_instruction, language_context)
    ui.set_output(bufnr, "edit-request", "Requesting replacement...")
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
  end)
end

local function ask_selection(cmd, instruction, title)
  local sel = context.selection_context(cmd)
  local opts = { output = "popup" }
  local bufnr = open_response_output(title, "Collecting language context...", opts)
  collect_selection_language_context(sel, {
    hover = true,
    definition = true,
    document_symbols = true,
  }, function(language_context)
    local prompt = build_selection_prompt(sel, instruction, language_context)
    request_output(title, messages(prompt), opts, bufnr)
  end)
end

local function user_prompt(cmd, fallback)
  local args = cmd.args or ""
  if args == "" then
    return fallback
  end
  return args
end

function rel_path(path, root)
  root = root or context.root(0)
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
  request_output("buffer", messages(full_buffer_prompt(cmd, "Answer using the current buffer as context.")), { output = "popup" })
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
  request_output("file-summary", messages(prompt), { output = "popup" })
end

function M.fix_diagnostic()
  local diag = context.diagnostic_context()
  if not diag then
    ui.notify("No diagnostic on the current line.", vim.log.levels.WARN)
    return
  end

  local bufnr = ui.open_output("diagnostic-fix", "Collecting language context...")
  collect_diagnostic_language_context(diag, function(language_context)
    local lines = {
      "Fix the following diagnostic.",
      "Return only a unified diff that can be applied with git apply.",
      "Use paths relative to the project root.",
      "",
      ("Project root: %s"):format(diag.root or context.root(diag.bufnr or 0)),
      ("File: %s"):format(diag.path ~= "" and rel_path(diag.path, diag.root) or "[No Name]"),
      ("Filetype: %s"):format(diag.filetype ~= "" and diag.filetype or "unknown"),
      ("Diagnostic: %s"):format(diag.diagnostic.message or ""),
      ("Context lines: %d-%d"):format(diag.context_start, diag.context_end),
      "",
      "```" .. (diag.filetype ~= "" and diag.filetype or "text"),
      diag.text,
      "```",
    }

    if language_context ~= "" then
      vim.list_extend(lines, {
        "",
        "Language context:",
        language_context,
      })
    end

    request_patch("diagnostic-fix", messages(table.concat(lines, "\n")), bufnr, diag.root or context.root(diag.bufnr or 0))
  end)
end

function M.fix_all_diagnostics()
  local diagnostics = context.all_diagnostics_context(120)
  if diagnostics == "" then
    ui.notify("No diagnostics found in loaded buffers.", vim.log.levels.WARN)
    return
  end

  local prompt = table.concat({
    "Fix these diagnostics reported by the editor.",
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

local function git_request(title, instruction, on_success, opts)
  opts = opts or {}
  local root = context.root(0)
  local bufnr = open_response_output(title, "Reading git diff...", opts)
  context.git_diff(function(err, diff)
    if err then
      set_response_output(bufnr, title .. "-error", err, opts)
      return
    end
    if diff:gsub("%s+", "") == "#gitstatus--short#gitdiff#gitdiff--cached" then
      set_response_output(bufnr, title, "No git changes found.", opts)
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
  git_request("diff-explain", "Explain what changed in this git diff. Keep it concise and developer-facing.", nil, { output = "popup" })
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
  git_request("commit-message", "Write a concise commit message for this diff. Return only the commit message.", nil, { output = "popup" })
end

function M.project(cmd)
  local prompt = user_prompt(cmd, "Answer the question using project context.")
  local root = context.root(0)
  local opts = { output = "popup" }
  local bufnr = open_response_output("project", "Searching project context...", opts)
  context.project_context(prompt, function(err, project_context)
    if err then
      set_response_output(bufnr, "project-error", err, opts)
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
    }, "\n")), opts, bufnr)
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
  chat_panel.open({ system_prompt = system_prompt })
  if prompt ~= "" then
    chat_panel.send(prompt)
  end
end

function M.pop_chat(cmd)
  local prompt = cmd.args or ""
  chat_panel.open({ system_prompt = system_prompt, layout = "float" })
  if prompt ~= "" then
    chat_panel.send(prompt)
  end
end

function M.chat_toggle()
  chat_panel.toggle({ system_prompt = system_prompt })
end

function M.pop_chat_toggle()
  chat_panel.toggle({ system_prompt = system_prompt, layout = "float" })
end

function M.chat_stop()
  chat_panel.stop()
end

function M.chat_reset()
  chat_panel.clear()
  ui.notify("AI chat history cleared.")
end

function M.ping()
  local provider = config.get().provider
  local started = vim.uv and vim.uv.hrtime() or vim.loop.hrtime()
  local bufnr = ui.open_output("ping", table.concat({
    "# AI ping",
    "",
    "Pinging provider...",
    "",
    "Base URL: " .. provider.base_url,
    "Model: " .. provider.model,
  }, "\n"))

  client.chat({
    { role = "system", content = "You are a health check endpoint. Reply with exactly: pong" },
    { role = "user", content = "ping" },
  }, {
    stream = false,
    max_tokens = 64,
    temperature = false,
  }, function(err, text)
    local elapsed_ms = math.floor(((vim.uv and vim.uv.hrtime() or vim.loop.hrtime()) - started) / 1000000)
    if err then
      ui.set_output(bufnr, "ping-error", table.concat({
        "# AI ping failed",
        "",
        "Base URL: " .. provider.base_url,
        "Model: " .. provider.model,
        ("Elapsed: %d ms"):format(elapsed_ms),
        "",
        err,
      }, "\n"))
      return
    end

    ui.set_output(bufnr, "ping", table.concat({
      "# AI ping ok",
      "",
      "Base URL: " .. provider.base_url,
      "Model: " .. provider.model,
      ("Elapsed: %d ms"):format(elapsed_ms),
      "",
      "Response:",
      text,
    }, "\n"))
  end)
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

function M.tools()
  ui.open_output("tools", tools.render(), "markdown")
end

local function parse_tool_call(raw)
  raw = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if raw == "" then
    return nil, nil, "Usage: :AITool {tool_name} [json_args]"
  end

  local name, payload = raw:match("^(%S+)%s*(.*)$")
  if not name then
    return nil, nil, "Usage: :AITool {tool_name} [json_args]"
  end

  if payload == "" then
    return name, {}
  end

  local ok, decoded = pcall(vim.json.decode, payload)
  if not ok or type(decoded) ~= "table" then
    return nil, nil, "Tool args must be a JSON object."
  end

  return name, decoded
end

function M.tool(cmd)
  local name, args, parse_err = parse_tool_call(cmd.args)
  if parse_err then
    ui.open_output("tool-error", parse_err)
    return
  end

  local bufnr = ui.open_output("tool-" .. name, "Running tool...")
  tools.run(name, args, function(err, result)
    if err then
      ui.set_output(bufnr, "tool-error", err)
      return
    end
    ui.set_output(bufnr, "tool-" .. name, tools.result_text(result), "lua")
  end)
end

local function complete_tool_names(arg_lead, cmdline)
  if cmdline:match("^%s*AITool%s+%S+%s") then
    return {}
  end

  local out = {}
  for _, name in ipairs(tools.names()) do
    if name:sub(1, #arg_lead) == arg_lead then
      table.insert(out, name)
    end
  end
  return out
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
  create_command("AIPopChat", M.pop_chat, { range = false })
  create_command("AIChatToggle", M.chat_toggle, { nargs = 0, range = false })
  create_command("AIPopChatToggle", M.pop_chat_toggle, { nargs = 0, range = false })
  create_command("AIChatStop", M.chat_stop, { nargs = 0, range = false })
  create_command("AIChatReset", M.chat_reset, { nargs = 0, range = false })
  create_command("AIPing", M.ping, { nargs = 0, range = false })
  create_command("AIApply", ui.apply_pending, { nargs = 0, range = false })
  create_command("AIRun", ui.run_pending_command, { nargs = 0, range = false })
  create_command("AIReject", ui.reject_pending, { nargs = 0, range = false })
  create_command("AITools", M.tools, { nargs = 0, range = false })
  create_command("AITool", M.tool, { nargs = "*", range = false, complete = complete_tool_names })
  create_command("AIRules", M.show_rules, { nargs = 0, range = false })
  create_command("AIConfig", M.show_config, { nargs = 0, range = false })
end

return M
