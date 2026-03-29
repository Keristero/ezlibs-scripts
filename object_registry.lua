local ezcache = require('scripts/ezlibs-scripts/ezcache')

local object_registry = {
    handlers = {},          -- type -> list of callbacks
    types_to_cache = {},    -- set of types that have handlers AND should be cached
}

-- Register a handler for an object type.
-- @param object_type: string, the type of object (e.g., "Custom Warp")
-- @param callback: function(area_id, object) to be called for each object
-- @param cache: boolean, whether to cache the object (remove from Net). Default true.
function object_registry.register_handler(object_type, callback, cache)
    if cache == nil then cache = true end

    if not object_registry.handlers[object_type] then
        object_registry.handlers[object_type] = {}
    end
    table.insert(object_registry.handlers[object_type], callback)

    if cache then
        -- Only add to cacheable set if caching is desired
        if not object_registry.types_to_cache[object_type] then
            object_registry.types_to_cache[object_type] = true
            ezcache.add_cacheable_type(object_type)
        end
    end
end

function object_registry.load_all()
    print("[object_registry] Starting preload...")
    local start_time = os.clock()

    local areas = Net.list_areas()
    for _, area_id in ipairs(areas) do
        local objects = Net.list_objects(area_id)
        for _, object_id in ipairs(objects) do
            local object = Net.get_object_by_id(area_id, object_id)
            if object and object.type and object_registry.handlers[object.type] then
                -- Run handlers first (they may need the object)
                local handlers = object_registry.handlers[object.type]
                for _, callback in ipairs(handlers) do
                    callback(area_id, object)
                end

                -- Cache only if this type is marked as cacheable
                if object_registry.types_to_cache[object.type] then
                    ezcache.cache_object(area_id, object)
                end
            end
        end
    end

    local elapsed = os.clock() - start_time
    print("[object_registry] Preload completed in " .. elapsed .. "s")
end

return object_registry