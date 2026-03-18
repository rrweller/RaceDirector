
local M = {}

local schemaVersion = 2
local baseConfigDir = "/settings/raceDirector"
local mapConfigDir = baseConfigDir .. "/maps"
local defaultConfigFilename = "default.json"
local defaultPresetName = "Default TV Coverage"
local defaultTriggerDistance = 90
local defaultAngleToleranceDeg = 75
local defaultTracksideHoldMs = 1000
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
local activeTracksideSession = nil

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
  activeElapsedMs = 0,
  isFreeCamera = false,
  raceTickerDetected = false,
  expectedCamera = nil
}

local function clearTracksideSession()
  activeTracksideSession = nil
end

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
    clearTracksideSession()
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
    runtime.activeElapsedMs = 0
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

local function normalizeVec3(vector, fallback)
  if not vector then
    return fallback
  end

  local length = math.sqrt(
    ((vector.x or 0) * (vector.x or 0)) +
    ((vector.y or 0) * (vector.y or 0)) +
    ((vector.z or 0) * (vector.z or 0))
  )
  if length <= 0.001 then
    return fallback
  end

  local invLength = 1 / length
  return {
    x = (vector.x or 0) * invLength,
    y = (vector.y or 0) * invLength,
    z = (vector.z or 0) * invLength
  }
end

local function dotVec3(left, right)
  if not left or not right then
    return 0
  end

  return ((left.x or 0) * (right.x or 0)) +
    ((left.y or 0) * (right.y or 0)) +
    ((left.z or 0) * (right.z or 0))
end

local function quatForward(rotation)
  if not rotation then
    return nil
  end

  local x = tonumber(rotation.x) or 0
  local y = tonumber(rotation.y) or 0
  local z = tonumber(rotation.z) or 0
  local w = tonumber(rotation.w) or 1
  local length = math.sqrt((x * x) + (y * y) + (z * z) + (w * w))
  if length <= 0.001 then
    return { x = 0, y = 1, z = 0 }
  end

  local invLength = 1 / length
  x = x * invLength
  y = y * invLength
  z = z * invLength
  w = w * invLength

  return normalizeVec3({
    x = (2 * x * y) - (2 * w * z),
    y = (w * w) - (x * x) + (y * y) - (z * z),
    z = (2 * y * z) + (2 * w * x)
  }, { x = 0, y = 1, z = 0 })
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

local function vehicleFocusPosition(vehicle)
  local position = vehicle and vehicle.position or nil
  if not position then
    return nil
  end

  local speed = tonumber(vehicle and vehicle.speed) or 0
  local velocity = vehicle and vehicle.velocity or nil
  if speed <= 1 or not velocity then
    return {
      x = position.x or 0,
      y = position.y or 0,
      z = position.z or 0
    }
  end

  local direction = normalizeVec3(velocity, nil)
  if not direction then
    return {
      x = position.x or 0,
      y = position.y or 0,
      z = position.z or 0
    }
  end

  local offset = 1.8
  return {
    x = (position.x or 0) + (direction.x or 0) * offset,
    y = (position.y or 0) + (direction.y or 0) * offset,
    z = (position.z or 0) + (direction.z or 0) * offset
  }
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
      entry.cameraForward = quatForward(entry.rotation)
    end
  elseif analysis.count == 1 and analysis.list[1] then
    analysis.list[1].previousTracksideOrdinal = 1
    analysis.list[1].nextTracksideOrdinal = 1
    analysis.list[1].approachStart = analysis.list[1].position
    analysis.list[1].approachDirection = nil
    analysis.list[1].approachLength = 0
    analysis.list[1].departDirection = nil
    analysis.list[1].departLength = 0
    analysis.list[1].cameraForward = quatForward(analysis.list[1].rotation)
  end

  return analysis
end

