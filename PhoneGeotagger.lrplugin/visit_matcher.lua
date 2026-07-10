-- Finds the Timeline visit whose time interval contains a UTC timestamp.

local visit_matcher = {}

-- visits: array of { start_t, end_t, place_id, lat, lon }.
-- Returns the containing visit with the latest start_t (so a narrower nested
-- visit wins over a wider one), or nil.
function visit_matcher.match(visits, utc_seconds)
  local best
  for _, v in ipairs(visits) do
    if utc_seconds >= v.start_t and utc_seconds <= v.end_t then
      if not best or v.start_t > best.start_t then best = v end
    end
  end
  return best
end

return visit_matcher
