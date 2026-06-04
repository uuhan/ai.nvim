local ui = require("ai.ui")

local M = {
  state = nil,
}

local function json_decode(value)
  if vim.json and vim.json.decode then
    return vim.json.decode(value)
  end
  return vim.fn.json_decode(value)
end

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function extract_json(text)
  text = trim(text)

  for body in text:gmatch("```json\n(.-)\n```") do
    return trim(body)
  end
  for body in text:gmatch("```\n(.-)\n```") do
    local candidate = trim(body)
    if candidate:sub(1, 1) == "{" then
      return candidate
    end
  end

  local first = text:find("{", 1, true)
  local last = text:match("^.*()}")
  if first and last and last >= first then
    return text:sub(first, last)
  end

  return text
end

local function infer_type(step)
  local step_type = step.type or step.kind or step.action
  if step_type then
    step_type = tostring(step_type):lower()
  end

  if step_type == "shell" then
    return "command"
  end
  if step_type == "run" then
    return "command"
  end
  if step_type == "diff" then
    return "patch"
  end
  if step_type == "review" or step_type == "read" or step_type == "search" then
    return "inspect"
  end
  if step_type then
    return step_type
  end

  if step.patch or step.diff then
    return "patch"
  end
  if step.command or step.cmd then
    return "command"
  end
  return "inspect"
end

local function normalize_step(step, index)
  if type(step) == "string" then
    step = {
      type = "inspect",
      title = step,
      details = step,
    }
  end

  step = step or {}
  return {
    type = infer_type(step),
    title = step.title or step.name or ("Step " .. index),
    details = step.details or step.description or step.instruction or step.reason or "",
    patch = step.patch or step.diff,
    command = step.command or step.cmd,
    status = step.status or "pending",
  }
end

local function fallback_markdown_plan(text)
  local steps = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local item = line:match("^%s*%d+[%.)]%s+(.+)$") or line:match("^%s*[-*]%s+(.+)$")
    if item then
      table.insert(steps, normalize_step(item, #steps + 1))
    end
  end

  if vim.tbl_isempty(steps) then
    table.insert(steps, normalize_step({
      type = "inspect",
      title = "Review AI response",
      details = text,
    }, 1))
  end

  return {
    task = "",
    summary = "AI returned a non-JSON plan. Stored it as inspect steps.",
    steps = steps,
  }
end

function M.parse(text)
  local candidate = extract_json(text)
  local ok, decoded = pcall(json_decode, candidate)
  if not ok or type(decoded) ~= "table" then
    return fallback_markdown_plan(text), "AI response was not valid JSON; using markdown fallback."
  end

  local raw_steps = decoded.steps or decoded.plan or decoded
  if type(raw_steps) ~= "table" then
    return nil, "Agent plan did not include a steps array."
  end

  local steps = {}
  for index, step in ipairs(raw_steps) do
    table.insert(steps, normalize_step(step, index))
  end

  if vim.tbl_isempty(steps) then
    return nil, "Agent plan did not include any steps."
  end

  return {
    task = decoded.task or "",
    summary = decoded.summary or decoded.reasoning or "",
    steps = steps,
  }
end

function M.set(plan, opts)
  opts = opts or {}
  M.state = {
    task = plan.task or opts.task or "",
    summary = plan.summary or "",
    steps = plan.steps or {},
    cursor = 1,
    active_index = nil,
    cwd = opts.cwd or vim.fn.getcwd(),
  }
  return M.state
end

function M.current()
  return M.state
end

local function step_status(step)
  if step.status == "done" then
    return "x"
  end
  if step.status == "skipped" then
    return "-"
  end
  if step.status == "ready" then
    return ">"
  end
  return " "
end

function M.render(state)
  state = state or M.state
  if not state then
    return "No active AI plan."
  end

  local lines = {
    "# AI plan",
    "",
  }

  if state.task ~= "" then
    table.insert(lines, "Task: " .. state.task)
    table.insert(lines, "")
  end

  if state.summary ~= "" then
    table.insert(lines, state.summary)
    table.insert(lines, "")
  end

  table.insert(lines, "Commands: :AIPlanNext, :AIPlanApply, :AIPlanRun, :AIPlanDone, :AIPlanSkip, :AIReject")
  table.insert(lines, "")

  for index, step in ipairs(state.steps) do
    table.insert(lines, ("- [%s] %d. %s `%s`"):format(step_status(step), index, step.title, step.type))
    if step.details and step.details ~= "" then
      table.insert(lines, "  " .. step.details:gsub("\n", "\n  "))
    end
    if step.command and step.command ~= "" then
      table.insert(lines, "  command: `" .. step.command .. "`")
    end
    if step.patch and step.patch ~= "" then
      table.insert(lines, "  patch: available")
    end
  end

  return table.concat(lines, "\n")
end

local function find_step(kind)
  local state = M.state
  if not state then
    return nil, "No active AI plan. Run :AIAgent first."
  end

  for index = state.cursor, #state.steps do
    local step = state.steps[index]
    if step.status ~= "done" and step.status ~= "skipped" then
      if not kind or kind[step.type] then
        return index, step, state
      end
    end
  end

  return nil, "No matching pending AI plan step."
end

local function mark_ready(state, index)
  state.active_index = index
  state.steps[index].status = "ready"
end

function M.preview_next(kind)
  local index, step, state = find_step(kind)
  if not index then
    return nil, step
  end

  mark_ready(state, index)

  if step.type == "patch" then
    if not step.patch or step.patch == "" then
      return nil, "Plan step does not include a patch."
    end
    ui.preview_patch({
      title = "agent-step-" .. index,
      text = step.patch,
      cwd = state.cwd,
    })
    return step
  end

  if step.type == "command" or step.type == "test" then
    if not step.command or step.command == "" then
      return nil, "Plan step does not include a command."
    end
    ui.preview_command({
      title = "agent-step-" .. index,
      command = step.command,
      cwd = state.cwd,
    })
    return step
  end

  step.status = "done"
  state.cursor = math.max(state.cursor, index + 1)
  ui.open_output("agent-step-" .. index, table.concat({
    "# " .. step.title,
    "",
    step.details ~= "" and step.details or "No action required for this step.",
  }, "\n"))
  return step
end

function M.preview_next_patch()
  return M.preview_next({ patch = true })
end

function M.preview_next_command()
  return M.preview_next({ command = true, test = true })
end

function M.mark_done()
  local state = M.state
  if not state then
    return nil, "No active AI plan."
  end

  local index = state.active_index or state.cursor
  local step = state.steps[index]
  if not step then
    return nil, "No active AI plan step."
  end

  step.status = "done"
  state.cursor = math.max(state.cursor, index + 1)
  state.active_index = nil
  return step
end

function M.skip()
  local state = M.state
  if not state then
    return nil, "No active AI plan."
  end

  local index = state.active_index or state.cursor
  local step = state.steps[index]
  if not step then
    return nil, "No active AI plan step."
  end

  step.status = "skipped"
  state.cursor = math.max(state.cursor, index + 1)
  state.active_index = nil
  return step
end

function M.reset()
  M.state = nil
end

return M
