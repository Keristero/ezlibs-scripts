local eztriggers = {}

eztriggers.interact_triggers = {}
eztriggers.radius_triggers = {}

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
        warn(trigger_object.id.." is already registered as a interact trigger")
    end
end

function eztriggers.add_radius_trigger(area_id,trigger_object,radius)
    if not trigger_object then
        return nil
    end
    if not eztriggers.radius_triggers[area_id] then
        eztriggers.radius_triggers[area_id] = {}
    end
    if not eztriggers.radius_triggers[area_id][trigger_object.id] then
        local emitter = Net.EventEmitter.new()
        eztriggers.radius_triggers[area_id][trigger_object.id] = {object=trigger_object,emitter=emitter,overlapping_players={},radius=tonumber(radius)}
        return emitter
    else
        warn(trigger_object.id.." is already registered as a radius trigger")
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
    local player_area = Net.get_player_area(player_id)
    if not eztriggers.radius_triggers[player_area] then 
        return 
    end
    for trigger_id, trigger_info in pairs(eztriggers.radius_triggers[player_area]) do
        if trigger_info.object.z == z then
            local radius = trigger_info.radius
            local distance = math.sqrt((x - trigger_info.object.x) ^ 2 + (y - trigger_info.object.y) ^ 2)

            if distance < radius then
                if not trigger_info.overlapping_players[player_id] then
                    trigger_info.emitter:emit("entered_radius",{player_id=player_id,object=trigger_info.object})
                    trigger_info.overlapping_players[player_id] = true
                end
            else
                if trigger_info.overlapping_players[player_id] then
                    trigger_info.emitter:emit("departed_radius",{player_id=player_id,object=trigger_info.object})
                    trigger_info.overlapping_players[player_id] = nil
                end
            end
        end
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

function eztriggers.handle_player_transfer(player_id)
    eztriggers.clear_radius_overlaps_for_player(player_id)
end

function eztriggers.handle_player_disconnect(player_id)
    eztriggers.clear_radius_overlaps_for_player(player_id)
end

return eztriggers