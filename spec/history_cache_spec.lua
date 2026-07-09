local history_cache = require "history_cache"

local tmpdir = os.getenv("TMPDIR") or "/tmp"
local path = tmpdir .. "/phone_geotagger_hist_test.json"

describe("history_cache", function()
  before_each(function() os.remove(path) end)
  after_each(function() os.remove(path) end)

  it("loads empty points+visits when the file is missing", function()
    assert.same({ points = {}, visits = {} }, history_cache.load(path))
  end)

  it("saves and reloads points and visits", function()
    local data = {
      points = { { t = 100, lat = 23.78, lon = 90.27 } },
      visits = { { start_t = 100, end_t = 200, place_id = "A", lat = 1, lon = 2 } },
    }
    assert.is_true(history_cache.save(path, data))
    local loaded = history_cache.load(path)
    assert.equals(1, #loaded.points)
    assert.equals(100, loaded.points[1].t)
    assert.equals("A", loaded.visits[1].place_id)
    assert.equals(200, loaded.visits[1].end_t)
  end)

  it("merges points (existing wins) and visits (by place_id@start_t)", function()
    local existing = {
      points = { { t = 100, lat = 1, lon = 2 } },
      visits = { { start_t = 100, end_t = 200, place_id = "A", lat = 1, lon = 1 } },
    }
    local incoming = {
      points = { { t = 100, lat = 9, lon = 9 }, { t = 50, lat = 3, lon = 4 } },
      visits = {
        { start_t = 100, end_t = 200, place_id = "A", lat = 9, lon = 9 }, -- dup
        { start_t = 300, end_t = 400, place_id = "B", lat = 5, lon = 6 },
      },
    }
    local m = history_cache.merge(existing, incoming)
    assert.equals(2, #m.points)
    assert.equals(50, m.points[1].t)      -- sorted
    assert.equals(1, m.points[2].lat)     -- existing wins at t=100
    assert.equals(2, #m.visits)
    assert.equals(1, m.visits[1].lat)     -- existing A wins
    assert.equals("B", m.visits[2].place_id)
  end)

  it("reports coverage over points", function()
    assert.is_nil(history_cache.coverage({ points = {}, visits = {} }))
    local cov = history_cache.coverage({
      points = { { t = 100, lat = 1, lon = 2 }, { t = 900, lat = 3, lon = 4 } },
      visits = {},
    })
    assert.same({ count = 2, first_t = 100, last_t = 900 }, cov)
  end)

  it("load returns empty structure on unparseable file", function()
    local f = assert(io.open(path, "w")); f:write("not json"); f:close()
    assert.same({ points = {}, visits = {} }, history_cache.load(path))
  end)
end)
