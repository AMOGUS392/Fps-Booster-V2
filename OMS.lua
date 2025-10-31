local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local fastSqrt = math.sqrt
local fastMax = math.max
local fastMin = math.min
local fastFloor = math.floor
local fastClamp = math.clamp
local osClock = os.clock
local clearTable = table.clear

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoidRootPart = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart")

local config = {
 target_fps = 50,
 cleanup_distance = 280,
 min_distance = 220,
 max_distance = 450,
 safe_zone = 75,
 objects_per_frame = 25,
 min_per_frame = 10,
 max_per_frame = 50,
 adjustment_interval = 0.5,
 scan_interval = 0.35,
 fps_sample_count = 22,
 aggressive_mode_threshold = 40,
 extreme_mode_threshold = 20,
 super_extreme_threshold = 15,
 ultra_extreme_distance_min = 50,
 ultra_extreme_distance_max = 100,
 restore_multiplier = 0.75,
 floor_min_area = 500,
 floor_max_height = 8,
 hide_scan_batch = 400,
 restore_scan_batch = 200,
 vertical_check_threshold = 18,
 safe_zone_multiplier = 1.69,
 tight_radius_base = 30,
 fps_ratio_min = 5,
 fps_ratio_range = 10,
 max_effect_scan_depth = 3,
 parent_operations_per_defer = 5,
 defer_cooldown = 0.016
}

local state = {
 cleanup_distance = config.cleanup_distance,
 safe_zone = config.safe_zone,
 objects_per_frame = config.objects_per_frame,
 last_parent_operation = 0,
 running = true
}

local stabilitySystem = {
 last_aggressive_trigger = osClock(),
 restoration_speed = 1.0
}

local hiddenFolder = ReplicatedStorage:FindFirstChild("HiddenObjects_LOD")
if not hiddenFolder then
 hiddenFolder = Instance.new("Folder")
 hiddenFolder.Name = "HiddenObjects_LOD"
 hiddenFolder.Parent = ReplicatedStorage
end

local originalParents = {}
local pendingHide = {}
local pendingRestore = {}

local allParts = {}
local allPartsCount = 0
local partsToHide = table.create(1024)
local partsToRestore = table.create(512)
local partsToHideLen = 0
local partsToRestoreLen = 0

local hiddenParts = table.create(512)
local hiddenLookup = {}
local hiddenCount = 0
local restoringNow = {}

local playerCharacters = {}
local playerConnections = {}
local floorCache = {}
local effectCache = {}
local extentCache = {}
local partConnections = {}
local skipPartCache = {}

local fpsSamples = table.create(config.fps_sample_count, config.target_fps)
local fpsIndex = 1
local fpsSum = config.target_fps * config.fps_sample_count

local aggressiveMode = false
local extremeMode = false
local superExtremeMode = false

local workspaceTerrain = Workspace.Terrain

local hideIndex = 1
local restoreIndex = 1
local scanCursor = nil
local hiddenScanIndex = 1

local hideBufferVersion = 0
local activeHideVersion = 0
local restoreBufferVersion = 0
local activeRestoreVersion = 0

local isRebuilding = false
local lastRebuildTime = -math.huge
local rebuildDebounce = 5

local globalConnections = {}

local function getCamera()
 return Workspace.CurrentCamera
end

local camera = getCamera()
if not camera then
 Workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
 camera = getCamera()
end

local function addHiddenPart(part)
 if hiddenLookup[part] then
  return
 end
 hiddenCount += 1
 hiddenParts[hiddenCount] = part
 hiddenLookup[part] = hiddenCount
end

local function removeHiddenPart(part)
 local index = hiddenLookup[part]
 if not index then
  return
 end
	
 local lastPartInTable = hiddenParts[hiddenCount]
	
 if index ~= hiddenCount then
  hiddenParts[index] = lastPartInTable
  if lastPartInTable then
   hiddenLookup[lastPartInTable] = index
  end
 end
	
 hiddenParts[hiddenCount] = nil
 hiddenLookup[part] = nil
 hiddenCount -= 1
	
 if hiddenCount <= 0 then
  hiddenCount = 0
  hiddenScanIndex = 1
 elseif hiddenScanIndex > hiddenCount then
  hiddenScanIndex = 1
 end