local function evaluateVehicleAgainstTrackside(vehicle, entry)
  local dx = (entry.position.x or 0) - (vehicle.position.x or 0)
  local dy = (entry.position.y or 0) - (vehicle.position.y or 0)
  local dz = (entry.position.z or 0) - (vehicle.position.z or 0)
  local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
  local triggerDistance = normalizeNumber(entry.triggerDistance, defaultTriggerDistance, 10, 600)
  local corridorWidth = clamp(triggerDistance * 0.32, 12, 28)
  local travelScore = 1
  local corridorDistance = distance
  local progressRatio = 0
  local rawProgress = 0
  local hasApproachSegment = entry.approachDirection and entry.approachStart and (entry.approachLength or 0) > 0.001

  if hasApproachSegment then
    local metrics = pointSegmentMetrics(vehicle.position, entry.approachStart, entry.position)
    corridorDistance = metrics.distance
    progressRatio = metrics.progress
    rawProgress = metrics.rawProgress
    travelScore = directionAlignment(entry.approachDirection, vehicle.velocity, vehicle.speed)
  else
    progressRatio = 1 - math.min(distance / math.max(triggerDistance, 1), 0.99)
    rawProgress = progressRatio
    travelScore = 1
  end

  local approaching = (vehicle.speed or 0) <= 1 or (
    travelScore >= -0.15 and
    rawProgress <= 1.20
  )
  local score = distance + (corridorDistance * 2.1)

  if rawProgress < -0.25 then
    score = score + (triggerDistance * 4)
  end
  if rawProgress > 1.25 then
    score = score + (triggerDistance * 4)
  end
  if travelScore < -0.20 then
    score = score + (triggerDistance * 6)
  elseif travelScore < 0 then
    score = score + (triggerDistance * 2)
  end
  if corridorDistance > corridorWidth then
    score = score + ((corridorDistance - corridorWidth) * 3)
  end

  return {
    distance = distance,
    approachScore = travelScore,
    travelScore = travelScore,
    cameraFacingScore = 1,
    approaching = approaching,
    corridorDistance = corridorDistance,
    corridorWidth = corridorWidth,
    progressRatio = progressRatio,
    rawProgress = rawProgress,
    score = score
  }
end

local function wrapOrdinal(ordinal, count)
  local numericOrdinal = math.floor(tonumber(ordinal) or 0)
  local total = math.floor(tonumber(count) or 0)
  if total <= 0 then
    return nil
  end

  while numericOrdinal < 1 do
    numericOrdinal = numericOrdinal + total
  end
  while numericOrdinal > total do
    numericOrdinal = numericOrdinal - total
  end

  return numericOrdinal
end

local function tracksideStepsForward(fromOrdinal, toOrdinal, count)
  local fromValue = wrapOrdinal(fromOrdinal, count)
  local toValue = wrapOrdinal(toOrdinal, count)
  local total = math.floor(tonumber(count) or 0)
  if not fromValue or not toValue or total <= 0 then
    return nil
  end

  local steps = toValue - fromValue
  while steps < 0 do
    steps = steps + total
  end
  return steps
end

local function candidateTracksideOrdinals(count, previousOrdinal)
  local ordinals = {}
  local seen = {}

  local function addCandidate(ordinal)
    local wrapped = wrapOrdinal(ordinal, count)
    if not wrapped or seen[wrapped] then
      return
    end
    seen[wrapped] = true
    table.insert(ordinals, wrapped)
  end

  if count <= 0 then
    return ordinals
  end

  if not previousOrdinal then
    for ordinal = 1, count do
      addCandidate(ordinal)
    end
    return ordinals
  end

  addCandidate(previousOrdinal - 1)
  addCandidate(previousOrdinal)
  addCandidate(previousOrdinal + 1)
  addCandidate(previousOrdinal + 2)

  if count <= 4 then
    for ordinal = 1, count do
      addCandidate(ordinal)
    end
  end

  return ordinals
end

