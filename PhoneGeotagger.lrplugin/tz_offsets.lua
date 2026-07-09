-- UTC offset choices for the home/destination dropdowns.

local tz_offsets = {}

-- All whole-hour offsets plus the real-world :30/:45 zones.
local OFFSET_MINUTES = {
  -720, -660, -600, -570, -540, -480, -420, -360, -300, -240, -210, -180,
  -120, -60, 0, 60, 120, 180, 210, 240, 270, 300, 330, 345, 360, 390, 420,
  480, 525, 540, 570, 600, 630, 660, 720, 765, 780, 840,
}

function tz_offsets.format(seconds)
  local sign = seconds < 0 and "-" or "+"
  local abs = math.abs(seconds)
  return string.format("UTC%s%02d:%02d",
    sign, math.floor(abs / 3600), math.floor((abs % 3600) / 60))
end

-- Shape consumed directly by Lightroom's popup_menu `items`.
function tz_offsets.items()
  local items = {}
  for i, minutes in ipairs(OFFSET_MINUTES) do
    items[i] = { title = tz_offsets.format(minutes * 60), value = minutes * 60 }
  end
  return items
end

return tz_offsets
