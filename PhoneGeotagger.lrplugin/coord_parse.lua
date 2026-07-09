-- Parses a "lat, lon" (or "lat lon") string into numeric coordinates.

local coord_parse = {}

-- Returns lat, lon — or nil, error_message.
function coord_parse.parse(text)
  if type(text) ~= "string" then
    return nil, "no coordinates to parse"
  end
  local lat_s, lon_s = text:match("^%s*(%-?%d+%.?%d*)%s*[, ]%s*(%-?%d+%.?%d*)%s*$")
  if not lat_s then
    return nil, "could not read coordinates from: " .. text
  end
  local lat, lon = tonumber(lat_s), tonumber(lon_s)
  if not lat or not lon then
    return nil, "could not read coordinates from: " .. text
  end
  if lat < -90 or lat > 90 then
    return nil, "latitude out of range: " .. lat_s
  end
  if lon < -180 or lon > 180 then
    return nil, "longitude out of range: " .. lon_s
  end
  return lat, lon
end

return coord_parse
