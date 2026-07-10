-- Matches a UTC timestamp against a sorted track of {t, lat, lon} points.

local matcher = {}

-- Returns the lat, lon of the breadcrumb closest in time to t — snapping to an
-- actual recorded point, never interpolating between two. Returns nil, "empty"
-- | "no_match" when the track is empty or the closest point is beyond max_gap.
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

  -- Snap to whichever bracketing breadcrumb is closer in time (ties -> earlier).
  local nearest
  if before and after then
    nearest = (t - before.t) <= (after.t - t) and before or after
  else
    nearest = before or after
  end
  if nearest and math.abs(nearest.t - t) <= max_gap then
    return nearest.lat, nearest.lon
  end
  return nil, "no_match"
end

return matcher
