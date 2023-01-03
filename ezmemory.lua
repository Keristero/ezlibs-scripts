local json = require('scripts/ezlibs-scripts/json')
local helpers = require('scripts/ezlibs-scripts/helpers')
local table = require('table')
local ezmemory = {}

local isChangeHP = true

local player_memory = {}
local area_memory = {}
local player_list = {}
local player_avatar_details = {}
local items = {}
local item_name_table = {}
local objects_hidden_till_disconnect_for_player = {}

local players_path = './memory/players.json'
local items_path = './memory/items.json'
local area_path_prefix = './memory/area/'
local player_path_prefix = './memory/player/'

local memory_loaded_flags = {
    area_memory=false,
    player_memory=false,
    items=false
}

local highest_item_id = 1

local function load_file_and_then(filename,callback)
    local read_file_promise = Async.read_file(filename)
    read_file_promise.and_then(function(value)
        if value and value ~= "" then
            print('[ezmemory] loaded file '..filename)
            callback(value)
        else
            warn('[ezmemory] file dont exist '..filename)
            callback(nil)
        end
    end)
end

-- LOAD MEMORY, the order of these files loading matters
--Load items and their descriptions
load_file_and_then(items_path,function(value)
    if value == nil then
        items = {}
    else
        items = json.decode(value)
    end
    for item_id, item_data in pairs(items) do
        if item_data.key_item then
            Net.create_item(item_id,item_data)
        end
        item_name_table[item_data.name] = item_id
        local number_item_id = tonumber(item_id)
        if number_item_id > highest_item_id then
            highest_item_id = number_item_id
        end
        print('[ezmemory] loaded item '..item_id..' = '..item_data.name)
    end
    memory_loaded_flags.items = true
end)

--Load list of players that have existed
load_file_and_then(players_path,function(value)
    if value == nil then
        player_list = {}
    else
        player_list = json.decode(value)
    end
    --Load memory files for every player
    for safe_secret, name in pairs(player_list) do
        load_file_and_then(player_path_prefix..safe_secret..'.json',function (value)
            player_memory[safe_secret] = json.decode(value)
            print('[ezmemory] loaded memory for '..name)
        end)
    end
    memory_loaded_flags.player_memory = true
end)

--Load area memory for every area
local net_areas = Net.list_areas()
for i, area_id in ipairs(net_areas) do
    load_file_and_then(area_path_prefix..area_id..'.json',function(value)
        if value ~= nil then
            area_memory[area_id] = json.decode(value)
            print('[ezmemory] loaded area memory for '..area_id)
        end
    end)
end

local function update_player_health(player_id)
    local area_id = Net.get_player_area(player_id)
    local forced_base_hp = tonumber(Net.get_area_custom_property(area_id, "Forced Base HP"))
    local honor_hp_memory_rules = Net.get_area_custom_property(area_id, "Honor HPMem") == "true"
    local honor_saved_hp = Net.get_area_custom_property(area_id, "Honor Saved HP") == "true"
    local full_heal = Net.get_area_custom_property(area_id, "Full Heal") == "true"

    --first, load the players current health, this will be based on the player avatar unless it has already been modified
    local max_hp = Net.get_player_max_health(player_id)
    local hp = Net.get_player_health(player_id)
    print('current hp',hp)

    if not forced_base_hp and player_avatar_details[player_id].max_health then
        -- use default avatar max hp
        max_hp = player_avatar_details[player_id].max_health
    end

    --if we honor saved hp, load the saved hp from memory
    if honor_saved_hp then
        max_hp = ezmemory.get_player_max_health(player_id)
        hp = ezmemory.get_player_health(player_id)
    end

    --if we force base hp, set the max hp down to base
    if forced_base_hp and forced_base_hp > 0 then
        max_hp = forced_base_hp
    end

    --if we honor mystery data hp increases, calculate the modified max hp
    if honor_hp_memory_rules then
        max_hp = ezmemory.calculate_player_modified_max_hp(player_id,max_hp,20,"HPMem")
    end

    if full_heal then
        hp = max_hp
    end

    print('trying to set hp and max hp',hp,max_hp)
    Net.set_player_max_health(player_id,max_hp,false)
    hp = math.min(hp,max_hp)
    Net.set_player_health(player_id,hp)
