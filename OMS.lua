local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local math_sqrt = math.sqrt
local math_abs = math.abs
local math_min = math.min
local math_max = math.max
local math_floor = math.floor
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
    floor_check_distance = 10,
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
    vertical_safe_zone = 18,
    restore_multiplier = 0.75
}

local stability_system = {
    last_aggressive_trigger = 0,
    cooldown_duration = 5,
    slow_restoration_duration = 10,
    fps_trend = table.create(10),
    trend_index = 1,
    trend_window = 10,
    restoration_speed = 1.0,
    min_stable_fps = 40,
    extreme_mode_active = false,
    current_mode = "normal"
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
local last_protection_check = 0
local cache_interval = 9
local cache_cleanup_interval = 30
local protection_check_interval = 0.5

local fps_samples = table.create(config.fps_sample_count)
local fps_index = 1
local fps_sum = 0
local current_fps = 60
local last_frame_time = os_clock()
local aggressive_mode = false
local extreme_mode = false
local super_extreme_mode = false

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
    if current_time - last_protection_check < protection_check_interval then
        return
    end
    last_protection_check = current_time
    
    table_clear(protected_parts)
    
    local char = player.Character
    if not char then return end
    
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    
    local player_pos = hrp.Position
    local check_distance = config.floor_check_distance
    local vertical_check = 50
    
    for i = 1, #cached_parts do
        local obj = cached_parts[i]
        if obj and obj.Parent then
            pcall(function()
                local obj_pos = obj.Position
                
                if obj_pos.Y < player_pos.Y and obj_pos.Y > player_pos.Y - vertical_check then
                    local dx = obj_pos.X - player_pos.X
                    local dz = obj_pos.Z - player_pos.Z
                    local horizontal_dist_sq = dx * dx + dz * dz
                    
                    if horizontal_dist_sq < (check_distance * check_distance) then
                        if is_floor_or_terrain(obj) then
                            protected_parts[obj] = true
                        end
                    end
                end
            end)
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

local function calculate_fps_trend()
    local trend_count = 0
    for i = 1, stability_system.trend_window do
        if stability_system.fps_trend[i] then
            trend_count = trend_count + 1
        end
    end
    
    if trend_count < 5 then return 0 end
    
    local sum = 0
    local valid_diffs = 0
    for i = 1, trend_count - 1 do
        local current_val = stability_system.fps_trend[i]
        local next_val = stability_system.fps_trend[i + 1]
        if current_val and next_val then
            sum = sum + (next_val - current_val)
            valid_diffs = valid_diffs + 1
        end
    end
    
    if valid_diffs == 0 then return 0 end
    return sum / valid_diffs
end

local function update_stability_system(current_fps)
    stability_system.fps_trend[stability_system.trend_index] = current_fps
    stability_system.trend_index = stability_system.trend_index % stability_system.trend_window + 1
    
    local current_time = os_clock()
    local time_since_extreme = current_time - stability_system.last_aggressive_trigger
    
    if current_fps < config.extreme_mode_threshold then
        stability_system.restoration_speed = 0
        return
    end
    
    if time_since_extreme < stability_system.cooldown_duration then
        stability_system.restoration_speed = 0
        return
    end
    
    if time_since_extreme < (stability_system.cooldown_duration + stability_system.slow_restoration_duration) then
        if current_fps < stability_system.min_stable_fps then
            stability_system.extreme_mode_active = true
            stability_system.last_aggressive_trigger = current_time
            stability_system.restoration_speed = 0
        else
            stability_system.restoration_speed = 0.3
        end
        return
    end
    
    local fps_trend = calculate_fps_trend()
    
    if current_fps < stability_system.min_stable_fps then
        stability_system.extreme_mode_active = true
        stability_system.last_aggressive_trigger = current_time
        stability_system.restoration_speed = 0
    elseif fps_trend < -1.5 then
        stability_system.restoration_speed = 0.3
    elseif fps_trend > 0.5 and current_fps > stability_system.min_stable_fps + 5 then
        stability_system.restoration_speed = 1.0
    else
        stability_system.restoration_speed = 0.5
    end
end

local function adjust_parameters()
    local avg_fps = calculate_average_fps()
    current_fps = avg_fps
    
    update_stability_system(avg_fps)
    
    if avg_fps < config.super_extreme_threshold or (stability_system.extreme_mode_active and avg_fps < config.extreme_mode_threshold) then
        super_extreme_mode = true
        extreme_mode = true
        aggressive_mode = true
        stability_system.last_aggressive_trigger = os_clock()
        stability_system.extreme_mode_active = false
        stability_system.current_mode = "ultra_extreme"
        
        local fps_ratio = math_max(0, math_min(1, (avg_fps - 5) / 10))
        config.cleanup_distance = config.ultra_extreme_distance_min + 
            (config.ultra_extreme_distance_max - config.ultra_extreme_distance_min) * fps_ratio
        
        config.objects_per_frame = 150
        config.safe_zone = 30
    elseif avg_fps < config.extreme_mode_threshold or stability_system.extreme_mode_active then
        super_extreme_mode = false
        extreme_mode = true
        aggressive_mode = true
        stability_system.last_aggressive_trigger = os_clock()
        stability_system.extreme_mode_active = false
        stability_system.current_mode = "extreme"
        
        config.cleanup_distance = 280
        config.objects_per_frame = math_min(config.max_per_frame, 120)
        config.safe_zone = 50
    elseif avg_fps < config.aggressive_mode_threshold then
        super_extreme_mode = false
        extreme_mode = false
        aggressive_mode = true
        stability_system.current_mode = "aggressive"
        
        config.cleanup_distance = math_min(config.max_distance, 345)
        config.objects_per_frame = math_max(config.min_per_frame, 45)
        config.safe_zone = 60
    elseif avg_fps < config.target_fps - 5 then
        super_extreme_mode = false
        extreme_mode = false
        aggressive_mode = false
        stability_system.current_mode = "normal"
        
        config.cleanup_distance = math_min(config.max_distance, config.cleanup_distance + 50)
        config.objects_per_frame = math_max(config.min_per_frame, config.objects_per_frame - 10)
    elseif avg_fps > config.target_fps + 10 and stability_system.restoration_speed > 0 then
        super_extreme_mode = false
        extreme_mode = false
        aggressive_mode = false
        stability_system.current_mode = "normal"
        
        config.cleanup_distance = math_max(config.min_distance, config.cleanup_distance - 35)
        config.objects_per_frame = math_min(config.max_per_frame, config.objects_per_frame + 12)
        config.safe_zone = math_min(75, config.safe_zone + 2)
    end
    
    local object_count = #cached_parts
    if object_count > 5000 and stability_system.restoration_speed > 0 then
        config.objects_per_frame = math_max(config.min_per_frame, config.objects_per_frame - 12)
    elseif object_count > 3500 and stability_system.restoration_speed > 0 then
        config.objects_per_frame = math_max(config.min_per_frame, config.objects_per_frame - 5)
    elseif object_count < 1800 and stability_system.restoration_speed > 0 then
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
        
        local effective_distance = config.cleanup_distance
        
        local count = 0
        local check_safe_zone = not super_extreme_mode
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
        
        if stability_system.restoration_speed == 0 then
            continue
        end
        
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
    local effective_per_frame
    if super_extreme_mode then
        effective_per_frame = config.objects_per_frame * 3
    elseif extreme_mode then
        effective_per_frame = config.objects_per_frame * 2.5
    elseif aggressive_mode then
        effective_per_frame = config.objects_per_frame * 1.35
    else
        effective_per_frame = config.objects_per_frame
    end
    
    local parts_to_hide_count = #parts_to_hide
    local parts_to_restore_count = #parts_to_restore
    
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp and stability_system.restoration_speed > 0 then
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
    
    if stability_system.restoration_speed > 0 then
        local base_per_frame = config.objects_per_frame
        local adjusted_per_frame = math_floor(base_per_frame * stability_system.restoration_speed)
        adjusted_per_frame = math_max(5, adjusted_per_frame)
        
        local processed_restore = 0
        local restore_list = parts_to_restore
        
        while processed_restore < adjusted_per_frame and restore_index <= parts_to_restore_count do
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
    end
end)
