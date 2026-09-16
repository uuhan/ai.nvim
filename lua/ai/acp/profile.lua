--- Session profile for the ACP backend.
---
--- The agent on the other end runs its own tools by default. Handing it this
--- profile makes the session exclusive: it then runs only the tools declared
--- here, which are the same tools the OpenAI backend sends. Switching backends
--- therefore changes the transport, not what the model can do.
local config = require("ai.config")
local tools = require("ai.tools")

local M = {}

local EXTENSION = "yaah.dev/session-profile"

--- Tool declarations in the shape a host catalog accepts: exactly name,
--- description and parameters. Unknown keys are rejected by the agent, so the
--- OpenAI export is trimmed rather than extended — both backends then share one
--- registry and one JSON-schema normalization.
function M.tools()
  local declarations = {}
  for _, entry in ipairs(tools.openai_tools()) do
    local spec = entry["function"] or {}
    if spec.name then
      table.insert(declarations, {
        name = spec.name,
        description = spec.description or "",
        parameters = spec.parameters,
      })
    end
  end
  return declarations
end

function M.enabled()
  local acp = config.get().acp or {}
  if acp.tools == false then
    return false
  end
  return config.get().chat.tools_enabled ~= false
end

--- `clientCapabilities._meta` for `initialize`. The agent refuses a profile it
--- was never told the client understands, so this has to precede the session.
function M.client_capabilities(capabilities)
  capabilities = vim.deepcopy(capabilities or {})
  if M.enabled() then
    capabilities._meta = vim.tbl_extend("force", capabilities._meta or {}, { [EXTENSION] = true })
  end
  return capabilities
end

--- `session/new._meta`, or nil to leave the agent with its own tools.
---
--- An empty catalog is not the same as no catalog: it would leave the model
--- with no tools at all. With nothing to declare, send no profile.
function M.session_meta(instructions)
  if not M.enabled() then
    return nil
  end
  local declarations = M.tools()
  if #declarations == 0 then
    return nil
  end
  return {
    [EXTENSION] = {
      instructions = instructions or "",
      tools = declarations,
    },
  }
end

return M
