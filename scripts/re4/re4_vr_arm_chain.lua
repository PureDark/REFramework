-- Builtin implementation: src/mods/vr/games/re4/RE4VRArmChain.cpp
return

-- re4_vr_arm_chain.lua — two-bone IK for R/L arm (upper + forearm); hand targets from VR motion globals.

if reframework:get_game_name() ~= "re4" then
    return
end

local _motion_module_cached = rawget(_G, "__re4_vr_arm_chain_module")
if _motion_module_cached ~= nil then
    package.loaded["re4_vr_arm_chain"] = _motion_module_cached
    return _motion_module_cached
end

local ok_ks, ks = pcall(function()
    return require("re4vr/re4_vr_killswitch")
end)
if not ok_ks or not ks then
    return
end

-- Lua doesn't expose math.atan2; use math.atan(y, x) (Lua 5.3+) or a fallback.
local function atan2_fallback(y, x)
    y = tonumber(y) or 0.0
    x = tonumber(x) or 0.0
    if math.atan then
        -- If 2-arg atan is supported, prefer it.
        local ok, r = pcall(function() return math.atan(y, x) end)
        if ok and type(r) == "number" then return r end
    end
    if x > 0.0 then
        return math.atan(y / x)
    elseif x < 0.0 then
        return math.atan(y / x) + ((y >= 0.0) and math.pi or -math.pi)
    else
        if y > 0.0 then return math.pi * 0.5 end
        if y < 0.0 then return -math.pi * 0.5 end
        return 0.0
    end
end

-- Provide math.atan2 for any legacy codepaths in this script.
if math.atan2 == nil then
    -- pcall in case math table is locked down by host.
    pcall(function() math.atan2 = atan2_fallback end)
end

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

-- Player body root transform (same source as other RE4 VR scripts; no utility module).
local function get_player_transform()
    local char_mgr = sdk.get_managed_singleton("chainsaw.CharacterManager")
    if not char_mgr then return nil end
    local ctx = safe(function() return char_mgr:call("getPlayerContextRef") end)
    if not ctx then return nil end
    local body_go = safe(function() return ctx:call("get_BodyGameObject") end)
    if not body_go then return nil end
    return safe(function() return body_go:call("get_Transform") end)
end

local function get_player_root_pose(player_tf)
    if not player_tf then return nil end
    local pos = safe(function() return player_tf:call("get_Position") end)
    local rot = safe(function() return player_tf:call("get_Rotation") end)
    if not pos or not rot then return nil end
    local inv = safe(function() return rot:inverse() end)
    local parent = safe(function() return player_tf:call("get_Parent") end)
    return {
        pos = pos,
        rot = rot,
        inv_rot = inv,
        parent = parent,
        parented = (parent ~= nil),
    }
end

