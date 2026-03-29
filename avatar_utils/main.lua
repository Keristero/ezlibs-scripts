-- NaviSpot.lua
-- Module to cache player and bot avatar/mugshot assets.
-- For players: copies assets from engine to local files on avatar change.
-- For bots: registers existing local asset paths (no copying).

local avatar_utils = require('scripts/ezlibs-scripts/avatar_utils/avatar_utils')

-- Cache structure for players: cache[player_secret] = {
--   sheet = { texture = path, animation = path },
--   mug   = { texture = path, animation = path }
-- }
local player_cache = {}
local handler_registered = false

-- Cache structure for bots: bot_cache[bot_id] = {
--   sheet = { texture = path, animation = path },
--   mug   = { texture = path, animation = path }
-- }
local bot_cache = {}

local function get_player_secret(player_id)
    return Net.get_player_secret(player_id)
end

--- Internal helper: resolve input to a player secret.
--- @param input string|number player ID or existing secret
--- @return string|nil secret or nil if cannot resolve
local function resolve_secret(input)
    if not input then return nil end
    -- Try as player ID first
    local ok, secret = pcall(Net.get_player_secret, input)
    if ok and secret then
        return secret
    end
    -- Assume input is already a secret
    return input
end

--- Copies the player's current avatar and mugshot to local files and registers them as assets.
--- @param player_id string
--- @return table|nil cached entry or nil on failure
local function update_player_avatar(player_id)
    local secret = get_player_secret(player_id)
    if not secret then
        print("NaviSpot: Failed to get secret for player", player_id)
        return nil
    end

    -- Define local paths
    local sheet_texture_path   = "assets/avatars/sheet/" .. secret .. ".png"
    local sheet_animation_path = "assets/avatars/sheet/" .. secret .. ".animation"
    local mug_texture_path     = "assets/avatars/mug/" .. secret .. ".png"
    local mug_animation_path   = "assets/avatars/mug/" .. secret .. ".animation"

    -- Copy both avatar and mugshot using the utility function
    local success = avatar_utils.copy_player_avatar_to(
        player_id,
        sheet_texture_path,
        sheet_animation_path,
        mug_texture_path,
        mug_animation_path
    )

    if not success then
        print("NaviSpot: Failed to copy avatar for player", player_id)
        return nil
    end

    -- Store in cache
    local entry = {
        sheet = {
            texture = sheet_texture_path,
            animation = sheet_animation_path
        },
        mug = {
            texture = mug_texture_path,
            animation = mug_animation_path
        }
    }
    player_cache[secret] = entry
    return entry
end

-- Register the avatar change handler only once
if not handler_registered then
    Net:on("player_avatar_change", function(event)
        -- event contains: player_id, texture_path, animation_path, name, element, max_health, prevent_default
        -- We ignore the provided paths and always fetch the latest full set
        update_player_avatar(event.player_id)
    end)
    handler_registered = true
end

--- Public API: retrieve cached player avatar paths.
--- Accepts either a player ID or a player secret.
--- @param input string|number player ID or secret
--- @return table|nil the cached sheet/mug paths or nil if not yet cached
local function get_player_avatar_paths(input)
    local secret = resolve_secret(input)
    if not secret then
        print("NaviSpot: Could not resolve secret from input:", tostring(input))
        return nil
    end
    return player_cache[secret]
end

--- Public API: force an immediate refresh for a player ID (useful if you need the data right away).
--- @param player_id string
--- @return table|nil the updated cached entry
local function refresh_player_avatar(player_id)
    return update_player_avatar(player_id)
end

--- Public API: parse a player's animation file to get frame data.
--- Accepts either a player ID or a player secret.
--- @param input string|number player ID or secret
--- @param type string "sheet" or "mug"
--- @return table|nil parsed animation structure or nil if missing/error
local function parse_player_animation(input, type)
    local secret = resolve_secret(input)
    if not secret then
        print("NaviSpot: Could not resolve secret from input:", tostring(input))
        return nil
    end
    local entry = player_cache[secret]
    if not entry then
        print("Player: Player not cached for secret:", secret)
        return nil
    end
    local anim_path = (type == "sheet" and entry.sheet.animation) or (type == "mug" and entry.mug.animation)
    if not anim_path then
        print("Player: No animation path for secret", secret, "type", type)
        return nil
    end
    return avatar_utils.parse_animation_file(anim_path)
end

--- ======================== Bot Avatar Caching ========================

--- Register or update a bot's avatar and mugshot asset paths.
--- These are assumed to be existing local files or server assets; no copying is performed.
--- @param bot_id string Unique identifier for the bot (e.g., bot name)
--- @param sheet_texture_path string Path to the bot's sheet texture
--- @param sheet_animation_path string Path to the bot's sheet animation file
--- @param mug_texture_path string Path to the bot's mugshot texture
--- @param mug_animation_path string Path to the bot's mugshot animation file
--- @return table the stored entry
local function register_bot_avatar(bot_id, sheet_texture_path, sheet_animation_path, mug_texture_path, mug_animation_path)
    local entry = {
        sheet = {
            texture = sheet_texture_path,
            animation = sheet_animation_path
        },
        mug = {
            texture = mug_texture_path,
            animation = mug_animation_path
        }
    }
    bot_cache[bot_id] = entry
    return entry
end

--- Retrieve cached bot avatar paths.
--- @param bot_id string
--- @return table|nil the cached sheet/mug paths or nil if not registered
local function get_bot_avatar_paths(bot_id)
    return bot_cache[bot_id]
end

--- Optionally parse a bot's animation file to get frame data.
--- @param bot_id string
--- @param type string "sheet" or "mug" to specify which animation to parse
--- @return table|nil parsed animation structure or nil if missing/error
local function parse_bot_animation(bot_id, type)
    local entry = bot_cache[bot_id]
    if not entry then
        print("Bot: Bot not registered:", bot_id)
        return nil
    end
    local anim_path = (type == "sheet" and entry.sheet.animation) or (type == "mug" and entry.mug.animation)
    if not anim_path then
        print("Bot: No animation path for bot", bot_id, "type", type)
        return nil
    end
    return avatar_utils.parse_animation_file(anim_path)
end

-- Return the public interface
return {
    -- Player functions (accept either player_id or secret)
    get_player_avatar_paths = get_player_avatar_paths,
    refresh_player_avatar = refresh_player_avatar,
    parse_player_animation = parse_player_animation,

    -- Bot functions
    register_bot_avatar = register_bot_avatar,
    get_bot_avatar_paths = get_bot_avatar_paths,
    parse_bot_animation = parse_bot_animation,

    -- For debugging/inspection
    _player_cache = player_cache,
    _bot_cache = bot_cache
}