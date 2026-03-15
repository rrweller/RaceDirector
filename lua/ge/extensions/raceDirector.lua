
local M = {}

local schemaVersion = 1
local baseConfigDir = "/settings/raceDirector"
local mapConfigDir = baseConfigDir .. "/maps"
local defaultConfigFilename = "default.json"
local defaultPresetName = "Default TV Coverage"
local defaultTriggerDistance = 90
local defaultAngleToleranceDeg = 75
local defaultTracksideHoldMs = 2500
local defaultOnboardHoldMs = 2200
local defaultCameraSpeed = 35
local defaultLoopSequence = true
local pollIntervalMs = 200
local manualRotationGraceMs = 450
local tracksidePositionTolerance = 0.12
local tracksideRotationDotTolerance = 0.995

local onboardAngles = {
  { value = "driver", label = "Driver" },
  { value = "onboard.hood", label = "Hood" },
  { value = "external", label = "External" },
  { value = "topDown", label = "Topdown" }
}
local onboardAngleAliases = {
  onboard = "driver",
  driver = "driver",
  hood = "onboard.hood",
  ["onboard.hood"] = "onboard.hood",
  orbit = "external",
  external = "external",
  topdown = "topDown",
  topDown = "topDown"
}
local targetModes = {
  { value = "racePosition", label = "Race Position" },
  { value = "randomCar", label = "Random Car" },
  { value = "specificCar", label = "Specific Car" }
}

local currentMapId = nil
local currentConfigPath = nil
local configCache = nil
local lastPollMs = 0
local idCounter = 0
local vehiclesById = {}
local progressByVehId = {}

local runtime = {
  playing = false,
  stateLabel = "Idle",
  activeEntryId = nil,
  activeEntryName = "",
  activeEntryType = "",
  activeEntryIndex = nil,
  activeTargetVehId = nil,
  nextEntryId = nil,
  nextEntryName = "",
  nextEntryIndex = nil,
  referenceVehId = nil,
  referenceVehName = "",
  focusVehId = nil,
  pausedReason = "",
  message = "",
  lastSwitchReason = "",
  lastSwitchMs = 0,
  isFreeCamera = false,
  raceTickerDetected = false,
  expectedCamera = nil
}

local function nowMs()
  return Engine.Platform.getSystemTimeMS()
end

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function copyTable(value)
  if type(value) ~= "table" then
    return value
  end

  local result = {}
  for key, entry in pairs(value) do
    result[key] = copyTable(entry)
  end
  return result
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function sanitizeText(value, fallback, maxLength)
  local text = trim(value)
  if text == "" then
    text = fallback or ""
  end
  if maxLength and #text > maxLength then
    text = text:sub(1, maxLength)
  end
  return text
end

local function simplifyVehicleName(rawName, vehId)
  local text = tostring(rawName or "")
  text = text:gsub("\\", "/")
  text = text:gsub("^.*/", "")
  text = text:gsub("%.jbeam$", "")
  text = text:gsub("[_-]+", " ")
  text = text:gsub("%s+", " ")
  text = trim(text)
  if text == "" then
    return "Vehicle " .. tostring(vehId or "")
  end

  local parts = {}
  for word in text:gmatch("%S+") do
    word = word:sub(1, 1):upper() .. word:sub(2)
    table.insert(parts, word)
  end
  return table.concat(parts, " ")
end

local function humanizeMapId(mapId)
  local text = sanitizeText(mapId, "unknown_map", 64)
  text = text:gsub("_", " ")
  text = text:gsub("%s+", " ")
  text = trim(text)
  return text:gsub("(%a)([%w']*)", function(first, rest)
    return first:upper() .. rest
  end)
end

local function normalizeBool(value, defaultValue)
  if value == nil then
    return defaultValue and true or false
  end
  return value and true or false
end

local function normalizeNumber(value, defaultValue, minValue, maxValue)
  local numericValue = tonumber(value)
  if not numericValue then
    numericValue = defaultValue
  end
  numericValue = tonumber(numericValue) or 0
  if minValue ~= nil then
    numericValue = math.max(numericValue, minValue)
  end
  if maxValue ~= nil then
    numericValue = math.min(numericValue, maxValue)
  end
  return numericValue
end

local function normalizeInteger(value, defaultValue, minValue, maxValue)
  return math.floor(normalizeNumber(value, defaultValue, minValue, maxValue))
end

local function normalizeTargetMode(value)
  local mode = tostring(value or "racePosition")
  if mode ~= "randomCar" and mode ~= "racePosition" and mode ~= "specificCar" then
    mode = "racePosition"
  end
  return mode
end

local function normalizeOnboardAngle(value)
  local requested = tostring(value or "driver")
  if onboardAngleAliases[requested] then
    requested = onboardAngleAliases[requested]
  end
  for _, angle in ipairs(onboardAngles) do
    if angle.value == requested then
      return angle.value
    end
  end
  return "driver"
end

local function sanitizeVec3(value)
  local data = type(value) == "table" and value or {}
  return {
    x = normalizeNumber(data.x, 0),
    y = normalizeNumber(data.y, 0),
    z = normalizeNumber(data.z, 0)
  }
end

local function sanitizeQuat(value)
  local data = type(value) == "table" and value or {}
  return {
    x = normalizeNumber(data.x, 0),
    y = normalizeNumber(data.y, 0),
    z = normalizeNumber(data.z, 0),
    w = normalizeNumber(data.w, 1)
  }
end

local function nextId(prefix)
  idCounter = idCounter + 1
  return string.format("%s_%d_%03d", prefix, nowMs(), idCounter)
end

