local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local collection_name = require "collection_name"

local LocationDialog = {}

local LEVEL_ITEMS = {
  { title = "Neighborhood", value = "sublocation" },
  { title = "City", value = "city" },
  { title = "State / Province", value = "state" },
  { title = "Country", value = "country" },
}
local SECONDARY_ITEMS = {
  { title = "(none)", value = "none" },
  { title = "Neighborhood", value = "sublocation" },
  { title = "City", value = "city" },
  { title = "State / Province", value = "state" },
  { title = "Country", value = "country" },
}

-- args: { photo_count, prefs }
-- Returns { set_name, endpoint, primary, secondary } or nil on cancel.
function LocationDialog.run(args)
  local prefs = args.prefs
  local result

  LrFunctionContext.callWithContext("LocationDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.set_name = (prefs.loc_set_name and prefs.loc_set_name ~= "" and prefs.loc_set_name)
      or "Geo Locations"
    props.endpoint = (prefs.loc_endpoint and prefs.loc_endpoint ~= "" and prefs.loc_endpoint)
      or "https://nominatim.openstreetmap.org/reverse"
    props.primary = prefs.loc_primary or "sublocation"
    props.secondary = prefs.loc_secondary or "city"

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text {
        title = string.format(
          "%d photo(s) selected. Locations are looked up as needed "
          .. "(about one per second for new ones).", args.photo_count),
      },
      f:row {
        f:static_text { title = "Collection set name:" },
        f:edit_field { value = bind "set_name", width_in_chars = 24 },
      },
      f:row {
        f:static_text { title = "Geocoder endpoint:" },
        f:edit_field { value = bind "endpoint", fill_horizontal = 1 },
      },
      f:row {
        f:static_text { title = "Collection name — primary:" },
        f:popup_menu { items = LEVEL_ITEMS, value = bind "primary" },
        f:static_text { title = "secondary:" },
        f:popup_menu { items = SECONDARY_ITEMS, value = bind "secondary" },
      },
    }

    while true do
      local action = LrDialogs.presentModalDialog {
        title = "Create Location Collections",
        contents = contents,
        actionVerb = "Create Collections",
      }
      if action ~= "ok" then return end -- cancel: result stays nil

      if props.set_name == nil or props.set_name == "" then props.set_name = "Geo Locations" end
      if props.endpoint == nil or props.endpoint == "" then
        props.endpoint = "https://nominatim.openstreetmap.org/reverse"
      end

      local ferr = collection_name.format_error(props.primary, props.secondary)
      if ferr then
        LrDialogs.message("Invalid collection name format", ferr, "warning")
      else
        prefs.loc_set_name = props.set_name
        prefs.loc_endpoint = props.endpoint
        prefs.loc_primary = props.primary
        prefs.loc_secondary = props.secondary
        prefs.loc_overwrite = nil
        result = {
          set_name = props.set_name, endpoint = props.endpoint,
          primary = props.primary, secondary = props.secondary,
        }
        return
      end
    end
  end)

  return result
end

return LocationDialog
