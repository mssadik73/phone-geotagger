local candidate_finder = require "candidate_finder"

describe("candidate_finder.find", function()
  local points = {
    { t = 1, lat = 23.5000, lon = 90.4000 },
    { t = 2, lat = 23.5000, lon = 90.4000 }, -- exact duplicate coordinate
    { t = 3, lat = 23.5010, lon = 90.4000 }, -- ~111 m
    { t = 4, lat = 23.6000, lon = 90.4000 }, -- ~11 km, out of default radius
  }

  it("returns nearby points deduped by coordinate, nearest first", function()
    local out = candidate_finder.find(points, 23.5000, 90.4000, {})
    assert.equals(2, #out)                 -- duplicate collapsed, far point dropped
    assert.near(23.5000, out[1].lat, 1e-9)
    assert.equals(0, out[1].dist)
    assert.near(23.5010, out[2].lat, 1e-9)
    assert.near(111, out[2].dist, 2)
  end)

  it("honors a custom radius", function()
    local out = candidate_finder.find(points, 23.5000, 90.4000, { radius_m = 20000 })
    assert.equals(3, #out)                 -- now includes the ~11 km point
  end)

  it("caps the result count", function()
    local many = {}
    for i = 1, 30 do
      many[i] = { t = i, lat = 23.5 + i * 0.0001, lon = 90.4 }
    end
    local out = candidate_finder.find(many, 23.5, 90.4, { radius_m = 100000, max = 5 })
    assert.equals(5, #out)
  end)

  it("returns an empty list when history is empty", function()
    assert.same({}, candidate_finder.find({}, 23.5, 90.4, {}))
  end)
end)
