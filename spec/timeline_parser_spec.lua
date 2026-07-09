local timeline_parser = require "timeline_parser"

local function read_fixture(name)
  local f = assert(io.open("spec/fixtures/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

describe("timeline_parser.parse", function()
  it("parses the on-device export format", function()
    local points = assert(timeline_parser.parse(read_fixture("ondevice_export.json")))
    -- 2 timelinePath + 1 rawSignal + 2 visit endpoints
    assert.equals(5, #points)
    -- sorted ascending; 10:05+06:00 == 04:05Z on 2025-06-01
    assert.equals(1748750700, points[1].t)
    assert.near(23.7805733, points[1].lat, 1e-9)
    assert.near(90.2792399, points[1].lon, 1e-9)
    -- rawSignal lands between the path points and the visit
    assert.equals(1748752200, points[3].t)
    assert.near(23.79, points[3].lat, 1e-9)
    -- visit emits identical coordinates at startTime and endTime
    assert.equals(1748754000, points[4].t)
    assert.equals(1748757600, points[5].t)
    assert.near(23.8103, points[4].lat, 1e-9)
    assert.near(90.4125, points[5].lon, 1e-9)
  end)

  it("parses the legacy Takeout Records format", function()
    local points = assert(timeline_parser.parse(read_fixture("takeout_records.json")))
    assert.equals(2, #points)
    assert.equals(1678867200, points[1].t)
    assert.near(23.7805733, points[1].lat, 1e-9)
    assert.near(90.2792399, points[1].lon, 1e-9)
    assert.equals(1678959000, points[2].t)
    assert.near(-33.86882, points[2].lat, 1e-9)
    assert.near(151.209255, points[2].lon, 1e-9)
  end)

  it("handles geo: URI points and duration-offset path entries", function()
    local json = [[{
      "semanticSegments": [
        {
          "startTime": "2025-06-01T10:00:00.000Z",
          "endTime": "2025-06-01T11:00:00.000Z",
          "timelinePath": [
            { "point": "geo:10.5,-20.25", "durationMinutesOffsetFromStartTime": "30" }
          ]
        }
      ]
    }]]
    local points = assert(timeline_parser.parse(json))
    assert.equals(1, #points)
    assert.equals(1748773800, points[1].t)  -- 10:00Z + 30 min
    assert.near(10.5, points[1].lat, 1e-9)
    assert.near(-20.25, points[1].lon, 1e-9)
  end)

  it("rejects invalid JSON with a clear error", function()
    local points, err = timeline_parser.parse("{{{nope")
    assert.is_nil(points)
    assert.matches("JSON", err)
  end)

  it("rejects unrecognized JSON shapes naming the supported formats", function()
    local points, err = timeline_parser.parse('{"something": "else"}')
    assert.is_nil(points)
    assert.matches("semanticSegments", err)
    assert.matches("Takeout", err)
  end)

  it("rejects files with zero extractable points", function()
    local points, err = timeline_parser.parse('{"semanticSegments": []}')
    assert.is_nil(points)
    assert.matches("No location points", err)
  end)
end)
