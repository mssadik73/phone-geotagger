-- Rounds coordinates to a fixed decimal precision so co-located photos share
-- an identical value (one map pin) instead of scattering from interpolation.

local coord_round = {}

-- Returns lat, lon each rounded to `decimals` places.
function coord_round.round(lat, lon, decimals)
  local m = 10 ^ decimals
  return math.floor(lat * m + 0.5) / m, math.floor(lon * m + 0.5) / m
end

return coord_round