local function progressForVehicle(vehicle, tracksideAnalysis, writeProgress)
  if not vehicle or tracksideAnalysis.count <= 0 then
    return nil
  end

  local previous = progressByVehId[vehicle.vehId]
  local bestEntry = nil
  local bestOrdinal = nil
  local bestEval = nil
  local candidateOrdinals = candidateTracksideOrdinals(tracksideAnalysis.count, previous and previous.ordinal or nil)

  for _, ordinal in ipairs(candidateOrdinals) do
    local entry = tracksideAnalysis.list[ordinal]
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

  previous = previous or { lap = 0, ordinal = bestOrdinal }
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
  if writeProgress ~= false then
    progressByVehId[vehicle.vehId] = progress
  end
  return progress
end

local function tracksideViewHalfAngle(entry, relaxed)
  local baseFov = normalizeNumber(entry and entry.fov, 60, 5, 140)
  local halfAngle = (baseFov * 0.5) + (relaxed and 8 or 4)
  return clamp(halfAngle, 12, 88)
end

local function evaluateVehicleAgainstTracksideShot(vehicle, entry, relaxed)
  local camPos = entry and entry.position or nil
  local vehPos = vehicleFocusPosition(vehicle)
  local forward = entry and (entry.cameraForward or quatForward(entry.rotation)) or nil
  if not camPos or not vehPos then
    return nil
  end

  local dx = (vehPos.x or 0) - (camPos.x or 0)
  local dy = (vehPos.y or 0) - (camPos.y or 0)
  local dz = (vehPos.z or 0) - (camPos.z or 0)
  local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
  local triggerDistance = normalizeNumber(entry.triggerDistance, defaultTriggerDistance, 10, 600)
  local maxDistance = triggerDistance * (relaxed and 1.10 or 1.00)
  local toVehicleDirection = normalizeVec3({ x = dx, y = dy, z = dz }, nil)
  local viewHalfAngle = tracksideViewHalfAngle(entry, relaxed)
  local viewThreshold = math.cos(math.rad(viewHalfAngle))
  local hasApproachSegment = entry and entry.approachDirection and entry.approachStart and (entry.approachLength or 0) > 0.001
  local approachAlignment = directionAlignment(entry and entry.approachDirection or nil, vehicle and vehicle.velocity or nil, vehicle and vehicle.speed or nil)
  local approachThreshold = relaxed and -0.35 or -0.20
  local directionOk = approachAlignment >= approachThreshold
  local corridorDistance = distance
  local corridorWidth = clamp(triggerDistance * (relaxed and 0.58 or 0.48), 12, 40)
  local corridorProgress = nil
  local corridorRawProgress = nil
  local inCorridor = true
  local viewDot = 1

  if forward and toVehicleDirection then
    viewDot = dotVec3(forward, toVehicleDirection)
  end

  if hasApproachSegment then
    local metrics = pointSegmentMetrics(vehPos, entry.approachStart, entry.position)
    corridorDistance = metrics.distance
    corridorProgress = metrics.progress
    corridorRawProgress = metrics.rawProgress
    inCorridor = corridorDistance <= corridorWidth and corridorRawProgress >= -0.30 and corridorRawProgress <= 1.35
  end

  local inFov = viewDot >= viewThreshold
  local inRange = distance <= maxDistance
  local visible = inFov and inRange and inCorridor and directionOk
  local score = distance + ((1 - math.max(viewDot, -1)) * triggerDistance * 0.7) + (corridorDistance * 1.2)

  if not inFov then
    score = score + (triggerDistance * 8)
  end
  if not inRange then
    score = score + ((distance - maxDistance) * 4) + (triggerDistance * 3)
  end
  if not inCorridor then
    score = score + (triggerDistance * 5) + (math.max(corridorDistance - corridorWidth, 0) * 3)
  end
  if not directionOk then
    score = score + (triggerDistance * 4)
  end

  return {
    distance = distance,
    maxDistance = maxDistance,
    viewDot = viewDot,
    viewHalfAngle = viewHalfAngle,
    viewThreshold = viewThreshold,
    inFov = inFov,
    inRange = inRange,
    inCorridor = inCorridor,
    corridorDistance = corridorDistance,
    corridorWidth = corridorWidth,
    corridorProgress = corridorProgress,
    corridorRawProgress = corridorRawProgress,
    approachAlignment = approachAlignment,
    directionOk = directionOk,
    visible = visible,
    score = score
  }
