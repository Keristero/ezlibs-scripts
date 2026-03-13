local Direction = require("scripts/ezlibs-scripts/direction")
local helpers = require('scripts/ezlibs-scripts/helpers')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezcache = require('scripts/ezlibs-scripts/ezcache')
local object_registry = require('scripts/ezlibs-scripts/object_registry')
local math = require('math')
local ezbus = require('scripts/ezlibs-scripts/ezbus')
local ezquests = require('scripts/ezlibs-scripts/ezquests')   -- added for quest checks

local eznpcs = {}
local placeholder_to_botid = {}          -- area_id -> placeholder_id -> global bot ID (for non-exclusive NPCs)
local exclusive_npcs = {}                -- player_id -> { placeholder_id = bot_id }
local exclusive_placeholders = {}        -- list of { area_id, object_id } for all exclusive NPC placeholders

-- NEW: Quest‑exclusive NPC data
local quest_exclusive_placeholders = {}  -- list of { area_id, object_id, quest_name, required_state }
local quest_exclusive_npcs = {}           -- player_id -> { placeholder_id = bot_id }

local npcs = {}                           -- global bot ID -> npc data (for all bots, including exclusive)
local current_player_conversation = {}

local npc_asset_folder = '/server/assets/ezlibs-assets/eznpcs/'
local custom_events_script_path = 'scripts/events/eznpcs_events'
local custom_events_script_loaded = false
local generic_npc_mug_animation_path = npc_asset_folder..'mug/mug.animation'
local events = require('scripts/ezlibs-scripts/eznpcs/dialogue_types')
local npc_required_properties = {"Direction","Asset Name"}


local function printd(...)
    local arg={...}
    print('[eznpcs]',table.unpack(arg))
end

-- Helper to safely evaluate boolean properties from Tiled (can be boolean or string)
local function is_property_true(val)
    if val == true then return true end
    if type(val) == "string" then return val:lower() == "true" end
    if type(val) == "number" then return val ~= 0 end
    return false
end

-- Helper: get all players currently in the server (across all areas)
local function get_all_players()
    local players = {}
    local areas = Net.list_areas()
    for _, area_id in ipairs(areas) do
        local area_players = Net.list_players(area_id) or {}
        for _, pid in ipairs(area_players) do
            table.insert(players, pid)
        end
    end
    return players
end

-- Helper: exclude a bot from everyone except the owner
local function exclude_except_for(owner_id, bot_id)
    local all_players = get_all_players()
    for _, pid in ipairs(all_players) do
        if pid ~= owner_id then
            Net.exclude_actor_for_player(pid, bot_id)
        end
    end
    printd("Excluded bot", bot_id, "from all except", owner_id)
end

-- Helper: include a bot for all players (used when creating a non-exclusive bot)
local function include_for_all(bot_id)
    local all_players = get_all_players()
    for _, pid in ipairs(all_players) do
        Net.include_actor_for_player(pid, bot_id)
    end
end


function eznpcs.get_dialogue_mugshot(npc,player_id,dialogue)
    local mugshot_asset_name = npc.asset_name
    local custom_mugshot = dialogue.custom_properties["Mugshot"]
    local mug = {}
    if custom_mugshot then
        mugshot_asset_name = custom_mugshot
    end
    mug.texture_path = npc_asset_folder.."mug/"..mugshot_asset_name..".png"
    mug.animation_path = npc.mug_animation_path
    if mugshot_asset_name == "player" then
        local player_mugshot = Net.get_player_mugshot(player_id)
        mug.texture_path = player_mugshot.texture_path
        mug.animation_path = player_mugshot.animation_path
    end
    return mug
end

function do_dialogue(npc,player_id,dialogue,relay_object)
    return async(function ()
        local dialogue_promise = nil

        local area_id = Net.get_player_area(player_id)
        local dialogue_type = dialogue.custom_properties["Dialogue Type"]
        local event_name = dialogue.custom_properties["Event Name"]
        if event_name then
            --legacy override for people still using Event Name
            dialogue_type = event_name
        end
        if dialogue_type == nil then
            printd("dialogue "..dialogue.id.." has no Dialogue Type specified.")
            return
        end
        
        if events[dialogue_type] then
            dialogue_promise = events[dialogue_type].action(npc,player_id,dialogue,relay_object)
        end

        local next_dialogue_id = await(dialogue_promise)
        if not next_dialogue_id then
            return
        end

        local dialogue = ezcache.get_object_by_id_cached(area_id,next_dialogue_id)
        if not dialogue then
            return
        end
        return await(do_dialogue(npc,player_id,dialogue,relay_object))
    end)
