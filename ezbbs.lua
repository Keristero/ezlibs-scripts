-- ezbbs.lua - Bulletin Board System for ezlibs
-- Handles board interaction, posting, pinning, deleting.
-- Uses ezusers for permission checks.
-- Board data stored in memory/board/<board_name>.json (path from ezconfig).

local json = require("scripts/libs/json")
local ezusers = require("scripts/ezlibs-scripts/ezusers")
local helpers = require("scripts/ezlibs-scripts/helpers")
local ezconfig = require("scripts/ezlibs-scripts/ezconfig")  -- load config

-- Async helpers (only used for admin prompts)
local async = helpers.async or function(p) local co = coroutine.create(p) return Async.promisify(co) end
local await = helpers.await or Async.await

local BOARDS_DIR = ezconfig.BOARD_PATH_FOLDER  -- from config (should end with '/')
local TITLE_LIMIT = 14
local AUTHOR_LIMIT = 7

-- Module state
local last_read_time = {}
local player_states = {}
local board_cache = {}          -- cache: board_name -> data (posts, next_id)

-- Ensure boards directory exists using the helper
helpers.ensure_directory(BOARDS_DIR)

-- ----------------------------------------------------------------------
-- Helper functions
-- ----------------------------------------------------------------------
local function shallow_copy(original)
    local copy = {}
    for k, v in pairs(original) do copy[k] = v end
    return copy
end

local function contains_only_whitespace(text)
    return not string.find(text, "[^ \t\r\n]")
end

local function sanitize_title(text, limit)
    return string.sub(string.gsub(text, "[\t\r\n]", " ", limit), 1, limit)
end

local function bbs_compare_pinned(a, b)
    local at = tonumber(a.pin_time or a.time) or 0
    local bt = tonumber(b.pin_time or b.time) or 0
    if at ~= bt then return at > bt end
    local at2 = tonumber(a.time) or 0
    local bt2 = tonumber(b.time) or 0
    if at2 ~= bt2 then return at2 > bt2 end
    return tostring(a.id) > tostring(b.id)
end

local function bbs_compare_unpinned(a, b)
    local at = tonumber(a.time) or 0
    local bt = tonumber(b.time) or 0
    if at ~= bt then return at > bt end
    return tostring(a.id) > tostring(b.id)
end

