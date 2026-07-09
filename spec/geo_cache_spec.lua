local geo_cache = require "geo_cache"

local tmpdir = os.getenv("TMPDIR") or "/tmp"
local path = tmpdir .. "/phone_geotagger_geocode_test.json"

describe("geo_cache", function()
  before_each(function() os.remove(path) end)
  after_each(function() os.remove(path) end)

  it("rounds the key to 4 decimals", function()
    assert.equals("34.0500,-118.2400", geo_cache.key(34.050012, -118.239987))
  end)

  it("returns an empty table when the file is missing", function()
    assert.same({}, geo_cache.load(path))
  end)

  it("puts and gets by rounded coordinate", function()
    local cache = {}
    geo_cache.put(cache, 34.05, -118.24, { city = "Los Angeles", sublocation = "DTLA" })
    local p = geo_cache.get(cache, 34.050004, -118.239996) -- same 4-decimal bucket
    assert.equals("Los Angeles", p.city)
    assert.equals("DTLA", p.sublocation)
  end)

  it("saves and reloads, preserving non-ASCII", function()
    local cache = {}
    geo_cache.put(cache, 41.0, 29.0, { city = "İstanbul", sublocation = "Fenerbahçe" })
    assert.is_true(geo_cache.save(path, cache))
    local loaded = geo_cache.load(path)
    local p = geo_cache.get(loaded, 41.0, 29.0)
    assert.equals("İstanbul", p.city)
    assert.equals("Fenerbahçe", p.sublocation)
  end)

  it("load returns empty table on unparseable file", function()
    local f = assert(io.open(path, "w")); f:write("not json"); f:close()
    assert.same({}, geo_cache.load(path))
  end)

  it("saves without os.rename/os.remove (Lightroom sandbox)", function()
    -- Lightroom's Lua strips os.rename/os.remove; save must fall back to a
    -- direct write instead of the atomic tmp+rename.
    local real_rename, real_remove = os.rename, os.remove
    os.rename, os.remove = nil, nil
    finally(function() os.rename, os.remove = real_rename, real_remove end)

    local cache = {}
    geo_cache.put(cache, 41.0, 29.0, { city = "İstanbul", sublocation = "Fenerbahçe" })
    assert.is_true(geo_cache.save(path, cache))

    os.rename, os.remove = real_rename, real_remove -- restore for load/cleanup
    local loaded = geo_cache.load(path)
    local p = geo_cache.get(loaded, 41.0, 29.0)
    assert.equals("İstanbul", p.city)
    assert.equals("Fenerbahçe", p.sublocation)
  end)
end)
