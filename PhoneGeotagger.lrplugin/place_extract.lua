-- Extracts human-readable place names from a Nominatim `address` object.

local place_extract = {}

local function first(t, keys)
  for _, k in ipairs(keys) do
    local v = t[k]
    if v ~= nil and v ~= "" then return v end
  end
  return nil
end

-- Returns { country, state, city, sublocation } with nil for absent fields.
function place_extract.extract(address)
  if type(address) ~= "table" then return {} end
  local city = first(address, { "city", "town", "village", "municipality" })
  local sub = first(address, { "neighbourhood", "suburb", "quarter", "city_district" })
  return {
    country = first(address, { "country" }),
    state = first(address, { "state" }),
    city = city,
    sublocation = sub,
  }
end

return place_extract
