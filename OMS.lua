local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid_root_part = character:WaitForChild("HumanoidRootPart")

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

local stability_system = {
    last_aggressive_trigger = 0,
    restoration_speed = 1.0
}

local hidden_folder = ReplicatedStorage:FindFirstChild("HiddenObjects")
if not hidden_folder then
    hidden_folder = Instance.new("Folder")
    hidden_folder.Name = "HiddenObjects"
    hidden_folder.Parent = ReplicatedStorage
end

local original_parents = {}
local pending_hide = {}
local all_parts = {}
local parts_to_hide = table.create(500)
local parts_to_restore = table.create(500)
local player_characters = {}
local floor_cache = {}
local effect_cache = setmetatable({}, { __mode = "k" })
local extent_cache = {}

local overlap_params = OverlapParams.new()
overlap_params.FilterType = Enum.RaycastFilterType.Exclude
overlap_params.MaxParts = 10000

local fps_samples = table.create(config.fps_sample_count, config.target_fps)
local fps_index = 1
local fps_sum = config.target_fps * config.fps_sample_count

local aggressive_mode = false
local extreme_mode = false
local super_extreme_mode = false

local workspace_terrain = Workspace.Terrain

local function refresh_character_reference()
    if not character or not character.Parent then
        character = player.Character
    end
    if character then
        if not humanoid_root_part or humanoid_root_part.Parent ~= character then
            humanoid_root_part = character:FindFirstChild("HumanoidRootPart")
        end
    else
        humanoid_root_part = nil
    end
    return humanoid_root_part ~= nil
end

local function is_camera_part(part, camera)
    return camera and part:IsDescendantOf(camera)
end

local function is_player_part(part)
    local current = part
    while current and current ~= Workspace do
        if player_characters[current] then
            return true
        end
        current = current.Parent
    end
    return false
end

