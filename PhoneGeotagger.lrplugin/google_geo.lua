-- Google geocoding: nearest notable POI (Places API New) plus a reverse
-- Geocoding fallback for city/state/country. HTTP is injected so this module
-- stays Lightroom-free and unit-testable.

local dkjson = require "dkjson"

local google_geo = {}

-- The single place to adjust if Google rejects a type. Notable place types.
local INCLUDED_TYPES = {
  "tourist_attraction", "park", "national_park", "museum", "art_gallery",
  "historical_landmark", "monument", "cultural_landmark", "church", "mosque",
  "synagogue", "hindu_temple", "amusement_park", "zoo", "aquarium", "stadium",
  "plaza", "garden",
}

-- Extract city/state/country from a Google address-components list.
-- name_key is "longText" (Places) or "long_name" (Geocoding).
local function address(components, name_key)
  local city, state, country
  for _, c in ipairs(components or {}) do
    local val = c[name_key]
    for _, t in ipairs(c.types or {}) do
      if (t == "locality" or t == "postal_town") and not city then city = val
      elseif t == "administrative_area_level_1" and not state then state = val
      elseif t == "country" and not country then country = val
      end
    end
  end
  return city, state, country
end

-- Returns { poi, city, state, country } (or {} when no notable place), or nil, err.
function google_geo.nearest_poi(http_post, key, lat, lon, radius)
  local body = dkjson.encode({
    includedTypes = INCLUDED_TYPES,
    maxResultCount = 1,
    rankPreference = "DISTANCE",
    locationRestriction = {
      circle = {
        center = { latitude = lat, longitude = lon },
        radius = radius,
      },
    },
  })
  local headers = {
    { field = "Content-Type", value = "application/json" },
    { field = "X-Goog-Api-Key", value = key },
    { field = "X-Goog-FieldMask", value = "places.displayName,places.addressComponents" },
  }
  local resp = http_post("https://places.googleapis.com/v1/places:searchNearby",
    body, headers)
  if not resp or resp == "" then return nil, "no response from Places" end
  local doc = dkjson.decode(resp)
  if type(doc) ~= "table" then return nil, "invalid Places response" end
  if doc.error then
    return nil, "Places error: " .. tostring(doc.error.message or doc.error)
  end
  local places = doc.places
  if type(places) ~= "table" or not places[1] then return {} end
  local p = places[1]
  local city, state, country = address(p.addressComponents, "longText")
  return {
    poi = p.displayName and p.displayName.text or nil,
    city = city, state = state, country = country,
  }
end

-- Returns { city, state, country } (or {} when no result), or nil, err.
function google_geo.reverse(http_get, key, lat, lon)
  local url = string.format(
    "https://maps.googleapis.com/maps/api/geocode/json?latlng=%.7f,%.7f&key=%s",
    lat, lon, key)
  local resp = http_get(url)
  if not resp or resp == "" then return nil, "no response from Geocoding" end
  local doc = dkjson.decode(resp)
  if type(doc) ~= "table" then return nil, "invalid Geocoding response" end
  if doc.status and doc.status ~= "OK" and doc.status ~= "ZERO_RESULTS" then
    return nil, "Geocoding status: " .. tostring(doc.status)
  end
  local results = doc.results
  if type(results) ~= "table" or not results[1] then return {} end
  local city, state, country = address(results[1].address_components, "long_name")
  return { city = city, state = state, country = country }
end

return google_geo
