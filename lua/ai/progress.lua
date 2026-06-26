-- A shared progress indicator for long-running AI requests.
--
-- Prefers fidget's progress API (an indeterminate, animated spinner that stays
-- visible until finished) so the status does not expire like a one-shot
-- notification while waiting for the model; falls back to a key-updated
-- notification when fidget's progress API is unavailable.

local M = {}

local function emit_notify(text, level, opts)
  opts = opts or {}
  local notify_opts = {
    title = opts.title,
    group = opts.group,
    key = opts.key,
    skip_history = true,
  }
  if opts.use_fidget ~= false then
    local ok, fidget = pcall(require, "fidget")
    if ok and type(fidget.notify) == "function" then
      fidget.notify(text, level or vim.log.levels.INFO, notify_opts)
      return
    end
  end
  vim.notify(text, level or vim.log.levels.INFO, notify_opts)
end

--- Create a progress handle: `{ report(text), finish(text, level) }`.
--- opts: { title, message, group, use_fidget }.
function M.handle(opts)
  opts = opts or {}
  local title = opts.title or "ai.nvim"
  local group = opts.group
  local use_fidget = opts.use_fidget ~= false
  local message = opts.message or "thinking…"

  if use_fidget then
    local ok, handle_mod = pcall(require, "fidget.progress.handle")
    if ok and type(handle_mod.create) == "function" then
      local created, handle = pcall(handle_mod.create, {
        title = title,
        message = message,
        lsp_client = { name = title },
      })
      if created and handle then
        return {
          report = function(text)
            pcall(function()
              handle:report({ message = text })
            end)
          end,
          finish = function(text, level)
            pcall(function()
              if text and text ~= "" then
                handle:report({ message = text })
              end
              handle:finish()
            end)
            if level == vim.log.levels.ERROR and text and text ~= "" then
              emit_notify(text, level, { title = title, group = group, use_fidget = use_fidget })
            end
          end,
        }
      end
    end
  end

  -- Fallback: one key-updated notification (no spinner animation).
  local uv = vim.uv or vim.loop
  local key = ("ai.nvim.progress.%d"):format(uv.hrtime())
  local notify_opts = { title = title, group = group, key = key, use_fidget = use_fidget }
  emit_notify(message, vim.log.levels.INFO, notify_opts)
  return {
    report = function(text)
      emit_notify(text, vim.log.levels.INFO, notify_opts)
    end,
    finish = function(text, level)
      if text and text ~= "" then
        emit_notify(text, level or vim.log.levels.INFO, notify_opts)
      end
    end,
  }
end

return M
