local ezwarps = require('scripts/ezlibs-scripts/ezwarps/main')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local helpers = require('scripts/ezlibs-scripts/helpers')
local eztriggers = require('scripts/ezlibs-scripts/eztriggers')
local object_registry = require('scripts/ezlibs-scripts/object_registry')
local ezbus = require('scripts/ezlibs-scripts/ezbus')
local ezconfig = require('scripts/ezlibs-scripts/ezconfig')

local ezencounters = {}
local players_in_encounters = {}
local player_last_position = {}
local player_steps_since_encounter = {}
local named_encounters = {}
local provided_encounter_assets = {}
local encounter_finished_callbacks = {}

-- Ensure encounters directory exists
helpers.ensure_directory(ezconfig.ENCOUNTERS_PATH)

local load_battle_rewards = function ()
    local rewards_path = ezconfig.ENCOUNTERS_PATH .. 'rewards'
    local status, rewards = pcall(function () return require(rewards_path) end)
    if status and type(rewards) == 'table' then
        print('[ezencounters] loaded battle rewards')
        return rewards
    end
    return nil
end

local battle_rewards = load_battle_rewards()

local battle_reward_types = {
    money = 0,
    hp = 2,
    bugfrags = 3,
}

local get_reward_tier = function (score)
    score = tonumber(score) or 0
    if score >= 9 then
        return 'high'
    end
    if score >= 5 then
        return 'mid'
    end
    return 'low'
end

local get_enemy_reward_table = function (enemy)
    if not battle_rewards or not enemy then
        return nil
    end
    local enemy_rewards = battle_rewards[enemy.name]
    if type(enemy_rewards) ~= 'table' then
        return nil
    end
    return enemy_rewards[enemy.rank] or enemy_rewards[tostring(enemy.rank)]
end

