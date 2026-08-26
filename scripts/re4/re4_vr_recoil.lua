-- PORTED TO C++: src/mods/vr/games/re4/RE4VRRecoil.cpp (kept as reference)
return

-- ============================================================
-- RE4 VR Recoil (aus re4_vr_firstperson.lua ausgelagert, 1:1 Port)
-- * Hookt chainsaw.PlayerCameraController:
-- requestRecoil -> nativen Kamera-Kick skippen, VR-Recoil + Haptik ausloesen
-- updateRecoil -> skippen (HMD)
-- updateHandShake-> skippen (HMD)
-- * Attack-Ramp + Spring-Damper-Sim, Export via _G.vr_recoil
-- (Konsumenten: re4_vr_two_hands_weapons.lua u.a.)
-- * Config: re4_vr/re4_vr_recoil.json — wird beim ersten Lauf aus
-- re4_vr/re4_vr_firstperson.json geseedet (bestehende Tuning-Werte bleiben).
-- * sdk.hooks via _G-Indirektion: Hook-Install einmal pro Game-Session,
-- Bodies werden bei Reset Scripts neu gebunden.
-- ============================================================

if reframework:get_game_name() ~= "re4" then return end

local ok_ks, ks = pcall(function() return require("re4vr/re4_vr_killswitch") end)
if not ok_ks then ks = nil end

local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end

-- ---------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------
local CFG_PATH = "re4_vr/re4_vr_recoil.json"
local SEED_PATH = "re4_vr/re4_vr_firstperson.json"

-- [UI-DIAET 2026-07-31] Im UI leben nur noch: An/Aus, General-Intensity, Per-Waffe-Intensity und
-- der neue Per-Waffe-Support-Wert. Alles andere ist Kurven-/Feel-Kram, der nie pro Spieler getunt wird
-- -> feste Werte hier im Code, NICHT mehr in der JSON (die alten Eintraege werden ignoriert).
-- Zum Nachjustieren einfach hier aendern; die Rechnung selbst ist unveraendert.
local CONFIG = {
    -- ---- die drei UI-Werte (werden gespeichert) ----
    enable_recoil = false,
    recoil_intensity_multiplier = 1.0,   -- globaler Faktor ueber ALLEM (linear)

    -- ---- feste Werte (kein Regler, keine JSON) ----
    recoil_position_intensity = 0.008,   -- Stoss geradlinig: zurueck (z) + leicht hoch (y), in m
    recoil_rotation_intensity = 0.055,   -- Hochkippen (Pitch) in rad -- der eigentliche Recoil
    recoil_horizontal_spread  = 0.024,   -- Zufalls-Yaw pro Schuss (+/-), rad: seitliches Ausbrechen
    recoil_vertical_spread    = 0.016,   -- Zufalls-Pitch pro Schuss (+/-), rad: nicht jeder Schuss gleich
    recoil_randomness         = 0.35,    -- Zufall auf die Gesamtstaerke (0.35 = +/-17.5%)
    recoil_mult_exponent      = 0.35,    -- staucht den Waffen-Multiplikator (mult^0.35): 3x kickt nicht 3x
    recoil_stack_cap          = 2.0,     -- Dauerfeuer-Deckel: aufaddierte Kicks max. 2x Peak
    recoil_spring_stiffness   = 120.0,   -- Rueckholfeder k: hoeher = schneller zurueck in die Ruhelage
    recoil_spring_damping     = 18.0,    -- Daempfung c: niedriger = mehr Nachwippen
    recoil_attack_duration    = 0.022,   -- Anstiegszeit bis zum Peak (s), danach uebernimmt die Feder
    recoil_auto_scale         = 0.15,    -- Vollautomaten (WEAPON_AUTO_FLAGS) nur 15% pro Schuss
    recoil_sustained_damping  = 28.0,    -- Daempfung waehrend einer Salve (gegen Aufschaukeln)
    recoil_sustained_window   = 0.12,    -- Schussabstand (s), unter dem eine Salve erkannt wird
    recoil_supported_impulse_mult = 0.70,-- [2026-07-31] Stuetzhand dran -> Kick faellt auf 70 %
    recoil_unsupported_light_mult = 1.18,-- einhaendig, leichte Waffe
    recoil_unsupported_heavy_mult = 1.90,-- einhaendig, schwere Waffe (Basis-Mult >= 2.0)
    -- [VIBRATION ENTFERNT] Schuss-Haptik laeuft jetzt separat in re4_vr_haptic.lua.
}

