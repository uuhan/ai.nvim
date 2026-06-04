if vim.g.loaded_ai_nvim == 1 then
  return
end

vim.g.loaded_ai_nvim = 1

require("ai").setup()
