local json = require('scripts/ezlibs-scripts/json')
local helpers = require('scripts/ezlibs-scripts/helpers')
local table = require('table')
local ezbus = require('scripts/ezlibs-scripts/ezbus')
local ezconfig = require('scripts/ezlibs-scripts/ezconfig') -- load config
local avatar_utils = require('scripts/ezlibs-scripts/avatar_utils/main')

local ezmemory = {}
local player_memory = {}
local area_memory = {}
local player_list = {}
local player_avatar_details = {}
local items = {}
local item_name_table = {}
local objects_hidden_till_disconnect_for_player = {}
local highest_item_id = 1

local players_path = ezconfig.PLAYERS_PATH
local items_path = ezconfig.ITEMS_PATH
local area_path_prefix = ezconfig.AREA_PATH_FOLDER
local player_path_prefix = ezconfig.PLAYER_PATH_FOLDER

local idle_map = {
    ["Down Right"] = "IDLE_DR",
    ["Down Left"] = "IDLE_DL",
    ["Up Right"] = "IDLE_UR",
    ["Up Left"] = "IDLE_UL",
    ["Up"] = "IDLE_U",
    ["Down"] = "IDLE_D",
    ["Left"] = "IDLE_L",
    ["Right"] = "IDLE_R",
}

local memory_loaded_flags = {
    area_memory = false,
    player_memory = false,
    items = false
}

local sfx = {
    item_get = '/server/assets/ezlibs-assets/sfx/item_get.ogg',
}

-- ============================================================================
-- Ensure directories and files exist at startup
-- ============================================================================

-- Ensure base memory directory
helpers.ensure_directory('./memory/')

-- Ensure parent directories for players.json and items.json
local players_dir = players_path:match("^(.*[/\\])")
if players_dir then helpers.ensure_directory(players_dir) end
local items_dir = items_path:match("^(.*[/\\])")
if items_dir then helpers.ensure_directory(items_dir) end

-- Helper to create a file with default content if it doesn't exist
local function ensure_file(path, default_content)
    local f = io.open(path, "rb")
    if not f then
        f = io.open(path, "w")
        if f then
            f:write(default_content)
            f:close()
            print("[ezmemory] Created default file:", path)
        else
            print("[ezmemory] Warning: Could not create file", path)
        end
    else
        f:close()
    end
end

-- Ensure players.json and items.json exist with default empty tables
ensure_file(players_path, "{}")
ensure_file(items_path, "{}")

-- Ensure area and player directories
helpers.ensure_directory(area_path_prefix)
helpers.ensure_directory(player_path_prefix)

-- ============================================================================
-- File I/O helpers (fixed path handling)
-- ============================================================================

-- Given a base path, returns the main file path and backup file path.
-- If base already ends with ".json", backup is base with "_backup" inserted before .json.
-- Otherwise, main is base .. ".json", backup is base .. "_backup.json".
local function get_file_paths(base)
    if base:match("%.json$") then
        -- e.g., "./memory/players.json" -> main: same, backup: "./memory/players_backup.json"
        local main = base
        local backup = base:gsub("%.json$", "_backup.json")
        return main, backup
    else
        -- e.g., "./memory/player/abc123" -> main: "./memory/player/abc123.json", backup: "./memory/player/abc123_backup.json"
        local main = base .. ".json"
        local backup = base .. "_backup.json"
        return main, backup
    end
end

local function ezmemory_load_file(file_path)
    return async(function()
        local main_file, backup_file = get_file_paths(file_path)
        local data = nil
        pcall(function()
            data = json.decode(await(Async.read_file(main_file)))
        end)
        if data == nil then
            pcall(function()
                data = json.decode(await(Async.read_file(backup_file)))
            end)
            if data == nil then
                return {}
            end
        end
        return data
    end)
end

local function ezmemory_save_file(file_path, value)
    return async(function()
        local main_file, backup_file = get_file_paths(file_path)
        local json_str = json.encode(value, true)
        await(Async.write_file(backup_file, json_str))
        await(Async.write_file(main_file, json_str))
    end)
end

-- ============================================================================
-- Rest of the module unchanged
-- ============================================================================

Net:on("handle_player_join", function(event)
    for name, path in pairs(sfx) do
        Net.provide_asset_for_player(event.player_id, path)
    end
end)

