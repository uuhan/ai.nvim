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
  "AISearchProject",
  "AIChat",
  "AIPopChat",
  "AIChatToggle",
  "AIPopChatToggle",
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
local tool_path = vim.fn.tempname() .. ".lua"
vim.api.nvim_buf_set_name(tool_buf, tool_path)

local tools = require("ai.tools")
local client = require("ai.client")
local config = require("ai.config")
local stream_buffer = require("ai.stream_buffer")
assert(#tools.list() >= 10, "tool registry is too small")
assert(#tools.openai_tools() == #tools.list(), "OpenAI tool export size mismatch")
local editor_state_tool = tools.openai_tools()[1]
local editor_state_schema_json = vim.json.encode(editor_state_tool["function"].parameters)
assert(editor_state_schema_json:match([["properties":{}]]), "OpenAI tool schema did not encode empty properties as object")
assert(tools.describe():match("nvim_current_buffer"), "tool description missing current buffer")

local fake_curl = vim.fn.tempname()
local stream_content_payload = vim.json.encode({
  choices = {
    {
      delta = {
        content = "hello ",
      },
    },
  },
})
local stream_reasoning_payload = vim.json.encode({
  choices = {
    {
      delta = {
        reasoning_content = "thinking ",
      },
    },
  },
})
local stream_tool_payload = vim.json.encode({
  choices = {
    {
      delta = {
        tool_calls = {
          {
            index = 0,
            id = "call_client_stream",
            type = "function",
            ["function"] = {
              name = "nvim_current_buffer",
              arguments = "{}",
            },
          },
        },
      },
      finish_reason = "tool_calls",
    },
  },
})
vim.fn.writefile({
  "#!/bin/sh",
  "cat >/dev/null",
  "cat <<'AI_NVIM_STREAM'",
  "data: " .. stream_reasoning_payload,
  "data: " .. stream_content_payload,
  "data: " .. stream_tool_payload,
  "data: [DONE]",
  "AI_NVIM_STREAM",
}, fake_curl)
vim.fn.system({ "chmod", "+x", fake_curl })
config.setup({
  provider = {
    api_key = "",
    curl = fake_curl,
    stream = true,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})
local client_stream_done = false
local client_stream_err
local client_stream_text = ""
local client_reasoning_text = ""
local client_tool_delta
local client_finish_reason
client.chat_stream({ { role = "user", content = "stream" } }, {
  tools = { tools.openai_tools()[1] },
  tool_choice = "auto",
}, {
  on_delta = function(delta)
    client_stream_text = client_stream_text .. delta
  end,
  on_reasoning_delta = function(delta)
    client_reasoning_text = client_reasoning_text .. delta
  end,
  on_tool_call_delta = function(delta)
    client_tool_delta = delta
  end,
  on_finish = function(reason)
    client_finish_reason = reason
  end,
  on_error = function(err)
    client_stream_err = err
    client_stream_done = true
  end,
  on_done = function()
    client_stream_done = true
  end,
})
assert(vim.wait(5000, function()
  return client_stream_done
end), "timed out waiting for client stream parser")
vim.fn.delete(fake_curl)
config.setup({
  provider = {
    api_key = "",
    stream = false,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})
assert(not client_stream_err, client_stream_err)
assert(client_stream_text == "hello ", "client stream did not parse text delta")
assert(client_reasoning_text == "thinking ", "client stream did not parse reasoning delta")
assert(client_tool_delta and client_tool_delta[1].id == "call_client_stream", "client stream did not parse tool call delta")
assert(client_finish_reason == "tool_calls", "client stream did not parse finish reason")

config.setup({
  provider = {
    api_key = "",
  },
  streaming = {
    interval_ms = 1,
    max_chars_per_flush = 2,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})
local buffered_updates = {}
local buffered_done = false
local buffered_text
local renderer = stream_buffer.new({
  on_update = function(text)
    table.insert(buffered_updates, text)
  end,
  on_done = function(text)
    buffered_text = text
    buffered_done = true
  end,
})
renderer.push("我先看。")
renderer.finish()
assert(vim.wait(5000, function()
  return buffered_done
end), "timed out waiting for stream buffer")
assert(buffered_text == "我先看。", "stream buffer did not preserve UTF-8 text")
assert(#buffered_updates >= 2, "stream buffer did not throttle updates")

local custom_request_seen = false
local custom_stream_seen = false
config.setup({
  provider = {
    api_key = "",
    transport = {
      request = function(req, cb)
        custom_request_seen = true
        assert(req.url:match("/chat/completions$"), "custom transport request URL mismatch")
        assert(req.headers["Content-Type"] == "application/json", "custom transport missing JSON content type")
        assert(req.body.messages[1].content == "custom transport", "custom transport request body mismatch")
        cb(nil, [[{"choices":[{"message":{"content":"custom ok"}}]}]])
      end,
      stream = function(req, callbacks)
        custom_stream_seen = true
        assert(req.stream == true, "custom stream request did not mark stream mode")
        callbacks.on_chunk([[data: {"choices":[{"delta":{"content":"custom stream"}}]}]] .. "\n")
        callbacks.on_chunk("data: [DONE]\n")
        callbacks.on_done()
        return {
          kill = function() end,
        }
      end,
    },
  },
  chat = {
    max_tool_model_chars = 80,
  },
})
local custom_done = false
local custom_err
local custom_text
client.chat({ { role = "user", content = "custom transport" } }, {}, function(err, text)
  custom_err = err
  custom_text = text
  custom_done = true
end)
assert(vim.wait(5000, function()
  return custom_done
end), "timed out waiting for custom transport request")
assert(not custom_err, custom_err)
assert(custom_request_seen, "custom transport request was not used")
assert(custom_text == "custom ok", "custom transport response did not parse")

local custom_stream_done = false
local custom_stream_err
local custom_stream_text = ""
client.chat_stream({ { role = "user", content = "custom stream" } }, {}, {
  on_delta = function(delta)
    custom_stream_text = custom_stream_text .. delta
  end,
  on_error = function(err)
    custom_stream_err = err
    custom_stream_done = true
  end,
  on_done = function()
    custom_stream_done = true
  end,
})
assert(vim.wait(5000, function()
  return custom_stream_done
end), "timed out waiting for custom stream transport")
assert(not custom_stream_err, custom_stream_err)
assert(custom_stream_seen, "custom stream transport was not used")
assert(custom_stream_text == "custom stream", "custom stream transport response did not parse")

local capture_curl = vim.fn.tempname()
local capture_body = vim.fn.tempname()
vim.fn.writefile({
  "#!/bin/sh",
  ("cat >%s"):format(vim.fn.shellescape(capture_body)),
  "cat <<'AI_NVIM_JSON'",
  [[{"choices":[{"message":{"content":"ok"}}]}]],
  "AI_NVIM_JSON",
}, capture_curl)
vim.fn.system({ "chmod", "+x", capture_curl })
config.setup({
  provider = {
    base_url = "https://api.deepseek.com",
    api_key = "",
    curl = capture_curl,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})
local capture_done = false
local capture_err
client.chat({ { role = "user", content = "thinking default" } }, {}, function(err)
  capture_err = err
  capture_done = true
end)
assert(vim.wait(5000, function()
  return capture_done
end), "timed out waiting for captured DeepSeek request")
assert(not capture_err, capture_err)
local captured = table.concat(vim.fn.readfile(capture_body), "\n")
assert(captured:match([["thinking"%s*:%s*{]]) and captured:match([["type"%s*:%s*"disabled"]]), "DeepSeek request did not disable thinking by default")
vim.fn.delete(capture_curl)
vim.fn.delete(capture_body)
config.setup({
  provider = {
    api_key = "",
    stream = false,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})

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

local unavailable_language_tools = {
  { "nvim_symbol_hover", {} },
  { "nvim_symbol_definition", {} },
  { "nvim_symbol_references", {} },
  { "nvim_document_symbols", {} },
  { "nvim_workspace_symbols", { query = "x" } },
  { "nvim_code_actions", {} },
}
for _, item in ipairs(unavailable_language_tools) do
  local result = run_tool(item[1], item[2])
  assert(result.available == false, item[1] .. " should report unavailable without language intelligence")
  assert(result.message:match("language intelligence"), item[1] .. " returned the wrong unavailable message")
end
assert(not vim.tbl_contains(tools.names(), "nvim_lsp_clients"), "tool registry should not expose language service internals")

local original_get_clients = vim.lsp.get_clients
local original_buf_request_all = vim.lsp.buf_request_all
local fake_uri = vim.uri_from_bufnr(tool_buf)
local request_params_by_method = {}
vim.lsp.get_clients = function()
  return {
    {
      id = 9001,
      stop = function() end,
      supports_method = function(_, method)
        return ({
          ["textDocument/hover"] = true,
          ["textDocument/definition"] = true,
          ["textDocument/references"] = true,
          ["textDocument/documentSymbol"] = true,
          ["workspace/symbol"] = true,
          ["textDocument/codeAction"] = true,
        })[method] == true
      end,
    },
  }
end
vim.lsp.buf_request_all = function(_, method, params, cb)
  request_params_by_method[method] = params
  local result_by_method = {
    ["textDocument/hover"] = {
      contents = {
        kind = "markdown",
        value = "hover docs",
      },
    },
    ["textDocument/definition"] = {
      uri = fake_uri,
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 5 },
      },
    },
    ["textDocument/references"] = {
      {
        uri = fake_uri,
        range = {
          start = { line = 1, character = 0 },
          ["end"] = { line = 1, character = 5 },
        },
      },
    },
    ["textDocument/documentSymbol"] = {
      {
        name = "outer",
        kind = vim.lsp.protocol.SymbolKind.Function,
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 1, character = 8 },
        },
        selectionRange = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 5 },
        },
        children = {
          {
            name = "inner",
            kind = vim.lsp.protocol.SymbolKind.Variable,
            range = {
              start = { line = 0, character = 6 },
              ["end"] = { line = 0, character = 7 },
            },
            selectionRange = {
              start = { line = 0, character = 6 },
              ["end"] = { line = 0, character = 7 },
            },
          },
        },
      },
    },
    ["workspace/symbol"] = {
      {
        name = "outer",
        kind = vim.lsp.protocol.SymbolKind.Function,
        location = {
          uri = fake_uri,
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 5 },
          },
        },
      },
    },
    ["textDocument/codeAction"] = {
      {
        title = "Fix sample",
        kind = "quickfix",
      },
    },
  }
  cb({ [1] = { result = result_by_method[method] } })
end

local hover = run_tool("nvim_symbol_hover")
assert(hover.available == true and hover.text:match("hover docs"), "symbol hover did not return fake hover text")
local definition = run_tool("nvim_symbol_definition")
assert(definition.available == true and definition.items[1].snippet.text:match("local x = 1"), "symbol definition did not return snippet")
local references = run_tool("nvim_symbol_references")
assert(references.available == true and references.items[1].lnum == 2, "symbol references did not return location")
local document_symbols = run_tool("nvim_document_symbols")
assert(document_symbols.available == true and document_symbols.items[2].name == "inner", "document symbols did not flatten children")
local workspace_symbols = run_tool("nvim_workspace_symbols", { query = "outer" })
assert(workspace_symbols.available == true and workspace_symbols.items[1].name == "outer", "workspace symbols did not return item")
local code_actions = run_tool("nvim_code_actions")
assert(code_actions.available == true and code_actions.items[1].title == "Fix sample", "code actions did not return action title")

config.setup({
  system_prompt = "请使用中文回复对话。",
  provider = {
    api_key = "",
    stream = false,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})
local original_command_chat = client.chat
local explain_prompt
client.chat = function(messages, _, cb)
  assert(messages[1].content:match("请使用中文回复对话。"), "AIExplain did not include configured system prompt")
  explain_prompt = messages[2].content
  cb(nil, "explain ok")
end
vim.api.nvim_set_current_buf(tool_buf)
vim.api.nvim_win_set_cursor(0, { 1, 6 })
local explain_source_winid = vim.api.nvim_get_current_win()
request_params_by_method = {}
vim.cmd("AIExplain")
assert(vim.wait(5000, function()
  return explain_prompt ~= nil
end), "timed out waiting for AIExplain prompt")
assert(explain_prompt:match("Language context:"), "AIExplain did not include language context")
assert(explain_prompt:match("hover docs"), "AIExplain did not include symbol hover")
assert(explain_prompt:match("Current file symbols"), "AIExplain did not include document symbols")
assert(request_params_by_method["textDocument/hover"].position.character == 6, "AIExplain used the wrong hover column")
local explain_float_winid = vim.api.nvim_get_current_win()
local explain_float_bufnr = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_win_get_config(explain_float_winid).relative == "editor", "AIExplain did not render in a floating window")
assert(vim.bo[vim.api.nvim_get_current_buf()].filetype == "markdown", "AIExplain floating output is not markdown")
assert(vim.fn.maparg("<Esc>", "n", false, true).buffer == 1, "AIExplain floating output missing close keymap")
assert(vim.fn.maparg("<C-q>", "n", false, true).buffer == 1, "AIExplain floating output missing normal ctrl-q close keymap")
assert(vim.fn.maparg("<C-q>", "i", false, true).buffer == 1, "AIExplain floating output missing insert ctrl-q close keymap")
require("ai.popup").close()
assert(not vim.api.nvim_win_is_valid(explain_float_winid), "AIExplain popup close did not close window")
assert(vim.api.nvim_buf_is_valid(explain_float_bufnr), "AIExplain close wiped the popup buffer")
if vim.api.nvim_win_is_valid(explain_source_winid) then
  vim.api.nvim_set_current_win(explain_source_winid)
end

vim.api.nvim_set_current_buf(tool_buf)
local buffer_prompt
client.chat = function(messages, opts, cb)
  assert(opts.output == nil, "AIBuffer leaked popup opts to provider")
  buffer_prompt = messages[2].content
  cb(nil, "buffer ok")
end
vim.cmd("AIBuffer summarize this buffer")
assert(vim.wait(5000, function()
  return buffer_prompt ~= nil
end), "timed out waiting for AIBuffer prompt")
assert(buffer_prompt:match("Answer using the current buffer"), "AIBuffer used the wrong prompt")
local buffer_float_winid = vim.api.nvim_get_current_win()
assert(vim.api.nvim_win_get_config(buffer_float_winid).relative == "editor", "AIBuffer did not render in a floating window")
assert(vim.api.nvim_get_current_buf() == explain_float_bufnr, "AIBuffer did not reuse the popup buffer")
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):match("buffer ok"), "AIBuffer did not render provider response")
vim.api.nvim_win_close(buffer_float_winid, true)
if vim.api.nvim_win_is_valid(explain_source_winid) then
  vim.api.nvim_set_current_win(explain_source_winid)
