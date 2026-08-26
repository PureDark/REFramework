-- PORTED TO C++: src/mods/vr/games/re4/RE4VRCrosshair.cpp (kept as reference)
return

-- ============================================================
-- RE4 VR Crosshair (v4 — schlank: Engine-Laser + Reticle-Dot + Bullet-Hook)
-- * Muzzle direkt vom Muzzle-Joint (Waffe haengt via motion an der VR-Hand)
-- * Async-Raycast -> Strahllaenge / Trefferpunkt
-- * Laser: native Line des LaserSightController im updateLaser-POST-Hook
-- LOKAL auf den VR-Strahl gesetzt (Parent wird nach uns bewegt)
-- * End-Dot: Engine-GUI-Reticle Gui_ui2040 im Welt-Raum an den Hit-Punkt
-- (gleiche Frame, kein Lag). Der native EPV-Glow der Light-GO sampelt
-- zu frueh (Yaw-Lag, unschlagbar) -> wird ausgeblendet.
-- * Bullet-Hook: Kugeln/Rocket spawnen an VR-Muzzle in VR-Richtung
-- Exporte: _G.is_aim, _G.is_reticle_displayed, _G._IsWeaponChanging,
-- re4.last_muzzle_*, re4.crosshair_*.
-- ============================================================

if reframework:get_game_name() ~= "re4" then return end

local re4 = require("utility/RE4")

local ok_ks, killswitch = pcall(function() return require("re4vr/re4_vr_killswitch") end)
if not ok_ks or not killswitch then
    killswitch = { is_active = function() return false end }
end
local function ks_active()
    local ok, v = pcall(killswitch.is_active)
    return ok and v == true
end

-- ---- Config (persistiert) ----
local CFG_PATH = "re4_vr/re4_vr_crosshair.json"
local cfg = {
    bullet_hook = true,        -- Kugeln folgen VR-Muzzle
    crosshair_off = false,     -- [CROSSHAIR-TOGGLE] true = VR-Reticle-Dot komplett aus (kein Crosshair)
    reticle_scale = {},        -- [weapon_id_str] = Groessen-Multiplikator (Default 1.0)
    reticle_color = false,     -- [RETICLE-COLOR] true = eigene Farbe erzwingen (sonst nativ/weiss)
    reticle_r = 1.0, reticle_g = 0.0, reticle_b = 0.0,   -- ColorScale-Multiplikator (r,g,b), a bleibt 1
    force_reticle_concentrate = false,  -- [CONCENTRATE] Reticle dauerhaft zusammengezogen
    concentrate_ratio = 1.0,            -- Ziel-Wert (1=eng/konzentriert, 0=weit)
}
local function save_cfg() pcall(function() json.dump_file(CFG_PATH, cfg) end) end
pcall(function()
    local d = json.load_file(CFG_PATH)
    if type(d) == "table" then
        for k, v in pairs(cfg) do
            if d[k] ~= nil and type(d[k]) == type(v) then cfg[k] = d[k] end
        end
    end
end)

-- ---- [HAND_HUDS] HUD-GUIs an die rechte Hand (konsolidiert aus dem fruechren re4_vr_hand_huds.lua) ----
-- Position UND Ausrichtung kommen aus der rechten VR-Hand (__vr_rh_world/__vr_rh_rot, von motion.lua)
-- -> drehen nur mit der Hand, nicht mit dem Kopf. Alle Ziel-GUIs bekommen die IDENTISCHE Transform
-- (1 gemeinsamer Offset + 1 Scale) -> ihr natives Verhaeltnis zueinander bleibt erhalten.
local HUD_TARGETS = {
    { name = "Gui_ui2030",         label = "Gun (Munition)" },
    { name = "Gui_ui2032_default", label = "Energy/Health-Meter" },
    -- [ADA 2026-07-20] Ada zeichnet den Energie-Ring als "Gui_ui2032" OHNE das _default-Suffix
    -- (per GUI-Namen-Dump belegt) -> mit nur dem Leon-Namen blieb ihre Leiste als einziges HUD-Element
    -- am Kopf haengen. Eigener Eintrag statt Praefix-Match: die Liste bleibt exakt, kein Kollateralfang.
    { name = "Gui_ui2032",         label = "Energy/Health-Meter (Ada)" },
    { name = "Gui_ui2180",         label = "Body Armor" },
    { name = "Gui_ui2190",         label = "Knife" },
    { name = "Gui_ui2083",         label = "Gui_ui2083" },
}
local HUD_CFG_PATH = "re4_vr/re4_vr_hand_huds.json"
local hud_cfg = {
    enabled = true, hide_hud = false,
    dx = -0.143, dy = -0.094, dz = 0.10, scale = 0.289,   -- getunte Defaults
    rx = -180.0, ry = 55.0, rz = 102.0,
    -- [ADA-ROTATION 2026-07-20] Ada haelt die Waffe anders -> sie braucht eine EIGENE Ausrichtung
    -- der HUD-Gruppe. Nur die ROTATION ist getrennt (Position/Groesse passen fuer beide). ada_rot=false
    -- -> Adas Werte werden ignoriert und alles laeuft exakt wie vorher ueber rx/ry/rz. Leons Werte werden
    -- von diesem Zweig NIE angefasst.
    ada_rot = false,
    ada_rx = -180.0, ada_ry = 55.0, ada_rz = 102.0,
    -- [ADA-POSITION 2026-07-20] nachgereicht: auch der Offset zur Hand braucht eigene Werte.
    -- Haengt am SELBEN Schalter (ada_rot) -- ein Haken schaltet Adas komplettes Set (Rotation + Position).
    -- Groesse (scale) bleibt bewusst gemeinsam.
    ada_dx = -0.143, ada_dy = -0.094, ada_dz = 0.10,
    guis = {},
}
for _, t in ipairs(HUD_TARGETS) do hud_cfg.guis[t.name] = { enabled = true } end
local function save_hud_cfg() pcall(function() json.dump_file(HUD_CFG_PATH, hud_cfg) end) end
pcall(function()
    local d = json.load_file(HUD_CFG_PATH)
    if type(d) == "table" then
        for _, k in ipairs({ "enabled", "hide_hud", "ada_rot" }) do
            if type(d[k]) == "boolean" then hud_cfg[k] = d[k] end
        end
        for _, k in ipairs({ "dx", "dy", "dz", "scale", "rx", "ry", "rz",
                             "ada_rx", "ada_ry", "ada_rz", "ada_dx", "ada_dy", "ada_dz" }) do
            if type(d[k]) == "number" then hud_cfg[k] = d[k] end
        end
        if type(d.guis) == "table" then
            for name, g in pairs(d.guis) do
                if hud_cfg.guis[name] and type(g) == "table" and type(g.enabled) == "boolean" then
                    hud_cfg.guis[name].enabled = g.enabled
                end
            end
        end
    end
end)

-- ---- [CONCENTRATE] Reticle dauerhaft im zusammengezogenen Zustand ----
-- chainsaw.ReticleGuiBehavior treibt das dynamische Reticle ueber CurrConcentrateRatio
-- (0=weit … 1=zusammengezogen). Wir hooken den Setter und zwingen den Wert auf den
-- Ziel-Wert, BEVOR das Panel ihn liest. Toggle live via _G (ueberlebt Script-Reload).
local function float_bits(f)
    local ok, b = pcall(function() return (string.unpack("<I4", string.pack("<f", f))) end)
    return ok and b or 0x3F800000   -- Fallback = 1.0f
end
_G.__re4_force_concentrate = cfg.force_reticle_concentrate == true
_G.__re4_concentrate_bits  = float_bits(cfg.concentrate_ratio or 1.0)

if not _G.__re4_concentrate_hook_installed then
    _G.__re4_concentrate_hook_installed = true
    local td = sdk.find_type_definition("chainsaw.ReticleGuiBehavior")
    local m = td and td:get_method("set_CurrConcentrateRatio(System.Single)")
    if m then
        sdk.hook(m,
            function(args)
                if rawget(_G, "__re4_force_concentrate") then
                    args[3] = sdk.to_ptr(rawget(_G, "__re4_concentrate_bits") or 0x3F800000)
                end
            end,
            function(retval) return retval end)
    else
    end

end

-- [CONCENTRATE via applyConcentrate] Die Panel-State-Machine (DEFAULT<->CONCENTRATE) treibt die sichtbare
-- Groesse. applyConcentrate(bool) schaltet sie vermutlich: false=aufgehen(DEFAULT), true=klein(CONCENTRATE).
-- Bei force_concentrate das Argument auf TRUE zwingen -> Reticle bleibt klein. Callback global, eigener Guard.
_G.__re4_apply_concentrate_cb = function(args)
    if rawget(_G, "__re4_force_concentrate") then args[3] = sdk.to_ptr(1) end   -- true erzwingen -> Reticle bleibt klein
