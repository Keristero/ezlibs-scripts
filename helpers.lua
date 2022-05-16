local helpers = {}
local urlencode = require('scripts/ezlibs-scripts/urlencode')

--Shorthand globals
function async(p)
    local co = coroutine.create(p)
    return Async.promisify(co)
end

function await(v) return Async.await(v) end

function first_value_from_table(tbl)
    for i, value in pairs(tbl) do
        return value
    end
    return nil
end

function get_table_length(tbl)
    local getN = 0
    for n in pairs(tbl) do 
      getN = getN + 1 
    end
    return getN
end

function helpers.extract_numbered_properties(object,property_prefix)
    local out_table = {}
    for i=1,10 do
        local text = object.custom_properties[property_prefix..i]
        if text then
            out_table[i] = text
        end
    end
    return out_table
end

--helpers lib
function helpers.clear_table(tbl)
    local count = #tbl
    for i = 0, count do
        tbl[i] = nil
    end
end

function helpers.split(string, delimiter)
    local table = {}
    for tag, line in string:gmatch('([^' .. delimiter .. ']+)') do
        table[#table + 1] = tag
    end
    return table
end

function helpers.get_safe_player_secret(player_id)
    local player_secret = Net.get_player_secret(player_id)
    local secert_substr = player_secret:sub(2, 32)
    return urlencode.string(secert_substr)
end

function helpers.object_is_of_type(object, types)
    local should_be_cached = false
    for index, type_name in ipairs(types) do
        if object.type == type_name then
            should_be_cached = true
        end
    end
    return should_be_cached
end

function helpers.get_object_by_id_cached(area_id, object_id, object_cache, cache_types)
    area_id = tostring(area_id)
    object_id = tostring(object_id)
    --same as Net.get_object_by_id except it uses objects from a cache and caches them if they are not already cached
    if not object_cache[area_id] then
        object_cache[area_id] = {}
    end
    if object_cache[area_id][object_id] ~= nil then
        return object_cache[area_id][object_id]
    else
        local object_data = Net.get_object_by_id(area_id, object_id)
        if object_data then
            local should_be_cached = helpers.object_is_of_type(object_data, cache_types)
            if should_be_cached then
                object_cache[area_id][object_id] = object_data
                Net.remove_object(area_id, object_id)
            end
            return object_data
        else
            print('[helpers] unable to find object ' .. area_id .. "," .. object_id)
            return nil
        end
    end
end

function helpers.safe_require(script_path)
    local status, err = pcall(function() require(script_path) end)
    if status == true then
        return require(script_path)
    else
        if string.find(err, "module '" .. script_path .. "' not found") then
            print("(safe_require) no script found at " .. script_path)
        else
            print("(safe_require) error loading script " .. script_path)
            print("(safe_require) reason " .. err)
        end
    end
end

function helpers.date_string_to_timestamp(date_string)
    --expect basic cron like date format, only supporting * or specific values
    --0 0 10 15 * * this would be on the 15th of every month at 10AM
    --seconds, minute, hour, day, month, year
    local current_date = os.date("*t")
    local date_parts = helpers.split(date_string," ")
    if #date_parts < 6 then
        return nil
    end
    local date_part_keys = {"sec","min","hour","day","month","year"}
    --everywhere that is not a * in the date string, replace time value with specified time
    for index, value in ipairs(date_parts) do
        if value ~= "*" then
            local date_part_key = date_part_keys[index]
            current_date[date_part_key] = tonumber(value)
        end
    end
    return os.time{year=current_date.year, month=current_date.month, day=current_date.day, hour=current_date.hour, min=current_date.min, sec=current_date.sec}
end

function helpers.is_now_before_date(date_string)
    local timestamp_a = os.time()
    local timestamp_b = helpers.date_string_to_timestamp(date_string)
    if timestamp_a < timestamp_b then
        return true
    end
    return false
end

function helpers.position_overlaps_something(position,area_id)
    --Returns true if a position (with a size) overlaps something important
    local player_ids = Net.list_players(area_id)

    --Check for overlap against players
    for i = 1, #player_ids, 1 do
        local player_pos = Net.get_player_position(player_ids[i])
        if
            math.abs(player_pos.x - position.x) < position.size and
            math.abs(player_pos.y - position.y) < position.size and
            player_pos.z == position.z
        then
            return true
        end
    end

    return false
end

return helpers
