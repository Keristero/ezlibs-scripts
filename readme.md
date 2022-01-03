# ezlibs

## Installation
- copy / clone [ezlibs-scripts](https://github.com/Keristero/ezlibs-scripts/tree/master) into `server/scripts/ezlibs-scripts`
- copy / clone [ezlibs-assets](https://github.com/Keristero/ezlibs-assets/tree/master) into `server/scripts/ezlibs-assets`
- create these folders
    - `server/memory/area/`
    - `server/memory/player/`
    - `server/encounters/`

### contents

## ezmemory
provides easyish saving and loading of things.

```lua
local new_item_id = ezmemory.create_or_update_item(item_name,item_description,is_key)
```
- if an item with is_key is given to a player it will show in keyitems
- if an item with the same name already exists; the details will be updated, this wont update in the players key items until the player reconnects

```lua
local new_item_count = ezmemory.give_player_item(player_id, name, amount)
```
- gives the player an item

## ezencounters
handle enemy encounters, and trigger random ones from a table for each map

create a lua file for each map with the same name as the tiled map (`default.lua` for example)
here is an example of the contents, in this case just one potential encounter layout with some mettaurs and a champy

```lua
local encounter1 = {
    path="/server/assets/ezlibs-assets/ezencounters/ezencounters_bundle.zip",
    weight=10,
    enemies = {
        {name="Mettaur",rank=1},
        {name="Champy",rank=1},
    },
    positions = {
        {0,0,0,0,0,2},
        {0,0,0,0,1,0},
        {0,0,0,1,0,0}
    },
}

return {
    minimum_steps_before_encounter=400,
    encounter_chance_per_step=0.01,
    encounters={encounter1}
}
```