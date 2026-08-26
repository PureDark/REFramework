-- Builtin implementation: src/mods/vr/games/re4/RE4VRReload3.cpp
return
-- =====================================================================
-- RE4 VR — Manual Reload 3: CHICAGO SWEEPER (wp4201) — eigene Gattung, eigenes File
-- Pfad: reframework/autorun/re4_vr_reload3.lua
-- =====================================================================
-- Komplett ABGEKAPSELT von re4_vr_reload.lua UND re4_vr_reload2.lua (beide kratzen
-- am Lua-200-Local-Limit). Hier lebt NUR der Chicago-Sweeper-Reload (Mag-Drop/Insert
-- + Slide-Rack). reload.lua managed 4201 NICHT mehr (aus smgs/JOINTS entfernt) ->
-- kein Konflikt. Wir publishen dieselben Slide-/Rack-/Mag-Globals wie reload.lua's
-- gemanagte SMG (motion/arm_chain/binding/holster lesen sie waffen-agnostisch).
--
-- WICHTIG: Der VERSTELLSCHALTER + BURST der Chicago bleiben in re4_vr_motion.lua
-- (gemeinsam mit der LE5, SWITCH_DOCK_WEAPONS/FIRE_MODE_CYCLE). Hier NICHT dupliziert.
-- reload3 fasst Switch/Burst NICHT an -> motion.lua laeuft unveraendert weiter.
--
-- Eigene Persistenz: reframework/data/re4_vr/re4_vr_reload3_chicago.json
-- Joints sind PLATZHALTER (mag=_14, slide=_01) -> im VR verifizieren/tunen.
-- =====================================================================

if reframework:get_game_name() ~= "re4" then return end

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function safe(fn) local ok, r = pcall(fn); return ok and r or nil end
local function sc(o, m, ...)
    if not o then return nil end
    local a = { ... }
    return safe(function() return o:call(m, table.unpack(a)) end)
end
local function sf(o, name) if not o then return nil end return safe(function() return o:get_field(name) end) end

-- Quaternion aus Euler-Grad (Quaternion.new ist W,X,Y,Z)
local function quat_from_euler(rx, ry, rz)
    local hx, hy, hz = math.rad(rx) * 0.5, math.rad(ry) * 0.5, math.rad(rz) * 0.5
    local qx = Quaternion.new(math.cos(hx), math.sin(hx), 0, 0)
    local qy = Quaternion.new(math.cos(hy), 0, math.sin(hy), 0)
    local qz = Quaternion.new(math.cos(hz), 0, 0, math.sin(hz))
    return qz * qy * qx
end
-- Right-Controller-B (rohe Flanke, von binding.lua publiziert)
local function right_b_down() return rawget(_G, "__vr_raw_r_bbutton") == true end

-- ---------------------------------------------------------------------
-- [POSE_FADE] Zeitbasierter Rueckblend der Insert-/Halte-Handpose (statt harter Snap zur nativen
-- Anim beim Loslassen). f = { name, data, release_t }. pose_fade_step(f, want, data): solange want
-- (Pose-Name) gesetzt -> (want, 1.0, data); danach ueber POSE_FADE_DUR auf 0 blenden, zuletzt
-- gehaltenen Namen + data behalten. os.clock-basiert (Apply laeuft mehrfach pro Frame). Gleiches
-- Muster wie in re4_vr_motion.lua / re4_vr_reload2.lua.
-- GLOBAL definiert (KEIN Local-Slot — reload2/3 sind am 200-Local-Limit). Geteilt mit reload2:
-- __re4_pose_fade_dur = Dauer (Sek. bis zurueck auf nativ, hoeher = weicher). Guarded -> egal welche
-- Datei zuerst laedt. Aufruf via _G.__re4_pose_fade_step(f, want, data) (Laufzeit -> immer definiert).
_G.__re4_pose_fade_dur = _G.__re4_pose_fade_dur or 0.10
if not _G.__re4_pose_fade_step then
    _G.__re4_pose_fade_step = function(f, want, data)
        if want and want ~= "" then f.name, f.data, f.release_t = want, data, nil; return want, 1.0, data end
        if not f.name then return nil, 0, nil end
        if not f.release_t then f.release_t = os.clock() end
        local el = os.clock() - f.release_t
        local dur = _G.__re4_pose_fade_dur or 0.10
        if el >= dur then f.name, f.data = nil, nil; return nil, 0, nil end
        return f.name, 1.0 - (el / dur), f.data
    end
end

-- ---------------------------------------------------------------------
-- Player / Waffe (minimal, eigenstaendig)
-- ---------------------------------------------------------------------
-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: dieselben Objekte wurden pro Frame
-- dutzendfach neu bei der Engine erfragt (get_equip_wid = vier Managed-Calls, body_tf = drei),
-- und die Waffen-Paesse laufen 4-5 mal pro Frame. Ab jetzt einmal pro Frame, danach aus einer
-- Lua-Tabelle. Semantik unveraendert -- die alten Wege stehen als Fallback darunter.
-- NOT-AUS: `_G.__re4_fc_off = true`. Bewusst OHNE Datei-Local (Lua-200-Local-Limit).
pcall(function() require("re4vr/re4_vr_frame_cache") end)
local character_manager = nil
local function get_ctx()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.ctx() end
    if not character_manager then character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager") end
    return character_manager and sc(character_manager, "getPlayerContextRef")
end
local function get_equip_wid()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.equip_wid() end
    local ctx = get_ctx(); if not ctx then return nil end
    local hu = sc(ctx, "get_HeadUpdater"); if not hu then return nil end
    local wid = sc(hu, "get_EquipWeaponID")
    if type(wid) == "userdata" then local b = sf(wid, "value__"); if type(b) == "number" then return b end end
    if type(wid) == "number" then return wid end
    return nil
end
local function body_tf()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.body_tf() end
    local ctx = get_ctx(); local b = ctx and sc(ctx, "get_BodyGameObject")
    return b and sc(b, "get_Transform")
end
local pe_td = sdk.typeof("chainsaw.PlayerEquipment")
local function get_pe()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.pe() end
    local ctx = get_ctx(); local head = ctx and sc(ctx, "get_HeadGameObject")
    return head and sc(head, "getComponent(System.Type)", pe_td)
end
local function find_weapon(wid)
    local bt = body_tf(); if not (bt and wid) then return nil, nil end
    -- [GO_SUFFIX 2026-07-19] s. re4_vr_motion.lua: GO kann "wp####", "_AO" oder "_MC" heissen.
    -- Reihenfolge wichtig -- wo ein plain-GO existiert, ist "_AO" nur der Schatten-Proxy.
    local base = string.format("wp%04d", wid)
    local name = base
    local function rec(tf, depth)
        if not tf or depth < 0 then return nil end
        local child = sc(tf, "get_Child"); local n = 0
        while child and n < 128 do
            n = n + 1
            local go = sc(child, "get_GameObject")
            local gn = go and sc(go, "get_Name")
            if gn and tostring(gn) == name and sc(go, "get_DrawSelf") ~= false then return go, child end
            local fgo, ftf = rec(child, depth - 1); if fgo then return fgo, ftf end
            child = sc(child, "get_Next")
        end
    end
    for _, suffix in ipairs({ "", "_AO", "_MC" }) do
        name = base .. suffix
        local go, tf = rec(bt, 5)
        if go then return go, tf end
    end
    return nil, nil
end