end

vim.api.nvim_set_current_buf(tool_buf)
vim.api.nvim_win_set_cursor(0, { 1, 6 })
local edit_prompt
client.chat = function(messages, _, cb)
  edit_prompt = messages[2].content
  cb(nil, "local x = 2")
end
request_params_by_method = {}
vim.cmd("AIEdit improve")
assert(vim.wait(5000, function()
  return edit_prompt ~= nil
end), "timed out waiting for AIEdit prompt")
assert(edit_prompt:match("Language context:"), "AIEdit did not include language context")
assert(edit_prompt:match("Available code actions:"), "AIEdit did not include code actions")
assert(edit_prompt:match("Fix sample"), "AIEdit did not include code action title")
assert(request_params_by_method["textDocument/codeAction"].range.start.character == 0, "AIEdit used the wrong code action start column")
assert(request_params_by_method["textDocument/codeAction"].range["end"].character == 8, "AIEdit used the wrong code action end column")

vim.api.nvim_set_current_buf(tool_buf)
local diagnostic_ns = vim.api.nvim_create_namespace("ai.nvim.test.diagnostic")
vim.diagnostic.set(diagnostic_ns, tool_buf, {
  {
    lnum = 0,
    col = 6,
    end_col = 7,
    severity = vim.diagnostic.severity.ERROR,
    message = "sample diagnostic",
  },
})
vim.api.nvim_win_set_cursor(0, { 1, 6 })
local diagnostic_prompt
client.chat = function(messages, _, cb)
  diagnostic_prompt = messages[2].content
  cb(nil, [[
diff --git a/test.lua b/test.lua
--- a/test.lua
+++ b/test.lua
@@ -1 +1 @@
-local x = 1
+local x = 2
]])
end
request_params_by_method = {}
vim.cmd("AIFixDiagnostic")
assert(vim.wait(5000, function()
  return diagnostic_prompt ~= nil
end), "timed out waiting for AIFixDiagnostic prompt")
assert(diagnostic_prompt:match("Language context:"), "AIFixDiagnostic did not include language context")
assert(diagnostic_prompt:match("Selected diagnostic:"), "AIFixDiagnostic did not include selected diagnostic")
assert(diagnostic_prompt:match("Available code actions:"), "AIFixDiagnostic did not include code actions")
assert(request_params_by_method["textDocument/codeAction"].range.start.character == 6, "AIFixDiagnostic used the wrong code action start column")
assert(request_params_by_method["textDocument/codeAction"].range["end"].character == 7, "AIFixDiagnostic used the wrong code action end column")
vim.diagnostic.reset(diagnostic_ns, tool_buf)
client.chat = original_command_chat
vim.lsp.get_clients = original_get_clients
vim.lsp.buf_request_all = original_buf_request_all

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

