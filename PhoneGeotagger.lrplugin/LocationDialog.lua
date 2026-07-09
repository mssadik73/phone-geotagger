local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local LocationDialog = {}

-- args: { photo_count, unique_count, prefs }
-- Returns { set_name, overwrite, endpoint } or nil on cancel.
function LocationDialog.run(args)
  local prefs = args.prefs
  local result

  LrFunctionContext.callWithContext("LocationDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.set_name = prefs.loc_set_name or "Geo Locations"
    props.overwrite = prefs.loc_overwrite or false
    props.endpoint = prefs.loc_endpoint or "https://nominatim.openstreetmap.org/reverse"

    local est = math.ceil(args.unique_count * 1.1)
    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text {
        title = string.format(
          "%d photo(s), %d unique location(s) to look up (up to ~%d s on first run).",
          args.photo_count, args.unique_count, est),
      },
      f:row {
        f:static_text { title = "Collection set name:" },
        f:edit_field { value = bind "set_name", width_in_chars = 24 },
      },
      f:row {
        f:static_text { title = "Geocoder endpoint:" },
        f:edit_field { value = bind "endpoint", fill_horizontal = 1 },
      },
      f:checkbox {
        title = "Overwrite existing location metadata",
        value = bind "overwrite",
      },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Create Location Collections",
      contents = contents,
      actionVerb = "Create Collections",
    }
    if action ~= "ok" then return end

    prefs.loc_set_name = props.set_name
    prefs.loc_overwrite = props.overwrite and true or false
    prefs.loc_endpoint = props.endpoint

    result = {
      set_name = props.set_name,
      overwrite = props.overwrite and true or false,
      endpoint = props.endpoint,
    }
  end)

  return result
end

return LocationDialog
