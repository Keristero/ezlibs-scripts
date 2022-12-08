--for timed events
local json = require('scripts/ezlibs-scripts/json')
local create_arrow_animation = require('scripts/ezlibs-scripts/ezwarps/arrow_animation_factory')
local create_jack_in_out_animation = require('scripts/ezlibs-scripts/ezwarps/log_in_animation')
local eztriggers = require('scripts/ezlibs-scripts/eztriggers')

local ezwarps = {}

--arrival / leaving animations
local special_animations = {
    fall_in = require('scripts/ezlibs-scripts/ezwarps/fall_in_animation'),
    lev_beast_in = require('scripts/ezlibs-scripts/ezwarps/lev_beast_in_animation'),
    lev_beast_out = require('scripts/ezlibs-scripts/ezwarps/lev_beast_out_animation'),
    arrow_up_left_out = create_arrow_animation(false,"Up Left"),
    arrow_up_right_out = create_arrow_animation(false,"Up Right"),
    arrow_down_left_out = create_arrow_animation(false,"Down Left"),
    arrow_down_right_out = create_arrow_animation(false,"Down Right"),
    arrow_up_left_in = create_arrow_animation(true,"Up Left"),
    arrow_up_right_in = create_arrow_animation(true,"Up Right"),
    arrow_down_left_in = create_arrow_animation(true,"Down Left"),
    arrow_down_right_in = create_arrow_animation(true,"Down Right"),
    fall_off_2 = require('scripts/ezlibs-scripts/ezwarps/fall_off_2'),
    log_in = create_jack_in_out_animation(true),
    log_out = create_jack_in_out_animation(false)
}

local landings = {}
local player_animations = {}
local players_in_animations = {}
local warp_types_with_landings = {"Server Warp","Custom Warp","Interact Warp","Radius Warp"}

function table_has_value (table, val)
    for index, value in ipairs(table) do
        if value == val then
            return true
        end
    end
    return false
end

-- Logs the given message on screen --
function log(message)
   print('[ezwarps] '.. message)
end

function add_landing(area_id, incoming_data, x, y, z, direction, warp_in, arrival_animation)
    local new_landing = {
        area_id = area_id,
        warp_in = warp_in,
        x = x,
        y = y,
        z = z,
        pre_animation_x=x,
        pre_animation_y=y,
        pre_animation_z=z,
        direction = direction,
        arrival_animation = arrival_animation
    }
    landings[incoming_data] = new_landing

    log('added landing for '..incoming_data.." = "..json.encode(new_landing))
end

function doAnimationForWarp(player_id,animation_name,is_leave_animation,warp_object)
    return async(function()
        log('doing special animation '..animation_name)
        players_in_animations[player_id] = true
        if warp_object and warp_object.custom_properties["Dont Teleport"] == "true" then
            players_in_animations[player_id] = nil
        end
        Net.lock_player_input(player_id)
        local animation_properties = special_animations[animation_name]
        local animation_duration = 0
        if animation_properties then
            await(animation_properties.animate(player_id,warp_object))
            log('animation complete '..animation_name)
            player_animations[player_id] = nil
        end
        Net.unlock_player_input(player_id)
    end)
end

function add_interact_warp(object, object_id, area_id, area_name)
    log('adding interact warp... '..object_id)
    local interact_warp_emitter = eztriggers.add_interact_trigger(area_id,object)
    interact_warp_emitter:on("interaction",function(event)
        if not players_in_animations[event.player_id] then
            log('using interact warp')
            use_warp(event.player_id,object)
        end
    end)
    log('added interact warp '..object_id)
end

-- Adds the given radius warp to the list of detected radius warps
function add_radius_warp(object, object_id, area_id, area_name)
    local diameter = tonumber(object.custom_properties["Activation Radius"])*2
    log('adding radius warp '..object_id..", "..diameter)
    local radius_warp_emitter = eztriggers.add_radius_trigger(area_id,object,diameter,diameter,0,0)
    radius_warp_emitter:on("entered",function(event)
        if not players_in_animations[event.player_id] then
            log('using radius warp')
            use_warp(event.player_id,object)
        else
            log('player arrived in radius warp range')
            players_in_animations[event.player_id] = nil
        end
    end)
    log('added radius warp '..object_id)
end

-- Adds the given custom warp to the list of detected custom warps
function add_custom_warp(object, object_id, area_id, area_name) 
    local warp_is_valid = true
            
    log('adding custom warp with id ' .. object_id .. ' in ' .. area_name .. ' ... ')
    local target_object = nil
    local target_area = object.custom_properties["Target Area"]
    local dont_teleport = object.custom_properties["Dont Teleport"]
    if not dont_teleport and target_area then
        target_object = Net.get_object_by_id(target_area, object.custom_properties["Target Object"])                
        if target_object == nil then
            log('found warp in ' .. area_name .. ' with target area, but could not find target object')
            log('skipping current warp due to missing target object')
            warp_is_valid = false                    
        end
    end
end

