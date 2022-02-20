local helpers = {}
local urlencode = require('scripts/ezlibs-scripts/urlencode')

function helpers.split(string,delimiter)
    local table = {}
    for tag, line in string:gmatch('([^'..delimiter..']+)') do
        table[#table+1] = tag
    end
    return table
end

function helpers.get_safe_player_secret(player_id)
    local player_secret = Net.get_player_secret(player_id)
    local secert_substr = player_secret:sub(2,32)
    return urlencode.string(secert_substr)
end

function helpers.object_is_of_type(object,types)
    local should_be_cached = false
    for index, type_name in ipairs(types) do
        if object.type == type_name then
            should_be_cached = true
        end
    end
    return should_be_cached
end

function helpers.get_object_by_id_cached(area_id,object_id,object_cache,cache_types)
    area_id = tostring(area_id)
    object_id = tostring(object_id)
    --same as Net.get_object_by_id except it uses objects from a cache and caches them if they are not already cached
    if not object_cache[area_id] then
        object_cache[area_id] = {}
    end
    if object_cache[area_id][object_id] ~= nil then
        return object_cache[area_id][object_id]
    else
        local object_data = Net.get_object_by_id(area_id,object_id)
        if object_data then
            local should_be_cached = helpers.object_is_of_type(object_data,cache_types)
            if should_be_cached then
                object_cache[area_id][object_id] = object_data
                Net.remove_object(area_id, object_id)
            end
            return object_data
        else
            print('[helpers] unable to find object '..area_id..","..object_id)
            return nil
        end
    end
end

function helpers.safe_require(script_path)
    local status, err = pcall(function () require(script_path) end)
    if status == true then
        return require(script_path)
    else
        if string.find(err,"module '"..script_path.."' not found") then
            print("(safe_require) no script found at "..script_path)
        else
            print("(safe_require) error loading script "..script_path)
            print("(safe_require) reason "..err)
        end
    end
end

return helpers