local listeners = {}

local ezevents = {}

function ezevents.add_listener(eventName,handler)
    if not listeners[eventName] then
        listeners[eventName] = {}
    end
    table.insert(listeners[eventName],handler)
end

function ezevents.broadcast_event(eventName,eventData)
    print('[ezlisteners] broadcast event ',eventName)
    if listeners[eventName] then
        --print(eventName,eventData)
        for i, handler in pairs(listeners[eventName]) do
            handler(eventData)
        end  
    end
end

return ezevents