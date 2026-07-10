-- Accumulated Timeline history: movement points and visits (with placeId),
-- stored as one JSON object so old photos can be geotagged from past exports.

local dkjson = require "dkjson"

local history_cache = {}

function history_cache.load(path)
  local f = io.open(path, "r")
  if not f then return { points = {}, visits = {} } end
  local text = f:read("*a")
  f:close()
  if not text then return { points = {}, visits = {} } end
  local t = dkjson.decode(text)
  if type(t) ~= "table" then return { points = {}, visits = {} } end
  return { points = t.points or {}, visits = t.visits or {} }
end

local function merge_by(existing, incoming, key_of)
  local seen, out = {}, {}
  local function absorb(list)
    for _, item in ipairs(list) do
      local k = key_of(item)
      if not seen[k] then seen[k] = true; out[#out + 1] = item end
    end
  end
  absorb(existing)
  absorb(incoming)
  return out
end

function history_cache.merge(existing, incoming)
  local points = merge_by(existing.points or {}, incoming.points or {},
    function(p) return math.floor(p.t) end)
  local visits = merge_by(existing.visits or {}, incoming.visits or {},
    function(v) return tostring(v.place_id) .. "@" .. tostring(v.start_t) end)
  table.sort(points, function(a, b) return a.t < b.t end)
  table.sort(visits, function(a, b) return a.start_t < b.start_t end)
  return { points = points, visits = visits }
end

function history_cache.save(path, data)
  local atomic = os.rename ~= nil
  local target = atomic and (path .. ".tmp") or path
  local f, err = io.open(target, "w")
  if not f then return nil, err end
  local wrote, werr = f:write(dkjson.encode(data, { indent = false }))
  f:close()
  if not wrote then
    if os.remove then os.remove(target) end
    return nil, werr
  end
  if atomic then
    if os.remove then os.remove(path) end
    local ok, rerr = os.rename(target, path)
    if not ok then return nil, rerr end
  end
  return true
end

function history_cache.coverage(data)
  local points = data.points or {}
  if #points == 0 then return nil end
  return { count = #points, first_t = points[1].t, last_t = points[#points].t }
end

return history_cache