end

local function refreshCharacterReference()
 if not character or not character.Parent then
  character = player.Character
 end
 if character then
  if not humanoidRootPart or humanoidRootPart.Parent ~= character then
   humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
  end
 else
  humanoidRootPart = nil
 end
 return humanoidRootPart ~= nil
end

local function invalidatePartCache(part)
 skipPartCache[part] = nil
 floorCache[part] = nil
 extentCache[part] = nil
end

local function shouldSkipPart(part, cam)
 local cached = skipPartCache[part]
 if cached ~= nil then
  return cached
 end
	
 local pooled = part:GetAttribute("_PooledObject")
 if pooled == true then
  skipPartCache[part] = true
  return true
 end
	
 if cam and part:IsDescendantOf(cam) then
  skipPartCache[part] = true
  return true
 end
	
 local current = part
 while current and current ~= Workspace do
  if playerCharacters[current] then
   skipPartCache[part] = true
   return true
  end
  current = current.Parent
 end
	
 skipPartCache[part] = false
 return false
end

local function deregisterPart(part)
 if allParts[part] then
  allParts[part] = nil
  allPartsCount -= 1
  if allPartsCount < 0 then
   allPartsCount = 0
  end
  if scanCursor == part then
   scanCursor = nil
  end
 end
end

local function cleanupTracking(part)
 deregisterPart(part)
 invalidatePartCache(part)
 originalParents[part] = nil
 effectCache[part] = nil
 pendingHide[part] = nil
 pendingRestore[part] = nil
 removeHiddenPart(part)
	
 if partConnections[part] then
  for key, conn in partConnections[part] do
   pcall(function()
    if conn and typeof(conn) == "RBXScriptConnection" then
     conn:Disconnect()
    end
   end)
  end
  partConnections[part] = nil
 end
end

local function isLargeFloor(part)
 local cached = floorCache[part]
 if cached ~= nil then
  return cached
 end
	
 local success, partSize = pcall(function()
  return part.Size
 end)
	
 if not success then
  floorCache[part] = false
  return false
 end
	
 local sizeY = partSize.Y
	
 if sizeY > config.floor_max_height then
  floorCache[part] = false
  return false
 end
	
 local horizontalArea = partSize.X * partSize.Z
 local isFloor = horizontalArea >= config.floor_min_area
	
 floorCache[part] = isFloor
 return isFloor
end

local function getBoundingRadius(part)
 local cached = extentCache[part]
 if cached then
  return cached
 end
	
 local success, partSize = pcall(function()
  return part.Size
 end)
	
 if not success then
  extentCache[part] = 0
  return 0
 end
	
 local halfX = partSize.X * 0.5
 local halfY = partSize.Y * 0.5
 local halfZ = partSize.Z * 0.5
 local radius = fastSqrt(halfX * halfX + halfY * halfY + halfZ * halfZ)
	
 extentCache[part] = radius
 return radius
end

local function registerPart(part, cam)
 if not part:IsA("BasePart") then
  return
 end
	
 if allParts[part]
  or part == workspaceTerrain
  or part:IsDescendantOf(workspaceTerrain)
  or part:IsDescendantOf(hiddenFolder) then
  return
 end
	
 skipPartCache[part] = nil
	
 if shouldSkipPart(part, cam) then
  return
 end
	
 allParts[part] = true
 allPartsCount += 1
	
 local connections = {}
	
 local success1, sizeConn = pcall(function()
  return part:GetPropertyChangedSignal("Size"):Connect(function()
   invalidatePartCache(part)
  end)
 end)
	
 if success1 and sizeConn then
  connections.size = sizeConn
 end
	
 local success2, ancestryConn = pcall(function()
  return part.AncestryChanged:Connect(function()
   invalidatePartCache(part)
  end)
 end)
	
 if success2 and ancestryConn then
  connections.ancestry = ancestryConn
 end
	
 if next(connections) then
  partConnections[part] = connections
 end
end