local weapon_intensity_overrides = {}
-- [SUPPORT_PER_WEAPON 2026-07-31] Pro Waffe: auf wie viel faellt der Recoil, sobald die linke
-- (Stuetz-)Hand an der Waffe ist. 0.55 = 55% des Kicks. Kein Eintrag -> CONFIG.recoil_supported_impulse_mult.
local weapon_support_overrides = {}

-- [UI-DIAET 2026-07-31] Nur noch diese beiden werden geladen/gespeichert -- alles andere sind feste
-- Code-Werte. Alte JSONs mit den ausgemusterten Schluesseln stoeren nicht, sie werden schlicht ignoriert.
local CONFIG_KEYS = { "enable_recoil", "recoil_intensity_multiplier" }

local function apply_config_table(data)
    if type(data) ~= "table" then return false end
    local found = false
    for _, k in ipairs(CONFIG_KEYS) do
        if data[k] ~= nil then
            CONFIG[k] = data[k]
            found = true
        end
    end
    if type(data.weapon_intensity_overrides) == "table" then
        for k, v in pairs(data.weapon_intensity_overrides) do
            if type(v) == "number" then weapon_intensity_overrides[k] = v end
        end
        found = true
    end
    if type(data.weapon_support_overrides) == "table" then   -- [SUPPORT_PER_WEAPON]
        for k, v in pairs(data.weapon_support_overrides) do
            if type(v) == "number" then weapon_support_overrides[k] = v end
        end
        found = true
    end
    return found
end

local function save_config()
    local out = {}
    for _, k in ipairs(CONFIG_KEYS) do out[k] = CONFIG[k] end
    out.weapon_intensity_overrides = weapon_intensity_overrides
    out.weapon_support_overrides   = weapon_support_overrides   -- [SUPPORT_PER_WEAPON]
    pcall(function() json.dump_file(CFG_PATH, out) end)
end

local function load_config()
    local d = safe(function() return json.load_file(CFG_PATH) end)
    if type(d) == "table" then
        apply_config_table(d)
        return
    end
    -- Erster Lauf: Tuning aus der alten firstperson-JSON uebernehmen
    local seed = safe(function() return json.load_file(SEED_PATH) end)
    if apply_config_table(seed) then
        save_config()
    end
end

load_config()

-- ---------------------------------------------------------------------
-- Waffen-Multiplikatoren (1:1 aus dem alten firstperson)
-- ---------------------------------------------------------------------
local WEAPON_RECOIL_MULTIPLIERS = {
    [4000] = 1.2, [4001] = 1.2, [4002] = 1.2, [4003] = 1.2, [4004] = 1.2, [4005] = 1.4,
    [4100] = 1.8, [4101] = 1.8, [4102] = 1.8,
    [4200] = 1.5, [4201] = 1.5, [4202] = 1.5,
    [4400] = 1.8, [4401] = 1.8, [4402] = 1.8,
    [4500] = 2.0, [4501] = 2.0, [4502] = 2.0,
    [4600] = 1.8,
    [4900] = 2.5, [4901] = 2.5, [4902] = 2.5,
    [6000] = 1.2, [6001] = 1.2,
    [6100] = 1.2, [6101] = 1.2, [6102] = 1.2, [6103] = 1.2, [6104] = 1.2, [6105] = 1.8,
    [6106] = 1.2, [6107] = 0.0, [6108] = 0.0, [6111] = 1.2, [6112] = 1.2, [6113] = 1.2, [6114] = 1.8,
    [6300] = 1.2, [6301] = 1.2, [6302] = 1.2, [6304] = 1.2, [6305] = 1.2,
}

