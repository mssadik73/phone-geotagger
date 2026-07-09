local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp = import "LrHttp"
local LrPathUtils = import "LrPathUtils"

local clipboard = require "clipboard"
local coord_parse = require "coord_parse"
local LrExec = require "LrExec"

local CorrectDialog = {}

local function fmt(lat, lon)
  return string.format("%.5f, %.5f", lat, lon)
end

-- args: { photo_count, current_lat, current_lon, candidates }
-- candidates: { {lat, lon, dist}, ... }
-- Returns { lat = number, lon = number } or nil on cancel / no pick.
function CorrectDialog.run(args)
  local result

  LrFunctionContext.callWithContext("CorrectDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)

    -- Build candidate popup items; source defaults to history if any exist.
    local items = {}
    for i, c in ipairs(args.candidates) do
      items[i] = {
        title = string.format("%s   (~%d m away)", fmt(c.lat, c.lon), math.floor(c.dist + 0.5)),
        value = i,
      }
    end
    props.has_candidates = #items > 0
    props.source = props.has_candidates and "history" or "map"
    props.candidate_index = 1
    props.map_label = "(none yet)"
    props.map_lat = nil
    props.map_lon = nil

    local history_row
    if props.has_candidates then
      history_row = f:row {
        f:radio_button { title = "From Timeline history:", value = bind "source", checked_value = "history" },
        f:popup_menu { items = items, value = bind "candidate_index" },
      }
    else
      history_row = f:static_text { title = "No Timeline history found near this location." }
    end

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text { title = "Current tag: " .. fmt(args.current_lat, args.current_lon) },
      history_row,
      f:row {
        f:radio_button { title = "From map:", value = bind "source", checked_value = "map" },
        f:push_button {
          title = "Open map picker",
          action = function()
            local html = LrPathUtils.child(_PLUGIN.path, "mappicker.html")
            local url = "file://" .. html .. "?lat=" .. tostring(args.current_lat)
              .. "&lon=" .. tostring(args.current_lon)
            LrHttp.openUrlInBrowser(url)
          end,
        },
      },
      f:row {
        f:push_button {
          title = "Use location from map",
          action = function()
            local text = clipboard.read(LrExec.execute, WIN_ENV == true)
            local lat, lon = coord_parse.parse(text)
            if not lat then
              LrDialogs.message("Use location from map",
                "No coordinates on the clipboard yet. In the map, drag the pin "
                .. "or click the correct spot, then try again.", "warning")
              return
            end
            props.map_lat = lat
            props.map_lon = lon
            props.map_label = fmt(lat, lon)
            props.source = "map"
          end,
        },
        f:static_text { title = bind "map_label", fill_horizontal = 1 },
      },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Correct Geotag",
      contents = contents,
      actionVerb = string.format("Apply to %d photo(s)", args.photo_count),
    }
    if action ~= "ok" then return end

    if props.source == "history" and props.has_candidates then
      local c = args.candidates[props.candidate_index]
      result = { lat = c.lat, lon = c.lon }
    elseif props.source == "map" and props.map_lat then
      result = { lat = props.map_lat, lon = props.map_lon }
    else
      LrDialogs.message("Correct Geotag",
        "No corrected location was chosen. Pick a history candidate or use the "
        .. "map picker first.", "warning")
    end
  end)

  return result
end

return CorrectDialog
