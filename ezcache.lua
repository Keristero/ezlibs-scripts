--ezcache provides get_object_by_id_cached, which is the same is get_object_by_id
--  except if the object is a type that should be cached, we delete it from the map and only keep it in memory.
local ezcache = {}
ezcache.cache = {}
ezcache.types = {"NPC","Waypoint","Dialogue","Shop Item","Mystery Option"}

function ezcache.object_is_of_type(object, types)
    local should_be_cached = false
    for index, type_name in ipairs(types) do
        if object.type == type_name then
            should_be_cached = true
        end
    end
    return should_be_cached
end

function ezcache.get_object_by_id_cached(area_id, object_id)
    area_id = tostring(area_id)
    object_id = tostring(object_id)
    --same as Net.get_object_by_id except it uses objects from a cache and caches them if they are not already cached
    if not ezcache.cache[area_id] then
        ezcache.cache[area_id] = {}
    end
    if ezcache.cache[area_id][object_id] ~= nil then
        return ezcache.cache[area_id][object_id]
    else
        local object_data = Net.get_object_by_id(area_id, object_id)
        if object_data then
            local should_be_cached = ezcache.object_is_of_type(object_data, ezcache.types)
            if should_be_cached then
                ezcache.cache[area_id][object_id] = object_data
                Net.remove_object(area_id, object_id)
            end
            return object_data
        else
            warn('[helpers] unable to find object ' .. area_id .. "," .. object_id)
            return nil
        end
    end
end

return ezcache