local function newTracksideEntry(index, cameraData)
  local number = index or 1
  local capture = type(cameraData) == "table" and cameraData or {}
  return {
    id = nextId("cam"),
    type = "trackside",
    name = "Trackside " .. tostring(number),
    enabled = true,
    minHoldMs = defaultTracksideHoldMs,
    triggerDistance = defaultTriggerDistance,
    angleToleranceDeg = defaultAngleToleranceDeg,
    fov = normalizeNumber(capture.fov, 60, 5, 140),
    position = sanitizeVec3(capture.position),
    rotation = sanitizeQuat(capture.rotation)
  }
end

local function newOnboardEntry(index)
  local number = index or 1
  return {
    id = nextId("onb"),
    type = "onboard",
    name = "Onboard " .. tostring(number),
    enabled = true,
    minHoldMs = defaultOnboardHoldMs,
    onboardAngle = "driver",
    targetMode = "racePosition",
    targetValue = 1
  }
end

local function sanitizeEntry(entry, index)
  local data = type(entry) == "table" and copyTable(entry) or {}
  local entryType = tostring(data.type or "trackside")
  if entryType ~= "trackside" and entryType ~= "onboard" then
    entryType = "trackside"
  end

  local sanitized = {
    id = sanitizeText(data.id, nextId(entryType == "trackside" and "cam" or "onb"), 64),
    type = entryType,
    name = sanitizeText(data.name, (entryType == "trackside" and "Trackside " or "Onboard ") .. tostring(index or 1), 28),
    enabled = normalizeBool(data.enabled, true),
    minHoldMs = normalizeInteger(data.minHoldMs, entryType == "trackside" and defaultTracksideHoldMs or defaultOnboardHoldMs, 500, 20000)
  }

  if entryType == "trackside" then
    sanitized.triggerDistance = normalizeNumber(data.triggerDistance, defaultTriggerDistance, 10, 600)
    sanitized.angleToleranceDeg = normalizeNumber(data.angleToleranceDeg, defaultAngleToleranceDeg, 15, 180)
    sanitized.fov = normalizeNumber(data.fov, 60, 5, 140)
    sanitized.position = sanitizeVec3(data.position)
    sanitized.rotation = sanitizeQuat(data.rotation)
  else
    sanitized.onboardAngle = normalizeOnboardAngle(data.onboardAngle)
    sanitized.targetMode = normalizeTargetMode(data.targetMode)
    sanitized.targetValue = normalizeInteger(data.targetValue, 1, 1, 9999)
  end

  return sanitized
end

local function defaultConfig(mapId)
  return {
    schemaVersion = schemaVersion,
    mapId = sanitizeText(mapId, "unknown_map", 64),
    presetName = defaultPresetName,
    settings = {
      eventPriority = false,
      cameraSpeed = defaultCameraSpeed,
      loopSequence = defaultLoopSequence
    },
    entries = {}
  }
end

local function sanitizeConfig(config, mapId)
  local data = type(config) == "table" and copyTable(config) or {}
  local sanitized = defaultConfig(mapId)

  sanitized.mapId = sanitizeText(data.mapId, sanitized.mapId, 64)
  sanitized.presetName = sanitizeText(data.presetName, defaultPresetName, 32)
  sanitized.settings.eventPriority = normalizeBool(data.settings and data.settings.eventPriority, false)
  sanitized.settings.cameraSpeed = normalizeNumber(data.settings and data.settings.cameraSpeed, defaultCameraSpeed, 2, 100)
  sanitized.settings.loopSequence = normalizeBool(data.settings and data.settings.loopSequence, defaultLoopSequence)

  if type(data.entries) == "table" then
    for index, entry in ipairs(data.entries) do
      table.insert(sanitized.entries, sanitizeEntry(entry, index))
    end
  end

  return sanitized
end

local function buildConfigPath(mapId)
  return string.format("%s/%s/%s", mapConfigDir, sanitizeText(mapId, "unknown_map", 64), defaultConfigFilename)
end

local function ensureConfigDirs(mapId)
  FS:directoryCreate(baseConfigDir)
  FS:directoryCreate(mapConfigDir)
  FS:directoryCreate(string.format("%s/%s", mapConfigDir, sanitizeText(mapId, "unknown_map", 64)))
end

local function currentLevelId()
  local ok, levelId = pcall(getCurrentLevelIdentifier)
  if ok and levelId then
    return sanitizeText(levelId, "unknown_map", 64)
  end
  return "unknown_map"
end

local function saveConfigToDisk(config)
  if not config then
    return nil
  end

  ensureConfigDirs(config.mapId)
  currentConfigPath = buildConfigPath(config.mapId)
  jsonWriteFile(currentConfigPath, config, true)
  progressByVehId = {}
  return copyTable(config)
end

local function loadConfigForMap(mapId)
  local normalizedMapId = sanitizeText(mapId, "unknown_map", 64)
  ensureConfigDirs(normalizedMapId)
  currentConfigPath = buildConfigPath(normalizedMapId)
  local stored = jsonReadFile(currentConfigPath) or {}
  configCache = sanitizeConfig(stored, normalizedMapId)
  progressByVehId = {}
  if not FS:fileExists(currentConfigPath) then
    saveConfigToDisk(configCache)
  end
  return configCache
end

local function syncMap()
  local detectedMapId = currentLevelId()
  if detectedMapId ~= currentMapId or not configCache then
    currentMapId = detectedMapId
    loadConfigForMap(currentMapId)
    runtime.activeEntryId = nil
    runtime.activeEntryName = ""
    runtime.activeEntryType = ""
    runtime.activeEntryIndex = nil
    runtime.activeTargetVehId = nil
    runtime.nextEntryId = nil
    runtime.nextEntryName = ""
    runtime.nextEntryIndex = nil
    runtime.referenceVehId = nil
    runtime.referenceVehName = ""
    runtime.pausedReason = ""
    runtime.message = "Loaded map config for " .. humanizeMapId(currentMapId)
    runtime.expectedCamera = nil
  end
end

