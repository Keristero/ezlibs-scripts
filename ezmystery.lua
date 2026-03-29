local ezmystery = {}
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezcache = require('scripts/ezlibs-scripts/ezcache')
local helpers = require('scripts/ezlibs-scripts/helpers')
local ezlocks = require('scripts/ezlibs-scripts/ezlocks')
local condition = require('scripts/ezlibs-scripts/condition')
local ezencounters = require('scripts/ezlibs-scripts/ezencounters/main')
local math = require('math')
local ezbus = require('scripts/ezlibs-scripts/ezbus')

local AvatarCache = require('scripts/ezlibs-scripts/avatar_utils/main')
local AvatarUtils = require('scripts/ezlibs-scripts/avatar_utils/avatar_utils')

local object_cache = {}
local revealed_mysteries_for_players = {}

local sfx = {
    item_get = '/server/assets/ezlibs-assets/sfx/item_get.ogg',
}

local player_avatars = {}
local player_animations = {}

-- Robust boolean checker (case‑insensitive, accepts 1 as true)
local function is_property_true(val)
    if val == true then
        return true
    end
    if type(val) == "string" then
        return val:lower() == "true"
    end
    if type(val) == "number" then
        return val ~= 0
    end
    return false
end

-- Helper to get a readable resource name
local function resource_name(cost_type)
    if cost_type == "money" then return "Money"
    elseif cost_type == "fragments" then return "Bug Fragments"
    elseif cost_type == "tokens" then return "Tokens"
    else return cost_type end
end

local function object_is_mystery_data(object)
    if object.type == "Mystery Data" or object.type == "Mystery Datum" then
        return true
    end
end

local function fetch_player_avatar_and_details(player_id)
    local player_secret = Net.get_player_secret(player_id)
    local player_avatar = AvatarCache.get_player_avatar_paths(player_secret)
    print(player_avatar)

    local texture_path = ""
    local anim_path = ""
    if player_avatar ~= nil then
        if player_avatar.sheet ~= nil and player_avatar.sheet.texture ~= nil then
            texture_path = player_avatar.sheet.texture
        end
        if player_avatar.sheet ~= nil and player_avatar.sheet.animation ~= nil then
            anim_path = player_avatar.sheet.animation
        end
    end
    player_avatars[player_secret] = { texture_path = texture_path, anim_path = anim_path }
    local parsed = AvatarUtils.parse_animation_file(anim_path)
    player_animations[player_secret] = parsed
    print(player_animations)
end

Net:on("player_join", function(event)
    local player_id = event.player_id
    fetch_player_avatar_and_details(player_id)
end)

Net:on("avatar_change", function(event)
    local player_id = event.player_id
    fetch_player_avatar_and_details(player_id)
end)

