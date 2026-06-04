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

print("ai.nvim smoke ok")