local function scanEffectsRecursive(instance, effects, depth, visited)
 if depth > config.max_effect_scan_depth or visited[instance] then
  return effects
 end
	
 visited[instance] = true
	
 local children = instance:GetChildren()
 local childCount = #children
 for i = 1, childCount do
  local child = children[i]
  local class = child.ClassName
  
  if class == "ParticleEmitter" or class == "PointLight" 
   or class == "SpotLight" or class == "Sound" 
   or class == "Fire" or class == "Smoke" 
   or class == "Sparkles" then
   
   effects = effects or table.create(6)
   local effectsLen = #effects
   effects[effectsLen + 1] = {
    effect = child,
    was_enabled = class ~= "Sound" and child.Enabled or nil,
    was_playing = class == "Sound" and child.Playing or nil
   }
  else
   effects = scanEffectsRecursive(child, effects, depth + 1, visited)
  end
 end
	
 return effects
end

local function scanEffectsImmediate(part)
 if effectCache[part] then
  return
 end
	
 local visited = {}
 local effects = scanEffectsRecursive(part, nil, 1, visited)
	
 if effects then
  effectCache[part] = effects
 end
end

local function disableEffects(part)
 local effects = effectCache[part]
 if not effects then
  return
 end
	
 local effectCount = #effects
 for i = 1, effectCount do
  local effectData = effects[i]
  local effect = effectData.effect
  
  if effect and effect.Parent then
   pcall(function()
    if effect:IsA("Sound") then
     if effect.Playing then
      effect:Stop()
     end
    else
     if effect:IsA("ParticleEmitter") then
      effect:Clear()
     end
     effect.Enabled = false
    end
   end)
  end
 end
end

local function enableEffects(part)
 local effects = effectCache[part]
 if not effects then
  return
 end
	
 local effectCount = #effects
 for i = 1, effectCount do
  local effectData = effects[i]
  local effect = effectData.effect
  
  if effect and effect.Parent then
   pcall(function()
    if effect:IsA("Sound") then
     if effectData.was_playing then
      effect:Play()
     end
    else
     if effectData.was_enabled ~= nil then
      effect.Enabled = effectData.was_enabled
     end
    end
   end)
  end
 end
end

local function calculateAverageFPS()
 return fpsSum / config.fps_sample_count
end

local function adjustParameters()
 local avgFPS = calculateAverageFPS()

 local newCleanup = state.cleanup_distance
 local newObjects = state.objects_per_frame
 local newSafeZone = state.safe_zone
 local newRestorationSpeed = stabilitySystem.restoration_speed

 if avgFPS < config.super_extreme_threshold then
  superExtremeMode = true
  extremeMode = true
  aggressiveMode = true
  stabilitySystem.last_aggressive_trigger = osClock()
  newRestorationSpeed = 0

  local fpsRatio = fastClamp((avgFPS - config.fps_ratio_min) / config.fps_ratio_range, 0, 1)
  newCleanup = config.ultra_extreme_distance_min + (config.ultra_extreme_distance_max - config.ultra_extreme_distance_min) * fpsRatio
  newObjects = config.max_per_frame
  newSafeZone = config.safe_zone
 elseif avgFPS < config.extreme_mode_threshold then
  superExtremeMode = false
  extremeMode = true
  aggressiveMode = true
  stabilitySystem.last_aggressive_trigger = osClock()
  newRestorationSpeed = 0

  newCleanup = 320
  newObjects = fastMin(config.max_per_frame, 35)
  newSafeZone = config.safe_zone
 elseif avgFPS < config.aggressive_mode_threshold then
  superExtremeMode = false
  extremeMode = false
  aggressiveMode = true
  newRestorationSpeed = 0.3

  newCleanup = 360
  newObjects = 30
  newSafeZone = config.safe_zone
 else
  superExtremeMode = false
  extremeMode = false
  aggressiveMode = false

  local timeSince = osClock() - stabilitySystem.last_aggressive_trigger
  newRestorationSpeed = timeSince > 5 and 1.0 or 0.6

  if avgFPS > config.target_fps + 10 then
   newCleanup = fastMin(config.max_distance, state.cleanup_distance + 35)
   newObjects = fastMin(config.max_per_frame, state.objects_per_frame + 8)
   newSafeZone = fastMax(config.safe_zone, state.safe_zone + 5)
  else
   newCleanup = fastMax(config.min_distance, state.cleanup_distance - 20)
   newObjects = fastMax(config.min_per_frame, state.objects_per_frame - 4)
   newSafeZone = fastMax(config.safe_zone, state.safe_zone - 2)
  end
 end

 stabilitySystem.restoration_speed = newRestorationSpeed
 state.cleanup_distance = fastClamp(newCleanup, config.min_distance, config.max_distance)
 state.objects_per_frame = fastClamp(newObjects, config.min_per_frame, config.max_per_frame)
 state.safe_zone = fastMax(config.safe_zone, newSafeZone)
