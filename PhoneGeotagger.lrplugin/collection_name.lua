-- Builds a regular-collection name from a reverse-geocoded place, either from
-- an explicit primary+secondary format or automatically (finest present level
-- plus the next coarser present level). Also validates a chosen format.

local collection_name = {}

local ORDER = { "poi", "city", "state", "country" } -- fine -> coarse
local RANK = { poi = 1, city = 2, state = 3, country = 4 }

local function present(v)
  return v ~= nil and v ~= ""
end

-- Finest present level + next coarser present level, comma-joined; nil if none.
function collection_name.auto(place)
  local primary_i
  for i = 1, #ORDER do
    if present(place[ORDER[i]]) then primary_i = i; break end
  end
  if not primary_i then return nil end
  local primary = place[ORDER[primary_i]]
  for i = primary_i + 1, #ORDER do
    if present(place[ORDER[i]]) then
      return primary .. ", " .. place[ORDER[i]]
    end
  end
  return primary
end

-- Applies fmt = { primary, secondary }; falls back to auto when the primary
-- level is absent for this place.
function collection_name.of(place, fmt)
  if not fmt then return collection_name.auto(place) end
  local primary = place[fmt.primary]
  if not present(primary) then return collection_name.auto(place) end
  local sec = fmt.secondary
  if sec and sec ~= "none" and sec ~= fmt.primary and present(place[sec]) then
    return primary .. ", " .. place[sec]
  end
  return primary
end

-- nil if the format is valid, else an error message.
function collection_name.format_error(primary, secondary)
  if not RANK[primary] then
    return "Unknown primary level: " .. tostring(primary)
  end
  if secondary == nil or secondary == "none" then
    return nil
  end
  if not RANK[secondary] then
    return "Unknown secondary level: " .. tostring(secondary)
  end
  if RANK[secondary] <= RANK[primary] then
    return "The secondary level must be broader than the primary level, "
      .. "or set to (none)."
  end
  return nil
end

return collection_name