end
if not _G.__re4_apply_concentrate_installed then
    _G.__re4_apply_concentrate_installed = true
    local td3 = sdk.find_type_definition("chainsaw.ReticleGuiBehavior")
    local m_ac = td3 and (td3:get_method("applyConcentrate(System.Boolean)") or td3:get_method("applyConcentrate"))
    if m_ac then
        sdk.hook(m_ac,
            function(args) local f = rawget(_G, "__re4_apply_concentrate_cb"); if f then pcall(f, args) end end,
            function(retval) return retval end)
    else
    end
end

-- ---- Raycast-Infrastruktur ----
local function generate_statics(typename)
    local t = sdk.find_type_definition(typename)
    if not t then return {} end
    local enum = {}
    for _, field in ipairs(t:get_fields()) do
        if field:is_static() then
            enum[field:get_name()] = field:get_data(nil)
        end
    end
    return enum
end

local CollisionLayer = generate_statics(sdk.game_namespace("CollisionUtil.Layer"))
local CollisionFilter = generate_statics(sdk.game_namespace("CollisionUtil.Filter"))

local cast_ray_async_method = sdk.find_type_definition("via.physics.System")
    :get_method("castRayAsync(via.physics.CastRayQuery, via.physics.CastRayResult)")

local function cast_ray_async(ray_result, start_pos, end_pos, layer, filter_info)
    if layer == nil then layer = CollisionLayer.Bullet end
    local via_physics_system = sdk.get_native_singleton("via.physics.System")
    local ray_query = sdk.create_instance("via.physics.CastRayQuery")
    ray_result = ray_result or sdk.create_instance("via.physics.CastRayResult")

    ray_query:call("setRay(via.vec3, via.vec3)", start_pos, end_pos)
    ray_query:call("clearOptions")
    ray_query:call("enableAllHits")
    ray_query:call("enableNearSort")

    if filter_info == nil then
        filter_info = ray_query:call("get_FilterInfo")
        filter_info:call("set_Group", 0)
        filter_info:call("set_MaskBits", 0xFFFFFFFF & ~1)
        filter_info:call("set_Layer", layer)
    end

    ray_query:call("set_FilterInfo", filter_info)
    cast_ray_async_method:call(via_physics_system, ray_query, ray_result)
    return ray_result
end

-- ---- State ----
re4.crosshair_pos = re4.crosshair_pos or Vector3f.new(0, 0, 0)
re4.crosshair_dir = re4.crosshair_dir or Vector3f.new(0, 0, 1)
re4.crosshair_normal = re4.crosshair_normal or Vector3f.new(0, 0, 0)

local joint_get_position = sdk.find_type_definition("via.Joint"):get_method("get_Position")
local joint_get_rotation = sdk.find_type_definition("via.Joint"):get_method("get_Rotation")

local crosshair_bullet_ray_result = nil
local crosshair_attack_ray_result = nil

local vec3_t = sdk.find_type_definition("via.vec3")
local quat_t = sdk.find_type_definition("via.Quaternion")
local set_item_vec3 = vec3_t:get_method("set_Item(System.Int32, System.Single)")
local set_item_quat = quat_t:get_method("set_Item(System.Int32, System.Single)")

local scene = nil
local current_weapon_id = nil
local current_muzzle_joint = nil
local current_laser_active = false   -- [LASER-RETICLE] equippte Gun hat den Laser-Aufsatz aktiv -> Reticle-Dot aus

local cached_pl_head = nil
local cached_gun_obj = nil
local cached_weapon_id = nil
local cache_refresh_time = 0
local CACHE_REFRESH_INTERVAL = 1.0

local character_ids = {
    "ch3a8z0_head", "ch6i0z0_head", "ch6i1z0_head", "ch6i2z0_head",
    "ch6i3z0_head", "ch3a8z0_MC_head", "ch6i5z0_head",
}

-- [MERCS 2026-08-02] Praefixe (5 Zeichen) aller SPIELBAREN Characters --
-- gebraucht vom NPC-Filter im Bullet-Hook unten. Ohne die Mercs-Eintraege galt
-- dort jeder Mercs-Charakter als NPC und der Bullet-Hook stieg VOR dem Umlenken
-- aus (Leon in Mercs = ch6i0z0_body). Ada faellt nicht auf, weil ihr
-- Mercs-Body ch3a8z0_MC_body denselben Praefix wie in Separate Ways hat.
local PLAYER_CH_PREFIX = {
    ch0a0 = true,   -- Leon (Kampagne)
    ch3a8 = true,   -- Ada (Separate Ways + Mercs)
    ch6i0 = true,   -- Leon (Mercs)
    ch6i1 = true,   -- Luis
    ch6i2 = true,   -- Krauser
    ch6i3 = true,   -- HUNK
    ch6i5 = true,   -- Wesker
}

local function is_valid_managed(obj)
    if not obj then return false end
    if tostring(obj) == "nil" then return false end
    if sdk.is_managed_object and sdk.is_managed_object(obj) == false then return false end
    return true
end

local function quat_rotate_vec3(q, v)
    local qv_x, qv_y, qv_z = q.x, q.y, q.z
    local uv_x = qv_y * v.z - qv_z * v.y
    local uv_y = qv_z * v.x - qv_x * v.z
    local uv_z = qv_x * v.y - qv_y * v.x
    local uuv_x = qv_y * uv_z - qv_z * uv_y
    local uuv_y = qv_z * uv_x - qv_x * uv_z
    local uuv_z = qv_x * uv_y - qv_y * uv_x
    return Vector3f.new(
        v.x + ((uv_x * q.w) + uuv_x) * 2.0,
        v.y + ((uv_y * q.w) + uuv_y) * 2.0,
        v.z + ((uv_z * q.w) + uuv_z) * 2.0
    )
end

-- ---- Raycast: Muzzle -> Welt-Hit ----
local function update_crosshair_world_pos(start_pos, end_pos)
    if crosshair_attack_ray_result == nil or crosshair_bullet_ray_result == nil then
        crosshair_attack_ray_result = cast_ray_async(crosshair_attack_ray_result, start_pos, end_pos, 5)
        crosshair_bullet_ray_result = cast_ray_async(crosshair_bullet_ray_result, start_pos, end_pos, 10)
        crosshair_attack_ray_result:add_ref()
        crosshair_bullet_ray_result:add_ref()
    end

    local finished = crosshair_attack_ray_result:call("get_Finished") == true
        and crosshair_bullet_ray_result:call("get_Finished") == true
    local attack_hit = finished and crosshair_attack_ray_result:call("get_NumContactPoints") > 0
    local any_hit = finished and (attack_hit or crosshair_bullet_ray_result:call("get_NumContactPoints") > 0)
    local both_hit = finished and crosshair_attack_ray_result:call("get_NumContactPoints") > 0
        and crosshair_bullet_ray_result:call("get_NumContactPoints") > 0

    if finished and any_hit then
        local best_result
        if both_hit then
            local attack_distance = crosshair_attack_ray_result:call("getContactPoint(System.UInt32)", 0):get_field("Distance")
            local bullet_distance = crosshair_bullet_ray_result:call("getContactPoint(System.UInt32)", 0):get_field("Distance")
            best_result = (attack_distance < bullet_distance) and crosshair_attack_ray_result or crosshair_bullet_ray_result
        else
            best_result = attack_hit and crosshair_attack_ray_result or crosshair_bullet_ray_result
        end

        local contact_point = best_result:call("getContactPoint(System.UInt32)", 0)
        if contact_point then
            local contact_distance = contact_point:get_field("Distance")
            if contact_distance and contact_distance > 100.0 then contact_distance = 100.0 end
            re4.crosshair_dir = (end_pos - start_pos):normalized()
            re4.crosshair_normal = contact_point:get_field("Normal")
            re4.crosshair_distance = contact_distance
            re4.crosshair_pos = start_pos + (re4.crosshair_dir * contact_distance)
        end
    elseif finished and not any_hit then
        local sky_distance = 100.0
        re4.crosshair_dir = (end_pos - start_pos):normalized()
        re4.crosshair_distance = sky_distance
        re4.crosshair_pos = start_pos + (re4.crosshair_dir * sky_distance)
    else
        re4.crosshair_dir = (end_pos - start_pos):normalized()
        if re4.crosshair_distance then
            re4.crosshair_pos = start_pos + (re4.crosshair_dir * re4.crosshair_distance)
        else
            re4.crosshair_pos = start_pos + (re4.crosshair_dir * 10.0)
            re4.crosshair_distance = 10.0
        end
    end

    if finished then
        cast_ray_async(crosshair_attack_ray_result, start_pos, end_pos, 5, CollisionFilter.DamageCheckOtherThanPlayer)
        cast_ray_async(crosshair_bullet_ray_result, start_pos, end_pos, 10)
    end
