local RunService = game:GetService("RunService")

if _G.lod_system_running then
	return
end
_G.lod_system_running = true

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local hrp = character:WaitForChild("HumanoidRootPart", 10)

local hiddenFolder = ReplicatedStorage:FindFirstChild("HiddenObjects_LOD") 
	or Instance.new("Folder", ReplicatedStorage)
hiddenFolder.Name = "HiddenObjects_LOD"

local parts = {}
local partsCount = 0
local hiddenParts = {}
local playerChars = {}
local connections = {}
local pendingOps = {}

local toHide = table.create(500)
local toRestore = table.create(500)
local hideLen = 0
local restoreLen = 0

local camera = Workspace.CurrentCamera
local terrain = Workspace.Terrain
local lastPlayerPos = hrp and hrp.Position or Vector3.zero

local lastScan = 0
local deferredCount = 0
local isRunning = true

local sqrt = math.sqrt

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
local filterInstances = table.create(32)

local scanSize = Vector3.new(640, 640, 640)
local hideThreshold = 300
local restoreThreshold = 200
local minHorizontalSq = 5625
local distCheckThreshold = 100
local scanInterval = 0.3

local effectClassMap = {
	ParticleEmitter = {needsClear = true},
	Trail = {needsClear = true},
	Beam = {needsClear = false},
	PointLight = {needsClear = false},
	SpotLight = {needsClear = false},
	SurfaceLight = {needsClear = false},
	Fire = {needsClear = false},
	Smoke = {needsClear = false},
	Sparkles = {needsClear = false}
}

local function shouldSkip(part)
	if not part:IsA("BasePart") then return true end
	if part == terrain then return true end
	if rawget(pendingOps, part) then return true end
	
	local parent = part.Parent
	if not parent then return true end
	if parent == hiddenFolder or parent == camera then return true end
	
	if part:GetAttribute("_PooledObject") then return true end
	
	local p = parent
	while p and p ~= Workspace do
		if rawget(playerChars, p) then return true end
		p = p.Parent
	end
	
	return false
end

local function isFloor(sx, sy, sz)
	return sy < 8 and sx * sz >= 500 and sx * sz < 1000000
end

local function getRadiusSq(sx, sy, sz)
	local hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
	return hx * hx + hy * hy + hz * hz
end

local function scanEffects(part)
	local effects = nil
	local count = 0
	
	for _, child in part:GetDescendants() do
		local className = child.ClassName
		local effectData = effectClassMap[className]
		if effectData and child.Enabled then
			if not effects then effects = table.create(8) end
			count += 1
			effects[count] = {obj = child, needsClear = effectData.needsClear}
		end
	end
	
	return effects
end

local function toggleEffects(effects, enable)
	if not effects then return end
	
	for i = 1, #effects do
		local data = effects[i]
		local obj = data.obj
		if obj and obj.Parent then
			if not enable and data.needsClear then
				obj:Clear()
			end
			obj.Enabled = enable
		end
	end
end

local function addToParts(part)
	if rawget(parts, part) then return end
	
	local size = part.Size
	local sx, sy, sz = size.X, size.Y, size.Z
	local radiusSq = getRadiusSq(sx, sy, sz)
	
	partsCount += 1
	parts[part] = {
		parent = part.Parent,
		hidden = false,
		radiusSq = radiusSq,
		radiusSqrt = sqrt(radiusSq),
		isFloor = isFloor(sx, sy, sz),
		effects = nil
	}
end

local function removeFromParts(part)
	local data = rawget(parts, part)
	if data then
		if data.effects then
			table.clear(data.effects)
			data.effects = nil
		end
		parts[part] = nil
		partsCount -= 1
		if partsCount < 0 then partsCount = 0 end
	end
end

local function registerPart(part)
	if not isRunning then return end
	if shouldSkip(part) or rawget(parts, part) then return end
	addToParts(part)
end

local function cleanupPart(part)
	if not isRunning then return end
	if rawget(pendingOps, part) then return end
	removeFromParts(part)
	hiddenParts[part] = nil
