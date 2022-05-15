local Direction = require("scripts/ezlibs-scripts/direction")
local helpers = require('scripts/ezlibs-scripts/helpers')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local eznpcs_helpers = require('scripts/ezlibs-scripts/eznpcs/eznpcs_helpers')
local math = require('math')

local eznpcs = {}
local placeholder_to_botid = {}

local npc_asset_folder = '/server/assets/ezlibs-assets/eznpcs/'
local custom_events_script_path = 'scripts/events/eznpcs_events'
local custom_events_script_loaded = false
local generic_npc_mug_animation_path = npc_asset_folder..'mug/mug.animation'
local npcs = {}
local events = {}
local current_player_dialogue = {}
local npc_required_properties = {"Direction","Asset Name"}
local object_cache = {}
local cache_types = {"NPC","Waypoint","Dialogue"}

function printd(...)
    local arg={...}
    print('[eznpcs]',table.unpack(arg))
end

--TODO load all waypoints / dialogues on server start and delete them from the map to save bandwidth

function do_dialogue(npc,player_id,dialogue,relay_object)
    return async(function ()
        if current_player_dialogue[player_id] == dialogue.id then
            return --player is already in this dialogue, anti spam protection
        end
        current_player_dialogue[player_id] = dialogue.id
        local area_id = Net.get_player_area(player_id)
        local dialogue_type = dialogue.custom_properties["Dialogue Type"]
        local event_name = dialogue.custom_properties["Event Name"]
        local custom_mugshot = dialogue.custom_properties["Mugshot"]
        local should_be_cached = helpers.object_is_of_type(dialogue,cache_types)
        if not should_be_cached then
            print("[eznpcs] WARNING Dialogue "..dialogue.id.." at "..dialogue.x..","..dialogue.y.." in "..npc.area_id.." has incorrect type and wont be cached")
        end
        local mugshot_asset_name = npc.asset_name
        if custom_mugshot then
            mugshot_asset_name = custom_mugshot
        end
        local message = nil
        local next_dialogue_id = nil
        if event_name then
            if events[event_name] then
                local next_dialogue_info = events[event_name].action(npc,player_id,dialogue,relay_object)
                if next_dialogue_info then
                    if next_dialogue_info.id then
                        if not next_dialogue_info.wait_for_response then
                            local dialogue = helpers.get_object_by_id_cached(area_id,next_dialogue_info.id,object_cache,cache_types)
                            do_dialogue(npc,player_id,dialogue,relay_object)
                            return
                        end
                        next_dialogue_id = next_dialogue_info.id
                    end
                end
            else
                print("[eznpcs] event "..event_name.." was not found, are you sure you added it?")
            end
        end
        if dialogue_type == nil then
            return
        end
        local mug_texture_path = npc_asset_folder.."mug/"..mugshot_asset_name..".png"
        local mug_animation_path = npc.mug_animation_path
        if mugshot_asset_name == "player" then
            local player_mugshot = Net.get_player_mugshot(player_id)
            mug_texture_path = player_mugshot.texture_path
            mug_animation_path = player_mugshot.animation_path
        end
        local player_pos = Net.get_player_position(player_id)
    
        local dialogue_texts = eznpcs_helpers.extract_numbered_properties(dialogue,"Text ")
        local next_dialogues = eznpcs_helpers.extract_numbered_properties(dialogue,"Next ")
        
        if dialogue_type == "first" or  dialogue_type == "question" then
            message = dialogue_texts[1]
            local next_id = first_value_from_table(next_dialogues)
            next_dialogue_id = next_id
        end
    
        if dialogue_type == "random" then
            local rnd_text_index = math.random( #dialogue_texts)
            message = dialogue_texts[rnd_text_index]
            next_dialogue_id = next_dialogues[rnd_text_index] or next_dialogues[1]
        end
    
        if dialogue_type == "itemcheck" then
            local required_item = dialogue.custom_properties["Required Item"]
            if required_item ~= nil then
                local required_amount = dialogue.custom_properties["Required Amount"]
                if required_amount == nil then
                    required_amount = 1
                end
                local take_item = dialogue.custom_properties["Take Item"] == "true"
                if required_item == "money" then
                    if ezmemory.get_player_money(player_id) >= tonumber(required_amount) then
                        next_dialogue_id = next_dialogues[1]
                        if take_item then
                            ezmemory.spend_player_money(player_id,required_amount)
                        end
                    else
                        next_dialogue_id = next_dialogues[2]
                    end
                else
                    if ezmemory.count_player_item(player_id, required_item) >= tonumber(required_amount) then
                        next_dialogue_id = next_dialogues[1]
                        if take_item then
                            ezmemory.remove_player_item(player_id, required_item, required_amount)
                        end
                    else
                        next_dialogue_id = next_dialogues[2]
                    end
                end
            end
        end
    
        --date based events
        local date_b = dialogue.custom_properties['Date']
        if dialogue_type == "before" then
            if date_b then
                message = dialogue_texts[2]
                next_dialogue_id = next_dialogues[2]
                if eznpcs_helpers.is_now_before_date(date_b) then
                    message = dialogue_texts[1]
                    next_dialogue_id = next_dialogues[1]
                end
            end
        end
        if dialogue_type == "after" then
            if date_b then
                message = dialogue_texts[2]
                next_dialogue_id = next_dialogues[2]
                if not eznpcs_helpers.is_now_before_date(date_b) then
                    message = dialogue_texts[1]
                    next_dialogue_id = next_dialogues[1]
                end
            end
        end
        if not npc.dont_face_player then
            Net.set_bot_direction(npc.bot_id, Direction.from_points(npc, player_pos))
        end
    
        if message == nil and next_dialogue_id ~= nil then
            --If we know what dialogue is next but we have no message to send
            --Do the next dialogue now
            local area_id = Net.get_player_area(player_id)
            local dialogue = helpers.get_object_by_id_cached(area_id,next_dialogue_id,object_cache,cache_types)
            do_dialogue(npc,player_id,dialogue,relay_object)
            return
        end
            
        local response = nil
        if dialogue_type ~= "none" then
            if dialogue_type == "question" then
                response = Async.await(Async.question_player(player_id, message, mug_texture_path, mug_animation_path))
            else
                response = Async.await(Async.message_player(player_id, message, mug_texture_path, mug_animation_path))
            end
        end
    
        end_conversation(player_id)
        if dialogue_type == "question" then
            local next_index = 2
            if response == 1 then
                next_index = 1
            end
            next_dialogue_id = next_dialogues[next_index]
        end
        if next_dialogue_id then
            local area_id = Net.get_player_area(player_id)
            local dialogue = helpers.get_object_by_id_cached(area_id,next_dialogue_id,object_cache,cache_types)
            do_dialogue(npc,player_id,dialogue,relay_object)
        else
            Net.set_bot_direction(npc.bot_id, npc.direction)
        end
    end)
end

function create_bot_from_object(area_id,object_id)
    local placeholder_object = helpers.get_object_by_id_cached(area_id, object_id,object_cache,cache_types)
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
    placeholder_to_botid[tostring(object_id)] = npc.bot_id
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
        printd('added '..behaviour.type..' behaviour to NPC')
    end
end

--Behaviour factories
function chat_behaviour()
    behaviour = {
        type='on_interact',
        action=function(npc,player_id,relay_object)
            local dialogue = npc.first_dialogue
            do_dialogue(npc,player_id,dialogue,relay_object)
        end
    }
    return behaviour
end

function end_conversation(player_id)
    current_player_dialogue[player_id] = nil
end

function waypoint_follow_behaviour(first_waypoint_id)
    behaviour = {
        type='on_tick',
        initialize=function(npc)
            local first_waypoint = helpers.get_object_by_id_cached(npc.area_id, first_waypoint_id,object_cache,cache_types)
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
    --TODO fix this function
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

    if eznpcs_helpers.position_overlaps_something(new_pos,area_id) then
        return
    end

    Net.move_bot(npc.bot_id, new_pos.x, new_pos.y, new_pos.z)
    npc.x = new_pos.x
    npc.y = new_pos.y

end

function on_npc_reached_waypoint(npc,waypoint)
    local should_be_cached = helpers.object_is_of_type(waypoint,cache_types)
    if not should_be_cached then
        print("[eznpcs] WARNING Waypoint "..waypoint.id.." at "..waypoint.x..","..waypoint.y.." in "..npc.area_id.." has incorrect type and wont be cached")
    end
    if waypoint.custom_properties['Wait Time'] ~= nil then
        npc.wait_time = tonumber(waypoint.custom_properties['Wait Time'])
        if waypoint.custom_properties['Direction'] ~= nil then
            Net.set_bot_direction(npc.bot_id, waypoint.custom_properties['Direction'])
        end
    end
    local waypoint_type = "first"
    if waypoint.custom_properties["Waypoint Type"] then
        waypoint_type = waypoint.custom_properties["Waypoint Type"]
    end
    --select next waypoint based on Waypoint Type
    local next_waypoints = eznpcs_helpers.extract_numbered_properties(waypoint,"Next Waypoint ")
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
            if eznpcs_helpers.is_now_before_date(date_b) then
                next_waypoint_id = next_waypoints[1]
            end
        end
    end
    if waypoint_type == "after" then
        if date_b then
            next_waypoint_id = next_waypoints[2]
            if not eznpcs_helpers.is_now_before_date(date_b) then
                next_waypoint_id = next_waypoints[1]
            end
        end
    end

    if next_waypoint_id then
        npc.next_waypoint = helpers.get_object_by_id_cached(npc.area_id,next_waypoint_id,object_cache,cache_types)
    end
end

function add_npcs_to_area(area_id)
    --Loop over all objects in area, spawning NPCs for each NPC type object.
    local objects = Net.list_objects(area_id)
    for i, object_id in next, objects do
        local object = helpers.get_object_by_id_cached(area_id, object_id,object_cache,cache_types)
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
        add_npcs_to_area(area_id)
    end
end

function eznpcs.add_event(event_object)
    if event_object.name and event_object.action then
        if events[event_object.name] then
            printd('WARNING event '..event_object.name..' already exists and will be replaced')
        end
        events[event_object.name] = event_object
        printd('added event '..event_object.name)
    else
        printd('Cant add invalid event, events need a name and action {}')
    end
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
    end_conversation(player_id)
end
  
function eznpcs.handle_player_disconnect(player_id)
    end_conversation(player_id)
end

function eznpcs.handle_object_interaction(player_id, object_id)
    local area_id = Net.get_player_area(player_id)
    local relay_object = Net.get_object_by_id(area_id,object_id)
    if relay_object.custom_properties["Interact Relay"] then
        local placeholder_id = relay_object.custom_properties["Interact Relay"]
        local bot_id = placeholder_to_botid[placeholder_id]
        do_actor_interaction(player_id,bot_id,relay_object)
    end
end

return eznpcs