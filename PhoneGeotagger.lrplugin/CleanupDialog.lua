local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local CleanupDialog = {}

function CleanupDialog.run(args)
  local prefs = args.prefs
  local result

  LrFunctionContext.callWithContext("CleanupDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.radius_km = prefs.cleanup_radius_km or 2

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),
      f:static_text {
        title = string.format("%d photo(s) selected.", args.photo_count),
      },
      f:static_text {
        title = "Reconciles City / State / Country for photos at the same place "
          .. "(same POI within the cluster radius) by majority vote, so a place "
          .. "no longer splits into multiple collections.",
        fill_horizontal = 1, width_in_chars = 44, height_in_lines = 3,
      },
      f:row {
        f:static_text { title = "Cluster radius (km):" },
        f:edit_field { value = bind "radius_km", width_in_chars = 6 },
      },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Clean Up Place Names",
      contents = contents,
      actionVerb = "Clean Up Places",
    }
    if action ~= "ok" then return end
    local radius = tonumber(props.radius_km)
    if not radius or radius <= 0 then radius = 2 end
    prefs.cleanup_radius_km = radius
    result = { radius_km = radius }
  end)

  return result
end

return CleanupDialog
