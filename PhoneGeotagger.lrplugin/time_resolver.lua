-- Converts a photo capture time (ISO 8601 string from Lightroom) to UTC.

local iso8601 = require "iso8601"

local time_resolver = {}

-- opts:
--   override_offset  seconds; when set, ignores any EXIF offset
--                    (the home/destination radio choices in the dialog)
--   home_offset      seconds; fallback when the photo has no EXIF offset
--   drift            seconds the camera clock runs fast; subtracted (default 0)
-- Returns utc_seconds, used_home_fallback — or nil, error_message.
function time_resolver.resolve(capture_time, opts)
  local naive, embedded = iso8601.parse(capture_time)
  if not naive then return nil, embedded end
  local offset, used_fallback
  if opts.override_offset then
    offset, used_fallback = opts.override_offset, false
  elseif embedded then
    offset, used_fallback = embedded, false
  else
    offset, used_fallback = opts.home_offset, true
  end
  return naive - offset - (opts.drift or 0), used_fallback
end

return time_resolver