end

function ezmemory.get_item_info(item_id)
    if items[item_id] then
        return items[item_id]
    end
    return nil
end

function ezmemory.create_or_update_item(item_name,item_description,is_key)
    if not item_name or not item_description then
        print('[ezmemory] item not created, missing name or description')
        return
    end
    local existing_item_id = ezmemory.get_item_id_by_name(item_name)
    local new_item_id
    if existing_item_id ~= nil then
        new_item_id = existing_item_id
        print('[ezmemory] item with name '..item_name..' already exists, overwriting')
    else
        new_item_id = tostring(highest_item_id + 1)
        highest_item_id = tonumber(new_item_id)
    end

    local new_item = {name=item_name,description=item_description,key_item=is_key}
    items[new_item_id] = new_item
    item_name_table[item_name] = new_item_id
    ezmemory.save_items()
    if is_key then
        Net.create_item(new_item_id,new_item)
    end
    return new_item_id
end

function ezmemory.get_item_id_by_name(item_name)
    if not memory_loaded_flags.items then
        error("ezmemory is still loading items, please wait a bit")
    end
    if item_name_table[item_name] then
        --If there is already an item with this name
        return item_name_table[item_name]
    end
    print('[ezmemory] item '..item_name..' does not exist')
    return nil
end

function ezmemory.get_or_create_item(item_name,item_description,is_key)
    local existing_item_id = ezmemory.get_item_id_by_name(item_name)
    if existing_item_id ~= nil then
        return existing_item_id
    end
    return ezmemory.create_or_update_item(item_name,item_description,is_key)
end

function ezmemory.save_items()
    Async.write_file(items_path, json.encode(items))
end

function ezmemory.save_area_memory(area_id)
    if area_memory[area_id] then
        Async.write_file('./memory/area/'..area_id..'.json', json.encode(area_memory[area_id]))
    end
end

function ezmemory.save_player_memory(safe_secret)
    if player_memory[safe_secret] then
        Async.write_file('./memory/player/'..safe_secret..'.json', json.encode(player_memory[safe_secret]))
    end
end

function ezmemory.dangerously_override_player_memory(safe_secret,new_memory)
    --Potentially really dangerous, might leave hanging references to the old memory and cause all kinds of trouble, use with absolute caution
    if player_memory[safe_secret] then
        player_memory[safe_secret] = new_memory
        Async.write_file('./memory/player/'..safe_secret..'.json', json.encode(player_memory[safe_secret]))
    end
end

function ezmemory.get_area_memory(area_id)
    if area_memory[area_id] then
        return area_memory[area_id]
    else
        area_memory[area_id] = {
            hidden_objects = {}
        }
        ezmemory.save_area_memory(area_id)
        return area_memory[area_id]
    end
end

function ezmemory.get_player_memory(safe_secret)
    if not memory_loaded_flags.player_memory then
        error("ezmemory is still loading area_memory, please wait a bit")
    end
    if player_memory[safe_secret] then
        return player_memory[safe_secret]
    else
        player_memory[safe_secret] = {
            items={},
            money=0,
            meta={
                joins=0
            },
            area_memory={},
        }
        ezmemory.save_player_memory(safe_secret)
        return player_memory[safe_secret]
    end
end

function ezmemory.get_player_area_memory(safe_secret,area_id)
    if not memory_loaded_flags.player_memory then
        error("ezmemory is still loading player_memory, please wait a bit")
    end
    local player_memory = ezmemory.get_player_memory(safe_secret)
    if player_memory.area_memory[area_id] then
        return player_memory.area_memory[area_id]
    else
        player_memory.area_memory[area_id] = {hidden_objects={}}
        ezmemory.save_player_memory(safe_secret)
        return player_memory.area_memory[area_id]
    end
end

function update_player_list(safe_secret,name)
    player_list[safe_secret] = name
    Async.write_file(players_path, json.encode(player_list))
