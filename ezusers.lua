-- ezusers.lua
-- A flexible user/role/permission system for your server.
-- Stores each player's role and a full copy of their permissions in ezmemory.
-- Permissions are defined per role in the global `permissions` table.
-- Per‑user permissions can be overridden without changing the role.
-- Integrates with ezlibs via standard plugin hooks: handle_player_join, handle_player_disconnect.

local helpers = require('scripts/ezlibs-scripts/helpers')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local sha = require("scripts/ezlibs-scripts/sha256")
local ezconfig = require('scripts/ezlibs-scripts/ezconfig')  -- load server config

-- ============================================================================
-- Compute admin password hash from the plaintext seed in config
-- ============================================================================
local admin_password_hash
if ezconfig.ADMIN_SEED and ezconfig.ADMIN_SEED ~= "" then
    admin_password_hash = sha.sha256(ezconfig.ADMIN_SEED)
    print("[ezusers] Admin password hash computed from seed.")
else
    admin_password_hash = ""
    print("[ezusers] WARNING: ADMIN_SEED not set in config – admin access disabled.")
end

-- ============================================================================
-- Permission definitions – easily extendable
-- ============================================================================
local permissions = {
    user = {
        BBS = {
            CanRead = true,
            CanPost = false,
            CanEdit = false,
            CanDelete = false,
            CanPin = false,
        },
        Commands = {
            CanAccess = false,   -- users cannot use any commands by default
        },
    },
    admin = {
        BBS = {
            CanRead = true,
            CanPost = true,
            CanEdit = true,
            CanDelete = true,
            CanPin = true,
        },
        Commands = {
            CanAccess = true,
            CanWarp = true,
            CanGiftItem = true,
            CanTakeItem = true,
            CanKickUser = true,
        },
    },
    -- Add more roles here later, e.g.:
    -- moderator = { ... }
}

-- ============================================================================
-- Internal helpers
-- ============================================================================
local function async(p)
    local co = coroutine.create(p)
    return Async.promisify(co)
end

local function await(v)
    return Async.await(v)
end