end

local function addCharacter(char)
	if not char or not isRunning then return end
	playerChars[char] = true
	for _, part in char:GetDescendants() do
		if part:IsA("BasePart") then
			cleanupPart(part)
		end
	end
end

local function removeCharacter(char)
	if char then
		playerChars[char] = nil
	end
end

local function setupPlayer(plr)
	if not isRunning or plr == player then return end
	
	if plr.Character then
		addCharacter(plr.Character)
	end
	
	connections[plr] = {
		plr.CharacterAdded:Connect(addCharacter),
		plr.CharacterRemoving:Connect(removeCharacter)
	}
end

local function disconnectPlayer(plr)
	local conns = connections[plr]
	if conns then
		conns[1]:Disconnect()
		conns[2]:Disconnect()
		connections[plr] = nil
	end
end

for _, plr in Players:GetPlayers() do
	setupPlayer(plr)
end

connections.playerAdded = Players.PlayerAdded:Connect(setupPlayer)
connections.playerRemoving = Players.PlayerRemoving:Connect(function(plr)
	removeCharacter(plr.Character)
	disconnectPlayer(plr)
end)

connections.charAdded = player.CharacterAdded:Connect(function(char)
	character = char
	hrp = char:WaitForChild("HumanoidRootPart", 10)
	addCharacter(char)
	if hrp then
		lastPlayerPos = hrp.Position
	end
end)

connections.charRemoving = player.CharacterRemoving:Connect(function()
	hrp = nil
end)

connections.descAdded = Workspace.DescendantAdded:Connect(registerPart)
connections.descRemoving = Workspace.DescendantRemoving:Connect(cleanupPart)

task.spawn(function()
	local descendants = Workspace:GetDescendants()
	local count = #descendants
	local batchSize = 250
	
	for i = 1, count do
		if not isRunning then break end
		registerPart(descendants[i])
		if i % batchSize == 0 then
			task.wait()
		end
	end
end)

local function updateFilterInstances()
	table.clear(filterInstances)
	local idx = 1
	filterInstances[idx] = character
	for char in playerChars do
		idx += 1
		filterInstances[idx] = char
	end
	overlapParams.FilterDescendantsInstances = filterInstances
end

local function scanNearby()
	if not hrp or not isRunning then return end
	
	table.clear(toHide)
	table.clear(toRestore)
	hideLen = 0
	restoreLen = 0
	
	local pos = hrp.Position
	local px, py, pz = pos.X, pos.Y, pos.Z
	
	updateFilterInstances()
	
	local nearbyParts = Workspace:GetPartBoundsInBox(CFrame.new(pos), scanSize, overlapParams)
	local nearbyCount = #nearbyParts
	
	for i = 1, nearbyCount do
		local part = nearbyParts[i]
		local parent = part.Parent
		if parent and parent ~= hiddenFolder then
			local data = rawget(parts, part)
			if data and not data.hidden and not rawget(pendingOps, part) and not data.isFloor then
				local partPos = part.Position
				local dx = partPos.X - px
				local dz = partPos.Z - pz
				local horizontalSq = dx * dx + dz * dz
				
				if horizontalSq > minHorizontalSq then
					local dy = partPos.Y - py
					local distSq = dx * dx + dy * dy + dz * dz
					
					local threshold = hideThreshold + data.radiusSqrt
					local thresholdSq = threshold * threshold
					
					if distSq > thresholdSq then
						hideLen += 1
						toHide[hideLen] = part
					end
				end
			end
		end
	end
	
	for part in hiddenParts do
		if not isRunning then break end
		local parent = part.Parent
		if parent == hiddenFolder and not rawget(pendingOps, part) then
			local data = rawget(parts, part)
			if data then
				local originalParent = data.parent
				if originalParent and originalParent.Parent then
					local partPos = part.Position
					local dx = partPos.X - px
					local dy = partPos.Y - py
					local dz = partPos.Z - pz
					local distSq = dx * dx + dy * dy + dz * dz
					
					local threshold = restoreThreshold + data.radiusSqrt
					local thresholdSq = threshold * threshold
					
					if distSq <= thresholdSq then
						restoreLen += 1
						toRestore[restoreLen] = part
					end
				end
			end
		end
	end