end

local function detachCharacterParts(characterModel)
 if not characterModel then
  return
 end
	
 local descendants = characterModel:GetDescendants()
 local descCount = #descendants
	
 for i = 1, descCount do
  local desc = descendants[i]
  if desc:IsA("BasePart") then
   cleanupTracking(desc)
  end
 end
end

local function addCharacterToTracking(char)
 if not char then return end
 playerCharacters[char] = true
 detachCharacterParts(char)
end

local function removeCharacterFromTracking(char)
 if not char then return end
 if playerCharacters[char] then
  playerCharacters[char] = nil
  detachCharacterParts(char)
 end
end

local function disconnectPlayerConnections(plr)
 if playerConnections[plr] then
  local connections = playerConnections[plr]
  local connCount = #connections
  for i = 1, connCount do
   local conn = connections[i]
   pcall(function()
    if conn and typeof(conn) == "RBXScriptConnection" then
     conn:Disconnect()
    end
   end)
  end
  playerConnections[plr] = nil
 end
end

local function setupPlayerConnections(plr)
 if plr == player then
  return
 end
	
 disconnectPlayerConnections(plr)
	
 if plr.Character then
  addCharacterToTracking(plr.Character)
 end
	
 local connections = {}
 connections[1] = plr.CharacterAdded:Connect(addCharacterToTracking)
 connections[2] = plr.CharacterRemoving:Connect(removeCharacterFromTracking)
 playerConnections[plr] = connections
end

local existingPlayers = Players:GetPlayers()
local playerCount = #existingPlayers
for i = 1, playerCount do
 setupPlayerConnections(existingPlayers[i])
end

globalConnections.localCharacterAdded = player.CharacterAdded:Connect(function(char)
 character = char
 humanoidRootPart = char:WaitForChild("HumanoidRootPart", 10)
 if humanoidRootPart then
  addCharacterToTracking(char)
 end
end)

globalConnections.localCharacterRemoving = player.CharacterRemoving:Connect(function(char)
 humanoidRootPart = nil
 removeCharacterFromTracking(char)
end)

globalConnections.playerAdded = Players.PlayerAdded:Connect(setupPlayerConnections)

globalConnections.playerRemoving = Players.PlayerRemoving:Connect(function(plr)
 removeCharacterFromTracking(plr.Character)
 disconnectPlayerConnections(plr)
end)

refreshCharacterReference()

local function rebuildPartList()
 local now = osClock()
 if isRebuilding or (now - lastRebuildTime) < rebuildDebounce then
  return
 end
	
 isRebuilding = true
 lastRebuildTime = now
	
 local partsToCleanup = {}
 local cleanupCount = 0
 for part in allParts do
  cleanupCount += 1
  partsToCleanup[cleanupCount] = part
 end
	
 for i = 1, cleanupCount do
  cleanupTracking(partsToCleanup[i])
 end
	
 allParts = {}
 allPartsCount = 0
 scanCursor = nil
 hiddenScanIndex = 1

 local cam = getCamera()
 local descendants = Workspace:GetDescendants()
 local descCount = #descendants
	
 for i = 1, descCount do
  registerPart(descendants[i], cam)
 end
	
 isRebuilding = false
end

globalConnections.workspaceAdded = Workspace.DescendantAdded:Connect(function(obj)
 if obj:IsA("BasePart") then
  local cam = getCamera()
  registerPart(obj, cam)
 end
end)

globalConnections.workspaceRemoving = Workspace.DescendantRemoving:Connect(function(obj)
 if pendingHide[obj] or pendingRestore[obj] then
  return
 end
 if obj:IsA("BasePart") then
  cleanupTracking(obj)
 end
end)

globalConnections.hiddenAdded = hiddenFolder.DescendantAdded:Connect(function(obj)
 if obj:IsA("BasePart") then
  addHiddenPart(obj)
 end
end)