end

local function orderedVehicles(tracksideAnalysis, writeProgress)
  local ordered = {}

  for vehId, vehicle in pairs(vehiclesById) do
    local progress = progressForVehicle(vehicle, tracksideAnalysis, writeProgress)
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

local function selectReferenceVehicle(ordered)
  if type(ordered) ~= "table" or #ordered == 0 then
    return nil
  end

  return ordered[1]
end

local function frontPackCount(ordered)
  if type(ordered) ~= "table" then
    return 0
  end

  return math.max(1, math.ceil(#ordered / 2))
end

local function selectFrontPackTriggerVehicle(entry, ordered)
  local bestVehicle = nil
  local bestEvaluation = nil
  local bestVisibleVehicle = nil
  local bestVisibleEvaluation = nil
  local count = frontPackCount(ordered)
  local index
  local candidate
  local vehicle
  local evaluation

  if not entry or count <= 0 then
    return nil, nil
  end

  for index = 1, count do
    candidate = ordered[index]
    vehicle = candidate and vehiclesById[candidate.vehId] or nil
    if vehicle then
      evaluation = evaluateVehicleAgainstTracksideShot(vehicle, entry, false)
      if evaluation and evaluation.visible and (not bestVisibleEvaluation or evaluation.score < bestVisibleEvaluation.score) then
        bestVisibleVehicle = candidate
        bestVisibleEvaluation = evaluation
      end
      if evaluation and (not bestEvaluation or evaluation.score < bestEvaluation.score) then
        bestVehicle = candidate
        bestEvaluation = evaluation
      end
    end
  end

  return bestVisibleVehicle or bestVehicle, bestVisibleEvaluation or bestEvaluation
end

local function collectTracksideVisibility(entry, ordered, relaxed)
  local summary = {
    visibleCount = 0,
    visibleVehIds = {},
    nearestVisibleVehicle = nil,
    nearestVisibleEvaluation = nil,
    frontPackVisibleCount = 0,
    frontPackVisibleVehIds = {},
    nearestFrontPackVisibleVehicle = nil,
    nearestFrontPackVisibleEvaluation = nil
  }
  local count = type(ordered) == "table" and #ordered or 0
  local frontCount = frontPackCount(ordered)
  local index
  local candidate
  local vehicle
  local evaluation

  if not entry or count <= 0 then
    return summary
  end

  for index = 1, count do
    candidate = ordered[index]
    vehicle = candidate and vehiclesById[candidate.vehId] or nil
    if vehicle then
      evaluation = evaluateVehicleAgainstTracksideShot(vehicle, entry, relaxed)
      if evaluation and evaluation.visible then
        summary.visibleCount = summary.visibleCount + 1
        summary.visibleVehIds[candidate.vehId] = true
        if index <= frontCount then
          summary.frontPackVisibleCount = summary.frontPackVisibleCount + 1
          summary.frontPackVisibleVehIds[candidate.vehId] = true
          if not summary.nearestFrontPackVisibleEvaluation or evaluation.distance < summary.nearestFrontPackVisibleEvaluation.distance then
            summary.nearestFrontPackVisibleVehicle = candidate
            summary.nearestFrontPackVisibleEvaluation = evaluation
          end
        end
        if not summary.nearestVisibleEvaluation or evaluation.distance < summary.nearestVisibleEvaluation.distance then
          summary.nearestVisibleVehicle = candidate
          summary.nearestVisibleEvaluation = evaluation
        end
      end
    end
  end

  return summary
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

local tracksideReady

local function findResumeIndex(referenceVehicle, tracksideAnalysis, ordered)
  if not configCache or type(configCache.entries) ~= "table" or #configCache.entries == 0 then
    return nil
  end

  local firstTracksideIndex = nil
  local firstEnabledIndex = nil
  local targetOrdinal = wrapOrdinal(referenceVehicle and referenceVehicle.tracksideOrdinal or 1, tracksideAnalysis.count) or 1

  for index, entry in ipairs(configCache.entries) do
    if entry and entry.enabled then
      firstEnabledIndex = firstEnabledIndex or index
      if entry.type == "trackside" then
        firstTracksideIndex = firstTracksideIndex or index
      end
    end
  end

  if tracksideAnalysis.count > 0 then
    for offset = 0, tracksideAnalysis.count - 1 do
      local ordinal = wrapOrdinal(targetOrdinal + offset, tracksideAnalysis.count)
      local entry = ordinal and tracksideAnalysis.list[ordinal] or nil
      if entry and entry.sequenceIndex then
        local _, ready = tracksideReady(entry, ordered)
        if ready then
          return entry.sequenceIndex
        end
      end
    end
  end

  if tracksideAnalysis.count > 0 then
    local entry = tracksideAnalysis.list[targetOrdinal]
    if entry and entry.sequenceIndex then
      return entry.sequenceIndex
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
  clearTracksideSession()
  markMessage(runtime.pausedReason)
  updateNextEntryState()
end

local function beginTracksideSession(ordered)
  local expectedVehIds = {}
  local expectedCount = 0
  local requiredSeenCount = 0
  local trackedCount = frontPackCount(ordered)
  local index
  local candidate

  if type(ordered) == "table" then
    for index = 1, trackedCount do
      candidate = ordered[index]
      if candidate and candidate.vehId and not expectedVehIds[candidate.vehId] then
        expectedVehIds[candidate.vehId] = true
        expectedCount = expectedCount + 1
      end
    end
  end

  if expectedCount > 0 then
    requiredSeenCount = math.max(1, math.floor((expectedCount * 0.5) + 0.5))
  end

  activeTracksideSession = {
    expectedVehIds = expectedVehIds,
    expectedCount = expectedCount,
    requiredSeenCount = requiredSeenCount,
    seenVehIds = {},
    seenCount = 0,
    lastVisibleMs = nil
  }
end

local function updateTracksideSession(visibility)
  local session = activeTracksideSession
  local visibleVehIds = visibility and visibility.visibleVehIds or nil
  local currentTime = nowMs()
  local seenCount = 0
  local expectedCount = 0
  local requiredSeenCount = 0
  local visibleExpectedCount = 0
  local clearDurationMs = 0
  local vehId

  if not session then
    return 0, 0, 0, 0, 0
  end

  expectedCount = tonumber(session.expectedCount) or 0
  requiredSeenCount = tonumber(session.requiredSeenCount) or 0
  if type(visibleVehIds) == "table" then
    for vehId in pairs(visibleVehIds) do
      if expectedCount <= 0 or session.expectedVehIds[vehId] then
        if not session.seenVehIds[vehId] then
          session.seenVehIds[vehId] = true
          session.seenCount = (session.seenCount or 0) + 1
        end
        visibleExpectedCount = visibleExpectedCount + 1
      end
    end
  end
  if visibleExpectedCount > 0 then
    session.lastVisibleMs = currentTime
  end

  seenCount = tonumber(session.seenCount) or 0
  if session.lastVisibleMs then
    clearDurationMs = math.max(0, currentTime - session.lastVisibleMs)
  end
  return seenCount, expectedCount, requiredSeenCount, visibleExpectedCount, clearDurationMs
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
  runtime.activeElapsedMs = 0
  runtime.lastSwitchReason = sanitizeText(reason, "Switch", 80)
  runtime.stateLabel = runtime.playing and "Playing" or "Preview"
  runtime.pausedReason = ""
  updateNextEntryState()

  if entry.type == "trackside" and tracksideAnalysis then
    runtime.activeTracksideOrdinal = tracksideAnalysis.ordinalByEntryId[entry.id]
    beginTracksideSession(ordered)
  else
    runtime.activeTracksideOrdinal = nil
    clearTracksideSession()
  end

  return true
end

tracksideReady = function(entry, ordered)
  if not entry then
    return nil, false, nil, nil
  end

  local visibility = collectTracksideVisibility(entry, ordered, false)
  local triggerVehicle = visibility.nearestFrontPackVisibleVehicle or visibility.nearestVisibleVehicle
  local evaluation = visibility.nearestFrontPackVisibleEvaluation or visibility.nearestVisibleEvaluation
  local ready = (visibility.frontPackVisibleCount or 0) > 0
  return triggerVehicle, ready, evaluation, visibility
end

local function findNextReadyTracksideIndex(startIndex, ordered, maxTracksideHops)
  if not configCache or type(configCache.entries) ~= "table" or #configCache.entries == 0 then
    return nil
  end

  local size = #configCache.entries
  local cursor = startIndex or 0
  local hops = 0

  for _ = 1, size do
    cursor = getNextEnabledIndex(cursor, isLoopSequenceEnabled())
    if not cursor then
      return nil
    end

    local entry = configCache.entries[cursor]
    if entry and entry.type == "trackside" then
      hops = hops + 1
      if maxTracksideHops and maxTracksideHops > 0 and hops > maxTracksideHops then
        return nil
      end
      local _, ready = tracksideReady(entry, ordered)
      if ready then
        return cursor
      end
    end
  end

  return nil
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
  local referenceVehicle = selectReferenceVehicle(ordered)
  if referenceVehicle then
    runtime.referenceVehId = referenceVehicle.vehId
    runtime.referenceVehName = referenceVehicle.name
  end
end

local function advanceActiveElapsed(dtReal, dtSim)
  if not runtime.playing or not runtime.activeEntryId then
    return
  end

  local deltaSeconds = tonumber(dtSim)
  if not deltaSeconds then
    deltaSeconds = tonumber(dtReal)
  end
  deltaSeconds = math.max(tonumber(deltaSeconds) or 0, 0)
  runtime.activeElapsedMs = math.max(0, (runtime.activeElapsedMs or 0) + (deltaSeconds * 1000))
end

local function updateDirector(dtReal, dtSim, dtRaw)
  syncMap()
  updateRuntimeCameraFlags()
  updateVehicleCache(false)
  advanceActiveElapsed(dtReal, dtSim)

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

  local referenceVehicle = selectReferenceVehicle(ordered)
  local activeIndex = runtime.activeEntryIndex
  local activeEntry = activeIndex and configCache.entries[activeIndex] or nil

  if not activeEntry or not activeEntry.enabled then
    local resumeIndex = findResumeIndex(referenceVehicle, tracksideAnalysis, ordered)
    if resumeIndex then
      activateEntryByIndex(resumeIndex, "Resume", ordered, tracksideAnalysis)
    else
      pauseDirector("No enabled sequence entries are available.")
    end
    return
  end

  local elapsed = runtime.activeElapsedMs or 0
  local activeMinHoldMs = normalizeInteger(activeEntry.minHoldMs, activeEntry.type == "trackside" and defaultTracksideHoldMs or defaultOnboardHoldMs, 500, 20000)
  local nextIndex = getNextEnabledIndex(activeIndex, isLoopSequenceEnabled())
  local nextEntry = nextIndex and configCache.entries[nextIndex] or nil

  updateNextEntryState()

  if elapsed < activeMinHoldMs then
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

  local currentTracksideVisibility = nil
  local currentTracksideReleased = true

  if activeEntry.type == "trackside" then
    local seenCount
    local expectedCount
    local requiredSeenCount
    local visibleExpectedCount
    local clearDurationMs
    local referenceSteps = nil
    local referenceMovedAhead = false
    local seenEnough = false
    currentTracksideVisibility = collectTracksideVisibility(activeEntry, ordered, true)
    seenCount, expectedCount, requiredSeenCount, visibleExpectedCount, clearDurationMs = updateTracksideSession(currentTracksideVisibility)
    referenceSteps = tracksideStepsForward(runtime.activeTracksideOrdinal, referenceVehicle and referenceVehicle.tracksideOrdinal or nil, tracksideAnalysis.count)
    referenceMovedAhead = referenceSteps ~= nil and referenceSteps >= 1
    seenEnough = requiredSeenCount > 0 and seenCount >= requiredSeenCount

    currentTracksideReleased = visibleExpectedCount == 0 and clearDurationMs >= 120 and (
      seenEnough or
      (referenceMovedAhead and seenCount > 0)
    )
  end

  if nextEntry.type == "onboard" then
    if activeEntry.type ~= "trackside" or currentTracksideReleased then
      local onboardAdvanceReason = activeEntry.type == "trackside" and "Track clear" or "Insert onboard"
      activateEntryByIndex(nextIndex, onboardAdvanceReason, ordered, tracksideAnalysis)
    else
      runtime.stateLabel = "Playing"
    end
    return
  end

  local triggerVehicle, ready, evaluation = tracksideReady(nextEntry, ordered)
  if ready and evaluation and triggerVehicle and (activeEntry.type ~= "trackside" or currentTracksideReleased) then
    local tracksideAdvanceReason = activeEntry.type == "trackside" and "Track clear" or "Shot ready"
    activateEntryByIndex(nextIndex, tracksideAdvanceReason, ordered, tracksideAnalysis)
  elseif activeEntry.type == "trackside" and currentTracksideReleased then
    local recoveryIndex = findNextReadyTracksideIndex(activeIndex, ordered, 2)
    if recoveryIndex and recoveryIndex ~= activeIndex and recoveryIndex ~= nextIndex then
      activateEntryByIndex(recoveryIndex, "Recover sequence", ordered, tracksideAnalysis)
    else
      runtime.stateLabel = "Playing"
    end
  else
    runtime.stateLabel = "Playing"
  end
end

local function buildVehicleSummaryFromOrdered(ordered)
  local summary = {}

  for _, vehicle in ipairs(ordered or {}) do
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
  local tracksideAnalysis = buildTracksideAnalysis()
  local ordered = orderedVehicles(tracksideAnalysis, false)
  local runtimeSnapshot = copyTable(runtime)
  local referenceVehicle = selectReferenceVehicle(ordered)
  local nextIndex = nil
  local nextEntry = nil

  runtimeSnapshot.referenceVehId = nil
  runtimeSnapshot.referenceVehName = ""
  if referenceVehicle then
    runtimeSnapshot.referenceVehId = referenceVehicle.vehId
    runtimeSnapshot.referenceVehName = referenceVehicle.name
  end

  runtimeSnapshot.nextEntryId = nil
  runtimeSnapshot.nextEntryName = ""
  runtimeSnapshot.nextEntryIndex = nil
  if runtimeSnapshot.activeEntryIndex then
    nextIndex = getNextEnabledIndex(runtimeSnapshot.activeEntryIndex, isLoopSequenceEnabled())
    nextEntry = nextIndex and configCache.entries[nextIndex] or nil
    if nextEntry then
      runtimeSnapshot.nextEntryId = nextEntry.id
      runtimeSnapshot.nextEntryName = nextEntry.name
      runtimeSnapshot.nextEntryIndex = nextIndex
    end
  end

  return {
    mapId = currentMapId,
    mapLabel = humanizeMapId(currentMapId),
    configPath = currentConfigPath,
    config = copyTable(configCache or defaultConfig(currentMapId)),
    runtime = runtimeSnapshot,
    vehicles = buildVehicleSummaryFromOrdered(ordered),
    options = {
      onboardAngles = copyTable(onboardAngles),
      targetModes = copyTable(targetModes)
    }
  }
end

local function getState()
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
    runtime.activeElapsedMs = 0
    runtime.expectedCamera = nil
    clearTracksideSession()
    updateDirector()
  else
    runtime.activeElapsedMs = 0
    runtime.expectedCamera = nil
    clearTracksideSession()
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
    local resumeIndex = findResumeIndex(referenceVehicle, tracksideAnalysis, ordered) or getNextEnabledIndex(0)
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
    runtime.activeElapsedMs = 0
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