end

local hideIndex = 1
local restoreIndex = 1

local function processBatch()
	if not isRunning or deferredCount >= 16 then return end
	
	local maxHidePerFrame = 6
	local maxRestorePerFrame = 10
	local processed = 0
	
	while processed < maxHidePerFrame and hideIndex <= hideLen and deferredCount < 16 do
		local part = toHide[hideIndex]
		hideIndex += 1
		
		if part and isRunning then
			local parent = part.Parent
			if parent and parent ~= hiddenFolder and not rawget(pendingOps, part) then
				local data = rawget(parts, part)
				if data then
					if not data.effects then
						data.effects = scanEffects(part)
					end
					
					pendingOps[part] = true
					deferredCount += 1
					
					task.defer(function()
						if not isRunning then
							pendingOps[part] = nil
							deferredCount -= 1
							return
						end
						
						local currentParent = part.Parent
						if part and currentParent and currentParent ~= hiddenFolder then
							toggleEffects(data.effects, false)
							part.Parent = hiddenFolder
							data.hidden = true
							hiddenParts[part] = true
						end
						
						pendingOps[part] = nil
						deferredCount -= 1
					end)
					
					processed += 1
				end
			end
		end
	end
	
	if hideIndex > hideLen then
		hideIndex = 1
	end
	
	processed = 0
	
	while processed < maxRestorePerFrame and restoreIndex <= restoreLen and deferredCount < 16 do
		local part = toRestore[restoreIndex]
		restoreIndex += 1
		
		if part and isRunning then
			local currentParent = part.Parent
			if currentParent == hiddenFolder and not rawget(pendingOps, part) then
				local data = rawget(parts, part)
				if data then
					local originalParent = data.parent
					if originalParent and originalParent.Parent then
						pendingOps[part] = true
						deferredCount += 1
						
						task.defer(function()
							if not isRunning then
								pendingOps[part] = nil
								deferredCount -= 1
								return
							end
							
							if part.Parent == hiddenFolder and originalParent.Parent then
								part.Parent = originalParent
								toggleEffects(data.effects, true)
								data.hidden = false
								hiddenParts[part] = nil
							else
								removeFromParts(part)
								hiddenParts[part] = nil
							end
							
							pendingOps[part] = nil
							deferredCount -= 1
						end)
						
						processed += 1
					else
						removeFromParts(part)
						hiddenParts[part] = nil
					end
				end
			end
		end
	end
	
	if restoreIndex > restoreLen then
		restoreIndex = 1
	end
end

local function cleanup()
	isRunning = false
	_G.lod_system_running = nil
	
	task.wait(0.15)
	
	for k, conn in connections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif type(conn) == "table" then
			conn[1]:Disconnect()
			conn[2]:Disconnect()
		end
	end
	
	table.clear(connections)
	table.clear(parts)
	table.clear(hiddenParts)
	table.clear(playerChars)
	table.clear(pendingOps)
	table.clear(toHide)
	table.clear(toRestore)
end

if script.Parent then
	script.AncestryChanged:Connect(function()
		if not script.Parent then
			cleanup()
		end
	end)
end

connections.postsim = RunService.PostSimulation:Connect(function()
	if not hrp or not isRunning then return end
	
	local currentPlayerPos = hrp.Position
	local dx = currentPlayerPos.X - lastPlayerPos.X
	local dy = currentPlayerPos.Y - lastPlayerPos.Y
	local dz = currentPlayerPos.Z - lastPlayerPos.Z
	local distSq = dx * dx + dy * dy + dz * dz
	
	if distSq > distCheckThreshold then
		local now = os.clock()
		if now - lastScan > scanInterval then
			lastPlayerPos = currentPlayerPos
			lastScan = now
			hideIndex = 1
			restoreIndex = 1
			scanNearby()
		end
	end
	
	processBatch()
end)
