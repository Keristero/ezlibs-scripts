local ezmystery = {}
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezcache = require('scripts/ezlibs-scripts/ezcache')
local helpers = require('scripts/ezlibs-scripts/helpers')
local math = require('math')

local object_cache = {}
local revealed_mysteries_for_players = {}

local sfx = {
    item_get = '/server/assets/ezlibs-assets/sfx/item_get.ogg',
}

--Type Mystery Data (or Mystery Datum) have these custom_properties
--Locked (bool) do you need an unlocker to open this?
--Once (bool) should this never respawn for this player?
--Type (string) either 'keyitem' or 'money'
--(for keyitem type)
--    Name (string) name of keyitem
--    Description (string) description of keyitem
--(for money type)
--    Amount (number) amount of money to give

local function object_is_mystery_data(object)
    if object.type == "Mystery Data" or object.type == "Mystery Datum" then
        return true
    end
end

Net:on("object_interaction", function(event)
    -- { player_id: string, object_id: number, button: number }
    local area_id = Net.get_player_area(event.player_id)
    local object = Net.get_object_by_id(area_id, event.object_id)
    if object_is_mystery_data(object) then
        try_collect_datum(event.player_id, area_id, object)
    end
end)

function ezmystery.handle_player_disconnect(player_id)
    revealed_mysteries_for_players[player_id] = nil
end

function ezmystery.hide_random_data(player_id)
    local area_id = Net.get_player_area(player_id)
    local objects = Net.list_objects(area_id)
    --New map properties. Default to making maximum smaller than minimum so that if this isn't setup, it won't be used.
    local area_min_mystery_count = tonumber(Net.get_area_custom_property(area_id, "Mystery Data Minimum")) or 1
    local area_max_mystery_count = tonumber(Net.get_area_custom_property(area_id, "Mystery Data Maximum")) or 0
    --As mentioned, don't do anything if the min is smaller than the max. Safety!
    if area_min_mystery_count > area_max_mystery_count then return end
    --If we don't have a record of this player upon transfer (due to reasons like joining in an area without randomized data), then process this player
    if revealed_mysteries_for_players[player_id] == nil then revealed_mysteries_for_players[player_id] = {} end
    --If we've already processed this area for this player, don't process. We don't want to process the same area twice.
    --That way, we don't rearrange existing mystery data, or data that's already been hidden.
    if revealed_mysteries_for_players[player_id] and revealed_mysteries_for_players[player_id][area_id] then
        return
    end
    --Mystery count used in the loop.
    local mystery_count = 0
    --Amount of mystery data to be found in the area.
    local desired_mystery_count = math.random(area_min_mystery_count, area_max_mystery_count)
    --Add the area to a dict of player memory. Since we've started processing this area, we don't want to process it again.
    revealed_mysteries_for_players[player_id][area_id] = {}
    local datum_list = {}
    for i, object_id in next, objects do
        local object = Net.get_object_by_id(area_id, object_id)
        --Only allow in to the list if it's a mystery datum that is not set to one-time and it's not locked.
        if object_is_mystery_data(object) and object.custom_properties["Once"] ~= "true" and object.custom_properties["Locked"] ~= "true" then
            --Add to the list.
            table.insert(datum_list, object.id)
            --Increment count since we found a datum.
            mystery_count = mystery_count + 1
        end
    end
    while mystery_count > desired_mystery_count do
        --Get random mystery index.
        local index = math.random(#datum_list)
        --Get random mystery ID.
        local mystery = datum_list[index]
        --If it's not already removed, then...
        if mystery ~= nil then
            --Hide it.
            ezmemory.hide_object_from_player_till_disconnect(player_id, area_id, mystery)
            --Remove it.
            table.remove(datum_list, helpers.indexOf(datum_list, mystery))
            --Reassign the mystery count.
            mystery_count = #datum_list
        end
    end
    revealed_mysteries_for_players[player_id][area_id] = datum_list
end

function ezmystery.handle_player_transfer(player_id)
    ezmystery.hide_random_data(player_id)
end

function ezmystery.handle_player_join(player_id)
    ezmystery.hide_random_data(player_id)
end

function try_collect_datum(player_id, area_id, object)
    return async(function()
        if ezmemory.object_is_hidden_from_player(player_id, area_id, object.id) then
            --Anti spam protection
            return
        end
        --anti spam lock
        local lock_id = player_id.."_"..area_id.."_"..object.id
        --lock needs to have a unique id for interaction between this player, and object
        local lock = helpers.get_lock(player_id,lock_id)
        if not lock then
            return
        end
        if object.custom_properties["Locked"] == "true" then
            await(Async.message_player(player_id, "The Mystery Data is locked."))
            if ezmemory.count_player_item(player_id, "Unlocker") > 0 then
                local response = await(Async.question_player(player_id, "Use an Unlocker to open it?"))
                if response == 1 then
                    ezmemory.remove_player_item(player_id, "Unlocker", 1)
                    await(collect_datum(player_id, object, object.id))
                    lock.release()
                end
            end
        else
            --If the data is not locked, collect it
            await(Async.message_player(player_id, "Accessing the mystery data\x01...\x01"))
            await(collect_datum(player_id, object, object.id))
            lock.release()
        end
    end)
end

function read_datum_information(area_id,object)
    local item_info = helpers.read_item_information(area_id, object.id)
    if not item_info then
        return false
    end
    if item_info.type == "random" then
        local random_options = helpers.extract_numbered_properties(object, "Next ")
        if #random_options == 0 then
            warn('[ezmystery] ' .. object.id .. ' is type=random, but has no Next #')
            return false
        end
    end
    return item_info
end

function collect_datum(player_id, object, datum_id_override)
    return async(function()
        local area_id = Net.get_player_area(player_id)
        local item_info = read_datum_information(area_id,object)
        if item_info == false then
            return
        end

        local is_key = item_info.type == "keyitem"
        if item_info.type == "random" then
            local random_options = helpers.extract_numbered_properties(object, "Next ")
            local random_selection_id = random_options[math.random(#random_options)]
            if random_selection_id then
                randomly_selected_datum = ezcache.get_object_by_id_cached(area_id, random_selection_id)
                await(collect_datum(player_id, randomly_selected_datum, datum_id_override))
                return
            end
        else
            await(ezmemory.give_item_with_optional_notify(player_id,area_id,object.id,item_info))
        end

        if object.custom_properties["Once"] == "true" then
            --If this mystery data should only be available once (not respawning)
            ezmemory.hide_object_from_player(player_id, area_id, datum_id_override)
        end

        --Now remove the mystery data
        ezmemory.hide_object_from_player_till_disconnect(player_id, area_id, datum_id_override)
    end)
end

return ezmystery
