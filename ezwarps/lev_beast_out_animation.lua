local lev_beast_out_animation = {
    --these offsets will modify the warp landing location so that the player can animate from their spawn location nicely
    pre_animation_offsets={
        x=0,
        y=0,
        z=0
    },
    duration = 8,--delay in seconds from start of animation till player warps out
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
            local seconds_intro = 1
            local seconds_arriving = 3
            local seconds_here = 1
            local seconds_leaving = 3

            local player_keyframes = {{
                properties={{
                    property="Y",
                    value=player_pos.y,
                },{
                    property="Z",
                    value=player_pos.z
                }},
                duration=seconds_arriving+seconds_here
            }}
            player_keyframes[#player_keyframes+1] = {
                properties={{
                    property="Y",
                    ease="In",
                    value=player_pos.y+3
                },{
                    property="Z",
                    ease="In",
                    value=player_pos.z+17
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
            local player_mugshot = Net.get_player_mugshot(player_id)
            Net.play_sound(area_id, 'resources/sfx/falzar.ogg')
            Net.shake_player_camera(player_id, 3, 1)
            Net.animate_player(player_id, "IDLE_DL",true)
            await(Async.sleep(seconds_intro))
            Net.play_sound(area_id, '/server/assets/ezlibs-assets/ezwarps/lev-bus-arrive.ogg')
            Net.animate_player_properties(player_id, player_keyframes)
            Net.animate_bot_properties(lev_beast_id, beast_keyframes)
            Net.message_player(player_id, "AHHH! The Lev Beast is here!?", player_mugshot.texture_path, player_mugshot.animation_path)
            await(Async.sleep(seconds_arriving))
            Net.play_sound(area_id, '/server/assets/ezlibs-assets/ezwarps/lev-bus-leave.ogg')
            await(Async.sleep(seconds_here+seconds_leaving))
            Net.remove_bot(lev_beast_id)
        end)
    end
}

return lev_beast_out_animation