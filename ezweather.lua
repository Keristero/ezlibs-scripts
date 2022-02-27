local ezweather = {}

local volatile_memory = {}

--On server start, record the default custom properties for each area that might be overwritten if the weather changes
--TODO, support areas being added during server runtime
local fine_weather_properties = {}
local areas = Net.list_areas()
local weather_properties = {"Song","Foreground Animation","Foreground Texture","Foreground Parallax","Foreground Vel X","Foreground Vel Y"}
for i, area_id in ipairs(areas) do
    local area_custom_properties = Net.get_area_custom_properties(area_id)
    fine_weather_properties[area_id] = {}
    for i, property_name in ipairs(weather_properties) do
        if area_custom_properties[property_name] ~= nil then
            --store the default property for returning the weather to normal later
            fine_weather_properties[area_id][property_name] = area_custom_properties[property_name]
        else
            fine_weather_properties[area_id][property_name] = ""
        end
    end
end

function ezweather.start_rain_in_area(area_id)
    print('[ezweather] starting rain in '..area_id)

    volatile_memory[area_id] = {
        type="rain",
        camera_tint={r=10, g=10, b=40, a=120}
    }

    local area_custom_properties = Net.get_area_custom_properties(area_id)
    if area_custom_properties["Rain Song"] then
        Net.set_song(area_id, area_custom_properties["Rain Song"])
    end

    Net.set_area_custom_property(area_id, "Foreground Animation", "/server/assets/ezlibs-assets/ezweather/rain.animation")
    Net.set_area_custom_property(area_id, "Foreground Texture", "/server/assets/ezlibs-assets/ezweather/rain.png")
    Net.set_area_custom_property(area_id, "Foreground Parallax", 1.3)
    Net.set_area_custom_property(area_id, "Foreground Vel X", 0.2)
    Net.set_area_custom_property(area_id, "Foreground Vel Y", 0.3)

    fade_camera_for_players_in_area(area_id)
end

function ezweather.start_snow_in_area(area_id)
    print('[ezweather] starting snow in '..area_id)

    volatile_memory[area_id] = {
        type="snow",
        camera_tint={r=255, g=255, b=255, a=40}
    }

    local area_custom_properties = Net.get_area_custom_properties(area_id)
    if area_custom_properties["Snow Song"] then
        Net.set_song(area_id, area_custom_properties["Snow Song"])
    end

    Net.set_area_custom_property(area_id, "Foreground Animation", "/server/assets/ezlibs-assets/ezweather/snow.animation")
    Net.set_area_custom_property(area_id, "Foreground Texture", "/server/assets/ezlibs-assets/ezweather/snow.png")
    Net.set_area_custom_property(area_id, "Foreground Parallax", 1.3)
    Net.set_area_custom_property(area_id, "Foreground Vel X", 0.2)
    Net.set_area_custom_property(area_id, "Foreground Vel Y", -0.1)

    fade_camera_for_players_in_area(area_id)
end

function ezweather.start_fog_in_area(area_id)
    print('[ezweather] starting fog in '..area_id)

    volatile_memory[area_id] = {
        type="fog",
        camera_tint={r=0, g=0, b=0, a=0}
    }

    Net.set_area_custom_property(area_id, "Foreground Animation", "/server/assets/ezlibs-assets/ezweather/fog.animation")
    Net.set_area_custom_property(area_id, "Foreground Texture", "/server/assets/ezlibs-assets/ezweather/fog.png")
    Net.set_area_custom_property(area_id, "Foreground Parallax", 0.0)
    Net.set_area_custom_property(area_id, "Foreground Vel X", 0.05)
    Net.set_area_custom_property(area_id, "Foreground Vel Y", 0.05)

    fade_camera_for_players_in_area(area_id)
end

function fade_camera_for_players_in_area(area_id)
    local players_in_area = Net.list_players(area_id)
    for i, player_id in ipairs(players_in_area) do
        Net.fade_player_camera(player_id, volatile_memory[area_id].camera_tint, 1)
    end
end

function ezweather.get_area_weather(area_id)
    if not volatile_memory[area_id] then
        volatile_memory[area_id] = {camera_tint={r=0, g=0, b=0, a=0},type="clear"}
    end
    return volatile_memory[area_id]
end


function ezweather.clear_weather_in_area(area_id)
    print('[ezweather] restoring fine weather properties for '..area_id)

    --fade camera to no tint
    volatile_memory[area_id] = {camera_tint={r=0, g=0, b=0, a=0},type="clear"}
    fade_camera_for_players_in_area(area_id)

    --restore default properties
    for property_name, property_value in pairs(fine_weather_properties[area_id]) do
        Net.set_area_custom_property(area_id, property_name, property_value)
    end

    --set the song to to change the music, not sure if it is needed?
    --if fine_weather_properties[area_id].song then
    --    Net.set_song(area_id,fine_weather_properties[area_id].song)
    --end
end

function ezweather.handle_player_transfer(player_id)
    print('[ezweather] player transfered '..player_id)
    local area_id = Net.get_player_area(player_id)
    local area_weather = ezweather.get_area_weather(area_id)
    Net.fade_player_camera(player_id, area_weather.camera_tint, 1)
end

function ezweather.handle_player_join(player_id)
    print('[ezweather] player joined '..player_id)
    local area_id = Net.get_player_area(player_id)
    local area_weather = ezweather.get_area_weather(area_id)
    Net.fade_player_camera(player_id, area_weather.camera_tint, 1)
end

return ezweather