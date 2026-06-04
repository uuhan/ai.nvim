# ai.nvim

A small Neovim AI assistant built around editor operations:

- run prompts on a visual selection, paragraph, buffer, file, git diff, or project search context
- preview AI edits as a unified diff before applying them
- use LSP diagnostics, quickfix entries, git diff, and project rules as request context
- talk to OpenAI-compatible `/v1/chat/completions` endpoints through `curl`

This is intentionally not just a chat panel. The useful path is:

```text
selection + intent -> diff preview -> confirm apply
diagnostic + context -> minimal patch guidance
git diff -> review / commit message
project grep -> answer with source context
```

## Install

With lazy.nvim:

```lua
{
  "uuhan/ai.nvim",
  opts = {
    provider = {
      model = "gpt-5.4-mini",
      api_key_env = "OPENAI_API_KEY",
      base_url = "https://api.openai.com/v1",
      stream = true,
    },
  },
}
```

For local or compatible providers:

```lua
require("ai").setup({
  provider = {
    base_url = "http://localhost:11434/v1",
    api_key = "",
    model = "qwen2.5-coder",
  },
})
```

If your provider does not require a key, set the env var to an empty value or
use:

```lua
require("ai").setup({
  provider = {
    api_key = "",
    temperature = false, -- omit temperature for providers that reject it
  },
})
```

## Commands

Core editing:

```vim
:AI {prompt}                 " ask about visual selection or current paragraph
:AIExplain                   " explain selected/current code
:AIEdit {instruction}        " generate replacement and preview diff
:AIRefactor                  " refactor selected/current code
:AIFix                       " fix selected/current code
:AITest                      " suggest tests for selected/current code
:AIApply                     " apply the latest AI edit preview
:AIReject                    " clear the latest AI edit preview
```

Buffer and project context:

```vim
:AIBuffer {prompt}
:AIFile {prompt}
:AISummarizeFile
:AIProject {question}
:AIAskProject {question}
```

Diagnostics and git:

```vim
:AIFixDiagnostic
:AIFixAllDiagnostics
:AIFixQuickfix
:AIReviewDiff
:AIExplainDiff
:AIFindBugInDiff
:AICommitMessage
```

Shell commands:

```vim
:AICmd {task}                " generate a shell command for review
:AIShell {task}              " alias for :AICmd
:AIGit {task}                " generate a git command
:AIRun                       " run the latest generated command
```

Agent plan:

```vim
:AIAgent {task}              " create a reviewable plan
:AIPlanNext                  " preview the next pending step
:AIPlanApply                 " preview the next patch step
:AIPlanRun                   " preview the next command/test step
:AIPlanDone                  " mark the active step done
:AIPlanSkip                  " skip the active step
:AIPlanShow                  " show the active plan
:AIPlanReset                 " clear the active plan
```

Chat:

```vim
:AIChat {message}
:AIChatReset
```

Configuration and rules:

```vim
:AIPing
:AIConfig
:AIRules
```

Project rule files are automatically included when present:

```text
.nvim/ai.md
.ai/rules.md
AGENTS.md
CLAUDE.md
codex.md
```

## Notes

- Edits are never applied automatically. Use `:AIApply` after inspecting the diff.
- AI-generated patches are never applied automatically. Use `:AIApply` after inspecting the patch.
- AI-generated shell commands are never executed automatically. Use `:AIRun` after inspecting the command.
- `:AIProject` uses `rg` when available. It does not maintain a vector database.
- `:AIReviewDiff` and related commands read `git diff`, `git diff --cached`, and
  `git status --short`.
- `:AIReviewDiff` and `:AIFindBugInDiff` parse `file:line` references from the
  AI response and place them in the location list when possible.
- Command execution has a small safety blocklist by default. Set
  `safety.allow_dangerous_commands = true` only if you want `:AIRun` to skip it.
- Set `provider.stream = true` to stream normal answers and chat responses.
  Patch and command requests stay non-streaming so the plugin can parse the
  complete result before previewing it.
- `:AIAgent` generates a plan only. It does not apply patches or run commands.
  Use `:AIPlanApply` with `:AIApply`, or `:AIPlanRun` with `:AIRun`, then
  `:AIPlanDone` to advance the plan.
- `:AIPing` sends a tiny non-streaming request to the configured model and shows
  provider, model, elapsed time, and response.
