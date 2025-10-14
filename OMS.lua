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
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")

local config = {
	target_fps = 50,
	cleanup_distance = 280,
	min_distance = 220,
	max_distance = 450,
	safe_zone = 75,
	objects_per_frame = 60,
	min_per_frame = 30,
	max_per_frame = 150,
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
	floor_max_height = 8
}

local state = {
	cleanup_distance = config.cleanup_distance,
	safe_zone = config.safe_zone,
	objects_per_frame = config.objects_per_frame
}

local stabilitySystem = {
	last_aggressive_trigger = 0,
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
local allParts = {}
local partsToHide = table.create(1024)
local partsToRestore = table.create(512)
local largeFloorWhitelist = {}
local partsToEvict = table.create(128)

local partsToHideLen = 0
local partsToRestoreLen = 0
local partsToEvictLen = 0

local playerCharacters = {}
local floorCache = {}
local effectCache = setmetatable({}, { __mode = "k" })
local extentCache = {}

local fpsSamples = table.create(config.fps_sample_count, config.target_fps)
local fpsIndex = 1
local fpsSum = config.target_fps * config.fps_sample_count

local aggressiveMode = false
local extremeMode = false
local superExtremeMode = false

local workspaceTerrain = Workspace.Terrain

local verticalCheckThreshold = 18
local safeZoneMultiplier = 1.69
local tightRadiusBase = 30
local fpsRatioMin = 5
local fpsRatioRange = 10

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

local function isCameraPart(part, camera)
	return camera and part:IsDescendantOf(camera)
end

local function isPooledObject(part)
	return part:GetAttribute("_PooledObject") == true
end

local function isPlayerPart(part)
	local current = part
	while current and current ~= Workspace do
		if playerCharacters[current] then
			return true
		end
		current = current.Parent
	end
	return false
end

local function cleanupTracking(part)
	allParts[part] = nil
	floorCache[part] = nil
	extentCache[part] = nil
	largeFloorWhitelist[part] = nil
	originalParents[part] = nil
	effectCache[part] = nil
	pendingHide[part] = nil
end

local function trackPart(part, camera)
	if not part:IsA("BasePart") then
		return
	end
	if part == workspaceTerrain
		or part:IsDescendantOf(workspaceTerrain)
		or part:IsDescendantOf(hiddenFolder)
		or isPlayerPart(part)
		or isPooledObject(part)
		or (camera and isCameraPart(part, camera)) then
		return
	end
	allParts[part] = true
	floorCache[part] = nil
	extentCache[part] = nil
end

local function detachCharacterParts(characterModel)
	local descendants = characterModel:GetDescendants()
	for i = 1, #descendants do
		local desc = descendants[i]
		if desc:IsA("BasePart") then
			cleanupTracking(desc)
		end
	end
end

local function updatePlayerCharacters()
	clearTable(playerCharacters)

	local playersList = Players:GetPlayers()
	for i = 1, #playersList do
		local plr = playersList[i]
		local char = plr.Character
		if char then
			playerCharacters[char] = true
			detachCharacterParts(char)
		end
	end
end

player.CharacterAdded:Connect(function(char)
	character = char
	humanoidRootPart = char:WaitForChild("HumanoidRootPart")
	updatePlayerCharacters()
end)

player.CharacterRemoving:Connect(function()
	humanoidRootPart = nil
end)

Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function()
		updatePlayerCharacters()
	end)
	plr.CharacterRemoving:Connect(function(char)
		if char then
			detachCharacterParts(char)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(plr)
	local char = plr.Character
	if char then
		detachCharacterParts(char)
	end
	updatePlayerCharacters()
end)

updatePlayerCharacters()
refreshCharacterReference()

local function isLargeFloor(part)
	local cached = floorCache[part]
	if cached ~= nil then
		return cached
	 end
	local size = part.Size
	if size.Y > config.floor_max_height then
		floorCache[part] = false
		return false
	end
	local horizontalArea = size.X * size.Z
	local isFloor = horizontalArea >= config.floor_min_area
	floorCache[part] = isFloor
	if isFloor then
		largeFloorWhitelist[part] = true
	end
	return isFloor
