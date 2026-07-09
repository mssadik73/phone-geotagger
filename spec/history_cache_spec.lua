local history_cache = require "history_cache"

local tmpdir = os.getenv("TMPDIR") or "/tmp"
local path = tmpdir .. "/phone_geotagger_test_cache.csv"

describe("history_cache", function()
  before_each(function() os.remove(path) end)
  after_each(function() os.remove(path) end)

  it("loads an empty list when the file is missing", function()
    assert.same({}, history_cache.load(path))
  end)

  it("saves and reloads points, preserving order and precision", function()
    local points = {
      { t = 100, lat = 23.7805733, lon = 90.2792399 },
      { t = 200, lat = -33.86882, lon = 151.209255 },
    }
    assert.is_true(history_cache.save(path, points))
    local loaded = history_cache.load(path)
    assert.equals(2, #loaded)
    assert.equals(100, loaded[1].t)
    assert.near(23.7805733, loaded[1].lat, 1e-6)
    assert.near(151.209255, loaded[2].lon, 1e-6)
  end)

  it("skips malformed lines on load", function()
    local f = assert(io.open(path, "w"))
    f:write("100,10.5,20.5\n")
    f:write("garbage line\n")
    f:write("200,11.5,21.5\n")
    f:close()
    assert.equals(2, #history_cache.load(path))
  end)

  it("merges with existing points winning on duplicate timestamps", function()
    local existing = { { t = 100, lat = 1.0, lon = 2.0 } }
    local incoming = {
      { t = 100, lat = 9.0, lon = 9.0 },
      { t = 50, lat = 3.0, lon = 4.0 },
    }
    local merged = history_cache.merge(existing, incoming)
    assert.equals(2, #merged)
    assert.equals(50, merged[1].t)   -- sorted
    assert.equals(1.0, merged[2].lat) -- existing wins at t=100
  end)

  it("reports coverage", function()
    assert.is_nil(history_cache.coverage({}))
    local cov = history_cache.coverage({
      { t = 100, lat = 1, lon = 2 },
      { t = 900, lat = 3, lon = 4 },
    })
    assert.same({ count = 2, first_t = 100, last_t = 900 }, cov)
  end)

  it("saves without os.rename/os.remove (Lightroom sandbox)", function()
    -- Lightroom's Lua strips os.rename/os.remove; save must fall back to a
    -- direct write instead of the atomic tmp+rename.
    local real_rename, real_remove = os.rename, os.remove
    os.rename, os.remove = nil, nil
    finally(function() os.rename, os.remove = real_rename, real_remove end)

    local points = { { t = 100, lat = 10.5, lon = 20.5 } }
    assert.is_true(history_cache.save(path, points))

    os.rename, os.remove = real_rename, real_remove -- restore for load/cleanup
    local loaded = history_cache.load(path)
    assert.equals(1, #loaded)
    assert.equals(100, loaded[1].t)
    assert.near(10.5, loaded[1].lat, 1e-6)
  end)
end)
