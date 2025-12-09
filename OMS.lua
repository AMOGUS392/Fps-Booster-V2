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
if not hiddenFolder then
	hiddenFolder = Instance.new("Folder")
	hiddenFolder.Name = "HiddenObjects_LOD"
	hiddenFolder.Parent = ReplicatedStorage
end

for _, child in hiddenFolder:GetChildren() do
	child:Destroy()
end

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
local hideIndex = 1
local restoreIndex = 1

local camera = Workspace.CurrentCamera
local terrain = Workspace.Terrain
local lastPlayerPos = hrp and hrp.Position or Vector3.zero

local lastScan = 0
local deferredCount = 0
local isRunning = true

local sqrt = math.sqrt

local hideThreshold = 300
local restoreThreshold = 200
local minHorizontalDistSq = 5625
local distCheckThresholdSq = 10000
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
	if pendingOps[part] then return true end
	
	if part:IsA("SpawnLocation") or part:IsA("VehicleSeat") or part:IsA("Seat") then return true end
	
	if part.Transparency >= 1 and not part.CanCollide then return true end
	
	local parent = part.Parent
	if not parent then return true end
	if parent == hiddenFolder or parent == camera then return true end
	
	if part:GetAttribute("_PooledObject") then return true end
	
	local checkParent = parent
	local depth = 0
	while checkParent and checkParent ~= Workspace and depth < 20 do
		if playerChars[checkParent] then return true end
		checkParent = checkParent.Parent
		depth = depth + 1
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
	local maxDepth = 50
	local checked = 0
	
	for _, child in part:GetDescendants() do
		checked = checked + 1
		if checked > maxDepth then break end
		
		local className = child.ClassName
		local effectData = effectClassMap[className]
		if effectData and child.Enabled then
			if not effects then effects = table.create(8) end
			count = count + 1
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
			pcall(function()
				if not enable and data.needsClear then
					obj:Clear()
				end
				obj.Enabled = enable
			end)
		end
	end
end

local function addToParts(part)
	if parts[part] then return end
	
	local success, size = pcall(function() return part.Size end)
	if not success or not size then return end
	
	local sx, sy, sz = size.X, size.Y, size.Z
	local radiusSq = getRadiusSq(sx, sy, sz)
	
	partsCount = partsCount + 1
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
	local data = parts[part]
	if data then
		if data.effects then
			table.clear(data.effects)
			data.effects = nil
		end
		parts[part] = nil
		partsCount = partsCount - 1
		if partsCount < 0 then partsCount = 0 end
	end
end

local function registerPart(part)
	if not isRunning then return end
	if shouldSkip(part) or parts[part] then return end
	addToParts(part)
end

local function cleanupPart(part)
	if not isRunning then return end
	if pendingOps[part] then return end
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

if character then
	addCharacter(character)
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
connections.hiddenRemoving = hiddenFolder.DescendantRemoving:Connect(cleanupPart)

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

local function scanNearby()
	if not hrp or not isRunning then return end
	
	if hideIndex <= hideLen or restoreIndex <= restoreLen then
		return
	end
	
	table.clear(toHide)
	table.clear(toRestore)
	hideLen = 0
	restoreLen = 0
	
	local success, pos = pcall(function() return hrp.Position end)
	if not success or not pos then return end
	
	local px, py, pz = pos.X, pos.Y, pos.Z
	
	for part, data in parts do
		if not pendingOps[part] then
			local partParent = part.Parent
			if not partParent then
				continue
			end
			
			local partSuccess, partPos = pcall(function() return part.Position end)
			if not partSuccess or not partPos then
				continue
			end
			
			local dx = partPos.X - px
			local dy = partPos.Y - py
			local dz = partPos.Z - pz
			local distSq = dx * dx + dy * dy + dz * dz
			
			if not data.hidden then
				if not data.isFloor and partParent ~= hiddenFolder then
					local horizontalSq = dx * dx + dz * dz
					if horizontalSq > minHorizontalDistSq then
						local threshold = hideThreshold + data.radiusSqrt
						local thresholdSq = threshold * threshold
						
						if distSq > thresholdSq then
							hideLen = hideLen + 1
							toHide[hideLen] = part
						end
					end
				end
			else
				local originalParent = data.parent
				if originalParent and originalParent.Parent then
					local threshold = restoreThreshold + data.radiusSqrt
					local thresholdSq = threshold * threshold
					
					if distSq <= thresholdSq then
						restoreLen = restoreLen + 1
						toRestore[restoreLen] = part
					end
				else
					pcall(function() part:Destroy() end)
					removeFromParts(part)
					hiddenParts[part] = nil
				end
			end
		end
	end
	
	hideIndex = 1
	restoreIndex = 1
