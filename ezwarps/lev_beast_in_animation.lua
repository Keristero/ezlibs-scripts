local lev_beast_in_animation = {
    --these offsets will modify the warp landing location so that the player can animate from their spawn location nicely
    pre_animation_offsets={
        x=0,
        y=0,
        z=0
    },
    animate=function(player_id)
        return async(function()
            local player_pos = Net.get_player_position(player_id)
            local area_id = Net.get_player_area(player_id)
            
            local lev_beast_id = "lev_beast"..player_id
            Net.create_bot(lev_beast_id, {
                texture_path = "/server/assets/ezlibs-assets/ezwarps/lev-beast-64-65.png",
                animation_path = "/server/assets/ezlibs-assets/ezwarps/lev-beast-64-65.animation",
                area_id = area_id,
                x = player_pos.x,
                y = player_pos.y-5,
                z = player_pos.z+5
            })

            local beast_z_offset = 3
            local seconds_arriving = 3
            local seconds_here = 1
            local seconds_leaving = 3

            local player_keyframes = {{
                properties={{
                    property="Y",
                    value=player_pos.y-3,
                },{
                    property="Z",
                    value=player_pos.z+17
                }},
                duration=0
            }}
            player_keyframes[#player_keyframes+1] = {
                properties={{
                    property="Y",
                    ease="Out",
                    value=player_pos.y
                },{
                    property="Z",
                    ease="Out",
                    value=player_pos.z
                }},
                duration=seconds_arriving
            }

            local beast_keyframes = {{
                properties={{
                    property="Y",
                    value=player_pos.y-3,
                },{
                    property="Z",
                    value=player_pos.z+17+beast_z_offset
                }},
                duration=0
            }}
            beast_keyframes[#beast_keyframes+1] = {
                properties={{
                    property="Y",
                    ease="Out",
                    value=player_pos.y
                },{
                    property="Z",
                    ease="Out",
                    value=player_pos.z+beast_z_offset
                }},
                duration=seconds_arriving
            }
            beast_keyframes[#beast_keyframes+1] = {
                properties={{
                    property="Y",
                    value=player_pos.y
                },{
                    property="Z",
                    value=player_pos.z+beast_z_offset
                }},
                duration=seconds_here
            }
            beast_keyframes[#beast_keyframes+1] = {
                properties={{
                    property="Y",
                    ease="In",
                    value=player_pos.y+3
                },{
                    property="Z",
                    ease="In",
                    value=player_pos.z+17+beast_z_offset
                }},
                duration=seconds_leaving
            }
            Net.shake_player_camera(player_id, 3, 1)
            Net.animate_player(player_id, "IDLE_DL",true)
            Net.animate_player_properties(player_id, player_keyframes)
            Net.animate_bot_properties(lev_beast_id, beast_keyframes)
            await(Async.sleep(0.1))

            Net.play_sound(area_id, '/server/assets/ezlibs-assets/ezwarps/lev-bus-arrive.ogg')
            await(Async.sleep(seconds_arriving))

            Net.play_sound(area_id, 'resources/sfx/falzar.ogg')
            Net.shake_player_camera(player_id, 3, 1)
            await(Async.sleep(seconds_here))
            
            Net.play_sound(area_id, '/server/assets/ezlibs-assets/ezwarps/lev-bus-leave.ogg')
            Net.unlock_player_input(player_id)
            await(Async.sleep(seconds_leaving))
            
            Net.remove_bot(lev_beast_id)
        end)
    end
}

return lev_beast_in_animation