local function vec3_subtract(a, b)
    return Vector3f.new(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function vec3_add(a, b)
    return Vector3f.new(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function vec3_scale(v, s)
    return Vector3f.new(v.x * s, v.y * s, v.z * s)
end

local function vec3_length(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function vec3_normalize(v)
    local len = vec3_length(v)
    if len < 1e-8 then return nil end
    return Vector3f.new(v.x / len, v.y / len, v.z / len)
end

local function vec3_dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function vec3_cross(a, b)
    return Vector3f.new(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
end

local function clampf(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function smoothstep01(t)
    t = clampf(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
end

local function quat_dot(a, b)
    if not a or not b then return 0.0 end
    return (a.x * b.x) + (a.y * b.y) + (a.z * b.z) + (a.w * b.w)
end

local function quat_neg(q)
    if not q then return nil end
    return Quaternion.new(-q.w, -q.x, -q.y, -q.z)
end

local function quat_slerp(a, b, t)
    if not a then return b end
    if not b then return a end
    -- Enforce quaternion continuity (q and -q represent same rotation).
    -- Without this, slerp can take the long way and cause visible 360° roll flips.
    if quat_dot(a, b) < 0.0 then
        b = quat_neg(b)
    end
    local ok, r = pcall(function() return a:slerp(b, t) end)
    return ok and r or b
end

local function vec3_lerp(a, b, t)
    if not a then return b end
    if not b then return a end
    local s = 1.0 - t
    return Vector3f.new(
        a.x * s + b.x * t,
        a.y * s + b.y * t,
        a.z * s + b.z * t
    )
end

local function vec3_reject_normalize(v, from_unit)
    local d = vec3_dot(from_unit, v)
    local r = vec3_subtract(v, vec3_scale(from_unit, d))
    local rl = vec3_length(r)
    if rl < 1e-5 then return nil end
    return vec3_scale(r, 1.0 / rl)
end

local function vec3_distance(a, b)
    return vec3_length(vec3_subtract(a, b))
end

local function quat_rotate_vec3(q, v)
    local ok, result = pcall(function() return q * v end)
    if ok and result then return result end
    local qv = Vector3f.new(q.x, q.y, q.z)
    local uv = Vector3f.new(
        qv.y * v.z - qv.z * v.y,
        qv.z * v.x - qv.x * v.z,
        qv.x * v.y - qv.y * v.x
    )
    local uuv = Vector3f.new(
        qv.y * uv.z - qv.z * uv.y,
        qv.z * uv.x - qv.x * uv.z,
        qv.x * uv.y - qv.y * uv.x
    )
    return Vector3f.new(
        v.x + ((uv.x * q.w) + uuv.x) * 2.0,
        v.y + ((uv.y * q.w) + uuv.y) * 2.0,
        v.z + ((uv.z * q.w) + uuv.z) * 2.0
    )
end

local function quat_inverse(q)
    if not q then return nil end
    local ok, inv = pcall(function() return q:inverse() end)
    return ok and inv or nil
end

local function quat_bone_x_along_dir(bone_dir, pole_hint)
    local x = vec3_normalize(bone_dir)
    if not x then return nil end
    local p = vec3_normalize(pole_hint)
    if not p then p = Vector3f.new(0.0, 1.0, 0.0) end

    local z = vec3_cross(p, x)
    local zl = vec3_length(z)
    if zl < 1e-5 then
        z = vec3_cross(Vector3f.new(0.0, 1.0, 0.0), x)
        zl = vec3_length(z)
    end
    if zl < 1e-5 then return nil end
    z = vec3_scale(z, 1.0 / zl)

    local y = vec3_cross(z, x)
    local yl = vec3_length(y)
    if yl < 1e-5 then return nil end
    y = vec3_scale(y, 1.0 / yl)

    local m00, m01, m02 = x.x, y.x, z.x
    local m10, m11, m12 = x.y, y.y, z.y
    local m20, m21, m22 = x.z, y.z, z.z
    local trace = m00 + m11 + m22
    local qw, qx, qy, qz

    if trace > 0 then
        local s = 0.5 / math.sqrt(trace + 1.0)
        qw = 0.25 / s
        qx = (m21 - m12) * s
        qy = (m02 - m20) * s
        qz = (m10 - m01) * s
    elseif m00 > m11 and m00 > m22 then
        local s = 2.0 * math.sqrt(1.0 + m00 - m11 - m22)
        qw = (m21 - m12) / s
        qx = 0.25 * s
        qy = (m01 + m10) / s
        qz = (m02 + m20) / s
    elseif m11 > m22 then
        local s = 2.0 * math.sqrt(1.0 + m11 - m00 - m22)
        qw = (m02 - m20) / s
        qx = (m01 + m10) / s
        qy = 0.25 * s
        qz = (m12 + m21) / s
    else
        local s = 2.0 * math.sqrt(1.0 + m22 - m00 - m11)
        qw = (m10 - m01) / s
        qx = (m02 + m20) / s
        qy = (m12 + m21) / s
        qz = 0.25 * s
    end

    local q = Quaternion.new(qw, qx, qy, qz)
    local ok, n = pcall(function() return q:normalized() end)
    return (ok and n) or q
end

-- Match motion reach slack (upper + lower − slack); solver uses same margin inside triangle.
local ik_reach_slack = 0.018
-- Forearm IK: blend lower-bone pole between elbow-plane axis vs body pole (higher = more hinge / “ball” elbow freedom)
local ik_lower_pole_mix = 0.64
-- Multiplier on outward component of pole hint (elbows point more out / less pinned)
local ik_pole_outward_mul = 1.0

-- [SHOULDER_REACH_FOLLOW] RE9-Pattern (apply_slide_rack_arm_follow): liegt das
-- Hand-Target ausserhalb der Armreichweite, wird die Schulter (prefix.._Shoulder,
-- Clavicle-Aequivalent) exakt um den Ueberschuss Richtung Hand geschoben ->
-- kein Clamp, kein Wrist-Stretch, Offsets bleiben exakt erhalten. Omnidirektional.
-- Ersetzt den frueheren Arm-Reach-Clamp + Forward-Shoulder-Stretch (beide entfernt).
local shoulder_reach_follow = true
local shoulder_reach_follow_slack = 0.018
-- Max. Schulter-Verschiebung (m) durch Reach-Follow: ungedeckelt wanderte
-- die Schulter dem Controller hinterher vom Koerper weg (L beobachtet,
-- R vermutlich der Ins-Bild-Dreher beim Rotieren).
local shoulder_reach_follow_max = 0.45

-- [HAND_CLAMP] Hat die Schulter ihr Follow-Limit (shoulder_reach_follow_max) ausgeschoepft
-- und die Hand will NOCH weiter weg als Schulter+Arm reichen, wird die HAND aufs erreichbare
-- Maximum geklemmt (Punkt = Armreichweite ab der gefolgten Schulter) statt vom Arm abzureissen.
-- Greift NUR im Extrem-Ueberstrecken; in normaler Reichweite haelt shoulder_reach_follow das
-- Target und der Clamp ist inaktiv.
local hand_clamp = true

-- [SHOULDER_PIN] L/R_Shoulder VOR dem IK-Solve hart auf die transform-
-- relative Stand-Pose setzen (Pos+Rot) — das anim-getriebene Schulter-
-- Wandern (Lauf/Kurven) ist weg, die Zwei-Bone-IK rechnet von der
-- gepinnten Basis -> Haende bleiben exakt am Controller. Reach-Follow
-- schiebt danach als bewusster Offset OBEN drauf. WICHTIG: Pin lebt HIER
-- (vor dem Solve), nicht in movement — ein Pin NACH dem Solve verschiebt
-- die fertige Armkette und die Haende verfehlen die VR-Targets
-- (gescheiterter [SHOULDER_PIN]-Versuch vom 2026-06-06, Memo).
-- Capture einmalig im ruhigen Stand (Anim-Export __vr_anim_l0 aus movement).
local shoulder_pin = true
local shoulder_pin_rel = { L = nil, R = nil }

-- [REMOVED] Upper-body pose lock komplett entfernt (Entscheid 2026-06-04).

-- [WRIST_Y] Hoehe der Unterarm-Enden als Offset (RE9 grace_wrist_y-Pattern):
-- Y-Offset aufs IK-Wrist-Ziel -> Unterarm-Ende hebt/senkt sich, Oberarm
-- re-solved automatisch. Pro Seite einstellbar, persistiert in der Config.
-- WICHTIG: Deklaration muss VOR apply_key_config stehen (Loader-Referenz).
local wrist_y = { L = 0.0, R = 0.0 }

-- [WRIST_X] Seitlicher Offset der Unterarm-Enden (links/rechts), char-relativ:
-- lokaler X-Offset wird mit der Char-Rotation in Welt gedreht, damit
-- "rechts" unabhaengig von der Blickrichtung stimmt. Analog zu wrist_y.
local wrist_x = { L = 0.0, R = 0.0 }


local function solve_arm_ik(shoulder_pos, hand_pos, upper_len, lower_len, pole_vector, bend_sign)
    bend_sign = (bend_sign == nil) and 1.0 or bend_sign
    if not shoulder_pos or not hand_pos or not pole_vector then return nil, nil end
    if upper_len < 1e-4 or lower_len < 1e-4 then return nil, nil end

    local w = vec3_subtract(hand_pos, shoulder_pos)
    local dist = vec3_length(w)
    if dist < 1e-6 then return nil, nil end

    local max_reach = upper_len + lower_len - ik_reach_slack
    if max_reach < 1e-3 then max_reach = upper_len + lower_len - 1e-4 end
    local reach = math.min(dist, max_reach - 1e-4)
    if reach < 1e-4 then return nil, nil end

    local to_target = vec3_normalize(vec3_scale(w, 1.0 / dist))
    if not to_target then return nil, nil end

    local effector = vec3_add(shoulder_pos, vec3_scale(to_target, reach))

    local cos_shoulder = (upper_len * upper_len + reach * reach - lower_len * lower_len) / (2.0 * upper_len * reach)
    cos_shoulder = clampf(cos_shoulder, -1.0, 1.0)
    local sin_shoulder = math.sqrt(math.max(0.0, 1.0 - cos_shoulder * cos_shoulder))

    local pole_planar = vec3_reject_normalize(pole_vector, to_target) or pole_vector
    local n = vec3_cross(pole_planar, to_target)
    local nl = vec3_length(n)
    if nl < 1e-5 then
        n = vec3_cross(pole_planar, Vector3f.new(0.0, 1.0, 0.0))
        nl = vec3_length(n)
    end
    if nl < 1e-5 then return nil, nil end
    n = vec3_scale(n, 1.0 / nl)

    local perp = vec3_cross(n, to_target)
    local pl = vec3_length(perp)
    if pl < 1e-5 then return nil, nil end
    perp = vec3_scale(perp, bend_sign / pl)

    local function dirs_from_perp(pu)
        local ud = vec3_normalize(vec3_add(
            vec3_scale(to_target, cos_shoulder),
            vec3_scale(pu, sin_shoulder)
        ))
        if not ud then return nil, nil end
        local elbow_guess = vec3_add(shoulder_pos, vec3_scale(ud, upper_len))
        local fr = vec3_normalize(vec3_subtract(effector, elbow_guess))
        if not fr then return nil, nil end
        return ud, fr
    end

    local upper_dir, fore = dirs_from_perp(perp)
    if not upper_dir or not fore then return nil, nil end

    local elbow_pos = vec3_add(shoulder_pos, vec3_scale(upper_dir, upper_len))
    local reaching_low = hand_pos.y < shoulder_pos.y - 0.06
    local elbow_too_high = elbow_pos.y > shoulder_pos.y - 0.03
    if reaching_low and elbow_too_high then
        local perp2 = vec3_scale(perp, -1.0)
        local ud2, fr2 = dirs_from_perp(perp2)
        if ud2 and fr2 then
            upper_dir, fore = ud2, fr2
        end
    end

    return upper_dir, fore
end

-- Forward declare (hooks weiter unten referenzieren es vor der Definition).
local should_pause


local function ik_world_rotations_from_dirs(upper_dir, fore, pole_vector, bone_axis_flip)
    bone_axis_flip = (bone_axis_flip == nil) and 1.0 or bone_axis_flip
    local ud = vec3_scale(upper_dir, bone_axis_flip)
    local fd = vec3_scale(fore, bone_axis_flip)
    local q_upper = quat_bone_x_along_dir(ud, pole_vector)
    if not q_upper then return nil, nil end

    local elbow_axis = vec3_normalize(vec3_cross(ud, fd))
    local pole_lower = pole_vector
    if elbow_axis then
        local w_el = clampf(ik_lower_pole_mix, 0.0, 1.0)
        local pole_mix = vec3_normalize(vec3_add(
            vec3_scale(elbow_axis, w_el),
            vec3_scale(pole_vector, 1.0 - w_el)
        ))
        if pole_mix then pole_lower = pole_mix end
    end
    local q_lower = quat_bone_x_along_dir(fd, pole_lower)
    if not q_lower then return nil, nil end
    return q_upper, q_lower
end

local ENABLE_ARM_CHAIN = true

-- Per-joint tuning (defaults = no change vs stock IK): pos_* magnitude also feeds IK segment length hint.
-- rot_* = additive local euler degrees after IK; scale_* = local scale (default 1).
local chain_offset = {
    R_Hand = { pos_x = 0, pos_y = 0, pos_z = 0, rot_x = 0, rot_y = 0, rot_z = 0, scale_x = 1, scale_y = 1, scale_z = 1 },
    R_Forearm = { pos_x = 0, pos_y = 0, pos_z = 0, rot_x = 0, rot_y = 0, rot_z = 0, scale_x = 1, scale_y = 1, scale_z = 1 },
    R_UpperArm = { pos_x = 0, pos_y = 0, pos_z = 0, rot_x = 0, rot_y = 0, rot_z = 0, scale_x = 1, scale_y = 1, scale_z = 1 },
    R_Shoulder = { pos_x = 0, pos_y = 0, pos_z = 0, rot_x = 0, rot_y = 0, rot_z = 0, scale_x = 1, scale_y = 1, scale_z = 1 },
    L_Hand = { pos_x = 0, pos_y = 0, pos_z = 0, rot_x = 0, rot_y = 0, rot_z = 0, scale_x = 1, scale_y = 1, scale_z = 1 },
    L_Forearm = { pos_x = 0, pos_y = 0, pos_z = 0, rot_x = 0, rot_y = 0, rot_z = 0, scale_x = 1, scale_y = 1, scale_z = 1 },
    L_UpperArm = { pos_x = 0, pos_y = 0, pos_z = 0, rot_x = 0, rot_y = 0, rot_z = 0, scale_x = 1, scale_y = 1, scale_z = 1 },
    L_Shoulder = { pos_x = 0, pos_y = 0, pos_z = 0, rot_x = 0, rot_y = 0, rot_z = 0, scale_x = 1, scale_y = 1, scale_z = 1 },
}

local arm_segment_enabled = {
    R_Hand = true,
    R_Forearm = true,
    R_UpperArm = true,
    R_Shoulder = true,
    L_Hand = true,
    L_Forearm = true,
    L_UpperArm = true,
    L_Shoulder = true,
}

local function flush_all_arm_caches(reset_scapula)
    chain_joints = {}
    -- (Shoulder-Stretch-State entfernt — reach follow ist zustandslos.)
end

local chain_joints = {}

local CONFIG_FILE = "re4_vr/re4_vr_arm_chain.json"
local current_key = "default"
local all_configs = {}

local function load_all_configs()
    pcall(function()
        local f = io.open(CONFIG_FILE, "r")
        if not f then return end
        local data = json.load_string(f:read("*a"))
        f:close()
        if data then all_configs = data end
    end)
end

local function resolve_config_key()
    local g = _G.__vr_active_char
    if type(g) == "string" and g ~= "" then
        return g:lower()
    end
    return "leon"
end

local function apply_key_config(resolved_key)
    resolved_key = resolved_key or resolve_config_key()
    local data = all_configs[resolved_key] or all_configs["default"] or all_configs["leon"]
    if not data then return end
    current_key = resolved_key
    if data.enabled ~= nil then ENABLE_ARM_CHAIN = data.enabled end
    if data.chain then
        for name, offsets in pairs(data.chain) do
            if chain_offset[name] then
                for k, v in pairs(offsets) do chain_offset[name][k] = v end
            end
        end
    end
    if data.segments then
        for name, en in pairs(data.segments) do
            if arm_segment_enabled[name] ~= nil then arm_segment_enabled[name] = en end
        end
    end

    if data.wrist_y and type(data.wrist_y) == "table" then
        wrist_y.L = tonumber(data.wrist_y.L) or 0.0
        wrist_y.R = tonumber(data.wrist_y.R) or 0.0
    end

    if data.wrist_x and type(data.wrist_x) == "table" then
        wrist_x.L = tonumber(data.wrist_x.L) or 0.0
        wrist_x.R = tonumber(data.wrist_x.R) or 0.0
    end

    if data.shoulder_reach_follow ~= nil then
        shoulder_reach_follow = data.shoulder_reach_follow == true
    end
    if type(data.shoulder_reach_follow_max) == "number" then
        shoulder_reach_follow_max = data.shoulder_reach_follow_max
    end
    if data.hand_clamp ~= nil then
        hand_clamp = data.hand_clamp == true
    end
    if data.shoulder_pin ~= nil then
        shoulder_pin = data.shoulder_pin == true
    end
    if type(data.shoulder_pin_pose) == "table" then
        for _, side in ipairs({ "L", "R" }) do
            local s = data.shoulder_pin_pose[side]
            if type(s) == "table" and type(s.px) == "number" and type(s.rw) == "number" then
                shoulder_pin_rel[side] = {
                    p = Vector3f.new(s.px, s.py, s.pz),
                    r = Quaternion.new(s.rw, s.rx, s.ry, s.rz),
                }
            end
        end
    end


end

local function deep_copy_offsets()
    local copy = {}
    for name, off in pairs(chain_offset) do
        copy[name] = {}
        for k, v in pairs(off) do copy[name][k] = v end
    end
    return copy
end

local function deep_copy_segments()
    local copy = {}
    for name, en in pairs(arm_segment_enabled) do
        copy[name] = en
    end
    return copy
end

-- [WRIST_Y]/[WRIST_X] Deklaration nach oben verschoben (vor apply_key_config),
-- sonst kompiliert der Config-Loader sie als global=nil -> Crash beim Laden.

local function load_from_config_bodychain(bc)
    if not bc or type(bc) ~= "table" then return end
    if bc.enabled ~= nil then ENABLE_ARM_CHAIN = bc.enabled end
    if bc.chain and type(bc.chain) == "table" then
        for name, offsets in pairs(bc.chain) do
            if chain_offset[name] then
                for k, v in pairs(offsets) do
                    if chain_offset[name][k] ~= nil then
                        chain_offset[name][k] = v
                    end
                end
            end
        end
    end
    if bc.segments and type(bc.segments) == "table" then
        for name, en in pairs(bc.segments) do
            if arm_segment_enabled[name] ~= nil then
                arm_segment_enabled[name] = en
            end
        end
    end
end

local function get_save_bodychain()
    return {
        enabled = ENABLE_ARM_CHAIN,
        chain = deep_copy_offsets(),
        segments = deep_copy_segments(),
    }
end

local function save_config()
    local save_key = resolve_config_key()
    local pin_pose = {}
    for _, side in ipairs({ "L", "R" }) do
        local r = shoulder_pin_rel[side]
        if r then
            pin_pose[side] = {
                px = r.p.x, py = r.p.y, pz = r.p.z,
                rw = r.r.w, rx = r.r.x, ry = r.r.y, rz = r.r.z,
            }
        end
    end
    all_configs[save_key] = {
        enabled = ENABLE_ARM_CHAIN,
        chain = deep_copy_offsets(),
        segments = deep_copy_segments(),
        wrist_y = { L = wrist_y.L, R = wrist_y.R },
        wrist_x = { L = wrist_x.L, R = wrist_x.R },
        shoulder_reach_follow = shoulder_reach_follow == true,
        shoulder_reach_follow_max = shoulder_reach_follow_max,
        hand_clamp = hand_clamp == true,
        shoulder_pin = shoulder_pin == true,
        shoulder_pin_pose = pin_pose,
    }
    local ok, err = pcall(function()
        local ok_dump, dumped = pcall(json.dump_string, all_configs)
        if not ok_dump or type(dumped) ~= "string" then
            return
        end
        local f = io.open(CONFIG_FILE, "w")
        if not f then
            return
        end
        f:write(dumped)
        f:close()
    end)
    if not ok then
    end
end

load_all_configs()
apply_key_config(resolve_config_key())

local function deg2rad(d) return d * 0.0174532925 end

local function quat_from_euler_deg(x, y, z)
    local v = Vector3f.new(deg2rad(x), deg2rad(y), deg2rad(z))
    local ok, q = pcall(function() return Quaternion.new(v):normalized() end)
    return ok and q or nil
end

local function joint_tweak_scale_vec(off)
    if not off then return Vector3f.new(1, 1, 1) end
    local sx = tonumber(off.scale_x) or 1.0
    local sy = tonumber(off.scale_y) or 1.0
    local sz = tonumber(off.scale_z) or 1.0
    sx = math.max(sx, 0.001)
    sy = math.max(sy, 0.001)
    sz = math.max(sz, 0.001)
    return Vector3f.new(sx, sy, sz)
end

local function arm_pole_direction_world(char_rot, is_right_arm)
    local world_down = Vector3f.new(0.0, -1.0, 0.0)
    if not char_rot then
        return world_down
    end
    local char_right = quat_rotate_vec3(char_rot, Vector3f.new(1.0, 0.0, 0.0))
    local char_fwd = quat_rotate_vec3(char_rot, Vector3f.new(0.0, 0.0, 1.0))
    local char_down = quat_rotate_vec3(char_rot, Vector3f.new(0.0, -1.0, 0.0))
    local char_back = vec3_scale(char_fwd, -1.0)
    local outward = is_right_arm and vec3_scale(char_right, -1.0) or char_right

    local out_w = 0.46 * clampf(ik_pole_outward_mul, 0.0, 2.5)
    local blend = vec3_add(
        vec3_add(vec3_scale(outward, out_w), vec3_scale(char_down, 0.36)),
        vec3_add(vec3_scale(char_back, 0.12), vec3_scale(world_down, 0.06))
    )
    local p = vec3_normalize(blend)
    return p or char_down
end

local function segment_length_from_offset(off)
    if not off then return 0.0 end
    return math.sqrt(off.pos_x * off.pos_x + off.pos_y * off.pos_y + off.pos_z * off.pos_z)
end

-- Max plausible IK segment length from chain_offset hints (meters).
local ARM_SEG_CAP = 0.40

local AUTORESET_DIST     = 0.15
local AUTORESET_COOLDOWN = 1.0
local autoreset_last_t   = 0
local cached_player_tf   = nil

-- IK bone lengths from chain_offset only (|pos| per bone as length hint).
-- Never use live shoulder→elbow / elbow→hand distances: they follow the current animation
-- bend (and reload pose), so the solver's reach budget changes with controller distance and
-- looks like forearm stretch or collapse after script reset / load game.
local function arm_ik_segment_lengths(_upper_joint, _lower_joint, _hand_joint, name_upper, name_lower)
    local u_json = segment_length_from_offset(chain_offset[name_upper])
    local l_json = segment_length_from_offset(chain_offset[name_lower])
    local upper_len = math.min(math.max(u_json, 0.26, 0.24), ARM_SEG_CAP)
    local lower_len = math.min(math.max(l_json, 0.24, 0.22), ARM_SEG_CAP)
    return upper_len, lower_len
end

-- [LOGFLUT 2026-08-02, "was ist das fuer eine Flut an Exceptions"] Dieser Test prueft die
-- Gueltigkeit eines Joints, indem er absichtlich get_Position aufruft und schaut, ob es wirft.
-- Das ist logisch richtig, hat aber eine teure Nebenwirkung: REFramework schreibt JEDE Engine-
-- Exception SYNCHRON ins Framework-Log -- und zwar in der Invoke-Schicht, also BEVOR unser pcall sie
-- abfaengt. `pcall` verhindert den Lua-Fehler, NICHT die Logzeile.
-- Ist ein Joint dauerhaft tot und dieser Test laeuft pro Frame fuer beide Arme mehrfach, entstehen
-- Hunderte Zeilen pro Sekunde (gemessen: 665 in EINER Sekunde, Logdatei auf 10 MB). Waehrend die
-- Platte beschrieben wird, kommt der Script-Thread nicht hinterher -- Eingaben laufen ins Leere.
-- Genau dieses Muster hat am 2026-07-20 schon einmal den Script-Thread abgewuergt.
-- FIX: Die Logik bleibt identisch, nur die HAEUFIGKEIT wird gedeckelt. Ein Joint, der eben noch
-- ungueltig war, wird 0.5 s lang nicht erneut angefasst -> aus 665 Zeilen/s werden hoechstens 2.
-- Sobald er wieder gueltig ist, faellt er aus der Merkliste.
-- [LOGFLUT GEDROSSELT 2026-08-02, "da is kein unterschied" -- Vergleichslauf ohne Drosselung
-- gemacht, Arm-IK fuehlt sich identisch an] Der Test prueft die Gueltigkeit eines Joints, indem er
-- absichtlich get_Position aufruft und schaut, ob es wirft. REFramework schreibt aber JEDE
-- Engine-Exception SYNCHRON ins Framework-Log -- in der Invoke-Schicht, also BEVOR unser pcall sie
-- abfaengt. `pcall` verhindert den Lua-Fehler, NICHT die Logzeile. Bei einem dauerhaft toten Joint
-- sind das Hunderte Zeilen pro Sekunde (gemessen: 665 in EINER Sekunde, Logdatei auf 10 MB), und
-- waehrend die Platte beschrieben wird, kommt der Script-Thread nicht hinterher -> Eingaben laufen
-- ins Leere. Dasselbe Muster hat am 2026-07-20 schon einmal den Script-Thread abgewuergt.
-- Logik unveraendert, nur die HAEUFIGKEIT gedeckelt: ein eben noch ungueltiger Joint wird 0.5 s lang
-- nicht erneut angefasst -> aus 665 Zeilen/s werden hoechstens 2. Ein GUELTIGER Joint wird weiterhin
-- jeden Frame geprueft und faellt sofort aus der Merkliste.
local _jv_bad = {}
local function is_joint_valid(joint)
    if not joint then return false end
    local addr = nil
    do local ok_a, a = pcall(function() return joint:get_address() end); if ok_a then addr = a end end
    local now = os.clock()
    if addr and _jv_bad[addr] and (now - _jv_bad[addr]) < 0.5 then return false end
    local ok, _ = pcall(function() return joint:call("get_Position") end)
    if addr then
        if ok then _jv_bad[addr] = nil else _jv_bad[addr] = now end
    end
    return ok
end

local axis_verify_done = { R = false, L = false }

-- [LOGGING ENTFERNT 2026-08-19, Public Release] Die Bone-Achsen-Pruefung baute nur noch einen
-- Diagnose-String, dessen Ausgabe schon geloescht war (leere if/else-Zweige). Rumpf bleibt leer,
-- die Aufrufstellen bleiben unveraendert.
local function maybe_log_bone_axis_once() end

local function get_chain_joint(name)
    if chain_joints[name] and is_joint_valid(chain_joints[name]) then
        return chain_joints[name]
    end
    local pt = get_player_transform()
    if not pt then return nil end
    chain_joints[name] = safe(function() return pt:call("getJointByName", name) end)
    return chain_joints[name]
end

local function apply_ik_rotation_to_joint(name, world_rot, joint)
    -- The caller resolved this joint immediately before the solve.  Reusing it
    -- avoids a second cache validation/native position lookup in the same pass.
    joint = joint or get_chain_joint(name)
    if not joint or not world_rot then return end

    local off = chain_offset[name]
    local rot_off = nil
    if off and (off.rot_x ~= 0 or off.rot_y ~= 0 or off.rot_z ~= 0) then
        rot_off = quat_from_euler_deg(off.rot_x, off.rot_y, off.rot_z)
    end

    local parent = safe(function() return joint:call("get_Parent") end)
    if parent then
        local parent_rot = safe(function() return parent:call("get_Rotation") end)
        if parent_rot then
            local inv_rot = safe(function() return parent_rot:inverse() end)
            if inv_rot then
                local local_rot = safe(function() return (inv_rot * world_rot):normalized() end)
                if local_rot then
                    if rot_off then
                        local ok2, lr2 = pcall(function() return (local_rot * rot_off):normalized() end)
                        if ok2 and lr2 then local_rot = lr2 end
                    end
                    pcall(function() joint:call("set_LocalRotation", local_rot) end)
                end
            end
        end
    else
        local wr = world_rot
        if rot_off then
            local ok2, w2 = pcall(function() return (world_rot * rot_off):normalized() end)
            if ok2 and w2 then wr = w2 end
        end
        pcall(function() joint:call("set_Rotation", wr) end)
    end

    local scale_vec = joint_tweak_scale_vec(off)
    pcall(function() joint:call("set_LocalScale", scale_vec) end)
end

-- [SHOULDER_PIN] Capture + Enforce; laeuft pro Seite direkt vor dem Solve.
-- LOKALE Pose (Parent = Spine_2, durch movement-SPINE_PIN eingefroren) —
-- Welt-Writes wurden vom Engine-Pose-Recompute geschluckt, Locals halten.
local function apply_shoulder_pin(prefix)
    if not shoulder_pin then
        shoulder_pin_rel[prefix] = nil
        return
    end
    local sj = get_chain_joint(prefix .. "_Shoulder")
    if not sj then return end

    local rel = shoulder_pin_rel[prefix]
    -- Capture passiert NICHT hier, sondern im Solve (apply_arm_ik_side):
    -- dort ist die Reichweite bekannt — Capture nur wenn die Hand in
    -- natuerlicher Reichweite ist, sonst friert man eine bereits von
    -- Reach-Follow verschobene Schulter ein (linke Schulter: Hand liegt
    -- im Stand am Foregrip -> verschoben gecaptured -> "sitzt neben dem
    -- Koerper" + Wrist-Stretch).
    if not rel then return end

    pcall(function()
        sj:call("set_LocalPosition", rel.p)
        sj:call("set_LocalRotation", rel.r)
    end)
end

local function apply_arm_ik_side(prefix, hand_pos, char_rot, pole_smoothed, root_pose)
    local upper_name = prefix .. "_UpperArm"
    local lower_name = prefix .. "_Forearm"
    local hand_name = prefix .. "_Hand"
    if arm_segment_enabled[upper_name] == false and arm_segment_enabled[lower_name] == false then
        return
    end

    -- [WRIST_Y] Y-Offset aufs IK-Wrist-Ziel (nur IK; der Hand-Joint selbst
    -- bleibt am Controller-Target des Motion-Scripts).
    local wy = wrist_y[prefix]
    if wy and wy ~= 0.0 then
        hand_pos = Vector3f.new(hand_pos.x, hand_pos.y + wy, hand_pos.z)
    end

    -- [WRIST_X] Seitlicher Offset aufs IK-Wrist-Ziel, char-relativ (+ = rechts).
    local wx = wrist_x[prefix]
    if wx and wx ~= 0.0 then
        local off_world = char_rot
            and quat_rotate_vec3(char_rot, Vector3f.new(wx, 0.0, 0.0))
            or Vector3f.new(wx, 0.0, 0.0)
        hand_pos = vec3_add(hand_pos, off_world)
    end

    local upper_joint = get_chain_joint(upper_name)
    local lower_joint = get_chain_joint(lower_name)
    local hand_joint = get_chain_joint(hand_name)
    if not upper_joint then return end

    -- [SHOULDER_PIN] Basis festnageln BEVOR shoulder_world gelesen wird —
    -- der Solve rechnet dann von der gepinnten Schulter.
    apply_shoulder_pin(prefix)

    local shoulder_world = safe(function() return upper_joint:call("get_Position") end)
    if not shoulder_world then return end

    local upper_len, lower_len = arm_ik_segment_lengths(
        upper_joint, lower_joint, hand_joint, upper_name, lower_name
    )

    -- [HAND_CLAMP] Arm-Ursprung (gepinnte Schulter/Upper) + maximale Reichweite fuer motion
    -- veroeffentlichen. motion clampt damit den HAND-Pin (write_joint_pose) auf diesen Radius
    -- -> Hand bleibt am Arm-Ende statt mit Wrist-Stretch zum Controller gezogen zu werden.
    -- maxreach = Armlaenge (minus Slack) + erlaubtes Schulter-Nachziehen (Reach-Follow).
    if hand_clamp then
        local maxreach = upper_len + lower_len - (shoulder_reach_follow_slack or 0.0)
            + ((shoulder_reach_follow and shoulder_reach_follow_max) or 0.0)
        _G["__vr_arm_chain_" .. prefix .. "_root"] = shoulder_world
        _G["__vr_arm_chain_" .. prefix .. "_maxreach"] = maxreach
    else
        _G["__vr_arm_chain_" .. prefix .. "_root"] = nil
        _G["__vr_arm_chain_" .. prefix .. "_maxreach"] = nil
    end

    -- [SHOULDER_PIN] Capture-Slot: nur wenn Hand in natuerlicher Reichweite
    -- (Reach-Follow inaktiv -> Schulter-Local garantiert unverschoben) und
    -- ruhige Stand-Anim. Enforce laeuft oben in apply_shoulder_pin.
    if shoulder_pin and not shoulder_pin_rel[prefix] then
        local max_r0 = upper_len + lower_len - (shoulder_reach_follow_slack or 0.0)
        local d0 = vec3_length(vec3_subtract(hand_pos, shoulder_world))
        local a = _G.__vr_anim_l0
        if a and a:lower():find("stand", 1, true) and max_r0 > 0.05 and d0 < max_r0 then
            local sj = get_chain_joint(prefix .. "_Shoulder")
            local lp = sj and safe(function() return sj:call("get_LocalPosition") end)
            local lr = sj and safe(function() return sj:call("get_LocalRotation") end)
            if lp and lr then
                shoulder_pin_rel[prefix] = { p = lp, r = lr }
                pcall(save_config)   -- Pose persistent: gleiche Optik jede Session
            end
        end
    end

    -- [SHOULDER_REACH_FOLLOW] Schulter exakt um den Reichweiten-Ueberschuss
    -- Richtung Hand schieben (RE9-Pattern), bevor geclampt/gesolved wird.
    if shoulder_reach_follow then
        local max_r = upper_len + lower_len - (shoulder_reach_follow_slack or 0.0)
        local w = vec3_subtract(hand_pos, shoulder_world)
        local d = vec3_length(w)
        if max_r > 0.05 and d > max_r then
            local dir = vec3_normalize(w)
            if dir then
                local sj = get_chain_joint(prefix .. "_Shoulder")
                local sp = sj and safe(function() return sj:call("get_Position") end) or nil
                if sp then
                    local excess = d - max_r
                    -- [RAILCAR] Auf dem Cart die Schulter VOLL mitgehen lassen (kein Cap) -> nie Clamp.
                    if rawget(_G, "__re4_railcar_mode") ~= true and excess > shoulder_reach_follow_max then
                        excess = shoulder_reach_follow_max
                    end
                    local delta = vec3_scale(dir, excess)
                    pcall(function() sj:call("set_Position", vec3_add(sp, delta)) end)
                    -- UpperArm ist Kind der Schulter -> Welt-Pos verschiebt sich mit.
                    shoulder_world = vec3_add(shoulder_world, delta)
                end
            end
        end
    end

    -- [HAND_CLAMP] Nach dem Reach-Follow: ist die Hand IMMER NOCH weiter weg als der Arm ab
    -- der (gefolgten) Schulter reicht (= Schulter hat ihr Follow-Limit ausgeschoepft), die
    -- Hand-Vorgabe aufs Maximum klemmen -> Hand bleibt am Arm, kein Wegfliegen/Abriss.
    -- In normaler Reichweite ist d == max_r (Follow hat exakt nachgezogen) -> kein Clamp.
    if hand_clamp and rawget(_G, "__re4_railcar_mode") ~= true then   -- [RAILCAR] kein Hand-Clamp auf dem Cart
        local max_r = upper_len + lower_len - (shoulder_reach_follow_slack or 0.0)
        local w = vec3_subtract(hand_pos, shoulder_world)
        local d = vec3_length(w)
        if max_r > 0.05 and d > max_r + 1e-4 then
            local dir = vec3_normalize(w)
            if dir then hand_pos = vec3_add(shoulder_world, vec3_scale(dir, max_r)) end
        end
    end

    -- When the player root is dynamically parented (e.g. elevator), the engine moves the parent
    -- and the player root together. VR controller targets are authored in absolute world space,
    -- so we solve the arm IK in the player-root local space to avoid a tug-of-war.
    local do_local_space = (root_pose and root_pose.parented == true and root_pose.inv_rot ~= nil and root_pose.pos ~= nil)

    local shoulder_solve = shoulder_world
    local hand_solve = hand_pos
    local pole_solve = pole_smoothed
    if do_local_space then
        local rel_sh = vec3_subtract(shoulder_world, root_pose.pos)
        local rel_ha = vec3_subtract(hand_pos, root_pose.pos)
        shoulder_solve = quat_rotate_vec3(root_pose.inv_rot, rel_sh)
        hand_solve = quat_rotate_vec3(root_pose.inv_rot, rel_ha)
        if pole_solve then
            pole_solve = quat_rotate_vec3(root_pose.inv_rot, pole_solve)
        end
    end

    -- Reach-Clamp entfernt — shoulder_reach_follow haelt das Target in Reichweite.
    -- Globals bleiben fuer two_hands_weapons erhalten, zeigen jetzt aufs ungeclampte Target.
    local hand_pos_clamped = hand_solve
    if prefix == "R" then
        _G.__vr_arm_chain_rh_clamped_pos = hand_pos_clamped
    else
        _G.__vr_arm_chain_lh_clamped_pos = hand_pos_clamped
    end

    local is_right = (prefix == "R")
    local pole_vec = pole_solve
    if not pole_vec or vec3_length(pole_vec) < 1e-6 then
        pole_vec = arm_pole_direction_world(char_rot, is_right)
        if do_local_space then
            pole_vec = quat_rotate_vec3(root_pose.inv_rot, pole_vec)
        end
    else
        local pn = vec3_normalize(pole_vec)
        if pn then pole_vec = pn end
    end
    local bend_sign = -1.0
    local bone_axis_flip = is_right and -1.0 or 1.0

    local upper_dir, fore_dir = solve_arm_ik(shoulder_solve, hand_pos_clamped, upper_len, lower_len, pole_vec, bend_sign)
    if not upper_dir or not fore_dir then return end

    if do_local_space then
        upper_dir = quat_rotate_vec3(root_pose.rot, upper_dir)
        fore_dir = quat_rotate_vec3(root_pose.rot, fore_dir)
        pole_vec = quat_rotate_vec3(root_pose.rot, pole_vec)
    end

    maybe_log_bone_axis_once(prefix, upper_joint, lower_joint, upper_dir)

    local q_upper, q_lower = ik_world_rotations_from_dirs(upper_dir, fore_dir, pole_vec, bone_axis_flip)
    if not q_upper or not q_lower then return end

    if arm_segment_enabled[upper_name] ~= false then
        apply_ik_rotation_to_joint(upper_name, q_upper, upper_joint)
    end
    if arm_segment_enabled[lower_name] ~= false then
        apply_ik_rotation_to_joint(lower_name, q_lower, lower_joint)
    end
end

local chain_first_load = true

-- Debug/synchronization controls (for diagnosing arm twisting / script conflicts).
-- Defaults preserve existing behavior (multi-phase IK application).
local debug_sync = {
    -- Option A: Only run after VR Motion has produced a new "final hand target" tick.
    require_motion_tick = false,

    -- Option B: Even if we are hooked multiple times, solve at most once per game frame.
    apply_once_per_frame = false,

    -- Option C: Enable/disable each hook point (to find the best phase that doesn't fight animation/motion).
    -- Voller Phasen-Stack (RE9-Regel): Engine-Anim schreibt ZWISCHEN den Phasen,
    -- ohne LateUpdate+BeginRendering schwingen die Arme beim Laufen mit.
    hook_lockscene = true,
    hook_lateupdate = true,
    hook_update_jointexpr = true,
    hook_beginrender = true,

    -- Debug readout
    show_status = true,
}

local debug_last_frame_applied = -1
local debug_last_motion_tick_seen = -1

should_pause = function()
    -- [RAILCAR] Auf dem Schienenwagen laeuft arm_chain TROTZ Killswitch weiter -- AUSSER waehrend eines
    -- nativen Reloads (dann pausieren, damit die native Nachlade-Anim durchspielt).
    if rawget(_G, "__re4_railcar_mode") == true then
        if rawget(_G, "__re4_railcar_reloading") ~= true then return false end
    end
    if ks.is_active() then return true end
    if _G.__vr_motion_paused == true then return true end
    return false
end

local function check_cutscene_end()
end

local function check_player_changed()
    local tf = get_player_transform()
    if tf == nil then return end
    if cached_player_tf ~= nil and tf ~= cached_player_tf then
        flush_all_arm_caches(true)
    end
    cached_player_tf = tf
end

local function check_autoreset(prefix, hand_target)
    if not hand_target then return end
    local now = os.clock()
    if (now - autoreset_last_t) < AUTORESET_COOLDOWN then return end
    local hand_joint = chain_joints[prefix .. "_Hand"]
    if not hand_joint then return end
    local hand_actual = safe(function() return hand_joint:call("get_Position") end)
    if not hand_actual then return end
    local dx = hand_actual.x - hand_target.x
    local dy = hand_actual.y - hand_target.y
    local dz = hand_actual.z - hand_target.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > AUTORESET_DIST then
        flush_all_arm_caches(false)
        autoreset_last_t = now
    end
end

_G.__vr_flush_arm_joint_cache = flush_all_arm_caches

local function should_apply_body_chain_now()
    if debug_sync.require_motion_tick then
        local mt = tonumber(_G.__vr_motion_tick_id) or -1
        if mt <= debug_last_motion_tick_seen then
            return false
        end
    end

    if debug_sync.apply_once_per_frame then
        local f = -1
        if re.get_frame_count then
            local ok, n = pcall(function() return re.get_frame_count() end)
            if ok and type(n) == "number" then f = n end
        end
        if f == -1 then
            f = tonumber(_G.__vr_motion_tick_id) or (debug_last_frame_applied + 1)
        end
        if f == debug_last_frame_applied then
            return false
        end
        debug_last_frame_applied = f
    end

    if debug_sync.require_motion_tick then
        debug_last_motion_tick_seen = tonumber(_G.__vr_motion_tick_id) or debug_last_motion_tick_seen
    end

    return true
end

local function apply_body_chain()
    _G.__vr_re4_two_bone_ik_active = false
    if not ENABLE_ARM_CHAIN then return end
    if should_pause() then
        return
    end
    if not should_apply_body_chain_now() then
        return
    end

    if chain_first_load then
        chain_first_load = false
        chain_joints = {}
        return
    end

    check_player_changed()

    local new_key = resolve_config_key()
    if new_key ~= current_key then
        chain_joints = {}
        apply_key_config(new_key)
    end

    local player_tf = get_player_transform()
    if not player_tf then
        return
    end

    _G.__vr_re4_two_bone_ik_active = true

    local root_pose = get_player_root_pose(player_tf)

    local char_rot = safe(function() return player_tf:call("get_Rotation") end) or nil

    -- [HAND_REPIN] Wir laufen NACH motion (siehe HOOK_ORDER): das IK verdreht
    -- den Unterarm, dessen Kind der Hand-Joint ist -> Hand wuerde mitgezogen.
    -- Deshalb nach dem IK die Hand selbst wieder aufs Motion-Target pinnen.
    local function repin_hand(prefix, pos, rot)
        local hj = get_chain_joint(prefix .. "_Hand")
        if not hj then return end
        if pos then pcall(function() hj:call("set_Position", pos) end) end
        if rot then pcall(function() hj:call("set_Rotation", rot) end) end
    end

    local rh_raw = _G.__vr_rh_joint_pos or _G.__vr_unified_rh_pos or _G.__vr_rh_world
    local rh_pos = rh_raw
    if rh_pos then
        apply_arm_ik_side("R", rh_pos, char_rot, nil, root_pose)
        check_autoreset("R", rh_pos)
    end

    local lh_raw = _G.__vr_lh_joint_pos or _G.__vr_unified_lh_pos or _G.__vr_lh_world
    -- [SLIDE_DOCK] re4_vr_reload.lua setzt __vr_slide_hand_world_pos waehrend der
    -- Slide-Grab -> linke Hand-IK aufs Slide-Ziel. [DOCK_LERP] Statt hartem Swap:
    -- per __vr_slide_dock_blend_factor (0..1, smoothstep) sanft zwischen Roh-Hand und
    -- Slide hin- und (nach dem Loslassen) wieder weg-lerpen. Wie RE9.
    local lh_pos = lh_raw
    do
        local dock_pos = rawget(_G, "__vr_slide_hand_world_pos")
        local sblend   = tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0
        if dock_pos and sblend > 0.001 then
            -- [LDOCK_RH 2026-07-03] Dock an die SOLIDE rechte Hand ankern statt ans beim Laufen
            -- einfrierende Slide-Dock. Gemessen: L_Hand trailt 0.24->0.46 m, weil das Dock (Slide-Joint-
            -- Welt) einfriert, waehrend R_Hand die Waffe 1:1 traegt. Offset (Dock relativ R_Hand) NUR bei
            -- ruhiger R_Hand neu merken (throttled) -> waehrend Bewegung gehaltenes Offset an die live
            -- R_Hand kleben => Hand traegt die Waffe mit, kein Trail. Laeuft im Solve = rendert.
            local rh_rot = _G.__vr_rh_joint_rot
            if rh_pos and rh_rot then
                local prev = rawget(_G, "__ldock_rhprev")
                local moved = prev and math.sqrt((rh_pos.x-prev.x)^2 + (rh_pos.y-prev.y)^2 + (rh_pos.z-prev.z)^2) or 999
                _G.__ldock_rhprev = rh_pos
                -- Offset JEDEN Frame neu merken solange R_Hand ~ruhig -> dann rekonstruiert er exakt aufs
                -- Dock, KEIN Snap. NUR bei echter Bewegung (moved>=0.006/Frame) halten -> gegen Trail.
                -- (Der fruehere 0.03s-Throttle war der Flacker-Grund: nur alle 0.03s exakt, dazwischen
                -- rh-relativ gedriftet = ~33Hz-Snap im Stand.)
                if (not rawget(_G, "__ldock_off")) or moved < 0.006 then
                    local inv = safe(function() return rh_rot:inverse() end)
                    local no = inv and safe(function() return inv * Vector3f.new(dock_pos.x-rh_pos.x, dock_pos.y-rh_pos.y, dock_pos.z-rh_pos.z) end)
                    if no then _G.__ldock_off = no end
                end
                local off = rawget(_G, "__ldock_off")
                if off then
                    local wo = quat_rotate_vec3(rh_rot, off)
                    if wo then dock_pos = Vector3f.new(rh_pos.x + wo.x, rh_pos.y + wo.y, rh_pos.z + wo.z) end
                end
            end
            if lh_raw and sblend < 0.999 then
                lh_pos = Vector3f.new(
                    lh_raw.x + (dock_pos.x - lh_raw.x) * sblend,
                    lh_raw.y + (dock_pos.y - lh_raw.y) * sblend,
                    lh_raw.z + (dock_pos.z - lh_raw.z) * sblend)
            else
                lh_pos = dock_pos
            end
            -- [LDOCK_RH] das FERTIG gelerpte L-Ziel veroeffentlichen (nicht das pre-lerp Dock) -> motion
            -- uebernimmt es 1:1 als Hand-Position, OHNE zweiten Lerp. Sonst lerpten motion (von hand_pos)
            -- und arm_chain (von lh_raw) aus verschiedenen Startpunkten -> Flackern beim Ranblenden.
            _G.__vr_ldock_anchored = lh_pos
        end
    end
    if lh_pos then
        apply_arm_ik_side("L", lh_pos, char_rot, nil, root_pose)
        check_autoreset("L", lh_pos)
    end

    -- Repin ganz am Ende: nichts darf die Hand nach dem IK mehr verschieben.
    if rh_pos then repin_hand("R", rh_pos, _G.__vr_rh_joint_rot) end
    if lh_pos then repin_hand("L", lh_pos, _G.__vr_lh_joint_rot) end
end

-- [RESUME_CLAMP] Auch waehrend arm_chain pausiert (Killswitch aktiv) den Hand-Clamp-Anker
-- (root = Schulter-Weltpos, maxreach = Armreichweite) jeden Frame FRISCH veroeffentlichen.
-- motion klemmt seinen Hand-Pin auf diese Globals. Ohne das blieb der Anker sekundenalt
-- (von VOR dem Event, ganz andere Koerperpos) -> im ersten Gameplay-Frame nach dem
-- Killswitch klemmte motion gegen den veralteten Anker -> Hand schnappte ~1-2 m raus
-- (1 Frame), bis arm_chain wieder lief (Diag re4_stretch_diag.log: Spike GENAU im Frame
-- ks=AKTIV->aus). Billig: nur get_Position + Config-Laengen, KEIN IK-Solve. Spiegelt die
-- Live-Publikation in apply_arm_ik_side.
local function publish_clamp_anchors()
    if not hand_clamp then
        _G.__vr_arm_chain_R_root = nil; _G.__vr_arm_chain_R_maxreach = nil
        _G.__vr_arm_chain_L_root = nil; _G.__vr_arm_chain_L_maxreach = nil
        return
    end
    for _, prefix in ipairs({ "R", "L" }) do
        local uj = get_chain_joint(prefix .. "_UpperArm")
        local sw = uj and safe(function() return uj:call("get_Position") end)
        if sw then
            local ul, ll = arm_ik_segment_lengths(nil, nil, nil,
                prefix .. "_UpperArm", prefix .. "_Forearm")
            local maxreach = ul + ll - (shoulder_reach_follow_slack or 0.0)
                + ((shoulder_reach_follow and shoulder_reach_follow_max) or 0.0)
            _G["__vr_arm_chain_" .. prefix .. "_root"] = sw
            _G["__vr_arm_chain_" .. prefix .. "_maxreach"] = maxreach
        end
    end
end

-- [HOOK_ORDER] Phase-Hooks erst im ersten on_frame registrieren: Ausfuehrungs-
-- Reihenfolge pro Entry = Registrierungs-Reihenfolge, und re4_vr_arm_chain laedt
-- alphabetisch VOR re4_vr_motion. Bei Load-Time-Registrierung loest das IK also
-- mit dem Hand-Target der LETZTEN Phase, waehrend motion die Hand danach aufs
-- frische Target pinnt -> Unterarm-Ende haengt beim Laufen/Drehen einen Tick
-- hinter der Hand (Diag: tear ~ Laufgeschwindigkeit, dFore=0). Spaet registriert
-- laufen wir NACH motion und loesen mit dem frischen Target dieser Phase.
-- [RAILCAR_SPINE_PIN] Auf dem Schienenwagen die Torso-Basis pinnen (aus re4_vr_minecart.lua) BEVOR die
-- 2-Bone-IK die Schulter liest -> sonst rechnet sie von der nativen (wippenden) Cart-Pose = Hand flackert.
local function railcar_pin_spine()
    if rawget(_G, "__re4_railcar_mode") ~= true then return end
    if rawget(_G, "__re4_railcar_reloading") == true then return end   -- Reload: native Anim durchlassen
    local f = rawget(_G, "__re4_minecart_apply_spine_pin")
    if f then pcall(f) end
end

local function register_phase_hooks()
    re.on_pre_application_entry("LockScene", function()
        check_cutscene_end()
        if should_pause() then
            _G.__vr_re4_two_bone_ik_active = false
            publish_clamp_anchors()   -- [RESUME_CLAMP] Anker frisch halten -> kein Hand-Snap beim Killswitch-Austritt
            return
        end
        railcar_pin_spine()
        if debug_sync.hook_lockscene then
            apply_body_chain()
        end
    end)

    re.on_application_entry("LateUpdateBehavior", function()
        check_cutscene_end()
        if should_pause() then
            _G.__vr_re4_two_bone_ik_active = false
            publish_clamp_anchors()   -- [RESUME_CLAMP] Anker frisch halten -> kein Hand-Snap beim Killswitch-Austritt
            return
        end
        railcar_pin_spine()
        if debug_sync.hook_lateupdate then
            apply_body_chain()
        end
    end)

    re.on_application_entry("UpdateJointExpression", function()
        check_cutscene_end()
        if should_pause() then
            _G.__vr_re4_two_bone_ik_active = false
            publish_clamp_anchors()   -- [RESUME_CLAMP] Anker frisch halten -> kein Hand-Snap beim Killswitch-Austritt
            return
        end
        railcar_pin_spine()
        if debug_sync.hook_update_jointexpr then
            apply_body_chain()
        end
    end)

    re.on_pre_application_entry("BeginRendering", function()
        check_cutscene_end()
        if should_pause() then
            _G.__vr_re4_two_bone_ik_active = false
            publish_clamp_anchors()   -- [RESUME_CLAMP] Anker frisch halten -> kein Hand-Snap beim Killswitch-Austritt
            return
        end
        railcar_pin_spine()
        if debug_sync.hook_beginrender then
            apply_body_chain()
        end
    end)

end

local phase_hooks_registered = false
re.on_frame(function()
    if not phase_hooks_registered then
        phase_hooks_registered = true
        register_phase_hooks()
    end
end)

-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Arm Chain##re4_vr_arm_chain_root" raus (170 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

local motion_exports = {}
setmetatable(motion_exports, {
    __index = function(t, k)
        if k == "enabled" then return ENABLE_ARM_CHAIN end
        if k == "arm_segment_enabled" then return arm_segment_enabled end
        if k == "chain_offset" then return chain_offset end
        return rawget(t, k)
    end,
    __newindex = function(t, k, v)
        if k == "enabled" then
            ENABLE_ARM_CHAIN = v
            return
        end
        rawset(t, k, v)
    end,
})

function motion_exports.apply(_get_tf, _cache, _safe_call, _safe_call1)
end

motion_exports.load_from_config_bodychain = load_from_config_bodychain
motion_exports.get_save_bodychain = get_save_bodychain
motion_exports.clear_joint_cache = flush_all_arm_caches
motion_exports.upperbody_apply = nil
motion_exports.upperbody_draw_ui = nil

_G.__re4_vr_arm_chain_module = motion_exports
package.loaded["re4_vr_arm_chain"] = motion_exports
return motion_exports