Net:on("object_interaction", function(event)
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
    local area_min_mystery_count = tonumber(Net.get_area_custom_property(area_id, "Mystery Data Minimum")) or 1
    local area_max_mystery_count = tonumber(Net.get_area_custom_property(area_id, "Mystery Data Maximum")) or 0
    if area_min_mystery_count > area_max_mystery_count then return end
    if revealed_mysteries_for_players[player_id] == nil then revealed_mysteries_for_players[player_id] = {} end
    if revealed_mysteries_for_players[player_id] and revealed_mysteries_for_players[player_id][area_id] then
        return
    end
    local mystery_count = 0
    local desired_mystery_count = math.random(area_min_mystery_count, area_max_mystery_count)
    revealed_mysteries_for_players[player_id][area_id] = {}
    local datum_list = {}
    for i, object_id in next, objects do
        local object = Net.get_object_by_id(area_id, object_id)
        if object_is_mystery_data(object) then
            local once = is_property_true(object.custom_properties["Once"])
            local locked = is_property_true(object.custom_properties["Locked"])
            if not once and not locked then
                table.insert(datum_list, object.id)
                mystery_count = mystery_count + 1
            end
        end
    end
    while mystery_count > desired_mystery_count do
        local index = math.random(#datum_list)
        local mystery = datum_list[index]
        if mystery ~= nil then
            ezmemory.hide_object_from_player_till_disconnect(player_id, area_id, mystery)
            table.remove(datum_list, helpers.indexOf(datum_list, mystery))
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

local function run_quiz_from_list(player_id, area_id, quiz_list_id, failure_message)
    local quiz_list = ezcache.get_object_by_id_cached(area_id, quiz_list_id)
    if not quiz_list then
        warn("[ezmystery] Quiz List object not found: " .. tostring(quiz_list_id))
        return false
    end

    local question_ids = helpers.extract_numbered_properties(quiz_list, "Next ")
    if #question_ids == 0 then
        warn("[ezmystery] Quiz List has no Next properties")
        return false
    end

    for _, qid in ipairs(question_ids) do
        local qobj = ezcache.get_object_by_id_cached(area_id, qid)
        if not qobj then
            warn("[ezmystery] Quiz question object not found: " .. tostring(qid))
            return false
        end

        local question = qobj.custom_properties["Question"]
        local opt1 = qobj.custom_properties["Option 1"]
        local opt2 = qobj.custom_properties["Option 2"]
        local opt3 = qobj.custom_properties["Option 3"]
        local correct_answer = tonumber(qobj.custom_properties["Correct Answer"]) or 1

        local options = {}
        if opt1 and #opt1 > 0 then table.insert(options, opt1) end
        if opt2 and #opt2 > 0 then table.insert(options, opt2) end
        if opt3 and #opt3 > 0 then table.insert(options, opt3) end

        if #options == 0 then
            warn("[ezmystery] Quiz question " .. tostring(qid) .. " has no options")
            return false
        end

        if correct_answer < 1 or correct_answer > #options then
            correct_answer = 1
        end

        await(Async.message_player(player_id, question))

        local quiz_promise = Async.quiz_player(player_id, options[1], options[2], options[3])
        if type(quiz_promise) ~= "table" then
            if failure_message and #failure_message > 0 then
                await(Async.message_player(player_id, failure_message))
            end
            return false
        end
        local choice = await(quiz_promise)
        if choice == nil or choice < 0 or choice+1 ~= correct_answer then
            if failure_message and #failure_message > 0 then
                await(Async.message_player(player_id, failure_message))
            end
            return false
        end
    end
    return true
end

function try_collect_datum(player_id, area_id, object)
    return async(function()
        if ezmemory.object_is_hidden_from_player(player_id, area_id, object.id) then
            return
        end

        local lock_id = player_id .. "_" .. area_id .. "_" .. object.id
        local lock = helpers.get_lock(player_id, lock_id)
        if not lock then
            return
        end

        local password = object.custom_properties["Password Locked"]
        if password and #password > 0 then
            local unlocked = await(ezlocks.check_password(player_id, "Enter password:", password))
            if not unlocked then
                lock.release()
                return
            end
        end

        -- Cost handling with prompt
        local cost_type = object.custom_properties["Cost Type"]
        if cost_type and cost_type ~= "" then
            local cost_amount = tonumber(object.custom_properties["Cost Amount"] or 1)

            -- First check if they can afford it (without consuming)
            local check_cond = { type = cost_type, amount = cost_amount, consume = false }
            local can_afford = condition.evaluate(player_id, check_cond)

            if not can_afford then
                local fail_msg = object.custom_properties["Cost Failure Message"]
                                 or ("You don't have enough " .. cost_type .. ".")
                await(Async.message_player(player_id, fail_msg))
                lock.release()
                return
            end

            -- Ask for confirmation
            local res_name = resource_name(cost_type)
            local prompt = "Spend " .. cost_amount .. " " .. res_name .. " to unlock this Mystery Data?"
            local choice = await(Async.question_player(player_id, prompt))
            if choice == 0 then
                -- Player declined
                lock.release()
                return
            end

            -- Now spend it (consume = true)
            local spend_cond = { type = cost_type, amount = cost_amount, consume = true }
            if not condition.evaluate(player_id, spend_cond) then
                local fail_msg = "Failed to spend " .. cost_type .. "."
                await(Async.message_player(player_id, fail_msg))
                lock.release()
                return
            end
        end

        if is_property_true(object.custom_properties["Locked"]) then
            await(Async.message_player(player_id, "The Mystery Data is locked."))
            local unlocked = await(ezlocks.check_item(player_id, "Use an Unlocker to open it?", "Unlocker", 1, true))
            if not unlocked then
                lock.release()
                return
            end
        end

        local datum_type = object.custom_properties["Type"]
        local can_collect = true
        if datum_type == "quiz" then
            local quiz_list_id = object.custom_properties["Quiz List"]
            if not quiz_list_id or #quiz_list_id == 0 then
                warn("[ezmystery] Quiz type missing Quiz List property")
                can_collect = false
            else
                local failure_message = object.custom_properties["Failure Message"] or "Incorrect answer."
                can_collect = run_quiz_from_list(player_id, area_id, quiz_list_id, failure_message)
            end
        end

        if can_collect then
            await(Async.message_player(player_id, "Accessing the mystery data\x01...\x01"))
            await(collect_datum(player_id, object, object.id, datum_type == "quiz"))
        else
            -- Quiz failed – handle On Fail property
            local on_fail = object.custom_properties["On Fail"] or "retry"
            if on_fail == "hide_once" then
                ezmemory.hide_object_from_player(player_id, area_id, object.id)
            elseif on_fail == "hide_temp" then
                ezmemory.hide_object_from_player_till_disconnect(player_id, area_id, object.id)
            elseif on_fail == "explode" then
                local explosion_count = tonumber(object.custom_properties["Explosion Count"]) or 3
                ezbus:emit("explode", {
                    actor_id = object.id,
                    area_id = area_id,
                    max_explosions = explosion_count
                })
                -- Wait for the explosion effect to finish (~2 seconds)
                -- await(Async.sleep(2.0))
                ezmemory.hide_object_from_player_till_disconnect(player_id, area_id, object.id)
            end
            -- "retry" does nothing
        end
        lock.release()
    end)
end

function read_datum_information(area_id, object)
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

function collect_datum(player_id, object, datum_id_override, is_quiz)
    return async(function()
        local area_id = Net.get_player_area(player_id)
        local item_info

        if is_quiz then
            item_info = {
                type = object.custom_properties["Reward Type"] or "item",
                name = object.custom_properties["Reward Name"],
                amount = tonumber(object.custom_properties["Reward Amount"] or 1),
                description = object.custom_properties["Reward Description"] or "???",
                price = 0
            }
        else
            item_info = read_datum_information(area_id, object)
        end

        if not item_info or item_info == false then
            return
        end

        if item_info.type == "random" then
            local random_options = helpers.extract_numbered_properties(object, "Next ")
            local random_selection_id = random_options[math.random(#random_options)]
            if random_selection_id then
                local randomly_selected_datum = ezcache.get_object_by_id_cached(area_id, random_selection_id)
                await(collect_datum(player_id, randomly_selected_datum, datum_id_override, false))
            end

        elseif item_info.type == "encounter" then
            -- Start an encounter
            local encounter_name = item_info.name
            if not encounter_name or encounter_name == "" then
                warn("[ezmystery] Encounter type missing Name property")
                return
            end

            -- Show introductory messages
            await(Async.message_player(player_id, "Oh no! The Mystery Data was a virus!"))

            -- Hide temporarily during battle
            ezmemory.hide_object_from_player_till_disconnect(player_id, area_id, datum_id_override)

            -- Start the encounter
            local results = await(ezencounters.begin_encounter_by_name(player_id, encounter_name))

            -- After battle, always keep it hidden temporarily (already done)
            -- No further action needed.

        else
            local direction = Net.get_player_direction(player_id)
            -- Normal item/money/fragments/tokens reward
            ezmemory.play_anim_get(player_id)
            await(ezmemory.give_item_with_optional_notify(player_id, area_id, object.id, item_info))
            ezmemory.set_direction_anim(player_id, direction)
        end

        ezbus:emit("mystery_collected", {
            player_id = player_id,
            area_id = area_id,
            object_id = datum_id_override,
            item_info = item_info
        })

        -- For non-encounter types, apply hiding after reward
        if item_info.type ~= "encounter" then
            if is_property_true(object.custom_properties["Once"]) then
                print("[ezmystery] Hiding permanently for player", player_id, "object", datum_id_override)
                ezmemory.hide_object_from_player(player_id, area_id, datum_id_override)
            end
            ezmemory.hide_object_from_player_till_disconnect(player_id, area_id, datum_id_override)
        end
    end)
end

return ezmystery