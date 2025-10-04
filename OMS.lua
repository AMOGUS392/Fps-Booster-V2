local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local math_sqrt = math.sqrt
local math_abs = math.abs
local math_min = math.min
local math_max = math.max
local table_sort = table.sort
local table_clear = table.clear
local table_remove = table.remove
local os_clock = os.clock
local string_lower = string.lower
local string_find = string.find

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid_root_part = character:WaitForChild("HumanoidRootPart")

player.CharacterAdded:Connect(function(char)
    character = char
    humanoid_root_part = char:WaitForChild("HumanoidRootPart")
end)

local config = {
    target_fps = 50,
    cleanup_distance = 280,
    min_distance = 220,
    max_distance = 450,
    safe_zone = 75,
    floor_protection_radius = 50,
    floor_vertical_offset = 3,
    raycast_distance = 50,
    objects_per_frame = 60,
    min_per_frame = 30,
    max_per_frame = 120,
    adjustment_interval = 0.5,
    scan_interval = 0.35,
    fps_sample_count = 22,
    aggressive_mode_threshold = 40,
    extreme_mode_threshold = 20,
    extreme_cleanup_distance = 30,
    vertical_safe_zone = 18,
    restore_multiplier = 0.65
}

local hidden_folder = ReplicatedStorage:FindFirstChild("HiddenObjects") or Instance.new("Folder")
hidden_folder.Name = "HiddenObjects"
hidden_folder.Parent = ReplicatedStorage

local original_parents = {}
local original_effect_states = setmetatable({}, {__mode = "k"})
local cached_parts = table.create(5000)
local parts_to_hide = table.create(500)
local parts_to_restore = table.create(500)
local effect_cache = setmetatable({}, {__mode = "k"})
local protected_parts = {}
local player_characters = {}
local last_cache_update = 0
local last_cache_cleanup = 0
local last_raycast_check = 0
local cache_interval = 9
local cache_cleanup_interval = 30
local raycast_interval = 0.5

local fps_samples = table.create(config.fps_sample_count)
local fps_index = 1
local fps_sum = 0
local current_fps = 60
local last_frame_time = os_clock()
local aggressive_mode = false
local extreme_mode = false

local raycast_params = RaycastParams.new()
raycast_params.FilterType = Enum.RaycastFilterType.Exclude
raycast_params.IgnoreWater = true

local EFFECT_CLASSES = {
    ParticleEmitter = true,
    Smoke = true,
    Fire = true,
    Sparkles = true,
    PointLight = true,
    SpotLight = true,
    SurfaceLight = true,
    Sound = true,
    Trail = true,
    Beam = true
}

local FLOOR_KEYWORDS = {"floor", "ground", "terrain", "base", "platform", "road", "path"}
local workspace_terrain = Workspace.Terrain

local function update_player_characters()
    table_clear(player_characters)
    for _, plr in pairs(Players:GetPlayers()) do
        if plr.Character then
            player_characters[plr.Character] = true
        end
    end
end

Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(update_player_characters)
end)

Players.PlayerRemoving:Connect(update_player_characters)

for _, plr in pairs(Players:GetPlayers()) do
    if plr.Character then
        plr.CharacterAdded:Connect(update_player_characters)
    end
end

update_player_characters()

local function is_terrain_related(obj)
    return obj == workspace_terrain or obj.Parent == workspace_terrain or obj:IsDescendantOf(workspace_terrain)
end

local function is_player_character_part(obj)
    if not obj or not obj.Parent then return false end
    
    local parent = obj.Parent
    if player_characters[parent] then
        return true
    end
    
    local current = obj
    local max_depth = 5
    local depth = 0
    
    while current and depth < max_depth do
        if player_characters[current] then
            return true
        end
        current = current.Parent
        depth = depth + 1
        if current == Workspace then
            break
        end
    end
    
    return false
end

