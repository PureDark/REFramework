-- Builtin implementation: src/mods/vr/games/re4/RE4VRAudio.cpp
return

local send_request_td = sdk.find_type_definition("via.simplewwise.SendRequest")
local driver_td = sdk.find_type_definition("via.simplewwise.Driver")

-- Killswitch: in Cutscenes Listener-Orientierung der Engine ueberlassen
local ok_ks, killswitch = pcall(function() return require("re4vr/re4_vr_killswitch") end)
if not ok_ks then killswitch = nil end

local function is_ks_active()
    if killswitch and killswitch.is_active then
        local ok, v = pcall(killswitch.is_active)
        return ok and v == true
    end
    return false
end

local cfg = {
    enabled = true,
    use_full_hmd = true,
    negate_fwd_x = false,
    negate_fwd_y = false,
    negate_fwd_z = true,
    negate_up_x = false,
    negate_up_y = false,
    negate_up_z = false,
    swap_fwd_xz = false,
    swap_fwd_xy = false,
    swap_up_xz = false,
    swap_up_xy = false,
    swap_fwd_up = false,
}

local last_fwd = nil
local last_up = nil
local last_yaw_deg = 0
local last_pitch_deg = 0
local last_roll_deg = 0
local hook_count = 0

local function get_hmd_full_rotation()
    if not vrmod or not vrmod:is_hmd_active() then return nil end
    local t0 = vrmod:get_transform(0)
    if not t0 then return nil end
    local hmd_quat = t0:to_quat()
    local rot_offset = vrmod:get_rotation_offset()
    local combined = rot_offset * hmd_quat

    local siny = 2.0 * (combined.w * combined.y + combined.z * combined.x)
    local cosy = 1.0 - 2.0 * (combined.y * combined.y + combined.x * combined.x)
    last_yaw_deg = math.deg(math.atan(siny, cosy))

    local sinp = 2.0 * (combined.w * combined.x - combined.y * combined.z)
    if math.abs(sinp) >= 1.0 then
        last_pitch_deg = math.deg(math.pi * 0.5) * (sinp > 0 and 1 or -1)
    else
        last_pitch_deg = math.deg(math.asin(sinp))
    end

    local sinr = 2.0 * (combined.w * combined.z + combined.x * combined.y)
    local cosr = 1.0 - 2.0 * (combined.z * combined.z + combined.x * combined.x)
    last_roll_deg = math.deg(math.atan(sinr, cosr))

    return combined
end

local function get_hmd_yaw_flat()
    if not vrmod or not vrmod:is_hmd_active() then return nil end
    local t0 = vrmod:get_transform(0)
    if not t0 then return nil end
    local hmd_quat = t0:to_quat()
    local rot_offset = vrmod:get_rotation_offset()
    local combined = rot_offset * hmd_quat

    local siny = 2.0 * (combined.w * combined.y + combined.z * combined.x)
    local cosy = 1.0 - 2.0 * (combined.y * combined.y + combined.x * combined.x)
    local hmd_yaw = math.atan(siny, cosy)

    last_yaw_deg = math.deg(hmd_yaw)
    last_pitch_deg = 0
    last_roll_deg = 0

    local half = hmd_yaw * 0.5
    return Quaternion.new(math.cos(half), 0, math.sin(half), 0)
end

local function get_game_camera_rotation()
    local cam_sys = sdk.get_managed_singleton("chainsaw.CameraSystem")
    if not cam_sys then return nil end
    local ok, ctrl = pcall(cam_sys.call, cam_sys, "get_MainCameraController")
    if not ok or not ctrl then return nil end
    local ok2, rot = pcall(ctrl.call, ctrl, "get_CameraRotation")
    if not ok2 or not rot then return nil end
    return rot
end

