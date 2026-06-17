vim.opt.runtimepath:append(vim.fn.getcwd())

-- Redirect all chat session persistence into a temp dir so test runs never
-- write into the real stdpath("state") of the user running the suite.
local smoke_sessions_dir = vim.fn.tempname()
do
  local config = require("ai.config")
  local original_setup = config.setup
  config.setup = function(opts)
    opts = opts or {}
    opts.chat = opts.chat or {}
    opts.chat.sessions = opts.chat.sessions or { dir = smoke_sessions_dir }
    return original_setup(opts)
  end
end

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
  "AIFindBug",
  "AIFixBug",
  "AIImplement",
  "AIEdit",
  "AIComment",
  "AIApply",
  "AIReject",
  "AIRun",
  "AICmd",
  "AICommit",
  "AIAgent",
  "AIPlan",
  "AIFixAllDiagnostics",
  "AIReviewDiff",
  "AISearchProject",
  "AIChat",
  "AIPopChat",
  "AIQuick",
  "AIChatToggle",
  "AIPopChatToggle",
  "AIChatStop",
  "AIChatReset",
  "AIChatResume",
  "AIChatSessions",
  "AIPing",
  "AITools",
  "AITool",
  "AIRules",
  "AIConfig",
}

for _, name in ipairs(commands) do
  assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
end

for _, name in ipairs({
  "AIPlanNext",
  "AIPlanApply",
  "AIPlanRun",
  "AIPlanDone",
  "AIPlanSkip",
  "AIPlanShow",
  "AIPlanReset",
}) do
  assert(vim.fn.exists(":" .. name) == 0, "old plan command should not exist: " .. name)
end

local function run_tool(name, args, opts)
  local done = false
  local tool_err
  local result

  require("ai.tools").run(name, args or {}, function(err, value)
    tool_err = err
    result = value
    done = true
  end, opts)

  assert(vim.wait(5000, function()
    return done
  end), "timed out waiting for tool " .. name)
  assert(not tool_err, tool_err)
  return result
end

local function run_tool_error(name, args)
  local tool_err
  local done = false
  require("ai.tools").run(name, args or {}, function(err)
    tool_err = err
    done = true
  end)
  assert(vim.wait(5000, function()
    return done
  end), "timed out waiting for tool error " .. name)
  assert(tool_err, name .. " was expected to fail")
  return tool_err
end

local function count_unnamed_buffers()
  local count = 0
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == "" then
      count = count + 1
    end
  end
  return count
end

vim.cmd("new")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = 1", "print(x)" })
local tool_buf = vim.api.nvim_get_current_buf()
local tool_path = vim.fn.tempname() .. ".lua"
vim.api.nvim_buf_set_name(tool_buf, tool_path)
vim.bo[tool_buf].modified = false

local tools = require("ai.tools")
local client = require("ai.client")
local config = require("ai.config")
local context = require("ai.context")
local popup = require("ai.popup")
local response_session = require("ai.response_session")
local stream_buffer = require("ai.stream_buffer")
local ui = require("ai.ui")
assert(#tools.list() >= 10, "tool registry is too small")
assert(#tools.openai_tools() == #tools.list(), "OpenAI tool export size mismatch")
local editor_state_tool = tools.openai_tools()[1]
local editor_state_schema_json = vim.json.encode(editor_state_tool["function"].parameters)
assert(editor_state_schema_json:match([["properties":{}]]), "OpenAI tool schema did not encode empty properties as object")
assert(tools.describe():match("nvim_current_buffer"), "tool description missing current buffer")

vim.cmd("new")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "fn upgrade() {",
  "  let service = ServiceRunner::get_service();",
  "",
  "  let jar = prepare_upgrade_jar();",
  "}",
})
local syntax_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 2, 4 })
local original_get_node = vim.treesitter.get_node
local function_node = {
  type = function()
    return "function_item"
  end,
  range = function()
    return 0, 0, 4, 1
  end,
  parent = function()
    return nil
  end,
}
local child_node = {
  type = function()
    return "identifier"
  end,
  range = function()
    return 1, 6, 1, 13
  end,
  parent = function()
    return function_node
  end,
}
vim.treesitter.get_node = function(opts)
  assert(opts.bufnr == syntax_buf, "selection context queried the wrong buffer")
  return child_node
end
local syntax_selection = context.selection_context({ range = 0 })
vim.treesitter.get_node = original_get_node
assert(syntax_selection.line1 == 1 and syntax_selection.line2 == 5, "selection context did not expand to current syntax node")
assert(syntax_selection.text:match("prepare_upgrade_jar"), "selection context only captured the first paragraph")
vim.api.nvim_set_current_buf(tool_buf)
vim.api.nvim_buf_delete(syntax_buf, { force = true })

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
local capture_args = vim.fn.tempname()
vim.fn.writefile({
  "#!/bin/sh",
  ("printf '%%s\\n' \"$@\" >%s"):format(vim.fn.shellescape(capture_args)),
  ("cat >%s"):format(vim.fn.shellescape(capture_body)),
  "cat <<'AI_NVIM_JSON'",
  [[{"choices":[{"message":{"content":"ok"}}]}]],
  "AI_NVIM_JSON",
}, capture_curl)
vim.fn.system({ "chmod", "+x", capture_curl })
config.setup({
  provider = {
    base_url = "https://api.deepseek.com",
    api_key = "sk-test-secret",
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
do
  local captured_argv = vim.fn.readfile(capture_args)
  local saw_header_config = false
  for _, arg in ipairs(captured_argv) do
    assert(not arg:match("Authorization"), "Authorization header leaked into curl argv")
    assert(not arg:match("sk%-test%-secret"), "API key leaked into curl argv")
    if arg == "-K" then
      saw_header_config = true
    end
  end
  assert(saw_header_config, "curl was not given a header config file")
end
vim.fn.delete(capture_curl)
vim.fn.delete(capture_body)
vim.fn.delete(capture_args)
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
assert(editor_state.current_buffer.cursor_line_text == "local x = 1", "editor state current buffer missing cursor line text")
assert(#editor_state.windows > 0, "editor state did not include windows")

local current_buffer = run_tool("nvim_current_buffer")
assert(current_buffer.bufnr == tool_buf, "current buffer tool returned wrong buffer")
assert(current_buffer.cursor_line_text == "local x = 1", "current buffer tool missing cursor line text")

local read_buffer = run_tool("nvim_read_buffer", { bufnr = tool_buf, start_line = 1, end_line = 1 })
assert(read_buffer.text == "1\tlocal x = 1", "read buffer tool did not return numbered text")
assert(read_buffer.lines == nil, "read buffer tool should not duplicate text in a lines field")

local read_file = run_tool("nvim_read_file", { path = "README.md", max_chars = 200 })
assert(read_file.text:match("^1\t# ai.nvim"), "read file tool did not return numbered text")

local opened_file = run_tool("nvim_open_file", { path = "README.md", line = 3, col = 1 })
assert(opened_file.path:match("README%.md$"), "open file tool returned wrong path")
assert(opened_file.buffer.name:match("README%.md$"), "open file tool opened wrong buffer")
assert(opened_file.buffer.cursor[1] == 3, "open file tool did not move cursor to requested line")
assert(vim.api.nvim_get_current_buf() == opened_file.buffer.bufnr, "open file tool did not switch current buffer")
local opened_current_buffer = run_tool("nvim_current_buffer")
assert(opened_current_buffer.bufnr == opened_file.buffer.bufnr, "open file tool did not update target buffer")
vim.api.nvim_set_current_buf(tool_buf)
require("ai.target").capture_current()

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
local original_buf_request_sync = vim.lsp.buf_request_sync
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
vim.lsp.buf_request_sync = function(bufnr, method)
  assert(method == "textDocument/documentSymbol", "unexpected sync LSP method: " .. tostring(method))
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  return {
    [1] = {
      result = {
        {
          name = "current",
          kind = vim.lsp.protocol.SymbolKind.Function,
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = line_count - 1, character = 1 },
          },
          selectionRange = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 7 },
          },
        },
      },
    },
  }