end

local function processBatch()
	if not isRunning or deferredCount >= 16 then return end
	
	local maxHidePerFrame = 6
	local maxRestorePerFrame = 10
	local processed = 0
	
	while processed < maxHidePerFrame and hideIndex <= hideLen and deferredCount < 16 do
		local part = toHide[hideIndex]
		hideIndex = hideIndex + 1
		
		if part and part.Parent and isRunning then
			local parent = part.Parent
			if parent and parent ~= hiddenFolder and not pendingOps[part] then
				local data = parts[part]
				if data then
					if not data.effects then
						data.effects = scanEffects(part)
					end
					
					data.parent = parent
					pendingOps[part] = true
					deferredCount = deferredCount + 1
					
					task.defer(function()
						pcall(function()
							if not isRunning then return end
							
							local currentParent = part.Parent
							if part and currentParent and currentParent ~= hiddenFolder then
								toggleEffects(data.effects, false)
								part.Parent = hiddenFolder
								data.hidden = true
								hiddenParts[part] = true
							end
						end)
						
						pendingOps[part] = nil
						deferredCount = deferredCount - 1
					end)
					
					processed = processed + 1
				end
			end
		end
	end
	
	processed = 0
	
	while processed < maxRestorePerFrame and restoreIndex <= restoreLen and deferredCount < 16 do
		local part = toRestore[restoreIndex]
		restoreIndex = restoreIndex + 1
		
		if part and part.Parent and isRunning then
			local currentParent = part.Parent
			if currentParent == hiddenFolder and not pendingOps[part] then
				local data = parts[part]
				if data then
					local originalParent = data.parent
					if originalParent and originalParent.Parent then
						pendingOps[part] = true
						deferredCount = deferredCount + 1
						
						task.defer(function()
							pcall(function()
								if not isRunning then return end
								
								if part.Parent == hiddenFolder and originalParent.Parent then
									part.Parent = originalParent
									toggleEffects(data.effects, true)
									data.hidden = false
									hiddenParts[part] = nil
								else
									part:Destroy()
									removeFromParts(part)
									hiddenParts[part] = nil
								end
							end)
							
							pendingOps[part] = nil
							deferredCount = deferredCount - 1
						end)
						
						processed = processed + 1
					else
						pcall(function() part:Destroy() end)
						removeFromParts(part)
						hiddenParts[part] = nil
					end
				end
			end
		end
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
	
	for part, data in parts do
		if data.hidden and part.Parent == hiddenFolder and data.parent and data.parent.Parent then
			pcall(function()
				part.Parent = data.parent
				toggleEffects(data.effects, true)
			end)
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
	
	local success, currentPlayerPos = pcall(function() return hrp.Position end)
	if not success or not currentPlayerPos then return end
	
	local dx = currentPlayerPos.X - lastPlayerPos.X
	local dy = currentPlayerPos.Y - lastPlayerPos.Y
	local dz = currentPlayerPos.Z - lastPlayerPos.Z
	local distSq = dx * dx + dy * dy + dz * dz
	
	if distSq > distCheckThresholdSq then
		local now = os.clock()
		if now - lastScan > scanInterval then
			lastPlayerPos = currentPlayerPos
			lastScan = now
			scanNearby()
		end
	end
	
	processBatch()
end)
