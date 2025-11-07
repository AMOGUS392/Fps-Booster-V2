local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local hrp = character:WaitForChild("HumanoidRootPart", 10)

local hiddenFolder = ReplicatedStorage:FindFirstChild("HiddenObjects_LOD") 
	or Instance.new("Folder", ReplicatedStorage)
hiddenFolder.Name = "HiddenObjects_LOD"

local parts = {}
local partsArray = {}
local partsCount = 0

local hiddenParts = {}
local hiddenArray = {}
local hiddenCount = 0

local playerChars = {}
local connections = {}
local pendingHide = {}
local pendingRestore = {}

local toHide = {}
local toRestore = {}
local hideLen = 0
local restoreLen = 0

local camera = Workspace.CurrentCamera
local lastPlayerPos = hrp and hrp.Position or Vector3.zero
local lastCameraPos = camera and camera.CFrame.Position or Vector3.zero

local state = {
	running = true,
	lastScan = 0
}

local function shouldSkip(part)
	if not part:IsA("BasePart") then return true end
	if part == Workspace.Terrain or part:IsDescendantOf(Workspace.Terrain) then return true end
	if part:IsDescendantOf(hiddenFolder) then return true end
	if camera and part:IsDescendantOf(camera) then return true end
	if part:GetAttribute("_PooledObject") then return true end
	
	local p = part.Parent
	while p and p ~= Workspace do
		if playerChars[p] then return true end
		p = p.Parent
	end
	
	return false
end

local function isFloor(part)
	local s = part.Size
	return s.Y < 8 and (s.X * s.Z) > 500
end

local function getRadius(part)
	local s = part.Size
	return math.sqrt(s.X * s.X + s.Y * s.Y + s.Z * s.Z) * 0.5
end

local effectTypes = {
	ParticleEmitter = true,
	Trail = true,
	Beam = true,
	PointLight = true,
	SpotLight = true,
	SurfaceLight = true,
	Fire = true,
	Smoke = true,
	Sparkles = true
}

local function disableEffects(part)
	local descendants = part:GetDescendants()
	for i = 1, #descendants do
		local child = descendants[i]
		local className = child.ClassName
		if effectTypes[className] then
			if child.Enabled then
				if className == "ParticleEmitter" or className == "Trail" then
					child:Clear()
				end
				child.Enabled = false
				child:SetAttribute("_WasEnabled", true)
			end
		end
	end
end

local function enableEffects(part)
	local descendants = part:GetDescendants()
	for i = 1, #descendants do
		local child = descendants[i]
		if child:GetAttribute("_WasEnabled") then
			if effectTypes[child.ClassName] then
				child.Enabled = true
				child:SetAttribute("_WasEnabled", nil)
			end
		end
	end
end

local function addToParts(part)
	if not parts[part] then
		partsCount = partsCount + 1
		partsArray[partsCount] = part
		parts[part] = {
			parent = part.Parent,
			hidden = false,
			radius = getRadius(part),
			index = partsCount
		}
	end
end

local function removeFromParts(part)
	local data = parts[part]
	if data then
		local idx = data.index
		local lastPart = partsArray[partsCount]
		
		if idx ~= partsCount then
			partsArray[idx] = lastPart
			parts[lastPart].index = idx
		end
		
		partsArray[partsCount] = nil
		parts[part] = nil
		partsCount = partsCount - 1
	end
end

local function addToHidden(part)
	if not hiddenParts[part] then
		hiddenCount = hiddenCount + 1
		hiddenArray[hiddenCount] = part
		hiddenParts[part] = hiddenCount
	end
end

local function removeFromHidden(part)
	local idx = hiddenParts[part]
	if idx then
		local lastPart = hiddenArray[hiddenCount]
		
		if idx ~= hiddenCount then
			hiddenArray[idx] = lastPart
			hiddenParts[lastPart] = idx
		end
		
		hiddenArray[hiddenCount] = nil
		hiddenParts[part] = nil
		hiddenCount = hiddenCount - 1
	end
end

local function registerPart(part)
	if shouldSkip(part) or parts[part] then return end
	addToParts(part)
end

local function cleanupPart(part)
	if pendingHide[part] or pendingRestore[part] then return end
	removeFromParts(part)
	removeFromHidden(part)
end

local function addCharacter(char)
	if not char then return end
	playerChars[char] = true
	local descendants = char:GetDescendants()
	for i = 1, #descendants do
		local part = descendants[i]
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
		for i = 1, #conns do
			conns[i]:Disconnect()
		end
		connections[plr] = nil
	end