end

-- ---- Muzzle-Daten direkt vom Joint ----
-- [NPC-SHARED WEAPON / LUIS-FIX] wp4002 (Red9) traegt auch Luis -> scene:findGameObject liefert evtl.
-- SEINE Waffe (erster Szenen-Treffer) -> falscher Muzzle/Bullet-Hook + "sein" Crosshair. Fuer NPC-geteilte
-- Waffen die Waffe als DIREKTES Kind des SPIELER-Bodys suchen (parent-safe), nie global. Port aus dem alten
-- Mod (find_weapon_on_player_body). Spieler-Body-Namen sind eindeutig (Leon ch0a0z0 / Ada ch3a8z0 != Luis).
local NPC_SHARED_WEAPONS = { [4002] = true }
-- [MERCS 2026-08-02] Auch hier muessen die Mercs-Bodies rein: bei den
-- NPC_SHARED_WEAPONS (Red9) wird das Waffen-GO NUR unter diesen Bodies gesucht.
-- Luis spielt in Mercs eine Red9 -- ohne ch6i1z0_body fand das Script seine
-- Waffe nicht, also gab es weder Crosshair noch Muzzle fuer den Bullet-Hook.
local PLAYER_BODY_NAMES = {
    "ch0a0z0_body",      -- Leon (Kampagne)
    "ch3a8z0_body",      -- Ada (Separate Ways)
    "ch3a8z0_MC_body",   -- Ada (Mercs)
    "ch6i0z0_body",      -- Leon (Mercs)
    "ch6i1z0_body",      -- Luis
    "ch6i2z0_body",      -- Krauser
    "ch6i3z0_body",      -- HUNK
    "ch6i5z0_body",      -- Wesker
}
local function find_weapon_on_player_body(weapon_name)
    if not scene then return nil end
    for _, body_name in ipairs(PLAYER_BODY_NAMES) do
        local ok_pb, pb = pcall(scene.call, scene, "findGameObject(System.String)", body_name)
        local btf = ok_pb and pb and select(2, pcall(pb.call, pb, "get_Transform")) or nil
        if btf then
            local child = select(2, pcall(btf.call, btf, "get_Child"))
            local guard = 0
            while child and guard < 60 do
                guard = guard + 1
                local ok_go, cgo = pcall(child.call, child, "get_GameObject")
                if ok_go and cgo then
                    local ok_cn, cn = pcall(cgo.call, cgo, "get_Name")
                    if ok_cn and cn and tostring(cn) == weapon_name then return cgo end
                end
                child = select(2, pcall(child.call, child, "get_Next"))
            end
        end
    end
    return nil
end

local function update_muzzle_data()
    if not scene then
        local sm = sdk.get_native_singleton("via.SceneManager")
        if sm then
            scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        end
        if not scene then return end
    end

    local current_time = os.clock()
    if not cached_pl_head or (current_time - cache_refresh_time) > CACHE_REFRESH_INTERVAL then
        cached_pl_head = scene:call("findGameObject(System.String)", "ch0a0z0_head")
        if not cached_pl_head then
            for _, character_id in ipairs(character_ids) do
                cached_pl_head = scene:call("findGameObject(System.String)", character_id)
                if cached_pl_head then break end
            end
        end
        cache_refresh_time = current_time
    end
    if not cached_pl_head then return end
    if cached_pl_head.get_Valid and not cached_pl_head:get_Valid() then
        cached_pl_head = nil
        return
    end

    local player_equip = cached_pl_head:call("getComponent(System.Type)", sdk.typeof("chainsaw.PlayerEquipment"))
    local equip_weapon = player_equip and player_equip:call("get_EquipWeaponID()")
    if not equip_weapon then return end

    current_weapon_id = equip_weapon

    if not cached_gun_obj or cached_weapon_id ~= equip_weapon
        or (current_time - cache_refresh_time) > CACHE_REFRESH_INTERVAL then
        if NPC_SHARED_WEAPONS[equip_weapon] then
            -- [LUIS-FIX] Red9 & Co: NUR im Spieler-Body suchen, sonst schnappt man sich Luis' Waffe.
            cached_gun_obj = find_weapon_on_player_body("wp" .. tostring(equip_weapon))
                or find_weapon_on_player_body("wp" .. tostring(equip_weapon) .. "_AO")
                or find_weapon_on_player_body("wp" .. tostring(equip_weapon) .. "_MC")
        else
            cached_gun_obj = scene:call("findGameObject(System.String)", "wp" .. tostring(equip_weapon))
                or scene:call("findGameObject(System.String)", "wp" .. tostring(equip_weapon) .. "_AO")
                or scene:call("findGameObject(System.String)", "wp" .. tostring(equip_weapon) .. "_MC")
        end
        cached_weapon_id = equip_weapon
        cache_refresh_time = current_time
    end
    if not cached_gun_obj or not is_valid_managed(cached_gun_obj) then return end

    local ok_arms, bt_arms = pcall(cached_gun_obj.call, cached_gun_obj, "getComponent(System.Type)", sdk.typeof("chainsaw.Arms"))
    if not ok_arms then bt_arms = nil end

    -- [LASER-RETICLE 2026-07-18] Hat die equippte Gun den Laser-Aufsatz aktiv (get_EnableLaserSight, nur an
    -- chainsaw.Gun -> pcall wegen Messer/Nicht-Gun)? Wenn ja -> unten der Reticle-Dot AUS (nur der Laser bleibt).
    -- Dynamisch pro Update: Laser-Addon AB -> false -> Reticle-Dot ist wieder da. Unabhaengig vom manuellen Toggle.
    current_laser_active = false
    if bt_arms then
        local ok_l, en = pcall(function() return bt_arms:call("get_EnableLaserSight") end)
        if ok_l and en == true then current_laser_active = true end
    end

    local muzzle_joint = bt_arms and bt_arms:call("getMuzzleJoint") or nil
    if not muzzle_joint then
        local ok, gun_transforms = pcall(cached_gun_obj.get_Transform, cached_gun_obj)
        if ok and gun_transforms then
            muzzle_joint = gun_transforms:call("getJointByName", "vfx_muzzle")
                or gun_transforms:call("getJointByName", "vfx_muzzle1")
        end
    end

    if muzzle_joint then
        -- Waffen-GO haengt via motion an der VR-Hand -> Joint sitzt korrekt,
        -- AxisZ = Laufachse.
        current_muzzle_joint = muzzle_joint
        re4.last_muzzle_pos = joint_get_position(muzzle_joint)
        re4.last_muzzle_forward = muzzle_joint:call("get_AxisZ")
        re4.last_shoot_dir = re4.last_muzzle_forward
        re4.last_shoot_pos = re4.last_muzzle_pos
        re4.last_muzzle_joint = muzzle_joint
    else
        current_muzzle_joint = nil
        re4.last_muzzle_joint = nil
    end
end

-- [LASER ENTFERNT 2026-06-17] Komplettes Laser-Subsystem raus (so gewollt: KEIN laser-relevanter
-- Versteck-/Umpositionier-Code). Der native Laser bleibt voellig unangetastet und folgt der VR-Waffe
-- von selbst (Laser-GOs haengen als Joint-Children am bewegten Waffen-GO, genau wie das Muendungsfeuer).
-- Falls aus einer frueheren Session noch der updateLaser-Hook installiert ist: die global referenzierten
-- Callbacks auf Pass-Through setzen -> der alte Hook tut sofort nichts mehr (kein Neustart noetig).
-- Auf frischem Start wird gar kein updateLaser-Hook mehr installiert.
_G.__re4_vr_laser_pre  = function(args) return end
_G.__re4_vr_laser_post = function(retval) return retval end

-- Forward-Decl (Definition unten) — sonst ist die Funktion im Callback nil.
local apply_reticle_params

