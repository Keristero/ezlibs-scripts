local ezchristmas = {}
local ezweather = require('scripts/ezlibs-scripts/ezweather')

local areas = Net.list_areas()
for i, area_id in ipairs(areas) do
    print('[ezchristmas] let it snow, let it snow, let it snow. in '..area_id)
    ezweather.start_snow_in_area(area_id)
end

return ezchristmas