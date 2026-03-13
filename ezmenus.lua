local EzEmitter = require('scripts/ezlibs-scripts/ezemitter')

local ezmenus = {}

ezmenus.open_menu = function (player_id,board_name,color,posts)
    local board_emitter = Net.open_board(player_id, board_name, color, posts)
    local custom_emitter = EzEmitter.new()

    -- Forward events
    board_emitter:on("post_selection", function(event)
        custom_emitter:emit("post_selection", event.post_id)
    end)
    board_emitter:on("board_close", function()
        custom_emitter:emit("board_close")
        custom_emitter:destroy()
    end)

    -- Provide async iterator methods
    function custom_emitter:selection_once()
        return async(function()
            local iter = self:async_iter("post_selection")
            for post_id in Async.await(iter) do
                return post_id
            end
        end)
    end

    return custom_emitter
end

return ezmenus