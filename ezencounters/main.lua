local ezwarps = require('scripts/ezlibs-scripts/ezwarps/main')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local helpers = require('scripts/ezlibs-scripts/helpers')
local eztriggers = require('scripts/ezlibs-scripts/eztriggers')

local ezencounters = {}
local players_in_encounters = {}
local player_last_position = {}
local player_steps_since_encounter = {}
local named_encounters = {}
local provided_encounter_assets = {}
local encounter_finished_callbacks = {}

local load_encounters_for_areas = function ()
    local areas = Net.list_areas()
    local area_encounter_tables = {}
    for i, area_id in ipairs(areas) do
        local encounter_table_path = 'encounters/'..area_id
        local status, err = pcall(function () require(encounter_table_path) end)
        if status == true then
            area_encounter_tables[area_id] = require(encounter_table_path)
            for index, encounter_info in ipairs(area_encounter_tables[area_id].encounters) do
                if not provided_encounter_assets[encounter_info.path] then
                    print('[ezencounters] providing mob package '..encounter_info.path)
                    Net.provide_asset(area_id, encounter_info.path)
                    provided_encounter_assets[encounter_info.path] = true
                end
                if encounter_info.name then
                    print('[ezencounters] loaded named encounter '..encounter_info.name)
                    named_encounters[encounter_info.name] = encounter_info
                end
            end
            print('[ezencounters] loaded encounter table for '..area_id)
        end
    end
    return area_encounter_tables
end

local area_encounter_tables = load_encounters_for_areas()

local function should_record_step(player_id)
    local player_area = Net.get_player_area(player_id)
    if not player_last_position[player_id] then
        return false
    end
    if Net.is_player_battling(player_id) then
        return false
    end
    if ezwarps.player_is_in_animation(player_id) then
        return false
    end
    local last_pos = player_last_position[player_id]
    local last_tile = Net.get_tile(player_area, last_pos.x, last_pos.y, last_pos.z) -- { gid, flipped_horizontally, flipped_vertically, rotated }
    local tile_tileset_info =  Net.get_tileset_for_tile(player_area, last_tile.gid) -- { path, first_gid }?
    if not tile_tileset_info then
        return false
    end
    if string.find(tile_tileset_info.path,'conveyer') then
        return false
    end
    return true
end

ezencounters.increment_steps_since_encounter = function (player_id)
    if not should_record_step(player_id) then
        return
    end
    local player_area = Net.get_player_area(player_id)
    local encounter_table = area_encounter_tables[player_area]
    if not player_steps_since_encounter[player_id] then
        player_steps_since_encounter[player_id] = 1
    else
        player_steps_since_encounter[player_id] = player_steps_since_encounter[player_id] + 1
    end
    if encounter_table then
        if player_steps_since_encounter[player_id] >= encounter_table.minimum_steps_before_encounter then
            ezencounters.try_random_encounter(player_id,encounter_table)
        end
    end
end

ezencounters.handle_player_move = function(player_id, x, y, z)
    local floor = math.floor
    local rounded_pos_x = floor(x)
    local rounded_pos_y = floor(y)
    local rounded_pos_z = floor(z)
    local last_tile = player_last_position[player_id]
    if last_tile then
        if last_tile.x ~= rounded_pos_x or last_tile.y ~= rounded_pos_y or last_tile.z ~= rounded_pos_z then
            --player has moved to a different tile
            player_last_position[player_id] = {x=rounded_pos_x,y=rounded_pos_y,z=rounded_pos_z}
        end
    else
        player_last_position[player_id] = {x=rounded_pos_x,y=rounded_pos_y,z=rounded_pos_z}
    end
    ezencounters.increment_steps_since_encounter(player_id)
end

ezencounters.pick_encounter_from_table = function (encounter_table)
    local total_weight = 0
    for _, option in ipairs(encounter_table.encounters) do
        total_weight = total_weight + option.weight
    end
    local crawler = math.random() * total_weight
    for i, option in ipairs(encounter_table.encounters) do
        crawler = crawler - option.weight
        if crawler <= 0 then
            return encounter_table.encounters[i]
        end
    end
    return encounter_table.encounters[1]
