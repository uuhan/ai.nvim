local config = require("ai.config")

local M = {}

local function positive_number(value, fallback)
  value = tonumber(value)
  if value and value > 0 then
    return value
  end
  return fallback
end

local function positive_integer(value, fallback)
  return math.max(1, math.floor(positive_number(value, fallback)))
end

local function char_count(text)
  return vim.fn.strchars(text or "")
end

local function take_chars(text, count)
  if text == "" then
    return "", ""
  end

  if char_count(text) <= count then
    return text, ""
  end

  local head = vim.fn.strcharpart(text, 0, count)
  local tail = vim.fn.strcharpart(text, count)
  return head, tail
end

local function stream_options(opts)
  opts = opts or {}
  local cfg = config.get().streaming or {}
  return {
    interval_ms = positive_integer(opts.interval_ms, positive_integer(cfg.interval_ms, 30)),
    max_chars_per_flush = positive_integer(opts.max_chars_per_flush, positive_integer(cfg.max_chars_per_flush, 96)),
  }
end

function M.new(opts)
  opts = opts or {}
  local stream_opts = stream_options(opts)
  local pending = ""
  local visible = ""
  local scheduled = false
  local done_requested = false
  local closed = false

  local renderer = {}

  local function emit_update()
    if type(opts.on_update) == "function" then
      opts.on_update(visible)
    end
  end

  local function emit_done()
    if type(opts.on_done) == "function" then
      opts.on_done(visible)
    end
  end

  local function pump()
    scheduled = false
    if closed then
      return
    end

    if pending ~= "" then
      local chunk
      chunk, pending = take_chars(pending, stream_opts.max_chars_per_flush)
      visible = visible .. chunk
      emit_update()
      if closed then
        return
      end
    end

    if pending ~= "" then
      renderer.schedule()
      return
    end

    if done_requested then
      closed = true
      emit_done()
    end
  end

  function renderer.schedule()
    if closed or scheduled then
      return
    end
    scheduled = true
    vim.defer_fn(pump, stream_opts.interval_ms)
  end

  function renderer.push(delta)
    if closed or delta == nil or delta == "" then
      return
    end
    pending = pending .. delta
    renderer.schedule()
  end

  function renderer.finish()
    if closed then
      return
    end
    done_requested = true
    if pending == "" and not scheduled then
      closed = true
      emit_done()
      return
    end
    renderer.schedule()
  end

  function renderer.cancel()
    closed = true
    pending = ""
  end

  function renderer.text()
    return visible
  end

  function renderer.has_pending()
    return pending ~= ""
  end

  return renderer
end

return M
