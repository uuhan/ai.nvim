local config = require("ai.config")

local M = {}

function M.setup(opts)
  config.setup(opts)
  require("ai.commands").setup()
  return config.get()
end

function M.config()
  return config.get()
end

function M.tools()
  return require("ai.tools")
end

function M.acp(opts)
  return require("ai.acp.client").new(opts)
end

return M