Net:on("player_request", function(event)
    if not ezmemory.is_loaded() then
        Net.kick_player(event.player_id, "joined too soon, ezmemory still loading", false)
        return
    end
end)

local function printd(...)
    local arg = { ... }
    print('[ezmemory]', table.unpack(arg))
end

local function normalize_player_memory(mem)
    if not mem then return end
    mem.items = mem.items or {}
    mem.money = mem.money or 0
    mem.fragments = mem.fragments or 0
    mem.tokens = mem.tokens or 0
    mem.meta = mem.meta or { joins = 0 }
    mem.area_memory = mem.area_memory or {}
    mem.emails = mem.emails or {}
    mem.emails.by_id = mem.emails.by_id or {}
    return mem
end

local function initialize_area_memory_file(area_id)
    local loaded = nil
    local io_ok = (io ~= nil and io.open ~= nil)
    area_memory[area_id] = { hidden_objects = {} }
    pcall(function()
        if not io_ok then return end
        local function _read(path)
            local f = io.open(path, "rb")
            if not f then return nil end
            local s = f:read("*a")
            f:close()
            return s
        end

        local base = area_path_prefix .. area_id
        local raw = _read(base .. ".json")
        if raw then
            local ok, data = pcall(function() return json.decode(raw) end)
            if ok and type(data) == "table" and data.hidden_objects ~= nil then
                loaded = data
                return
            end
        end

        raw = _read(base .. "_backup.json")
        if raw then
            local ok, data = pcall(function() return json.decode(raw) end)
            if ok and type(data) == "table" and data.hidden_objects ~= nil then
                loaded = data
                return
            end
        end
    end)

    if loaded then
        area_memory[area_id] = loaded
        return area_memory[area_id]
    end


    if io_ok then
        ezmemory.save_area_memory(area_id)
    end
    return area_memory[area_id]
end

local function load_all_memory()
    return async(function()
        items = await(ezmemory_load_file(items_path))
        for item_id, item_data in pairs(items) do
            if item_data.key_item then
                Net.create_item(item_id, item_data)
            end
            item_name_table[item_data.name] = item_id
            local number_item_id = tonumber(item_id)
            if number_item_id > highest_item_id then
                highest_item_id = number_item_id
            end
            printd('loaded item ' .. item_id .. ' = ' .. item_data.name)
        end
        memory_loaded_flags.items = true

        player_list = await(ezmemory_load_file(players_path))
        for safe_secret, name in pairs(player_list) do
            local mem = await(ezmemory_load_file(player_path_prefix .. safe_secret))
            normalize_player_memory(mem)
            player_memory[safe_secret] = mem
            printd('loaded memory for ' .. name)
        end
        memory_loaded_flags.player_memory = true

        local net_areas = Net.list_areas()
        for i, area_id in ipairs(net_areas) do
            local mem = await(ezmemory_load_file(area_path_prefix .. area_id))
            if mem.hidden_objects then
                area_memory[area_id] = mem
            else
                initialize_area_memory_file(area_id)
            end
            printd('loaded area memory for ' .. area_id)
        end
        memory_loaded_flags.area_memory = true
    end)
end

load_all_memory()

local function update_player_health(player_id)
    local area_id = Net.get_player_area(player_id)
    local forced_base_hp = tonumber(Net.get_area_custom_property(area_id, "Forced Base HP"))
    local honor_hp_memory_rules = Net.get_area_custom_property(area_id, "Honor HPMem") == "true"
    local honor_saved_hp = Net.get_area_custom_property(area_id, "Honor Saved HP") == "true"
    local full_heal = Net.get_area_custom_property(area_id, "Full Heal") == "true"

    local max_hp = Net.get_player_max_health(player_id)
    local hp = Net.get_player_health(player_id)

    if not forced_base_hp and player_avatar_details[player_id].max_health then
        max_hp = player_avatar_details[player_id].max_health
    end

    if honor_saved_hp then
        max_hp = ezmemory.get_player_max_health(player_id)
        hp = ezmemory.get_player_health(player_id)
    end

    if forced_base_hp and forced_base_hp > 0 then
        max_hp = forced_base_hp
    end

    if honor_hp_memory_rules then
        max_hp = ezmemory.calculate_player_modified_max_hp(player_id, max_hp, 20, "HPMem")
    end

    if full_heal then
        hp = max_hp
    end

    Net.set_player_max_health(player_id, max_hp, false)
    hp = math.min(hp, max_hp)
    Net.set_player_health(player_id, hp)