local function quat_to_vectors(q)
    local fx = 2.0 * (q.x * q.z + q.w * q.y)
    local fy = 2.0 * (q.y * q.z - q.w * q.x)
    local fz = 1.0 - 2.0 * (q.x * q.x + q.y * q.y)

    local ux = 2.0 * (q.x * q.y - q.w * q.z)
    local uy = 1.0 - 2.0 * (q.x * q.x + q.z * q.z)
    local uz = 2.0 * (q.y * q.z + q.w * q.x)

    if cfg.swap_fwd_xz then fx, fz = fz, fx end
    if cfg.swap_fwd_xy then fx, fy = fy, fx end
    if cfg.swap_up_xz then ux, uz = uz, ux end
    if cfg.swap_up_xy then ux, uy = uy, ux end

    if cfg.negate_fwd_x then fx = -fx end
    if cfg.negate_fwd_y then fy = -fy end
    if cfg.negate_fwd_z then fz = -fz end
    if cfg.negate_up_x then ux = -ux end
    if cfg.negate_up_y then uy = -uy end
    if cfg.negate_up_z then uz = -uz end

    local forward = Vector3f.new(fx, fy, fz)
    local up = Vector3f.new(ux, uy, uz)

    if cfg.swap_fwd_up then
        forward, up = up, forward
    end

    return forward, up
end

local cached_forward = nil
local cached_up = nil
local cached_frame = -1

local function compute_hmd_orientation()
    local frame = re.get_frame_count and re.get_frame_count() or 0
    if frame == cached_frame and cached_forward then
        return cached_forward, cached_up
    end

    local cam_rot = get_game_camera_rotation()
    if not cam_rot then return nil, nil end

    local hmd_rot
    if cfg.use_full_hmd then
        hmd_rot = get_hmd_full_rotation()
    else
        hmd_rot = get_hmd_yaw_flat()
    end
    if not hmd_rot then return nil, nil end

    local combined = cam_rot * hmd_rot
    local fwd, up = quat_to_vectors(combined)

    cached_forward = fwd
    cached_up = up
    cached_frame = frame

    return fwd, up
end

if send_request_td then
    local set_method = send_request_td:get_method("setListenerPosition")
    if set_method then
        sdk.hook(
            set_method,
            function(args)
                if not cfg.enabled then return end
                if is_ks_active() then return end

                local fwd, up = compute_hmd_orientation()
                if not fwd or not up then return end

                last_fwd = fwd
                last_up = up
                hook_count = hook_count + 1

                if args[5] then
                    sdk.set_native_field(args[5], sdk.find_type_definition("via.vec3"), "x", fwd.x)
                    sdk.set_native_field(args[5], sdk.find_type_definition("via.vec3"), "y", fwd.y)
                    sdk.set_native_field(args[5], sdk.find_type_definition("via.vec3"), "z", fwd.z)
                end

                if args[6] then
                    sdk.set_native_field(args[6], sdk.find_type_definition("via.vec3"), "x", up.x)
                    sdk.set_native_field(args[6], sdk.find_type_definition("via.vec3"), "y", up.y)
                    sdk.set_native_field(args[6], sdk.find_type_definition("via.vec3"), "z", up.z)
                end
            end,
            function(retval)
                return retval
            end
        )
    else
        re.on_application_entry("UpdateAudioRender", function()
            if not cfg.enabled then return end
            if is_ks_active() then return end

            local fwd, up = compute_hmd_orientation()
            if not fwd or not up then return end

            last_fwd = fwd
            last_up = up
            hook_count = hook_count + 1

            local drv = sdk.get_native_singleton("via.simplewwise.Driver")
            if not drv or not driver_td then return end
            local ok, pos = pcall(sdk.call_native_func, drv, driver_td, "getListenerPosition", 0)
            if not ok or not pos then return end

            local send_req = sdk.get_native_singleton("via.simplewwise.SendRequest")
            if not send_req then return end

            pcall(sdk.call_native_func,
                send_req, send_request_td,
                "setListenerPosition",
                0, Vector3f.new(pos.x, pos.y, pos.z), fwd, up
            )
        end)
    end
end

-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Audio" raus (54 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.