local buffer_replace_preview = run_tool("nvim_preview_buffer_replace", {
  bufnr = tool_buf,
  start_line = 1,
  end_line = 1,
  replacement = "local x = 2",
})
assert(buffer_replace_preview.status == "previewed", "buffer replace tool did not preview")
assert(buffer_replace_preview.action == "buffer_replace", "buffer replace tool returned wrong action")
assert(buffer_replace_preview.start_line == 1 and buffer_replace_preview.end_line == 1, "buffer replace range mismatch")

local file_replace_preview = run_tool("nvim_preview_file_replace", {
  path = "README.md",
  start_line = 1,
  end_line = 1,
  replacement = "# ai.nvim",
})
assert(file_replace_preview.status == "previewed", "file replace tool did not preview")
assert(file_replace_preview.action == "file_replace", "file replace tool returned wrong action")

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
assert(chat.target_bufnr == tool_buf, "AIChat did not retain target editor buffer")
local chat_state = run_tool("nvim_editor_state")
assert(chat_state.current_buffer.name:match("ai://chat%-input"), "editor state did not report actual focused chat buffer")
assert(chat_state.target_buffer and chat_state.target_buffer.bufnr == tool_buf, "editor state did not report target editor buffer")
local chat_current_buffer = run_tool("nvim_current_buffer")
assert(chat_current_buffer.bufnr == tool_buf, "current buffer tool used AIChat input instead of target buffer")
local chat_default_read = run_tool("nvim_read_buffer", { start_line = 1, end_line = 1 })
assert(chat_default_read.bufnr == tool_buf, "default read buffer tool used AIChat input instead of target buffer")
assert(chat_default_read.text == "local x = 1", "default read buffer tool read wrong target text")
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
    assert(messages[1].content:match("请使用中文回复对话。"), "AIChat did not include configured system prompt")
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
assert(rendered_chat:match("> summary:"), "AIChat did not render tool result summary")
assert(rendered_chat:match("> details:"), "AIChat did not render tool result details header")
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

