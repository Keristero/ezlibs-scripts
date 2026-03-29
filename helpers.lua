local helpers = {}
local urlencode = require('scripts/ezlibs-scripts/urlencode')
local ezcache = require('scripts/ezlibs-scripts/ezcache')
local locks = {}
local locks_by_player = {}

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

function helpers.indexOf(array, value)
    for i, v in ipairs(array) do
        if v == value then
            return i
        end
    end
    return nil
end

function helpers.extract_numbered_properties(object,property_prefix)
    local out_table = {}
    for i=1,20 do
        local text = object.custom_properties[property_prefix..i]
        if text then
            out_table[i] = text
        end
    end
    return out_table
end

function helpers.clear_table(tbl)
    local count = #tbl
    for i = 0, count do
        tbl[i] = nil
    end
end

function helpers.create_bbs_option(text,id)
    if id == nil then
        id = text
    end
    return {id= text, read= true, title=text, author= ""}
end

function helpers.deep_copy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[helpers.deep_copy(orig_key)] = helpers.deep_copy(orig_value)
        end
        setmetatable(copy, helpers.deep_copy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
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

function helpers.safe_require(script_path)
    local status, err = pcall(function() require(script_path) end)
    if status == true then
        return require(script_path)
    else
        if string.find(err, "module '" .. script_path .. "' not found") then
            warn("(safe_require) no script found at " .. script_path)
        else
            warn("(safe_require) error loading script " .. script_path)
            warn("(safe_require) reason " .. err)
        end
    end
end

function helpers.date_string_to_timestamp(date_string)
    local current_date = os.date("*t")
    local date_parts = helpers.split(date_string," ")
    if #date_parts < 6 then
        return nil
    end
    local date_part_keys = {"sec","min","hour","day","month","year"}
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
    local player_ids = Net.list_players(area_id)

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

function helpers.get_lock(player_id,lock_id,timeout)
    if locks[lock_id] == nil then
        if not locks_by_player[player_id] then
            locks_by_player[player_id] = {}
        end
        local lock = {
            release=function()
                if locks_by_player[player_id] then
                    locks_by_player[player_id][lock_id] = nil
                end
                locks[lock_id] = nil
            end
        }
        locks_by_player[player_id][lock_id] = lock
        locks[lock_id] = lock
        if timeout then
            Async.sleep(timeout).and_then(function ()
                lock.release()
            end)
        end
        return lock
    end
    return false
end

function helpers.read_item_information(area_id, item_object_id)
    local item_info_object = ezcache.get_object_by_id_cached(area_id,item_object_id)
    local item_props = item_info_object.custom_properties
    local item = {}
    item.name = item_props["Name"]
    item.amount = tonumber(item_props["Amount"] or 1)
    item.description = item_props["Description"] or "???"
    item.type = item_props["Type"] or "item"
    item.price = tonumber(item_props["Price"] or 999999)
    if (item.type == "keyitem" or item.type == "item" ) and not item.name then
        warn("[helpers] item "..item_object_id.." needs a 'Name'")
        return false
    end
    if item.type == "keyitem" and item.description == "???" then
        warn("[helpers] key item "..item_object_id.."("..item.name..") should have a 'Description'")
        return false
    end
    return item
end

-- ============================================================================
-- Cross‑platform directory creation
-- ============================================================================
function helpers.ensure_directory(path)
    -- Remove trailing slashes for mkdir command
    local dir = path:gsub("[/\\]+$", "")
    if dir == "" then return end

    -- Try LuaFileSystem first
    local has_lfs, lfs = pcall(require, "lfs")
    if has_lfs then
        local attr = lfs.attributes(dir)
        if not attr then
            local ok, err = pcall(lfs.mkdir, dir)
            if ok then
                print("[helpers] Created directory:", dir)
            else
                print("[helpers] Warning: Could not create directory", dir, "error:", err)
            end
        elseif attr.mode ~= "directory" then
            print("[helpers] Warning:", dir, "exists but is not a directory.")
        end
        return
    end

    -- Fallback: use os.execute with platform detection
    local command
    if package.config:sub(1,1) == '\\' then -- Windows
        command = 'if not exist "' .. dir .. '" mkdir "' .. dir .. '"'
    else -- Unix-like
        command = 'mkdir -p "' .. dir .. '"'
    end
    local success = pcall(os.execute, command)
    if success then
        print("[helpers] Created directory via os.execute:", dir)
    else
        print("[helpers] Warning: Could not create directory", dir, "via os.execute. Please create it manually.")
    end
end

Net:on("player_disconnect", function(event)
    if locks_by_player[event.player_id] then
        for lock_id, lock in pairs(locks_by_player[event.player_id]) do
            lock.release()
        end
    end
end)

return helpers