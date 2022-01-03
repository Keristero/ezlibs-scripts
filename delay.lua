local delay = {}

local events = {}
local player_events = {}
local latest_event_id = 0

function OnTick(delta_time)
    for event_id, event in pairs(events) do
        if event.secs_delay > 0 then
            event.secs_delay = event.secs_delay - delta_time
        end
        if event.secs_delay <= 0 then
            event.callback()
            events[event_id] = nil
        end
    end
    for player_id, events in pairs(player_events) do
        for event_id, event in pairs(events) do
            if event.secs_delay > 0 then
                event.secs_delay = event.secs_delay - delta_time
            end
            if event.secs_delay <= 0 then
                event.callback()
                events[event_id] = nil
            end
        end
    end
end

function Seconds(callback,secs_delay)
    latest_event_id = latest_event_id + 1
    events[latest_event_id] = {
        callback=callback,
        secs_delay=secs_delay
    }
    return latest_event_id
end

function ForPlayer(player_id,callback,secs_delay)
    latest_event_id = latest_event_id + 1
    if not player_events[player_id] then
        player_events[player_id] = {}
    end
    player_events[player_id][latest_event_id] = {
        callback=callback,
        secs_delay=secs_delay
    }
    return latest_event_id
end

function ClearPlayerEvents(player_id)
    player_events[player_id] = nil
end

--Interface
--all of these must be used by entry script for this to function.
function delay.on_tick(delta_time)
    return ( OnTick(delta_time) )
end

--methods
function delay.seconds(callback,delay_ms)
    return ( Seconds(callback,delay_ms) )
end

function delay.for_player(player_id,callback,delay_ms)
    return ( ForPlayer(player_id,callback,delay_ms) )
end

function delay.clear_player_events(player_id)
    return ( ClearPlayerEvents(player_id) )
end

return delay