local function vecDistance(a, b)
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function vecDirection(fromPos, toPos)
  if not fromPos or not toPos then
    return nil, 0
  end

  local dx = (toPos.x or 0) - (fromPos.x or 0)
  local dy = (toPos.y or 0) - (fromPos.y or 0)
  local dz = (toPos.z or 0) - (fromPos.z or 0)
  local length = math.sqrt(dx * dx + dy * dy + dz * dz)
  if length <= 0.001 then
    return nil, 0
  end

  local invLength = 1 / length
  return {
    x = dx * invLength,
    y = dy * invLength,
    z = dz * invLength
  }, length
end

local function pointSegmentMetrics(point, startPos, endPos)
  if not point or not startPos or not endPos then
    return {
      distance = 0,
      progress = 0,
      rawProgress = 0
    }
  end

  local segX = (endPos.x or 0) - (startPos.x or 0)
  local segY = (endPos.y or 0) - (startPos.y or 0)
  local segZ = (endPos.z or 0) - (startPos.z or 0)
  local segLengthSq = segX * segX + segY * segY + segZ * segZ
  if segLengthSq <= 0.001 then
    return {
      distance = vecDistance(point, startPos),
      progress = 0,
      rawProgress = 0
    }
  end

  local relX = (point.x or 0) - (startPos.x or 0)
  local relY = (point.y or 0) - (startPos.y or 0)
  local relZ = (point.z or 0) - (startPos.z or 0)
  local rawProgress = ((relX * segX) + (relY * segY) + (relZ * segZ)) / segLengthSq
  local progress = clamp(rawProgress, 0, 1)
  local closestPoint = {
    x = (startPos.x or 0) + (segX * progress),
    y = (startPos.y or 0) + (segY * progress),
    z = (startPos.z or 0) + (segZ * progress)
  }

  return {
    distance = vecDistance(point, closestPoint),
    progress = progress,
    rawProgress = rawProgress
  }
end

local function directionAlignment(direction, velocity, speed)
  if not direction or not velocity then
    return 1
  end

  local speedValue = tonumber(speed) or 0
  if speedValue <= 1 then
    return 1
  end

  return (
    ((velocity.x or 0) * (direction.x or 0)) +
    ((velocity.y or 0) * (direction.y or 0)) +
    ((velocity.z or 0) * (direction.z or 0))
  ) / math.max(speedValue, 0.001)
end

local function quatDot(a, b)
  return math.abs(
    (a.x or 0) * (b.x or 0) +
    (a.y or 0) * (b.y or 0) +
    (a.z or 0) * (b.z or 0) +
    (a.w or 1) * (b.w or 1)
  )
end

local function buildCameraSnapshot()
  local isFree = commands and commands.isFreeCamera and commands.isFreeCamera() or false
  local activeCamName = nil
  if core_camera and core_camera.getActiveCamName then
    activeCamName = core_camera.getActiveCamName(0)
  end
  local focusVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil

  local snapshot = {
    isFreeCamera = isFree and true or false,
    activeCamName = activeCamName,
    focusVehId = focusVehId
  }

  if isFree and core_camera and core_camera.getPosition and core_camera.getQuat then
    local pos = core_camera.getPosition()
    local rot = core_camera.getQuat()
    snapshot.position = { x = pos.x, y = pos.y, z = pos.z }
    snapshot.rotation = { x = rot.x, y = rot.y, z = rot.z, w = rot.w }
  end

  return snapshot
end

local function updateRuntimeCameraFlags()
  local snapshot = buildCameraSnapshot()
  runtime.isFreeCamera = snapshot.isFreeCamera
  runtime.focusVehId = snapshot.focusVehId
  runtime.raceTickerDetected = extensions and extensions.raceTickerScriptAI and true or false
end

local function updateVehicleCache(force)
  local currentTime = nowMs()
  if not force and (currentTime - lastPollMs) < pollIntervalMs then
    return
  end
  lastPollMs = currentTime

  local freshVehicles = {}
  local seenVehIds = {}
  local liveVehicles = getAllVehiclesByType() or {}

  for _, vehicle in ipairs(liveVehicles) do
    if vehicle and vehicle.getID and vehicle.getPosition and vehicle.getVelocity then
      local vehId = vehicle:getID()
      local pos = vehicle:getPosition()
      local vel = vehicle:getVelocity()
      local speed = vel:length()
      freshVehicles[vehId] = {
        vehId = vehId,
        name = simplifyVehicleName((vehicle.getJBeamFilename and vehicle:getJBeamFilename()) or "", vehId),
        position = { x = pos.x, y = pos.y, z = pos.z },
        velocity = { x = vel.x, y = vel.y, z = vel.z },
        speed = speed
      }
      seenVehIds[vehId] = true
    end
  end

  vehiclesById = freshVehicles
  for vehId in pairs(progressByVehId) do
    if not seenVehIds[vehId] then
      progressByVehId[vehId] = nil
    end
  end