local pick_reward_table = function (encounter_info)
    local candidates = {}
    for _, enemy in ipairs((encounter_info and encounter_info.enemies) or {}) do
        local reward_table = get_enemy_reward_table(enemy)
        if type(reward_table) == 'table' then
            candidates[#candidates + 1] = reward_table
        end
    end
    if #candidates == 0 then
        return nil
    end
    return candidates[math.random(#candidates)]
end

local copy_reward = function (reward)
    local copy = {}
    for key, value in pairs(reward or {}) do
        copy[key] = value
    end
    return copy
end

local get_battle_reward = function (player_id, encounter_info, stats, persistent_health)
    if not battle_rewards or not stats or stats.reason ~= 1 then
        return nil
    end

    local reward_table = pick_reward_table(encounter_info)
    if not reward_table then
        return nil
    end

    local health = tonumber(stats.health) or 0
    local max_health = tonumber(Net.get_player_max_health(player_id)) or 0
    local recovery = reward_table.low_hp_recovery

    if persistent_health and type(recovery) == 'table' and max_health > 0 then
        local threshold = tonumber(recovery.threshold) or 0.375
        local value = math.floor(tonumber(recovery.value) or 0)
        if value > 0 and health < max_health * threshold then
            return {
                type = 'hp',
                value = value,
            }
        end
    end

    local tier = get_reward_tier(stats.score)
    local reward = reward_table[tier]
    if type(reward) ~= 'table' then
        return nil
    end
    if reward.type == 'hp' and not persistent_health then
        return nil
    end

    return copy_reward(reward)
end

local normalize_battle_rewards = function (player_id, rewards, stats, persistent_health)
    local native_rewards = {}
    local money = 0
    local bugfrags = 0
    local recovery = 0
    local health = math.floor(tonumber(stats and stats.health) or 0)
    local max_health = tonumber(Net.get_player_max_health(player_id)) or health
    local missing_health = math.max(0, max_health - health)

    for _, reward in ipairs(rewards or {}) do
        if type(reward) == 'table' then
            local reward_type = reward.type
            local native_type = battle_reward_types[reward_type]

            if reward_type == 'chip' then
                native_type = 1
            elseif type(reward_type) == 'number' then
                native_type = reward_type
            end

            if native_type == 1 and reward.card_id then
                native_rewards[#native_rewards + 1] = {
                    type = 1,
                    card_id = reward.card_id,
                    code = reward.code or '*',
                }
            elseif native_type == battle_reward_types.money then
                local value = math.floor(tonumber(reward.value) or 0)
                if value > 0 then
                    native_rewards[#native_rewards + 1] = {type=native_type,value=value}
                    money = money + value
                end
            elseif native_type == battle_reward_types.bugfrags then
                local value = math.floor(tonumber(reward.value) or 0)
                if value > 0 then
                    native_rewards[#native_rewards + 1] = {type=native_type,value=value}
                    bugfrags = bugfrags + value
                end
            elseif native_type == battle_reward_types.hp and persistent_health then
                local value = math.floor(tonumber(reward.value) or 0)
                value = math.min(value, missing_health)
                if value > 0 then
                    native_rewards[#native_rewards + 1] = {type=native_type,value=value}
                    recovery = recovery + value
                    missing_health = missing_health - value
                end
            end
        end
    end

    return native_rewards, money, bugfrags, recovery
end

local send_battle_rewards = function (player_id, rewards, stats, persistent_health)
    local native_rewards, money, bugfrags, recovery = normalize_battle_rewards(
        player_id,
        rewards,
        stats,
        persistent_health
    )

    local current_money = nil
    if money > 0 then
        current_money = ezmemory.get_player_money(player_id)
    end

    local current_fragments = nil
    if bugfrags > 0 then
        current_fragments = ezmemory.get_player_fragments(player_id)
    end

    if #native_rewards > 0 then
        Net.send_player_battle_rewards(player_id, native_rewards)
    end

    if current_money ~= nil then
        ezmemory.set_player_money(player_id, current_money + money)
    end

    if current_fragments ~= nil then
        ezmemory.set_player_fragments(player_id, current_fragments + bugfrags)
    end

    return recovery
end

local persist_battle_health = function (player_id, stats, recovery)
    local health = math.floor(tonumber(stats and stats.health) or 0)
    local max_health = tonumber(Net.get_player_max_health(player_id)) or health

    health = health + math.max(0, math.floor(tonumber(recovery) or 0))

    health = math.min(health, max_health)
    ezmemory.set_player_health(player_id, health)
end

local load_encounters_for_areas = function ()
    local areas = Net.list_areas()
    local area_encounter_tables = {}
    for i, area_id in ipairs(areas) do
        local encounter_table_path = ezconfig.ENCOUNTERS_PATH .. area_id
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

-- FIXED: Now returns the stats
ezencounters.begin_encounter_by_name = function(player_id,encounter_name,trigger_object)
    return async(function ()
        local encounter_info = named_encounters[encounter_name]
        if encounter_info then
            local stats = await(ezencounters.begin_encounter(player_id,encounter_info,trigger_object))
            return stats
        else
            print('[ezencounters] no encounter with name ',encounter_name,' has been added to any encounter tables!')
            return nil
        end
    end)
end

ezencounters.begin_encounter = function (player_id,encounter_info,trigger_object)
    return async(function ()
        --print('[ezencounters] beginning encounter for',player_id)
        local player_area = Net.get_player_area(player_id)
        local encounter_table = area_encounter_tables[player_area]
        players_in_encounters[player_id] = {
            encounter_info=encounter_info,
            persistent_health=encounter_table and encounter_table.persistent_health == true
        }
        ezencounters.clear_tiles_since_encounter(player_id)
        ezbus:emit("encounter_started", {
            player_id = player_id,
            encounter_info = encounter_info,
            trigger_object = trigger_object
        })
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
        local rewards = {}
        local reward = get_battle_reward(player_id, player_encounter.encounter_info, event, player_encounter.persistent_health)
        if reward then
            rewards[#rewards + 1] = reward
        end
        if player_encounter.encounter_info.results_callback then
            player_encounter.encounter_info.results_callback(player_id,player_encounter.encounter_info,event,rewards)
        end
        local recovery = send_battle_rewards(player_id, rewards, event, player_encounter.persistent_health)
        if player_encounter.persistent_health then
            persist_battle_health(player_id, event, recovery)
        end
        players_in_encounters[player_id] = nil
    end
    -- stats = { health: number, score: number, time: number, reason: number, emotion: number, turns: number, enemies: { id: String, health: number }[] }
    ezbus:emit("encounter_finished", {
        player_id = player_id,
        stats = {
            health = event.health,
            time = event.time,
            reason = event.reason,
            emotion = event.emotion,
            turns = event.turns,
            enemies = event.enemies,
            score = event.score
        }
    })
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
            if stats.reason ~= 1 then
                return stats -- dont hide the encounter if the player ran, lost, or used dev escape
            end
            local player_area = Net.get_player_area(event.player_id)
            if event.object.custom_properties["Once"] == "true" then
                ezmemory.hide_object_from_player(event.player_id,player_area,event.object.id)
            end
        end
        ezmemory.hide_object_from_player_till_disconnect(event.player_id,player_area,event.object.id)
    end)
end

-- Register handler for Radius Encounter objects
object_registry.register_handler("Radius Encounter", function(area_id, object)
    local radius = tonumber(object.custom_properties["Radius"] or 1)
    local emitter = eztriggers.add_radius_trigger(area_id, object, radius, radius, 0, 0)
    emitter:on('entered', function(event)
        return on_radius_encounter_triggered(event)
    end)
end)

return ezencounters
