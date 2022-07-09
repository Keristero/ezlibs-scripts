
local helpers = require('scripts/ezlibs-scripts/helpers')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezquests = require('scripts/ezlibs-scripts/ezquests')

local function read_item_information(area_id, item_object_id)
    local item_info_object = Net.get_object_by_id(area_id,item_object_id)
    local item_props = item_info_object.custom_properties
    local item = {}
    item.name = item_props["Name"]
    item.amount = tonumber(item_props["Amount"] or 1)
    item.description = item_props["Description"] or "???"
    item.type = item_props["Type"] or "item"
    item.price = tonumber(item_props["Price"] or 999999)
    if item.type ~= "money" and not item.name then
        warn("[eznpcs] item "..item_object_id.." needs a 'Name'")
        return false
    end
    if item.type == "keyitem" and item.description == "???" then
        warn("[eznpcs] key item "..item_object_id.."("..item.name..") should have a 'Description'")
        return false
    end
    return item
end
--Dialogue Types
local dialogue_types = {
    first={
        name = "first",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function()
                local dialogue_texts = helpers.extract_numbered_properties(dialogue,"Text ")
                local next_dialogues = helpers.extract_numbered_properties(dialogue,"Next ")
                local mugshot = eznpcs.get_dialogue_mugshot(npc,player_id,dialogue)
                local res = await(Async.message_player(player_id, dialogue_texts[1], mugshot.texture_path, mugshot.animation_path))
                local next_id = first_value_from_table(next_dialogues)
                return next_id
            end)
        end
    },
    question={
        name = "question",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local dialogue_texts = helpers.extract_numbered_properties(dialogue,"Text ")
                local next_dialogues = helpers.extract_numbered_properties(dialogue,"Next ")
                local mugshot = eznpcs.get_dialogue_mugshot(npc,player_id,dialogue)
                local res = await(Async.question_player(player_id, dialogue_texts[1], mugshot.texture_path, mugshot.animation_path))
                local next_id = next_dialogues[2-res]
                return next_id
            end)
        end
    },
    quiz={
        name = "quiz",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local dialogue_texts = helpers.extract_numbered_properties(dialogue,"Text ")
                local next_dialogues = helpers.extract_numbered_properties(dialogue,"Next ")
                local mugshot = eznpcs.get_dialogue_mugshot(npc,player_id,dialogue)
                local res = await(Async.quiz_player(player_id, dialogue_texts[1],dialogue_texts[2],dialogue_texts[3], mugshot.texture_path, mugshot.animation_path))
                local next_id = next_dialogues[res+1]
                return next_id
            end)
        end
    },
    random={
        name = "random",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local dialogue_texts = helpers.extract_numbered_properties(dialogue,"Text ")
                local next_dialogues = helpers.extract_numbered_properties(dialogue,"Next ")
                local mugshot = eznpcs.get_dialogue_mugshot(npc,player_id,dialogue)
                local rnd_text_index = math.random( #dialogue_texts)
                local res = await(Async.message_player(player_id, dialogue_texts[rnd_text_index], mugshot.texture_path, mugshot.animation_path))
                local next_id = next_dialogues[rnd_text_index] or next_dialogues[1]
                return next_id
            end)
        end
    },
    itemcheck={
        name = 'itemcheck',
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local area_id = Net.get_player_area(player_id)
                local required_items = helpers.extract_numbered_properties(dialogue,"Item ")
                local next_dialogues = helpers.extract_numbered_properties(dialogue,"Next ")

                local take_item = dialogue.custom_properties["Take Item"] == "true"
                local next_dialogue_id = nil

                local check_passed = true
                for index, item_object_id in ipairs(required_items) do
                    local item_info = read_item_information(area_id,item_object_id)
                    local has_count = 0
                    if item_info then
                        if item_info.type == "money" then
                            has_count = Net.get_player_money(player_id)
                        else
                            has_count = ezmemory.count_player_item(player_id, item_info.name)
                        end
                        if has_count < item_info.amount then
                            check_passed = false
                        end
                    end
                end
                if check_passed then
                    next_dialogue_id = next_dialogues[1]
                    for index, item_object_id in ipairs(required_items) do
                        local item_info = read_item_information(area_id,item_object_id)
                        if item_info and take_item then
                            if item_info.type == "money" then
                                ezmemory.spend_player_money(player_id,item_info.amount)
                            else
                                ezmemory.remove_player_item(player_id,item_info.name, item_info.amount)
                            end
                        end
                    end
                else
                    next_dialogue_id = next_dialogues[2]
                end
                return next_dialogue_id
            end)
        end
    },
    before={
        name = "before",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local dialogue_texts = helpers.extract_numbered_properties(dialogue,"Text ")
                local next_dialogues = helpers.extract_numbered_properties(dialogue,"Next ")
                local mugshot = eznpcs.get_dialogue_mugshot(npc,player_id,dialogue)
                local date_b = dialogue.custom_properties['Date']
                local message = dialogue_texts[2]
                local next_dialogue_id = next_dialogues[2]
                if helpers.is_now_before_date(date_b) then
                    message = dialogue_texts[1]
                    next_dialogue_id = next_dialogues[1]
                end
                if message then
                    await(Async.message_player(player_id, message, mugshot.texture_path, mugshot.animation_path))
                end
                return next_dialogue_id
            end)
        end
    },
    after={
        name = "after",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local dialogue_texts = helpers.extract_numbered_properties(dialogue,"Text ")
                local next_dialogues = helpers.extract_numbered_properties(dialogue,"Next ")
                local mugshot = eznpcs.get_dialogue_mugshot(npc,player_id,dialogue)
                local date_b = dialogue.custom_properties['Date']
                local message = dialogue_texts[2]
                local next_dialogue_id = next_dialogues[2]
                if not helpers.is_now_before_date(date_b) then
                    message = dialogue_texts[1]
                    next_dialogue_id = next_dialogues[1]
                end
                if message then
                    await(Async.message_player(player_id, message, mugshot.texture_path, mugshot.animation_path))
                end
                return next_dialogue_id
            end)
        end
    },
    shop={
        name = "shop",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local area_id = Net.get_player_area(player_id)
                local shop_item_object_ids = helpers.extract_numbered_properties(dialogue,"Item ")
                local next_dialogues = helpers.extract_numbered_properties(dialogue,"Next ")
                local mugshot = eznpcs.get_dialogue_mugshot(npc,player_id,dialogue)
                local shop_items = {}

                --create list of items for sale
                for i, item_object_id in ipairs(shop_item_object_ids) do
                    local item_info = read_item_information(area_id,item_object_id)
                    if item_info then
                        local shop_item = {
                            name=item_info.name,
                            price=item_info.price,
                            description=item_info.description or "???",
                            is_key=item_info.type == 'keyitem'
                        }
                        table.insert(shop_items,shop_item)
                    end
                end

                await(ezmemory.open_shop_async(player_id,shop_items,mugshot.texture_path,mugshot.animation_path))
                local next_id = first_value_from_table(next_dialogues)
                return next_id
            end)
        end
    },
    password={
        name = "password",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local correct_password = dialogue.custom_properties["Text 1"]
                local user_input = await(Async.prompt_player(player_id))
                if user_input == correct_password then
                    return dialogue.custom_properties["Next 1"]
                else
                    return dialogue.custom_properties["Next 2"]
                end
            end)
        end
    },
    quest_switch={
        name = "quest_switch",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                --returns a different next dialogue based on current quest state
                --specify a quest name as a property
                local quest_name = dialogue.custom_properties["Quest Name"]
                local quest_state = ezquests.get_player_quest_state(player_id,quest_name)
                if dialogue.custom_properties[quest_state] then
                    return dialogue.custom_properties[quest_state]
                else
                    warn('[eznpcs] dialogue node',dialogue.id,'has no custom property for quest state',quest_state)
                end
            end)
        end
    },
    quest_event={
        name = "quest_event",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local quest_name = dialogue.custom_properties["Quest Name"]
                local event_value = dialogue.custom_properties["Event Value"]
                local next_dialogues = helpers.extract_numbered_properties(dialogue,"Next ")
                await(ezquests.quest_event(player_id,quest_name,event_value))
                return first_value_from_table(next_dialogues)
            end)
        end
    },
    item={
        name = "item",
        action = function(npc, player_id, dialogue, relay_object)
            return async(function ()
                local area_id = Net.get_player_area(player_id)
                local gift_item_ids = helpers.extract_numbered_properties(dialogue,"Item ")
                for index, item_id in ipairs(gift_item_ids) do
                    local item_info = read_item_information(area_id,item_id)
                    if item_info then
                        if item_info.type == "money" then
                            item_info.name = "$"
                            --spending negative money gives it instead.
                            ezmemory.spend_player_money(player_id, -item_info.amount)
                        else
                            ezmemory.create_or_update_item(item_info.name,item_info.description,item_info.is_key)
                            ezmemory.give_player_item(player_id,item_info.name,item_info.amount)
                        end
                        local notify_player = dialogue.custom_properties["Dont Notify"] ~= "true"
                        local message = ""
                        if notify_player then
                            if item_info.amount == 1 then
                                message = "Got "..item_info.name.."!"
                            elseif item_info.amount > 1 then
                                message = "Got "..item_info.amount.." "..item_info.name.."!"
                            end
                            Net.play_sound_for_player(player_id, '/server/assets/ezlibs-assets/sfx/item_get.ogg')
                            await(Async.message_player(player_id, message))
                        end
                    end
                end
                return dialogue.custom_properties["Next 1"]
            end)
        end
    }
}

return dialogue_types