end

-- Creates a bot (global or per-player) and returns its npc_data
function create_bot_from_object(area_id, object, player_id)
    if not object then return end
    local x = object.x
    local y = object.y
    local z = object.z

    for i, prop_name in pairs(npc_required_properties) do
        if not object.custom_properties[prop_name] then
            printd('NPC objects require the custom property '..prop_name)
            return false
        end
    end  

    local npc_asset_name = object.custom_properties["Asset Name"]
    local npc_animation_name = object.custom_properties["Animation Name"] or false
    local npc_mug_animation_name = object.custom_properties["Mug Animation Name"] or false
    local npc_turns_to_talk = is_property_true(object.custom_properties["Dont Face Player"])
    local direction = object.custom_properties.Direction

    -- Debug: print asset paths
    printd("Creating NPC with asset:", npc_asset_name, "texture:", npc_asset_folder.."sheet/"..npc_asset_name..".png")

    -- Create the bot (initially visible to all)
    local npc = create_npc(area_id, npc_asset_name, x, y, z, direction,
                           object.name, npc_animation_name, npc_mug_animation_name, npc_turns_to_talk)

    if not npc then 
        printd("Failed to create bot for", npc_asset_name)
        return 
    end

    -- If this is an exclusive NPC for a specific player, hide it from everyone else
    if player_id then
        if not exclusive_npcs[player_id] then exclusive_npcs[player_id] = {} end
        exclusive_npcs[player_id][tostring(object.id)] = npc.bot_id
        exclude_except_for(player_id, npc.bot_id)
        printd("Exclusive bot", npc.bot_id, "created for player", player_id)
    else
        -- Global NPC: store in placeholder_to_botid and ensure visible to all
        if not placeholder_to_botid[area_id] then placeholder_to_botid[area_id] = {} end
        placeholder_to_botid[area_id][tostring(object.id)] = npc.bot_id
        printd("Global bot", npc.bot_id, "created for placeholder", object.id)
    end

    if object.custom_properties["Dialogue Type"] then
        npc.first_dialogue = object
        local chat_behaviour = chat_behaviour()
        add_behaviour(npc, chat_behaviour)
    end

    if object.custom_properties["Next Waypoint 1"] then
        local waypoint_follow_behaviour = waypoint_follow_behaviour(object.custom_properties["Next Waypoint 1"])
        add_behaviour(npc, waypoint_follow_behaviour)
    end

    return npc
end

function create_npc(area_id,asset_name,x,y,z,direction,bot_name,animation_name,mug_animation_name,npc_turns_to_talk)
    local texture_path = npc_asset_folder.."sheet/"..asset_name..".png"
    local animation_path = npc_asset_folder.."sheet/"..asset_name..".animation"
    local mug_animation_path = generic_npc_mug_animation_path
    local name = bot_name or nil
    --Override animations if they were provided as custom properties
    if animation_name then
        animation_path = npc_asset_folder..'sheet/'..animation_name..".animation"
    end
    if mug_animation_name then
        mug_animation_path = npc_asset_folder..'mug/'..mug_animation_name..".animation"
    end
    if npc_turns_to_talk == nil then
        npc_turns_to_talk = true
    end
    --Create bot
    local npc_data = {
        asset_name=asset_name,
        bot_id=nil, 
        name=name, 
        area_id=area_id, 
        texture_path=texture_path, 
        animation_path=animation_path, 
        mug_animation_path=mug_animation_path,
        x=x, 
        y=y, 
        z=z, 
        direction=direction, 
        solid=true,
        size=0.2,
        speed=1,
        dont_face_player=npc_turns_to_talk,
        warp_in = true,  -- Explicitly set warp_in to ensure visibility
    }
    printd("Creating bot with texture:", texture_path, "animation:", animation_path)
    local lastBotId = Net.create_bot(npc_data)
    if not lastBotId then 
        printd("Net.create_bot returned nil for", asset_name)
        return nil 
    end
    npc_data.bot_id = lastBotId
    npcs[lastBotId] = npc_data
    printd('created npc '..(name or "unnamed")..' id:'..lastBotId..' at ('..x..','..y..','..z..')')
    return npc_data
