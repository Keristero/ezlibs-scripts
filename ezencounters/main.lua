local ezwarps = require('scripts/ezlibs-scripts/ezwarps/main')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local helpers = require('scripts/ezlibs-scripts/helpers')

local ezencounters = {}
local players_in_encounters = {}
local player_last_position = {}
local player_steps_since_encounter = {}

local fight_cache = {}
local fight_type = "Location Encounter"
local players_in_tile_encounters = {}
local hidden_fights_till_rejoin_per_player = {}

local load_encounters_for_areas = function ()
    local areas = Net.list_areas()
    local area_encounter_tables = {}
    for i, area_id in ipairs(areas) do
        local encounter_table_path = 'encounters/'..area_id
        local status, err = pcall(function () require(encounter_table_path) end)
        if status == true then
            area_encounter_tables[area_id] = require(encounter_table_path)
            for index, encounter_info in ipairs(area_encounter_tables[area_id].encounters) do
                print('[ezencounters] loading mob package '..encounter_info.path)
                Net.provide_asset(area_id, encounter_info.path)
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

function ezencounters.handle_player_join(player_id)
    --Reset the hidden tile encounters for the player
    hidden_fights_till_rejoin_per_player[player_id] = {}
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
    local area_id = Net.get_player_area(player_id)
    if not fight_cache[area_id] then return end
    if #fight_cache[area_id] > 0 then
        for f = 1, #fight_cache[area_id], 1 do
            local object = Net.get_object_by_id(area_id, fight_cache[area_id][f])
            local radius = tonumber(object.custom_properties["Encounter Radius"])
            if object ~= nil and object.z == player_last_position[player_id].z and radius ~= nil and hidden_fights_till_rejoin_per_player[player_id][area_id][tostring(object.id)] ~= true then
                local distance = math.sqrt((player_last_position[player_id].x - object.x) ^ 2 + (player_last_position[player_id].y - object.y) ^ 2)
                if distance < radius then
                    if not players_in_tile_encounters[player_id] then
                        Net.initiate_encounter(player_id, object.custom_properties["Encounter Path"])
                        players_in_tile_encounters[player_id] = true
                        if object.custom_properties["One Time Only"] == "true" then
                            local safe_secret = helpers.get_safe_player_secret(player_id)
                            local player_area_memory = ezmemory.get_player_area_memory(safe_secret,area_id)
                            player_area_memory.hidden_objects[tostring(object.id)] = true
                            ezmemory.save_player_memory(safe_secret)
                        else
                            hidden_fights_till_rejoin_per_player[player_id][area_id][tostring(object.id)] = true
                            Net.exclude_object_for_player(player_id, object.id)
                        end
                    end
                    player_steps_since_encounter[player_id] = 1
                end
            end
        end
    end
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

ezencounters.begin_encounter = function (player_id,encounter_info)
    print('beginning encounter for',player_id)
    Net.initiate_encounter(player_id, encounter_info.path,encounter_info)
    ezencounters.clear_tiles_since_encounter(player_id)
    players_in_encounters[player_id] = {encounter_info=encounter_info}
end

ezencounters.clear_tiles_since_encounter = function (player_id)
    player_steps_since_encounter[player_id] = nil
end

ezencounters.clear_last_position = function (player_id)
    print('[ezencounters] clearing last position')
    player_last_position[player_id] = nil
    ezencounters.clear_tiles_since_encounter(player_id)
    players_in_encounters[player_id] = nil
    if players_in_tile_encounters[player_id] then
        players_in_tile_encounters[player_id] = false
    end
end

ezencounters.handle_battle_results = function(player_id, stats)
    if players_in_encounters[player_id] then
        local player_encounter = players_in_encounters[player_id]
        if player_encounter.encounter_info.results_callback then
            player_encounter.encounter_info.results_callback(player_id,player_encounter.encounter_info,stats)
        end
        players_in_encounters[player_id] = nil
    end
    if players_in_tile_encounters[player_id] then
        players_in_tile_encounters[player_id] = false
    end
    -- stats = { health: number, score: number, time: number, ran: bool, emotion: number, turns: number, npcs: { id: String, health: number }[] }
end

function ezencounters.handle_player_transfer(player_id)
    --Set the player and area hidden fights as necessary.
    local area_id = Net.get_player_area(player_id)
    if hidden_fights_till_rejoin_per_player[player_id][area_id] then
        for object_id, is_hidden in pairs(hidden_fights_till_rejoin_per_player[player_id][area_id]) do
            Net.exclude_object_for_player(player_id, object_id)
        end
    else
        hidden_fights_till_rejoin_per_player[player_id][area_id] = {}
    end
    ezencounters.clear_last_position(player_id)
end

ezencounters.handle_player_disconnect = ezencounters.clear_last_position

local areas = Net.list_areas()
for i, area_id in next, areas do
  --filter and store an array of all fight objects on server start
  local objects = Net.list_objects(area_id)
  fight_cache[area_id] = {}
  for j, object_id in next, objects do
    local object = Net.get_object_by_id(area_id, object_id)
    if object.type == fight_type then
      table.insert(fight_cache[area_id], object_id)
    end
  end
end

return ezencounters