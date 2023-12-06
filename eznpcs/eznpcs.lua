local Direction = require("scripts/ezlibs-scripts/direction")
local helpers = require('scripts/ezlibs-scripts/helpers')
local CONFIG = require('scripts/ezlibs-scripts/ezconfig')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezcache = require('scripts/ezlibs-scripts/ezcache')
local math = require('math')

local eznpcs = {}
local placeholder_to_botid = {}

local npc_asset_folder = CONFIG.NPC_ASSET_FOLDER
local custom_events_script_path = CONFIG.NPC_EVENTS_SCRIPT_PATH
local custom_events_script_loaded = false
local generic_npc_mug_animation_path = npc_asset_folder..'mug/mug.animation'
local npcs = {}
local events = require('scripts/ezlibs-scripts/eznpcs/dialogue_types')
local current_player_conversation = {}
local npc_required_properties = {"Direction","Asset Name"}
local object_cache = {}

local function printd(...)
    local arg={...}
    print('[eznpcs]',table.unpack(arg))
end

--TODO load all waypoints / dialogues on server start and delete them from the map to save bandwidth

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

function create_bot_from_object(area_id,object_id)
    local placeholder_object = ezcache.get_object_by_id_cached(area_id, object_id)
    if not placeholder_object then
        return
    end
    local x = placeholder_object.x
    local y = placeholder_object.y
    local z = placeholder_object.z

    for i, prop_name in pairs(npc_required_properties) do
        if not placeholder_object.custom_properties[prop_name] then
            printd('NPC objects require the custom property '..prop_name)
            return false
        end
    end  

    local npc_asset_name = placeholder_object.custom_properties["Asset Name"]
    local npc_animation_name = placeholder_object.custom_properties["Animation Name"] or false
    local npc_mug_animation_name = placeholder_object.custom_properties["Mug Animation Name"] or false
    local npc_turns_to_talk = placeholder_object.custom_properties["Dont Face Player"] == "true"
    local direction = placeholder_object.custom_properties.Direction

    local npc = create_npc(area_id,npc_asset_name,x,y,z,direction,placeholder_object.name,npc_animation_name,npc_mug_animation_name,npc_turns_to_talk)

    if not placeholder_to_botid[area_id] then
        placeholder_to_botid[area_id] = {}
    end
    placeholder_to_botid[area_id][tostring(object_id)] = npc.bot_id
    --printd('added placeholder mapping '..object_id..' to '..npc.bot_id)

    if placeholder_object.custom_properties["Dialogue Type"] then
        --If the placeholder has Chat text, add behaviour to have it respond to interactions
        npc.first_dialogue = placeholder_object
        local chat_behaviour = chat_behaviour()
        add_behaviour(npc,chat_behaviour)
    end

    if placeholder_object.custom_properties["Next Waypoint 1"] then
        --If the placeholder has npc_first_waypoint
        local waypoint_follow_behaviour = waypoint_follow_behaviour(placeholder_object.custom_properties["Next Waypoint 1"])
        add_behaviour(npc,waypoint_follow_behaviour)
    end
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
    --Log final paths
    --printd('texture path: '..texture_path)
    --printd('animation path: '..animation_path)
    --printd('mug animation path: '..mug_animation_path)
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
    }
    local lastBotId = Net.create_bot(npc_data)
    npc_data.bot_id = lastBotId
    npcs[lastBotId] = npc_data
    printd('created npc '..name..' id:'..lastBotId..' at ('..x..','..y..','..z..')')
    return npc_data
end

function add_behaviour(npc,behaviour)
    --Behaviours have a type and an action
    --type is the event that triggers them, on_interact or on_tick
    --action is the callback for the logic
    --optionally initialize can exist to init the behaviour when it is first added
    if behaviour.type and behaviour.action then
        npc[behaviour.type] = behaviour
        if behaviour.initialize then
            behaviour.initialize(npc)
        end
        --printd('added '..behaviour.type..' behaviour to NPC')
    end