local function update_player_characters()
    table.clear(player_characters)
    local players_list = Players:GetPlayers()
    local filter = table.create(#players_list)

    for i = 1, #players_list do
        local plr = players_list[i]
        local char = plr.Character
        if char then
            player_characters[char] = true
            filter[#filter + 1] = char

            local descendants = char:GetDescendants()
            for j = 1, #descendants do
                local desc = descendants[j]
                if desc:IsA("BasePart") then
                    all_parts[desc] = nil
                    floor_cache[desc] = nil
                    extent_cache[desc] = nil
                end
            end
        end
    end

    overlap_params.FilterDescendantsInstances = filter
end

player.CharacterAdded:Connect(function(char)
    character = char
    humanoid_root_part = char:WaitForChild("HumanoidRootPart")
    update_player_characters()
end)

Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(update_player_characters)
end)

Players.PlayerRemoving:Connect(update_player_characters)

update_player_characters()
refresh_character_reference()

local function is_large_floor(part)
    local cached = floor_cache[part]
    if cached ~= nil then
        return cached
    end
    local size = part.Size
    local horizontal_area = size.X * size.Z
    local is_floor = size.Y <= config.floor_max_height and horizontal_area >= config.floor_min_area
    floor_cache[part] = is_floor
    return is_floor
end

local function get_bounding_radius(part)
    local cached = extent_cache[part]
    if cached then
        return cached
    end
    local size = part.Size
    local half_x = size.X * 0.5
    local half_y = size.Y * 0.5
    local half_z = size.Z * 0.5
    local radius = math.sqrt(half_x * half_x + half_y * half_y + half_z * half_z)
    extent_cache[part] = radius
    return radius
end

local function scan_effects_immediate(part)
    if effect_cache[part] then
        return
    end
    local effects = nil
    local descendants = part:GetDescendants()
    for i = 1, #descendants do
        local desc = descendants[i]
        local class = desc.ClassName
        if class == "ParticleEmitter" or class == "Smoke" or class == "Fire" or
            class == "Sparkles" or class == "PointLight" or class == "SpotLight" or
            class == "Sound" then
            effects = effects or table.create(4)
            local state = { effect = desc }
            if desc:IsA("Sound") then
                state.was_playing = desc.Playing
            else
                state.was_enabled = desc.Enabled
            end
            effects[#effects + 1] = state
        end
    end
    if effects then
        effect_cache[part] = effects
    end
end

local function disable_effects(part)
    local effects = effect_cache[part]
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

local function enable_effects(part)
    local effects = effect_cache[part]
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
                effect.Enabled = state.was_enabled
            end
        end
    end
end

local function calculate_average_fps()
    local count = #fps_samples
    if count == 0 then
        return 60
    end
    return fps_sum / count
end

local function adjust_parameters()
    local avg_fps = calculate_average_fps()

    local new_cleanup = state.cleanup_distance
    local new_objects = state.objects_per_frame
    local new_safe_zone = state.safe_zone
    local new_restoration_speed = stability_system.restoration_speed

    if avg_fps < config.super_extreme_threshold then
        super_extreme_mode = true
        extreme_mode = true
        aggressive_mode = true
        stability_system.last_aggressive_trigger = os.clock()
        new_restoration_speed = 0

        local fps_ratio = math.max(0, math.min(1, (avg_fps - 5) / 10))
        new_cleanup = config.ultra_extreme_distance_min +
            (config.ultra_extreme_distance_max - config.ultra_extreme_distance_min) * fps_ratio
        new_objects = 150
        new_safe_zone = config.safe_zone
    elseif avg_fps < config.extreme_mode_threshold then
        super_extreme_mode = false
        extreme_mode = true
        aggressive_mode = true
        stability_system.last_aggressive_trigger = os.clock()
        new_restoration_speed = 0

        new_cleanup = 320
        new_objects = 120
        new_safe_zone = config.safe_zone
    elseif avg_fps < config.aggressive_mode_threshold then
        super_extreme_mode = false
        extreme_mode = false
        aggressive_mode = true
        new_restoration_speed = 0.3

        new_cleanup = 360
        new_objects = 90
        new_safe_zone = config.safe_zone
    else
        super_extreme_mode = false
        extreme_mode = false
        aggressive_mode = false

        local time_since = os.clock() - stability_system.last_aggressive_trigger
        new_restoration_speed = time_since > 5 and 1.0 or 0.6

        if avg_fps > config.target_fps + 10 then
            new_cleanup = math.min(config.max_distance, state.cleanup_distance + 35)
            new_objects = math.min(config.max_per_frame, state.objects_per_frame + 12)
            new_safe_zone = math.max(config.safe_zone, state.safe_zone + 5)
        else
            new_cleanup = math.max(state.cleanup_distance - 20, config.cleanup_distance)
            new_objects = math.max(config.min_per_frame, state.objects_per_frame - 6)
            new_safe_zone = math.max(config.safe_zone, state.safe_zone - 2)
        end
    end

    stability_system.restoration_speed = new_restoration_speed
    state.cleanup_distance = math.min(config.max_distance, math.max(config.cleanup_distance, new_cleanup))
    state.objects_per_frame = math.clamp(new_objects, config.min_per_frame, config.max_per_frame)
    state.safe_zone = math.max(config.safe_zone, new_safe_zone)
end

local function rebuild_part_list()
    table.clear(all_parts)
    table.clear(floor_cache)
    table.clear(extent_cache)

    local camera = Workspace.CurrentCamera
    local descendants = Workspace:GetDescendants()
    for i = 1, #descendants do
        local obj = descendants[i]
        if obj:IsA("BasePart")
            and obj ~= workspace_terrain
            and not obj:IsDescendantOf(workspace_terrain)
            and not obj:IsDescendantOf(hidden_folder)
            and not is_player_part(obj)
            and not is_camera_part(obj, camera) then
            all_parts[obj] = true
        end
    end
end

Workspace.DescendantAdded:Connect(function(obj)
    if not obj:IsA("BasePart") then
        return
    end
    if obj == workspace_terrain
        or obj:IsDescendantOf(workspace_terrain)
        or obj:IsDescendantOf(hidden_folder)
        or is_player_part(obj)
        or is_camera_part(obj, Workspace.CurrentCamera) then
        return
    end
    all_parts[obj] = true
    floor_cache[obj] = nil
    extent_cache[obj] = nil
end)

Workspace.DescendantRemoving:Connect(function(obj)
    if pending_hide[obj] then
        return
    end
    if all_parts[obj] then
        all_parts[obj] = nil
        floor_cache[obj] = nil
        extent_cache[obj] = nil
        effect_cache[obj] = nil
        original_parents[obj] = nil
    end
end)

task.spawn(rebuild_part_list)

task.spawn(function()
    while true do
        task.wait(config.adjustment_interval)
        adjust_parameters()
    end
end)

local hide_index = 1
local restore_index = 1

task.spawn(function()
    while true do
        task.wait(config.scan_interval)
        if not refresh_character_reference() then
            continue
        end

        local root = humanoid_root_part
        local player_pos = root.Position
        local px, py, pz = player_pos.X, player_pos.Y, player_pos.Z

        table.clear(parts_to_hide)
        hide_index = 1

        local camera = Workspace.CurrentCamera
        local cleanup_radius = state.cleanup_distance
        local safe_zone_radius = state.safe_zone
        local cleanup_radius_sq = cleanup_radius * cleanup_radius
        local safe_zone_sq = safe_zone_radius * safe_zone_radius

        local hide_count = 0
        for part in pairs(all_parts) do
            local parent = part.Parent
            if not parent or parent == hidden_folder then
                continue
            end
            if is_large_floor(part) or is_player_part(part) or is_camera_part(part, camera) then
                continue
            end

            local obj_pos = part.Position
            local dx = obj_pos.X - px
            local dy = obj_pos.Y - py
            local dz = obj_pos.Z - pz
            local dist_sq = dx * dx + dy * dy + dz * dz

            local bounding_radius = get_bounding_radius(part)
            local removal_limit = cleanup_radius + bounding_radius
            if dist_sq <= removal_limit * removal_limit then
                continue
            end

            local horizontal_sq = dx * dx + dz * dz
            local expanded_safe = safe_zone_radius + bounding_radius
            local expanded_safe_sq = expanded_safe * expanded_safe
            local should_hide = true

            if not super_extreme_mode then
                if horizontal_sq <= expanded_safe_sq then
                    should_hide = false
                elseif dy * dy < (18 + bounding_radius) * (18 + bounding_radius) then
                    if horizontal_sq <= expanded_safe_sq * 1.69 then
                        should_hide = false
                    end
                end
            else
                local tight_radius = 30 + bounding_radius
                if horizontal_sq < tight_radius * tight_radius then
                    should_hide = false
                end
            end

            if should_hide then
                hide_count += 1
                parts_to_hide[hide_count] = part
            end
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(config.scan_interval + 0.15)
        if stability_system.restoration_speed == 0 then
            continue
        end
        if not refresh_character_reference() then
            continue
        end

        local root = humanoid_root_part
        local player_pos = root.Position
        local px, py, pz = player_pos.X, player_pos.Y, player_pos.Z

        table.clear(parts_to_restore)
        restore_index = 1

        local restore_radius = state.cleanup_distance * config.restore_multiplier
        local restore_radius_sq = restore_radius * restore_radius

        local children = hidden_folder:GetChildren()
        local restore_count = 0
        for i = 1, #children do
            local obj = children[i]
            if obj:IsA("BasePart") then
                local obj_pos = obj.Position
                local dx = obj_pos.X - px
                local dy = obj_pos.Y - py
                local dz = obj_pos.Z - pz
                local dist_sq = dx * dx + dy * dy + dz * dz

                local bounding_radius = get_bounding_radius(obj)
                local limit = restore_radius + bounding_radius
                if dist_sq <= limit * limit then
                    restore_count += 1
                    parts_to_restore[restore_count] = obj
                end
            end
        end
    end
end)

RunService.Heartbeat:Connect(function(deltaTime)
    local old_fps = fps_samples[fps_index]
    if deltaTime > 0.001 then
        local new_fps = 1 / deltaTime
        fps_samples[fps_index] = new_fps
        fps_sum = fps_sum - old_fps + new_fps
    else
        fps_sum = fps_sum - old_fps + 60
        fps_samples[fps_index] = 60
    end
    fps_index = fps_index % config.fps_sample_count + 1

    local effective_per_frame
    if super_extreme_mode then
        effective_per_frame = state.objects_per_frame * 3
    elseif extreme_mode then
        effective_per_frame = math.floor(state.objects_per_frame * 2.5)
    elseif aggressive_mode then
        effective_per_frame = math.floor(state.objects_per_frame * 1.35)
    else
        effective_per_frame = state.objects_per_frame
    end

    local parts_to_hide_count = #parts_to_hide
    local processed_hide = 0
    local camera = Workspace.CurrentCamera

    while processed_hide < effective_per_frame and hide_index <= parts_to_hide_count do
        local obj = parts_to_hide[hide_index]
        if obj and obj.Parent and obj.Parent ~= hidden_folder and not is_player_part(obj) and not is_camera_part(obj, camera) then
            pending_hide[obj] = true
            local success = pcall(function()
                scan_effects_immediate(obj)
                disable_effects(obj)
                if original_parents[obj] == nil then
                    original_parents[obj] = obj.Parent
                end
                obj.Parent = hidden_folder
            end)
            pending_hide[obj] = nil

            if not success then
                all_parts[obj] = nil
                original_parents[obj] = nil
                floor_cache[obj] = nil
                extent_cache[obj] = nil
                effect_cache[obj] = nil
            end
        end
        hide_index += 1
        processed_hide += 1
    end

    if hide_index > parts_to_hide_count then
        hide_index = 1
    end

    if stability_system.restoration_speed > 0 then
        local parts_to_restore_count = #parts_to_restore
        if parts_to_restore_count > 0 then
            local adjusted_per_frame = math.floor(state.objects_per_frame * stability_system.restoration_speed)
            local min_restore = math.max(config.min_per_frame, adjusted_per_frame)
            local processed_restore = 0

            while processed_restore < min_restore and restore_index <= parts_to_restore_count do
                local obj = parts_to_restore[restore_index]
                if obj then
                    local parent = original_parents[obj]
                    if parent and parent.Parent then
                        local success = pcall(function()
                            obj.Parent = parent
                            enable_effects(obj)
                        end)
                        if success then
                            original_parents[obj] = nil
                            all_parts[obj] = true
                            floor_cache[obj] = nil
                        else
                            original_parents[obj] = nil
                        end
                    else
                        original_parents[obj] = nil
                    end
                end
                restore_index += 1
                processed_restore += 1
            end

            if restore_index > parts_to_restore_count then
                restore_index = 1
            end
        end
    end
end)