end

function add_behaviour(npc,behaviour)
    if behaviour.type and behaviour.action then
        npc[behaviour.type] = behaviour
        if behaviour.initialize then
            behaviour.initialize(npc)
        end
    end
end

function clear_player_conversation(player_id)
    Net.unlock_player_input(player_id)
    local bot_id = current_player_conversation[player_id]
    if bot_id then
        local npc = npcs[bot_id]
        if npc and not npc.dont_face_player then
            Net.set_bot_direction(npc.bot_id, npc.direction)
        end
        current_player_conversation[player_id] = nil
        ezbus:emit("dialogue_ended", {
            player_id = player_id,
            npc_id = bot_id
        })
    end
end

--Behaviour factories
function chat_behaviour()
    behaviour = {
        type='on_interact',
        action=function(npc,player_id,relay_object)
            return async(function ()
                if current_player_conversation[player_id] == npc.bot_id then
                    return
                end
                current_player_conversation[player_id] = npc.bot_id

                if not npc.dont_face_player then
                    local player_pos = Net.get_player_position(player_id)
                    local dir = player_pos and Direction.from_points(npc, player_pos) or nil
                    if dir then
                        Net.set_bot_direction(npc.bot_id, dir)
                    end
                end

                local dialogue = npc.first_dialogue
                Net.lock_player_input(player_id)
                await(do_dialogue(npc,player_id,dialogue,relay_object))
                clear_player_conversation(player_id)
            end)
        end
    }
    return behaviour
end

function waypoint_follow_behaviour(first_waypoint_id)
    behaviour = {
        type='on_tick',
        initialize=function(npc)
            local first_waypoint = ezcache.get_object_by_id_cached(npc.area_id, first_waypoint_id)
            if first_waypoint then
                npc.next_waypoint = first_waypoint
            else
                printd('invalid Next Waypoint '..first_waypoint_id)
            end
        end,
        action=function(npc,delta_time)
            move_npc(npc,delta_time)
        end
    }
    return behaviour
end

function do_actor_interaction(player_id,actor_id,relay_object)
    local npc = npcs[actor_id]
    if npc and npc.on_interact then
        npc.on_interact.action(npc,player_id,relay_object)
    end
end

function is_anyone_talking_to_npc(npc_id)
    for player_id, chatty_npc_id in pairs(current_player_conversation) do
        if npc_id == chatty_npc_id then return true end
    end
    return false
end

function move_npc(npc,delta_time)
    if is_anyone_talking_to_npc(npc.bot_id) then return end
    if npc.wait_time and npc.wait_time > 0 then
        npc.wait_time = npc.wait_time - delta_time
        return
    end

    local area_id = Net.get_bot_area(npc.bot_id)
    local waypoint = npc.next_waypoint

    local distance = math.sqrt((waypoint.x - npc.x) ^ 2 + (waypoint.y - npc.y) ^ 2)
    if distance < npc.size then
        on_npc_reached_waypoint(npc,waypoint)
        return
    end
    
    local angle = math.atan(waypoint.y - npc.y, waypoint.x - npc.x)
    local vel_x = math.cos(angle) * npc.speed
    local vel_y = math.sin(angle) * npc.speed

    local new_pos = {x=0,y=0,z=npc.z,size=npc.size}

    new_pos.x = npc.x + vel_x * delta_time
    new_pos.y = npc.y + vel_y * delta_time

    if helpers.position_overlaps_something(new_pos,area_id) then return end

    Net.move_bot(npc.bot_id, new_pos.x, new_pos.y, new_pos.z)
    npc.x = new_pos.x
    npc.y = new_pos.y
end

