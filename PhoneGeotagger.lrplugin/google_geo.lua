-- Google geocoding: Place Details (placeId -> place), Text Search (query ->
-- places), and reverse Geocoding (coordinate -> city/state/country). HTTP is
-- injected so this module stays Lightroom-free and unit-testable.

local dkjson = require "dkjson"

local google_geo = {}

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

-- Google Places (New) Place Details for a placeId -> { poi, city, state, country }.
function google_geo.place_details(http_get, key, place_id)
  local url = "https://places.googleapis.com/v1/places/" .. place_id
  local headers = {
    { field = "X-Goog-Api-Key", value = key },
    { field = "X-Goog-FieldMask", value = "displayName,addressComponents" },
  }
  local resp = http_get(url, headers)
  if not resp or resp == "" then return nil, "no response from Place Details" end
  local doc = dkjson.decode(resp)
  if type(doc) ~= "table" then return nil, "invalid Place Details response" end
  if doc.error then
    return nil, "Places error: " .. tostring(doc.error.message or doc.error)
  end
  local city, state, country = address(doc.addressComponents, "longText")
  return {
    poi = doc.displayName and doc.displayName.text or nil,
    city = city, state = state, country = country,
  }
end

-- Google Places (New) Text Search -> list of { place_id, poi, city, state,
-- country, lat, lon }. Location bias omitted when bias_lat/bias_lon are nil.
function google_geo.text_search(http_post, key, query, bias_lat, bias_lon)
  local req = { textQuery = query, maxResultCount = 8 }
  if bias_lat ~= nil and bias_lon ~= nil then
    req.locationBias = {
      circle = {
        center = { latitude = bias_lat, longitude = bias_lon },
        radius = 50000,
      },
    }
  end
  local headers = {
    { field = "Content-Type", value = "application/json" },
    { field = "X-Goog-Api-Key", value = key },
    { field = "X-Goog-FieldMask",
      value = "places.id,places.displayName,places.location,places.addressComponents" },
  }
  local resp = http_post("https://places.googleapis.com/v1/places:searchText",
    dkjson.encode(req), headers)
  if not resp or resp == "" then return nil, "no response from Text Search" end
  local doc = dkjson.decode(resp)
  if type(doc) ~= "table" then return nil, "invalid Text Search response" end
  if doc.error then
    return nil, "Places error: " .. tostring(doc.error.message or doc.error)
  end
  local out = {}
  for _, p in ipairs(doc.places or {}) do
    local city, state, country = address(p.addressComponents, "longText")
    out[#out + 1] = {
      place_id = p.id,
      poi = p.displayName and p.displayName.text or nil,
      city = city, state = state, country = country,
      lat = p.location and p.location.latitude or nil,
      lon = p.location and p.location.longitude or nil,
    }
  end
  return out
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
