local helpers = require('scripts/ezlibs-scripts/helpers')
local eztriggers = require('scripts/ezlibs-scripts/eztriggers')
local ezcache = require('scripts/ezlibs-scripts/ezcache')
local ezencounters = require('scripts/ezlibs-scripts/ezencounters/main')
eznpcs = require('scripts/ezlibs-scripts/eznpcs/eznpcs')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezmystery = require('scripts/ezlibs-scripts/ezmystery')
local ezweather = require('scripts/ezlibs-scripts/ezweather')
local ezwarps = require('scripts/ezlibs-scripts/ezwarps/main')
local ezfarms = require('scripts/ezlibs-scripts/ezfarms')

local plugins = { ezweather, eznpcs, ezmemory, ezmystery, ezwarps, ezencounters, ezfarms ,eztriggers}

local sfx = {
    hurt = '/server/assets/ezlibs-assets/sfx/hurt.ogg',
    item_get = '/server/assets/ezlibs-assets/sfx/item_get.ogg',
    recover = '/server/assets/ezlibs-assets/sfx/recover.ogg',
    card_error = '/server/assets/ezlibs-assets/ezfarms/card_error.ogg'
}

local custom_script_path = 'scripts/ezlibs-custom/custom'
local custom_plugin = helpers.safe_require(custom_script_path)
if custom_plugin then
    plugins[#plugins + 1] = custom_plugin
end

eznpcs.load_npcs()

Net:on("battle_results", function(event)
    local stats = {
        health=event.health,
        time=event.time,
        ran=event.ran,
        emotion=event.emotion,
        turns=event.turns,
        enemies=event.enemies,
        score=event.score
    }
    for i, plugin in ipairs(plugins) do
        if plugin.handle_battle_results then
            plugin.handle_battle_results(event.player_id, stats)
        end
    end
end)

Net:on("shop_purchase", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_shop_purchase then
            plugin.handle_shop_purchase(event.player_id, event.item_name)
        end
    end
end)

Net:on("shop_close", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_shop_close then
            plugin.handle_shop_close(event.player_id)
        end
    end
end)

Net:on("custom_warp", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_custom_warp then
            plugin.handle_custom_warp(event.player_id, event.object_id)
        end
    end
end)

Net:on("player_move", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_player_move then
            plugin.handle_player_move(event.player_id, event.x, event.y, event.z)
        end
    end
end)

Net:on("player_request", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_player_request then
            plugin.handle_player_request(event.player_id, event.data)
        end
    end
end)

--Pass handlers on to all the libraries we are using
Net:on("tile_interaction", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_tile_interaction then
            plugin.handle_tile_interaction(event.player_id, event.x, event.y, event.z, event.button)
        end
    end
end)

Net:on("post_selection", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_post_selection then
            plugin.handle_post_selection(event.player_id, event.post_id)
        end
    end
end)

Net:on("board_close", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_board_close then
            plugin.handle_board_close(event.player_id)
        end
    end
end)

Net:on("player_avatar_change", function(event)
    local details = {
        texture_path=event.texture_path,
        animation_path=event.animation_path,
        name=event.name,
        element=event.element,
        max_health=event.max_health,
        prevent_default=event.prevent_default
    }
    for i, plugin in ipairs(plugins) do
        if plugin.handle_player_avatar_change then
            plugin.handle_player_avatar_change(event.player_id, details)
        end
    end
end)

Net:on("player_join", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_player_join then
            plugin.handle_player_join(event.player_id)
        end
    end
    --Provide assets for custom events
    for name, path in pairs(sfx) do
        Net.provide_asset_for_player(event.player_id, path)
    end
end)

Net:on("actor_interaction", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_actor_interaction then
            plugin.handle_actor_interaction(event.player_id, event.actor_id, event.button)
        end
    end
end)

Net:on("tick", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.on_tick then
            plugin.on_tick(event.delta_time)
        end
    end
end)

Net:on("player_disconnect", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_player_disconnect then
            plugin.handle_player_disconnect(event.player_id)
        end
    end
end)

Net:on("object_interaction", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_object_interaction then
            plugin.handle_object_interaction(event.player_id, event.object_id, event.button)
        end
    end
end)

Net:on("player_area_transfer", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_player_transfer then
            plugin.handle_player_transfer(event.player_id)
        end
    end
end)

Net:on("textbox_response", function(event)
    for i, plugin in ipairs(plugins) do
        if plugin.handle_textbox_response then
            plugin.handle_textbox_response(event.player_id, event.response)
        end
    end
end)
