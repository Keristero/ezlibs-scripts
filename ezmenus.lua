
local ezmenus = {}

ezmenus.open_menu = function (player_id,board_name,color,posts)
    print('opened menu')
    local board_emitter = Net.open_board(player_id, board_name, color, posts)
    board_emitter.close_async = function ()
        return async(function()
            local board_closed = false
            local max_timeout = 2
            board_emitter:on("board_close", function(event)
                board_closed = true
            end)
            Net.close_bbs(player_id)
            while not board_closed and max_timeout > 0 do
                max_timeout = max_timeout - 0.02
                await(Async.sleep(0.02))
            end
        end)
    end
    board_emitter.selection_once = function ()
        return async(function()
            local selection = nil
            local handle_cancel = nil
            handle_cancel = function (event)
                if event.player_id == player_id then
                    Net:remove_listener("player_disconnect", handle_cancel)
                    selection = false
                end
            end
            Net:on("player_disconnect",handle_cancel)
            board_emitter:on("post_selection", function (event)
                selection = event.post_id
            end)
            board_emitter:on("board_close",function (event)
                selection = false
            end)
            while selection == nil do
                await(Async.sleep(0.02))
            end
            return selection
        end)
    end
    return board_emitter
end

return ezmenus