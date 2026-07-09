local google_geo = require "google_geo"

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

local DETAILS_BODY = [[{
  "displayName": { "text": "Griffith Observatory" },
  "addressComponents": [
    { "longText": "Los Angeles", "types": ["locality"] },
    { "longText": "California", "types": ["administrative_area_level_1"] },
    { "longText": "United States", "types": ["country"] }
  ]
}]]

local SEARCH_BODY = [[{
  "places": [
    {
      "id": "ChIJ_place_1",
      "displayName": { "text": "Golden Gate Park" },
      "location": { "latitude": 37.7694, "longitude": -122.4862 },
      "addressComponents": [
        { "longText": "San Francisco", "types": ["locality"] },
        { "longText": "California", "types": ["administrative_area_level_1"] },
        { "longText": "United States", "types": ["country"] }
      ]
    }
  ]
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
  return function(url, headers)
    calls[#calls + 1] = { url = url, headers = headers }
    return body
  end, calls
end

describe("google_geo.place_details", function()
  it("parses POI and address from a Place Details response", function()
    local get = fake_get(DETAILS_BODY)
    local p = assert(google_geo.place_details(get, "KEY", "ChIJxyz"))
    assert.equals("Griffith Observatory", p.poi)
    assert.equals("Los Angeles", p.city)
    assert.equals("California", p.state)
    assert.equals("United States", p.country)
  end)

  it("requests the place path with key + field-mask headers", function()
    local get, calls = fake_get(DETAILS_BODY)
    google_geo.place_details(get, "KEY", "ChIJxyz")
    local c = calls[1]
    assert.equals("https://places.googleapis.com/v1/places/ChIJxyz", c.url)
    local hkey, hmask
    for _, h in ipairs(c.headers) do
      if h.field == "X-Goog-Api-Key" then hkey = h.value end
      if h.field == "X-Goog-FieldMask" then hmask = h.value end
    end
    assert.equals("KEY", hkey)
    assert.equals("displayName,addressComponents", hmask)
  end)

  it("errors on a Google error body", function()
    local get = fake_get('{"error": {"message": "not found"}}')
    local p, err = google_geo.place_details(get, "KEY", "bad")
    assert.is_nil(p)
    assert.matches("not found", err)
  end)
end)

describe("google_geo.text_search", function()
  it("parses results with id, poi, address, and location", function()
    local post = fake_post(SEARCH_BODY)
    local list = assert(google_geo.text_search(post, "KEY", "golden gate", 37.77, -122.42))
    assert.equals(1, #list)
    assert.equals("ChIJ_place_1", list[1].place_id)
    assert.equals("Golden Gate Park", list[1].poi)
    assert.equals("San Francisco", list[1].city)
    assert.near(37.7694, list[1].lat, 1e-6)
    assert.near(-122.4862, list[1].lon, 1e-6)
  end)

  it("sends the searchText URL, field mask, query, and location bias", function()
    local post, calls = fake_post(SEARCH_BODY)
    google_geo.text_search(post, "KEY", "golden gate", 37.77, -122.42)
    local c = calls[1]
    assert.equals("https://places.googleapis.com/v1/places:searchText", c.url)
    local body = c.body:gsub("%s", "")
    assert.matches('"textQuery":"goldengate"', body)
    assert.matches("locationBias", body)
  end)

  it("omits the bias when lat/lon are nil", function()
    local post, calls = fake_post(SEARCH_BODY)
    google_geo.text_search(post, "KEY", "eiffel tower", nil, nil)
    assert.is_nil(calls[1].body:find("locationBias", 1, true))
  end)

  it("returns an empty list when there are no results", function()
    local post = fake_post('{"places": []}')
    assert.same({}, google_geo.text_search(post, "KEY", "nowhere", nil, nil))
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
