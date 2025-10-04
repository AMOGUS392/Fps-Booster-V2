local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid_root_part = character:WaitForChild("HumanoidRootPart")

player.CharacterAdded:Connect(function(char)
    character = char
    humanoid_root_part = char:WaitForChild("HumanoidRootPart")
end)

local cleanup_distance = 500
local cleanup_interval = 3
local batch_size = 50
local batch_delay = 0.1

local hidden_folder = ReplicatedStorage:FindFirstChild("HiddenObjects") or Instance.new("Folder")
hidden_folder.Name = "HiddenObjects"
hidden_folder.Parent = ReplicatedStorage

local original_parents = {}
local original_effect_states = {}
local cached_parts = {}
local last_cache_update = 0
local cache_interval = 10

local effect_classes = {
    "ParticleEmitter",
    "Smoke",
    "Fire",
    "Sparkles",
    "PointLight",
    "SpotLight",
    "SurfaceLight",
    "Sound"
}

local function disable_effects(part)
    for _, effect_class in pairs(effect_classes) do
        for _, effect in pairs(part:GetDescendants()) do
            if effect:IsA(effect_class) then
                pcall(function()
                    local key = tostring(effect)
                    if original_effect_states[key] == nil then
                        if effect:IsA("Sound") then
                            original_effect_states[key] = {
                                Playing = effect.Playing,
                                Volume = effect.Volume
                            }
                            effect.Volume = 0
                            if effect.Playing then
                                effect:Stop()
                            end
                        else
                            original_effect_states[key] = effect.Enabled
                            effect.Enabled = false
                        end
                    end
                end)
            end
        end
    end
end

local function enable_effects(part)
    for _, effect_class in pairs(effect_classes) do
        for _, effect in pairs(part:GetDescendants()) do
            if effect:IsA(effect_class) then
                pcall(function()
                    local key = tostring(effect)
                    local original_state = original_effect_states[key]
                    
                    if original_state ~= nil then
                        if effect:IsA("Sound") then
                            effect.Volume = original_state.Volume
                            if original_state.Playing then
                                effect:Play()
                            end
                        else
                            effect.Enabled = original_state
                        end
                        original_effect_states[key] = nil
                    end
                end)
            end
        end
    end
end

local function update_cache()
    cached_parts = {}
    for _, obj in pairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") then
            table.insert(cached_parts, obj)
        end
    end
    last_cache_update = tick()
end

update_cache()

Workspace.DescendantAdded:Connect(function(obj)
    if obj:IsA("BasePart") then
        table.insert(cached_parts, obj)
    end
end)

task.spawn(function()
    while task.wait(cleanup_interval) do
        local char = player.Character
        if not char then continue end
        
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end
        
        if tick() - last_cache_update > cache_interval then
            update_cache()
        end
        
        local player_pos = hrp.Position
        local processed = 0
        
        for _, obj in pairs(cached_parts) do
            if obj and obj.Parent and not char:IsAncestorOf(obj) and obj.Parent ~= hidden_folder then
                local success, dist = pcall(function()
                    return (obj.Position - player_pos).Magnitude
                end)
                
                if success and dist > cleanup_distance then
                    pcall(function()
                        disable_effects(obj)
                        if not original_parents[obj] then
                            original_parents[obj] = obj.Parent
                        end
                        obj.Parent = hidden_folder
                    end)
                    
                    processed = processed + 1
                    if processed >= batch_size then
                        task.wait(batch_delay)
                        processed = 0
                    end
                end
            end
        end
    end
end)

task.spawn(function()
    while task.wait(cleanup_interval + 1) do
        local char = player.Character
        if not char then continue end
        
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end
        
        local player_pos = hrp.Position
        local processed = 0
        
        for _, obj in pairs(hidden_folder:GetChildren()) do
            if obj:IsA("BasePart") then
                local success, dist = pcall(function()
                    return (obj.Position - player_pos).Magnitude
                end)
                
                if success and dist <= cleanup_distance * 0.8 then
                    pcall(function()
                        local parent = original_parents[obj]
                        if parent and parent:IsDescendantOf(game) then
                            obj.Parent = parent
                            original_parents[obj] = nil
                            enable_effects(obj)
                        end
                    end)
                    
                    processed = processed + 1
                    if processed >= batch_size then
                        task.wait(batch_delay)
                        processed = 0
                    end
                end
            end
        end
    end
end)
