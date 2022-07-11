local helpers = require('scripts/ezlibs-scripts/helpers')

local eztriggers = {}

eztriggers.interact_triggers = {}
eztriggers.radius_triggers = {}
eztriggers.rectangle_triggers = {}
eztriggers._event_table = {}

function eztriggers.add_location_event_trigger(area_id,object)
    local event_name = object.custom_properties["Event Name"]
    local emitter

    local trigger_name = "unnamed"
    if object.name and string.len(object.name) > 0 then
        trigger_name = object.name
    end

    print("[eztriggers] Configuring ("..trigger_name..") Location Trigger ↴")

    if object.data then
        local collision_shape_type = object.data.type
        if collision_shape_type == "ellipse" then
            emitter = eztriggers.add_radius_trigger(area_id, object, object.width, object.height, object.width/2,object.height/2)
        elseif collision_shape_type == "rect" then
            emitter = eztriggers.add_rectangle_trigger(area_id, object, object.width, object.height)
        else
            -- no satisfied condition
            warn("[eztriggers] No collision shape supported: "..collision_shape_type)
        end
    else
        warn("[eztriggers] Location trigger is missing collision data.")
    end
    
    if emitter then
        print("[eztriggers]"..object.data.type.." trigger added (width="..object.width..", height="..object.height..")")
        local extra_str = "."
        if event_name then
            --If the trigger had an event name, add a handler for activating that event
            emitter:on("entered",function (event_info)
                local event = eztriggers._event_table[event_name]
                if event then
                    local lock = helpers.get_lock(event_info.player_id, event_info.player_id..":"..event_name)
                    if lock then
                        event.action(event_info.player_id,event_info.object).and_then(function()
                            lock.release()
                        end)
                    end
                end
            end)
            print("[eztriggers] Successfully added Location Trigger "..trigger_name.." for event: "..event_name)
        else
            warn("[eztriggers] added Location Trigger "..trigger_name.." however no Event Name has been specifed")
        end
    end
end

function eztriggers.add_interact_trigger(area_id,trigger_object)
    if not trigger_object then
        return nil
    end
    if not eztriggers.interact_triggers[area_id] then
        eztriggers.interact_triggers[area_id] = {}
    end
    if not eztriggers.interact_triggers[area_id][trigger_object.id] then
        local emitter = Net.EventEmitter.new()
        eztriggers.interact_triggers[area_id][trigger_object.id] = {object=trigger_object,emitter=emitter}
        return emitter
    else
        warn("[eztriggers] "..trigger_object.id.." is already registered as a interact trigger")
    end
end

function eztriggers.add_radius_trigger(area_id,trigger_object,diameter_x,diameter_y,center_x,center_y,event_name)
    if not trigger_object then
        return nil
    end
    if not eztriggers.radius_triggers[area_id] then
        eztriggers.radius_triggers[area_id] = {}
    end
    if not eztriggers.radius_triggers[area_id][trigger_object.id] then
        local emitter = Net.EventEmitter.new()
        local trigger_info = {
            object=trigger_object,
            emitter=emitter,
            overlapping_players={},
            radius_x=diameter_x/2,
            radius_y=diameter_y/2,
            center_x=trigger_object.x+center_x,
            center_y=trigger_object.y+center_y
        }
        eztriggers.radius_triggers[area_id][trigger_object.id] = trigger_info
        return emitter
    else
        warn("[eztriggers] "..trigger_object.id.." is already registered as a ellipse trigger")
    end
end

function eztriggers.add_rectangle_trigger(area_id,trigger_object,width,height,event_name)
    if not trigger_object then
        return nil
    end
    if not eztriggers.rectangle_triggers[area_id] then
        eztriggers.rectangle_triggers[area_id] = {}
    end
    if not eztriggers.rectangle_triggers[area_id][trigger_object.id] then
        local emitter = Net.EventEmitter.new()
        local trigger_info = {
            object=trigger_object,
            emitter=emitter,
            overlapping_players={},
            width=tonumber(width),
            height=tonumber(height)
        }
        eztriggers.rectangle_triggers[area_id][trigger_object.id] = trigger_info
        return emitter
    else
        warn("[eztriggers] "..trigger_object.id.." is already registered as a rectangle trigger")
    end
end

function eztriggers.handle_object_interaction(player_id,object_id,button)
    --check interact triggers
    local player_area = Net.get_player_area(player_id)
    if not eztriggers.interact_triggers[player_area] then 
        return 
    end
    for trigger_id, trigger_info in pairs(eztriggers.interact_triggers[player_area]) do
        if object_id == trigger_id then
            trigger_info.emitter:emit("interaction",{player_id=player_id,object=trigger_info.object,button=button})
        end
    end
