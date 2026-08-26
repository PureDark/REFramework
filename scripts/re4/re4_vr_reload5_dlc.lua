-- Builtin implementation: src/mods/vr/games/re4/RE4VRReload5.cpp
return
-- =====================================================================
-- RE4 VR - Manual Reload 5: SEPARATE WAYS (DLC) - Langwaffen (Anti-Materiel + Hunting Rifle)
-- Pfad: reframework/autorun/re4_vr_reload5_dlc.lua
-- =====================================================================
-- 1:1-PORTIERUNG des Rifle-Blocks aus re4_vr_reload2.lua (Z.1251-2316,
-- Leons Stingray wp4401) auf die DLC-Waffe wp6105 "Anti-Materiel Rifle".
-- Uebernommen ist ALLES: Mag-Drop, Slide-Rack, Verstellschalter, Ammo-
-- Zaehlung, Sounds, Hand-Posen und deren Offsets.
--
-- WARUM EIN EIGENES FILE: 6105 wurde bisher von KEINEM Reload-Script
-- verwaltet (reload4_dlc kennt nur 6100/6103/6104/6112, reload5_dlc nur
-- 6113) -> kein Mag-Drop, kein Rack.
--
-- LEON BLEIBT UNBERUEHRT -- die Trennung ist mehrfach gesichert:
-- * RIFLES = { [6105] } -> Leons 4401/4402 werden NIE angefasst
-- * eigene Persistenz: re4_vr/re4_vr_reload6_dlc.json
-- (Leons re4_vr_reload2_rifle.json wird weder gelesen noch geschrieben)
-- * EIGENE Pose-Daten im Block (RPOSES) -- kein Zugriff auf Leons POSES,
-- kein gestures-Quer-Laden. Handposen sind aus Leons Werten KOPIERT
-- und ab hier unabhaengig tunbar.
-- * __re4_reload_set_mag_in_hand und die Rifle-UI laufen ueber die
-- WEITERREICH-KETTE (Vorgaenger sichern -> bei fremder Waffe an ihn
-- durchreichen), nicht ueber hartes Ueberschreiben.
-- * (der State-Export __re4_reload_dbg wurde am 2026-08-15 entfernt)
--
-- Laedt alphabetisch NACH reload2/reload4/reload5 -> die Ketten stimmen.
-- =====================================================================

if reframework:get_game_name() ~= "re4" then return end

-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: dieselben Objekte wurden pro Frame
-- dutzendfach neu bei der Engine erfragt (get_equip_wid = vier Managed-Calls, body_tf = drei),
-- und die Waffen-Paesse laufen 4-5 mal pro Frame. Ab jetzt einmal pro Frame, danach aus einer
-- Lua-Tabelle. Semantik unveraendert -- die alten Wege stehen als Fallback darunter.
-- NOT-AUS: `_G.__re4_fc_off = true`. Bewusst OHNE Datei-Local (Lua-200-Local-Limit).
pcall(function() require("re4vr/re4_vr_frame_cache") end)
local character_manager = nil
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
local snd_sc_td = sdk.typeof("soundlib.SoundContainer")   -- [SOUND] fuer trigger(UInt32, id) am Waffen-GO
local _pe_cache = nil
local function get_pe()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.pe() end
    if _pe_cache and safe(function() return _pe_cache:call("get_Context") end) then return _pe_cache end
    local ctx = get_ctx(); local head = ctx and sc(ctx, "get_HeadGameObject")
    _pe_cache = head and sc(head, "getComponent(System.Type)", pe_td)
    return _pe_cache
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

local wep = { wid = nil, tf = nil, cyl_joint = nil, cyl_rest_rot = nil, cyl_rest_pos = nil, bullet_joints = nil, insert_joint = nil, spin_joint = nil, spin_rest_rot = nil, hand_cart_joint = nil, hand_cart_vis = nil }

