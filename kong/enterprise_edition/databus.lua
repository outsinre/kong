local inspect = require "inspect"

local request = require "kong.enterprise_edition.utils".request

local kong = kong

-- XXX TODO:
-- payload webhook, can it be just a JSON blob?
-- make slack nicer
-- refactor http request into something useful
-- use proper templating instead of regexing
-- (does not support compount foo.bar fields)

local kong = kong

local _M = {}

local events = {}

-- Not sure if this is good enough. Holds references to callbacks by id so
-- we can properly unregister worker events
local references = {}

_M.enabled = function()
  return kong.configuration.databus_enabled
end

_M.publish = function(source, event, help)
  if not _M.enabled() then return end
  if not events[source] then events[source] = {} end
  events[source][#events[source] + 1] = { event, help }
end

_M.register = function(entity)
  if not _M.enabled() then return end
  local callback = _M.callback(entity)
  local source = entity.source
  local event = entity.event
  -- register null event
  if event == ngx.null then
    event = nil
  end

  references[entity.id] = callback

  return kong.worker_events.register(callback, "dbus:" .. source, event)
end

_M.unregister = function(entity)
  if not _M.enabled() then return end
  local callback = references[entity.id]
  local source = entity.source
  local event = entity.event

  -- XXX This good? maybe check if the unregister was succesful
  references[entity.id] = nil

  return kong.worker_events.unregister(callback, "dbus:" .. source, event)
end


_M.emit = function(source, event, data)
  if not _M.enabled() then return end
  return kong.worker_events.post_local("dbus:" .. source, event, data)
end

_M.list = function()
  return events
end

-- XXX: hack to get asynchronous execution of callbacks. Check with thijs
-- about this
local BatchQueue = require "kong.tools.batch_queue"
local queue

local process_callback = function(batch)
  local entry = batch[1]
  return entry.callback(entry.data, entry.event, entry.source, entry.pid)
end

_M.callback = function(entity)
  if not queue then
    local opts = {
      batch_max_size = 1,
    }
    queue = BatchQueue.new(process_callback, opts)
  end
  local callback = _M.handlers[entity.handler](entity, entity.config)
  local wrap = function(data, event, source, pid)
    local blob = {
      callback = callback,
      data = data,
      event = event,
      source = source,
      pid = pid,
    }
    return queue:add(blob)
  end
  return wrap
end


_M.handlers = {
  webhook = function(entity, config)
    return function(data, event, source, pid)
      data.event = event
      data.source = source

      local payload = {}
      if config.payload_format then
        for k, v in pairs(config.payload) do
          payload[k] = format(v, data)
        end
      else
        payload = config.payload
      end

      local headers = {}
      if config.headers_format then
        for k, v in pairs(config.headers) do
          headers[k] = format(v, data)
        end
      else
        headers = config.headers
      end

      kong.log.debug("webhook event data: ", inspect({data, event, source, pid}))
      local res, err = request(config.url, config.method, payload, headers)
      kong.log.debug("response: ", inspect({res and res.status or nil, err}))
      return not err
    end
  end,

  -- This would be a specialized helper easier to configure than a webhook
  -- even though slack would use a webhook
  slack = function(entity, config)
    return function(data, event, source, pid)
      kong.log.debug("slack event data: ", inspect({data, event, source, pid}))
      kong.log.debug("slack callback not implemented")
      return true
    end
  end,

  log = function(entity, config)
    return function(data, event, source, pid)
      kong.log.notice("log callback ", inspect({event, source, data, pid}))
      return true
    end
  end,

  lambda = function(entity, config)
    local functions = {}

    -- limit execution context
    --local helper_ctx = {
    --  require = require,
    --  type = type,
    --  print = print,
    --  pairs = pairs,
    --  ipairs = ipairs,
    --  inspect = inspect,
    --  request = request,
    --  kong = kong,
    --  ngx = ngx,
    --  -- ... anything else useful ?
    --}
    -- or allow _anything_
    local helper_ctx = _G

    local chunk_name = "dbus:" .. entity.id

    for i, fn_str in ipairs(config.functions) do
      -- each function has its own context. We could let them share context
      -- by not defining fn_ctx and just passing helper_ctx
      local fn_ctx = {}
      setmetatable(fn_ctx, { __index = helper_ctx })
      -- t -> only text chunks
      local fn = load(fn_str, chunk_name .. ":" .. i, "t", fn_ctx)     -- load
      local _, actual_fn = pcall(fn)
      table.insert(functions, actual_fn)
    end

    return function(data, event, source, pid)
      -- reduce on functions with data
      local err
      for _, fn in ipairs(functions) do
        data, err = fn(data, event, source, pid)
      end
      return not err
    end
  end,
}

return _M