end

function ezmemory.get_player_name_from_safesecret(safe_secret)
    if player_list[safe_secret] then
        return player_list[safe_secret]
    end
    return "Unknown"
end

function ezmemory.give_player_item(player_id, name, amount)
    if not amount then
        amount = 1
    end
    --TODO index items with player_memory.items[item_id]
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    local item_id = ezmemory.get_item_id_by_name(name)
    if item_id == nil then
        print('cant give player '..name..' because it has not been created')
        return 0
    end
    local item_info = ezmemory.get_item_info(item_id)
    if item_info.key_item then
        for i=1,amount do
            Net.give_player_item(player_id, item_id)
        end
    end
    if player_memory.items[item_id] then
        --If the player already has the item, increase the quantity
        player_memory.items[item_id] = player_memory.items[item_id] + amount
    else
        --Otherwise create the item
        player_memory.items[item_id] = amount
    end
    print('[ezmemory] gave '..player_id..' '..amount..' '..name..' now they have '..player_memory.items[item_id])
    ezmemory.save_player_memory(safe_secret)
    if name == "HPMem" then
        ezmemory.set_player_max_health(player_id,Net.get_player_max_health(player_id)+20,true)
    end
    return player_memory.items[item_id]
end

function ezmemory.remove_player_item(player_id, name, remove_quant)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    local item_id = ezmemory.get_item_id_by_name(name)
    if item_id == nil then
        print('[ezmemory] cant remove a '..name..' because it does not exist')
        return 0
    end
    if player_memory.items[item_id] then
        --If the player has the item
        if items[item_id].key_item then
            for i=1,remove_quant do
                Net.remove_player_item(player_id, item_id)
            end
        end
        player_memory.items[item_id] = player_memory.items[item_id] - remove_quant
        if player_memory.items[item_id] < 1 then
            --if the quantity drops below 1, remove the item completely
            player_memory.items[item_id] = nil
            ezmemory.save_player_memory(safe_secret)
            return 0
        end
        ezmemory.save_player_memory(safe_secret)
        return player_memory.items[item_id]
    end
    print('[ezmemory] removed a '..name..' from '..player_id)
    return 0
end

function ezmemory.spend_player_money(player_id, amount)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    if player_memory.money >= amount then
        local new_balance = player_memory.money-amount
        Net.set_player_money(player_id, new_balance)
        player_memory.money = new_balance
        ezmemory.save_player_memory(safe_secret)
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

function ezmemory.open_shop_async(player_id,shop_items,mugshot_texture_path,mugshot_animation_path)
    return async(function ()
        --print('[ezmemory] opened shop with items',shop_items)
        local shop = Net.open_shop(player_id, shop_items, mugshot_texture_path, mugshot_animation_path)
        local async_iter = shop:async_iter_all()
        local shop_items_by_name = {}
        for index, value in ipairs(shop_items) do
            shop_items_by_name[value.name] = value
        end

        --process shop events until the shop closes
        for event_name, event_data in Async.await(async_iter) do
            if event_name == 'shop_purchase' then
                local item = shop_items_by_name[event_data.item_name]
                if ezmemory.spend_player_money(player_id,item.price) then
                    ezmemory.create_or_update_item(item.name,item.description,item.is_key)
                    ezmemory.give_player_item(player_id,item.name,1)
                end
            end
        end
    end)
end

function ezmemory.hide_object_from_player_till_disconnect(player_id,area_id,object_id)
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
        --if the player is in the area of the object being hidden
        Net.exclude_object_for_player(player_id, object_id)
    end
end

