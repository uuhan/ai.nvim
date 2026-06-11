local M = {}

local defaults = {
  system_prompt = nil,
  provider = {
    base_url = "https://api.openai.com/v1",
    endpoint = "/chat/completions",
    model = "gpt-4.1-mini",
    api_key_env = "OPENAI_API_KEY",
    api_key = nil,
    curl = "curl",
    transport = "curl",
    timeout_ms = 60000,
    temperature = 0.2,
    max_tokens = nil,
    stream = false,
    thinking = false,
    reasoning_effort = nil,
    extra_headers = {},
  },
  streaming = {
    interval_ms = 30,
    max_chars_per_flush = 96,
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
    max_full_tool_results = 4,
    fold_tool_results = true,
    sessions = {
      enabled = true,
      -- dir defaults to stdpath("state")/ai.nvim/sessions when unset
      resume = "manual",
      keep = 20,
    },
  },
  response = {
    input_title = " You ",
    placeholder = "Input & Enter",
  },
  quick = {
    prompt = "AI: ",
    title = "ai.nvim",
    group = "ai.nvim.quick",
    use_fidget = true,
    max_notify_chars = 600,
    instruction = "Quick mode: use Neovim harness tools to complete the user's task when possible. For command-oriented tasks, use the command preview tool according to the configured safety settings instead of only describing commands. Keep the final reply short.",
  },
  safety = {
    auto_apply_edits = false,
    auto_write_edits = false,
    auto_run_commands = false,
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