local function get_min_distance_to_part(part, point)
    local pos = part.Position
    local size = part.Size
    
    local to_center = pos - point
    local center_dist_sq = to_center.X * to_center.X + to_center.Y * to_center.Y + to_center.Z * to_center.Z
    local max_extent = math_max(size.X, size.Y, size.Z) * 0.5
    local quick_check = math_sqrt(center_dist_sq) - max_extent
    
    if quick_check > 100 then
        return quick_check
    end
    
    local half_size = size * 0.5
    local min_x = pos.X - half_size.X
    local max_x = pos.X + half_size.X
    local min_y = pos.Y - half_size.Y
    local max_y = pos.Y + half_size.Y
    local min_z = pos.Z - half_size.Z
    local max_z = pos.Z + half_size.Z
    
    local closest_x = math_max(min_x, math_min(point.X, max_x))
    local closest_y = math_max(min_y, math_min(point.Y, max_y))
    local closest_z = math_max(min_z, math_min(point.Z, max_z))
    
    local dx = point.X - closest_x
    local dy = point.Y - closest_y
    local dz = point.Z - closest_z
    
    return math_sqrt(dx * dx + dy * dy + dz * dz)
end

local function update_protected_parts()
    local current_time = os_clock()
    if current_time - last_raycast_check < raycast_interval then
        return
    end
    last_raycast_check = current_time
    
    table_clear(protected_parts)
    
    local char = player.Character
    if not char then return end
    
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    
    raycast_params.FilterDescendantsInstances = {char, hidden_folder}
    
    local origin = hrp.Position
    local direction = Vector3.new(0, -config.raycast_distance, 0)
    
    local raycast_result = Workspace:Raycast(origin, direction, raycast_params)
    
    if raycast_result and raycast_result.Instance then
        local hit_part = raycast_result.Instance
        protected_parts[hit_part] = true
        
        local parent = hit_part.Parent
        if parent and parent:IsA("Model") then
            for _, part in pairs(parent:GetDescendants()) do
                if part:IsA("BasePart") then
                    protected_parts[part] = true
                end
            end
        end
    end
end

local function is_floor_or_terrain(part)
    if not part then return false end
    
    if is_terrain_related(part) then
        return true
    end
    
    local name_lower = string_lower(part.Name)
    for i = 1, #FLOOR_KEYWORDS do
        if string_find(name_lower, FLOOR_KEYWORDS[i], 1, true) then
            return true
        end
    end
    
    return false
end

local function is_floor_under_player(part, player_pos)
    local part_pos = part.Position
    
    if part_pos.Y > player_pos.Y + config.floor_vertical_offset then
        return false
    end
    
    local dx = part_pos.X - player_pos.X
    local dz = part_pos.Z - player_pos.Z
    local horizontal_dist_sq = dx * dx + dz * dz
    
    return horizontal_dist_sq < 2500
end

local function is_in_safe_zone_normal(obj_pos, player_pos)
    local dx = obj_pos.X - player_pos.X
    local dz = obj_pos.Z - player_pos.Z
    local horizontal_dist = math_sqrt(dx * dx + dz * dz)
    
    if horizontal_dist < config.safe_zone then
        return true
    end
    
    local vertical_dist = math_abs(obj_pos.Y - player_pos.Y)
    return vertical_dist < config.vertical_safe_zone and horizontal_dist < config.safe_zone * 1.3
end

local function is_in_safe_zone_extreme(obj_pos, player_pos)
    local dx = obj_pos.X - player_pos.X
    local dz = obj_pos.Z - player_pos.Z
    return dx * dx + dz * dz < 900
end

local function cache_effects(part)
    local effects = effect_cache[part]
    if effects then return effects end
    
    effects = table.create(10)
    local descendants = part:GetDescendants()
    local count = 0
    
    for i = 1, #descendants do
        local desc = descendants[i]
        if EFFECT_CLASSES[desc.ClassName] then
            count = count + 1
            effects[count] = desc
        end
    end
    
    if count > 0 then
        effect_cache[part] = effects
    end
    
    return effects
end

local function disable_effects(part)
    local effects = cache_effects(part)
    
    for i = 1, #effects do
        local effect = effects[i]
        if effect.Parent and not original_effect_states[effect] then
            if effect:IsA("Sound") then
                original_effect_states[effect] = {
                    Playing = effect.Playing,
                    Volume = effect.Volume
                }
                effect.Volume = 0
                if effect.Playing then
                    effect:Stop()
                end
            else
                original_effect_states[effect] = effect.Enabled
                effect.Enabled = false
            end
        end
    end
end

