vim.opt.runtimepath:append(vim.fn.getcwd())

local ai = require("ai")
ai.setup({
  provider = {
    api_key = "",
  },
  chat = {
    max_tool_model_chars = 80,
  },
})

local commands = {
  "AI",
  "AIExplain",
  "AIEdit",
  "AIApply",
  "AIReject",
  "AIRun",
  "AICmd",
  "AIShell",
  "AIGit",
  "AIAgent",
  "AIPlanNext",
  "AIPlanApply",
  "AIPlanRun",
  "AIPlanDone",
  "AIPlanSkip",
  "AIPlanShow",
  "AIPlanReset",
  "AIFixAllDiagnostics",
  "AIReviewDiff",
  "AIProject",
  "AIChat",
  "AIPopChat",
  "AIChatToggle",
  "AIChatStop",
  "AIChatReset",
  "AIPing",
  "AITools",
  "AITool",
  "AIRules",
  "AIConfig",
}

for _, name in ipairs(commands) do
  assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
end

local function run_tool(name, args)
  local done = false
  local tool_err
  local result

  require("ai.tools").run(name, args or {}, function(err, value)
    tool_err = err
    result = value
    done = true
  end)

  assert(vim.wait(5000, function()
    return done
  end), "timed out waiting for tool " .. name)
  assert(not tool_err, tool_err)
  return result
end

vim.cmd("new")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = 1", "print(x)" })
local tool_buf = vim.api.nvim_get_current_buf()