-- Deep copy a table (for copying permission structures)
local function deep_copy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deep_copy(orig_key)] = deep_copy(orig_value)
        end
        setmetatable(copy, deep_copy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

-- Get player safe secret (urlencoded) for ezmemory
local function get_safe_secret(player_id)
    return helpers.get_safe_player_secret(player_id)
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Returns the role string for a player (defaults to "user")
function get_role(player_id)
    local safe = get_safe_secret(player_id)
    if not safe then return "user" end
    local mem = ezmemory.get_player_memory(safe)
    if mem.role == nil then
        mem.role = "user"
        mem.permissions = deep_copy(permissions.user)
        ezmemory.save_player_memory(safe)
        print("[ezusers] get_role: initialized role and permissions for player", player_id, "safe:", safe)
    end
    return mem.role
end

-- Assign a role to a player. This also resets their permissions to the new role's defaults.
-- Returns true if successful, false if player_id invalid
function assign_role(player_id, role)
    print("[ezusers] assign_role called for player", player_id, "with role", role)
    local safe = get_safe_secret(player_id)
    if not safe then
        print("[ezusers] Cannot assign role – no safe secret for player", player_id)
        return false
    end
    if not permissions[role] then
        print("[ezusers] Role '" .. tostring(role) .. "' does not exist.")
        return false
    end
    local mem = ezmemory.get_player_memory(safe)
    mem.role = role
    mem.permissions = deep_copy(permissions[role])
    ezmemory.save_player_memory(safe)
    print("[ezusers] Assigned role", role, "to player", player_id, "(safe:", safe, ") and saved.")
    return true
end

-- Get a player's full permission table (for inspection or direct use)
function get_user_permissions(player_id)
    local safe = get_safe_secret(player_id)
    if not safe then return nil end
    local mem = ezmemory.get_player_memory(safe)
    if mem.permissions == nil then
        -- Fallback: initialize from role
        local role = mem.role or "user"
        mem.permissions = deep_copy(permissions[role] or permissions.user)
        ezmemory.save_player_memory(safe)
    end
    return mem.permissions
end

-- Set a specific permission for a player.
-- permission_path can be a dot‑separated string (e.g., "BBS.CanPost") or a table of keys.
-- value is the new permission value (usually boolean).
function set_user_permission(player_id, permission_path, value)
    local safe = get_safe_secret(player_id)
    if not safe then return false end
    local mem = ezmemory.get_player_memory(safe)
    if mem.permissions == nil then
        local role = mem.role or "user"
        mem.permissions = deep_copy(permissions[role] or permissions.user)
    end

    -- Normalize permission_path to a table
    local path
    if type(permission_path) == "string" then
        path = {}
        for part in permission_path:gmatch("[^.]+") do
            table.insert(path, part)
        end
    else
        path = permission_path
    end

    -- Traverse to the parent table
    local parent = mem.permissions
    for i = 1, #path - 1 do
        local key = path[i]
        if type(parent[key]) ~= "table" then
            parent[key] = {}  -- create missing tables
        end
        parent = parent[key]
    end
    parent[path[#path]] = value

    ezmemory.save_player_memory(safe)
    return true
end

-- Reset a player's permissions to their role's defaults (discarding any overrides)
function reset_user_permissions(player_id)
    local safe = get_safe_secret(player_id)
    if not safe then return false end
    local mem = ezmemory.get_player_memory(safe)
    local role = mem.role or "user"
    mem.permissions = deep_copy(permissions[role] or permissions.user)
    ezmemory.save_player_memory(safe)
    return true
end

-- Check if a player has a specific permission.
-- permission_path can be a dot‑separated string (e.g., "BBS.CanPost")
-- or a table of keys (e.g., {"BBS", "CanPost"}).
-- Returns the permission value (usually boolean) or nil if not found.
function has_permission(player_id, permission_path)
    local perms = get_user_permissions(player_id)  -- ensures permissions exist
    if not perms then return nil end

    -- Normalize permission_path to a table
    local path
    if type(permission_path) == "string" then
        path = {}
        for part in permission_path:gmatch("[^.]+") do
            table.insert(path, part)
        end
    else
        path = permission_path
    end

    -- Traverse the permission table
    local current = perms
    for _, key in ipairs(path) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[key]
        if current == nil then
            return nil
        end
    end
    return current
end

-- Verify a password attempt; if correct, grant the player the "admin" role.
-- Returns true if password correct and role assigned, false otherwise.
function check_password_and_grant_admin(player_id, password_attempt)
    print("[ezusers] Password attempt for player", player_id)
    if sha.sha256(password_attempt) == admin_password_hash then
        print("[ezusers] Password correct, granting admin")
        return assign_role(player_id, "admin")
    else
        print("[ezusers] Password incorrect")
        return false
    end
end

-- (Optional) Add a new role with its permission table.
-- Use this to extend the system dynamically.
function add_role(role_name, permission_table)
    permissions[role_name] = permission_table
    print("[ezusers] Added new role:", role_name)
end

-- (Optional) Update permissions for an existing role (merges with current).
-- If a permission path exists, it is overwritten; otherwise added.
function update_permissions(role_name, permission_updates)
    local current = permissions[role_name]
    if not current then
        print("[ezusers] Role '" .. role_name .. "' does not exist. Use add_role first.")
        return
    end
    -- Simple shallow merge – you can make this recursive if needed
    for k, v in pairs(permission_updates) do
        current[k] = v
    end
    print("[ezusers] Updated permissions for role:", role_name)
end

-- ============================================================================
-- ezlibs plugin hooks
-- ============================================================================

-- Called when a player joins: ensure they have a role and permissions.
function handle_player_join(player_id)
    print("[ezusers] handle_player_join called for player", player_id)
    local safe = get_safe_secret(player_id)
    if not safe then
        print("[ezusers] No safe secret for player", player_id)
        return
    end
    print("[ezusers] Player safe secret:", safe)
    local mem = ezmemory.get_player_memory(safe)
    if mem.role == nil then
        mem.role = "user"
        mem.permissions = deep_copy(permissions.user)
        ezmemory.save_player_memory(safe)
        print("[ezusers] Set role to 'user' and initialized permissions.")
    else
        -- Ensure permissions exist (migration from older version)
        if mem.permissions == nil then
            mem.permissions = deep_copy(permissions[mem.role] or permissions.user)
            ezmemory.save_player_memory(safe)
            print("[ezusers] Migrated: added permissions for existing player.")
        end
    end
end

-- Called when a player disconnects: nothing needed
function handle_player_disconnect(player_id)
    -- nothing to do
end

-- ============================================================================
-- Admin Console object handler (exclusive to ezusers)
-- ============================================================================
local object_registry = require('scripts/ezlibs-scripts/object_registry')
local eztriggers = require('scripts/ezlibs-scripts/eztriggers')

object_registry.register_handler("Admin Console", function(area_id, object)
    -- Create an interact trigger for this object
    local emitter = eztriggers.add_interact_trigger(area_id, object)
    if emitter then
        emitter:on("interaction", function(event)
            local player_id = event.player_id
            -- Use async to handle the password prompt – do NOT return the promise
            async(function()
                -- Check if already admin
                local current_role = get_role(player_id)
                if current_role == "admin" then
                    await(Async.message_player(player_id, "You are already an admin."))
                    return
                end

                -- Ask if they want to enter password
                local question = await(Async.question_player(player_id, "Would you like to enter admin password?"))
                if question == 1 then
                    local password = await(Async.prompt_player(player_id))
                    if check_password_and_grant_admin(player_id, password) then
                        await(Async.message_player(player_id, "Password correct. You are now an admin."))
                    end
                end
            end)  -- called immediately
        end)
    end
end, false) -- cache = false so the object remains visible

-- Return the public API (including plugin hooks)
return {
    get_role = get_role,
    assign_role = assign_role,
    get_user_permissions = get_user_permissions,
    set_user_permission = set_user_permission,
    reset_user_permissions = reset_user_permissions,
    has_permission = has_permission,
    check_password_and_grant_admin = check_password_and_grant_admin,
    add_role = add_role,
    update_permissions = update_permissions,
    handle_player_join = handle_player_join,
    handle_player_disconnect = handle_player_disconnect,
}