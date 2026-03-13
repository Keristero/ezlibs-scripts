-- EventEmitter.lua
-- A flexible event system with async capabilities
local EventEmitter = {}
EventEmitter.__index = EventEmitter

-- Create a new EventEmitter instance
function EventEmitter.new()
    local self = setmetatable({}, EventEmitter)
    self._events = {} -- Regular event listeners
    self._once_events = {} -- One-time event listeners
    self._any_events = {} -- Listeners for any event
    self._any_once_events = {} -- One-time listeners for any event
    self._destroyed = false
    self._iterators = {}
    self._any_iterators = {}
    return self
end

-- Register a listener for a specific event
function EventEmitter:on(event, callback)
    if self._destroyed then return self end

    if not self._events[event] then self._events[event] = {} end
    table.insert(self._events[event], callback)
    return self
end

-- Register a one-time listener for a specific event
function EventEmitter:once(event, callback)
    if self._destroyed then return self end

    if not self._once_events[event] then self._once_events[event] = {} end
    table.insert(self._once_events[event], callback)
    return self
end

-- Register a listener for any event
function EventEmitter:on_any(callback)
    if self._destroyed then return self end

    table.insert(self._any_events, callback)
    return self
end

-- Register a one-time listener for any event
function EventEmitter:on_any_once(callback)
    if self._destroyed then return self end

    table.insert(self._any_once_events, callback)
    return self
end

-- Emit an event
function EventEmitter:emit(event, ...)
    if self._destroyed then return self end

    -- Call regular listeners
    if self._events[event] then
        for _, callback in ipairs(self._events[event]) do callback(...) end
    end

    -- Call once listeners and remove them
    if self._once_events[event] then
        for _, callback in ipairs(self._once_events[event]) do
            callback(...)
        end
        self._once_events[event] = nil
    end

    -- Call any-event listeners
    for _, callback in ipairs(self._any_events) do callback(event, ...) end

    -- Call any-event once listeners and remove them
    for _, callback in ipairs(self._any_once_events) do callback(event, ...) end
    self._any_once_events = {}

    -- Notify async iterators
    self:_notify_iterators(event, ...)

    return self
end

-- Remove a specific listener
function EventEmitter:remove_listener(event, callback)
    if self._destroyed or not self._events[event] then return self end

    for i, cb in ipairs(self._events[event]) do
        if cb == callback then
            table.remove(self._events[event], i)
            break
        end
    end

    if #self._events[event] == 0 then self._events[event] = nil end

    return self
end

-- Remove a specific on_any listener
function EventEmitter:remove_on_any_listener(callback)
    if self._destroyed then return self end

    for i, cb in ipairs(self._any_events) do
        if cb == callback then
            table.remove(self._any_events, i)
            break
        end
    end

    return self
end

-- Create an async iterator for a specific event
function EventEmitter:async_iter(event)
    if self._destroyed then return nil end

    local iterator = {event = event, queue = {}, waiting = nil, closed = false}

    local function on_event(...)
        if iterator.closed then return end

        table.insert(iterator.queue, {...})
        if iterator.waiting then
            iterator.waiting(table.unpack(table.remove(iterator.queue, 1)))
            iterator.waiting = nil
        end
    end

    self:on(event, on_event)
    iterator.listener = on_event

    if not self._iterators[event] then self._iterators[event] = {} end
    table.insert(self._iterators[event], iterator)

    return function()
        if iterator.closed then return nil end

        if #iterator.queue > 0 then
            return table.unpack(table.remove(iterator.queue, 1))
        else
            return function(resolve) iterator.waiting = resolve end
        end
    end
end

-- Create an async iterator for all events
function EventEmitter:async_iter_all()
    if self._destroyed then return nil end

    local iterator = {queue = {}, waiting = nil, closed = false}

    local function on_any(event, ...)
        if iterator.closed then return end

        table.insert(iterator.queue, {event, ...})
        if iterator.waiting then
            local data = table.remove(iterator.queue, 1)
            iterator.waiting(table.unpack(data))
            iterator.waiting = nil
        end
    end

    self:on_any(on_any)
    iterator.listener = on_any

    table.insert(self._any_iterators, iterator)

    return function()
        if iterator.closed then return nil end

        if #iterator.queue > 0 then
            local data = table.remove(iterator.queue, 1)
            return table.unpack(data)
        else
            return function(resolve) iterator.waiting = resolve end
        end
    end
end

-- Notify all iterators of an event
function EventEmitter:_notify_iterators(event, ...)
    -- Specific event iterators
    if self._iterators[event] then
        for _, iterator in ipairs(self._iterators[event]) do
            table.insert(iterator.queue, {...})
            if iterator.waiting then
                iterator.waiting(table.unpack(table.remove(iterator.queue, 1)))
                iterator.waiting = nil
            end
        end
    end

    -- Any-event iterators
    for _, iterator in ipairs(self._any_iterators) do
        table.insert(iterator.queue, {event, ...})
        if iterator.waiting then
            local data = table.remove(iterator.queue, 1)
            iterator.waiting(table.unpack(data))
            iterator.waiting = nil
        end
    end
end

-- Clean up all resources
function EventEmitter:destroy()
    if self._destroyed then return end

    self._destroyed = true
    self._events = {}
    self._once_events = {}
    self._any_events = {}
    self._any_once_events = {}

    -- Close all iterators
    for _, iterators in pairs(self._iterators) do
        for _, iterator in ipairs(iterators) do
            iterator.closed = true
            if iterator.waiting then
                iterator.waiting(nil)
                iterator.waiting = nil
            end
        end
    end

    for _, iterator in ipairs(self._any_iterators) do
        iterator.closed = true
        if iterator.waiting then
            iterator.waiting(nil)
            iterator.waiting = nil
        end
    end

    self._iterators = {}
    self._any_iterators = {}
end

return EventEmitter