end
local function buildTracksideAnalysis()
  local analysis = {
    list = {},
    ordinalByEntryId = {},
    sequenceIndexByEntryId = {},
    count = 0
  }

  if not configCache or type(configCache.entries) ~= "table" then
    return analysis
  end

  local ordinal = 0
  for index, entry in ipairs(configCache.entries) do
    if entry and entry.enabled and entry.type == "trackside" and entry.position and entry.rotation then
      ordinal = ordinal + 1
      entry.sequenceIndex = index
      entry.tracksideOrdinal = ordinal
      analysis.list[ordinal] = entry
      analysis.ordinalByEntryId[entry.id] = ordinal
      analysis.sequenceIndexByEntryId[entry.id] = index
    end
  end

  analysis.count = ordinal
  if analysis.count > 1 then
    for shotOrdinal, entry in ipairs(analysis.list) do
      local previousOrdinal = shotOrdinal > 1 and (shotOrdinal - 1) or analysis.count
      local nextOrdinal = shotOrdinal < analysis.count and (shotOrdinal + 1) or 1
      local previousEntry = analysis.list[previousOrdinal]
      local nextEntry = analysis.list[nextOrdinal]

      entry.previousTracksideOrdinal = previousOrdinal
      entry.nextTracksideOrdinal = nextOrdinal
      entry.approachStart = previousEntry and previousEntry.position or nil
      entry.approachDirection, entry.approachLength = vecDirection(previousEntry and previousEntry.position or nil, entry.position)
      entry.departDirection, entry.departLength = vecDirection(entry.position, nextEntry and nextEntry.position or nil)
    end
  elseif analysis.count == 1 and analysis.list[1] then
    analysis.list[1].previousTracksideOrdinal = 1
    analysis.list[1].nextTracksideOrdinal = 1
    analysis.list[1].approachStart = analysis.list[1].position
    analysis.list[1].approachDirection = nil
    analysis.list[1].approachLength = 0
    analysis.list[1].departDirection = nil
    analysis.list[1].departLength = 0
  end

  return analysis
end

local function evaluateVehicleAgainstTrackside(vehicle, entry)
  local dx = (entry.position.x or 0) - (vehicle.position.x or 0)
  local dy = (entry.position.y or 0) - (vehicle.position.y or 0)
  local dz = (entry.position.z or 0) - (vehicle.position.z or 0)
  local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
  local triggerDistance = normalizeNumber(entry.triggerDistance, defaultTriggerDistance, 10, 600)
  local corridorWidth = clamp(triggerDistance * 0.30, 12, 30)
  local approachScore = 1
  local travelScore = 1
  local corridorDistance = distance
  local progressRatio = 0
  local rawProgress = 0

  if (vehicle.speed or 0) > 1 and distance > 0.001 then
    local invLength = 1 / distance
    local toCamX = dx * invLength
    local toCamY = dy * invLength
    local toCamZ = dz * invLength
    approachScore = (
      (vehicle.velocity.x or 0) * toCamX +
      (vehicle.velocity.y or 0) * toCamY +
      (vehicle.velocity.z or 0) * toCamZ
    ) / math.max(vehicle.speed, 0.001)
  end

  if entry.approachDirection and entry.approachStart and (entry.approachLength or 0) > 0.001 then
    local metrics = pointSegmentMetrics(vehicle.position, entry.approachStart, entry.position)
    corridorDistance = metrics.distance
    progressRatio = metrics.progress
    rawProgress = metrics.rawProgress
    travelScore = directionAlignment(entry.approachDirection, vehicle.velocity, vehicle.speed)
  else
    progressRatio = 1 - math.min(distance / math.max(triggerDistance, 1), 0.99)
    rawProgress = progressRatio
    travelScore = approachScore
  end

  local angleThreshold = math.cos(math.rad(normalizeNumber(entry.angleToleranceDeg, defaultAngleToleranceDeg, 15, 180)))
  local approaching = (vehicle.speed or 0) <= 1 or (
    approachScore >= angleThreshold and
    travelScore >= -0.05 and
    rawProgress <= 1.15
  )
  local score = distance + (corridorDistance * 1.75)

  if rawProgress < -0.20 then
    score = score + (triggerDistance * 2.5)
  end
  if rawProgress > 1.25 then
    score = score + (triggerDistance * 4)
  end
  if travelScore < -0.10 then
    score = score + (triggerDistance * 6)
  elseif travelScore < 0.20 then
    score = score + (triggerDistance * 1.75)
  end
  if corridorDistance > corridorWidth then
    score = score + ((corridorDistance - corridorWidth) * 2)
  end

  return {
    distance = distance,
    approachScore = approachScore,
    travelScore = travelScore,
    approaching = approaching,
    corridorDistance = corridorDistance,
    corridorWidth = corridorWidth,
    progressRatio = progressRatio,
    rawProgress = rawProgress,
    score = score
  }
end

local function progressForVehicle(vehicle, tracksideAnalysis)
  if not vehicle or tracksideAnalysis.count <= 0 then
    return nil
  end

  local bestEntry = nil
  local bestOrdinal = nil
  local bestEval = nil

  for ordinal, entry in ipairs(tracksideAnalysis.list) do
    local evaluation = evaluateVehicleAgainstTrackside(vehicle, entry)
    if not bestEval or evaluation.score < bestEval.score then
      bestEntry = entry
      bestOrdinal = ordinal
      bestEval = evaluation
    end
  end

  if not bestEntry or not bestEval then
    return nil
  end

  local previous = progressByVehId[vehicle.vehId] or { lap = 0, ordinal = bestOrdinal }
  local lap = previous.lap or 0

  if tracksideAnalysis.count > 1 then
    if previous.ordinal and previous.ordinal >= math.max(tracksideAnalysis.count - 1, 1) and bestOrdinal == 1 and (bestEval.rawProgress or 0) >= 0.10 then
      lap = lap + 1
    elseif previous.ordinal and bestOrdinal + 1 < previous.ordinal then
      bestOrdinal = previous.ordinal
      bestEntry = tracksideAnalysis.list[bestOrdinal] or bestEntry
      if bestEntry then
        bestEval = evaluateVehicleAgainstTrackside(vehicle, bestEntry)
      end
    end
  end

  local fraction = bestEval.progressRatio
  if fraction == nil then
    fraction = 1 - math.min(bestEval.distance / math.max(normalizeNumber(bestEntry.triggerDistance, defaultTriggerDistance, 10, 600), 1), 0.99)
  end
  fraction = clamp(fraction, 0, 0.99)
  local total = ((lap * math.max(tracksideAnalysis.count, 1)) + math.max(bestOrdinal - 1, 0)) + fraction

  local progress = {
    lap = lap,
    ordinal = bestOrdinal,
    total = total,
    entryId = bestEntry.id,
    sequenceIndex = bestEntry.sequenceIndex,
    distance = bestEval.distance,
    approachScore = bestEval.approachScore,
    travelScore = bestEval.travelScore,
    approaching = bestEval.approaching,
    progressRatio = fraction,
    corridorDistance = bestEval.corridorDistance
  }
  progressByVehId[vehicle.vehId] = progress
  return progress
