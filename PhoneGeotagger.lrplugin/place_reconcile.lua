-- Reconciles City/State/Country across photos at the same place. Pure and
-- Lightroom-free: groups by trimmed POI + proximity clustering (single-linkage
-- within the cluster radius, so nearby photos never split at a grid boundary),
-- then per-field majority vote with an earliest-capture-time tie-break.

local place_reconcile = {}

local KM_PER_DEG = 111
local FIELDS = { "city", "state", "country" }

local function trim(s)
  if s == nil then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function present(v)
  return v ~= nil and v ~= ""
end

-- Approximate great-circle distance in km (equirectangular; accurate at the
-- small scale of a cluster radius, and needs no atan2).
function place_reconcile.distance_km(lat1, lon1, lat2, lon2)
  local mlat = math.rad((lat1 + lat2) / 2)
  local dlat = lat2 - lat1
  local dlon = (lon2 - lon1) * math.cos(mlat)
  return math.sqrt(dlat * dlat + dlon * dlon) * KM_PER_DEG
end

-- Assigns each record a group id. Records are bucketed by trimmed POI (nil/""
-- share the empty bucket), then single-linkage clustered within each bucket by
-- proximity: two records join the same group when within radius_km. Returns
-- gid (array: record index -> group id) and the group count.
function place_reconcile.groups(records, radius_km)
  local buckets = {}
  for i, r in ipairs(records) do
    local p = trim(r.poi)
    local b = buckets[p]
    if not b then b = {}; buckets[p] = b end
    b[#b + 1] = i
  end

  local gid = {}
  local ngroups = 0
  for _, idxs in pairs(buckets) do
    local parent = {}
    for _, i in ipairs(idxs) do parent[i] = i end
    local function find(x)
      while parent[x] ~= x do parent[x] = parent[parent[x]]; x = parent[x] end
      return x
    end
    for a = 1, #idxs do
      for b = a + 1, #idxs do
        local i, j = idxs[a], idxs[b]
        local d = place_reconcile.distance_km(
          records[i].lat, records[i].lon, records[j].lat, records[j].lon)
        if d <= radius_km then parent[find(i)] = find(j) end
      end
    end
    local root_gid = {}
    for _, i in ipairs(idxs) do
      local root = find(i)
      if not root_gid[root] then ngroups = ngroups + 1; root_gid[root] = ngroups end
      gid[i] = root_gid[root]
    end
  end
  return gid, ngroups
end

-- records: array of { poi, city, state, country, lat, lon, time }.
-- Returns out (array of { city, state, country }, same order/length) and
-- stats { groups, conflicts }.
function place_reconcile.reconcile(records, radius_km)
  local gid, ngroups = place_reconcile.groups(records, radius_km)

  local members = {}
  for g = 1, ngroups do members[g] = {} end
  for i = 1, #records do
    local g = gid[i]
    members[g][#members[g] + 1] = i
  end

  local winners = {}
  local conflicts = 0
  for g = 1, ngroups do
    -- Order the group's photos by capture time (missing time last) so ties
    -- resolve to the earliest.
    local sorted = {}
    for _, i in ipairs(members[g]) do sorted[#sorted + 1] = i end
    table.sort(sorted, function(a, b)
      local ta, tb = records[a].time, records[b].time
      if ta == tb then return a < b end
      if ta == nil then return false end
      if tb == nil then return true end
      return ta < tb
    end)

    local win = {}
    local group_conflict = false
    for _, field in ipairs(FIELDS) do
      local counts, firstpos, distinct = {}, {}, 0
      for pos, i in ipairs(sorted) do
        local v = records[i][field]
        if present(v) then
          if counts[v] == nil then distinct = distinct + 1; firstpos[v] = pos end
          counts[v] = (counts[v] or 0) + 1
        end
      end
      if distinct >= 2 then group_conflict = true end
      local best, bestcount, bestpos
      for v, c in pairs(counts) do
        if best == nil or c > bestcount
           or (c == bestcount and firstpos[v] < bestpos) then
          best, bestcount, bestpos = v, c, firstpos[v]
        end
      end
      win[field] = best  -- nil when the field is empty across the whole group
    end
    if group_conflict then conflicts = conflicts + 1 end
    winners[g] = win
  end

  local out = {}
  for i = 1, #records do
    local w = winners[gid[i]]
    out[i] = { city = w.city, state = w.state, country = w.country }
  end
  return out, { groups = ngroups, conflicts = conflicts }
end

return place_reconcile
