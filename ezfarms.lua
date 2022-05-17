local ezfarms = {}

local eznpcs = require('scripts/ezlibs-scripts/eznpcs/eznpcs')
local ezweather = require('scripts/ezlibs-scripts/ezweather')
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local table = require('table')
local helpers = require('scripts/ezlibs-scripts/helpers')

local players_using_bbs = {}
local player_tools = {}
local farm_area = 'farm'
local area_memory = nil
local delay_till_update = 5 --wait 1 second between updating all farm tiles
local period_multiplier = 1 --1.0 is real time, 0.5 is double speed
local reference_seed

--Try getting the reference seed, if we cant then there is no map set up for ezfarms and we should cancel loading
local status, err = pcall(function ()reference_seed = Net.get_object_by_name(farm_area,"Reference Seed")end)
if err then
    print('[ezfarms] unable to find the holy Reference Seed in '..farm_area..' aborting loading of ezfarms')
    return {}
end

local plant_ram = {}--non persisted plant related values, keyed by loc_string

local PlantData = {
    Parsnip={price=300,growth_time_multi=0.4,local_gid=0,harvest={1,2}},
    Cauliflower={price=1200,growth_time_multi=1.2,local_gid=7,harvest={1,1}},
    Garlic={price=600,growth_time_multi=0.4,local_gid=14,harvest={2,3}},
    Tomato={price=350,growth_time_multi=1.1,local_gid=21,harvest={1,3}},
    Chili={price=600,growth_time_multi=0.5,local_gid=28,harvest={1,1}},
    Radish={price=550,growth_time_multi=0.6,local_gid=35,harvest={1,1}},
    ["Star Fruit"]={price=1800,growth_time_multi=1.3,local_gid=42,harvest={1,2}},
    Eggplant={price=320,growth_time_multi=0.5,local_gid=49,harvest={2,3}},
    Pumpkin={price=1200,growth_time_multi=1.3,local_gid=56,harvest={1,1}},
    Yam={price=900,growth_time_multi=1,local_gid=63,harvest={2,4}},
    Beetroot={price=400,growth_time_multi=1.8,local_gid=70,harvest={1,1}},
    ["Ancient Fruit"]={price=2800,growth_time_multi=2.8,local_gid=77,harvest={1,1}},
    ["Sweet Gem"]={price=3000,growth_time_multi=2.4,local_gid=84,harvest={1,2}},
    Blueberry={price=800,growth_time_multi=1.5,local_gid=91,harvest={2,6}},
    Dead={local_gid=98}
}

--Key = tool name, value = plant/tool name
local ToolNames = {CyberHoe="CyberHoe",CyberWtrCan="CyberWtrCan",CyberScythe="CyberScythe",GigFreez="GigFreez"}
for plant_name, plant in pairs(PlantData) do
    ToolNames[plant_name.." seed"] = plant_name
end

local growth_stage_descriptions = {
    ["0"]="like it was just planted",
    ["1"]="to be growing steadily",
    ["2"]="to be healthy",
    ["3"]="almost ripe for picking!",
    ["4"]="ready for harvest!",
    ["5"]="very sad..."
}

local Tiles = {
    Dirt=85,
    Grass=86,
    DirtWet=87
}

local sfx = {
    item_get='/server/assets/ezlibs-assets/sfx/item_get.ogg',
    card_error='/server/assets/ezlibs-assets/ezfarms/card_error.ogg',
    hoe='/server/assets/ezlibs-assets/ezfarms/hoe.ogg',
    rain='/server/assets/ezlibs-assets/ezfarms/rain.ogg',
    scythe='/server/assets/ezlibs-assets/ezfarms/scythe.ogg',
    swap_tool='/server/assets/ezlibs-assets/ezfarms/swap_tool.ogg',
    water_tile='/server/assets/ezlibs-assets/ezfarms/water_tile.ogg',
    wind='/server/assets/ezlibs-assets/ezfarms/wind.ogg'
}