end

function ezmemory.wait_until_loaded()
    return async(function()
        while not ezmemory.is_loaded() do
            await(Async.sleep(0.2))
        end
    end)
end

function ezmemory.is_loaded()
    for flag_name, flag_value in pairs(memory_loaded_flags) do
        if flag_value == false then
            return false
        end
    end
    return true
end

function ezmemory.get_item_info(item_id)
    if items[item_id] then
        return items[item_id]
    end
    return nil
end

function ezmemory.create_or_update_item(item_name, item_description, is_key)
    if not item_name or not item_description then
        warn('[ezmemory] item not created, missing name or description')
        return
    end
    local existing_item_id = ezmemory.get_item_id_by_name(item_name)
    local new_item_id
    if existing_item_id ~= nil then
        new_item_id = existing_item_id
        printd('item with name ' .. item_name .. ' already exists, overwriting')
    else
        new_item_id = tostring(highest_item_id + 1)
        highest_item_id = tonumber(new_item_id)
    end

    local new_item = { name = item_name, description = item_description, key_item = is_key }
    items[new_item_id] = new_item
    item_name_table[item_name] = new_item_id
    ezmemory.save_items()
    if is_key then
        Net.create_item(new_item_id, new_item)
    end
    return new_item_id
end

function ezmemory.get_item_id_by_name(item_name)
    if not memory_loaded_flags.items then
        error("ezmemory is still loading items, please wait a bit")
    end
    if item_name_table[item_name] then
        return item_name_table[item_name]
    end
    printd('item ' .. item_name .. ' does not exist')
    return nil
end

function ezmemory.get_or_create_item(item_name, item_description, is_key)
    local existing_item_id = ezmemory.get_item_id_by_name(item_name)
    if existing_item_id ~= nil then
        return existing_item_id
    end
    return ezmemory.create_or_update_item(item_name, item_description, is_key)
end

function ezmemory.save_items()
    ezmemory_save_file(items_path, items)
end

function ezmemory.save_area_memory(area_id)
    ezmemory_save_file(area_path_prefix .. area_id, area_memory[area_id])
end

function ezmemory.save_player_memory(safe_secret)
    ezmemory_save_file(player_path_prefix .. safe_secret, player_memory[safe_secret])
end

function ezmemory.dangerously_override_player_memory(safe_secret, new_memory)
    if player_memory[safe_secret] then
        ezmemory_save_file(player_path_prefix .. safe_secret, new_memory)
    end
end

function ezmemory.get_area_memory(area_id)
    if area_memory[area_id] then
        return area_memory[area_id]
    end

    local loaded = nil
    pcall(function()
        local function _read(path)
            local f = io.open(path, "rb")
            if not f then return nil end
            local s = f:read("*a")
            f:close()
            return s
        end

        local base = area_path_prefix .. area_id
        local raw = _read(base .. ".json")
        if raw then
            local ok, data = pcall(function() return json.decode(raw) end)
            if ok and type(data) == "table" and data.hidden_objects ~= nil then
                loaded = data
                return
            end
        end

        raw = _read(base .. "_backup.json")
        if raw then
            local ok, data = pcall(function() return json.decode(raw) end)
            if ok and type(data) == "table" and data.hidden_objects ~= nil then
                loaded = data
                return
            end
        end
    end)

    if loaded then
        area_memory[area_id] = loaded
        return area_memory[area_id]
    end

    initialize_area_memory_file(area_id)
    return area_memory[area_id]
end

function ezmemory.get_player_memory(safe_secret)
    if not memory_loaded_flags.player_memory then
        error("ezmemory is still loading player_memory, please wait a bit")
    end
    if player_memory[safe_secret] then
        return player_memory[safe_secret]
    else
        player_memory[safe_secret] = {
            items = {},
            money = 0,
            fragments = 0,
            tokens = 0,
            meta = { joins = 0 },
            area_memory = {},
        }
        ezmemory.save_player_memory(safe_secret)
        return player_memory[safe_secret]
    end
