local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import "LrTasks"

local tz_offsets = require "tz_offsets"
local history_cache = require "history_cache"
local timeline_parser = require "timeline_parser"

local GeotagDialog = {}

local function coverage_text(points)
  local cov = history_cache.coverage(points)
  if not cov then
    return "Cache: empty — import a Timeline export file"
  end
  return string.format("Cache: %d points, %s → %s", cov.count,
    os.date("!%Y-%m-%d", cov.first_t), os.date("!%Y-%m-%d", cov.last_t))
end

-- args: { photo_count, points, cache_path, prefs }
-- Returns { points, override_offset, home_offset, drift, max_gap_sec,
-- overwrite } or nil on cancel.
function GeotagDialog.run(args)
  local prefs = args.prefs
  local points = args.points
  local result

  LrFunctionContext.callWithContext("GeotagDialog", function(context)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.mode = prefs.mode or "exif"
    props.home_offset = prefs.home_offset or 0
    props.dest_offset = prefs.dest_offset or 0
    props.drift = prefs.drift or 0
    props.max_gap_min = prefs.max_gap_min or 15
    props.overwrite = prefs.overwrite or false
    props.coverage = coverage_text(points)
    props.precision = prefs.precision or 4

    local function absorb_file(file_path)
      local fh = io.open(file_path, "rb")
      if not fh then
        LrDialogs.message("Import failed", "Could not read " .. file_path, "warning")
        return
      end
      local text = fh:read("*a")
      fh:close()
      local new_points, err = timeline_parser.parse(text)
      if not new_points then
        LrDialogs.message("Import failed", err, "warning")
        return
      end
      points = history_cache.merge(points, new_points)
      local ok, serr = history_cache.save(args.cache_path, points)
      if not ok then
        LrDialogs.message("Cache write failed", tostring(serr), "warning")
      end
      props.coverage = coverage_text(points)
    end

    local contents = f:column {
      bind_to_object = props,
      spacing = f:control_spacing(),

      f:group_box {
        title = "Location history",
        fill_horizontal = 1,
        f:static_text { title = bind "coverage", fill_horizontal = 1 },
        f:push_button {
          title = "Import file…",
          action = function()
            local files = LrDialogs.runOpenPanel {
              title = "Choose Timeline export",
              allowsMultipleSelection = false,
              canChooseDirectories = false,
            }
            if files and files[1] then
              LrTasks.startAsyncTask(function()
                absorb_file(files[1])
              end)
            end
          end,
        },
      },

      f:group_box {
        title = "Camera time",
        fill_horizontal = 1,
        f:radio_button {
          title = "Camera's timezone setting is correct (use EXIF offset)",
          value = bind "mode", checked_value = "exif",
        },
        f:row {
          f:radio_button {
            title = "Clock was on home time",
            value = bind "mode", checked_value = "home",
          },
          f:popup_menu { items = tz_offsets.items(), value = bind "home_offset" },
        },
        f:row {
          f:radio_button {
            title = "Clock was on destination time",
            value = bind "mode", checked_value = "dest",
          },
          f:popup_menu { items = tz_offsets.items(), value = bind "dest_offset" },
        },
        f:row {
          f:static_text { title = "Clock drift (seconds fast):" },
          f:edit_field {
            value = bind "drift", width_in_chars = 6,
            validate = function(_, v)
              local n = tonumber(v)
              if n then return true, n end
              return false, 0, "Enter a number of seconds"
            end,
          },
        },
      },

      f:group_box {
        title = "Matching",
        fill_horizontal = 1,
        f:row {
          f:static_text { title = "Maximum time gap (minutes):" },
          f:edit_field {
            value = bind "max_gap_min", width_in_chars = 6,
            validate = function(_, v)
              local n = tonumber(v)
              if n and n > 0 then return true, n end
              return false, 15, "Enter minutes greater than zero"
            end,
          },
        },
        f:row {
          f:static_text { title = "Location precision:" },
          f:popup_menu {
            value = bind "precision",
            items = {
              { title = "Exact", value = 8 },
              { title = "~11 m (4 decimals)", value = 4 },
              { title = "~110 m (3 decimals)", value = 3 },
            },
          },
        },
        f:checkbox {
          title = "Overwrite existing GPS coordinates",
          value = bind "overwrite",
        },
      },
    }

    local action = LrDialogs.presentModalDialog {
      title = "Geotag from Phone Timeline",
      contents = contents,
      actionVerb = string.format("Geotag %d photos", args.photo_count),
    }
    if action ~= "ok" then return end

    prefs.mode = props.mode
    prefs.home_offset = props.home_offset
    prefs.dest_offset = props.dest_offset
    prefs.drift = props.drift
    prefs.max_gap_min = props.max_gap_min
    prefs.overwrite = props.overwrite and true or false
    prefs.precision = props.precision

    local override
    if props.mode == "home" then
      override = props.home_offset
    elseif props.mode == "dest" then
      override = props.dest_offset
    end

    result = {
      points = points,
      override_offset = override,
      home_offset = props.home_offset,
      drift = tonumber(props.drift) or 0,
      max_gap_sec = (tonumber(props.max_gap_min) or 15) * 60,
      overwrite = props.overwrite and true or false,
      precision = props.precision,
    }
  end)

  return result
end

return GeotagDialog
