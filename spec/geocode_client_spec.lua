local geocode_client = require "geocode_client"

local function fake_get(body)
  local calls = {}
  return function(url) calls[#calls + 1] = url; return body end, calls
end

describe("geocode_client.reverse_url", function()
  it("builds the Nominatim reverse URL", function()
    local url = geocode_client.reverse_url(
      "https://nominatim.openstreetmap.org/reverse", 34.0, -118.5)
    assert.equals(
      "https://nominatim.openstreetmap.org/reverse?format=jsonv2"
        .. "&lat=34.0000000&lon=-118.5000000&zoom=18&addressdetails=1",
      url)
  end)
end)

describe("geocode_client.reverse", function()
  it("returns the address table from a good response", function()
    local body = '{"address":{"suburb":"Venice","city":"Los Angeles"}}'
    local get, calls = fake_get(body)
    local addr = assert(geocode_client.reverse(get, "https://x/reverse", 34, -118))
    assert.equals("Venice", addr.suburb)
    assert.equals("Los Angeles", addr.city)
    assert.equals(
      "https://x/reverse?format=jsonv2&lat=34.0000000&lon=-118.0000000"
        .. "&zoom=18&addressdetails=1",
      calls[1])
  end)

  it("errors on an empty body", function()
    local get = fake_get("")
    local addr, err = geocode_client.reverse(get, "https://x/reverse", 0, 0)
    assert.is_nil(addr)
    assert.is_string(err)
  end)

  it("errors on invalid JSON", function()
    local get = fake_get("<html>rate limited</html>")
    local addr, err = geocode_client.reverse(get, "https://x/reverse", 0, 0)
    assert.is_nil(addr)
    assert.is_string(err)
  end)

  it("errors when Nominatim reports an error field", function()
    local get = fake_get('{"error":"Unable to geocode"}')
    local addr, err = geocode_client.reverse(get, "https://x/reverse", 0, 0)
    assert.is_nil(addr)
    assert.matches("Unable to geocode", err)
  end)

  it("errors when there is no address", function()
    local get = fake_get('{"lat":"0","lon":"0"}')
    local addr, err = geocode_client.reverse(get, "https://x/reverse", 0, 0)
    assert.is_nil(addr)
    assert.is_string(err)
  end)
end)