-- =====================================================================
-- CHICAGO-SWEEPER-GATTUNG (wp4201) — eigener, vollstaendig gekapselter Block
-- =====================================================================
-- Logik = LE5-SMG (Mag-Drop + Slide-Rack), 1:1 vom reload2-Rifle-Muster portiert,
-- aber OHNE Verstellschalter (der bleibt in motion.lua). Alles in einem do...end-Block,
-- damit die hier deklarierten Locals NACH dem Block frei werden; die re.on_*-Closures
-- leben ueber ihre Upvalues weiter.
-- =====================================================================
do
    local CHICAGO = { [4201] = true }   -- wp4201 Chicago Sweeper
    local function is_chicago(wid) return wid ~= nil and CHICAGO[wid] == true end
    local function ease(t) return t * t * (3.0 - 2.0 * t) end   -- smoothstep
    local _rack_near = false     -- Hand nah am Slide? (Upvalue fuer apply_hand_pose + on_frame)

    -- ---- Per-Waffe Joints (CODE-Konstanten, NIE aus JSON) ----
    -- Vom bestaetigt: Magazin = joint_04, Slide = joint_01 (wird bei Leer-Reload in Z zurueckgezogen,
    -- wie LE5; beim normalen Reload nicht). Die Slide-Z-Werte (rest/park/back) sind noch von LE5 _02 geseedet
    -- -> fuer _01 nachmessen/tunen (Diag loggt joint_01 Ruhe-Z; UI-Preview zum Justieren).
    local RJOINTS = {
        [4201] = { mag = "_04", slide = "_01" },
    }

    -- ---- Slide-Pose (absolute lokale Z + Hand-Dock-Offset/Rot), 1:1 von reload.lua's SLIDE_POSE[4201] ----
    -- [OPEN-BOLT] gemessen an joint_01: hinten/ready = -0.02336, vorne/leer = +0.08664 (Schuss-Peak).
    -- rest_z=back_z=hinten (chambered + Zieh-Ende); park_z=vorne (Leer-Zustand). Hub ~0.11.
    local RSLIDE_DEF = { rest_z = -0.02336, park_z = 0.08664, back_z = -0.02336, empty_x = 0.0,
                         dock_x = 0.045, dock_y = 0.032, dock_z = -0.192,
                         rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1,
                         st_rx = 0.0, st_ry = 0.0, st_rz = 0.0 }
    local RSLIDE = { [4201] = {} }
    local function rslide(wid)
        local sp = RSLIDE[wid]; if not sp then sp = {}; RSLIDE[wid] = sp end
        for k, v in pairs(RSLIDE_DEF) do if sp[k] == nil then sp[k] = v end end
        return sp
    end
    local function park_ref(sp) return ((sp.empty_x or 0) ~= 0) and sp.rest_z or sp.park_z end

    -- ---- Dock-Port (fester Gun-Joint + Offset) fuer die Einlege-Naehe ----
    local RDOCK_DEF = { joint = "_03", x = 0.0, y = 0.040, z = 0.060 }   -- Chicago: _03 + (0, 0.040, 0.060)
    local RDOCK = { [4201] = { joint = "_03", x = 0.0, y = 0.040, z = 0.060 } }
    local function rdock(wid)
        local d = RDOCK[wid]; if not d then d = {}; RDOCK[wid] = d end
        if d.joint == nil then d.joint = RDOCK_DEF.joint end
        d.x = d.x or 0; d.y = d.y or 0; d.z = d.z or RDOCK_DEF.z
        return d
    end

    -- ---- Mag-in-Hand Offset (Mag-Joint folgt der linken Hand) + Daumen-Spreizung ----
    local RMAGHAND = { [4201] = {} }
    local function rmaghand(wid)
        local m = RMAGHAND[wid]; if not m then m = {}; RMAGHAND[wid] = m end
        m.x = m.x or 0; m.y = m.y or 0; m.z = m.z or 0
        m.rx = m.rx or 0; m.ry = m.ry or 0; m.rz = m.rz or 0
        m.t_rx = m.t_rx or 0; m.t_ry = m.t_ry or 0; m.t_rz = m.t_rz or 0
        return m
    end

    -- ---- Hand-Posen: EIGENE DATEN-KOPIE (gestures-unabhaengig). reload.lua hatte fuer 4201 KEINE
    -- Mag-/Rack-Pose -> wir seeden die Stingray-Greifposen (links Mag halten / Slide ziehen) als
    -- sinnvollen Start. Im UI per Pose-Name aenderbar; tunebar via Daumen-Offsets. ----
    local RPOSES = {
        ["ChicagoMag"] = { hand="left", bones = { ["L_IndexF1"]={0.993446,0.042820,0.010770,-0.105429}, ["L_IndexF2"]={0.868657,0.000000,0.000000,-0.495415}, ["L_IndexF3"]={0.955468,0.000000,0.000000,-0.295095}, ["L_MiddleF1"]={0.964366,-0.034839,0.015712,-0.261795}, ["L_MiddleF2"]={0.812551,0.000000,0.000000,-0.582890}, ["L_MiddleF3"]={0.929199,0.000000,0.000000,-0.369579}, ["L_Palm"]={1.000000,0.000000,0.000000,0.000000}, ["L_PinkyF1"]={0.886025,-0.206433,0.097919,-0.403432}, ["L_PinkyF2"]={0.655536,0.000000,0.000000,-0.755164}, ["L_PinkyF3"]={0.800316,0.000000,0.000000,-0.599579}, ["L_RingF1"]={0.910646,-0.152227,0.095372,-0.372096}, ["L_RingF2"]={0.820979,0.000000,0.000000,-0.570959}, ["L_RingF3"]={0.918430,0.000000,0.000000,-0.395584}, ["L_Thumb1"]={0.954216,0.092758,-0.147124,-0.243356}, ["L_Thumb2"]={0.928704,0.047384,-0.316781,-0.186854}, ["L_Thumb3"]={0.976686,-0.002277,0.208568,0.050784} } },
        ["ChicagoSlide"] = { hand="left", bones = { ["L_IndexF1"]={0.962506,0.038342,-0.001037,-0.268536}, ["L_IndexF2"]={0.847117,0.000000,0.000000,-0.531406}, ["L_IndexF3"]={0.952203,0.000000,0.000000,-0.305466}, ["L_MiddleF1"]={0.938745,-0.015258,-0.024061,-0.343433}, ["L_MiddleF2"]={0.764522,0.000000,0.000000,-0.644598}, ["L_MiddleF3"]={0.964690,0.000000,0.000000,-0.263388}, ["L_Palm"]={1.000000,0.000000,0.000000,0.000000}, ["L_PinkyF1"]={0.933727,-0.083950,0.015837,-0.347642}, ["L_PinkyF2"]={0.881599,0.000000,0.000000,-0.471999}, ["L_PinkyF3"]={0.919535,0.000000,0.000000,-0.393009}, ["L_RingF1"]={0.938012,-0.058541,0.018805,-0.341106}, ["L_RingF2"]={0.813982,0.000000,0.000000,-0.580890}, ["L_RingF3"]={0.962837,0.000000,0.000000,-0.270083}, ["L_Thumb1"]={0.964133,0.166059,-0.014706,-0.206532}, ["L_Thumb2"]={0.992006,0.012628,-0.122927,0.025579}, ["L_Thumb3"]={0.982769,-0.006119,0.182809,-0.026611} } },
    }
    local RMAG_POSE  = { [4201] = "ChicagoMag" }    -- 1) linke Hand haelt Mag
    local RRACK_POSE = { [4201] = "ChicagoSlide" }  -- 2) linke Hand zieht am Slide

    -- Bone-Name -> Joint cachen, dann Pose direkt anwenden.
    local _pmap, _pmap_tf = {}, nil
    local function pose_map()
        local tf = body_tf(); if not tf then return {} end
        if tf == _pmap_tf and next(_pmap) ~= nil then return _pmap end
        local map = {}
        local joints = safe(function() return tf:call("get_Joints") end)
        if joints then
            local count = safe(function() return joints:call("get_Count") end)
            if type(count) == "number" then
                for i = 0, count - 1 do
                    local j = safe(function() return joints[i] end)
                    local nm = j and safe(function() return j:call("get_Name") end)
                    if nm then map[tostring(nm)] = j end
                end
            end
        end
        _pmap_tf, _pmap = tf, map
        return map
    end
    local function rf_pose_apply(name, blend)
        local pose = name and RPOSES[name]; if not (pose and pose.bones) then return false end
        local map = pose_map(); if next(map) == nil then return false end
        blend = blend or 1.0
        if blend <= 0.0 then return true end
        for bone, v in pairs(pose.bones) do
            local j = map[bone]
            if j and v and v[1] then
                if blend >= 0.9999 then
                    pcall(function() j:call("set_LocalRotation", Quaternion.new(v[1], v[2], v[3], v[4])) end)
                else
                    local c = sc(j, "get_LocalRotation")
                    if c then
                        local tw, tx, ty, tz = v[1], v[2], v[3], v[4]
                        if (c.w*tw + c.x*tx + c.y*ty + c.z*tz) < 0.0 then tw, tx, ty, tz = -tw, -tx, -ty, -tz end
                        local w, x, y, z = c.w+(tw-c.w)*blend, c.x+(tx-c.x)*blend, c.y+(ty-c.y)*blend, c.z+(tz-c.z)*blend
                        local len = math.sqrt(w*w + x*x + y*y + z*z)
                        if len > 1e-6 then pcall(function() j:call("set_LocalRotation", Quaternion.new(w/len, x/len, y/len, z/len)) end) end
                    end
                end
            end
        end
        return true
    end

    -- ---- Engine schliesst den Slide selbst nach dem Reload? (SMG/LE5 = true) -> wir forcen rest_z NICHT ----
    local RENGINE_CLOSES = { [4201] = true }

    -- ---- Sounds (per-wid, 1:1 von reload.lua's SOUNDS[4201]) ----
    local RSND = {
        [4201] = { dry_fire = 812850326, mag_eject = 1466005368, mag_insert = 1757452382,
                   mag_floor = 3140689763, slide_back = 943565871, slide_forward = 943565871,
                   mag_holster = 1839787494 },
    }

    -- ---- skalare Konfiguration ----
    local RCFG = { chicago_enabled = true, reload_ammo = true, sound_enabled = true, insert_distance = 0.15 }
    local RCFG_PATH = "re4_vr/re4_vr_reload3_chicago.json"

    local RSLIDE_FIELDS = { "rest_z","park_z","back_z","empty_x","dock_x","dock_y","dock_z","rack_rx","rack_ry","rack_rz","st_rx","st_ry","st_rz" }

    local function rload_cfg()
        local data = safe(function() return json.load_file(RCFG_PATH) end)
        if type(data) ~= "table" then return end
        local c = data.cfg or {}
        if type(c.chicago_enabled)== "boolean" then RCFG.chicago_enabled= c.chicago_enabled end
        if type(c.reload_ammo)    == "boolean" then RCFG.reload_ammo    = c.reload_ammo    end
        if type(c.sound_enabled)  == "boolean" then RCFG.sound_enabled  = c.sound_enabled  end
        if type(c.insert_distance)== "number"  then RCFG.insert_distance= c.insert_distance end
        if type(data.slide) == "table" then
            for k, v in pairs(data.slide) do local wid = tonumber(k)
                if wid and type(v) == "table" then local sp = rslide(wid)
                    for _, f in ipairs(RSLIDE_FIELDS) do if type(v[f]) == "number" then sp[f] = v[f] end end end end
        end
        if type(data.dock) == "table" then
            for k, v in pairs(data.dock) do local wid = tonumber(k)
                if wid and type(v) == "table" then local d = rdock(wid)
                    if type(v.joint) == "string" then d.joint = v.joint end
                    for _, f in ipairs({ "x","y","z" }) do if type(v[f]) == "number" then d[f] = v[f] end end end end
        end
        if type(data.maghand) == "table" then
            for k, v in pairs(data.maghand) do local wid = tonumber(k)
                if wid and type(v) == "table" then local m = rmaghand(wid)
                    for _, f in ipairs({ "x","y","z","rx","ry","rz","t_rx","t_ry","t_rz" }) do if type(v[f]) == "number" then m[f] = v[f] end end end end
        end
    end
    local function rsave_cfg()
        local slideo, docko, mho = {}, {}, {}
        for wid in pairs(CHICAGO) do
            local sp = rslide(wid); local so = {}; for _, f in ipairs(RSLIDE_FIELDS) do so[f] = sp[f] end; slideo[tostring(wid)] = so
            local d = rdock(wid); docko[tostring(wid)] = { joint = d.joint, x = d.x, y = d.y, z = d.z }
            local m = rmaghand(wid); mho[tostring(wid)] = { x=m.x,y=m.y,z=m.z, rx=m.rx,ry=m.ry,rz=m.rz, t_rx=m.t_rx,t_ry=m.t_ry,t_rz=m.t_rz }
        end
        pcall(function() json.dump_file(RCFG_PATH, { cfg = RCFG, slide = slideo, dock = docko, maghand = mho }) end)
    end
    rload_cfg()

    -- ---- Sound am Waffen-SoundContainer ----
    local snd_td = sdk.typeof("soundlib.SoundContainer")
    local rwep = { wid = nil, tf = nil, mag_joint = nil, slide_joint = nil,
                   slide_rest_lp = nil, rest_lp = nil, rest_lr = nil }
    local _reacquired = false   -- [SAVE_LOAD] gleiche Waffe neu instanziiert
    local function rf_snd(id)
        if not RCFG.sound_enabled or not id or id <= 0 then return end
        local tf = rwep.tf; if not (tf and snd_td) then return end
        local go = safe(function() return tf:call("get_GameObject") end); if not go then return end
        local scn = safe(function() return go:call("getComponent(System.Type)", snd_td) end); if not scn then return end
        pcall(function() scn:call("trigger(System.UInt32)", id) end)
    end
    local function rsnd(wid, key) local t = wid and RSND[wid]; return t and t[key] or nil end

    -- ---- gemanagte Chicago? ----
    local function rmanaged_wid()
        if not RCFG.chicago_enabled then return nil end
        local wid = get_equip_wid()
        if not is_chicago(wid) then return nil end
        return wid
    end
    local function rf_refresh()
        local wid = rmanaged_wid()
        if not wid then
            rwep.wid, rwep.tf, rwep.mag_joint, rwep.slide_joint = nil, nil, nil, nil
            return
        end
        if rwep.wid == wid and rwep.mag_joint and rwep.tf and safe(function() return rwep.tf:call("get_Position") end) then return end
        local same_wid = (rwep.wid == wid)
        rwep.wid, rwep.tf, rwep.mag_joint, rwep.slide_joint = nil, nil, nil, nil
        local jc = RJOINTS[wid]; if not (jc and jc.mag) then return end
        local go, tf = find_weapon(wid); if not tf then return end
        local mj = sc(tf, "getJointByName", jc.mag); if not mj then return end
        rwep.wid, rwep.tf, rwep.mag_joint = wid, tf, mj
        rwep.slide_joint  = (jc.slide  and jc.slide  ~= "") and sc(tf, "getJointByName", jc.slide)  or nil
        rwep.slide_rest_lp = nil
        if rwep.slide_joint then
            local lp = sc(rwep.slide_joint, "get_LocalPosition")
            if lp then rwep.slide_rest_lp = { x = lp.x, y = lp.y, z = lp.z } end
        end
        if same_wid then _reacquired = true end
    end

    -- ---- chainsaw.Gun (Leer-Erkennung + Slide-Entriegeln nach Rack) ----
    local _state_td = sdk.find_type_definition("chainsaw.Gun.State")
    local _gun_holding = _state_td and safe(function() return _state_td:get_field("Holding"):get_data(nil) end)
    local function get_gun()
        local pe = get_pe(); if not pe then return nil end
        local wl = safe(function() return pe:get_field("WeaponList") end); if not wl then return nil end
        local ewid = get_equip_wid(); if not ewid then return nil end
        for _, key in ipairs({ safe(function() return pe:call("get_EquipWeaponID") end), ewid }) do
            if key ~= nil then
                local a = safe(function() return wl:call("get_Item", key) end)
                if a and safe(function() return a:call("get_CurrentState") end) ~= nil then return a end
            end
        end
        return nil
    end
    local function gun_chamber()
        local g = get_gun(); if not (g and _gun_holding ~= nil) then return end
        pcall(function() g:call("set_CurrentState(chainsaw.Gun.State)", _gun_holding) end)
    end
    local function gun_ammo_empty()
        local pe = get_pe()
        return (pe and safe(function() return pe:call("isGunAmmoEmpty") end)) == true
    end

    -- ---- Live-WeaponItem + Ammo-Helfer (gegen die EQUIPPTE wid validiert) ----
    local function rf_get_wi()
        local ewid = get_equip_wid()
        -- [ACCESSOR 2026-08-12] ZUERST die einzige PERSISTENTE Instanz. Alles darunter
        -- (__re4_live_wi, getEquipWeaponItem) sind KOPIEN: Schreiben wirkt dort im selben Tick
        -- und ist danach weg -- deshalb "verpufften" hier alle Buchungen und der native
        -- inv:reload blieb der einzige Weg, der lud (und beim Bogen zuverlaessig crashte).
        -- Belegt am 12.08.: @acc/@get_Item bleiben ueber alle Ticks stabil, waehrend die
        -- Kopien jeden Tick eine neue Adresse haben. Siehe [[reference_re4_echte_weaponitem_instanz]].
        -- Rueckbau: _G.__re4_use_accessor_item = false
        if rawget(_G, "__re4_use_accessor_item") ~= false then
            local pe_a = get_pe()
            local acc  = pe_a and safe(function() return pe_a:call("getEquipWeaponAccessor") end)
            local real = acc and safe(function() return acc:call("get_Item") end)
            if real and safe(function() return real:call("get_CurrentAmmoCount") end) ~= nil then
                local rwid = safe(function() return real:call("get_WeaponId"):get_field("value__") end)
                if ewid == nil or rwid == nil or rwid == ewid then return real end
            end
        end
        local wi = rawget(_G, "__re4_live_wi")
        if wi and safe(function() return wi:call("get_CurrentAmmoCount") end) ~= nil then
            local cwid = safe(function() return wi:call("get_WeaponId"):get_field("value__") end)
            if cwid and ewid and cwid == ewid then return wi end   -- STRIKT: nur cachen wenn gleiche Waffe (kein stale)
        end
        local pe = get_pe()
        local ewi = pe and safe(function() return pe:call("getEquipWeaponItem") end)
        if ewi and safe(function() return ewi:call("get_CurrentAmmoCount") end) ~= nil then return ewi end
        return nil
    end
    local function rf_loaded()
        local wi = rf_get_wi(); if not wi then return nil end
        return tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end))
    end
    local function rf_cap()
        local wi = rf_get_wi(); if not wi then return 0 end
        return tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0
    end
    local function rf_reserve()
        local wi = rf_get_wi(); if not wi then return 0 end
        local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end); if not ammo_id then return 0 end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController"); if not inv then return 0 end
        return tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0
    end

    -- ---- [STAGE-DETECT] Ausbaustufen-Grundstein ----
    -- ---- VR-Input (frische Handles jeden Frame) ----
    local function left_grip_down()
        if not vrmod then return false end
        local act, lj
        pcall(function() act = vrmod:get_action_grip() end)
        pcall(function() lj  = vrmod:get_left_joystick() end)
        if not (act and lj) then return false end
        local ok, v = pcall(function() return vrmod:is_action_active(act, lj) end)
        return ok and v == true
    end
    local _rack_lj = nil
    local function rack_haptic(amp, dur)
        if not vrmod then return end
        if not _rack_lj then pcall(function() _rack_lj = vrmod:get_left_joystick() end) end
        if _rack_lj then pcall(function() vrmod:trigger_haptic_vibration(0.0, dur or 0.06, 169.385, amp or 0.9, _rack_lj) end) end
    end
    local function left_hand_world()
        local hp = rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
        if hp then return hp end
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        return lh and sc(lh, "get_Position")
    end

    -- =====================================================================
    -- Mag-Drop / Mag-in-Hand / Insert
    -- =====================================================================
    local GRAVITY = 9.8
    local DROP_FALL_DUR = 1.0
    local drop = { active = false, use_module = false, joint = nil, sx = 0, sy = 0, sz = 0, t0 = 0 }
    local _mag_floor_at   = 0
    local _floor_delay        = 0.45
    local _floor_delay_module = 0.78
    local mag_hand = { active = false }
    local mag_insert = { active = false, t0 = 0, dur = 0.18, slp = nil, slr = nil }
    local mag_out = false
    local mag_retained = 0
    local mag_tune = { active = false }
    local _flow = function() return drop.active or mag_hand.active or mag_insert.active or mag_tune.active end

    local rack = { needs = false, empty_when_dropped = false, grab_active = false, armed = false,
                   frac = 0, pulled = false, gx = 0, gy = 0, gz = 0, dock_blend = 0,
                   _ammo_input_t = nil, empty = false, _chambered_hold = false, tuning = false, tune_frac = 0,
                   dock_tune = false }

    local function rf_capture_mag_rest()
        if not rwep.mag_joint then return end
        if _flow() or mag_out then return end
        local lp = sc(rwep.mag_joint, "get_LocalPosition")
        local lr = sc(rwep.mag_joint, "get_LocalRotation")
        if lp then rwep.rest_lp = { x = lp.x, y = lp.y, z = lp.z } end
        if lr then rwep.rest_lr = { w = lr.w, x = lr.x, y = lr.y, z = lr.z } end
    end

    local function stop_drop()
        if drop.use_module then local ms = _G.__re4_reload_mag_slide; if ms then pcall(function() ms.cancel() end) end end
        drop.active, drop.joint, drop.use_module = false, nil, false
    end
    local function start_drop_from(p, use_module)
        if use_module and rwep.mag_joint then
            local ms = _G.__re4_reload_mag_slide
            if ms then
                local ok = ms.begin_drop(rwep.mag_joint, rwep.wid, mag_insert.dur)
                if ok then drop.active, drop.use_module, drop.joint = true, true, rwep.mag_joint; return true end
            end
        end
        if not p then return false end
        drop.joint = rwep.mag_joint
        drop.use_module = false
        drop.sx, drop.sy, drop.sz = p.x, p.y, p.z
        drop.t0 = os.clock(); drop.active = true
        return true
    end
    local function rf_force_eject()
        if _G.__re4_is_unlimited and _G.__re4_is_unlimited() then return false end   -- [UNLIMITED] B stillgelegt
        rf_refresh()
        if not rwep.mag_joint then return false end
        if mag_out then return false end
        -- [KEIN DROP OHNE RESERVE 2026-08-12] Ohne Nachschub wird das Magazin gar nicht erst
        -- ausgeworfen -- gilt fuer JEDE Waffe, nicht nur fuer die, bei der es auffiel.
        if (tonumber(rf_reserve()) or 0) <= 0 then
            return false
        end
        -- [LIVE-EMPTY 2026-07-08] Frischer Engine-Read (getCurrentGunAmmo, kein Cache) statt rf_loaded
        -- (__re4_live_wi -> stale 0 nach Save-Load -> empty_when_dropped faelschlich true -> Dauer-Dry-Fire).
        do
            local _pe = get_pe()
            local _fga = _pe and tonumber(safe(function() return _pe:call("getCurrentGunAmmo") end))
            if _fga ~= nil then rack.empty_when_dropped = (_fga <= 0)
            else rack.empty_when_dropped = ((rf_loaded() or 0) <= 0) end
            -- [KAMMER 2026-08-12] Der Read oben kann bereits UNSERE 0 sehen (mehrere Stellen nullen
            -- die Waffe beim Auswurf). War beim Nullen etwas im Magazin, war die Kammer NICHT leer
            -- -> kein Rack verlangen. Quelle ist der gemerkte Magazinrest.
            if (tonumber(rawget(_G, "__re4_mag_carry")) or 0) > 0 then rack.empty_when_dropped = false end
        end
        rack._chambered_hold = false
        mag_hand.active = false; mag_insert.active = false
        if RCFG.reload_ammo then
            mag_retained = loaded
            local wi = rf_get_wi(); if wi then _G.__re4_carry_capture(wi, "re4_vr_reload3.lua:481", nil); pcall(function() wi:write_dword(0x44, 0) end) end
            -- [ACCESSOR-FOLGE 2026-08-12] Diese 0 ist UNSER Werk und wirkt seit dem Accessor-Umbau
            -- wirklich. `rack.empty` darf sie beim Einsetzen nicht als leere Kammer werten.
            rack._zeroed_by_us = true
        end
        if rwep.rest_lp then pcall(function() rwep.mag_joint:call("set_LocalPosition", Vector3f.new(rwep.rest_lp.x, rwep.rest_lp.y, rwep.rest_lp.z)) end) end
        if rwep.rest_lr then pcall(function() rwep.mag_joint:call("set_LocalRotation", Quaternion.new(rwep.rest_lr.w, rwep.rest_lr.x, rwep.rest_lr.y, rwep.rest_lr.z)) end) end
        local p = sc(rwep.mag_joint, "get_Position")
        local started = start_drop_from(p, true)
        if started then
            mag_out = true; rf_snd(rsnd(rwep.wid, "mag_eject"))
            _mag_floor_at = os.clock() + (drop.use_module and _floor_delay_module or _floor_delay)
        end
        return started
    end
    local function update_drop()
        if not drop.active then return end
        if drop.use_module then
            local ms = _G.__re4_reload_mag_slide
            if ms then pcall(function() ms.tick() end) else stop_drop() end
            return
        end
        if not drop.joint then return end
        local t = os.clock() - drop.t0
        if t > DROP_FALL_DUR then drop.active, drop.joint = false, nil; return end
        local fall = 0.5 * GRAVITY * t * t
        pcall(function() drop.joint:call("set_Position", Vector3f.new(drop.sx, drop.sy - fall, drop.sz)) end)
    end

    local function rf_can_grab()
        if mag_hand.active or mag_insert.active then return false end
        if not mag_out then return false end
        return ((mag_retained or 0) + rf_reserve()) > 0
    end
    local function chicago_set_mag_in_hand(active)
        if active then
            if not rf_can_grab() then return false end
            stop_drop()
            mag_hand.active = true
            rf_snd(rsnd(rwep.wid, "mag_holster"))
            return true
        end
        if mag_hand.active then
            mag_hand.active = false
            local p = rwep.mag_joint and sc(rwep.mag_joint, "get_Position")
            if start_drop_from(p) then _mag_floor_at = os.clock() + _floor_delay end
        end
        return true
    end

    local function update_mag_in_hand()
        local joint = ((mag_hand.active or mag_tune.active) and rwep.mag_joint) or nil
        if not joint then return end
        local m = rmaghand(rwep.wid or 0)
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position"); if not hp then return end
        local hr = lh and sc(lh, "get_Rotation")
        local wx, wy, wz = hp.x, hp.y, hp.z
        if hr then
            local off = safe(function() return hr * Vector3f.new(m.x, m.y, m.z) end)
            if off then wx, wy, wz = hp.x + off.x, hp.y + off.y, hp.z + off.z end
        end
        pcall(function() joint:call("set_Position", Vector3f.new(wx, wy, wz)) end)
        if hr then
            local rot = safe(function() return (hr * quat_from_euler(m.rx, m.ry, m.rz)):normalized() end)
            if rot then pcall(function() joint:call("set_Rotation", rot) end) end
        end
    end

    local function dock_port_world()
        local d = rdock(rwep.wid or 0); if not rwep.tf then return nil end
        local j = sc(rwep.tf, "getJointByName", d.joint); if not j then return nil end
        local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation"); if not (jp and jr) then return nil end
        local off = safe(function() return jr * Vector3f.new(d.x, d.y, d.z) end); if not off then return nil end
        return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
    end

    local function start_insert()
        if not (rwep.mag_joint and rwep.rest_lp) then return false end
        local lp = sc(rwep.mag_joint, "get_LocalPosition"); if not lp then return false end
        local lr = sc(rwep.mag_joint, "get_LocalRotation")
        mag_insert.slp = { x = lp.x, y = lp.y, z = lp.z }
        mag_insert.slr = lr and { w = lr.w, x = lr.x, y = lr.y, z = lr.z } or nil
        mag_insert.t0 = os.clock(); mag_insert.active = true; mag_insert.snd = false
        return true
    end
    local function check_insert_proximity()
        if not mag_hand.active then return end
        local hp = left_hand_world(); if not hp then return end
        local gp = dock_port_world() or (rwep.tf and sc(rwep.tf, "get_Position")); if not gp then return end
        local d = math.sqrt((hp.x-gp.x)^2 + (hp.y-gp.y)^2 + (hp.z-gp.z)^2)
        if d <= (RCFG.insert_distance or 0.15) then mag_hand.active = false; start_insert() end
    end
    local function reload_ammo_on_insert()
        if not RCFG.reload_ammo then return end
        local wi = rf_get_wi(); if not wi then return end
        local cap = rf_cap()
        local reserve = rf_reserve()
        local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end)
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        local target = math.min(cap, (mag_retained or 0) + reserve)
        local used = math.max(0, target - (mag_retained or 0))
        -- [RUNTIME-FIX 0/0 + MAG-RETAIN] zwei Quellen: (1) Reserve-Anteil `used` via Engine-Reload
        -- (greift aufs echte Gun-Item, zieht Reserve), (2) Retained-Anteil (gedropptes Mag, schon bezahlt)
        -- frei auf target auffuellen OHNE Reserve-Abzug. Frueher: alles auf used>0 gegated -> bei reserve=0
        -- + retained>0 wurde nichts geladen = 0.
        local function gun_ammo() return pe and tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or nil end
        local _et_td = sdk.find_type_definition("chainsaw.EquipType")
        local et = _et_td and safe(function() return _et_td:get_field("Main"):get_data(nil) end)
        local r_b4 = reserve
        local function read_rsv() return (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or r_b4) or r_b4 end
        local b4 = gun_ammo() or 0
        if et and inv and used > 0 then
            if _G.__re4_safe_inv_reload then _G.__re4_load_and_book(inv, et, used, false) end   -- [CRASH-HARDEN 2026-07-17] engine-Gate enableReloadItem gegen null-Item-AV
        end
        local af = gun_ammo() or b4
        local got = math.max(0, af - b4)
        if got > 0 and inv and ammo_id and read_rsv() >= r_b4 then
            _G.__re4_safe_reduce(inv, ammo_id, got)
        end
        if (gun_ammo() or af) < target then   -- (2) Retained-Anteil auffuellen (frei, kein Reserve-Abzug)
            pcall(function() wi:write_dword(0x44, target) end)
            local now = gun_ammo() or (b4 + got)
            if now < target and wi then pcall(function() wi:call("addAmmoCount", target - now, false) end) end
        end
        mag_retained = 0
    end
    local function update_insert()
        if not (mag_insert.active and rwep.mag_joint and mag_insert.slp and rwep.rest_lp) then return end
        local t = (os.clock() - mag_insert.t0) / math.max(mag_insert.dur, 0.01)
        if t > 1.0 then t = 1.0 end
        if not mag_insert.snd and t >= 0.75 then mag_insert.snd = true; rf_snd(rsnd(rwep.wid, "mag_insert")) end
        local u = ease(t)
        local a, b = mag_insert.slp, rwep.rest_lp
        pcall(function() rwep.mag_joint:call("set_LocalPosition", Vector3f.new(a.x+(b.x-a.x)*u, a.y+(b.y-a.y)*u, a.z+(b.z-a.z)*u)) end)
        if mag_insert.slr and rwep.rest_lr then
            local s, r = mag_insert.slr, rwep.rest_lr
            local rw, rx, ry, rz = r.w, r.x, r.y, r.z
            if (s.w*rw + s.x*rx + s.y*ry + s.z*rz) < 0 then rw, rx, ry, rz = -rw, -rx, -ry, -rz end
            local w, x, y, z = s.w+(rw-s.w)*u, s.x+(rx-s.x)*u, s.y+(ry-s.y)*u, s.z+(rz-s.z)*u
            local len = math.sqrt(w*w+x*x+y*y+z*z)
            if len > 1e-6 then pcall(function() rwep.mag_joint:call("set_LocalRotation", Quaternion.new(w/len, x/len, y/len, z/len)) end) end
        end
        if t >= 1.0 then
            mag_insert.active = false
            rack._ammo_input_t = os.clock()
            mag_out = false
            -- [NO-SLIDE-GUARD] Chicago hat (bisher) keinen erkannten Slide-Joint (joint_02 fehlt). Ohne
            -- Slide-Joint gibt es keinen Rack -> NIE rack.needs setzen (sonst Feuer-Softlock), stattdessen
            -- direkt chambern. Nur wenn ein Slide-Joint existiert, den Empty-Rack verlangen.
            -- [LEERE KAMMER 2026-07-23] zusaetzlich `rack.empty` -- nach einem Waffenwechsel ist
            -- empty_when_dropped geloescht, die Kammer aber leer. Slide-Joint-Guard bleibt zwingend.
            -- [ACCESSOR-FOLGE 2026-08-12] `rack.empty` zaehlt nur, wenn die 0 NICHT von unserem
            -- eigenen Mag-Drop-Leeren stammt (Waffenwechsel-Fall bleibt erhalten).
            if (rack.empty_when_dropped
                or (rack.empty and rack._zeroed_by_us ~= true)) and rwep.slide_joint then rack.needs = true else
                rack.needs = false
                rack._zeroed_by_us = false   -- Merker verbraucht
                if rack.empty_when_dropped and not rwep.slide_joint then gun_chamber() end
                if rwep.slide_joint and not RENGINE_CLOSES[rwep.wid] then
                    local cur = sc(rwep.slide_joint, "get_LocalPosition")
                    if cur then local sp = rslide(rwep.wid or 0)
                        pcall(function() rwep.slide_joint:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp.rest_z)) end) end
                end
            end
            rack.empty_when_dropped = false
            reload_ammo_on_insert()
        end
    end

    -- =====================================================================
    -- Slide-Rack (Pull-Geste)
    -- =====================================================================
    local RACK_GRAB_DIST = 0.14
    local function clear_rack()
        rack.needs = false; rack.grab_active = false; rack.pulled = false; rack.frac = 0
        gun_chamber()
        if RENGINE_CLOSES[rwep.wid] then rack._chambered_hold = false; return end
        rack._chambered_hold = true
        if rwep.slide_joint then
            local cur = sc(rwep.slide_joint, "get_LocalPosition")
            if cur then local sp = rslide(rwep.wid or 0)
                pcall(function() rwep.slide_joint:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp.rest_z)) end) end
        end
    end
    local function update_rack_gesture()
        if rack.tuning then return end
        if not rack.needs then
            rack.grab_active = false; rack.pulled = false; rack.frac = 0; rack.armed = false; return
        end
        local sj = rwep.slide_joint; if not sj then return end
        local hp = left_hand_world(); local sp = sc(sj, "get_Position")
        local grip = left_grip_down()
        if not (hp and sp) then return end
        local dist = math.sqrt((hp.x-sp.x)^2 + (hp.y-sp.y)^2 + (hp.z-sp.z)^2)
        if not rack.grab_active then
            if mag_hand.active then rack.armed = false; return end
            if rack._ammo_input_t and (os.clock() - rack._ammo_input_t) < 0.2 then rack.armed = false; return end
            if not grip then rack.armed = true; return end
            if not rack.armed then return end
            if dist <= RACK_GRAB_DIST then
                rack.grab_active = true; rack.armed = false; rack.pulled = false; rack.frac = 0
                rack.gx, rack.gy, rack.gz = hp.x, hp.y, hp.z
                -- [LAUFEN 2026-08-12] Zweiter Anker: die Waffenhand. Ohne ihn steckt die Fortbewegung im Zug
                -- (Gehen/Drehen bewegt BEIDE Haende) und der Slide ging nur im Stand.
                do local _rhr = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos"); rack.rgx, rack.rgy, rack.rgz = _rhr and _rhr.x or nil, _rhr and _rhr.y or nil, _rhr and _rhr.z or nil end
                rack_haptic(0.25, 0.03)
            end
            return
        end
        if grip then
            local sp_pose = rslide(rwep.wid or 0)
            local travel = math.max(math.abs(sp_pose.back_z - park_ref(sp_pose)), 0.005)
            local px, py, pz = hp.x - rack.gx, hp.y - rack.gy, hp.z - rack.gz
            -- [LAUFEN 2026-08-12] Bewegung der Waffenhand abziehen -> uebrig bleibt die Bewegung der
            -- Ziehhand GEGEN die Waffe. Rueckbau: _G.__re4_rack_relative = false
            if rack.rgx and rawget(_G, "__re4_rack_relative") ~= false then
                local _rhn = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
                if _rhn then px = px - (_rhn.x - rack.rgx); py = py - (_rhn.y - rack.rgy); pz = pz - (_rhn.z - rack.rgz) end
            end
            local srot = sc(sj, "get_Rotation")
            local bd = srot and safe(function() return srot * Vector3f.new(0, 0, -1) end)
            local pull
            if bd then
                local bl = math.sqrt(bd.x*bd.x + bd.y*bd.y + bd.z*bd.z)
                if bl > 1e-6 then bd = Vector3f.new(bd.x/bl, bd.y/bl, bd.z/bl) end
                pull = px*bd.x + py*bd.y + pz*bd.z; if pull < 0 then pull = 0 end
            else pull = math.sqrt(px*px+py*py+pz*pz) end
            local f = pull / travel; rack.frac = (f > 1.0) and 1.0 or f
            if rack.frac >= 1.0 and not rack.pulled then rack.pulled = true; rf_snd(rsnd(rwep.wid, "slide_back")) end
            return
        end
        if rack.pulled then
            clear_rack(); rack_haptic(0.95, 0.07); rf_snd(rsnd(rwep.wid, "slide_forward"))
        else
            rack.grab_active = false; rack.frac = 0; rack.pulled = false; rack.armed = true
        end
    end

    -- Dock-Ziel (Hand folgt dem Slide) publizieren. NUR Slide-Rack (Switch ist in motion.lua).
    local DOCK_BLEND_SPEED = 0.10
    local function update_dock_publish(advance)
        local src_joint, ox, oy, oz, rrx, rry, rrz
        local want = 0.0
        if (rack.grab_active or rack.dock_tune) and rwep.slide_joint then
            local sd = rslide(rwep.wid or 0)
            src_joint = rwep.slide_joint
            ox, oy, oz = sd.dock_x, sd.dock_y, sd.dock_z
            rrx, rry, rrz = sd.rack_rx, sd.rack_ry, sd.rack_rz
            want = 1.0
        end
        local b = rack.dock_blend or 0
        if advance then
            if b < want then b = math.min(b + DOCK_BLEND_SPEED, want) elseif b > want then b = math.max(b - DOCK_BLEND_SPEED, want) end
            rack.dock_blend = b
        end
        if b > 0.001 and src_joint then
            local p = sc(src_joint, "get_Position"); local r = sc(src_joint, "get_Rotation")
            if p and r and (ox ~= 0 or oy ~= 0 or oz ~= 0) then
                local off = safe(function() return r * Vector3f.new(ox, oy, oz) end)
                if off then p = Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
            end
            if r and (rrx ~= 0 or rry ~= 0 or rrz ~= 0) then
                r = safe(function() return (r * quat_from_euler(rrx, rry, rrz)):normalized() end) or r
            end
            _G.__vr_slide_hand_world_pos = p
            _G.__vr_slide_hand_world_rot = r
            _G.__vr_slide_dock_blend_factor = b * b * (3.0 - 2.0 * b)
        else
            _G.__vr_slide_hand_world_pos = nil
            _G.__vr_slide_hand_world_rot = nil
            _G.__vr_slide_dock_blend_factor = 0
        end
    end

    -- [TEMP MEASURE] true = Slide NICHT forcen (Mess-Modus). Werte gemessen+geseedet -> aus.
    local _MEASURE_SLIDE = false
    -- [OPEN-BOLT] Die Engine laesst den Bolzen bei LEER hinten -> wir halten ihn vorne (park_z).
    -- Force NUR bei echtem Ammo-Count==0 (rack._loaded) + Reload-Wartezustand (rack.needs) + manuellem
    -- Zug/Tuning. NICHT an gun_ammo_empty haengen (flackert beim Feuern -> killt die Schnalz-Animation).
    -- Normal feuern (loaded>0) -> NIE geforct -> Engine-Schnalz bleibt erhalten.
    local function apply_slide_park()
        if _MEASURE_SLIDE then return end
        if not rwep.slide_joint then return end
        local empty_now = (rack._loaded == 0)
        if not (rack.grab_active or rack.tuning or empty_now or rack.needs) then return end
        local cur = sc(rwep.slide_joint, "get_LocalPosition"); if not cur then return end
        local sp = rslide(rwep.wid or 0)
        local pz = park_ref(sp)   -- park_z = vorne (Leer-Position)
        local z
        if rack.tuning then z = pz + (sp.back_z - pz) * rack.tune_frac
        elseif rack.grab_active then z = pz + (sp.back_z - pz) * rack.frac   -- Zug: vorne -> hinten
        else z = pz end                                                     -- leer: Bolzen vorne halten
        pcall(function() rwep.slide_joint:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, z)) end)
    end

    local _mag_hidden = false
    local function apply_mag_out_hidden()
        local should_hide = mag_out and rwep.mag_joint and not _flow()
        if should_hide then pcall(function() rwep.mag_joint:call("set_LocalScale", Vector3f.new(0, 0, 0)) end); _mag_hidden = true
        elseif _mag_hidden then if rwep.mag_joint then pcall(function() rwep.mag_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end) end; _mag_hidden = false end
    end

    -- Hand-Pose direkt anwenden (Mag-Halten / Slide-Rack). KEIN Switch (motion.lua).
    local _hand_fade = {}
    local function apply_hand_pose()
        local name, thumb = nil, nil
        if mag_hand.active or mag_insert.active or mag_tune.active then
            name = RMAG_POSE[rwep.wid]; thumb = rmaghand(rwep.wid or 0)
        elseif rack.dock_tune or (rack.needs and (rack.grab_active or _rack_near)) then
            name = RRACK_POSE[rwep.wid]
            local sp = rslide(rwep.wid or 0); thumb = { t_rx = sp.st_rx, t_ry = sp.st_ry, t_rz = sp.st_rz }
        end
        -- [POSE_FADE] beim Loslassen ueber POSE_FADE_DUR zurueckblenden statt snappen
        local fname, b, fthumb = _G.__re4_pose_fade_step(_hand_fade, name, thumb)
        if not fname then return end
        rf_pose_apply(fname, b)
        if fthumb and (fthumb.t_rx ~= 0 or fthumb.t_ry ~= 0 or fthumb.t_rz ~= 0) then
            local bt = body_tf(); local tj = bt and sc(bt, "getJointByName", "L_Thumb1")
            local cur = tj and sc(tj, "get_LocalRotation")
            if cur then pcall(function() tj:call("set_LocalRotation", (cur * quat_from_euler(fthumb.t_rx*b, fthumb.t_ry*b, fthumb.t_rz*b)):normalized()) end) end
        end
    end

    -- =====================================================================
    -- Holster-Wrapper (Chicago -> reload3, sonst weiter an reload2/reload-Kette)
    -- =====================================================================
    local _orig3 = _G.__re4_reload_set_mag_in_hand
    _G.__re4_reload_set_mag_in_hand = function(active)
        if is_chicago(get_equip_wid()) then return chicago_set_mag_in_hand(active) end
        if _orig3 then return _orig3(active) end
        return false
    end

    -- =====================================================================
    -- Frame-Loop
    -- =====================================================================
    local function chicago_soft_reset()
        stop_drop(); mag_hand.active = false; mag_insert.active = false; mag_tune.active = false
        mag_out = false; mag_retained = 0
        rack.needs = false; rack.grab_active = false; rack.armed = false; rack.frac = 0
        rack.pulled = false; rack._chambered_hold = false; rack.dock_blend = 0
        rack.empty_when_dropped = false; rack._ammo_input_t = nil; rack.dock_tune = false; rack.tuning = false
        rack._zeroed_by_us = false   -- [ACCESSOR-FOLGE] Merker darf einen Wechsel/Reset nicht ueberleben
    end

    local _rb_prev = false
    local _dry_prev = false
    local _prev_wid = nil
    re.on_frame(function()
        rf_refresh()
        if rwep.wid ~= _prev_wid then
            local was_chicago = (_prev_wid ~= nil)
            chicago_soft_reset()
            if was_chicago and not rwep.wid then
                _G.__vr_needs_rack = false; _G.__vr_slide_rack_active = false
                _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil
                _G.__vr_slide_dock_blend_factor = 0; _G.__vr_rack_hand_pose = nil; _G.__vr_mag_in_hand = false
            end
            if rwep.wid then _G.__re4_live_wi = nil end
            _prev_wid = rwep.wid
        end
        if not rwep.wid then return end
        if _reacquired then
            _reacquired = false
            _G.__re4_live_wi = nil
            chicago_soft_reset()
        end
        rf_capture_mag_rest()
        check_insert_proximity()

        _G.__vr_manual_reload_consume_b = true

        local loaded = rf_loaded()
        rack.empty = gun_ammo_empty()
        rack._loaded = loaded   -- [OPEN-BOLT] echter Count fuer apply_slide_park (Force NUR bei loaded==0)
        rack.has_mag = (type(loaded) == "number" and loaded > 0)
        -- [STAGGER_HEAL 2026-07-19] Stagger-Ende (fallende Flanke von __re4_damage_active, killswitch) ->
        -- Slide zu + fire-ready wie Waffenwechsel. clear_rack chambert + snappt slide_joint auf rest_z.
        if rack._chambered_hold then
            local ga = loaded
            if rack._prev_ga and type(ga) == "number" and ga < rack._prev_ga then rack._chambered_hold = false end
            rack._prev_ga = ga
        end

        if mag_out and not mag_insert.active then
            local wi = rf_get_wi()
            if wi and (tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)) or 0) > 0 then
                _G.__re4_carry_capture(wi, "re4_vr_reload3.lua:860", nil)   -- [MAG-REST] merken, bevor genullt wird
                pcall(function() wi:write_dword(0x44, 0) end)
            end
        end

        _G.__re4_reload_grab_empty = (mag_out and not mag_hand.active and not mag_insert.active
            and not (((mag_retained or 0) + rf_reserve()) > 0))

        update_rack_gesture()

        do
            local sj = rwep.slide_joint
            local hp = sj and left_hand_world(); local sp = sj and sc(sj, "get_Position")
            _rack_near = (hp and sp) and (math.sqrt((hp.x-sp.x)^2 + (hp.y-sp.y)^2 + (hp.z-sp.z)^2) <= RACK_GRAB_DIST) or false
        end

        _G.__vr_needs_rack          = rack.needs
        _G.__vr_slide_rack_active   = rack.grab_active == true
        _G.__vr_mag_in_hand         = (mag_hand.active or mag_insert.active
            or (rack._ammo_input_t and (os.clock() - rack._ammo_input_t) < 0.2)) and true or false
        _G.__vr_rack_hand_pose      = (rack.needs and (rack.grab_active or _rack_near)) and RRACK_POSE[rwep.wid] or nil
        -- [KRITISCHES GATE — LIVE] Feuer-Block NUR aus frischen Engine-Quellen. Switch/Burst-Fire-Block
        -- macht motion.lua selbst -> hier NUR Reload-Gruende (rack/mag/leer).
        _G.__vr_block_fire_when_empty = (rack.needs or mag_out or _flow() or rack.empty) and true or false
        _G.__re4_bf_who = "re4_vr_reload3.lua:856"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        _G.__vr_rack_block_left_knife = rack.needs

        update_dock_publish(true)

        if _mag_floor_at > 0 and os.clock() >= _mag_floor_at then _mag_floor_at = 0; rf_snd(rsnd(rwep.wid, "mag_floor")) end

        local et = rawget(_G, "__re4_empty_trigger_held") == true
        if et and not _dry_prev then rf_snd(rsnd(rwep.wid, "dry_fire")) end
        _dry_prev = et

        local bd = right_b_down()
        if bd and not _rb_prev then rf_force_eject() end
        _rb_prev = bd

    end)

    -- =====================================================================
    -- Render-Pass (voller Override-Stack; NACH reload.lua + reload2 -> gewinnt)
    -- =====================================================================
    local function chicago_apply_pass()
        if not (RCFG.chicago_enabled and rwep.wid) then return end
        update_drop()
        update_mag_in_hand()
        update_insert()
        apply_slide_park()
        apply_mag_out_hidden()
        update_dock_publish(false)
        apply_hand_pose()
    end
    pcall(function() re.on_pre_application_entry("LockScene", chicago_apply_pass) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", chicago_apply_pass) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", chicago_apply_pass) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", chicago_apply_pass) end)

    -- =====================================================================
    -- Reset
    -- =====================================================================
    re.on_script_reset(function()
        if rwep.mag_joint then pcall(function() rwep.mag_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end) end
        rwep.wid, rwep.tf, rwep.mag_joint, rwep.slide_joint = nil, nil, nil, nil
        chicago_soft_reset()
        _G.__vr_needs_rack = false; _G.__vr_slide_rack_active = false
        _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil; _G.__vr_slide_dock_blend_factor = 0
        _G.__vr_rack_hand_pose = nil
    end)

    -- =====================================================================
    -- UI — eigener Header "RE4 VR — Manual Reload 3"
    -- =====================================================================
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Reload3" raus (90 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.
end
-- =====================================================================
-- ENDE CHICAGO-SWEEPER-GATTUNG
-- =====================================================================