end

vim.cmd("new")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "fn upgrade() {",
  "  let service = ServiceRunner::get_service();",
  "",
  "  let jar = prepare_upgrade_jar();",
  "}",
})
local lsp_range_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 2, 4 })
local lsp_selection = context.selection_context({ range = 0 })
assert(lsp_selection.line1 == 1 and lsp_selection.line2 == 5, "selection context did not expand to current LSP symbol")
assert(lsp_selection.text:match("prepare_upgrade_jar"), "selection context LSP range only captured the first paragraph")
vim.api.nvim_set_current_buf(tool_buf)
vim.api.nvim_buf_delete(lsp_range_buf, { force = true })

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
local explain_float_winid = response_session.output_winid
local explain_float_bufnr = response_session.output_bufnr
local explain_input_winid = response_session.input_winid
local explain_input_bufnr = response_session.input_bufnr
assert(vim.api.nvim_win_get_config(explain_float_winid).relative == "editor", "AIExplain did not render in a floating window")
assert(vim.api.nvim_win_get_config(explain_input_winid).relative == "editor", "AIExplain did not render follow-up input")
assert(vim.api.nvim_get_current_win() == explain_float_winid, "AIExplain did not focus response output")
assert(vim.fn.mode() == "n", "AIExplain output focus did not use normal mode")
vim.api.nvim_set_current_win(explain_float_winid)
assert(vim.bo[vim.api.nvim_get_current_buf()].filetype == "markdown", "AIExplain floating output is not markdown")
assert(vim.fn.maparg("<Esc>", "n", false, true).buffer == 1, "AIExplain floating output missing close keymap")
assert(vim.fn.maparg("<C-q>", "n", false, true).buffer == 1, "AIExplain floating output missing normal ctrl-q close keymap")
vim.api.nvim_set_current_win(explain_input_winid)
assert(vim.api.nvim_get_current_buf() == explain_input_bufnr, "AIExplain did not focus follow-up input")
assert(vim.bo[vim.api.nvim_get_current_buf()].filetype == "text", "AIExplain follow-up input is not text")
assert(#vim.api.nvim_buf_get_extmarks(explain_input_bufnr, response_session.placeholder_ns, 0, -1, {}) == 1, "AIExplain follow-up placeholder missing")
assert(vim.fn.maparg("q", "n", false, true).buffer == 1, "AIExplain follow-up input missing normal q close keymap")
assert(vim.fn.maparg("<C-q>", "i", false, true).buffer == 1, "AIExplain floating output missing insert ctrl-q close keymap")
assert(vim.fn.maparg("<CR>", "i", false, true).buffer == 1, "AIExplain follow-up input missing send keymap")
local followup_messages
client.chat = function(messages, _, cb)
  followup_messages = messages
  cb(nil, "follow ok")
end
vim.api.nvim_buf_set_lines(explain_input_bufnr, 0, -1, false, { "why?" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = explain_input_bufnr })
assert(#vim.api.nvim_buf_get_extmarks(explain_input_bufnr, response_session.placeholder_ns, 0, -1, {}) == 0, "AIExplain follow-up placeholder did not clear")
response_session.send()
assert(vim.wait(5000, function()
  return followup_messages ~= nil
end), "timed out waiting for AIExplain follow-up")
local saw_initial_reply = false
local saw_followup_question = false
for _, message in ipairs(followup_messages) do
  if message.role == "assistant" and message.content == "explain ok" then
    saw_initial_reply = true
  elseif message.role == "user" and message.content == "why?" then
    saw_followup_question = true
  end
end
assert(saw_initial_reply, "AIExplain follow-up did not include initial assistant reply")
assert(saw_followup_question, "AIExplain follow-up did not include user question")
assert(table.concat(vim.api.nvim_buf_get_lines(explain_float_bufnr, 0, -1, false), "\n"):match("follow ok"), "AIExplain follow-up did not render response")
assert(vim.api.nvim_get_current_win() == explain_float_winid, "AIExplain follow-up did not return focus to response output")
assert(vim.fn.mode() == "n", "AIExplain follow-up output focus did not use normal mode")
vim.api.nvim_set_current_win(explain_input_winid)
local input_q_map = vim.fn.maparg("q", "n", false, true)
assert(type(input_q_map.callback) == "function", "AIExplain follow-up q keymap is not callable")
input_q_map.callback()
assert(not vim.api.nvim_win_is_valid(explain_float_winid), "AIExplain popup close did not close window")
assert(not vim.api.nvim_win_is_valid(explain_input_winid), "AIExplain popup close did not close input window")
assert(vim.api.nvim_buf_is_valid(explain_float_bufnr), "AIExplain close wiped the popup buffer")
if vim.api.nvim_win_is_valid(explain_source_winid) then
  vim.api.nvim_set_current_win(explain_source_winid)
end

local find_bug_ns = vim.api.nvim_create_namespace("ai.nvim.test.find_bug")
vim.diagnostic.set(find_bug_ns, tool_buf, {
  {
    lnum = 0,
    col = 0,
    end_lnum = 0,
    end_col = 5,
    severity = vim.diagnostic.severity.WARN,
    message = "possible nil access",
  },
})
local find_bug_prompt
client.chat = function(messages, _, cb)
  find_bug_prompt = messages[2].content
  cb(nil, "bug ok")
end
vim.api.nvim_set_current_buf(tool_buf)
vim.api.nvim_win_set_cursor(0, { 1, 6 })
request_params_by_method = {}
vim.cmd("AIFindBug")
assert(vim.wait(5000, function()
  return find_bug_prompt ~= nil
end), "timed out waiting for AIFindBug prompt")
assert(find_bug_prompt:match("Look for concrete correctness bugs"), "AIFindBug used the wrong prompt")
assert(find_bug_prompt:match("Do not report style"), "AIFindBug prompt is not strict enough")
assert(find_bug_prompt:match(":AIFixBug"), "AIFindBug did not point to fix preview command")
assert(find_bug_prompt:match("Diagnostics in selected range:"), "AIFindBug did not include selected diagnostics")
assert(find_bug_prompt:match("possible nil access"), "AIFindBug did not include diagnostic message")
assert(find_bug_prompt:match("Language context:"), "AIFindBug did not include language context")
assert(vim.api.nvim_win_is_valid(response_session.input_winid), "AIFindBug did not keep follow-up input open")
response_session.close()
vim.diagnostic.reset(find_bug_ns, tool_buf)
if vim.api.nvim_win_is_valid(explain_source_winid) then
  vim.api.nvim_set_current_win(explain_source_winid)
end

vim.api.nvim_set_current_buf(tool_buf)
vim.api.nvim_win_set_cursor(0, { 1, 6 })
local fix_bug_prompt
client.chat = function(messages, _, cb)
  fix_bug_prompt = messages[2].content
  cb(nil, "local x = 3")
end
request_params_by_method = {}
vim.cmd("AIFixBug")
assert(vim.wait(5000, function()
  return fix_bug_prompt ~= nil
end), "timed out waiting for AIFixBug prompt")
assert(fix_bug_prompt:match("Fix concrete correctness bugs"), "AIFixBug used the wrong prompt")
assert(fix_bug_prompt:match("preview the replacement"), "AIFixBug did not explain reviewable preview")
assert(fix_bug_prompt:match("Available code actions:"), "AIFixBug did not include code actions")
assert(ui.pending_edit and ui.pending_edit.replacement_lines[1] == "local x = 3", "AIFixBug did not create a pending edit preview")
ui.reject_pending()

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
local buffer_float_winid = response_session.output_winid
assert(vim.api.nvim_win_get_config(buffer_float_winid).relative == "editor", "AIBuffer did not render in a floating window")
assert(response_session.output_bufnr == explain_float_bufnr, "AIBuffer did not reuse the result session output buffer")
assert(vim.api.nvim_win_is_valid(response_session.input_winid), "AIBuffer did not keep follow-up input open")
assert(table.concat(vim.api.nvim_buf_get_lines(response_session.output_bufnr, 0, -1, false), "\n"):match("buffer ok"), "AIBuffer did not render provider response")
response_session.close()
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
ui.reject_pending()

vim.api.nvim_set_current_buf(tool_buf)
vim.api.nvim_win_set_cursor(0, { 1, 6 })
local comment_prompt
client.chat = function(messages, _, cb)
  comment_prompt = messages[2].content
  cb(nil, "-- Explain x\nlocal x = 2")
end
request_params_by_method = {}
vim.cmd("AIComment use English doc comments")
assert(vim.wait(5000, function()
  return comment_prompt ~= nil
end), "timed out waiting for AIComment prompt")
assert(comment_prompt:match("Add useful comments"), "AIComment used the wrong prompt")
assert(comment_prompt:match("Do not comment obvious syntax"), "AIComment prompt is not strict enough")
assert(comment_prompt:match("Additional user instruction:"), "AIComment did not preserve the user instruction section")
assert(comment_prompt:match("use English doc comments"), "AIComment dropped the user instruction")
assert(comment_prompt:match("Language context:"), "AIComment did not include language context")
assert(ui.pending_edit and ui.pending_edit.replacement_lines[1] == "-- Explain x", "AIComment did not create a pending edit preview")
assert(vim.api.nvim_win_is_valid(popup.winid), "AIComment did not render in a popup window")
assert(vim.api.nvim_buf_get_name(popup.bufnr):match("ai://edit%-preview"), "AIComment popup did not show the edit preview")
ui.reject_pending()
popup.close()

vim.api.nvim_set_current_buf(tool_buf)
vim.api.nvim_win_set_cursor(0, { 1, 6 })
require("ai.target").capture_current()
popup.open("scratch", "temporary popup", "markdown")
local comment_no_args_prompt
client.chat = function(messages, _, cb)
  comment_no_args_prompt = messages[2].content
  cb(nil, "-- Explain x\nlocal x = 2")
end
request_params_by_method = {}
vim.cmd("AIComment")
assert(vim.wait(5000, function()
  return comment_no_args_prompt ~= nil
end), "timed out waiting for AIComment without args")
assert(comment_no_args_prompt:match("Add useful comments"), "AIComment without args used the wrong prompt")
assert(not comment_no_args_prompt:match("Additional user instruction:"), "AIComment without args added an empty user instruction")
assert(comment_no_args_prompt:match(vim.pesc(tool_path)), "AIComment without args did not use the target editor buffer")
assert(ui.pending_edit and ui.pending_edit.bufnr == tool_buf, "AIComment without args did not preview against the target buffer")
assert(vim.api.nvim_buf_get_name(popup.bufnr):match("ai://edit%-preview"), "AIComment without args did not show the edit preview popup")
ui.reject_pending()
popup.close()

vim.api.nvim_set_current_buf(tool_buf)
vim.api.nvim_win_set_cursor(0, { 1, 6 })
local implement_prompt_seen
client.chat = function(messages, _, cb)
  assert(messages[1].content:match("Return a unified diff only"), "AIImplement did not include patch-only system instruction")
  implement_prompt_seen = messages[2].content
  cb(nil, [[
diff --git a/test.lua b/test.lua
--- a/test.lua
+++ b/test.lua
@@ -1 +1 @@
-local x = 1
+local x = 4
]])
end
request_params_by_method = {}
vim.cmd("AIImplement add support for x")
assert(vim.wait(5000, function()
  return implement_prompt_seen ~= nil
end), "timed out waiting for AIImplement prompt")
assert(implement_prompt_seen:match("Implement the requested change"), "AIImplement used the wrong prompt")
assert(implement_prompt_seen:match("User request:%s+add support for x"), "AIImplement did not include user request")
assert(implement_prompt_seen:match("Current editor context:"), "AIImplement did not include editor context")
assert(implement_prompt_seen:match("Relevant project context:"), "AIImplement did not include project context")
assert(implement_prompt_seen:match("Available code actions:"), "AIImplement did not include code actions")
assert(ui.pending_patch and ui.pending_patch.title == "implement", "AIImplement did not create a pending patch preview")
assert(popup.is_open(), "AIImplement did not render patch preview in a popup")
assert(vim.api.nvim_win_get_config(popup.winid).relative == "editor", "AIImplement popup is not floating")
assert(vim.fn.maparg("a", "n", false, true).buffer == 1, "AIImplement popup missing apply keymap")
ui.reject_pending()
popup.close()

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
vim.lsp.buf_request_sync = original_buf_request_sync

local quickfix = run_tool("nvim_quickfix")
assert(type(quickfix.items) == "table", "quickfix tool did not return items")

local loclist = run_tool("nvim_location_list")
assert(type(loclist.items) == "table", "location list tool did not return items")

local project_files = run_tool("nvim_project_files", { max_items = 5 })
assert(project_files.root ~= "", "project files tool did not return root")
assert(#project_files.files > 0, "project files tool returned no files")

local project_search = run_tool("nvim_project_search", { query = "AIChat", max_chars = 2000 })
assert(project_search.text ~= "", "project search tool returned empty text")

local project_context_text
context.project_context("how does AIChat work", function(err, text)
  assert(not err, err)
  project_context_text = text
end)
assert(vim.wait(5000, function()
  return project_context_text ~= nil
end), "timed out waiting for project context")
assert(project_context_text:match("# search terms\nAIChat"), "project context did not pick the distinctive search term")
assert(not project_context_text:match("# search terms\nhow"), "project context selected a stopword as search term")
assert(project_context_text:match("# rg results: AIChat"), "project context did not include rg results for the search term")

do
  local grep_result = run_tool("nvim_grep", { pattern = "AIChatToggle", glob = "*.lua", max_items = 50 })
  assert(grep_result.total > 0, "grep tool found no matches")
  assert(grep_result.items[1].path ~= "" and grep_result.items[1].lnum > 0, "grep tool returned malformed item")
  assert(grep_result.items[1].text:match("AIChatToggle"), "grep tool item text mismatch")

  local grep_fixed = run_tool("nvim_grep", { pattern = "M.chat_toggle()", fixed = true })
  assert(grep_fixed.total > 0, "fixed-string grep found no matches")

  local grep_empty = run_tool("nvim_grep", { pattern = "zz_no_such" .. "_string_in_repo_zz" })
  assert(grep_empty.total == 0 and #grep_empty.items == 0, "grep tool no-match case failed")

  local glob_result = run_tool("nvim_glob", { pattern = "lua/ai/*.lua" })
  assert(vim.tbl_contains(glob_result.files, "lua/ai/chat.lua"), "glob tool did not list chat.lua")
  assert(glob_result.total >= 10, "glob tool returned too few files")
end

local git_diff = run_tool("nvim_git_diff", { max_chars = 2000 })
assert(git_diff.text:match("# git status %-%-short"), "git diff tool returned wrong shape")

local command_preview = run_tool("nvim_preview_command", { command = "printf '%s\\n' ok" }, { source = "chat" })
assert(command_preview.status == "previewed", "command preview tool did not preview")
assert(require("ai.runner").pending.source == "chat", "command preview tool did not record chat source")

config.setup({
  provider = {
    api_key = "",
    stream = false,
  },
  chat = {
    max_tool_model_chars = 80,
  },
  safety = {
    auto_run_commands = true,
  },
})
local command_run = run_tool("nvim_preview_command", { command = "printf '%s\\n' autorun" }, { source = "chat" })
assert(command_run.status == "ran", "command preview tool did not auto-run with safety.auto_run_commands")
assert(command_run.output:match("autorun"), "auto-run command did not return output")
assert(not require("ai.runner").pending, "auto-run command left a pending command")
config.setup({
  provider = {
    api_key = "",
    stream = false,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})

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
assert(ui.pending_notice():match("Pending AI edit preview"), "pending edit notice missing")

local file_replace_preview = run_tool("nvim_preview_file_replace", {
  path = "README.md",
  start_line = 1,
  end_line = 1,
  replacement = "# ai.nvim",
})
assert(file_replace_preview.status == "previewed", "file replace tool did not preview")
assert(file_replace_preview.action == "file_replace", "file replace tool returned wrong action")

config.setup({
  provider = {
    api_key = "",
    stream = false,
  },
  safety = {
    auto_apply_edits = true,
  },
  chat = {
    max_tool_model_chars = 80,
  },
})
vim.cmd("new")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local auto = 1" })
local auto_apply_buf = vim.api.nvim_get_current_buf()
local auto_apply_preview = run_tool("nvim_preview_buffer_replace", {
  bufnr = auto_apply_buf,
  start_line = 1,
  end_line = 1,
  replacement = "local auto = 2",
})
assert(auto_apply_preview.status == "applied", "auto apply edit preview did not apply")
assert(ui.pending_edit == nil, "auto apply edit left a pending edit")
assert(vim.api.nvim_buf_get_lines(auto_apply_buf, 0, 1, false)[1] == "local auto = 2", "auto apply edit did not change buffer")
vim.api.nvim_buf_delete(auto_apply_buf, { force = true })
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
local chat = require("ai.chat")
assert(vim.api.nvim_buf_get_name(0):match("ai://chat$"), "AIChat did not focus message pane")
assert(vim.fn.mode() == "n", "AIChat message focus did not use normal mode")
vim.api.nvim_set_current_win(chat.input_winid)
assert(vim.fn.maparg("<CR>", "i", false, true).buffer == 1, "AIChat send keymap missing")
assert(vim.fn.maparg("<C-q>", "i", false, true).buffer == 1, "AIChat input close keymap missing")
assert(chat.target_bufnr == tool_buf, "AIChat did not retain target editor buffer")
local chat_state = run_tool("nvim_editor_state")
assert(chat_state.current_buffer.name:match("ai://chat%-input"), "editor state did not report actual focused chat buffer")
assert(chat_state.target_buffer and chat_state.target_buffer.bufnr == tool_buf, "editor state did not report target editor buffer")
assert(chat_state.target_buffer.cursor_line_text == "local x = 1", "editor state target buffer missing cursor line text")
local chat_current_buffer = run_tool("nvim_current_buffer")
assert(chat_current_buffer.bufnr == tool_buf, "current buffer tool used AIChat input instead of target buffer")
assert(chat_current_buffer.cursor_line_text == "local x = 1", "current buffer tool target missing cursor line text")
local chat_default_read = run_tool("nvim_read_buffer", { start_line = 1, end_line = 1 })
assert(chat_default_read.bufnr == tool_buf, "default read buffer tool used AIChat input instead of target buffer")
assert(chat_default_read.text == "1\tlocal x = 1", "default read buffer tool read wrong target text")
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
    assert(not messages[1].content:match("Available tools"), "AIChat native mode should not duplicate the tool registry text")
    assert(messages[1].content:match("native tools API"), "AIChat native mode did not mention native tool definitions")
    assert(messages[1].content:match("nvim_preview_buffer_replace"), "AIChat did not expose preview edit tools")
    assert(messages[1].content:match(":AIApply"), "AIChat did not explain preview apply flow")
    assert(messages[1].content:match("applied or rejected"), "AIChat did not explain the apply/reject follow-up flow")
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
assert(rendered_chat:match("> summary: `"), "AIChat tool result summary should be inline code (paths with ~ must not render as markdown)")
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
    assert(not messages[1].content:match("Available tools"), "AIChat stream native mode should not duplicate the tool registry text")
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
assert(vim.api.nvim_get_current_win() == chat.messages_winid, "AIChat toggle did not focus message pane")
assert(vim.fn.mode() == "n", "AIChat toggle message focus did not use normal mode")
local closed_messages_winid = chat.messages_winid
local closed_input_winid = chat.input_winid
chat.close()
assert(not vim.api.nvim_win_is_valid(closed_messages_winid), "AIChat close did not close messages pane")
assert(not vim.api.nvim_win_is_valid(closed_input_winid), "AIChat close did not close input pane")

vim.cmd("AIPopChat")
assert(chat.layout == "float", "AIPopChat did not use float layout")
assert(vim.api.nvim_get_current_win() == chat.messages_winid, "AIPopChat did not focus message pane")
assert(vim.fn.mode() == "n", "AIPopChat message focus did not use normal mode")
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
assert(vim.api.nvim_get_current_win() == chat.messages_winid, "AIPopChatToggle did not focus message pane")
assert(vim.fn.mode() == "n", "AIPopChatToggle message focus did not use normal mode")
chat.close()

vim.cmd("AIChat")
chat.clear()
do
  local apply_feedback_messages
  client.chat = function(messages, _, cb)
    apply_feedback_messages = messages
    cb(nil, "continuing after apply")
  end
  local chat_edit_preview = run_tool("nvim_preview_buffer_replace", {
    bufnr = tool_buf,
    start_line = 2,
    end_line = 2,
    replacement = "print(x) -- checked",
  }, { source = "chat" })
  assert(chat_edit_preview.status == "previewed", "chat edit preview did not preview")
  require("ai.ui").apply_pending()
  assert(vim.wait(5000, function()
    return apply_feedback_messages ~= nil
  end), "timed out waiting for apply feedback request")
  local apply_feedback = apply_feedback_messages[#apply_feedback_messages]
  assert(apply_feedback.role == "user" and apply_feedback.content:match("applied the edit preview"), "AIApply did not feed the apply result back to chat")
  assert(vim.wait(5000, function()
    return not chat.active
  end), "timed out waiting for apply feedback round")
  assert(vim.api.nvim_buf_get_lines(tool_buf, 1, 2, false)[1] == "print(x) -- checked", "AIApply did not apply the chat edit")
  local rendered_apply = table.concat(vim.api.nvim_buf_get_lines(chat.messages_bufnr, 0, -1, false), "\n")
  assert(rendered_apply:match("## Editor"), "apply feedback was not rendered as an editor event")

  local reject_calls = 0
  client.chat = function(_, _, cb)
    reject_calls = reject_calls + 1
    cb(nil, "should not be requested")
  end
  local chat_reject_preview = run_tool("nvim_preview_buffer_replace", {
    bufnr = tool_buf,
    start_line = 1,
    end_line = 1,
    replacement = "local x = 9",
  }, { source = "chat" })
  assert(chat_reject_preview.status == "previewed", "chat reject preview did not preview")
  require("ai.ui").reject_pending()
  assert(reject_calls == 0, "AIReject should not trigger a model request")
  local reject_event = chat.history[#chat.history]
  assert(reject_event.kind == "event" and reject_event.content:match("rejected the pending edit"), "AIReject did not record an editor event")
  client.chat = original_chat
  chat.close()

  local unnamed_before_chat = count_unnamed_buffers()
  vim.cmd("AIChatToggle")
  vim.cmd("AIChatToggle")
  vim.cmd("AIChatToggle")
  vim.cmd("AIChatToggle")
  assert(count_unnamed_buffers() == unnamed_before_chat, "AIChat side layout leaked unnamed buffers")

  ui.open_output("reuse-leak-test", "one")
  vim.cmd("vsplit")
  local keepalive_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(keepalive_winid, ui.output_bufnr)
  pcall(vim.api.nvim_win_close, ui.output_winid, true)
  local unnamed_before_reuse = count_unnamed_buffers()
  ui.open_output("reuse-leak-test", "two")
  assert(count_unnamed_buffers() == unnamed_before_reuse, "output window reuse leaked an unnamed buffer")
  pcall(vim.api.nvim_win_close, ui.output_winid, true)
  pcall(vim.api.nvim_win_close, keepalive_winid, true)
end

do
  local session = require("ai.session")
  local persist_dir = vim.fn.tempname()
  config.setup({
    system_prompt = "请使用中文回复对话。",
    provider = {
      api_key = "",
      stream = false,
    },
    chat = {
      max_tool_model_chars = 80,
      sessions = { enabled = true, dir = persist_dir, keep = 5 },
    },
  })
  vim.cmd("AIChat")
  chat.clear()
  client.chat = function(_, _, cb)
    cb(nil, "persisted reply")
  end
  chat.send("persist me please")
  assert(vim.wait(5000, function()
    return not chat.active
  end), "timed out waiting for persisted chat round")
  client.chat = original_chat

  local persisted = session.list()
  assert(#persisted == 1, "chat session was not persisted")
  assert(persisted[1].count == 2, "persisted session message count mismatch")
  assert(persisted[1].preview:match("persist me"), "session preview missing first user message")

  local saved_history_len = #chat.history
  chat.clear()
  assert(#chat.history == 0, "chat clear did not empty history")
  assert(chat.restore("latest"), "chat session restore failed")
  assert(#chat.history == saved_history_len, "restored history length mismatch")
  assert(chat.history[1].content == "persist me please", "restored history missing user message")
  assert(chat.history[#chat.history].content == "persisted reply", "restored history missing assistant reply")

  client.chat = function(_, _, cb)
    cb(nil, "second reply")
  end
  chat.send("continue session")
  assert(vim.wait(5000, function()
    return not chat.active
  end), "timed out waiting for continued session round")
  client.chat = original_chat
  persisted = session.list()
  assert(#persisted == 1, "continuing a restored session created a new file")
  assert(persisted[1].count == 4, "continued session did not append messages")

  chat.clear()
  for index = 1, 6 do
    table.insert(chat.history, {
      role = "tool",
      native = true,
      tool_call_id = "call_downsample_" .. index,
      summary = "tool summary " .. index,
      content = "full content " .. index,
      model_content = "full model content " .. index,
    })
  end
  local downsample_messages
  client.chat = function(messages, _, cb)
    downsample_messages = messages
    cb(nil, "downsample ok")
  end
  chat.send("after many tool calls")
  assert(vim.wait(5000, function()
    return not chat.active
  end), "timed out waiting for downsample round")
  client.chat = original_chat
  local full_results = 0
  local compressed_results = 0
  for _, message in ipairs(downsample_messages) do
    if message.role == "tool" then
      if message.content:match("^%[compressed%]") then
        compressed_results = compressed_results + 1
        assert(message.content:match("tool summary"), "compressed tool result lost its summary")
      else
        full_results = full_results + 1
      end
    end
  end
  assert(full_results == 4, "downsampling did not keep the most recent tool results in full")
  assert(compressed_results == 2, "downsampling did not compress older tool results")
end
chat.clear()
chat.close()
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

vim.cmd("AIChat")
chat.clear()
do
  local fence_calls = 0
  client.chat = function(_, _, cb)
    fence_calls = fence_calls + 1
    cb(nil, table.concat({
      "You can call tools like:",
      "",
      "```json",
      [[{"tool":"nvim_current_buffer","args":{}}]],
      "```",
      "Done.",
    }, "\n"))
  end
  chat.send("show me a tool example")
  assert(vim.wait(5000, function()
    return not chat.active
  end), "timed out waiting for fenced example round")
  client.chat = original_chat
  assert(fence_calls == 1, "fenced tool example triggered extra model rounds")
  for _, message in ipairs(chat.history) do
    assert(message.kind ~= "tool_call", "fenced tool example was executed as a tool call")
  end

  config.setup({
    system_prompt = "请使用中文回复对话。",
    provider = {
      api_key = "",
      stream = false,
    },
    chat = {
      max_tool_model_chars = 80,
      max_tool_rounds = 2,
    },
  })
  chat.clear()
  local limit_call_index = 0
  local limit_final_opts
  client.chat = function(_, opts, cb)
    limit_call_index = limit_call_index + 1
    if opts.tools then
      cb(nil, "", nil, {
        content = "",
        tool_calls = {
          {
            id = "call_limit_" .. limit_call_index,
            type = "function",
            ["function"] = { name = "nvim_current_buffer", arguments = "{}" },
          },
        },
      })
      return
    end
    limit_final_opts = opts
    cb(nil, "final summary without tools")
  end
  chat.send("keep calling tools forever")
  assert(vim.wait(5000, function()
    return not chat.active
  end), "timed out waiting for round-limit flow")
  client.chat = original_chat
  assert(limit_final_opts ~= nil and limit_final_opts.tools == nil, "round limit did not request a tool-free final answer")
  assert(chat.history[#chat.history].content == "final summary without tools", "round limit final answer missing from history")
  local saw_limit_event = false
  for _, message in ipairs(chat.history) do
    if message.kind == "event" and (message.content or ""):match("tool round limit") then
      saw_limit_event = true
    end
  end
  assert(saw_limit_event, "round limit event note missing from history")
  assert(chat.status == "idle", "round limit flow did not end idle")
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

  vim.api.nvim_set_current_win(chat.input_winid)
  assert(vim.fn.maparg("<C-j>", "i", false, true).buffer == 1, "AIChat input missing newline keymap")
  chat.close()

  vim.api.nvim_set_current_buf(tool_buf)
  require("ai.target").capture_current()
  chat.clear()
  local range_message
  client.chat = function(messages, _, cb)
    range_message = messages[#messages].content
    cb(nil, "range ok")
  end
  vim.cmd("1,2AIChat explain selection")
  assert(vim.wait(5000, function()
    return not chat.active
  end), "timed out waiting for ranged AIChat")
  client.chat = original_chat
  assert(range_message:match("explain selection"), "ranged AIChat dropped the prompt")
  assert(range_message:match("local x = 1"), "ranged AIChat did not include the selection")
  chat.close()

  vim.api.nvim_set_current_buf(tool_buf)
  chat.clear()
  vim.cmd("1,1AIChat")
  local selection_event = chat.history[#chat.history]
  assert(selection_event and selection_event.kind == "event", "ranged AIChat without prompt did not record an event")
  assert(selection_event.content:match("shared this selection"), "selection event content mismatch")
end
chat.clear()
chat.close()

local target = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(target, 0, -1, false, { "local x = 1", "print(x)" })

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
local extracted_with_trailing_text = patch.extract([[
diff --git a/test.lua b/test.lua
--- a/test.lua
+++ b/test.lua
@@ -1 +1 @@
-local x = 1
+local x = 2

This patch updates the value.
]])
assert(extracted_with_trailing_text and not extracted_with_trailing_text:match("This patch"), "patch extraction included trailing prose")
local extracted_fenced_with_trailing_text = patch.extract([[
```diff
diff --git a/test.lua b/test.lua
--- a/test.lua
+++ b/test.lua
@@ -1 +1 @@
-local x = 1
+local x = 2

This patch updates the value.
```
]])
assert(extracted_fenced_with_trailing_text and not extracted_fenced_with_trailing_text:match("This patch"), "fenced patch extraction included trailing prose")

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
vim.bo[current].modified = false

local apply_done = false
local apply_err
local apply_message
patch.apply([[
diff --git a/test.lua b/test.lua
--- a/test.lua
+++ b/test.lua
@@ -1 +1 @@
-local x = 1
+local x = 2

This patch updates the value.
]], function(err, message)
  apply_err = err
  apply_message = message
  apply_done = true
end)

assert(vim.wait(5000, function()
  return apply_done
end), "timed out waiting for patch apply")
assert(not apply_err, apply_err)
local changed = vim.fn.readfile(tmp .. "/test.lua")
assert(changed[1] == "local x = 1", "buffer patch apply wrote to disk before save")
assert(vim.api.nvim_buf_get_lines(current, 0, 1, false)[1] == "local x = 2", "buffer patch apply did not update loaded buffer")
assert(vim.bo[current].modified, "buffer patch apply did not mark buffer modified")
assert(apply_message and apply_message:match("Patch applied to 1 buffer"), "buffer patch apply did not report applied buffer")

vim.fn.writefile({ "-- old" }, tmp .. "/comment.lua")
local comment_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(comment_buf, tmp .. "/comment.lua")
vim.api.nvim_buf_set_lines(comment_buf, 0, -1, false, { "-- old" })
vim.bo[comment_buf].modified = false
local comment_done = false
local comment_err
patch.apply([[
diff --git a/comment.lua b/comment.lua
--- a/comment.lua
+++ b/comment.lua
@@ -1 +1 @@
--- old
+-- new
]], function(err)
  comment_err = err
  comment_done = true
end, { cwd = tmp })
assert(vim.wait(5000, function()
  return comment_done
end), "timed out waiting for comment patch apply")
assert(not comment_err, comment_err)
assert(vim.api.nvim_buf_get_lines(comment_buf, 0, 1, false)[1] == "-- new", "buffer patch apply misparsed comment hunk lines")

vim.fn.writefile({ "local wrong = 1" }, tmp .. "/wrong-count.lua")
local wrong_count_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(wrong_count_buf, tmp .. "/wrong-count.lua")
vim.api.nvim_buf_set_lines(wrong_count_buf, 0, -1, false, { "local wrong = 1" })
vim.bo[wrong_count_buf].modified = false
local wrong_count_done = false
local wrong_count_err
patch.apply([[
diff --git a/wrong-count.lua b/wrong-count.lua
--- a/wrong-count.lua
+++ b/wrong-count.lua
@@ -1,99 +1,99 @@
-local wrong = 1
+local wrong = 2
]], function(err)
  wrong_count_err = err
  wrong_count_done = true
end, { cwd = tmp })
assert(vim.wait(5000, function()
  return wrong_count_done
end), "timed out waiting for wrong-count patch apply")
assert(not wrong_count_err, wrong_count_err)
assert(vim.api.nvim_buf_get_lines(wrong_count_buf, 0, 1, false)[1] == "local wrong = 2", "buffer patch apply rejected wrong hunk counts")

vim.fn.writefile({ "local before = 1", "local keep = true", "local target = 1", "local after = 1" }, tmp .. "/relocate.lua")
local relocate_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(relocate_buf, tmp .. "/relocate.lua")
vim.api.nvim_buf_set_lines(relocate_buf, 0, -1, false, { "local before = 1", "local keep = true", "local target = 1", "local after = 1" })
vim.bo[relocate_buf].modified = false
local relocate_done = false
local relocate_err
patch.apply([[
diff --git a/relocate.lua b/relocate.lua
--- a/relocate.lua
+++ b/relocate.lua
@@ -99 +99 @@
-local target = 1
+local target = 2
]], function(err)
  relocate_err = err
  relocate_done = true
end, { cwd = tmp })
assert(vim.wait(5000, function()
  return relocate_done
end), "timed out waiting for relocated patch apply")
assert(not relocate_err, relocate_err)
assert(vim.api.nvim_buf_get_lines(relocate_buf, 2, 3, false)[1] == "local target = 2", "buffer patch apply did not relocate shifted hunk")

local undo_lines = {}
for index = 1, 120 do
  undo_lines[index] = ("line %03d"):format(index)
end
vim.fn.writefile(undo_lines, tmp .. "/undo.lua")
local undo_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(undo_buf)
vim.api.nvim_buf_set_name(undo_buf, tmp .. "/undo.lua")
vim.bo[undo_buf].undolevels = -1
vim.api.nvim_buf_set_lines(undo_buf, 0, -1, false, undo_lines)
vim.bo[undo_buf].undolevels = 1000
vim.bo[undo_buf].modified = false
vim.api.nvim_win_set_cursor(0, { 100, 0 })
local undo_done = false
local undo_err
patch.apply([[
diff --git a/undo.lua b/undo.lua
--- a/undo.lua
+++ b/undo.lua
@@ -100 +100 @@
-line 100
+line 100 patched
]], function(err)
  undo_err = err
  undo_done = true
end, { cwd = tmp })
assert(vim.wait(5000, function()
  return undo_done
end), "timed out waiting for undo patch apply")
assert(not undo_err, undo_err)
assert(vim.api.nvim_buf_get_lines(undo_buf, 99, 100, false)[1] == "line 100 patched", "buffer patch apply did not update undo target")
vim.cmd("undo")
assert(vim.api.nvim_buf_get_lines(undo_buf, 99, 100, false)[1] == "line 100", "buffer patch undo did not restore target")
assert(vim.api.nvim_win_get_cursor(0)[1] >= 95, "buffer patch undo moved cursor too far from edited line")

vim.fn.writefile({ "local autosave = 1" }, tmp .. "/autosave.lua")
local autosave_buf = vim.fn.bufadd(tmp .. "/autosave.lua")
vim.fn.bufload(autosave_buf)
config.setup({
  provider = {
    api_key = "",
    stream = false,
  },
  chat = {
    max_tool_model_chars = 80,
  },
  safety = {
    auto_apply_edits = true,
    auto_write_edits = true,
  },
})
local autosave_preview = run_tool("nvim_preview_buffer_replace", {
  bufnr = autosave_buf,
  start_line = 1,
  end_line = 1,
  replacement = "local autosave = 2",
})
assert(autosave_preview.status == "applied", "auto write edit preview did not apply")
assert(autosave_preview.written == true, "auto write edit did not report written status")
assert(not vim.bo[autosave_buf].modified, "auto write edit left the buffer modified")
assert(vim.fn.readfile(tmp .. "/autosave.lua")[1] == "local autosave = 2", "auto write edit did not write the file to disk")
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

vim.fn.writefile({ "alpha", "beta", "alpha" }, tmp .. "/edit.lua")
vim.api.nvim_set_current_buf(autosave_buf)
require("ai.target").capture_current()

do
  local ambiguous_err = run_tool_error("nvim_edit_file", { path = "edit.lua", old_string = "alpha", new_string = "ALPHA" })
  assert(ambiguous_err:match("2 locations"), "ambiguous edit_file did not report the match count")

  local missing_err = run_tool_error("nvim_edit_file", { path = "edit.lua", old_string = "missing text", new_string = "x" })
  assert(missing_err:match("not found"), "edit_file did not report a missing old_string")

  local prefixed_err = run_tool_error("nvim_edit_file", { path = "edit.lua", old_string = "1\talpha", new_string = "x" })
  assert(prefixed_err:match("line%-number prefixes"), "edit_file did not hint about line-number prefixes")

  local string_edit = run_tool("nvim_edit_file", { path = "edit.lua", old_string = "beta", new_string = "BETA" })
  assert(string_edit.status == "previewed" and string_edit.action == "edit_file", "edit_file did not preview")
  assert(string_edit.start_line == 2 and string_edit.end_line == 2, "edit_file computed the wrong range")
  assert(ui.pending_edit and ui.pending_edit.replacement_lines[1] == "BETA", "edit_file replacement mismatch")
  ui.reject_pending()

  local multiline_edit = run_tool("nvim_edit_file", { path = "edit.lua", old_string = "beta\nalpha", new_string = "one\ntwo\nthree" })
  assert(multiline_edit.start_line == 2 and multiline_edit.end_line == 3, "multi-line edit_file range mismatch")
  assert(ui.pending_edit and #ui.pending_edit.replacement_lines == 3, "multi-line edit_file replacement mismatch")
  ui.reject_pending()

  local create_preview = run_tool("nvim_create_file", { path = "created/new.lua", content = "line one\nline two" })
  assert(create_preview.status == "previewed" and create_preview.action == "create_file", "create_file did not preview")
  assert(ui.pending_create and ui.pending_create.path:match("created/new%.lua$"), "create_file pending action missing")
  local created_path = ui.pending_create.path
  ui.apply_pending()
  local created_bufnr = vim.fn.bufnr(created_path)
  assert(created_bufnr ~= -1, "create_file apply did not create a buffer")
  assert(vim.api.nvim_buf_get_lines(created_bufnr, 0, -1, false)[2] == "line two", "create_file content mismatch")
  -- auto_write_new_files defaults to true, so a created file lands on disk
  assert(vim.fn.filereadable(created_path) == 1, "create_file apply should write the new file to disk by default")
  assert(table.concat(vim.fn.readfile(created_path), "\n"):match("line two"), "create_file disk content mismatch")
  assert(ui.pending_create == nil, "create_file apply left a pending action")
  vim.fn.delete(created_path)

  -- with auto_write_new_files disabled, the new file stays in-buffer (gated like edits)
  config.setup({
    provider = { api_key = "", stream = false },
    safety = { auto_write_new_files = false },
    chat = { max_tool_model_chars = 80 },
  })
  run_tool("nvim_create_file", { path = "created/gated.lua", content = "gated" })
  local gated_path = ui.pending_create.path
  ui.apply_pending()
  assert(vim.fn.filereadable(gated_path) == 0, "create_file should stay in-buffer when auto_write_new_files is off")
  config.setup({
    provider = { api_key = "", stream = false },
    chat = { max_tool_model_chars = 80 },
  })
  vim.fn.delete(vim.fn.fnamemodify(created_path, ":h"), "rf")

  local exists_err = run_tool_error("nvim_create_file", { path = "edit.lua", content = "x" })
  assert(exists_err:match("already exists"), "create_file did not refuse an existing file")
end

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

-- Tree-sitter code context: boundaries, outline, scope (Phases 1-3).
do
  local ts = require("ai.treesitter")
  local ts_buffers = {}
  local function ts_buf(lines, ft)
    vim.cmd("new")
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].filetype = ft
    table.insert(ts_buffers, b)
    return b
  end

  -- enclosing_range: explicit line is decoupled from the window cursor.
  local plain = ts_buf({ "local x = 1", "local function foo()", "  return 1", "end" }, "lua")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert(ts.enclosing_range(plain, 1) == nil, "ts enclosing_range outside a function should be nil")
  local fr1, fr2 = ts.enclosing_range(plain, 3)
  assert(fr1 == 2 and fr2 == 4, "ts enclosing_range should find foo (2-4) by explicit line")

  -- symbols: wrapper-artifact dedup keeps real, named, nested symbols.
  local nested = ts_buf({
    "local function outer()",
    "  local function inner()",
    "    return 1",
    "  end",
    "  return inner",
    "end",
    "local function sibling()",
    "  return 2",
    "end",
  }, "lua")
  local syms = ts.symbols(nested)
  assert(#syms == 3, "ts symbols should dedup to 3 real symbols, got " .. #syms)
  assert(syms[1].name == "outer" and syms[2].name == "inner" and syms[3].name == "sibling", "ts symbols name/order")

  -- outline: nested indentation, siblings back at depth 0.
  local outline = context.outline(nested)
  assert(outline:match("^function outer %[1%-6%]"), "ts outline: outer at depth 0")
  assert(outline:match("\n  function inner %[2%-4%]"), "ts outline: inner indented one level")
  assert(outline:match("\nfunction sibling %[7%-9%]"), "ts outline: sibling back at depth 0")

  -- imports + enclosing scope + scope_context (C).
  local cbuf = ts_buf({
    "#include <stdio.h>",
    '#include "foo.h"',
    "int main(void) {",
    "  return 0;",
    "}",
  }, "c")
  assert(#ts.imports(cbuf) == 2, "ts imports should find 2 includes")
  local cscopes = ts.enclosing_scopes(cbuf, 4)
  assert(#cscopes == 1 and cscopes[1].line1 == 3, "ts enclosing_scopes should find main")
  local sc = context.scope_context(cbuf, 4)
  assert(sc:match("Imports:") and sc:match("#include <stdio.h>"), "scope_context should include imports")
  assert(sc:match("Enclosing scope:"), "scope_context should include the scope chain")

  -- nested scope chain is outermost-first and keeps an anonymous scope.
  local anon = ts_buf({
    "local function wrap()",
    "  local f = function()",
    "    return 1",
    "  end",
    "  return f",
    "end",
  }, "lua")
  local ascopes = ts.enclosing_scopes(anon, 3)
  assert(#ascopes == 2 and ascopes[1].name == "wrap", "scope chain should be outermost-first")
  assert(ascopes[2].line1 == 2 and ascopes[2].line2 == 4, "anonymous inner scope should be retained")

  -- selection_context captures scope by default and skips it on request.
  vim.api.nvim_set_current_buf(cbuf)
  vim.api.nvim_win_set_cursor(0, { 4, 2 })
  assert(context.selection_context({ range = 0 }).scope_context ~= "", "selection_context should capture scope by default")
  assert(
    context.selection_context({ range = 0 }, { scope = false }).scope_context == "",
    "selection_context scope=false should skip scope"
  )

  -- long signatures are truncated and the scope text stays bounded.
  local longsig = ts_buf({ "local function f(" .. string.rep("a", 300) .. ")", "  return 1", "end" }, "lua")
  local long_scope = context.scope_context(longsig, 2)
  assert(long_scope:match("…"), "scope_context should truncate a very long signature")
  assert(#long_scope < 400, "scope_context should stay bounded")

  vim.api.nvim_set_current_buf(tool_buf)
  for _, b in ipairs(ts_buffers) do
    if vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
end

print("ai.nvim smoke ok")
