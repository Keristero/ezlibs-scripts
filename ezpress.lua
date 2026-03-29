-- ezpress.lua
-- Compression/decompression using eztriggers and area property "Minish Mode".
-- Objects with "Compress" = true cause player to shrink on entry.
-- Objects with "Decompress" = true restore normal size on entry.
-- Areas with "Minish Mode" = true compress all players inside (overridden by tiles).

local eztriggers = require('scripts/ezlibs-scripts/eztriggers')
local helpers = require('scripts/ezlibs-scripts/helpers')
local ezbus = require('scripts/ezlibs-scripts/ezbus')

local ezpress = {}

-- Persistent state per player
local compressed_players = {}

-- Sound effect path (adjust if needed)
local compressSfx = "/server/assets/ezlibs-assets/sfx/compress.ogg"

-- Store trigger data per area for manual checks on join/transfer
local area_triggers = {}

-- ----------------------------------------------------------------------------
-- Public getter for area minish mode (live property lookup)
-- ----------------------------------------------------------------------------
function ezpress.get_area_minish_mode(area_id)
    local prop = Net.get_area_custom_property(area_id, "Minish Mode")
    return (prop == "true" or prop == true)
end

-- ----------------------------------------------------------------------------
-- Compression / Decompression animations
-- ----------------------------------------------------------------------------
function ezpress.compress(player_id, immediate)
    print("[ezpress] compress called for player", player_id, "currently compressed =", compressed_players[player_id] or false, "immediate =", immediate)
    if compressed_players[player_id] then
        return  -- already compressed
    end

    local duration = immediate and 0 or 0.15
    Net.animate_player_properties(player_id, {
        {
            properties = {
                { property = "ScaleX", value = 3 / 8, ease = "Linear" },
                { property = "ScaleY", value = 3 / 8, ease = "Linear" }
            },
            duration = duration
        }
    })

    Net.play_sound_for_player(player_id, compressSfx)
    compressed_players[player_id] = true

    ezbus:emit("player_compressed", { player_id = player_id })
end

function ezpress.decompress(player_id, immediate)
    print("[ezpress] decompress called for player", player_id, "currently compressed =", compressed_players[player_id] or false, "immediate =", immediate)
    if not compressed_players[player_id] then
        return  -- already normal size
    end

    local duration = immediate and 0 or 0.15
    Net.animate_player_properties(player_id, {
        {
            properties = {
                { property = "ScaleX", value = 1, ease = "Linear" },
                { property = "ScaleY", value = 1, ease = "Linear" }
            },
            duration = duration
        }
    })

    Net.play_sound_for_player(player_id, compressSfx)
    compressed_players[player_id] = nil

    ezbus:emit("player_decompressed", { player_id = player_id })
end

-- ----------------------------------------------------------------------------
-- Apply the area's minish mode property (live lookup)
-- ----------------------------------------------------------------------------
function ezpress.apply_map_property(player_id, area_id, immediate)
    local minish = ezpress.get_area_minish_mode(area_id)
    print("[ezpress] apply_map_property: player", player_id, "area", area_id, "minish_mode (live) =", minish, "immediate =", immediate)
    if minish then
        ezpress.compress(player_id, immediate)
    else
        ezpress.decompress(player_id, immediate)
    end
end

-- ----------------------------------------------------------------------------
-- Manual check on player join/transfer (to catch spawns inside a tile)
-- ----------------------------------------------------------------------------
function ezpress.check_and_apply(player_id, area_id, pos)
    local triggers = area_triggers[area_id]
    if not triggers then return end

    for _, t in ipairs(triggers) do
        if pos.z == t.z and
           pos.x > t.x and pos.x < t.x + t.width and
           pos.y > t.y and pos.y < t.y + t.height then
            if t.type == "compress" then
                ezpress.compress(player_id, false)   -- animated
            else
                ezpress.decompress(player_id, false) -- animated
            end
            break  -- apply first matching tile only (original behaviour)
        end
    end
end

-- ----------------------------------------------------------------------------
-- Plugin hooks called from main.lua
-- ----------------------------------------------------------------------------
function ezpress.handle_player_join(player_id)
    -- Provide sound asset for this player
    Net.provide_asset_for_player(player_id, compressSfx)

    local area = Net.get_player_area(player_id)
    local pos = Net.get_player_position(player_id)

    -- Apply area minish mode immediately
    ezpress.apply_map_property(player_id, area, true)

    -- Then check if standing inside a compression/decompression tile (animated)
    ezpress.check_and_apply(player_id, area, pos)
end

function ezpress.handle_player_transfer(player_id)
    local area = Net.get_player_area(player_id)
    local pos = Net.get_player_position(player_id)
    print("[ezpress] handle_player_transfer: player", player_id, "to area", area)

    -- Apply area minish mode immediately before arrival animations
    ezpress.apply_map_property(player_id, area, true)

    -- Check tile overlap (animated)
    ezpress.check_and_apply(player_id, area, pos)
end

function ezpress.handle_player_disconnect(player_id)
    compressed_players[player_id] = nil
end

-- ----------------------------------------------------------------------------
-- Initialisation: scan all areas for compression tiles (Minish Mode not cached)
-- ----------------------------------------------------------------------------
local function init()
    print("[ezpress] Scanning for compression tiles...")

    local areas = Net.list_areas()
    for _, area_id in ipairs(areas) do
        -- Scan objects for compress/decompress tiles
        local objects = Net.list_objects(area_id)
        for _, object_id in ipairs(objects) do
            local obj = Net.get_object_by_id(area_id, object_id)
            if obj and obj.custom_properties then
                local props = obj.custom_properties
                local is_compress = props.Compress == "true" or props.Compress == true
                local is_decompress = props.Decompress == "true" or props.Decompress == true

                if is_compress or is_decompress then
                    local trigger_type = is_compress and "compress" or "decompress"

                    -- Add rectangle trigger via eztriggers
                    local emitter = eztriggers.add_rectangle_trigger(area_id, obj, obj.width, obj.height)
                    if emitter then
                        -- Entered: apply tile effect (animated)
                        emitter:on("entered", function(event)
                            if trigger_type == "compress" then
                                ezpress.compress(event.player_id, false)
                            else
                                ezpress.decompress(event.player_id, false)
                            end
                        end)

                        -- Departed: revert to area's default (animated)
                        emitter:on("departed", function(event)
                            ezpress.apply_map_property(event.player_id, area_id, false)
                        end)
                    else
                        print("[ezpress] Warning: could not create trigger for object", object_id)
                    end

                    -- Store for manual checks
                    if not area_triggers[area_id] then
                        area_triggers[area_id] = {}
                    end
                    table.insert(area_triggers[area_id], {
                        x = obj.x, y = obj.y, z = obj.z,
                        width = obj.width, height = obj.height,
                        type = trigger_type
                    })

                    print(string.format("[ezpress] Added %s tile at (%.1f,%.1f,z=%d) in %s",
                        trigger_type, obj.x, obj.y, obj.z, area_id))
                end
            end
        end
    end

    print("[ezpress] Initialisation complete.")
end

-- Run initialisation immediately when the module is loaded
init()

return ezpress