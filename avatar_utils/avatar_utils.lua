-- avatar_utils.lua
-- Utility functions for handling player avatars and mugshots

local lua_yes_parser = require('scripts/ezlibs-scripts/avatar_utils/lua_yes_parser/lib')
local base64 = require('scripts/ezlibs-scripts/avatar_utils/base64')

local avatar_utils = {}

-- Helper: parse duration from .animation file (e.g., "10f" → 166ms)
local function parse_duration(duration_str)
    local multi = 1
    if duration_str:sub(-1) == 'f' then
        -- if the duration is in frames, convert to seconds (assuming 16.6ms per frame)
        duration_str = "0.00"..duration_str:sub(1, -2) -- remove trailing 'f'
        multi = 16.6
    end
    local duration = tonumber(duration_str) or 0
    return duration * multi
end

-- Helper: extract argument value from YES parser args
local get_arg_by_key = function (args, key, transform)
    for _, arg in ipairs(args) do
        if arg.key == key then
            -- always remove quotes from string
            local value = arg.val:gsub('"','')
            if value == nil or value == '' then
                return nil
            end
            if transform == nil then
                return value
            end
            return transform(value)
        end
    end
    return nil
end

-- Helper: ensure all required arguments are present
local assert_no_nils = function(expected_args)
    for key, value in pairs(expected_args) do
        if value == nil then
            error("Missing expected argument: " .. key)
            return true
        end
    end
    return false
end

