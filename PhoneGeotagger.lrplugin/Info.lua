return {
  LrSdkVersion = 6.0,
  LrSdkMinimumVersion = 6.0,
  LrToolkitIdentifier = "com.github.mssadik73.phonegeotagger",
  LrPluginName = "Phone Geotagger",
  LrPluginInfoUrl = "https://github.com/mssadik73/phone-geotagger",
  LrLibraryMenuItems = {
    {
      title = "Geotag from Phone Timeline...",
      file = "GeotagMenuItem.lua",
    },
    {
      title = "Find Photos With This Geotag",
      file = "FindGeotagGroupMenuItem.lua",
    },
    {
      title = "Correct Geotag of Selection...",
      file = "CorrectGeotagMenuItem.lua",
    },
    {
      title = "Create Location Collections...",
      file = "LocationCollectionsMenuItem.lua",
    },
  },
  VERSION = { major = 0, minor = 1, revision = 0 },
}