--periods before certain things happen to tiles
local Period = {
    Minute=60,
    Hour=60*60,
}
Period.EmptyDirtToGrass=Period.Minute*10
Period.GrowthStageTime=Period.Hour*12
Period.PlantedDirtWetToDirt=Period.Hour*4
Period.UnwateredPlantDeath=Period.Hour*36
Period.JustPlantedGracePeriod=Period.Hour*4
Period.RainDuration=Period.Hour*1
Period.WitherTime=Period.Hour*48--Time for a plant to wither after it is fully grown

--for testing, make things take a fraction of the time by reducing all periods!
for period_name, period in pairs(Period) do
    Period[period_name] = period*period_multiplier
end

local farm_loaded = false

local function calculate_plant_sell_price(plant_name)
    local plant = PlantData[plant_name]
    local av_harvest = (plant.harvest[1]+plant.harvest[2])/2
    local price = math.floor(plant.price*((((plant.growth_time_multi*0.4)^1.1)+1)/av_harvest))
    return price
end

for plant_name, plant in pairs(PlantData) do
    if plant_name ~= "Dead" then
        PlantData[plant_name].sell_price = calculate_plant_sell_price(plant_name)
    end
end

local function calculate_plant_gid(plant_name,growth_stage)
    local first_gid = reference_seed.data.gid
    if growth_stage == 0 then
        --if the plant is seeds
        local first_plant_gid = first_gid+PlantData[plant_name].local_gid
        return first_plant_gid + math.random(0,1)
    elseif growth_stage > 0 and growth_stage < 5 then
        --if the plant is growing or grown
        local first_plant_gid = (first_gid+1)+PlantData[plant_name].local_gid
        return first_plant_gid+growth_stage
    else
        --if the plant is dead
        plant_name = "Dead"
        local first_plant_gid = first_gid+PlantData[plant_name].local_gid
        return first_plant_gid + math.random(0,3)
    end
end

local function determine_growth_stage(plant_name,elapsed_since_planted,elpased_since_water,death_time)
    if death_time ~= 0 then
        return 5
    end
    --stage 0 = seeds, stage 1-3 = growing, 4 = grown, 5=dead 
    local plant = PlantData[plant_name]
    local stages = 4
    local unique_growth_stage_time = plant.growth_time_multi*Period.GrowthStageTime
    local death_time = (unique_growth_stage_time*stages)+Period.WitherTime
    local growth_stage = math.min(4,math.floor(elapsed_since_planted/unique_growth_stage_time))
    if elpased_since_water > Period.UnwateredPlantDeath and elapsed_since_planted > Period.JustPlantedGracePeriod then
        print("[ezfarms] a "..plant_name.." dried up and died")
        growth_stage = 5
    end
    if elapsed_since_planted > death_time then
        print("[ezfarms] a "..plant_name.." died of old age")
        growth_stage = 5
    end
    return growth_stage
end

