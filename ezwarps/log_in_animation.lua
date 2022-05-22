function create_jack_in_out_animation(is_arriving)
    local log_in_animation = {
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
                Net.provide_asset(area_id, "/server/assets/ezlibs-assets/ezwarps/logout.png")
                Net.provide_asset(area_id, "/server/assets/ezlibs-assets/ezwarps/logout.animation")
                local warp_in_effect_id = "warp_in_effect_"..player_id
                print('spawning log in effect bot')
                Net.create_bot(warp_in_effect_id, {
                    warp_in = false,
                    texture_path = "/server/assets/ezlibs-assets/ezwarps/logout.png",
                    animation_path = "/server/assets/ezlibs-assets/ezwarps/logout.animation",
                    area_id = area_id,
                    x = player_pos.x+0.2,
                    y = player_pos.y+0.2,
                    z = player_pos.z
                })
                if is_arriving then
                    Net.animate_bot(warp_in_effect_id, "JACK_IN", false)
                    Net.play_sound(area_id, '/server/assets/ezlibs-assets/ezwarps/log_in.ogg')
                else
                    Net.animate_bot(warp_in_effect_id, "JACK_OUT", false)
                    Net.play_sound(area_id, '/server/assets/ezlibs-assets/ezwarps/log_out.ogg')
                end
                local duration = 1.0
                local vanish_time = 0.4

                local player_keyframes = {{
                    properties={{
                        property="Y",
                        value=player_pos.y,
                    },{
                        property="Z",
                        value=player_pos.z
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
                    duration=duration
                }

                Net.animate_player_properties(player_id, player_keyframes)

                await(Async.sleep(vanish_time))
                local players = Net.list_players(area_id)
                for i, nearby_player_id in next, players do
                    if is_arriving then
                        Net.include_actor_for_player(nearby_player_id, player_id)
                    else
                        Net.exclude_actor_for_player(nearby_player_id, player_id)
                    end
                end
                await(Async.sleep(duration))
                Net.unlock_player_camera(player_id)
                Net.remove_bot(warp_in_effect_id)
            end)
        end
    }

    return log_in_animation
end

return create_jack_in_out_animation