globalConnections.hiddenRemoving = hiddenFolder.DescendantRemoving:Connect(function(obj)
 removeHiddenPart(obj)
 if restoringNow[obj] then
  restoringNow[obj] = nil
  return
 end
 if obj:IsA("BasePart") then
  cleanupTracking(obj)
 end
end)

do
 local hiddenDescendants = hiddenFolder:GetDescendants()
 local hiddenDescCount = #hiddenDescendants
 for i = 1, hiddenDescCount do
  local desc = hiddenDescendants[i]
  if desc:IsA("BasePart") then
   addHiddenPart(desc)
  end
 end
end

local function cleanup()
 state.running = false
	
 for key, conn in globalConnections do
  pcall(function()
   if conn and typeof(conn) == "RBXScriptConnection" then
    conn:Disconnect()
   end
  end)
 end
	
 for plr, conns in playerConnections do
  disconnectPlayerConnections(plr)
 end
	
 for part, conns in partConnections do
  for k, conn in conns do
   pcall(function()
    if conn and typeof(conn) == "RBXScriptConnection" then
     conn:Disconnect()
    end
   end)
  end
 end
	
 clearTable(allParts)
 clearTable(originalParents)
 clearTable(pendingHide)
 clearTable(pendingRestore)
 clearTable(hiddenParts)
 clearTable(hiddenLookup)
 clearTable(playerCharacters)
 clearTable(floorCache)
 clearTable(effectCache)
 clearTable(extentCache)
 clearTable(skipPartCache)
end

if script.Parent then
 script.AncestryChanged:Connect(function()
  if not script.Parent then
   cleanup()
  end
 end)
end

task.spawn(rebuildPartList)

task.spawn(function()
 while state.running do
  local success = pcall(adjustParameters)
  if not success then
   task.wait(config.adjustment_interval)
  else
   task.wait(config.adjustment_interval)
  end
 end
end)

task.spawn(function()
 local batch = config.hide_scan_batch
 local cleanupBuffer = table.create(batch)
	
 while state.running do
  task.wait(config.scan_interval)
  
  if not refreshCharacterReference() then
   hideBufferVersion += 1
   clearTable(partsToHide)
   partsToHideLen = 0
   hideIndex = 1
   activeHideVersion = hideBufferVersion
   continue
  end

  hideBufferVersion += 1
  local currentVersion = hideBufferVersion
  clearTable(partsToHide)
  partsToHideLen = 0
  hideIndex = 1
  
  local cleanupLen = 0
  clearTable(cleanupBuffer)

  local root = humanoidRootPart
  if not root then
   activeHideVersion = currentVersion
   continue
  end
  
  local success, playerPos = pcall(function()
   return root.Position
  end)
  
  if not success then
   activeHideVersion = currentVersion
   continue
  end
  
  local px, py, pz = playerPos.X, playerPos.Y, playerPos.Z

  local cam = getCamera()
  local cleanupRadius = state.cleanup_distance
  local safeZoneRadius = state.safe_zone

  local processed = 0
  local snapshotParts = {}
  local snapshotCount = 0
  
  for part in allParts do
   snapshotCount += 1
   snapshotParts[snapshotCount] = part
  end
  
  local snapshotIndex = 1
  
  while processed < batch and snapshotIndex <= snapshotCount do
   local part = snapshotParts[snapshotIndex]
   snapshotIndex += 1
   processed += 1

   if not part or not part.Parent then
    cleanupLen += 1
    cleanupBuffer[cleanupLen] = part
    continue
   end

   local partParent = part.Parent
   if not partParent or partParent == hiddenFolder then
    cleanupLen += 1
    cleanupBuffer[cleanupLen] = part
    continue
   end
   
   if isLargeFloor(part) or shouldSkipPart(part, cam) then
    continue
   end

   local posSuccess, objPos = pcall(function()
    return part.Position
   end)
   
   if not posSuccess then
    continue
   end
   
   local dx = objPos.X - px
   local dy = objPos.Y - py
   local dz = objPos.Z - pz
   
   local horizontalSq = dx * dx + dz * dz
   local dySq = dy * dy
   local distSq = horizontalSq + dySq

   local boundingRadius = getBoundingRadius(part)
   local removalLimit = cleanupRadius + boundingRadius
   local removalLimitSq = removalLimit * removalLimit
   
   if distSq <= removalLimitSq then
    continue
   end

   local shouldHide = true

   if not superExtremeMode then
    local expandedSafe = safeZoneRadius + boundingRadius
    local expandedSafeSq = expandedSafe * expandedSafe
    
    if horizontalSq <= expandedSafeSq then
     shouldHide = false
    else
     local verticalLimit = config.vertical_check_threshold + boundingRadius
     local verticalLimitSq = verticalLimit * verticalLimit
     
     if dySq < verticalLimitSq then
      if horizontalSq <= expandedSafeSq * config.safe_zone_multiplier then
       shouldHide = false
      end
     end
    end
   else
    local tightRadius = config.tight_radius_base + boundingRadius
    local tightRadiusSq = tightRadius * tightRadius
    if horizontalSq < tightRadiusSq then
     shouldHide = false
    end
   end

   if shouldHide then
    partsToHideLen += 1
    partsToHide[partsToHideLen] = part
   end
  end
  
  for i = 1, cleanupLen do
   local partToClean = cleanupBuffer[i]
   if partToClean then
    cleanupTracking(partToClean)
   end
  end

  activeHideVersion = currentVersion
 end
end)

