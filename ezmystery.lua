local ezmystery = {}
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezcache = require('scripts/ezlibs-scripts/ezcache')
local helpers = require('scripts/ezlibs-scripts/helpers')
local math = require('math')

local object_cache = {}

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

Net:on("object_interaction", function(event)
    -- { player_id: string, object_id: number, button: number }
    print(event.player_id, event.object_id, event.button)
    local area_id = Net.get_player_area(event.player_id)
    local object = Net.get_object_by_id(area_id, event.object_id)
    if object.type == "Mystery Data" or object.type == "Mystery Datum" then
        try_collect_datum(event.player_id, area_id, object)
    end
end)

function ezmystery.handle_player_join(player_id)
    --Load sound effects for mystery data interaction
    for name, path in pairs(sfx) do
        Net.provide_asset_for_player(player_id, path)
    end
end

function try_collect_datum(player_id, area_id, object)
    return async(function()
        if ezmemory.object_is_hidden_from_player(player_id, area_id, object.id) then
            --Anti spam protection
            return
        end
        if object.custom_properties["Locked"] == "true" then
            await(Async.message_player(player_id, "The Mystery Data is locked."))
            if ezmemory.count_player_item(player_id, "Unlocker") > 0 then
                local response = await(Async.question_player(player_id, "Use an Unlocker to open it?"))
                if response == 1 then
                    ezmemory.remove_player_item(player_id, "Unlocker", 1)
                    await(collect_datum(player_id, object, object.id))
                end
            end
        else
            --If the data is not locked, collect it
            await(Async.message_player(player_id, "Accessing the mystery data\x01...\x01"))
            await(collect_datum(player_id, object, object.id))
        end
    end)
end

function validate_datum(object)
    local type = object.custom_properties["Type"]
    if type == "random" then
        local random_options = helpers.extract_numbered_properties(object, "Next ")
        if #random_options == 0 then
            warn('[ezmystery] ' .. object.id .. ' is type=random, but has no Next #')
            return false
        end
    elseif type == "keyitem" then
        local name = object.custom_properties["Name"]
        local description = object.custom_properties["Description"]
        if not name or not description then
            warn('[ezmystery] ' .. object.id .. ' has either no name or description')
            return false
        end
    elseif type == "item" then
        local name = object.custom_properties["Name"]
        if not name then
            warn('[ezmystery] ' .. object.id .. ' has no name')
            return false
        end
    elseif type == "money" then
        local amount = object.custom_properties["Amount"]
        if not amount then
            warn('[ezmystery] ' .. object.id .. ' has no amount')
            return false
        end
    else
        warn('[ezmystery] invalid type for mystery data '.. object.id .. " type= ".. tostring(type))
    end
    return true
end

function collect_datum(player_id, object, datum_id_override)
    return async(function()
        local area_id = Net.get_player_area(player_id)
        if not validate_datum(object) then
            return
        end
        if object.custom_properties["Type"] == "random" then
            local random_options = helpers.extract_numbered_properties(object, "Next ")
            local random_selection_id = random_options[math.random(#random_options)]
            if random_selection_id then
                randomly_selected_datum = ezcache.get_object_by_id_cached(area_id, random_selection_id)
                await(collect_datum(player_id, randomly_selected_datum, datum_id_override))
                return
            end
        elseif object.custom_properties["Type"] == "keyitem" then
            local name = object.custom_properties["Name"]
            local description = object.custom_properties["Description"]
            --Give the player an item
            ezmemory.create_or_update_item(name, description, true)
            ezmemory.give_player_item(player_id, name, 1)
            Net.message_player(player_id, "Got " .. name .. "!")
            Net.play_sound_for_player(player_id, sfx.item_get)
        elseif object.custom_properties["Type"] == "item" then
            local name = object.custom_properties["Name"]
            --Give the player an item
            ezmemory.create_or_update_item(name, "", false)
            ezmemory.give_player_item(player_id, name, 1)
            Net.message_player(player_id, "Got " .. name .. "!")
            Net.play_sound_for_player(player_id, sfx.item_get)
        elseif object.custom_properties["Type"] == "money" then
            local amount = object.custom_properties["Amount"]
            --Give the player money
            ezmemory.spend_player_money(player_id, -amount)
            Net.message_player(player_id, "Got " .. amount .. "$!")
            Net.play_sound_for_player(player_id, sfx.item_get)
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