end

function clear_player_conversation(player_id)
    Net.unlock_player_input(player_id)
    local bot_id = current_player_conversation[player_id]
    if bot_id then
        local npc = npcs[bot_id]
        if not npc.dont_face_player then
            Net.set_bot_direction(npc.bot_id, npc.direction)
        end
        current_player_conversation[player_id] = nil
    end
end

--Behaviour factories
function chat_behaviour()
    behaviour = {
        type='on_interact',
        action=function(npc,player_id,relay_object)
            return async(function ()
                if current_player_conversation[player_id] == npc.bot_id then
                    --this player is already in a conversation with this npc
                    return
                end
                --printd('started talking to npc')
                current_player_conversation[player_id] = npc.bot_id

                if not npc.dont_face_player then
                    local player_pos = Net.get_player_position(player_id)
                    Net.set_bot_direction(npc.bot_id, Direction.from_points(npc, player_pos))
                end

                local dialogue = npc.first_dialogue
                Net.lock_player_input(player_id)
                await(do_dialogue(npc,player_id,dialogue,relay_object))
                --printd('finished talking to npc')
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
    local npc_id = actor_id
    if npcs[npc_id] then
        local npc = npcs[npc_id]
        if npc.on_interact then
            npc.on_interact.action(npc,player_id,relay_object)
        end
    end
end

function is_anyone_talking_to_npc(npc_id)
    for player_id, chatty_npc_id in pairs(current_player_conversation) do
        if npc_id == chatty_npc_id then
            return true
        end
    end
    return false
end

function move_npc(npc,delta_time)
    if is_anyone_talking_to_npc(npc.bot_id) then
        return
    end
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

    if helpers.position_overlaps_something(new_pos,area_id) then
        return
    end

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
    --select next waypoint based on Waypoint Type
    local next_waypoints = helpers.extract_numbered_properties(waypoint,"Next Waypoint ")
    local next_waypoint_id = nil
    if waypoint_type == "first" then
        next_waypoint_id = first_value_from_table(next_waypoints)
    end
    if waypoint_type == "random" then
        local next_waypoint_index = math.random(#next_waypoints)
        next_waypoint_id = next_waypoints[next_waypoint_index]
    end
    --date based events
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

function eznpcs.add_npcs_to_area(area_id)
    --Loop over all objects in area, spawning NPCs for each NPC type object.
    local objects = Net.list_objects(area_id)
    for i, object_id in next, objects do
        local object = ezcache.get_object_by_id_cached(area_id, object_id)
        if object.type == "NPC" then
            create_bot_from_object(area_id, object_id)
        end
    end
end

--Interface
--all of these must be used by entry script for this to function.
function eznpcs.load_npcs()
    --for each area, load NPCS
    local areas = Net.list_areas()
    for i, area_id in next, areas do
        --Add npcs to existing areas on startup
        eznpcs.add_npcs_to_area(area_id)
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
    return ( create_bot_from_object(area_id,object_id) )
end

function eznpcs.handle_actor_interaction(player_id,actor_id)
    return ( do_actor_interaction(player_id,actor_id) )
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
    return ( create_npc(area_id,asset_name,x,y,z,direction,bot_name,animation_name,mug_animation_name) )
end

function eznpcs.handle_player_transfer(player_id)
    clear_player_conversation(player_id)
end
  
function eznpcs.handle_player_disconnect(player_id)
    clear_player_conversation(player_id)
end

function eznpcs.handle_object_interaction(player_id, object_id)
    local area_id = Net.get_player_area(player_id)
    local relay_object = Net.get_object_by_id(area_id,object_id)
    if relay_object and relay_object.custom_properties["Interact Relay"] then
        local placeholder_id = relay_object.custom_properties["Interact Relay"]
        local bot_id = placeholder_to_botid[area_id][placeholder_id]
        do_actor_interaction(player_id,bot_id,relay_object)
    end
end

return eznpcs