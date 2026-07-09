-- Persistent coordinate -> resolved-place cache, so shared locations and
-- repeat runs cost no geocoder requests. Stored as a single JSON object.

local dkjson = require "dkjson"

local geo_cache = {}

function geo_cache.key(lat, lon)
  return string.format("%.4f,%.4f", lat, lon)
end

function geo_cache.load(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local text = f:read("*a")
  f:close()
  local t = dkjson.decode(text)
  if type(t) ~= "table" then return {} end
  return t
end

function geo_cache.get(cache, lat, lon)
  return cache[geo_cache.key(lat, lon)]
end

function geo_cache.put(cache, lat, lon, place)
  cache[geo_cache.key(lat, lon)] = place
end

-- Writes path..".tmp" then renames, so a crash can't truncate the cache.
function geo_cache.save(path, cache)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return nil, err end
  local wrote, werr = f:write(dkjson.encode(cache, { indent = false }))
  f:close()
  if not wrote then
    os.remove(tmp)
    return nil, werr
  end
  os.remove(path) -- Windows os.rename refuses to overwrite
  local ok, rerr = os.rename(tmp, path)
  if not ok then return nil, rerr end
  return true
end

return geo_cache
