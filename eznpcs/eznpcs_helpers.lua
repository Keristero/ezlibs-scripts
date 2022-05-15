function is_now_before_date(date_string)
    local timestamp_a = os.time()
    local timestamp_b = date_string_to_timestamp(date_string)
    if timestamp_a < timestamp_b then
        return true
    end
    return false
end

function date_string_to_timestamp(date_string)
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

function position_overlaps_something(position,area_id)
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

function extract_numbered_properties(object,property_prefix)
    local out_table = {}
    for i=1,10 do
        local text = object.custom_properties[property_prefix..i]
        if text then
            out_table[i] = text
        end
    end
    return out_table
end