task.spawn(function()
 local batch = config.restore_scan_batch
 local invalidPartsBuffer = table.create(batch)
	
 while state.running do
  task.wait(config.scan_interval + 0.15)
  
  if stabilitySystem.restoration_speed == 0 or not refreshCharacterReference() then
   restoreBufferVersion += 1
   clearTable(partsToRestore)
   partsToRestoreLen = 0
   restoreIndex = 1
   activeRestoreVersion = restoreBufferVersion
   continue
  end

  restoreBufferVersion += 1
  local currentVersion = restoreBufferVersion
  clearTable(partsToRestore)
  partsToRestoreLen = 0
  restoreIndex = 1
  
  local invalidPartsLen = 0
  clearTable(invalidPartsBuffer)

  local root = humanoidRootPart
  if not root then
   activeRestoreVersion = currentVersion
   continue
  end
  
  local success, playerPos = pcall(function()
   return root.Position
  end)
  
  if not success then
   activeRestoreVersion = currentVersion
   continue
  end
  
  local px, py, pz = playerPos.X, playerPos.Y, playerPos.Z
  local restoreRadius = state.cleanup_distance * config.restore_multiplier

  if hiddenCount > 0 then
   local processed = 0
   local scanned = 0
   local maxScans = hiddenCount
   local startingCount = hiddenCount
   
   while processed < batch and scanned < maxScans and hiddenCount > 0 do
    if hiddenCount == 0 then
     break
    end
    
    if hiddenScanIndex < 1 or hiddenScanIndex > hiddenCount then
     hiddenScanIndex = 1
    end
    
    local obj = hiddenParts[hiddenScanIndex]
    hiddenScanIndex += 1
    scanned += 1

    if not obj or obj.Parent ~= hiddenFolder or pendingHide[obj] or pendingRestore[obj] then
     if obj then
      invalidPartsLen += 1
      invalidPartsBuffer[invalidPartsLen] = obj
     end
     continue
    end
    
    processed += 1

    local posSuccess, objPos = pcall(function()
     return obj.Position
    end)
    
    if not posSuccess then
     continue
    end
    
    local dx = objPos.X - px
    local dy = objPos.Y - py
    local dz = objPos.Z - pz
    
    local horizontalSq = dx * dx + dz * dz
    local dySq = dy * dy
    local distSq = horizontalSq + dySq

    local boundingRadius = getBoundingRadius(obj)
    local limit = restoreRadius + boundingRadius
    local limitSq = limit * limit
    
    if distSq <= limitSq then
     partsToRestoreLen += 1
     partsToRestore[partsToRestoreLen] = obj
    end
   end
   
   for i = 1, invalidPartsLen do
    removeHiddenPart(invalidPartsBuffer[i])
   end
  end

  activeRestoreVersion = currentVersion
 end
end)

