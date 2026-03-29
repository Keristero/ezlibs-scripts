local ezcache = {}
ezcache.cache = {}
ezcache.cacheable_types = {}   -- dynamic set of types to cache

-- Add a type to the cacheable set
function ezcache.add_cacheable_type(type_name)
    ezcache.cacheable_types[type_name] = true
end

-- Check if an object type should be cached
function ezcache.object_is_of_type(object)
    return ezcache.cacheable_types[object.type] == true
end

-- Store a pre‑fetched object in the cache and remove it from Net
function ezcache.cache_object(area_id, object)
    if not object then return nil end
    area_id = tostring(area_id)
    local object_id = tostring(object.id)
    if not ezcache.cache[area_id] then
        ezcache.cache[area_id] = {}
    end
    -- If already cached, return the cached copy
    if ezcache.cache[area_id][object_id] then
        return ezcache.cache[area_id][object_id]
    end
    -- Store and remove from Net
    ezcache.cache[area_id][object_id] = object
    Net.remove_object(area_id, object_id)
    return object
end

-- Get an object by ID, using cache and fetching if necessary
function ezcache.get_object_by_id_cached(area_id, object_id)
    area_id = tostring(area_id)
    object_id = tostring(object_id)

    if not ezcache.cache[area_id] then
        ezcache.cache[area_id] = {}
    end

    if ezcache.cache[area_id][object_id] then
        return ezcache.cache[area_id][object_id]
    else
        local object = Net.get_object_by_id(area_id, object_id)
        if object and ezcache.object_is_of_type(object) then
            return ezcache.cache_object(area_id, object)
        end
        return object   -- uncached type, return as‑is
    end
end

return ezcache