local tools = require("ai.tools")
local client = require("ai.client")
assert(#tools.list() >= 10, "tool registry is too small")
assert(#tools.openai_tools() == #tools.list(), "OpenAI tool export size mismatch")
local editor_state_tool = tools.openai_tools()[1]
local editor_state_schema_json = vim.json.encode(editor_state_tool["function"].parameters)
assert(editor_state_schema_json:match([["properties":{}]]), "OpenAI tool schema did not encode empty properties as object")
assert(tools.describe():match("nvim_current_buffer"), "tool description missing current buffer")

local editor_state = run_tool("nvim_editor_state")
assert(editor_state.current_buffer.bufnr == tool_buf, "editor state current buffer mismatch")
assert(#editor_state.windows > 0, "editor state did not include windows")

local current_buffer = run_tool("nvim_current_buffer")
assert(current_buffer.bufnr == tool_buf, "current buffer tool returned wrong buffer")

local read_buffer = run_tool("nvim_read_buffer", { bufnr = tool_buf, start_line = 1, end_line = 1 })
assert(read_buffer.text == "local x = 1", "read buffer tool returned wrong text")

local read_file = run_tool("nvim_read_file", { path = "README.md", max_chars = 200 })
assert(read_file.text:match("# ai.nvim"), "read file tool returned wrong text")

local buffers = run_tool("nvim_list_buffers", { listed_only = false })
assert(buffers.total >= 1, "list buffers tool returned no buffers")

local diagnostics = run_tool("nvim_diagnostics", { scope = "all" })
assert(type(diagnostics.items) == "table", "diagnostics tool did not return items")

local quickfix = run_tool("nvim_quickfix")
assert(type(quickfix.items) == "table", "quickfix tool did not return items")

local loclist = run_tool("nvim_location_list")
assert(type(loclist.items) == "table", "location list tool did not return items")

local project_files = run_tool("nvim_project_files", { max_items = 5 })
assert(project_files.root ~= "", "project files tool did not return root")
assert(#project_files.files > 0, "project files tool returned no files")

local project_search = run_tool("nvim_project_search", { query = "AIChat", max_chars = 2000 })
assert(project_search.text ~= "", "project search tool returned empty text")

local git_diff = run_tool("nvim_git_diff", { max_chars = 2000 })
assert(git_diff.text:match("# git status %-%-short"), "git diff tool returned wrong shape")

local command_preview = run_tool("nvim_preview_command", { command = "printf '%s\\n' ok" })
assert(command_preview.status == "previewed", "command preview tool did not preview")

local patch_preview = run_tool("nvim_preview_patch", {
  patch = [[
diff --git a/test.lua b/test.lua
--- a/test.lua
+++ b/test.lua
@@ -1 +1 @@
-local x = 1
+local x = 2
]],
})
assert(patch_preview.status == "previewed", "patch preview tool did not preview")

vim.cmd("AITools")
vim.cmd(('AITool nvim_read_buffer {"bufnr":%d,"start_line":1,"end_line":1}'):format(tool_buf))
vim.cmd("AIConfig")
vim.cmd("AIRules")
local rules_buf = vim.api.nvim_get_current_buf()
vim.cmd("AIConfig")
assert(vim.api.nvim_get_current_buf() == rules_buf, "AI output buffer was not reused")
assert(vim.fn.maparg("a", "n", false, true).buffer == 1, "AI apply buffer keymap missing")

local render_markdown_calls = 0
package.loaded["render-markdown"] = {
  buf_enable = function()
    render_markdown_calls = render_markdown_calls + 1
  end,
}

vim.cmd("AIChat")
assert(vim.api.nvim_buf_get_name(0):match("ai://chat%-input"), "AIChat did not focus input pane")
assert(vim.fn.maparg("<CR>", "i", false, true).buffer == 1, "AIChat send keymap missing")
assert(vim.fn.maparg("<C-q>", "i", false, true).buffer == 1, "AIChat input close keymap missing")
local chat = require("ai.chat")
assert(render_markdown_calls > 0, "AIChat did not enable render-markdown.nvim")
local message_pos = vim.api.nvim_win_get_position(chat.messages_winid)
local input_pos = vim.api.nvim_win_get_position(chat.input_winid)
assert(message_pos[2] == input_pos[2], "AIChat input pane is not inside chat column")
assert(vim.api.nvim_win_get_width(chat.messages_winid) == vim.api.nvim_win_get_width(chat.input_winid), "AIChat panes have different widths")
assert(input_pos[1] > message_pos[1], "AIChat input pane is not below messages pane")
assert(#vim.api.nvim_buf_get_extmarks(chat.input_bufnr, chat.placeholder_ns, 0, -1, {}) == 1, "AIChat placeholder missing")
vim.api.nvim_buf_set_lines(chat.input_bufnr, 0, -1, false, { "hello" })
vim.cmd("doautocmd <nomodeline> TextChanged")
assert(#vim.api.nvim_buf_get_extmarks(chat.input_bufnr, chat.placeholder_ns, 0, -1, {}) == 0, "AIChat placeholder did not clear")

chat.clear()
local original_chat = client.chat
local chat_calls = 0
client.chat = function(messages, opts, cb)
  chat_calls = chat_calls + 1
  assert(opts.stream == false, "AIChat harness should use non-streaming requests")
  assert(type(opts.tools) == "table" and #opts.tools > 0, "AIChat did not send native tool definitions")
  assert(opts.tool_choice == "auto", "AIChat did not enable native tool choice")
  if chat_calls == 1 then
    assert(messages[1].content:match("Available tools"), "AIChat did not include tool registry")
    cb(nil, "我先看看当前 buffer。", nil, {
      content = "我先看看当前 buffer。",
      tool_calls = {
        {
          id = "call_current_buffer",
          type = "function",
          ["function"] = {
            name = "nvim_current_buffer",
            arguments = "{}",
          },
        },
      },
    })
    return
  end

  local saw_tool_result = false
  for _, message in ipairs(messages) do
    if message.role == "tool" and message.tool_call_id == "call_current_buffer" then
      saw_tool_result = true
      assert(#message.content <= 120, "AIChat did not compress native tool result for model backfill")
      assert(message.content:match("%[truncated%]"), "AIChat did not mark compressed native tool result")
      break
    end
  end
  assert(saw_tool_result, "AIChat did not feed native tool result back to model")

  if chat_calls == 2 then
    cb(nil, "现在读取前几行。\n\n" .. vim.json.encode({
      tool = "nvim_read_buffer",
      args = {
        bufnr = tool_buf,
        start_line = 1,
        end_line = 1,
      },
    }))
    return
  end

  local saw_buffer_result = false
  for _, message in ipairs(messages) do
    if message.role == "user" and message.content:match("Tool `nvim_read_buffer` returned") then
      saw_buffer_result = true
      break
    end
  end
  assert(saw_buffer_result, "AIChat did not feed second tool result back to model")
  cb(nil, [[I read `local x = 1`.

```typescript
function sample(): number {
  return 1;
}
```]])
end

chat.send("read line one")
assert(vim.wait(5000, function()
  return not chat.active
end), "timed out waiting for AIChat harness")
client.chat = original_chat
assert(chat_calls == 3, "AIChat did not complete the tool loop")
assert(chat.history[#chat.history].content:match("local x = 1"), "AIChat did not store final assistant reply")
local rendered_chat = table.concat(vim.api.nvim_buf_get_lines(chat.messages_bufnr, 0, -1, false), "\n")
assert(rendered_chat:match("Status: `idle`"), "AIChat did not render idle status")
assert(rendered_chat:match("我先看看当前 buffer。"), "AIChat did not split assistant text before native tool call")
assert(rendered_chat:match("> %[!NOTE%] Tool call: nvim_current_buffer"), "AIChat did not render embedded tool call markdown")
assert(rendered_chat:match("> %[!NOTE%] Tool call: nvim_read_buffer"), "AIChat did not render tool call markdown")
assert(rendered_chat:match("> %[!INFO%] Tool result: nvim_read_buffer %(returned%)"), "AIChat did not render tool result markdown")
assert(rendered_chat:match("> ```json"), "AIChat did not render tool result as fenced markdown")
local folded_line
local in_tool_result = false
for index, line in ipairs(vim.api.nvim_buf_get_lines(chat.messages_bufnr, 0, -1, false)) do
  if line:match("^> %[!INFO%] Tool result: nvim_read_buffer") then
    in_tool_result = true
  elseif in_tool_result and line:match("^> ```json") then
    folded_line = index
    break
  elseif in_tool_result and line ~= "" and not line:match("^>") then
    break
  end
end
assert(folded_line, "AIChat did not include foldable tool result JSON")
vim.api.nvim_win_call(chat.messages_winid, function()
  assert(vim.fn.foldclosed(folded_line) > 0, "AIChat did not fold tool result details")
end)

local stopped_request = false
client.chat = function(_, opts)
  assert(opts.stream == false, "AIChat stop test should use non-streaming request")
  return {
    kill = function()
      stopped_request = true
    end,
  }
end
chat.send("wait for stop")
assert(chat.active, "AIChat stop test did not start an active request")
vim.cmd("AIChatStop")
client.chat = original_chat
assert(stopped_request, "AIChatStop did not kill the active request")
assert(not chat.active, "AIChatStop did not mark chat inactive")
assert(chat.status == "stopped", "AIChatStop did not render stopped status")

vim.cmd("AIChatToggle")
assert(not chat.is_open(), "AIChat toggle did not close chat panes")
vim.cmd("AIChatToggle")
assert(chat.is_open(), "AIChat toggle did not reopen chat panes")
local closed_messages_winid = chat.messages_winid
local closed_input_winid = chat.input_winid
chat.close()
assert(not vim.api.nvim_win_is_valid(closed_messages_winid), "AIChat close did not close messages pane")
assert(not vim.api.nvim_win_is_valid(closed_input_winid), "AIChat close did not close input pane")

vim.cmd("AIPopChat")
assert(chat.layout == "float", "AIPopChat did not use float layout")
assert(vim.api.nvim_buf_get_name(0):match("ai://chat%-input"), "AIPopChat did not focus input pane")
local pop_messages_config = vim.api.nvim_win_get_config(chat.messages_winid)
local pop_input_config = vim.api.nvim_win_get_config(chat.input_winid)
assert(pop_messages_config.relative == "editor", "AIPopChat messages pane is not floating")
assert(pop_input_config.relative == "editor", "AIPopChat input pane is not floating")
assert(pop_input_config.row > pop_messages_config.row, "AIPopChat input pane is not below messages pane")
closed_messages_winid = chat.messages_winid
closed_input_winid = chat.input_winid
chat.close()
assert(not vim.api.nvim_win_is_valid(closed_messages_winid), "AIPopChat close did not close messages pane")
assert(not vim.api.nvim_win_is_valid(closed_input_winid), "AIPopChat close did not close input pane")

local target = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(target, 0, -1, false, { "local x = 1", "print(x)" })

local ui = require("ai.ui")
ui.preview_edit({
  bufnr = target,
  path = "test.lua",
  line1 = 1,
  line2 = 1,
  original_lines = { "local x = 1" },
  replacement = "local x = 2",
})
ui.apply_pending()

local applied = vim.api.nvim_buf_get_lines(target, 0, -1, false)
assert(applied[1] == "local x = 2", "AIApply did not replace target line")
assert(applied[2] == "print(x)", "AIApply changed the wrong line")

local patch = require("ai.patch")
local extracted = patch.extract([[
The patch is:

```diff
diff --git a/test.lua b/test.lua
--- a/test.lua
+++ b/test.lua
@@ -1 +1 @@
-local x = 1
+local x = 2
```
]])
assert(extracted and extracted:match("diff %-%-git a/test.lua b/test.lua"), "patch extraction failed")

local locations = require("ai.locations")
local parsed = locations.parse("lua/ai/init.lua:1:1 check this line")
assert(#parsed == 1, "location parser did not find file:line")

ui.preview_command({
  title = "command-test",
  command = "printf '%s\\n' ok",
  cwd = vim.fn.getcwd(),
})

assert(type(client.chat_stream) == "function", "streaming client missing")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.writefile({ "local x = 1" }, tmp .. "/test.lua")
vim.fn.system({ "git", "-C", tmp, "init" })

local current = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(current)
vim.api.nvim_buf_set_name(current, tmp .. "/test.lua")
vim.api.nvim_buf_set_lines(current, 0, -1, false, { "local x = 1" })

local apply_done = false
local apply_err
patch.apply([[
diff --git a/test.lua b/test.lua
--- a/test.lua
+++ b/test.lua
@@ -1 +1 @@
-local x = 1
+local x = 2
]], function(err)
  apply_err = err
  apply_done = true
end)

assert(vim.wait(5000, function()
  return apply_done
end), "timed out waiting for patch apply")
assert(not apply_err, apply_err)
local changed = vim.fn.readfile(tmp .. "/test.lua")
assert(changed[1] == "local x = 2", "git apply path did not change temp file")

local runner = require("ai.runner")
runner.preview("git reset --hard", { cwd = tmp })
local blocked_done = false
local blocked_err
runner.run(function(err)
  blocked_err = err
  blocked_done = true
end)
assert(vim.wait(1000, function()
  return blocked_done
end), "timed out waiting for command safety check")
assert(blocked_err and blocked_err:match("Refusing to run"), "dangerous command was not blocked")

local agent = require("ai.agent")
local plan = assert(agent.parse([[
```json
{
  "task": "fix a bug",
  "summary": "Use a small patch and then run tests.",
  "steps": [
    {
      "type": "inspect",
      "title": "Read context",
      "details": "Check the failing area."
    },
    {
      "type": "patch",
      "title": "Patch file",
      "patch": "diff --git a/test.lua b/test.lua\n--- a/test.lua\n+++ b/test.lua\n@@ -1 +1 @@\n-local x = 1\n+local x = 2\n"
    },
    {
      "type": "test",
      "title": "Run smoke",
      "command": "nvim --headless -u NONE -c 'qa!'"
    }
  ]
}
```
]]))
agent.set(plan, { cwd = tmp })
assert(agent.current().steps[2].type == "patch", "agent patch step did not parse")
assert(agent.render():match("AI plan"), "agent plan did not render")
local inspect_step = assert(agent.preview_next())
assert(inspect_step.status == "done", "inspect step should complete after preview")
local patch_step = assert(agent.preview_next_patch())
assert(patch_step.status == "ready", "patch step should be ready after preview")
assert(agent.mark_done())
local run_step = assert(agent.preview_next_command())
assert(run_step.status == "ready", "command step should be ready after preview")
assert(agent.skip())
assert(not agent.preview_next(), "agent should have no pending steps")

print("ai.nvim smoke ok")