end

function ezmemory.get_player_area_memory(safe_secret, area_id)
    if not memory_loaded_flags.player_memory then
        error("ezmemory is still loading player_memory, please wait a bit")
    end
    local player_memory = ezmemory.get_player_memory(safe_secret)
    if player_memory.area_memory[area_id] then
        return player_memory.area_memory[area_id]
    else
        player_memory.area_memory[area_id] = { hidden_objects = {} }
        ezmemory.save_player_memory(safe_secret)
        return player_memory.area_memory[area_id]
    end
end

function ezmemory.update_player_list(safe_secret, name)
    player_list[safe_secret] = name
    ezmemory_save_file(players_path, player_list)
end

function ezmemory.get_player_name_from_safesecret(safe_secret)
    local name = "Unknown"
    if player_list[safe_secret] then
        name = player_list[safe_secret]
    end
    print("NAME=", name)
    return name
end

function ezmemory.give_player_item(player_id, name, amount)
    if not amount then
        amount = 1
    end
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    local item_id = ezmemory.get_item_id_by_name(name)
    if item_id == nil then
        printd('cant give player ' .. name .. ' because it has not been created')
        return 0
    end
    local item_info = ezmemory.get_item_info(item_id)
    if item_info.key_item then
        for i = 1, amount do
            Net.give_player_item(player_id, item_id)
        end
    end
    if player_memory.items[item_id] then
        player_memory.items[item_id] = player_memory.items[item_id] + amount
    else
        player_memory.items[item_id] = amount
    end
    printd('gave ' .. player_id .. ' ' .. amount .. ' ' .. name .. ' now they have ' .. player_memory.items[item_id])
    ezmemory.save_player_memory(safe_secret)
    if name == "HPMem" then
        ezmemory.set_player_max_health(player_id, Net.get_player_max_health(player_id) + 20, true)
    end
    ezbus:emit("item_gained", {
        player_id = player_id,
        item_name = name,
        amount = amount,
        new_total = player_memory.items[item_id]
    })
    return player_memory.items[item_id]
end

function ezmemory.remove_player_item(player_id, name, remove_quant)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    local item_id = ezmemory.get_item_id_by_name(name)
    if item_id == nil then
        printd('cant remove a ' .. name .. ' because it does not exist')
        return 0
    end
    if player_memory.items[item_id] then
        if items[item_id].key_item then
            for i = 1, remove_quant do
                Net.remove_player_item(player_id, item_id)
            end
        end
        player_memory.items[item_id] = player_memory.items[item_id] - remove_quant
        local remaining = player_memory.items[item_id]
        if remaining < 1 then
            player_memory.items[item_id] = nil
            remaining = 0
            ezmemory.save_player_memory(safe_secret)
        else
            ezmemory.save_player_memory(safe_secret)
        end
        ezbus:emit("item_lost", {
            player_id = player_id,
            item_name = name,
            amount_removed = remove_quant,
            remaining = remaining
        })
        return remaining
    end
    printd('removed a ' .. name .. ' from ' .. player_id)
    return 0
end

function ezmemory.get_player_money(player_id)
    if not (Net.get_player_money and Net.set_player_money) then
        return nil
    end

    local safe_secret = helpers.get_safe_player_secret(player_id)
    local pm = ezmemory.get_player_memory(safe_secret)

    local net_money = tonumber(Net.get_player_money(player_id) or 0) or 0
    local mem_money = tonumber(pm.money or net_money) or net_money

    local merged = math.max(net_money, mem_money)

    if pm.money ~= merged then
        pm.money = merged
        ezmemory.save_player_memory(safe_secret)
    end

    if net_money ~= merged then
        Net.set_player_money(player_id, merged)
    end

    return merged
end

function ezmemory.spend_player_money(player_id, amount)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    if player_memory.money >= amount then
        local new_balance = player_memory.money - amount
        Net.set_player_money(player_id, new_balance)
        player_memory.money = new_balance
        ezmemory.save_player_memory(safe_secret)
        ezbus:emit("money_spent", {
            player_id = player_id,
            amount = amount,
            new_balance = new_balance
        })
        return true
    end
    return false
end