globalConnections.heartbeat = RunService.Heartbeat:Connect(function(deltaTime)
 local oldFPS = fpsSamples[fpsIndex]
 local newFPS = fastClamp(1 / fastMax(deltaTime, 0.001), 10, 144)
 fpsSamples[fpsIndex] = newFPS
 fpsSum = fpsSum - oldFPS + newFPS
 fpsIndex = fpsIndex % config.fps_sample_count + 1

 local now = osClock()
 local timeSinceLastOp = now - state.last_parent_operation
	
 if timeSinceLastOp < config.defer_cooldown then
  return
 end

 local baseObjectsPerFrame = state.objects_per_frame
 local amplified = superExtremeMode and fastFloor(baseObjectsPerFrame * 2)
  or extremeMode and fastFloor(baseObjectsPerFrame * 1.5)
  or aggressiveMode and fastFloor(baseObjectsPerFrame * 1.2)
  or baseObjectsPerFrame
	
 local effectivePerFrame = fastMin(amplified, config.max_per_frame)
 local cam = getCamera()

 local hideCountSnapshot = partsToHideLen
 local hideVersionSnapshot = activeHideVersion
 local processedHide = 0

 while processedHide < effectivePerFrame and hideIndex <= hideCountSnapshot do
  local obj = partsToHide[hideIndex]
  
  if obj and obj.Parent and obj.Parent ~= hiddenFolder
   and not shouldSkipPart(obj, cam) and not pendingHide[obj] then

   pendingHide[obj] = true
   
   task.defer(function()
    pcall(function()
     if not obj or not obj.Parent or obj.Parent == hiddenFolder then
      pendingHide[obj] = nil
      return
     end
     
     if not effectCache[obj] then
      scanEffectsImmediate(obj)
     end
     disableEffects(obj)
     if originalParents[obj] == nil then
      originalParents[obj] = obj.Parent
     end
     obj.Parent = hiddenFolder
     
     pendingHide[obj] = nil
     deregisterPart(obj)
    end)
   end)
   
   state.last_parent_operation = now
  end
  
  partsToHide[hideIndex] = nil
  hideIndex += 1
  processedHide += 1
  
  if processedHide % config.parent_operations_per_defer == 0 then
   break
  end
 end

 if hideIndex > hideCountSnapshot then
  hideIndex = 1
  if activeHideVersion == hideVersionSnapshot then
   partsToHideLen = 0
   clearTable(partsToHide)
  end
 end

 if stabilitySystem.restoration_speed > 0 then
  local restoreCountSnapshot = partsToRestoreLen
  
  if restoreCountSnapshot > 0 then
   local restoreVersionSnapshot = activeRestoreVersion
   local adjustedPerFrame = fastFloor(state.objects_per_frame * stabilitySystem.restoration_speed * 0.5)
   local minRestore = fastMax(config.min_per_frame, adjustedPerFrame)
   local processedRestore = 0

   while processedRestore < minRestore and restoreIndex <= restoreCountSnapshot do
    local obj = partsToRestore[restoreIndex]
    
    if obj and obj.Parent == hiddenFolder and not pendingRestore[obj] then
     local parent = originalParents[obj]
     
     if parent and parent.Parent then
      pendingRestore[obj] = true
      restoringNow[obj] = true
      
      local objToRestore = obj
      local parentToRestore = parent
      
      task.defer(function()
       pcall(function()
        if not objToRestore or objToRestore.Parent ~= hiddenFolder then
         pendingRestore[objToRestore] = nil
         restoringNow[objToRestore] = nil
         return
        end
        
        objToRestore.Parent = parentToRestore
        enableEffects(objToRestore)
        
        pendingRestore[objToRestore] = nil
        restoringNow[objToRestore] = nil
        originalParents[objToRestore] = nil
        
        registerPart(objToRestore, cam)
       end)
      end)
      
      state.last_parent_operation = now
     else
      originalParents[obj] = nil
      cleanupTracking(obj)
     end
    end
    
    partsToRestore[restoreIndex] = nil
    restoreIndex += 1
    processedRestore += 1
    
    if processedRestore % config.parent_operations_per_defer == 0 then
     break
    end
   end

   if restoreIndex > restoreCountSnapshot then
    restoreIndex = 1
    if activeRestoreVersion == restoreVersionSnapshot then
     partsToRestoreLen = 0
     clearTable(partsToRestore)
    end
   end
  end
 end
end)