do
    -- ---- welche Waffen sind Rifles (dieser Gattung) ----
    local RIFLES = { [6105] = true }   -- [DLC] wp6105 Anti-Materiel Rifle (= Leons Stingray 4401)
    local function is_rifle(wid) return wid ~= nil and RIFLES[wid] == true end
    local function ease(t) return t * t * (3.0 - 2.0 * t) end   -- smoothstep (reload2 hat kein globales ease)
    local _rack_near = false     -- Hand nah am Slide? (Upvalue fuer apply_hand_pose + on_frame)
    local _switch_hand = false   -- Hand am Verstellschalter + Grip? (Upvalue fuer apply_hand_pose + on_frame)

    -- ---- Per-Waffe Joints (CODE-Konstanten, NIE aus JSON; vgl. feedback-re4-joints-code-only) ----
    local RJOINTS = {
        [6105] = { mag = "_04", slide = "_02", switch = "_05" },   -- Stingray (bestaetigt; Verstellschalter = _05)
        -- CQBR (: Mag=_04, Slide=_02, Klappschalter=_06)
    }

    -- ---- Slide-Pose (absolute lokale Z + Hand-Dock-Offset/Rot), 1:1 von LE5 (wp4202) geseedet ----
    -- rest_z=gechambert/vorne, park_z=leer/Mag-out (MITTEL), back_z=Rack-Endpunkt (voll hinten).
    -- dock_x/y/z = Versatz der LINKEN Hand relativ zum Slide-Joint; rack_rx/ry/rz = Hand-Rotation am Slide.
    -- empty_x = X-Versatz (lokal), um den der Slide bei LEER/Nachladen ausfaehrt (0 = bleibt zu).
    -- CQBR (4402) faehrt bei Ammo=0 sichtbar in X +0.020 raus; wir ziehen dann in Z zum Chambern.
    local RSLIDE_DEF = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, empty_x = 0.0,
                         dock_x = 0.045, dock_y = 0.032, dock_z = -0.192,
                         rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1,
                         st_rx = 0.0, st_ry = 0.0, st_rz = 0.0 }   -- Daumen-Spreizung (additiv) der Slide-Zieh-Pose
    local RSLIDE = { [6105] = {} }   -- per-wid Overrides (JSON), Default fuellt Luecken
    local function rslide(wid)
        local sp = RSLIDE[wid]; if not sp then sp = {}; RSLIDE[wid] = sp end
        for k, v in pairs(RSLIDE_DEF) do if sp[k] == nil then sp[k] = v end end
        return sp
    end
    -- Slide-Idle-/Pull-Basis: empty_x-Waffen (CQBR) bleiben auf empty in Z VORNE (rest_z) und fahren
    -- nur in X aus -> der Z-Pull ist der manuelle Rack. Stingray/SMG: park_z (Slide rutscht mittig).
    local function park_ref(sp) return ((sp.empty_x or 0) ~= 0) and sp.rest_z or sp.park_z end

    -- ---- Dock-Port (fester Gun-Joint + Offset) fuer die Einlege-Naehe. Stingray = _03 + Z 0.090
    -- (bestaetigt: genau da kommt das Mag rein; gleiches Muster wie LE5/andere Waffen). ----
    local RDOCK_DEF = { joint = "_03", x = 0.0, y = 0.0, z = 0.090 }
    local RDOCK = { [6105] = { joint = "_03", z = 0.090 } }
    local function rdock(wid)
        local d = RDOCK[wid]; if not d then d = {}; RDOCK[wid] = d end
        if d.joint == nil then d.joint = RDOCK_DEF.joint end
        d.x = d.x or 0; d.y = d.y or 0; d.z = d.z or RDOCK_DEF.z
        return d
    end

    -- ---- Mag-in-Hand Offset (Mag-Joint folgt der linken Hand) + Daumen-Spreizung ----
    local RMAGHAND = { [6105] = {} }
    local function rmaghand(wid)
        local m = RMAGHAND[wid]; if not m then m = {}; RMAGHAND[wid] = m end
        m.x = m.x or 0; m.y = m.y or 0; m.z = m.z or 0
        m.rx = m.rx or 0; m.ry = m.ry or 0; m.rz = m.rz or 0
        m.t_rx = m.t_rx or 0; m.t_ry = m.t_ry or 0; m.t_rz = m.t_rz or 0
        return m
    end

    -- ---- Verstellschalter _05 (2 Stufen): Rotation bei Stufe 1 + Greif-/Dreh-Parameter ----
    -- rx/ry/rz = Schalter-Joint-Drehung bei Stufe 1. dx/dy/dz = Versatz der LINKEN HAND relativ zum
    -- Schalter-Joint (lokales Joint-Frame) zum Andocken. hrx/hry/hrz = Hand-Rotations-Offset am Schalter.
    local RSWITCH_DEF = { rx = 0.0, ry = 0.0, rz = -45.0, lerp = 0.18, grab_dist = 0.14,
                          dx = 0.0, dy = 0.0, dz = 0.0, hrx = 0.0, hry = 0.0, hrz = 0.0 }
    local RSWITCH = { [6105] = {} }
    local function rswitch(wid)
        local s = RSWITCH[wid]; if not s then s = {}; RSWITCH[wid] = s end
        for k, v in pairs(RSWITCH_DEF) do if s[k] == nil then s[k] = v end end
        return s
    end

    -- ---- Hand-Posen: EIGENE DATEN-KOPIE in reload2 (NICHT aus gestures.json/reload.json quer-laden!
    -- gestures wird geloescht -> Werte hier FEST reingeschrieben). Aus gestures.json ausgelesen:
    -- StingrayMag/StingraySlide = eigene Captures; StingraySwitch = Kopie der LE5SWITCH-Pose.
    -- Eigene Apply-Funktion (rf_pose_apply) -> KEINE Abhaengigkeit von reload.lua's Pose-Engine.
    local RPOSES = {
        ["StingrayMag"] = { hand="left", bones = { ["L_IndexF1"]={0.993446,0.042820,0.010770,-0.105429}, ["L_IndexF2"]={0.868657,0.000000,0.000000,-0.495415}, ["L_IndexF3"]={0.955468,0.000000,0.000000,-0.295095}, ["L_MiddleF1"]={0.964366,-0.034839,0.015712,-0.261795}, ["L_MiddleF2"]={0.812551,0.000000,0.000000,-0.582890}, ["L_MiddleF3"]={0.929199,0.000000,0.000000,-0.369579}, ["L_Palm"]={1.000000,0.000000,0.000000,0.000000}, ["L_PinkyF1"]={0.886025,-0.206433,0.097919,-0.403432}, ["L_PinkyF2"]={0.655536,0.000000,0.000000,-0.755164}, ["L_PinkyF3"]={0.800316,0.000000,0.000000,-0.599579}, ["L_RingF1"]={0.910646,-0.152227,0.095372,-0.372096}, ["L_RingF2"]={0.820979,0.000000,0.000000,-0.570959}, ["L_RingF3"]={0.918430,0.000000,0.000000,-0.395584}, ["L_Thumb1"]={0.954216,0.092758,-0.147124,-0.243356}, ["L_Thumb2"]={0.928704,0.047384,-0.316781,-0.186854}, ["L_Thumb3"]={0.976686,-0.002277,0.208568,0.050784} } },
        ["StingraySlide"] = { hand="left", bones = { ["L_IndexF1"]={0.962506,0.038342,-0.001037,-0.268536}, ["L_IndexF2"]={0.847117,0.000000,0.000000,-0.531406}, ["L_IndexF3"]={0.952203,0.000000,0.000000,-0.305466}, ["L_MiddleF1"]={0.938745,-0.015258,-0.024061,-0.343433}, ["L_MiddleF2"]={0.764522,0.000000,0.000000,-0.644598}, ["L_MiddleF3"]={0.964690,0.000000,0.000000,-0.263388}, ["L_Palm"]={1.000000,0.000000,0.000000,0.000000}, ["L_PinkyF1"]={0.933727,-0.083950,0.015837,-0.347642}, ["L_PinkyF2"]={0.881599,0.000000,0.000000,-0.471999}, ["L_PinkyF3"]={0.919535,0.000000,0.000000,-0.393009}, ["L_RingF1"]={0.938012,-0.058541,0.018805,-0.341106}, ["L_RingF2"]={0.813982,0.000000,0.000000,-0.580890}, ["L_RingF3"]={0.962837,0.000000,0.000000,-0.270083}, ["L_Thumb1"]={0.964133,0.166059,-0.014706,-0.206532}, ["L_Thumb2"]={0.992006,0.012628,-0.122927,0.025579}, ["L_Thumb3"]={0.982769,-0.006119,0.182809,-0.026611} } },
        ["StingraySwitch"] = { hand="left", bones = { ["L_IndexF1"]={0.924900,0.000000,-0.015000,-0.380100}, ["L_IndexF2"]={0.819200,0.000000,0.000000,-0.573600}, ["L_IndexF3"]={0.866000,0.000000,0.000000,-0.500000}, ["L_MiddleF1"]={0.896271,-0.104853,0.085188,-0.422431}, ["L_MiddleF2"]={0.705958,0.000000,0.000000,-0.708254}, ["L_MiddleF3"]={0.890564,0.000000,0.000000,-0.454858}, ["L_Palm"]={1.000000,0.000000,0.000000,0.000000}, ["L_PinkyF1"]={0.922581,-0.182263,0.075602,-0.331525}, ["L_PinkyF2"]={0.722647,0.000000,0.000000,-0.691217}, ["L_PinkyF3"]={0.896982,0.000000,0.000000,-0.442068}, ["L_RingF1"]={0.879959,-0.133028,0.090023,-0.447069}, ["L_RingF2"]={0.710167,0.000000,0.000000,-0.704033}, ["L_RingF3"]={0.892185,0.000000,0.000000,-0.451670}, ["L_Thumb1"]={0.918569,0.252866,-0.108586,-0.283724}, ["L_Thumb2"]={0.999635,0.000000,-0.027026,0.000000}, ["L_Thumb3"]={0.923391,-0.000011,0.383861,-0.000004} } },
        -- CQBR Slide-Zieh-Pose = eigene Kopie der RiotSLide-Daten (gestures-unabhaengig, NUR diese Waffe).
        ["CqbrSlide"] = { hand="left", bones = { ["L_IndexF1"]={0.986822,0.041360,0.006551,-0.156297}, ["L_IndexF2"]={0.800622,0,0,-0.599170}, ["L_IndexF3"]={0.976009,0,0,-0.217732}, ["L_MiddleF1"]={0.924938,-0.023124,0.000451,-0.379414}, ["L_MiddleF2"]={0.833468,0,0,-0.552567}, ["L_MiddleF3"]={0.957340,0,0,-0.288964}, ["L_Palm"]={1,0,0,0}, ["L_PinkyF1"]={0.864541,-0.060455,-0.034802,-0.497697}, ["L_PinkyF2"]={0.905133,0,0,-0.425128}, ["L_PinkyF3"]={0.935618,0,0,-0.353014}, ["L_RingF1"]={0.877944,-0.024523,-0.013350,-0.477948}, ["L_RingF2"]={0.893334,0,0,-0.449392}, ["L_RingF3"]={0.933580,0,0,-0.358368}, ["L_Thumb1"]={0.991438,0.108579,-0.021318,-0.069329}, ["L_Thumb2"]={0.935394,0,-0.353608,0}, ["L_Thumb3"]={1.0,0,-0.000215,0} } },
    }
    local RMAG_POSE    = { [6105] = "StingrayMag" }    -- 1) linke Hand haelt Mag (CQBR seedet Stingray-Pose, spaeter tunen)
    local RRACK_POSE   = { [6105] = "StingraySlide" }       -- 2) linke Hand zieht am Slide (CQBR = eigene RiotSLide-Kopie)
    local RSWITCH_POSE = { [6105] = "StingraySwitch" } -- 3) Hand am Klappschalter (CQBR seedet Stingray-Switch-Pose)

    -- Bone-Name -> Joint cachen (wie reload.lua pose_build_map), dann Pose direkt anwenden.
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

    -- ---- Engine schliesst den Slide selbst nach dem Reload? (LE5 = true) -> wir forcen rest_z NICHT ----
    local RENGINE_CLOSES = { [6105] = true }   -- CQBR (4402) NICHT: voller manueller Rack (wir forcen Z zu + X zurueck)

    -- ---- Sperrt Schalter-Stufe 1 das Feuern? (Stingray ja = bewusster Dry-Fire-Stand; CQBR NEIN,
    -- dort ist Stufe 1 = semi/2-Schuss und muss feuern -> Fire-Mode-Logik kommt separat). ----
    local RSWITCH_BLOCKS_FIRE = { [6105] = true }

    -- ---- Schalter-Stufe 1 = Burst? Wert = Schuss pro Trigger-Zug. binding.lua blockt RT nach N Schuss
    -- (liest __vr_burst_active/__vr_burst_count; Schuss-Zaehler kommt aus dem Crosshair-Hook). ----
    local RSWITCH_BURST = {}   -- [DLC] leer (war nur CQBR 4402, gehoert Leon)

    -- ---- Sounds (per-wid, von LE5/Punisher geseedet -> ggf. per #re4_sound_player.lua nachziehen) ----
    local RSND = {
        [6105] = { dry_fire = 812850326, mag_eject = 1466005368, mag_insert = 943565871,   -- mag_eject/insert/slide_back bestaetigt
                   mag_floor = 3042341191, slide_back = 2254736731, slide_forward = 2254736731, mag_holster = 1839787494,
                   switch = 3805002294 },   -- Verstellschalter-Umleg-Sound (bestaetigt)
        }

    -- ---- skalare Konfiguration ----
    local RCFG = { rifle_enabled = true, reload_ammo = true, sound_enabled = true, insert_distance = 0.15 }
    local RCFG_PATH = "re4_vr/re4_vr_reload5_dlc_rifle.json"

    local RSLIDE_FIELDS = { "rest_z","park_z","back_z","empty_x","dock_x","dock_y","dock_z","rack_rx","rack_ry","rack_rz","st_rx","st_ry","st_rz" }

    local function rload_cfg()
        local data = safe(function() return json.load_file(RCFG_PATH) end)
        if type(data) ~= "table" then return end
        local c = data.cfg or {}
        if type(c.rifle_enabled)  == "boolean" then RCFG.rifle_enabled  = c.rifle_enabled  end
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
        if type(data.switch) == "table" then
            for k, v in pairs(data.switch) do local wid = tonumber(k)
                if wid and type(v) == "table" then local s = rswitch(wid)
                    for _, f in ipairs({ "rx","ry","rz","lerp","grab_dist","dx","dy","dz","hrx","hry","hrz" }) do if type(v[f]) == "number" then s[f] = v[f] end end end end
        end
    end
    local function rsave_cfg()
        local slideo, docko, mho, swo = {}, {}, {}, {}
        for wid in pairs(RIFLES) do
            local sp = rslide(wid); local so = {}; for _, f in ipairs(RSLIDE_FIELDS) do so[f] = sp[f] end; slideo[tostring(wid)] = so
            local d = rdock(wid); docko[tostring(wid)] = { joint = d.joint, x = d.x, y = d.y, z = d.z }
            local m = rmaghand(wid); mho[tostring(wid)] = { x=m.x,y=m.y,z=m.z, rx=m.rx,ry=m.ry,rz=m.rz, t_rx=m.t_rx,t_ry=m.t_ry,t_rz=m.t_rz }
            local s = rswitch(wid); swo[tostring(wid)] = { rx=s.rx,ry=s.ry,rz=s.rz, lerp=s.lerp, grab_dist=s.grab_dist,
                dx=s.dx, dy=s.dy, dz=s.dz, hrx=s.hrx, hry=s.hry, hrz=s.hrz }
        end
        pcall(function() json.dump_file(RCFG_PATH, { cfg = RCFG, slide = slideo, dock = docko, maghand = mho, switch = swo }) end)
    end
    rload_cfg()

    -- ---- Sound am Waffen-SoundContainer (eigene tf, nicht die Revolver-tf) ----
    local snd_td = sdk.typeof("soundlib.SoundContainer")
    local rwep = { wid = nil, tf = nil, mag_joint = nil, slide_joint = nil, switch_joint = nil,
                   switch_rest_rot = nil, slide_rest_lp = nil, rest_lp = nil, rest_lr = nil }
    local _reacquired = false   -- [SAVE_LOAD] gleiche Waffe neu instanziiert (Item-Cache stale -> abraeumen)
    local function rf_snd(id)
        if not RCFG.sound_enabled or not id or id <= 0 then return end
        local tf = rwep.tf; if not (tf and snd_td) then return end
        local go = safe(function() return tf:call("get_GameObject") end); if not go then return end
        local scn = safe(function() return go:call("getComponent(System.Type)", snd_td) end); if not scn then return end
        pcall(function() scn:call("trigger(System.UInt32)", id) end)
    end
    local function rsnd(wid, key) local t = wid and RSND[wid]; return t and t[key] or nil end

    -- ---- gemanagte Rifle? ----
    local function rmanaged_wid()
        if not RCFG.rifle_enabled then return nil end
        local wid = get_equip_wid()
        if not is_rifle(wid) then return nil end
        return wid
    end
    local function rf_refresh()
        local wid = rmanaged_wid()
        if not wid then
            rwep.wid, rwep.tf, rwep.mag_joint, rwep.slide_joint, rwep.switch_joint, rwep.switch_rest_rot = nil, nil, nil, nil, nil, nil
            return
        end
        if rwep.wid == wid and rwep.mag_joint and rwep.tf and safe(function() return rwep.tf:call("get_Position") end) then return end
        -- [SAVE_LOAD] gleiche WeaponId, aber tf ungueltig -> neue Instanz (Save-Load/Respawn). Der
        -- Waffenwechsel-Reset greift hier NICHT (wid unveraendert) -> separat signalisieren.
        local same_wid = (rwep.wid == wid)
        rwep.wid, rwep.tf, rwep.mag_joint, rwep.slide_joint, rwep.switch_joint, rwep.switch_rest_rot = nil, nil, nil, nil, nil, nil
        local jc = RJOINTS[wid]; if not (jc and jc.mag) then return end
        local go, tf = find_weapon(wid); if not tf then return end
        local mj = sc(tf, "getJointByName", jc.mag); if not mj then return end
        rwep.wid, rwep.tf, rwep.mag_joint = wid, tf, mj
        rwep.slide_joint  = (jc.slide  and jc.slide  ~= "") and sc(tf, "getJointByName", jc.slide)  or nil
        rwep.slide_rest_lp = nil
        if rwep.slide_joint then
            local lp = sc(rwep.slide_joint, "get_LocalPosition")   -- Basis-X (Slide zu); fuer empty_x-Ausfahren
            if lp then rwep.slide_rest_lp = { x = lp.x, y = lp.y, z = lp.z } end
        end
        rwep.switch_joint = (jc.switch and jc.switch ~= "") and sc(tf, "getJointByName", jc.switch) or nil
        if rwep.switch_joint then rwep.switch_rest_rot = sc(rwep.switch_joint, "get_LocalRotation") end
        if same_wid then _reacquired = true end
    end

    -- ---- chainsaw.Gun (Leer-Erkennung + Slide-Entriegeln nach Rack), 1:1 von reload.lua ----
    local _state_td = sdk.find_type_definition("chainsaw.Gun.State")
    local _ammoempty_num = _state_td and safe(function() return _state_td:get_field("AmmoEmpty"):get_data(nil) end)
    if type(_ammoempty_num) == "userdata" then _ammoempty_num = safe(function() return _ammoempty_num:get_field("value__") end) end
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
    local function gun_chamber()   -- aus AmmoEmpty holen -> Engine entriegelt den Slide
        local g = get_gun(); if not (g and _gun_holding ~= nil) then return end
        pcall(function() g:call("set_CurrentState(chainsaw.Gun.State)", _gun_holding) end)
    end
    local function gun_ammo_empty()
        local pe = get_pe()
        return (pe and safe(function() return pe:call("isGunAmmoEmpty") end)) == true
    end

    -- ---- Live-WeaponItem + Ammo-Helfer. EIGENES rf_get_wi (NICHT reload2-get_live_wi!): das
    -- validiert gegen die Revolver-wep.wid und gibt bei Rifle (wep.wid=nil) ein evtl. stale
    -- Revolver-Item zurueck. Hier gegen die EQUIPPTE wid validieren -> immer das Rifle-Item.
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

    -- ---- VR-Input (frische Handles jeden Frame; Stale-Handle-Fix wie reload.lua) ----
    local function left_grip_down()
        if not vrmod then return false end
        local act, lj
        pcall(function() act = vrmod:get_action_grip() end)
        pcall(function() lj  = vrmod:get_left_joystick() end)
        if not (act and lj) then return false end
        local ok, v = pcall(function() return vrmod:is_action_active(act, lj) end)
        return ok and v == true
    end
    local function left_trigger_down()
        if not vrmod then return false end
        local ok, v = pcall(function()
            local act = vrmod:get_action_weapon_dial(); local lj = vrmod:get_left_joystick()
            if not (act and lj) then return false end
            return vrmod:is_action_active(act, lj)
        end)
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
    -- Mag-Drop / Mag-in-Hand / Insert (RE9-/LE5-Muster, gekapselt)
    -- =====================================================================
    local GRAVITY = 9.8
    local DROP_FALL_DUR = 1.0
    local drop = { active = false, use_module = false, joint = nil, sx = 0, sy = 0, sz = 0, t0 = 0 }
    -- [FLOOR-SND] Boden-Sound wird beim Drop-START geplant (nicht ueber eine Frame-Flanke -> robust,
    -- feuert auch beim B-Eject). _floor_delay_module = Slide+Fall (Modul landet spaeter als der gerade Hand-Fall).
    local _mag_floor_at   = 0
    local _floor_delay        = 0.45   -- gerader Hand-Fall (Mag aus der Hand losgelassen)
    local _floor_delay_module = 0.78   -- Modul-Slide (Schaft-Slide ~0.18 + kontrollierter Fall ~0.55)
    local mag_hand = { active = false }
    local mag_insert = { active = false, t0 = 0, dur = 0.18, slp = nil, slr = nil }
    local mag_out = false             -- Mag physisch draussen (blockt B-Doppeldrop + Feuer, bis Insert)
    local mag_retained = 0            -- beim Drop gemerkter Lade-Stand (UI zeigt 0, geht beim Insert zurueck)
    local mag_tune = { active = false }   -- [PREVIEW] Mag zum Tunen in die Hand zwingen (kein Reload-Zyklus)
    local _flow = function() return drop.active or mag_hand.active or mag_insert.active or mag_tune.active end

    local rack = { needs = false, empty_when_dropped = false, grab_active = false, armed = false,
                   frac = 0, pulled = false, gx = 0, gy = 0, gz = 0, dock_blend = 0,
                   _ammo_input_t = nil, empty = false, _chambered_hold = false, tuning = false, tune_frac = 0,
                   dock_tune = false }   -- [PREVIEW] Hand ans Slide-Dock zwingen (zum Tunen der dock/rack-Offsets)

    local function rf_capture_mag_rest()
        if not rwep.mag_joint then return end
        if _flow() or mag_out then return end
        local lp = sc(rwep.mag_joint, "get_LocalPosition")
        local lr = sc(rwep.mag_joint, "get_LocalRotation")
        if lp then rwep.rest_lp = { x = lp.x, y = lp.y, z = lp.z } end
        if lr then rwep.rest_lr = { w = lr.w, x = lr.x, y = lr.y, z = lr.z } end
    end

    -- [ADV-SLIDE] Mag gleitet erst entlang des Schachts aus der Waffe, dann Fall zum Boden.
    -- use_module=true nutzt das gemeinsame _G.__re4_reload_mag_slide-Modul (wie reload.lua's
    -- start_mag_drop) -> Schaft-Slide. use_module=false = simpler Geradeaus-Fall (Hand-Loslassen).
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
        if mag_out then return false end                                  -- schon draussen (Anti-Doppeldrop)
        -- [KEIN DROP OHNE RESERVE 2026-08-12] Ohne Nachschub wird das Magazin gar nicht erst
        -- ausgeworfen -- gilt fuer JEDE Waffe, nicht nur fuer die, bei der es auffiel.
        if (tonumber(rf_reserve()) or 0) <= 0 then
            return false
        end
        -- [LIVE-EMPTY 2026-07-08] Frischer Engine-Read (getCurrentGunAmmo, kein Cache) statt rf_loaded
        -- (__re4_live_wi -> stale 0 nach Save-Load -> empty_when_dropped faelschlich true -> rack.needs
        -- latcht -> Dauer-Dry-Fire). Fallback auf rf_loaded nur wenn pe/Read fehlt.
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
            -- [FIX 2026-07-23] Hier stand `mag_retained = loaded` -- `loaded` ist an dieser Stelle
            -- gar nicht definiert (die lokale gibt es erst in der Tick-Funktion) -> mag_retained wurde 0.
            -- Folge: droppt man ein VOLLES Mag ohne Reserve, meldet rf_can_grab (0 + 0 > 0 = false) und
            -- man kann kein neues Mag holen -- obwohl 18 Schuss im gedroppten Mag waren. Also den echten
            -- aktuellen Ladestand nehmen (frischer Engine-Read, kein Cache).
            local _pe2 = get_pe()
            local _ld = _pe2 and tonumber(safe(function() return _pe2:call("getCurrentGunAmmo") end))
            mag_retained = _ld or (rf_loaded() or 0)
            local wi = rf_get_wi(); if wi then _G.__re4_carry_capture(wi, "re4_vr_reload5_dlc.lua:527", nil); pcall(function() wi:write_dword(0x44, 0) end) end   -- UI auf 0
            -- [ACCESSOR-FOLGE 2026-08-12] Diese 0 ist UNSER Werk und wirkt seit dem Accessor-Umbau
            -- wirklich. `rack.empty` darf sie beim Einsetzen nicht als leere Kammer werten.
            rack._zeroed_by_us = true
        end
        -- Mag-Joint in Ruhe, dann frisch droppen
        if rwep.rest_lp then pcall(function() rwep.mag_joint:call("set_LocalPosition", Vector3f.new(rwep.rest_lp.x, rwep.rest_lp.y, rwep.rest_lp.z)) end) end
        if rwep.rest_lr then pcall(function() rwep.mag_joint:call("set_LocalRotation", Quaternion.new(rwep.rest_lr.w, rwep.rest_lr.x, rwep.rest_lr.y, rwep.rest_lr.z)) end) end
        local p = sc(rwep.mag_joint, "get_Position")
        local started = start_drop_from(p, true)   -- [ADV-SLIDE] B-Eject: erst aus dem Schacht sliden, dann fallen
        if started then
            mag_out = true; rf_snd(rsnd(rwep.wid, "mag_eject"))
            _mag_floor_at = os.clock() + (drop.use_module and _floor_delay_module or _floor_delay)   -- [FLOOR-SND]
        end
        return started
    end
    local function update_drop()
        if not drop.active then return end
        if drop.use_module then
            -- [ADV-SLIDE] Slide+Fall treibt das Modul; es hält am Boden, bis Grab/Reset cancelt.
            local ms = _G.__re4_reload_mag_slide
            if ms then pcall(function() ms.tick() end) else stop_drop() end
            return
        end
        if not drop.joint then return end
        local t = os.clock() - drop.t0
        if t > DROP_FALL_DUR then drop.active, drop.joint = false, nil; return end   -- Auto-Clear (kein Soft-Lock)
        local fall = 0.5 * GRAVITY * t * t
        pcall(function() drop.joint:call("set_Position", Vector3f.new(drop.sx, drop.sy - fall, drop.sz)) end)
    end

    -- Holster-Grab: Mag in die linke Hand (nur wenn Mag draussen + was zu laden da)
    local function rf_can_grab()
        if mag_hand.active or mag_insert.active then return false end
        if not mag_out then return false end
        return ((mag_retained or 0) + rf_reserve()) > 0
    end
    local function rifle_set_mag_in_hand(active)
        if active then
            if not rf_can_grab() then return false end
            stop_drop()   -- [ADV-SLIDE] laufenden Modul-Slide sauber abbrechen, sonst kämpft er gegen die Hand-Pose
            mag_hand.active = true
            rf_snd(rsnd(rwep.wid, "mag_holster"))
            return true
        end
        -- losgelassen ohne Einlegen -> Mag faellt von der Hand-Position auf den Boden
        if mag_hand.active then
            mag_hand.active = false
            local p = rwep.mag_joint and sc(rwep.mag_joint, "get_Position")
            if start_drop_from(p) then _mag_floor_at = os.clock() + _floor_delay end   -- [FLOOR-SND] gerader Fall
        end
        return true
    end

    -- Mag folgt der linken Hand (Hand-Pose wird im Render-Pass direkt gesetzt, s.u.)
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

    -- Dock-Port-Welt (fester Gun-Joint + Offset) fuer die Einlege-Naehe
    local function dock_port_world()
        local d = rdock(rwep.wid or 0); if not rwep.tf then return nil end
        local j = sc(rwep.tf, "getJointByName", d.joint); if not j then return nil end
        local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation"); if not (jp and jr) then return nil end
        local off = safe(function() return jr * Vector3f.new(d.x, d.y, d.z) end); if not off then return nil end
        return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
    end

    -- Insert: Mag von Hand-Lokalpose in die Chamber-Ruhepose lerpen
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
            -- [LEERE KAMMER 2026-07-23] wie in reload2/3: leere Kammer verlangt den Rack auch
            -- dann, wenn zwischendurch die Waffe gewechselt wurde. Nur mit Slide-Joint.
            -- [ACCESSOR-FOLGE 2026-08-12] `rack.empty` zaehlt nur, wenn die 0 NICHT von unserem
            -- eigenen Mag-Drop-Leeren stammt (Waffenwechsel-Fall bleibt erhalten).
            if (rack.empty_when_dropped
                or (rack.empty and rwep.slide_joint and rack._zeroed_by_us ~= true)) then rack.needs = true else
                rack.needs = false
                rack._zeroed_by_us = false   -- Merker verbraucht
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
    -- Slide-Rack (Pull-Geste) + Switch
    -- =====================================================================
    local RACK_GRAB_DIST = 0.14
    local function clear_rack()
        rack.needs = false; rack.grab_active = false; rack.pulled = false; rack.frac = 0
        gun_chamber()                                  -- Engine aus AmmoEmpty -> Slide entriegelt
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
            if not grip then rack.armed = true; return end                -- Grip erst loslassen -> scharf
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
        -- Grip losgelassen
        if rack.pulled then
            clear_rack(); rack_haptic(0.95, 0.07); rf_snd(rsnd(rwep.wid, "slide_forward"))
        else
            rack.grab_active = false; rack.frac = 0; rack.pulled = false; rack.armed = true
        end
    end

    -- Dock-Ziel (Hand folgt dem Slide) publizieren
    local DOCK_BLEND_SPEED = 0.10
    -- advance=true (on_frame): Blend EINMAL pro Frame vorruecken. advance=false (Render-Pass): nur
    -- mit dem aktuellen Blend frisch re-publishen (arm_chain liest pro Pass) OHNE doppelten Ramp -> kein Snap.
    local function update_dock_publish(advance)
        -- Quelle waehlen: Verstellschalter (joint_05) hat VORRANG vor dem Slide-Rack (wie LE5 in motion.lua).
        -- Beide docken die linke Hand ueber DIESELBEN Globals (__vr_slide_hand_world_*), die arm_chain liest.
        local src_joint, ox, oy, oz, rrx, rry, rrz
        local want = 0.0
        if _switch_hand and rwep.switch_joint then   -- _switch_hand enthaelt bereits den Preview-Zustand (s. update_switch)
            local s = rswitch(rwep.wid or 0)
            src_joint = rwep.switch_joint
            ox, oy, oz = s.dx, s.dy, s.dz
            rrx, rry, rrz = s.hrx, s.hry, s.hrz
            want = 1.0
        elseif (rack.grab_active or rack.dock_tune) and rwep.slide_joint then
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

    -- Slide-Joint-Z treiben (apply_slide_park-Aequivalent)
    local function apply_slide_park()
        if not rwep.slide_joint then return end
        if not (rack.empty or mag_out or rack.needs or rack.grab_active or rack.tuning or rack._chambered_hold) then return end
        local cur = sc(rwep.slide_joint, "get_LocalPosition"); if not cur then return end
        local sp = rslide(rwep.wid or 0); local z
        local extended = false   -- Slide bei leer/Nachladen/Ziehen in X ausgefahren (CQBR empty_x)
        local pz = park_ref(sp)  -- Idle-/Pull-Basis (CQBR=rest_z -> kein Z-Versatz auf empty)
        if rack.tuning then z = pz + (sp.back_z - pz) * rack.tune_frac; extended = true
        elseif rack.grab_active then z = pz + (sp.back_z - pz) * rack.frac; extended = true
        elseif rack._chambered_hold then if RENGINE_CLOSES[rwep.wid] then return end; z = sp.rest_z
        elseif rack.needs or rack.empty_when_dropped or rack.empty then z = pz; extended = true
        else if RENGINE_CLOSES[rwep.wid] then return end; z = sp.rest_z end
        local nx = cur.x
        local ex = sp.empty_x or 0
        if ex ~= 0 and rwep.slide_rest_lp then nx = rwep.slide_rest_lp.x + (extended and ex or 0) end
        pcall(function() rwep.slide_joint:call("set_LocalPosition", Vector3f.new(nx, cur.y, z)) end)
    end

    -- Verstellschalter _05: [SWITCH-GRIP-LATCH] wie LE5 (re4_vr_motion.lua). Grip-FLANKE latcht NUR, wenn die
    -- linke Hand im Schalter-Radius (grab_dist) ist -> fällt sie nicht rein, passiert NICHTS. Gelatcht bleibt es
    -- bis Grip losgelassen -> zum Wechsel Schalter<->Schaft IMMER neu greifen. Schalter hat VORRANG vor dem Slide.
    -- Am Schalter gelatcht + Grip + Left-Trigger-FLANKE -> Stufe togglen (0<->1).
    local switch_st = { stage = 0, prog = 0.0, _prev_trig = false, _prev_grip = false, latched = false, preview = false }
    local function update_switch()
        if not rwep.switch_joint then _switch_hand = false; switch_st.latched = false; switch_st._prev_grip = false; return end
        local s = rswitch(rwep.wid or 0)
        if switch_st.preview then
            _switch_hand = true
        else
            local grip = left_grip_down()
            -- Schalter gesperrt solange der Slide gezogen werden muss (Schalter + Slide liegen zu nah beieinander).
            if grip and not switch_st._prev_grip and not rack.needs then  -- Grip-Druck-Flanke: latchen NUR wenn nah am Schalter UND kein Rack faellig
                local sjp = sc(rwep.switch_joint, "get_Position"); local hp = left_hand_world()
                local d = (sjp and hp) and math.sqrt((hp.x-sjp.x)^2 + (hp.y-sjp.y)^2 + (hp.z-sjp.z)^2) or 1e9
                switch_st.latched = d <= (s.grab_dist or 0.14)
            end
            if not grip or rack.needs then switch_st.latched = false end
            switch_st._prev_grip = grip
            _switch_hand = (grip and switch_st.latched) == true
            local trig = left_trigger_down()
            if _switch_hand and trig and not switch_st._prev_trig then
                switch_st.stage = 1 - switch_st.stage
                rf_snd(rsnd(rwep.wid, "switch"))
            end
            switch_st._prev_trig = trig
        end
        -- prog lerpt zur Ziel-Stufe; publiziert die Stufe (Gameplay-Effekt der 2 Stufen folgt separat)
        local target = switch_st.stage
        local L = s.lerp or 0.18
        if switch_st.prog < target then switch_st.prog = math.min(target, switch_st.prog + L)
        elseif switch_st.prog > target then switch_st.prog = math.max(target, switch_st.prog - L) end
        -- Stufe 0 (default) = normal feuern. Stufe 1 = Feuer gesperrt -> Dry-Fire (s. Fire-Block unten).
        _G.__vr_rifle_fire_mode = switch_st.stage
    end
    local function apply_switch()
        if not (rwep.switch_joint and rwep.switch_rest_rot) then return end
        local p = switch_st.prog or 0; if p <= 0.0001 then
            pcall(function() rwep.switch_joint:call("set_LocalRotation", rwep.switch_rest_rot) end); return end
        local s = rswitch(rwep.wid or 0)
        local q = quat_from_euler(s.rx * p, s.ry * p, s.rz * p)
        local nr = safe(function() return (rwep.switch_rest_rot * q):normalized() end)
        if nr then pcall(function() rwep.switch_joint:call("set_LocalRotation", nr) end) end
    end

    -- Mag-Mesh aus der Kammer halten solange das Mag draussen ist
    local _mag_hidden = false
    local function apply_mag_out_hidden()
        local should_hide = mag_out and rwep.mag_joint and not _flow()
        if should_hide then pcall(function() rwep.mag_joint:call("set_LocalScale", Vector3f.new(0, 0, 0)) end); _mag_hidden = true
        elseif _mag_hidden then if rwep.mag_joint then pcall(function() rwep.mag_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end) end; _mag_hidden = false end
    end

    -- Hand-Pose direkt anwenden (Mag-Halten / Slide-Rack / Verstellschalter) via EIGENE rf_pose_apply
    -- (reload2-eigene Pose-Daten, kein __re4_reload_apply_pose / kein gestures-Quer-Laden).
    local _hand_fade = {}
    local function apply_hand_pose()
        local name, thumb = nil, nil
        if mag_hand.active or mag_insert.active or mag_tune.active then
            name = RMAG_POSE[rwep.wid]; thumb = rmaghand(rwep.wid or 0)     -- 1) Mag in Hand
        elseif rack.dock_tune or (rack.needs and (rack.grab_active or _rack_near)) then
            name = RRACK_POSE[rwep.wid]                                     -- 2) Slide ziehen
            local sp = rslide(rwep.wid or 0); thumb = { t_rx = sp.st_rx, t_ry = sp.st_ry, t_rz = sp.st_rz }
        elseif _switch_hand or switch_st.preview then
            name = RSWITCH_POSE[rwep.wid]                                   -- 3) Verstellschalter (LE5-Switch-Pose)
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
    -- Holster-Wrapper (Rifle -> reload2, sonst weiter an die Revolver-/reload-Kette)
    -- =====================================================================
    local _orig2 = _G.__re4_reload_set_mag_in_hand
    _G.__re4_reload_set_mag_in_hand = function(active)
        if is_rifle(get_equip_wid()) then return rifle_set_mag_in_hand(active) end
        if _orig2 then return _orig2(active) end
        return false
    end

    -- =====================================================================
    -- Frame-Loop (laeuft NACH reload.lua + nach dem Revolver-on_frame -> gewinnt)
    -- =====================================================================
    -- Gemeinsamer interner Reset (Waffenwechsel / Save-Load / Script-Reset). Nur State, KEINE Globals.
    local function rifle_soft_reset()
        stop_drop(); mag_hand.active = false; mag_insert.active = false; mag_tune.active = false
        mag_out = false; mag_retained = 0
        rack.needs = false; rack.grab_active = false; rack.armed = false; rack.frac = 0
        rack.pulled = false; rack._chambered_hold = false; rack.dock_blend = 0
        rack.empty_when_dropped = false; rack._ammo_input_t = nil; rack.dock_tune = false; rack.tuning = false
        rack._zeroed_by_us = false   -- [ACCESSOR-FOLGE] Merker darf einen Wechsel/Reset nicht ueberleben
        switch_st.stage = 0; switch_st.prog = 0.0; switch_st._prev_trig = false; switch_st.preview = false
        switch_st.latched = false; switch_st._prev_grip = false; _switch_hand = false
    end

    local _rb_prev = false
    local _dry_prev = false
    local _prev_wid = nil
    re.on_frame(function()
        rf_refresh()
        if rwep.wid ~= _prev_wid then
            -- Waffenwechsel: internen Rifle-State IMMER abraeumen. War vorher eine Rifle managed
            -- und jetzt nicht mehr (z.B. Wechsel Rifle->Revolver/Messer, die reload.lua NICHT managed)
            -- -> auch die Rifle-Globals freigeben, sonst zieht ein stale Slide-Dock die linke Hand fehl.
            local was_rifle = (_prev_wid ~= nil)
            rifle_soft_reset()
            if was_rifle and not rwep.wid then
                _G.__vr_needs_rack = false; _G.__vr_slide_rack_active = false
                _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil
                _G.__vr_slide_dock_blend_factor = 0; _G.__vr_rack_hand_pose = nil; _G.__vr_mag_in_hand = false
                _G.__vr_burst_active = false
            end
            -- [SAVE_LOAD] Frisch ins/zurueck ins Rifle gewechselt -> evtl. stale Item-Cache raus
            -- (falls die Waffe beim Load kurz auf nil ging). reload.lua's Hook re-cached das frische Item.
            if rwep.wid then _G.__re4_live_wi = nil end
            _prev_wid = rwep.wid
        end
        if not rwep.wid then
            -- nicht-Rifle equippt: nichts publishen (Revolver/reload regeln ihre Faelle selbst)
            return
        end
        if _reacquired then
            -- [SAVE_LOAD] gleiche Waffe neu instanziiert (kein wid-Wechsel) -> stale Item-Cache + State
            -- abraeumen. Sonst liest die Ammo-Anzeige/der Reload-Write weiter das alte (0-Ammo) Item.
            -- Das Feuer-Gate selbst haengt eh an rack.empty (live), ist also schon davor sicher.
            _reacquired = false
            _G.__re4_live_wi = nil
            rifle_soft_reset()
        end
        rf_capture_mag_rest()
        check_insert_proximity()

        -- Binding faengt rechten B ab (manueller Reload statt nativem)
        _G.__vr_manual_reload_consume_b = true

        -- Slide/Empty-State pflegen
        local loaded = rf_loaded()
        rack.empty = gun_ammo_empty()
        rack.has_mag = (type(loaded) == "number" and loaded > 0)
        -- Nach-Rack-Halt beim Schuss loesen (nur falls genutzt; bei ENGINE_CLOSES nie aktiv)
        if rack._chambered_hold then
            local ga = loaded
            if rack._prev_ga and type(ga) == "number" and ga < rack._prev_ga then rack._chambered_hold = false end
            rack._prev_ga = ga
        end

        -- UI auf 0 halten solange Mag draussen (gegen Engine-Re-Sync), nicht waehrend des Inserts
        if mag_out and not mag_insert.active then
            local wi = rf_get_wi()
            if wi and (tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)) or 0) > 0 then
                _G.__re4_carry_capture(wi, "re4_vr_reload5_dlc.lua:984", nil)   -- [MAG-REST] merken, bevor genullt wird
                pcall(function() wi:write_dword(0x44, 0) end)
            end
        end

        -- Holster-Gate: nur SPERREN/buzzen wenn das Mag DRAUSSEN ist und es NICHTS zu laden gibt.
        -- Mag noch drin (mag_out=false) -> KEIN Buzz (man greift eh erst nach dem B-Eject; SMG-Verhalten).
        _G.__re4_reload_grab_empty = (mag_out and not mag_hand.active and not mag_insert.active
            and not (((mag_retained or 0) + rf_reserve()) > 0))

        update_rack_gesture()
        update_switch()
        -- [STAGGER_HEAL 2026-07-19] Stagger-Ende (fallende Flanke von __re4_damage_active, killswitch) ->
        -- Slide zu + fire-ready wie Waffenwechsel. clear_rack chambert + snappt slide_joint auf rest_z.

        -- Rack-Naehe fuer die Hand-Pose merken
        do
            local sj = rwep.slide_joint
            local hp = sj and left_hand_world(); local sp = sj and sc(sj, "get_Position")
            _rack_near = (hp and sp) and (math.sqrt((hp.x-sp.x)^2 + (hp.y-sp.y)^2 + (hp.z-sp.z)^2) <= RACK_GRAB_DIST) or false
        end
        -- (_switch_hand wird in update_switch per Grip-FLANKEN-Latch gesetzt, nicht mehr hier roh aus Naehe+Grip)

        -- Globals fuer motion/arm_chain/binding publishen
        _G.__vr_needs_rack          = rack.needs
        _G.__vr_slide_rack_active   = rack.grab_active == true
        _G.__vr_mag_in_hand         = (mag_hand.active or mag_insert.active
            or (rack._ammo_input_t and (os.clock() - rack._ammo_input_t) < 0.2)) and true or false
        _G.__vr_rack_hand_pose      = (rack.needs and (rack.grab_active or _rack_near)) and RRACK_POSE[rwep.wid] or nil
        -- [KRITISCHES GATE — LIVE] Feuer-Block NUR aus frischen Engine-Quellen, NIE aus gecachtem Ammo
        -- (rf_loaded geht ueber __re4_live_wi -> nach Save-Load stale 0 -> Dauer-Dry-Fire = gamebreaking).
        -- rack.empty = pe:isGunAmmoEmpty (jeden Frame frisch, kein Item-Cache). [[feedback-no-cached-state-for-critical-gates]]
        -- Zusaetzlich: Verstellschalter Stufe 1 sperrt das Feuern bewusst -> Dry-Fire (Stufe 0 feuert normal).
        _G.__vr_block_fire_when_empty = (rack.needs or mag_out or _flow() or rack.empty
            or (RSWITCH_BLOCKS_FIRE[rwep.wid] and switch_st.stage == 1)) and true or false
        _G.__re4_bf_who = "re4_vr_reload5_dlc.lua:983"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        -- [BURST] Schalter-Stufe 1 auf Burst-Waffen (CQBR) -> binding.lua feuert nur N Schuss pro Trigger-Zug.
        local _bn = RSWITCH_BURST[rwep.wid]
        if _bn and switch_st.stage == 1 then
            _G.__vr_burst_active = true; _G.__vr_burst_count = _bn
        else
            _G.__vr_burst_active = false
        end
        _G.__vr_rack_block_left_knife = rack.needs

        update_dock_publish(true)   -- Blend hier (on_frame) EINMAL pro Frame vorruecken

        -- Mag-Boden-Sound: beim Drop-Start geplant (s. rf_force_eject / rifle_set_mag_in_hand), hier feuern
        if _mag_floor_at > 0 and os.clock() >= _mag_floor_at then _mag_floor_at = 0; rf_snd(rsnd(rwep.wid, "mag_floor")) end

        -- Dry-Fire bei gesperrtem Trigger
        local et = rawget(_G, "__re4_empty_trigger_held") == true
        if et and not _dry_prev then rf_snd(rsnd(rwep.wid, "dry_fire")) end
        _dry_prev = et

        -- B-Flanke -> Mag-Auswurf
        local bd = right_b_down()
        if bd and not _rb_prev then rf_force_eject() end
        _rb_prev = bd

    end)

    -- =====================================================================
    -- Render-Pass (voller Override-Stack; NACH reload.lua + Revolver -> gewinnt)
    -- =====================================================================
    local function rifle_apply_pass()
        if not (RCFG.rifle_enabled and rwep.wid) then return end
        update_drop()
        update_mag_in_hand()
        update_insert()
        apply_slide_park()
        apply_mag_out_hidden()
        apply_switch()
        update_dock_publish(false)   -- Render-Pass: nur frisch re-publishen, Blend NICHT nochmal vorruecken (kein Snap)
        apply_hand_pose()
    end
    pcall(function() re.on_pre_application_entry("LockScene", rifle_apply_pass) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", rifle_apply_pass) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", rifle_apply_pass) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", rifle_apply_pass) end)

    -- =====================================================================
    -- Reset (Waffenwechsel/Script-Reset)
    -- =====================================================================
    re.on_script_reset(function()
        -- Joints in Ruhe zuruecksetzen, solange wir die echte Ruhe noch kennen
        if rwep.switch_joint and rwep.switch_rest_rot then pcall(function() rwep.switch_joint:call("set_LocalRotation", rwep.switch_rest_rot) end) end
        if rwep.mag_joint then pcall(function() rwep.mag_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end) end
        rwep.wid, rwep.tf, rwep.mag_joint, rwep.slide_joint, rwep.switch_joint, rwep.switch_rest_rot = nil, nil, nil, nil, nil, nil
        rifle_soft_reset()
        _G.__vr_needs_rack = false; _G.__vr_slide_rack_active = false
        _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil; _G.__vr_slide_dock_blend_factor = 0
        _G.__vr_rack_hand_pose = nil
    end)

    -- =====================================================================
    -- UI
    -- =====================================================================
    -- Rifle-UI als Funktion: wird vom gemeinsamen "RE4 VR — Manual Reload 2"-Header
    -- (Revolver-Block unten) aufgerufen -> EIN Menue-Eintrag, Gattungen darin
    -- gestapelt wie in reload.lua. Kein eigener collapsing_header mehr.
    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion local function rifle_ui_body (103 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.

    -- [EIN HAUPTTREE 2026-07-19] Kein eigener Top-Level-Baum pro Gattung: beide Langwaffen
    -- haengen unter EINEM Haupttree ganz unten im File. Hier nur den Body veroeffentlichen.
    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion Global-Zuweisung (1 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end

-- =====================================================================
-- ZWEITE GATTUNG IM SELBEN FILE: HUNTING RIFLE (wp6114, Bolt-Action)
-- =====================================================================
-- [ZUSAMMENGELEGT 2026-07-19] War re4_vr_reload7_dlc.lua -- eine eigene Datei pro Waffe
-- ist unnoetig. Eigener do...end-Block: die ~Locals werden am Blockende wieder freigegeben
-- (Lua-200-Limit bleibt niedrig), die re.on_*-Closures leben ueber ihre Upvalues weiter.
-- Persistenz bleibt getrennt: re4_vr_reload7_dlc.json. Eigener UI-Baum, kein reload2-Hook.
-- Die Helfer oben (safe/sc/sf/quat_from_euler/get_ctx/get_equip_wid/body_tf/get_pe/find_weapon)
-- werden mitbenutzt -- sie sind identisch zu denen, die reload7 hatte.

do
    -- [NULLLAGE 2026-08-12] Einmal gemerkte Bolt-Ruhelage pro Waffe (gegen Stagger-Drift).
    local BOLT_REST_LP5 = {}
    local BOLTS = { [6114] = true }   -- [DLC] wp6114 Hunting Rifle (= Leons SR M1903 4400)
    local function is_bolt(wid) return wid ~= nil and BOLTS[wid] == true end
    local function ease(t) return t * t * (3.0 - 2.0 * t) end
    local function clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 else return v end end

    -- ---- Joints (CODE-Konstanten) ----
    local BJOINTS = { [6114] = { bolt = "_01", cart = "_10" } }

    -- ---- Per-Waffe Tuning (JSON-persistiert; rest_rot/rest_lp werden LIVE gecaptured) ----
    local BCFG_DEF = {
        -- Bolt-Bewegung
        back_off = -0.060,         -- Z-Versatz (lokal) bei voll zurueckgezogenem Bolt
        travel   = 0.12,           -- Hand-Pull-Distanz (m) fuer voll zurueck
        open_lerp= 0.15,           -- Roll-Dreh-Geschwindigkeit (pro Frame)
        brx = 0.0, bry = 0.0, brz = -70.0,   -- Roll-Winkel (Grad) bei voll offen (default roll links)
        grab_dist= 0.16,           -- Greif-Radius am Bolt
        -- Hand-Dock am Bolt (TMPSUpport)
        dock_x = 0.0, dock_y = 0.0, dock_z = 0.0,
        hrx = 0.0, hry = 0.0, hrz = 0.0,
        -- Patrone in Hand (Shotgunshell) — joint_10 folgt der linken Hand
        cx = 0.0, cy = 0.0, cz = 0.0,
        crx = 0.0, cry = 0.0, crz = 0.0,
        t_rx = 0.0, t_ry = 0.0, t_rz = 0.0,   -- Daumen-Spreizung (additiv)
        -- Kammer-Dock (Einlege-Naehe): Gun-Joint + Offset
        cd_joint = "_01", cd_x = 0.0, cd_y = 0.0, cd_z = 0.05,
    }
    local BCFG_WID = { [6114] = {} }
    local function bcfg(wid)
        local c = BCFG_WID[wid]; if not c then c = {}; BCFG_WID[wid] = c end
        for k, v in pairs(BCFG_DEF) do if c[k] == nil then c[k] = v end end
        return c
    end

    -- ---- Hand-Posen (eigene Daten-Kopie, aus gestures.json gebacken; gestures wird geloescht) ----
    local BPOSES = {
        ["TMPSUpport"] = { hand="left", bones = { ["L_IndexF1"]={0.804279,-0.055429,-0.040679,-0.590261}, ["L_IndexF2"]={0.788875,0,0,-0.614554}, ["L_IndexF3"]={0.922189,0,0,-0.386738}, ["L_MiddleF1"]={0.797521,-0.117887,-0.086517,-0.585302}, ["L_MiddleF2"]={0.788875,0,0,-0.614554}, ["L_MiddleF3"]={0.922189,0,0,-0.386738}, ["L_Palm"]={1,0,0,0}, ["L_PinkyF1"]={0.840226,-0.199592,-0.116520,-0.490516}, ["L_PinkyF2"]={0.931932,0,0,-0.362634}, ["L_PinkyF3"]={0.814746,0,0,-0.579818}, ["L_RingF1"]={0.796371,-0.132487,-0.096843,-0.582119}, ["L_RingF2"]={0.843908,0,0,-0.536488}, ["L_RingF3"]={0.843411,0,0,-0.537269}, ["L_Thumb1"]={0.949122,0.196826,-0.043902,-0.241868}, ["L_Thumb2"]={0.996365,0,-0.085182,0}, ["L_Thumb3"]={0.941245,0,0.337725,0} } },
        ["Shotgunshell"] = { hand="left", bones = { ["L_IndexF1"]={0.986822,0.041360,0.006551,-0.156297}, ["L_IndexF2"]={0.800622,0,0,-0.599170}, ["L_IndexF3"]={0.970822,0,0,-0.239802}, ["L_MiddleF1"]={0.973517,-0.022758,0.004124,-0.227444}, ["L_MiddleF2"]={0.752896,0,0,-0.658139}, ["L_MiddleF3"]={0.949174,0,0,-0.314753}, ["L_Palm"]={1,0,0,0}, ["L_PinkyF1"]={0.900387,-0.062961,-0.030031,-0.429462}, ["L_PinkyF2"]={0.861629,0,0,-0.507538}, ["L_PinkyF3"]={0.934950,0,0,-0.354780}, ["L_RingF1"]={0.939326,-0.026238,-0.009550,-0.341887}, ["L_RingF2"]={0.819152,0,0,-0.573577}, ["L_RingF3"]={0.921309,0,0,-0.388830}, ["L_Thumb1"]={0.991438,0.108579,-0.021318,-0.069329}, ["L_Thumb2"]={0.935394,0,-0.353608,0}, ["L_Thumb3"]={0.998456,0,-0.055552,0} } },
        ["RiotSLide"] = { hand="left", bones = { ["L_IndexF1"]={0.986822,0.041360,0.006551,-0.156297}, ["L_IndexF2"]={0.800622,0,0,-0.599170}, ["L_IndexF3"]={0.976009,0,0,-0.217732}, ["L_MiddleF1"]={0.924938,-0.023124,0.000451,-0.379414}, ["L_MiddleF2"]={0.833468,0,0,-0.552567}, ["L_MiddleF3"]={0.957340,0,0,-0.288964}, ["L_Palm"]={1,0,0,0}, ["L_PinkyF1"]={0.864541,-0.060455,-0.034802,-0.497697}, ["L_PinkyF2"]={0.905133,0,0,-0.425128}, ["L_PinkyF3"]={0.935618,0,0,-0.353014}, ["L_RingF1"]={0.877944,-0.024523,-0.013350,-0.477948}, ["L_RingF2"]={0.893334,0,0,-0.449392}, ["L_RingF3"]={0.933580,0,0,-0.358368}, ["L_Thumb1"]={0.991438,0.108579,-0.021318,-0.069329}, ["L_Thumb2"]={0.935394,0,-0.353608,0}, ["L_Thumb3"]={1.0,0,-0.000215,0} } },
    }
    local _bpmap, _bpmap_tf = {}, nil
    local function bpose_map()
        local tf = body_tf(); if not tf then return {} end
        if tf == _bpmap_tf and next(_bpmap) ~= nil then return _bpmap end
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
        _bpmap_tf, _bpmap = tf, map
        return map
    end
    local function bpose_apply(name)
        local pose = name and BPOSES[name]; if not (pose and pose.bones) then return false end
        local map = bpose_map(); if next(map) == nil then return false end
        for bone, v in pairs(pose.bones) do
            local j = map[bone]
            if j and v and v[1] then pcall(function() j:call("set_LocalRotation", Quaternion.new(v[1], v[2], v[3], v[4])) end) end
        end
        return true
    end

    -- ---- Sounds (von der Stingray geseedet; ggf. echte Bolt-IDs nachziehen) ----
    local BSND = { [6114] = { bolt_open = 3388506884, bolt_close = 3505191890,
                              cart_grab = 1839787494, insert = 403849506, cart_floor = 1302378315,
                              dry_fire = 812850326 } }
    local snd_td2 = sdk.typeof("soundlib.SoundContainer")

    -- ---- skalare Config + Persistenz ----
    local BCFG = { bolt_enabled = true, reload_ammo = true, sound_enabled = true, insert_distance = 0.15 }
    local BCFG_PATH = "re4_vr/re4_vr_reload5_dlc_bolt.json"
    local BFIELDS = { "back_off","travel","open_lerp","brx","bry","brz","grab_dist",
                      "dock_x","dock_y","dock_z","hrx","hry","hrz",
                      "cx","cy","cz","crx","cry","crz","t_rx","t_ry","t_rz",
                      "cd_x","cd_y","cd_z" }
    local function bload_cfg()
        local data = safe(function() return json.load_file(BCFG_PATH) end)
        if type(data) ~= "table" then return end
        local c = data.cfg or {}
        if type(c.bolt_enabled)   == "boolean" then BCFG.bolt_enabled   = c.bolt_enabled   end
        if type(c.reload_ammo)    == "boolean" then BCFG.reload_ammo    = c.reload_ammo    end
        if type(c.sound_enabled)  == "boolean" then BCFG.sound_enabled  = c.sound_enabled  end
        if type(c.insert_distance)== "number"  then BCFG.insert_distance= c.insert_distance end
        if type(data.tune) == "table" then
            for k, v in pairs(data.tune) do local wid = tonumber(k)
                if wid and type(v) == "table" then local cc = bcfg(wid)
                    for _, f in ipairs(BFIELDS) do if type(v[f]) == "number" then cc[f] = v[f] end end
                    if type(v.cd_joint) == "string" then cc.cd_joint = v.cd_joint end end end
        end
    end
    local function bsave_cfg()
        local tune = {}
        for wid in pairs(BOLTS) do
            local cc = bcfg(wid); local o = {}
            for _, f in ipairs(BFIELDS) do o[f] = cc[f] end
            o.cd_joint = cc.cd_joint
            tune[tostring(wid)] = o
        end
        pcall(function() json.dump_file(BCFG_PATH, { cfg = BCFG, tune = tune }) end)
    end
    bload_cfg()

    -- ---- Live-Weapon-Item + Ammo (eigene Helfer; gegen die EQUIPPTE wid validiert) ----
    local function bget_wi()
        local ewid = get_equip_wid()
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
    local function bloaded() local wi = bget_wi(); return wi and tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)) end
    local function bcap()    local wi = bget_wi(); return wi and tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0 end
    local function breserve()
        local wi = bget_wi(); if not wi then return 0 end
        local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end); if not ammo_id then return 0 end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController"); if not inv then return 0 end
        return tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0
    end

    -- ---- chainsaw.Gun (Leer-Erkennung + Chambern), 1:1 wie die Stingray ----
    local _bstate_td = sdk.find_type_definition("chainsaw.Gun.State")
    local _bgun_holding = _bstate_td and safe(function() return _bstate_td:get_field("Holding"):get_data(nil) end)
    local function bget_gun()
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
    local function bolt_chamber()
        local g = bget_gun(); if not (g and _bgun_holding ~= nil) then return end
        pcall(function() g:call("set_CurrentState(chainsaw.Gun.State)", _bgun_holding) end)
    end
    local function bammo_empty()
        local pe = get_pe()
        return (pe and safe(function() return pe:call("isGunAmmoEmpty") end)) == true
    end

    -- ---- VR-Input ----
    local function left_grip_down()
        if not vrmod then return false end
        local act, lj
        pcall(function() act = vrmod:get_action_grip() end)
        pcall(function() lj  = vrmod:get_left_joystick() end)
        if not (act and lj) then return false end
        local ok, v = pcall(function() return vrmod:is_action_active(act, lj) end)
        return ok and v == true
    end
    local _bolt_lj = nil
    local function bolt_haptic(amp, dur)
        if not vrmod then return end
        if not _bolt_lj then pcall(function() _bolt_lj = vrmod:get_left_joystick() end) end
        if _bolt_lj then pcall(function() vrmod:trigger_haptic_vibration(0.0, dur or 0.06, 169.385, amp or 0.9, _bolt_lj) end) end
    end
    local function left_hand_world()
        local hp = rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
        if hp then return hp end
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        return lh and sc(lh, "get_Position")
    end

    -- ---- Waffen-/Joint-Acquire ----
    local bwep = { wid = nil, tf = nil, bolt_joint = nil, cart_joint = nil,
                   bolt_rest_rot = nil, bolt_rest_lp = nil, cart_rest_lp = nil, cart_rest_lr = nil }
    local _breacquired = false
    local function bsnd(key)
        if not BCFG.sound_enabled then return end
        local t = bwep.wid and BSND[bwep.wid]; local id = t and t[key]
        if not (id and id > 0) then return end
        local tf = bwep.tf; if not (tf and snd_td2) then return end
        local go = safe(function() return tf:call("get_GameObject") end); if not go then return end
        local scn = safe(function() return go:call("getComponent(System.Type)", snd_td2) end); if not scn then return end
        pcall(function() scn:call("trigger(System.UInt32)", id) end)
    end
    local function bmanaged_wid()
        if not BCFG.bolt_enabled then return nil end
        local wid = get_equip_wid()
        if not is_bolt(wid) then return nil end
        return wid
    end
    local function bolt_refresh()
        local wid = bmanaged_wid()
        if not wid then
            bwep.wid, bwep.tf, bwep.bolt_joint, bwep.cart_joint, bwep.bolt_rest_rot = nil, nil, nil, nil, nil
            return
        end
        if bwep.wid == wid and bwep.bolt_joint and bwep.tf and safe(function() return bwep.tf:call("get_Position") end) then return end
        local same_wid = (bwep.wid == wid)
        bwep.wid, bwep.tf, bwep.bolt_joint, bwep.cart_joint, bwep.bolt_rest_rot = nil, nil, nil, nil, nil
        local jc = BJOINTS[wid]; if not (jc and jc.bolt) then return end
        local go, tf = find_weapon(wid); if not tf then return end
        local bj = sc(tf, "getJointByName", jc.bolt); if not bj then return end
        bwep.wid, bwep.tf, bwep.bolt_joint = wid, tf, bj
        bwep.cart_joint = (jc.cart and jc.cart ~= "") and sc(tf, "getJointByName", jc.cart) or nil
        bwep.bolt_rest_rot = sc(bj, "get_LocalRotation")
        -- [NULLLAGE 2026-08-12] Wie in reload2: pro Waffe EINMAL merken. Wird sie bei jedem Neu-
        -- Greifen frisch gemessen, faengt ein Stagger die zurueckgezogene Stellung als Ruhe ein und
        -- der Bolt wandert mit jedem Ereignis weiter nach hinten.
        local lp = sc(bj, "get_LocalPosition")
        if BOLT_REST_LP5[wid] then bwep.bolt_rest_lp = { x = BOLT_REST_LP5[wid].x, y = BOLT_REST_LP5[wid].y, z = BOLT_REST_LP5[wid].z }
        elseif lp then BOLT_REST_LP5[wid] = { x = lp.x, y = lp.y, z = lp.z }; bwep.bolt_rest_lp = { x = lp.x, y = lp.y, z = lp.z } end
        if same_wid then _breacquired = true end
    end

    -- ---- State ----
    local bolt = { open = false, grab = false, armed = false, mode = "open", locked = false,
                   roll = 0.0, zf = 0.0, troll = 0.0, tzf = 0.0, gx = 0, gy = 0, gz = 0, zf_anchor = 0.0,
                   dock_blend = 0.0, preview = false, preview_open = false }
    local cart = { active = false, insert = false, t0 = 0, dur = 0.18, slp = nil, slr = nil, tune = false }

    local function bolt_capture_cart_rest()
        if not bwep.cart_joint then return end
        if cart.active or cart.insert or cart.tune then return end
        local lp = sc(bwep.cart_joint, "get_LocalPosition")
        local lr = sc(bwep.cart_joint, "get_LocalRotation")
        if lp then bwep.cart_rest_lp = { x = lp.x, y = lp.y, z = lp.z } end
        if lr then bwep.cart_rest_lr = { w = lr.w, x = lr.x, y = lr.y, z = lr.z } end
    end

    -- ---- Settle: roll/zf sanft zu troll/tzf lerpen (Snap-frei) ----
    local function bolt_settle_step(c)
        local sp = (c.open_lerp or 0.35)
        if bolt.roll ~= bolt.troll then
            if bolt.roll < bolt.troll then bolt.roll = math.min(bolt.troll, bolt.roll + sp)
            else bolt.roll = math.max(bolt.troll, bolt.roll - sp) end
        end
        if bolt.zf ~= bolt.tzf then
            if bolt.zf < bolt.tzf then bolt.zf = math.min(bolt.tzf, bolt.zf + sp)
            else bolt.zf = math.max(bolt.tzf, bolt.zf - sp) end
        end
    end

    -- ---- Bolt-Gesten (Oeffnen: roll dann Z; Schliessen: Z dann roll) ----
    -- EIN Griff = EINE Transition: ist offen/zu erreicht -> locked, weitere
    -- Bewegung im selben Griff ignoriert (kein Z-Wiggle ohne Rotation). Un-
    -- vollstaendiges Loslassen lerpt sanft in die Ausgangslage der Geste zurueck.
    local function update_bolt_gesture()
        if bolt.preview then return end
        local c = bcfg(bwep.wid or 6114)
        local bj = bwep.bolt_joint; if not bj then bolt.grab = false; bolt_settle_step(c); return end
        local hp = left_hand_world(); local sp = sc(bj, "get_Position")
        local grip = left_grip_down()
        if not (hp and sp) then bolt_settle_step(c); return end
        local dist = math.sqrt((hp.x-sp.x)^2 + (hp.y-sp.y)^2 + (hp.z-sp.z)^2)
        if not bolt.grab then
            bolt_settle_step(c)                                     -- nicht gegriffen -> ggf. zuruecklerpen
            if cart.active or cart.insert then bolt.armed = false; return end
            if not grip then bolt.armed = true; return end          -- Grip erst loslassen -> scharf
            if not bolt.armed then return end
            if dist <= (c.grab_dist or 0.16) then
                bolt.grab = true; bolt.armed = false; bolt.locked = false
                bolt.gx, bolt.gy, bolt.gz = hp.x, hp.y, hp.z
                -- [STAGGER 2026-08-12] Zweiter Anker: die Waffenhand (siehe reload2).
                do local _r = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
                    bolt.rgx, bolt.rgy, bolt.rgz = _r and _r.x or nil, _r and _r.y or nil, _r and _r.z or nil end
                bolt.zf_anchor = bolt.zf
                bolt.troll, bolt.tzf = bolt.roll, bolt.zf
                bolt.mode = bolt.open and "close" or "open"
                bolt_haptic(0.25, 0.03)
            end
            return
        end
        if grip then
            if bolt.locked then
                bolt_settle_step(c)                                  -- Transition fertig -> sanft aufs Ziel lerpen
                -- [ONE_GRAB_CYCLE] Kein Re-Grab noetig: nach dem Auf-Lock kurz EINRASTEN (0.5s -- verhindert das
                -- "Gummistange"-Gefuehl), dann im SELBEN Griff auf "close" umschalten (Anker = aktuelle Hand) ->
                -- Zurueckdruecken schliesst direkt. Nur Auf->Zu; Zu bleibt gelockt bis Grip-Release (wie bisher).
                if bolt.open and bolt.mode == "open" and (os.clock() - (bolt.lock_t or 0)) >= 0.12 then   -- [2026-07-19] Einrast 0.5->0.3s
                    bolt.locked = false; bolt.mode = "close"
                    bolt.gx, bolt.gy, bolt.gz = hp.x, hp.y, hp.z
                    -- [STAGGER 2026-08-12] Zweiter Anker: die Waffenhand (siehe reload2).
                    do local _r = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
                        bolt.rgx, bolt.rgy, bolt.rgz = _r and _r.x or nil, _r and _r.y or nil, _r and _r.z or nil end
                    bolt.zf_anchor = bolt.zf; bolt.troll, bolt.tzf = bolt.roll, bolt.zf
                    bolt_haptic(0.35, 0.03)                          -- Einrast-Klick
                end
                return
            end
            local travel = math.max(c.travel or 0.075, 0.01)
            local px, py, pz = hp.x - bolt.gx, hp.y - bolt.gy, hp.z - bolt.gz
            -- [STAGGER 2026-08-12] Bewegung der Waffenhand abziehen. Rueckbau: _G.__re4_rack_relative = false
            if bolt.rgx and rawget(_G, "__re4_rack_relative") ~= false then
                local _rn = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
                if _rn then px = px - (_rn.x - bolt.rgx); py = py - (_rn.y - bolt.rgy); pz = pz - (_rn.z - bolt.rgz) end
            end
            local brot = sc(bj, "get_Rotation")
            local bd = brot and safe(function() return brot * Vector3f.new(0, 0, -1) end)
            local pull
            if bd then
                local bl = math.sqrt(bd.x*bd.x + bd.y*bd.y + bd.z*bd.z)
                if bl > 1e-6 then bd = Vector3f.new(bd.x/bl, bd.y/bl, bd.z/bl) end
                pull = px*bd.x + py*bd.y + pz*bd.z
            else pull = pz end
            if bolt.mode == "open" then
                if bolt.roll < 1.0 then bolt.roll = math.min(1.0, bolt.roll + (c.open_lerp or 0.35)) end
                if bolt.roll >= 0.999 then bolt.zf = clamp01(bolt.zf_anchor + pull / travel) end
                if bolt.roll >= 0.999 and bolt.zf >= 0.6 then       -- weit genug offen -> lock (Rest lerpt voll auf)
                    bolt.open = true; bolt.locked = true
                    bolt.lock_t = os.clock()                        -- [ONE_GRAB_CYCLE] Einrast-Start (Auf->Zu ohne Re-Grab)
                    bolt.troll, bolt.tzf = 1.0, 1.0                  -- Settle zieht roll/zf sanft auf 1.0
                    bolt_haptic(0.6, 0.05); bsnd("bolt_open")
                end
            else
                bolt.zf = clamp01(bolt.zf_anchor + pull / travel)
                if bolt.zf <= 0.001 and bolt.roll > 0.0 then bolt.roll = math.max(0.0, bolt.roll - (c.open_lerp or 0.35)) end
                if bolt.zf <= 0.001 and bolt.roll <= 0.001 then     -- voll zu -> lock + chamber
                    bolt.open = false; bolt.locked = true
                    bolt.roll, bolt.zf, bolt.troll, bolt.tzf = 0.0, 0.0, 0.0, 0.0
                    bolt.needs_cycle = false                        -- [MANUAL_CYCLE] Bolt durchgezogen -> Feuer frei
                    bolt_chamber(); bolt_haptic(0.85, 0.06); bsnd("bolt_close")
                end
            end
            if not bolt.locked then bolt.troll, bolt.tzf = bolt.roll, bolt.zf end   -- waehrend aktivem Zug folgt Ziel der Hand; NICHT nach Lock (sonst klobbert es das 1.0-Ziel)
            return
        end
        -- Grip losgelassen
        bolt.grab = false; bolt.armed = true
        if bolt.locked then
            bolt.locked = false                                     -- Transition bestaetigt, schon am Ziel
        else                                                        -- unvollstaendig -> sanft zur Geste-Startlage zurueck
            if bolt.mode == "open" then bolt.open = false; bolt.troll, bolt.tzf = 0.0, 0.0
            else bolt.open = true; bolt.troll, bolt.tzf = 1.0, 1.0 end
        end
    end

    -- ---- Bolt-Joint treiben (nur wenn aktiv -> Engine-Auto-Cycle sonst in Ruhe) ----
    local function apply_bolt_joint()
        local bj = bwep.bolt_joint; if not bj then return end
        local active = bolt.grab or bolt.open or bolt.preview or cart.active or cart.insert
        -- [MANUAL_CYCLE] needs_cycle (nach Schuss, noch nicht durchgezogen) -> _01 NICHT der Engine ueberlassen,
        -- sondern unten auf Zu-Ruhe (roll/zf=0) zwingen -> native PumpAction (Ghost-Bolt) unterdrueckt.
        if not active and bolt.roll <= 0.001 and bolt.zf <= 0.001 and not bolt.needs_cycle then return end
        local c = bcfg(bwep.wid or 6114)
        local roll = bolt.preview and (bolt.preview_open and 1.0 or 0.0) or bolt.roll
        local zf   = bolt.preview and (bolt.preview_open and 1.0 or 0.0) or bolt.zf
        if bwep.bolt_rest_rot then
            local q = quat_from_euler(c.brx * roll, c.bry * roll, c.brz * roll)
            local nr = safe(function() return (bwep.bolt_rest_rot * q):normalized() end)
            if nr then pcall(function() bj:call("set_LocalRotation", nr) end) end
        end
        if bwep.bolt_rest_lp then
            local rp = bwep.bolt_rest_lp
            pcall(function() bj:call("set_LocalPosition", Vector3f.new(rp.x, rp.y, rp.z + (c.back_off or 0) * zf)) end)
        end
    end

    -- ---- Hand folgt dem Bolt (Dock-Publish; arm_chain liest die Globals) ----
    local DOCK_BLEND_SPEED = 0.10
    local function update_bolt_dock(advance)
        local src, ox, oy, oz, rrx, rry, rrz
        local want = 0.0
        if (bolt.grab or bolt.preview) and bwep.bolt_joint then
            local c = bcfg(bwep.wid or 6114)
            src = bwep.bolt_joint
            ox, oy, oz = c.dock_x, c.dock_y, c.dock_z
            rrx, rry, rrz = c.hrx, c.hry, c.hrz
            want = 1.0
        end
        local b = bolt.dock_blend or 0
        if advance then
            if b < want then b = math.min(b + DOCK_BLEND_SPEED, want) elseif b > want then b = math.max(b - DOCK_BLEND_SPEED, want) end
            bolt.dock_blend = b
        end
        if b > 0.001 and src then
            local p = sc(src, "get_Position"); local r = sc(src, "get_Rotation")
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

    -- ---- Patrone in Hand (joint_10 folgt der linken Hand) ----
    local function update_cart_in_hand()
        local cj = (cart.active or cart.tune) and bwep.cart_joint or nil
        if not cj then return end
        local c = bcfg(bwep.wid or 6114)
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position"); if not hp then return end
        local hr = lh and sc(lh, "get_Rotation")
        local wx, wy, wz = hp.x, hp.y, hp.z
        if hr then
            local off = safe(function() return hr * Vector3f.new(c.cx, c.cy, c.cz) end)
            if off then wx, wy, wz = hp.x + off.x, hp.y + off.y, hp.z + off.z end
        end
        pcall(function() cj:call("set_Position", Vector3f.new(wx, wy, wz)) end)
        if hr then
            local rot = safe(function() return (hr * quat_from_euler(c.crx, c.cry, c.crz)):normalized() end)
            if rot then pcall(function() cj:call("set_Rotation", rot) end) end
        end
        pcall(function() cj:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
    end

    -- ---- Kammer-Dock-Welt (Einlege-Naehe) ----
    local function chamber_world()
        if not bwep.tf then return nil end
        local c = bcfg(bwep.wid or 6114)
        local j = sc(bwep.tf, "getJointByName", c.cd_joint or "_01"); if not j then return nil end
        local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation"); if not (jp and jr) then return nil end
        local off = safe(function() return jr * Vector3f.new(c.cd_x, c.cd_y, c.cd_z) end); if not off then return jp end
        return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
    end

    -- +1 laden: write_dword(0x44)/addAmmoCount werden bei wp4400 von der Engine RE-SYNCT (Dump: Item-Feld
    -- ging 7->8 direkt nach dem Write, aber getCurrentGunAmmo blieb 7 -> eine Frame spaeter zurueckgesetzt,
    -- HUD lud nie). Einziger Pfad der WIRKLICH laedt = ENGINE-Reload inv:reload(EquipType.Main, 1, false),
    -- additiv +1 (wie r9_add_single / Armbrust xadd_one). Reserve zieht die Engine selbst -> KEIN 0x44, KEIN
    -- manueller Abzug. Hinweis: inv:reload ist VERZOEGERT -> getCurrentGunAmmo direkt danach kann noch alt sein.
    local _bet_main = nil
    local function bequip_type_main()
        if _bet_main ~= nil then return _bet_main end
        local td = sdk.find_type_definition("chainsaw.EquipType"); local f = td and td:get_field("Main")
        if f then _bet_main = f:get_data(nil) end
        return _bet_main
    end
    local function bolt_add_one()
        local dbg = { reload_ammo = BCFG.reload_ammo }
        local function BDUMP(s) dbg.result = s end   -- [LOG ENTFERNT 2026-07-24] Debug-Datei-Dump raus (re4_vr_reload5_dlc_boltdbg.json); No-Op, Aufrufe unveraendert
        if not BCFG.reload_ammo then BDUMP("bail:reload_ammo_off"); return end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        dbg.has_inv = (inv ~= nil); if not inv then BDUMP("bail:no_inv"); return end
        local wi = bget_wi(); dbg.has_wi = (wi ~= nil)
        local loaded = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or 0
        local cap = wi and (tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0) or 0
        dbg.loaded, dbg.cap = loaded, cap
        if cap > 0 and loaded >= cap then BDUMP("bail:full"); return end
        local ammo_id = wi and safe(function() return wi:call("get_CurrentAmmo") end)
        dbg.ammo_id = tostring(ammo_id)
        local reserve = ammo_id and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
        dbg.reserve = reserve
        if reserve <= 0 then BDUMP("bail:no_reserve"); return end
        local et = bequip_type_main()
        if et and _G.__re4_safe_inv_reload then _G.__re4_load_and_book(inv, et, 1, false) end   -- [CRASH-HARDEN] enableReloadItem-Gate gegen null-Item-AV
        local loaded_af = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or loaded
        dbg.loaded_after = loaded_af
        BDUMP(loaded_af > loaded and "success" or "engine_reload_delayed")
    end

    -- ---- Patrone-Einlegen (joint_10 von Hand-Lokalpose zurueck in die Kammer-Ruhe) ----
    local function start_cart_insert()
        local cj = bwep.cart_joint; if not (cj and bwep.cart_rest_lp) then return false end
        local lp = sc(cj, "get_LocalPosition"); local lr = sc(cj, "get_LocalRotation")
        cart.slp = lp and { x = lp.x, y = lp.y, z = lp.z } or nil
        cart.slr = lr and { w = lr.w, x = lr.x, y = lr.y, z = lr.z } or nil
        cart.t0 = os.clock(); cart.insert = true; cart.active = false; cart.snd = false
        return true
    end
    local function bolt_check_insert_proximity()
        if not cart.active then return end
        local hp = left_hand_world(); if not hp then return end
        local gp = chamber_world(); if not gp then return end
        local d = math.sqrt((hp.x-gp.x)^2 + (hp.y-gp.y)^2 + (hp.z-gp.z)^2)
        if d <= (BCFG.insert_distance or 0.15) then start_cart_insert() end
    end
    local function update_cart_insert()
        if not (cart.insert and bwep.cart_joint and cart.slp and bwep.cart_rest_lp) then return end
        local t = (os.clock() - cart.t0) / math.max(cart.dur, 0.01); if t > 1.0 then t = 1.0 end
        if not cart.snd and t >= 0.6 then cart.snd = true; bsnd("insert") end
        local u = ease(t)
        local a, b2 = cart.slp, bwep.cart_rest_lp
        pcall(function() bwep.cart_joint:call("set_LocalPosition", Vector3f.new(a.x+(b2.x-a.x)*u, a.y+(b2.y-a.y)*u, a.z+(b2.z-a.z)*u)) end)
        if cart.slr and bwep.cart_rest_lr then
            local s, r = cart.slr, bwep.cart_rest_lr
            local rw, rx, ry, rz = r.w, r.x, r.y, r.z
            if (s.w*rw + s.x*rx + s.y*ry + s.z*rz) < 0 then rw, rx, ry, rz = -rw, -rx, -ry, -rz end
            local w, x, y, z = s.w+(rw-s.w)*u, s.x+(rx-s.x)*u, s.y+(ry-s.y)*u, s.z+(rz-s.z)*u
            local len = math.sqrt(w*w+x*x+y*y+z*z)
            if len > 1e-6 then pcall(function() bwep.cart_joint:call("set_LocalRotation", Quaternion.new(w/len, x/len, y/len, z/len)) end) end
        end
        if t >= 1.0 then cart.insert = false; bolt_add_one() end
    end

    -- ---- Holster-Grab -> Patrone in die linke Hand (nur bei offenem Bolt + ladbar) ----
    local function bolt_can_load()
        if cart.active or cart.insert then return false end
        if not bolt.open then return false end
        return (bloaded() or 0) < bcap() and breserve() > 0
    end
    local function bolt_set_cart_in_hand(active)
        if active then
            if not bolt_can_load() then return false end
            cart.active = true; bsnd("cart_grab"); return true
        end
        if cart.active then
            cart.active = false
            bsnd("cart_floor")                          -- aus der Hand gelassen ohne Einstecken -> faellt zu Boden
            -- geliehene Patrone zurueck in die Kammer-Ruhe (kein Drop, Einzelpatrone)
            if bwep.cart_joint and bwep.cart_rest_lp then
                pcall(function() bwep.cart_joint:call("set_LocalPosition", Vector3f.new(bwep.cart_rest_lp.x, bwep.cart_rest_lp.y, bwep.cart_rest_lp.z)) end)
                if bwep.cart_rest_lr then pcall(function() bwep.cart_joint:call("set_LocalRotation", Quaternion.new(bwep.cart_rest_lr.w, bwep.cart_rest_lr.x, bwep.cart_rest_lr.y, bwep.cart_rest_lr.z)) end) end
            end
        end
        return true
    end

    -- ---- Hand-Pose (Default RiotSLide / Bolt TMPSUpport / Patrone Shotgunshell) ----
    local function apply_bolt_pose()
        local name, thumb = "RiotSLide", nil
        if cart.active or cart.insert or cart.tune then
            name = "Shotgunshell"; thumb = bcfg(bwep.wid or 6114)
        elseif bolt.grab or bolt.preview then
            name = "TMPSUpport"
        end
        bpose_apply(name)
        if thumb and (thumb.t_rx ~= 0 or thumb.t_ry ~= 0 or thumb.t_rz ~= 0) then
            local bt = body_tf(); local tj = bt and sc(bt, "getJointByName", "L_Thumb1")
            local cur = tj and sc(tj, "get_LocalRotation")
            if cur then pcall(function() tj:call("set_LocalRotation", (cur * quat_from_euler(thumb.t_rx, thumb.t_ry, thumb.t_rz)):normalized()) end) end
        end
    end

    -- =====================================================================
    -- Holster-Wrapper (Bolt -> reload2-Bolt, sonst weiter an die bestehende Kette)
    -- =====================================================================
    local _orig_b = _G.__re4_reload_set_mag_in_hand
    _G.__re4_reload_set_mag_in_hand = function(active)
        if is_bolt(get_equip_wid()) then return bolt_set_cart_in_hand(active) end
        if _orig_b then return _orig_b(active) end
        return false
    end

    -- =====================================================================
    -- Reset / Frame-Loop / Render-Pass
    -- =====================================================================
    local function bolt_soft_reset()
        bolt.open = false; bolt.grab = false; bolt.armed = false; bolt.mode = "open"
        bolt.needs_cycle = false; bolt._prev_loaded = nil   -- [MANUAL_CYCLE] Cycle-Pflicht + Schuss-Tracker aus
        bolt.roll = 0.0; bolt.zf = 0.0; bolt.zf_anchor = 0.0; bolt.dock_blend = 0.0
        bolt.preview = false; bolt.preview_open = false
        cart.active = false; cart.insert = false; cart.tune = false
    end


    -- =====================================================================
    -- [CYCLE-SUPPRESS ADA wp6114 2026-07-20] native Bolt-Cycle-Anim nach dem Schuss
    -- =====================================================================
    -- War frueher ein eigenes File (re4_vr_bolt_cycle_suppress.lua) -- unnoetig, gehoert dorthin,
    -- wo die Waffe verwaltet wird. Zwei Teile:
    -- (A) BOLT-BEWEGUNG: der Cycle-Node wird per set_Frame(End) + set_Speed(100) sofort ans Ende
    -- gespult -> der Bolt bewegt sich nicht sichtbar.
    -- (B) SOUND/CASING: die Tracks haengen als MOTION-TRACKS an genau dieser Anim (kein
    -- SoundContainer.trigger, deshalb per ID nicht blockbar). chainsaw.Gun.callbackTracks
    -- wird uebersprungen, SOLANGE die Cycle-Anim laeuft -- Schuss und Aim bleiben unberuehrt.
    -- Alles im do-Block -> die Locals zaehlen nicht gegen das 200er-Limit des Haupt-Chunks.
    do
        local _sup_motion_t = sdk.typeof("via.motion.Motion")
        local CYCLE_NODE = "wp6114_general_0513_Aim_Fire_after"

        local function _sup_gun_go()
            local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return end
            local ctx = safe(function() return cm:call("getPlayerContextRef") end); if not ctx then return end
            local hu  = safe(function() return ctx:call("get_HeadUpdater") end); if not hu then return end
            local gun = safe(function() return hu:call("get_EquipWeapon") end); if not gun then return end
            return safe(function() return gun:call("get_GameObject") end)
        end

        re.on_frame(function()
            _G.__re4_bolt_in_cycle_dlc = false
            if not _sup_motion_t then return end
            if not (bwep.wid ~= nil) then return end
            local go = _sup_gun_go(); if not go then return end
            local mc = safe(function() return go:call("getComponent(System.Type)", _sup_motion_t) end); if not mc then return end
            local layer = safe(function() return mc:call("getLayer", 0) end); if not layer then return end
            local node = safe(function() return layer:call("get_HighestWeightMotionNode") end); if not node then return end
            local nm = safe(function() return node:call("get_MotionName") end)
            if nm and tostring(nm) == CYCLE_NODE then
                _G.__re4_bolt_in_cycle_dlc = true
                local ef = safe(function() return node:call("get_EndFrame") end)
                if ef and ef > 0 then pcall(function() node:call("set_Frame", ef) end) end
                pcall(function() layer:call("set_Speed", 100.0) end)
            end
        end)
    end

    local _bprev_wid = nil
    local _bdry_prev = false
    re.on_frame(function()
        bolt_refresh()
        _G.__re4_bolt_equipped = (bwep.wid ~= nil)   -- [SOUND_PROBE] Gate fuer den Sound-Hook (nur wenn wp4400 equippt)
        if bwep.wid ~= _bprev_wid then
            local was_bolt = (_bprev_wid ~= nil)
            bolt_soft_reset()
            if was_bolt and not bwep.wid then
                _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil
                _G.__vr_slide_dock_blend_factor = 0; _G.__vr_rack_hand_pose = nil; _G.__vr_mag_in_hand = false
                _G.__vr_slide_rack_active = false; _G.__vr_needs_rack = false
                _G.__vr_block_aim = false
            end
            if bwep.wid then _G.__re4_live_wi = nil end
            _bprev_wid = bwep.wid
        end
        if not bwep.wid then return end
        if _breacquired then
            _breacquired = false; _G.__re4_live_wi = nil; bolt_soft_reset()
        end
        bolt_capture_cart_rest()
        bolt_check_insert_proximity()

        -- Native Reload abfangen (manueller Bolt statt Engine-Reload)
        _G.__vr_manual_reload_consume_b = true

        update_bolt_gesture()

        -- Holster-Gate: buzzen nur wenn NICHTS zu laden geht
        _G.__re4_reload_grab_empty = not (bolt.open and (breserve() > 0) and ((bloaded() or 0) < bcap()))

        -- Globals fuer motion/arm_chain/binding
        _G.__vr_needs_rack        = false
        _G.__vr_slide_rack_active = bolt.grab == true
        _G.__vr_mag_in_hand       = (cart.active or cart.insert) and true or false
        _G.__vr_rack_hand_pose    = bolt.grab and "TMPSUpport" or nil
        -- [MANUAL_CYCLE 2026-07-18] Schuss erkennen (getCurrentGunAmmo gesunken) -> Cycle-Pflicht:
        -- bis der Bolt einmal manuell auf+zu ist, bleibt Feuern gesperrt UND apply_bolt_joint zwingt _01 auf
        -- Zu-Ruhe (native PumpAction/Ghost-Bolt unterdrueckt). RE9-Modell: Anim raus, alles manuell. Reload
        -- (cart.insert erhoeht loaded) und offener Bolt sind ausgenommen -> keine Falsch-Erkennung.
        local _pe = get_pe()
        local _bl = _pe and tonumber(safe(function() return _pe:call("getCurrentGunAmmo") end))
        if _bl and bolt._prev_loaded and _bl < bolt._prev_loaded and not bolt.open and not cart.insert then bolt.needs_cycle = true; _G.__re4_bolt_shot_t = os.clock() end   -- [SOUND_PROBE] Schuss-Zeitpunkt fuer das Post-Schuss-Fenster
        bolt._prev_loaded = _bl or bolt._prev_loaded
        -- [KRITISCHES GATE — LIVE] Feuer-Block: offener Bolt + echter Leerstand + Cycle-Pflicht nach Schuss
        -- [MESH FORCE 2026-08-12] Waehrend des Repetierens blendet die Engine die Waffe aus -> an zwingen.
        if (bolt.needs_cycle or bolt.open or bolt.grab) and _G.__re4_force_weapon_visible then
            _G.__re4_force_weapon_visible(bwep.tf, "Hunting Rifle")
        end
        _G.__vr_block_fire_when_empty = (bolt.open or bammo_empty() or bolt.needs_cycle) and true or false
        _G.__re4_bf_who = "re4_vr_reload5_dlc.lua:1814"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        _G.__re4_bolt_suppress_cock   = bolt.needs_cycle and true or false   -- [COCK_MUTE] Fenster fuer re4_vr_bolt_cock_mute (native Auto-Cock-Sound blocken)
        _G.__vr_rack_block_left_knife = bolt.open
        _G.__vr_block_aim             = bolt.open and true or false   -- offener Bolt -> Aimen gesperrt (binding liest)

        update_bolt_dock(true)

        -- Dry-Fire bei gesperrtem Trigger
        local et = rawget(_G, "__re4_empty_trigger_held") == true
        if et and not _bdry_prev then bsnd("dry_fire") end
        _bdry_prev = et
    end)

    local function bolt_apply_pass()
        if not (BCFG.bolt_enabled and bwep.wid) then return end
        update_cart_in_hand()
        update_cart_insert()
        apply_bolt_joint()
        update_bolt_dock(false)
        apply_bolt_pose()
    end
    pcall(function() re.on_pre_application_entry("LockScene", bolt_apply_pass) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", bolt_apply_pass) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", bolt_apply_pass) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", bolt_apply_pass) end)

    re.on_script_reset(function()
        if bwep.bolt_joint then
            if bwep.bolt_rest_rot then pcall(function() bwep.bolt_joint:call("set_LocalRotation", bwep.bolt_rest_rot) end) end
            if bwep.bolt_rest_lp then pcall(function() bwep.bolt_joint:call("set_LocalPosition", Vector3f.new(bwep.bolt_rest_lp.x, bwep.bolt_rest_lp.y, bwep.bolt_rest_lp.z)) end) end
        end
        if bwep.cart_joint and bwep.cart_rest_lp then
            pcall(function() bwep.cart_joint:call("set_LocalPosition", Vector3f.new(bwep.cart_rest_lp.x, bwep.cart_rest_lp.y, bwep.cart_rest_lp.z)) end)
            if bwep.cart_rest_lr then pcall(function() bwep.cart_joint:call("set_LocalRotation", Quaternion.new(bwep.cart_rest_lr.w, bwep.cart_rest_lr.x, bwep.cart_rest_lr.y, bwep.cart_rest_lr.z)) end) end
        end
        bwep.wid, bwep.tf, bwep.bolt_joint, bwep.cart_joint, bwep.bolt_rest_rot = nil, nil, nil, nil, nil
        bolt_soft_reset()
        _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil; _G.__vr_slide_dock_blend_factor = 0
        _G.__vr_rack_hand_pose = nil; _G.__vr_slide_rack_active = false; _G.__vr_needs_rack = false
        _G.__vr_block_aim = false
    end)

    -- =====================================================================
    -- UI (wird vom gemeinsamen Header aufgerufen, gestapelt)
    -- =====================================================================
    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion local function bolt_ui_body (81 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.

    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion Global-Zuweisung (1 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end

-- =====================================================================
-- DRITTE GATTUNG: SAMURAI EDGE (wp6113, Red9-Mechanik / Stripper-Clip)
-- =====================================================================
-- [ZUSAMMENGELEGT 2026-07-19] War re4_vr_reload5_dlc.lua. Eigener do...end-Block, eigene
-- Persistenz (re4_vr_reload5_dlc_samuraiedge.json). Sie ist mechanisch eine Red9 (Top-Loader,
-- kein Magazin), deshalb stammt sie aus einem anderen Leon-Block als die Rifles -- fachlich
-- gehoert sie aber in dieselbe DLC-Datei.

do
    -- [SW 2026-07-19] Die Samurai Edge ist EXAKT eine Red9 -> gleicher Top-Loader-Pfad,
    -- nur andere WeaponID. Alles andere (Joints, Parts, Chamber, Slide) 1:1 aus reload2.
    local R9 = 6113
    local function is_red9(wid) return wid == R9 end

    local RCFG = { enabled = true, parts = "5,20,21", single_part = "22",
        dx = 0.0, dy = 0.0, dz = 0.0, drx = 0.0, dry = 0.0, drz = 0.0, dscale = 1.0,
        -- EIGENER Offset + Pose-Tuning der EINZELPATRONE (Part 22, mode "single") — getrennt vom Stripper-Clip:
        sdx = 0.0, sdy = 0.0, sdz = 0.0, sdrx = 0.0, sdry = 0.0, sdrz = 0.0, sdscale = 1.0,
        st_rx = 0.0, st_ry = 0.0, st_rz = 0.0, -- Daumen-Tuning der Einzelpatrone (additiv, L_Thumb1)
        sti_rx = 0.0, sti_ry = 0.0, sti_rz = 0.0, -- Zeigefinger-Tuning der Einzelpatrone (additiv, L_IndexF1..3)
        s_thumb_str = 0.0, s_index_str = 0.0, -- Einzelpatrone: Finger Richtung GERADE strecken (0=Pose-Kruemmung, 1=gestreckt; Daumen alle 3 Gelenke)
        s_insert_dist = 0.12, -- Einzelpatrone: EIGENER Einlege-Abstand (Clip nutzt weiterhin insert_dist)
        t_rx = 0.0, t_ry = 0.0, t_rz = 0.0,    -- Daumen-Spreizung (additiv, auf L_Thumb1)
        i_rx = 0.0, i_ry = 0.0, i_rz = 0.0,    -- Zeigefinger Clip-Pose (additiv, auf L_IndexF1..3)
        si_rx = 0.0, si_ry = 0.0, si_rz = 0.0, -- Zeigefinger Slide-Pose (additiv, auf L_IndexF1..3)
        slide_joint = "_01", rack_z = -0.030, rack_grab = 0.14,   -- Slide = Joint _01, Z-Hub (negativ=zurueck), Greif-Distanz
        rest_z = 0.0267,   -- [REST-KONSTANTE 2026-07-18] feste Slide-Nulllage (Slide ZU) am wp4002-_01, live verifiziert. NIE mehr live messen -> sonst wird beim Leer-Ziehen die Empty-Lock-Back-Position eingefangen.
        dock_x = 0.045, dock_y = 0.032, dock_z = -0.192,          -- Dock-Versatz der Hand relativ zum Slide (Punisher-Start)
        rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1,         -- Hand-Rotation am Slide
        reload_ammo = true,                                       -- Insert lädt echte Munition (+1)
        insert_dist = 0.12, insert_dur = 0.40,                    -- Greif-Distanz Clip->Dockport + Slide-In-Dauer (langsamer Default)
        ip_joint = "_03", ip_x = 0.0, ip_y = 0.0, ip_z = 0.054,   -- Dockport = Joint _03 + lokaler Versatz (nur für Insert-Trigger/Nähe)
        insert_drop = 0.12 }                                       -- TOP-LOADER: Clip gleitet GERADE nach unten (Welt -Y) um diese Strecke
    local RCFG_PATH = "re4_vr/re4_vr_reload5_dlc_samuraiedge.json"
    local RFIELDS = { "parts","single_part","dx","dy","dz","drx","dry","drz","dscale",
        "sdx","sdy","sdz","sdrx","sdry","sdrz","sdscale","st_rx","st_ry","st_rz",
        "sti_rx","sti_ry","sti_rz","s_thumb_str","s_index_str","s_insert_dist",
        "t_rx","t_ry","t_rz","i_rx","i_ry","i_rz",
        "si_rx","si_ry","si_rz","rack_z","rack_grab","dock_x","dock_y","dock_z","rack_rx","rack_ry","rack_rz",
        "reload_ammo","insert_dist","insert_dur","ip_joint","ip_x","ip_y","ip_z","insert_drop" }
    local function rload_cfg()
        local d = safe(function() return json.load_file(RCFG_PATH) end); if type(d) ~= "table" then return end
        if type(d.enabled) == "boolean" then RCFG.enabled = d.enabled end
        for _, f in ipairs(RFIELDS) do if d[f] ~= nil then RCFG[f] = d[f] end end
    end
    local function rsave_cfg()
        local o = { enabled = RCFG.enabled }
        for _, f in ipairs(RFIELDS) do o[f] = RCFG[f] end
        pcall(function() json.dump_file(RCFG_PATH, o) end)
    end
    rload_cfg()

    local _rcm
    local function rget_gun()
        _rcm = _rcm or sdk.get_managed_singleton("chainsaw.CharacterManager"); if not _rcm then return nil end
        local ctx = safe(function() return _rcm:call("getPlayerContextRef") end); if not ctx then return nil end
        local hu = safe(function() return ctx:call("get_HeadUpdater") end); if not hu then return nil end
        local wid = safe(function() return hu:call("get_EquipWeaponID") end)
        local widn = (type(wid) == "userdata") and safe(function() return wid:get_field("value__") end) or wid
        if widn ~= R9 then return nil end
        return safe(function() return hu:call("get_EquipWeapon") end)
    end
    local function rget_gun_mesh() local g = rget_gun(); return g and safe(function() return g:call("get_Mesh") end) end
    local function rparts() local t = {}; for n in tostring(RCFG.parts):gmatch("%d+") do t[#t+1] = tonumber(n) end; return t end

    -- ---- Sounds (Wwise-IDs, am Waffen-GameObject getriggert) ----
    local R9SND = {
        mag_grab   = 1839787494,  -- Clip aus dem Holster gezogen
        slide_pull = 2611874302,  -- Slide voll nach HINTEN gezogen (100% offen)
        slide_close = 2611874302, -- Slide voll nach VORNE geschoben (100% zu) -- eigene ID liefern wenn gewuenscht
        drop       = 1351699582,  -- Kugel/Clip faellt auf den Boden (nach Loslassen)
        mag_insert =  943565871,  -- Clip in die Waffe (greift erst, wenn INSERT gebaut ist)
        dry_fire   =  812850326,  -- RT gezogen, aber Feuern gesperrt (Slide offen)
    }
    local function r9_play_sound(id)
        if not id or id <= 0 then return end
        local g = rget_gun(); if not g then return end
        local go = safe(function() return g:call("get_GameObject") end); if not (go and snd_sc_td) then return end
        local scn = safe(function() return go:call("getComponent(System.Type)", snd_sc_td) end)
        if scn then pcall(function() scn:call("trigger(System.UInt32)", id) end) end
    end

    -- ---- Hand-Pose (EIGENE Daten, gestures-unabhaengig; Start = XbowBolt-Kopie, spaeter tunen) ----
    local RPOSES = {
        ["Red9Clip"] = { bones = {
            ["L_IndexF1"]={0.924900,0.000000,-0.015000,-0.380100}, ["L_IndexF2"]={0.819200,0,0,-0.573600}, ["L_IndexF3"]={0.866000,0,0,-0.500000},
            ["L_MiddleF1"]={0.896271,-0.104853,0.085188,-0.422431}, ["L_MiddleF2"]={0.705958,0,0,-0.708254}, ["L_MiddleF3"]={0.890564,0,0,-0.454858},
            ["L_Palm"]={1.000000,0.000000,0.000000,0.000000},
            ["L_PinkyF1"]={0.922581,-0.182263,0.075602,-0.331525}, ["L_PinkyF2"]={0.722647,0,0,-0.691217}, ["L_PinkyF3"]={0.896982,0,0,-0.442068},
            ["L_RingF1"]={0.879959,-0.133028,0.090023,-0.447069}, ["L_RingF2"]={0.710167,0,0,-0.704033}, ["L_RingF3"]={0.892185,0,0,-0.451670},
            ["L_Thumb1"]={0.918569,0.252866,-0.108586,-0.283724}, ["L_Thumb2"]={0.999635,0.000000,-0.027026,0.000000}, ["L_Thumb3"]={0.923391,-0.000011,0.383861,-0.000004} } },
        -- Slide-Rack-Pose = EXAKTE Kopie der "rack-slide"-Pose aus reload.json (Zeigefinger gestreckt).
        ["Red9Slide"] = { bones = {
            ["L_IndexF1"]={1.0,0.0,0.0,0.0}, ["L_IndexF2"]={1.0,0.0,0.0,0.0}, ["L_IndexF3"]={1.0,0.0,0.0,0.0},
            ["L_MiddleF1"]={0.896271,-0.104853,0.085188,-0.422431}, ["L_MiddleF2"]={0.705958,0.0,0.0,-0.708254}, ["L_MiddleF3"]={0.890564,0.0,0.0,-0.454858},
            ["L_Palm"]={1.0,0.0,0.0,0.0},
            ["L_PinkyF1"]={0.922581,-0.182263,0.075602,-0.331525}, ["L_PinkyF2"]={0.722647,0.0,0.0,-0.691217}, ["L_PinkyF3"]={0.896982,0.0,0.0,-0.442068},
            ["L_RingF1"]={0.879959,-0.133028,0.090023,-0.447069}, ["L_RingF2"]={0.710167,0.0,0.0,-0.704033}, ["L_RingF3"]={0.892185,0.0,0.0,-0.451670},
            ["L_Thumb1"]={0.956054,0.293178,-0.002559,-0.001295}, ["L_Thumb2"]={0.983266,0.016017,-0.181468,-0.000566}, ["L_Thumb3"]={0.990157,0.0,0.139960,0.0} } },
        -- Einzelpatrone-Pose = EXAKTE LE5SWITCH-Kopie aus re4_vr_gestures.json (fest reingeschrieben, da gestures geloescht wird).
        ["Red9Single"] = { bones = {
            ["L_IndexF1"]={0.9249,0.0,-0.015,-0.3801}, ["L_IndexF2"]={0.8192,0.0,0.0,-0.5736}, ["L_IndexF3"]={0.866,0.0,0.0,-0.5},
            ["L_MiddleF1"]={0.8962705731391907,-0.10485319048166275,0.08518750220537186,-0.42243102192878723}, ["L_MiddleF2"]={0.7059580683708191,0.0,0.0,-0.7082536220550537}, ["L_MiddleF3"]={0.8905639052391052,0.0,0.0,-0.45485809445381165},
            ["L_Palm"]={1.0,0.0,0.0,0.0},
            ["L_PinkyF1"]={0.9225811958312988,-0.18226279318332672,0.0756017193198204,-0.3315245509147644}, ["L_PinkyF2"]={0.722647488117218,0.0,0.0,-0.6912167072296143}, ["L_PinkyF3"]={0.8969815373420715,0.0,0.0,-0.4420679807662964},
            ["L_RingF1"]={0.8799594640731812,-0.13302844762802124,0.09002332389354706,-0.4470687806606293}, ["L_RingF2"]={0.710166871547699,0.0,0.0,-0.7040334343910217}, ["L_RingF3"]={0.8921849131584167,0.0,0.0,-0.4516703188419342},
            ["L_Thumb1"]={0.9185688495635986,0.2528655230998993,-0.10858584940433502,-0.28372427821159363}, ["L_Thumb2"]={0.9996347427368164,0.0,-0.027026206254959106,0.0}, ["L_Thumb3"]={0.9233907461166382,-1.1019408702850342e-05,0.38386136293411255,-4.132278263568878e-06} } },
    }
    local _rpmap, _rpmap_tf = {}, nil
    local function rpose_map()
        local tf = body_tf(); if not tf then return {} end
        if tf == _rpmap_tf and next(_rpmap) ~= nil then return _rpmap end
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
        _rpmap_tf, _rpmap = tf, map
        return map
    end
    local function r9_apply_pose(name, with_thumb, blend)
        local pose = RPOSES[name]; if not (pose and pose.bones) then return end
        local map = rpose_map(); if next(map) == nil then return end
        blend = blend or 1.0
        if blend <= 0.0 then return end
        for bone, v in pairs(pose.bones) do
            local j = map[bone]
            if j and v and v[1] then
                if blend >= 0.9999 then
                    pcall(function() j:call("set_LocalRotation", Quaternion.new(v[1], v[2], v[3], v[4])) end)
                else
                    local c = safe(function() return j:call("get_LocalRotation") end)
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
        -- Daumen-/Zeigefinger-Spreizung additiv (Clip- und Einzelpatrone-Pose), mit blend skaliert
        if with_thumb then
            local single = (name == "Red9Single")
            -- [STRECKEN] Einzelpatrone: Fingergelenke Richtung GERADE (Identitaet) lerpen. 0 = Pose-Kruemmung,
            -- 1 = ganz gestreckt. Daumen wirkt auf ALLE 3 Gelenke (Euler st_* dreht nur L_Thumb1 -> Spitze blieb
            -- krumm). Danach laeuft das Euler-Feintuning additiv obendrauf.
            if single then
                local function straighten(bn, amt)
                    amt = (amt or 0) * blend; if amt <= 0 then return end
                    local j = map[bn]; local c = j and safe(function() return j:call("get_LocalRotation") end); if not c then return end
                    local w, x, y, z = c.w + (1 - c.w) * amt, c.x - c.x * amt, c.y - c.y * amt, c.z - c.z * amt
                    local len = math.sqrt(w*w + x*x + y*y + z*z)
                    if len > 1e-6 then pcall(function() j:call("set_LocalRotation", Quaternion.new(w/len, x/len, y/len, z/len)) end) end
                end
                for _, bn in ipairs({ "L_Thumb1", "L_Thumb2", "L_Thumb3" }) do straighten(bn, RCFG.s_thumb_str) end
                for _, bn in ipairs({ "L_IndexF1", "L_IndexF2", "L_IndexF3" }) do straighten(bn, RCFG.s_index_str) end
            end
            -- Daumen: Einzelpatrone hat EIGENE Werte (st_*), sonst Clip-Werte (t_*)
            local trx = (single and RCFG.st_rx or RCFG.t_rx) * blend
            local try = (single and RCFG.st_ry or RCFG.t_ry) * blend
            local trz = (single and RCFG.st_rz or RCFG.t_rz) * blend
            if trx ~= 0 or try ~= 0 or trz ~= 0 then
                local th = map["L_Thumb1"]; local cur = th and safe(function() return th:call("get_LocalRotation") end)
                if cur then pcall(function() th:call("set_LocalRotation", (cur * quat_from_euler(trx, try, trz)):normalized()) end) end
            end
            -- Zeigefinger-Streckung: Clip-Pose nutzt i_*, Einzelpatrone nutzt EIGENE sti_* (getrennt tunebar).
            local irx = single and RCFG.sti_rx or RCFG.i_rx
            local iry = single and RCFG.sti_ry or RCFG.i_ry
            local irz = single and RCFG.sti_rz or RCFG.i_rz
            if irx ~= 0 or iry ~= 0 or irz ~= 0 then
                local q = quat_from_euler(irx*blend, iry*blend, irz*blend)
                for _, bn in ipairs({ "L_IndexF1", "L_IndexF2", "L_IndexF3" }) do
                    local ix = map[bn]; local cur = ix and safe(function() return ix:call("get_LocalRotation") end)
                    if cur then pcall(function() ix:call("set_LocalRotation", (cur * q):normalized()) end) end
                end
            end
        end
        -- Zeigefinger-Tuning der SLIDE-Pose (additiv auf alle 3 Glieder), mit blend skaliert
        if name == "Red9Slide" and (RCFG.si_rx ~= 0 or RCFG.si_ry ~= 0 or RCFG.si_rz ~= 0) then
            local q = quat_from_euler(RCFG.si_rx*blend, RCFG.si_ry*blend, RCFG.si_rz*blend)
            for _, bn in ipairs({ "L_IndexF1", "L_IndexF2", "L_IndexF3" }) do
                local ix = map[bn]; local cur = ix and safe(function() return ix:call("get_LocalRotation") end)
                if cur then pcall(function() ix:call("set_LocalRotation", (cur * q):normalized()) end) end
            end
        end
    end

    -- ---- Mesh-Klon (Munition) ----
    -- clip.mode = "strip" (Stripper-Clip, Parts 5/20/21, fuellt auf Max-Cap) bei loaded==0
    -- = "single" (Einzelpatrone, Part 22, +1) bei loaded>0. Wird beim Holster-Griff gesetzt.
    local clip = { obj = nil, mesh = nil, mode = "strip", parts_sig = nil }
    local function r9_destroy()
        if clip.obj then pcall(function()
            local td = sdk.find_type_definition("via.GameObject"); local d = td and td:get_method("destroy(via.GameObject)")
            if d then d:call(nil, clip.obj) end
        end) end
        clip.obj, clip.mesh, clip.parts_sig = nil, nil, nil
    end
    local function r9_spawn()
        if clip.obj then return true end
        local gmesh = rget_gun_mesh(); if not gmesh then return false end
        local holder = safe(function() return gmesh:call("getMesh") end); if not holder then return false end
        local gmat = safe(function() return gmesh:call("get_Material") end)
        local go_td = sdk.find_type_definition("via.GameObject")
        local create = go_td and go_td:get_method("create(System.String)")
        local go = create and safe(function() return create:call(nil, "vr_red9_clip") end); if not go then return false end
        pcall(function() go:add_ref() end)
        pcall(function() go:call("createComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)  -- KERN: baut Skelett
        local mesh = safe(function() return go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
        if not mesh then return false end
        pcall(function() mesh:call("setMesh", holder) end)
        if gmat then pcall(function() mesh:call("set_Material", gmat) end) end
        pcall(function() mesh:call("set_DrawDefault", true) end)
        pcall(function() mesh:call("set_Enabled", true) end)
        pcall(function() mesh:call("set_FrustumCulling", false) end)
        clip.obj, clip.mesh = go, mesh
        -- [NO_LAG] nativ ans L_Hand-Joint parenten -> Engine propagiert die Transform VOR dem Skinning
        -- -> kein Render-Versatz beim Laufen. Danach nur noch LOKALE Pose setzen.
        clip.parented = false
        local ctf = safe(function() return go:call("get_Transform") end)
        local bt2 = body_tf()
        if ctf and bt2 then
            pcall(function() ctf:call("set_Parent", bt2) end)
            if pcall(function() ctf:call("set_ParentJoint", "L_Hand") end) then clip.parented = true end
        end
        return true
    end
    local function r9_isolate()
        if not clip.mesh then return end
        -- mode-abhaengig: Stripper-Clip = RCFG.parts, Einzelpatrone = RCFG.single_part (Part 22)
        local src = (clip.mode == "single") and (RCFG.single_part or "22") or RCFG.parts
        local sig = clip.mode .. ":" .. tostring(src)
        if clip.parts_sig == sig then return end
        local keep = {}; for n in tostring(src):gmatch("%d+") do keep[tonumber(n)] = true end
        local applied = true
        for i = 0, 40 do
            if not pcall(function() clip.mesh:call("setPartsEnable", i, keep[i] == true) end) then applied = false end
        end
        if applied then clip.parts_sig = sig end
    end

    -- [DROP] reiner freier Fall beim Loslassen (wie die Pistolen in reload.lua: s = 1/2 g t^2, KEINE Drehung).
    local rdrop = { active = false, snd = false, sx = 0, sy = 0, sz = 0, t0 = 0 }
    local RDROP_DUR, RGRAV, RDROP_SND_DELAY = 1.0, 9.8, 0.45   -- Dauer / Gravitation / Boden-Sound-Verzoegerung

    local state = { active = false, preview = false }
    -- WICHTIG: 'insert' MUSS hier (vor update_slide_rack) deklariert sein, sonst sieht die Funktion das
    -- globale nil 'insert' und crasht beim Indexieren (insert.active) -> ganzer Slide-Code tot, left grip
    -- macht nichts. Befuellt wird die Tabelle weiter unten (reine Zuweisung, kein neues 'local').
    local insert = { active = false, t0 = 0, sx = 0, sy = 0, sz = 0, lx = 0, ly = 0, lz = 0, local_ok = false }

    -- ---- VR-Grip + Hand-Welt (wie Gewehr-Block) ----
    local function left_grip_down()
        if not vrmod then return false end
        local act, lj
        pcall(function() act = vrmod:get_action_grip() end)
        pcall(function() lj  = vrmod:get_left_joystick() end)
        if not (act and lj) then return false end
        local ok, v = pcall(function() return vrmod:is_action_active(act, lj) end)
        return ok and v == true
    end
    local function left_hand_world()
        local hp = rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
        if hp then return hp end
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        return lh and sc(lh, "get_Position")
    end

    -- ---- Slide-Rack (Joint _01): jederzeit ziehbar. Hand nah am Slide + Grip -> Slide-Pose + _01 in Z zurueck ----
    local function rget_gun_tf()
        local g = rget_gun(); if not g then return nil end
        local go = safe(function() return g:call("get_GameObject") end); if not go then return nil end
        return safe(function() return go:call("get_Transform") end)
    end
    local rack = { grabbed = false, tune = false, open = false,
                   grab_base = 0, _armed_up = true, _armed_dn = false, _dock_want = 1.0,
                   settling = false, settle_t0 = 0, settle_from_z = 0, settle_to_z = 0, _last_apply_z = nil,
                   anchor_z = nil, rest_z = nil, joint = nil, dock_blend = 0, _need_regrip = false, _grab_cd = 0 }
    local CLOSE_DUR     = 0.12    -- s: Settle-Gleiten nach Loslassen (kein Snap)
    local UNDOCK_OVER   = 0.05    -- m: Controller so weit ueber den Slide-Weg hinaus -> Hand loest sich (zum Controller zurueck)
    local rack_apply_z = nil   -- [LATE-PASS] Ziel-Z fuer den Slide-Joint; in on_frame berechnet, im SPAETEN Pass geschrieben (sonst clobbert Engine)
    local function rget_slide()
        local tf = rget_gun_tf(); if not tf then rack.joint = nil; return nil end
        local j = sc(tf, "getJointByName", RCFG.slide_joint or "_01")
        if j and rack.rest_z == nil then
            -- [REST-KONSTANTE 2026-07-18] Nulllage NIE mehr live messen. Grund: rest_z wurde bei jedem
            -- Unequip/Reset ge-nilt und beim naechsten Ziehen aus dem Live-Joint gelesen -> beim LEER-Ziehen
            -- steht der Slide (Engine-Empty-Lock) schon hinten -> falsche Nulllage, Slide zu weit hinten.
            -- Fester Wert fest im Script (BEWUSST nicht in RFIELDS -> nicht ueber JSON kalibrierbar, kann
            -- nicht wieder verstellt/verkehrt werden). Live-Messung nur noch Fallback, falls RCFG.rest_z mal nil.
            if RCFG.rest_z ~= nil then rack.rest_z = RCFG.rest_z
            else local lp = sc(j, "get_LocalPosition"); if lp then rack.rest_z = lp.z end end
        end
        rack.joint = j
        return j
    end
    local function rset_slide_z(z)
        local j = rack.joint; if not j then return end
        local lp = sc(j, "get_LocalPosition"); if not lp then return end
        pcall(function() j:call("set_LocalPosition", Vector3f.new(lp.x, lp.y, z)) end)
    end
    -- Hand an den Slide docken (arm_chain liest __vr_slide_hand_world_*). Publisht NUR den aktuellen
    -- Blend (kein Ramp hier -> kann pro Pass aufgerufen werden); der Ramp passiert in update_slide_rack.
    local function r9_publish_dock(j)
        local bl = rack.dock_blend or 0
        if bl > 0.001 and j then
            local p = sc(j, "get_Position"); local r = sc(j, "get_Rotation")
            if p and r then
                if RCFG.dock_x ~= 0 or RCFG.dock_y ~= 0 or RCFG.dock_z ~= 0 then
                    local off = safe(function() return r * Vector3f.new(RCFG.dock_x, RCFG.dock_y, RCFG.dock_z) end)
                    if off then p = Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
                end
                if RCFG.rack_rx ~= 0 or RCFG.rack_ry ~= 0 or RCFG.rack_rz ~= 0 then
                    r = safe(function() return (r * quat_from_euler(RCFG.rack_rx, RCFG.rack_ry, RCFG.rack_rz)):normalized() end) or r
                end
                _G.__vr_slide_hand_world_pos = p
                _G.__vr_slide_hand_world_rot = r
                _G.__vr_slide_dock_blend_factor = bl * bl * (3.0 - 2.0 * bl)
                return
            end
        end
        _G.__vr_slide_hand_world_pos = nil
        _G.__vr_slide_hand_world_rot = nil
        _G.__vr_slide_dock_blend_factor = 0
    end
    local function update_slide_rack()
        rack_apply_z = nil   -- pro Frame frisch; nur waehrend Zug/Anim gesetzt -> im spaeten Pass geschrieben
        local j = rget_slide(); if not (j and rack.rest_z ~= nil) then rack.grabbed = false; rack.dock_blend = 0; r9_publish_dock(nil); return end
        local maxpull = math.abs(RCFG.rack_z or -0.030)
        local sgn     = (RCFG.rack_z or 0) < 0 and -1 or 1
        local open_z  = rack.rest_z + sgn * maxpull

        -- [SETTLE] nach dem Loslassen: gleitet von der losgelassenen Position auf den Latch-Wert (open_z/rest_z).
        if rack.settling then
            rack.grabbed = false
            local t = (os.clock() - rack.settle_t0) / CLOSE_DUR
            if t >= 1.0 then rack.settling = false; rack_apply_z = rack.settle_to_z
            else rack_apply_z = rack.settle_from_z + (rack.settle_to_z - rack.settle_from_z) * t end
            local bl = rack.dock_blend or 0; if bl > 0 then bl = math.max(bl - 0.10, 0) end; rack.dock_blend = bl
            rack._last_apply_z = rack_apply_z
            r9_publish_dock(j)
            return
        end

        -- [CLIP-IN-HAND / INSERT] Clip in der Hand ODER Einleg-Animation laeuft -> KEIN Slide-Grab/Dock.
        -- Wichtig: waehrend insert.active ist state.active schon false, der Grip aber noch gehalten ->
        -- ohne diesen Skip wuerde unser Slide-Grab sofort waehrend des Einlegens zupacken. Slide bleibt offen.
        if state.active or insert.active then
            rack.grabbed = false; rack.dock_blend = 0
            if rack.open then rack_apply_z = open_z end
            r9_publish_dock(nil)
            return
        end

        local hp = left_hand_world(); local sp = sc(j, "get_Position"); local grip = left_grip_down()
        -- [RE-GRIP nach Insert] Grip-Loslassen loescht die Sperre (eine Variante). Distanz-Clear unten ist die
        -- robuste: greift auch wenn der Grip DURCHGEHEND gehalten wird (Zwei-Hand-Aim) -> sonst haengt die Sperre.
        if not grip then rack._need_regrip = false end
        -- Hand-Position in WAFFEN-LOKALEN Koordinaten (Z = Slide-Achse) -> immun gegen Waffenbewegung in der Welt.
        local gtf = rget_gun_tf(); local gpos = gtf and sc(gtf, "get_Position"); local grot = gtf and sc(gtf, "get_Rotation")
        local function hand_gun_z(p)
            if not (p and gpos and grot) then return nil end
            local d = Vector3f.new(p.x - gpos.x, p.y - gpos.y, p.z - gpos.z)
            local ginv = Quaternion.new(grot.w, -grot.x, -grot.y, -grot.z)   -- Konjugat (Einheits-Quat) = Inverse
            local l = safe(function() return ginv * d end)
            return l and l.z or nil
        end
        if hp and sp then
            local dist = math.sqrt((hp.x-sp.x)^2 + (hp.y-sp.y)^2 + (hp.z-sp.z)^2)
            local grab = RCFG.rack_grab or 0.14
            -- [RE-GRIP Distanz-Clear] Sperre faellt, sobald die Hand den Slide verlaesst (dist > grab*1.5).
            -- Direkt nach dem Einlegen ist die Hand noch am Port (dist klein) -> Sperre bleibt -> kein Sofort-Snap.
            -- Erst Weg-und-wieder-hin (oder Grip los) erlaubt den naechsten Slide-Grab. Haengt NIE bei Dauer-Grip.
            if rack._need_regrip and dist > grab * 1.5 then rack._need_regrip = false end
            if not rack.grabbed then
                if grip and dist <= grab and not rack._need_regrip and os.clock() >= (rack._grab_cd or 0) then
                    rack.grabbed = true; rack.anchor_z = hand_gun_z(hp)
                    rack.grab_base = rack.open and maxpull or 0     -- Slide folgt der Hand AB der aktuellen Offenheit
                    rack._armed_up = not rack.open                  -- zu -> Oeffnungs-Sound scharf
                    rack._armed_dn = rack.open                      -- offen -> Schliess-Sound scharf
                end
            elseif grip and dist > grab * 3.0 then
                -- [HARD-SAFETY] Hand extrem weit -> Grab komplett loslassen (Backstop)
                rack.grabbed = false
                rack_apply_z = rack.open and open_z or rack.rest_z
            elseif grip then
                -- Slide folgt der Hand live: target = Greif-Offenheit + Handzug entlang Waffen-Z
                local cz = hand_gun_z(hp)
                local raw    = (cz and rack.anchor_z) and ((cz - rack.anchor_z) * sgn) or 0
                local target = rack.grab_base + raw
                local amt = target; if amt < 0 then amt = 0 elseif amt > maxpull then amt = maxpull end
                local frac = (maxpull > 0) and (amt / maxpull) or 0
                -- Sounds als Flanken (jede Voll-Bewegung) -> auch bei mehrfachem Rackern im selben Griff
                if frac >= 0.90 and rack._armed_up then rack._armed_up = false; rack._armed_dn = true; r9_play_sound(R9SND.slide_pull) end
                if frac <= 0.10 and rack._armed_dn then rack._armed_dn = false; rack._armed_up = true; r9_play_sound(R9SND.slide_close) end
                rack.open = (frac >= 0.5)                          -- live: offen/zu (treibt Fire-Block)
                rack_apply_z = rack.rest_z + sgn * amt
                -- [UNDOCK bei Ueber-Reise] Controller weiter als der Slide kann -> Hand loest sich, geht zum Controller zurueck
                local over = math.max(0, target - maxpull) + math.max(0, -target)
                rack._dock_want = (over > UNDOCK_OVER) and 0.0 or 1.0
            else
                -- LOSLASSEN -> auf den naechsten Latch-Wert gleiten (kein Snap)
                rack.grabbed = false
                rack.settling = true; rack.settle_t0 = os.clock()
                rack.settle_from_z = rack._last_apply_z or (rack.open and open_z or rack.rest_z)
                rack.settle_to_z   = rack.open and open_z or rack.rest_z
                rack_apply_z = rack.settle_from_z
            end
            -- OFFEN-Latch halten (ohne Griff)
            if rack.open and not rack.grabbed and not rack.settling then rack_apply_z = open_z end
        end
        -- OFFEN-Latch absichern (Hand-Welt diesen Frame nicht gelesen)
        if rack.open and not rack.settling and rack_apply_z == nil then rack_apply_z = open_z end
        -- [PREVIEW] Tune-Modus
        if rack.tune and not rack.grabbed then rack_apply_z = open_z end
        -- [SLIDE-OWNERSHIP] Wir besitzen _01 VOLLSTAENDIG: solange unser Latch ZU ist (rack_apply_z noch nil =
        -- idle, nicht gegriffen/Settle/Tune/offen) forcen wir rest_z. Das ueberschreibt JEDE Engine-Slide-Anim
        -- (Empty-Lock-Back bei 0 UND das offen-Haengen nach dem Reload) -> Port haengt nie gegen unseren Zustand.
        -- Trade-off: die per-Schuss Slide-Recoil-Anim wird mit unterdrueckt (alte Waffe = wir steuern den Slide).
        if rack_apply_z == nil and rack.rest_z ~= nil and not rack.open then
            rack_apply_z = rack.rest_z
        end
        -- Dock-Blend: voll bei Griff (ausser Ueber-Reise -> 0); Tune -> voll; sonst 0
        local want = rack.tune and 1.0 or (rack.grabbed and (rack._dock_want or 1.0) or 0.0)
        local bl = rack.dock_blend or 0
        if bl < want then bl = math.min(bl + 0.10, want) elseif bl > want then bl = math.max(bl - 0.10, want) end
        rack.dock_blend = bl
        rack._last_apply_z = rack_apply_z
        r9_publish_dock(j)
    end

    -- no_dirty=true: selbst erzeugte Transform bleibt sonst in den gelockten Paessen haengen -> Zittern.
    local function r9_set_tf(tf, p, rot, s)
        local okp = pcall(function() tf:set_position(p, true) end)
        if not okp then pcall(function() tf:call("set_Position", p) end) end
        if rot then local okr = pcall(function() tf:set_rotation(rot) end); if not okr then pcall(function() tf:call("set_Rotation", rot) end) end end
        if s then pcall(function() tf:call("set_LocalScale", Vector3f.new(s, s, s)) end) end
    end
    local function r9_follow_to_hand()
        if not clip.obj then return end
        -- [NO_LAG] geparentet ans L_Hand: nur LOKALE Pose (Offset war schon hand-relativ = jetzt lokal).
        if clip.parented then
            local single = (clip.mode == "single")
            local ox  = single and RCFG.sdx or RCFG.dx
            local oy  = single and RCFG.sdy or RCFG.dy
            local oz  = single and RCFG.sdz or RCFG.dz
            local orx = single and RCFG.sdrx or RCFG.drx
            local ory = single and RCFG.sdry or RCFG.dry
            local orz = single and RCFG.sdrz or RCFG.drz
            local osc = (single and RCFG.sdscale or RCFG.dscale) or 1.0
            local tf = safe(function() return clip.obj:call("get_Transform") end); if not tf then return end
            pcall(function() tf:call("set_LocalPosition", Vector3f.new(ox, oy, oz)) end)
            pcall(function() tf:call("set_LocalRotation", quat_from_euler(orx, ory, orz)) end)
            pcall(function() tf:call("set_LocalScale", Vector3f.new(osc, osc, osc)) end)
            return
        end
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position"); local hr = lh and sc(lh, "get_Rotation")
        if not (hp and hr) then return end
        -- Einzelpatrone (mode "single") hat EIGENEN Offset (sd*), sonst Stripper-Clip (d*).
        local single = (clip.mode == "single")
        local ox  = single and RCFG.sdx or RCFG.dx
        local oy  = single and RCFG.sdy or RCFG.dy
        local oz  = single and RCFG.sdz or RCFG.dz
        local orx = single and RCFG.sdrx or RCFG.drx
        local ory = single and RCFG.sdry or RCFG.dry
        local orz = single and RCFG.sdrz or RCFG.drz
        local osc = (single and RCFG.sdscale or RCFG.dscale) or 1.0
        local off = safe(function() return hr * Vector3f.new(ox, oy, oz) end) or Vector3f.new(0, 0, 0)
        local tf = safe(function() return clip.obj:call("get_Transform") end); if not tf then return end
        local rot = safe(function() return (hr * quat_from_euler(orx, ory, orz)):normalized() end)
        r9_set_tf(tf, Vector3f.new(hp.x + off.x, hp.y + off.y, hp.z + off.z), rot, osc)
    end
    local function r9_apply_drop()
        if not (rdrop.active and clip.obj) then return false end
        local t = os.clock() - rdrop.t0
        if t > RDROP_DUR then rdrop.active = false; r9_destroy(); return false end
        if not rdrop.snd and t >= RDROP_SND_DELAY then rdrop.snd = true; r9_play_sound(R9SND.drop) end   -- Boden-Aufprall (verzoegert wie Pistolen)
        local fall = 0.5 * RGRAV * t * t              -- s = 1/2 g t^2 (reiner freier Fall, keine Drehung)
        local tf = safe(function() return clip.obj:call("get_Transform") end); if not tf then return true end
        pcall(function() tf:call("set_Position", Vector3f.new(rdrop.sx, rdrop.sy - fall, rdrop.sz)) end)
        local s = RCFG.dscale or 1.0
        pcall(function() tf:call("set_LocalScale", Vector3f.new(s, s, s)) end)
        return true
    end
    local function r9_start_drop()
        local tf = clip.obj and safe(function() return clip.obj:call("get_Transform") end)
        local p = tf and safe(function() return tf:call("get_Position") end)
        if p then rdrop.active = true; rdrop.snd = false; rdrop.sx, rdrop.sy, rdrop.sz = p.x, p.y, p.z; rdrop.t0 = os.clock()
            -- [NO_LAG] Klon war ans L_Hand geparentet -> fuer den Welt-Freifall entkoppeln.
            if clip.parented then pcall(function() tf:call("set_Parent", nil) end); clip.parented = false end
        end
    end

    -- ====================================================================
    -- INSERT: Clip nahe Dockport (bei OFFENEM Slide) -> Clip GLEITET in die Kammer -> +1
    -- (Red9 hat KEIN Rausgleiten; nur das Reinfuehren slidet, wie man wollte.)
    -- ====================================================================
    -- (insert oben deklariert; hier nur frisch setzen)
    insert.active = false; insert.t0 = 0; insert.sx = 0; insert.sy = 0; insert.sz = 0
    insert.lx = 0; insert.ly = 0; insert.lz = 0; insert.local_ok = false
    local function r9_ease(t) return t * t * (3.0 - 2.0 * t) end
    -- Dockport-Weltpos (Joint ip_joint + lokaler ip-Versatz) — NUR für die Insert-Nähe (Trigger), nicht für die Bewegung.
    local function r9_dockport_world()
        local tf = rget_gun_tf(); if not tf then return nil end
        local j = sc(tf, "getJointByName", RCFG.ip_joint or "_03"); if not j then return nil end
        local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation"); if not (jp and jr) then return nil end
        local off = safe(function() return jr * Vector3f.new(RCFG.ip_x, RCFG.ip_y, RCFG.ip_z) end) or Vector3f.new(0, 0, 0)
        return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
    end
    -- +1 laden (verlustsicher via inv:reload wie Armbrust xadd_one; Reserve zieht die Engine selbst, kein 0x44).
    local _r9_et = nil
    local function r9_equip_type_main()
        if _r9_et ~= nil then return _r9_et end
        local td = sdk.find_type_definition("chainsaw.EquipType"); local f = td and td:get_field("Main")
        if f then _r9_et = f:get_data(nil) end
        return _r9_et
    end
    -- STRIPPER-CLIP: füllt die Waffe AUF MAX-CAP (need = cap-loaded), begrenzt durch Reserve.
    -- inv:reload zieht die Reserve selbst (kein manueller Abzug). Bsp: cap15, loaded5, res20 -> +10, res10.
    -- [FEHLENDER HELFER 2026-07-19] get_live_wi stammt aus re4_vr_reload2.lua und wurde beim
    -- Herauskopieren des Samurai-Blocks nicht mitgenommen -> Laufzeitfehler
    -- "global 'get_live_wi' is not callable" in r9_grab_allowed, dadurch kein Clip/keine Patrone.
    -- 1:1 aus reload2 uebernommen, nur die Waffen-ID-Pruefung auf R9 (=6113) dieses Blocks gemuenzt.
    local function get_live_wi()
        -- [ACCESSOR 2026-08-12] zuerst die ECHTE, persistente Instanz (s. reload.lua,
        -- __re4_real_wi). Alles darunter sind KOPIEN -> Schreiben verpufft.
        local _rw = _G.__re4_real_wi and _G.__re4_real_wi()
        if _rw then return _rw end
        local wi = rawget(_G, "__re4_live_wi")
        if wi and safe(function() return wi:call("get_IsValid") end) == true
           and safe(function() return wi:call("get_CurrentAmmoCount") end) ~= nil then
            local cwid = safe(function() return wi:call("get_WeaponId"):get_field("value__") end)
            if cwid and cwid == R9 then return wi end   -- STRIKT: valid + unsere Waffe (kein stale)
        end
        local pe = get_pe()
        local ewi = pe and safe(function() return pe:call("getEquipWeaponItem") end)
        if ewi and safe(function() return ewi:call("get_CurrentAmmoCount") end) ~= nil then return ewi end
        return nil
    end

    local function r9_fill_to_cap()
        if not RCFG.reload_ammo then return end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController"); if not inv then return end
        local wi = get_live_wi()
        local loaded = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or 0
        local cap = wi and (tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0) or 0
        if cap <= 0 or loaded >= cap then return end
        local ammo_id = wi and safe(function() return wi:call("get_CurrentAmmo") end)
        local reserve = ammo_id and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
        if reserve <= 0 then return end
        local need = cap - loaded; if need > reserve then need = reserve end   -- nicht mehr als Reserve da ist
        local et = r9_equip_type_main()
        if et and _G.__re4_safe_inv_reload then _G.__re4_load_and_book(inv, et, need, false) end   -- [CRASH-HARDEN 2026-07-17] engine-Gate enableReloadItem gegen null-Item-AV
        local loaded_af = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or loaded
        if loaded_af > loaded then r9_play_sound(R9SND.mag_insert) end   -- Sound nur bei echtem Nachladen
    end
    -- EINZELPATRONE: lädt WIRKLICH nur +1 (verlustsicher via inv:reload count=1). Genutzt bei loaded>0.
    local function r9_add_single()
        if not RCFG.reload_ammo then return end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController"); if not inv then return end
        local wi = get_live_wi()
        local loaded = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or 0
        local cap = wi and (tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0) or 0
        if cap > 0 and loaded >= cap then return end
        local ammo_id = wi and safe(function() return wi:call("get_CurrentAmmo") end)
        local reserve = ammo_id and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
        if reserve <= 0 then return end
        local et = r9_equip_type_main()
        if et and _G.__re4_safe_inv_reload then _G.__re4_load_and_book(inv, et, 1, false) end   -- [CRASH-HARDEN 2026-07-17] engine-Gate enableReloadItem gegen null-Item-AV
        local loaded_af = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or loaded
        if loaded_af > loaded then r9_play_sound(R9SND.mag_insert) end   -- Sound nur bei echtem +1
    end
    -- Holster nur greifbar wenn Slide OFFEN + Reserve da + nicht voll. Sonst Sperr-Puls (Bolt-Modell).
    local function r9_grab_allowed()
        if not rack.open then return false end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController"); if not inv then return false end
        local wi = get_live_wi()
        local ammo_id = wi and safe(function() return wi:call("get_CurrentAmmo") end)
        local reserve = ammo_id and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
        if reserve <= 0 then return false end
        local loaded = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or 0
        local cap = wi and (tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0) or 0
        if cap > 0 and loaded >= cap then return false end
        return true
    end
    -- Naehe Clip-Hand -> Dockport bei OFFENEM Slide -> Slide-In starten.
    local function r9_check_insert()
        if insert.active or not state.active or not rack.open then return end
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position"); if not hp then return end
        local dp = r9_dockport_world(); if not dp then return end
        local d = math.sqrt((hp.x-dp.x)^2 + (hp.y-dp.y)^2 + (hp.z-dp.z)^2)
        -- [INSERT-DIST] Einzelpatrone hat EIGENEN Abstand (s_insert_dist), Stripper-Clip nutzt insert_dist.
        local thr = (clip.mode == "single") and (RCFG.s_insert_dist or RCFG.insert_dist or 0.12) or (RCFG.insert_dist or 0.12)
        if d <= thr then
            -- Start = aktuelle Clip-Position (Hand) -> KEIN Sprung.
            local tf = clip.obj and safe(function() return clip.obj:call("get_Transform") end)
            local p = tf and safe(function() return tf:call("get_Position") end)
            local px, py, pz = (p and p.x) or hp.x, (p and p.y) or hp.y, (p and p.z) or hp.z
            insert.sx, insert.sy, insert.sz = px, py, pz   -- Welt-Fallback
            -- Start in WAFFEN-LOKALEN Koordinaten -> Slide-In folgt der Waffen-Achse (kippt mit der Waffe,
            -- nicht stur Welt-unten). Sonst faellt der Clip bei geneigter Waffe daneben.
            local gtf = rget_gun_tf(); local gpos = gtf and sc(gtf, "get_Position"); local grot = gtf and sc(gtf, "get_Rotation")
            if gpos and grot then
                local ginv = Quaternion.new(grot.w, -grot.x, -grot.y, -grot.z)
                local dd = Vector3f.new(px - gpos.x, py - gpos.y, pz - gpos.z)
                local l = safe(function() return ginv * dd end)
                if l then insert.lx, insert.ly, insert.lz, insert.local_ok = l.x, l.y, l.z, true
                else insert.local_ok = false end
            else insert.local_ok = false end
            insert.active = true; insert.t0 = os.clock()
            state.active = false   -- Clip nicht mehr an der Hand -> gleitet jetzt von oben in die Kammer
            -- [NO_LAG] Klon war ans L_Hand geparentet -> fuer die Welt-Slide-In-Animation entkoppeln.
            if clip.parented then pcall(function() tf:call("set_Parent", nil) end); clip.parented = false end
            rack._need_regrip = true   -- SOFORT: Grip ist noch gehalten -> Slide-Grab erst nach Loslassen+Neugreifen
        end
    end
    -- Slide-In-Animation: Clip gleitet von der Hand-Start-Position GERADE nach unten (Welt -Y), dann +1 + verschwindet.
    local function r9_update_insert()
        if not insert.active then return false end
        if not clip.obj then insert.active = false; return false end
        r9_isolate()
        -- [SHELL-KEYFRAMES 2026-07-24] Samurai Edge (6113) = 1:1 Red9 -> NUTZT DIESELBEN Red9-Keyframes
        -- (single=40021, Stripper-Clip=4002) + denselben Anlauf. Dauer + Bahn aus reload_adv statt dem Drop.
        local ms = rawget(_G, "__re4_reload_mag_slide")
        local kfwid = (clip.mode == "single") and 40021 or 4002
        local kf = ms and type(ms.shell_pose_at) == "function" and ms.has_shell_keys and ms.has_shell_keys(kfwid)
        local dur = kf and (tonumber(ms.shell_dur) or 0.4) or (RCFG.insert_dur or 0.22)
        local t = (os.clock() - insert.t0) / math.max(dur, 0.01)
        if t >= 1.0 then
            -- Stripper-Clip -> auf Max-Cap fuellen; Einzelpatrone -> nur +1
            insert.active = false
            if clip.mode == "single" then r9_add_single() else r9_fill_to_cap() end
            r9_destroy()
            -- [RE-GRIP -> COOLDOWN] Frueher: _need_regrip blieb true bis Grip los/Hand weg -> bei durchgehend
            -- gehaltenem Grip + Hand am Slide blieb der Slide-Grab DAUERHAFT gesperrt (man kam nicht mehr an den
            -- Slide, um ihn zu schliessen). Die Einleg-Phase selbst ist schon ueber den insert.active-Skip gegen
            -- ein Zuschnappen geschuetzt. Daher: Sperre loesen + nur kurzer Zeit-Cooldown, damit der Grab nicht ins
            -- Anim-Ende reinsnappt; danach darf man bei gehaltenem Grip sofort den Slide greifen.
            rack._need_regrip = false
            rack._grab_cd = os.clock() + (RCFG.regrip_cd or 0.25)
            return true
        end
        -- Gleitet entlang der WAFFEN-LOKALEN -Y-Achse nach unten (kippt mit der Waffe) -> immer in die Kammer.
        -- Kein Bogen, kein Vorwaerts. Fallback = Welt -Y (falls Waffen-Transform fehlt).
        if kf then
            local gtf = rget_gun_tf(); local gp = gtf and sc(gtf, "get_Position"); local gr = gtf and sc(gtf, "get_Rotation")
            local tf = safe(function() return clip.obj:call("get_Transform") end)
            if tf and gp and gr then
                local anl = (kfwid == 40021) and (tonumber(ms.r9_anlauf) or 0.0) or 0.0
                local x, y, z, rx, ry, rz
                if anl > 0.001 and insert.local_ok then
                    if t < anl then
                        local k1x, k1y, k1z, k1rx, k1ry, k1rz = ms.shell_pose_at(kfwid, 0.0)
                        local bf = t / anl
                        x = insert.lx + ((k1x or 0) - insert.lx) * bf
                        y = insert.ly + ((k1y or 0) - insert.ly) * bf
                        z = insert.lz + ((k1z or 0) - insert.lz) * bf
                        rx, ry, rz = k1rx or 0, k1ry or 0, k1rz or 0
                    else
                        x, y, z, rx, ry, rz = ms.shell_pose_at(kfwid, (t - anl) / math.max(1.0 - anl, 0.01))
                    end
                else
                    x, y, z, rx, ry, rz = ms.shell_pose_at(kfwid, t)
                end
                if x then
                    local off = safe(function() return gr * Vector3f.new(x, y, z) end)
                    local pos = off and Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z) or gp
                    local rot = safe(function() return (gr * quat_from_euler(rx, ry, rz)):normalized() end)
                    r9_set_tf(tf, pos, rot, RCFG.dscale or 1.0)
                end
            end
            return true
        end
        local u = r9_ease(t)
        local drop = (RCFG.insert_drop or 0.12) * u
        local tf = safe(function() return clip.obj:call("get_Transform") end)
        if tf then
            local pos
            if insert.local_ok then
                local gtf = rget_gun_tf(); local gpos = gtf and sc(gtf, "get_Position"); local grot = gtf and sc(gtf, "get_Rotation")
                if gpos and grot then
                    local lp = Vector3f.new(insert.lx, insert.ly - drop, insert.lz)
                    local w = safe(function() return grot * lp end)
                    if w then pos = Vector3f.new(gpos.x + w.x, gpos.y + w.y, gpos.z + w.z) end
                end
            end
            if not pos then pos = Vector3f.new(insert.sx, insert.sy - drop, insert.sz) end
            r9_set_tf(tf, pos, nil, RCFG.dscale or 1.0)
        end
        return true
    end

    -- ---- Hauptlogik: zeigt den Clip solange aktiv (Griff) oder preview ----
    local function r9_update(show)
        if r9_update_insert() then return end   -- Slide-In laeuft -> Vorrang
        if show then
            rdrop.active = false
            if not clip.obj then if not r9_spawn() then return end end
            r9_isolate()
            r9_follow_to_hand()
            r9_check_insert()                    -- nah am Dockport + Slide offen -> Slide-In starten
        else
            if r9_apply_drop() then return end   -- laeuft ein Fall -> animieren
            if clip.obj and not rdrop.active then r9_destroy() end
        end
    end

    -- ---- Holster-Grab -> Clip in die Hand (chained vor die bestehende Kette) ----
    local function r9_set_in_hand(active)
        if active then
            if not state.active then
                r9_play_sound(R9SND.mag_grab)   -- Flanke: einmal beim Greifen
                -- Modus beim Greifen festlegen: leer (0) -> Stripper-Clip; sonst -> Einzelpatrone
                local pe = get_pe()
                local loaded = pe and (tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or 0) or 0
                clip.mode = (loaded <= 0) and "strip" or "single"
            end
            state.active = true; return true
        end
        if state.active then r9_start_drop() end
        state.active = false
        return true
    end
    local _orig_r9 = _G.__re4_reload_set_mag_in_hand
    _G.__re4_reload_set_mag_in_hand = function(active)
        if is_red9(get_equip_wid()) then return r9_set_in_hand(active) end
        if _orig_r9 then return _orig_r9(active) end
        return false
    end

    local _rprev_wid = nil
    local _r9_dry_prev = false
    re.on_frame(function()
        local ewid = get_equip_wid()
        if not (RCFG.enabled and is_red9(ewid)) then
            if _rprev_wid ~= nil then
                state.active = false; state.preview = false; rdrop.active = false; insert.active = false; r9_destroy()
                if rack.joint and rack.rest_z ~= nil then rset_slide_z(rack.rest_z) end
                rack.grabbed = false; rack.tune = false; rack.open = false
                rack.settling = false; rack._dock_want = 1.0; rack._armed_up = true; rack._armed_dn = false; rack._last_apply_z = nil; rack._need_regrip = false; rack._grab_cd = 0
                rack.joint = nil; rack.rest_z = nil; rack.dock_blend = 0
                _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil; _G.__vr_slide_dock_blend_factor = 0
                _G.__vr_block_fire_when_empty = false
                _G.__re4_bf_who = "re4_vr_reload5_dlc.lua:2652"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
                _G.__vr_block_two_hand = false
                _G.__vr_slide_rack_active = false   -- [FL_RACK] Flag freigeben beim Wegwechseln von Red9
                _G.__vr_mag_in_hand = false         -- [LH_KNIFE-KILL] Clip-Flag beim Wegwechseln freigeben (sonst bleibt Messer-Klon-Kill/Two-Hand-Yield haengen)
                _G.__re4_reload_grab_empty = false
                _rprev_wid = nil
            end
            return
        end
        _rprev_wid = ewid
        _G.__vr_manual_reload_consume_b = true   -- nativer Reload geblockt (B macht nichts)
        update_slide_rack()                      -- Slide _01 jederzeit ziehbar
        -- [STAGGER_HEAL 2026-07-19] Stagger-Ende (fallende Flanke __re4_damage_active) -> Slide ZU (rest) +
        -- fire-ready, exakt die Reset-Zeilen vom Red9-Wegwechsel. rack.open=false -> Fire-Block faellt weg.
        _G.__vr_block_fire_when_empty = rack.open and true or false   -- feuern nur bei GESCHLOSSENEM Slide
        _G.__re4_bf_who = "re4_vr_reload5_dlc.lua:2666"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        -- [SUPPORT-YIELD] Solange Red9 die linke Hand besitzt (Slide gegriffen/Settle/Clip/Insert), weicht die
        -- geteilte Support-Hand (Group-A Auto-Dock in motion.lua) -> sonst greift sie die Hand zurueck an die
        -- Waffe und mein Slide-Undock ist machtlos ("support haengt"). Sonst aus -> Support-Hand normal (unveraendert).
        _G.__vr_block_two_hand = (rack.grabbed or rack.settling or state.active or insert.active) and true or false
        -- [LH_KNIFE-KILL 2026-07-18] Clip in linker Hand ODER Insert-Anim -> gemeinsames "Mag in Hand"-Flag setzen,
        -- damit weapons2.lua den linken Messer-Klon sofort zerstoert (wie bei den Pistolen-Magazinen). Der Red9-Block
        -- setzte es bisher NIE -> Klon blieb sichtbar. Gleiches Muster wie der Revolver-Block (reload2 ~Z.866).
        _G.__vr_mag_in_hand = (state.active or insert.active) and true or false
        -- [FL_RACK] Slide gegriffen/Settle -> Flashlight ans HMD + FL-Mesh aus (motion.lua liest __vr_slide_rack_active,
        -- fl_busy_reason). Red9 setzte das Flag bisher nicht -> Lampe blieb beim Slide-Racken in der Hand.
        _G.__vr_slide_rack_active = (rack.grabbed or rack.settling) and true or false
        -- [HOLSTER-GATE] Mag kommt NUR bei offenem Slide (+ Reserve, nicht voll) aus dem Holster; sonst Sperr-Puls.
        local _ga = r9_grab_allowed()
        _G.__re4_reload_grab_empty = (not state.active and not insert.active and not _ga)
        -- [DRY-FIRE] RT gezogen waehrend gesperrt (binding.lua setzt __re4_empty_trigger_held) -> Klick auf der Flanke
        local et = rawget(_G, "__re4_empty_trigger_held") == true
        if et and not _r9_dry_prev then r9_play_sound(R9SND.dry_fire) end
        _r9_dry_prev = et
        -- [SHELL-KEYFRAMES 2026-07-24] Samurai Edge teilt sich Red9-Keyframes/Preview/Anlauf (4002/40021).
        do
            local _kms = rawget(_G, "__re4_reload_mag_slide")
            if _kms and _kms.shell_preview and (_kms.KEYFRAME_INSERT[4002] or _kms.KEYFRAME_INSERT[40021])
               and not state.active and not insert.active then
                clip.mode = (rawget(_G, "__re4_r9_kf_mode") == "single") and "single" or "strip"
                state.preview = true
                _G.__re4_r9_kf_preview = true
            elseif rawget(_G, "__re4_r9_kf_preview") then
                state.preview = false; _G.__re4_r9_kf_preview = false
            end
            _G.__re4_reload_ui_wid = (clip.mode == "single") and 40021 or 4002
        end
        r9_update(state.active or state.preview)
        -- [STATE-LOG 2026-07-18] Red9-Innenzustand fuer re4_vr_state_log.lua publishen (reine _G-Tabelle,
        -- keine neue Local, ganz am Ende -> beeinflusst nichts). reload.lua fasst 4002 nicht an, daher
        -- war der Red9 im Logger bisher unsichtbar. rack.open = script-Meinung "Slide offen" (treibt Fire-Block),
        -- _ga = r9_grab_allowed Netto ("Holster greifbar?").
        local _r9pe  = get_pe()
        local _r9wi  = get_live_wi()
        local _r9inv = _r9pe and sc(_r9pe, "get_InventoryController")
        local _r9amid = _r9wi and safe(function() return _r9wi:call("get_CurrentAmmo") end)
        _G.__re4_red9_dbg = { wid = ewid, open = rack.open, grabbed = rack.grabbed, settling = rack.settling,
            tune = rack.tune, state_active = state.active, insert_active = insert.active, mode = clip.mode,
            grab_allowed = _ga, block_fire = rack.open and true or false,
            slide_now = rack._last_apply_z, slide_rest = rack.rest_z,
            loaded   = _r9pe and tonumber(safe(function() return _r9pe:call("getCurrentGunAmmo") end)),
            cap      = _r9wi and tonumber(safe(function() return _r9wi:call("get_CurrentAmmoMax") end)),
            reserve  = (_r9inv and _r9amid) and tonumber(safe(function() return _G.__re4_item_count_sum(_r9inv, _r9amid) end)),
            t = os.clock() }
    end)

    -- Spaeter Pass: Clip-Transform + Handpose setzen -> gewinnt gegen Engine-Finger-Anim.
    local _r9_fade = {}
    local function r9_apply_pass()
        if not (RCFG.enabled and is_red9(get_equip_wid())) then return end
        r9_publish_dock(rack.joint)                           -- Hand-Dock pro Pass frisch (arm_chain liest hier)
        if rack_apply_z then rset_slide_z(rack_apply_z) end   -- [LATE-PASS] Slide-Z hier schreiben -> Engine clobbert nicht mehr
        local want, wthumb = nil, nil
        if rack.grabbed or rack.tune then
            want, wthumb = "Red9Slide", false                 -- linke Hand greift den Slide
        elseif (state.active or state.preview) and not rdrop.active then
            -- [SHELL-KEYFRAMES 2026-07-24] Keyframe-Preview -> Clip an die Tuning-Lage (relativ zur Waffe)
            -- statt an die Hand, damit man die Bahn am Desktop ausrichtet (VR- sieht ImGui nicht im Headset).
            local _kms = rawget(_G, "__re4_reload_mag_slide")
            if rawget(_G, "__re4_r9_kf_preview") and _kms and clip.obj then
                local sl = _kms.shell_live or {}
                local gtf = rget_gun_tf(); local gp = gtf and sc(gtf, "get_Position"); local gr = gtf and sc(gtf, "get_Rotation")
                local tf = safe(function() return clip.obj:call("get_Transform") end)
                if tf and gp and gr then
                    if clip.parented then pcall(function() tf:call("set_Parent", nil) end); clip.parented = false end
                    local off = safe(function() return gr * Vector3f.new(sl.x or 0, sl.y or 0, sl.z or 0) end)
                    local pos = off and Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z) or gp
                    local rot = safe(function() return (gr * quat_from_euler(sl.rx or 0, sl.ry or 0, sl.rz or 0)):normalized() end)
                    r9_set_tf(tf, pos, rot, RCFG.dscale or 1.0)
                end
            else
                r9_follow_to_hand()
            end
            -- Einzelpatrone (mode "single") nutzt EIGENE Pose Red9Single + st_*-Daumen; sonst Stripper-Clip
            want, wthumb = ((clip.mode == "single") and "Red9Single" or "Red9Clip"), true
        end
        -- [POSE_FADE] beim Loslassen ueber POSE_FADE_DUR zurueckblenden statt snappen (with_thumb als data)
        local fname, b, fthumb = _G.__re4_pose_fade_step(_r9_fade, want, wthumb)
        if fname then r9_apply_pose(fname, fthumb, b) end
    end
    pcall(function() re.on_pre_application_entry("LockScene", r9_apply_pass) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", r9_apply_pass) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", r9_apply_pass) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", r9_apply_pass) end)

    re.on_script_reset(function()
        state.active = false; state.preview = false; rdrop.active = false; insert.active = false
        if rack.joint and rack.rest_z ~= nil then rset_slide_z(rack.rest_z) end
        rack.grabbed = false; rack.tune = false; rack.open = false
        rack.settling = false; rack._dock_want = 1.0; rack._armed_up = true; rack._armed_dn = false; rack._last_apply_z = nil; rack._need_regrip = false; rack._grab_cd = 0
        rack.joint = nil; rack.rest_z = nil; rack.dock_blend = 0
        _G.__vr_block_fire_when_empty = false
        _G.__re4_bf_who = "re4_vr_reload5_dlc.lua:2733"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        _G.__vr_block_two_hand = false
        _G.__vr_slide_rack_active = false   -- [FL_RACK] Flag bei Script-Reset freigeben
        _G.__re4_reload_grab_empty = false
        _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil; _G.__vr_slide_dock_blend_factor = 0
        r9_destroy(); _rcm = nil
    end)

    -- ---- UI ----
    -- [UI-KAPERUNG 2026-07-19] Diese Zuweisung war HART und ohne Weiterleitung. Der Hook
    -- gehoert re4_vr_reload2.lua (dort definiert Z.4621, aufgerufen Z.3832) -- und reload5_dlc laedt
    -- ALPHABETISCH SPAETER, gewann also immer: LEONS Red9-UI war nicht mehr erreichbar, an ihrer
    -- Stelle stand die Samurai-Edge-Sektion. Seine JSON blieb zwar unangetastet, aber er konnte
    -- seine Red9 nicht mehr einstellen.
    -- Fix wie bei set_mag_in_hand: Vorgaenger sichern und ZUERST aufrufen -> Leons UI erscheint
    -- unveraendert, die DLC-Sektion haengt sich darunter. reload2.lua bleibt unberuehrt.
    -- [EIGENER UI-BAUM 2026-07-19] Kein Einhaengen in Leons reload2-Hook mehr -- eigenes File,
    -- eigener Haupttree, gleiches Namensschema wie Reload 4. reload2 bleibt unberuehrt.
    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion local function samurai_ui_body (110 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.

    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion Global-Zuweisung (1 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end
-- =====================================================================
-- ENDE SAMURAI-EDGE-GATTUNG
-- =====================================================================


-- =====================================================================
-- VIERTE GATTUNG: BLAST CROSSBOW (wp6102) -- Armbrust, 1 Bolzen
-- =====================================================================
-- [BOW 2026-07-19] Ablauf: Schuss -> Bolzen aus dem MAG-HOLSTER holen (Joint _04 folgt der
-- linken Hand) -> einlegen (Naehe zur Waffe) -> Sehne spannen: _01 UND _04 gemeinsam in Z zurueck
-- -> feuerbereit. Ohne Bolzen bzw. ungespannt ist Feuern gesperrt (Dry-Fire).
-- Kapazitaet 1: nach dem Schuss beginnt der Zyklus von vorn.
-- Eigene Persistenz: re4_vr/re4_vr_reload5_dlc_bow.json. Leons Boegen (4800/4801) sind bewusst
-- NICHT eingetragen -- dieses File fasst nur 6102 an.
-- =====================================================================
do
    local BOW_WID   = 6102
    local J_STRING  = "_01"     -- Sehne (wird gespannt)
    -- [GEMESSEN 2026-07-20] feste Anschlaege der Sehne (LocalPosition Z)
    local STRING_REST_Z  =  0.35594   -- entspannt (nach dem Schuss)
    local STRING_DRAWN_Z = -0.01500   -- voll gespannt
    -- [GEMESSEN] Bolzen _04 in der Waffe: z = 0.32000 (bei geladener Waffe); 0/0/0 = nicht gesetzt.
    local BOLT_LOADED_Z  =  0.32000
    local BOLT_LOADED_Y  =  0.11360
    local J_ARROW   = "_04"     -- Bolzen (aus dem Holster, faehrt mit der Sehne zurueck)
    -- [EINLEGEPUNKT 2026-07-20] Vom an der Waffe ausgemessen: Joint _03 + (0, 0.040, 0.118).
    -- Gegen DIESEN Punkt wird die Distanz des Bolzen-Klons gemessen (Einrast-Radius = insert_distance).
    local J_INSERT  = "_03"
    local BCFG_PATH = "re4_vr/re4_vr_reload5_dlc_bow.json"

    local BOWCFG = {
        enabled = true, reload_ammo = true, sound_enabled = true,
        draw_smooth = 0.5,   -- [ZUG] 1.0 = ungefiltert, kleiner = weicher
        dock_blend_speed = 0.12,   -- [DOCK] wie schnell die Hand an den Sehnengriff blendet
        -- [EINRAST-HALTEN 2026-07-20] Nach dem vollen Spannen die Hand noch kurz am Griff halten,
        -- statt sie sofort wegspringen zu lassen -- das liest sich als "einrasten". Sekunden.
        latch_hold_sec = 0.35,
        insert_distance = 0.15,
        -- [EINLEGE-DOCK 2026-07-20] Wo genau der Bolzen einrastet: Offset relativ zu Joint
        -- _03, im Waffen-Frame -- an der Waffe ausgemessen.
        insert_x = 0.0, insert_y = 0.040, insert_z = 0.118,
        draw_grab_dist  = 0.12,
        -- [GEMESSEN 2026-07-20] Sehne _01: Ruhe z = +0.35594, gespannt z = -0.01500
        -- -> Spannweg 0.37094 in -Z. (Platzhalter war -0.10, deshalb kam die Sehne nur ein Drittel weit.)
        draw_z          = -0.37094,
        draw_need       = 0.85,
        arrow_x = 0.0, arrow_y = 0.0, arrow_z = 0.0,
        arrow_rx = 0.0, arrow_ry = 0.0, arrow_rz = 0.0,
        -- [PART-KLON 2026-07-20] Nach dem Schuss existiert KEIN Bolzen-Joint mehr, den man an
        -- die Hand haengen koennte. Zuverlaessig ist dagegen der Mesh-Part -- derselbe Weg, den auch
        -- Hunting Rifle und Samurai Edge nutzen: einen Klon des Waffen-Meshes erzeugen, alle Parts
        -- ausser diesem ausblenden und das Ganze ans L_Hand-Joint parenten.
        arrow_part = 5,
        -- [SETUP-VORSCHAU 2026-07-20] Bolzen dauerhaft in der Hand zeigen, um Offsets zu stellen.
        arrow_preview = false,
        -- [BOLZEN-HANDPOSE] eigene KOPIE der Blacktail-Rackpose (ADAbowbolt), damit Tuning hier nichts
        -- an MAGRack veraendert. Leer = keine Pose erzwingen.
        arrow_pose = "ADAbowbolt",
        -- [DAUMEN 2026-07-20] additiv auf L_Thumb1, wie bei den Mag-Posen der anderen Waffen
        arrow_trx = 0.0, arrow_try = 0.0, arrow_trz = 0.0,
        -- [BOLZEN IN DER WAFFE 2026-07-20] Es gibt in der Waffe KEINEN Bolzen-Joint und keinen
        -- Mesh-Part, den man einblenden koennte -- der Bolzen existiert dort schlicht nicht. Deshalb
        -- bleibt beim Einlegen UNSER Klon bestehen und wird von der Hand an die Waffe umgehaengt.
        -- Diese Offsets legen ihn in die Laufrinne (Frame des Sehnen-Joints _01).
        gun_x = 0.0, gun_y = 0.0, gun_z = 0.0,
        gun_rx = 0.0, gun_ry = 0.0, gun_rz = 0.0,
        -- [EINLEG-BLEND 2026-07-20] Die Uebergabe Hand -> Laufrinne war ein harter Sprung (Parent-
        -- und Offset-Wechsel in EINEM Frame). Jetzt gleitet der Bolzen ueber diese Zeit von seiner letzten
        -- Hand-Pose in die Waffen-Pose (Position + Rotation, smoothstep). 0 = wieder hart wie vorher.
        insert_blend = 0.18,
        -- [SEHNEN-POSE 2026-07-19] Handpose, sobald die linke Hand an der Sehne ist bzw. zieht.
        -- Name einer gecaptureten Pose; leer = keine Pose erzwingen (Finger bleiben nativ).
        string_pose = "",
        string_pose_near = true,   -- true: Pose schon bei Naehe, false: erst beim Ziehen (Grip)
        -- [SEHNEN-DOCK 2026-07-19] Wohin genau die linke Hand an der Sehne greift: Position
        -- relativ zum Sehnen-Joint (_01) im Waffen-Frame + Rotation der Hand. Damit laesst sich die
        -- Hand exakt auf den Sehnengriff legen, ohne die Pose (Finger) anzufassen.
        dock_x = 0.0, dock_y = 0.0, dock_z = 0.0,
        dock_rx = 0.0, dock_ry = 0.0, dock_rz = 0.0,
        dock_preview = false,      -- Setup: Hand dauerhaft ans Dock legen, auch ohne Grip
        -- [SOUND 2026-07-20] IDs ausgemessen. draw_loop ist KEIN echter Loop, sondern
        -- ein kurzes Segment, das waehrend des Spannens im Intervall neu angespielt wird -- exakt das
        -- Muster vom Wild-West-Twirl (weapons2 ~Z.1914). snd_seg = Laenge eines Segments in Sekunden.
        snd_seg = 0.12,
        -- Der fallengelassene Bolzen bekommt seinen Aufprall-Sound verzoegert (Fallzeit bis zum Boden),
        -- genau wie das fallende Magazin bei den Pistolen.
        snd_drop_delay = 0.45,
    }
    local function bow_load_cfg()
        local d = safe(function() return json.load_file(BCFG_PATH) end)
        if type(d) ~= "table" then return end
        for k, v in pairs(d) do
            if BOWCFG[k] ~= nil and type(v) == type(BOWCFG[k]) then BOWCFG[k] = v end
        end
    end
    local function bow_save_cfg() pcall(function() json.dump_file(BCFG_PATH, BOWCFG) end) end
    bow_load_cfg()

    local bwep = { wid = nil, tf = nil, sj = nil, aj = nil, s_rest = nil, a_rest = nil }
    local bow  = { arrow_in_hand = false, loaded = false, drawn = false,
                   frac = 0.0, grab = false, anchor = nil, prev_grip = false, dock_blend = 0.0,
                   latch_t = nil }
    -- [PART-KLON] sichtbarer Bolzen in der Hand (Mesh-Kopie, Muster wie r9_spawn/r9_isolate)
    local bclone = { obj = nil, mesh = nil, parented = false, in_gun = false }

    -- [EIGENE HELFER 2026-07-19] left_grip_down/left_hand_world sind LOKAL im Samurai-Block
    -- (do...end) und ausserhalb davon nicht sichtbar -> Laufzeitfehler "global 'left_grip_down' is
    -- not callable". Deshalb hier eigene, inhaltlich identische Fassungen.
    local function bow_left_grip_down()
        if not vrmod then return false end
        local act, lj
        pcall(function() act = vrmod:get_action_grip() end)
        pcall(function() lj  = vrmod:get_left_joystick() end)
        if not (act and lj) then return false end
        local ok, v = pcall(function() return vrmod:is_action_active(act, lj) end)
        return ok and v == true
    end
    local function bow_left_hand_world()
        return rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
    end
    -- [ROHER CONTROLLER 2026-07-20] Fuer den SPANN-ZUG zwingend die unverschobene Controller-
    -- Position: sobald das Sehnen-Dock greift, ist __vr_lh_world die GEDOCKTE Hand (also unsere eigene
    -- Vorgabe) -- der Zug haette sich dann selbst gemessen und wirkte snappy statt dem Controller zu
    -- folgen. Gleiche Ursache wie beim Messer-Holster.
    local function bow_ctrl_raw()
        return rawget(_G, "__vr_lh_ctrl_raw") or bow_left_hand_world()
    end

    local function is_bow(wid) return wid == BOW_WID end

    -- ---- [PART-KLON] Bolzen als Mesh-Kopie an der linken Hand ------------------------------
    local function bow_gun_mesh()
        local cm  = sdk.get_managed_singleton("chainsaw.CharacterManager")
        local ctx = safe(function() return cm and cm:call("getPlayerContextRef") end)
        local hu  = ctx and sc(ctx, "get_HeadUpdater")
        local gun = hu and sc(hu, "get_EquipWeapon")
        return gun and safe(function() return gun:call("get_Mesh") end)
    end
    local function bow_clone_destroy()
        if bclone.obj then pcall(function()
            local td = sdk.find_type_definition("via.GameObject")
            local d = td and td:get_method("destroy(via.GameObject)")
            if d then d:call(nil, bclone.obj) end
        end) end
        bclone.obj, bclone.mesh, bclone.parented, bclone.in_gun = nil, nil, false, false
        bclone.from, bclone.blend = nil, 1.0   -- [EINLEG-BLEND] kein Rest-Blend fuer den naechsten Bolzen
    end
    local function bow_clone_spawn()
        if bclone.obj then return true end
        local gmesh = bow_gun_mesh(); if not gmesh then return false end
        local holder = safe(function() return gmesh:call("getMesh") end); if not holder then return false end
        local gmat = safe(function() return gmesh:call("get_Material") end)
        local go_td = sdk.find_type_definition("via.GameObject")
        local create = go_td and go_td:get_method("create(System.String)")
        local go = create and safe(function() return create:call(nil, "vr_bow_bolt") end); if not go then return false end
        pcall(function() go:add_ref() end)
        pcall(function() go:call("createComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)
        local mesh = safe(function() return go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
        if not mesh then return false end
        pcall(function() mesh:call("setMesh", holder) end)
        if gmat then pcall(function() mesh:call("set_Material", gmat) end) end
        pcall(function() mesh:call("set_DrawDefault", true) end)
        pcall(function() mesh:call("set_Enabled", true) end)
        pcall(function() mesh:call("set_FrustumCulling", false) end)
        bclone.obj, bclone.mesh = go, mesh
        -- nativ ans L_Hand parenten -> kein Render-Versatz beim Laufen, danach nur lokale Pose
        local ctf = safe(function() return go:call("get_Transform") end)
        local bt2 = body_tf()
        if ctf and bt2 then
            pcall(function() ctf:call("set_Parent", bt2) end)
            if pcall(function() ctf:call("set_ParentJoint", "L_Hand") end) then bclone.parented = true end
        end
        -- nur den Bolzen-Part sichtbar lassen
        local keep = tonumber(BOWCFG.arrow_part) or 5
        for i = 0, 40 do pcall(function() mesh:call("setPartsEnable", i, i == keep) end) end
        return true
    end
    local function bow_clone_pose()
        if not bclone.obj then return end
        local ctf = safe(function() return bclone.obj:call("get_Transform") end); if not ctf then return end
        local px, py, pz, rx, ry, rz
        if bclone.in_gun then
            px, py, pz = BOWCFG.gun_x, BOWCFG.gun_y, BOWCFG.gun_z
            rx, ry, rz = BOWCFG.gun_rx, BOWCFG.gun_ry, BOWCFG.gun_rz
        else
            px, py, pz = BOWCFG.arrow_x, BOWCFG.arrow_y, BOWCFG.arrow_z
            rx, ry, rz = BOWCFG.arrow_rx, BOWCFG.arrow_ry, BOWCFG.arrow_rz
        end
        local rq = quat_from_euler(rx, ry, rz)
        -- [EINLEG-BLEND 2026-07-20] Laeuft ein Blend (beim Umhaengen gesetzt), von der gemerkten
        -- Start-Pose in die Ziel-Pose gleiten -- beide bereits im NEUEN Parent-Frame (_01), also reine
        -- lokale Interpolation. smoothstep = weiches An- und Auslaufen. Rotation als nlerp mit Vorzeichen-
        -- Korrektur (kuerzester Weg); nach dem Blend laeuft alles exakt wie vorher.
        if bclone.from and (bclone.blend or 1.0) < 1.0 then
            local dur = tonumber(BOWCFG.insert_blend) or 0.0
            local t = (dur > 0.001) and ((os.clock() - (bclone.blend_t0 or 0)) / dur) or 1.0
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            bclone.blend = t
            local s = t * t * (3.0 - 2.0 * t)
            local f = bclone.from
            px = f.px + (px - f.px) * s
            py = f.py + (py - f.py) * s
            pz = f.pz + (pz - f.pz) * s
            if rq and f.q then
                local q0 = f.q
                local dot = q0.x*rq.x + q0.y*rq.y + q0.z*rq.z + q0.w*rq.w
                local sg = (dot < 0) and -1.0 or 1.0
                local nq = safe(function()
                    return Quaternion.new(q0.w*(1-s) + rq.w*sg*s, q0.x*(1-s) + rq.x*sg*s,
                                          q0.y*(1-s) + rq.y*sg*s, q0.z*(1-s) + rq.z*sg*s):normalized()
                end)
                if nq then rq = nq end
            end
            if t >= 1.0 then bclone.from = nil end
        end
        pcall(function() ctf:call("set_LocalPosition", Vector3f.new(px, py, pz)) end)
        if rq then pcall(function() ctf:call("set_LocalRotation", rq) end) end
        pcall(function() ctf:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
    end

    local function bow_refresh()
        local wid = get_equip_wid()
        if not is_bow(wid) then bwep.wid = nil; bwep.tf = nil; bwep.sj = nil; bwep.aj = nil; return end
        if bwep.wid ~= wid or not bwep.tf then
            local go = find_weapon(wid)
            bwep.wid = wid
            bwep.tf  = go and safe(function() return go:call("get_Transform") end) or nil
            bwep.sj, bwep.aj, bwep.s_rest, bwep.a_rest = nil, nil, nil, nil
        end
        if not bwep.tf then return end
        if not bwep.sj then
            bwep.sj = sc(bwep.tf, "getJointByName", J_STRING)
            local lp = bwep.sj and sc(bwep.sj, "get_LocalPosition")
            -- [RUHE HARTKODIERT 2026-07-20] Die Ruhelage NICHT live uebernehmen: wird sie
            -- erfasst, waehrend die Sehne schon gespannt ist (z = -0.015), rechnet der Zug von dort
            -- nochmal den vollen Weg -> die Sehne landete bei -0.386, weit hinter dem Anschlag.
            -- Gemessene Werte: Ruhe z = 0.35594, gespannt z = -0.01500 (x/y bleiben live).
            if lp then bwep.s_rest = { x = lp.x, y = lp.y, z = STRING_REST_Z } end
        end
        if not bwep.aj then
            bwep.aj = sc(bwep.tf, "getJointByName", J_ARROW)
            local lp = bwep.aj and sc(bwep.aj, "get_LocalPosition")
            if lp then bwep.a_rest = { x = lp.x, y = lp.y, z = lp.z } end
        end
    end

    local function bow_wi()
        local pe = get_pe(); return pe and safe(function() return pe:call("getEquipWeaponItem") end)
    end
    local function bow_loaded()
        local pe = get_pe()
        return tonumber(pe and safe(function() return pe:call("getCurrentGunAmmo") end)) or 0
    end
    local function bow_reserve()
        local wi = bow_wi(); if not wi then return 0 end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
        local aid = safe(function() return wi:call("get_CurrentAmmo") end)
        if not (inv and aid) then return 0 end
        return tonumber(safe(function() return _G.__re4_item_count_sum(inv, aid) end)) or 0
    end

    -- [BOW-DIAG 2026-07-20 STILLGELEGT 2026-07-21] Kein Dateischreiben mehr (re4_bow_diag.log ist raus);
    -- die verbliebenen Aufrufstellen laufen als No-Op ins Leere.
    local function bow_log() end

    -- ---- [SOUND 2026-07-20] --------------------------------------------------------------
    -- Alle IDs ausgemessen; gespielt wird auf dem SoundContainer der Waffe (gleiches Muster
    -- wie rf_snd/r9_play_sound weiter oben).
    local BOWSND = {
        dry_fire     = 812850326,    -- RT gezogen ohne Bolzen ODER ohne gespannte Sehne
        drop_floor   = 3732631409,   -- fallengelassener Bolzen schlaegt auf dem Boden auf
        insert       = 1839787494,   -- Bolzen wird in die Waffe gelegt
        draw_seg     = 3331890328,   -- Segment beim Spannen der Sehne (im Intervall wiederholt)
        holster_grab = 3042341191,   -- Bolzen aus dem Holster geholt
    }
    local bsnd_td = sdk.typeof("soundlib.SoundContainer")
    local function bow_snd(id)
        if not BOWCFG.sound_enabled or not id then return end
        local tf = bwep.tf; if not (tf and bsnd_td) then return end
        local go = safe(function() return tf:call("get_GameObject") end); if not go then return end
        local scn = safe(function() return go:call("getComponent(System.Type)", bsnd_td) end); if not scn then return end
        pcall(function() scn:call("trigger(System.UInt32)", id) end)
    end
    local bow_snd_state = { next_seg = 0, drop_at = 0, dry_prev = false }

    local function bow_set_arrow_in_hand(active)
        bow_log(string.format("AUFRUF active=%s | enabled=%s wid=%s drawn=%s in_hand=%s loaded=%s reserve=%s",
            tostring(active), tostring(BOWCFG.enabled), tostring(bwep.wid), tostring(bow.drawn),
            tostring(bow.arrow_in_hand), tostring(bow.loaded), tostring(bow_reserve())))
        if not (BOWCFG.enabled and bwep.wid) then return false end
        if active then
            if bow.arrow_in_hand or bow.loaded then return false end
            -- [ERST SPANNEN 2026-07-20] Die gespannte Sehne ist das Signal, dass ein Bolzen
            -- geholt werden darf -- vorher gibt der Mag-Holster nichts her.
            if not bow.drawn then bow_log("  -> ABGELEHNT: Sehne nicht gespannt"); return false end
            if bow_reserve() <= 0 then return false end   -- keine Reserve -> nichts zu holen
            bow.arrow_in_hand = true
            bow_clone_spawn()          -- [PART-KLON] sichtbarer Bolzen an die Hand
            bow_snd(BOWSND.holster_grab)
            bow_log("  -> BOLZEN IN HAND (Klon=" .. tostring(bclone.obj ~= nil) .. ")")
            return true
        end
        -- [DROP-SOUND] Losgelassen, ohne eingelegt zu haben -> der Bolzen faellt zu Boden. Der
        -- Aufprall kommt verzoegert (Fallzeit), sonst klingt er direkt an der Hand.
        if bow.arrow_in_hand and not bclone.in_gun then
            bow_snd_state.drop_at = os.clock() + (tonumber(BOWCFG.snd_drop_delay) or 0.45)
        end
        bow.arrow_in_hand = false
        if not bclone.in_gun then bow_clone_destroy() end   -- in der Waffe: bleibt stehen
        return true
    end
    local _orig_bow = _G.__re4_reload_set_mag_in_hand
    _G.__re4_reload_set_mag_in_hand = function(active)
        if is_bow(get_equip_wid()) then return bow_set_arrow_in_hand(active) end
        if _orig_bow then return _orig_bow(active) end
        return false
    end

    local function bow_apply()
        if not (BOWCFG.enabled and bwep.wid and bwep.tf) then return end
        -- [SEHNE HALTEN 2026-07-20] Der Bolzen-in-Hand-Zweig ist frueher mit return ausgestiegen
        -- -> die gespannte Sehne wurde nicht mehr geschrieben und die Engine hat sie nach vorne
        -- zurueckgestellt (sichtbar: Sehne snappt beim Griff zum Holster auf). Jetzt wird der Bolzen
        -- an die Hand gesetzt UND die Sehne weiter auf ihrer Position gehalten.
        if bow.arrow_in_hand or bclone.in_gun or (BOWCFG.arrow_preview and bclone.obj) then
            -- [PART-KLON] Der Klon haengt nativ am L_Hand-Joint -> nur die LOKALE Pose setzen.
            bow_clone_pose()
            if bwep.sj and bwep.s_rest and (bow.frac or 0) > 0.001 then
                local zz = STRING_REST_Z + (STRING_DRAWN_Z - STRING_REST_Z) * bow.frac
                if zz < STRING_DRAWN_Z then zz = STRING_DRAWN_Z end
                if zz > STRING_REST_Z  then zz = STRING_REST_Z  end
                pcall(function() bwep.sj:call("set_LocalPosition",
                    Vector3f.new(bwep.s_rest.x, bwep.s_rest.y, zz)) end)
            end
            return
        end
        -- [NUR WENN WIR DRAN SIND 2026-07-19] Solange wir weder einen Bolzen in der Hand halten
        -- noch am Spannen sind, GAR NICHTS schreiben -- die Engine stellt Sehne und Bolzen selbst
        -- korrekt dar (HUD zeigt geladen -> nativ ist gespannt). Vorher hat dieser Pass beide Joints
        -- jeden Frame auf die beim ersten Frame erfassten Ruhelagen gezwungen: Sehne entspannt,
        -- Bolzen an einer alten Position unter der Waffe.
        if not bow.grab and (bow.frac or 0.0) <= 0.001 then return end
        -- [ANSCHLAG 2026-07-20] Zielposition zwischen den beiden GEMESSENEN Anschlaegen
        -- interpolieren und hart klemmen -- so kann die Sehne konstruktiv nie hinter den gespannten
        -- Punkt rutschen, egal was Ruhelage oder frac gerade behaupten.
        local zt = STRING_REST_Z + (STRING_DRAWN_Z - STRING_REST_Z) * (bow.frac or 0.0)
        if zt < STRING_DRAWN_Z then zt = STRING_DRAWN_Z end
        if zt > STRING_REST_Z  then zt = STRING_REST_Z  end
        local z = zt - STRING_REST_Z   -- fuer den Bolzen-Zweig weiter unten (relativ)
        if bwep.sj and bwep.s_rest then
            pcall(function() bwep.sj:call("set_LocalPosition",
                Vector3f.new(bwep.s_rest.x, bwep.s_rest.y, zt)) end)
        end
        -- [BOLZEN SELBST SETZEN 2026-07-20] Die Engine stellt den geladenen Bolzen NICHT dar:
        -- _04 bleibt auf 0/0/0, weil sie ihn nur ueber ihre native Ladeanimation setzt -- und die
        -- spielen wir nie ab. Also selbst auf die GEMESSENE Ladeposition schreiben, solange geladen.
        -- (Der Bolzen in der HAND ist ein eigener Mesh-Klon und davon unberuehrt.)
        if bow.loaded then
            -- [KEIN CACHE 2026-07-20] Den Bolzen-Joint JEDEN Pass frisch aufloesen: er existiert
            -- erst wieder, wenn ein Bolzen geladen ist -- ein einmal gecachter (toter) Zeiger zeigte
            -- ins Leere, waehrend der Dump den echten Joint mit 0/0/0 las.
            local aj = sc(bwep.tf, "getJointByName", J_ARROW) or bwep.aj
            if aj then
                bwep.aj = aj
                pcall(function() aj:call("set_LocalPosition",
                    Vector3f.new(0.0, BOLT_LOADED_Y, BOLT_LOADED_Z)) end)
            end
            --... UND den Mesh-Part wieder einschalten: nach dem Schuss blendet die Engine den
            -- Bolzen-Part aus, deshalb blieb die Rinne leer, obwohl Ammo 1 war.
            -- [DOPPELTER BOLZEN 2026-08-13] Nur einschalten, solange KEIN eigener Klon in der Waffe
            -- liegt. Beim manuellen Einlegen bleibt unser Mesh-Klon in der Laufrinne stehen (in_gun),
            -- und dieser native Part kam zusaetzlich dazu -- sichtbar als zweiter Pfeil darunter.
            -- Beides zeigt denselben Bolzen, also darf immer nur eines an sein: Klon in der Waffe ->
            -- Part aus; kein Klon (z.B. nach dem Schuss oder nach einem Engine-Reload) -> Part an,
            -- damit die Rinne nicht leer aussieht.
            local gm = bow_gun_mesh()
            if gm then
                local part = tonumber(BOWCFG.arrow_part) or 5
                pcall(function() gm:call("setPartsEnable", part, true) end)
            end
        end
    end

    local _bow_prev_wid, _bow_prev_loaded = nil, nil
    re.on_frame(function()
        bow_refresh()
        if not (BOWCFG.enabled and bwep.wid) then
            if _bow_prev_wid then
                _G.__vr_block_fire_when_empty = false
                _G.__re4_bf_who = "re4_vr_reload5_dlc.lua:3252"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
                _G.__vr_needs_rack = false
                _G.__vr_mag_in_hand = false
                _G.__re4_reload_grab_empty = false
                _G.__vr_rack_hand_pose = nil
                _G.__vr_mag_hand_pose = nil
                _G.__vr_mag_hand_trx, _G.__vr_mag_hand_try, _G.__vr_mag_hand_trz = nil, nil, nil
                _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil
                _G.__vr_slide_dock_blend_factor = 0; _G.__vr_slide_rack_active = false
                bow.arrow_in_hand = false; bow_clone_destroy()
                bow.loaded = false; bow.drawn = false; bow.frac = 0.0
                _bow_prev_wid = nil
            end
            return
        end
        _bow_prev_wid = bwep.wid

        local ld = bow_loaded()
        if _bow_prev_loaded and ld < _bow_prev_loaded then
            bow.loaded = false; bow.drawn = false; bow.frac = 0.0
            bow_clone_destroy()   -- [BOLZEN IN DER WAFFE] verschossen -> Klon weg
        end
        _bow_prev_loaded = ld
        bow.loaded = (ld > 0)   -- [ENGINE IST DIE WAHRHEIT 2026-07-20] strikt aus getCurrentGunAmmo

        -- [ZUSTANDS-LOG 2026-07-20 ENTFERNT 2026-07-21] Lief jeden Frame (string.format + bow_reserve
        -- = Inventar-Summe pro Frame) nur fuer re4_bow_diag.log.

        if bow.arrow_in_hand and bwep.tf then
            -- [EINLEGEPUNKT] Gemessen wird die Position des BOLZEN-KLONS (nicht die Handmitte) gegen
            -- den Einlegepunkt an der Waffe: Joint _03 + Offset. Beides Weltpositionen.
            local hp
            if bclone.obj then
                local ctf = safe(function() return bclone.obj:call("get_Transform") end)
                hp = ctf and safe(function() return ctf:call("get_Position") end)
            end
            if not hp then hp = bow_left_hand_world() end
            local wp
            do
                local ij = sc(bwep.tf, "getJointByName", J_INSERT)
                local jp = ij and safe(function() return ij:call("get_Position") end)
                local jr = ij and safe(function() return ij:call("get_Rotation") end)
                if jp then
                    local off = jr and safe(function() return jr * Vector3f.new(BOWCFG.insert_x, BOWCFG.insert_y, BOWCFG.insert_z) end)
                    wp = off and Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z) or jp
                end
            end
            if not wp then wp = safe(function() return bwep.tf:call("get_Position") end) end
            _G.__re4_bow_insert_dist = (hp and wp) and
                math.sqrt((hp.x-wp.x)^2 + (hp.y-wp.y)^2 + (hp.z-wp.z)^2) or nil
            if hp and wp then
                local dx, dy, dz = hp.x - wp.x, hp.y - wp.y, hp.z - wp.z
                if math.sqrt(dx*dx + dy*dy + dz*dz) <= (BOWCFG.insert_distance or 0.15) then
                    bow.arrow_in_hand = false
                    -- [BOLZEN IN DER WAFFE] Klon NICHT zerstoeren, sondern an die Waffe umhaengen.
                    if bclone.obj and bwep.tf then
                        local ctf = safe(function() return bclone.obj:call("get_Transform") end)
                        if ctf then
                            -- [EINLEG-BLEND 2026-07-20] Weltpose des Bolzens NOCH IN DER HAND merken --
                            -- direkt vor dem Umhaengen. Danach in den neuen Parent-Frame (Sehnen-Joint _01)
                            -- umgerechnet: so kann bow_clone_pose rein lokal von dort in die Laufrinnen-Pose
                            -- gleiten statt in einem Frame dorthin zu springen.
                            local wp0 = safe(function() return ctf:call("get_Position") end)
                            local wr0 = safe(function() return ctf:call("get_Rotation") end)
                            local ok1 = pcall(function() ctf:call("set_Parent", bwep.tf) end)
                            local ok2 = pcall(function() ctf:call("set_ParentJoint", J_STRING) end)
                            bclone.in_gun = true
                            bclone.from, bclone.blend = nil, 1.0
                            do
                                local jp = bwep.sj and safe(function() return bwep.sj:call("get_Position") end)
                                local jr = bwep.sj and safe(function() return bwep.sj:call("get_Rotation") end)
                                if wp0 and wr0 and jp and jr and (tonumber(BOWCFG.insert_blend) or 0) > 0.001 then
                                    local qc = Quaternion.new(jr.w, -jr.x, -jr.y, -jr.z)   -- Inverse (Einheitsquat)
                                    local lp = safe(function() return qc * Vector3f.new(wp0.x - jp.x, wp0.y - jp.y, wp0.z - jp.z) end)
                                    local lq = safe(function() return (qc * Quaternion.new(wr0.w, wr0.x, wr0.y, wr0.z)):normalized() end)
                                    if lp and lq and type(lp.x) == "number" then
                                        bclone.from = { px = lp.x, py = lp.y, pz = lp.z, q = lq }
                                        bclone.blend, bclone.blend_t0 = 0.0, os.clock()
                                    end
                                end
                            end
                            bow_log(string.format("  -> UMGEHAENGT an Waffe: set_Parent=%s set_ParentJoint=%s obj=%s mesh=%s",
                                tostring(ok1), tostring(ok2), tostring(bclone.obj ~= nil), tostring(bclone.mesh ~= nil)))
                        else
                            bow_log("  -> UMHAENGEN FEHLGESCHLAGEN: kein Transform am Klon")
                        end
                    else
                        bow_log(string.format("  -> UMHAENGEN UEBERSPRUNGEN: klon=%s wep_tf=%s",
                            tostring(bclone.obj ~= nil), tostring(bwep.tf ~= nil)))
                    end
                    bow_snd(BOWSND.insert)
                    -- [ENGINE IST DIE WAHRHEIT 2026-07-20] bow.loaded NICHT hart setzen: es wurde
                    -- auch dann true, wenn die Ammo-Buchung fehlschlug -> Holster sperrte ("schon geladen"),
                    -- geschossen werden konnte mangels Munition trotzdem nicht. loaded kommt jetzt
                    -- ausschliesslich aus getCurrentGunAmmo (siehe on_frame).
                    -- [SPANNUNG BLEIBT] drawn/frac bleiben unangetastet -- zuerst spannen, dann einlegen.
                    if BOWCFG.reload_ammo then
                        -- [EQUIPTYPE STATT AMMO-ID 2026-07-20] safe_inv_reload erwartet
                        -- chainsaw.EquipType.Main -- ich hatte die Ammo-ID uebergeben, deshalb wurde nie
                        -- gebucht (ammo blieb 0). Exakt der Pfad, mit dem bolt_add_one nachweislich laedt.
                        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
                        local et
                        do
                            local td = sdk.find_type_definition("chainsaw.EquipType")
                            local f = td and td:get_field("Main")
                            if f then et = f:get_data(nil) end
                        end
                        if inv and et and _G.__re4_safe_inv_reload then
                            pcall(function() _G.__re4_load_and_book(inv, et, 1, false) end)
                            bow_log("  -> AMMO GEBUCHT (inv:reload EquipType.Main +1)")
                            -- [DOPPELTER BOLZEN 2026-08-13] Ab dieser Sekunde hat die WAFFE einen
                            -- geladenen Bolzen und stellt ihn selbst dar. Unser Klon war bis hierher
                            -- die Anzeige waehrend des Einlegens -- laesst man ihn stehen, sieht man
                            -- beide (der Klon haengt am Sehnen-Joint und schwebt unter der Waffe).
                            -- Das Log belegt: es gibt nur EINEN Klon, er wird nur zu spaet zerstoert.
                            -- Also genau hier weg, statt den nativen Part zu unterdruecken.
                            bow_clone_destroy()
                        else
                            bow_log(string.format("  -> AMMO NICHT GEBUCHT: inv=%s et=%s",
                                tostring(inv ~= nil), tostring(et ~= nil)))
                        end
                    end
                end
            end
        end

        -- [STAGGER_HEAL 2026-07-20] Wird man mitten im Spannen getroffen, bricht der Zug ab und
        -- die Sehne bliebe auf einem Zwischenwert stehen ("halb acht") -- dasselbe Problem, das die
        -- Pistolen-Slides hatten. Auf der FALLENDEN Flanke von __re4_damage_active daher definiert
        -- aufraeumen: nicht fertig gespannt -> zurueck in die Ruhe; fertig gespannt -> bleibt gespannt.
        do
            local dmg = rawget(_G, "__re4_damage_active") == true
            if bow._prev_dmg and not dmg then
                if not bow.drawn then
                    bow.frac = 0.0
                    bow.grab = false; bow.anchor = nil
                    bow_log("STAGGER: Zug abgebrochen -> Sehne zurueck in Ruhe")
                else
                    bow.frac = 1.0
                    bow_log("STAGGER: war gespannt -> bleibt gespannt")
                end
            end
            -- Waehrend des Staggers keinen neuen Zug starten und den laufenden einfrieren.
            if dmg then bow.grab = false; bow.anchor = nil end
            bow._prev_dmg = dmg
        end

        -- [SOUND-TICK] (a) faelliger Boden-Aufprall des fallengelassenen Bolzens,
        -- (b) Spann-Segment: solange die Sehne unter Zug WAECHST, das kurze Segment im Intervall neu
        -- anspielen (es ist kein echter Loop) -- Muster wie der Twirl-Sound.
        do
            local now = os.clock()
            if bow_snd_state.drop_at > 0 and now >= bow_snd_state.drop_at then
                bow_snd_state.drop_at = 0; bow_snd(BOWSND.drop_floor)
            end
            local drawing = bow.grab and not bow.drawn
            if drawing then
                if now >= (bow_snd_state.next_seg or 0) then
                    bow_snd(BOWSND.draw_seg)
                    bow_snd_state.next_seg = now + math.max(0.03, tonumber(BOWCFG.snd_seg) or 0.12)
                end
            else
                bow_snd_state.next_seg = 0   -- naechster Zug spielt sofort
            end
        end
        -- [DRY-FIRE] Kein Bolzen drin ODER Sehne nicht gespannt -> Feuern ist gesperrt
        -- (__vr_block_fire_when_empty weiter unten), binding.lua meldet den gezogenen Trigger.
        do
            local et = rawget(_G, "__re4_empty_trigger_held") == true
            if et and not bow_snd_state.dry_prev then bow_snd(BOWSND.dry_fire) end
            bow_snd_state.dry_prev = et
        end

        local grip = bow_left_grip_down()
        local sp   = bwep.sj and safe(function() return bwep.sj:call("get_Position") end)
        -- [ZWEI POSITIONEN 2026-07-20] Bewusst getrennt:
        -- near -> SICHTBARE Hand (bow_left_hand_world): sie steht am Griff, danach richtet sich,
        -- ob man ueberhaupt greifen darf. Mit der rohen Controller-Pos war der Abstand ein
        -- ganz anderer -> near wurde nie wahr und das Greifen war tot.
        -- Zug -> ROHER Controller (bow_ctrl_raw): sobald das Dock greift, ist die sichtbare Hand
        -- unsere eigene Vorgabe und wuerde sich selbst messen (snappy).
        local hvis = bow_left_hand_world()
        local hp   = bow_ctrl_raw()
        local near = false
        if sp and hvis then
            local dx, dy, dz = hvis.x - sp.x, hvis.y - sp.y, hvis.z - sp.z
            near = math.sqrt(dx*dx + dy*dy + dz*dz) <= (BOWCFG.draw_grab_dist or 0.12)
        end
        bow._near_dbg = near   -- [ZUSTANDS-LOG]
        -- [KEIN ZURUECK 2026-07-20] Ist die Sehne einmal gespannt, laesst sie sich nicht wieder
        -- greifen: sonst schiebt man sie nach vorne und die linke Hand wird dabei extrem gestreckt.
        -- Zurueck geht sie nur durch den Schuss.
        -- [NACHGREIFEN ERLAUBT 2026-07-20] Frueher sperrte bow.drawn das Greifen komplett --
        -- damit liess sich die Sehne nach dem ersten Spannen NIE wieder anfassen (auch nicht, wenn
        -- die Engine sie zwischendurch zurueckgestellt hatte). Jetzt darf immer gegriffen werden;
        -- gegen das Nach-vorne-Schieben schuetzt stattdessen die Einbahn-Regel weiter unten:
        -- frac kann nur WACHSEN, nie kleiner werden.
        local grip_edge = grip and not bow.prev_grip
        -- [GESPANNT = FERTIG 2026-07-20] Ist die Sehne einmal gespannt, ist sie durch: kein
        -- erneutes Greifen mehr (die Einbahn-Regel allein reichte nicht -- das Dock zog die Hand
        -- weiterhin an den Griff). Geloest wird sie ausschliesslich durch den Schuss.
        -- [KEIN SPANNEN OHNE BOLZEN 2026-07-20] 0 geladen UND 0 Reserve -> die Sehne laesst sich
        -- gar nicht erst greifen (sinnlos spannen, wenn nichts zu verschiessen ist). Beide Werte live aus
        -- der Engine (getCurrentGunAmmo / Reserve), kein Script-Zustand. Sobald wieder Bolzen da sind,
        -- geht es normal weiter.
        local bow_has_ammo = (bow_loaded() > 0) or (bow_reserve() > 0)
        if grip_edge and near and not bow.drawn and not bow.arrow_in_hand and bow_has_ammo then
            bow.grab = true; bow.anchor = hp and Vector3f.new(hp.x, hp.y, hp.z) or nil
        elseif not grip then
            bow.grab = false; bow.anchor = nil
        end
        bow.prev_grip = grip
        if bow.drawn and not bow.grab then
            bow.frac = 1.0            -- gespannt bleibt gespannt (nur der Schuss loest sie)
        elseif bow.grab and bow.anchor and hp then
            -- [ZUG ENTLANG DER WAFFE 2026-07-19] Vorher: 3D-Distanz zum Greifpunkt -> JEDE
            -- Handbewegung (auch seitlich/hoch) hat gespannt, das wirkte snappy und unkontrollierbar.
            -- Jetzt wird die Handbewegung auf die WAFFENACHSE projiziert (Skalarprodukt): nur der
            -- Anteil nach hinten entlang der Waffe zaehlt, alles andere wird ignoriert -> die Sehne
            -- folgt 1:1 der Controllerbewegung.
            local dx, dy, dz = hp.x - bow.anchor.x, hp.y - bow.anchor.y, hp.z - bow.anchor.z
            local pull = 0.0
            local wr = safe(function() return bwep.tf:call("get_Rotation") end)
            local ax = wr and safe(function() return wr * Vector3f.new(0, 0, 1) end)
            if ax then
                local al = math.sqrt(ax.x*ax.x + ax.y*ax.y + ax.z*ax.z)
                if al > 1e-6 then
                    -- Sehne faehrt in -Z (gespannt z=-0.015 gegen Ruhe z=+0.356) -> Zug nach hinten
                    -- ist die NEGATIVE Achsrichtung; darum das Minus.
                    pull = -((dx*ax.x + dy*ax.y + dz*ax.z) / al)
                end
            else
                pull = math.sqrt(dx*dx + dy*dy + dz*dz)   -- Fallback wie bisher
            end
            if pull < 0.0 then pull = 0.0 end
            local full = math.abs(BOWCFG.draw_z or 0.10)
            local target = math.min(1.0, (full > 0.001) and (pull / full) or 0.0)
            -- leichte Glaettung gegen Controller-Jitter, ohne spuerbare Verzoegerung
            local sm = tonumber(BOWCFG.draw_smooth) or 0.5
            -- [EINBAHN] nur nach hinten: ein kleinerer Zielwert wird ignoriert -> die Sehne laesst
            -- sich nicht nach vorne schieben (das macht allein der Schuss).
            if target > bow.frac then
                bow.frac = bow.frac + (target - bow.frac) * sm
            end
            -- [EINRASTEN 2026-07-20] NICHT an bow.loaded knuepfen: bei der Armbrust wird ZUERST
            -- gespannt und DANN der Bolzen eingelegt. Mit der alten Bedingung rastete die Sehne ohne
            -- Bolzen nie ein und schnellte beim Loslassen zurueck.
            if bow.frac >= (BOWCFG.draw_need or 0.85) then bow.drawn = true; bow.frac = 1.0 end
        elseif not bow.drawn then
            bow.frac = 0.0
        else
            bow.frac = 1.0
        end

        -- [KRITISCHES GATE — LIVE 2026-07-20] Feuer-Block NUR bei echt leerer Waffe. Vorher stand hier
        -- `not (bow.loaded and bow.drawn)` -- beides SCRIPT-Flags: stand die Sehne aus Sicht des Scripts nicht
        -- auf "drawn" (oder bow.loaded stale), war trotz Bolzen im Lauf Dauer-Dry-Fire. Regel:
        -- steht in der aktuellen Munition (nicht Reserve) eine 1, wird NIE gesperrt. Quelle daher die frische
        -- Engine-Ammo (getCurrentGunAmmo, jeden Frame), kein Script-Zustand.
        _G.__vr_block_fire_when_empty = (bow_loaded() <= 0)
        _G.__re4_bf_who = "re4_vr_reload5_dlc.lua:3517"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        -- [KEIN needs_rack 2026-07-19] __vr_needs_rack NICHT setzen: motion.lua reisst damit die
        -- Support-Hand sofort vom Dock (dort ist es das Signal "Hand muss zum Slide"). Bei der Armbrust
        -- spannt dieselbe linke Hand ohnehin an Ort und Stelle -- das Flag kostete nur die Support-Hand.
        _G.__vr_needs_rack            = false
        _G.__vr_mag_in_hand           = bow.arrow_in_hand and true or false
        -- [SETUP-VORSCHAU] Klon auch ohne Holster-Griff zeigen, solange die Vorschau an ist.
        if BOWCFG.arrow_preview and not bow.arrow_in_hand then
            bow_clone_spawn()
        elseif not BOWCFG.arrow_preview and not bow.arrow_in_hand and bclone.obj and not bclone.in_gun then
            -- [NICHT IN DER WAFFE 2026-07-20] in_gun MUSS hier geprueft werden: nach dem Einlegen
            -- ist arrow_in_hand false, und dieser Zweig hat den gerade umgehaengten Bolzen sofort wieder
            -- zerstoert -> im Log "UMGEHAENGT... true" gefolgt von "klon=false in_gun=false".
            bow_clone_destroy()
        end
        -- [SEHNEN-POSE] motion.lua wendet den publizierten Namen im POST-ANIM-Pass an (wie bei den
        -- Rack-Posen der anderen Waffen). Nur wenn kein Bolzen in der Hand ist -- der hat Vorrang.
        do
            local want = false
            if BOWCFG.string_pose ~= "" and not bow.arrow_in_hand then
                want = bow.grab or BOWCFG.dock_preview or (BOWCFG.string_pose_near and near)
            end
            -- [BOLZEN-HANDPOSE] Bolzen in der Hand (oder Vorschau) laeuft ueber den MAG-Pfad:
            -- der traegt in motion.lua das additive Daumen-Tuning (__vr_mag_hand_trx/try/trz).
            -- Die Sehnen-Pose bleibt am Rack-Pfad -- so kommen sich beide nie ins Gehege.
            local holding = bow.arrow_in_hand or (BOWCFG.arrow_preview and bclone.obj ~= nil)
            if holding and BOWCFG.arrow_pose ~= "" then
                _G.__vr_mag_hand_pose = BOWCFG.arrow_pose
                _G.__vr_mag_hand_trx  = BOWCFG.arrow_trx
                _G.__vr_mag_hand_try  = BOWCFG.arrow_try
                _G.__vr_mag_hand_trz  = BOWCFG.arrow_trz
                _G.__vr_rack_hand_pose = nil
            else
                _G.__vr_mag_hand_pose = nil
                _G.__vr_mag_hand_trx, _G.__vr_mag_hand_try, _G.__vr_mag_hand_trz = nil, nil, nil
                _G.__vr_rack_hand_pose = want and BOWCFG.string_pose or nil
            end
        end
        -- [SEHNEN-DOCK] Hand-Ziel an den Sehnen-Joint publizieren. Dieselben Globals, die auch die
        -- Slide-Rack-Hand der anderen Waffen benutzt -> motion/arm_chain ziehen die linke Hand dorthin.
        -- Aktiv beim echten Zug (grab) und im Setup-Vorschaumodus; sonst freigeben.
        -- [EINRAST-HALTEN] Zeitpunkt des Einrastens merken (siehe latch_hold_sec).
        if bow.drawn and not bow.latch_t then bow.latch_t = os.clock() end
        if not bow.drawn then bow.latch_t = nil end
        local latching = bow.latch_t and ((os.clock() - bow.latch_t) < (tonumber(BOWCFG.latch_hold_sec) or 0.0))
        if bwep.sj and (bow.grab or latching or BOWCFG.dock_preview) then
            local jp = safe(function() return bwep.sj:call("get_Position") end)
            local jr = safe(function() return bwep.sj:call("get_Rotation") end)
            if jp and jr then
                local off = safe(function() return jr * Vector3f.new(BOWCFG.dock_x, BOWCFG.dock_y, BOWCFG.dock_z) end)
                if off then
                    _G.__vr_slide_hand_world_pos = Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
                else
                    _G.__vr_slide_hand_world_pos = Vector3f.new(jp.x, jp.y, jp.z)
                end
                local rq = quat_from_euler(BOWCFG.dock_rx, BOWCFG.dock_ry, BOWCFG.dock_rz)
                local hr = rq and safe(function() return (jr * rq):normalized() end)
                _G.__vr_slide_hand_world_rot = hr or jr
                -- [DOCK-LERP 2026-07-20] Blend hochLERPEN statt hart auf 1.0 -> die Hand
                -- wandert weich an den Sehnengriff, statt hinzuspringen. Tempo per dock_blend_speed.
                local bs = tonumber(BOWCFG.dock_blend_speed) or 0.12
                bow.dock_blend = math.min(1.0, (bow.dock_blend or 0.0) + bs)
                _G.__vr_slide_dock_blend_factor = bow.dock_blend
                _G.__vr_slide_rack_active = true
            end
        else
            -- Ausblenden ebenfalls weich (gleiches Tempo), erst dann Ziel freigeben.
            local bs = tonumber(BOWCFG.dock_blend_speed) or 0.12
            bow.dock_blend = math.max(0.0, (bow.dock_blend or 0.0) - bs)
            _G.__vr_slide_dock_blend_factor = bow.dock_blend
            if bow.dock_blend <= 0.001 then
                _G.__vr_slide_hand_world_pos = nil
                _G.__vr_slide_hand_world_rot = nil
                _G.__vr_slide_rack_active = false
            end
        end
        _G.__re4_reload_grab_empty    = (bow_reserve() <= 0) and not bow.arrow_in_hand
    end)

    pcall(function() re.on_pre_application_entry("LockScene", bow_apply) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", bow_apply) end)
    pcall(function() re.on_application_entry("BeginRendering", bow_apply) end)

    re.on_script_reset(function()
        bow_clone_destroy()   -- [PART-KLON] kein Waise beim Script-Reset
        _G.__vr_block_fire_when_empty = false
        _G.__re4_bf_who = "re4_vr_reload5_dlc.lua:3602"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        _G.__vr_needs_rack = false
        _G.__vr_mag_in_hand = false
        _G.__re4_reload_grab_empty = false
    end)

    _G.__re4_reload5_ui_bow = function()
        local c, v = imgui.checkbox("Enable##bow", BOWCFG.enabled)
        if c then BOWCFG.enabled = v; bow_save_cfg() end
        imgui.text(string.format("Equippt: %s | Bolzen in Hand: %s | geladen: %s | gespannt: %s (%.2f)",
            tostring(bwep.wid), tostring(bow.arrow_in_hand), tostring(bow.loaded),
            tostring(bow.drawn), bow.frac or 0))
        imgui.text(string.format("Joints gefunden: Sehne=%s  Bolzen=%s",
            tostring(bwep.sj ~= nil), tostring(bwep.aj ~= nil)))
        local d1, n1 = imgui.slider_float("Einlege-Distanz m (Einrasten)##bow", BOWCFG.insert_distance, 0.03, 0.50, "%.3f")
        if d1 then BOWCFG.insert_distance = n1; bow_save_cfg() end
        do
            local dd = tonumber(rawget(_G, "__re4_bow_insert_dist"))
            imgui.text_colored(dd and string.format("   aktueller Abstand Hand -> Einlegepunkt: %.3f m", dd)
                or "   (Bolzen in die Hand nehmen, dann zeigt sich der Abstand)", 0xFF66CCFF)
        end
        imgui.text("Einlegepunkt (Offset ab Joint _03, ausgemessen):")
        local e1, f1 = imgui.slider_float("Einlege X##bow", BOWCFG.insert_x, -0.50, 0.50, "%.4f")
        if e1 then BOWCFG.insert_x = f1; bow_save_cfg() end
        local e2, f2 = imgui.slider_float("Einlege Y##bow", BOWCFG.insert_y, -0.50, 0.50, "%.4f")
        if e2 then BOWCFG.insert_y = f2; bow_save_cfg() end
        local e3, f3 = imgui.slider_float("Einlege Z##bow", BOWCFG.insert_z, -0.50, 0.50, "%.4f")
        if e3 then BOWCFG.insert_z = f3; bow_save_cfg() end
        -- [EINLEG-BLEND 2026-07-20] Dauer der weichen Uebergabe Hand -> Laufrinne. 0 = hart (alt).
        local eb, ebv = imgui.slider_float("Einleg-Blend (s)  [0 = hart]##bow", BOWCFG.insert_blend, 0.0, 0.60, "%.2f")
        if eb then BOWCFG.insert_blend = ebv; bow_save_cfg() end
        local d2, n2 = imgui.slider_float("Sehne Greif-Distanz m##bow", BOWCFG.draw_grab_dist, 0.03, 0.40, "%.3f")
        if d2 then BOWCFG.draw_grab_dist = n2; bow_save_cfg() end
        local d3, n3 = imgui.slider_float("Sehnen-Zug Z (m)##bow", BOWCFG.draw_z, -0.40, 0.0, "%.3f")
        if d3 then BOWCFG.draw_z = n3; bow_save_cfg() end
        local d4, n4 = imgui.slider_float("Gespannt ab Anteil##bow", BOWCFG.draw_need, 0.30, 1.0, "%.2f")
        if d4 then BOWCFG.draw_need = n4; bow_save_cfg() end
        local d5, n5 = imgui.slider_float("Zug-Glaettung (1 = direkt)##bow", BOWCFG.draw_smooth, 0.05, 1.0, "%.2f")
        if d5 then BOWCFG.draw_smooth = n5; bow_save_cfg() end
        local d6, n6 = imgui.slider_float("Hand-Andock-Tempo##bow", BOWCFG.dock_blend_speed, 0.02, 1.0, "%.2f")
        if d6 then BOWCFG.dock_blend_speed = n6; bow_save_cfg() end
        local d7, n7 = imgui.slider_float("Einrasten: Hand haelt noch (s)##bow", BOWCFG.latch_hold_sec, 0.0, 1.5, "%.2f")
        if d7 then BOWCFG.latch_hold_sec = n7; bow_save_cfg() end
        imgui.text("-- Sehnen-Handpose --")
        local sp1, sv = imgui.input_text("Pose-Name (Sehne)##bow", BOWCFG.string_pose)
        if sp1 then BOWCFG.string_pose = sv; bow_save_cfg() end
        local sp2, sv2 = imgui.checkbox("Pose schon bei Naehe (sonst erst beim Ziehen)##bow", BOWCFG.string_pose_near)
        if sp2 then BOWCFG.string_pose_near = sv2; bow_save_cfg() end
        imgui.text("-- Sehnen-Dock (wohin die Hand greift) --")
        local pv, pvv = imgui.checkbox("Vorschau: Hand dauerhaft ans Dock##bow", BOWCFG.dock_preview)
        if pv then BOWCFG.dock_preview = pvv; bow_save_cfg() end
        local k1, w1 = imgui.slider_float("Dock X##bow", BOWCFG.dock_x, -0.30, 0.30, "%.4f")
        if k1 then BOWCFG.dock_x = w1; bow_save_cfg() end
        local k2, w2 = imgui.slider_float("Dock Y##bow", BOWCFG.dock_y, -0.30, 0.30, "%.4f")
        if k2 then BOWCFG.dock_y = w2; bow_save_cfg() end
        local k3, w3 = imgui.slider_float("Dock Z##bow", BOWCFG.dock_z, -0.30, 0.30, "%.4f")
        if k3 then BOWCFG.dock_z = w3; bow_save_cfg() end
        local k4, w4 = imgui.slider_float("Dock RotX##bow", BOWCFG.dock_rx, -180, 180, "%.1f")
        if k4 then BOWCFG.dock_rx = w4; bow_save_cfg() end
        local k5, w5 = imgui.slider_float("Dock RotY##bow", BOWCFG.dock_ry, -180, 180, "%.1f")
        if k5 then BOWCFG.dock_ry = w5; bow_save_cfg() end
        local k6, w6 = imgui.slider_float("Dock RotZ##bow", BOWCFG.dock_rz, -180, 180, "%.1f")
        if k6 then BOWCFG.dock_rz = w6; bow_save_cfg() end
        -- [MESSUNG] Live-Werte des Sehnen-Joints -- fuer den naechsten Schritt (gespannt/ungespannt).
        do
            local lp = bwep.sj and safe(function() return bwep.sj:call("get_LocalPosition") end)
            if lp then
                imgui.text_colored(string.format("Sehne _01 LocalPos: x=%.4f y=%.4f z=%.4f   (Ruhe erfasst: %s)",
                    lp.x, lp.y, lp.z, bwep.s_rest and string.format("z=%.4f", bwep.s_rest.z) or "-"), 0xFF66CCFF)
                if imgui.button("Aktuelle Sehnen-Z als RUHE merken##bow") then
                    bwep.s_rest = { x = lp.x, y = lp.y, z = lp.z }
                end
            end
        end
        imgui.text("-- Bolzen in der Hand (Mesh-Part-Klon) --")
        local ap, apv = imgui.checkbox("Vorschau: Bolzen dauerhaft in der Hand##bow", BOWCFG.arrow_preview)
        if ap then BOWCFG.arrow_preview = apv; bow_save_cfg() end
        local an, anv = imgui.input_text("Bolzen-Handpose##bow", BOWCFG.arrow_pose)
        if an then BOWCFG.arrow_pose = anv; bow_save_cfg() end
        local pi, piv = imgui.slider_int("Bolzen Mesh-Part##bow", tonumber(BOWCFG.arrow_part) or 5, 0, 40)
        if pi then BOWCFG.arrow_part = piv; bow_save_cfg() end
        local a1, m1 = imgui.slider_float("Bolzen X##bow", BOWCFG.arrow_x, -0.30, 0.30, "%.3f")
        if a1 then BOWCFG.arrow_x = m1; bow_save_cfg() end
        local a2, m2 = imgui.slider_float("Bolzen Y##bow", BOWCFG.arrow_y, -0.30, 0.30, "%.3f")
        if a2 then BOWCFG.arrow_y = m2; bow_save_cfg() end
        local a3, m3 = imgui.slider_float("Bolzen Z##bow", BOWCFG.arrow_z, -0.30, 0.30, "%.3f")
        if a3 then BOWCFG.arrow_z = m3; bow_save_cfg() end
        local b1, r1 = imgui.slider_float("Bolzen RotX##bow", BOWCFG.arrow_rx, -180, 180, "%.1f")
        if b1 then BOWCFG.arrow_rx = r1; bow_save_cfg() end
        local b2, r2 = imgui.slider_float("Bolzen RotY##bow", BOWCFG.arrow_ry, -180, 180, "%.1f")
        if b2 then BOWCFG.arrow_ry = r2; bow_save_cfg() end
        local b3, r3 = imgui.slider_float("Bolzen RotZ##bow", BOWCFG.arrow_rz, -180, 180, "%.1f")
        if b3 then BOWCFG.arrow_rz = r3; bow_save_cfg() end
        imgui.text("-- Bolzen IN DER WAFFE (Offset ab Sehnen-Joint) --")
        local g1, h1 = imgui.slider_float("In-Gun X##bow", BOWCFG.gun_x, -0.50, 0.50, "%.4f")
        if g1 then BOWCFG.gun_x = h1; bow_save_cfg() end
        local g2, h2 = imgui.slider_float("In-Gun Y##bow", BOWCFG.gun_y, -0.50, 0.50, "%.4f")
        if g2 then BOWCFG.gun_y = h2; bow_save_cfg() end
        local g3, h3 = imgui.slider_float("In-Gun Z##bow", BOWCFG.gun_z, -0.50, 0.50, "%.4f")
        if g3 then BOWCFG.gun_z = h3; bow_save_cfg() end
        local g4, h4 = imgui.slider_float("In-Gun RotX##bow", BOWCFG.gun_rx, -180, 180, "%.1f")
        if g4 then BOWCFG.gun_rx = h4; bow_save_cfg() end
        local g5, h5 = imgui.slider_float("In-Gun RotY##bow", BOWCFG.gun_ry, -180, 180, "%.1f")
        if g5 then BOWCFG.gun_ry = h5; bow_save_cfg() end
        local g6, h6 = imgui.slider_float("In-Gun RotZ##bow", BOWCFG.gun_rz, -180, 180, "%.1f")
        if g6 then BOWCFG.gun_rz = h6; bow_save_cfg() end
        imgui.text("Bolzen-Daumen (additiv auf die Pose, Grad):")
        local t1, u1 = imgui.slider_float("Daumen RotX##bow", BOWCFG.arrow_trx, -90, 90, "%.1f")
        if t1 then BOWCFG.arrow_trx = u1; bow_save_cfg() end
        local t2, u2 = imgui.slider_float("Daumen RotY##bow", BOWCFG.arrow_try, -90, 90, "%.1f")
        if t2 then BOWCFG.arrow_try = u2; bow_save_cfg() end
        local t3, u3 = imgui.slider_float("Daumen RotZ##bow", BOWCFG.arrow_trz, -90, 90, "%.1f")
        if t3 then BOWCFG.arrow_trz = u3; bow_save_cfg() end
        local ca, va = imgui.checkbox("Ammo beim Einlegen nachladen##bow", BOWCFG.reload_ammo)
        if ca then BOWCFG.reload_ammo = va; bow_save_cfg() end
        imgui.text("-- Sounds --")
        local cs, vs = imgui.checkbox("Sounds an##bow", BOWCFG.sound_enabled ~= false)
        if cs then BOWCFG.sound_enabled = vs; bow_save_cfg() end
        local s1, sv1 = imgui.slider_float("Spann-Segment Laenge (s)##bow", tonumber(BOWCFG.snd_seg) or 0.12, 0.03, 1.00, "%.3f")
        if s1 then BOWCFG.snd_seg = sv1; bow_save_cfg() end
        local s2, sv2 = imgui.slider_float("Bolzen-Aufprall Verzoegerung (s)##bow", tonumber(BOWCFG.snd_drop_delay) or 0.45, 0.0, 2.0, "%.2f")
        if s2 then BOWCFG.snd_drop_delay = sv2; bow_save_cfg() end
    end
end

-- =====================================================================
-- UI: EIN Haupttree fuer dieses File (Namensschema wie Reload 4/5)
-- =====================================================================
-- [EIN HAUPTTREE 2026-07-19] Vorher zeichnete jede Gattung ihren eigenen Top-Level-Baum --
-- zwei Baeume fuer eine Datei, dazu Namen, die nicht zum Dateinamen passten. Jetzt: ein Baum,
-- beide Langwaffen als Untertrees darunter.
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Reload 5 (Separate Ways)" raus (20 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- =====================================================================
-- [FIRE-GATE DLC5 2026-07-20 -- per Log belegt]
-- PROBLEM: Unser Feuer-Block (f.RT weglassen) erreicht die Engine bei ADAS Waffen NICHT. Beweis aus
-- re4_rack_diag.log: "BF block_fire false -> true gesetzt von: re4_vr_reload5_dlc.lua:1814" und trotzdem
-- "SHOT von_uns=false block_fire=true empty_trigger=true" -> der Schuss kommt am Binding vorbei direkt
-- aus dem rohen Controller-Trigger. Bei Leon bremst zusaetzlich die Engine selbst; die DLC-Waffen
-- chambern dagegen selbst weiter (schon bei Adas Pistolen gemessen, s. reload4_dlc Fire-Gate).
--
-- LOESUNG (identisch zu re4_vr_reload4_dlc.lua): nicht den Trigger abfangen, sondern der Engine IHRE
-- EIGENE Frage beantworten -- chainsaw.PlayerEquipment.isEnableFire -> false, solange dieses Modul
-- die equippte Waffe verwaltet UND seinen Block gesetzt hat.
--
-- ABSICHERUNG (hangende Sperre = tote Waffe = gamebreaking):
-- * nur bei den 4 hier verwalteten DLC-Waffen (6105/6114/6113/6102), nie bei Leon
-- * nur wenn __vr_block_fire_when_empty gerade true ist (setzen nur die Bloecke dieses Files,
-- wenn eine dieser Waffen equippt ist)
-- * nicht im Killswitch/KS4, nicht waehrend eines Mag-/Patronen-Flows (__vr_mag_in_hand)
-- * Not-Aus jederzeit: _G.__re4_fire_gate5 = false
-- ACHTUNG: sdk.hook -> erst nach GAME-NEUSTART aktiv, "Reset Scripts" genuegt NICHT.
-- =====================================================================
if not _G.__re4_fire_gate5_hook then
    _G.__re4_fire_gate5_hook = true
    _G.__re4_fire_gate5 = true
    local GATED = { [6105] = true, [6114] = true, [6113] = true, [6102] = true }
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        local m  = td and td:get_method("isEnableFire")
        if not m then return end
        sdk.hook(m,
            function() end,
            function(retval)
                pcall(function()
                    if rawget(_G, "__re4_fire_gate5") ~= true then return end
                    if rawget(_G, "__vr_block_fire_when_empty") ~= true then return end
                    local wid = get_equip_wid()
                    if not (wid and GATED[wid]) then return end
                    if _G.__re4_holster_killswitch == true or rawget(_G, "__re4_ks4_active") == true then return end
                    if rawget(_G, "__vr_mag_in_hand") == true then return end
                    retval = sdk.to_ptr(0)   -- false -> Engine feuert nicht (spielt ihren eigenen Dry-Fire)
                end)
                return retval
            end)
    end)
end


-- =====================================================================
-- [RUNDEN-RESET 2026-08-09] Neue Mercenaries-Runde -> Waffenzustand wegwerfen
-- =====================================================================
-- SYMPTOM: die letzte Runde mit leerem Magazin verlassen -> in der neuen Runde ist die
-- Waffe voll, das Script will aber trotzdem nachladen/durchladen.
-- URSACHE: `rack` und `_pe_cache` leben auf Script-Ebene und werden nur bei Waffenwechsel
-- bzw. bei einem GEWORFENEN Aufruf verworfen. Ein Rundenwechsel ist beides nicht: das
-- Spiel laedt die Map neu, die alten Objekte bleiben ansprechbar (Schreiben verpufft
-- lautlos, siehe Notiz).
-- TRIGGER: `__re4_merc_round` -- re4_vr_merc.lua zaehlt es in der Ladeluecke hoch, in der
-- der Body kurz gar nichts meldet. Das ist der einzige verlaessliche Hinweis auf eine neue
-- Runde; ein eigenes Flag dafuer gibt es nicht.
-- Ausserhalb Mercenaries aendert sich der Token nie -> Kampagne und Adas DLC sind unberuehrt.
-- Zaehler bewusst als Global, NICHT als local: diese Datei liegt nah am 200-Local-Limit.
re.on_frame(function()
    local t = tonumber(rawget(_G, "__re4_merc_round"))
    if t == rawget(_G, "__re4_round_seen_reload5") then return end
    _G["__re4_round_seen_reload5"] = t

    _pe_cache = nil
end)