function on_npc_reached_waypoint(npc,waypoint)
    local should_be_cached = ezcache.object_is_of_type(waypoint,{"Waypoint"})
    if not should_be_cached then
        printd("WARNING Waypoint "..waypoint.id.." at "..waypoint.x..","..waypoint.y.." in "..npc.area_id.." has incorrect type and wont be cached")
    end
    if waypoint.custom_properties['Wait Time'] ~= nil then
        npc.wait_time = tonumber(waypoint.custom_properties['Wait Time'])
        if waypoint.custom_properties['Direction'] ~= nil then
            npc.direction = waypoint.custom_properties['Direction']
            Net.set_bot_direction(npc.bot_id, waypoint.custom_properties['Direction'])
        end
    end
    local waypoint_type = "first"
    if waypoint.custom_properties["Waypoint Type"] then
        waypoint_type = waypoint.custom_properties["Waypoint Type"]
    end
    local next_waypoints = helpers.extract_numbered_properties(waypoint,"Next Waypoint ")
    local next_waypoint_id = nil
    if waypoint_type == "first" then
        next_waypoint_id = first_value_from_table(next_waypoints)
    end
    if waypoint_type == "random" then
        local next_waypoint_index = math.random(#next_waypoints)
        next_waypoint_id = next_waypoints[next_waypoint_index]
    end
    local date_b = waypoint.custom_properties['Date']
    if waypoint_type == "before" then
        if date_b then
            next_waypoint_id = next_waypoints[2]
            if helpers.is_now_before_date(date_b) then
                next_waypoint_id = next_waypoints[1]
            end
        end
    end
    if waypoint_type == "after" then
        if date_b then
            next_waypoint_id = next_waypoints[2]
            if not helpers.is_now_before_date(date_b) then
                next_waypoint_id = next_waypoints[1]
            end
        end
    end

    if next_waypoint_id then
        npc.next_waypoint = ezcache.get_object_by_id_cached(npc.area_id,next_waypoint_id)
    end
end

-- Helper to update quest‑exclusive NPCs for a given player
local function update_quest_exclusive_for_player(player_id)
    -- Remove any existing quest exclusive NPCs for this player
    if quest_exclusive_npcs[player_id] then
        for placeholder_id, bot_id in pairs(quest_exclusive_npcs[player_id]) do
            Net.remove_bot(bot_id)
            npcs[bot_id] = nil
        end
        quest_exclusive_npcs[player_id] = nil
    end

    -- For each quest exclusive placeholder, check if the player's quest state matches
    for _, entry in ipairs(quest_exclusive_placeholders) do
        local state = ezquests.get_player_quest_state(player_id, entry.quest_name)
        if state and state == entry.required_state then
            local object = ezcache.get_object_by_id_cached(entry.area_id, entry.object_id)
            if object then
                local npc = create_bot_from_object(entry.area_id, object, player_id)
                if npc then
                    if not quest_exclusive_npcs[player_id] then
                        quest_exclusive_npcs[player_id] = {}
                    end
                    quest_exclusive_npcs[player_id][tostring(entry.object_id)] = npc.bot_id
                    printd("Quest‑exclusive bot", npc.bot_id, "created for player", player_id, "quest", entry.quest_name)
                end
            end
        end
    end
end

-- Register handler for NPC objects
object_registry.register_handler("NPC", function(area_id, object)
    local props = object.custom_properties or {}
    local is_quest = is_property_true(props["Quest NPC"])
    local is_exclusive = is_property_true(props["Player Exclusive"])
    local quest_exclusive = props["Quest Exclusive"]   -- string (quest name) or nil

    if quest_exclusive then
        -- This is a quest‑exclusive placeholder
        local required_state = props["Quest State"] or "active"   -- default state
        table.insert(quest_exclusive_placeholders, {
            area_id = area_id,
            object_id = object.id,
            quest_name = quest_exclusive,
            required_state = required_state
        })
        printd("Registered quest‑exclusive placeholder id "..object.id.." in "..area_id.." for quest "..quest_exclusive)
    elseif is_quest or is_exclusive then
        printd("Skipping quest/exclusive NPC placeholder id "..object.id.." in "..area_id)
        if is_exclusive then
            -- Store exclusive placeholder for later use
            table.insert(exclusive_placeholders, {area_id = area_id, object_id = object.id})
        end
    else
        create_bot_from_object(area_id, object)
    end
end)

-- Public API
function eznpcs.load_npcs()
    local areas = Net.list_areas()
    for i, area_id in next, areas do
        eznpcs.add_npcs_to_area(area_id)
    end
end

function eznpcs.add_npcs_to_area(area_id)
    -- Legacy: scan area for NPCs (already handled by registry, but keep for completeness)
    local objects = Net.list_objects(area_id)
    for i, object_id in next, objects do
        local object = ezcache.get_object_by_id_cached(area_id, object_id)
        if object and object.type == "NPC" then
            local props = object.custom_properties or {}
            local is_quest = is_property_true(props["Quest NPC"])
            local is_exclusive = is_property_true(props["Player Exclusive"])
            local quest_exclusive = props["Quest Exclusive"]
            if quest_exclusive then
                -- Already handled by registry, but ensure it's stored (registry runs first)
                -- (duplicate entries won't hurt)
                local required_state = props["Quest State"] or "active"
                table.insert(quest_exclusive_placeholders, {
                    area_id = area_id,
                    object_id = object.id,
                    quest_name = quest_exclusive,
                    required_state = required_state
                })
            elseif not is_quest and not is_exclusive then
                create_bot_from_object(area_id, object)
            elseif is_exclusive then
                -- Also store in exclusive_placeholders in case area was added after startup
                table.insert(exclusive_placeholders, {area_id = area_id, object_id = object.id})
            end
        end
    end
end

function eznpcs.add_event(event_object)
    if not (event_object.name and event_object.action) then
        printd('Cant add invalid event, events need a name and action {}')
        return
    end
    if events[event_object.name] then
        printd('WARNING event '..event_object.name..' already exists and will be replaced')
    end
    events[event_object.name] = event_object
    printd('added event '..event_object.name)
end

function eznpcs.create_npc_from_object(area_id,object_id)
    local object = ezcache.get_object_by_id_cached(area_id, object_id)
    return create_bot_from_object(area_id, object)
end

function eznpcs.handle_actor_interaction(player_id,actor_id)
    return do_actor_interaction(player_id,actor_id)
end

function eznpcs.on_tick(delta_time)
    if not custom_events_script_loaded then
        custom_events_script_loaded = true
        helpers.safe_require(custom_events_script_path)
    end
    for bot_id, npc in pairs(npcs) do
        if npc.on_tick then
            npc.on_tick.action(npc,delta_time)
        end
    end
end

function eznpcs.create_npc(area_id,asset_name,x,y,z,direction,bot_name,animation_name,mug_animation_name)
    return create_npc(area_id,asset_name,x,y,z,direction,bot_name,animation_name,mug_animation_name)
end

function eznpcs.handle_player_transfer(player_id)
    clear_player_conversation(player_id)
end

function eznpcs.handle_player_join(player_id)
    -- Create player‑exclusive NPCs
    for _, entry in ipairs(exclusive_placeholders) do
        local object = ezcache.get_object_by_id_cached(entry.area_id, entry.object_id)
        if object then
            local hidden = ezmemory.object_is_hidden_from_player(player_id, entry.area_id, entry.object_id)
            if not hidden then
                if not exclusive_npcs[player_id] or not exclusive_npcs[player_id][tostring(entry.object_id)] then
                    create_bot_from_object(entry.area_id, object, player_id)
                end
            end
        end
    end

    -- Create quest‑exclusive NPCs based on current quest state
    update_quest_exclusive_for_player(player_id)

    -- Exclude other players' exclusive NPCs from this new player
    for owner_id, npcs_for_owner in pairs(exclusive_npcs) do
        for placeholder_id, bot_id in pairs(npcs_for_owner) do
            if owner_id ~= player_id then
                Net.exclude_actor_for_player(player_id, bot_id)
            end
        end
    end
    -- Also exclude other players' quest‑exclusive NPCs
    for owner_id, npcs_for_owner in pairs(quest_exclusive_npcs) do
        for placeholder_id, bot_id in pairs(npcs_for_owner) do
            if owner_id ~= player_id then
                Net.exclude_actor_for_player(player_id, bot_id)
            end
        end
    end
end

function eznpcs.handle_player_disconnect(player_id)
    clear_player_conversation(player_id)

    -- Remove player‑exclusive NPCs
    if exclusive_npcs[player_id] then
        for placeholder_id, bot_id in pairs(exclusive_npcs[player_id]) do
            Net.remove_bot(bot_id)
            npcs[bot_id] = nil
        end
        exclusive_npcs[player_id] = nil
    end

    -- Remove quest‑exclusive NPCs
    if quest_exclusive_npcs[player_id] then
        for placeholder_id, bot_id in pairs(quest_exclusive_npcs[player_id]) do
            Net.remove_bot(bot_id)
            npcs[bot_id] = nil
        end
        quest_exclusive_npcs[player_id] = nil
    end
end

function eznpcs.handle_object_interaction(player_id, object_id)
    local area_id = Net.get_player_area(player_id)
    local object = ezcache.get_object_by_id_cached(area_id, object_id)
    if not object then 
        printd("handle_object_interaction: object not found in cache", object_id)
        return 
    end

    -- Check if it's an exclusive NPC placeholder
    if object.type == "NPC" and object.custom_properties then
        if is_property_true(object.custom_properties["Player Exclusive"]) then
            printd("Exclusive NPC interaction for player", player_id, "placeholder", object.id)
            if not exclusive_npcs[player_id] or not exclusive_npcs[player_id][tostring(object.id)] then
                local npc = create_bot_from_object(area_id, object, player_id)
                if npc then
                    do_actor_interaction(player_id, npc.bot_id, object)
                end
            else
                local bot_id = exclusive_npcs[player_id][tostring(object.id)]
                do_actor_interaction(player_id, bot_id, object)
            end
            return
        end

        -- Check if it's a quest‑exclusive placeholder
        local quest_exclusive = object.custom_properties["Quest Exclusive"]
        if quest_exclusive then
            printd("Quest‑exclusive NPC interaction for player", player_id, "placeholder", object.id)
            if not quest_exclusive_npcs[player_id] or not quest_exclusive_npcs[player_id][tostring(object.id)] then
                local required_state = object.custom_properties["Quest State"] or "active"
                local state = ezquests.get_player_quest_state(player_id, quest_exclusive)
                if state and state == required_state then
                    local npc = create_bot_from_object(area_id, object, player_id)
                    if npc then
                        if not quest_exclusive_npcs[player_id] then
                            quest_exclusive_npcs[player_id] = {}
                        end
                        quest_exclusive_npcs[player_id][tostring(object.id)] = npc.bot_id
                        do_actor_interaction(player_id, npc.bot_id, object)
                    end
                else
                    printd("Player", player_id, "does not meet quest state for", quest_exclusive)
                end
            else
                local bot_id = quest_exclusive_npcs[player_id][tostring(object.id)]
                do_actor_interaction(player_id, bot_id, object)
            end
            return
        end
    end

    -- Existing relay logic for non-exclusive NPCs
    if object.custom_properties and object.custom_properties["Interact Relay"] then
        local placeholder_id = object.custom_properties["Interact Relay"]
        if placeholder_to_botid[area_id] and placeholder_to_botid[area_id][placeholder_id] then
            local bot_id = placeholder_to_botid[area_id][placeholder_id]
            do_actor_interaction(player_id, bot_id, object)
        end
    end
end

-- Helper to remove an exclusive NPC (called from dialogue_types on win)
function eznpcs.remove_exclusive_npc(player_id, placeholder_id)
    if exclusive_npcs[player_id] then
        local bot_id = exclusive_npcs[player_id][tostring(placeholder_id)]
        if bot_id then
            Net.remove_bot(bot_id)
            npcs[bot_id] = nil
            exclusive_npcs[player_id][tostring(placeholder_id)] = nil
            printd("Removed exclusive NPC bot", bot_id, "for player", player_id)
        end
    end
end

-- Helper to remove a quest‑exclusive NPC (can be called when quest state changes)
function eznpcs.remove_quest_exclusive_npc(player_id, placeholder_id)
    if quest_exclusive_npcs[player_id] then
        local bot_id = quest_exclusive_npcs[player_id][tostring(placeholder_id)]
        if bot_id then
            Net.remove_bot(bot_id)
            npcs[bot_id] = nil
            quest_exclusive_npcs[player_id][tostring(placeholder_id)] = nil
            printd("Removed quest‑exclusive NPC bot", bot_id, "for player", player_id)
        end
    end
end

-- Helper to get bot ID for placeholder (used in ezmemory)
function eznpcs.get_bot_id_for_placeholder(area_id, placeholder_id)
    if placeholder_to_botid[area_id] then
        return placeholder_to_botid[area_id][tostring(placeholder_id)]
    end
    return nil
end

-- Listen for quest events to refresh quest‑exclusive NPCs
ezbus:on("quest_event", function(event)
    local player_id = event.player_id
    -- When a quest event occurs, update quest‑exclusive NPCs for that player
    -- (This covers state changes that happen through dialogue)
    update_quest_exclusive_for_player(player_id)
end)

return eznpcs