local google_geo = require "google_geo"

local PLACES_BODY = [[{
  "places": [
    {
      "displayName": { "text": "Griffith Observatory", "languageCode": "en" },
      "addressComponents": [
        { "longText": "Los Angeles", "types": ["locality", "political"] },
        { "longText": "California", "types": ["administrative_area_level_1"] },
        { "longText": "United States", "types": ["country", "political"] }
      ]
    }
  ]
}]]

local GEOCODE_BODY = [[{
  "results": [
    {
      "address_components": [
        { "long_name": "Lone Pine", "types": ["locality", "political"] },
        { "long_name": "California", "types": ["administrative_area_level_1"] },
        { "long_name": "United States", "types": ["country", "political"] }
      ]
    }
  ],
  "status": "OK"
}]]

local function fake_post(body)
  local calls = {}
  return function(url, reqbody, headers)
    calls[#calls + 1] = { url = url, body = reqbody, headers = headers }
    return body
  end, calls
end

local function fake_get(body)
  local calls = {}
  return function(url) calls[#calls + 1] = url; return body end, calls
end

describe("google_geo.nearest_poi", function()
  it("parses POI and address from a Places response", function()
    local post = fake_post(PLACES_BODY)
    local p = assert(google_geo.nearest_poi(post, "KEY", 34.1184, -118.3004, 200))
    assert.equals("Griffith Observatory", p.poi)
    assert.equals("Los Angeles", p.city)
    assert.equals("California", p.state)
    assert.equals("United States", p.country)
  end)

  it("sends the searchNearby URL, key header, and field mask", function()
    local post, calls = fake_post(PLACES_BODY)
    google_geo.nearest_poi(post, "KEY", 34.0, -118.0, 200)
    local c = calls[1]
    assert.equals("https://places.googleapis.com/v1/places:searchNearby", c.url)
    local hkey, hmask
    for _, h in ipairs(c.headers) do
      if h.field == "X-Goog-Api-Key" then hkey = h.value end
      if h.field == "X-Goog-FieldMask" then hmask = h.value end
    end
    assert.equals("KEY", hkey)
    assert.equals("places.displayName,places.addressComponents", hmask)
    assert.matches("searchNearby", c.url)
    assert.matches('"rankPreference":"DISTANCE"', (c.body:gsub("%s", "")))
    assert.matches('"radius":200', (c.body:gsub("%s", "")))
  end)

  it("returns an empty table when there is no notable place", function()
    local post = fake_post('{"places": []}')
    assert.same({}, google_geo.nearest_poi(post, "KEY", 0, 0, 200))
  end)

  it("errors on a Google error body", function()
    local post = fake_post('{"error": {"code": 403, "message": "denied"}}')
    local p, err = google_geo.nearest_poi(post, "KEY", 0, 0, 200)
    assert.is_nil(p)
    assert.matches("denied", err)
  end)

  it("errors on an empty response", function()
    local post = fake_post("")
    local p, err = google_geo.nearest_poi(post, "KEY", 0, 0, 200)
    assert.is_nil(p)
    assert.is_string(err)
  end)
end)

describe("google_geo.reverse", function()
  it("parses city/state/country from a Geocoding response", function()
    local get = fake_get(GEOCODE_BODY)
    local p = assert(google_geo.reverse(get, "KEY", 36.5, -116.9))
    assert.equals("Lone Pine", p.city)
    assert.equals("California", p.state)
    assert.equals("United States", p.country)
    assert.is_nil(p.poi)
  end)

  it("returns an empty table when there is no result", function()
    local get = fake_get('{"results": [], "status": "ZERO_RESULTS"}')
    assert.same({}, google_geo.reverse(get, "KEY", 0, 0))
  end)

  it("errors on a non-OK status", function()
    local get = fake_get('{"results": [], "status": "REQUEST_DENIED"}')
    local p, err = google_geo.reverse(get, "KEY", 0, 0)
    assert.is_nil(p)
    assert.matches("REQUEST_DENIED", err)
  end)
end)