end

local function orderedVehicles(tracksideAnalysis)
  local ordered = {}

  for vehId, vehicle in pairs(vehiclesById) do
    local progress = progressForVehicle(vehicle, tracksideAnalysis)
    table.insert(ordered, {
      vehId = vehId,
      name = vehicle.name,
      speed = vehicle.speed or 0,
      speedKph = math.floor((vehicle.speed or 0) * 3.6 + 0.5),
      tracksideOrdinal = progress and progress.ordinal or nil,
      progressTotal = progress and progress.total or (vehicle.speed or 0),
      nearestEntryId = progress and progress.entryId or nil,
      nearestSequenceIndex = progress and progress.sequenceIndex or nil,
      distance = progress and progress.distance or nil,
      isFocus = runtime.focusVehId ~= nil and runtime.focusVehId == vehId or false
    })
  end

  table.sort(ordered, function(left, right)
    if left.progressTotal ~= right.progressTotal then
      return left.progressTotal > right.progressTotal
    end
    if left.speed ~= right.speed then
      return left.speed > right.speed
    end
    return left.vehId < right.vehId
  end)

  if ordered[1] then
    ordered[1].isReference = true
  end

  return ordered
end

local function findEntryIndexById(entryId)
  if not configCache or type(configCache.entries) ~= "table" then
    return nil
  end

  for index, entry in ipairs(configCache.entries) do
    if entry.id == entryId then
      return index
    end
  end
  return nil
end

local function isLoopSequenceEnabled()
  return normalizeBool(configCache and configCache.settings and configCache.settings.loopSequence, defaultLoopSequence)
end

local function getNextEnabledIndex(startIndex, wrapAround)
  if not configCache or type(configCache.entries) ~= "table" or #configCache.entries == 0 then
    return nil
  end

  local size = #configCache.entries
  local cursor = startIndex or 0
  local allowWrap = wrapAround ~= false
  for _ = 1, size do
    cursor = cursor + 1
    if cursor > size then
      if not allowWrap then
        return nil
      end
      cursor = 1
    end
    local entry = configCache.entries[cursor]
    if entry and entry.enabled then
      return cursor
    end
  end

  return nil
end

local function getPreviousEnabledIndex(startIndex, wrapAround)
  if not configCache or type(configCache.entries) ~= "table" or #configCache.entries == 0 then
    return nil
  end

  local size = #configCache.entries
  local cursor = startIndex or (size + 1)
  local allowWrap = wrapAround ~= false
  for _ = 1, size do
    cursor = cursor - 1
    if cursor < 1 then
      if not allowWrap then
        return nil
      end
      cursor = size
    end
    local entry = configCache.entries[cursor]
    if entry and entry.enabled then
      return cursor
    end
  end

  return nil
end

local function findResumeIndex(referenceVehicle, tracksideAnalysis)
  if not configCache or type(configCache.entries) ~= "table" or #configCache.entries == 0 then
    return nil
  end

  local firstTracksideIndex = nil
  local firstEnabledIndex = nil
  local targetOrdinal = referenceVehicle and referenceVehicle.tracksideOrdinal or nil

  for index, entry in ipairs(configCache.entries) do
    if entry and entry.enabled then
      firstEnabledIndex = firstEnabledIndex or index
      if entry.type == "trackside" then
        firstTracksideIndex = firstTracksideIndex or index
        local ordinal = tracksideAnalysis.ordinalByEntryId[entry.id]
        if targetOrdinal and ordinal and ordinal >= targetOrdinal then
          return index
        end
      end
    end
  end

  return firstTracksideIndex or firstEnabledIndex
end

local function updateNextEntryState()
  runtime.nextEntryId = nil
  runtime.nextEntryName = ""
  runtime.nextEntryIndex = nil

  if not runtime.activeEntryIndex then
    return
  end

  local nextIndex = getNextEnabledIndex(runtime.activeEntryIndex, isLoopSequenceEnabled())
  local nextEntry = nextIndex and configCache.entries[nextIndex] or nil
  if nextEntry then
    runtime.nextEntryId = nextEntry.id
    runtime.nextEntryName = nextEntry.name
    runtime.nextEntryIndex = nextIndex
  end
end

local function markMessage(text)
  runtime.message = sanitizeText(text, "", 160)
end

local function pauseDirector(reason)
  runtime.playing = false
  runtime.stateLabel = "Paused"
  runtime.pausedReason = sanitizeText(reason, "Paused", 120)
  runtime.expectedCamera = nil
  markMessage(runtime.pausedReason)
  updateNextEntryState()
end

local function applyTracksideEntry(entry)
  if not (commands and commands.setFreeCamera and core_camera and core_camera.setPosRot) then
    markMessage("Free camera controls are unavailable in this session.")
    return false
  end

  commands.setFreeCamera()
  core_camera.setSpeed(configCache.settings.cameraSpeed or defaultCameraSpeed)
  core_camera.setPosRot(
    0,
    entry.position.x, entry.position.y, entry.position.z,
    entry.rotation.x, entry.rotation.y, entry.rotation.z, entry.rotation.w
  )
  if core_camera.setFOV then
    core_camera.setFOV(0, entry.fov or 60)
  end

  runtime.expectedCamera = {
    isFreeCamera = true,
    focusVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil,
    position = copyTable(entry.position),
    rotation = copyTable(entry.rotation)
  }
  return true