end

local players = Players:GetPlayers()
for i = 1, #players do
	setupPlayer(players[i])
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

local function scanWorkspace()
	local descendants = Workspace:GetDescendants()
	for i = 1, #descendants do
		registerPart(descendants[i])
	end
end

connections.descAdded = Workspace.DescendantAdded:Connect(registerPart)
connections.descRemoving = Workspace.DescendantRemoving:Connect(cleanupPart)

local function scanToHide()
	if not hrp then return end
	
	hideLen = 0
	
	local pos = hrp.Position
	local px, py, pz = pos.X, pos.Y, pos.Z
	local hideDistSq = 280 * 280
	local safeRadiusSq = 75 * 75
	
	for i = 1, partsCount do
		local part = partsArray[i]
		if part and part.Parent then
			local data = parts[part]
			if data and not data.hidden and part.Parent ~= hiddenFolder and not pendingHide[part] then
				if not isFloor(part) then
					local partPos = part.Position
					local dx = partPos.X - px
					local dy = partPos.Y - py
					local dz = partPos.Z - pz
					local distSq = dx * dx + dy * dy + dz * dz
					
					local limit = 280 + data.radius
					
					if distSq > limit * limit then
						local horizontalSq = dx * dx + dz * dz
						if horizontalSq > safeRadiusSq then
							hideLen = hideLen + 1
							toHide[hideLen] = part
						end
					end
				end
			end
		end
	end
end

local function scanToRestore()
	if not hrp then return end
	
	restoreLen = 0
	
	local pos = hrp.Position
	local px, py, pz = pos.X, pos.Y, pos.Z
	
	for i = 1, hiddenCount do
		local part = hiddenArray[i]
		if part and part.Parent == hiddenFolder and not pendingRestore[part] then
			local data = parts[part]
			if data and data.parent and data.parent.Parent then
				local partPos = part.Position
				local dx = partPos.X - px
				local dy = partPos.Y - py
				local dz = partPos.Z - pz
				local distSq = dx * dx + dy * dy + dz * dz
				
				local limit = 220 + data.radius
				if distSq <= limit * limit then
					restoreLen = restoreLen + 1
					toRestore[restoreLen] = part
				end
			end
		end
	end
end

local function processBatch()
	local hideProcessed = 0
	local hideMax = math.min(hideLen, 30)
	
	while hideProcessed < hideMax do
		hideProcessed = hideProcessed + 1
		local part = toHide[hideProcessed]
		
		if part and part.Parent and part.Parent ~= hiddenFolder and not pendingHide[part] then
			local data = parts[part]
			if data then
				pendingHide[part] = true
				disableEffects(part)
				part.Parent = hiddenFolder
				data.hidden = true
				addToHidden(part)
				pendingHide[part] = nil
			end
		end
	end
	
	local restoreProcessed = 0
	local restoreMax = math.min(restoreLen, 40)
	
	while restoreProcessed < restoreMax do
		restoreProcessed = restoreProcessed + 1
		local part = toRestore[restoreProcessed]
		
		if part and part.Parent == hiddenFolder and not pendingRestore[part] then
			local data = parts[part]
			if data and data.parent and data.parent.Parent then
				pendingRestore[part] = true
				part.Parent = data.parent
				enableEffects(part)
				data.hidden = false
				removeFromHidden(part)
				pendingRestore[part] = nil
			else
				removeFromParts(part)
				removeFromHidden(part)
			end
		end
	end
end

local function cleanup()
	state.running = false
	for k, conn in pairs(connections) do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif type(conn) == "table" then
			for i = 1, #conn do
				conn[i]:Disconnect()
			end
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

task.spawn(scanWorkspace)

connections.heartbeat = RunService.Heartbeat:Connect(function()
	if not hrp then return end
	
	local currentPlayerPos = hrp.Position
	local playerMoved = (currentPlayerPos - lastPlayerPos).Magnitude > 8
	
	local currentCameraPos = camera.CFrame.Position
	local cameraMoved = (currentCameraPos - lastCameraPos).Magnitude > 12
	
	local now = os.clock()
	local shouldScan = (playerMoved or cameraMoved) and (now - state.lastScan) > 0.1
	
	if shouldScan then
		lastPlayerPos = currentPlayerPos
		lastCameraPos = currentCameraPos
		state.lastScan = now
		
		scanToHide()
		scanToRestore()
	end
	
	processBatch()
end)