function ezmemory.set_player_money(player_id, money)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    Net.set_player_money(player_id, money)
    player_memory.money = money
    ezmemory.save_player_memory(safe_secret)
    ezbus:emit("money_changed", {
        player_id = player_id,
        new_balance = money
    })
end

function ezmemory.get_player_fragments(player_id)
    if not (Net.get_player_fragments and Net.set_player_fragments) then
        return nil
    end

    local safe_secret = helpers.get_safe_player_secret(player_id)
    local pm = ezmemory.get_player_memory(safe_secret)

    local net_frags = tonumber(Net.get_player_fragments(player_id) or 0) or 0
    local mem_frags = tonumber(pm.fragments or net_frags) or net_frags

    local merged = math.max(net_frags, mem_frags)

    if pm.fragments ~= merged then
        pm.fragments = merged
        ezmemory.save_player_memory(safe_secret)
    end

    if net_frags ~= merged then
        Net.set_player_fragments(player_id, merged)
    end

    return merged
end

function ezmemory.set_player_fragments(player_id, fragments)
    if not (Net.get_player_fragments and Net.set_player_fragments) then
        error(
            "Fragments support isn't available on this server build (missing Net.get_player_fragments / Net.set_player_fragments).")
    end
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    Net.set_player_fragments(player_id, fragments)
    player_memory.fragments = fragments
    ezmemory.save_player_memory(safe_secret)
    ezbus:emit("fragments_changed", {
        player_id = player_id,
        new_total = fragments
    })
end

function ezmemory.add_player_fragments(player_id, amount)
    if not (Net.get_player_fragments and Net.set_player_fragments) then
        error(
            "Fragments support isn't available on this server build (missing Net.get_player_fragments / Net.set_player_fragments).")
    end
    amount = tonumber(amount) or 0
    if amount == 0 then return true end
    local cur = ezmemory.get_player_fragments(player_id) or 0
    ezmemory.set_player_fragments(player_id, cur + amount)
    ezbus:emit("fragments_changed", {
        player_id = player_id,
        new_total = cur + amount
    })
    return true
end

function ezmemory.spend_player_fragments(player_id, amount)
    if not (Net.get_player_fragments and Net.set_player_fragments) then
        print("Fragments support isn't installed in ezmemory yet.")
        return false
    end

    amount = tonumber(amount) or 0
    if amount == 0 then
        return true
    end

    local cur = tonumber(ezmemory.get_player_fragments(player_id) or 0) or 0

    if cur >= amount then
        ezmemory.set_player_fragments(player_id, cur - amount)
        ezbus:emit("fragments_changed", {
            player_id = player_id,
            new_total = cur - amount
        })
        return true
    end

    return false
end

local function _normalize_tokens(value)
    value = tonumber(value) or 0
    value = math.floor(value)
    if value < 0 then value = 0 end
    return value
end

