local matcher = require "matcher"

local track = {
  { t = 1000, lat = 10.0, lon = 20.0 },
  { t = 2000, lat = 12.0, lon = 22.0 },
  { t = 10000, lat = 50.0, lon = 60.0 },
}

describe("matcher.match", function()
  it("snaps to the nearest breadcrumb by time (earlier point)", function()
    local lat, lon = matcher.match(track, 1300, 3600)
    assert.equals(10.0, lat)
    assert.equals(20.0, lon)
  end)

  it("snaps to the nearest breadcrumb by time (later point)", function()
    local lat, lon = matcher.match(track, 1700, 3600)
    assert.equals(12.0, lat)
    assert.equals(22.0, lon)
  end)

  it("never interpolates — a midpoint snaps to a real point, not the average", function()
    -- exactly between 1000 and 2000: must return one of the two actual points
    -- (tie -> earlier), never (11.0, 21.0)
    local lat, lon = matcher.match(track, 1500, 3600)
    assert.equals(10.0, lat)
    assert.equals(20.0, lon)
  end)

  it("returns an exact point on a direct hit", function()
    local lat, lon = matcher.match(track, 2000, 60)
    assert.equals(12.0, lat)
    assert.equals(22.0, lon)
  end)

  it("snaps to the nearest even across a wide bracket", function()
    -- bracket 2000..10000 is 8000s wide; photo at 2300 is 300s from the point
    -- at 2000, well within the 600s gap
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