local function enable_effects(part)
    local effects = effect_cache[part]
    if not effects then return end
    
    for i = 1, #effects do
        local effect = effects[i]
        local original_state = original_effect_states[effect]
        
        if original_state and effect.Parent then
            if effect:IsA("Sound") then
                effect.Volume = original_state.Volume
                if original_state.Playing then
                    effect:Play()
                end
            else
                effect.Enabled = original_state
            end
            original_effect_states[effect] = nil
        end
    end
    
    effect_cache[part] = nil
end

local function cleanup_effect_cache()
    local current_time = os_clock()
    if current_time - last_cache_cleanup < cache_cleanup_interval then
        return
    end
    
    for part, _ in pairs(effect_cache) do
        if not part.Parent then
            effect_cache[part] = nil
        end
    end
    
    last_cache_cleanup = current_time
end

local function calculate_average_fps()
    local count = #fps_samples
    if count == 0 then return 60 end
    return fps_sum / count
end

local function adjust_parameters()
    local avg_fps = calculate_average_fps()
    current_fps = avg_fps
    
    if avg_fps < config.extreme_mode_threshold then
        extreme_mode = true
        aggressive_mode = true
        config.cleanup_distance = config.extreme_cleanup_distance
        config.objects_per_frame = math_min(config.max_per_frame, config.objects_per_frame * 2)
        config.safe_zone = 30
    elseif avg_fps < config.aggressive_mode_threshold then
        extreme_mode = false
        aggressive_mode = true
        config.cleanup_distance = math_min(config.max_distance, config.cleanup_distance + 65)
        config.objects_per_frame = math_max(config.min_per_frame, config.objects_per_frame - 15)
        config.safe_zone = math_max(50, config.safe_zone - 3)
    elseif avg_fps < config.target_fps - 5 then
        extreme_mode = false
        aggressive_mode = false
        config.cleanup_distance = math_min(config.max_distance, config.cleanup_distance + 50)
        config.objects_per_frame = math_max(config.min_per_frame, config.objects_per_frame - 10)
    elseif avg_fps > config.target_fps + 10 then
        extreme_mode = false
        aggressive_mode = false
        config.cleanup_distance = math_max(config.min_distance, config.cleanup_distance - 35)
        config.objects_per_frame = math_min(config.max_per_frame, config.objects_per_frame + 12)
        config.safe_zone = math_min(75, config.safe_zone + 2)
    end
    
    local object_count = #cached_parts
    if object_count > 5000 then
        config.objects_per_frame = math_max(config.min_per_frame, config.objects_per_frame - 12)
    elseif object_count > 3500 then
        config.objects_per_frame = math_max(config.min_per_frame, config.objects_per_frame - 5)
    elseif object_count < 1800 then
        config.objects_per_frame = math_min(config.max_per_frame, config.objects_per_frame + 8)
    end
end

local function update_cache()
    table_clear(cached_parts)
    local descendants = Workspace:GetDescendants()
    local count = 0
    
    for i = 1, #descendants do
        local obj = descendants[i]
        if obj:IsA("BasePart") and not is_terrain_related(obj) and not is_player_character_part(obj) then
            count = count + 1
            cached_parts[count] = obj
        end
    end
    
    last_cache_update = os_clock()
end

update_cache()

