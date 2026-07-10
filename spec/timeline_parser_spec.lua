local timeline_parser = require "timeline_parser"

local function read_fixture(name)
  local f = assert(io.open("spec/fixtures/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

describe("timeline_parser.parse", function()
  it("parses the on-device export format into points and visits", function()
    local r = assert(timeline_parser.parse(read_fixture("ondevice_export.json")))
    -- points: 2 timelinePath + 1 rawSignal (visit endpoints no longer duplicated as points)
    assert.equals(3, #r.points)
    assert.equals(1748750700, r.points[1].t)
    assert.near(23.7805733, r.points[1].lat, 1e-9)
    -- one visit, with its placeId and interval
    assert.equals(1, #r.visits)
    assert.equals("ChIJ_fixture_place", r.visits[1].place_id)
    assert.equals(1748754000, r.visits[1].start_t)  -- 2025-06-01T11:00:00+06:00
    assert.equals(1748757600, r.visits[1].end_t)    -- 2025-06-01T12:00:00+06:00
    assert.near(23.8103, r.visits[1].lat, 1e-9)
    assert.near(90.4125, r.visits[1].lon, 1e-9)
  end)

  it("parses the legacy Takeout Records format", function()
    local r = assert(timeline_parser.parse(read_fixture("takeout_records.json")))
    assert.equals(2, #r.points)
    assert.equals(1678867200, r.points[1].t)
    assert.near(23.7805733, r.points[1].lat, 1e-9)
    assert.near(90.2792399, r.points[1].lon, 1e-9)
    assert.equals(1678959000, r.points[2].t)
    assert.near(-33.86882, r.points[2].lat, 1e-9)
    assert.near(151.209255, r.points[2].lon, 1e-9)
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
    local r = assert(timeline_parser.parse(json))
    assert.equals(1, #r.points)
    assert.equals(1748773800, r.points[1].t)  -- 10:00Z + 30 min
    assert.near(10.5, r.points[1].lat, 1e-9)
    assert.near(-20.25, r.points[1].lon, 1e-9)
  end)

  it("rejects invalid JSON with a clear error", function()
    local r, err = timeline_parser.parse("{{{nope")
    assert.is_nil(r)
    assert.matches("JSON", err)
  end)

  it("rejects unrecognized JSON shapes naming the supported formats", function()
    local r, err = timeline_parser.parse('{"something": "else"}')
    assert.is_nil(r)
    assert.matches("semanticSegments", err)
    assert.matches("Takeout", err)
  end)

  it("rejects files with zero extractable points", function()
    local r, err = timeline_parser.parse('{"semanticSegments": []}')
    assert.is_nil(r)
    assert.matches("No location points", err)
  end)

  it("rejects non-table semanticSegments without crashing", function()
    local r, err = timeline_parser.parse('{"semanticSegments": true}')
    assert.is_nil(r)
    assert.matches("semanticSegments", err)
  end)

  it("tolerates a non-table semanticSegments beside a valid rawSignals", function()
    local json = [[{
      "semanticSegments": true,
      "rawSignals": [
        { "position": { "LatLng": "10.0°, 20.0°", "timestamp": "2025-06-01T00:00:00Z" } }
      ]
    }]]
    local r = assert(timeline_parser.parse(json))
    assert.equals(1, #r.points)
    assert.near(10.0, r.points[1].lat, 1e-9)
  end)
end)
