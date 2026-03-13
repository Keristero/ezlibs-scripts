-- ezrushroads.lua
-- Rush Roads minigame integrated with ezlibs
-- Uses eztriggers for tile detection and ezmemory for persistence
local ezrushroads = {}-- ezrushroads.lua
-- ezrushroads.lua
-- Rush Roads minigame integrated with ezlibs
-- Uses eztriggers for tile detection and ezmemory for persistence

local helpers = require('scripts/ezlibs-scripts/helpers')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local eztriggers = require('scripts/ezlibs-scripts/eztriggers')
local ezbus = require('scripts/ezlibs-scripts/ezbus')

-- Define local async/await using the global Async object (for use in handle_object_interaction)
local async = function(p)
    local co = coroutine.create(p)
    return Async.promisify(co)
end
local await = Async.await

-- Local table length helper
local function get_table_length(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

-- Helper to get animation state from direction string
local function get_anim_state_from_direction(direction)
    if direction == "Down Right" then
        return "IDLE_DR"
    elseif direction == "Down Left" then
        return "IDLE_DL"
    end
end

-- ============================================================================
-- Global state (not persistent)
-- ============================================================================
local rush_roads = {}               -- [area_id][road_id] = road info
local player_temp_bots = {}         -- [player_id][area_id][road_id] = bot_name
local player_active_animation = {}  -- [player_id] = { seq, area, group_id, roads }
local bot_occupants = {}            -- [bot_name] = { players = { [player_id] = true }, road = road_ref }
local any_player = {}               -- [player_id] = true (online)
local OFFMAP_X = -1000
local OFFMAP_Y = -1000

-- Assets for temporary bots (original rush sheet)
local rush_texture = "/server/assets/ezlibs-assets/ezrushroads/rushy.png"
local rush_animation = "/server/assets/ezlibs-assets/ezrushroads/rushy.anim"

-- Assets for permanent bots (new fed_rush sheet with direction‑specific animations)
local FED_RUSH_TEXTURE = "/server/assets/ezlibs-assets/ezrushroads/fed_rush.png"
local RUSH_DL_ANIM = "/server/assets/ezlibs-assets/ezrushroads/rush_dl.anim"
local RUSH_DR_ANIM = "/server/assets/ezlibs-assets/ezrushroads/rush_dr.anim"

-- Food item base name (constant)
local BASE_FOOD_NAME = "Rush Food"
local BASE_FOOD_DESC = "You have %d Rush Food."

-- ============================================================================
-- Helper: generate player‑specific item ID
-- ============================================================================
local function get_food_item_id(player_id)
    return "rush_food_" .. tostring(player_id)
end

-- ============================================================================
-- Food management using ezmemory
-- ============================================================================
local function get_player_rush_memory(player_id)
    local secret = helpers.get_safe_player_secret(player_id)
    local mem = ezmemory.get_player_memory(secret)
    if not mem.rushroads then
        mem.rushroads = { food = 0, cleared = {} }
        ezmemory.save_player_memory(secret)
    end
    return mem.rushroads, secret
end

local function update_food_item(player_id, count)
    local item_id = get_food_item_id(player_id)
    -- Remove any existing item with this ID
    while Net.remove_player_item(player_id, item_id) do end
    if count > 0 then
        local description = BASE_FOOD_DESC:format(count)
        Net.create_item(item_id, {
            name = BASE_FOOD_NAME,
            description = description,
            type = "keyitem"
        })
        Net.give_player_item(player_id, item_id)
    end
end

function ezrushroads.get_food(player_id)
    local rush, _ = get_player_rush_memory(player_id)
    return rush.food or 0
end

function ezrushroads.add_food(player_id, amount)
    amount = amount or 1
    local rush, secret = get_player_rush_memory(player_id)
    rush.food = (rush.food or 0) + amount
    ezmemory.save_player_memory(secret)
    update_food_item(player_id, rush.food)
    return rush.food
end

function ezrushroads.remove_food(player_id, amount)
    amount = amount or 1
    local rush, secret = get_player_rush_memory(player_id)
    local current = rush.food or 0
    if current < amount then
        return -1
    end
    rush.food = current - amount
    ezmemory.save_player_memory(secret)
    update_food_item(player_id, rush.food)
    return rush.food
end

-- ============================================================================
-- Group roads in an area (cardinal adjacency)
-- ============================================================================
local function group_rush_roads_in_area(area_id)
    local roads = rush_roads[area_id]
    if not roads then return end

    local road_ids = {}
    for id, _ in pairs(roads) do
        table.insert(road_ids, id)
    end

    local visited = {}
    local group_counter = 0

    local function dfs(start_id, group_id)
        local stack = { start_id }
        visited[start_id] = true
        roads[start_id].group_id = group_id

        while #stack > 0 do
            local current_id = table.remove(stack)
            local cur = roads[current_id]
            local cx = math.floor(cur.x + 0.5)
            local cy = math.floor(cur.y + 0.5)

            for _, other_id in ipairs(road_ids) do
                if not visited[other_id] then
                    local other = roads[other_id]
                    local ox = math.floor(other.x + 0.5)
                    local oy = math.floor(other.y + 0.5)

                    local dx = math.abs(cx - ox)
                    local dy = math.abs(cy - oy)

                    if (dx == 1 and dy == 0) or (dx == 0 and dy == 1) then
                        visited[other_id] = true
                        other.group_id = group_id
                        table.insert(stack, other_id)
                    end
                end
            end
        end
    end

    for _, id in ipairs(road_ids) do
        if not visited[id] then
            group_counter = group_counter + 1
            dfs(id, group_counter)
        end
    end

    print("[ezrushroads] Grouped " .. #road_ids .. " roads in " .. area_id .. " into " .. group_counter .. " groups")
end

-- ============================================================================
-- Create permanent bot for linked object
-- ============================================================================
local function create_permanent_bot(area_id, road_id, linked_obj, direction)
    local bot_name = "rush_perm_" .. area_id .. "_" .. road_id
    local bot_x = linked_obj.x - 0.5
    local bot_y = linked_obj.y - 0.5
    local bot_z = linked_obj.z - 1

    local anim_state = get_anim_state_from_direction(direction)

    -- Choose the correct animation file based on direction
    local anim_path
    if direction == "Down Right" then
        anim_path = RUSH_DR_ANIM
    elseif direction == "Down Left" then
        anim_path = RUSH_DL_ANIM
    end

    print(string.format("[ezrushroads] Creating permanent bot %s at (%.2f, %.2f, %.2f) with anim %s (direction: %s, anim file: %s)",
        bot_name, bot_x, bot_y, bot_z, anim_state, direction, anim_path))

    local success, err = pcall(Net.create_bot, bot_name, {
        name = "Rush Bot",
        area_id = area_id,
        warp_in = true,
        texture_path = FED_RUSH_TEXTURE,
        animation_path = anim_path,
        animation = anim_state,
        x = bot_x,
        y = bot_y,
        z = bot_z,
        solid = false
    })

    if success then
        local road = rush_roads[area_id][road_id]
        road.bot_name = bot_name
        road.original_x = bot_x
        road.original_y = bot_y
        road.original_z = bot_z
        road.anim_state = anim_state
        road.down_x = bot_x + 0.1
        road.down_y = bot_y + 0.1
        road.down_z = bot_z

        -- Register in bot_occupants (record persists forever)
        bot_occupants[bot_name] = { players = {}, road = road }
        print("[ezrushroads] Created permanent bot " .. bot_name .. " and registered occupants")

        -- Bot is initially invisible for all players; visibility is controlled per player via cleared status
        return true
    else
        print("[ezrushroads] Failed to create permanent bot: " .. tostring(err))
        return false
    end
end

-- ============================================================================
-- Process a single Rush Road object (called during init)
-- ============================================================================
local function process_rush_road(area_id, object)
    if not rush_roads[area_id] then
        rush_roads[area_id] = {}
    end

    local road = {
        id = object.id,
        x = object.x,
        y = object.y,
        z = object.z,
        custom_properties = object.custom_properties,
        group_id = nil,
        bot_name = nil,
        original_x = nil,
        original_y = nil,
        original_z = nil,
        down_x = nil,
        down_y = nil,
        down_z = nil,
        anim_state = nil
    }
    rush_roads[area_id][object.id] = road
    print("[ezrushroads] Registered road " .. object.id .. " at (" .. object.x .. "," .. object.y .. "," .. object.z .. ")")

    -- If there is a linked object, create a permanent bot FIRST
    local linked_id = object.custom_properties["Rush Object"]
    if linked_id then
        local linked_obj = Net.get_object_by_id(area_id, linked_id)
        if linked_obj then
            local direction = object.custom_properties["Direction"] or "Down Left"
            create_permanent_bot(area_id, object.id, linked_obj, direction)
        else
            print("[ezrushroads] Linked object " .. tostring(linked_id) .. " not found in " .. area_id)
        end
    end

    -- Create a rectangle trigger for this road tile
    local width = 64
    local height = 32
    local emitter = eztriggers.add_rectangle_trigger(area_id, object, width, height, "rush_trigger")
    if emitter then
        emitter:on("entered", function(event)
            local player_id = event.player_id
            if road.bot_name then
                print("[ezrushroads] 🟢 Tile entered by player " .. player_id .. " for road " .. object.id .. " bot " .. road.bot_name)
                ezbus:emit("rush_tile_entered", {
                    player_id = player_id,
                    area_id = area_id,
                    road_id = object.id,
                    bot_name = road.bot_name
                })
            else
                print("[ezrushroads] ⚠️ Tile entered but no bot_name yet for road " .. object.id)
            end
        end)

        emitter:on("departed", function(event)
            local player_id = event.player_id
            if road.bot_name then
                print("[ezrushroads] 🔴 Tile departed by player " .. player_id .. " for road " .. object.id)
                ezbus:emit("rush_tile_departed", {
                    player_id = player_id,
                    area_id = area_id,
                    road_id = object.id,
                    bot_name = road.bot_name
                })
            end
        end)
    end
end

-- ============================================================================
-- After all objects are loaded, scan for Rush Roads and process them
-- ============================================================================
function ezrushroads.init()
    print("[ezrushroads] Initializing...")
    local areas = Net.list_areas()
    for _, area_id in ipairs(areas) do
        local objects = Net.list_objects(area_id)
        for _, object_id in ipairs(objects) do
            local object = Net.get_object_by_id(area_id, object_id)
            if object and object.type == "Rush Road" then
                process_rush_road(area_id, object)
            end
        end
    end

    -- Now group all roads
    for area_id, _ in pairs(rush_roads) do
        group_rush_roads_in_area(area_id)
    end

    print("[ezrushroads] Initialized")
end

-- ============================================================================
-- Update visibility of road objects and permanent bots for a player in a given area
-- ============================================================================
local function update_visibility_for_player(player_id, area_id)
    local rush, _ = get_player_rush_memory(player_id)
    local cleared = rush.cleared[area_id] or {}
    local roads = rush_roads[area_id]
    if not roads then return end

    for road_id, road in pairs(roads) do
        local road_id_str = tostring(road_id)
        local is_cleared = cleared[road_id_str]

        -- Road object visibility
        if is_cleared then
            Net.exclude_object_for_player(player_id, road_id)
        else
            Net.include_object_for_player(player_id, road_id)
        end

        -- Permanent bot visibility (if it exists)
        if road.bot_name then
            if is_cleared then
                Net.include_actor_for_player(player_id, road.bot_name)
                print("[ezrushroads] 👁️ Showing permanent bot " .. road.bot_name .. " for player " .. player_id)
            else
                Net.exclude_actor_for_player(player_id, road.bot_name)
                print("[ezrushroads] 🙈 Hiding permanent bot " .. road.bot_name .. " for player " .. player_id)
            end
        end
    end
end

-- ============================================================================
-- Create temporary animation bots for a player (one per road, off-map)
-- ============================================================================
local function create_temp_bots_for_player(player_id)
    if player_temp_bots[player_id] then return end
    player_temp_bots[player_id] = {}
    print("[ezrushroads] Creating temp bots for player " .. player_id)

    for area_id, roads in pairs(rush_roads) do
        player_temp_bots[player_id][area_id] = {}
        for road_id, road in pairs(roads) do
            local bot_name = "rush_temp_" .. player_id .. "_" .. area_id .. "_" .. road_id
            local success, err = pcall(Net.create_bot, bot_name, {
                name = "Rush Temp",
                area_id = area_id,
                warp_in = true,
                texture_path = rush_texture,
                animation_path = rush_animation,
                animation = "IDLE_D",
                x = OFFMAP_X,
                y = OFFMAP_Y,
                z = road.z,
                solid = false
            })
            if success then
                -- Hide from everyone except this player
                for pid, _ in pairs(any_player) do
                    if pid ~= player_id then
                        Net.exclude_actor_for_player(pid, bot_name)
                    end
                end
                player_temp_bots[player_id][area_id][road_id] = bot_name
            else
                print("[ezrushroads] Failed to create temp bot: " .. tostring(err))
            end
        end
    end
end

-- ============================================================================
-- Remove temporary bots for a player
-- ============================================================================
local function remove_temp_bots_for_player(player_id)
    if not player_temp_bots[player_id] then return end
    for area_id, roads in pairs(player_temp_bots[player_id]) do
        for road_id, bot_name in pairs(roads) do
            Net.remove_bot(bot_name)
        end
    end
    player_temp_bots[player_id] = nil
end

-- ============================================================================
-- Clean up active animation state for a player (if any)
-- ============================================================================
local function clear_active_animation(player_id)
    if player_active_animation[player_id] then
        player_active_animation[player_id] = nil
    end
end

-- ============================================================================
-- Handle pressure plate effects via bus events
-- ============================================================================
ezbus:on("rush_tile_entered", function(event)
    local player_id = event.player_id
    local bot_name = event.bot_name
    local occ = bot_occupants[bot_name]
    if not occ then
        print("[ezrushroads] ❌ ERROR: No occupant record for bot " .. bot_name)
        return
    end

    if not occ.players[player_id] then
        occ.players[player_id] = true
        local new_count = get_table_length(occ.players)
        print("[ezrushroads] Player " .. player_id .. " entered tile, now " .. new_count .. " occupants")
        if new_count == 1 then
            local road = occ.road
            if road.down_x and road.down_y then
                print(string.format("[ezrushroads] ⬇️ Moving bot %s down to (%.2f, %.2f)", bot_name, road.down_x, road.down_y))
                Net.move_bot(bot_name, road.down_x, road.down_y, road.down_z)
            end
        end
    end
end)

ezbus:on("rush_tile_departed", function(event)
    local player_id = event.player_id
    local bot_name = event.bot_name
    local occ = bot_occupants[bot_name]
    if not occ then
        print("[ezrushroads] ❌ ERROR: No occupant record for bot " .. bot_name .. " on departure")
        return
    end

    if occ.players[player_id] then
        occ.players[player_id] = nil
        local new_count = get_table_length(occ.players)
        print("[ezrushroads] Player " .. player_id .. " departed tile, remaining " .. new_count)
        if new_count == 0 then
            local road = occ.road
            if road.original_x and road.original_y then
                print(string.format("[ezrushroads] ⬆️ Returning bot %s to (%.2f, %.2f)", bot_name, road.original_x, road.original_y))
                Net.move_bot(bot_name, road.original_x, road.original_y, road.original_z)
            end
        end
    end
end)

-- ============================================================================
-- Event handlers (called from main.lua)
-- ============================================================================
function ezrushroads.handle_player_join(player_id)
    any_player[player_id] = true
    local rush, _ = get_player_rush_memory(player_id)

    -- Ensure food item exists
    update_food_item(player_id, rush.food or 0)

    -- Give starting food (original behavior)
    ezrushroads.add_food(player_id, 10)
    local name = Net.get_player_name(player_id)
    if name == "D3str0y3d" then
        ezrushroads.add_food(player_id, 6)
    end

    -- Create temporary bots
    create_temp_bots_for_player(player_id)

    -- Update visibility in current area
    local area = Net.get_player_area(player_id)
    if area then
        update_visibility_for_player(player_id, area)
    end
end

function ezrushroads.handle_player_disconnect(player_id)
    any_player[player_id] = nil
    clear_active_animation(player_id)
    remove_temp_bots_for_player(player_id)

    -- Remove player from bot_occupants but keep the records
    for bot_name, occ in pairs(bot_occupants) do
        if occ.players[player_id] then
            occ.players[player_id] = nil
            if get_table_length(occ.players) == 0 then
                -- Reset bot position to original (no delay needed on disconnect)
                local road = occ.road
                if road and road.original_x and road.original_y then
                    print("[ezrushroads] Player disconnect resetting bot " .. bot_name)
                    Net.move_bot(bot_name, road.original_x, road.original_y, road.original_z)
                end
            end
        end
    end
end

function ezrushroads.handle_player_transfer(player_id)
    local area = Net.get_player_area(player_id)
    if area then
        update_visibility_for_player(player_id, area)
    end
    clear_active_animation(player_id)
end

function ezrushroads.handle_object_interaction(player_id, object_id)
    local area = Net.get_player_area(player_id)
    local object = Net.get_object_by_id(area, object_id)
    if not object or object.type ~= "Rush Road" then return end

    -- Get road data
    local road = rush_roads[area] and rush_roads[area][object_id]
    if not road then return end

    local group_id = road.group_id
    -- Count roads in group
    local group_size = 1
    if group_id then
        group_size = 0
        for _, r in pairs(rush_roads[area]) do
            if r.group_id == group_id then
                group_size = group_size + 1
            end
        end
    end

    local food = ezrushroads.get_food(player_id)
    if food < group_size then
        Net.message_player(player_id, "You don't have enough Rush Food...")
        return
    end

    -- Return an async function (promise)
    return async(function()
        local choice = await(Async.question_player(player_id,
            "Would you like to use " .. group_size .. " Rush Food to activate this group?"))
        if choice ~= 1 then
            return
        end

        -- Lock player input
        Net.lock_player_input(player_id)

        -- Consume food
        local remaining = ezrushroads.remove_food(player_id, group_size)
        if remaining < 0 then
            Net.unlock_player_input(player_id)
            return
        end

        -- Collect all roads in group
        local group_roads = {}
        for id, r in pairs(rush_roads[area]) do
            if (group_id and r.group_id == group_id) or (not group_id and id == object_id) then
                group_roads[id] = r
            end
        end

        -- Mark cleared in memory
        local rush_mem, secret = get_player_rush_memory(player_id)
        if not rush_mem.cleared[area] then
            rush_mem.cleared[area] = {}
        end
        for id, _ in pairs(group_roads) do
            rush_mem.cleared[area][tostring(id)] = true
        end
        ezmemory.save_player_memory(secret)

        -- Immediately hide road objects (they stay hidden)
        for id, _ in pairs(group_roads) do
            Net.exclude_object_for_player(player_id, id)
        end

        -- Animation sequence
        local seq = (player_active_animation[player_id] and player_active_animation[player_id].seq or 0) + 1
        local anim_state = {
            seq = seq,
            area = area,
            group_id = group_id,
            roads = {}
        }

        -- Move temp bots to road positions
        for id, r in pairs(group_roads) do
            local temp_bot = player_temp_bots[player_id][area][id]
            if not temp_bot then
                print("[ezrushroads] Missing temp bot for road " .. id)
                goto continue
            end

            local x = r.x + 0.5
            local y = r.y + 0.5

            -- Instant move to road location
            local move_in = {{ properties = { { property = "X", value = x }, { property = "Y", value = y } }, duration = 0 }}
            Net.animate_bot_properties(temp_bot, move_in)

            -- Full animation keyframes
            local keyframes = {
                { properties = { { property = "Animation", value = "IDLE_D" }, { property = "X", ease = "In", value = x }, { property = "Y", ease = "In", value = y } }, duration = 1.0 },
                { properties = { { property = "Animation", value = "WIND_UP" }, { property = "X", ease = "In", value = (x - .2) }, { property = "Y", ease = "In", value = (y - .2) } }, duration = 0.1 },
                { properties = { { property = "Animation", value = "LAUNCH" }, { property = "X", ease = "In", value = (x - .4) }, { property = "Y", ease = "In", value = (y - .4) } }, duration = 0.2 },
                { properties = { { property = "Animation", value = "SPIN" }, { property = "X", ease = "In", value = (x - .6) }, { property = "Y", ease = "In", value = (y - .6) } }, duration = 0.2 },
                { properties = { { property = "Animation", value = "SPIN" }, { property = "X", ease = "Out", value = (x - .8) }, { property = "Y", ease = "Out", value = (y - .8) } }, duration = 0.2 },
                { properties = { { property = "Animation", value = "SPIN" }, { property = "X", ease = "Out", value = (x - 1) }, { property = "Y", ease = "Out", value = (y - 1) } }, duration = 1.0 },
                { properties = { { property = "Animation", value = "SPIN" }, { property = "X", ease = "Out", value = (x) - .8 }, { property = "Y", ease = "Out", value = (y - .8) } }, duration = 0.2 },
                { properties = { { property = "Animation", value = "SPIN" }, { property = "X", ease = "Out", value = (x) - .6 }, { property = "Y", ease = "Out", value = (y - .6) } }, duration = 0.2 },
                { properties = { { property = "Animation", value = "SPIN" }, { property = "X", ease = "Out", value = (x) - .4 }, { property = "Y", ease = "Out", value = (y - .4) } }, duration = 0.2 },
                { properties = { { property = "Animation", value = "SPIN" }, { property = "X", ease = "Out", value = (x) - .2 }, { property = "Y", ease = "Out", value = (y - .2) } }, duration = 0.1 },
                { properties = { { property = "Animation", value = "SPIN" }, { property = "X", ease = "Out", value = (x) }, { property = "Y", ease = "Out", value = (y) } }, duration = 0.2 },
                { properties = { { property = "Animation", value = "END" }, { property = "X", ease = "Out", value = (x) }, { property = "Y", ease = "Out", value = (y) } }, duration = 0.2 }
            }
            Net.animate_bot_properties(temp_bot, keyframes)

            anim_state.roads[id] = temp_bot
            ::continue::
        end

        player_active_animation[player_id] = anim_state

        -- After animation, move temp bots off-map and show permanent bots
        await(Async.sleep(3.6))
        local current = player_active_animation[player_id]
        if current and current.seq == seq then
            if Net.get_player_name(player_id) then  -- player still online
                -- Move temp bots off-map
                for id, bot_name in pairs(anim_state.roads) do
                    local move_out = {{ properties = { { property = "X", value = OFFMAP_X }, { property = "Y", value = OFFMAP_Y } }, duration = 0 }}
                    Net.animate_bot_properties(bot_name, move_out)
                end

                -- Show permanent bots for all cleared roads in this group
                for id, _ in pairs(group_roads) do
                    if rush_roads[area][id].bot_name then
                        Net.include_actor_for_player(player_id, rush_roads[area][id].bot_name)
                        print("[ezrushroads] 👁️ Showing permanent bot " .. rush_roads[area][id].bot_name .. " after animation")
                    end
                end

                Net.unlock_player_input(player_id)
            end
            player_active_animation[player_id] = nil
        end
    end)
end

return ezrushroads