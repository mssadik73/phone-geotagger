local pr = require "place_reconcile"

describe("place_reconcile.distance_km", function()
  it("is ~0 for identical points and grows with separation", function()
    assert.near(0, pr.distance_km(64, -20, 64, -20), 1e-9)
    -- 0.01 deg of latitude ~= 1.11 km
    assert.near(1.11, pr.distance_km(64.00, -20, 64.01, -20), 0.05)
  end)
end)

describe("place_reconcile.groups", function()
  local function rec(poi, lat, lon) return { poi = poi, lat = lat, lon = lon } end

  it("merges same-POI points that are close (even across a grid line)", function()
    -- these two once fell in different hard-grid cells; proximity must merge them
    local recs = { rec("Hella", 64.0000, -20.0000), rec("Hella", 64.0050, -20.0050) }
    local gid, n = pr.groups(recs, 2)
    assert.equals(gid[1], gid[2])
    assert.equals(1, n)
  end)

  it("separates the same POI when far apart", function()
    local recs = { rec("Hella", 63.83, -20.38), rec("Hella", 64.50, -20.38) }
    local gid, n = pr.groups(recs, 2)
    assert.is_not.equal(gid[1], gid[2])
    assert.equals(2, n)
  end)

  it("clusters empty/nil-POI points by proximity only", function()
    local recs = { rec(nil, 10.000, 10.000), rec("", 10.001, 10.001), rec(nil, 40.0, 40.0) }
    local gid, n = pr.groups(recs, 2)
    assert.equals(gid[1], gid[2])       -- nil and "" are both the empty-POI bucket, close
    assert.is_not.equal(gid[1], gid[3])
    assert.equals(2, n)
  end)

  it("keeps different POIs at the same spot in different groups", function()
    local recs = { rec("A", 10, 10), rec("B", 10, 10) }
    local gid, n = pr.groups(recs, 2)
    assert.is_not.equal(gid[1], gid[2])
    assert.equals(2, n)
  end)

  it("trims POI before bucketing", function()
    local recs = { rec("Hella", 63.8300, -20.3800), rec(" Hella ", 63.8310, -20.3810) }
    local gid, n = pr.groups(recs, 2)
    assert.equals(gid[1], gid[2])
    assert.equals(1, n)
  end)
end)

describe("place_reconcile.reconcile", function()
  local function rec(poi, city, state, country, lat, lon, time)
    return { poi = poi, city = city, state = state, country = country,
             lat = lat, lon = lon, time = time }
  end

  it("picks the plurality value per field and rewrites the whole group", function()
    -- Iceland x12 vs 'Rangarthing ytra' x2 -> Iceland for all 14
    local records = {}
    for i = 1, 12 do
      records[i] = rec("Hella", "Hella", "South", "Iceland", 63.83, -20.38,
        string.format("2026-06-01T10:%02d:00", i))
    end
    records[13] = rec("Hella", "Hella", "South", "Rangarthing ytra", 63.8301, -20.3801, "2026-06-01T09:00:00")
    records[14] = rec("Hella", "Hella", "South", "Rangarthing ytra", 63.8302, -20.3802, "2026-06-01T09:01:00")
    local out, stats = pr.reconcile(records, 2)
    for i = 1, 14 do assert.equals("Iceland", out[i].country) end
    assert.equals(1, stats.groups)
    assert.equals(1, stats.conflicts)
  end)

  it("breaks a tie by earliest capture time", function()
    -- 2 vs 2 on country; the earliest-timed photo carries 'Alpha'
    local records = {
      rec("P", "C", "S", "Beta",  10.0, 10.0, "2026-06-01T12:00:00"),
      rec("P", "C", "S", "Beta",  10.0, 10.0, "2026-06-01T11:00:00"),
      rec("P", "C", "S", "Alpha", 10.0, 10.0, "2026-06-01T08:00:00"),  -- earliest
      rec("P", "C", "S", "Alpha", 10.0, 10.0, "2026-06-01T09:00:00"),
    }
    local out = pr.reconcile(records, 2)
    for i = 1, 4 do assert.equals("Alpha", out[i].country) end
  end)

  it("fills blanks from the group winner", function()
    local records = {
      rec("P", "Town", "State", "Country", 10.0, 10.0, "t1"),
      rec("P", nil,    nil,     nil,       10.0, 10.0, "t2"),
    }
    local out = pr.reconcile(records, 2)
    assert.equals("Town", out[2].city)
    assert.equals("State", out[2].state)
    assert.equals("Country", out[2].country)
  end)

  it("leaves a field nil when empty across the whole group", function()
    local records = {
      rec("P", nil, nil, "Country", 10.0, 10.0, "t1"),
      rec("P", nil, nil, "Country", 10.0, 10.0, "t2"),
    }
    local out, stats = pr.reconcile(records, 2)
    assert.is_nil(out[1].city)
    assert.is_nil(out[1].state)
    assert.equals("Country", out[1].country)
    assert.equals(0, stats.conflicts)
  end)

  it("treats empty string like nil (not a vote)", function()
    local records = {
      rec("P", "", "", "Iceland", 10.0, 10.0, "t1"),
      rec("P", "Vik", "South", "Iceland", 10.0, 10.0, "t2"),
    }
    local out = pr.reconcile(records, 2)
    assert.equals("Vik", out[1].city)
  end)
end)
