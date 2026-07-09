local geo_group = require "geo_group"

describe("geo_group.haversine", function()
  it("is zero for identical points", function()
    assert.equals(0, geo_group.haversine(23.5, 90.4, 23.5, 90.4))
  end)

  it("computes ~111.2 km for one degree of longitude at the equator", function()
    local d = geo_group.haversine(0, 0, 0, 1)
    assert.near(111195, d, 100)
  end)

  it("computes ~111.2 km for one degree of latitude", function()
    local d = geo_group.haversine(0, 0, 1, 0)
    assert.near(111195, d, 100)
  end)

  it("computes a short distance in meters", function()
    -- ~0.001 deg latitude ~= 111 m
    local d = geo_group.haversine(23.5, 90.4, 23.501, 90.4)
    assert.near(111, d, 2)
  end)
end)

describe("geo_group.filter_within", function()
  local candidates = {
    { lat = 23.5000, lon = 90.4000, label = "A" },
    { lat = 23.5010, lon = 90.4000, label = "B" }, -- ~111 m north
    { lat = 23.6000, lon = 90.4000, label = "C" }, -- ~11 km north
  }

  it("keeps only points within the radius, nearest first, with dist", function()
    local out = geo_group.filter_within(candidates, 23.5000, 90.4000, 500)
    assert.equals(2, #out)
    assert.equals("A", out[1].label)
    assert.equals("B", out[2].label)
    assert.equals(0, out[1].dist)
    assert.near(111, out[2].dist, 2)
  end)

  it("returns an empty list when nothing is in range", function()
    local out = geo_group.filter_within(candidates, 0, 0, 500)
    assert.equals(0, #out)
  end)

  it("does not mutate the input candidates", function()
    geo_group.filter_within(candidates, 23.5, 90.4, 500)
    assert.is_nil(candidates[1].dist)
  end)
end)
