local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp = import "LrHttp"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"

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
            local function file_url(p)
              p = p:gsub("\\", "/")
              p = p:gsub("[^%w/%:%.%-_]", function(ch)
                return string.format("%%%02X", string.byte(ch))
              end)
              return "file:///" .. p:gsub("^/", "")
            end
            -- macOS strips both ?query and #hash when opening a local file://
            -- URL, so coordinates can't ride the URL. Generate a self-contained
            -- page in the temp folder: absolute file URLs for Leaflet, and the
            -- coordinates baked straight into the script.
            local dir = _PLUGIN.path
            local fh = io.open(LrPathUtils.child(dir, "mappicker.html"), "rb")
            if not fh then
              LrDialogs.message("Open map picker",
                "Could not read the bundled map picker.", "warning")
              return
            end
            local html = fh:read("*a")
            fh:close()
            local css = file_url(LrPathUtils.child(dir, "leaflet.css"))
            local js = file_url(LrPathUtils.child(dir, "leaflet.js"))
            html = html:gsub('href="leaflet%.css"', function()
              return 'href="' .. css .. '"' end)
            html = html:gsub('src="leaflet%.js"', function()
              return 'src="' .. js .. '"' end)
            html = html:gsub("__START_LAT__", function()
              return tostring(args.current_lat) end)
            html = html:gsub("__START_LON__", function()
              return tostring(args.current_lon) end)
            local out = LrPathUtils.child(
              LrPathUtils.getStandardFilePath("temp"),
              string.format("phone_geotagger_map_%d.html", math.random(1000000000)))
            local wf, werr = io.open(out, "wb")
            if not wf then
              LrDialogs.message("Open map picker",
                "Could not write the map file: " .. tostring(werr), "warning")
              return
            end
            wf:write(html)
            wf:close()
            LrHttp.openUrlInBrowser(file_url(out))
          end,
        },
      },
      f:row {
        f:push_button {
          title = "Use location from map",
          action = function()
            LrTasks.startAsyncTask(function()
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
            end)
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
