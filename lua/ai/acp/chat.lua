local M = {}

--- Send one prompt, starting the agent and its session as needed.
---
--- `callbacks.resume` is the id of a session the agent may still hold: a
--- restored transcript asks for its own conversation back so the agent keeps
--- the context the chat file only shows. `callbacks.on_session` reports the
--- session the prompt actually runs on, and whether the agent restored it.
function M.run(client, text, callbacks)
  callbacks = callbacks or {}

  local function announce(session_id, resumed)
    if callbacks.on_session then callbacks.on_session(session_id, resumed) end
  end

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
      announce(client.session_id, false)
      prompt()
    end)
  end

  --- An agent that no longer has the session is the ordinary case rather than
  --- a failure: it may store sessions in memory, or have pruned this one. The
  --- prompt then opens a fresh session instead of being lost.
  local function load_session()
    client.load_session(callbacks.resume, function(err)
      if err then
        new_session()
        return
      end
      announce(client.session_id, true)
      prompt()
    end)
  end

  local function resumable()
    return type(callbacks.resume) == "string"
      and callbacks.resume ~= ""
      and client.capabilities
      and client.capabilities.loadSession == true
  end

  local function ready()
    if client.session_id then
      prompt()
    elseif resumable() then
      load_session()
    else
      new_session()
    end
  end

  if client.ready then
    ready()
  else
    client.start(function(err)
      if err then
        if callbacks.on_error then callbacks.on_error(err) end
        return
      end
      ready()
    end)
  end

  return {
    kill = function()
      return client.cancel()
    end,
  }
end

return M
