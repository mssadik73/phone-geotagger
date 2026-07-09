-- Builds and interprets Nominatim reverse-geocode requests. HTTP is injected
-- (http_get) so this module stays Lightroom-free and unit-testable.

local dkjson = require "dkjson"

local geocode_client = {}

function geocode_client.reverse_url(endpoint, lat, lon)
  return string.format(
    "%s?format=jsonv2&lat=%.7f&lon=%.7f&zoom=18&addressdetails=1",
    endpoint, lat, lon)
end

-- http_get: function(url) -> body_string
-- Returns the decoded `address` table, or nil, error_message.
function geocode_client.reverse(http_get, endpoint, lat, lon)
  local body = http_get(geocode_client.reverse_url(endpoint, lat, lon))
  if not body or body == "" then
    return nil, "no response from geocoder"
  end
  local doc = dkjson.decode(body)
  if type(doc) ~= "table" then
    return nil, "invalid geocoder response"
  end
  if doc.error then
    return nil, "geocoder error: " .. tostring(doc.error)
  end
  if type(doc.address) ~= "table" then
    return nil, "no address in geocoder response"
  end
  return doc.address
end

return geocode_client
