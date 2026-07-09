local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp = import "LrHttp"
local LrTasks = import "LrTasks"

local google_geo = require "google_geo"

local CorrectDialog = {}

local function http_post(url, body, headers)
  return (LrHttp.post(url, body, headers))
end

local function fmt(lat, lon)
  return string.format("%.5f, %.5f", lat, lon)
end

-- args: { photo_count, current_lat, current_lon, key }
-- Returns { lat, lon, poi, city, state, country } or nil.
function CorrectDialog.run(args)
  local result

  LrFunctionContext.callWithContext("CorrectDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.query = ""
    props.status = "Search Google for the correct place, then pick it below."
    props.items = { { title = "(search first)", value = 0 } }
    props.choice = 0
    local hits = {} -- index -> place

    local function do_search()
      LrTasks.startAsyncTask(function()
        local list, err = google_geo.text_search(http_post, args.key, props.query,
          args.current_lat, args.current_lon)
        if not list then
          props.status = "Search failed: " .. tostring(err)
          return
        end
        if #list == 0 then
          props.status = "No places found for: " .. props.query
          props.items = { { title = "(no results)", value = 0 } }
          hits = {}
          return
        end
        hits = {}
        local items = {}
        for i, p in ipairs(list) do
          hits[i] = p
          local label = p.poi or "(unnamed)"
          if p.city then label = label .. ", " .. p.city end
          items[i] = { title = label, value = i }
        end
        props.items = items
        props.choice = 1
        props.status = string.format("%d result(s). Pick one and click Apply.", #list)
      end)
    end

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text { title = "Current tag: " .. fmt(args.current_lat, args.current_lon) },
      f:row {
        f:edit_field { value = bind "query", width_in_chars = 30,
          placeholder_string = "Search for a place" },
        f:push_button { title = "Search", action = do_search },
      },
      f:static_text { title = bind "status", fill_horizontal = 1 },
      f:popup_menu { value = bind "choice", items = bind "items", fill_horizontal = 1 },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Correct Geotag",
      contents = contents,
      actionVerb = string.format("Apply to %d photo(s)", args.photo_count),
    }
    if action ~= "ok" then return end

    local p = hits[props.choice]
    if not p or not p.lat then
      LrDialogs.message("Correct Geotag",
        "No place was picked. Search and select a place first.", "warning")
      return
    end
    result = {
      lat = p.lat, lon = p.lon,
      poi = p.poi, city = p.city, state = p.state, country = p.country,
    }
  end)

  return result
end

return CorrectDialog
