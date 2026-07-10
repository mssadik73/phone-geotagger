-- Parses Google Timeline exports into sorted {t, lat, lon} track points and visits.
-- Supported formats:
--   1. Android on-device Timeline export: { semanticSegments = {...}, rawSignals = {...} }
--   2. Legacy Google Takeout Records.json: { locations = { {latitudeE7, longitudeE7, timestamp} } }

local dkjson = require "dkjson"
local iso8601 = require "iso8601"

local timeline_parser = {}

-- Accepts "23.78°, 90.27°", "23.78, 90.27", and "geo:23.78,90.27".
local function parse_latlng(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("^geo:", ""):gsub("°", "")
  local lat, lon = s:match("^%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*$")
  if not lat then return nil end
  return tonumber(lat), tonumber(lon)
end

local function utc(iso)
  local naive, offset = iso8601.parse(iso)
  if not naive then return nil end
  return naive - (offset or 0)
end

local function add(points, t, lat, lon)
  if t and lat and lon then
    points[#points + 1] = { t = t, lat = lat, lon = lon }
  end
end

local function parse_ondevice(doc, points, visits)
  local segments = type(doc.semanticSegments) == "table" and doc.semanticSegments or {}
  local signals = type(doc.rawSignals) == "table" and doc.rawSignals or {}
  for _, seg in ipairs(segments) do
    local seg_start = utc(seg.startTime)
    local path = type(seg.timelinePath) == "table" and seg.timelinePath or {}
    for _, entry in ipairs(path) do
      local t = utc(entry.time)
      if not t and entry.durationMinutesOffsetFromStartTime and seg_start then
        local minutes = tonumber(entry.durationMinutesOffsetFromStartTime)
        if minutes then t = seg_start + minutes * 60 end
      end
      local lat, lon = parse_latlng(entry.point)
      add(points, t, lat, lon)
    end
    if seg.visit then
      local tc = seg.visit.topCandidate
      local lat, lon = parse_latlng(tc and tc.placeLocation and tc.placeLocation.latLng)
      local s, e = utc(seg.startTime), utc(seg.endTime)
      if lat and s and e then
        visits[#visits + 1] = {
          start_t = s, end_t = e,
          place_id = tc.placeId,
          lat = lat, lon = lon,
        }
      end
    end
  end
  for _, sig in ipairs(signals) do
    local pos = sig.position
    if pos then
      local lat, lon = parse_latlng(pos.LatLng or pos.latLng)
      add(points, utc(pos.timestamp), lat, lon)
    end
  end
end

local function parse_takeout(doc, points)
  for _, loc in ipairs(doc.locations) do
    if loc.latitudeE7 and loc.longitudeE7 then
      local t
      if loc.timestamp then
        t = utc(loc.timestamp)
      elseif loc.timestampMs then
        local ms = tonumber(loc.timestampMs)
        if ms then t = math.floor(ms / 1000) end
      end
      add(points, t, loc.latitudeE7 / 1e7, loc.longitudeE7 / 1e7)
    end
  end
end

-- Returns { points = sorted [{t,lat,lon}], visits = [{start_t,end_t,place_id,lat,lon}] },
-- or nil, error_message.
function timeline_parser.parse(json_text)
  local doc, _, jerr = dkjson.decode(json_text)
  if type(doc) ~= "table" then
    return nil, "Not valid JSON: " .. tostring(jerr)
  end
  local points, visits = {}, {}
  if type(doc.locations) == "table" then
    parse_takeout(doc, points)
  elseif type(doc.semanticSegments) == "table" or type(doc.rawSignals) == "table" then
    parse_ondevice(doc, points, visits)
  else
    return nil, "Unrecognized file. Expected a Google Timeline on-device export "
      .. "(semanticSegments/rawSignals) or a legacy Takeout Records.json (locations)."
  end
  if #points == 0 and #visits == 0 then
    return nil, "No location points found in the file."
  end
  table.sort(points, function(a, b) return a.t < b.t end)
  return { points = points, visits = visits }
end

return timeline_parser