local function bbs_display_order_ids(board_data)
    local pinned, unpinned = {}, {}
    local posts_table = (board_data and board_data.posts) or {}
    for _, p in ipairs(posts_table) do
        if p.pin then
            pinned[#pinned+1] = p
        else
            unpinned[#unpinned+1] = p
        end
    end
    table.sort(pinned, bbs_compare_pinned)
    table.sort(unpinned, bbs_compare_unpinned)
    local ids = {}
    for _, p in ipairs(pinned) do ids[#ids+1] = p.id end
    for _, p in ipairs(unpinned) do ids[#ids+1] = p.id end
    return ids, pinned, unpinned
end

-- ----------------------------------------------------------------------
-- Board saving
-- ----------------------------------------------------------------------
local saving = {}
local pending_save = {}
local function save_board(board_name)
    if saving[board_name] then
        pending_save[board_name] = true
        return
    end

    local data = board_cache[board_name]
    if not data then return end

    saving[board_name] = true
    local filename = BOARDS_DIR .. board_name:gsub("[^%w_%-]", "_") .. ".json"
    Async.write_file(filename, json.encode(data, true)).and_then(function()
        saving[board_name] = false
        if pending_save[board_name] then
            pending_save[board_name] = false
            save_board(board_name)
        end
    end)
end

-- ----------------------------------------------------------------------
-- Post creation and display functions
-- ----------------------------------------------------------------------
local function push_post(board_name, area_id, post)
    local board_data = board_cache[board_name]
    if not board_data then return end

    local next_id = nil
    local posts = board_data.posts
    for i = #posts, 1, -1 do
        if not posts[i].pin then
            next_id = posts[i].id
            break
        end
    end
    local push_func = next_id and Net.prepend_posts or Net.append_posts
    local new_posts = { post }
    for _, pid in ipairs(Net.list_players(area_id)) do
        push_func(pid, new_posts, next_id)
    end
end

local function show_post(player_id, post_id)
    local state = player_states[player_id]
    if not state then return end
    local board_data = board_cache[state.board_name]
    if not board_data then return end
    for _, p in ipairs(board_data.posts) do
        if p.id == post_id then
            Net.message_player(player_id, p.body)
            break
        end
    end
end

local function create_post(player_id, state)
    local board = Net.get_object_by_id(state.area_id, state.board_id)
    local board_data = board_cache[state.board_name]
    if not board_data then
        board_data = { posts = {}, next_id = 1 }
        board_cache[state.board_name] = board_data
        save_board(state.board_name)  -- ensure file exists on first post
    end

    local player_name = Net.get_player_name(player_id)
    local char_limit = tonumber(board.custom_properties and board.custom_properties["Character Limit"]) or 256

    local title = state.submission_title
    if contains_only_whitespace(title) then
        title = state.submission_text
    end

    local post = {
        time = os.time(),
        author = sanitize_title(player_name, AUTHOR_LIMIT),
        title = sanitize_title(title, TITLE_LIMIT),
        id = tostring(board_data.next_id),
        body = string.sub(state.submission_text, 1, char_limit),
        pin = false,
    }

    board_data.next_id = board_data.next_id + 1

    local post_limit = tonumber(board.custom_properties and board.custom_properties["Post Limit"]) or 50
    if #board_data.posts >= post_limit then
        for i, old in ipairs(board_data.posts) do
            if not old.pin then
                table.remove(board_data.posts, i)
                break
            end
        end
    end

    table.insert(board_data.posts, post)
    save_board(state.board_name)

    push_post(state.board_name, state.area_id, post)
end

-- ----------------------------------------------------------------------
-- Board loading with callback (and auto‑creation)
-- ----------------------------------------------------------------------
local function load_board(name, callback)
    -- If already cached, call callback immediately
    if board_cache[name] then
        callback(board_cache[name])
        return
    end

    -- Load from file
    local filename = BOARDS_DIR .. name:gsub("[^%w_%-]", "_") .. ".json"
    Async.read_file(filename).and_then(function(content)
        local data
        if content and content ~= "" then
            local ok, decoded = pcall(json.decode, content)
            if ok then
                data = decoded
            end
        end
        if not data then
            data = { posts = {}, next_id = 1 }
            board_cache[name] = data
            -- Save the newly created board to disk immediately
            save_board(name)
            print("[ezbbs] Created board file for:", name)
        else
            board_cache[name] = data
            print("[ezbbs] Loaded board:", name)
        end
        callback(data)
    end)
end


-- ----------------------------------------------------------------------
-- Board opening (shared)
-- ----------------------------------------------------------------------
local function open_board_with_data(board_data, player_id, board_name, color, postable, area_id, board_id)
    -- Build post list for display
    local posts = { { id = "POST", read = true, title = "POST" } }
    local last_time = last_read_time[player_id]

    if board_data then
        local _, pinned, unpinned = bbs_display_order_ids(board_data)
        local function add_display_post(src)
            local post = shallow_copy(src)
            if post.pin then
                post.title = "PIN: " .. string.sub(post.title, 1, TITLE_LIMIT - 5)
            else
                post.title = string.sub(post.title, 1, TITLE_LIMIT)
            end
            local t = tonumber(post.time) or 0
            if last_time == nil or t < last_time then
                post.read = true
            end
            posts[#posts + 1] = post
        end
        for _, p in ipairs(pinned) do add_display_post(p) end
        for _, p in ipairs(unpinned) do add_display_post(p) end
    end

    Net.open_board(player_id, board_name, color, posts)

    player_states[player_id] = {
        status = "READING",
        area_id = area_id,
        board_id = board_id,
        board_name = board_name,
        current_board_postable = postable,
    }
end

local function load_board_and_open(name, player_id, area_id, object, color, postable)
    load_board(name, function(board_data)
        open_board_with_data(board_data, player_id, name, color, postable, area_id, object.id)
    end)
end

-- ----------------------------------------------------------------------
-- Preload all boards at startup (create missing files)
-- ----------------------------------------------------------------------
local function preload_boards()
    print("[ezbbs] Preloading boards...")
    local areas = Net.list_areas()
    local board_names = {}
    for _, area_id in ipairs(areas) do
        local objects = Net.list_objects(area_id)
        for _, object_id in ipairs(objects) do
            local obj = Net.get_object_by_id(area_id, object_id)
            if obj and obj.custom_properties and obj.custom_properties.BBS then
                local name = obj.custom_properties.Name
                if name and not board_names[name] then
                    board_names[name] = true
                    -- Initiate load (callback does nothing, but ensures file is created)
                    load_board(name, function() end)
                end
            end
        end
    end
    print("[ezbbs] Preload initiated for " .. #board_names .. " boards.")
end

-- ----------------------------------------------------------------------
-- Plugin hooks
-- ----------------------------------------------------------------------
local ezbbs = {}

function ezbbs.handle_player_join(player_id)
    last_read_time[player_id] = os.time()
end

function ezbbs.handle_player_disconnect(player_id)
    last_read_time[player_id] = nil
    player_states[player_id] = nil
end

function ezbbs.handle_object_interaction(player_id, object_id, button)
    if button ~= 0 then return end
    local area_id = Net.get_player_area(player_id)
    local object = Net.get_object_by_id(area_id, object_id)
    if not object then return end

    -- BBS board only (Admin Console is handled by ezusers)
    if not object.custom_properties or not object.custom_properties.BBS then return end

    local name = object.custom_properties.Name
    local color_string = object.custom_properties.Color
    if not name or not color_string then
        print("[ezbbs] Board missing Name or Color property")
        return
    end

    -- Postable flag
    local postable = true
    if object.custom_properties.Postable ~= nil then
        postable = (object.custom_properties.Postable == true)
    end

    -- Parse color (#RRGGBB)
    local color = {
        r = tonumber(string.sub(color_string, 4, 5), 16) or 0,
        g = tonumber(string.sub(color_string, 6, 7), 16) or 0,
        b = tonumber(string.sub(color_string, 8, 9), 16) or 0,
    }

    -- Load board and open when ready
    load_board_and_open(name, player_id, area_id, object, color, postable)
end

function ezbbs.handle_post_selection(player_id, post_id)
    local state = player_states[player_id]
    if not state then return end

    local board_name = state.board_name
    local board_data = board_cache[board_name]  -- should be loaded already
    if not board_data then
        print("[ezbbs] Board data not loaded for", board_name)
        return
    end

    local has_admin_perm = ezusers.has_permission(player_id, "BBS.CanPin")  -- treat as admin

    if post_id == "POST" then
        -- New post button
        if state.current_board_postable or has_admin_perm then
            local board = Net.get_object_by_id(state.area_id, state.board_id)
            local char_limit = board.custom_properties and board.custom_properties["Character Limit"]
            Net.prompt_player(player_id, char_limit)
            state.status = "EDITING"
        else
            Net.message_player(player_id, "It appears you do not have permission to post here...")
        end
        return
    end

    -- Regular post selected
    if has_admin_perm then
        -- Admin options
        async(function()
            local choice = await(Async.quiz_player(player_id, "Show Post", "Pin Post", "Delete Post"))
            if choice == 0 then
                show_post(player_id, post_id)
            elseif choice == 1 then
                -- Pin/unpin
                if not ezusers.has_permission(player_id, "BBS.CanPin") then
                    Net.message_player(player_id, "You don't have permission to pin posts.")
                    return
                end
                local post = nil
                for _, p in ipairs(board_data.posts) do
                    if p.id == post_id then post = p; break end
                end
                if not post then return end
                post.pin = not post.pin
                if post.pin then
                    post.pin_time = os.time()
                else
                    post.pin_time = nil
                end
                save_board(board_name)

                -- Update all viewers
                local viewers = {}
                for pid, st in pairs(player_states) do
                    if st.board_name == board_name then viewers[#viewers+1] = pid end
                end
                local ordered_ids = bbs_display_order_ids(board_data)
                local anchor_id = "POST"
                for i, id in ipairs(ordered_ids) do
                    if id == post_id then
                        anchor_id = (i == 1) and "POST" or ordered_ids[i-1]
                        break
                    end
                end
                local base_display = shallow_copy(post)
                if post.pin then
                    base_display.title = "PIN: " .. string.sub(base_display.title, 1, TITLE_LIMIT-5)
                else
                    base_display.title = string.sub(base_display.title, 1, TITLE_LIMIT)
                end
                for _, pid in ipairs(viewers) do
                    local display = shallow_copy(base_display)
                    local t = tonumber(post.time) or 0
                    local last = last_read_time[pid]
                    if last == nil or t < last then display.read = true end
                    Net.remove_post(pid, post_id)
                    Net.append_posts(pid, { display }, anchor_id)
                end
            elseif choice == 2 then
                -- Delete post
                if not ezusers.has_permission(player_id, "BBS.CanDelete") then
                    Net.message_player(player_id, "You don't have permission to delete posts.")
                    return
                end
                for i, p in ipairs(board_data.posts) do
                    if p.id == post_id then
                        table.remove(board_data.posts, i)
                        break
                    end
                end
                save_board(board_name)
                for pid, st in pairs(player_states) do
                    if st.board_name == board_name then
                        Net.remove_post(pid, post_id)
                    end
                end
            end
        end)  -- called immediately
    else
        -- Regular user: just show post
        show_post(player_id, post_id)
    end
end

function ezbbs.handle_textbox_response(player_id, response)
    local state = player_states[player_id]
    if not state then return end

    if state.status == "EDITING" then
        if not contains_only_whitespace(response) then
            state.submission_text = response
            state.status = "SUBMITTING"
            Net.question_player(player_id, "Do you want to submit?")
        else
            state.status = "READING"
        end
    elseif state.status == "SUBMITTING" then
        if response == 1 then
            Net.message_player(player_id, "Title:")
            Net.prompt_player(player_id, TITLE_LIMIT, sanitize_title(state.submission_text, TITLE_LIMIT))
            state.status = "INFORMED_OF_INPUT"
        else
            state.status = "READING"
        end
    elseif state.status == "INFORMED_OF_INPUT" then
        state.status = "TITLING"
    elseif state.status == "TITLING" then
        state.submission_title = response
        create_post(player_id, state)
        state.status = "READING"
    end
end

function ezbbs.handle_board_close(player_id)
    last_read_time[player_id] = os.time()
end

-- Start preloading boards after module load
preload_boards()

return ezbbs