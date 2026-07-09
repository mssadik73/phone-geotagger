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
  if not text then return {} end
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

-- Prefers an atomic tmp+rename so a crash can't truncate the cache; falls back
-- to a direct write where os.rename is unavailable (Lightroom's Lua sandbox
-- has no os.rename/os.remove).
function geo_cache.save(path, cache)
  local atomic = os.rename ~= nil
  local target = atomic and (path .. ".tmp") or path
  local f, err = io.open(target, "w")
  if not f then return nil, err end
  local wrote, werr = f:write(dkjson.encode(cache, { indent = false }))
  f:close()
  if not wrote then
    if os.remove then os.remove(target) end
    return nil, werr
  end
  if atomic then
    if os.remove then os.remove(path) end -- Windows os.rename won't overwrite
    local ok, rerr = os.rename(target, path)
    if not ok then return nil, rerr end
  end
  return true
end

return geo_cache
