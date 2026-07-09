-- ISO 8601 timestamp parsing without os.time (which would apply the
-- computer's local timezone and corrupt the conversion).

local iso8601 = {}

-- Howard Hinnant's days-from-civil algorithm; valid across the Gregorian range.
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- Returns naive_seconds, offset_seconds|nil — or nil, error_message.
-- naive_seconds: the wall-clock time counted as if UTC (Unix epoch seconds).
-- offset_seconds: the embedded UTC offset, nil when the string has none.
function iso8601.parse(s)
  if type(s) ~= "string" then
    return nil, "timestamp is not a string"
  end
  local y, mo, d, h, mi, sec, rest =
    s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
  if not y then
    return nil, "unrecognized timestamp: " .. s
  end
  local frac, tail = rest:match("^%.(%d+)(.*)$")
  if frac then rest = tail end
  local offset
  if rest == "Z" then
    offset = 0
  elseif rest ~= "" then
    local sign, oh, om = rest:match("^([+%-])(%d%d):?(%d%d)$")
    if not sign then
      return nil, "unrecognized timestamp: " .. s
    end
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  local days = days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
  local naive = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  return naive, offset
end

return iso8601