-- ---- Frame-Update: Aim-State exportieren + Muzzle + Raycast ----
re.on_pre_application_entry("LockScene", function()
    local character_manager = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local CharacterContext = character_manager and character_manager:call("getPlayerContextRef")
    if CharacterContext then
        _G.is_aim = CharacterContext:call("get_IsShootEnable")
        _G.is_reticle_displayed = CharacterContext:call("get_IsReticleDisp")
        _G._IsWeaponChanging = CharacterContext:call("get_IsWeaponChanging") or false
    else
        _G.is_aim = false
        _G.is_reticle_displayed = false
        _G._IsWeaponChanging = false
    end

    if ks_active() and rawget(_G, "__re4_railcar_mode") ~= true then
        _G.is_aim = false
        _G.is_reticle_displayed = false
        _G._IsWeaponChanging = false
    end

    update_muzzle_data()
    apply_reticle_params()
    if re4.last_shoot_pos and re4.last_shoot_dir then
        local pos = re4.last_shoot_pos + (re4.last_shoot_dir * 0.05)
        update_crosshair_world_pos(pos, pos + (re4.last_shoot_dir * 1000.0))
    end
end)

-- ---- Reticle ruhigstellen (Dev-Pattern, einmalig) ----
-- _ReticleShape/_ReticleGuiType = 4 (statischer Punkt) + _PointRange 100/100
-- im WeaponCatalog. Ohne das animiert die Engine das Reticle-Panel intern
-- (Sway/Spread) -> Dot tanzt seitlich, auch bei ruhiger Hand.
local RETICLE_VALUE = 4
local reticle_params_applied = false

-- [WRITE_VALUETYPE 2026-07-15] FEHLTE -- deshalb warf applyPointRange unten seit jeher
-- "global 'write_valuetype' is not callable (a nil value)", der pcall brach beim ERSTEN Reticle-Param ab
-- und reticle_params_applied wurde nie true -> der ganze Katalog-Scan lief in JEDEM Frame neu (der Fehler
-- stand nur 1x im Log, die Arbeit passierte trotzdem 90x/s). Der Retry an sich ist gewollt: der
-- WeaponCatalog existiert in den ersten Frames einer Szene noch nicht ("kein catalog" -> naechster Frame).
-- Standard-REFramework-Helfer: get_field auf einem ValueType liefert eine KOPIE -- ohne Rueckschreiben
-- bleibt "pointRange.s = 100" wirkungslos. Schreibt die Struct byteweise zurueck an <offset> in <parent>.
-- (Gleiches Muster wie write_vec4 weiter unten, nur fuer beliebige ValueTypes.)
local function write_valuetype(parent, offset, value)
    for i = 0, value.type:get_valuetype_size() - 1 do
        parent:write_byte(offset + i, value:read_byte(i))
    end
end

