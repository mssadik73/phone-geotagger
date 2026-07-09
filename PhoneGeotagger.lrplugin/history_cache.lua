-- Persistent accumulated location history: one CSV line per point,
-- "utc_seconds,lat,lon". Every Timeline export the user imports is merged
-- in, so old photos can be geotagged without the phone connected.

local history_cache = {}

-- Returns a sorted points array; {} when the file doesn't exist.
function history_cache.load(path)
  local points = {}
  local f = io.open(path, "r")
  if not f then return points end
  for line in f:lines() do
    local t, lat, lon = line:match("^(%-?%d+),(%-?[%d%.]+),(%-?[%d%.]+)%s*$")
    if t then
      points[#points + 1] = { t = tonumber(t), lat = tonumber(lat), lon = tonumber(lon) }
    end
  end
  f:close()
  table.sort(points, function(a, b) return a.t < b.t end)
  return points
end

-- Returns a new sorted array; on duplicate integer timestamps the existing
-- point wins (re-importing an export must not churn the cache).
function history_cache.merge(existing, incoming)
  local seen, out = {}, {}
  local function absorb(list)
    for _, p in ipairs(list) do
      local k = math.floor(p.t)
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = { t = k, lat = p.lat, lon = p.lon }
      end
    end
  end
  absorb(existing)
  absorb(incoming)
  table.sort(out, function(a, b) return a.t < b.t end)
  return out
end

-- Writes to path..".tmp" then renames, so a crash can't truncate the cache.
function history_cache.save(path, points)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return nil, err end
  for _, p in ipairs(points) do
    f:write(string.format("%d,%.7f,%.7f\n", p.t, p.lat, p.lon))
  end
  f:close()
  os.remove(path) -- Windows os.rename refuses to overwrite
  local ok, rerr = os.rename(tmp, path)
  if not ok then return nil, rerr end
  return true
end

-- nil for empty, else { count, first_t, last_t }.
function history_cache.coverage(points)
  if #points == 0 then return nil end
  return { count = #points, first_t = points[1].t, last_t = points[#points].t }
end

return history_cache