-- Detect all warps across all rooms
local areas = Net.list_areas()
for i, area_id in next, areas do
    
    local area_name = Net.get_area_name(area_id)
    local objects = Net.list_objects(area_id)
    for i, object_id in next, objects do
        local object = Net.get_object_by_id(area_id, object_id)
        local arrival_animation = object.custom_properties["Arrival Animation"]

        if table_has_value(warp_types_with_landings,object.type) then
            --For inter server warps, add landings
            local incoming_data = object.custom_properties["Incoming Data"]
            if incoming_data then
                local direction = object.custom_properties.Direction or "Down"
                local warp_in = object.custom_properties["Warp In"] == "true"
                add_landing(area_id, incoming_data, object.x+0.5, object.y+0.5, object.z, direction, warp_in,arrival_animation)
            end
        end

        if object.type == "Radius Warp" then
            add_radius_warp(object, object_id, area_id, area_name)
        end

        if object.type == "Custom Warp" then
            add_custom_warp(object, object_id, area_id, area_name)   
        end

        if object.type == "Interact Warp" then
            add_interact_warp(object, object_id, area_id, area_name)
        end
    end
end

function prepare_player_arrival(player_id,x,y,z,special_animation_name)
    local entry_x = x
    local entry_y = y
    local entry_z = z
    if special_animation_name then
        if special_animations[special_animation_name] then
            local special_animation = special_animations[special_animation_name]
            player_animations[player_id] = special_animation_name
            entry_x = entry_x + special_animation.pre_animation_offsets.x
            entry_y = entry_y + special_animation.pre_animation_offsets.y
            entry_z = entry_z + special_animation.pre_animation_offsets.z
            log('[Landings] stored arrival animation '..special_animation_name..' to run when player joins')
        end
    end
    return {x=entry_x,y=entry_y,z=entry_z}
end

function ezwarps.handle_player_request(player_id, data)
    log('player '..player_id..' requested connection with data: '..data)
    if data == nil or data == "" then
        return
    end
    for key, l in next, landings do
        if data == key then
            local entry_pos = prepare_player_arrival(player_id,l["x"],l["y"],l["z"],l["arrival_animation"])
            Net.transfer_player(player_id, l["area_id"], l["warp_in"], entry_pos.x, entry_pos.y, entry_pos.z, l["direction"])
            log('transfering player to landing',data)
            return
        end
    end
    log('no landing for '..data)
end

--target_object=target_object,
--object=object,
--activation_radius=activation_radius,
--target_area=target_area,
--area_id=area_id

function use_warp(player_id,warp_object,warp_meta)
    return async(function()
        local warp_properties = warp_object.custom_properties
        local is_valid_warp = false
        local is_remote_warp = false

        if warp_properties.Address and warp_properties.Port then
            is_remote_warp = true
            is_valid_warp = true
        end

        local target_object_id = warp_object.custom_properties["Target Object"]
        local target_area = warp_object.custom_properties["Target Area"]

        if target_object_id ~= nil and target_area ~= nil then
            is_remote_warp = false
            is_valid_warp = true
        end

        if warp_object.custom_properties["Dont Teleport"] then
            is_valid_warp = true
        end

        if is_valid_warp == false then
            log('warp '..warp_object.id..' is invalid')
            return
        end

        local warp_out = warp_properties["Warp Out"] == "True"
        local warp_in = warp_properties["Warp In"] == "True"
        local data = warp_properties.Data
        if warp_properties["Leave Animation"] and warp_properties["Leave Animation"] ~= "" then
            await(doAnimationForWarp(player_id,warp_properties["Leave Animation"],true,warp_object))
        end
        if is_remote_warp then
            Net.transfer_server(player_id, warp_properties.Address, warp_properties.Port, warp_out, data)
        else
            local direction = "Down"
            local arrival_animation_name = nil
            local dont_teleport = warp_object.custom_properties["Dont Teleport"]
            if target_object_id and not dont_teleport then
                local target_object = Net.get_object_by_id(target_area,target_object_id)
                if target_object.custom_properties["Direction"] then
                    direction = target_object.custom_properties["Direction"]
                end
                arrival_animation_name = target_object.custom_properties["Arrival Animation"]
                if arrival_animation_name then
                    local entry_pos = prepare_player_arrival(player_id,target_object.x,target_object.y,target_object.z,arrival_animation_name)
                    Net.transfer_player(player_id, target_area, warp_in, entry_pos.x, entry_pos.y, entry_pos.z, direction)
                else
                    Net.transfer_player(player_id, target_area, true, target_object.x+0.5,target_object.y+0.5,target_object.z, direction)                    
                    print(player_id, target_area, true, target_object.x+0.5, target_object.y+0.5,target_object.z, direction)
                end
            else
                log('unable to transfer, no target object')
            end
        end
    end)
end

function ezwarps.handle_custom_warp(player_id, object_id)
    if ezwarps.player_is_in_animation(player_id) then
        return
    end
    local player_area = Net.get_player_area(player_id)
    local object = Net.get_object_by_id(player_area, object_id)
    if not object then
        return
    end
    local target_object = object.custom_properties["Target Object"]
    local target_area = object.custom_properties["Target Area"]
    if not (target_area and target_object) then
        return
    end
    use_warp(player_id,object)
end

function ezwarps.handle_player_join(player_id)
    if player_animations[player_id] then
        doAnimationForWarp(player_id,player_animations[player_id],false)
        player_animations[player_id] = nil
    end
end

function ezwarps.player_is_in_animation(player_id)
    if players_in_animations[player_id] then
        return true
    end
    return false
end

function ezwarps.handle_player_transfer(player_id)
    if player_animations[player_id] then
        doAnimationForWarp(player_id,player_animations[player_id])
    end
end

log('Loaded')

return ezwarps
