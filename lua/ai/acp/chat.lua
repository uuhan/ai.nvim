local M = {}

function M.run(client, text, callbacks)
  callbacks = callbacks or {}

  local function prompt()
    client.prompt(text, function(err, result)
      if err then
        if callbacks.on_error then callbacks.on_error(err) end
        return
      end
      if callbacks.on_done then callbacks.on_done(result) end
    end)
  end

  local function new_session()
    client.new_session({}, function(err)
      if err then
        if callbacks.on_error then callbacks.on_error(err) end
        return
      end
      prompt()
    end)
  end

  local function ready()
    if client.session_id then prompt() else new_session() end
  end

  if client.ready then
    ready()
  else
    client.start(function(err)
      if err then
        if callbacks.on_error then callbacks.on_error(err) end
        return
      end
      new_session()
    end)
  end

  return {
    kill = function()
      return client.cancel()
    end,
  }
end

return M
