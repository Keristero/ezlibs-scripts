local ezbus = require('scripts/ezlibs-scripts/ezbus')

local EXPLOSION_DURATION = .6
local EXPLOSION_AXIS_RANGE = .5

local function update_tracked_position(exploding_effect)
  local actor_id = exploding_effect.tracked_actor_id

  if Net.is_bot(actor_id) then
    exploding_effect.area_id = Net.get_bot_area(actor_id)
    exploding_effect.position = Net.get_bot_position(actor_id)
  elseif Net.is_player(actor_id) then
    exploding_effect.area_id = Net.get_player_area(actor_id)
    exploding_effect.position = Net.get_player_position(actor_id)
  else -- tile object
    local area_id = exploding_effect.area_id
    local object = Net.get_object_by_id(area_id, actor_id)
    exploding_effect.position = {x=object.x, y=object.y, z=object.z}
  end
end

local function explode(self, explosion_bot_id)
  update_tracked_position(self)

  local offset_x = (math.random() * 2 - 1) * EXPLOSION_AXIS_RANGE
  local offset_y = (math.random() * 2 - 1) * EXPLOSION_AXIS_RANGE

  Net.transfer_bot(
    explosion_bot_id,
    self.area_id,
    false,
    self.position.x + offset_x,
    self.position.y + offset_y,
    self.position.z
  )

  -- If we have a finite max and we've reached zero, remove bot and stop
  if self.max_explosions then
    self.remaining_explosions = self.remaining_explosions - 1
    if self.remaining_explosions <= 0 then
      Net.remove_bot(explosion_bot_id)
      return
    end
  end

  -- If the effect has been manually stopped, remove bot and stop
  if self.stopped then
    Net.remove_bot(explosion_bot_id)
    return
  end

  Net.play_sound(self.area_id, "/server/assets/ezlibs-assets/sfx/explode.ogg")

  if math.random(2) == 1 then
    Net.animate_bot(explosion_bot_id, "EXPLODE")
  else
    Net.animate_bot(explosion_bot_id, "SMOKE")
  end

  -- Schedule next explosion
  Async.sleep(EXPLOSION_DURATION)
    .and_then(function()
      explode(self, explosion_bot_id)
    end)
end

local function spawn(self)
  for i = 1, self.total_explosions, 1 do
    local explosion_bot_id = Net.create_bot({
      texture_path = "/server/assets/ezlibs-assets/ezexplosions/explosion.png",
      animation_path = "/server/assets/ezlibs-assets/ezexplosions/explosion.animation",
      area_id = self.area_id,
      warp_in = false,
      x = self.position.x,
      y = self.position.y,
      z = self.position.z,
    })

    if i > 1 then
      Async.sleep((i - 1) * EXPLOSION_DURATION / self.total_explosions)
        .and_then(function()
          explode(self, explosion_bot_id)
        end)
    else
      explode(self, explosion_bot_id)
    end
  end
end

local ExplodingEffect = {}

function ExplodingEffect:new(actor_id, opt_area_id, max_explosions)
  -- max_explosions: nil for infinite, or a number for finite blasts
  local exploding_effect = {
    tracked_actor_id = actor_id,
    position = nil,
    area_id = opt_area_id,
    max_explosions = max_explosions,
    remaining_explosions = max_explosions,  -- only used if finite
    total_explosions = 3,                   -- number of bots to spawn initially
    stopped = false
  }

  setmetatable(exploding_effect, self)
  self.__index = self

  update_tracked_position(exploding_effect, opt_area_id)
  spawn(exploding_effect)

  return exploding_effect
end

-- Call this to stop an infinite explosion early
function ExplodingEffect:remove()
  self.stopped = true
end

-- Public API
local ezexplosions = {}

function ezexplosions.explode(actor_id, area_id, max_explosions)
    return ExplodingEffect:new(actor_id, area_id, max_explosions)
end

-- Listen for explosion requests via the global event bus
ezbus:on("explode", function(event)
    ezexplosions.explode(event.actor_id, event.area_id, event.max_explosions)
end)

return ezexplosions