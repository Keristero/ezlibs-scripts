local Direction = {
  UP = "Up",
  LEFT = "Left",
  DOWN = "Down",
  RIGHT = "Right",
  UP_LEFT = "Up Left",
  UP_RIGHT = "Up Right",
  DOWN_LEFT = "Down Left",
  DOWN_RIGHT = "Down Right",
}

Direction.list = {
  Direction.UP,
  Direction.LEFT,
  Direction.DOWN,
  Direction.RIGHT,
  Direction.UP_LEFT,
  Direction.UP_RIGHT,
  Direction.DOWN_LEFT,
  Direction.DOWN_RIGHT,
}

local reverse_table = {
  ["Up"] = "Down",
  ["Left"] = "Left",
  ["Down"] = "Up",
  ["Right"] = "Left",
  ["Up Left"] = "Down Right",
  ["Up Right"] = "Down Left",
  ["Down Left"] = "Up Right",
  ["Down Right"] = "Up Left",
}

function Direction.reverse(direction)
  return reverse_table[direction]
end

function Direction.to_vector(direction_str)
  local x_distance = 0
  local y_distance = 0
  local x_start_offset = 0
  local y_start_offset = 0
  if direction_str == Direction.LEFT then
    x_distance = -0.5
    y_distance = 0.5
  elseif direction_str == Direction.RIGHT then
    x_distance = 0.5
    y_distance = -0.5
  elseif direction_str == Direction.UP then
    x_distance = -0.5
    y_distance = -0.5
  elseif direction_str == Direction.DOWN then
    x_distance = 0.5
    y_distance = 0.5
  elseif direction_str == Direction.UP_LEFT then
      x_distance = -1
  elseif direction_str == Direction.DOWN_RIGHT then
      x_distance = 1
  elseif direction_str == Direction.UP_RIGHT then
      y_distance = -1
  elseif direction_str == Direction.DOWN_LEFT then
      y_distance = 1
  end
  return {x=x_distance,y=y_distance}
end

function Direction.from_points(point_a, point_b)
  local a_z_offset = point_a.z / 2
  local a_x = point_a.x - a_z_offset
  local a_y = point_a.y - a_z_offset

  local b_z_offset = point_b.z / 2
  local b_x = point_b.x - b_z_offset
  local b_y = point_b.y - b_z_offset

  return Direction.from_offset(b_x - a_x, b_y - a_y)
end

local directions = {
  "Up Left",
  "Up",
  "Up Right",
  "Right",
  "Down Right",
  "Down",
  "Down Left",
  "Left",
}

function Direction.from_offset(x, y)
  local angle = math.atan(y, x)
  local direction_index = math.floor(angle / math.pi * 4) + 5
  return directions[direction_index]
end

return Direction
