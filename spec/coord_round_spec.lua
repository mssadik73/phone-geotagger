local coord_round = require "coord_round"

describe("coord_round.round", function()
  it("rounds to 4 decimals", function()
    local lat, lon = coord_round.round(23.780573, 90.279240, 4)
    assert.near(23.7806, lat, 1e-9)
    assert.near(90.2792, lon, 1e-9)
  end)

  it("collapses nearby coordinates to the same value", function()
    local a = coord_round.round(34.052210, -118.0, 4)
    local b = coord_round.round(34.052240, -118.0, 4)
    assert.equals(a, b) -- both 34.0522
  end)

  it("handles negative coordinates", function()
    local lat, lon = coord_round.round(-33.868800, 151.209255, 4)
    assert.near(-33.8688, lat, 1e-9)
    assert.near(151.2093, lon, 1e-9)
  end)

  it("rounds to 3 decimals (~110 m)", function()
    local lat = coord_round.round(34.052235, 0, 3)
    assert.near(34.052, lat, 1e-9)
  end)

  it("treats 8 decimals as effectively exact", function()
    local lat, lon = coord_round.round(34.05223456, -118.24368912, 8)
    assert.near(34.05223456, lat, 1e-9)
    assert.near(-118.24368912, lon, 1e-9)
  end)
end)
