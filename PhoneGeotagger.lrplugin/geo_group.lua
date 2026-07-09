-- Great-circle distance and radius filtering for geotag grouping/correction.

local geo_group = {}

-- atan2: math.atan2 on Lua 5.1 (Lightroom), two-arg math.atan on 5.3+
local atan2 = math.atan2 or math.atan

local R = 6371000 -- mean Earth radius, meters
local RAD = math.pi / 180

-- Distance in meters between two lat/lon pairs (degrees).
function geo_group.haversine(lat1, lon1, lat2, lon2)
  local dlat = (lat2 - lat1) * RAD
  local dlon = (lon2 - lon1) * RAD
  local a = math.sin(dlat / 2) ^ 2
    + math.cos(lat1 * RAD) * math.cos(lat2 * RAD) * math.sin(dlon / 2) ^ 2
  local c = 2 * atan2(math.sqrt(a), math.sqrt(1 - a))
  return R * c
end

-- Returns a new array of shallow-copied candidates within radius_m of
-- (lat, lon), each with an added `dist` (meters), sorted nearest first.
function geo_group.filter_within(candidates, lat, lon, radius_m)
  local out = {}
  for _, c in ipairs(candidates) do
    local d = geo_group.haversine(lat, lon, c.lat, c.lon)
    if d <= radius_m then
      local copy = {}
      for k, v in pairs(c) do copy[k] = v end
      copy.dist = d
      out[#out + 1] = copy
    end
  end
  table.sort(out, function(a, b) return a.dist < b.dist end)
  return out
end

return geo_group