end

local function resolveOnboardTarget(entry, ordered)
  if type(ordered) ~= "table" or #ordered == 0 then
    return nil
  end

  if entry.targetMode == "specificCar" then
    local targetVehId = normalizeInteger(entry.targetValue, 1, 1)
    if vehiclesById[targetVehId] then
      return targetVehId
    end
  elseif entry.targetMode == "randomCar" then
    local selectedIndex = ((nowMs() + #ordered) % #ordered) + 1
    return ordered[selectedIndex].vehId
  else
    local targetIndex = clamp(normalizeInteger(entry.targetValue, 1, 1, #ordered), 1, #ordered)
    return ordered[targetIndex].vehId
  end

  return ordered[1].vehId
end

local function applyOnboardEntry(entry, ordered)
  if not (be and be.enterVehicle and core_camera and core_camera.setByName) then
    markMessage("Vehicle camera controls are unavailable in this session.")
    return false
  end

  local targetVehId = resolveOnboardTarget(entry, ordered)
  if not targetVehId then
    markMessage("No valid vehicle is available for this onboard shot.")
    return false
  end

  local vehicleObject = scenetree.findObject(targetVehId) or scenetree.findObject(tostring(targetVehId))
  if not vehicleObject then
    markMessage("Target vehicle " .. tostring(targetVehId) .. " was not found.")
    return false
  end

  be:enterVehicle(0, vehicleObject)
  core_camera.setByName(0, normalizeOnboardAngle(entry.onboardAngle), false)

  runtime.expectedCamera = {
    isFreeCamera = false,
    focusVehId = targetVehId,
    cameraMode = normalizeOnboardAngle(entry.onboardAngle)
  }
  runtime.activeTargetVehId = targetVehId
  return true
end
local function activateEntryByIndex(index, reason, ordered, tracksideAnalysis)
  if not index or not configCache or not configCache.entries[index] then
    return false
  end

  local entry = configCache.entries[index]
  if not entry.enabled then
    return false
  end

  local applied = false
  if entry.type == "trackside" then
    applied = applyTracksideEntry(entry)
  else
    applied = applyOnboardEntry(entry, ordered or {})
  end

  if not applied then
    return false
  end

  runtime.activeEntryId = entry.id
  runtime.activeEntryName = entry.name
  runtime.activeEntryType = entry.type
  runtime.activeEntryIndex = index
  runtime.lastSwitchMs = nowMs()
  runtime.lastSwitchReason = sanitizeText(reason, "Switch", 80)
  runtime.stateLabel = runtime.playing and "Playing" or "Preview"
  runtime.pausedReason = ""
  updateNextEntryState()

  if entry.type == "trackside" and tracksideAnalysis then
    runtime.activeTracksideOrdinal = tracksideAnalysis.ordinalByEntryId[entry.id]
  else
    runtime.activeTracksideOrdinal = nil
  end

  return true
end

local function tracksideReady(referenceVehicle, entry)
  if not referenceVehicle or not entry or not vehiclesById[referenceVehicle.vehId] then
    return false, nil
  end

  local evaluation = evaluateVehicleAgainstTrackside(vehiclesById[referenceVehicle.vehId], entry)
  local triggerDistance = normalizeNumber(entry.triggerDistance, defaultTriggerDistance, 10, 600)
  local progressGate = (entry.approachLength or 0) > math.max(triggerDistance * 0.8, 25) and 0.15 or 0.05
  local ready = evaluation.distance <= triggerDistance * 1.05
    and evaluation.corridorDistance <= evaluation.corridorWidth
    and evaluation.rawProgress >= progressGate
    and evaluation.approaching
  return ready, evaluation
end

local function detectManualOverride()
  if not runtime.playing or not runtime.expectedCamera then
    return false
  end

  local currentTime = nowMs()
  if currentTime - runtime.lastSwitchMs < manualRotationGraceMs then
    return false
  end

  if core_camera and core_camera.timeSinceLastRotation and core_camera.timeSinceLastRotation() < manualRotationGraceMs then
    pauseDirector("Manual camera input detected.")
    return true
  end

  local snapshot = buildCameraSnapshot()

  if runtime.expectedCamera.focusVehId and snapshot.focusVehId and runtime.expectedCamera.focusVehId ~= snapshot.focusVehId then
    pauseDirector("Manual vehicle focus change detected.")
    return true
  end

  if runtime.expectedCamera.isFreeCamera then
    if not snapshot.isFreeCamera then
      pauseDirector("Manual camera mode change detected.")
      return true
    end

    if snapshot.position and runtime.expectedCamera.position and vecDistance(snapshot.position, runtime.expectedCamera.position) > tracksidePositionTolerance then
      pauseDirector("Manual freecam move detected.")
      return true
    end

    if snapshot.rotation and runtime.expectedCamera.rotation and quatDot(snapshot.rotation, runtime.expectedCamera.rotation) < tracksideRotationDotTolerance then
      pauseDirector("Manual freecam rotation detected.")
      return true
    end
  else
    if snapshot.isFreeCamera then
      pauseDirector("Manual camera mode change detected.")
      return true
    end

    local expectedMode = runtime.expectedCamera.cameraMode
    if expectedMode and snapshot.activeCamName and snapshot.activeCamName ~= expectedMode then
      pauseDirector("Manual onboard camera change detected.")
      return true
    end
  end

  return false
end

local function updateReferenceVehicle(ordered)
  runtime.referenceVehId = nil
  runtime.referenceVehName = ""
  if ordered[1] then
    runtime.referenceVehId = ordered[1].vehId
    runtime.referenceVehName = ordered[1].name
  end
end

local function updateDirector()
  syncMap()
  updateRuntimeCameraFlags()
  updateVehicleCache(false)

  local tracksideAnalysis = buildTracksideAnalysis()
  local ordered = orderedVehicles(tracksideAnalysis)
  updateReferenceVehicle(ordered)

  if not runtime.playing then
    updateNextEntryState()
    return
  end

  if detectManualOverride() then
    return
  end

  if #ordered == 0 then
    runtime.stateLabel = "Waiting"
    markMessage("Spawn race cars to start directing.")
    return
  end

  if tracksideAnalysis.count == 0 then
    pauseDirector("Add at least one trackside camera before enabling playback.")
    return
  end

  local referenceVehicle = ordered[1]
  local activeIndex = runtime.activeEntryIndex
  local activeEntry = activeIndex and configCache.entries[activeIndex] or nil

  if not activeEntry or not activeEntry.enabled then
    local resumeIndex = findResumeIndex(referenceVehicle, tracksideAnalysis)
    if resumeIndex then
      activateEntryByIndex(resumeIndex, "Resume", ordered, tracksideAnalysis)
    else
      pauseDirector("No enabled sequence entries are available.")
    end
    return
  end

  local elapsed = nowMs() - runtime.lastSwitchMs
  local activeHoldMs = normalizeInteger(activeEntry.minHoldMs, activeEntry.type == "trackside" and defaultTracksideHoldMs or defaultOnboardHoldMs, 500, 20000)
  local nextIndex = getNextEnabledIndex(activeIndex, isLoopSequenceEnabled())
  local nextEntry = nextIndex and configCache.entries[nextIndex] or nil

  updateNextEntryState()

  if elapsed < activeHoldMs then
    runtime.stateLabel = "Playing"
    return
  end

  if not nextEntry then
    if isLoopSequenceEnabled() then
      runtime.stateLabel = "Playing"
    else
      pauseDirector("Reached end of sequence.")
    end
    return
  end

  if nextEntry.type == "onboard" then
    activateEntryByIndex(nextIndex, "Insert onboard", ordered, tracksideAnalysis)
    return
  end

  local nextOrdinal = tracksideAnalysis.ordinalByEntryId[nextEntry.id]
  local activeOrdinal = activeEntry.type == "trackside" and tracksideAnalysis.ordinalByEntryId[activeEntry.id] or nil

  if referenceVehicle.tracksideOrdinal and nextOrdinal and referenceVehicle.tracksideOrdinal > nextOrdinal then
    local resumeIndex = findResumeIndex(referenceVehicle, tracksideAnalysis)
    if resumeIndex and resumeIndex ~= activeIndex then
      activateEntryByIndex(resumeIndex, "Skip ahead", ordered, tracksideAnalysis)
    end
    return
  end

  if activeOrdinal and referenceVehicle.tracksideOrdinal and referenceVehicle.tracksideOrdinal > activeOrdinal + 1 then
    local resumeIndex = findResumeIndex(referenceVehicle, tracksideAnalysis)
    if resumeIndex and resumeIndex ~= activeIndex then
      activateEntryByIndex(resumeIndex, "Catch up", ordered, tracksideAnalysis)
    end
    return
  end

  local ready, evaluation = tracksideReady(referenceVehicle, nextEntry)
  if ready and evaluation and (
    referenceVehicle.tracksideOrdinal == nextOrdinal or
    (evaluation.progressRatio or 0) >= 0.70
  ) then
    activateEntryByIndex(nextIndex, "Approaching shot", ordered, tracksideAnalysis)
  else
    runtime.stateLabel = "Playing"
  end
end

local function buildVehicleSummary()
  local tracksideAnalysis = buildTracksideAnalysis()
  local ordered = orderedVehicles(tracksideAnalysis)
  local summary = {}

  for _, vehicle in ipairs(ordered) do
    table.insert(summary, {
      vehId = vehicle.vehId,
      name = vehicle.name,
      speedKph = vehicle.speedKph,
      tracksideOrdinal = vehicle.tracksideOrdinal,
      isReference = vehicle.isReference and true or false,
      isFocus = vehicle.isFocus and true or false
    })
  end

  return summary
end

local function buildState()
  syncMap()
  updateRuntimeCameraFlags()
  updateVehicleCache(false)
  updateReferenceVehicle(orderedVehicles(buildTracksideAnalysis()))
  updateNextEntryState()

  return {
    mapId = currentMapId,
    mapLabel = humanizeMapId(currentMapId),
    configPath = currentConfigPath,
    config = copyTable(configCache or defaultConfig(currentMapId)),
    runtime = copyTable(runtime),
    vehicles = buildVehicleSummary(),
    options = {
      onboardAngles = copyTable(onboardAngles),
      targetModes = copyTable(targetModes)
    }
  }
end

local function getState()
  updateDirector()
  return buildState()
end

local function saveConfig(config)
  syncMap()
  configCache = sanitizeConfig(config, currentMapId)
  saveConfigToDisk(configCache)
  markMessage("Saved preset for " .. humanizeMapId(currentMapId) .. ".")
  return buildState()
end

local function setPlaying(enabled)
  syncMap()
  runtime.playing = enabled and true or false
  runtime.stateLabel = runtime.playing and "Playing" or "Paused"
  runtime.pausedReason = ""
  runtime.message = runtime.playing and "Director running." or "Director paused."

  if runtime.playing then
    runtime.activeEntryId = nil
    runtime.activeEntryName = ""
    runtime.activeEntryType = ""
    runtime.activeEntryIndex = nil
    runtime.expectedCamera = nil
    updateDirector()
  else
    runtime.expectedCamera = nil
    updateNextEntryState()
  end

  return buildState()
end

local function skipShot(offset)
  syncMap()
  updateVehicleCache(true)

  local direction = normalizeInteger(offset, 1, -1, 1)
  local tracksideAnalysis = buildTracksideAnalysis()
  local ordered = orderedVehicles(tracksideAnalysis)
  local referenceVehicle = ordered[1]
  local targetIndex = nil

  if runtime.activeEntryIndex and configCache.entries[runtime.activeEntryIndex] and configCache.entries[runtime.activeEntryIndex].enabled then
    if direction >= 0 then
      targetIndex = getNextEnabledIndex(runtime.activeEntryIndex)
    else
      targetIndex = getPreviousEnabledIndex(runtime.activeEntryIndex)
    end
  else
    local resumeIndex = findResumeIndex(referenceVehicle, tracksideAnalysis) or getNextEnabledIndex(0)
    if direction >= 0 then
      targetIndex = resumeIndex
    else
      targetIndex = resumeIndex and getPreviousEnabledIndex(resumeIndex) or getPreviousEnabledIndex()
    end
  end

  if not targetIndex then
    markMessage("No enabled sequence entry is available.")
    return buildState()
  end

  if not activateEntryByIndex(targetIndex, direction >= 0 and "Manual next" or "Manual previous", ordered, tracksideAnalysis) then
    markMessage("Unable to activate the requested sequence entry.")
    return buildState()
  end

  if runtime.playing then
    runtime.stateLabel = "Playing"
    markMessage("Skipped to " .. (runtime.activeEntryName or "selected shot") .. ".")
  else
    runtime.stateLabel = "Paused"
    markMessage("Selected " .. (runtime.activeEntryName or "shot") .. " while paused.")
  end

  return buildState()
end
local function captureTracksideCamera()
  syncMap()
  updateRuntimeCameraFlags()

  if not (commands and commands.isFreeCamera and commands.isFreeCamera()) then
    markMessage("Switch to BeamNG freecam before saving a trackside shot.")
    return buildState()
  end

  local pos = core_camera.getPosition()
  local rot = core_camera.getQuat()
  local fov = core_camera.getFovDeg()

  local entry = newTracksideEntry(#configCache.entries + 1, {
    position = { x = pos.x, y = pos.y, z = pos.z },
    rotation = { x = rot.x, y = rot.y, z = rot.z, w = rot.w },
    fov = fov
  })
  table.insert(configCache.entries, entry)
  saveConfigToDisk(configCache)
  markMessage("Saved " .. entry.name .. ".")
  return buildState()
end

local function overwriteTracksideCamera(entryId)
  syncMap()
  updateRuntimeCameraFlags()

  if not (commands and commands.isFreeCamera and commands.isFreeCamera()) then
    markMessage("Switch to BeamNG freecam before replacing a trackside shot.")
    return buildState()
  end

  local index = findEntryIndexById(entryId)
  local entry = index and configCache.entries[index] or nil
  if not entry or entry.type ~= "trackside" then
    markMessage("That trackside shot no longer exists.")
    return buildState()
  end

  local pos = core_camera.getPosition()
  local rot = core_camera.getQuat()
  local fov = core_camera.getFovDeg()
  entry.position = { x = pos.x, y = pos.y, z = pos.z }
  entry.rotation = { x = rot.x, y = rot.y, z = rot.z, w = rot.w }
  entry.fov = normalizeNumber(fov, 60, 5, 140)
  saveConfigToDisk(configCache)
  markMessage("Updated " .. entry.name .. " from freecam.")
  return buildState()
end

local function addOnboardEntry()
  syncMap()
  local entry = newOnboardEntry(#configCache.entries + 1)
  table.insert(configCache.entries, entry)
  saveConfigToDisk(configCache)
  markMessage("Added " .. entry.name .. ".")
  return buildState()
end

local function deleteEntry(entryId)
  syncMap()
  local index = findEntryIndexById(entryId)
  if not index then
    markMessage("That sequence entry was not found.")
    return buildState()
  end

  table.remove(configCache.entries, index)
  if runtime.activeEntryId == entryId then
    runtime.activeEntryId = nil
    runtime.activeEntryIndex = nil
    runtime.activeEntryName = ""
    runtime.activeEntryType = ""
  end
  saveConfigToDisk(configCache)
  markMessage("Deleted sequence entry.")
  return buildState()
end

local function moveEntry(entryId, offset)
  syncMap()
  local index = findEntryIndexById(entryId)
  if not index then
    return buildState()
  end

  local targetIndex = clamp(index + normalizeInteger(offset, 0, -1, 1), 1, #configCache.entries)
  if targetIndex == index then
    return buildState()
  end

  local entry = table.remove(configCache.entries, index)
  table.insert(configCache.entries, targetIndex, entry)
  saveConfigToDisk(configCache)
  markMessage("Moved " .. entry.name .. ".")
  return buildState()
end

local function previewEntry(entryId)
  syncMap()
  updateVehicleCache(true)

  local index = findEntryIndexById(entryId)
  if not index then
    markMessage("That sequence entry was not found.")
    return buildState()
  end

  local tracksideAnalysis = buildTracksideAnalysis()
  local ordered = orderedVehicles(tracksideAnalysis)
  if activateEntryByIndex(index, "Preview", ordered, tracksideAnalysis) then
    runtime.playing = false
    runtime.stateLabel = "Preview"
    runtime.pausedReason = ""
    markMessage("Previewing " .. configCache.entries[index].name .. ".")
  end
  return buildState()
end

local function onUiClosed()
  if not runtime.playing then
    runtime.expectedCamera = nil
  end
end

M.getState = getState
M.saveConfig = saveConfig
M.setPlaying = setPlaying
M.skipShot = skipShot
M.captureTracksideCamera = captureTracksideCamera
M.overwriteTracksideCamera = overwriteTracksideCamera
M.addOnboardEntry = addOnboardEntry
M.deleteEntry = deleteEntry
M.moveEntry = moveEntry
M.previewEntry = previewEntry
M.onUiClosed = onUiClosed
M.onUpdate = updateDirector

return M
