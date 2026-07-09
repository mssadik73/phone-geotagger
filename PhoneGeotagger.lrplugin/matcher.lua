-- Matches a UTC timestamp against a sorted track of {t, lat, lon} points.

local matcher = {}

-- Returns lat, lon — or nil, "empty" | "no_match".
function matcher.match(points, t, max_gap)
  local n = #points
  if n == 0 then return nil, "empty" end

  -- lo = first index with points[lo].t >= t (binary search)
  local lo, hi = 1, n + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if points[mid].t < t then lo = mid + 1 else hi = mid end
  end
  local after = points[lo]
  local before = points[lo - 1]

  if after and after.t == t then
    return after.lat, after.lon
  end
  if before and after and (after.t - before.t) <= max_gap then
    local f = (t - before.t) / (after.t - before.t)
    return before.lat + (after.lat - before.lat) * f,
           before.lon + (after.lon - before.lon) * f
  end
  local nearest
  if before and after then
    nearest = (t - before.t) <= (after.t - t) and before or after
  else
    nearest = before or after
  end
  if math.abs(nearest.t - t) <= max_gap then
    return nearest.lat, nearest.lon
  end
  return nil, "no_match"
end

return matcher
