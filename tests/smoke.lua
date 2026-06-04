vim.opt.runtimepath:append(vim.fn.getcwd())

local ai = require("ai")
ai.setup({
  provider = {
    api_key = "",
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
  "AIFixAllDiagnostics",
  "AIReviewDiff",
  "AIProject",
  "AIChat",
  "AIConfig",
}

for _, name in ipairs(commands) do
  assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
end

vim.cmd("new")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = 1", "print(x)" })
vim.cmd("AIConfig")
vim.cmd("AIRules")

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

local client = require("ai.client")
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

print("ai.nvim smoke ok")