Workspace.DescendantAdded:Connect(function(obj)
    if obj:IsA("BasePart") and not is_terrain_related(obj) and not is_player_character_part(obj) then
        cached_parts[#cached_parts + 1] = obj
    end
end)

task.spawn(function()
    while true do
        task.wait(config.adjustment_interval)
        adjust_parameters()
        cleanup_effect_cache()
    end
end)

local hide_index = 1
local restore_index = 1

task.spawn(function()
    while true do
        task.wait(config.scan_interval)
        
        local char = player.Character
        if not char then continue end
        
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end
        
        if os_clock() - last_cache_update > cache_interval then
            update_cache()
        end
        
        update_protected_parts()
        
        local player_pos = hrp.Position
        table_clear(parts_to_hide)
        hide_index = 1
        
        local effective_distance
        if extreme_mode then
            effective_distance = config.extreme_cleanup_distance
        elseif aggressive_mode then
            effective_distance = config.cleanup_distance * 0.8
        else
            effective_distance = config.cleanup_distance
        end
        
        local count = 0
        local check_safe_zone = not extreme_mode
        local hidden_check = hidden_folder
        local protected_check = protected_parts
        
        for i = 1, #cached_parts do
            local obj = cached_parts[i]
            if obj and obj.Parent and obj.Parent ~= hidden_check then
                if protected_check[obj] then
                    continue
                end
                
                local dist = get_min_distance_to_part(obj, player_pos)
                
                if dist > effective_distance then
                    local should_hide = true
                    
                    if is_floor_or_terrain(obj) then
                        if is_floor_under_player(obj, player_pos) then
                            should_hide = false
                        end
                    elseif check_safe_zone then
                        if is_in_safe_zone_normal(obj.Position, player_pos) then
                            should_hide = false
                        end
                    else
                        if is_in_safe_zone_extreme(obj.Position, player_pos) then
                            should_hide = false
                        end
                    end
                    
                    if should_hide then
                        count = count + 1
                        parts_to_hide[count] = {obj = obj, dist = dist}
                    end
                end
            end
        end
        
        table_sort(parts_to_hide, function(a, b)
            return a.dist > b.dist
        end)
    end
end)

task.spawn(function()
    while true do
        task.wait(config.scan_interval + 0.15)
        
        local char = player.Character
        if not char then continue end
        
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end
        
        local player_pos = hrp.Position
        table_clear(parts_to_restore)
        restore_index = 1
        
        local children = hidden_folder:GetChildren()
        local count = 0
        local threshold = config.cleanup_distance * config.restore_multiplier
        
        for i = 1, #children do
            local obj = children[i]
            if obj:IsA("BasePart") then
                local dist = get_min_distance_to_part(obj, player_pos)
                
                if dist <= threshold then
                    count = count + 1
                    parts_to_restore[count] = {obj = obj, dist = dist}
                end
            end
        end
        
        table_sort(parts_to_restore, function(a, b)
            return a.dist < b.dist
        end)
    end
end)

RunService.Heartbeat:Connect(function()
    local current_time = os_clock()
    local delta_time = current_time - last_frame_time
    last_frame_time = current_time
    
    if delta_time > 0 then
        local old_fps = fps_samples[fps_index] or 0
        local new_fps = 1 / delta_time
        fps_samples[fps_index] = new_fps
        fps_sum = fps_sum - old_fps + new_fps
        fps_index = fps_index % config.fps_sample_count + 1
    end
    
    local char = player.Character
    local effective_per_frame = extreme_mode and config.objects_per_frame * 2 
        or (aggressive_mode and config.objects_per_frame * 1.35 or config.objects_per_frame)
    local parts_to_hide_count = #parts_to_hide
    local parts_to_restore_count = #parts_to_restore
    local obj_per_frame = config.objects_per_frame
    
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then
            local restore_list = parts_to_restore
            for i = #restore_list, 1, -1 do
                local entry = restore_list[i]
                if entry and entry.obj and protected_parts[entry.obj] then
                    local parent = original_parents[entry.obj]
                    if parent and parent:IsDescendantOf(game) then
                        entry.obj.Parent = parent
                        original_parents[entry.obj] = nil
                        enable_effects(entry.obj)
                    end
                    table_remove(restore_list, i)
                end
            end
        end
    end
    
    local processed_hide = 0
    local hide_list = parts_to_hide
    local protected = protected_parts
    
    while processed_hide < effective_per_frame and hide_index <= parts_to_hide_count do
        local entry = hide_list[hide_index]
        if entry and entry.obj and entry.obj.Parent and not is_terrain_related(entry.obj) 
            and not protected[entry.obj] and not is_player_character_part(entry.obj) then
            disable_effects(entry.obj)
            if not original_parents[entry.obj] then
                original_parents[entry.obj] = entry.obj.Parent
            end
            entry.obj.Parent = hidden_folder
        end
        
        hide_index = hide_index + 1
        processed_hide = processed_hide + 1
    end
    
    if hide_index > parts_to_hide_count then
        hide_index = 1
    end
    
    local processed_restore = 0
    local restore_list = parts_to_restore
    
    while processed_restore < obj_per_frame and restore_index <= parts_to_restore_count do
        local entry = restore_list[restore_index]
        if entry and entry.obj then
            local parent = original_parents[entry.obj]
            if parent and parent:IsDescendantOf(game) then
                entry.obj.Parent = parent
                original_parents[entry.obj] = nil
                enable_effects(entry.obj)
            end
        end
        
        restore_index = restore_index + 1
        processed_restore = processed_restore + 1
    end
    
    if restore_index > parts_to_restore_count then
        restore_index = 1
    end
end)
