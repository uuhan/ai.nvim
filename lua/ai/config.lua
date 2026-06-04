local M = {}

local defaults = {
  provider = {
    base_url = "https://api.openai.com/v1",
    endpoint = "/chat/completions",
    model = "gpt-4.1-mini",
    api_key_env = "OPENAI_API_KEY",
    api_key = nil,
    curl = "curl",
    timeout_ms = 60000,
    temperature = 0.2,
    max_tokens = nil,
    stream = false,
    thinking = false,
    reasoning_effort = nil,
    extra_headers = {},
  },
  rules = {
    enabled = true,
    max_chars = 12000,
    files = {
      ".nvim/ai.md",
      ".ai/rules.md",
      "AGENTS.md",
      "CLAUDE.md",
      "codex.md",
    },
  },
  project = {
    markers = { ".git", "Cargo.toml", "package.json", "go.mod", "pyproject.toml", "Makefile" },
    max_context_chars = 30000,
    max_rg_matches = 80,
    max_file_list = 120,
  },
  ui = {
    reuse_output = true,
    auto_scroll = true,
    output_cmd = "botright vertical 80new",
    filetype = "markdown",
    buffer_keymaps = {
      apply = "a",
      reject = "r",
      next = "n",
      patch = "p",
      run = "t",
      done = "d",
      skip = "s",
      close = "q",
    },
  },
  chat = {
    width = 80,
    input_height = 3,
    popup = {
      width = 0.82,
      height = 0.78,
      border = "rounded",
    },
    placeholder = "在此输入，Enter 发送",
    render_markdown = true,
    native_tools = true,
    tools_enabled = true,
    max_tool_rounds = 20,
    max_tool_model_chars = 6000,
    max_tool_result_chars = 20000,
    fold_tool_results = true,
  },
  safety = {
    allow_dangerous_commands = false,
    blocked_command_patterns = {
      "rm%s+%-rf%s+/",
      "git%s+reset%s+%-%-hard",
      "git%s+clean%s+%-[fdxFDX]",
      "mkfs",
      "dd%s+if=",
      ":%(%)%s*{%s*:%|:%s*&%s*}:%s*;",
      "sudo%s+rm",
    },
  },
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  return M.options
end

function M.get()
  return M.options
end

return M