local apply_attempt_logged = false
apply_reticle_params = function()
    if reticle_params_applied then return end
    if not scene then return end
    if not apply_attempt_logged then
        apply_attempt_logged = true
    end

    local ok, err = pcall(function()
        local weaponCatalog = scene:call("findGameObject(System.String)", "WeaponCatalog")
            or scene:call("findGameObject(System.String)", "WeaponCatalog_AO")
        local weaponDataTables2 = nil
        if not weaponCatalog then
            weaponCatalog = scene:call("findGameObject(System.String)", "WeaponCatalog_MC")
            local cat2 = scene:call("findGameObject(System.String)", "WeaponCatalog_MC_2nd")
            if cat2 then
                local reg2 = cat2:call("getComponent(System.Type)", sdk.typeof("chainsaw.WeaponCatalogRegister"))
                local ud2 = reg2 and reg2:call("get_WeaponEquipParamCatalogUserData")
                weaponDataTables2 = ud2 and ud2:get_field("_DataTable")
            end
        end
        if not weaponCatalog then error("kein catalog") end

        local register = weaponCatalog:call("getComponent(System.Type)", sdk.typeof("chainsaw.WeaponCatalogRegister"))
        local ud = register and register:call("get_WeaponEquipParamCatalogUserData")
        local weaponDataTables = ud and ud:get_field("_DataTable")
        if not weaponDataTables then error("kein datatable") end

        local function applyPointRange(param)
            if not param then return end
            local pointRange = param:get_field("_PointRange")
            if pointRange then
                pointRange.s = 100
                pointRange.r = 100
                write_valuetype(param, 0x10, pointRange)
            end
        end

        -- Waffen, deren Default-Shape kein Punkt ist (Dev-Liste)
        local RETICLE_SHAPE_WEAPONS = {
            [4005] = true, [4400] = true, [4401] = true, [4402] = true,
            [6105] = true, [6114] = true, [6304] = true, [6102] = true,
            [4501] = true,
        }

        local function processWeaponData(weaponData)
            local weaponID = weaponData:get_field("_WeaponID")
            local tbl = weaponData:get_field("_ReticleFitParamTable")
            if not tbl then return end
            if RETICLE_SHAPE_WEAPONS[weaponID] then
                tbl:set_field("_ReticleShape", RETICLE_VALUE)
            end
            applyPointRange(tbl:get_field("_DefaultParam"))
            local customParams = tbl:get_field("_CustomParams")
            if customParams then
                for i = 0, (customParams:call("get_Count") or 0) - 1 do
                    local cp = customParams:call("get_Item", i)
                    local p = cp and cp:get_field("_Param")
                    if p then applyPointRange(p) end
                end
            end
        end

        for _, weaponTable in ipairs({ weaponDataTables, weaponDataTables2 }) do
            if weaponTable then
                for i = 0, weaponTable:call("get_Count") - 1 do
                    processWeaponData(weaponTable:call("get_Item", i))
                end
            end
        end

        -- Custom-Catalog: Laser-Sight-Attachment ReticleGuiType + PointRange
        local customCatalog = scene:call("findGameObject(System.String)", "WeaponCustomCatalog")
            or scene:call("findGameObject(System.String)", "WeaponCustomCatalog_AO")
            or scene:call("findGameObject(System.String)", "WeaponCustomCatalog_MC")
        local customRegister = customCatalog and customCatalog:call("getComponent(System.Type)", sdk.typeof("chainsaw.WeaponCustomCatalogRegister"))
        local detailUd = customRegister and customRegister:call("get_WeaponDetailCustomUserdata")
        local stages = detailUd and detailUd:get_field("_WeaponDetailStages")
        if stages then
            for i = 0, stages:call("get_Count") - 1 do
                local weaponData = stages:call("get_Item", i)
                local detail = weaponData and weaponData:get_field("_WeaponDetailCustom")
                local attachments = detail and detail:get_field("_AttachmentCustoms")
                if attachments then
                    for j = 0, attachments:call("get_Count") - 1 do
                        local itemData = attachments:call("get_Item", j)
                        local itemID = itemData and itemData:get_field("_ItemID")
                        if itemID == 116008000 then
                            local params = itemData:get_field("_AttachmentParams")
                            if params then
                                for k = 0, params:call("get_Count") - 1 do
                                    local ad = params:call("get_Item", k)
                                    if ad and ad:get_field("_AttachmentParamName") == 501 then
                                        ad:set_field("_ReticleGuiType", RETICLE_VALUE)
                                    end
                                end
                            end
                        elseif itemID == 116006400 or itemID == 116001600 or itemID == 116009600 then
                            local params = itemData:get_field("_AttachmentParams")
                            if params then
                                for k = 0, params:call("get_Count") - 1 do
                                    local ad = params:call("get_Item", k)
                                    local fit = ad and ad:get_field("_ReticleFitParam")
                                    if fit then applyPointRange(fit) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    if ok then
        reticle_params_applied = true
    elseif not _G.__re4_vr_reticle_param_err_logged then
        _G.__re4_vr_reticle_param_err_logged = true
    end
end

-- ---- End-Dot: Engine-GUI-Reticle Gui_ui2040 im Welt-Raum an den Hit ----
-- Gerendert im selben Frame -> kein Effekt-Lag. Gui_ui2042 bleibt versteckt.
local RETICLE_DOT = "Gui_ui2040"
local reticle_hide = { ["Gui_ui2042"] = true }
local MIN_SCALE = 0.3
local MAX_SCALE = 0.94

local function write_vec4(obj, vec, offset)
    obj:write_float(offset, vec.x)
    obj:write_float(offset + 4, vec.y)
    obj:write_float(offset + 8, vec.z)
    obj:write_float(offset + 12, vec.w)
end

-- [HAND_HUDS] Euler->Quat (relativ zur Hand) + hand-feste Transform fuer die HUD-Gruppe
local function hud_quat_from_euler_deg(dxg, dyg, dzg)
    local function axis_q(ax, ay, az, ang)
        local h = math.rad(ang) * 0.5; local s = math.sin(h)
        return Quaternion.new(math.cos(h), ax * s, ay * s, az * s)
    end
    return (axis_q(0, 1, 0, dyg) * axis_q(1, 0, 0, dxg) * axis_q(0, 0, 1, dzg)):normalized()
end

local function apply_hand_hud(game_object)
    local hand = rawget(_G, "__vr_rh_world")
    local hrot = rawget(_G, "__vr_rh_rot")
    if not (hand and hand.x and hrot) then return end
    local tf = game_object:call("get_Transform")
    if not tf then return end
    -- [HAND_HUDS] View hart auf Welt-Raum zwingen (wie das Reticle). Sonst rendert ein
    -- uebrig gebliebener Screen-Space-Pass dasselbe Element mit unseren Welt-Koordinaten
    -- als winziges Duplikat am Bildrand. Welt-Raum + Overlay -> nur 1 korrekte Darstellung.
    local gui = re4.get_component(game_object, "via.gui.GUI")
    local view = gui and gui:call("get_View")
    if view then
        pcall(function() view:call("set_ViewType", 1) end)
        pcall(function() view:call("set_Overlay", true) end)
    end
    -- native Basis-Laenge (Panel-Groesse) lesen, BEVOR wir die Basis ueberschreiben
    local L = 0.0833
    local b0x, b0y, b0z = tf:read_float(0x80), tf:read_float(0x84), tf:read_float(0x88)
    local n = math.sqrt(b0x * b0x + b0y * b0y + b0z * b0z)
    if n > 1e-5 then L = n end
    -- Position hand-relativ + Ausrichtung aus Hand-Rotation -> dreht nur mit der Hand, nicht dem HMD
    -- [ADA-SET 2026-07-20] Nur wenn ada_rot aktiv IST und der sticky Charakter-Getter
    -- (__re4_char_now, motion.lua) wirklich "ada" meldet -> Adas eigenes Set (Rotation UND Offset).
    -- Sonst unveraendert Leons Werte. Kein eigener Body-Check hier: der sticky Getter ueberbrueckt die
    -- Frames, in denen der Body kurz weg ist (sonst klappte die HUD-Gruppe fuer einen Frame zurueck).
    local _rx, _ry, _rz = hud_cfg.rx, hud_cfg.ry, hud_cfg.rz
    local _dx, _dy, _dz = hud_cfg.dx, hud_cfg.dy, hud_cfg.dz
    if hud_cfg.ada_rot then
        local _cn = rawget(_G, "__re4_char_now")
        if type(_cn) == "function" and _cn() == "ada" then
            _rx, _ry, _rz = hud_cfg.ada_rx, hud_cfg.ada_ry, hud_cfg.ada_rz
            _dx, _dy, _dz = hud_cfg.ada_dx, hud_cfg.ada_dy, hud_cfg.ada_dz
        end
    end
    local off = hrot * Vector3f.new(_dx, _dy, _dz)
    local q = (hrot * hud_quat_from_euler_deg(_rx, _ry, _rz)):normalized()
    local m = q:to_mat4()
    local s = L * hud_cfg.scale
    write_vec4(tf, m[0] * s, 0x80)
    write_vec4(tf, m[1] * s, 0x90)
    write_vec4(tf, m[2] * s, 0xA0)
    write_vec4(tf, Vector4f.new(hand.x + off.x, hand.y + off.y, hand.z + off.z, 1.0), 0xB0)
end

-- [FINISHER_PROMPT] Frische-Check als Global (kein top-level local -> kein 200-Limit).
-- true solange Gui_ui2200 innerhalb der letzten ~0.15s gezeichnet wurde.
_G.__re4_finisher_prompt_seen = _G.__re4_finisher_prompt_seen or 0.0
_G.__re4_is_finisher_prompt = function()
    return (os.clock() - (_G.__re4_finisher_prompt_seen or 0)) < 0.15
end

-- [DODGE_PROMPT 2026-07-15] Ausweich-Prompt (Krauser-Fight). Das Spiel zeichnet je nach eingestelltem
-- BUTTON-SYMBOLSATZ ein anderes Element -> beide triggern (s. Hook unten):
-- Gui_ui2191_3 = Xbox360-Symbole ( im Spiel bestaetigt)
-- Gui_ui2150 = PlayStation-Symbole
-- Das erklaert den ersten Fehlversuch: 2150 war zuerst eingetragen und tat nichts -- nicht weil der Name
-- falsch war, sondern weil damals Xbox-Symbole liefen und 2150 gar nicht gezeichnet wurde.
-- Gui_ui2151 taucht immer als 0.5s-Paar mit 2150 auf (Glyph/Container) -> NICHT noetig; falls PS doch
-- nicht ausloest, waere es der naechste Kandidat.
-- Gleiches Muster wie der Finisher-Prompt oben, gleiche Gruende: Frische-Fenster statt Flag -> es gibt
-- NICHTS, das haengenbleiben kann. Verschwindet das GUI, ist das Binding nach 0.15s von selbst aus;
-- im Menue wird das Gameplay-HUD gar nicht erst gezeichnet (per Pause-Snapshot 2026-07-15 belegt:
-- dort laufen NUR Gui_ui0200/0300/0500/0501/0502 + Fades).
-- Konsument: re4_vr_binding.lua Gameplay-Branch (L.Grip -> f.B, NUR in diesem Fenster).
_G.__re4_dodge_prompt_seen = _G.__re4_dodge_prompt_seen or 0.0
_G.__re4_is_dodge_prompt = function()
    return (os.clock() - (_G.__re4_dodge_prompt_seen or 0)) < 0.15
end

re.on_pre_gui_draw_element(function(element, context)
    local game_object = element:call("get_GameObject")
    local name = game_object and game_object:call("get_Name")
    if not name then return true end

    -- [FINISHER_PROMPT] Gui_ui2200 = RT-Finisher-Prompt (100% bestaetigt).
    -- Zeichnet jeden Frame solange sichtbar -> Timestamp merken, Frische-Fenster
    -- macht daraus ein Boolean (kein on_frame/Reset noetig, save/load-sicher).
    -- Konsument: __re4_is_finisher_prompt (Messer-Reverse-Shake -> RT feuern).
    if name == "Gui_ui2200" then _G.__re4_finisher_prompt_seen = os.clock() end

    -- [DODGE_PROMPT] Ausweich-Prompt -> Timestamp fuer __re4_is_dodge_prompt. ZWEI Namen, weil das Spiel
    -- je nach Button-Symbolsatz ein anderes Element zeichnet: 2191_3 = Xbox360-Symbole (bestaetigt),
    -- 2150 = PlayStation-Symbole. Beide muessen rein, sonst ist das Ausweichen im jeweils anderen Satz tot.
    -- Inline-or statt Tabelle: crosshair.lua ist am 200-Local-Limit, das hier kostet keine neue local.
    --
    -- [2151 WIEDER RAUS 2026-07-17] "Gui_ui2151" war testweise drin (im Ausweich-Fenster per GUI-Dump gesehen,
    -- Stage 43302). Es hat das Ausweichen NICHT repariert, ist also nicht der Prompt -- und dann ist es
    -- gefaehrlich: taucht es irgendwo sonst auf, wird der linke Grip "aus dem Nichts" zu B umgebunden.
    -- NICHT wieder aufnehmen, ohne vorher zu BELEGEN, dass es wirklich der Ausweich-Prompt ist.
    -- (2191_3 kam im selben Fenster und wird bereits erkannt -> der GUI-Name ist NICHT die Ursache.)
    if name == "Gui_ui2191_3" or name == "Gui_ui2150" then _G.__re4_dodge_prompt_seen = os.clock() end

    -- [GUI-NAMEN-DUMP 2026-07-17 -- ERLEDIGT, ENTFERNT] Hat den fehlenden Ausweich-Prompt gefunden
    -- ("Gui_ui2151", s. Zweig oben). Falls je wieder gebraucht: dedupliziert ueber eine Tabelle JEDEN
    -- Namen genau EINMAL nach re4_gui_names.log schreiben -- NIEMALS pro Frame (s. Homing-Probe, das
    -- die FPS zerlegt hat).

    if reticle_hide[name] then return false end

    -- [HAND_HUDS] HUD-GUIs an die rechte Hand (oder komplett ausblenden)
    local hh = hud_cfg.guis[name]
    if hh and hh.enabled then
        if hud_cfg.hide_hud then return false end
        -- [SCOPE 2026-08-08] Beim Zielen durch ein montiertes Scope liegt die
        -- Hand-HUD-Gruppe mitten im gezoomten Bild -> waehrenddessen komplett aus.
        -- Beide Signale, damit es mit UND ohne unseren Fork greift (weapons.lua ~373/401):
        -- __re4_scope_native = Scope-Aim auf dem Fork, __re4_force_killswitch_scope = sonst.
        if rawget(_G, "__re4_force_killswitch_scope") == true
        or rawget(_G, "__re4_scope_native") == true then return false end
        if hud_cfg.enabled then apply_hand_hud(game_object) end
        return true
    end

    if name ~= RETICLE_DOT then return true end

    -- [CROSSHAIR-TOGGLE 2026-07-18] Komplett-Aus per UI-Checkbox: den VR-Reticle-Dot gar nicht zeichnen.
    if cfg.crosshair_off == true then return false end

    -- [LASER-RETICLE 2026-07-18] Hat die equippte Pistole den Laser-Aufsatz aktiv -> KEIN Reticle-Dot (nur der
    -- Laser). Unabhaengig vom Toggle oben. Laser-Addon AB -> current_laser_active=false -> Reticle wieder da.
    if current_laser_active then return false end

    -- Dot nur beim Aimen mit Muzzle-Waffe
    if not _G.is_aim or not current_muzzle_joint or not re4.crosshair_distance then
        return false
    end

    local transform = game_object:call("get_Transform")
    if not transform then return true end
    local gui_comp = re4.get_component(game_object, "via.gui.GUI")
    local view = gui_comp and gui_comp:call("get_View")
    if not view then return true end

    view:call("set_ViewType", 1)        -- Welt-Raum
    view:call("set_Overlay", true)      -- Overlay an
    view:call("set_Detonemap", true)
    -- [SICHTBARKEIT] DepthTest AUS: mit Depth-Test kaempfte der auf der Trefferflaeche liegende Dot je nach
    -- Winkel/Surface gegen die Szenen-Tiefe -> Z-Fighting -> mal sichtbar, mal komplett weg ("Lotto"). Der Dot
    -- sitzt am naechsten Aim-Treffer, zwischen Muzzle und Dot ist nichts -> "immer oben drauf" ist korrekt.
    view:call("set_DepthTest", false)
    -- [RETICLE-COLOR 2026-07-23] Punkt einfaerben ueber ColorScale des Panels 'main' (Dump
    -- 20:48: via.gui.Panel hat set_ColorScale). r/g/b Multiplikator, Alpha bleibt 1. force aus -> 1/1/1
    -- (nativ/weiss). Genau das Muster der Laser-Presets, nur hier als GUI-Tint.
    do
        local root = view:call("get_Child")
        if root then
            local r = cfg.reticle_color and (tonumber(cfg.reticle_r) or 1.0) or 1.0
            local g = cfg.reticle_color and (tonumber(cfg.reticle_g) or 1.0) or 1.0
            local b = cfg.reticle_color and (tonumber(cfg.reticle_b) or 1.0) or 1.0
            pcall(function() root:call("set_ColorScale", Vector4f.new(r, g, b, 1.0)) end)
        end
    end

    -- Der VR-Mod hat eine EIGENE Crosshair-Behandlung — ohne unhide
    -- kaempft sie mit unserem Write.
    pcall(function() vrmod:unhide_crosshair() end)

    -- Position FRISCH vom Muzzle-Joint (gleiche Quelle/Moment wie die
    -- Laser-Line) — der LockScene-Stand ist 1 Frame alt und zappelt
    -- relativ zum Laser. Nur die Distanz kommt vom (async) Raycast.
    local distance = re4.crosshair_distance
    local mp = select(2, pcall(joint_get_position, current_muzzle_joint))
    local fwd = select(2, pcall(function() return current_muzzle_joint:call("get_AxisZ") end))
    local dir, base
    if mp and fwd then
        dir = fwd:normalized()
        base = mp
    else
        dir = re4.crosshair_dir
        base = re4.crosshair_pos - (dir * distance)
    end

    local scale_distance = distance * 0.075
    if scale_distance < MIN_SCALE then scale_distance = MIN_SCALE
    elseif scale_distance > MAX_SCALE then scale_distance = MAX_SCALE end
    -- Per-Waffe Groessen-Multiplikator (1.0 = unveraendert)
    local user_scale = current_weapon_id and cfg.reticle_scale[tostring(current_weapon_id)]
    if user_scale then scale_distance = scale_distance * user_scale end

    local new_mat = dir:to_quat():to_mat4()
    local adjusted_pos = base + (dir * (distance - 0.05))
    local crosshair_pos = Vector4f.new(adjusted_pos.x, adjusted_pos.y, adjusted_pos.z, 1.0)

    write_vec4(transform, new_mat[0] * scale_distance, 0x80)
    write_vec4(transform, new_mat[1] * scale_distance, 0x90)
    write_vec4(transform, new_mat[2] * scale_distance, 0xA0)
    write_vec4(transform, crosshair_pos, 0xB0)

    return true
end)

-- ---- Bullet-Hook ----
local function on_pre_request_fire(args)
    -- [LUIS-FIX] NPC-Schuss (Luis' Red9 -> gleiche BulletShellGenerator-Klasse) NICHT als Spieler-Schuss
    -- werten: sonst zaehlt __vr_shot_seq hoch (-> Haptik/Burst bei SEINEM Schuss) UND seine Kugel wird an
    -- DEINEN Muzzle umgelenkt. Discriminator = der besitzende CHARACTER: vom Generator (args[2]) die
    -- Transform-Parent-Kette hoch bis zum ersten "ch..."-Character. Spieler = ch0a0 (Leon)/ch3a8 (Ada) -> ok,
    -- anderer Character (Luis) -> skip. Kein ch-Ancestor gefunden -> NICHT skippen (kein Regression-Risiko).
    do
        local gen = sdk.to_managed_object(args[2])
        if gen then
            local tf = select(2, pcall(function() return gen:call("get_GameObject"):call("get_Transform") end))
            local is_npc = false
            local guard = 0
            while tf and guard < 16 do
                guard = guard + 1
                local nm = select(2, pcall(function() return tf:call("get_GameObject"):call("get_Name") end))
                if nm then
                    local s = tostring(nm)
                    if s:sub(1, 2) == "ch" then
                        if PLAYER_CH_PREFIX[s:sub(1, 5)] then is_npc = false
                        else is_npc = true end
                        break   -- erster Character-Ancestor entscheidet
                    end
                end
                tf = select(2, pcall(function() return tf:call("get_Parent") end))
            end
            if is_npc then return end
        end
    end
    _G.__vr_shot_seq = (rawget(_G, "__vr_shot_seq") or 0) + 1   -- [BURST] Schuss-Zaehler (motion/binding nutzen ihn)
    if not cfg.bullet_hook then return end

    if rawget(_G, "vr_scope_active") and rawget(_G, "vr_scope_aim_pos") and rawget(_G, "vr_scope_aim_dir") then
        local p = sdk.to_ptr(sdk.to_int64(args[3]))
        set_item_vec3:call(p, 0, _G.vr_scope_aim_pos.x)
        set_item_vec3:call(p, 1, _G.vr_scope_aim_pos.y)
        set_item_vec3:call(p, 2, _G.vr_scope_aim_pos.z)
        local rot = _G.vr_scope_aim_dir:normalized():to_quat()
        local r = sdk.to_ptr(sdk.to_int64(args[4]))
        set_item_quat:call(r, 0, rot.x)
        set_item_quat:call(r, 1, rot.y)
        set_item_quat:call(r, 2, rot.z)
        set_item_quat:call(r, 3, rot.w)
        return
    end

    if ks_active() and rawget(_G, "__re4_railcar_mode") ~= true then return end

    local muzzle_pos = re4.last_muzzle_pos
    local muzzle_fwd = re4.last_muzzle_forward
    -- [LEAD-FIX] IMMER: den Muzzle-Joint LIVE im Feuer-Moment lesen statt aus dem on_frame-Cache. So sind
    -- Ursprung + Richtung so frisch wie der Feuer-Tick -> der latenzbedingte Vorhalte-Lead schrumpft (im
    -- Minecart am deutlichsten, aber ueberall gleichwertig-oder-besser). Joint tot (save/load) -> pcall -> Cache.
    if current_muzzle_joint then
        local lp = select(2, pcall(joint_get_position, current_muzzle_joint))
        local lf = select(2, pcall(function() return current_muzzle_joint:call("get_AxisZ") end))
        if lp and lf then muzzle_pos = lp; muzzle_fwd = lf end
    end
    if not muzzle_pos or not muzzle_fwd then return end

    local pos_addr = sdk.to_ptr(sdk.to_int64(args[3]))
    set_item_vec3:call(pos_addr, 0, muzzle_pos.x)
    set_item_vec3:call(pos_addr, 1, muzzle_pos.y)
    set_item_vec3:call(pos_addr, 2, muzzle_pos.z)

    local new_rotation = muzzle_fwd:normalized():to_quat()
    local rot_addr = sdk.to_ptr(sdk.to_int64(args[4]))
    set_item_quat:call(rot_addr, 0, new_rotation.x)
    set_item_quat:call(rot_addr, 1, new_rotation.y)
    set_item_quat:call(rot_addr, 2, new_rotation.z)
    set_item_quat:call(rot_addr, 3, new_rotation.w)
end

local function on_post_request_fire(retval)
    return retval
end

local function on_pre_rocket_generate(args)
    if not cfg.bullet_hook then return end
    if ks_active() and rawget(_G, "__re4_railcar_mode") ~= true then return end

    local muzzle_pos = re4.last_muzzle_pos
    local muzzle_fwd = re4.last_muzzle_forward
    if not muzzle_pos or not muzzle_fwd then return end

    local owner = sdk.to_managed_object(args[6])
    if not owner then return end
    if owner:get_type_definition():get_full_name() ~= "chainsaw.Gun" then return end

    local pos_addr = sdk.to_ptr(sdk.to_int64(args[3]))
    set_item_vec3:call(pos_addr, 0, muzzle_pos.x)
    set_item_vec3:call(pos_addr, 1, muzzle_pos.y)
    set_item_vec3:call(pos_addr, 2, muzzle_pos.z)

    local new_rotation = muzzle_fwd:normalized():to_quat()
    local rot_addr = sdk.to_ptr(sdk.to_int64(args[4]))
    set_item_quat:call(rot_addr, 0, new_rotation.x)
    set_item_quat:call(rot_addr, 1, new_rotation.y)
    set_item_quat:call(rot_addr, 2, new_rotation.z)
    set_item_quat:call(rot_addr, 3, new_rotation.w)
end

_G.__re4_vr_crosshair_pre_fire = on_pre_request_fire
_G.__re4_vr_crosshair_post_fire = on_post_request_fire
_G.__re4_vr_crosshair_pre_rocket = on_pre_rocket_generate

if not _G.__re4_vr_crosshair_hooks_installed then
    local function hook_method(type_name, method_name, pre_key, post_key)
        local td = sdk.find_type_definition(type_name)
        local method = td and td:get_method(method_name)
        if method then
            sdk.hook(method,
                function(args) return _G[pre_key](args) end,
                function(retval) return _G[post_key](retval) end)
        end
    end
    hook_method("chainsaw.BulletShellGenerator", "requestFire", "__re4_vr_crosshair_pre_fire", "__re4_vr_crosshair_post_fire")
    hook_method("chainsaw.ShotgunShellGenerator", "requestFire", "__re4_vr_crosshair_pre_fire", "__re4_vr_crosshair_post_fire")
    hook_method("chainsaw.RocketLauncherShellGenerator", "requestGenerate", "__re4_vr_crosshair_pre_rocket", "__re4_vr_crosshair_post_fire")
    _G.__re4_vr_crosshair_hooks_installed = true
end

-- =====================================================================
-- [PUBLIC-UI 2026-07-23] Ohne Tree im nackten Hauptmenue, 1:1 derselbe Schalter wie im Dev-Tree
-- (gleiches cfg-Feld, gleiches save_cfg): Dev heisst "Crosshair komplett aus", public "Disable
-- Crosshair" -- gleiche Richtung, Haken drin = Crosshair aus.
-- Beim Release fliegen alle [DEV-UI]-Bloecke raus, dieser bleibt.
-- =====================================================================
do
    local draw = function()
        local c, v = imgui.checkbox("Disable Crosshair", cfg.crosshair_off)
        if c then cfg.crosshair_off = v; save_cfg() end
    end
    -- Reihenfolge zentral ueber #re4_vr_menu.lua (Platz 30); ohne Dispatcher eigener Callback.
    local add = rawget(_G, "__re4_ui_add")
    if type(add) == "function" then add(30, "crosshair_off", draw) else re.on_draw_ui(draw) end
end

-- [DEV-UI] ---- UI (minimal) ----
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Crosshair" raus (57 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- ---- [HAND_HUDS] UI (Verstell-Slider) — genestet unter "RE4 VR Crosshair" ----
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4 VR — Hand-HUDs" raus (56 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

re.on_script_reset(function()
    crosshair_bullet_ray_result = nil
    crosshair_attack_ray_result = nil
    cached_pl_head = nil
    cached_gun_obj = nil
    cached_weapon_id = nil
    reticle_params_applied = false
    _G.__re4_vr_reticle_param_err_logged = nil
    scene = nil
    _G.is_aim = false
    _G.is_reticle_displayed = false
end)


-- ============================================================
-- [VR-LASER-FIX + TUNING] Killer7 & Laser-Sight-Aufsaetze.
-- Der native chainsaw.LaserSightController projiziert Strahl + Dot entlang der KAMERA (HMD) -> in VR tanzt er
-- und sitzt neben der Waffe. Fix: in updateLaser-POST das Strahl-GO (get_Line) an den SightEmitJoint (Muzzle)
-- tackern (Position + Rotation), und das 'Light'-GO (dem der Dot folgt) entlang der stabilen Emit-Achse ans
-- Strahl-Ende setzen (Raycast-Distanz = re4.crosshair_distance). Optik per UI. Material 'wpXXXX_00_Laserbeam':
-- 'AlphaRate'/'EmissiveIntensity' sind FLOAT-Params (set_ValueF). Farbe = ApplyColor(0xD0)+IsChangeColor(0xD4).
-- ============================================================
local LASER_CFG_PATH = "re4_vr/re4_vr_laser.json"
local laser_cfg = {
    enabled     = true,  width = 1.5, length = 2.4,
    force_color = false, r = 0.0, g = 1.0, b = 0.0,
    tune_glow   = true,  glow = 8.0, alpha = 0.03,
    smoke       = true,  smoke_amt = 0.28, smoke_speed = 30.0,
    dot_raycast = true,  dot_dist = 5.0, dot_size = 1.0,
}
local function save_laser_cfg() pcall(function() json.dump_file(LASER_CFG_PATH, laser_cfg) end) end
pcall(function()
    local d = json.load_file(LASER_CFG_PATH)
    if type(d) == "table" then for k, val in pairs(laser_cfg) do
        if d[k] ~= nil and type(d[k]) == type(val) then laser_cfg[k] = d[k] end
    end end
end)

local function laser_rgba(r, g, b, a)
    local R = math.floor((r or 0) * 255 + 0.5); local G = math.floor((g or 0) * 255 + 0.5)
    local B = math.floor((b or 0) * 255 + 0.5); local A = math.floor((a or 1) * 255 + 0.5)
    return R + G * 256 + B * 65536 + A * 16777216   -- via.Color = ABGR
end

local laser_this = nil
_G.__re4_laser_pre  = function(args) laser_this = nil; pcall(function() laser_this = sdk.to_managed_object(args[2]) end) end
_G.__re4_laser_post = function(retval)
    local this = laser_this; if not this then return retval end
    if not laser_cfg.enabled then return retval end
    pcall(function()
        if this:get_field("_IsDraw") ~= true then return end
        local emit = this:get_field("SightEmitJoint"); if not emit then return end
        local ep = emit:call("get_Position")
        local er = emit:call("get_Rotation")
        local ez = emit:call("get_AxisZ")

        -- [SMOKE] organische Zeit-Modulation (Dicke + Laenge + Alpha).
        local sm_w, sm_l, sm_alpha = 1.0, 1.0, 1.0
        if laser_cfg.smoke then
            local t  = os.clock() * laser_cfg.smoke_speed
            local n  = math.sin(t) * 0.5 + math.sin(t * 2.3 + 1.7) * 0.3 + math.sin(t * 5.1 + 3.0) * 0.2
            sm_w     = 1.0 + laser_cfg.smoke_amt * n
            sm_l     = 1.0 + laser_cfg.smoke_amt * 0.5 * math.sin(t * 2.3 + 1.7)
            sm_alpha = 1.0 - laser_cfg.smoke_amt * 0.5 * (0.5 + 0.5 * n)
        end

        -- (1) STRAHL an Emit-Joint (Position + Rotation) + Dicke/Laenge (LocalScale, smoke-moduliert).
        local line = this:call("get_Line")
        if line then local tf = line:call("get_Transform")
            if tf then
                if ep then tf:call("set_Position", ep) end
                if er then tf:call("set_Rotation", er) end
                local w = laser_cfg.width * sm_w
                pcall(function() tf:call("set_LocalScale", Vector3f.new(w, w, laser_cfg.length * sm_l)) end)
            end
        end

        -- (2) FARBE (optional): ApplyColor.
        if laser_cfg.force_color then
            pcall(function() this:write_dword(0xD0, laser_rgba(laser_cfg.r, laser_cfg.g, laser_cfg.b, 1.0)) end)
            pcall(function() this:write_byte(0xD4, 1) end)
        end

        -- (2b) TRANSPARENZ (AlphaRate) + GLOW (EmissiveIntensity) — FLOAT-Params -> set_ValueF.
        if laser_cfg.tune_glow or laser_cfg.smoke then
            local a = (laser_cfg.tune_glow and laser_cfg.alpha or 1.0) * sm_alpha
            pcall(function() local mp = this:call("get_PlayerLineAlphaMaterialParam"); if mp then mp:call("set_ValueF", a) end end)
            if laser_cfg.tune_glow then
                pcall(function() local mp = this:call("get_PlayerLineEmissiveMaterialParam"); if mp then mp:call("set_ValueF", laser_cfg.glow) end end)
            end
        end

        -- (3) DOT: 'Light'-GO (dem der Dot folgt) ans Strahl-Ende entlang stabiler Emit-Achse.
        if ep and ez then
            local dist = laser_cfg.dot_dist
            if laser_cfg.dot_raycast and tonumber(re4.crosshair_distance) then dist = re4.crosshair_distance end
            local endp = ep + (ez * dist)
            local light = this:call("get_Light")
            if light then local ltf = light:call("get_Transform")
                if ltf then
                    ltf:call("set_Position", endp)
                    pcall(function() ltf:call("set_LocalScale", Vector3f.new(laser_cfg.dot_size, laser_cfg.dot_size, laser_cfg.dot_size)) end)
                end
            end
        end
    end)
    return retval
end

if not _G.__re4_laser_track_installed then
    _G.__re4_laser_track_installed = true
    local ltd = sdk.find_type_definition("chainsaw.LaserSightController")
    local lm = ltd and (ltd:get_method("updateLaser()") or ltd:get_method("updateLaser"))
    if lm then
        sdk.hook(lm,
            function(args) local f = rawget(_G, "__re4_laser_pre"); if f then pcall(f, args) end end,
            function(retval) local f = rawget(_G, "__re4_laser_post"); if f then local ok, r = pcall(f, retval); if ok then return r end end; return retval end)
    end
end

-- =====================================================================
-- [PUBLIC-UI 2026-07-23] Laser-Farbe als Presets im nackten Hauptmenue statt Farbwaehler:
-- drei Knoepfe fuer voll Rot / voll Gruen / voll Blau. Jeder schreibt dieselben Felder wie der
-- Dev-Farbwaehler (laser_cfg.r/g/b) und schaltet "Farbe erzwingen" gleich mit ein -- ohne das
-- greift die Farbe nicht, und ein Preset, der nichts sichtbar tut, waere fuer Spieler ein Bug.
-- Beim Release fliegen alle [DEV-UI]-Bloecke raus, dieser bleibt.
-- =====================================================================
local function laser_preset(r, g, b)
    laser_cfg.force_color = true
    laser_cfg.r, laser_cfg.g, laser_cfg.b = r, g, b
    save_laser_cfg()
end

do
    -- Der aktive Preset faerbt seine eigene Schrift in seiner Farbe, die anderen bleiben weiss.
    -- Style-Index 0 = Text; die Farbwerte sind ABGR (0xAABBGGRR), deshalb steht Rot als 0xFF0000FF.
    local draw = function()
        local function preset_button(label, r, g, b, tint)
            local active = laser_cfg.force_color
                and math.abs((laser_cfg.r or 0) - r) < 0.01
                and math.abs((laser_cfg.g or 0) - g) < 0.01
                and math.abs((laser_cfg.b or 0) - b) < 0.01
            if active then imgui.push_style_color(0, tint) end
            if imgui.button(label) then laser_preset(r, g, b) end
            if active then imgui.pop_style_color(1) end
        end
        imgui.text_colored("Select Laser Color:", 0xFF00A5FF)   -- [KNALLIG 2026-07-24] Orange (2026-07-24)
        preset_button("Red",   1.0, 0.0, 0.0, 0xFF0000FF)
        imgui.same_line()
        preset_button("Green", 0.0, 1.0, 0.0, 0xFF00FF00)
        imgui.same_line()
        preset_button("Blue",  0.0, 0.0, 1.0, 0xFFFF0000)
        imgui.same_line()
        preset_button("Yellow", 1.0, 1.0, 0.0, 0xFF00FFFF)
    end
    -- Reihenfolge zentral ueber #re4_vr_menu.lua (Platz 40); ohne Dispatcher eigener Callback.
    local add = rawget(_G, "__re4_ui_add")
    if type(add) == "function" then add(40, "laser_color", draw) else re.on_draw_ui(draw) end
end

-- =====================================================================
-- [PUBLIC-UI 2026-07-23] Reticle-Farbe als Presets -- gleiche Farben wie beim Laser (Red/Green/
-- Blue). Setzt cfg.reticle_r/g/b und schaltet cfg.reticle_color (Farbe erzwingen) mit ein. Ohne das
-- bleibt der Punkt weiss. Aktiver Preset faerbt seine eigene Schrift. Platz 45 (direkt hinter Laser).
-- =====================================================================
local function reticle_preset(r, g, b)
    cfg.reticle_color = true
    cfg.reticle_r, cfg.reticle_g, cfg.reticle_b = r, g, b
    save_cfg()
end

do
    local draw = function()
        local function preset_button(label, r, g, b, tint)
            local active = cfg.reticle_color
                and math.abs((cfg.reticle_r or 0) - r) < 0.01
                and math.abs((cfg.reticle_g or 0) - g) < 0.01
                and math.abs((cfg.reticle_b or 0) - b) < 0.01
            if active then imgui.push_style_color(0, tint) end
            if imgui.button(label .. "##ret") then reticle_preset(r, g, b) end
            if active then imgui.pop_style_color(1) end
        end
        imgui.text_colored("Select Crosshair Color:", 0xFF00A5FF)   -- [KNALLIG 2026-07-24] Orange (2026-07-24)
        -- [WHITE 2026-07-24] Default ganz links: Weiss ist KEINE erzwungene Farbe, sondern
        -- cfg.reticle_color = false (siehe Dev-Schalter "Farbe erzwingen (sonst weiss)").
        do
            local active = not cfg.reticle_color
            if active then imgui.push_style_color(0, 0xFFFFFFFF) end
            if imgui.button("White##ret") then cfg.reticle_color = false; save_cfg() end
            if active then imgui.pop_style_color(1) end
            imgui.same_line()
        end
        preset_button("Red",   1.0, 0.0, 0.0, 0xFF0000FF)
        imgui.same_line()
        preset_button("Green", 0.0, 1.0, 0.0, 0xFF00FF00)
        imgui.same_line()
        preset_button("Blue",  0.0, 0.0, 1.0, 0xFFFF0000)
        imgui.same_line()
        preset_button("Yellow", 1.0, 1.0, 0.0, 0xFF00FFFF)
    end
    local add = rawget(_G, "__re4_ui_add")
    if type(add) == "function" then add(45, "reticle_color", draw) else re.on_draw_ui(draw) end
end

-- =====================================================================
-- [PUBLIC-UI 2026-07-24] Reticle-Groesse ohne Tree im nackten Hauptmenue. 1:1 derselbe
-- Slider wie im Dev-Tree (gleiches cfg.reticle_scale[wid], gleiches save_cfg) -- nur der Name
-- ist public ("Crosshair Size") und die Waffen-ID im Label entfaellt. Ohne equippte Waffe gibt
-- es nichts zu stellen -> Zeile bleibt einfach weg. Platz 46 (direkt hinter den Farb-Presets).
-- =====================================================================
do
    local draw = function()
        if not current_weapon_id then return end
        local key = tostring(current_weapon_id)
        local cur = cfg.reticle_scale[key] or 1.0
        local c, v = imgui.slider_float("Crosshair Size", cur, 0.25, 4.0, "%.2f")
        if c then cfg.reticle_scale[key] = v; save_cfg() end
    end
    local add = rawget(_G, "__re4_ui_add")
    if type(add) == "function" then add(46, "reticle_size", draw) else re.on_draw_ui(draw) end
end

-- [DEV-UI] Voller Laser-Tree (Strahl, Farbwaehler, Glow, Smokey) -- beim Public-Release entfaellt
-- dieser gesamte Block; die drei Farb-Presets oben bleiben.
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4 VR — Laser" raus (42 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- ---- [CLOSER] schliesst den Parent-Tree "RE4 VR Crosshair" nachdem die Kinder gerendert sind ----
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree (Closer) raus (3 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.
