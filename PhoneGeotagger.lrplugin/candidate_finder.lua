-- Finds nearby history points to offer as corrected-location candidates.

local geo_group = require "geo_group"

local candidate_finder = {}

local function key(lat, lon)
  return string.format("%.5f,%.5f", lat, lon)
end

-- points: { {t, lat, lon}, ... }. opts: { radius_m = 500, max = 10 }.
-- Returns { {lat, lon, dist}, ... } nearest first, deduped by ~1 m coordinate.
function candidate_finder.find(points, lat, lon, opts)
  opts = opts or {}
  local radius_m = opts.radius_m or 500
  local max = opts.max or 10

  local seen = {}
  local unique = {}
  for _, p in ipairs(points) do
    local k = key(p.lat, p.lon)
    if not seen[k] then
      seen[k] = true
      unique[#unique + 1] = { lat = p.lat, lon = p.lon }
    end
  end

  local within = geo_group.filter_within(unique, lat, lon, radius_m)
  local out = {}
  for i = 1, math.min(max, #within) do
    out[i] = { lat = within[i].lat, lon = within[i].lon, dist = within[i].dist }
  end
  return out
end

return candidate_finder
