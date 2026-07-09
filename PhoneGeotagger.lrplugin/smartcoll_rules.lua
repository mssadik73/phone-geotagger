-- Builds Lightroom smart-collection search descriptions and display names for
-- reverse-geocoded places. The criteria strings ("location" = IPTC
-- Sublocation, "city") live ONLY here — the single place to correct if the
-- Lightroom manual test shows a collection not populating.

local smartcoll_rules = {}

-- Returns a Lightroom smart-collection searchDescription table.
function smartcoll_rules.build(sublocation, city)
  local desc = { combine = "intersect" }
  desc[#desc + 1] = { criteria = "location", operation = "==", value = sublocation }
  if city ~= nil and city ~= "" then
    desc[#desc + 1] = { criteria = "city", operation = "==", value = city }
  end
  return desc
end

-- Given { {sublocation, city}, ... }, returns { {sublocation, city, name}, ... }
-- disambiguating a sublocation shared across cities as "<sub> (<city>)".
function smartcoll_rules.names(place_pairs)
  local cities_for = {}
  for _, p in ipairs(place_pairs) do
    cities_for[p.sublocation] = cities_for[p.sublocation] or {}
    if p.city and p.city ~= "" then
      cities_for[p.sublocation][p.city] = true
    end
  end
  local out = {}
  for i, p in ipairs(place_pairs) do
    local count = 0
    for _ in pairs(cities_for[p.sublocation]) do count = count + 1 end
    local name = p.sublocation
    if count > 1 and p.city and p.city ~= "" then
      name = p.sublocation .. " (" .. p.city .. ")"
    end
    out[i] = { sublocation = p.sublocation, city = p.city, name = name }
  end
  return out
end

return smartcoll_rules