-- =====================================================================
-- HANDCANNON-REVOLVER (wp4502) — eigener, vollstaendig gekapselter do-Block.
-- =====================================================================
-- 1:1-Port der Broken-Butterfly-Logik (reload2) fuer die Handcannon, aber
-- EIGENSTAENDIG: eigene Daten, eigenes JSON, eigene UI. reload2 fasst 4502
-- nicht mehr an (aus REVOLVERS/JOINTS gezogen) -> kein Konflikt. Per-Waffe-
-- unabhaengig: tunen der Handcannon trifft NIE die Broken Butterfly.
-- Nutzt die Top-Level-Helfer von reload3 (safe/sc/sf/quat_from_euler/
-- right_b_down/get_ctx/get_equip_wid/body_tf/get_pe/pe_td/find_weapon) wieder.
-- Eigenes JSON: reframework/data/re4_vr/re4_vr_reload3_handcannon.json
-- =====================================================================
do
    local HC = 4502
    local function is_revolver(wid) return wid == HC end
    local snd_sc_td = sdk.typeof("soundlib.SoundContainer")

    -- ---- Joints (CODE-Konstanten, 2026-06-26 bestaetigt) ----
    -- _02 = Spannhahn. _04 = TROMMEL (Chambers + Patronen, schwenkt zur Seite raus). _05 = FUEHRUNG/Crane
    -- (Parent von _04, schwenkt _04 mit raus). _07.._11 = 5 Patronen (fuer Kipp-&-Fallen-Eject).
    -- Da Swing UND Chamber-Spin getrennte Joints brauchen (sonst kollidieren die Overrides):
    -- cyl_joint(Swing, Right-B) = _05 (Crane dreht -> _04 schwenkt als Kind mit)
    -- spin/index + eject + Patronen = _04 (Trommel-Eigenrotation, haelt die Kugeln)
    -- Hand-Patrone = Mesh-Clone Parts 20+30 (kein Joint noetig) -> hand_cartridge nur Doku.
    local JOINTS = {
        -- cyl_joint=_04 (Swing/Scharnier, Right-B). spin=_05 (TROMMEL selbst, bohrungszentriert -> dreht
        -- sauber an Ort um lokales Z) = BB-konform (wp4500: swing=_04, spin=_05). apply_cylinder_spin_lock
        -- treibt _05 (Chamber-Advance pro Schuss) + liefert die Bohrungs-Referenz fuers Eject. _04 macht NUR
        -- den Swing (kein Spin mehr drauf, sonst schwenkt es seitlich raus statt sich zu drehen).
        [HC] = { cylinder = "_04", bullet = "_07", bullet_pack = "_04", insert_ref = "_04", spin = "_05",
                 hand_cartridge = "_101", hammer = "_02",
                 bullets = { "_07", "_08", "_09", "_10", "_11" }, capacity = 5 },
    }

    -- ---- Trommel ausschwenken (per Right-B). rx/ry/rz = Crane-Dreh (Grad), px/py/pz = Translation (m).
    -- Seed = seitlicher Swing-Out (rz). Achse/Winkel im VR tunen (Crane _05 hat eigenes lokales Frame).
    local CYL = { [HC] = { rx = 0.0, ry = 0.0, rz = -62.0, lerp = 0.08 } }
    local function cyl_cfg(wid)
        local c = wid and CYL[wid]; if not c then c = {}; if wid then CYL[wid] = c end end
        c.rx = c.rx or 0; c.ry = c.ry or 0; c.rz = c.rz or 0
        c.px = c.px or 0; c.py = c.py or 0; c.pz = c.pz or 0
        c.lerp = c.lerp or 0.08
        c.shot_deg = c.shot_deg or -45.0; c.shot_lerp = c.shot_lerp or 0.20
        return c
    end
    local cyl_st = { open = false, prog = 0.0, _prev_b = false, preview = false }
    local spin_st = { target = 0.0, current = 0.0, prev_seq = nil }

    -- ---- Single-Action (Hahn _02 + rechter Daumen) gebuendelt ----
    local hammer_st = {
        hand_frac = 0.0, ham_frac = 0.0, cocked = false,
        frac = 0.0, target = 0.0, prev_seq = nil, cock_prev = false,
        cock_running = false, cock_t0 = 0.0, cock_snd = false,   -- einmalige Spann-Geste (Zeitfenster)
        cock_stick_y = -0.55,
        thumb_joints = { "R_Thumb1", "R_Thumb2", "R_Thumb3" },
        cfg  = { [HC] = { idle_rx = 14.5, idle_ry = 0.0, idle_rz = 0.0, rx = 0.0, ry = 0.0, rz = 0.0, lerp = 0.25 } },
        tcfg = { [HC] = { { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }, { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }, { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 } } },
        tcfg_aim = { [HC] = { { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }, { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }, { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 } } },
        use_aim = false,
        hand = { rx = 0.0, ry = 0.0, rz = 0.0, px = 0.0, py = 0.0, pz = 0.0 },
        hand_aim = { rx = 0.0, ry = 0.0, rz = 0.0, px = 0.0, py = 0.0, pz = 0.0 },
        thumb_pos = { x = 0.0, y = 0.0, z = 0.0 },
        thumb_pos_aim = { x = 0.0, y = 0.0, z = 0.0 },
        -- [DAUMEN-KEYS 2026-07-31] Gespiegelt vom Broken Butterfly (reload2): der Daumen als KURVE
        -- ueber die Spann-Geste statt 2-Punkt-Lerp. phase = MONOTON 0..1 ueber hoch+kleben+zurueck, damit
        -- Hin- und Rueckweg getrennt keyframebar sind. EIGENE Listen, eigenes JSON -- der Handcannon teilt
        -- sich nichts mit dem Broken Butterfly. Ohne Keys laeuft exakt der alte Pfad.
        tkeys = {}, tkeys_aim = {},
        phase = 0.0, key_blend = 0.0,
        kprev = false, klive = true, kphase = 0.0, kjoint = 1,
        kedit = { { x=0,y=0,z=0,px=0,py=0,pz=0 }, { x=0,y=0,z=0,px=0,py=0,pz=0 }, { x=0,y=0,z=0,px=0,py=0,pz=0 } },
        kout  = { { x=0,y=0,z=0,px=0,py=0,pz=0 }, { x=0,y=0,z=0,px=0,py=0,pz=0 }, { x=0,y=0,z=0,px=0,py=0,pz=0 } },
    }
    local function hammer_cfg(wid)
        local h = wid and hammer_st.cfg[wid]; if not h then h = {}; if wid then hammer_st.cfg[wid] = h end end
        h.idle_rx = h.idle_rx or 0; h.idle_ry = h.idle_ry or 0; h.idle_rz = h.idle_rz or 0
        h.rx = h.rx or 0; h.ry = h.ry or 0; h.rz = h.rz or 0; h.lerp = h.lerp or 0.25
        return h
    end
    local function thumb_cfg(wid)
        local t = wid and hammer_st.tcfg[wid]; if not t then t = {}; if wid then hammer_st.tcfg[wid] = t end end
        for i = 1, 3 do
            t[i] = t[i] or { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }
            local j = t[i]; j.ix = j.ix or 0; j.iy = j.iy or 0; j.iz = j.iz or 0; j.cx = j.cx or 0; j.cy = j.cy or 0; j.cz = j.cz or 0
        end
        return t
    end
    local function thumb_cfg_aim(wid)
        local t = wid and hammer_st.tcfg_aim[wid]; if not t then t = {}; if wid then hammer_st.tcfg_aim[wid] = t end end
        for i = 1, 3 do
            t[i] = t[i] or { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }
            local j = t[i]; j.ix = j.ix or 0; j.iy = j.iy or 0; j.iz = j.iz or 0; j.cx = j.cx or 0; j.cy = j.cy or 0; j.cz = j.cz or 0
        end
        return t
    end
    -- [DAUMEN-KEYS] Key-Liste (getrennt Aim / No-Aim), leer angelegt wenn noch keine da.
    local function thumb_keys(wid, aim)
        local m = aim and hammer_st.tkeys_aim or hammer_st.tkeys
        local t = wid and m[wid]; if not t then t = {}; if wid then m[wid] = t end end
        return t
    end
    -- [DAUMEN-KEYS] Kurve an der Phase p (0..100) abtasten -> out[1..3] = Winkel + Versatz je Glied.
    -- Vor dem ersten Key von NEUTRAL hoch, nach dem letzten wieder auf NEUTRAL -> kein Key bei 0/100 noetig.
    local function thumb_key_sample(list, p, out)
        for i = 1, 3 do local o = out[i]; o.x, o.y, o.z, o.px, o.py, o.pz = 0, 0, 0, 0, 0, 0 end
        local n = list and #list or 0
        if n == 0 then return false end
        local lo, hi, t
        if p <= list[1].p then
            hi = list[1]
            t = (list[1].p > 0.0001) and (p / list[1].p) or 1.0
        elseif p >= list[n].p then
            lo = list[n]
            local span = 100.0 - list[n].p
            t = (span > 0.0001) and ((p - list[n].p) / span) or 1.0
        else
            for i = 1, n - 1 do
                if p >= list[i].p and p <= list[i + 1].p then
                    lo, hi = list[i], list[i + 1]
                    local span = hi.p - lo.p
                    t = (span > 0.0001) and ((p - lo.p) / span) or 0.0
                    break
                end
            end
        end
        if not t then return false end
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        for i = 1, 3 do
            local a = lo and lo.j and lo.j[i] or nil
            local b = hi and hi.j and hi.j[i] or nil
            local o = out[i]
            for _, f in ipairs({ "x", "y", "z", "px", "py", "pz" }) do
                local av = a and (a[f] or 0) or 0
                local bv = b and (b[f] or 0) or 0
                o[f] = av + (bv - av) * t
            end
        end
        return true
    end

    -- ---- Mesh-Clone der Hand-Patrone (forward-deklariert) ----
    local cart_destroy
    local cart_clone = { obj = nil, mesh = nil, wid = nil, parts_sig = nil }

    -- ---- Shell-in-Hand (Pose + Offset + Daumen), eigenstaendig in reload3-handcannon.json ----
    local SHELL = {
        [HC] = { pose = "RevolverShell", x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0, t_rx = 0.0, t_ry = 0.0, t_rz = 0.0, i_rx = 0.0, i_ry = 0.0, i_rz = 0.0, parts = "20,30", scale = 1.0 },
    }
    local function shell_cfg(wid)
        local s = wid and SHELL[wid]; if not s then s = {}; if wid then SHELL[wid] = s end end
        s.pose = s.pose or ""
        s.x = s.x or 0; s.y = s.y or 0; s.z = s.z or 0
        s.rx = s.rx or 0; s.ry = s.ry or 0; s.rz = s.rz or 0
        s.t_rx = s.t_rx or 0; s.t_ry = s.t_ry or 0; s.t_rz = s.t_rz or 0
        s.i_rx = s.i_rx or 0; s.i_ry = s.i_ry or 0; s.i_rz = s.i_rz or 0
        s.parts = s.parts or "20,30"; s.scale = s.scale or 1.0
        return s
    end

    local _CAPTURE = false

    -- ---- Konfiguration (eigenes JSON, eigene Defaults) ----
    local CFG_PATH = "re4_vr/re4_vr_reload3_handcannon.json"
    local CFG = { revolver_enabled = true, insert_distance = 0.15, reload_ammo = true, sound_enabled = true,
                  cock_press = 0.18, cock_hold = 0.14, cock_return = 0.16, cock_fall = 0.40,   -- Spann-Geste: Daumen hoch / KLEBT oben / zurueck (s) + Hahn-Fall-Tempo
                  support_cooldown = 0.45 }   -- [SUPPORT-COOLDOWN] s, Support-Hand nach Insert so lange NICHT andocken
    local function load_cfg()
        local data = safe(function() return json.load_file(CFG_PATH) end)
        if type(data) ~= "table" then return end
        local c = data.cfg or data
        if type(c.revolver_enabled) == "boolean" then CFG.revolver_enabled = c.revolver_enabled end
        if type(c.reload_ammo) == "boolean" then CFG.reload_ammo = c.reload_ammo end
        if type(c.sound_enabled) == "boolean" then CFG.sound_enabled = c.sound_enabled end
        if type(c.insert_distance) == "number" then CFG.insert_distance = c.insert_distance end
        if type(c.support_cooldown) == "number" then CFG.support_cooldown = c.support_cooldown end
        if type(c.cock_press)  == "number" then CFG.cock_press  = c.cock_press  end
        if type(c.cock_hold)   == "number" then CFG.cock_hold   = c.cock_hold   end
        if type(c.cock_return) == "number" then CFG.cock_return = c.cock_return end
        if type(c.cock_fall)   == "number" then CFG.cock_fall   = c.cock_fall   end
        if type(data.cyl) == "table" then
            for k, v in pairs(data.cyl) do
                local wid = tonumber(k)
                if wid and type(v) == "table" then
                    local rr = cyl_cfg(wid)
                    for _, f in ipairs({ "rx", "ry", "rz", "px", "py", "pz", "lerp", "shot_deg", "shot_lerp" }) do if type(v[f]) == "number" then rr[f] = v[f] end end
                end
            end
        end
        if type(data.shell) == "table" then
            for k, v in pairs(data.shell) do
                local wid = tonumber(k)
                if wid and type(v) == "table" then
                    local ss = shell_cfg(wid)
                    if type(v.pose) == "string" then ss.pose = v.pose end
                    if type(v.parts) == "string" then ss.parts = v.parts end
                    for _, f in ipairs({ "x", "y", "z", "rx", "ry", "rz", "t_rx", "t_ry", "t_rz", "i_rx", "i_ry", "i_rz", "scale" }) do if type(v[f]) == "number" then ss[f] = v[f] end end
                end
            end
        end
        if type(data.hammer) == "table" then
            for k, v in pairs(data.hammer) do
                local wid = tonumber(k)
                if wid and type(v) == "table" then
                    local hh = hammer_cfg(wid)
                    for _, f in ipairs({ "idle_rx", "idle_ry", "idle_rz", "rx", "ry", "rz", "lerp" }) do if type(v[f]) == "number" then hh[f] = v[f] end end
                end
            end
        end
        if type(data.cockhand) == "table" then
            for _, f in ipairs({ "rx", "ry", "rz", "px", "py", "pz" }) do if type(data.cockhand[f]) == "number" then hammer_st.hand[f] = data.cockhand[f] end end
        end
        if type(data.cockhand_aim) == "table" then
            for _, f in ipairs({ "rx", "ry", "rz", "px", "py", "pz" }) do if type(data.cockhand_aim[f]) == "number" then hammer_st.hand_aim[f] = data.cockhand_aim[f] end end
        else
            for _, f in ipairs({ "rx", "ry", "rz", "px", "py", "pz" }) do hammer_st.hand_aim[f] = hammer_st.hand[f] end
        end
        if type(data.thumbpos) == "table" then
            for _, f in ipairs({ "x", "y", "z" }) do if type(data.thumbpos[f]) == "number" then hammer_st.thumb_pos[f] = data.thumbpos[f] end end
        end
        if type(data.thumb) == "table" then
            for k, v in pairs(data.thumb) do
                local wid = tonumber(k)
                if wid and type(v) == "table" then
                    local tt = thumb_cfg(wid)
                    for i = 1, 3 do
                        if type(v[i]) == "table" then
                            for _, f in ipairs({ "ix", "iy", "iz", "cx", "cy", "cz" }) do if type(v[i][f]) == "number" then tt[i][f] = v[i][f] end end
                        end
                    end
                end
            end
        end
        if type(data.thumbpos_aim) == "table" then
            for _, f in ipairs({ "x", "y", "z" }) do if type(data.thumbpos_aim[f]) == "number" then hammer_st.thumb_pos_aim[f] = data.thumbpos_aim[f] end end
        else
            for _, f in ipairs({ "x", "y", "z" }) do hammer_st.thumb_pos_aim[f] = hammer_st.thumb_pos[f] end
        end
        -- [DAUMEN-KEYS] Stuetzpunkte laden (getrennt Aim / No-Aim), nach Phase sortiert.
        for _, src in ipairs({ { data.thumbkeys, hammer_st.tkeys }, { data.thumbkeys_aim, hammer_st.tkeys_aim } }) do
            if type(src[1]) == "table" then
                for k, list in pairs(src[1]) do
                    local wid = tonumber(k)
                    if wid and type(list) == "table" then
                        local out = {}
                        for _, key in ipairs(list) do
                            if type(key) == "table" and tonumber(key.p) and type(key.j) == "table" then
                                local j = {}
                                for n = 1, 3 do
                                    local s = type(key.j[n]) == "table" and key.j[n] or {}
                                    j[n] = { x = tonumber(s.x) or 0, y = tonumber(s.y) or 0, z = tonumber(s.z) or 0,
                                             px = tonumber(s.px) or 0, py = tonumber(s.py) or 0, pz = tonumber(s.pz) or 0 }
                                end
                                out[#out + 1] = { p = tonumber(key.p) or 0, j = j }
                            end
                        end
                        table.sort(out, function(m, q) return m.p < q.p end)
                        src[2][wid] = out
                    end
                end
            end
        end
        for wid, _v in pairs(hammer_st.tcfg) do
            local ta = thumb_cfg_aim(wid); local tn = thumb_cfg(wid)
            local src = (type(data.thumb_aim) == "table") and data.thumb_aim[tostring(wid)] or nil
            for i = 1, 3 do
                if type(src) == "table" and type(src[i]) == "table" then
                    for _, f in ipairs({ "ix", "iy", "iz", "cx", "cy", "cz" }) do if type(src[i][f]) == "number" then ta[i][f] = src[i][f] end end
                else
                    for _, f in ipairs({ "ix", "iy", "iz", "cx", "cy", "cz" }) do ta[i][f] = tn[i][f] end
                end
            end
        end
    end
    local function save_cfg()
        local cylo = {}
        for wid, v in pairs(CYL) do cylo[tostring(wid)] = { rx = v.rx, ry = v.ry, rz = v.rz, px = v.px, py = v.py, pz = v.pz, lerp = v.lerp, shot_deg = v.shot_deg, shot_lerp = v.shot_lerp } end
        local shello = {}
        for wid, v in pairs(SHELL) do shello[tostring(wid)] = { pose = v.pose, x = v.x, y = v.y, z = v.z, rx = v.rx, ry = v.ry, rz = v.rz, t_rx = v.t_rx, t_ry = v.t_ry, t_rz = v.t_rz, i_rx = v.i_rx, i_ry = v.i_ry, i_rz = v.i_rz, parts = v.parts, scale = v.scale } end
        local hammero = {}
        for wid, v in pairs(hammer_st.cfg) do hammero[tostring(wid)] = { idle_rx = v.idle_rx, idle_ry = v.idle_ry, idle_rz = v.idle_rz, rx = v.rx, ry = v.ry, rz = v.rz, lerp = v.lerp } end
        local thumbo = {}
        for wid, v in pairs(hammer_st.tcfg) do
            local arr = {}
            for i = 1, 3 do local j = v[i] or {}; arr[i] = { ix = j.ix or 0, iy = j.iy or 0, iz = j.iz or 0, cx = j.cx or 0, cy = j.cy or 0, cz = j.cz or 0 } end
            thumbo[tostring(wid)] = arr
        end
        local thumbo_aim = {}
        for wid, v in pairs(hammer_st.tcfg_aim) do
            local arr = {}
            for i = 1, 3 do local j = v[i] or {}; arr[i] = { ix = j.ix or 0, iy = j.iy or 0, iz = j.iz or 0, cx = j.cx or 0, cy = j.cy or 0, cz = j.cz or 0 } end
            thumbo_aim[tostring(wid)] = arr
        end
        local ch = hammer_st.hand
        local cockhand = { rx = ch.rx, ry = ch.ry, rz = ch.rz, px = ch.px, py = ch.py, pz = ch.pz }
        local ca = hammer_st.hand_aim
        local cockhand_aim = { rx = ca.rx, ry = ca.ry, rz = ca.rz, px = ca.px, py = ca.py, pz = ca.pz }
        local tp = hammer_st.thumb_pos
        local thumbpos = { x = tp.x, y = tp.y, z = tp.z }
        local tpa = hammer_st.thumb_pos_aim
        local thumbpos_aim = { x = tpa.x, y = tpa.y, z = tpa.z }
        -- [DAUMEN-KEYS] Stuetzpunkte flach serialisieren (kein Verweis auf die Laufzeit-Tabellen)
        local function ser_keys(m)
            local o = {}
            for wid, list in pairs(m) do
                local arr = {}
                for i, key in ipairs(list) do
                    local j = {}
                    for n = 1, 3 do
                        local s = (type(key.j) == "table" and key.j[n]) or {}
                        j[n] = { x = s.x or 0, y = s.y or 0, z = s.z or 0, px = s.px or 0, py = s.py or 0, pz = s.pz or 0 }
                    end
                    arr[i] = { p = key.p or 0, j = j }
                end
                o[tostring(wid)] = arr
            end
            return o
        end
        pcall(function() json.dump_file(CFG_PATH, { cfg = CFG, cyl = cylo, shell = shello, hammer = hammero, thumb = thumbo, thumb_aim = thumbo_aim, cockhand = cockhand, cockhand_aim = cockhand_aim, thumbpos = thumbpos, thumbpos_aim = thumbpos_aim, thumbkeys = ser_keys(hammer_st.tkeys), thumbkeys_aim = ser_keys(hammer_st.tkeys_aim) }) end)
    end
    load_cfg()

    -- ---- Waffe (eigenstaendig) ----
    local wep = { wid = nil, tf = nil, cyl_joint = nil, cyl_rest_rot = nil, cyl_rest_pos = nil, bullet_joints = nil, insert_joint = nil, spin_joint = nil, spin_rest_rot = nil, hand_cart_joint = nil, hand_cart_vis = nil, hammer_joint = nil, hammer_rest_rot = nil }
    local function managed_wid()
        if not CFG.revolver_enabled then return nil end
        local wid = get_equip_wid()
        if not is_revolver(wid) then return nil end
        return wid
    end
    local function refresh_weapon()
        local wid = managed_wid()
        if not wid then if cart_destroy then cart_destroy() end; wep.wid, wep.tf, wep.cyl_joint, wep.cyl_rest_rot, wep.cyl_rest_pos, wep.bullet_joints, wep.insert_joint, wep.spin_joint, wep.spin_rest_rot, wep.hand_cart_joint, wep.hand_cart_vis = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil; wep.hammer_joint, wep.hammer_rest_rot = nil, nil; return end
        if wep.wid == wid and wep.tf and safe(function() return wep.tf:call("get_Position") end) then return end
        wep.wid, wep.tf, wep.cyl_joint, wep.cyl_rest_rot, wep.cyl_rest_pos, wep.bullet_joints, wep.insert_joint, wep.spin_joint, wep.spin_rest_rot, wep.hand_cart_joint, wep.hand_cart_vis = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        wep.hammer_joint, wep.hammer_rest_rot = nil, nil
        local go, tf = find_weapon(wid)
        if not tf then return end
        wep.wid, wep.tf = wid, tf
        local jc = JOINTS[wid] or {}
        wep.cyl_joint = (jc.cylinder and jc.cylinder ~= "") and sc(tf, "getJointByName", jc.cylinder) or nil
        if wep.cyl_joint then
            wep.cyl_rest_rot = sc(wep.cyl_joint, "get_LocalRotation")
            wep.cyl_rest_pos = sc(wep.cyl_joint, "get_LocalPosition")
        end
        wep.bullet_joints = {}
        if type(jc.bullets) == "table" then
            for _, bn in ipairs(jc.bullets) do
                local bj = sc(tf, "getJointByName", bn)
                if bj then
                    local rs = sc(bj, "get_LocalScale")
                    local vis = (rs and rs.x and rs.x > 0.01) and rs or Vector3f.new(1, 1, 1)
                    wep.bullet_joints[#wep.bullet_joints + 1] = { joint = bj, name = bn, vis = vis }
                end
            end
        end
        wep.insert_joint = (jc.insert_ref and jc.insert_ref ~= "") and sc(tf, "getJointByName", jc.insert_ref) or nil
        wep.spin_joint = (jc.spin and jc.spin ~= "") and sc(tf, "getJointByName", jc.spin) or nil
        if wep.spin_joint then wep.spin_rest_rot = sc(wep.spin_joint, "get_LocalRotation") end
        wep.hand_cart_joint = (jc.hand_cartridge and jc.hand_cartridge ~= "") and sc(tf, "getJointByName", jc.hand_cartridge) or nil
        if wep.hand_cart_joint then
            local rs = sc(wep.hand_cart_joint, "get_LocalScale")
            wep.hand_cart_vis = (rs and rs.x and rs.x > 0.01) and rs or Vector3f.new(1, 1, 1)
        end
        wep.hammer_joint = (jc.hammer and jc.hammer ~= "") and sc(tf, "getJointByName", jc.hammer) or nil
        -- [SAVE-LOAD-FEST] Ruhe = BIND-Pose (get_BaseLocalRotation), eine Modell-Konstante die NIE von unserem
        -- Override kontaminiert wird (im Gegensatz zu get_LocalRotation = aktuelle, evtl. unsere eigene Ausgabe).
        -- -> idle/cocked werden immer aus dem sauberen Bind-Wert gerechnet, robust gegen Save-Load/Script-Reload.
        wep.hammer_rest_rot = wep.hammer_joint and sc(wep.hammer_joint, "get_BaseLocalRotation") or nil
    end
    local function wp_label(wid) return wid and string.format("wp%04d", wid) or "-" end

    local function play_weapon_sound(id)
        if not CFG.sound_enabled or not id or id <= 0 then return end
        local tf = wep.tf; if not tf then return end
        local go = safe(function() return tf:call("get_GameObject") end)
        if not go or not snd_sc_td then return end
        local scn = safe(function() return go:call("getComponent(System.Type)", snd_sc_td) end)
        if not scn then return end
        pcall(function() scn:call("trigger(System.UInt32)", id) end)
    end
    local SND_CYLINDER    = 942865223
    local SND_COCK        = 938556079
    local SND_INSERT      = 942865223
    local SND_DROP        = 1351699582
    local SND_MAG_HOLSTER = 1839787494
    local SND_DRY_FIRE    = 812850326

    local rev_st = { cart = false, _dry_prev = false, preview = false }
    local drop2 = { active = false, idx = nil, sx = 0, sy = 0, sz = 0, t0 = 0, snd = false }
    local REV_GRAVITY  = 9.8
    local REV_DROP_DUR = 1.0

    local function get_live_wi()
        -- [ACCESSOR 2026-08-12] zuerst die ECHTE, persistente Instanz (s. reload.lua,
        -- __re4_real_wi). Alles darunter sind KOPIEN -> Schreiben verpufft.
        local _rw = _G.__re4_real_wi and _G.__re4_real_wi()
        if _rw then return _rw end
        local wi = rawget(_G, "__re4_live_wi")
        if wi and safe(function() return wi:call("get_CurrentAmmoCount") end) ~= nil then
            local cwid = safe(function() return wi:call("get_WeaponId"):get_field("value__") end)
            if cwid and wep.wid and cwid == wep.wid then return wi end   -- STRIKT: nur cachen wenn gleiche Waffe (kein stale)
        end
        local pe = get_pe()
        local ewi = pe and safe(function() return pe:call("getEquipWeaponItem") end)
        if ewi and safe(function() return ewi:call("get_CurrentAmmoCount") end) ~= nil then return ewi end
        return nil
    end
    local function gun_is_full(wi)
        local bf = safe(function() return wi:call("get_IsBulletFull") end)
        if bf ~= nil then return bf == true end
        local loaded = tonumber(sc(wi, "get_CurrentAmmoCount")) or 0
        local maxc   = tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0
        return maxc > 0 and loaded >= maxc
    end
    local function insert_one_round()
        if not CFG.reload_ammo then return false end
        local wi = get_live_wi(); if not wi then return false end
        local loaded = tonumber(sc(wi, "get_CurrentAmmoCount")) or 0
        if gun_is_full(wi) then return false end
        local pe  = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end)
        local function read_reserve()
            return (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
        end
        local r_b4 = read_reserve()
        if r_b4 <= 0 then return false end
        -- [RUNTIME-FIX 0/0] Erfolg gegen getCurrentGunAmmo (Laufzeit) pruefen, NICHT wi:get_CurrentAmmoCount
        -- (= evtl. Spiegel -> write_dword scheint zu gelingen, addAmmoCount uebersprungen, Reserve weg). Menge +1.
        local function gun_ammo() return pe and tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or nil end
        -- [HANDCANNON-AMMO 2026-07-24] Baugleicher Revolver wie die Broken Butterfly: write_dword @0x44
        -- greift bei OFFENER Trommel NICHT (getCurrentGunAmmo bleibt stehen) -> nativer Reload (+1), exakt der
        -- Weg der bei Butterfly/Shotguns/Pistolen funktioniert. __re4_safe_inv_reload zieht die Reserve selbst.
        local et
        pcall(function()
            local td = sdk.find_type_definition("chainsaw.EquipType")
            local ff = td and td:get_field("Main")
            if ff then et = ff:get_data(nil) end
        end)
        local before = gun_ammo() or loaded
        if _G.__re4_safe_inv_reload and inv and et then
            pcall(function() _G.__re4_load_and_book(inv, et, 1, false) end)
        end
        return (gun_ammo() or before) > before
    end
    local function revolver_can_grab()
        local wi = get_live_wi(); if not wi then return false end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end)
        local reserve = (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
        if reserve <= 0 then return false end
        if gun_is_full(wi) then return false end
        return true
    end
    local function revolver_set_mag_in_hand(active)
        if active then
            if rev_st.cart then return true end
            if rev_st.kf_used then return false end   -- [SHELL-KEYFRAMES] diese Greif-Session hat schon eine Bahn gefahren -> erst loslassen + neu greifen
            if not revolver_can_grab() then return false end
            rev_st.cart = true
            drop2.active = false
            play_weapon_sound(SND_MAG_HOLSTER)
            return true
        else
            -- [SHELL-KEYFRAMES 2026-07-24] Bahn laeuft -> Loslassen NICHT als Drop werten (sonst faellt
            -- die Patrone + Bahn bricht ab = kein Insert). Die Bahn legt selbst ein.
            if rev_st.kf_active then rev_st.kf_used = false; return true end
            local tf = cart_clone.obj and safe(function() return cart_clone.obj:call("get_Transform") end)
            local p = tf and safe(function() return tf:call("get_Position") end)
            if rev_st.cart and p then
                drop2.active = true; drop2.snd = false
                drop2.sx, drop2.sy, drop2.sz = p.x, p.y, p.z; drop2.t0 = os.clock()
                -- [NO_LAG] Klon war ans L_Hand geparentet -> fuer den Welt-Freifall entkoppeln.
                if cart_clone.parented then pcall(function() tf:call("set_Parent", nil) end); cart_clone.parented = false end
            end
            rev_st.cart = false
            rev_st.kf_used = false   -- [SHELL-KEYFRAMES] Grip losgelassen -> naechster Griff darf wieder eine Bahn fahren
            return true
        end
    end
    local function held_cartridge_pos()
        local bt = body_tf(); local lhj = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lhj and sc(lhj, "get_Position"); if not hp then return nil end
        local hr = lhj and sc(lhj, "get_Rotation")
        local s = SHELL[wep.wid] or {}
        if hr then
            local off = safe(function() return hr * Vector3f.new(s.x or 0, s.y or 0, s.z or 0) end)
            if off then return Vector3f.new(hp.x + off.x, hp.y + off.y, hp.z + off.z) end
        end
        return Vector3f.new(hp.x, hp.y, hp.z)
    end
    local function update_reload()
        if not (CFG.revolver_enabled and CFG.reload_ammo and wep.wid and wep.insert_joint) then return end
        if not rev_st.cart then return end
        if rawget(_G, "__vr_revolver_cyl_open") ~= true then return end
        local cp = held_cartridge_pos(); if not cp then return end
        local ip = sc(wep.insert_joint, "get_Position"); if not ip then return end
        local d  = math.sqrt((cp.x - ip.x)^2 + (cp.y - ip.y)^2 + (cp.z - ip.z)^2)
        if d <= (CFG.insert_distance or 0.15) then
            local ms = rawget(_G, "__re4_reload_mag_slide")
            if ms and type(ms.has_shell_keys) == "function" and ms.has_shell_keys(wep.wid) then
                -- [SHELL-KEYFRAMES 2026-07-24] Bahn (visuelle Deko) IMMER starten, entkoppelt vom Insert.
                if not rev_st.kf_active and not rev_st.kf_used then
                    rev_st.kf_active = true
                    rev_st.kf_used = true
                    rev_st.kf_inserted = false
                    rev_st.kf_t0 = os.clock()
                    local tf = cart_clone.obj and safe(function() return cart_clone.obj:call("get_Transform") end)
                    if tf and cart_clone.parented then pcall(function() tf:call("set_Parent", nil) end); cart_clone.parented = false end
                end
                -- +1 jeden Frame versuchen (RETRY) bis der native Reload greift -- parallel zur Bahn.
                if rev_st.cart and not rev_st.kf_inserted then
                    if insert_one_round() then rev_st.kf_inserted = true; rev_st._insert_t = os.clock(); play_weapon_sound(SND_INSERT) end
                end
            elseif insert_one_round() then
                rev_st.cart = false
                rev_st._insert_t = os.clock()   -- [SUPPORT-COOLDOWN] Support-Hand nach Insert kurz NICHT andocken
                play_weapon_sound(SND_INSERT)
            end
        end
    end

    local function update_cylinder()
        if not (wep.wid and wep.cyl_joint) then return end
        if cyl_st.preview then _G.__vr_revolver_cyl_open = (cyl_st.prog > 0.15); return end
        local r = cyl_cfg(wep.wid)
        local b = right_b_down()
        if b and not cyl_st._prev_b then cyl_st.open = not cyl_st.open; play_weapon_sound(cyl_st.open and SND_CYLINDER or SND_COCK) end   -- [SOUND] OEFFNEN=Trommel-ID, SCHLIESSEN=Cock-ID (getauscht)
        cyl_st._prev_b = b
        local target = cyl_st.open and 1.0 or 0.0
        local SPD = r.lerp or 0.08
        if cyl_st.prog < target then cyl_st.prog = math.min(target, cyl_st.prog + SPD)
        elseif cyl_st.prog > target then cyl_st.prog = math.max(target, cyl_st.prog - SPD) end
        _G.__vr_revolver_cyl_open = (cyl_st.open or cyl_st.prog > 0.15) == true
    end
    local function update_cyl_spin()
        if not wep.wid then return end
        local r = cyl_cfg(wep.wid)
        local seq = tonumber(rawget(_G, "__vr_shot_seq")) or 0
        if spin_st.prev_seq == nil then spin_st.prev_seq = seq
        elseif seq > spin_st.prev_seq then
            spin_st.target = spin_st.target + (r.shot_deg or -30.0) * (seq - spin_st.prev_seq)
            spin_st.prev_seq = seq
        end
        local diff = spin_st.target - spin_st.current
        if math.abs(diff) <= 0.5 then spin_st.current = spin_st.target
        else spin_st.current = spin_st.current + diff * (r.shot_lerp or 0.20) end
    end
    -- Cock = EINMALIGE getimte Geste (Daumen drueckt den Sporn hoch & federt zurueck), NICHT gehaltene Pose.
    -- Stick-Flanke startet die Geste; egal wie lange der Stick haengt, der Daumen geht raus UND zurueck an
    -- den Griff. Der Hahn faehrt MIT dem Daumen hoch, latcht oben (bleibt hinten) und bleibt gespannt bis
    -- zum Schuss -> dann schneller Fall. So liest es sich als Bewegung statt als eingefrorene Endpose.
    local function update_hammer()
        -- [KEIN COCKBACK 2026-08-04, "handcannon soll nie cockback brauchen"] Single-Action der
        -- Handcannon ist in ALLEN Modi aus (Leon-Kampagne, Ada-DLC, Mercs) -- sie feuert wie jede andere
        -- Waffe. Der Feuer-Block unten prueft deshalb NICHT mehr auf 'cocked', sonst waere sie gesperrt.
        if true or wep.wid ~= HC then
            hammer_st.hand_frac = 0; hammer_st.ham_frac = 0; hammer_st.cocked = false
            hammer_st.cock_running = false
            hammer_st.phase = 0; hammer_st.key_blend = 0   -- [DAUMEN-KEYS] Kurve aus
            return
        end
        local ry = tonumber(rawget(_G, "__vr_right_stick_y")) or 0
        local stick = (ry <= (hammer_st.cock_stick_y or -0.55))
        local preview = hammer_st.hand.preview or hammer_st.hand_aim.preview

        -- [DAUMEN-KEYS] Vorschau am Phasen-Regler hat Vorrang: Daumen UND Hahn stehen exakt da, wo sie in
        -- der echten Geste bei dieser Phase stuenden -> Kuppe Stuetzpunkt fuer Stuetzpunkt an den Sporn legen.
        if hammer_st.kprev then
            local press = math.max(CFG.cock_press or 0.18, 0.01)
            local total = press + math.max(CFG.cock_hold or 0.14, 0.0) + math.max(CFG.cock_return or 0.16, 0.01)
            local ph = math.min(math.max((hammer_st.kphase or 0) / 100.0, 0.0), 1.0)
            hammer_st.phase = ph
            hammer_st.key_blend = 1.0
            local u = math.min(ph * total / press, 1.0); u = u * u * (3 - 2 * u)
            hammer_st.ham_frac = u
            hammer_st.hand_frac = 1.0
            hammer_st.cock_running = false
            return
        end

        -- Schuss-Flanke -> entspannen (Hahn faellt)
        local seq = tonumber(rawget(_G, "__vr_shot_seq")) or 0
        if hammer_st.prev_seq == nil then hammer_st.prev_seq = seq
        elseif seq > hammer_st.prev_seq then hammer_st.cocked = false; hammer_st.cock_running = false; hammer_st.prev_seq = seq end

        if preview then  -- UI-Tuning: volle statische Pose halten (Daumen + Hahn ganz raus)
            hammer_st.hand_frac = hammer_st.hand_frac + (1.0 - hammer_st.hand_frac) * 0.25
            hammer_st.ham_frac  = hammer_st.ham_frac  + (1.0 - hammer_st.ham_frac) * 0.25
            hammer_st.cock_running = false
            return
        end

        -- Stick-Flanke startet die Geste (nur wenn nicht schon gespannt / nicht schon laufend)
        if stick and not hammer_st.cock_prev and not hammer_st.cocked and not hammer_st.cock_running then
            hammer_st.cock_running = true; hammer_st.cock_t0 = os.clock(); hammer_st.cock_snd = false
            hammer_st.phase = 0.0   -- [DAUMEN-KEYS] Kurve startet vorne
        end
        hammer_st.cock_prev = stick

        if hammer_st.cock_running then
            local press = math.max(CFG.cock_press  or 0.18, 0.01)
            local hold  = math.max(CFG.cock_hold   or 0.14, 0.0)
            local back  = math.max(CFG.cock_return or 0.16, 0.01)
            local e = os.clock() - (hammer_st.cock_t0 or 0)
            -- [DAUMEN-KEYS] monotone Phase ueber die GANZE Geste (hoch + kleben + zurueck), 0..1
            hammer_st.phase = math.min(e / (press + hold + back), 1.0)
            hammer_st.key_blend = 1.0
            if e < press then                       -- 1) Daumen drueckt hoch, Hahn faehrt mit
                local u = e / press; u = u * u * (3 - 2 * u)
                hammer_st.hand_frac = u; hammer_st.ham_frac = u
            elseif e < press + hold then            -- 2) KLEBEN: Daumen + Hahn bleiben oben (Klick raster ein)
                if not hammer_st.cock_snd then hammer_st.cock_snd = true; play_weapon_sound(SND_COCK) end
                hammer_st.cocked = true
                hammer_st.hand_frac = 1.0; hammer_st.ham_frac = 1.0
            elseif e < press + hold + back then     -- 3) Daumen federt zurueck, Hahn BLEIBT hinten
                hammer_st.cocked = true
                local u = (e - press - hold) / back; u = u * u * (3 - 2 * u)
                hammer_st.hand_frac = 1.0 - u; hammer_st.ham_frac = 1.0
            else                                    -- fertig: Daumen am Griff, Hahn bleibt hinten
                hammer_st.cock_running = false
                hammer_st.hand_frac = 0.0; hammer_st.cocked = true; hammer_st.ham_frac = 1.0
            end
            return
        end

        -- Keine Geste aktiv: Daumen am Griff; Hahn folgt dem Latch (Schuss -> schneller Fall)
        hammer_st.hand_frac = hammer_st.hand_frac + (0.0 - hammer_st.hand_frac) * 0.30
        -- [DAUMEN-KEYS] Kurve ausblenden (kein Sprung, falls der letzte Key nicht auf neutral steht)
        hammer_st.key_blend = hammer_st.key_blend + (0.0 - hammer_st.key_blend) * 0.30
        local mt = hammer_st.cocked and 1.0 or 0.0
        local fall = math.min(math.max(CFG.cock_fall or 0.40, 0.05), 1.0)
        local hl = hammer_st.cocked and 0.20 or fall   -- Fall schneller als das Hochspannen
        hammer_st.ham_frac = hammer_st.ham_frac + (mt - hammer_st.ham_frac) * hl
    end

    -- ---- [EJECT] offene + gekippte Trommel -> geladene Kugeln fallen visuell raus ----
    local eject = { active = false, t0 = 0, items = {}, armed = true, exit = nil }
    local EJECT_DOWN       = 0.6
    local EJECT_ZSIGN      = -1.0
    local EJECT_SLIDE_DUR  = 0.13
    local EJECT_SLIDE_DIST = 0.055
    local EJECT_STAGGER    = 0.06
    local function update_eject()
        if not (CFG.revolver_enabled and wep.wid and wep.bullet_joints and wep.spin_joint) then return end
        if rawget(_G, "__vr_revolver_cyl_open") ~= true then
            eject.active = false; eject.items = {}; eject.armed = true; return
        end
        if eject.active then return end
        local rot = sc(wep.spin_joint, "get_Rotation"); if not rot then return end
        local bore = safe(function() return rot * Vector3f.new(0, 0, EJECT_ZSIGN) end); if not bore then return end
        if bore.y < -EJECT_DOWN and eject.armed then
            local wi = get_live_wi()
            local loaded = wi and (tonumber(sc(wi, "get_CurrentAmmoCount")) or 0) or 0
            local n = math.min(loaded, #wep.bullet_joints)
            if n > 0 then
                local bl = math.sqrt(bore.x * bore.x + bore.y * bore.y + bore.z * bore.z)
                eject.exit = (bl > 1e-6) and Vector3f.new(bore.x / bl, bore.y / bl, bore.z / bl) or Vector3f.new(0, -1, 0)
                local bp = body_tf() and sc(body_tf(), "get_Position")
                eject.floor_y = bp and bp.y or -9999
                eject.items = {}
                for i = 1, n do
                    local b = wep.bullet_joints[i]
                    local p = b and sc(b.joint, "get_Position")
                    local r = b and sc(b.joint, "get_Rotation")
                    if p then
                        eject.items[#eject.items + 1] = {
                            joint = b.joint, vis = b.vis, sx = p.x, sy = p.y, sz = p.z, rest_rot = r,
                            delay = (#eject.items) * EJECT_STAGGER, landed = false,
                            wx = 220 + i * 47, wy = 130 + i * 29, wz = 170 + i * 61,
                        }
                    end
                end
                if #eject.items > 0 then eject.active = true; eject.t0 = os.clock() end
            end
            eject.armed = false
        elseif bore.y >= -EJECT_DOWN then
            eject.armed = true
        end
    end
    local function apply_eject()
        if not (eject.active and eject.exit) then return end
        local now = os.clock(); local ex = eject.exit
        for _, it in ipairs(eject.items) do
            pcall(function() it.joint:call("set_LocalScale", it.vis) end)
            local lt = (now - eject.t0) - it.delay
            if lt <= 0 then
                pcall(function() it.joint:call("set_Position", Vector3f.new(it.sx, it.sy, it.sz)) end)
            else
                local s = (math.min(lt, EJECT_SLIDE_DUR) / EJECT_SLIDE_DUR) * EJECT_SLIDE_DIST
                local px, py, pz = it.sx + ex.x * s, it.sy + ex.y * s, it.sz + ex.z * s
                if lt > EJECT_SLIDE_DUR then
                    local ft = lt - EJECT_SLIDE_DUR
                    py = py - 0.5 * REV_GRAVITY * ft * ft
                    if py <= (eject.floor_y or -9999) then
                        py = eject.floor_y
                        if not it.landed then it.landed = true; it.land_lt = lt; play_weapon_sound(SND_DROP) end
                    end
                end
                pcall(function() it.joint:call("set_Position", Vector3f.new(px, py, pz)) end)
                if it.rest_rot then
                    local tt = it.land_lt or lt
                    local q = quat_from_euler(it.wx * tt, it.wy * tt, it.wz * tt)
                    local nr = safe(function() return (it.rest_rot * q):normalized() end)
                    if nr then pcall(function() it.joint:call("set_Rotation", nr) end) end
                end
            end
        end
    end

    -- ---- [WRIST-FLICK CLOSE] offene Trommel per SEITLICHEM Flick zuschnappen ----
    -- Handcannon: Trommel schwenkt seitlich nach LINKS (X) raus -> Schliess-Flick ist eine
    -- horizontale Hand-Bewegung -> wir messen fwd.x (Yaw), nicht fwd.y wie beim BB (Top-Break).
    local flick = { prev_fy = nil, prev_t = nil, last_close = 0, was_open = false, open_t = 0, snd_at = nil, peak_dir = 0, peak_t = 0 }
    local FLICK_VEL        = 8.0
    local FLICK_REVERSAL   = 0.30
    local FLICK_OPEN_GRACE = 0.35
    local FLICK_SND_DELAY  = 0.18
    local function update_close_flick()
        local now = os.clock()
        if flick.snd_at and now >= flick.snd_at then
            play_weapon_sound(SND_COCK); flick.snd_at = nil   -- [SOUND] Flick = Schliessen -> Close-Sound (getauscht)
        end
        local open = cyl_st.open == true
        if open and not flick.was_open then flick.open_t = now end
        flick.was_open = open
        if not (wep.wid and open) then flick.prev_fy = nil; flick.peak_dir = 0; return end
        local rot = rawget(_G, "__vr_rh_rot"); if not rot then flick.prev_fy = nil; return end
        local fwd = safe(function() return rot * Vector3f.new(0, 0, 1) end); if not fwd then return end
        local fy = fwd.x   -- [HANDCANNON] horizontaler (seitlicher) Flick statt vertikal (BB=fwd.y)
        if flick.peak_dir ~= 0 and (now - flick.peak_t) > FLICK_REVERSAL then flick.peak_dir = 0 end
        if flick.prev_fy ~= nil and flick.prev_t then
            local dt = now - flick.prev_t
            if dt > 0.001 and dt < 0.2 then
                local vel = (fy - flick.prev_fy) / dt
                if math.abs(vel) > FLICK_VEL then
                    local dir = (vel > 0) and 1 or -1
                    if flick.peak_dir ~= 0 and dir ~= flick.peak_dir
                       and (now - flick.open_t) > FLICK_OPEN_GRACE
                       and (now - flick.last_close) > 0.5 then
                        cyl_st.open = false
                        flick.snd_at = now + FLICK_SND_DELAY
                        flick.last_close = now
                        flick.peak_dir = 0
                    else
                        flick.peak_dir = dir; flick.peak_t = now
                    end
                end
            end
        end
        flick.prev_fy = fy
        flick.prev_t = now
    end

    local _cap_prev = nil            -- [SWING-CAPTURE temp]
    local _hc_was_managed = false    -- Transition managed->unmanaged -> Reload-State einmal aufraeumen
    re.on_frame(function()
        refresh_weapon()
        -- [SWING-CAPTURE temp] native Reload-Swing aufzeichnen: _03/_04/_05 LocalRotation+LocalPosition bei
        -- Aenderung loggen -> ich finde welcher Joint um welche Achse dreht UND/ODER wohin er translatiert.
        if _CAPTURE and wep.tf then
            local function jrp(name)
                local j = sc(wep.tf, "getJointByName", name)
                local r = j and sc(j, "get_LocalRotation")
                local p = j and sc(j, "get_LocalPosition")
                local rs = r and string.format("rot %.4f|%.4f|%.4f|%.4f", r.w, r.x, r.y, r.z) or "rot -"
                local ps = p and string.format("pos %.4f|%.4f|%.4f", p.x, p.y, p.z) or "pos -"
                return rs .. " " .. ps
            end
            local sig = string.format("CAP _03[%s] _04[%s] _05[%s]", jrp("_03"), jrp("_04"), jrp("_05"))
            if sig ~= _cap_prev then
                _cap_prev = sig
                -- [log entfernt]
            end
        end
        if not wep.wid then
            cyl_st._prev_b = false
            -- NICHT jeden Frame __vr_rev_cock_frac=0 setzen! reload3 laedt NACH reload2 -> das wuerde den
            -- Spann-Wert des Broken Butterfly (4500, von reload2 gesetzt) clobbern. Nur EINMAL beim Ablegen raeumen.
            if _hc_was_managed then
                _G.__vr_rev_cock_frac = 0
                rev_st.cart = false; rev_st.kf_active = false; rev_st.kf_used = false; drop2.active = false; _G.__vr_mag_in_hand = false; _hc_was_managed = false
            end
            return
        end
        _hc_was_managed = true
        _G.__re4_reload_ui_wid = wep.wid   -- [SHELL-KEYFRAMES] Keyframe-UI zeigt die Handcannon (auch ohne Clone in der Hand)
        _G.__vr_manual_reload_consume_b = not _CAPTURE
        _G.__re4_reload_grab_empty = not revolver_can_grab()
        -- [SUPPORT-HAND] Patrone in der Hand -> motion.lua Support-Hand + Two-Hand AUS (Vorrang-Flag).
        -- [SUPPORT-COOLDOWN] Nach dem Einsetzen noch kurz oben halten, damit die Support-Hand nicht SOFORT
        -- andockt ( kann die Hand erst wegziehen). Gleiches Muster wie Chicago/Rifle (_ammo_input_t),
        -- aber etwas laenger. 0 = aus.
        local cd_ok = rev_st._insert_t and (os.clock() - rev_st._insert_t) < (CFG.support_cooldown or 0.45)
        _G.__vr_mag_in_hand = (rev_st.cart or cd_ok) and true or false
        update_cylinder()
        update_close_flick()
        update_eject()
        update_cyl_spin()
        update_hammer()
        if wep.wid == HC then
            _G.__vr_rev_cock_frac = hammer_st.hand_frac or 0
            local use_aim
            if hammer_st.hand_aim.preview then use_aim = true
            elseif hammer_st.hand.preview then use_aim = false
            else use_aim = (rawget(_G, "is_aim") == true) end
            hammer_st.use_aim = use_aim
            _G.__vr_rev_cock_off = use_aim and hammer_st.hand_aim or hammer_st.hand
        else _G.__vr_rev_cock_frac = 0; hammer_st.use_aim = false end
        update_reload()
        -- [FIRE-BLOCK / SINGLE-ACTION] wie Broken Butterfly: offen ODER nicht gespannt ODER leer -> gesperrt.
        local cyl_open = rawget(_G, "__vr_revolver_cyl_open") == true
        local cocked   = hammer_st.cocked == true
        -- [LIVE-EMPTY 2026-07-08] Ladezustand fuer den Fire-Block FRISCH aus der Engine (getCurrentGunAmmo,
        -- kein Cache); gecachtes get_live_wi:get_CurrentAmmoCount war nach Save-Load stale 0 -> Dry-Fire trotz Muni.
        local wi = get_live_wi()
        local _pehc = get_pe()
        local loaded = (_pehc and tonumber(safe(function() return _pehc:call("getCurrentGunAmmo") end)))
                    or (wi and tonumber(sc(wi, "get_CurrentAmmoCount"))) or 0
        -- [UNLIMITED] Upgrade/Infinite-Script meldet AmmoCount=0 OBWOHL unendlich Muni da ist
        -- (Engine-Flag get_IsBulletFull=true; ein voll geladener Normalrevolver meldet FALSE -> kein
        -- Fehlausloesen). Zentrale Erkennung = eine Wahrheitsquelle; Modul fehlt -> alles normal.
        -- NUR bei unlimited: loaded<=0-Sperre + Dry-Fire aufgehoben. [[Notiz]]
        local unlimited = (_G.__re4_is_unlimited and _G.__re4_is_unlimited()) == true
        -- [UNLIMITED] Single-Action-Spannzwang (not cocked) UND Leer-Sperre (loaded<=0) aufheben ->
        -- einfach feuern, kein Cocking/Dry-Fire noetig. Normal (unlimited=false) = alte Logik 1:1.
        -- [KEIN COCKBACK 2026-08-04] 'cocked' faellt als Sperrgrund weg (die Handcannon spannt nicht
        -- mehr); es sperren nur noch offene Trommel und leer.
        _G.__vr_block_fire_when_empty = cyl_open or (loaded <= 0 and not unlimited)
        _G.__re4_bf_who = "re4_vr_reload3.lua:1689"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        local et = rawget(_G, "__re4_empty_trigger_held") == true
        if et and not rev_st._dry_prev and not unlimited then
            -- [KEIN COCKBACK 2026-08-04] frueher "nur wenn gespannt" -- 'cocked' ist jetzt immer false,
            -- sonst gaebe es beim Trockenschuss keinen Trommel-Weiterdreh mehr.
            if not cyl_open then
                play_weapon_sound(SND_DRY_FIRE)
                local r = cyl_cfg(wep.wid)
                spin_st.target = spin_st.target + (r.shot_deg or -30.0)
                hammer_st.cocked = false
            else
                -- Trommel offen ODER Hahn nicht gespannt: nur Klick (kein Spin/Uncock).
                play_weapon_sound(SND_DRY_FIRE)
            end
        end
        rev_st._dry_prev = et
    end)

    -- ---- Apply-Pass (voller Stack, nach der Engine-Anim) ----
    local function apply_cylinder_pass()
        if _CAPTURE then return end
        if not (CFG.revolver_enabled and wep.cyl_joint and wep.cyl_rest_rot) then return end
        local r = cyl_cfg(wep.wid)
        local has_pos = (r.px ~= 0 or r.py ~= 0 or r.pz ~= 0)
        local p = cyl_st.prog or 0
        -- _04 macht NUR den Swing. Der Chamber-Spin laeuft separat auf _05 (apply_cylinder_spin_lock).
        if p <= 0.0001 then
            if has_pos and wep.cyl_rest_pos then
                local rp = wep.cyl_rest_pos
                pcall(function() wep.cyl_joint:call("set_LocalPosition", Vector3f.new(rp.x, rp.y, rp.z)) end)
            end
            return
        end
        local q = quat_from_euler(r.rx * p, r.ry * p, r.rz * p)
        local newrot = safe(function() return (wep.cyl_rest_rot * q):normalized() end)
        if newrot then pcall(function() wep.cyl_joint:call("set_LocalRotation", newrot) end) end
        if has_pos and wep.cyl_rest_pos then
            local rp = wep.cyl_rest_pos
            pcall(function() wep.cyl_joint:call("set_LocalPosition", Vector3f.new(rp.x + r.px * p, rp.y + r.py * p, rp.z + r.pz * p)) end)
        end
    end
    local function get_gun_ammo()
        local wi = get_live_wi()
        if wi then local a = tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)); if a then return a end end
        local pe = get_pe(); if not pe then return nil end
        return tonumber(safe(function() return pe:call("getCurrentGunAmmo") end))
    end
    local _HIDE = Vector3f.new(0, 0, 0)
    local function apply_bullet_visibility()
        if _CAPTURE then return end
        if not (CFG.revolver_enabled and wep.bullet_joints and #wep.bullet_joints > 0) then return end
        local cap = #wep.bullet_joints
        local ammo = get_gun_ammo(); if not ammo then return end
        if ammo > cap then ammo = cap elseif ammo < 0 then ammo = 0 end
        for i, b in ipairs(wep.bullet_joints) do
            if i <= ammo then pcall(function() b.joint:call("set_LocalScale", b.vis) end)
            else pcall(function() b.joint:call("set_LocalScale", _HIDE) end) end
        end
    end
    local _shell_fade = {}
    local function apply_shell_pose()
        if not (CFG.revolver_enabled and wep.wid) then return end
        local s = SHELL[wep.wid]
        local want = nil
        if s and (rev_st.cart or rev_st.preview) and s.pose and s.pose ~= "" then want = s.pose end
        -- [POSE_FADE] beim Loslassen ueber POSE_FADE_DUR zurueckblenden statt snappen (s als data)
        local fname, b, fs = _G.__re4_pose_fade_step(_shell_fade, want, s)
        if not fname then return end
        s = fs or s; if not s then return end
        local f = rawget(_G, "__re4_reload_apply_pose")
        if f then pcall(function() f(fname, b) end) end
        if s.t_rx ~= 0 or s.t_ry ~= 0 or s.t_rz ~= 0 then
            local bt = body_tf()
            local thumb = bt and sc(bt, "getJointByName", "L_Thumb1")
            local cur = thumb and sc(thumb, "get_LocalRotation")
            if cur then
                local q = quat_from_euler(s.t_rx*b, s.t_ry*b, s.t_rz*b)
                pcall(function() thumb:call("set_LocalRotation", (cur * q):normalized()) end)
            end
        end
        -- [ZEIGEFINGER] additiv auf L_IndexF1/2/3 (Greif-Pose der Patrone, eigenstaendig).
        if s.i_rx ~= 0 or s.i_ry ~= 0 or s.i_rz ~= 0 then
            local bt = body_tf()
            for _, jn in ipairs({ "L_IndexF1", "L_IndexF2", "L_IndexF3" }) do
                local jt = bt and sc(bt, "getJointByName", jn)
                local cur = jt and sc(jt, "get_LocalRotation")
                if cur then
                    local q = quat_from_euler(s.i_rx*b, s.i_ry*b, s.i_rz*b)
                    pcall(function() jt:call("set_LocalRotation", (cur * q):normalized()) end)
                end
            end
        end
    end

    -- ---- [MESH-CLONE] Patrone in der Hand (Trommel bleibt unberuehrt) ----
    local function rev_gun_mesh()
        if not wep.tf then return nil end
        local go = sc(wep.tf, "get_GameObject")
        return go and sc(go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    end
    cart_destroy = function()
        if cart_clone.obj then pcall(function()
            local td = sdk.find_type_definition("via.GameObject"); local d = td and td:get_method("destroy(via.GameObject)")
            if d then d:call(nil, cart_clone.obj) end
        end) end
        cart_clone.obj, cart_clone.mesh, cart_clone.wid, cart_clone.parts_sig = nil, nil, nil, nil
    end
    local function cart_spawn()
        if cart_clone.obj then return true end
        local gmesh = rev_gun_mesh(); if not gmesh then return false end
        local holder = safe(function() return gmesh:call("getMesh") end); if not holder then return false end
        local gmat = safe(function() return gmesh:call("get_Material") end)
        local go_td = sdk.find_type_definition("via.GameObject")
        local create = go_td and go_td:get_method("create(System.String)")
        local go = create and safe(function() return create:call(nil, "vr_handcannon_cart") end); if not go then return false end
        pcall(function() go:add_ref() end)
        pcall(function() go:call("createComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)
        local mesh = safe(function() return go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
        if not mesh then return false end
        pcall(function() mesh:call("setMesh", holder) end)
        if gmat then pcall(function() mesh:call("set_Material", gmat) end) end
        pcall(function() mesh:call("set_DrawDefault", true) end)
        pcall(function() mesh:call("set_Enabled", true) end)
        pcall(function() mesh:call("set_FrustumCulling", false) end)
        cart_clone.obj, cart_clone.mesh, cart_clone.wid = go, mesh, wep.wid
        -- [NO_LAG] nativ ans L_Hand-Joint parenten -> Engine propagiert die Transform VOR dem Skinning
        -- -> kein Render-Versatz beim Laufen. Danach nur noch LOKALE Pose setzen.
        cart_clone.parented = false
        local ctf = safe(function() return go:call("get_Transform") end)
        local bt2 = body_tf()
        if ctf and bt2 then
            pcall(function() ctf:call("set_Parent", bt2) end)
            if pcall(function() ctf:call("set_ParentJoint", "L_Hand") end) then cart_clone.parented = true end
        end
        return true
    end
    local function cart_isolate()
        if not cart_clone.mesh then return end
        local s = SHELL[wep.wid] or {}
        local sig = "parts:" .. tostring(s.parts or "20,30")
        if cart_clone.parts_sig == sig then return end
        local keep = {}; for n in tostring(s.parts or "20,30"):gmatch("%d+") do keep[tonumber(n)] = true end
        local applied = true
        for i = 0, 48 do
            if not pcall(function() cart_clone.mesh:call("setPartsEnable", i, keep[i] == true) end) then applied = false end
        end
        if applied then cart_clone.parts_sig = sig end
    end
    local function cart_set_tf(tf, p, rot, scl)
        local okp = pcall(function() tf:set_position(p, true) end)
        if not okp then pcall(function() tf:call("set_Position", p) end) end
        if rot then local okr = pcall(function() tf:set_rotation(rot) end); if not okr then pcall(function() tf:call("set_Rotation", rot) end) end end
        if scl then pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end) end
    end
    local function apply_held_cartridge()
        if not (CFG.revolver_enabled and wep.wid) then return end
        -- [SHELL-KEYFRAMES 2026-07-24] Keyframe-Preview an -> Clone spawnen (zum Tunen ohne Patrone).
        local _kms = rawget(_G, "__re4_reload_mag_slide")
        local _kfp = (_kms and _kms.shell_preview and _kms.KEYFRAME_INSERT and _kms.KEYFRAME_INSERT[wep.wid]) == true
        if not (rev_st.cart or rev_st.preview or drop2.active or _kfp) then
            if cart_clone.obj then cart_destroy() end
            return
        end
        if drop2.active then return end
        if cart_clone.obj and cart_clone.wid ~= wep.wid then cart_destroy() end
        if not cart_clone.obj then
            local ok = cart_spawn()
            -- [log entfernt]
            if not ok then return end
        end
        cart_isolate()
        -- [SHELL-KEYFRAMES] Bahn ODER Preview -> Clone-Position macht reposition_cart_late; hier nur Scale/entkoppeln.
        if rev_st.kf_active or _kfp then
            if _kfp then
                local tf = safe(function() return cart_clone.obj:call("get_Transform") end)
                if tf then
                    if cart_clone.parented then pcall(function() tf:call("set_Parent", nil) end); cart_clone.parented = false end
                    local scl = (SHELL[wep.wid] or {}).scale or 1.0
                    pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
                end
            end
            return
        end
        local s = SHELL[wep.wid] or {}
        -- [NO_LAG] geparentet ans L_Hand: nur LOKALE Pose (Offset war schon hand-relativ = jetzt lokal).
        if cart_clone.parented then
            local tf = safe(function() return cart_clone.obj:call("get_Transform") end); if not tf then return end
            local scl = s.scale or 1.0
            pcall(function() tf:call("set_LocalPosition", Vector3f.new(s.x or 0, s.y or 0, s.z or 0)) end)
            pcall(function() tf:call("set_LocalRotation", quat_from_euler(s.rx or 0, s.ry or 0, s.rz or 0)) end)
            pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
            return
        end
        local bt = body_tf(); local lhj = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lhj and sc(lhj, "get_Position"); if not hp then return end
        local hr = lhj and sc(lhj, "get_Rotation")
        local wx, wy, wz = hp.x, hp.y, hp.z
        if hr then
            local off = safe(function() return hr * Vector3f.new(s.x or 0, s.y or 0, s.z or 0) end)
            if off then wx, wy, wz = hp.x + off.x, hp.y + off.y, hp.z + off.z end
        end
        local tf = safe(function() return cart_clone.obj:call("get_Transform") end); if not tf then return end
        local rot = hr and safe(function() return (hr * quat_from_euler(s.rx or 0, s.ry or 0, s.rz or 0)):normalized() end)
        cart_set_tf(tf, Vector3f.new(wx, wy, wz), rot, s.scale or 1.0)
    end
    -- [WOBBLE-FIX] Patrone NACH motion.lua's finalem L_Hand-Write nachziehen.
    -- apply_held_cartridge laeuft im BeginRendering-PRE-Pass -> liest die Hand BEVOR motion sie auf die
    -- VR-Endlage setzt (attach_left_hand im BeginRendering-POST) -> Patrone haengt 1 Pass hinterher = Wabbeln.
    -- Diese schlanke Variante laeuft im POST-Pass (nach motion, da reload3 nach motion laedt) und repositioniert
    -- NUR (kein Spawn/Isolate) auf die finale Hand -> Patrone klebt sauber.
    local function reposition_cart_late()
        if not (CFG.revolver_enabled and wep.wid and cart_clone.obj) then return end
        if drop2.active then return end
        -- [SHELL-KEYFRAMES 2026-07-24] Bahn aktiv -> Clone entlang der Keyframes fahren (relativ zur Waffe),
        -- am Bahn-Ende Clone entfernen (+1 sass beim Bahn-Start). cart_set_tf = sichtbar (mit Scale).
        if rev_st.kf_active then
            local ms = rawget(_G, "__re4_reload_mag_slide")
            local tf = safe(function() return cart_clone.obj:call("get_Transform") end)
            if ms and tf and type(ms.shell_pose_at) == "function" and wep.tf then
                local dur = tonumber(ms.shell_dur) or 0.4
                local tt = (os.clock() - (rev_st.kf_t0 or 0)) / math.max(dur, 0.01)
                if tt > 1.0 then tt = 1.0 end
                local x, y, z, rx, ry, rz = ms.shell_pose_at(wep.wid, tt)
                local gp = sc(wep.tf, "get_Position"); local gr = sc(wep.tf, "get_Rotation")
                if x and gp and gr then
                    local off = safe(function() return gr * Vector3f.new(x, y, z) end)
                    local pos = off and Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z) or gp
                    local rot = safe(function() return (gr * quat_from_euler(rx, ry, rz)):normalized() end)
                    cart_set_tf(tf, pos, rot, (SHELL[wep.wid] or {}).scale or 1.0)
                end
                if tt >= 1.0 then rev_st.kf_active = false; rev_st.cart = false end
            else
                rev_st.kf_active = false
            end
            return
        end
        -- [SHELL-KEYFRAMES] Keyframe-Preview: Clone an der Waffe + Tuning-Lage zeigen (nachgebaut vom reload3-Pfad).
        do
            local _kms = rawget(_G, "__re4_reload_mag_slide")
            if _kms and _kms.shell_preview and _kms.KEYFRAME_INSERT and _kms.KEYFRAME_INSERT[wep.wid] then
                local sl = _kms.shell_live or {}
                local tf = safe(function() return cart_clone.obj:call("get_Transform") end)
                local gp = wep.tf and sc(wep.tf, "get_Position")
                local gr = wep.tf and sc(wep.tf, "get_Rotation")
                if tf and gp and gr then
                    local off = safe(function() return gr * Vector3f.new(sl.x or 0, sl.y or 0, sl.z or 0) end)
                    local pos = off and Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z) or gp
                    local rot = safe(function() return (gr * quat_from_euler(sl.rx or 0, sl.ry or 0, sl.rz or 0)):normalized() end)
                    cart_set_tf(tf, pos, rot, (SHELL[wep.wid] or {}).scale or 1.0)
                end
                return
            end
        end
        if not (rev_st.cart or rev_st.preview) then return end
        local s = SHELL[wep.wid] or {}
        -- [NO_LAG] geparentet ans L_Hand: nur LOKALE Pose (Offset war schon hand-relativ = jetzt lokal).
        if cart_clone.parented then
            local tf = safe(function() return cart_clone.obj:call("get_Transform") end); if not tf then return end
            local scl = s.scale or 1.0
            pcall(function() tf:call("set_LocalPosition", Vector3f.new(s.x or 0, s.y or 0, s.z or 0)) end)
            pcall(function() tf:call("set_LocalRotation", quat_from_euler(s.rx or 0, s.ry or 0, s.rz or 0)) end)
            pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
            return
        end
        local bt = body_tf(); local lhj = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lhj and sc(lhj, "get_Position"); if not hp then return end
        local hr = lhj and sc(lhj, "get_Rotation")
        local wx, wy, wz = hp.x, hp.y, hp.z
        if hr then
            local off = safe(function() return hr * Vector3f.new(s.x or 0, s.y or 0, s.z or 0) end)
            if off then wx, wy, wz = hp.x + off.x, hp.y + off.y, hp.z + off.z end
        end
        local tf = safe(function() return cart_clone.obj:call("get_Transform") end); if not tf then return end
        local rot = hr and safe(function() return (hr * quat_from_euler(s.rx or 0, s.ry or 0, s.rz or 0)):normalized() end)
        cart_set_tf(tf, Vector3f.new(wx, wy, wz), rot, s.scale or 1.0)
    end
    local function apply_cart_drop()
        if not (CFG.revolver_enabled and wep.wid and drop2.active) then return end
        if not cart_clone.obj then drop2.active = false; return end
        local t = os.clock() - drop2.t0
        if t > REV_DROP_DUR then drop2.active = false; cart_destroy(); return end
        if not drop2.snd and t >= 0.45 then drop2.snd = true; play_weapon_sound(SND_DROP) end
        local fall = 0.5 * REV_GRAVITY * t * t
        local tf = safe(function() return cart_clone.obj:call("get_Transform") end); if not tf then return end
        local s = (SHELL[wep.wid] or {}).scale or 1.0
        cart_set_tf(tf, Vector3f.new(drop2.sx, drop2.sy - fall, drop2.sz), nil, s)
    end
    local function apply_cylinder_spin_lock()
        if not (CFG.revolver_enabled and wep.spin_joint and wep.spin_rest_rot) then return end
        local rot = wep.spin_rest_rot
        if spin_st.current ~= 0 then
            rot = safe(function() return (wep.spin_rest_rot * quat_from_euler(0, 0, spin_st.current)):normalized() end) or wep.spin_rest_rot
        end
        pcall(function() wep.spin_joint:call("set_LocalRotation", rot) end)
    end
    local function apply_hammer_pass()
        if not (CFG.revolver_enabled and wep.wid == HC and wep.hammer_joint and wep.hammer_rest_rot) then return end
        local h = hammer_cfg(wep.wid)
        local f = hammer_st.ham_frac or 0
        local ax = h.idle_rx + (h.rx - h.idle_rx) * f
        local ay = h.idle_ry + (h.ry - h.idle_ry) * f
        local az = h.idle_rz + (h.rz - h.idle_rz) * f
        local q = quat_from_euler(ax, ay, az)
        local nr = safe(function() return (wep.hammer_rest_rot * q):normalized() end)
        if nr then pcall(function() wep.hammer_joint:call("set_LocalRotation", nr) end) end
    end
    -- [SLERP] kuerzester Bogen Identitaet->Ziel; verhindert den Euler-"Kreis" (Achse wandert) bei grossen Winkeln.
    local _IDENT_Q = Quaternion.new(1, 0, 0, 0)
    local function qslerp(a, b, t)
        local dot = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z
        if dot < 0 then b = Quaternion.new(-b.w, -b.x, -b.y, -b.z); dot = -dot end
        if dot > 0.9995 then
            return Quaternion.new(a.w + (b.w - a.w) * t, a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t):normalized()
        end
        local theta = math.acos(dot); local s = math.sin(theta)
        local w1 = math.sin((1 - t) * theta) / s; local w2 = math.sin(t * theta) / s
        return Quaternion.new(a.w * w1 + b.w * w2, a.x * w1 + b.x * w2, a.y * w1 + b.y * w2, a.z * w1 + b.z * w2):normalized()
    end
    local function apply_thumb_pass()
        if not (CFG.revolver_enabled and wep.wid == HC) then return end
        local bt = body_tf(); if not bt then return end
        -- [DAUMEN-KEYS] Sind Stuetzpunkte gesetzt, kommen Winkel UND Versatz je Glied aus der Kurve ueber
        -- die Phase -- statt des 2-Punkt-Lerps unten. Geschrieben wird ABSOLUT gegen die BIND-Pose, sonst
        -- bleibt die Spiel-Anim der Chef und unsere Werte sind nur ein Offset im Zappeln.
        -- Aim/Huefte haben eigene Listen; ist die zustaendige leer, gilt die andere.
        local kb = hammer_st.key_blend or 0
        local KL = thumb_keys(wep.wid, hammer_st.use_aim == true)
        if #KL == 0 then KL = thumb_keys(wep.wid, hammer_st.use_aim ~= true) end
        local klive = hammer_st.kprev and (hammer_st.klive or #KL == 0)
        if kb > 0.0001 and (klive or #KL > 0) then
            local out = hammer_st.kout
            if klive then
                for i = 1, 3 do
                    local s, o = hammer_st.kedit[i], out[i]
                    o.x, o.y, o.z, o.px, o.py, o.pz = s.x or 0, s.y or 0, s.z or 0, s.px or 0, s.py or 0, s.pz or 0
                end
            else
                thumb_key_sample(KL, (hammer_st.phase or 0) * 100.0, out)
            end
            for i, jn in ipairs(hammer_st.thumb_joints) do
                local jt = sc(bt, "getJointByName", jn)
                local cur = jt and sc(jt, "get_LocalRotation")
                if cur then
                    local o = out[i]
                    local rest = sc(jt, "get_BaseLocalRotation") or cur
                    local q = quat_from_euler(o.x or 0, o.y or 0, o.z or 0)
                    local tgt = safe(function() return (rest * q):normalized() end)
                    if tgt then
                        -- qslerp (nicht cur:slerp): dreht den kuerzesten Bogen, sonst kann der Daumen bei
                        -- grossen Key-Winkeln den Umweg ueber 360 Grad nehmen.
                        local nr = tgt
                        if kb < 0.999 then
                            local okb, r2 = pcall(function() return qslerp(cur, tgt, kb) end)
                            if okb and r2 then nr = r2 end
                        end
                        pcall(function() jt:call("set_LocalRotation", nr) end)
                    end
                    -- Versatz PRO GLIED, ebenfalls absolut: Ziel = BIND-Position + Key-Versatz.
                    local restp = sc(jt, "get_BaseLocalPosition")
                    local lp = restp and sc(jt, "get_LocalPosition")
                    if restp and lp then
                        local tx, ty, tz = restp.x + (o.px or 0), restp.y + (o.py or 0), restp.z + (o.pz or 0)
                        pcall(function() jt:call("set_LocalPosition", Vector3f.new(
                            lp.x + (tx - lp.x) * kb, lp.y + (ty - lp.y) * kb, lp.z + (tz - lp.z) * kb)) end)
                    end
                end
            end
            return
        end
        local f = hammer_st.hand_frac or 0
        if f <= 0.0001 then return end
        local cfg = hammer_st.use_aim and thumb_cfg_aim(wep.wid) or thumb_cfg(wep.wid)
        for i, jn in ipairs(hammer_st.thumb_joints) do
            local jt = sc(bt, "getJointByName", jn)
            local cur = jt and sc(jt, "get_LocalRotation")
            if cur then
                local c = cfg[i]
                if (c.cx or 0) ~= 0 or (c.cy or 0) ~= 0 or (c.cz or 0) ~= 0 then
                    -- Ziel-Rotation einmal aus Euler bauen, dann per f slerpen (kuerzester Bogen, kein Kreis).
                    local qfull = quat_from_euler(c.cx or 0, c.cy or 0, c.cz or 0)
                    local q = qslerp(_IDENT_Q, qfull, f)
                    local nr = safe(function() return (cur * q):normalized() end)
                    if nr then pcall(function() jt:call("set_LocalRotation", nr) end) end
                end
                if i == 1 then
                    local tp = hammer_st.use_aim and hammer_st.thumb_pos_aim or hammer_st.thumb_pos
                    if tp and (tp.x ~= 0 or tp.y ~= 0 or tp.z ~= 0) then
                        local lp = sc(jt, "get_LocalPosition")
                        if lp then pcall(function() jt:call("set_LocalPosition", Vector3f.new(lp.x + tp.x * f, lp.y + tp.y * f, lp.z + tp.z * f)) end) end
                    end
                end
            end
        end
    end
    local function apply_revolver_pass()
        if _CAPTURE then return end   -- [SWING-CAPTURE] keine Overrides -> reine native Anim sichtbar+messbar
        apply_cylinder_pass()
        apply_cylinder_spin_lock()  -- _05 Eigenrotation: haelt Ruhe + Chamber-Advance pro Schuss (BB-konform)
        apply_hammer_pass()
        apply_thumb_pass()
        apply_bullet_visibility()
        apply_held_cartridge()
        apply_cart_drop()
        apply_eject()
        apply_shell_pose()
    end
    pcall(function() re.on_pre_application_entry("LockScene", apply_revolver_pass) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", apply_revolver_pass) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", apply_revolver_pass) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", apply_revolver_pass) end)
    -- [WOBBLE-FIX] Patrone NACH motion.lua's BeginRendering-POST (attach_left_hand) nochmal auf die finale
    -- Hand setzen. reload3 laedt nach motion -> dieser POST-Hook feuert nach motion -> Patrone klebt sauber.
    pcall(function() re.on_application_entry("BeginRendering", reposition_cart_late) end)

    -- ---- Holster-Wrapper (Handcannon -> reload3-Revolver, sonst weiter an Kette) ----
    local _orig_hc = _G.__re4_reload_set_mag_in_hand
    _G.__re4_reload_set_mag_in_hand = function(active)
        if is_revolver(get_equip_wid()) then return revolver_set_mag_in_hand(active) end
        if _orig_hc then return _orig_hc(active) end
        return false
    end

    re.on_script_reset(function()
        rev_st.cart = false
        drop2.active = false
        _G.__vr_mag_in_hand = false
        if cart_destroy then cart_destroy() end
        if wep.hammer_joint and wep.hammer_rest_rot then pcall(function() wep.hammer_joint:call("set_LocalRotation", wep.hammer_rest_rot) end) end
        hammer_st.hand_frac = 0.0; hammer_st.ham_frac = 0.0; hammer_st.cocked = false; hammer_st.prev_seq = nil; _G.__vr_rev_cock_frac = 0
        eject.active = false; eject.items = {}; eject.armed = true
        spin_st.target = 0.0; spin_st.current = 0.0; spin_st.prev_seq = nil
    end)

    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion _G.__re4_reload3_handcannon_ui (236 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end
-- =====================================================================
-- ENDE HANDCANNON-REVOLVER (wp4502)
-- =====================================================================

-- =====================================================================
-- ROCKET LAUNCHER (wp4900) — eigener, vollstaendig gekapselter do-Block
-- =====================================================================
-- Reload denkbar einfach: Warhead = joint _07. Schuss -> Engine entfernt den
-- Warhead (Ammo 0). Griff ins Mag-Holster -> wenn Reserve > 0: Warhead "in der Hand"
-- (Hand-Pose aus reload.json POSES, gecaptured) -> Hand nah an die Waffe
-- (Dock-Naehe an _07) -> +1 Ammo (Engine zeigt den Warhead wieder). Fertig.
-- Kein Mag-Drop / kein Slide. Nutzt reload3-Top-Level-Helfer (safe/sc/quat_from_euler/
-- get_equip_wid/body_tf/get_pe/find_weapon). Eigenes JSON: re4_vr_reload3_rl.json
-- Holster-Kette: RL -> Handcannon -> Chicago -> reload2 -> reload.
-- =====================================================================
do
    local RL = 4900   -- "primaerer" Key fuer geteilte Config/Pose (alle RL-Varianten 1:1 gleich)
    -- Alle Rocket-Launcher-Varianten teilen sich EIN Setup (Warhead/Pose/Dock/Offsets identisch):
    -- 4900 Rocket Launcher · 4901 RL (Special) · 4902 Infinite RL
    local RLS = { [4900] = true, [4901] = true, [4902] = true }
    local function is_rl(wid) return wid ~= nil and RLS[wid] == true end
    local snd_sc_td = sdk.typeof("soundlib.SoundContainer")

    -- Joints (CODE-Konstanten,): Warhead = _07 (alle Varianten gleich)
    local JOINTS = { [4900] = { warhead = "_07" }, [4901] = { warhead = "_07" }, [4902] = { warhead = "_07" } }

    -- Config (eigenes JSON)
    local CFG_PATH = "re4_vr/re4_vr_reload3_rl.json"
    local CFG = { rl_enabled = true, insert_distance = 0.15, reload_ammo = true, sound_enabled = true,
                  dock_joint = "_03", dock_x = 0.0, dock_y = 0.057, dock_z = 0.155,
                  -- Warhead-in-Hand = Mesh-Clone von Part 03 an L_Hand: Offset/Rot/Scale
                  parts = "03", wx = 0.0, wy = 0.0, wz = 0.0, wrx = 0.0, wry = 0.0, wrz = 0.0, wscale = 1.0 }

    -- ---- Hand-Pose: EIGENE DATEN-KOPIE (gestures-unabhaengig, in reload3 gebacken -> gestures.json loeschbar).
    -- "WarheadHold" = 1:1-Kopie der LE5MAG-Pose aus re4_vr_gestures.json (guter Greif-Start). NIE live aus
    -- gestures laden. Werte fest hier; im UI per Pose-Name aenderbar, feintunebar via Daumen/Zeigefinger-Offsets.
    local RLPOSES = {
        ["WarheadHold"] = { hand = "left", bones = {
            ["L_IndexF1"]={0.894645,0.048644,-0.003804,-0.444105}, ["L_IndexF2"]={0.807797,0.0,0.0,-0.589461}, ["L_IndexF3"]={0.939637,0.0,0.0,-0.342172},
            ["L_MiddleF1"]={0.918571,-0.004702,-0.034397,-0.393728}, ["L_MiddleF2"]={0.676934,0.0,0.0,-0.736044}, ["L_MiddleF3"]={0.957338,0.0,0.0,-0.288970},
            ["L_Palm"]={1.0,0.0,0.0,0.0},
            ["L_PinkyF1"]={0.966747,-0.031850,0.005328,-0.253687}, ["L_PinkyF2"]={0.700924,0.0,0.0,-0.713236}, ["L_PinkyF3"]={0.923357,0.0,0.0,-0.383943},
            ["L_RingF1"]={0.921790,-0.022723,-0.003569,-0.387007}, ["L_RingF2"]={0.710747,0.0,0.0,-0.703447}, ["L_RingF3"]={0.933578,0.0,0.0,-0.358375},
            ["L_Thumb1"]={0.918569,0.252866,-0.108586,-0.283724}, ["L_Thumb2"]={0.999635,0.0,-0.027026,0.0}, ["L_Thumb3"]={0.923391,-0.000011,0.383861,-0.000004},
        } },
    }
    local _rlpmap, _rlpmap_tf = {}, nil
    local function rl_pose_map()
        local tf = body_tf(); if not tf then return {} end
        if tf == _rlpmap_tf and next(_rlpmap) ~= nil then return _rlpmap end
        local map = {}
        local joints = safe(function() return tf:call("get_Joints") end)
        if joints then
            local count = safe(function() return joints:call("get_Count") end)
            if type(count) == "number" then
                for i = 0, count - 1 do
                    local j = safe(function() return joints[i] end)
                    local nm = j and safe(function() return j:call("get_Name") end)
                    if nm then map[tostring(nm)] = j end
                end
            end
        end
        _rlpmap_tf, _rlpmap = tf, map
        return map
    end
    local function rl_pose_apply(name, blend)
        local pose = name and RLPOSES[name]; if not (pose and pose.bones) then return false end
        local map = rl_pose_map(); if next(map) == nil then return false end
        blend = blend or 1.0
        if blend <= 0.0 then return true end
        for bone, v in pairs(pose.bones) do
            local j = map[bone]
            if j and v and v[1] then
                if blend >= 0.9999 then
                    pcall(function() j:call("set_LocalRotation", Quaternion.new(v[1], v[2], v[3], v[4])) end)
                else
                    local c = sc(j, "get_LocalRotation")
                    if c then
                        local tw, tx, ty, tz = v[1], v[2], v[3], v[4]
                        if (c.w*tw + c.x*tx + c.y*ty + c.z*tz) < 0.0 then tw, tx, ty, tz = -tw, -tx, -ty, -tz end
                        local w, x, y, z = c.w+(tw-c.w)*blend, c.x+(tx-c.x)*blend, c.y+(ty-c.y)*blend, c.z+(tz-c.z)*blend
                        local len = math.sqrt(w*w + x*x + y*y + z*z)
                        if len > 1e-6 then pcall(function() j:call("set_LocalRotation", Quaternion.new(w/len, x/len, y/len, z/len)) end) end
                    end
                end
            end
        end
        return true
    end

    -- Hand-Pose-Config "Warhead halten": Pose-Name (gebackene RLPOSES) + Daumen/Zeigefinger additiv.
    local POSE = { [RL] = { pose = "WarheadHold", t_rx = 0, t_ry = 0, t_rz = 0, i_rx = 0, i_ry = 0, i_rz = 0 } }
    local function pose_cfg(wid)
        local p = wid and POSE[wid]; if not p then p = {}; if wid then POSE[wid] = p end end
        p.pose = p.pose or "WarheadHold"
        p.t_rx = p.t_rx or 0; p.t_ry = p.t_ry or 0; p.t_rz = p.t_rz or 0
        p.i_rx = p.i_rx or 0; p.i_ry = p.i_ry or 0; p.i_rz = p.i_rz or 0
        return p
    end

    local function save_cfg()
        local data = { cfg = CFG, pose = {} }
        for wid, v in pairs(POSE) do data.pose[tostring(wid)] = v end
        pcall(function() json.dump_file(CFG_PATH, data) end)
    end
    local function load_cfg()
        local data = safe(function() return json.load_file(CFG_PATH) end)
        if type(data) ~= "table" then return end
        local c = data.cfg or data
        if type(c.rl_enabled) == "boolean" then CFG.rl_enabled = c.rl_enabled end
        if type(c.reload_ammo) == "boolean" then CFG.reload_ammo = c.reload_ammo end
        if type(c.sound_enabled) == "boolean" then CFG.sound_enabled = c.sound_enabled end
        if type(c.insert_distance) == "number" then CFG.insert_distance = c.insert_distance end
        if type(c.dock_joint) == "string" then CFG.dock_joint = c.dock_joint end
        if type(c.parts) == "string" then CFG.parts = c.parts end
        for _, f in ipairs({ "dock_x", "dock_y", "dock_z", "wx", "wy", "wz", "wrx", "wry", "wrz", "wscale" }) do if type(c[f]) == "number" then CFG[f] = c[f] end end
        if type(data.pose) == "table" then
            for k, v in pairs(data.pose) do
                local wid = tonumber(k)
                if wid and type(v) == "table" then
                    local p = pose_cfg(wid)
                    if type(v.pose) == "string" then p.pose = v.pose end
                    for _, f in ipairs({ "t_rx", "t_ry", "t_rz", "i_rx", "i_ry", "i_rz" }) do if type(v[f]) == "number" then p[f] = v[f] end end
                end
            end
        end
    end
    load_cfg()

    -- State
    local rl_wep = { wid = nil, tf = nil, warhead_joint = nil, dock_joint = nil }
    local rl_st = { cart = false, preview = false }
    -- Mesh-Clone des Warheads (Mesh-Part 03) in der Hand — forward-deklariert (Reset/Transition nutzen es).
    local wh_destroy
    local wh_clone = { obj = nil, mesh = nil, wid = nil, parts_sig = nil }

    local function wp_label(wid) return wid and string.format("wp%04d", wid) or "-" end
    local function play_sound(id)
        if not CFG.sound_enabled or not id or id <= 0 then return end
        local tf = rl_wep.tf; if not tf then return end
        local go = safe(function() return tf:call("get_GameObject") end); if not go or not snd_sc_td then return end
        local scn = safe(function() return go:call("getComponent(System.Type)", snd_sc_td) end); if not scn then return end
        pcall(function() scn:call("trigger(System.UInt32)", id) end)
    end
    local SND_GRAB   = 1839787494   -- Griff ins Holster (vom Revolver geseedet; echte RL-ID ggf. nachziehen)
    local SND_INSERT = 942865223    -- Warhead eingesetzt

    -- ---- Ammo-Helfer ----
    local function rl_get_wi()
        -- [ACCESSOR 2026-08-12] zuerst die ECHTE, persistente Instanz (s. reload.lua,
        -- __re4_real_wi). Alles darunter sind KOPIEN -> Schreiben verpufft.
        local _rw = _G.__re4_real_wi and _G.__re4_real_wi()
        if _rw then return _rw end
        local pe = get_pe()
        local ewi = pe and safe(function() return pe:call("getEquipWeaponItem") end)
        if ewi and safe(function() return ewi:call("get_CurrentAmmoCount") end) ~= nil then return ewi end
        return nil
    end
    local function gun_is_full(wi)
        local bf = safe(function() return wi:call("get_IsBulletFull") end)
        if bf ~= nil then return bf == true end
        local loaded = tonumber(sc(wi, "get_CurrentAmmoCount")) or 0
        local maxc   = tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0
        return maxc > 0 and loaded >= maxc
    end
    local function rl_reserve()
        local wi = rl_get_wi(); if not wi then return 0 end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end)
        return (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
    end
    local function rl_can_grab()
        local wi = rl_get_wi(); if not wi then return false end
        -- HART: nur 1 Warhead im Launcher -> bei loaded >= 1 Holster gesperrt (-Vorgabe).
        local loaded = tonumber(sc(wi, "get_CurrentAmmoCount")) or 0
        if loaded >= 1 then return false end
        if gun_is_full(wi) then return false end
        return rl_reserve() > 0
    end
    -- +1 verlustsicher (write_dword 0x44, Fallback addAmmoCount; Reserve nur ziehen wenn Pfad nicht selbst zog).
    local function rl_load_one()
        if not CFG.reload_ammo then return false end
        local wi = rl_get_wi(); if not wi then return false end
        if gun_is_full(wi) then return false end
        local loaded = tonumber(sc(wi, "get_CurrentAmmoCount")) or 0
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end)
        local function read_reserve()
            return (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
        end
        local r_b4 = read_reserve()
        if r_b4 <= 0 then return false end
        -- [RUNTIME-FIX 0/0] Erfolg gegen getCurrentGunAmmo (Laufzeit) pruefen, NICHT wi:get_CurrentAmmoCount
        -- (= evtl. Spiegel -> write_dword scheint zu gelingen, addAmmoCount uebersprungen, Reserve weg). Menge +1.
        local function gun_ammo() return pe and tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or nil end
        local base = gun_ammo() or loaded
        pcall(function() wi:write_dword(0x44, loaded + 1) end)
        local af = gun_ammo() or base
        if af <= base then pcall(function() wi:call("addAmmoCount", 1, true) end); af = gun_ammo() or base end
        if af <= base then return false end
        local gained = af - base
        if read_reserve() >= r_b4 and inv and ammo_id then
            _G.__re4_safe_reduce(inv, ammo_id, gained)
        end
        return true
    end

    -- ---- Refresh: Waffe + Joints ----
    local function rl_refresh()
        local wid = get_equip_wid()
        if not (CFG.rl_enabled and is_rl(wid)) then
            rl_wep.wid, rl_wep.tf, rl_wep.warhead_joint, rl_wep.dock_joint = nil, nil, nil, nil
            return
        end
        rl_wep.wid = wid
        if not (rl_wep.tf and safe(function() return rl_wep.tf:call("get_Position") end)) then
            local _, tf = find_weapon(wid); rl_wep.tf = tf
        end
        local tf = rl_wep.tf
        if tf then
            local jc = JOINTS[wid] or {}
            rl_wep.warhead_joint = (jc.warhead and jc.warhead ~= "") and sc(tf, "getJointByName", jc.warhead) or nil
            rl_wep.dock_joint = (CFG.dock_joint and CFG.dock_joint ~= "") and sc(tf, "getJointByName", CFG.dock_joint) or rl_wep.warhead_joint
        end
    end

    -- ---- Holster-Griff: Warhead in die Hand (nur wenn Reserve > 0 und nicht voll) ----
    local function rl_set_mag_in_hand(active)
        if active then
            if rl_st.cart then return true end
            if not rl_can_grab() then return false end
            rl_st.cart = true
            play_sound(SND_GRAB)
            return true
        else
            rl_st.cart = false
            return true
        end
    end

    -- ---- Dock-Naehe -> einsetzen (+1) ----
    local function left_hand_pos()
        local bt = body_tf(); local lhj = bt and sc(bt, "getJointByName", "L_Hand")
        return lhj and sc(lhj, "get_Position")
    end
    local function dock_world()
        local dj = rl_wep.dock_joint; if not dj then return nil end
        local p = sc(dj, "get_Position"); if not p then return nil end
        local r = sc(dj, "get_Rotation")
        if r then
            local off = safe(function() return r * Vector3f.new(CFG.dock_x or 0, CFG.dock_y or 0, CFG.dock_z or 0) end)
            if off then return Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
        end
        return Vector3f.new(p.x, p.y, p.z)
    end
    local function rl_update_insert()
        if not rl_st.cart then return end
        local hp = left_hand_pos(); local dp = dock_world()
        if not (hp and dp) then return end
        local d = math.sqrt((hp.x - dp.x)^2 + (hp.y - dp.y)^2 + (hp.z - dp.z)^2)
        if d <= (CFG.insert_distance or 0.15) then
            if rl_load_one() then
                rl_st.cart = false
                play_sound(SND_INSERT)
            end
        end
    end

    -- ---- Hand-Pose (Warhead halten): absolute Pose (reset) dann additiv Daumen/Zeigefinger ----
    local _rl_fade = {}
    local function rl_apply_pose()
        if not (CFG.rl_enabled and rl_wep.wid) then return end
        local p = pose_cfg(RL)   -- geteilt: alle RL-Varianten nutzen dieselbe Pose
        local want = nil
        if p and (rl_st.cart or rl_st.preview) and p.pose and p.pose ~= "" then want = p.pose end
        -- [POSE_FADE] beim Loslassen ueber POSE_FADE_DUR zurueckblenden statt snappen (p als data)
        local fname, b, fp = _G.__re4_pose_fade_step(_rl_fade, want, p)
        if not fname then return end
        p = fp or p; if not p then return end
        rl_pose_apply(fname, b)
        local bt = body_tf()
        if p.t_rx ~= 0 or p.t_ry ~= 0 or p.t_rz ~= 0 then
            local tj = bt and sc(bt, "getJointByName", "L_Thumb1")
            local cur = tj and sc(tj, "get_LocalRotation")
            if cur then pcall(function() tj:call("set_LocalRotation", (cur * quat_from_euler(p.t_rx*b, p.t_ry*b, p.t_rz*b)):normalized()) end) end
        end
        if p.i_rx ~= 0 or p.i_ry ~= 0 or p.i_rz ~= 0 then
            for _, jn in ipairs({ "L_IndexF1", "L_IndexF2", "L_IndexF3" }) do
                local jt = bt and sc(bt, "getJointByName", jn)
                local cur = jt and sc(jt, "get_LocalRotation")
                if cur then pcall(function() jt:call("set_LocalRotation", (cur * quat_from_euler(p.i_rx*b, p.i_ry*b, p.i_rz*b)):normalized()) end) end
            end
        end
    end

    -- ---- Frame-Loop ----
    local _prev_wid = nil
    re.on_frame(function()
        rl_refresh()
        if rl_wep.wid ~= _prev_wid then
            local was_rl = (_prev_wid ~= nil)
            rl_st.cart = false
            if was_rl and not rl_wep.wid then _G.__vr_mag_in_hand = false end
            _prev_wid = rl_wep.wid
        end
        if not rl_wep.wid then return end
        _G.__vr_manual_reload_consume_b = true   -- kein nativer Reload; B macht nichts
        rl_update_insert()
        -- Holster-Gate: buzzen nur wenn NICHTS einsetzbar (Reserve leer oder voll)
        _G.__re4_reload_grab_empty = (not rl_st.cart) and (not rl_can_grab())
        -- Support/Two-Hand weichen, solange der Warhead in der linken Hand ist
        _G.__vr_mag_in_hand = rl_st.cart and true or false
    end)

    -- ---- Render-Pass (Pose; reload3 laedt nach reload/reload2 -> gewinnt) ----
    local function rl_apply_pass()
        if not (CFG.rl_enabled and rl_wep.wid) then return end
        rl_apply_pose()
    end
    pcall(function() re.on_pre_application_entry("LockScene", rl_apply_pass) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", rl_apply_pass) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", rl_apply_pass) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", rl_apply_pass) end)

    -- ---- [WARHEAD-IN-HAND] Mesh-Clone von Part 03 an die linke Hand (echtes Modell, eigenes Objekt) ----
    -- Joint _07 umhaengen ging NICHT (Warhead ist part-basiert -> bei Ammo 0 weg -> nichts zu sehen).
    -- Daher Mesh-Clone-Technik wie die Revolver-Patrone (Notiz):
    -- eigenes GameObject + via.motion.Motion (Skelett) + via.render.Mesh + setMesh(Gun-Holder) + Gun-Material
    -- + nur Part 03 isolieren, an L_Hand. Die Waffe selbst bleibt unberuehrt.
    local function rl_gun_mesh()
        if not rl_wep.tf then return nil end
        local go = sc(rl_wep.tf, "get_GameObject")
        return go and sc(go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    end
    wh_destroy = function()
        if wh_clone.obj then pcall(function()
            local td = sdk.find_type_definition("via.GameObject"); local d = td and td:get_method("destroy(via.GameObject)")
            if d then d:call(nil, wh_clone.obj) end
        end) end
        wh_clone.obj, wh_clone.mesh, wh_clone.wid, wh_clone.parts_sig = nil, nil, nil, nil
    end
    local function wh_spawn()
        if wh_clone.obj then return true end
        local gmesh = rl_gun_mesh(); if not gmesh then return false end
        local holder = safe(function() return gmesh:call("getMesh") end); if not holder then return false end
        local gmat = safe(function() return gmesh:call("get_Material") end)
        local go_td = sdk.find_type_definition("via.GameObject")
        local create = go_td and go_td:get_method("create(System.String)")
        local go = create and safe(function() return create:call(nil, "vr_rl_warhead") end); if not go then return false end
        pcall(function() go:add_ref() end)
        pcall(function() go:call("createComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)
        local mesh = safe(function() return go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
        if not mesh then return false end
        pcall(function() mesh:call("setMesh", holder) end)
        if gmat then pcall(function() mesh:call("set_Material", gmat) end) end
        pcall(function() mesh:call("set_DrawDefault", true) end)
        pcall(function() mesh:call("set_Enabled", true) end)
        pcall(function() mesh:call("set_FrustumCulling", false) end)
        wh_clone.obj, wh_clone.mesh, wh_clone.wid = go, mesh, rl_wep.wid
        -- [NO_LAG] nativ ans L_Hand-Joint parenten -> Engine propagiert die Transform VOR dem Skinning
        -- -> kein Render-Versatz beim Laufen. Danach nur noch LOKALE Pose setzen.
        wh_clone.parented = false
        local ctf = safe(function() return go:call("get_Transform") end)
        local bt2 = body_tf()
        if ctf and bt2 then
            pcall(function() ctf:call("set_Parent", bt2) end)
            if pcall(function() ctf:call("set_ParentJoint", "L_Hand") end) then wh_clone.parented = true end
        end
        return true
    end
    local function wh_isolate()
        if not wh_clone.mesh then return end
        local sig = "parts:" .. tostring(CFG.parts or "03")
        if wh_clone.parts_sig == sig then return end
        local keep = {}; for n in tostring(CFG.parts or "03"):gmatch("%d+") do keep[tonumber(n)] = true end
        local applied = true
        for i = 0, 48 do
            if not pcall(function() wh_clone.mesh:call("setPartsEnable", i, keep[i] == true) end) then applied = false end
        end
        if applied then wh_clone.parts_sig = sig end
    end
    local function wh_set_tf(tf, p, rot, scl)
        local okp = pcall(function() tf:set_position(p, true) end)
        if not okp then pcall(function() tf:call("set_Position", p) end) end
        if rot then local okr = pcall(function() tf:set_rotation(rot) end); if not okr then pcall(function() tf:call("set_Rotation", rot) end) end end
        if scl then pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end) end
    end
    local function wh_place(tf)
        -- [NO_LAG] geparentet ans L_Hand: nur LOKALE Pose (Offset war schon hand-relativ = jetzt lokal).
        if wh_clone.parented then
            local scl = CFG.wscale or 1.0
            pcall(function() tf:call("set_LocalPosition", Vector3f.new(CFG.wx or 0, CFG.wy or 0, CFG.wz or 0)) end)
            pcall(function() tf:call("set_LocalRotation", quat_from_euler(CFG.wrx or 0, CFG.wry or 0, CFG.wrz or 0)) end)
            pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
            return
        end
        local bt = body_tf(); local lhj = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lhj and sc(lhj, "get_Position"); if not hp then return end
        local hr = lhj and sc(lhj, "get_Rotation")
        local wx, wy, wz = hp.x, hp.y, hp.z
        if hr then
            local off = safe(function() return hr * Vector3f.new(CFG.wx or 0, CFG.wy or 0, CFG.wz or 0) end)
            if off then wx, wy, wz = hp.x + off.x, hp.y + off.y, hp.z + off.z end
        end
        local rot = hr and safe(function() return (hr * quat_from_euler(CFG.wrx or 0, CFG.wry or 0, CFG.wrz or 0)):normalized() end)
        wh_set_tf(tf, Vector3f.new(wx, wy, wz), rot, CFG.wscale or 1.0)
    end
    local function wh_follow()
        if not (CFG.rl_enabled and rl_wep.wid) then if wh_clone.obj then wh_destroy() end return end
        if not (rl_st.cart or rl_st.preview) then if wh_clone.obj then wh_destroy() end return end
        if wh_clone.obj and wh_clone.wid ~= rl_wep.wid then wh_destroy() end
        if not wh_clone.obj then if not wh_spawn() then return end end
        wh_isolate()
        local tf = safe(function() return wh_clone.obj:call("get_Transform") end); if not tf then return end
        wh_place(tf)
    end
    pcall(function() re.on_frame(wh_follow) end)   -- 5. Punkt (wie Crossbow-Dummy): auch im on_frame
    pcall(function() re.on_pre_application_entry("LockScene", wh_follow) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", wh_follow) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", wh_follow) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", wh_follow) end)
    -- [WOBBLE-FIX] NACH motion's BeginRendering-POST (attach_left_hand) nochmal nur reposition -> klebt sauber.
    local function wh_reposition_late()
        if not (CFG.rl_enabled and rl_wep.wid and wh_clone.obj) then return end
        if not (rl_st.cart or rl_st.preview) then return end
        local tf = safe(function() return wh_clone.obj:call("get_Transform") end); if not tf then return end
        wh_place(tf)
    end
    pcall(function() re.on_application_entry("BeginRendering", wh_reposition_late) end)

    -- ---- Holster-Wrapper (RL -> reload3-RL, sonst weiter an die Kette) ----
    local _orig_rl = _G.__re4_reload_set_mag_in_hand
    _G.__re4_reload_set_mag_in_hand = function(active)
        if is_rl(get_equip_wid()) then return rl_set_mag_in_hand(active) end
        if _orig_rl then return _orig_rl(active) end
        return false
    end

    re.on_script_reset(function()
        rl_st.cart = false
        if wh_destroy then wh_destroy() end
        rl_wep.wid, rl_wep.tf, rl_wep.warhead_joint, rl_wep.dock_joint = nil, nil, nil, nil
        _G.__vr_mag_in_hand = false
    end)

    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion _G.__re4_reload3_rl_ui (71 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end
-- =====================================================================
-- ENDE ROCKET LAUNCHER (wp4900)
-- =====================================================================

-- =====================================================================
-- FLAMETHROWER (wp4701) — eigener, vollstaendig gekapselter do-Block
-- =====================================================================
-- Reload-Mechanik (-Design; Waffe existiert nur im Code, nie ins Spiel gekommen):
-- _05 = Sicherung -> Right-B togglet sie auf/zu, schwenkt SEITLICH raus (wie Handcannon-Trommel).
-- _04 = Tank (= die Ammo). Bei LEER + Sicherung OFFEN: Tank wird aus der Kammer genommen + faellt zu Boden.
-- Dann ist das Mag-Holster frei -> Griff -> DERSELBE Joint _04 erscheint an der Hand am Holster ->
-- an die Waffe (Dock-Naehe) -> einclippen -> Ammo voll. Loop. KEINE Engine-Reserve -> virtuell (CFG.reserve).
-- Nutzt reload3-Top-Level-Helfer (safe/sc/quat_from_euler/get_equip_wid/body_tf/get_pe/find_weapon/right_b_down).
-- JSON: re4_vr_reload3_flamethrower.json. Holster-Kette: FT -> RL -> Handcannon -> Chicago -> reload2 -> reload.
-- =====================================================================
do
    local FT = 4701
    local function is_ft(wid) return wid == FT end
    local snd_sc_td = sdk.typeof("soundlib.SoundContainer")
    -- EquipType.Main (Slot der Hauptwaffe) als Enum-Wert fuer Inventory-Calls
    local _et_td = sdk.find_type_definition("chainsaw.EquipType")
    local _et_main = _et_td and safe(function() return _et_td:get_field("Main"):get_data(nil) end)
    -- generateItem: chainsaw.Item bauen (wie item_adder) -> flame_fuel-Reserve ins Inventar legen
    local _gui_util_td = sdk.find_type_definition("chainsaw.ChainsawGuiUtil")
    local _gen_item = _gui_util_td and _gui_util_td:get_method("generateItem")
    local FLAME_FUEL_ID = 112814400

    -- Joints (CODE-Konstanten,): Sicherung = _05, Tank/Ammo = _04
    local JOINTS = { [FT] = { safety = "_05", tank = "_04" } }

    local CFG_PATH = "re4_vr/re4_vr_reload3_flamethrower.json"
    local CFG = {
        ft_enabled = true, sound_enabled = true,
        -- Sicherung _05 (Right-B swing-out, seitlich wie Handcannon-Trommel): Grad pro Achse * prog + Lerp
        saf_rx = 0.0, saf_ry = 0.0, saf_rz = -62.0, saf_lerp = 0.08,
        -- Tank _04: Dock-Punkt (Einlege-Naehe, rel. _05) + Einlege-Distanz + Hand-Offset (am Holster)
        dock_x = 0.0, dock_y = 0.0, dock_z = 0.0, insert_distance = 0.15, dock_catch = 0.30,
        hand_x = 0.0, hand_y = 0.0, hand_z = 0.0, hand_rx = 0.0, hand_ry = 0.0, hand_rz = 0.0,
        -- Magazin-/Kanister-Fuellmenge: worauf der Fake-Reload den Tank auffuellt.
        -- WICHTIG (Log-Befund 2026-06-26): Engine-Cap (CurrentAmmoMax) = 1000, aber der
        -- "volle" Kanister im Spiel = 100 (cnt/disp=100). Also NICHT auf den Engine-Max
        -- auffuellen, sondern auf diese konfigurierbare Groesse. cnt liegt im Feld 0x44.
        mag_size = 100,
        -- Feuersound Tap/Hold: Verbrauch kuerzer als hold_threshold s = einmaliger Burst-Sound,
        -- laenger = gehaltener Loop. burst_enabled schaltet den Tap-Burst ab (dann nur Loop).
        burst_enabled = true, hold_threshold = 0.12,
        -- virtuelle Reserve (Spiel hat keine: ammoid=nil/reserve=0) + unlimited-Loop
        reserve = 99, unlimited = true,
        -- Damage-Boost: die Engine gibt wp4701 fast keinen Schaden. NEUER Ansatz: wir boosten
        -- im PRE von callbackCalculateDamage (vor applyTo!) die DamageValue-Felder NATIV:
        -- Damage = HP-Schaden (Flamme-Basis nur 1) -> mult/floor
        -- Stopping = bricht Gegner-Attacken ab -> damage_stopping
        -- Wince = Zucken/Flinch -> damage_wince
        -- Break = Stagger/Gleichgewicht -> damage_break
        -- applyTo (laeuft danach in callbackCalculateDamage) wendet alles nativ an -> echte Reaktion.
        damage_enabled = true, damage_mult = 5.0, damage_floor = 30.0,
        damage_native = true,                                   -- set_Damage im PRE (nativer Pfad, gibt Reaktion)
        -- [2026-07-17] damage_scan_all entfernt (TEMP-Diagnose; Konsument flog mit dem Logging raus).
        -- Referenz MP5/TMP (wid=4202, Log): dmg~240 stop~495 wince~400 break~340-675 -> stoppt zuverlaessig.
        -- Darauf orientieren wir den Flamethrower fuer echten Attack-Abbruch (250 war zu wenig).
        damage_stopping = 495.0, damage_wince = 400.0, damage_break = 400.0,  -- Reaktions-Power (Attack-Abbruch)
        damage_hp_fallback = false,                             -- POST: zusaetzlich HP direkt abziehen (Sicherung)
        -- [2026-07-17] damage_debug entfernt (TEMP-Diagnose; Konsument flog mit dem Logging raus).
        -- Hand-Posen-Offsets: flamehand (rechte Hand, additiv auf R_Palm) + flamecanister-Daumen (L_Thumb1)
        fh_rx = 0.0, fh_ry = 0.0, fh_rz = 0.0,
        ca_trx = 0.0, ca_try = 0.0, ca_trz = 0.0,
    }
    local function save_cfg() pcall(function() json.dump_file(CFG_PATH, { cfg = CFG }) end) end
    local function load_cfg()
        local data = safe(function() return json.load_file(CFG_PATH) end)
        if type(data) ~= "table" then return end
        local c = data.cfg or data
        for k, v in pairs(c) do if CFG[k] ~= nil and type(v) == type(CFG[k]) then CFG[k] = v end end
    end
    load_cfg()

    -- ---- State ----
    local ft_wep = { wid = nil, tf = nil, safety_joint = nil, safety_rest_rot = nil, tank_joint = nil }
    local saf = { open = false, prog = 0.0, _prev_b = false, preview = false }
    local FT_GRAV = 9.8
    -- phase: idle (Tank in Kammer, Engine) | dropping (faellt) | floor (liegt) | in_hand (am Holster gegriffen)
    local tank = { phase = "idle", t0 = 0, sx = 0, sy = 0, sz = 0, floor_y = 0, snd = false, _insert_t = nil, preview = false, _drop_armed = false }

    -- ===== Damage-Boost (Flamethrower-spezifisch) =====
    -- Befund (re4_ft_damage.log): der echte Schaden steckt in HitController.DamageValue.get_Damage
    -- (Int32), NICHT in WwiseDamage(=0, nur Audio). Flammen-Familie: 4701 = direkter Tick (Basis nur
    -- 1!), 5801 = Flammen-Treffer, 5803/5804 = Entzuendungs-Burst (Basis 210-490). set_Damage im
    -- POST wirkte NICHT (DamageValue wird intern via applyTo schon angewendet) -> wir wenden den
    -- Zusatzschaden DIREKT am HitPoint des Opfers an (umgeht Timing + Feuerresistenz). Spieler/Partner
    -- + Invincible werden ausgespart. Werte live ueber _G.__re4_ft_dmg (Slider wirkt nach Reset Scripts).
    local FLAME_IDS = { [4701] = true, [5801] = true, [5803] = true, [5804] = true }
    _G.__re4_ft_dmg = _G.__re4_ft_dmg or {}
    local function ft_sync_dmg()
        local g = _G.__re4_ft_dmg
        g.enabled  = CFG.damage_enabled and true or false
        g.mult     = CFG.damage_mult or 1.0
        g.floor    = math.floor(CFG.damage_floor or 0.0)
        g.native   = CFG.damage_native and true or false
        -- [TOTE FLAGS RAUS 2026-07-17] g.scan_all / g.debug entfernt: sie wurden nur noch GESETZT, ihr
        -- einziger Leser war der Diagnose-Code, der mit dem Logging rausflog (per Grep ueber alle aktiven
        -- Scripte belegt). Zugehoerige CFG-Keys + UI-Checkboxen ebenfalls entfernt.
        g.stopping = CFG.damage_stopping or 0.0
        g.wince    = CFG.damage_wince or 0.0
        g.brk      = CFG.damage_break or 0.0
        g.hp_fb    = CFG.damage_hp_fallback and true or false
    end
    ft_sync_dmg()

    -- Logik in GLOBALS (werden bei JEDEM Script-Load neu definiert) -> kuenftige Logik-Aenderungen
    -- greifen schon mit "Reset Scripts". Nur der duenne Shim-Hook unten braucht EINMALIG einen
    -- Game-Neustart (sdk.hook-Body friert ein, Guard ueberlebt Reset Scripts).
    do
        local _pc = { t = -999, list = {} }   -- Spieler/Partner-HitPoint cachen (nicht selbst grillen)
        local function refresh_pc()
            local now = os.clock()
            if (now - _pc.t) < 0.5 and #_pc.list > 0 then return end
            _pc.t = now; _pc.list = {}
            local cm = safe(function() return sdk.get_managed_singleton("chainsaw.CharacterManager") end)
            if not cm then return end
            for _, getter in ipairs({ "getPlayerContextRef", "getPartnerContextRef" }) do
                local ctx = safe(function() return cm:call(getter) end)
                local hp  = ctx and safe(function() return ctx:call("get_HitPoint") end)
                local ad  = hp and tonumber(safe(function() return hp:get_address() end))
                if ad then _pc.list[#_pc.list + 1] = ad end
            end
        end
        local function is_player_hp(addr)
            if not addr then return false end
            refresh_pc()
            for _, a in ipairs(_pc.list) do if a == addr then return true end end
            return false
        end
        -- Opfer-HitPoint aus einem (evtl. Koerperteil-)GameObject: HitController suchen, dabei die
        -- Eltern-Hierarchie hochlaufen (DamageGameObject ist oft ein Collider-Child ohne HitController).
        -- Gibt hp + Tiefe zurueck (0 = direkt am GO).
        local function hp_from_go(go)
            local rt = _G.__re4_hc_rt; if not rt then rt = sdk.typeof("chainsaw.HitController"); _G.__re4_hc_rt = rt end
            if not rt then return nil, -1 end
            local cur = go
            for depth = 0, 6 do
                if not cur then break end
                local hcc = safe(function() return cur:call("getComponent(System.Type)", rt) end)
                if hcc then
                    local ctx = safe(function() return hcc:call("get_Context") end)
                    local hp  = ctx and safe(function() return ctx:call("get_HitPoint") end)
                    if hp then return hp, depth end
                end
                local tf  = safe(function() return cur:call("get_Transform") end)
                local ptf = tf and safe(function() return tf:call("get_Parent") end)
                cur = ptf and safe(function() return ptf:call("get_GameObject") end) or nil
            end
            return nil, -1
        end
        -- PRE: Argumente scannen -> Entry {wid, dv, hp} (oder false)
        _G.__re4_ft_dmg_pre = function(args)
            local hc, dv, ci
            for idx = 1, 5 do
                local o  = safe(function() return sdk.to_managed_object(args[idx]) end)
                local nm = o and safe(function() return o:get_type_definition():get_full_name() end)
                if nm == "chainsaw.HitController" then hc = o
                elseif nm == "chainsaw.HitController.DamageValue" then dv = o
                elseif nm == "chainsaw.HitController.CalculateInfo" then ci = o end
            end
            local widobj = hc and safe(function() return hc:call("get_WeaponID") end)
            local wid = (type(widobj) == "number") and widobj
                or (widobj and tonumber(safe(function() return widobj:get_field("value__") end)))
            if not hc then return false end
            local g = _G.__re4_ft_dmg
            if not FLAME_IDS[wid] then
                return false
            end

            -- ===== Opfer ZUERST bestimmen (vor jedem Boost!) =====
            -- Flammen-IDs treffen auch den Spieler (eigener Feuer-Splash / Gegner-Feuer). Wir DUERFEN
            -- den Schaden nur boosten, wenn das Opfer ein Gegner ist -> sonst grillen wir den Spieler.
            local hp, depth, vaddr = nil, -1, 0
            local vgo = ci and safe(function() return ci:call("get_DamageGameObject") end) or nil
            if vgo then
                vaddr = tonumber(safe(function() return vgo:get_address() end)) or 0
                hp, depth = hp_from_go(vgo)
            end
            -- SCHUTZ: Schaden gegen Spieler/Partner -> NIE boosten. NUR ueber HitPoint-Adresse pruefen!
            -- get_IsPlayerDamage ist NICHT "Opfer = Spieler", sondern "Schaden VOM Spieler ausgeteilt"
            -- (Angreifer-Seite) -> beim Flammenwerfer->Gegner immer true -> wuerde JEDEN Gegner skippen.
            local hp_addr = hp and tonumber(safe(function() return hp:get_address() end)) or nil
            local victim_is_player = (hp_addr and is_player_hp(hp_addr)) or false

            -- ===== NATIVER BOOST (vor applyTo!): Damage + Reaktions-Felder direkt am DamageValue =====
            -- applyTo laeuft GLEICH danach in callbackCalculateDamage und wendet die Werte nativ an
            -- -> echter Schaden + Attack-Abbruch (Stopping) + Flinch. NUR gegen Gegner.
            local obase, ostop, owince, obrk, nd = 0, 0, 0, 0, 0
            if dv then
                obase  = tonumber(safe(function() return dv:call("get_Damage") end)) or 0
                ostop  = tonumber(safe(function() return dv:call("get_Stopping") end)) or 0
                owince = tonumber(safe(function() return dv:call("get_Wince") end)) or 0
                obrk   = tonumber(safe(function() return dv:call("get_Break") end)) or 0
                nd = obase
                if g and g.enabled and g.native and not victim_is_player then
                    nd = math.floor(obase * (g.mult or 1.0) + 0.5)
                    if (g.floor or 0) > nd then nd = g.floor end
                    if nd > obase then pcall(function() dv:call("set_Damage", nd) end) end
                    -- Reaktion: native Originalwerte NICHT verkleinern (max), sonst flammt es schwaecher
                    if (g.stopping or 0) > ostop  then pcall(function() dv:call("set_Stopping", g.stopping) end) end
                    if (g.wince or 0)    > owince then pcall(function() dv:call("set_Wince", g.wince) end) end
                    if (g.brk or 0)      > obrk   then pcall(function() dv:call("set_Break", g.brk) end) end
                end
            end
            return { wid = wid, dv = dv, hp = hp }
        end
        -- POST: Zusatzschaden DIREKT am Opfer-HitPoint (umgeht applyTo-Timing + Feuerresistenz)
        _G.__re4_ft_dmg_post = function(e)
            local g = _G.__re4_ft_dmg
            -- HP-Direktabzug NUR noch als Fallback (Standard: nativer Boost im PRE traegt den Schaden).
            if not (e and g and g.enabled and g.hp_fb and e.hp) then return end
            local hp = e.hp
            local addr = tonumber(safe(function() return hp:get_address() end)) or 0
            if is_player_hp(addr) then return end
            if safe(function() return hp:call("get_Invincible") end)
                or safe(function() return hp:call("get_Immortal") end)
                or safe(function() return hp:call("get_NoDamage") end)
                or safe(function() return hp:call("get_IsDead") end) then return end
            local base = tonumber(safe(function() return e.dv and e.dv:call("get_Damage") end)) or 0
            -- extra = max(base*(mult-1), floor): mult skaliert grosse Bursts, floor garantiert
            -- spuerbaren Schaden pro Tick (Basis ist oft nur 1).
            local extra = math.floor(base * ((g.mult or 1.0) - 1.0) + 0.5)
            if (g.floor or 0) > extra then extra = g.floor end
            if extra <= 0 then return end
            local cur = tonumber(safe(function() return hp:call("get_CurrentHitPoint") end)) or 0
            local newhp = cur - extra; if newhp < 0 then newhp = 0 end
            pcall(function() hp:call("set_CurrentHitPoint", newhp) end)
            if newhp <= 0 then pcall(function() hp:call("dead") end) end
        end
    end

    -- Duenner Shim-Hook (EINMALIG, Guard ueberlebt Reset Scripts) -> ruft nur die Globals oben.
    if not _G.__re4_ft_dmg_hook_installed then
        local _hc_td  = sdk.find_type_definition("chainsaw.HitController")
        local _calc_m = _hc_td and _hc_td:get_method("callbackCalculateDamage")
        if _calc_m then
            _G.__re4_ft_dmg_hook_installed = true
            local _stack = {}   -- pre -> post Handoff (gleicher Thread, synchron)
            sdk.hook(_calc_m, function(args)
                local f = _G.__re4_ft_dmg_pre
                local ok, e = pcall(function() return f and f(args) end)
                _stack[#_stack + 1] = (ok and e) or false
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                local e = _stack[#_stack]; _stack[#_stack] = nil
                local f = _G.__re4_ft_dmg_post
                if e and f then pcall(function() f(e) end) end
                return retval
            end)
        end
    end
    -- [BOOT] bei JEDEM Script-Load: beweist Reload + zeigt Hook-/Config-Zustand (TEMP-Diag)
    -- [log entfernt]

    -- ===== Hand-Posen (gestures-unabhaengig GEBACKEN; gestures.json wird geloescht) =====
    -- Quaternionen in W,X,Y,Z-Reihenfolge (wie reload.lua: Quaternion.new(v[1],v[2],v[3],v[4])).
    -- flamehand = RECHTE Hand (Waffengriff) -> IMMER (no-aim + aim), offsetbar (additiv auf R_Palm).
    -- flamesupport = LINKE Support-Hand -> wenn Support gedockt / 2-Hand-IK aktiv.
    -- flamecanister = LINKE Hand am Tank (Holster-Griff) -> Phase in_hand, mit Daumen-Tuning (L_Thumb1).
    local POSE_FLAMEHAND = {
        ["R_IndexF1"]={0.994111,0.000000,0.108364,0.000000}, ["R_IndexF2"]={0.927257,0.000000,0.000000,0.374425}, ["R_IndexF3"]={0.955189,0.000000,0.000000,0.295997},
        ["R_MiddleF1"]={0.951202,0.026301,0.090222,0.293909}, ["R_MiddleF2"]={0.766392,0.000000,0.000000,0.642373}, ["R_MiddleF3"]={0.913677,0.000000,0.000000,0.406440},
        ["R_Palm"]={0.997250,0.000000,0.000000,-0.074108},
        ["R_PinkyF1"]={0.957255,-0.079671,-0.035414,0.275792}, ["R_PinkyF2"]={0.853292,0.000000,0.000000,0.521434}, ["R_PinkyF3"]={0.946328,0.000000,0.000000,0.323209},
        ["R_RingF1"]={0.928187,-0.025978,-0.012711,0.370988}, ["R_RingF2"]={0.888385,0.000000,0.000000,0.459099}, ["R_RingF3"]={0.853651,0.000000,0.000000,0.520846},
        ["R_Thumb1"]={0.861574,0.463423,0.082424,0.190092}, ["R_Thumb2"]={0.999996,0.000000,-0.002644,0.000000}, ["R_Thumb3"]={0.863236,0.000000,-0.504801,0.000000},
    }
    local POSE_FLAMESUPPORT = {
        ["L_IndexF1"]={0.993561,-0.083543,-0.065129,-0.040180}, ["L_IndexF2"]={0.954616,0.000000,0.000000,-0.297838}, ["L_IndexF3"]={0.950483,0.000000,0.000000,-0.310778},
        ["L_MiddleF1"]={0.977877,-0.109369,-0.088266,-0.154935}, ["L_MiddleF2"]={0.850457,0.000000,0.000000,-0.526044}, ["L_MiddleF3"]={0.980999,0.000000,0.000000,-0.194012},
        ["L_Palm"]={1.000000,-0.000000,-0.000000,-0.000000},
        ["L_PinkyF1"]={0.920692,-0.191583,-0.107047,-0.322742}, ["L_PinkyF2"]={0.941538,0.000000,0.000000,-0.336906}, ["L_PinkyF3"]={0.973633,0.000000,0.000000,-0.228118},
        ["L_RingF1"]={0.952338,-0.170963,-0.048996,-0.247838}, ["L_RingF2"]={0.876829,0.000000,0.000000,-0.480803}, ["L_RingF3"]={0.981566,0.000000,0.000000,-0.191126},
        ["L_Thumb1"]={0.966148,0.257212,0.011939,0.016055}, ["L_Thumb2"]={0.941147,-0.083984,-0.323802,0.048387}, ["L_Thumb3"]={0.998527,0.000000,0.054267,0.000000},
    }
    local POSE_FLAMECANISTER = {
        ["L_IndexF1"]={0.999912,0.002479,-0.012574,0.003377}, ["L_IndexF2"]={0.992097,0.000000,0.000000,-0.125471}, ["L_IndexF3"]={0.991860,0.000000,0.000000,-0.127334},
        ["L_MiddleF1"]={0.999422,0.001461,0.011326,-0.032021}, ["L_MiddleF2"]={0.941170,0.000000,0.000000,-0.337933}, ["L_MiddleF3"]={0.965377,0.000000,0.000000,-0.260859},
        ["L_Palm"]={1.000000,-0.000000,-0.000000,-0.000000},
        ["L_PinkyF1"]={0.999196,-0.000822,0.026396,-0.030168}, ["L_PinkyF2"]={0.925399,0.000000,0.000000,-0.378994}, ["L_PinkyF3"]={0.970562,0.000000,0.000000,-0.240852},
        ["L_RingF1"]={0.999773,-0.001175,0.018148,-0.011068}, ["L_RingF2"]={0.928340,0.000000,0.000000,-0.371733}, ["L_RingF3"]={0.950664,0.000000,0.000000,-0.310224},
        ["L_Thumb1"]={0.990954,0.114399,0.006076,-0.069907}, ["L_Thumb2"]={0.982677,0.007076,-0.185176,0.002216}, ["L_Thumb3"]={0.990361,0.000000,0.138508,0.000000},
    }
    -- Joint-Cache (Bone-Name -> Joint), an die aktuelle Body-Transform gebunden
    local _pose_jcache, _pose_jcache_tf = {}, nil
    local function pose_joint(tf, bone)
        if tf ~= _pose_jcache_tf then _pose_jcache, _pose_jcache_tf = {}, tf end
        local j = _pose_jcache[bone]
        if j == nil then j = sc(tf, "getJointByName", bone) or false; _pose_jcache[bone] = j end
        return j or nil
    end
    -- pose_apply: setzt jede Bone-LocalRotation; offsets[bone] = additiver Quaternion (rechts-multipliziert)
    local function pose_apply(tf, pose, offsets, blend)
        if not (tf and pose) then return end
        blend = blend or 1.0
        if blend <= 0.0 then return end
        for bone, v in pairs(pose) do
            local j = pose_joint(tf, bone)
            if j then
                local q = Quaternion.new(v[1], v[2], v[3], v[4])
                local off = offsets and offsets[bone]
                if off then q = safe(function() return (q * off):normalized() end) or q end
                if blend < 0.9999 then   -- [POSE_FADE] nlerp aktuelle (native) Rotation -> Ziel
                    local c = safe(function() return j:call("get_LocalRotation") end)
                    if c then
                        local tw, tx, ty, tz = q.w, q.x, q.y, q.z
                        if (c.w*tw + c.x*tx + c.y*ty + c.z*tz) < 0.0 then tw, tx, ty, tz = -tw, -tx, -ty, -tz end
                        local w, x, y, z = c.w+(tw-c.w)*blend, c.x+(tx-c.x)*blend, c.y+(ty-c.y)*blend, c.z+(tz-c.z)*blend
                        local len = math.sqrt(w*w + x*x + y*y + z*z)
                        if len > 1e-6 then q = Quaternion.new(w/len, x/len, y/len, z/len) end
                    end
                end
                pcall(function() j:call("set_LocalRotation", q) end)
            end
        end
    end
    -- Vorschau-Flags (UI) zum Tunen ohne echte Aktion
    local pose_prev = { support = false, canister = false }
    local _ft_fade = {}
    local function ft_apply_poses()
        if not (CFG.ft_enabled and ft_wep.wid) then return end
        local bt = body_tf(); if not bt then return end
        -- RECHTE Hand: IMMER flamehand (no-aim + aim), Palm-Offset
        pose_apply(bt, POSE_FLAMEHAND, { ["R_Palm"] = quat_from_euler(CFG.fh_rx or 0, CFG.fh_ry or 0, CFG.fh_rz or 0) })
        -- LINKE Hand: Tank-Griff schlaegt Support; Support nur wenn gedockt/2-Hand.
        -- [POSE_FADE] Canister-Pose beim Loslassen (Tank eingesetzt) ueber POSE_FADE_DUR zurueckblenden.
        local want = (tank.phase == "in_hand" or pose_prev.canister) and "canister" or nil
        local fname, b = _G.__re4_pose_fade_step(_ft_fade, want)
        if fname then
            local canister_thumb = { ["L_Thumb1"] = quat_from_euler((CFG.ca_trx or 0)*b, (CFG.ca_try or 0)*b, (CFG.ca_trz or 0)*b) }
            pose_apply(bt, POSE_FLAMECANISTER, canister_thumb, b)
        elseif pose_prev.support or (rawget(_G, "__vr_support_blend_factor") or 0) > 0.05 then
            pose_apply(bt, POSE_FLAMESUPPORT)
        end
    end

    local function wp_label(wid) return wid and string.format("wp%04d", wid) or "-" end
    local function play_sound(id)
        if not CFG.sound_enabled or not id or id <= 0 then return end
        local tf = ft_wep.tf; if not tf then return end
        local go = safe(function() return tf:call("get_GameObject") end); if not go or not snd_sc_td then return end
        local scn = safe(function() return go:call("getComponent(System.Type)", snd_sc_td) end); if not scn then return end
        pcall(function() scn:call("trigger(System.UInt32)", id) end)
    end

    -- =====================================================================
    -- FEUER-LOOP-SOUND (961885189): laeuft solange gefeuert wird, stoppt beim Loslassen.
    -- Die Waffe selbst gibt KEINEN Schuss-Sound aus -> wir spielen ihn manuell.
    -- ERKENNUNG: am Munitions-Verbrauch (Engine zaehlt cnt beim Feuern runter, ~54/s) +
    -- kurze Nachlauf-Toleranz -> kein unsicheres Engine-Flag noetig.
    -- STOP: robuster Pfad wie im #re4_sound_player.lua -> Wwise stopEvent(go, EventId, fade)
    -- ueber die statische soundlib.SoundManager (Loop laesst sich NUR per EventId stoppen,
    -- nicht per TriggerId), plus Container-stopTriggered mit dem RICHTIGEN (Waffen-)GO.
    -- =====================================================================
    local FIRE_LOOP_SND  = 961885189   -- gehaltener Feuer-Strahl (Loop)
    local BURST_SND      = 1470667332  -- kurzer Tap = kleiner Feuer-Burst (One-Shot)
    local CLASSIFY_GAP   = 0.05        -- kein Verbrauch so lange -> Feuern gestoppt (Tap-Entscheid, eng)
    local HOLD_STOP_TAIL = 0.10        -- Loop-Nachlauf nach Loslassen (robuster gg. Frame-Haenger)
    local _ftsm_td = sdk.find_type_definition("soundlib.SoundManager")
    local _ftsm_stopevent = _ftsm_td and _ftsm_td:get_method("stopEvent(via.GameObject, System.UInt32, System.UInt32)")
    local fire_snd = { on = false, scn = nil, go = nil }
    -- Tap/Hold-State: "idle" -> "pending" (feuert, noch unklar) -> "hold" (Loop laeuft)
    local _fire_prev_ammo, _fire_active_t, _fire_state, _fire_start_t = nil, nil, "idle", 0

    local function ft_sound_container()
        local tf = ft_wep.tf; if not tf then return nil end
        local go = safe(function() return tf:call("get_GameObject") end); if not (go and snd_sc_td) then return nil end
        local scn = safe(function() return go:call("getComponent(System.Type)", snd_sc_td) end)
        if not scn then return nil end
        return scn, go
    end
    -- EventId(s) zu einer TriggerId aus der _TriggerInfoList des Containers holen
    local function ft_event_ids_for(scn, trigid)
        local out = {}
        local list = scn and safe(function() return scn:get_field("_TriggerInfoList") end); if not list then return out end
        local cnt = tonumber(safe(function() return list:call("get_Count") end)) or 0
        local items = safe(function() return list:get_field("_items") end)
        for i = 0, cnt - 1 do
            local e = (items and safe(function() return items[i] end)) or safe(function() return list:call("get_Item", i) end)
            if e then
                local tid = tonumber(safe(function() return e:get_field("_TriggerId") end))
                if tid == trigid then
                    local eid = tonumber(safe(function() return e:get_field("_EventId") end))
                    if eid then out[#out + 1] = eid end
                end
            end
        end
        return out
    end
    local function ft_fire_sound_start()
        if fire_snd.on or not CFG.sound_enabled then return end
        local scn, go = ft_sound_container(); if not (scn and go) then return end
        pcall(function() scn:call("trigger(System.UInt32)", FIRE_LOOP_SND) end)
        fire_snd.on, fire_snd.scn, fire_snd.go = true, scn, go
    end
    local function ft_fire_sound_stop()
        if not fire_snd.on then return end
        fire_snd.on = false
        local scn, go = fire_snd.scn, fire_snd.go
        if not (scn and go) then scn, go = ft_sound_container() end
        fire_snd.scn, fire_snd.go = nil, nil
        if not (scn and go) then return end
        if _ftsm_stopevent then
            for _, ev in ipairs(ft_event_ids_for(scn, FIRE_LOOP_SND)) do
                if ev and ev > 0 then pcall(function() _ftsm_stopevent:call(nil, go, ev, 0) end) end
            end
        end
        pcall(function() scn:call("stopTriggered(System.UInt32, via.GameObject, System.UInt32)", FIRE_LOOP_SND, go, 0) end)
    end
    -- Einmaliger Tap-Burst (One-Shot, kein Stop noetig)
    local function ft_play_burst()
        local scn, go = ft_sound_container(); if not (scn and go and CFG.sound_enabled) then return end
        pcall(function() scn:call("trigger(System.UInt32)", BURST_SND) end)
    end

    local SND_SAFETY = 3042341191  -- Sicherung oeffnen (Right-B Press)
    local SND_DROP   = 3511992014  -- Kanister kommt auf dem Boden auf
    local SND_GRAB   = 1839787494  -- Tank/Mag aus Holster gegriffen
    local SND_INSERT = 2698018700  -- neuen Kanister einstecken
    local SND_DRY    = 812850326   -- Dry-Fire (Trigger bei leer / ammo=0)

    -- Rechter Controller-Trigger gedrueckt? (RAW OpenVR, unabhaengig vom Consume)
    local function right_trigger_down()
        if not vrmod then return false end
        local ok, v = pcall(function()
            local act = vrmod:get_action_trigger(); local rj = vrmod:get_right_joystick()
            if not (act and rj) then return false end
            return vrmod:is_action_active(act, rj)
        end)
        return ok and v == true
    end
    local _dryfire_prev = false

    -- ---- Ammo (virtuelle Reserve; Engine-Fuel ueber das Waffen-Item) ----
    -- WICHTIG: getEquipWeaponItem liefert eine SPIEGEL-Kopie -> Lesen zeigt den echten Wert,
    -- aber forceSet/write VERPUFFT (die Live-Gun schreibt 0 zurueck). Das ECHTE Item ist
    -- _G.__re4_live_wi (von reload.lua per sdk.hook auf reduce/addAmmoCount + get_CurrentAmmoCount
    -- publiziert). Darauf MUESSEN wir schreiben, damit der Refill stehen bleibt. WeaponId-gefiltert.
    local function ft_get_wi()
        -- [ACCESSOR 2026-08-12] zuerst die ECHTE, persistente Instanz (s. reload.lua,
        -- __re4_real_wi). Alles darunter sind KOPIEN -> Schreiben verpufft.
        local _rw = _G.__re4_real_wi and _G.__re4_real_wi()
        if _rw then return _rw end
        local ewid = get_equip_wid()
        -- (1) ECHTES Item direkt aus dem Inventar (kein reload.lua-Hook noetig) -> robust gg. "Reset
        -- Scripts" (sdk.hook wird dort nicht neu installiert -> __re4_live_wi wird stale).
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        if inv and _et_main then
            -- [ACCESSOR 2026-08-12] getEquippedWeapon ist eine KOPIE -> setAmmoId verpufft dort.
            local rwi = (_G.__re4_real_wi and _G.__re4_real_wi())
                        or safe(function() return inv:call("getEquippedWeapon", _et_main) end)
            if rwi and safe(function() return rwi:call("get_CurrentAmmoCount") end) ~= nil then
                local cwid = safe(function() return rwi:call("get_WeaponId"):get_field("value__") end)
                if cwid and ewid and cwid == ewid then return rwi end   -- STRIKT: nur cachen wenn gleiche Waffe (kein stale)
            end
        end
        -- (2) Live-Handle aus reload.lua (nur gueltig solange dessen Hook frisch ist)
        local wi = rawget(_G, "__re4_live_wi")
        if wi and safe(function() return wi:call("get_CurrentAmmoCount") end) ~= nil then
            local cwid = safe(function() return wi:call("get_WeaponId"):get_field("value__") end)
            if cwid and ewid and cwid == ewid then return wi end   -- STRIKT: nur cachen wenn gleiche Waffe (kein stale)
        end
        -- (3) Spiegel-Kopie (nur fuers Lesen brauchbar, Schreiben verpufft)
        local ewi = pe and safe(function() return pe:call("getEquipWeaponItem") end)
        if ewi and safe(function() return ewi:call("get_CurrentAmmoCount") end) ~= nil then return ewi end
        return nil
    end
    local function ft_ammo() local wi = ft_get_wi(); return wi and (tonumber(sc(wi, "get_CurrentAmmoCount")) or 0) or 0 end
    local function ft_reserve_ok() return CFG.unlimited or (CFG.reserve or 0) > 0 end
    -- Fake-Reload-Auffuellen: Tank-Count (Feld 0x44) DIREKT auf die Kanister-Groesse
    -- (CFG.mag_size, default 100) setzen. NICHT auf get_CurrentAmmoMax (=1000 lt. Log) –
    -- das waere der Engine-Hard-Cap, nicht der "volle Kanister". Auf den Engine-Max clampen.
    -- Fake-Reload: Magazin (Feld 0x44) auf CFG.mag_size (default 100) setzen, geclampt auf
    -- Engine-max. KERN: Die Engine haelt das Magazin nur, wenn echte flame_fuel-Reserve im
    -- Inventar liegt -> Reserve auffuellen, dann reload (Reserve->Magazin) + Spiegel setzen.
    local function ft_ac(o) return o and tonumber(safe(function() return o:call("get_CurrentAmmoCount") end)) or nil end
    local function ft_addr(o) return o and tonumber(safe(function() return o:get_address() end)) or 0 end
    local function ft_refill()
        local wi = ft_get_wi()
        if not wi then return false end
        local engine_max = tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0
        local target = math.floor(CFG.mag_size or 100)
        if engine_max > 0 and target > engine_max then target = engine_max end
        if target < 0 then target = 0 end

        -- Ammo-Typ der Waffe (UsableAmmoList[0] = flame_fuel) ermitteln
        local ual = safe(function() return wi:call("get_UsableAmmoList") end)
        local ammo0 = ual and (tonumber(safe(function() return ual:get_size() end)) or 0) > 0
            and safe(function() return ual[0] end) or nil
        local amid = safe(function() return wi:call("get_CurrentAmmo") end)
        local amidv = amid and safe(function() return amid:get_field("value__") end)
        -- Keine gueltige Ammo-ID gesetzt? -> setzen, sonst zwingt die Engine den Count auf 0.
        if (not amidv or amidv == 0) and ammo0 then pcall(function() wi:call("setAmmoId", ammo0) end) end

        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        -- KERN: inv:reload(count) ist ADDITIV+verzoegert (Log: Endwert = Magazin + count). Damit das
        -- Magazin GENAU auf target landet (nicht target+Rest), laden wir nur die Differenz nach.
        local current = ft_ac(wi) or 0
        local need = target - current

        if current > target then
            -- zu viel drin -> ECHTE Engine-Methode reduceAmmoCount (forceSet verpufft, Log bewiesen!)
            -- [ACCESSOR 2026-08-12] getEquippedWeapon ist eine KOPIE -> reduceAmmoCount verpufft dort.
            local rwi = (_G.__re4_real_wi and _G.__re4_real_wi())
                        or ((inv and _et_main) and safe(function() return inv:call("getEquippedWeapon", _et_main) end))
            local item = rwi or wi
            pcall(function() item:call("reduceAmmoCount", current - target) end)
            return true
        end

        if need <= 0 then return true end

        -- echte flame_fuel-Reserve fuer die Differenz sicherstellen
        local rsv_b
        if inv and ammo0 and _gen_item then
            rsv_b = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo0) end)) or 0
            if rsv_b < need then
                local newitem = safe(function() return _gen_item:call(nil, FLAME_FUEL_ID, 1000, -1, -1, 0, 0) end)
                if newitem then pcall(function() inv:call("pickupItem(chainsaw.Item)", newitem) end) end
            end
        end

        -- nur die Differenz nachladen -> Engine addiert (current + need) = target
        if inv and _et_main then
            -- [ACCESSOR 2026-08-12] getEquippedWeapon ist eine KOPIE -> setAmmoId verpufft dort.
            local rwi = (_G.__re4_real_wi and _G.__re4_real_wi())
                        or safe(function() return inv:call("getEquippedWeapon", _et_main) end)
            if rwi and (not amidv or amidv == 0) and ammo0 then pcall(function() rwi:call("setAmmoId", ammo0) end) end
            if _G.__re4_safe_inv_reload then _G.__re4_load_and_book(inv, _et_main, need, true) end   -- [CRASH-HARDEN 2026-07-17] engine-Gate enableReloadItem gegen null-Item-AV
        end
        return true
    end

    -- ---- Refresh: Waffe + Joints ----
    local function ft_refresh()
        local wid = get_equip_wid()
        if not (CFG.ft_enabled and is_ft(wid)) then
            ft_wep.wid, ft_wep.tf, ft_wep.safety_joint, ft_wep.tank_joint = nil, nil, nil, nil
            return
        end
        ft_wep.wid = wid
        if not (ft_wep.tf and safe(function() return ft_wep.tf:call("get_Position") end)) then
            local _, tf = find_weapon(wid); ft_wep.tf = tf
        end
        local tf = ft_wep.tf
        if tf then
            local jc = JOINTS[wid] or {}
            ft_wep.safety_joint = jc.safety and sc(tf, "getJointByName", jc.safety) or nil
            ft_wep.tank_joint = jc.tank and sc(tf, "getJointByName", jc.tank) or nil
            -- [SAVE-LOAD-FEST] Sicherungs-Ruhe = BIND-Pose (Konstante, nie von unseren Writes beruehrt)
            if ft_wep.safety_joint and not ft_wep.safety_rest_rot then
                ft_wep.safety_rest_rot = sc(ft_wep.safety_joint, "get_BaseLocalRotation")
            end
        end
    end

    -- ---- Sicherung _05 (Right-B Toggle, seitlicher Swing) ----
    local function ft_update_safety()
        if not ft_wep.safety_joint then return end
        local b = right_b_down()
        if b and not saf._prev_b and not saf.preview then
            saf.open = not saf.open
            if saf.open then tank._drop_armed = true end   -- Drop des alten Kanisters einmalig pro Oeffnen
            play_sound(SND_SAFETY)
        end
        saf._prev_b = b
        local target = (saf.open or saf.preview) and 1.0 or 0.0
        local spd = CFG.saf_lerp or 0.08
        if saf.prog < target then saf.prog = math.min(target, saf.prog + spd)
        elseif saf.prog > target then saf.prog = math.max(target, saf.prog - spd) end
    end
    local function ft_apply_safety()
        if not (ft_wep.safety_joint and ft_wep.safety_rest_rot) then return end
        local p = saf.prog or 0
        local q = quat_from_euler((CFG.saf_rx or 0) * p, (CFG.saf_ry or 0) * p, (CFG.saf_rz or 0) * p)
        local nr = safe(function() return (ft_wep.safety_rest_rot * q):normalized() end)
        if nr then pcall(function() ft_wep.safety_joint:call("set_LocalRotation", nr) end) end
    end

    -- ---- Tank _04: Drop / Boden / in der Hand (Welt-Transform-Override; idle = Engine in der Kammer) ----
    local function body_pos_y() local bt = body_tf(); local p = bt and sc(bt, "get_Position"); return p and p.y or 0 end
    local function ft_start_drop()
        local j = ft_wep.tank_joint; if not j then return end
        local p = sc(j, "get_Position"); if not p then return end
        tank.sx, tank.sy, tank.sz = p.x, p.y, p.z
        tank.floor_y = body_pos_y()
        tank.t0 = os.clock(); tank.snd = false; tank.phase = "dropping"
    end
    local function ft_dock_world()
        local sj = ft_wep.safety_joint; local p = sj and sc(sj, "get_Position"); if not p then return nil end
        local gr = ft_wep.tf and sc(ft_wep.tf, "get_Rotation")
        if gr then
            local off = safe(function() return gr * Vector3f.new(CFG.dock_x or 0, CFG.dock_y or 0, CFG.dock_z or 0) end)
            if off then return Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
        end
        return Vector3f.new(p.x, p.y, p.z)
    end
    -- Kanister (Joint _04) der linken Hand folgen lassen, mit CFG.hand_* Offset/Rot
    local function ft_follow_hand(j)
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position"); local hr = lh and sc(lh, "get_Rotation")
        if not (hp and hr) then return end
        local off = safe(function() return hr * Vector3f.new(CFG.hand_x or 0, CFG.hand_y or 0, CFG.hand_z or 0) end) or Vector3f.new(0, 0, 0)
        pcall(function() j:call("set_Position", Vector3f.new(hp.x + off.x, hp.y + off.y, hp.z + off.z)) end)
        local rot = safe(function() return (hr * quat_from_euler(CFG.hand_rx or 0, CFG.hand_ry or 0, CFG.hand_rz or 0)):normalized() end)
        if rot then pcall(function() j:call("set_Rotation", rot) end) end
    end
    local function ft_apply_tank()
        local j = ft_wep.tank_joint; if not j then return end
        if tank.preview then ft_follow_hand(j); return end   -- UI-Preview: Kanister an die Hand (Offset tunen)
        if tank.phase == "dropping" then
            local t = os.clock() - tank.t0
            local y = tank.sy - 0.5 * FT_GRAV * t * t
            if y <= tank.floor_y then y = tank.floor_y; tank.phase = "floor"; if not tank.snd then tank.snd = true; play_sound(SND_DROP) end end
            pcall(function() j:call("set_Position", Vector3f.new(tank.sx, y, tank.sz)) end)
        elseif tank.phase == "floor" then
            pcall(function() j:call("set_Position", Vector3f.new(tank.sx, tank.floor_y, tank.sz)) end)
        elseif tank.phase == "in_hand" then
            ft_follow_hand(j)
        end
        -- idle: NICHT anfassen -> Engine skinnt _04 zurueck in die Kammer
    end

    -- Gedroppter (alter/leerer) Kanister: in der "floor"-Phase AUSBLENDEN (weggeworfen -> darf
    -- nicht sichtbar liegenbleiben). Joint _04 = dasselbe Mesh wie der neue Kanister, darum beim
    -- Greifen (in_hand) / nach dem Einsetzen (idle) wieder einblenden. Scale muss jeden Frame in
    -- den Render-Paessen gesetzt werden, sonst skinnt die Engine ihn zurueck. (wie Chicago-Mag)
    local _tank_hidden = false
    local function ft_apply_tank_visibility()
        local j = ft_wep.tank_joint
        local should_hide = (tank.phase == "floor") and (not tank.preview) and j ~= nil
        if should_hide then
            pcall(function() j:call("set_LocalScale", Vector3f.new(0, 0, 0)) end); _tank_hidden = true
        elseif _tank_hidden then
            if j then pcall(function() j:call("set_LocalScale", Vector3f.new(1, 1, 1)) end) end
            _tank_hidden = false
        end
    end

    -- Distanz Hand->Dock (oder 999 wenn nicht ermittelbar)
    local function ft_hand_dock_dist()
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position"); local dp = ft_dock_world()
        if not (hp and dp) then return 999 end
        return math.sqrt((hp.x - dp.x)^2 + (hp.y - dp.y)^2 + (hp.z - dp.z)^2)
    end
    -- Kanister in die Waffe einsetzen (auftanken, angedockt bleiben). Safety bleibt offen ->
    -- Feuer weiter gesperrt, bis man mit Right-B die Sicherung wieder schliesst.
    local function ft_do_insert()
        ft_refill()
        if not CFG.unlimited then CFG.reserve = math.max(0, (CFG.reserve or 0) - 1) end
        tank.phase = "idle"; tank._insert_t = os.clock()
        play_sound(SND_INSERT)
    end

    -- ---- Holster-Griff: nur wenn Tank auf dem Boden liegt + Reserve da -> Joint _04 an die Hand ----
    local function ft_set_mag_in_hand(active)
        if active then
            if tank.phase ~= "floor" or not ft_reserve_ok() then return false end
            tank.phase = "in_hand"; play_sound(SND_GRAB)
            return true
        else
            -- Loslassen: nah an der Waffe -> EINSETZEN (bleibt angedockt); weit weg -> fallen lassen.
            if tank.phase == "in_hand" then
                if ft_hand_dock_dist() <= (CFG.dock_catch or 0.30) then ft_do_insert() else ft_start_drop() end
            end
            return true
        end
    end

    -- ---- Frame-Loop ----
    local _prev_wid = nil
    local _ft_was_managed = false
    re.on_frame(function()
        ft_refresh()
        if ft_wep.wid ~= _prev_wid then
            ft_fire_sound_stop()             -- Waffenwechsel -> Loop nicht haengen lassen
            _fire_prev_ammo, _fire_active_t, _fire_state = nil, nil, "idle"
            tank.phase = "idle"; tank._drop_armed = false; saf.open = false; saf.prog = 0.0
            if ft_wep.wid then _G.__re4_live_wi = nil end   -- echtes Live-Item beim Equippen neu greifen
            _prev_wid = ft_wep.wid
        end
        if not ft_wep.wid then
            if _ft_was_managed then ft_fire_sound_stop(); _G.__vr_mag_in_hand = false; _G.__re4_reload_grab_empty = false; _ft_was_managed = false end
            return
        end
        _ft_was_managed = true
        _G.__vr_manual_reload_consume_b = true   -- Right-B = unsere Sicherung -> kein nativer Reload
        ft_update_safety()

        -- Feuersound Tap vs. Hold (am Munitions-Verbrauch erkannt):
        -- kurzer Druck (< hold_threshold) -> einmaliger Burst; gehalten -> Loop (Stop beim Loslassen).
        do
            local now = os.clock()
            local cur = ft_ammo()
            if _fire_prev_ammo ~= nil and cur < _fire_prev_ammo then
                if _fire_state == "idle" then _fire_state, _fire_start_t = "pending", now end
                _fire_active_t = now
            end
            _fire_prev_ammo = cur
            local since = _fire_active_t and (now - _fire_active_t) or 999
            if _fire_state == "pending" then
                if since < CLASSIFY_GAP and (now - _fire_start_t) >= (CFG.hold_threshold or 0.12) then
                    _fire_state = "hold"; ft_fire_sound_start()             -- noch am Feuern + lang genug -> Hold/Loop
                elseif since >= CLASSIFY_GAP then
                    if CFG.burst_enabled ~= false then ft_play_burst() end  -- vorher gestoppt -> Tap/Burst
                    _fire_state, _fire_active_t = "idle", nil
                end
            elseif _fire_state == "hold" then
                if since >= HOLD_STOP_TAIL then ft_fire_sound_stop(); _fire_state, _fire_active_t = "idle", nil end
            end
        end

        -- Dry-Fire: immer wenn Feuer gesperrt ist (Sicherung OFFEN ODER leer) + frischem
        -- Trigger-Druck (steigende Flanke) -> ein Klick pro Abdruecken.
        do
            local trig = right_trigger_down()
            if trig and not _dryfire_prev and (saf.open or ft_ammo() <= 0) then
                play_sound(SND_DRY)
            end
            _dryfire_prev = trig
        end

        -- Auto-Drop: NUR einmal pro Sicherung-Oeffnen (armed), Tank in der Kammer. KEIN Ammo-Gate
        -- mehr -> der Kanister kann IMMER gewechselt werden (auch halbvoll); jeder neue Kanister
        -- bringt beim Einsetzen die volle Fake-Menge (ft_refill). _drop_armed (1x pro Oeffnen)
        -- verhindert, dass ein frisch eingesteckter Kanister bei noch offener Sicherung sofort faellt.
        if not tank.preview and tank._drop_armed and saf.open and tank.phase == "idle" then
            ft_start_drop(); tank._drop_armed = false
        end

        -- Auto-Einsetzen: Tank in Hand SEHR nah am Dock -> einrasten (auch ohne Loslassen)
        if tank.phase == "in_hand" and ft_hand_dock_dist() <= (CFG.insert_distance or 0.15) then
            ft_do_insert()
        end

        -- Holster frei NUR wenn Tank auf dem Boden liegt + Reserve da (sonst gesperrt + buzz)
        _G.__re4_reload_grab_empty = not (tank.phase == "floor" and ft_reserve_ok())
        -- Feuer gesperrt solange Sicherung offen ODER leer
        -- [LIVE-EMPTY 2026-07-08] Tank-Leer FRISCH aus der Engine (getCurrentGunAmmo, kein Cache); ft_ammo
        -- geht ueber das gecachte __re4_live_wi (stale 0 nach Save-Load) -> nur Fallback wenn pe/Read fehlt.
        local _peft = get_pe()
        local _ftlive = _peft and tonumber(safe(function() return _peft:call("getCurrentGunAmmo") end))
        local ft_empty = (((_ftlive ~= nil) and _ftlive) or ft_ammo()) <= 0
        _G.__vr_block_fire_when_empty = (saf.open or ft_empty) and true or false
        _G.__re4_bf_who = "re4_vr_reload3.lua:3403"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        -- Support-Hand AUS solange Tank in der Hand; nach Insert noch kurz (Cooldown), wie die Revolver
        local cd = tank._insert_t and (os.clock() - tank._insert_t) < 0.45
        _G.__vr_mag_in_hand = (tank.phase == "in_hand" or cd) and true or false
    end)

    -- ---- Render-Paesse (reload3 laedt nach reload/reload2 -> gewinnt) ----
    local function ft_apply_pass()
        if not (CFG.ft_enabled and ft_wep.wid) then return end
        ft_apply_safety()
        ft_apply_tank()
        ft_apply_tank_visibility()
        ft_apply_poses()
    end
    pcall(function() re.on_frame(ft_apply_pass) end)
    pcall(function() re.on_pre_application_entry("LockScene", ft_apply_pass) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", ft_apply_pass) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", ft_apply_pass) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", ft_apply_pass) end)
    -- [WOBBLE-FIX] NACH motion's BeginRendering-POST (+ nach Engine-Skinning) nachziehen:
    -- - Tank _04 fuer ALLE aktiven Phasen (sonst skinnt die Engine ihn zurueck in die Kammer)
    -- - Hand-Posen IMMER (rechte Hand flamehand + linke Hand), sonst ueberschreibt die Anim die Finger.
    local function ft_late()
        if not (CFG.ft_enabled and ft_wep.wid) then return end
        if tank.phase ~= "idle" or tank.preview then ft_apply_tank() end
        ft_apply_tank_visibility()
        ft_apply_poses()
    end
    pcall(function() re.on_application_entry("BeginRendering", ft_late) end)

    -- ---- Holster-Wrapper (FT -> reload3-FT, sonst weiter an die Kette) ----
    local _orig_ft = _G.__re4_reload_set_mag_in_hand
    _G.__re4_reload_set_mag_in_hand = function(active)
        if is_ft(get_equip_wid()) then return ft_set_mag_in_hand(active) end
        if _orig_ft then return _orig_ft(active) end
        return false
    end

    re.on_script_reset(function()
        ft_fire_sound_stop()
        _fire_prev_ammo, _fire_active_t, _fire_state = nil, nil, "idle"
        tank.phase = "idle"; tank._insert_t = nil; tank.preview = false; tank._drop_armed = false
        saf.open = false; saf.prog = 0.0
        ft_wep.wid, ft_wep.tf, ft_wep.safety_joint, ft_wep.tank_joint = nil, nil, nil, nil
        _G.__vr_mag_in_hand = false
    end)

    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion _G.__re4_reload3_ft_ui (109 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end
-- =====================================================================
-- ENDE FLAMETHROWER (wp4701)
-- =====================================================================