config.setup({
  provider = {
    api_key = "",
    stream = true,
  },
  streaming = {
    interval_ms = 1,
    max_chars_per_flush = 2,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})
chat.clear()
local original_chat_stream = client.chat_stream
local stream_calls = 0
client.chat_stream = function(messages, opts, callbacks)
  stream_calls = stream_calls + 1
  assert(type(opts.tools) == "table" and #opts.tools > 0, "AIChat stream did not send native tool definitions")
  assert(opts.tool_choice == "auto", "AIChat stream did not enable native tool choice")

  if stream_calls == 1 then
    assert(messages[1].content:match("Available tools"), "AIChat stream did not include tool registry")
    callbacks.on_reasoning_delta("stream thinking")
    callbacks.on_delta("我先")
    callbacks.on_delta("看。")
    callbacks.on_tool_call_delta({
      {
        index = 0,
        id = "call_stream_current_buffer",
        type = "function",
        ["function"] = {
          name = "nvim_current_buffer",
        },
      },
    })
    callbacks.on_tool_call_delta({
      {
        index = 0,
        ["function"] = {
          arguments = "{}",
        },
      },
    })
    callbacks.on_done()
    return
  end

  local saw_stream_tool_result = false
  local saw_stream_reasoning = false
  for _, message in ipairs(messages) do
    if message.role == "assistant" and message.tool_calls and message.reasoning_content == "stream thinking" then
      saw_stream_reasoning = true
    end
    if message.role == "tool" and message.tool_call_id == "call_stream_current_buffer" then
      saw_stream_tool_result = true
      break
    end
  end
  assert(saw_stream_reasoning, "AIChat stream did not preserve reasoning content for native tool call")
  assert(saw_stream_tool_result, "AIChat stream did not feed native tool result back to model")
  callbacks.on_delta("stream final")
  callbacks.on_done()
end

chat.send("stream current buffer")
assert(vim.wait(5000, function()
  return not chat.active
end), "timed out waiting for streaming AIChat harness")
client.chat_stream = original_chat_stream
config.setup({
  provider = {
    api_key = "",
    stream = false,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})
assert(stream_calls == 2, "AIChat stream did not complete the tool loop")
assert(chat.history[#chat.history].content == "stream final", "AIChat stream did not store final assistant reply")
rendered_chat = table.concat(vim.api.nvim_buf_get_lines(chat.messages_bufnr, 0, -1, false), "\n")
assert(rendered_chat:match("我先看。"), "AIChat stream did not keep streamed assistant preface")
assert(rendered_chat:match("> %[!NOTE%] Tool call: nvim_current_buffer"), "AIChat stream did not render native tool call")

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
vim.cmd("AIPopChatToggle")
assert(not vim.api.nvim_win_is_valid(closed_messages_winid), "AIPopChatToggle did not close messages pane")
assert(not vim.api.nvim_win_is_valid(closed_input_winid), "AIPopChatToggle did not close input pane")
vim.cmd("AIPopChatToggle")
assert(chat.layout == "float", "AIPopChatToggle did not reopen float layout")
chat.close()

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