function ezmemory.get_player_tokens(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local pm = ezmemory.get_player_memory(safe_secret)
    if pm.tokens == nil then
        pm.tokens = 0
        ezmemory.save_player_memory(safe_secret)
    end
    return _normalize_tokens(pm.tokens)
end

function ezmemory.set_player_tokens(player_id, tokens)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local pm = ezmemory.get_player_memory(safe_secret)
    tokens = _normalize_tokens(tokens)
    pm.tokens = tokens
    ezmemory.save_player_memory(safe_secret)
    ezbus:emit("tokens_changed", {
        player_id = player_id,
        new_total = tokens
    })
    return tokens
end

function ezmemory.add_player_tokens(player_id, amount)
    amount = tonumber(amount) or 0
    if amount == 0 then
        return ezmemory.get_player_tokens(player_id)
    end
    local cur = ezmemory.get_player_tokens(player_id)
    local new_total = cur + amount
    ezmemory.set_player_tokens(player_id, new_total)
    ezbus:emit("tokens_changed", {
        player_id = player_id,
        new_total = new_total
    })
    return new_total
end

function ezmemory.spend_player_tokens(player_id, amount)
    amount = tonumber(amount) or 0
    if amount == 0 then
        return true
    end

    local cur = ezmemory.get_player_tokens(player_id)

    if amount < 0 then
        local new_total = cur - amount
        ezmemory.set_player_tokens(player_id, new_total)
        ezbus:emit("tokens_changed", {
            player_id = player_id,
            new_total = new_total
        })
        return true
    end

    if cur >= amount then
        local new_total = cur - amount
        ezmemory.set_player_tokens(player_id, new_total)
        ezbus:emit("tokens_changed", {
            player_id = player_id,
            new_total = new_total
        })
        return true
    end

    return false
end

function ezmemory.count_player_item(player_id, item_name)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    local item_id = ezmemory.get_item_id_by_name(item_name)
    if item_id == nil then
        return 0
    end
    if player_memory.items[item_id] then
        return player_memory.items[item_id]
    end
    return 0
end

function ezmemory.open_shop_async(player_id, shop_items, mugshot_texture_path, mugshot_animation_path)
    return async(function()
        local shop = Net.open_shop(player_id, shop_items, mugshot_texture_path, mugshot_animation_path)
        local async_iter = shop:async_iter_all()
        local shop_items_by_name = {}
        for index, value in ipairs(shop_items) do
            shop_items_by_name[value.name] = value
        end

        for event_name, event_data in Async.await(async_iter) do
            if event_name == 'shop_purchase' then
                local item = shop_items_by_name[event_data.item_name]
                if ezmemory.spend_player_money(player_id, item.price) then
                    ezmemory.create_or_update_item(item.name, item.description, item.is_key)
                    ezmemory.give_player_item(player_id, item.name, 1)
                end
            end
        end
    end)
end

function ezmemory.hide_object_from_player_till_disconnect(player_id, area_id, object_id)
    object_id = tostring(object_id)
    local player_area = Net.get_player_area(player_id)
    if not objects_hidden_till_disconnect_for_player[player_id] then
        objects_hidden_till_disconnect_for_player[player_id] = {}
    end
    if not objects_hidden_till_disconnect_for_player[player_id][area_id] then
        objects_hidden_till_disconnect_for_player[player_id][area_id] = {}
    end
    objects_hidden_till_disconnect_for_player[player_id][area_id][object_id] = true
    if player_area == area_id then
        Net.exclude_object_for_player(player_id, object_id)
    end
    ezbus:emit("object_hidden", {
        player_id = player_id,
        area_id = area_id,
        object_id = object_id,
        persistent = false
    })
end

function ezmemory.unhide_object_from_player_till_disconnect(player_id, area_id, object_id)
    object_id = tostring(object_id)
    local dict = objects_hidden_till_disconnect_for_player
    if dict[player_id] and dict[player_id][area_id] then
        dict[player_id][area_id][object_id] = nil
        if next(dict[player_id][area_id]) == nil then
            dict[player_id][area_id] = nil
        end
        if next(dict[player_id]) == nil then
            dict[player_id] = nil
        end
    end

    if Net.include_object_for_player and Net.get_player_area(player_id) == area_id then
        pcall(Net.include_object_for_player, player_id, object_id)
    end
end

function ezmemory.unhide_object_from_player(player_id, area_id, object_id)
    object_id = tostring(object_id)
    local player_area = Net.get_player_area(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_area_memory = ezmemory.get_player_area_memory(safe_secret, area_id)
    if player_area_memory.hidden_objects[object_id] then
        player_area_memory.hidden_objects[object_id] = nil
        ezmemory.save_player_memory(safe_secret)
    end

    if Net.include_object_for_player and player_area == area_id then
        pcall(Net.include_object_for_player, player_id, object_id)
    end
end

function ezmemory.hide_object_from_player(player_id, area_id, object_id)
    object_id = tostring(object_id)
    local player_area = Net.get_player_area(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_area_memory = ezmemory.get_player_area_memory(safe_secret, area_id)
    if not player_area_memory.hidden_objects[object_id] then
        player_area_memory.hidden_objects[object_id] = true
        ezmemory.save_player_memory(safe_secret)
    end
    if player_area == area_id then
        Net.exclude_object_for_player(player_id, object_id)
    end
    ezbus:emit("object_hidden", {
        player_id = player_id,
        area_id = area_id,
        object_id = object_id,
        persistent = true
    })
end

function ezmemory.object_is_hidden_from_player(player_id, area_id, object_id)
    object_id = tostring(object_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_area_memory = ezmemory.get_player_area_memory(safe_secret, area_id)
    local area_memory = ezmemory.get_area_memory(area_id)
    if ezmemory.object_is_hidden_from_player_till_disconnect(player_id, area_id, object_id) then
        return true
    end
    if area_memory.hidden_objects[object_id] then
        return true
    end
    if player_area_memory.hidden_objects[object_id] then
        return true
    end
    return false
end

function ezmemory.object_is_hidden_from_player_till_disconnect(player_id, area_id, object_id)
    object_id = tostring(object_id)
    local dict = objects_hidden_till_disconnect_for_player
    if dict[player_id] and dict[player_id][area_id] and dict[player_id][area_id][object_id] == true then
        return true
    end
    return false
end

function ezmemory.handle_player_disconnect(player_id)
    objects_hidden_till_disconnect_for_player = {}
end

function ezmemory.handle_player_join(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_name = Net.get_player_name(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    normalize_player_memory(player_memory)
    ezmemory.update_player_list(safe_secret, player_name)
    for item_id, quantity in pairs(player_memory.items) do
        if items[item_id].key_item then
            for i = 1, quantity do
                Net.give_player_item(player_id, item_id)
            end
        end
    end
    if Net.get_player_money and Net.set_player_money then
        local net_money = tonumber(Net.get_player_money(player_id) or 0) or 0
        local mem_money = tonumber(player_memory.money or 0) or 0
        local merged = math.max(net_money, mem_money)

        if player_memory.money ~= merged then
            player_memory.money = merged
            ezmemory.save_player_memory(safe_secret)
        end
        Net.set_player_money(player_id, merged)
    else
        Net.set_player_money(player_id, player_memory.money)
    end
    if Net.get_player_fragments and Net.set_player_fragments then
        if player_memory.fragments == nil then
            local cur_frags = Net.get_player_fragments(player_id) or 0
            player_memory.fragments = cur_frags
            ezmemory.save_player_memory(safe_secret)
        end
        Net.set_player_fragments(player_id, player_memory.fragments or 0)
    end
    if player_memory.tokens == nil then
        player_memory.tokens = 0
    end
    player_memory.meta.joins = player_memory.meta.joins + 1
    ezmemory.handle_player_transfer(player_id)
    ezmemory.save_player_memory(safe_secret)
end

function ezmemory.handle_player_transfer(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_name = Net.get_player_name(player_id)
    local area_id = Net.get_player_area(player_id)
    if objects_hidden_till_disconnect_for_player[player_id] then
        if objects_hidden_till_disconnect_for_player[player_id][area_id] then
            for object_id, is_hidden in pairs(objects_hidden_till_disconnect_for_player[player_id][area_id]) do
                Net.exclude_object_for_player(player_id, object_id)
            end
        else
            objects_hidden_till_disconnect_for_player[player_id][area_id] = {}
        end
    else
        objects_hidden_till_disconnect_for_player[player_id] = {}
    end
    update_player_health(player_id)
    local area_memory = ezmemory.get_area_memory(area_id)
    if area_memory and area_memory.hidden_objects then
        for index, object_id in ipairs(area_memory.hidden_objects) do
            Net.exclude_object_for_player(player_id, object_id)
        end
    end
    local player_area_memory = ezmemory.get_player_area_memory(safe_secret, area_id)
    for object_id, is_hidden in pairs(player_area_memory.hidden_objects) do
        Net.exclude_object_for_player(player_id, object_id)
    end
    printd('hid ' .. #player_area_memory.hidden_objects .. ' objects from ' .. player_name)

    -- Also exclude bots for hidden NPC placeholders
    local eznpcs = require('scripts/ezlibs-scripts/eznpcs/eznpcs')
    if eznpcs and eznpcs.get_bot_id_for_placeholder then
        for obj_id, _ in pairs(player_area_memory.hidden_objects) do
            local bot_id = eznpcs.get_bot_id_for_placeholder(area_id, obj_id)
            if bot_id then
                Net.exclude_actor_for_player(player_id, bot_id)
            end
        end
    end
end

function ezmemory.calculate_player_modified_max_hp(player_id, base_max_hp, hp_memory_modifier, hp_memory_item)
    local hp_mem_count = ezmemory.count_player_item(player_id, hp_memory_item)
    local new_max_hp = (base_max_hp + hp_memory_modifier * hp_mem_count)
    return new_max_hp
end

function ezmemory.get_player_max_health(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    return player_memory.max_health
end

function ezmemory.get_player_health(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    return player_memory.health
end

function ezmemory.set_player_max_health(player_id, new_max_health, should_heal_by_increase)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)

    local current_health = Net.get_player_health(player_id)
    local max_health = Net.get_player_max_health(player_id)

    local new_health = current_health
    if new_max_health > max_health and should_heal_by_increase then
        local max_hp_increase = new_max_health - max_health
        new_health = current_health + max_hp_increase
    end

    new_health = math.min(new_health, new_max_health)
    Net.set_player_max_health(player_id, new_max_health)
    Net.set_player_health(player_id, new_health)
    player_memory.health = new_health
    player_memory.max_health = new_max_health
    ezmemory.save_player_memory(safe_secret)

    update_player_health(player_id)
    ezbus:emit("health_changed", {
        player_id = player_id,
        new_health = new_health,
        new_max_health = new_max_health
    })
end

ezmemory.set_player_health = function(player_id, new_health)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    local max_health = Net.get_player_max_health(player_id) or player_memory.max_health

    new_health = math.min(new_health, max_health)
    Net.set_player_health(player_id, new_health)
    player_memory.health = new_health
    ezmemory.save_player_memory(safe_secret)

    update_player_health(player_id)
    ezbus:emit("health_changed", {
        player_id = player_id,
        new_health = new_health,
        new_max_health = max_health
    })
end

function ezmemory.handle_player_avatar_change(player_id, details)
    player_avatar_details[player_id] = details
    update_player_health(player_id)
end

function ezmemory.give_item_with_optional_notify(player_id, area_id, item_object_id, item_info, notify_player)
    if notify_player == nil then
        notify_player = true
    end
    return async(function()
        if not item_info then
            item_info = helpers.read_item_information(area_id, item_object_id)
            if not item_info then
                return
            end
        end
        local is_key = item_info.type == "keyitem"
        local get_message = nil

        if is_key or item_info.type == "item" then
            ezmemory.create_or_update_item(item_info.name, item_info.description, is_key)
            ezmemory.give_player_item(player_id, item_info.name, item_info.amount)
            get_message = "Got " .. item_info.name .. "!"
            if item_info.amount ~= 1 then
                get_message = "Got " .. item_info.amount .. " " .. item_info.name .. "!"
            end
        elseif item_info.type == "money" then
            ezmemory.spend_player_money(player_id, -item_info.amount)
            get_message = "Got " .. item_info.amount .. "$!"
        elseif item_info.type == "fragments" then
            ezmemory.add_player_fragments(player_id, item_info.amount)
            get_message = "Got " .. item_info.amount .. " Bug Fragments!"
        elseif item_info.type == "tokens" then
            ezmemory.add_player_tokens(player_id, item_info.amount)
            get_message = "Got " .. item_info.amount .. " Tokens!"
        end
        if get_message ~= nil and notify_player == true then
            Net.play_sound_for_player(player_id, sfx.item_get)
            await(Async.message_player(player_id, get_message))
        end
    end)
end

-- ===================== Missing Animation Helpers =====================
function ezmemory.play_anim_get(player_id)
    pcall(function()
        return async(function()
            local parsed = avatar_utils.parse_player_animation(player_id, "sheet")
            print(parsed)
            if parsed and (parsed["animations"]["ITEM_GET"] ~= nil and parsed["animations"]["ITEM_GET_HOLD"]) then
                print(parsed["animations"]["ITEM_GET_HOLD"].total_duration_ms)
                Net.animate_player(player_id, "ITEM_GET", false)
                await(Async.sleep(tonumber(parsed["animations"]["ITEM_GET"].total_duration_ms)))
                Net.animate_player(player_id, "ITEM_GET_HOLD", true)
            else
                Net.animate_player(player_id, "ITEM_GET", false)
            end
        end)
    end)
end

function ezmemory.set_direction_anim(player_id, direction)
    pcall(function()
        print(direction)
        Net.animate_player(player_id, idle_map[direction], true)
    end)
end

return ezmemory