end

ezencounters.try_random_encounter = function (player_id,encounter_table)
    if math.random() <= encounter_table.encounter_chance_per_step then
        local encounter_info = ezencounters.pick_encounter_from_table(encounter_table)
        ezencounters.begin_encounter(player_id, encounter_info)
    end
end

ezencounters.begin_encounter_by_name = function(player_id,encounter_name,trigger_object)
    return async(function ()
        local encounter_info = named_encounters[encounter_name]
        if encounter_info then
            await(ezencounters.begin_encounter(player_id,encounter_info,trigger_object))
        else
            print('[ezencounters] no encounter with name ',encounter_name,' has been added to any encounter tables!')
        end
    end)
end

ezencounters.begin_encounter = function (player_id,encounter_info,trigger_object)
    return async(function ()
        --print('[ezencounters] beginning encounter for',player_id)
        players_in_encounters[player_id] = {encounter_info=encounter_info}
        ezencounters.clear_tiles_since_encounter(player_id)
        local stats = await(Async.initiate_encounter(player_id,encounter_info.path,encounter_info))
        return stats
    end)
end

ezencounters.clear_tiles_since_encounter = function (player_id)
    player_steps_since_encounter[player_id] = nil
end

ezencounters.clear_last_position = function (player_id)
    print('[ezencounters] clearing last position')
    player_last_position[player_id] = nil
    ezencounters.clear_tiles_since_encounter(player_id)
    players_in_encounters[player_id] = nil
end

Net:on("battle_results", function(event)
    local player_id = event.player_id
    if players_in_encounters[player_id] then
        local player_encounter = players_in_encounters[player_id]
        if encounter_finished_callbacks[player_id] then
            encounter_finished_callbacks[player_id](event)
            encounter_finished_callbacks[player_id] = nil
        end
        if player_encounter.encounter_info.results_callback then
            player_encounter.encounter_info.results_callback(player_id,player_encounter.encounter_info,event)
        end
        players_in_encounters[player_id] = nil
    end
    -- stats = { health: number, score: number, time: number, ran: bool, emotion: number, turns: number, npcs: { id: String, health: number }[] }
end)

ezencounters.handle_player_transfer = ezencounters.clear_last_position

ezencounters.handle_player_disconnect = function (player_id)
    encounter_finished_callbacks[player_id] = nil
    ezencounters.clear_last_position(player_id)
end

local function on_radius_encounter_triggered(event)
    return async(function ()
        print('[ezencounters] radius encounter triggered ',event.object.custom_properties)
        local player_area = Net.get_player_area(event.player_id)
        local is_hidden_already = ezmemory.object_is_hidden_from_player(event.player_id,player_area,event.object.id)
        if is_hidden_already then
            return
        end
        local encounter_name = event.object.custom_properties["Name"]
        local stats = false
        if encounter_name then
            stats = await(ezencounters.begin_encounter_by_name(event.player_id,encounter_name,event.object))
        else
            local encounter_info = {path=event.object.custom_properties["Path"]}
            stats = await(ezencounters.begin_encounter(event.player_id,encounter_info,event.object))
        end
        if stats then
            if stats.ran or stats.health == 0 then
                return stats -- dont hide the encounter if the player ran or lost
            end
            local player_area = Net.get_player_area(event.player_id)
            if event.object.custom_properties["Once"] == "true" then
                ezmemory.hide_object_from_player(event.player_id,player_area,event.object.id)
            end
        end
        ezmemory.hide_object_from_player_till_disconnect(event.player_id,player_area,event.object.id)
    end)
end

local areas = Net.list_areas()
for i, area_id in next, areas do
    --filter and store an array of all radius encounters
    local objects = Net.list_objects(area_id)
    for j, object_id in next, objects do
        local object = Net.get_object_by_id(area_id, object_id)
        if object.type == "Radius Encounter" then
            local radius = tonumber(object.custom_properties["Radius"] or 1)
            local emitter = eztriggers.add_radius_trigger(area_id,object,radius,radius,0,0)
            emitter:on('entered_radius',function(event)
                return on_radius_encounter_triggered(event)
            end)
        end
    end
end

return ezencounters