function ezmemory.hide_object_from_player(player_id,area_id,object_id)
    object_id = tostring(object_id)
    local player_area = Net.get_player_area(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_area_memory = ezmemory.get_player_area_memory(safe_secret,area_id)
    if not player_area_memory.hidden_objects[object_id] then
        print('hiding object')
        player_area_memory.hidden_objects[object_id] = true
        ezmemory.save_player_memory(safe_secret)
    else
        print('object was already hidden')
    end
    if player_area == area_id then
        --if the player is in the area of the object being hidden
        Net.exclude_object_for_player(player_id, object_id)
    end
end

function ezmemory.object_is_hidden_from_player(player_id,area_id,object_id)
    object_id = tostring(object_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_area_memory = ezmemory.get_player_area_memory(safe_secret,area_id)
    local area_memory = ezmemory.get_area_memory(area_id)
    if ezmemory.object_is_hidden_from_player_till_disconnect(player_id,area_id,object_id) then
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

function ezmemory.object_is_hidden_from_player_till_disconnect(player_id,area_id,object_id)
    object_id = tostring(object_id)
    local dict = objects_hidden_till_disconnect_for_player
    if dict[player_id] and dict[player_id][area_id] and dict[player_id][area_id][object_id] == true then
        return true
    end
    return false
end

function ezmemory.handle_player_disconnect(player_id)
    --clear objects hidden till rejoin for player
    objects_hidden_till_disconnect_for_player = {}
end

function ezmemory.handle_player_join(player_id)
    --record player to list of players that have joined
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_name = Net.get_player_name(player_id)
    --assumes that player memory has already been read from disk
    local player_memory = ezmemory.get_player_memory(safe_secret)
    update_player_list(safe_secret,player_name)
    --Send player key items
    for item_id, quantity in pairs(player_memory.items) do
        if items[item_id].key_item then
            for i=1,quantity do
                Net.give_player_item(player_id, item_id)
            end
        end
    end
    --Send player money
    Net.set_player_money(player_id, player_memory.money)
    --update join count
    player_memory.meta.joins = player_memory.meta.joins + 1
    --also treat join as player transfer to do per area logic
    ezmemory.handle_player_transfer(player_id)
    --Save player memory
    ezmemory.save_player_memory(safe_secret)
end

function ezmemory.handle_player_transfer(player_id)
    --record player to list of players that have joined
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_name = Net.get_player_name(player_id)
    local area_id = Net.get_player_area(player_id)
    --assumes that player memory has already been read from disk
    --exlcude objects hidden till disconnect
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
    --update health
    update_player_health(player_id)
    --load memory of area
    local area_memory = ezmemory.get_area_memory(area_id)
    for object_id, is_hidden in pairs(area_memory.hidden_objects) do
        Net.exclude_object_for_player(player_id, object_id)
    end
    --load player's memory of area
    local player_area_memory = ezmemory.get_player_area_memory(safe_secret,area_id)
    for object_id, is_hidden in pairs(player_area_memory.hidden_objects) do
        Net.exclude_object_for_player(player_id, object_id)
    end
    print('[ezmemory] hid '..#player_area_memory.hidden_objects..' objects from '..player_name)
end

function ezmemory.calculate_player_modified_max_hp(player_id,base_max_hp,hp_memory_modifier,hp_memory_item)
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
    --If max health is raised and flag is true, add the increase in max health to current health too
    if new_max_health > max_health and should_heal_by_increase then
        local max_hp_increase = new_max_health-max_health
        new_health = current_health + max_hp_increase
    end

    local new_health = math.min(new_health, new_max_health)
    Net.set_player_max_health(player_id,new_max_health)
    Net.set_player_health(player_id,new_health)
    player_memory.health = new_health
    player_memory.max_health = max_health
    ezmemory.save_player_memory(safe_secret)

    update_player_health(player_id)
end

ezmemory.set_player_health = function(player_id, new_health)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    local max_health = player_memory.max_health or Net.get_player_max_health(player_id)

    -- dont set health to anything above the players max health
    print('[ezmemory] setting player health to ',new_health)
    local new_health = math.min(new_health, max_health)
    Net.set_player_health(player_id,new_health)
    player_memory.health = new_health
    ezmemory.save_player_memory(safe_secret)

    update_player_health(player_id)
end

function ezmemory.handle_player_avatar_change(player_id, details)
    print('handle avatar change',details)
    player_avatar_details[player_id] = details
    update_player_health(player_id)
end

return ezmemory