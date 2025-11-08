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
local scanIndex = 1

local hiddenParts = {}

local playerChars = {}
local connections = {}
local pendingOps = {}

local toHide = {}
local toRestore = {}
local hideLen = 0
local restoreLen = 0

local camera = Workspace.CurrentCamera
local terrain = Workspace.Terrain
local lastPlayerPos = hrp and hrp.Position or Vector3.zero

local running = true
local lastScan = 0

local sqrt = math.sqrt
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.MaxParts = 1000

local function shouldSkip(part)
	if not part:IsA("BasePart") then return true end
	if part == terrain then return true end
	if rawget(pendingOps, part) then return true end
	
	local parent = part.Parent
	if parent == hiddenFolder then return true end
	if parent == camera then return true end
	
	if part:GetAttribute("_PooledObject") then return true end
	
	local p = parent
	while p and p ~= Workspace do
		if rawget(playerChars, p) then return true end
		p = p.Parent
	end
	
	return false
end

local function isFloor(sx, sy, sz)
	return sy < 8 and sx * sz >= 500
end

local function getRadiusSq(sx, sy, sz)
	local hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
	return hx * hx + hy * hy + hz * hz
end

local function disableEffects(part)
	for _, child in part:GetDescendants() do
		local className = child.ClassName
		if child.Enabled then
			if className == "ParticleEmitter" or className == "Trail" then
				child:Clear()
				child.Enabled = false
				child:SetAttribute("_WasEnabled", true)
			elseif className == "Beam" or className == "PointLight" or className == "SpotLight" 
				or className == "SurfaceLight" or className == "Fire" or className == "Smoke" 
				or className == "Sparkles" then
				child.Enabled = false
				child:SetAttribute("_WasEnabled", true)
			end
		end
	end
end

local function enableEffects(part)
	for _, child in part:GetDescendants() do
		if child:GetAttribute("_WasEnabled") then
			child.Enabled = true
			child:SetAttribute("_WasEnabled", nil)
		end
	end
end

local function addToParts(part)
	if rawget(parts, part) then return end
	
	local size = part.Size
	local sx, sy, sz = size.X, size.Y, size.Z
	
	partsCount += 1
	parts[part] = {
		parent = part.Parent,
		hidden = false,
		radiusSq = getRadiusSq(sx, sy, sz),
		isFloor = isFloor(sx, sy, sz)
	}
end

local function removeFromParts(part)
	if rawget(parts, part) then
		parts[part] = nil
		partsCount -= 1
		if partsCount < 0 then partsCount = 0 end
	end
end

local function addToHidden(part)
	hiddenParts[part] = true
end

local function removeFromHidden(part)
	hiddenParts[part] = nil
end

local function registerPart(part)
	if shouldSkip(part) or rawget(parts, part) then return end
	addToParts(part)
end

local function cleanupPart(part)
	if rawget(pendingOps, part) then return end
	removeFromParts(part)
	removeFromHidden(part)
end

local function addCharacter(char)
	if not char then return end
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
	if plr == player then return end
	
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
	for _, desc in Workspace:GetDescendants() do
		registerPart(desc)
	end
end)

local function scanNearby()
	if not hrp then return end
	
	table.clear(toHide)
	table.clear(toRestore)
	hideLen = 0
	restoreLen = 0
	
	local pos = hrp.Position
	local px, py, pz = pos.X, pos.Y, pos.Z
	
	overlapParams.FilterDescendantsInstances = {character}
	for _, char in playerChars do
		table.insert(overlapParams.FilterDescendantsInstances, char)
	end
	
	local nearbyParts = Workspace:GetPartBoundsInRadius(pos, 320)
	
	for _, part in nearbyParts do
		if part.Parent and part.Parent ~= hiddenFolder then
			local data = rawget(parts, part)
			if data and not data.hidden and not rawget(pendingOps, part) and not data.isFloor then
				local partPos = part.Position
				local dx = partPos.X - px
				local dy = partPos.Y - py
				local dz = partPos.Z - pz
				local distSq = dx * dx + dy * dy + dz * dz
				
				local limit = 280 + sqrt(data.radiusSq)
				
				if distSq > limit * limit then
					local horizontalSq = dx * dx + dz * dz
					if horizontalSq > 5625 then
						hideLen += 1
						toHide[hideLen] = part
					end
				end
			end
		end
	end
	
	for part in hiddenParts do
		if part and part.Parent == hiddenFolder and not rawget(pendingOps, part) then
			local data = rawget(parts, part)
			if data then
				local parent = data.parent
				if parent and parent.Parent then
					local partPos = part.Position
					local dx = partPos.X - px
					local dy = partPos.Y - py
					local dz = partPos.Z - pz
					local distSq = dx * dx + dy * dy + dz * dz
					
					local limit = 220 + sqrt(data.radiusSq)
					
					if distSq <= limit * limit then
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
	local processed = 0
	
	while processed < 5 and hideIndex <= hideLen do
		local part = toHide[hideIndex]
		
		if part then
			local parent = part.Parent
			if parent and parent ~= hiddenFolder and not rawget(pendingOps, part) then
				local data = rawget(parts, part)
				if data then
					pendingOps[part] = true
					
					task.defer(function()
						if part and part.Parent and part.Parent ~= hiddenFolder then
							disableEffects(part)
							part.Parent = hiddenFolder
							data.hidden = true
							addToHidden(part)
						end
						pendingOps[part] = nil
					end)
					
					processed += 1
				end
			end
		end
		
		hideIndex += 1
	end
	
	if hideIndex > hideLen then
		hideIndex = 1
	end
	
	processed = 0
	
	while processed < 8 and restoreIndex <= restoreLen do
		local part = toRestore[restoreIndex]
		
		if part and part.Parent == hiddenFolder and not rawget(pendingOps, part) then
			local data = rawget(parts, part)
			if data then
				local parent = data.parent
				if parent and parent.Parent then
					pendingOps[part] = true
					
					task.defer(function()
						if part and part.Parent == hiddenFolder and parent.Parent then
							part.Parent = parent
							enableEffects(part)
							data.hidden = false
							removeFromHidden(part)
						else
							removeFromParts(part)
							removeFromHidden(part)
						end
						pendingOps[part] = nil
					end)
					
					processed += 1
				else
					removeFromParts(part)
					removeFromHidden(part)
				end
			end
		end
		
		restoreIndex += 1
	end
	
	if restoreIndex > restoreLen then
		restoreIndex = 1
	end
end

local function cleanup()
	running = false
	_G.lod_system_running = nil
	
	for k, conn in pairs(connections) do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif type(conn) == "table" then
			conn[1]:Disconnect()
			conn[2]:Disconnect()
		end
	end
end

if script.Parent then
	script.AncestryChanged:Connect(function()
		if not script.Parent then
			cleanup()
		end
	end)
end

connections.postsim = RunService.PostSimulation:Connect(function()
	if not hrp then return end
	
	local currentPlayerPos = hrp.Position
	local dx = currentPlayerPos.X - lastPlayerPos.X
	local dy = currentPlayerPos.Y - lastPlayerPos.Y
	local dz = currentPlayerPos.Z - lastPlayerPos.Z
	local distSq = dx * dx + dy * dy + dz * dz
	
	local now = os.clock()
	local timeDelta = now - lastScan
	
	if distSq > 100 and timeDelta > 0.2 then
		lastPlayerPos = currentPlayerPos
		lastScan = now
		hideIndex = 1
		restoreIndex = 1
		scanNearby()
	end
	
	processBatch()
end)