end


function eztriggers.handle_player_move(player_id, x, y, z)
    --check radius triggers
    local player_area_id = Net.get_player_area(player_id)
    local area_radius_triggers = eztriggers.radius_triggers[player_area_id]
    if area_radius_triggers ~= nil then
        for trigger_id, trigger_info in pairs(area_radius_triggers) do
            if trigger_info.object.z == z then
                local rad_x = trigger_info.radius_x
                local rad_y = trigger_info.radius_y
                local center_x = trigger_info.center_x
                local center_y = trigger_info.center_y

                if (rad_x == 0 or rad_y == 0) then
                    return
                end

                local axis_1 = ((x - center_x)*(x - center_x))/(rad_x*rad_x)
                local axis_2 = ((y - center_y)*(y - center_y))/(rad_y*rad_y)
                if (axis_1 + axis_2) <= 1.0 then
                    if not trigger_info.overlapping_players[player_id] then
                        trigger_info.emitter:emit("entered",{player_id=player_id,object=trigger_info.object})
                        trigger_info.overlapping_players[player_id] = true
                    end
                else
                    if trigger_info.overlapping_players[player_id] then
                        trigger_info.emitter:emit("departed",{player_id=player_id,object=trigger_info.object})
                        trigger_info.overlapping_players[player_id] = nil
                    end
                end
            end
        end
    end

    local area_rectangle_triggers = eztriggers.rectangle_triggers[player_area_id]
    if area_rectangle_triggers ~= nil then
        for trigger_id, trigger_info in pairs(area_rectangle_triggers) do
            if trigger_info.object.z == z then
                local obj_x = trigger_info.object.x
                local obj_y = trigger_info.object.y
                local obj_w = trigger_info.object.width
                local obj_h = trigger_info.object.height

                local inside_aabb = x >= obj_x
                    and y >= obj_y
                    and x <= obj_x + obj_w
                    and y <= obj_y + obj_h

                if inside_aabb then
                    if not trigger_info.overlapping_players[player_id] then
                        trigger_info.emitter:emit("entered",{player_id=player_id,object=trigger_info.object})
                        trigger_info.overlapping_players[player_id] = true
                    end
                else
                    if trigger_info.overlapping_players[player_id] then
                        trigger_info.emitter:emit("departed",{player_id=player_id,object=trigger_info.object})
                        trigger_info.overlapping_players[player_id] = nil
                    end
                end
            end
        end
    end
end

function eztriggers.add_event(event_object)
    if not (event_object.name and event_object.action) then
        warn('[eztriggers] Cant add invalid event, events need a name and action {}')
        return
    end

    local entry = eztriggers._event_table[event_object.name]

    if entry ~= nil then
        warn("[eztriggers] "..event_object.name.." is already registered as an event")
    else
        eztriggers._event_table[event_object.name] = event_object
    end
end

function eztriggers.clear_radius_overlaps_for_player(player_id)
    for area_id, area_triggers in pairs(eztriggers.radius_triggers) do
        for trigger_id, trigger_info in pairs(area_triggers) do
            if trigger_info.overlapping_players[player_id] then
                trigger_info.overlapping_players[player_id] = nil
            end
        end
    end
end

function eztriggers.clear_rectangle_overlaps_for_player(player_id)
    for area_id, area_triggers in pairs(eztriggers.rectangle_triggers) do
        for trigger_id, trigger_info in pairs(area_triggers) do
            if trigger_info.overlapping_players[player_id] then
                trigger_info.overlapping_players[player_id] = nil
            end
        end
    end
end

function eztriggers.handle_player_transfer(player_id)
    eztriggers.clear_radius_overlaps_for_player(player_id)
    eztriggers.clear_rectangle_overlaps_for_player(player_id)
end

function eztriggers.handle_player_disconnect(player_id)
    eztriggers.clear_radius_overlaps_for_player(player_id)
    eztriggers.clear_rectangle_overlaps_for_player(player_id)
end

-- Detect all warps across all rooms
local areas = Net.list_areas()
for i, area_id in next, areas do
    local area_name = Net.get_area_name(area_id)

    local objects = Net.list_objects(area_id)
    for i, object_id in next, objects do
        local object = Net.get_object_by_id(area_id, object_id)

        if object.type == "Location Trigger" then
            eztriggers.add_location_event_trigger(area_id,object)
        end
    end
end

print("[eztriggers] Loaded")
return eztriggers