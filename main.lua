local helpers = require('scripts/ezlibs-scripts/helpers')
local ezencounters = require('scripts/ezlibs-scripts/ezencounters/main')
local eznpcs = require('scripts/ezlibs-scripts/eznpcs/eznpcs')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local ezmystery = require('scripts/ezlibs-scripts/ezmystery')
local ezweather = require('scripts/ezlibs-scripts/ezweather')
local ezwarps = require('scripts/ezlibs-scripts/ezwarps/main')
local ezfarms = require('scripts/ezlibs-scripts/ezfarms')

--local plugins = {ezweather,eznpcs,ezmemory,ezmystery,ezfarms,ezwarps,ezencounters}

local plugins = {ezweather,eznpcs,ezmemory,ezmystery,ezwarps,ezencounters,ezfarms}

local sfx = {
    hurt='/server/assets/ezlibs-assets/sfx/hurt.ogg',
    item_get='/server/assets/ezlibs-assets/sfx/item_get.ogg',
    recover='/server/assets/ezlibs-assets/sfx/recover.ogg',
    card_error='/server/assets/ezlibs-assets/ezfarms/card_error.ogg'
}

local custom_script_path = 'scripts/ezlibs-custom/custom'
local custom_plugin = helpers.safe_require(custom_script_path)
if custom_plugin then
    plugins[#plugins+1] = custom_plugin
end

eznpcs.load_npcs()

function handle_battle_results(player_id, stats)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_battle_results then
            plugin.handle_battle_results(player_id, stats)
        end
    end
end

function handle_shop_purchase(player_id, item_name)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_shop_purchase then
            plugin.handle_shop_purchase(player_id, item_name)
        end
    end
end

function handle_shop_close(player_id)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_shop_close then
            plugin.handle_shop_close(player_id)
        end
    end
end

function handle_custom_warp(player_id, object_id)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_custom_warp then
            plugin.handle_custom_warp(player_id, object_id)
        end
    end
end

function handle_player_move(player_id, x, y, z)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_player_move then
            plugin.handle_player_move(player_id, x, y, z)
        end
    end
end

function handle_player_request(player_id, data)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_player_request then
            plugin.handle_player_request(player_id, data)
        end
    end
end

--Pass handlers on to all the libraries we are using
function handle_tile_interaction(player_id, x, y, z, button)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_tile_interaction then
            plugin.handle_tile_interaction(player_id, x, y, z, button)
        end
    end
end

function handle_post_selection(player_id, post_id)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_post_selection then
            plugin.handle_post_selection(player_id, post_id)
        end
    end
end

function handle_board_close(player_id)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_board_close then
            plugin.handle_board_close(player_id)
        end
    end
end

function handle_player_avatar_change(player_id, details)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_player_avatar_change then
            plugin.handle_player_avatar_change(player_id, details)
        end
    end
end

function handle_player_join(player_id)

    for i,plugin in ipairs(plugins)do
        if plugin.handle_player_join then
            plugin.handle_player_join(player_id)
        end
    end
    --Provide assets for custom events
    for name,path in pairs(sfx) do
        Net.provide_asset_for_player(player_id, path)
    end
end

function handle_actor_interaction(player_id, actor_id, button)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_actor_interaction then
            plugin.handle_actor_interaction(player_id,actor_id, button)
        end
    end
end

function tick(delta_time)
    for i,plugin in ipairs(plugins)do
        if plugin.on_tick then
            plugin.on_tick(delta_time)
        end
    end
end

function handle_player_disconnect(player_id)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_player_disconnect then
            plugin.handle_player_disconnect(player_id)
        end
    end
end
function handle_object_interaction(player_id, object_id, button)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_object_interaction then
            plugin.handle_object_interaction(player_id,object_id, button)
        end
    end
end
function handle_player_transfer(player_id)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_player_transfer then
            plugin.handle_player_transfer(player_id)
        end
    end
end
function handle_textbox_response(player_id, response)
    for i,plugin in ipairs(plugins)do
        if plugin.handle_textbox_response then
            plugin.handle_textbox_response(player_id,response)
        end
    end
end