local WEAPON_AUTO_FLAGS = {
    [4005] = true, [4200] = true, [4201] = true, [4202] = true, [4402] = true,
}

local WEAPON_ID_CATALOG_SORTED = nil
local function build_weapon_id_catalog_sorted()
    if WEAPON_ID_CATALOG_SORTED then return end
    local t = {}
    for wid, _ in pairs(WEAPON_RECOIL_MULTIPLIERS) do
        if type(wid) == "number" then t[#t + 1] = wid end
    end
    table.sort(t)
    WEAPON_ID_CATALOG_SORTED = t
end

-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: einmal pro Frame aufloesen statt bei
-- jedem Aufruf. Semantik unveraendert, alter Weg bleibt als Fallback. NOT-AUS: `_G.__re4_fc_off = true`.
pcall(function() require("re4vr/re4_vr_frame_cache") end)

local function get_current_weapon_id()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.equip_wid() end
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    if not cm then return nil end
    local ctx = safe(function() return cm:call("getPlayerContextRef") end)
    if not ctx then return nil end
    local hu = safe(function() return ctx:call("get_HeadUpdater") end)
    if not hu then return nil end
    local wid = safe(function() return hu:call("get_EquipWeaponID") end)
    if wid == nil then return nil end
    if type(wid) == "userdata" then
        local value = safe(function() return wid:get_field("value__") end)
        if type(value) == "number" then return value end
    end
    return type(wid) == "number" and wid or nil
end

local function weapon_key_from_id(wid)
    if not wid then return nil end
    return string.format("wp%04d", wid)
end

local function get_effective_weapon_recoil_multiplier()
    local wid = get_current_weapon_id()
    local base = (wid and (WEAPON_RECOIL_MULTIPLIERS[wid] or 1.0)) or 1.0
    local key = weapon_key_from_id(wid)
    local per = (key and weapon_intensity_overrides[key]) or 1.0
    local g = tonumber(CONFIG.recoil_intensity_multiplier) or 1.0
    return base * g * per, base, per, g, key
end

-- ---------------------------------------------------------------------
-- FP-Gate (Port von should_fp_be_active, ohne Stage-Overrides/Scope)
-- ---------------------------------------------------------------------
local function fp_active()
    if not ks or not ks.is_active then return true end
    local ok, act = pcall(ks.is_active)
    if not ok or not act then return true end
    -- Killswitch aktiv: FP-Recoil nur in Reload-/FP-Aktionen behalten
    if ks.is_reload_active then
        local o, v = pcall(ks.is_reload_active)
        if o and v then return true end
    end
    if ks.is_first_person_action_active then
        local o, v = pcall(ks.is_first_person_action_active)
        if o and v then return true end
    end
    if ks.is_first_person_animation_active then
        local o, v = pcall(ks.is_first_person_animation_active)
        if o and v then return true end
    end
    return false
end

local function hmd_active()
    if vrmod == nil or vrmod.is_hmd_active == nil then return false end
    local ok, active = pcall(function() return vrmod:is_hmd_active() end)
    return ok and active == true
end

-- ---------------------------------------------------------------------
-- State + Export
-- ---------------------------------------------------------------------
local state = {
    recoil_attack_active = false,
    recoil_attack_t      = 0.0,
    recoil_attack_pos_y  = 0.0,
    recoil_attack_pos_z  = 0.0,
    recoil_attack_pitch  = 0.0,
    recoil_attack_yaw    = 0.0,
    recoil_last_t      = nil,
    recoil_last_shot_t = nil,
    recoil_active  = false,

    spring_pos_y = 0.0, spring_pos_z = 0.0,
    spring_pitch = 0.0, spring_yaw   = 0.0,
    spring_vel_y = 0.0, spring_vel_z = 0.0,
    spring_vel_pitch = 0.0, spring_vel_yaw = 0.0,
}

_G.vr_recoil = _G.vr_recoil or {
    position = Vector3f.new(0, 0, 0),
    rotation = Quaternion.identity(),
    active = false,
}

-- ---------------------------------------------------------------------
-- Hook-Bodies (1:1 Port)
-- ---------------------------------------------------------------------
local function on_pre_request_recoil(args)
    -- HMD VR: nativen requestRecoil nie Kamera-Impulse queuen lassen
    if hmd_active() then
        if fp_active() then
            goto request_recoil_fp_body
        end
        return sdk.PreHookResult.SKIP_ORIGINAL
    end

    if not fp_active() then return end

    ::request_recoil_fp_body::

    local weapon_multiplier, weapon_base_mult = get_effective_weapon_recoil_multiplier()

    -- [Schuss-Haptik entfernt -> laeuft jetzt in re4_vr_haptic.lua]

    if CONFIG.enable_recoil then
        if weapon_multiplier <= 0.0 then
            return sdk.PreHookResult.SKIP_ORIGINAL
        end

        pcall(function()
            local random_factor = 1.0 + (math.random() - 0.5) * CONFIG.recoil_randomness
            local exp = math.max(0.1, math.min(1.0, CONFIG.recoil_mult_exponent))
            local total_mult = (weapon_multiplier ^ exp) * random_factor

            local support_hand_active = false
            if _G.__vr_support_hand_docked ~= nil then
                support_hand_active = _G.__vr_support_hand_docked == true
            elseif _G.__vr_support_blend_factor ~= nil then
                support_hand_active = _G.__vr_support_blend_factor > 0.5
            end

            if support_hand_active then
                -- [SUPPORT_PER_WEAPON 2026-07-31] Wie stark die Stuetzhand die Waffe beruhigt, ist
                -- pro Waffe einstellbar (Slider in %). Kein Eintrag -> globaler Default.
                local skey = weapon_key_from_id(get_current_weapon_id())
                local sm = (skey and tonumber(weapon_support_overrides[skey]))
                        or tonumber(CONFIG.recoil_supported_impulse_mult) or 0.55
                if sm > 0.0 then total_mult = total_mult * sm end
            else
                local heavy = (weapon_base_mult or 1.0) >= 2.0
                local um = heavy and (tonumber(CONFIG.recoil_unsupported_heavy_mult) or 1.9)
                              or (tonumber(CONFIG.recoil_unsupported_light_mult) or 1.18)
                if um > 0.0 then total_mult = total_mult * um end
            end

            local wid_auto = get_current_weapon_id()
            if wid_auto and WEAPON_AUTO_FLAGS[wid_auto] then
                total_mult = total_mult * math.max(0.05, CONFIG.recoil_auto_scale)
            end

            local pos_peak = CONFIG.recoil_position_intensity * total_mult
            local new_pos_y =  pos_peak * 0.6
            local new_pos_z = -pos_peak

            local pitch_peak = CONFIG.recoil_rotation_intensity * total_mult
                             + (math.random() - 0.5) * CONFIG.recoil_vertical_spread * total_mult
            local yaw_peak   = (math.random() - 0.5) * 2.0
                             * CONFIG.recoil_horizontal_spread * total_mult

            state.recoil_attack_pos_y = state.recoil_attack_pos_y + new_pos_y
            state.recoil_attack_pos_z = state.recoil_attack_pos_z + new_pos_z
            state.recoil_attack_pitch = state.recoil_attack_pitch + pitch_peak
            state.recoil_attack_yaw   = state.recoil_attack_yaw   + yaw_peak

            -- [RECOIL-DIAG] flush-sicher pro Schuss: feuert der Hook ueberhaupt + wie gross sind die Peaks?
            -- [log entfernt]

            if CONFIG.recoil_stack_cap > 0.0 then
                -- [CAP-FIX 2026-07-31, "per-Waffe-Intensity aendert NICHTS"] Der Deckel wurde aus den
                -- BASIS-Intensitaeten gerechnet, also ohne den Waffen-Multiplikator -> ein absoluter Anschlag
                -- (0.11 rad Pitch). Sobald total_mult >= stack_cap war, landete JEDE Einstellung auf exakt
                -- demselben gekappten Wert und der Per-Waffe-Slider tat nichts. Gemeint war (Kommentar oben)
                -- ein DAUERFEUER-Deckel: aufaddierte Kicks max. stack_cap x dem Peak DIESES Schusses.
                local cap_pos = CONFIG.recoil_position_intensity * total_mult * CONFIG.recoil_stack_cap
                local cap_rot = CONFIG.recoil_rotation_intensity * total_mult * CONFIG.recoil_stack_cap
                local cap_yaw = CONFIG.recoil_horizontal_spread  * total_mult * CONFIG.recoil_stack_cap
                state.recoil_attack_pos_y = math.min( state.recoil_attack_pos_y,  cap_pos * 0.6)
                state.recoil_attack_pos_z = math.max( state.recoil_attack_pos_z, -cap_pos)
                state.recoil_attack_pitch = math.min( state.recoil_attack_pitch,  cap_rot)
                if state.recoil_attack_yaw >  cap_yaw then state.recoil_attack_yaw =  cap_yaw end
                if state.recoil_attack_yaw < -cap_yaw then state.recoil_attack_yaw = -cap_yaw end
            end

            state.recoil_attack_t      = 0.0
            state.recoil_attack_active = true
            state.recoil_active        = true
            local now_shot = os.clock()
            if not state.recoil_last_t then
                state.recoil_last_t = now_shot
            end
            state.recoil_last_shot_t = now_shot
        end)
    end

    return sdk.PreHookResult.SKIP_ORIGINAL
end

local function on_pre_update_recoil(args)
    if hmd_active() then
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
    if not fp_active() then return end
    return sdk.PreHookResult.SKIP_ORIGINAL
end

local function on_pre_update_handshake(args)
    if hmd_active() then
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
    if not fp_active() then return end
    return sdk.PreHookResult.SKIP_ORIGINAL
end

-- Bodies bei jedem (Re-)Load neu binden — die sdk.hooks rufen ueber _G rein.
_G.__re4_vr_recoil_on_request   = on_pre_request_recoil
_G.__re4_vr_recoil_on_update    = on_pre_update_recoil
_G.__re4_vr_recoil_on_handshake = on_pre_update_handshake

-- Hooks nur einmal pro Game-Session installieren
if not _G.__re4_vr_recoil_hooks_installed then
    local pcc_t = sdk.find_type_definition("chainsaw.PlayerCameraController")
    if pcc_t then
        local request_recoil = pcc_t:get_method("requestRecoil(chainsaw.CameraRecoilParam)")
        if request_recoil then
            sdk.hook(request_recoil,
                function(args)
                    local f = _G.__re4_vr_recoil_on_request
                    if f then return f(args) end
                end,
                function(retval) return retval end)
        end

        local update_recoil = pcc_t:get_method("updateRecoil")
        if update_recoil then
            sdk.hook(update_recoil,
                function(args)
                    local f = _G.__re4_vr_recoil_on_update
                    if f then return f(args) end
                end,
                function(retval) return retval end)
        end

        local update_handshake = pcc_t:get_method("updateHandShake")
        if update_handshake then
            sdk.hook(update_handshake,
                function(args)
                    local f = _G.__re4_vr_recoil_on_handshake
                    if f then return f(args) end
                end,
                function(retval) return retval end)
        end

        _G.__re4_vr_recoil_hooks_installed = true
    else
    end
end

-- ---------------------------------------------------------------------
-- Spring-Sim + Export (1:1 Port, einmal pro Frame)
-- ---------------------------------------------------------------------
local function update_spring_and_export()
    if state.recoil_active or state.recoil_attack_active then
        local now = os.clock()
        local dt  = 0.0
        if state.recoil_last_t then
            dt = math.min(now - state.recoil_last_t, 0.05)
        end
        state.recoil_last_t = now

        if state.recoil_attack_active and dt > 0.0 then
            local T = math.max(CONFIG.recoil_attack_duration, 0.001)
            state.recoil_attack_t = state.recoil_attack_t + dt

            if state.recoil_attack_t >= T then
                state.spring_pos_y    = state.recoil_attack_pos_y
                state.spring_pos_z    = state.recoil_attack_pos_z
                state.spring_pitch    = state.recoil_attack_pitch
                state.spring_yaw      = state.recoil_attack_yaw
                state.spring_vel_y    = 0.0
                state.spring_vel_z    = 0.0
                state.spring_vel_pitch = 0.0
                state.spring_vel_yaw   = 0.0
                state.recoil_attack_pos_y  = 0.0
                state.recoil_attack_pos_z  = 0.0
                state.recoil_attack_pitch  = 0.0
                state.recoil_attack_yaw    = 0.0
                state.recoil_attack_t      = 0.0
                state.recoil_attack_active = false
            else
                local s = math.sin((state.recoil_attack_t / T) * (math.pi * 0.5))
                state.spring_pos_y  = state.recoil_attack_pos_y * s
                state.spring_pos_z  = state.recoil_attack_pos_z * s
                state.spring_pitch  = state.recoil_attack_pitch * s
                state.spring_yaw    = state.recoil_attack_yaw   * s
                state.spring_vel_y    = 0.0
                state.spring_vel_z    = 0.0
                state.spring_vel_pitch = 0.0
                state.spring_vel_yaw   = 0.0
            end
        end

        if not state.recoil_attack_active and dt > 0.0 then
            local k = CONFIG.recoil_spring_stiffness
            local c = CONFIG.recoil_spring_damping
            if state.recoil_last_shot_t then
                local since_last = now - state.recoil_last_shot_t
                local win = math.max(0.01, CONFIG.recoil_sustained_window)
                if since_last < win then
                    local t_blend = 1.0 - (since_last / win)
                    c = c + (CONFIG.recoil_sustained_damping - c) * t_blend
                end
            end
            local steps = math.max(1, math.floor(dt / 0.008))
            local sub   = dt / steps

            for _ = 1, steps do
                local ay = -k * state.spring_pos_y - c * state.spring_vel_y
                state.spring_vel_y = state.spring_vel_y + ay * sub
                state.spring_pos_y = state.spring_pos_y + state.spring_vel_y * sub

                local az = -k * state.spring_pos_z - c * state.spring_vel_z
                state.spring_vel_z = state.spring_vel_z + az * sub
                state.spring_pos_z = state.spring_pos_z + state.spring_vel_z * sub

                local ap = -k * state.spring_pitch - c * state.spring_vel_pitch
                state.spring_vel_pitch = state.spring_vel_pitch + ap * sub
                state.spring_pitch     = state.spring_pitch     + state.spring_vel_pitch * sub

                local aw = -k * state.spring_yaw - c * state.spring_vel_yaw
                state.spring_vel_yaw = state.spring_vel_yaw + aw * sub
                state.spring_yaw     = state.spring_yaw     + state.spring_vel_yaw * sub
            end

            local pos_mag = math.abs(state.spring_pos_y) + math.abs(state.spring_pos_z)
            local rot_mag = math.abs(state.spring_pitch)  + math.abs(state.spring_yaw)
            local vel_mag = math.abs(state.spring_vel_y)  + math.abs(state.spring_vel_z)
                          + math.abs(state.spring_vel_pitch) + math.abs(state.spring_vel_yaw)

            if pos_mag < 0.00005 and rot_mag < 0.0002 and vel_mag < 0.001 then
                state.spring_pos_y    = 0.0; state.spring_pos_z    = 0.0
                state.spring_vel_y    = 0.0; state.spring_vel_z    = 0.0
                state.spring_pitch    = 0.0; state.spring_yaw      = 0.0
                state.spring_vel_pitch = 0.0; state.spring_vel_yaw = 0.0
                state.recoil_active   = false
                state.recoil_last_t   = nil
            end
        end
    end

    if CONFIG.enable_recoil and (state.recoil_active or state.recoil_attack_active) then
        _G.vr_recoil.position = Vector3f.new(0.0, state.spring_pos_y, state.spring_pos_z)

        -- [RECOIL Y-DOMINANT] Pitch (Muendung kippt hoch) ist der Haupt-Recoil -> verstaerkt.
        -- Das * 0.5 ist die Quaternion-Half-Angle-Konvention (NICHT antasten); PITCH_KICK_GAIN
        -- multipliziert den Winkel VOR der Half-Angle-Bildung. Zusammen mit KICK_BACK=1.0 in
        -- re4_vr_motion.lua dominiert damit das Hochkippen, der z-Rueckstoss bleibt dezent.
        local PITCH_KICK_GAIN = 2.0
        local ph = -(state.spring_pitch * PITCH_KICK_GAIN) * 0.5
        local yw =  state.spring_yaw   * 0.5
        local pitch_q = Quaternion.new(math.cos(ph), math.sin(ph), 0.0,          0.0)
        local yaw_q   = Quaternion.new(math.cos(yw), 0.0,          math.sin(yw), 0.0)
        local ok, rq  = pcall(function() return (pitch_q * yaw_q):normalized() end)
        _G.vr_recoil.rotation = (ok and rq) or Quaternion.identity()
        _G.vr_recoil.active   = true
    else
        _G.vr_recoil.position = Vector3f.new(0, 0, 0)
        _G.vr_recoil.rotation = Quaternion.identity()
        _G.vr_recoil.active   = false
    end
end

re.on_application_entry("LateUpdateBehavior", update_spring_and_export)

-- ---------------------------------------------------------------------
-- =====================================================================
-- [PUBLIC-UI 2026-07-23] Statt des Sliders "General Weapon Intensity" drei feste Stufen im
-- nackten Hauptmenue. [STUFEN 2026-07-31] OFF / Mid / Max = 0.00 / 0.75 / 1.50 -- nach dem
-- Cap-Fix schlagen die Multiplikatoren voll durch, die alten 1.00/3.00 waren dafuer zu hoch.
-- Geschrieben wird exakt dasselbe Feld
-- (CONFIG.recoil_intensity_multiplier) mit demselben save_config -- der Regler gilt global fuer
-- ALLE Waffen (Faktor `g` in base * g * per), OFF schaltet den Rueckstoss komplett ab.
-- Steht bewusst VOR dem Haptik-Teil dieser Datei: dort wird ein zweites lokales save_config
-- deklariert, das ab dort das erste verdeckt.
-- Beim Release fliegen alle [DEV-UI]-Bloecke raus, dieser bleibt.
-- =====================================================================
do
    local draw = function()
        local steps = { { "OFF", 0.0 }, { "Mid", 0.75 }, { "Max", 1.50 } }
        local cur = tonumber(CONFIG.recoil_intensity_multiplier) or 1.0
        imgui.text("Recoil:")
        for i, s in ipairs(steps) do
            imgui.same_line()
            local active = math.abs(cur - s[2]) < 0.001
            if active then imgui.push_style_color(0, 0xFFD0E040) end
            if imgui.button(s[1] .. "##recoilpublic") then
                CONFIG.recoil_intensity_multiplier = s[2]
                save_config()
            end
            if active then imgui.pop_style_color(1) end
        end
    end
    -- Reihenfolge zentral ueber #re4_vr_menu.lua (Platz 50); ohne Dispatcher eigener Callback.
    local add = rawget(_G, "__re4_ui_add")
    if type(add) == "function" then add(50, "recoil_level", draw) else re.on_draw_ui(draw) end
end

-- [DEV-UI] UI (1:1 Port der Recoil-/Vibration-Sektion)
-- ---------------------------------------------------------------------
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Recoil & Haptic" raus (121 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.


-- ==================== >>> re4_vr_haptic.lua (Sub-Tree unter "RE4VR - Recoil & Haptic") <<< ====================
-- [SCHUSS-HAPTIK] Pro Schuss ein Haptik-Puls. Rechts immer (solo 100% / mit Support 70%),
-- links nur bei angedockter Support-Hand (30%). Trigger = _G.__vr_shot_seq (crosshair.lua).
-- In IIFE gekapselt -> eigenes 200-Local-Budget, Locals isoliert von recoil.
;(function()

local CFG = {
    enabled       = true,
    amp_solo      = 1.00,   -- rechte Hand ALLEIN (keine Support-Hand): volle Pulle
    amp_right_sup = 0.70,   -- rechte Hand WENN Support-Hand mitmacht: 70%
    amp_left_sup  = 0.30,   -- linke Hand (Support): 30%
    dur           = 0.05,   -- s pro Puls (kurz+knackig -> bei SMG-Rate bleiben Pulse getrennt)
    freq          = 180.0,  -- Hz (scharfer "Knack", kein tiefes Wummern)
    delay         = 0.00,   -- s: Puls kommt so lange NACH dem Schuss (0 = sofort)
}

-- ---- Persistenz -------------------------------------------------------------
local CFG_PATH = "re4_vr/re4_vr_haptic.json"
local CFG_KEYS = { "enabled", "amp_solo", "amp_right_sup", "amp_left_sup", "dur", "freq", "delay" }
local function save_config()
    local out = {}
    for _, k in ipairs(CFG_KEYS) do out[k] = CFG[k] end
    pcall(function() json.dump_file(CFG_PATH, out) end)
end
local function load_config()
    local d = nil
    pcall(function() d = json.load_file(CFG_PATH) end)
    if type(d) == "table" then
        for _, k in ipairs(CFG_KEYS) do if d[k] ~= nil then CFG[k] = d[k] end end
    end
end
load_config()

local last_seq = nil
local pending  = {}   -- geplante (verzoegerte) Pulse: je { at = clock-Zeit, support = bool }

local function do_pulse(handle, amp)
    if not handle or amp <= 0.0 then return end
    pcall(function() vrmod:trigger_haptic_vibration(0.0, CFG.dur, CFG.freq, amp, handle) end)
end

-- Einen Schuss-Puls JETZT abfeuern (support = ob Support-Hand beim Schuss an der Waffe war).
local function fire(support)
    local rj = nil
    pcall(function() rj = vrmod:get_right_joystick() end)
    do_pulse(rj, support and CFG.amp_right_sup or CFG.amp_solo)
    if support then
        local lj = nil
        pcall(function() lj = vrmod:get_left_joystick() end)
        do_pulse(lj, CFG.amp_left_sup)
    end
end

re.on_frame(function()
    -- [KS_GLOBAL 2026-07-15] War nur __re4_ks4_active (= nur der Kick). Jetzt JEDER Killswitch: Recoil und
    -- Haptik haben in KS1/2/3/4/5 nichts verloren. Global statt require, weil das hier keinen der knappen
    -- Top-Level-Locals kostet. __re4_ks_active ist bei KS4 ebenfalls true -> deckt den alten Fall mit ab.
    if rawget(_G, "__re4_ks_active") == true then return end
    if not CFG.enabled then return end
    if not vrmod or not vrmod:is_hmd_active() then return end
    local now = os.clock()

    -- [DELAY] faellige geplante Pulse abfeuern
    if #pending > 0 then
        local i = 1
        while i <= #pending do
            if now >= pending[i].at then
                fire(pending[i].support)
                table.remove(pending, i)
            else
                i = i + 1
            end
        end
    end

    -- Schuss-Flanke erkennen
    local seq = tonumber(rawget(_G, "__vr_shot_seq")) or 0
    if last_seq == nil then last_seq = seq; return end   -- erster Frame: nur Baseline, NICHT feuern
    if seq <= last_seq then return end                   -- kein neuer Schuss
    last_seq = seq

    local support = (rawget(_G, "__vr_support_hand_docked") == true)
    if (CFG.delay or 0) <= 0.0 then
        fire(support)                                    -- sofort
    else
        pending[#pending + 1] = { at = now + CFG.delay, support = support }   -- verzoegert
    end
end)

-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "Schuss-Haptik" raus (15 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

end)()

-- ---- [CLOSER] schliesst den Parent-Tree "RE4VR - Recoil & Haptic" nachdem der Haptik-Sub-Tree rendert ----
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree (Closer) raus (3 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.
