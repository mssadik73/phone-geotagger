local visit_matcher = require "visit_matcher"

local visits = {
  { start_t = 1000, end_t = 2000, place_id = "A", lat = 10, lon = 20 },
  { start_t = 5000, end_t = 6000, place_id = "B", lat = 30, lon = 40 },
}

describe("visit_matcher.match", function()
  it("returns the visit containing the time", function()
    local v = visit_matcher.match(visits, 1500)
    assert.equals("A", v.place_id)
    assert.equals(10, v.lat)
    assert.equals(20, v.lon)
  end)

  it("is inclusive of the interval boundaries", function()
    assert.equals("A", visit_matcher.match(visits, 1000).place_id)
    assert.equals("A", visit_matcher.match(visits, 2000).place_id)
  end)

  it("returns nil between visits", function()
    assert.is_nil(visit_matcher.match(visits, 3000))
  end)

  it("returns nil before the first and after the last", function()
    assert.is_nil(visit_matcher.match(visits, 500))
    assert.is_nil(visit_matcher.match(visits, 9000))
  end)

  it("picks the later-starting visit when intervals overlap", function()
    local overlapping = {
      { start_t = 1000, end_t = 4000, place_id = "wide", lat = 1, lon = 1 },
      { start_t = 2000, end_t = 3000, place_id = "narrow", lat = 2, lon = 2 },
    }
    assert.equals("narrow", visit_matcher.match(overlapping, 2500).place_id)
  end)

  it("returns nil for an empty visit list", function()
    assert.is_nil(visit_matcher.match({}, 1500))
  end)
end)