local function update_tile(current_time,loc_string,area_weather)
    local tile_memory = area_memory.tile_states[loc_string]
    local elpased_since_water = current_time-tile_memory.time.watered
    local elapsed_since_tilled = current_time-tile_memory.time.tilled
    local elapsed_since_planted = current_time-tile_memory.time.planted
    local elapsed_since_death = current_time-tile_memory.time.death
    local new_gid = tile_memory.gid --dont change it by default
    local something_changed = false

    --Create or remove plant object when required
    if tile_memory.plant ~= nil then
        --If there is a plant here
        local growth_stage = determine_growth_stage(tile_memory.plant,elapsed_since_planted,elpased_since_water,tile_memory.time.death)
        if tile_memory.time.death == 0 and growth_stage == 5 then
            --plant has just died, so sad, am cry :(
            tile_memory.time.death = current_time
        end
        if not plant_ram[loc_string] then
            --create the plant if it does not exist when it should
            local plant_gid = calculate_plant_gid(tile_memory.plant,growth_stage)
            local plant_tile_data = {
                type = "tile",
                gid=plant_gid,
                flipped_horizontally=false,
                flipped_vertically=false
            }
            local new_plant_data = { 
                name=tile_memory.plant,
                visible=true,
                x=tile_memory.x+0.8,
                y=tile_memory.y+0.8,
                z=tile_memory.z,
                width=0.5,
                height=1,
                data=plant_tile_data
            }
            local new_plant_id = Net.create_object(farm_area, new_plant_data)
            plant_ram[loc_string] = {
                growth_stage=growth_stage,
                id=new_plant_id
            }
            something_changed = true
        else
            if growth_stage ~= plant_ram[loc_string].growth_stage then
                --if a differenet growth stage has been calculated, update the custom property and gid of the object
                print('[ezfarms] a plant changed growth stage! from '..plant_ram[loc_string].growth_stage..' to '..growth_stage)
                local plant_gid = calculate_plant_gid(tile_memory.plant,growth_stage)
                local plant_tile_data = {
                    type = "tile",
                    gid=plant_gid,
                    flipped_horizontally=false,
                    flipped_vertically=false
                }
                plant_ram[loc_string].growth_stage = growth_stage
                Net.set_object_data(farm_area, plant_ram[loc_string].id, plant_tile_data)
            end
        end
    else
        if plant_ram[loc_string] then
            --remove the plant if it exists when it should not
            Net.remove_object(farm_area, plant_ram[loc_string].id)
            plant_ram[loc_string] = nil
            something_changed = true
        end
    end

    --If it is raining, keep the ground wet
    if area_weather and area_weather.type == "rain" then
        tile_memory.time.watered = current_time
    end

    --Change tile between Grass/Dirt/DirtWet when required
    if tile_memory.gid == Tiles.DirtWet then
        if elpased_since_water > Period.PlantedDirtWetToDirt then
            tile_memory.time.tilled = current_time
            new_gid = Tiles.Dirt
            something_changed = true
        end
    elseif tile_memory.gid == Tiles.Dirt then
        if elpased_since_water < Period.PlantedDirtWetToDirt then
            new_gid = Tiles.DirtWet
            something_changed = true
        end
        if tile_memory.plant then
        else
            if elapsed_since_tilled > Period.EmptyDirtToGrass then
                new_gid = Tiles.Grass
                something_changed = true
            end
        end
    end
    --TODO might need to do something with something_changed here? where what was I doing...
    tile_memory.gid = new_gid
    Net.set_tile(farm_area, tile_memory.x, tile_memory.y, tile_memory.z, new_gid)
    return something_changed
end

function load_farm()
    print('[ezfarms] farm area loading')
    area_memory = ezmemory.get_area_memory(farm_area)
    --create tile states if it does not exist
    if not area_memory.tile_states then
        area_memory.tile_states = {}
        ezmemory.save_area_memory(farm_area)
    end
    --load tile states for land
    update_all_tiles()
    --after updating tiles, save memory
    ezmemory.save_area_memory(farm_area)
    farm_loaded = true
end

function update_all_tiles()
    local current_time = os.time()
    local something_changed = false
    local area_weather = ezweather.get_area_weather(farm_area)
    if area_weather.type ~= "clear" then
        if area_memory.rain_started then
            if current_time-area_memory.rain_started > Period.RainDuration then
                ezweather.clear_weather_in_area(farm_area)
            end
        end
    end
    for loc_string, tile_memory in pairs(area_memory.tile_states) do
        if update_tile(current_time,loc_string,area_weather) then
            something_changed = true
        end
    end
    return something_changed
end

function ezfarms.handle_player_join(player_id)
    --Load sound effects for player
    for name,path in pairs(sfx) do
        Net.provide_asset_for_player(player_id, path)
    end
    --Load farm, will skip if it is already loaded.
    load_farm()
end

function ezfarms.on_tick(delta_time)
    if not farm_loaded then
        return
    end
    if delay_till_update > 0 then
        delay_till_update = delay_till_update - delta_time
    else
        local something_changed = update_all_tiles()
        if something_changed then
            ezmemory.save_area_memory(farm_area)
        end
        delay_till_update = 5
    end
end

function ezfarms.handle_post_selection(player_id, post_id)
    if players_using_bbs[player_id] then
        if players_using_bbs[player_id] == "Buy Seeds" then
            try_buy_seed(player_id,post_id)
        elseif players_using_bbs[player_id] == "Select Tool" then
            player_tools[player_id] = post_id
            players_using_bbs[player_id] = nil
            Net.message_player(player_id,"You are now holding "..post_id)
            Net.close_bbs(player_id)
        elseif players_using_bbs[player_id] == "Sell Veggies" then
            local item_count = ezmemory.count_player_item(player_id, post_id)
            local plant = PlantData[post_id]
            local worth = plant.sell_price*item_count
            if worth > 0 then
                ezmemory.spend_player_money(player_id,-worth)
                ezmemory.remove_player_item(player_id,post_id,item_count)
                Net.remove_post(player_id, post_id)
                Net.message_player(player_id,"Sold all "..post_id.." for "..worth.."$!")
                Net.play_sound_for_player(player_id,sfx.item_get)
            end
        end
    end
end

function ezfarms.handle_board_close(player_id)
    players_using_bbs[player_id] = nil
end

function try_buy_seed(player_id,plant_name)
    local price = PlantData[plant_name].price
    if ezmemory.spend_player_money(player_id,price) then
        Net.play_sound_for_player(player_id,sfx.item_get)
        local seed_name = plant_name.." seed"
        ezmemory.get_or_create_item(seed_name, "seed for planting "..plant_name,false)
        ezmemory.give_player_item(player_id, seed_name,1)
    else
        Net.message_player(player_id,"Not enough $")
        Net.play_sound_for_player(player_id,sfx.card_error)
    end
    
end

local function list_plants(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    local plant_counts = {}
    for item_id, quantity in pairs(player_memory.items) do
        local item_info = ezmemory.get_item_info(item_id)
        for plant_name, plant in pairs(PlantData) do
            if plant_name == item_info.name and plant.price then
                --TODO, give plants differnet growth times that affect sell price and regrowths
                plant_counts[plant_name] = quantity
            end
        end
    end
    return plant_counts
end

local veggie_stall = {
    name="veggie_stall",
    action=function (npc,player_id,dialogue)
        return async(function ()
            local board_color = { r= 128, g= 255, b= 128 }
            local posts = {}
            local player_plants = list_plants(player_id)
            for plant_name, sell_price in pairs(player_plants) do
                posts[#posts+1] = { id=plant_name, read=true, title=plant_name , author=tostring(sell_price) }
            end
            local bbs_name = "Sell Veggies"
            players_using_bbs[player_id] = bbs_name
            Net.open_board(player_id, bbs_name, board_color, posts)
        end)
    end
}
eznpcs.add_event(veggie_stall)

function ezfarms.list_player_tools(player_id)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local player_memory = ezmemory.get_player_memory(safe_secret)
    local tool_counts = {}
    for item_id, quantity in pairs(player_memory.items) do
        local tool_info = ezmemory.get_item_info(item_id)
        for tool_name, tool_key in pairs(ToolNames) do
            if tool_info.name == tool_name then
                tool_counts[tool_info.name] = quantity
            end
        end
    end
    return tool_counts
end

function ezfarms.open_held_item_select(player_id)
    local tool_counts = ezfarms.list_player_tools(player_id)
    local board_color = { r= 165, g= 42, b= 42 }
    local posts = {}
    for tool_name, tool_count in pairs(tool_counts) do
        posts[#posts+1] = { id=tool_name, read=true, title=tool_name , author="x "..tostring(tool_count) }
    end
    local bbs_name = "Select Tool"
    players_using_bbs[player_id] = bbs_name
    Net.open_board(player_id, bbs_name, board_color, posts)
end

local function get_location_string(x,y,z)
    return tostring(x)..','..tostring(y)..','..tostring(z)
end

local function till_tile(tile,x,y,z,player_id)
    if tile.gid == Tiles.Grass then
        local tile_loc_string = get_location_string(x,y,z)
        local current_time = os.time()
        area_memory.tile_states[tile_loc_string] = {
            gid=Tiles.Dirt,
            x=x,
            y=y,
            z=z,
            plant=nil,
            time={
                tilled=current_time,
                watered=0,
                planted=0,
                death=0
            }
        }
        Net.play_sound_for_player(player_id,sfx.hoe)
        update_tile(current_time,tile_loc_string)
        ezmemory.save_area_memory(farm_area)
    end
end

function ezfarms.handle_object_interaction(player_id, object_id)
    local player_area = Net.get_player_area(player_id)
    if player_area ~= farm_area then
        return
    end
    local object = Net.get_object_by_id(player_area,object_id)
    if object.type == "Water Refill" then
        if player_tools[player_id] == "CyberWtrCan" then
            local safe_secret = helpers.get_safe_player_secret(player_id)
            local player_memory = ezmemory.get_player_memory(safe_secret)
            if player_memory.farming and player_memory.farming.water == 50 then
                Net.message_player(player_id,"CyberWtrCan is already full...")
            else
                player_memory.farming = {water=50}
                Net.play_sound_for_player(player_id,sfx.water_tile)
                Net.message_player(player_id,"Filled CyberWtrCan")
            end
        else
            local mugshot = Net.get_player_mugshot(player_id)
            Net.message_player(player_id,"\x02I could fill something here...\x02",mugshot.texture_path,mugshot.animation_path)
        end
    end
end

local function water_tile(tile,tile_loc_string,player_id,safe_secret)
    if tile.gid == Tiles.Dirt or tile.gid == Tiles.DirtWet then
        local current_time = os.time()
        local player_memory = ezmemory.get_player_memory(safe_secret)
        if not player_memory.farming then
            player_memory.farming = {water=0}
        end
        if player_memory.farming.water > 0 then
            player_memory.farming.water = player_memory.farming.water - 1
            area_memory.tile_states[tile_loc_string].time.watered = current_time
            area_memory.tile_states[tile_loc_string].gid = Tiles.DirtWet
            Net.play_sound_for_player(player_id,sfx.water_tile)
            update_tile(current_time,tile_loc_string)
            ezmemory.save_area_memory(farm_area)
        else
            Net.message_player(player_id,"CyberWtrCan is out of water...")
        end
    end
end

local function plant(tile_loc_string,player_id,seed,current_time)
    print('[ezfarms] planting '..seed)
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local plant_to_plant = ToolNames[seed]
    area_memory.tile_states[tile_loc_string].time.planted = current_time
    area_memory.tile_states[tile_loc_string].time.death = 0
    area_memory.tile_states[tile_loc_string].plant = plant_to_plant
    area_memory.tile_states[tile_loc_string].owner = safe_secret
    local seeds_remaining = ezmemory.remove_player_item(player_id,seed,1)
    if seeds_remaining < 1 then
        Net.message_player(player_id,"You ran out of "..seed)
        player_tools[player_id] = nil
    end
    update_tile(current_time,tile_loc_string)
    ezmemory.save_area_memory(farm_area)
end

local function deleet_plant(tile_loc_string,current_time)
    area_memory.tile_states[tile_loc_string].plant = nil
    area_memory.tile_states[tile_loc_string].owner = nil
    area_memory.tile_states[tile_loc_string].time.planted = 0
    area_memory.tile_states[tile_loc_string].time.tilled = current_time -- so the dirt does not immediately go back to being grass
    area_memory.tile_states[tile_loc_string].time.death = 0
    update_tile(current_time,tile_loc_string)
    ezmemory.save_area_memory(farm_area)
end

local function scythe_plant(tile_loc_string,current_time,prexisting_plant,player_id)
    if prexisting_plant then
        if prexisting_plant.growth_stage == 5 then
            Net.play_sound_for_player(player_id,sfx.scythe)
            deleet_plant(tile_loc_string,current_time)
        else
            Net.message_player(player_id,"Oak's words echoed... There's a time and place for everything, but not now.")
        end
    end
end

local function harvest(tile_loc_string,player_id,safe_secret,current_time)
    local plant_name = area_memory.tile_states[tile_loc_string].plant
    local plant_info = PlantData[plant_name]
    local harvest_count = math.random(plant_info.harvest[1],plant_info.harvest[2])
    Net.message_player(player_id,"Harvested "..harvest_count.." "..plant_name.."!")
    Net.play_sound_for_player(player_id,sfx.item_get)
    ezmemory.get_or_create_item(plant_name, "mmm, yummy "..plant_name,false)
    ezmemory.give_player_item(player_id, plant_name,harvest_count)
    deleet_plant(tile_loc_string,current_time)
end

local function describe_growth_state(growth_stage)
    return growth_stage_descriptions[tostring(growth_stage)]
end

local function try_harvest(tile_loc_string,prexisting_plant,player_id,safe_secret,current_time)
    local existing_plant_name = area_memory.tile_states[tile_loc_string].plant
    if area_memory.tile_states[tile_loc_string].owner == safe_secret then
        if prexisting_plant.growth_stage == 4 then
            harvest(tile_loc_string,player_id,safe_secret,current_time)
        else
            Net.message_player(player_id,"the "..existing_plant_name.." looks "..describe_growth_state(prexisting_plant.growth_stage))
        end
    else
        local owner_name = ezmemory.get_player_name_from_safesecret(area_memory.tile_states[tile_loc_string].owner)
        Net.message_player(player_id,owner_name.."'s "..existing_plant_name.." looks "..describe_growth_state(prexisting_plant.growth_stage))
    end
end

local function try_plant_seed(tile,tile_loc_string,player_id,seed)
    if tile.gid == Tiles.Dirt or tile.gid == Tiles.DirtWet then
        print("Trying to plant "..seed)
        local safe_secret = helpers.get_safe_player_secret(player_id)
        local current_time = os.time()
        local prexisting_plant = plant_ram[tile_loc_string]
        if not prexisting_plant or prexisting_plant.growth_stage == 5 then
            plant(tile_loc_string,player_id,seed,current_time)
        else
            try_harvest(tile_loc_string,prexisting_plant,player_id,safe_secret,current_time)
        end
    end
end

function ezfarms.handle_tile_interaction(player_id, x, y, z, button)
    local x = math.floor(x)
    local y = math.floor(y)
    local z = math.floor(z)
    local area_id = Net.get_player_area(player_id)
    if area_id ~= farm_area then
        --player is not in farm
        return
    end
    if button == 1 then
        ezfarms.open_held_item_select(player_id)
        return
    end
    if not player_tools[player_id] then
        --player has no tool selected
        return
    end
    --the player tool uses the ToolNames mapping, so "apple seed"="apple"
    local player_tool = player_tools[player_id]
    local tile = Net.get_tile(area_id, x, y, z)

    local tile_loc_string = get_location_string(x,y,z)
    local prexisting_plant = plant_ram[tile_loc_string]
    local safe_secret = helpers.get_safe_player_secret(player_id)
    local current_time = os.time()

    if player_tool == "GigFreez" then
        if ezmemory.count_player_item(player_id,"GigFreez") then
            Net.play_sound(farm_area,sfx.wind)
            local area_weather = ezweather.get_area_weather(farm_area)
            if area_weather.type == "clear" then
                ezweather.start_rain_in_area(farm_area)
                area_memory.rain_started = current_time
            elseif area_weather.type == "rain" then
                ezweather.start_snow_in_area(farm_area)
            end
            ezmemory.remove_player_item(player_id,"GigFreez",1)
            local mugshot = Net.get_player_mugshot(player_id)
            Net.message_player(player_id,"\x02\x01...\x01\x02",mugshot.texture_path,mugshot.animation_path)
            Net.message_player(player_id,"\x02I cant help but feel like I just wasted something...\x02",mugshot.texture_path,mugshot.animation_path)
        end
    elseif player_tool == "CyberHoe" then
        if prexisting_plant then
            try_harvest(tile_loc_string,prexisting_plant,player_id,safe_secret,current_time)
        else
            till_tile(tile,x,y,z,player_id)
        end
    elseif player_tool == "CyberWtrCan" then
        water_tile(tile,tile_loc_string,player_id,safe_secret)
    elseif player_tool == "CyberScythe" then
        scythe_plant(tile_loc_string,current_time,prexisting_plant,player_id)
    elseif prexisting_plant then
        try_harvest(tile_loc_string,prexisting_plant,player_id,safe_secret,current_time)
    else
        try_plant_seed(tile,tile_loc_string,player_id,player_tool)
    end
end

return ezfarms