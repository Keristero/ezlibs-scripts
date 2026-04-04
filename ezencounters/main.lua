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
local area_encounter_tables = {}

local DEFAULT_RANDOM_PLAYER_POSITIONS = {
    {0,0,0,0,0,0},
    {0,1,0,0,0,0},
    {0,0,0,0,0,0},
}

local DEFAULT_RANDOM_TILES = {
    {1,1,1,1,1,1},
    {1,1,1,1,1,1},
    {1,1,1,1,1,1},
}

local DEFAULT_RANDOM_TEAMS = {
    {2,2,2,1,1,1},
    {2,2,2,1,1,1},
    {2,2,2,1,1,1},
}

local DEFAULT_RANDOM_ENEMY_CELLS = {
    {x=4,y=1},{x=5,y=1},{x=6,y=1},
    {x=4,y=2},{x=5,y=2},{x=6,y=2},
    {x=4,y=3},{x=5,y=3},{x=6,y=3},
}

local DEFAULT_RANDOM_ALL_CELLS = {
    {x=1,y=1},{x=2,y=1},{x=3,y=1},{x=4,y=1},{x=5,y=1},{x=6,y=1},
    {x=1,y=2},{x=2,y=2},{x=3,y=2},{x=4,y=2},{x=5,y=2},{x=6,y=2},
    {x=1,y=3},{x=2,y=3},{x=3,y=3},{x=4,y=3},{x=5,y=3},{x=6,y=3},
}

local DEFAULT_RANDOM_OBSTACLE_POOL = {
    "Rock",
    "RockCube",
    "Coffin",
    "BlastCube",
    "IceCube",
}

-- 2=cracked, 9=grass, 11=holy, 12=ice, 13=lava, 14=poison
local DEFAULT_RANDOM_PANEL_POOL = { 2, 9, 11, 12, 13, 14 }

local function _copy_grid(grid)
    local out = {}
    for y, row in ipairs(grid or {}) do
        out[y] = {}
        for x, value in ipairs(row) do
            out[y][x] = value
        end
    end
    return out
end

local function _blank_positions_grid()
    return {
        {0,0,0,0,0,0},
        {0,0,0,0,0,0},
        {0,0,0,0,0,0},
    }
end

local function _cell_key(x, y)
    return tostring(x) .. "," .. tostring(y)
end

local function _shuffle_in_place(arr)
    for i = #arr, 2, -1 do
        local j = math.random(i)
        arr[i], arr[j] = arr[j], arr[i]
    end
    return arr
end