end

local function getBoundingRadius(part)
	local cached = extentCache[part]
	if cached then
		return cached
	end
	local size = part.Size
	local halfX = size.X * 0.5
	local halfY = size.Y * 0.5
	local halfZ = size.Z * 0.5
	local radius = fastSqrt(halfX * halfX + halfY * halfY + halfZ * halfZ)
	extentCache[part] = radius
	return radius
end

local function scanEffectsImmediate(part)
	if effectCache[part] then
		return
	end

	local effects = nil
	local descendants = part:GetDescendants()
	for i = 1, #descendants do
		local desc = descendants[i]
		local class = desc.ClassName

		if class == "ParticleEmitter"
			or class == "PointLight"
			or class == "SpotLight"
			or class == "Sound"
			or class == "Fire"
			or class == "Smoke"
			or class == "Sparkles" then

			effects = effects or table.create(6)
			local state = {
				effect = desc,
				was_enabled = class ~= "Sound" and desc.Enabled or nil,
				was_playing = class == "Sound" and desc.Playing or nil
			}
			effects[#effects + 1] = state
		end
	end

	if effects then
		effectCache[part] = effects
	end
end

local function disableEffects(part)
	local effects = effectCache[part]
	if not effects then
		return
	end
	for i = 1, #effects do
		local state = effects[i]
		local effect = state.effect
		if effect and effect.Parent then
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
		end
	end
end

local function enableEffects(part)
	local effects = effectCache[part]
	if not effects then
		return
	end
	for i = 1, #effects do
		local state = effects[i]
		local effect = state.effect
		if effect and effect.Parent then
			if effect:IsA("Sound") then
				if state.was_playing then
					effect:Play()
				end
			else
				if state.was_enabled ~= nil then
					effect.Enabled = state.was_enabled
				end
			end
		end
	end
end

local function calculateAverageFPS()
	local count = #fpsSamples
	return count > 0 and (fpsSum / count) or 60
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

		local fpsRatio = fastClamp((avgFPS - fpsRatioMin) / fpsRatioRange, 0, 1)
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
		newObjects = fastMin(config.max_per_frame, 120)
		newSafeZone = config.safe_zone
	elseif avgFPS < config.aggressive_mode_threshold then
		superExtremeMode = false
		extremeMode = false
		aggressiveMode = true
		newRestorationSpeed = 0.3

		newCleanup = 360
		newObjects = 90
		newSafeZone = config.safe_zone
	else
		superExtremeMode = false
		extremeMode = false
		aggressiveMode = false

		local timeSince = osClock() - stabilitySystem.last_aggressive_trigger
		newRestorationSpeed = timeSince > 5 and 1.0 or 0.6

		if avgFPS > config.target_fps + 10 then
			newCleanup = fastMin(config.max_distance, state.cleanup_distance + 35)
			newObjects = fastMin(config.max_per_frame, state.objects_per_frame + 12)
			newSafeZone = fastMax(config.safe_zone, state.safe_zone + 5)
		else
			newCleanup = fastMax(config.cleanup_distance, state.cleanup_distance - 20)
			newObjects = fastMax(config.min_per_frame, state.objects_per_frame - 6)
			newSafeZone = fastMax(config.safe_zone, state.safe_zone - 2)
		end
	end

	stabilitySystem.restoration_speed = newRestorationSpeed
	state.cleanup_distance = fastClamp(newCleanup, config.cleanup_distance, config.max_distance)
	state.objects_per_frame = fastClamp(newObjects, config.min_per_frame, config.max_per_frame)
	state.safe_zone = fastMax(config.safe_zone, newSafeZone)
end

local function rebuildPartList()
	clearTable(allParts)
	clearTable(floorCache)
	clearTable(extentCache)
	clearTable(largeFloorWhitelist)

	local camera = Workspace.CurrentCamera
	local descendants = Workspace:GetDescendants()
	for i = 1, #descendants do
		trackPart(descendants[i], camera)
	end
end

Workspace.DescendantAdded:Connect(function(obj)
	if not obj:IsA("BasePart") then
		return
	end
	local camera = Workspace.CurrentCamera
	if obj == workspaceTerrain
		or obj:IsDescendantOf(workspaceTerrain)
		or obj:IsDescendantOf(hiddenFolder)
		or isPlayerPart(obj)
		or isPooledObject(obj)
		or (camera and isCameraPart(obj, camera)) then
		return
	end
	allParts[obj] = true
	floorCache[obj] = nil
	extentCache[obj] = nil
end)

Workspace.DescendantRemoving:Connect(function(obj)
	if pendingHide[obj] then
		return
	end
	if allParts[obj] or largeFloorWhitelist[obj] or effectCache[obj] then
		cleanupTracking(obj)
	end
end)

hiddenFolder.DescendantRemoving:Connect(function(obj)
	cleanupTracking(obj)
end)

task.spawn(rebuildPartList)

task.spawn(function()
	while task.wait(config.adjustment_interval) do
		adjustParameters()
	end
end)

local hideIndex = 1
local restoreIndex = 1

task.spawn(function()
	while task.wait(config.scan_interval) do
		if not refreshCharacterReference() then
			for i = 1, partsToHideLen do
				partsToHide[i] = nil
			end
			partsToHideLen = 0
			hideIndex = 1
			continue
		end

		local root = humanoidRootPart
		local playerPos = root.Position
		local px, py, pz = playerPos.X, playerPos.Y, playerPos.Z

		for i = 1, partsToHideLen do
			partsToHide[i] = nil
		end
		partsToHideLen = 0
		hideIndex = 1

		local camera = Workspace.CurrentCamera
		local cleanupRadius = state.cleanup_distance
		local safeZoneRadius = state.safe_zone

		partsToEvictLen = 0

		for part in pairs(allParts) do
			if not part or not part.Parent or part.Parent == hiddenFolder then
				partsToEvictLen += 1
				partsToEvict[partsToEvictLen] = part
				continue
			end
			if largeFloorWhitelist[part] or isLargeFloor(part) then
				continue
			end
			if isPooledObject(part)
				or isPlayerPart(part)
				or (camera and isCameraPart(part, camera)) then
				continue
			end

			local objPos = part.Position
			local dx = objPos.X - px
			local dy = objPos.Y - py
			local dz = objPos.Z - pz
			local distSq = dx * dx + dy * dy + dz * dz

			local boundingRadius = getBoundingRadius(part)
			local removalLimit = cleanupRadius + boundingRadius
			if distSq <= removalLimit * removalLimit then
				continue
			end

			local horizontalSq = dx * dx + dz * dz
			local expandedSafe = safeZoneRadius + boundingRadius
			local expandedSafeSq = expandedSafe * expandedSafe
			local shouldHide = true

			if not superExtremeMode then
				if horizontalSq <= expandedSafeSq then
					shouldHide = false
				else
					local dySq = dy * dy
					local verticalLimit = verticalCheckThreshold + boundingRadius
					if dySq < verticalLimit * verticalLimit then
						if horizontalSq <= expandedSafeSq * safeZoneMultiplier then
							shouldHide = false
						end
					end
				end
			else
				local tightRadius = tightRadiusBase + boundingRadius
				if horizontalSq < tightRadius * tightRadius then
					shouldHide = false
				end
			end

			if shouldHide then
				partsToHideLen += 1
				partsToHide[partsToHideLen] = part
			end
		end

		for i = 1, partsToEvictLen do
			local part = partsToEvict[i]
			allParts[part] = nil
			partsToEvict[i] = nil
		end
	end
end)

task.spawn(function()
	while task.wait(config.scan_interval + 0.15) do
		if stabilitySystem.restoration_speed == 0 or not refreshCharacterReference() then
			for i = 1, partsToRestoreLen do
				partsToRestore[i] = nil
			end
			partsToRestoreLen = 0
			restoreIndex = 1
			continue
		end

		local root = humanoidRootPart
		local playerPos = root.Position
		local px, py, pz = playerPos.X, playerPos.Y, playerPos.Z

		for i = 1, partsToRestoreLen do
			partsToRestore[i] = nil
		end
		partsToRestoreLen = 0
		restoreIndex = 1

		local restoreRadius = state.cleanup_distance * config.restore_multiplier

		local children = hiddenFolder:GetChildren()
		for i = 1, #children do
			local obj = children[i]
			if obj:IsA("BasePart") and not pendingHide[obj] then
				local objPos = obj.Position
				local dx = objPos.X - px
				local dy = objPos.Y - py
				local dz = objPos.Z - pz
				local distSq = dx * dx + dy * dy + dz * dz

				local boundingRadius = getBoundingRadius(obj)
				local limit = restoreRadius + boundingRadius
				if distSq <= limit * limit then
					partsToRestoreLen += 1
					partsToRestore[partsToRestoreLen] = obj
				end
			end
		end
	end
end)

RunService.Heartbeat:Connect(function(deltaTime)
	local oldFPS = fpsSamples[fpsIndex]
	local newFPS = deltaTime > 0.001 and (1 / deltaTime) or 60
	fpsSamples[fpsIndex] = newFPS
	fpsSum = fpsSum - oldFPS + newFPS
	fpsIndex = fpsIndex % config.fps_sample_count + 1

	local baseObjectsPerFrame = state.objects_per_frame
	local effectivePerFrame = superExtremeMode and baseObjectsPerFrame * 3
		or extremeMode and fastFloor(baseObjectsPerFrame * 2.5)
		or aggressiveMode and fastFloor(baseObjectsPerFrame * 1.35)
		or baseObjectsPerFrame

	local camera = Workspace.CurrentCamera

	local processedHide = 0
	while processedHide < effectivePerFrame and hideIndex <= partsToHideLen do
		local obj = partsToHide[hideIndex]
		if obj and obj.Parent and obj.Parent ~= hiddenFolder
			and not isPlayerPart(obj)
			and not (camera and isCameraPart(obj, camera))
			and not isPooledObject(obj) then

			pendingHide[obj] = true
			local success = pcall(function()
				if not effectCache[obj] then
					scanEffectsImmediate(obj)
				end
				disableEffects(obj)
				if originalParents[obj] == nil then
					originalParents[obj] = obj.Parent
				end
				obj.Parent = hiddenFolder
			end)
			pendingHide[obj] = nil

			if success then
				allParts[obj] = nil
			else
				cleanupTracking(obj)
			end
		end
		hideIndex += 1
		processedHide += 1
	end

	if hideIndex > partsToHideLen then
		hideIndex = 1
	end

	if stabilitySystem.restoration_speed > 0 and partsToRestoreLen > 0 then
		local adjustedPerFrame = fastFloor(state.objects_per_frame * stabilitySystem.restoration_speed)
		local minRestore = fastMax(config.min_per_frame, adjustedPerFrame)
		local processedRestore = 0

		while processedRestore < minRestore and restoreIndex <= partsToRestoreLen do
			local obj = partsToRestore[restoreIndex]
			if obj then
				local parent = originalParents[obj]
				if parent and parent.Parent then
					local success = pcall(function()
						obj.Parent = parent
						enableEffects(obj)
					end)
					if success then
						originalParents[obj] = nil
						allParts[obj] = true
						floorCache[obj] = nil
						extentCache[obj] = nil
						largeFloorWhitelist[obj] = nil
					else
						originalParents[obj] = nil
					end
				else
					originalParents[obj] = nil
				end
			end
			restoreIndex += 1
			processedRestore += 1
		end

		if restoreIndex > partsToRestoreLen then
			restoreIndex = 1
		end
	end
end)
