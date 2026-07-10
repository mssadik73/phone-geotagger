local LrView = import "LrView"
local LrPrefs = import "LrPrefs"

local provider = {}

function provider.sectionsForTopOfDialog(f, _)
  local prefs = LrPrefs.prefsForPlugin()
  return {
    {
      title = "Phone Geotagger",
      f:row {
        f:static_text { title = "Google API key:", width = 110 },
        f:edit_field {
          value = LrView.bind { key = "google_api_key", object = prefs },
          fill_horizontal = 1,
          width_in_chars = 40,
        },
      },
      f:static_text {
        title = "Required for geotagging and correction (POI names + "
          .. "geocoding). Enable the Places API (New) and the Geocoding API "
          .. "on your Google Cloud project.",
        fill_horizontal = 1,
      },
    },
  }
end

return provider
