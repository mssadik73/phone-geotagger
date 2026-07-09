local matcher = require "matcher"

local track = {
  { t = 1000, lat = 10.0, lon = 20.0 },
  { t = 2000, lat = 12.0, lon = 22.0 },
  { t = 10000, lat = 50.0, lon = 60.0 },
}

describe("matcher.match", function()
  it("interpolates between bracketing points within the gap", function()
    local lat, lon = matcher.match(track, 1500, 3600)
    assert.near(11.0, lat, 1e-9)
    assert.near(21.0, lon, 1e-9)
  end)

  it("returns an exact point on a direct hit", function()
    local lat, lon = matcher.match(track, 2000, 60)
    assert.equals(12.0, lat)
    assert.equals(22.0, lon)
  end)

  it("falls back to the nearest point when the bracket gap is too wide", function()
    -- bracket 2000..10000 is 8000s wide; gap limit 600s; photo at 2300 is
    -- 300s from the point at 2000
    local lat, lon = matcher.match(track, 2300, 600)
    assert.equals(12.0, lat)
    assert.equals(22.0, lon)
  end)

  it("rejects when the nearest point exceeds the gap", function()
    local lat, reason = matcher.match(track, 5000, 600)
    assert.is_nil(lat)
    assert.equals("no_match", reason)
  end)

  it("matches before the first point within the gap", function()
    local lat = matcher.match(track, 900, 600)
    assert.equals(10.0, lat)
  end)

  it("rejects before the first point beyond the gap", function()
    local lat, reason = matcher.match(track, 100, 600)
    assert.is_nil(lat)
    assert.equals("no_match", reason)
  end)

  it("matches after the last point within the gap", function()
    local lat = matcher.match(track, 10300, 600)
    assert.equals(50.0, lat)
  end)

  it("rejects an empty track", function()
    local lat, reason = matcher.match({}, 1000, 600)
    assert.is_nil(lat)
    assert.equals("empty", reason)
  end)
end)