local function _pick_distinct(pool, count)
    local temp = {}
    for i, value in ipairs(pool or {}) do
        temp[i] = value
    end
    _shuffle_in_place(temp)

    local out = {}
    for i = 1, math.min(count or 0, #temp) do
        out[#out + 1] = temp[i]
    end
    return out
end

local function _pick_weighted_key(weight_table, fallback_key)
    local total = 0
    for _, weight in pairs(weight_table or {}) do
        weight = tonumber(weight) or 0
        if weight > 0 then
            total = total + weight
        end
    end

    if total <= 0 then
        return fallback_key
    end

    local crawler = math.random() * total
    for key, weight in pairs(weight_table) do
        weight = tonumber(weight) or 0
        if weight > 0 then
            crawler = crawler - weight
            if crawler <= 0 then
                return key
            end
        end
    end

    return fallback_key
end

local function _result_flags(stats)
    local reason = tonumber(stats and stats.reason or 0) or 0
    local hp = tonumber(stats and (stats.health or stats.player_hp or stats.hp) or 0) or 0

    local ran = false
    local dev_escape = false
    local won = false
    local lost = false

    if reason == 1 then
        won = true
    elseif reason == 2 then
        lost = true
    elseif reason == 3 then
        ran = true
    elseif reason == 4 then
        ran = true
        dev_escape = true
    else
        ran = stats and (stats.ran or stats.fled or stats.escape) or false
        if not ran then
            if hp > 0 then
                won = true
            else
                lost = true
            end
        end
    end

    return {
        reason = reason,
        hp = hp,
        ran = ran,
        dev_escape = dev_escape,
        won = won,
        lost = lost,
    }
end

local function _send_rewards_and_fixup_wallet(player_id, rewards)
    if not rewards or #rewards == 0 then
        return
    end

    local expected_money = 0
    for _, reward in ipairs(rewards) do
        if reward and reward.type == 0 then
            expected_money = expected_money + (tonumber(reward.value) or 0)
        end
    end

    local money_before = nil
    if expected_money > 0 and Net.get_player_money then
        money_before = tonumber(Net.get_player_money(player_id) or 0) or 0
    end

    Net.send_player_battle_rewards(player_id, rewards)

    if expected_money > 0 and money_before ~= nil then
        local money_after = tonumber(Net.get_player_money(player_id) or 0) or 0
        if money_after < (money_before + expected_money) then
            pcall(ezmemory.spend_player_money, player_id, -expected_money)
        elseif ezmemory.get_player_money then
            pcall(ezmemory.get_player_money, player_id)
        end
    end
end

local function _persist_health_and_emotion(player_id, stats)
    local emotion = tonumber(stats and stats.emotion or 0) or 0
    local health = tonumber(stats and stats.health or 0) or 0

    if emotion == 1 then
        Net.set_player_emotion(player_id, emotion)
    else
        Net.set_player_emotion(player_id, 0)
    end

    if ezmemory and ezmemory.set_player_health then
        ezmemory.set_player_health(player_id, health)
    end
end

local function _apply_area_result_awards(player_id, area_table, encounter_info, stats)
    local rewards_cfg = area_table and area_table.rewards
    if not rewards_cfg then
        return false
    end

    if rewards_cfg.enabled == false then
        _persist_health_and_emotion(player_id, stats)
        return true
    end

    local flags = _result_flags(stats)

    if not flags.won then
        _persist_health_and_emotion(player_id, stats)
        return true
    end

    local rewards = {}
    local score = tonumber(stats and stats.score or 0) or 0
    local hp = tonumber(stats and stats.health or 0) or 0
    local hp_bonus = 0

    local money_cfg = rewards_cfg.money
    if money_cfg and money_cfg.enabled ~= false then
        local multiplier = tonumber(money_cfg.score_multiplier or money_cfg.multiplier or money_cfg.per_score or 0) or 0
        local money_amount = math.floor(score * multiplier)
        if money_amount > 0 then
            rewards[#rewards + 1] = { type = 0, value = money_amount }
        end
    end

    local health_cfg = rewards_cfg.health
    if health_cfg and health_cfg.enabled ~= false then
        local threshold = tonumber(health_cfg.threshold or health_cfg.if_hp_below or 0) or 0
        local amount = tonumber(health_cfg.amount or health_cfg.give or 0) or 0
        if amount > 0 and hp <= threshold then
            hp_bonus = amount
            rewards[#rewards + 1] = { type = 2, value = amount }
        end
    end

    if #rewards > 0 then
        _send_rewards_and_fixup_wallet(player_id, rewards)
    end

    _persist_health_and_emotion(player_id, {
        health = hp + hp_bonus,
        emotion = stats and stats.emotion or 0
    })

    return true
end

local function _normalize_random_unit(unit_def)
    if type(unit_def) == "string" then
        return {
            name = unit_def,
            ranks = { "1" }
        }
    end

    if type(unit_def) ~= "table" then
        return nil
    end

    local name = unit_def.name or unit_def.alias
    if not name then
        return nil
    end

    local ranks = unit_def.ranks or unit_def.supported_ranks or unit_def.rank or { "1" }
    if type(ranks) ~= "table" then
        ranks = { ranks }
    end

    local normalized_ranks = {}
    for i, rank_token in ipairs(ranks) do
        normalized_ranks[i] = tostring(rank_token)
    end

    if #normalized_ranks == 0 then
        normalized_ranks[1] = "1"
    end

    return {
        name = name,
        ranks = normalized_ranks,
    }
end

local function _get_random_encounter_config(area_table)
    local cfg = area_table and area_table.random_encounters
    if not cfg or cfg.enabled ~= true then
        return nil
    end
    if not cfg.pool or #cfg.pool == 0 then
        return nil
    end
    return cfg
end

local function _get_random_package_path(area_table, cfg, is_boss)
    if is_boss and cfg and cfg.bosses and cfg.bosses.package_path then
        return cfg.bosses.package_path
    end
    if cfg and cfg.package_path then
        return cfg.package_path
    end
    if area_table and area_table.encounters and area_table.encounters[1] then
        return area_table.encounters[1].path
    end
    return nil
end

local function _pick_random_rank_token(unit_def)
    local ranks = unit_def.ranks or { "1" }
    return tostring(ranks[math.random(#ranks)] or "1")
end

local function _pick_random_units(pool, count, allow_duplicates)
    local normalized_pool = {}
    for _, unit_def in ipairs(pool or {}) do
        local normalized = _normalize_random_unit(unit_def)
        if normalized then
            normalized_pool[#normalized_pool + 1] = normalized
        end
    end

    if #normalized_pool == 0 then
        return {}
    end

    if allow_duplicates then
        local out = {}
        for i = 1, count do
            out[#out + 1] = normalized_pool[math.random(#normalized_pool)]
        end
        return out
    end

    return _pick_distinct(normalized_pool, count)
end

local function _build_enemy_positions(enemy_count, is_boss)
    local positions = _blank_positions_grid()
    local occupied = {}

    if is_boss then
        positions[2][5] = 1
        occupied[_cell_key(5, 2)] = true
        return positions, occupied
    end

    local chosen_cells = _pick_distinct(DEFAULT_RANDOM_ENEMY_CELLS, enemy_count)
    for index, cell in ipairs(chosen_cells) do
        positions[cell.y][cell.x] = index
        occupied[_cell_key(cell.x, cell.y)] = true
    end

    return positions, occupied
end

local function _get_blocked_player_cells(player_positions)
    local blocked = {}
    for y, row in ipairs(player_positions or {}) do
        for x, value in ipairs(row) do
            if tonumber(value) and tonumber(value) > 0 then
                blocked[_cell_key(x, y)] = true
            end
        end
    end
    return blocked
end

local function _build_random_obstacles(cfg, occupied, player_positions)
    local obstacle_cfg = cfg and cfg.obstacles or {}
    local obstacle_positions = _blank_positions_grid()
    local obstacles = {}

    if obstacle_cfg.enabled ~= true then
        return obstacles, obstacle_positions
    end

    local obstacle_pool = obstacle_cfg.pool or DEFAULT_RANDOM_OBSTACLE_POOL
    if #obstacle_pool == 0 then
        return obstacles, obstacle_positions
    end

    local chance = tonumber(obstacle_cfg.chance or 0.20) or 0.20
    if math.random() >= chance then
        return obstacles, obstacle_positions
    end

    local count_min = math.floor(tonumber(obstacle_cfg.count_min or obstacle_cfg.min or 1) or 1)
    local count_max = math.floor(tonumber(obstacle_cfg.count_max or obstacle_cfg.max or 2) or 2)

    if count_min < 1 then count_min = 1 end
    if count_max < count_min then count_max = count_min end

    local blocked = {}
    for key, value in pairs(occupied or {}) do
        blocked[key] = value
    end
    for key, value in pairs(_get_blocked_player_cells(player_positions)) do
        blocked[key] = value
    end

    local free_cells = {}
    for _, cell in ipairs(DEFAULT_RANDOM_ALL_CELLS) do
        if not blocked[_cell_key(cell.x, cell.y)] then
            free_cells[#free_cells + 1] = cell
        end
    end

    if #free_cells == 0 then
        return obstacles, obstacle_positions
    end

    local obstacle_count = math.random(count_min, count_max)
    obstacle_count = math.min(obstacle_count, #free_cells)

    local chosen_cells = _pick_distinct(free_cells, obstacle_count)
    for index, cell in ipairs(chosen_cells) do
        obstacles[index] = {
            name = obstacle_pool[math.random(#obstacle_pool)]
        }
        obstacle_positions[cell.y][cell.x] = index
    end

    return obstacles, obstacle_positions
end

local function _build_random_tiles(cfg)
    local panel_cfg = cfg and cfg.panels or {}
    local tiles = _copy_grid((cfg and cfg.base_tiles) or DEFAULT_RANDOM_TILES)

    if panel_cfg.enabled ~= true then
        return tiles
    end

    local panel_pool = panel_cfg.pool or DEFAULT_RANDOM_PANEL_POOL
    if #panel_pool == 0 then
        return tiles
    end

    local chance = tonumber(panel_cfg.chance or 0.15) or 0.15
    if math.random() >= chance then
        return tiles
    end

    local count_min = math.floor(tonumber(panel_cfg.count_min or panel_cfg.min or 1) or 1)
    local count_max = math.floor(tonumber(panel_cfg.count_max or panel_cfg.max or 2) or 2)

    if count_min < 1 then count_min = 1 end
    if count_max < count_min then count_max = count_min end

    local count = math.random(count_min, count_max)
    local chosen_cells = _pick_distinct(DEFAULT_RANDOM_ALL_CELLS, count)

    for _, cell in ipairs(chosen_cells) do
        tiles[cell.y][cell.x] = panel_pool[math.random(#panel_pool)]
    end

    return tiles
end

local function _build_random_encounter(area_id, area_table)
    local cfg = _get_random_encounter_config(area_table)
    if not cfg then
        return nil
    end

    local use_boss = false
    local boss_cfg = cfg.bosses
    if boss_cfg and boss_cfg.enabled == true and boss_cfg.pool and #boss_cfg.pool > 0 then
        local boss_chance = tonumber(boss_cfg.chance or 0) or 0
        if boss_chance > 0 and math.random() < boss_chance then
            use_boss = true
        end
    end

    local unit_pool = use_boss and boss_cfg.pool or cfg.pool
    local allow_duplicates = cfg.allow_duplicates == true

    local enemy_count = 1
    if not use_boss then
        local count_cfg = cfg.enemy_count or {}
        local min_count = math.floor(tonumber(count_cfg.min or count_cfg.min_enemies or 2) or 2)
        local max_count = math.floor(tonumber(count_cfg.max or count_cfg.max_enemies or 3) or 3)

        if min_count < 1 then min_count = 1 end
        if max_count < min_count then max_count = min_count end

        enemy_count = math.random(min_count, max_count)
        if not allow_duplicates then
            enemy_count = math.min(enemy_count, #unit_pool)
        end
    end

    local selected_units = _pick_random_units(unit_pool, enemy_count, allow_duplicates)
    if #selected_units == 0 then
        return nil
    end

    local enemies = {}
    for i, unit_def in ipairs(selected_units) do
        enemies[i] = {
            name = unit_def.name,
            rank = _pick_random_rank_token(unit_def),
        }
    end

    local player_positions = _copy_grid(cfg.player_positions or DEFAULT_RANDOM_PLAYER_POSITIONS)
    local positions, occupied = _build_enemy_positions(#enemies, use_boss)
    local obstacles, obstacle_positions = _build_random_obstacles(cfg, occupied, player_positions)
    local package_path = _get_random_package_path(area_table, cfg, use_boss)

    if not package_path then
        return nil
    end

    return {
        name = string.format("Random_%s_%d", tostring(area_id), math.random(1000000)),
        path = package_path,
        enemies = enemies,
        obstacles = obstacles,
        positions = positions,
        obstacle_positions = obstacle_positions,
        player_positions = player_positions,
        tiles = _build_random_tiles(cfg),
        teams = _copy_grid(cfg.teams or DEFAULT_RANDOM_TEAMS),
        _area_id = area_id,
        _random_encounter = true,
        _random_is_boss = use_boss,
    }
end

local function _pick_encounter_for_area(area_id, area_table)
    local has_static = area_table and area_table.encounters and #area_table.encounters > 0
    local random_cfg = _get_random_encounter_config(area_table)
    local has_random = random_cfg ~= nil and _get_random_package_path(area_table, random_cfg, false) ~= nil

    if has_static and not has_random then
        return ezencounters.pick_encounter_from_table(area_table)
    end

    if has_random and not has_static then
        return _build_random_encounter(area_id, area_table)
    end

    if not has_static and not has_random then
        return nil
    end

    local source_weights = random_cfg.source_weights or {}
    local source = _pick_weighted_key({
        static = tonumber(source_weights.static or 50) or 50,
        random = tonumber(source_weights.random or 50) or 50,
    }, "static")

    if source == "random" then
        local random_encounter = _build_random_encounter(area_id, area_table)
        if random_encounter then
            return random_encounter
        end
        return ezencounters.pick_encounter_from_table(area_table)
    end

    local static_encounter = ezencounters.pick_encounter_from_table(area_table)
    if static_encounter then
        return static_encounter
    end

    return _build_random_encounter(area_id, area_table)
end

-- Ensure encounters directory exists
helpers.ensure_directory(ezconfig.ENCOUNTERS_PATH)

local load_encounters_for_areas = function ()
    local areas = Net.list_areas()
    local loaded_tables = {}

    for _, area_id in ipairs(areas) do
        local encounter_table_path = ezconfig.ENCOUNTERS_PATH .. area_id
        local status, area_data = pcall(function ()
            return require(encounter_table_path)
        end)

        if status == true and area_data then
            area_data.encounters = area_data.encounters or {}
            loaded_tables[area_id] = area_data

            for _, encounter_info in ipairs(area_data.encounters) do
                encounter_info._area_id = area_id

                if encounter_info.path and not provided_encounter_assets[encounter_info.path] then
                    print('[ezencounters] providing mob package ' .. encounter_info.path)
                    Net.provide_asset(area_id, encounter_info.path)
                    provided_encounter_assets[encounter_info.path] = true
                end

                if encounter_info.name then
                    print('[ezencounters] loaded named encounter ' .. encounter_info.name)
                    named_encounters[encounter_info.name] = encounter_info
                end
            end

            local random_cfg = _get_random_encounter_config(area_data)
            if random_cfg then
                local random_path = _get_random_package_path(area_data, random_cfg, false)
                if random_path and not provided_encounter_assets[random_path] then
                    print('[ezencounters] providing random encounter package ' .. random_path)
                    Net.provide_asset(area_id, random_path)
                    provided_encounter_assets[random_path] = true
                end

                local boss_path = _get_random_package_path(area_data, random_cfg, true)
                if boss_path and boss_path ~= random_path and not provided_encounter_assets[boss_path] then
                    print('[ezencounters] providing random boss encounter package ' .. boss_path)
                    Net.provide_asset(area_id, boss_path)
                    provided_encounter_assets[boss_path] = true
                end
            end

            print('[ezencounters] loaded encounter table for ' .. area_id)
        end
    end

    return loaded_tables
end

area_encounter_tables = load_encounters_for_areas()

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
    if not encounter_table or not encounter_table.encounters or #encounter_table.encounters == 0 then
        return nil
    end

    local total_weight = 0
    for _, option in ipairs(encounter_table.encounters) do
        total_weight = total_weight + (tonumber(option.weight) or 0)
    end

    if total_weight <= 0 then
        return encounter_table.encounters[1]
    end

    local crawler = math.random() * total_weight
    for i, option in ipairs(encounter_table.encounters) do
        crawler = crawler - (tonumber(option.weight) or 0)
        if crawler <= 0 then
            return encounter_table.encounters[i]
        end
    end

    return encounter_table.encounters[1]
end

ezencounters.try_random_encounter = function (player_id, encounter_table)
    if math.random() > encounter_table.encounter_chance_per_step then
        return
    end

    local player_area = Net.get_player_area(player_id)
    local encounter_info = _pick_encounter_for_area(player_area, encounter_table)

    if encounter_info then
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
        players_in_encounters[player_id] = {encounter_info=encounter_info}
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
    local flags = _result_flags(event)

    if players_in_encounters[player_id] then
        local player_encounter = players_in_encounters[player_id]
        local encounter_info = player_encounter.encounter_info
        local area_id = encounter_info and encounter_info._area_id
        local area_table = area_id and area_encounter_tables[area_id] or nil

        if encounter_finished_callbacks[player_id] then
            encounter_finished_callbacks[player_id](event)
            encounter_finished_callbacks[player_id] = nil
        end

        if encounter_info and encounter_info.results_callback then
            encounter_info.results_callback(player_id, encounter_info, event)
        else
            _apply_area_result_awards(player_id, area_table, encounter_info, event)
        end

        players_in_encounters[player_id] = nil
    end

    ezbus:emit("encounter_finished", {
        player_id = player_id,
        stats = {
            health = event.health,
            time = event.time,
            ran = flags.ran,
            emotion = event.emotion,
            turns = event.turns,
            enemies = event.enemies,
            score = event.score,
            reason = event.reason,
            won = flags.won,
            lost = flags.lost,
            dev_escape = flags.dev_escape,
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
            local flags = _result_flags(stats)
            if flags.ran or flags.lost then
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

-- Register handler for Radius Encounter objects
object_registry.register_handler("Radius Encounter", function(area_id, object)
    local radius = tonumber(object.custom_properties["Radius"] or 1)
    local emitter = eztriggers.add_radius_trigger(area_id, object, radius, radius, 0, 0)
    emitter:on('entered', function(event)
        return on_radius_encounter_triggered(event)
    end)
end)

return ezencounters