-- Helper: create directory for a given file path (if it doesn't exist)
local function ensure_directory(filepath)
    -- Extract directory part (supports both / and \)
    local dir = filepath:match("^(.*[/\\])")
    if dir then
        -- Remove trailing slash/backslash
        dir = dir:sub(1, -2)
        -- Attempt to create directory; ignore errors if it already exists
        -- Using os.execute is a simple synchronous approach; adjust if your environment provides a better API
        os.execute('mkdir "' .. dir .. '" 2>nul')  -- Windows
        -- For Linux/macOS: os.execute('mkdir -p "' .. dir .. '"')
    end
end

-- Helper: register/update an asset with the server
function set_or_update_asset(asset_path, asset_content)
    if Net.has_asset("/server/"..asset_path) then
        Net.remove_asset("/server/"..asset_path)
    end
    Net.update_asset("/server/"..asset_path, asset_content)
end

--- Copy a player's avatar and mugshot to local files and register them as assets.
--- @param player_id string
--- @param new_texture_path string destination path for avatar texture (e.g., "assets/avatars/sheet/secret.png")
--- @param new_animation_path string destination path for avatar animation
--- @param mug_texture_path string destination path for mugshot texture
--- @param mug_animation_path string destination path for mugshot animation
--- @return boolean success
avatar_utils.copy_player_avatar_to = function(player_id, new_texture_path, new_animation_path, mug_texture_path, mug_animation_path)
    -- Ensure directories exist before writing files
    ensure_directory(new_texture_path)
    ensure_directory(new_animation_path)
    ensure_directory(mug_texture_path)
    ensure_directory(mug_animation_path)

    -- Retrieve player's current avatar and mugshot from the engine
    local avatar = Net.get_player_avatar(player_id)
    local mugshot = Net.get_player_mugshot(player_id)

    -- Avatar animation
    local animation_data = Net.read_asset(avatar.animation_path)
    local anim_file = io.open(new_animation_path, "wb")
    if not anim_file then
        print("ERROR: Cannot write to " .. new_animation_path)
        return false
    end
    anim_file:write(animation_data)
    anim_file:close()

    -- Avatar texture (base64 encoded)
    local texture_data_b64_string = Net.read_asset(avatar.texture_path)
    local texture_data = base64.decode(texture_data_b64_string)
    local tex_file = io.open(new_texture_path, "wb")
    if not tex_file then
        print("ERROR: Cannot write to " .. new_texture_path)
        return false
    end
    tex_file:write(texture_data)
    tex_file:close()

    -- Mugshot animation
    local mug_anim_data = Net.read_asset(mugshot.animation_path)
    local mug_anim_file = io.open(mug_animation_path, "wb")
    if not mug_anim_file then
        print("ERROR: Cannot write to " .. mug_animation_path)
        return false
    end
    mug_anim_file:write(mug_anim_data)
    mug_anim_file:close()

    -- Mugshot texture (base64 encoded)
    local mug_texture_data_b64 = Net.read_asset(mugshot.texture_path)
    local mug_texture_data = base64.decode(mug_texture_data_b64)
    local mug_tex_file = io.open(mug_texture_path, "wb")
    if not mug_tex_file then
        print("ERROR: Cannot write to " .. mug_texture_path)
        return false
    end
    mug_tex_file:write(mug_texture_data)
    mug_tex_file:close()

    -- Register the local files as server assets so they can be used by bots
    set_or_update_asset(new_texture_path, texture_data)
    set_or_update_asset(new_animation_path, animation_data)
    set_or_update_asset(mug_texture_path, mug_texture_data)
    set_or_update_asset(mug_animation_path, mug_anim_data)

    return true
end

--- Write content to a temporary file and return its path.
--- @param content string
--- @return string|nil temp file path, or nil on error
local function write_temp_file(content)
    local temp_path = os.tmpname()  -- returns a unique temporary filename
    local file, err = io.open(temp_path, "wb")
    if not file then
        print("Failed to create temp file:", err)
        return nil
    end
    file:write(content)
    file:close()
    return temp_path
end

--- Parse animation data from a string (content of .animation file) into a Lua table.
--- This function writes the content to a temporary file and uses lua_yes_parser.
--- @param data string The content of the .animation file
--- @return table|nil parsed animation structure, or nil on failure
avatar_utils.parse_animation_data = function(data)
    -- Write data to a temporary file
    local temp_path = write_temp_file(data)
    if not temp_path then
        print("Failed to write temporary animation file")
        return nil
    end

    -- Parse the temporary file
    local ok, yes_data = pcall(lua_yes_parser.parse, temp_path)
    -- Clean up temp file
    os.remove(temp_path)

    if not ok or not yes_data then
        print("Failed to parse animation data:", yes_data)
        return nil
    end

    local avatar = { animations = {} }
    local currently_parsing_animation_name = nil

    for _, value in ipairs(yes_data) do
        local text = value.text

        if text == "animation" then
            local expected_args = {
                name = get_arg_by_key(value.args, "state")
            }
            assert_no_nils(expected_args)
            avatar.animations[expected_args.name] = {
                frames = {},
                total_duration_ms = 0
            }
            currently_parsing_animation_name = expected_args.name
        end

        if text == "frame" then
            local expected_args = {
                duration = get_arg_by_key(value.args, "duration", parse_duration),
                x        = get_arg_by_key(value.args, "x", tonumber),
                y        = get_arg_by_key(value.args, "y", tonumber),
                width    = get_arg_by_key(value.args, "w", tonumber),
                height   = get_arg_by_key(value.args, "h", tonumber),
                originx  = get_arg_by_key(value.args, "originx", tonumber),
                originy  = get_arg_by_key(value.args, "originy", tonumber),
            }
            assert_no_nils(expected_args)
            local animation_table = avatar.animations[currently_parsing_animation_name]
            local frames_table = animation_table.frames
            frames_table[#frames_table + 1] = expected_args
            animation_table.total_duration_ms = animation_table.total_duration_ms + expected_args.duration
        end
    end

    return avatar
end

--- Parse an animation file (.animation) from disk into a Lua table.
--- This function works for any .animation file path, not just those belonging to an avatar.
--- @param filepath string path to the .animation file
--- @return table|nil parsed animation structure, or nil on failure
avatar_utils.parse_animation_file = function(filepath)
    print('Parsing animation file: ' .. filepath)

    local file, err = io.open(filepath, "r")
    if not file then
        print("Animation file not found: " .. filepath .. ", error: " .. tostring(err))
        return nil
    end
    local content = file:read("*a")
    file:close()

    return avatar_utils.parse_animation_data(content)
end

return avatar_utils