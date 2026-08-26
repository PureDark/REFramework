-- Builtin implementation: src/mods/vr/games/re4/RE4VRReload2.cpp
return
-- =====================================================================
-- RE4 VR — Manual Reload 2: REVOLVER (eigene Gattung, eigenes File)
-- Pfad: reframework/autorun/re4_vr_reload2.lua
-- =====================================================================
-- Komplett ABGEKAPSELT von re4_vr_reload.lua (eigenes Lua-200-Local-Budget).
-- Hier lebt die komplette Revolver-Logik. re4_vr_reload.lua ignoriert
-- Revolver automatisch (kein JOINTS-Eintrag dort) -> kein Konflikt.
-- Eigene Persistenz: reframework/data/re4_vr/re4_vr_reload2.json
--
-- STAND: Schritt 1 = Trommel (_06) per Right-B ausschwenken (Break-Action-
-- Muster). joint_06 = Trommel (nach links raus), joint_07 = Patrone.
-- Naechste Schritte (RE9-Vorbild): Patrone(n) auswerfen / einlegen / zu.
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
-- Anim, wenn die Pose losgelassen wird). f = { name, data, release_t }. pose_fade_step(f, want, data):
-- solange want (Pose-Name) gesetzt ist -> (want, 1.0, data); danach ueber POSE_FADE_DUR Sekunden auf 0
-- runterblenden und dabei den ZULETZT gehaltenen Namen + data behalten. os.clock-basiert -> robust,
-- weil die Apply-Funktionen mehrfach pro Frame laufen (mehrere Render-Passes). Blend wird an die
-- pose-apply-Funktionen (nlerp current->target) UND additiv an die Finger-Offsets (Euler*blend)
-- weitergereicht. Gleiches Muster wie in re4_vr_motion.lua.
-- GLOBAL definiert (KEIN Local-Slot — reload2 ist am 200-Local-Limit!). __re4_pose_fade_dur = Dauer
-- (Sek. bis zurueck auf nativ, hoeher = weicher). __re4_r2_shellfade = Fade-State der Revolver-Pose
-- (im Main-Chunk, daher ebenfalls global statt local).
_G.__re4_pose_fade_dur = _G.__re4_pose_fade_dur or 0.10
_G.__re4_r2_shellfade  = _G.__re4_r2_shellfade or {}
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
-- Revolver-Daten (per Waffe)
-- ---------------------------------------------------------------------
local REVOLVERS = { [5001] = true, [4500] = true }   -- wp5001, wp4500 Broken Butterfly. (wp4502 Handcannon -> re4_vr_reload3.lua)
local function is_revolver(wid) return wid ~= nil and REVOLVERS[wid] == true end

-- cylinder = Trommel (per Right-B ausschwenken), bullet = Patrone. Per-Waffe.
-- [4500 Broken Butterfly] 6 Kugeln. _05 = Trommel INKL. Kugeln (= der ausgeschwenkte Joint).
-- _06 = Kugel-Paket OHNE Trommel (alle 6 als Block angeordnet wie in der Trommel). _07.._12 =
-- jede Kugel EINZELN in der Trommel (6 Stueck) -> fuers Auswerfen/Einlegen pro Kugel.
local JOINTS = {
    [5001] = { cylinder = "_06", bullet = "_07" },
    -- [4502] Handcannon -> jetzt in re4_vr_reload3.lua (eigener do-Block)
    [4500] = { cylinder = "_04", bullet = "_07", bullet_pack = "_06", insert_ref = "_06", spin = "_05",
               hand_cartridge = "_101",   -- lose Lade-Patrone (NICHT in der Trommel) -> Modell fuer die Hand
               hammer = "_02",            -- [SINGLE-ACTION] Hahn hinten -> nach jedem Schuss spannen (nur wp4500!)
               bullets = { "_07", "_08", "_09", "_10", "_11", "_12" }, capacity = 6 },
               -- TOP-BREAK nach OBEN: _04 = Hinge/Treiber, _05 (Trommel+Kugeln) klappt als Kind mit hoch.
               -- _06 = Kugelpaket (alle 6 als Block) = Anker fuer die Einlege-Distanz. _07.._12 = 6 Einzelkugeln.
}

-- [CYLINDER] Ausschwenken pro Waffe. ZWEI Mechaniken (je Waffe das was passt):
-- rx/ry/rz = Rotations-Offset (Grad) -> Crane-Dreh-Revolver (z.B. 4502 _04 um Z).
-- px/py/pz = LocalPosition-Offset (m) -> Trommel faehrt translatorisch raus (Broken Butterfly 4500 _05).
-- prog 0=zu..1=auf lerpt beides mit lerp. Per-Waffe, eigenstaendig.
local CYL = {
    [5001] = { rx = 0.0, ry = -45.0, rz = 0.0, lerp = 0.08 },
    -- [4502] Handcannon -> jetzt in re4_vr_reload3.lua
    -- Broken Butterfly: TOP-BREAK, _04 klappt nach OBEN auf (Pitch/X, wie Skull-Shaker-Klappe). +62 = richtige Richtung.
    [4500] = { rx = 52.0, ry = 0.0, rz = 0.0, lerp = 0.08 },
}
local function cyl_cfg(wid)
    local c = wid and CYL[wid]
    if not c then c = {}; if wid then CYL[wid] = c end end
    c.rx = c.rx or 0; c.ry = c.ry or 0; c.rz = c.rz or 0
    c.px = c.px or 0; c.py = c.py or 0; c.pz = c.pz or 0
    c.lerp = c.lerp or 0.08
    c.shot_deg = c.shot_deg or -45.0   -- [CHAMBER-ADVANCE] Grad pro Schuss (Z, Richtung wie Chamber-Spin)
    c.shot_lerp = c.shot_lerp or 0.20  -- Dreh-Geschw. der Schuss-Animation
    return c
end

-- [CYLINDER] Laufzeit-State des Ausschwenkens
local cyl_st = { open = false, prog = 0.0, _prev_b = false, preview = false }

-- [CHAMBER-ADVANCE] Trommel nach jedem Schuss ein Stueck weiterdrehen (echtes Revolver-Gefuehl).
-- target = Soll-Winkel (akkumuliert pro Schuss), current = animiert hinterher. Wird auf _05s Eigen-
-- rotation additiv gelegt (in apply_cylinder_spin_lock, sonst haelt die die Trommel ja starr).
local spin_st = { target = 0.0, current = 0.0, prev_seq = nil }

-- [SINGLE-ACTION] ALLE Single-Action-Daten (Hahn _02 + rechter Daumen R_Thumb1/2/3) in EINER Tabelle
-- 'hammer_st' gebuendelt -> spart Top-Level-Locals (Lua-200-Limit im Haupt-Chunk). NUR wp4500.
-- cfg = per-Waffe Hahn-Config: idle (entspannt/vorne, Default +14.5 X) <-> cocked (gespannt, -7.5 X).
-- _02 = Ruhe * euler(lerp(idle,cocked,frac)) pro Achse. frac 0..1, lerpt per 'lerp'.
-- tcfg = per-Waffe Daumen-Config: 3 Joints, je idle XYZ + cocked XYZ (additiv, Grad).
-- Rest = Laufzeit-State + Diag. cfg/tcfg JSON-persistiert.
local hammer_st = {
    hand_frac = 0.0, ham_frac = 0.0, cocked = false,   -- hand_frac=Hand-Pose (faehrt hin/zurueck), ham_frac=Hahn (latcht)
    frac = 0.0, target = 0.0, prev_seq = nil, preview = false, cock_prev = false,
    cock_running = false, cock_t0 = 0.0, cock_snd = false,  -- einmalige Spann-Geste (Zeitfenster)
    cock_stick_y = -0.70,                                   -- rechter Stick so weit nach UNTEN -> spannen (Flanke)
    thumb_joints = { "R_Thumb1", "R_Thumb2", "R_Thumb3" },
    thumb_dbg_wid = nil, thumb_dbg_t = 0,                    -- [THUMB-DIAG temp]
    cfg  = { [4500] = { idle_rx = -25.5, idle_ry = 0.0, idle_rz = 0.0, rx = -41.5, ry = 0.0, rz = 0.0, lerp = 0.25 } },
    tcfg = { [4500] = { { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }, { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }, { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 } } },
    -- [AIM] eigener Daumen-Satz fuer den Aim-Zustand (Spiegel von tcfg/thumb_pos). use_aim waehlt zur Laufzeit.
    tcfg_aim = { [4500] = { { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }, { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 }, { ix=0,iy=0,iz=0,cx=0,cy=0,cz=0 } } },
    use_aim = false,
    -- [COCK-HAND] NUR die rechte Hand beim Spannen rollen/versetzen (Waffe bleibt stehen!). motion.lua wendet
    -- es nur auf die Hand-Joint-Pose an, skaliert mit frac. rx/ry/rz = Handgelenk-Roll (Grad), px/py/pz =
    -- Versatz (m, hand-lokal). NUR 4500.
    hand = { rx = 0.0, ry = 0.0, rz = 0.0, px = 0.0, py = 0.0, pz = 0.0 },
    -- [COCK-HAND AIM] zweites Set fuer den AIM-Zustand (Waffe kippt no-aim<->aim) -> eigene getunte Hand-Pose.
    -- Gleiche Struktur, beim Spannen wird je nach Aim das richtige Set publiziert. Start = Kopie von 'hand'.
    hand_aim = { rx = 0.0, ry = 0.0, rz = 0.0, px = 0.0, py = 0.0, pz = 0.0 },
    -- [DAUMEN-VERSATZ] verschiebt den ganzen Daumen ab der Basis (R_Thumb1 LocalPosition), m, skaliert mit frac.
    thumb_pos = { x = 0.0, y = 0.0, z = 0.0 },
    thumb_pos_aim = { x = 0.0, y = 0.0, z = 0.0 },   -- [AIM] Daumen-Versatz fuer den Aim-Zustand
    -- [DAUMEN-KEYS 2026-07-31] Der Daumen als KURVE ueber die Spann-Geste statt als 2-Punkt-Lerp.
    -- phase = MONOTON 0..1 ueber hoch+kleben+zurueck -> Hin- und Rueckweg sind getrennt keyframebar
    -- (hand_frac taugt dafuer nicht, der laeuft hoch UND wieder runter).
    -- Key: { p = 0..100, j = { {x,y,z,px,py,pz} x3 } } -- Grad additiv je Glied + Versatz (m) je Glied.
    -- Vor dem ersten / nach dem letzten Key wird gegen NEUTRAL geblendet -> kein Key bei 0/100 noetig.
    -- SIND KEINE KEYS GESETZT, laeuft exakt der alte 2-Punkt-Pfad -- kein Bruch.
    tkeys = {}, tkeys_aim = {},
    phase = 0.0, key_blend = 0.0,
    kprev = false, klive = true, kphase = 0.0, kjoint = 1,   -- UI: Phasen-Regler, Live-Werte, aktives Glied
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
-- [DAUMEN-KEYS] Key-Liste einer Waffe; Aim und No-Aim haben getrennte Listen (wie tcfg/tcfg_aim).
local function thumb_keys(wid, aim)
    local m = aim and hammer_st.tkeys_aim or hammer_st.tkeys
    local t = wid and m[wid]; if not t then t = {}; if wid then m[wid] = t end end
    return t
end
-- [DAUMEN-KEYS] Kurve an der Phase p (0..100) abtasten -> out[1..3] = Winkel + Versatz je Glied.
-- Vor dem ersten Key wird von NEUTRAL hochgeblendet, nach dem letzten wieder auf NEUTRAL runter --
-- der Daumen laeuft also von selbst sauber aus dem Griff heraus und wieder hinein.
local function thumb_key_sample(list, p, out)
    for i = 1, 3 do local o = out[i]; o.x, o.y, o.z, o.px, o.py, o.pz = 0, 0, 0, 0, 0, 0 end
    local n = list and #list or 0
    if n == 0 then return false end
    local lo, hi, t
    if p <= list[1].p then
        hi = list[1]
        t = (list[1].p > 0.0001) and (p / list[1].p) or 1.0          -- neutral -> erster Key
    elseif p >= list[n].p then
        lo = list[n]
        local span = 100.0 - list[n].p
        t = (span > 0.0001) and ((p - list[n].p) / span) or 1.0      -- letzter Key -> neutral
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

-- [MESH-CLONE FWD] cart_destroy + cart_clone werden von refresh_weapon / revolver_set_mag_in_hand (oben)
-- genutzt, aber die Helfer erst weiter unten definiert -> hier forward-deklarieren, sonst sieht der frueh
-- definierte Code ein globales nil und crasht (gleiche Falle wie der Red9 'insert'-Scope-Bug).
-- cart_clone = das eigene GameObject mit dem Patronen-Mesh-Clone in der Hand (statt geliehener Joint).
local cart_destroy
local cart_clone = { obj = nil, mesh = nil, wid = nil, parts_sig = nil }

-- [SHELL-IN-HAND] Pro Waffe: Finger-Pose (Name aus reload.json POSES, via _G.__re4_reload_apply_pose)
-- + Positions-/Rotations-Offset der Shell im Hand + Daumen-Spreizung. Gespiegelt von reload.lua MAGHAND,
-- aber EIGENSTAENDIG in reload2.json. Jede Waffe gekapselt.
local SHELL = {
    -- Broken Butterfly: eigene Pose "RevolverShell" (= unabhaengige Kopie von LE5SWITCH in reload.json,
    -- damit Tuning NIE die LE5 trifft). Daumen + Offset per-Waffe in reload2.json.
    -- parts = Mesh-Part-Indizes des Patronen-Clones in der Hand (20=Spitze, 30=Patrone). scale = dessen Groesse.
    -- Greifpose 2026-06-26 vom Handcannon (wp4502) kopiert (dort besser getunt): Daumen t_* + Zeigefinger i_*
    -- + Patronen-Lage. i_* = additiv auf L_IndexF1/2/3 (wie Handcannon).
    [4500] = { pose = "RevolverShell", x = 0.022, y = -0.078, z = 0.067, rx = 34.0, ry = 114.0, rz = 0.0,
               t_rx = 26.471, t_ry = 13.614, t_rz = 14.370, i_rx = -9.076, i_ry = 13.613, i_rz = 30.252,
               parts = "20,30", scale = 1.0 },
}
local function shell_cfg(wid)
    local s = wid and SHELL[wid]
    if not s then s = {}; if wid then SHELL[wid] = s end end
    s.pose = s.pose or ""
    s.x = s.x or 0; s.y = s.y or 0; s.z = s.z or 0
    s.rx = s.rx or 0; s.ry = s.ry or 0; s.rz = s.rz or 0
    s.t_rx = s.t_rx or 0; s.t_ry = s.t_ry or 0; s.t_rz = s.t_rz or 0
    s.i_rx = s.i_rx or 0; s.i_ry = s.i_ry or 0; s.i_rz = s.i_rz or 0
    s.parts = s.parts or "20,30"; s.scale = s.scale or 1.0
    return s
end

-- [CAPTURE temp] true = native Reload-Anim DURCHLASSEN (B nicht abfangen, kein Override). AUS ->
-- unser Override schwenkt _04 wieder per Right-B.
local _CAPTURE = false

-- ---------------------------------------------------------------------
-- Konfiguration (eigenes JSON, eigene Defaults)
-- ---------------------------------------------------------------------
local CFG_PATH = "re4_vr/re4_vr_reload2.json"
local CFG = {
    revolver_enabled = true,
    insert_distance  = 0.15,
    reload_ammo      = true,
    sound_enabled    = true,
    cock_press = 0.18, cock_hold = 0.14, cock_return = 0.16, cock_fall = 0.40,   -- (alt, ungenutzt seit cock_dur) + Hahn-Fall-Tempo
    cock_dur = 0.48,   -- [EIN SLIDER 2026-08-04] Gesamtdauer der Spann-Geste (s) = Phase 0..100 % der Daumen-Keys
    support_cooldown = 0.45,   -- [SUPPORT-COOLDOWN] s, Support-Hand nach Insert so lange NICHT andocken (0 = aus)
}
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
    if type(c.cock_dur)    == "number" then CFG.cock_dur    = c.cock_dur    end
    -- [CYLINDER] getunte Ausschwenk-Werte pro Waffe laden
    if type(data.cyl) == "table" then
        for k, v in pairs(data.cyl) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local rr = cyl_cfg(wid)
                for _, f in ipairs({ "rx", "ry", "rz", "px", "py", "pz", "lerp", "shot_deg", "shot_lerp" }) do if type(v[f]) == "number" then rr[f] = v[f] end end
            end
        end
    end
    -- [SHELL-IN-HAND] getunte Offsets + Pose-Name pro Waffe laden
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
    -- [SINGLE-ACTION HAMMER] getunte Hahn-Rotation pro Waffe laden
    if type(data.hammer) == "table" then
        for k, v in pairs(data.hammer) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local hh = hammer_cfg(wid)
                for _, f in ipairs({ "idle_rx", "idle_ry", "idle_rz", "rx", "ry", "rz", "lerp" }) do if type(v[f]) == "number" then hh[f] = v[f] end end
            end
        end
    end
    -- [COCK-HAND] getunten Hand-/Gun-Roll-Offset laden
    if type(data.cockhand) == "table" then
        for _, f in ipairs({ "rx", "ry", "rz", "px", "py", "pz" }) do if type(data.cockhand[f]) == "number" then hammer_st.hand[f] = data.cockhand[f] end end
    end
    -- [COCK-HAND AIM] zweites Set fuer den AIM-Zustand laden. Fehlt es -> Start = Kopie der No-Aim-Pose.
    if type(data.cockhand_aim) == "table" then
        for _, f in ipairs({ "rx", "ry", "rz", "px", "py", "pz" }) do if type(data.cockhand_aim[f]) == "number" then hammer_st.hand_aim[f] = data.cockhand_aim[f] end end
    else
        for _, f in ipairs({ "rx", "ry", "rz", "px", "py", "pz" }) do hammer_st.hand_aim[f] = hammer_st.hand[f] end
    end
    -- [DAUMEN-VERSATZ] laden
    if type(data.thumbpos) == "table" then
        for _, f in ipairs({ "x", "y", "z" }) do if type(data.thumbpos[f]) == "number" then hammer_st.thumb_pos[f] = data.thumbpos[f] end end
    end
    -- [SINGLE-ACTION THUMB] getunte rechte-Daumen-Posen pro Waffe laden (3 Joints, idle+cocked XYZ)
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
    -- [DAUMEN-VERSATZ AIM] laden; fehlt -> Kopie von thumb_pos
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
    -- [SINGLE-ACTION THUMB AIM] laden; pro Waffe fehlend -> Kopie der non-aim Daumen-Pose
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
        wep.cyl_rest_rot = sc(wep.cyl_joint, "get_LocalRotation")   -- Ruhe-Rotation (zu)
        wep.cyl_rest_pos = sc(wep.cyl_joint, "get_LocalPosition")   -- Ruhe-Position (zu) -> Basis fuers Ausfahren
        -- [RESET-DIAG temp] erfasste Ruhe loggen -> nach Reset pruefen ob "offen" reingerutscht ist
        -- [log entfernt]
    end
    -- [BULLETS] Einzel-Kugel-Joints (_07.._12) aufloesen + Ruhe-Scale merken. Beim Equip = nativer
    -- Zustand (alle sichtbar). Ruhe-Scale wird nur als "sichtbar"-Wert genutzt (Guard gegen 0).
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
    -- [RELOAD] Anker-Joint fuer die Einlege-Distanz (_06 Kugel-Paket -> bewegt sich beim Aufklappen mit).
    wep.insert_joint = (jc.insert_ref and jc.insert_ref ~= "") and sc(tf, "getJointByName", jc.insert_ref) or nil
    -- [SPIN-LOCK] Cylinder-Spin-Joint (_05) + Ruhe-Rotation merken -> native Chamber-Spin-Anim unterdruecken.
    wep.spin_joint = (jc.spin and jc.spin ~= "") and sc(tf, "getJointByName", jc.spin) or nil
    if wep.spin_joint then wep.spin_rest_rot = sc(wep.spin_joint, "get_LocalRotation") end
    -- [HAND-CARTRIDGE] lose Lade-Patrone (_100), NICHT in der Trommel -> Modell fuer die Hand.
    wep.hand_cart_joint = (jc.hand_cartridge and jc.hand_cartridge ~= "") and sc(tf, "getJointByName", jc.hand_cartridge) or nil
    if wep.hand_cart_joint then
        local rs = sc(wep.hand_cart_joint, "get_LocalScale")
        wep.hand_cart_vis = (rs and rs.x and rs.x > 0.01) and rs or Vector3f.new(1, 1, 1)
    end
    -- [SINGLE-ACTION HAMMER] Hahn-Joint (_02) + Ruhe-Rotation (entspannt/vorne) merken -> Basis fuers Spannen.
    wep.hammer_joint = (jc.hammer and jc.hammer ~= "") and sc(tf, "getJointByName", jc.hammer) or nil
    -- [SAVE-LOAD-FEST] Ruhe = BIND-Pose (get_BaseLocalRotation), eine Modell-Konstante die NIE von unserem
    -- Override kontaminiert wird (im Gegensatz zu get_LocalRotation = aktuelle, evtl. unsere eigene Ausgabe).
    -- -> idle/cocked werden immer aus dem sauberen Bind-Wert gerechnet, robust gegen Save-Load/Script-Reload.
    wep.hammer_rest_rot = wep.hammer_joint and sc(wep.hammer_joint, "get_BaseLocalRotation") or nil
end
local function wp_label(wid) return wid and string.format("wp%04d", wid) or "-" end

-- [SOUND] Waffen-Sound am SoundContainer des Waffen-GO triggern (wie reload.lua play_weapon_sound).
local function play_weapon_sound(id)
    if not CFG.sound_enabled or not id or id <= 0 then return end
    local tf = wep.tf; if not tf then return end
    local go = safe(function() return tf:call("get_GameObject") end)
    if not go or not snd_sc_td then return end
    local scn = safe(function() return go:call("getComponent(System.Type)", snd_sc_td) end)
    if not scn then return end
    pcall(function() scn:call("trigger(System.UInt32)", id) end)
end
local SND_CYLINDER    = 942865223   -- Trommel auf/zu (Right-B-Toggle + Flick-Close)
local SND_COCK        = 938556079   -- Hahn spannen (Flanke not-cocked -> cocked)
local SND_INSERT      = 942865223   -- Patrone schnappt in die Trommel
local SND_DROP        = 1351699582  -- fallengelassene Patrone (Boden)
local SND_MAG_HOLSTER = 1839787494  -- Patrone aus dem Mag-Holster gezogen (reload.lua-ID wiederverwendet)
local SND_DRY_FIRE    = 812850326   -- Klick bei gesperrtem Trigger (Trommel offen)

-- [SHELL FLOW] Patrone in der linken Hand: vom Mag-Holster-Griff bis eingelegt ODER fallengelassen.
-- Gleicher Flow wie alle Waffen, nur fuer den Revolver in reload2 (reload.lua verwaltet ihn nicht).
local reload2_st = { cart = false, _dry_prev = false, preview = false }   -- preview = UI-Vorschau "Patrone in der Hand"
-- [DROP] Fallengelassene Patrone (Loslassen ohne Einlegen) -> freier Fall der geliehenen Kammer-Kugel.
local drop2 = { active = false, idx = nil, sx = 0, sy = 0, sz = 0, t0 = 0, snd = false }
local REV_GRAVITY  = 9.8
local REV_DROP_DUR = 1.0   -- s bis der kosmetische Fall ausgelaufen ist (dann uebernimmt Visibility wieder)

-- ---------------------------------------------------------------------
-- [RELOAD] Shell-by-Shell: linke Hand mit Patrone an die OFFENE Trommel -> +1 geladen, -1 Reserve.
-- Das echte WeaponItem (mit get_CurrentAmmoCount/Reserve) pflegt re4_vr_reload.lua global als
-- _G.__re4_live_wi (sdk.hooks auf chainsaw.WeaponItem). Wir lesen/schreiben dasselbe Item -> konsistent
-- mit der Kugel-Anzeige. Ammo +1 via Roh-Schreibung _CurrentAmmoCount @0x44 (Laufzeit-/HUD-Feld,
-- exakt +1 statt Voll-Reload), Reserve via inv:reduce. Gedeckelt auf 6 Kammern + vorhandene Reserve.
-- ---------------------------------------------------------------------
local function get_live_wi()
    -- [ACCESSOR 2026-08-12] zuerst die ECHTE, persistente Instanz (s. reload.lua,
    -- __re4_real_wi). Alles darunter sind KOPIEN -> Schreiben verpufft.
    local _rw = _G.__re4_real_wi and _G.__re4_real_wi()
    if _rw then return _rw end
    -- 1) reload.lua's Live-Item (Schuss/Reload lief darauf), gegen die equippte Waffe validiert.
    local wi = rawget(_G, "__re4_live_wi")
    if wi and safe(function() return wi:call("get_IsValid") end) == true
       and safe(function() return wi:call("get_CurrentAmmoCount") end) ~= nil then
        local cwid = safe(function() return wi:call("get_WeaponId"):get_field("value__") end)
        if wep.wid and cwid and cwid == wep.wid then return wi end   -- STRIKT: valid + gleiche Waffe (kein stale)
    end
    -- 2) Fallback: getEquipWeaponItem (wie reload.lua current_reserve) -> robust ohne vorher zu schiessen
    -- und nach Save/Load, wenn __re4_live_wi nil/stale ist. WAR die Ursache fuer "keine Patrone".
    local pe = get_pe()
    local ewi = pe and safe(function() return pe:call("getEquipWeaponItem") end)
    if ewi and safe(function() return ewi:call("get_CurrentAmmoCount") end) ~= nil then return ewi end
    return nil
end

-- [FULL-CHECK] Engine-eigene Wahrheit bevorzugt: get_IsBulletFull (deckt Upgrades + Edge-Cases ab),
-- Fallback loaded>=get_CurrentAmmoMax (Live-Max INKL. Ausbau, NICHT get_DefaultAmmoMax=Basis 6).
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
    if gun_is_full(wi) then return false end                    -- voll (Engine-Check, Upgrade-aware)
    local pe  = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
    local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end)
    local function read_reserve()
        return (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
    end
    local r_b4 = read_reserve()
    if r_b4 <= 0 then return false end                         -- keine (oder nicht ermittelbare) Reserve -> nicht laden (kein Gratis-Ammo)
    -- +1 laden: Roh-Schreibung (Laufzeit/HUD-Feld @0x44), Fallback addAmmoCount.
    -- [RUNTIME-FIX 0/0] Erfolg gegen getCurrentGunAmmo (Laufzeit) pruefen, NICHT wi:get_CurrentAmmoCount
    -- (= evtl. Spiegel -> write_dword scheint zu "gelingen", addAmmoCount-Fallback uebersprungen, Reserve weg).
    local function gun_ammo() return pe and tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or nil end
    local function gun_ammo() return pe and tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or nil end
    -- [BUTTERFLY-AMMO 2026-07-24] write_dword @0x44 greift bei diesem Revolver NICHT (Engine deckelt/
    -- ignoriert -> getCurrentGunAmmo bleibt stehen, get_CurrentAmmoCount ist nur ein Spiegel). Stattdessen
    -- der NATIVE Reload (+1) -- EXAKT der Weg, der bei Shotguns/Pistolen funktioniert. Zieht die Reserve selbst.
    if wep.wid == 4500 then
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
    local base = gun_ammo() or loaded
    pcall(function() wi:write_dword(0x44, loaded + 1) end)
    local af = gun_ammo() or base
    if af <= base then pcall(function() wi:call("addAmmoCount", 1, true) end); af = gun_ammo() or base end
    if af <= base then return false end                        -- nichts geladen -> auch nichts abziehen
    -- [VERLUSTSICHER] Reserve NUR manuell ziehen, wenn der genutzte Lade-Pfad sie nicht selbst gezogen hat.
    local gained = af - base
    if read_reserve() >= r_b4 and inv and ammo_id then
        _G.__re4_safe_reduce(inv, ammo_id, gained)
    end
    return true
end

-- [SHELL FLOW] Gibt es ueberhaupt etwas zu greifen? Sperrt (Holster buzzt) bei Reserve==0 ODER voller
-- Trommel (echte get_CurrentAmmoMax). Frueher nur Reserve geprueft -> bei Max-Cap kam kein Speed-Puls;
-- der alte harte 6er-Cap war falsch (MaxCap kann >6), daher jetzt die echte Kapazitaet als Voll-Check.
local function revolver_can_grab()
    local wi = get_live_wi(); if not wi then return false end
    local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController")
    local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end)
    local reserve = (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
    if reserve <= 0 then return false end                       -- keine Reserve -> nichts zu greifen
    -- [FULL-BLOCK] Trommel voll -> ebenfalls sperren+buzzen, damit man nicht sinnlos eine Patrone greift
    -- die nicht reinpasst. (Speed-Puls soll auch bei Max-Cap kommen.) Engine-Check gun_is_full ist
    -- Upgrade-aware (Live-Max, nicht Basis-6) -> der alte harte 6er-Cap war falsch.
    if gun_is_full(wi) then return false end
    return true
end

-- [SHELL FLOW] Holster ruft das (via Wrapper am Ende) wenn der linke Grip im Mag-Holster greift/loslaesst.
-- active=true -> Patrone in die Hand (wenn was zu greifen ist). active=false -> losgelassen = fallen lassen
-- (kein Ammo), Patrone weg. Eingelegt wird in update_reload (verbraucht reload2_st.cart).
local function revolver_set_mag_in_hand(active)
    if active then
        if reload2_st.cart then return true end
        if reload2_st.kf_used then return false end   -- [SHELL-KEYFRAMES] diese Greif-Session hat schon eine Bahn gefahren + eingelegt -> KEINE neue Patrone in die Hand, erst loslassen + neu greifen
        if not revolver_can_grab() then return false end
        reload2_st.cart = true
        drop2.active = false   -- evtl. laufenden Fall abbrechen (gleicher Joint)
        play_weapon_sound(SND_MAG_HOLSTER)
        return true
    else
        -- [SHELL-KEYFRAMES 2026-07-24] Laeuft die Keyframe-Bahn, ist die Patrone bereits "committed":
        -- Loslassen (z.B. weil die Hand die Ablage verlaesst und zur Trommel wandert) NICHT als Drop werten --
        -- sonst faellt die Patrone UND die Bahn bricht ab (reposition_cart_late returnt bei drop2.active) =
        -- kein Insert. Die Bahn legt selbst ein; kf_used loesen, damit der naechste Griff wieder greift.
        if reload2_st.kf_active then reload2_st.kf_used = false; return true end
        -- losgelassen ohne Einlegen -> den Patronen-Mesh-Clone von seiner aktuellen (Hand-)Position
        -- fallen lassen (freier Fall, Deko) + Drop-Sound. Die Trommel bleibt unberuehrt (kein Loch).
        local tf = cart_clone.obj and safe(function() return cart_clone.obj:call("get_Transform") end)
        local p = tf and safe(function() return tf:call("get_Position") end)
        if reload2_st.cart and p then
            drop2.active = true; drop2.snd = false   -- Boden-Sound kommt verzoegert in apply_cart_drop (Aufprall)
            drop2.sx, drop2.sy, drop2.sz = p.x, p.y, p.z; drop2.t0 = os.clock()
            -- [NO_LAG] Klon war ans L_Hand geparentet -> fuer den Welt-Freifall entkoppeln.
            if cart_clone.parented then pcall(function() tf:call("set_Parent", nil) end); cart_clone.parented = false end
        end
        reload2_st.cart = false
        reload2_st.kf_used = false   -- [SHELL-KEYFRAMES] Grip losgelassen -> der naechste Griff darf wieder eine Bahn fahren
        return true
    end
end

-- [SHELL FLOW] Weltposition der Patrone IN DER HAND = L_Hand + Shell-Offset (wie apply_held_cartridge
-- sie setzt). Damit messen wir die Einlege-Distanz von der echten Patrone, nicht vom Hand-Joint.
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

-- [SHELL FLOW] Einlegen: Patrone in der Hand + Trommel OFFEN + Patrone nah am Kugel-Paket (_06) -> +1.
local function update_reload()
    if not (CFG.revolver_enabled and CFG.reload_ammo and wep.wid and wep.insert_joint) then return end
    if not reload2_st.cart then return end                              -- nur mit Patrone in der Hand
    if rawget(_G, "__vr_revolver_cyl_open") ~= true then return end     -- nur bei OFFENER Trommel
    local cp = held_cartridge_pos(); if not cp then return end          -- Patrone in der Hand
    local ip = sc(wep.insert_joint, "get_Position"); if not ip then return end   -- _06 Kugel-Paket
    local d  = math.sqrt((cp.x - ip.x)^2 + (cp.y - ip.y)^2 + (cp.z - ip.z)^2)
    if d <= (CFG.insert_distance or 0.15) then
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if ms and type(ms.has_shell_keys) == "function" and ms.has_shell_keys(wep.wid) then
            -- [SHELL-KEYFRAMES 2026-07-24] Statt sofort einlegen: Keyframe-Bahn starten -> der Patronen-
            -- Clone gleitet Hand->Trommel (reposition_cart_late faehrt die Bahn und legt am Ende real ein).
            if not reload2_st.kf_active and not reload2_st.kf_used then
                -- [SHELL-KEYFRAMES 2026-07-24] Bahn (visuelle Deko) IMMER starten, entkoppelt vom Insert.
                reload2_st.kf_active = true
                reload2_st.kf_used = true       -- EINE Bahn pro gegriffener Patrone -> kein Neustart/Loop
                reload2_st.kf_inserted = false  -- +1 fuer diese Patrone noch offen
                reload2_st.kf_t0 = os.clock()
                -- Parenting loesen -> die Bahn setzt Welt-Position (relativ zur Waffe), kein L_Hand-Parent-Kampf.
                local tf = cart_clone.obj and safe(function() return cart_clone.obj:call("get_Transform") end)
                if tf and cart_clone.parented then pcall(function() tf:call("set_Parent", nil) end); cart_clone.parented = false end
            end
            -- [SHELL-KEYFRAMES 2026-07-24] +1 JEDEN Frame versuchen (RETRY wie der bewaehrte elseif-Insert
            -- unten) bis getCurrentGunAmmo die 0x44-Schreibung reflektiert -- ein Einmal-Versuch scheitert am
            -- Timing. Laeuft parallel zur Bahn, solange die Patrone noch in der Hand ist.
            if reload2_st.cart and not reload2_st.kf_inserted then
                if insert_one_round() then reload2_st.kf_inserted = true; reload2_st._insert_t = os.clock(); play_weapon_sound(SND_INSERT) end
            end
        elseif insert_one_round() then
            reload2_st.cart = false                                     -- Patrone verbraucht
            reload2_st._insert_t = os.clock()                          -- [SUPPORT-COOLDOWN] Support-Hand nach Insert kurz NICHT andocken
            play_weapon_sound(SND_INSERT)
        end
    end
end

-- ---------------------------------------------------------------------
-- [CYLINDER] Trommel ausschwenken: Right-B togglet auf/zu, gelerped.
-- ---------------------------------------------------------------------
local function update_cylinder()
    if not (wep.wid and wep.cyl_joint) then return end
    if cyl_st.preview then _G.__vr_revolver_cyl_open = (cyl_st.prog > 0.15); return end   -- UI: Slider treibt prog
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

-- [CHAMBER-ADVANCE] Nach jedem Schuss (Schuss-Flanke __vr_shot_seq) die Trommel um shot_deg weiter-
-- drehen (akkumuliert), current animiert per shot_lerp hinterher. Einmal pro Frame.
local function update_cyl_spin()
    if not wep.wid then return end
    local r = cyl_cfg(wep.wid)
    local seq = tonumber(rawget(_G, "__vr_shot_seq")) or 0
    if spin_st.prev_seq == nil then
        spin_st.prev_seq = seq
    elseif seq > spin_st.prev_seq then
        spin_st.target = spin_st.target + (r.shot_deg or -30.0) * (seq - spin_st.prev_seq)
        spin_st.prev_seq = seq
    end
    local diff = spin_st.target - spin_st.current
    if math.abs(diff) <= 0.5 then spin_st.current = spin_st.target
    else spin_st.current = spin_st.current + diff * (r.shot_lerp or 0.20) end
end

-- [SPANNEN-POSE] NUR wp4500. frac = Cock-Zustand: 0 = normal, 1 = "spannen noetig"-Pose. Aktuell NUR ueber
-- die Vorschau-Checkbox getrieben (zum Tunen) -- der echte Trigger kommt spaeter. EIN frac treibt alles
-- gemeinsam: Hand-Offset (motion.lua), Daumen-Pose und Hahn _02. Sanft gelerpt.
-- Cock = EINMALIGE getimte Geste (Daumen drueckt den Sporn hoch, KLEBT kurz oben, federt zurueck), NICHT
-- gehaltene Pose. Stick-FLANKE startet; egal wie lange der Stick haengt, der Daumen geht raus und zurueck.
-- Der Hahn faehrt mit dem Daumen hoch, latcht (bleibt hinten) bis zum Schuss -> dann schneller Fall.
-- (Konsistent mit Handcannon wp4502 in reload3.)
-- [MERCS WIEDER AN 2026-08-04] Die Abschaltung im Mercenaries-DLC (02.08., `mercs_no_single`)
-- ist raus -- die Single-Action der Broken Butterfly laeuft dort wieder wie in der Kampagne.
-- Damals war am Daumen nichts zu sehen, weil die Keyframes nicht griffen (falscher Key-Satz +
-- alte 2-Punkt-Pose); das ist gefixt. Betrifft NUR wp4500; die Handcannon hat gar kein Cocking mehr.

-- [HAND-RAMPE 2026-08-04, "hand schnell in den offset, dann nur der daumen, am ende zurueck"]
-- Die Hand faehrt ueber die ersten HAND_RAMP der Phase in den cockhand-Offset, steht dann still
-- (nur die Daumen-Keys laufen) und faehrt ueber die letzten HAND_RAMP wieder zurueck.
local HAND_RAMP = 0.12
local function hand_frac_at(ph)
    local u
    if ph <= HAND_RAMP then u = ph / HAND_RAMP
    elseif ph >= 1.0 - HAND_RAMP then u = (1.0 - ph) / HAND_RAMP
    else return 1.0 end
    if u < 0 then u = 0 elseif u > 1 then u = 1 end
    return u * u * (3 - 2 * u)
end

local function update_hammer()
    if wep.wid ~= 4500 then
        hammer_st.hand_frac = 0; hammer_st.ham_frac = 0; hammer_st.cocked = false
        hammer_st.cock_running = false
        hammer_st.phase = 0; hammer_st.key_blend = 0   -- [DAUMEN-KEYS] Kurve aus
        return
    end
    local ry = tonumber(rawget(_G, "__vr_right_stick_y")) or 0
    local stick = (ry <= (hammer_st.cock_stick_y or -0.70))

    -- [DAUMEN-KEYS] Vorschau am Phasen-Regler hat Vorrang: Daumen UND Hahn stehen exakt da, wo sie in der
    -- echten Geste bei dieser Phase stuenden -> die Kuppe laesst sich Stuetzpunkt fuer Stuetzpunkt an den
    -- Sporn legen. Der Hahn folgt derselben Rampe wie im Lauf-Zweig unten (smoothstep ueber 'press').
    if hammer_st.kprev then
        local ph = math.min(math.max((hammer_st.kphase or 0) / 100.0, 0.0), 1.0)
        hammer_st.phase = ph
        hammer_st.key_blend = 1.0
        -- [EIN SLIDER] Hahn faehrt ueber die erste Haelfte der Phase hoch und rastet dort ein.
        local u = math.min(ph / 0.5, 1.0); u = u * u * (3 - 2 * u)
        hammer_st.ham_frac = u
        hammer_st.hand_frac = hand_frac_at(ph)   -- Hand: schnell rein, halten, am Ende zurueck
        hammer_st.cock_running = false
        return
    end

    -- Schuss-Flanke -> entspannen (Hahn faellt)
    local seq = tonumber(rawget(_G, "__vr_shot_seq")) or 0
    if hammer_st.prev_seq == nil then hammer_st.prev_seq = seq
    elseif seq > hammer_st.prev_seq then hammer_st.cocked = false; hammer_st.cock_running = false; hammer_st.prev_seq = seq end

    -- [AUSGEMISTET 2026-08-04] Hier hielt die Hand-Pose-Vorschau statisch frac=1 -- ohne key_blend,
    -- also lief dabei im Spiel die alte 2-Punkt-Daumenpose. Vorschau + alter Pfad sind beide raus.

    -- Stick-Flanke startet die Geste (nur wenn nicht schon gespannt / nicht schon laufend)
    if stick and not hammer_st.cock_prev and not hammer_st.cocked and not hammer_st.cock_running then
        hammer_st.cock_running = true; hammer_st.cock_t0 = os.clock(); hammer_st.cock_snd = false
        hammer_st.phase = 0.0   -- [DAUMEN-KEYS] Kurve startet vorne
    end
    hammer_st.cock_prev = stick

    if hammer_st.cock_running then
        -- [EIN SLIDER 2026-08-04, "einen slider der die gesamte animation mit meinen keyframes spielt"]
        -- EINE Dauer (CFG.cock_dur) = Phase 0..100 %. Die Daumenform macht komplett die Key-Kurve; hier
        -- laufen nur noch Hahn (_02) und der Hand-Offset mit. Hahn: hoch bis 50 %, rastet dort ein (Klick)
        -- und bleibt hinten. Hand: raus bis 50 %, danach zurueck an den Griff.
        local dur = math.max(CFG.cock_dur or 0.48, 0.05)
        local e = os.clock() - (hammer_st.cock_t0 or 0)
        local ph = math.min(e / dur, 1.0)
        hammer_st.phase = ph
        hammer_st.key_blend = 1.0
        local u = math.min(ph / 0.5, 1.0); u = u * u * (3 - 2 * u)
        hammer_st.ham_frac = u
        if ph >= 0.5 then
            if not hammer_st.cock_snd then hammer_st.cock_snd = true; play_weapon_sound(SND_COCK) end
            hammer_st.cocked = true
        end
        hammer_st.hand_frac = hand_frac_at(ph)   -- Hand: schnell rein, halten, am Ende zurueck
        if ph >= 1.0 then                       -- fertig: Daumen am Griff, Hahn bleibt hinten
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

-- [EJECT] Cooler Move: offene Trommel + Waffe gekippt (Muendung hoch -> Kammern nach unten) -> die
-- geladenen Kugeln fallen raus (rein visuell, KEIN Ammo-Verlust). Solange offen bleiben sie weg,
-- beim Zuklappen sind sie wieder da. Wir kennen die geladenen Kugeln via Ammo-Count.
local eject = { active = false, t0 = 0, items = {}, armed = true, exit = nil }
local EJECT_DOWN       = 0.6     -- wie steil die Kammer-Oeffnung (_05 Welt-Z) nach UNTEN zeigen muss
local EJECT_ZSIGN      = -1.0    -- welches Z-Ende die Oeffnung ist (1 = +Z, -1 = -Z)
local EJECT_SLIDE_DUR  = 0.13    -- s: erst entlang der Bohrung rausschieben (wie der Mag-Slide im advanced)
local EJECT_SLIDE_DIST = 0.055   -- m: wie weit raus aus der Kammer entlang der Achse
local EJECT_STAGGER    = 0.06    -- s Versatz zwischen den Kugeln
local EJECT_LAND_T     = 0.45    -- s freier Fall bis "Boden" (dann Sound + liegen bleiben)
local function update_eject()
    if not (CFG.revolver_enabled and wep.wid and wep.bullet_joints and wep.spin_joint) then return end
    if rawget(_G, "__vr_revolver_cyl_open") ~= true then   -- Trommel zu -> reset (Kugeln wieder da)
        eject.active = false; eject.items = {}; eject.armed = true; return
    end
    if eject.active then return end   -- schon ausgeworfen (bis Trommel zu)
    -- Bohrungs-/Oeffnungs-Achse der Trommel = _05 Welt-Z. Auswurf nur wenn die nach UNTEN zeigt (Gravity).
    local rot = sc(wep.spin_joint, "get_Rotation"); if not rot then return end
    local bore = safe(function() return rot * Vector3f.new(0, 0, EJECT_ZSIGN) end); if not bore then return end
    if bore.y < -EJECT_DOWN and eject.armed then
        local wi = get_live_wi()
        local loaded = wi and (tonumber(sc(wi, "get_CurrentAmmoCount")) or 0) or 0
        local n = math.min(loaded, #wep.bullet_joints)
        if n > 0 then
            local bl = math.sqrt(bore.x * bore.x + bore.y * bore.y + bore.z * bore.z)
            eject.exit = (bl > 1e-6) and Vector3f.new(bore.x / bl, bore.y / bl, bore.z / bl) or Vector3f.new(0, -1, 0)
            -- Boden-Hoehe = Spieler-Fusspunkt (body-Position Y). Kugeln fallen bis dahin.
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
                        wx = 220 + i * 47, wy = 130 + i * 29, wz = 170 + i * 61,  -- Grad/s Tumble, pro Kugel variiert
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
-- [EJECT] Pro Kugel: Stagger-Wartezeit -> entlang der Bohrung rausschieben -> freier Fall + Taumeln ->
-- am "Boden" Drop-Sound + liegen bleiben. Laeuft NACH apply_bullet_visibility (ueberschreibt deren Anzeige).
local function apply_eject()
    if not (eject.active and eject.exit) then return end
    local now = os.clock(); local ex = eject.exit
    for _, it in ipairs(eject.items) do
        pcall(function() it.joint:call("set_LocalScale", it.vis) end)
        local lt = (now - eject.t0) - it.delay
        if lt <= 0 then
            pcall(function() it.joint:call("set_Position", Vector3f.new(it.sx, it.sy, it.sz)) end)   -- noch in der Kammer (Stagger)
        else
            local s = (math.min(lt, EJECT_SLIDE_DUR) / EJECT_SLIDE_DUR) * EJECT_SLIDE_DIST   -- entlang Bohrung raus
            local px, py, pz = it.sx + ex.x * s, it.sy + ex.y * s, it.sz + ex.z * s
            if lt > EJECT_SLIDE_DUR then
                local ft = lt - EJECT_SLIDE_DUR
                py = py - 0.5 * REV_GRAVITY * ft * ft                                          -- gerade fallen
                if py <= (eject.floor_y or -9999) then                                         -- am Boden -> liegen + Sound
                    py = eject.floor_y
                    if not it.landed then it.landed = true; it.land_lt = lt; play_weapon_sound(SND_DROP) end
                end
            end
            pcall(function() it.joint:call("set_Position", Vector3f.new(px, py, pz)) end)
            if it.rest_rot then   -- Taumeln (eingefroren beim Aufkommen)
                local tt = it.land_lt or lt
                local q = quat_from_euler(it.wx * tt, it.wy * tt, it.wz * tt)
                local nr = safe(function() return (it.rest_rot * q):normalized() end)
                if nr then pcall(function() it.joint:call("set_Rotation", nr) end) end
            end
        end
    end
end

-- [WRIST-FLICK CLOSE] Trommel per schnellem Hoch/Runter-Handgelenk-Flick ZUSCHNAPPEN (nur schliessen,
-- nicht oeffnen). Misst die Pitch-Geschwindigkeit (forward.y der rechten Hand __vr_rh_rot). Grace nach
-- dem Aufklappen (Anhebe-Bewegung ignorieren) + Cooldown gegen Doppeltrigger.
local flick = { prev_fy = nil, prev_t = nil, last_close = 0, was_open = false, open_t = 0, snd_at = nil, peak_dir = 0, peak_t = 0 }
local FLICK_VEL        = 8.0    -- forward.y-Geschw. (1/s), ab der eine Bewegung als "schnell" zaehlt
local FLICK_REVERSAL   = 0.30   -- max s zwischen Hin- UND Rueckschlag -> nur ein RUCK (Flick) zaehlt, kein Kippen
local FLICK_OPEN_GRACE = 0.35   -- s nach dem Aufklappen kein Flick-Close
local FLICK_SND_DELAY  = 0.18   -- s nach dem Flick bis der Zuschnapp-Sound kommt (feste Zeit)
local function update_close_flick()
    local now = os.clock()
    -- [SOUND-DELAY] geplanten Zuschnapp-Sound nach fester Zeit spielen
    if flick.snd_at and now >= flick.snd_at then
        play_weapon_sound(SND_COCK); flick.snd_at = nil   -- [SOUND] Flick = Schliessen -> Close-Sound (getauscht)
    end
    local open = cyl_st.open == true
    if open and not flick.was_open then flick.open_t = now end   -- gerade aufgeklappt
    flick.was_open = open
    if not (wep.wid and open) then flick.prev_fy = nil; flick.peak_dir = 0; return end
    local rot = rawget(_G, "__vr_rh_rot"); if not rot then flick.prev_fy = nil; return end
    local fwd = safe(function() return rot * Vector3f.new(0, 0, 1) end); if not fwd then return end
    local fy = fwd.y
    -- gemerkten Hinschlag vergessen, wenn der Rueckschlag zu spaet kommt (= war ein langsames Kippen)
    if flick.peak_dir ~= 0 and (now - flick.peak_t) > FLICK_REVERSAL then flick.peak_dir = 0 end
    if flick.prev_fy ~= nil and flick.prev_t then
        local dt = now - flick.prev_t
        if dt > 0.001 and dt < 0.2 then
            local vel = (fy - flick.prev_fy) / dt
            if math.abs(vel) > FLICK_VEL then
                local dir = (vel > 0) and 1 or -1
                if flick.peak_dir ~= 0 and dir ~= flick.peak_dir          -- Richtungs-UMKEHR = echter Ruck
                   and (now - flick.open_t) > FLICK_OPEN_GRACE
                   and (now - flick.last_close) > 0.5 then
                    cyl_st.open = false                 -- zuschnappen
                    flick.snd_at = now + FLICK_SND_DELAY
                    flick.last_close = now
                    flick.peak_dir = 0
                else
                    flick.peak_dir = dir; flick.peak_t = now   -- Hinschlag merken, auf Rueckschlag warten
                end
            end
        end
    end
    flick.prev_fy = fy
    flick.prev_t = now
end

re.on_frame(function()
    refresh_weapon()
    if not wep.wid then
        cyl_st._prev_b = false; _G.__vr_rev_cock_frac = 0
        reload2_st.kf_active = false; reload2_st.kf_used = false   -- [SHELL-KEYFRAMES] Bahn-Flags beim Ablegen loesen (sonst haengt der naechste Start)
        if reload2_st._mih_owned then _G.__vr_mag_in_hand = false; reload2_st._mih_owned = false end   -- [SUPPORT-COOLDOWN] Flag freigeben beim Ablegen
        return
    end
    -- [B-CONSUME] Right-B fuer den nativen Engine-Reload abfangen. Im CAPTURE-Modus EXPLIZIT false
    -- (Globals ueberleben Reset -> sonst bleibt der Consume haengen) -> native Anim laeuft, ich lese
    -- die echte offene Trommel-Rotation aus.
    _G.__vr_manual_reload_consume_b = not _CAPTURE
    -- [SHELL FLOW] Holster-Gate: true = nichts zu greifen (Holster sperrt + buzzt). Nur fuer den
    -- Revolver setzen (laeuft erst ab hier = wep.wid vorhanden) -> ueberschreibt reload.lua's Stale-Wert.
    _G.__re4_reload_grab_empty = not revolver_can_grab()
    update_cylinder()
    update_close_flick()   -- [WRIST-FLICK] offene Trommel per Hoch/Runter-Flick zuschnappen
    update_eject()         -- [EJECT] offene Trommel + gekippt -> geladene Kugeln fallen raus (visuell)
    update_cyl_spin()   -- [CHAMBER-ADVANCE] Trommel pro Schuss weiterdrehen
    update_hammer()     -- [SINGLE-ACTION] Hahn _02 nach jedem Schuss spannen (nur wp4500)
    -- [COCK-HAND 2026-08-04, "die handbewegung sollte nicht raus, die hand soll nach oben rutschen"]
    -- Der Hand-Roll/Versatz beim Spannen bleibt (motion.lua liest __vr_rev_cock_frac + __vr_rev_cock_off),
    -- raus ist nur die alte Daumenpose. EIN Offset-Satz (hammer_st.hand) fuer alles -- kein Aim/No-Aim mehr;
    -- die Werte stehen in der JSON unter "cockhand" (Regler dafuer sind aus dem Tree entfernt).
    -- [AIM-HAND 2026-08-04, "die waffe steht in aim etwas anders"] Zwei Offset-Saetze, ausgewaehlt
    -- ueber __vr_aim_input (der ECHTE VR-Zielzustand, motion.lua:2690) -- NICHT ueber `is_aim`, das ist
    -- get_IsShootEnable und mit gezogener Waffe fast immer true. Zum Tunen haelt hold_hand den Offset.
    if wep.wid == 4500 then
        -- Im Spiel entscheidet der echte Zielzustand; solange die Tuning-Vorschau (hold_hand) laeuft,
        -- gilt STATT DESSEN der im UI gewaehlte Satz -- so tunt man immer genau den, der im UI steht.
        if hammer_st.hold_hand then hammer_st.use_aim = hammer_st.edit_aim == true
        else hammer_st.use_aim = rawget(_G, "__vr_aim_input") == true end
        local hf = hammer_st.hand_frac or 0
        if hammer_st.hold_hand then hf = 1.0 end
        _G.__vr_rev_cock_frac = hf
        _G.__vr_rev_cock_off  = hammer_st.use_aim and hammer_st.hand_aim or hammer_st.hand
    else _G.__vr_rev_cock_frac = 0; hammer_st.use_aim = false end
    update_reload()   -- [RELOAD] Shell-by-Shell: Hand mit Patrone an offene Trommel -> +1
    -- [SHELL-KEYFRAMES 2026-07-24] Patronen-Clone-Transform + Waffe fuer die Keyframe-UI/Bahn
    -- (reload_adv) exponieren -- reload2 laeuft NACH reload.lua -> ueberschreibt dessen Stale-Globals
    -- fuer den Revolver (sonst waere shell_joint nil = keine Preview/Bahn).
    if is_revolver(wep.wid) then
        _G.__re4_reload_ui_wid = wep.wid   -- IMMER -> Keyframe-UI zeigt die Waffe auch ohne Clone in der Hand
        -- [SHELL-KEYFRAMES] shell_joint fuer den Revolver BEWUSST NICHT setzen: reload2 positioniert den
        -- Clone selbst (reposition_cart_late) -> sonst zieht reload_adv's shell_preview_apply parallel am
        -- selben Clone in einem anderen Pass = Wabbeln (2 Schreiber). ui_wid reicht der Keyframe-UI.
    end
    -- [SUPPORT-HAND + COOLDOWN] Patrone in der Hand -> motion.lua Support-Hand AUS; nach dem Einsetzen noch
    -- support_cooldown s oben halten, damit die Support-Hand nicht SOFORT andockt ( kann Hand wegziehen).
    -- Konsistent mit Handcannon (reload3). NUR wenn BB gemanagt -> sonst clobbern wir andere Waffen nicht.
    if wep.wid == 4500 then
        local cd_ok = reload2_st._insert_t and (os.clock() - reload2_st._insert_t) < (CFG.support_cooldown or 0.45)
        _G.__vr_mag_in_hand = (reload2_st.cart or cd_ok) and true or false
        reload2_st._mih_owned = true
    elseif reload2_st._mih_owned then
        _G.__vr_mag_in_hand = false   -- BB abgelegt -> Flag freigeben (sonst bleibt Support unterdrueckt)
        reload2_st._mih_owned = false
    end
    -- [FIRE-BLOCK / SINGLE-ACTION] binding.lua liest __vr_block_fire_when_empty -> blockt RT und setzt
    -- __re4_empty_trigger_held bei RT-Druck. Regeln NUR wp4500 (Single-Action):
    -- * Trommel offen -> immer gesperrt (Dry-Fire-Klick wie bisher).
    -- * Hahn NICHT gespannt -> gesperrt, RT-Pull = Dry-Fire-Klick (Feedback; kein Spin/Uncock, Hahn ist unten).
    -- * Hahn gespannt + Ammo>0 -> NICHT gesperrt -> echter Schuss (Engine), update_hammer entspannt danach.
    -- * Hahn gespannt + Ammo==0 -> gesperrt, RT-Pull = DRY-FIRE: Trommel dreht + Klick + Hahn faellt.
    local cyl_open = rawget(_G, "__vr_revolver_cyl_open") == true
    -- [MERCS] dort keine Single-Action -> kein "Hahn nicht gespannt"-Feuerblock
    local single   = (wep.wid == 4500)
    local cocked   = hammer_st.cocked == true
    -- [LIVE-EMPTY 2026-07-08] Leer NUR aus der Engine (pe:isGunAmmoEmpty, jeden Frame frisch), NIE aus dem
    -- gecachten get_live_wi:get_CurrentAmmoCount (nach Save-Load stale 0 -> Dry-Fire trotz Munition).
    -- Plus Unlimited-Bypass (voll ausgebaute Broken Butterfly = infinite -> AmmoCount 0 aber feuert) wie beim
    -- Handcannon (reload3). Hat die Gun eine gechamberte Patrone -> feuert IMMER (sofern gespannt).
    local _pe4500 = single and get_pe()
    local empty4500 = single and ((_pe4500 and safe(function() return _pe4500:call("isGunAmmoEmpty") end)) == true)
    local unlimited4500 = single and (_G.__re4_is_unlimited and _G.__re4_is_unlimited()) == true
    if single then
        _G.__vr_block_fire_when_empty = cyl_open or ((not cocked) and not unlimited4500) or (empty4500 and not unlimited4500)
        _G.__re4_bf_who = "re4_vr_reload2.lua:897"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    else
        _G.__vr_block_fire_when_empty = cyl_open
        _G.__re4_bf_who = "re4_vr_reload2.lua:899"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    end
    local et = rawget(_G, "__re4_empty_trigger_held") == true
    if et and not reload2_st._dry_prev then
        if single and cocked and not cyl_open then
            -- Leerer Single-Action-Schuss (Ammo 0): Klick + Trommel einen Schritt weiter + Hahn entspannen.
            play_weapon_sound(SND_DRY_FIRE)
            local r = cyl_cfg(wep.wid)
            spin_st.target = spin_st.target + (r.shot_deg or -30.0)
            hammer_st.cocked = false
        elseif cyl_open then
            play_weapon_sound(SND_DRY_FIRE)   -- offene Trommel -> Klick (wie bisher)
        elseif single then
            -- Hahn nicht gespannt + Trommel zu: nur Klick (kein Spin/Uncock, Hahn ist unten).
            play_weapon_sound(SND_DRY_FIRE)
        end
    end
    reload2_st._dry_prev = et
end)

-- [CYLINDER] Override-Pass (voller Stack, nach der Engine-Anim): _06 um (rx,ry,rz)*prog drehen.
local function apply_cylinder_pass()
    if _CAPTURE then return end   -- [CAPTURE] native Rotation NICHT ueberschreiben
    if not (CFG.revolver_enabled and wep.cyl_joint and wep.cyl_rest_rot) then return end
    local r = cyl_cfg(wep.wid)
    local has_pos = (r.px ~= 0 or r.py ~= 0 or r.pz ~= 0)
    local p = cyl_st.prog or 0
    if p <= 0.0001 then
        -- zu: Rotation der Engine ueberlassen; Position aber explizit auf Ruhe zuruecksetzen, sonst
        -- bliebe der Translations-Offset haengen (LocalPosition wird nicht zwingend pro Frame animiert).
        if has_pos and wep.cyl_rest_pos then
            local rp = wep.cyl_rest_pos
            pcall(function() wep.cyl_joint:call("set_LocalPosition", Vector3f.new(rp.x, rp.y, rp.z)) end)
        end
        return
    end
    -- [ROT] Crane-Dreh-Revolver (4502): Trommel-Joint um (rx,ry,rz)*prog drehen.
    local q = quat_from_euler(r.rx * p, r.ry * p, r.rz * p)
    local newrot = safe(function() return (wep.cyl_rest_rot * q):normalized() end)
    if newrot then pcall(function() wep.cyl_joint:call("set_LocalRotation", newrot) end) end
    -- [POS] Translations-Revolver (Broken Butterfly 4500): Trommel per LocalPosition-Offset rausfahren.
    if has_pos and wep.cyl_rest_pos then
        local rp = wep.cyl_rest_pos
        pcall(function() wep.cyl_joint:call("set_LocalPosition", Vector3f.new(rp.x + r.px * p, rp.y + r.py * p, rp.z + r.pz * p)) end)
    end
end
-- [BULLETS] Aktuellen Trommel-Ammo-Stand lesen. KONSISTENZ: bevorzugt das Live-WeaponItem
-- (dasselbe, auf das der Insert schreibt), Fallback PlayerEquipment.getCurrentGunAmmo.
local function get_gun_ammo()
    local wi = get_live_wi()
    if wi then local a = tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)); if a then return a end end
    local pe = get_pe(); if not pe then return nil end
    return tonumber(safe(function() return pe:call("getCurrentGunAmmo") end))
end

-- [BULLETS] Nur so viele Kugel-Joints zeigen wie Ammo da ist. 6=alle, 5=eine weniger... 0=keine.
-- Versteckt via LocalScale 0 (sichtbar = gemerkter Ruhe-Scale). MaxCap >6 -> auf Kammerzahl geclamped
-- (also bei vollem/ueberfuelltem Magazin trotzdem alle 6 sichtbar). Native zeigt sonst immer alle.
local _HIDE = Vector3f.new(0, 0, 0)
local function apply_bullet_visibility()
    if _CAPTURE then return end
    if not (CFG.revolver_enabled and wep.bullet_joints and #wep.bullet_joints > 0) then return end
    local cap = #wep.bullet_joints
    local ammo = get_gun_ammo(); if not ammo then return end
    if ammo > cap then ammo = cap elseif ammo < 0 then ammo = 0 end
    for i, b in ipairs(wep.bullet_joints) do
        if i <= ammo then
            pcall(function() b.joint:call("set_LocalScale", b.vis) end)
        else
            pcall(function() b.joint:call("set_LocalScale", _HIDE) end)
        end
    end
end

-- [SHELL-IN-HAND] Finger-Pose (aus reload.json POSES via reload.lua-Engine) auf die linke Hand legen,
-- solange die Trommel OFFEN ist (Reload-Phase). Plus additive Daumen-Spreizung. reload.lua loescht
-- __vr_mag_hand_pose fuer den Revolver (unmanaged) -> wir wenden direkt _G.__re4_reload_apply_pose an.
local function apply_shell_pose()
    if not (CFG.revolver_enabled and wep.wid) then return end
    local s = SHELL[wep.wid]
    local want = nil
    if s and (reload2_st.cart or reload2_st.preview) and s.pose and s.pose ~= "" then want = s.pose end
    -- [POSE_FADE] beim Loslassen ueber POSE_FADE_DUR zurueckblenden statt snappen (s als data cachen)
    local fname, b, fs = _G.__re4_pose_fade_step(_G.__re4_r2_shellfade, want, s)
    if not fname then return end
    s = fs or s; if not s then return end
    local f = rawget(_G, "__re4_reload_apply_pose")
    if f then pcall(function() f(fname, b) end) end
    -- Daumen-Spreizung additiv auf L_Thumb1 (NACH der Pose), per-Waffe. Mit blend skaliert.
    if s.t_rx ~= 0 or s.t_ry ~= 0 or s.t_rz ~= 0 then
        local bt = body_tf()
        local thumb = bt and sc(bt, "getJointByName", "L_Thumb1")
        local cur = thumb and sc(thumb, "get_LocalRotation")
        if cur then
            local q = quat_from_euler(s.t_rx*b, s.t_ry*b, s.t_rz*b)
            pcall(function() thumb:call("set_LocalRotation", (cur * q):normalized()) end)
        end
    end
    -- [ZEIGEFINGER] additiv auf L_IndexF1/2/3 (Greif-Pose der Patrone, vom Handcannon uebernommen).
    if (s.i_rx or 0) ~= 0 or (s.i_ry or 0) ~= 0 or (s.i_rz or 0) ~= 0 then
        local bt = body_tf()
        for _, jn in ipairs({ "L_IndexF1", "L_IndexF2", "L_IndexF3" }) do
            local jt = bt and sc(bt, "getJointByName", jn)
            local cur = jt and sc(jt, "get_LocalRotation")
            if cur then
                local q = quat_from_euler((s.i_rx or 0)*b, (s.i_ry or 0)*b, (s.i_rz or 0)*b)
                pcall(function() jt:call("set_LocalRotation", (cur * q):normalized()) end)
            end
        end
    end
end

-- [SHELL-IN-HAND MESH-CLONE] Patrone in der Hand = eigenstaendiger MESH-CLONE der Patronen-Parts
-- (Standard 20=Spitze + 30=Patrone, per-Waffe konfigurierbar) auf einem eigenen GameObject -> die
-- echte Trommel bleibt voellig unberuehrt (KEIN Loch mehr, MIT Spitze). Technik wie Red9:
-- via.motion.Motion (baut Skelett) + via.render.Mesh + setMesh(lebender Gun-Holder) + Gun-Material +
-- Parts isolieren. Siehe Notiz.
local function rev_gun_mesh()
    if not wep.tf then return nil end
    local go = sc(wep.tf, "get_GameObject")
    return go and sc(go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
end
cart_destroy = function()   -- forward-deklariert (oben), hier nur zuweisen
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
    local go = create and safe(function() return create:call(nil, "vr_revolver_cart") end); if not go then return false end
    pcall(function() go:add_ref() end)
    pcall(function() go:call("createComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)   -- KERN: baut Skelett
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
    local okp = pcall(function() tf:set_position(p, true) end)   -- no_dirty gegen Jitter (wie Red9)
    if not okp then pcall(function() tf:call("set_Position", p) end) end
    if rot then local okr = pcall(function() tf:set_rotation(rot) end); if not okr then pcall(function() tf:call("set_Rotation", rot) end) end end
    if scl then pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end) end
end

local function apply_held_cartridge()
    if not (CFG.revolver_enabled and wep.wid) then return end
    -- Anzeigen wenn Patrone in der Hand (Holster->einlegen) ODER UI-Vorschau. Fall wird in apply_cart_drop bewegt.
    -- [SHELL-KEYFRAMES 2026-07-24] Keyframe-Preview an (reload_adv, DIREKT abgefragt -> kein Timing/
    -- ui_wid-Problem) -> Clone spawnen, damit man ihn OHNE Patrone in der Hand am Desktop tunen kann.
    local _kms = rawget(_G, "__re4_reload_mag_slide")
    local _kfp = (_kms and _kms.shell_preview and _kms.KEYFRAME_INSERT and _kms.KEYFRAME_INSERT[wep.wid]) == true
    if not (reload2_st.cart or reload2_st.preview or drop2.active or _kfp) then
        if cart_clone.obj then cart_destroy() end
        return
    end
    if drop2.active then return end                       -- Drop hat eigene Bewegung
    if cart_clone.obj and cart_clone.wid ~= wep.wid then cart_destroy() end   -- Waffenwechsel -> neu
    if not cart_clone.obj then if not cart_spawn() then return end end
    cart_isolate()
    -- [SHELL-KEYFRAMES] Bahn ODER Keyframe-Preview -> Clone-Position macht der Keyframe-Pass (reload_adv /
    -- reposition_cart_late), hier NICHT an die Hand ziehen. Clone bleibt gespawnt/isoliert.
    if reload2_st.kf_active or _kfp then
        -- [SHELL-KEYFRAMES] Preview: Clone entkoppeln + sichtbar skalieren (die Keyframe-Pass setzt nur
        -- Position/Rotation, nicht die Scale -> ohne das waere der Clone unsichtbar/falsch skaliert).
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
local function hide_hand_cartridge_when_idle() end   -- (no-op: apply_held_cartridge zerstoert den Clone wenn idle)

-- [DROP] Fallengelassene Patrone: den Mesh-Clone von seiner Loslass-Position frei fallen lassen
-- (Deko, ~1s), danach zerstoeren. Trommel bleibt unberuehrt.
local function apply_cart_drop()
    if not (CFG.revolver_enabled and wep.wid and drop2.active) then return end
    if not cart_clone.obj then drop2.active = false; return end
    local t = os.clock() - drop2.t0
    if t > REV_DROP_DUR then drop2.active = false; cart_destroy(); return end
    if not drop2.snd and t >= 0.45 then drop2.snd = true; play_weapon_sound(SND_DROP) end   -- Boden-Aufprall (0.45s ~ Falldauer)
    local fall = 0.5 * REV_GRAVITY * t * t
    local tf = safe(function() return cart_clone.obj:call("get_Transform") end); if not tf then return end
    local s = (SHELL[wep.wid] or {}).scale or 1.0
    cart_set_tf(tf, Vector3f.new(drop2.sx, drop2.sy - fall, drop2.sz), nil, s)
end

-- [WOBBLE-FIX] Patrone NACH motion.lua's finalem L_Hand-Write nachziehen. apply_held_cartridge laeuft im
-- BeginRendering-PRE-Pass -> liest die Hand BEVOR motion sie auf die VR-Endlage setzt (attach_left_hand im
-- BeginRendering-POST) -> Patrone haengt 1 Pass hinterher = Wabbeln. Diese schlanke Variante laeuft im POST
-- (reload2 laedt nach motion) und repositioniert NUR (kein Spawn/Isolate) auf die finale Hand.
local function reposition_cart_late()
    if not (CFG.revolver_enabled and wep.wid and cart_clone.obj) then return end
    if drop2.active then return end
    -- [SHELL-KEYFRAMES 2026-07-24] Bahn aktiv -> Clone entlang der Keyframes fahren (relativ zur Waffe),
    -- statt ihn an der Hand zu halten. Am Bahn-Ende die Patrone real einlegen (insert_one_round).
    if reload2_st.kf_active then
        local ms = rawget(_G, "__re4_reload_mag_slide")
        local tf = safe(function() return cart_clone.obj:call("get_Transform") end)
        if ms and tf and type(ms.shell_pose_at) == "function" and wep.tf then
            local dur = tonumber(ms.shell_dur) or 0.4
            local tt = (os.clock() - (reload2_st.kf_t0 or 0)) / math.max(dur, 0.01)
            if tt > 1.0 then tt = 1.0 end
            -- [SHELL-KEYFRAMES] interpolierte Bahn-Pose relativ zur Waffe + cart_set_tf (mit Scale -> sichtbar).
            local x, y, z, rx, ry, rz = ms.shell_pose_at(wep.wid, tt)
            local gp = sc(wep.tf, "get_Position"); local gr = sc(wep.tf, "get_Rotation")
            if x and gp and gr then
                local off = safe(function() return gr * Vector3f.new(x, y, z) end)
                local pos = off and Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z) or gp
                local rot = safe(function() return (gr * quat_from_euler(rx, ry, rz)):normalized() end)
                cart_set_tf(tf, pos, rot, (SHELL[wep.wid] or {}).scale or 1.0)
            end
            if tt >= 1.0 then
                reload2_st.kf_active = false
                reload2_st.cart = false   -- [SHELL-KEYFRAMES] Bahn (Deko) fertig -> Clone entfernen; +1 sass schon beim Bahn-Start
            end
        else
            reload2_st.kf_active = false
        end
        return
    end
    -- [SHELL-KEYFRAMES 2026-07-24] Keyframe-Preview: den reload2-Clone-Pfad NACHBAUEN, nur relativ zur
    -- WAFFE + Tuning-Lage statt zur Hand -> Clone wird garantiert sichtbar gesetzt (cart_set_tf, bewaehrt).
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
    if not (reload2_st.cart or reload2_st.preview) then return end
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

-- [SPIN-LOCK] Native Chamber-Spin-Animation der Trommel (_05 Eigenrotation) unterdruecken: lokale
-- Rotation jeden Pass auf die gemerkte Ruhe halten. Stoppt das "Selbstdrehen" nach Empty-Reload
-- (stale Anim). Der Aufklapp-Swing bleibt, weil der ueber den PARENT _04 laeuft (nicht _05 lokal).
local function apply_cylinder_spin_lock()
    if not (CFG.revolver_enabled and wep.spin_joint and wep.spin_rest_rot) then return end
    local rot = wep.spin_rest_rot
    if spin_st.current ~= 0 then   -- [CHAMBER-ADVANCE] Schuss-Drehung additiv um Z auf die Ruhe
        rot = safe(function() return (wep.spin_rest_rot * quat_from_euler(0, 0, spin_st.current)):normalized() end) or wep.spin_rest_rot
    end
    pcall(function() wep.spin_joint:call("set_LocalRotation", rot) end)
end

-- [SPANNEN-POSE] Hahn _02 (NUR wp4500): Winkel kommen aus hammer_cfg (idle <-> cocked, je 3 Achsen),
-- gelerpt mit frac. _02 = Ruhe * euler(lerp(idle,cocked,frac)). Tunebar via UI (Slider + Vorschau), JSON.
local function apply_hammer_pass()
    if not (CFG.revolver_enabled and wep.wid == 4500 and wep.hammer_joint and wep.hammer_rest_rot) then return end
    local h = hammer_cfg(wep.wid)
    local f = hammer_st.ham_frac or 0
    local ax = h.idle_rx + (h.rx - h.idle_rx) * f
    local ay = h.idle_ry + (h.ry - h.idle_ry) * f
    local az = h.idle_rz + (h.rz - h.idle_rz) * f
    local q = quat_from_euler(ax, ay, az)
    local nr = safe(function() return (wep.hammer_rest_rot * q):normalized() end)
    if nr then pcall(function() wep.hammer_joint:call("set_LocalRotation", nr) end) end
end

-- [SPANNEN-POSE] Daumen R_Thumb1/2/3 (NUR wp4500): ein Satz additiver Winkel pro Glied (cx/cy/cz), skaliert
-- mit frac (0=normal, 1=Spannen-Pose). Rest der rechten Hand unangetastet.
local function apply_thumb_pass()
    if not (CFG.revolver_enabled and wep.wid == 4500) then return end
    local bt = body_tf(); if not bt then return end
    -- [DAUMEN-KEYS] Sind fuer diesen Satz (Aim/No-Aim) Stuetzpunkte gesetzt, kommen Winkel UND Versatz je
    -- Glied aus der Kurve ueber die Phase -- statt des 2-Punkt-Lerps unten. In der Vorschau mit "Live"
    -- zeigen stattdessen direkt die Regler-Werte (sonst tunt man gegen die schon interpolierte Kurve).
    local kb = hammer_st.key_blend or 0
    -- [ZWEI KEY-SAETZE 2026-08-04] HUEFTE und AIM haben je eine Key-Liste. Live entscheidet
    -- __vr_aim_input (der ECHTE VR-Zielzustand) -- NICHT `is_aim`, das ist get_IsShootEnable
    -- (crosshair.lua:463) und mit gezogener Waffe fast immer true; daran scheiterte es vorher.
    -- In der Vorschau gilt der im UI gewaehlte Satz. Leerer Satz -> der andere greift.
    local kaim
    if hammer_st.kprev then kaim = hammer_st.key_aim == true
    else kaim = rawget(_G, "__vr_aim_input") == true end
    local KL = thumb_keys(wep.wid, kaim)
    if #KL == 0 then KL = thumb_keys(wep.wid, not kaim) end
    -- [VORSCHAU 2026-08-04] Vorschau an = die REGLER stehen am Daumen, immer. So aendert jeder Regler
    -- sofort sichtbar den Daumen (und "laden" zeigt den geladenen Key). Die fertige Kurve sieht man,
    -- indem man die Vorschau ausmacht und die Geste im Spiel macht.
    local klive = hammer_st.kprev == true
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
                -- [DAUMEN-KEYS ABSOLUT 2026-07-31, "der Daumen bewegt sich die ganze Zeit noch nativ"]
                -- Vorher lief das additiv auf die LAUFENDE Anim (cur * q) -- damit bleibt die Spiel-Animation
                -- der Chef und unsere Werte sind nur ein Offset obendrauf, der im Zappeln untergeht.
                -- Keyframes muessen die Anim ERSETZEN: gegen die BIND-Pose rechnen (get_BaseLocalRotation,
                -- konstant, kein Engine-State) und mit kb von der Anim dorthin slerpen. kb = 1 -> der Daumen
                -- steht exakt auf dem Key, die Anim ist fuer die Dauer der Geste egal.
                local rest = sc(jt, "get_BaseLocalRotation") or cur
                local q = quat_from_euler(o.x or 0, o.y or 0, o.z or 0)
                local tgt = safe(function() return (rest * q):normalized() end)
                if tgt then
                    local nr = tgt
                    if kb < 0.999 then
                        local okb, r2 = pcall(function() return cur:slerp(tgt, kb) end)
                        if okb and r2 then nr = r2 end
                    end
                    pcall(function() jt:call("set_LocalRotation", nr) end)
                end
                -- [DAUMEN-KEYS] Versatz PRO GLIED (nicht nur an der Basis) -> "strecken" ist keyframebar.
                -- Ebenfalls absolut: Ziel = BIND-Position + Key-Versatz, mit kb eingeblendet.
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
    -- [ALTE DAUMENBEWEGUNG RAUS 2026-08-04] Hier lag der alte 2-Punkt-Pfad: Daumenwinkel aus
    -- tcfg (idle/cocked cx/cy/cz) + Basis-Versatz thumb_pos, additiv auf die laufende Anim, skaliert
    -- mit hand_frac. Er lief IMMER, wenn die Key-Kurve gerade nicht griff (z.B. solange eine Hand-Pose-
    -- Vorschau an ist, denn die setzt kein key_blend) -- und genau das war im Spiel "die alte Bewegung".
    -- Der Daumen kommt jetzt AUSSCHLIESSLICH aus den Keyframes oben; greifen die nicht, bleibt die
    -- Engine-Animation stehen. Die alten Daumen-Slider im Tree sind damit wirkungslos.
end

local function apply_revolver_pass()
    apply_cylinder_pass()
    apply_cylinder_spin_lock()       -- _05 Eigenrotation auf Ruhe -> kein Selbstdrehen
    apply_hammer_pass()              -- [SINGLE-ACTION] Hahn _02 in gespannte Lage (nur wp4500)
    apply_thumb_pass()               -- [SINGLE-ACTION] rechter Daumen synchron zum Hahn (nur wp4500)
    apply_bullet_visibility()
    apply_held_cartridge()           -- geliehene Kammer-Kugel an der Hand (wenn gehalten/Vorschau)
    apply_cart_drop()                -- fallengelassene Patrone (freier Fall nach Loslassen)
    apply_eject()                    -- [EJECT] geladene Kugeln rausfallen lassen (gekippte offene Trommel)
    hide_hand_cartridge_when_idle()  -- (no-op)
    apply_shell_pose()
end
pcall(function() re.on_pre_application_entry("LockScene", apply_revolver_pass) end)
pcall(function() re.on_application_entry("LateUpdateBehavior", apply_revolver_pass) end)
pcall(function() re.on_application_entry("UpdateJointExpression", apply_revolver_pass) end)
pcall(function() re.on_pre_application_entry("BeginRendering", apply_revolver_pass) end)
-- [WOBBLE-FIX] Patrone NACH motion.lua's BeginRendering-POST (attach_left_hand) nochmal auf die finale Hand.
pcall(function() re.on_application_entry("BeginRendering", reposition_cart_late) end)

-- [SHELL FLOW] Holster-Hook einklinken: holster.lua ruft _G.__re4_reload_set_mag_in_hand(active).
-- reload.lua definiert es (fuer seine Waffen) und lehnt den Revolver ab (not _managed). Wir WRAPPEN:
-- Revolver -> reload2, sonst -> reload.lua-Original. Ladereihenfolge: reload.lua VOR reload2 -> Original
-- liegt vor. Bei on_script_reset definiert reload.lua sein Original neu -> wir re-wrappen frisch.
local _orig_set_mag_in_hand = _G.__re4_reload_set_mag_in_hand
_G.__re4_reload_set_mag_in_hand = function(active)
    if is_revolver(get_equip_wid()) then return revolver_set_mag_in_hand(active) end
    if _orig_set_mag_in_hand then return _orig_set_mag_in_hand(active) end
    return false
end

-- =====================================================================
-- =====================================================================
-- RIFLE-GATTUNG (eigener, vollstaendig gekapselter Block)
-- =====================================================================
-- Erste Rifle: wp4401 "Stingray". Logik = LE5-SMG (Mag-Drop _04 + Slide-Rack _02 +
-- Verstellschalter _05). Komplett in einem do...end-Block, damit die hier deklarierten
-- ~Locals NACH dem Block wieder freigegeben werden (reload2-Local-Budget bleibt niedrig);
-- die re.on_*-Closures leben ueber ihre Upvalues weiter. KEINE Zeile davon beruehrt den
-- Revolver oder reload.lua. Reload.lua ignoriert Rifles (kein JOINTS/CATEGORY-Eintrag dort)
-- -> _managed=false -> reload.lua schreibt NICHTS an der Stingray. Wir publishen dieselben
-- Globals wie reload.lua fuer die gemanagte SMG (motion/arm_chain/binding/holster lesen sie
-- waffen-agnostisch). reload2 laedt NACH reload -> unsere on_frame/apply-Passes gewinnen.
-- Eigenes JSON: reframework/data/re4_vr/re4_vr_reload2_rifle.json
-- =====================================================================
do
    -- ---- welche Waffen sind Rifles (dieser Gattung) ----
    local RIFLES = { [4401] = true, [4402] = true }   -- wp4401 Stingray, wp4402 CQBR Assault Rifle
    local function is_rifle(wid) return wid ~= nil and RIFLES[wid] == true end
    local function ease(t) return t * t * (3.0 - 2.0 * t) end   -- smoothstep (reload2 hat kein globales ease)
    local _rack_near = false     -- Hand nah am Slide? (Upvalue fuer apply_hand_pose + on_frame)
    local _switch_hand = false   -- Hand am Verstellschalter + Grip? (Upvalue fuer apply_hand_pose + on_frame)

    -- ---- Per-Waffe Joints (CODE-Konstanten, NIE aus JSON; vgl. feedback-re4-joints-code-only) ----
    local RJOINTS = {
        [4401] = { mag = "_04", slide = "_02", switch = "_05" },   -- Stingray (bestaetigt; Verstellschalter = _05)
        [4402] = { mag = "_04", slide = "_02", switch = "_06" },   -- CQBR (: Mag=_04, Slide=_02, Klappschalter=_06)
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
    local RSLIDE = { [4401] = {}, [4402] = { empty_x = 0.020 } }   -- per-wid Overrides (JSON), Default fuellt Luecken
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
    local RDOCK = { [4401] = { joint = "_03", z = 0.090 } }
    local function rdock(wid)
        local d = RDOCK[wid]; if not d then d = {}; RDOCK[wid] = d end
        if d.joint == nil then d.joint = RDOCK_DEF.joint end
        d.x = d.x or 0; d.y = d.y or 0; d.z = d.z or RDOCK_DEF.z
        return d
    end

    -- ---- Mag-in-Hand Offset (Mag-Joint folgt der linken Hand) + Daumen-Spreizung ----
    local RMAGHAND = { [4401] = {} }
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
    local RSWITCH = { [4401] = {} }
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
    local RMAG_POSE    = { [4401] = "StingrayMag",    [4402] = "StingrayMag" }    -- 1) linke Hand haelt Mag (CQBR seedet Stingray-Pose, spaeter tunen)
    local RRACK_POSE   = { [4401] = "StingraySlide",  [4402] = "CqbrSlide" }       -- 2) linke Hand zieht am Slide (CQBR = eigene RiotSLide-Kopie)
    local RSWITCH_POSE = { [4401] = "StingraySwitch", [4402] = "StingraySwitch" } -- 3) Hand am Klappschalter (CQBR seedet Stingray-Switch-Pose)

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
    local RENGINE_CLOSES = { [4401] = true }   -- CQBR (4402) NICHT: voller manueller Rack (wir forcen Z zu + X zurueck)

    -- ---- Sperrt Schalter-Stufe 1 das Feuern? (Stingray ja = bewusster Dry-Fire-Stand; CQBR NEIN,
    -- dort ist Stufe 1 = semi/2-Schuss und muss feuern -> Fire-Mode-Logik kommt separat). ----
    local RSWITCH_BLOCKS_FIRE = { [4401] = true }

    -- ---- Schalter-Stufe 1 = Burst? Wert = Schuss pro Trigger-Zug. binding.lua blockt RT nach N Schuss
    -- (liest __vr_burst_active/__vr_burst_count; Schuss-Zaehler kommt aus dem Crosshair-Hook). ----
    local RSWITCH_BURST = { [4402] = 2 }   -- CQBR: Stufe 1 = 2-Schuss-Burst

    -- ---- Sounds (per-wid, von LE5/Punisher geseedet -> ggf. per #re4_sound_player.lua nachziehen) ----
    local RSND = {
        [4401] = { dry_fire = 812850326, mag_eject = 1466005368, mag_insert = 943565871,   -- mag_eject/insert/slide_back bestaetigt
                   mag_floor = 3042341191, slide_back = 2254736731, slide_forward = 2254736731, mag_holster = 1839787494,
                   switch = 3805002294 },   -- Verstellschalter-Umleg-Sound (bestaetigt)
        [4402] = { dry_fire = 812850326, mag_eject = 1466005368, mag_insert = 943565871,   -- CQBR: slide_back/forward (611689939)
                   mag_floor = 3042341191, slide_back = 611689939, slide_forward = 611689939, mag_holster = 1839787494,
                   switch = 3805002294 },
    }

    -- ---- skalare Konfiguration ----
    local RCFG = { rifle_enabled = true, reload_ammo = true, sound_enabled = true, insert_distance = 0.15 }
    local RCFG_PATH = "re4_vr/re4_vr_reload2_rifle.json"

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
            mag_retained = loaded
            -- [SICHTBAR MACHEN 2026-08-12] Der Merker ist ein `local` dieser Datei. Laedt die Waffe
            -- ueber den (R)/(C)-Weg in re4_vr_reload.lua (Stingray tut das -- Log 22:53:43: START mit
            -- item=0, danach "geladen 17"), kennt der ihn nicht und die Patronen im Magazin gehen
            -- verloren. Deshalb dieselbe Zahl zusaetzlich als Global spiegeln -- KEIN zweiter Merker,
            -- nur sichtbar gemacht. Wer sie verbraucht, loescht sie (siehe unten).
            _G.__re4_mag_carry     = mag_retained
            _G.__re4_mag_carry_wid = rwep and rwep.wid or nil
            local wi = rf_get_wi(); if wi then _G.__re4_carry_capture(wi, "re4_vr_reload2.lua:1987", nil); pcall(function() wi:write_dword(0x44, 0) end) end   -- UI auf 0
            -- [ACCESSOR-FOLGE 2026-08-12] Diese 0 ist UNSER Werk und wirkt seit dem Accessor-Umbau
            -- wirklich (vorher verpuffte sie auf einer Kopie). `rack.empty` (= isGunAmmoEmpty) darf
            -- sie beim Einsetzen nicht als leere Kammer werten -- sonst rackt jede Magazinwaffe nach
            -- JEDEM Reload. Der echte Leer-Fall steht in `rack.empty_when_dropped` (oben gelatcht).
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
        _G.__re4_mag_carry, _G.__re4_mag_carry_wid = nil, nil   -- verbraucht: Spiegel mit loeschen
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
            -- [LEERE KAMMER 2026-07-23] Wie in reload.lua: nach einem Waffenwechsel ist
            -- `empty_when_dropped` geloescht, die Kammer aber trotzdem leer. `rack.empty` (jeden Frame
            -- frisch aus isGunAmmoEmpty) sagt es unabhaengig davon. NUR mit vorhandenem Slide-Joint,
            -- sonst gaebe es keinen Rack und die Waffe waere feuergesperrt.
            -- [ACCESSOR-FOLGE 2026-08-12] `rack.empty` zaehlt nur noch, wenn die 0 NICHT von unserem
            -- eigenen Mag-Drop-Leeren stammt. Der Waffenwechsel-Fall (oben im Kommentar) bleibt damit
            -- erhalten, der Dauer-Rack nach jedem Reload verschwindet.
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
        _G.__re4_mag_carry, _G.__re4_mag_carry_wid = nil, nil   -- Reset: Spiegel darf nicht ueberleben
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
                _G.__re4_carry_capture(wi, "re4_vr_reload2.lua:2451", nil)   -- [MAG-REST] merken, bevor genullt wird
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
        _G.__re4_bf_who = "re4_vr_reload2.lua:2133"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
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
    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion _G.__re4_reload2_rifle_ui (101 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end
-- =====================================================================
-- ENDE RIFLE-GATTUNG
-- =====================================================================

-- =====================================================================
-- BOLT-ACTION-GATTUNG (wp4400 SR M1903) — eigener do...end-Block
-- =====================================================================
-- Eigenes Local-Budget (wie Revolver/Rifle eigene Bloecke haben). Voellig
-- abgekapselt von der Stingray (4401): kein gemeinsamer State, eigenes JSON.
-- File-Level-Helfer (safe/sc/sf/get_equip_wid/get_pe/find_weapon/body_tf/
-- quat_from_euler/pe_td) werden geteilt; ammo/gun/VR/pose-Helfer hier lokal.
--
-- MECHANIK:
-- joint_01 = Bolt-Slide, joint_10 = Patrone.
-- Oeffnen: Hand an _01 + Grip -> roll links ~70deg, DANN Z nach hinten.
-- Laden (Bolt offen): ins Mag-Holster greifen -> Patrone (_10) in Hand
-- (Pose Shotgunshell) -> an die Kammer fuehren -> ammocount +1 (einzeln,
-- keine Ratio), Reserve -1. Beliebig oft bis Cap/Reserve leer.
-- Schliessen: Z ganz nach vorne, DANN roll rechts ~70deg -> chambern.
-- Feuern bleibt NATIV (Engine cycelt den Bolt kosmetisch + zieht Ammo beim
-- Schuss). Manueller Bolt = NUR Nachladen. Feuer gesperrt solange offen.
-- Default-Pose der linken Hand (nur wp4400 equippt) = RiotSLide; beim Bolt-
-- Ziehen TMPSUpport, mit Patrone Shotgunshell.
-- =====================================================================
do
    local BOLTS = { [4400] = true }
    local function is_bolt(wid) return wid ~= nil and BOLTS[wid] == true end
    local function ease(t) return t * t * (3.0 - 2.0 * t) end
    local function clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 else return v end end

    -- ---- Joints (CODE-Konstanten) ----
    local BJOINTS = { [4400] = { bolt = "_01", cart = "_10" } }

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
    local BCFG_WID = { [4400] = {} }
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
    local BSND = { [4400] = { bolt_open = 3388506884, bolt_close = 3505191890,
                              cart_grab = 1839787494, insert = 403849506, cart_floor = 1302378315,
                              dry_fire = 812850326 } }
    local snd_td2 = sdk.typeof("soundlib.SoundContainer")

    -- ---- skalare Config + Persistenz ----
    local BCFG = { bolt_enabled = true, reload_ammo = true, sound_enabled = true, insert_distance = 0.15 }
    local BCFG_PATH = "re4_vr/re4_vr_reload2_bolt.json"
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
    -- [NULLLAGE 2026-08-12] Einmal gemerkte Ruhelagen des Bolts pro Waffe -- bewusst NICHT bei jedem
    -- Neu-Greifen neu gemessen (sonst faengt ein Stagger die zurueckgezogene Stellung als Ruhe ein).
    local BOLT_REST_LP, BOLT_REST_ROT = {}, {}

    -- [MESH FORCE 2026-08-12] Die ENGINE blendet die Waffe waehrend des Repetierens aus (ihre eigene
    -- Bolt-Animation laeuft, wir unterdruecken sie -> sie schaltet das Mesh ab). Also zwingen wir es an,
    -- solange der Zyklus laeuft: Komponente an, DrawDefault (= DrawSelf) an, und alle Parts an, falls
    -- die Engine einzelne abgeschaltet hat. Global, damit Adas Hunting Rifle denselben Helfer nutzt.
    -- Beim ersten Eingriff pro Zyklus eine Logzeile -- so ist belegt, WAS aus war.
    -- [MESH_FORCE CACHE 2026-08-15] Die WIRKUNG bleibt Zeichen fuer Zeichen dieselbe -- ohne sie ist
    -- das Zielsystem/Scoping der Bolt-Waffen tot (live belegt). Geaendert ist nur, WIE OFT gesucht wird:
    -- frueher lief der Baumlauf JEDEN Frame neu (Tiefe 3 x bis 24 Geschwister, im Extremfall ~13.800
    -- Knoten mit je ~5 pcall-gekapselten Engine-Aufrufen, dazu ein getComponent pro Knoten) -- genau das
    -- war der Freeze beim Bolt-Griff. Jetzt wird der Baum EINMAL pro Waffe eingesammelt (GameObject +
    -- Mesh-Komponente gemerkt) und danach nur noch geschrieben. Das ist dieselbe Schreibmenge, aber ohne
    -- Suche: kein get_Child/get_Next, kein getComponent mehr pro Frame.
    -- Der Cache wird verworfen, sobald eine andere Waffe kommt oder ein Eintrag ungueltig wird -- gleiche
    -- Regel wie beim Komponenten-Cache anderswo, der einen Save-Load auch nicht ueberlebt.
    _G.__re4_fwv_cache = _G.__re4_fwv_cache or { tf = nil, list = nil, t = 0 }
    _G.__re4_force_weapon_visible = _G.__re4_force_weapon_visible or function(tf, tag)
        -- [AUS 2026-08-15 -- LIVE ABGENOMMEN] KOMPLETT STILLGELEGT. Der Helfer nahm beim Bolt-Griff die
        -- VR-Sitzung mit: das Spiel lief danach flach weiter (Screenshot bolt.png), jedes Mal Neustart.
        -- Einzige Stelle hier, die an der Engine vorbei in den Speicher schreibt: write_byte(0x13,1).
        -- MIT HELFER AUS live geprueft: Bolt-Ziehen laeuft, SCOPING LAEUFT AUCH. Die Behauptung, das
        -- Zielsystem haenge an diesen Schreibungen, war FALSCH -- sie stammte aus einer Sitzung, in der
        -- VR bereits abgestuerzt war, nicht aus dem Code. Bolt und Scope sind getrennte Systeme; dieser
        -- Helfer fasst ausschliesslich Sichtbarkeits-Flags an, nie Zoom/Kamera/Fadenkreuz.
        -- Offen bleibt nur sein urspruenglicher Zweck: ob die Waffe waehrend des Repetierens verschwindet.
        -- Falls ja, gezielt EIN Objekt ueber die Engine-Setter halten -- nie wieder Baumlauf + write_byte.
        -- WIEDER ANSCHALTEN: genau diese eine Zeile loeschen.
        do return end
        if not tf then return end
        if _G.__re4_meshtd == nil then
            _G.__re4_meshtd = false
            pcall(function() local t = sdk.typeof("via.render.Mesh"); if t then _G.__re4_meshtd = t end end)
        end
        local C = _G.__re4_fwv_cache

        -- ---- Cache pruefen: andere Waffe, leer, oder IRGENDEIN Eintrag tot -> neu sammeln ----
        -- [CRASH-FIX 2026-08-15] Vorher wurde nur Eintrag 1 geprueft. Der alte Code lief jeden Frame
        -- neu ueber den Baum und hatte damit IMMER frische Zeiger; ein Cache hat das nicht. Ueberlebt
        -- die Waffenwurzel einen Wechsel/Respawn, waehrend Kinder ersetzt werden, standen tote Zeiger
        -- in der Liste -- und `write_byte(0x13,1)` auf einen toten Zeiger crasht, da hilft auch pcall
        -- nicht (bekannte Falle: Komponenten-Cache ueberlebt keinen Save-Load).
        -- Ein get_Valid pro Eintrag ist billig -- der teure Teil war die SUCHE (get_Child/getComponent),
        -- und die bleibt weg.
        local ok_cache = (C.list ~= nil) and (C.tf == tf) and (#C.list > 0)
        if ok_cache then
            for i = 1, #C.list do
                local v = nil
                pcall(function() v = C.list[i].go:call("get_Valid") end)
                if v ~= true then ok_cache = false; break end
            end
        end

        if not ok_cache then
            -- EINMALIGER Baumlauf, identische Reichweite wie vorher (Tiefe 3, bis 24 Geschwister),
            -- zusaetzlich hart auf 256 Knoten gedeckelt -- ein entarteter Baum darf nicht wieder
            -- alles blockieren.
            local list, cnt = {}, 0
            local function collect(node, tiefe)
                if not node or tiefe > 3 or cnt >= 256 then return end
                pcall(function()
                    local go = node:call("get_GameObject")
                    if go then
                        local m = nil
                        if _G.__re4_meshtd then
                            m = go:call("getComponent(System.Type)", _G.__re4_meshtd)
                        end
                        cnt = cnt + 1
                        list[cnt] = { go = go, mesh = m }
                    end
                end)
                local kind = nil
                pcall(function() kind = node:call("get_Child") end)
                local n = 0
                while kind and n < 24 and cnt < 256 do
                    collect(kind, tiefe + 1)
                    local nx = nil; pcall(function() nx = kind:call("get_Next") end)
                    kind = nx; n = n + 1
                end
            end
            collect(tf, 0)
            if cnt == 0 then return end
            C.tf, C.list, C.t = tf, list, os.clock()
        end

        -- ---- Schreiben: exakt wie vorher, nur ohne Suche ----
        -- [SCOPE-WEG 2026-08-12] Geschaltet wird am GAMEOBJECT, nicht an der Mesh-Komponente -- exakt
        -- wie im Scope-Script, wo das Spiel uns sonst dieselben Meshes klaut: set_UpdateSelf/set_DrawSelf
        -- plus die rohe Schreibung auf 0x13. Zusaetzlich Part 0 am Mesh, das versteckt das Spiel separat.
        for i = 1, #C.list do
            local e = C.list[i]
            -- Zusaetzliche Sicherung unmittelbar vor der ROHEN Schreibung: nur schreiben, wenn das
            -- Objekt in DIESEM Moment gueltig ist. Ein toter Zeiger + write_byte = Absturz.
            local v = nil
            pcall(function() v = e.go:call("get_Valid") end)
            if v == true then
                -- [NUR BEI BEDARF 2026-08-15] Frueher wurde JEDEM Knoten JEDEN Frame alles neu
                -- aufgedrueckt -- inklusive einer ROHEN Schreibung auf 0x13. Die Rifle nimmt seit dem
                -- neuen Build beim Bolt-Griff die ganze VR-Sitzung mit (Spiel laeuft flach weiter),
                -- und die rohe Schreibung ist die einzige Stelle hier, die an der Engine vorbei in den
                -- Speicher geht. Deshalb: erst LESEN, und nur schreiben, was wirklich aus ist.
                -- Im eingeschwungenen Zustand (alles sichtbar) schreibt der Helfer damit GAR NICHTS mehr;
                -- er greift nur noch in genau den Frames ein, in denen die Engine etwas abschaltet.
                local draw_off, upd_off = false, false
                pcall(function() draw_off = (e.go:call("get_DrawSelf") == false) end)
                pcall(function() upd_off  = (e.go:call("get_UpdateSelf") == false) end)
                if upd_off  then pcall(function() e.go:call("set_UpdateSelf", true) end) end
                if draw_off then pcall(function() e.go:call("set_DrawSelf",  true) end) end
                -- Die rohe 0x13-Schreibung NUR noch als letztes Mittel: wenn das Setzen ueber die
                -- Engine nachweislich nicht angekommen ist.
                if draw_off then
                    local still_off = false
                    pcall(function() still_off = (e.go:call("get_DrawSelf") == false) end)
                    if still_off then pcall(function() e.go:write_byte(0x13, 1) end) end
                end
                if e.mesh then
                    local part_off = false
                    pcall(function() part_off = (e.mesh:call("getPartsEnable", 0) == false) end)
                    if part_off then pcall(function() e.mesh:call("setPartsEnable", 0, true) end) end
                end
            else
                C.list = nil   -- Liste ist nicht mehr vertrauenswuerdig -> naechster Frame sammelt neu
                return
            end
        end
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
        -- [NULLLAGE 2026-08-12] Die Ruhelage wurde bei JEDEM Neu-Greifen frisch gemessen. Passiert das,
        -- waehrend der Bolt hinten steht (Stagger, Waffen-Respawn, Engine-Anim), wird die ZURUECKGEZOGENE
        -- Position zur neuen "Ruhe" -- und unser Offset kommt danach obendrauf. Genau das war der Befund
        -- "nach dem Stagger wandert der Bolt noch weiter raus", und es ist dieselbe Falle wie bei den
        -- live gemessenen Slide-Nulllagen der Pistolen. Deshalb: pro Waffe EINMAL merken und nie wieder
        -- ueberschreiben. Ein spaeterer Messwert wird nur als Diagnose verglichen, nicht uebernommen.
        bwep.bolt_rest_rot = BOLT_REST_ROT[wid] or sc(bj, "get_LocalRotation")
        BOLT_REST_ROT[wid] = BOLT_REST_ROT[wid] or bwep.bolt_rest_rot
        local lp = sc(bj, "get_LocalPosition")
        if BOLT_REST_LP[wid] then
            local keep = BOLT_REST_LP[wid]
            bwep.bolt_rest_lp = { x = keep.x, y = keep.y, z = keep.z }
        elseif lp then
            BOLT_REST_LP[wid] = { x = lp.x, y = lp.y, z = lp.z }
            bwep.bolt_rest_lp = { x = lp.x, y = lp.y, z = lp.z }
        end
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
        local c = bcfg(bwep.wid or 4400)
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
                -- [STAGGER 2026-08-12] Zweiter Anker: die Waffenhand. Der Zug oben misst gegen einen
                -- WELTpunkt -- ein Stagger schiebt Koerper und Waffe, der Anker bleibt stehen, und die
                -- Differenz landet als zusaetzlicher Zug im Bolt (er wandert weiter nach hinten).
                -- Genau derselbe Fehler wie damals beim Pistolen-Slide.
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
                    -- [STAGGER 2026-08-12] Zweiter Anker: die Waffenhand. Der Zug oben misst gegen einen
                    -- WELTpunkt -- ein Stagger schiebt Koerper und Waffe, der Anker bleibt stehen, und die
                    -- Differenz landet als zusaetzlicher Zug im Bolt (er wandert weiter nach hinten).
                    -- Genau derselbe Fehler wie damals beim Pistolen-Slide.
                    do local _r = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
                        bolt.rgx, bolt.rgy, bolt.rgz = _r and _r.x or nil, _r and _r.y or nil, _r and _r.z or nil end
                    bolt.zf_anchor = bolt.zf; bolt.troll, bolt.tzf = bolt.roll, bolt.zf
                    bolt_haptic(0.35, 0.03)                          -- Einrast-Klick
                end
                return
            end
            local travel = math.max(c.travel or 0.075, 0.01)
            local px, py, pz = hp.x - bolt.gx, hp.y - bolt.gy, hp.z - bolt.gz
            -- [STAGGER 2026-08-12] Bewegung der Waffenhand abziehen -> uebrig bleibt die Bewegung der
            -- Ziehhand GEGEN die Waffe. Rueckbau: _G.__re4_rack_relative = false
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
        local c = bcfg(bwep.wid or 4400)
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
            local c = bcfg(bwep.wid or 4400)
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
        -- [KEYFRAME-PROGRAMM 2026-07-24] reload_adv-Preview ("Joint/Shell einblenden") deckt nur
        -- LateUpdate/BeginRendering ab -> die Engine setzt den leeren Cart-Joint auf den anderen Paessen
        -- zurueck (unsichtbar). Deshalb HIER, im vollen Bolt-Pass-Stack (LockScene/LateUpdate/JointExpr/
        -- BeginRendering-pre), den nativen Cart-Joint an die waffenrelative Keyframe-Tuning-Lage + Scale 1
        -- zwingen -- exakt wie cart.tune sichtbar ist, nur an der Bahn statt an der Hand.
        if rawget(_G, "__re4_shell_kf_preview") == bwep.wid and bwep.cart_joint and bwep.tf then
            local ms = rawget(_G, "__re4_reload_mag_slide"); local s = ms and ms.shell_live
            local gp = sc(bwep.tf, "get_Position"); local gr = sc(bwep.tf, "get_Rotation")
            if s and gp and gr then
                local off = safe(function() return gr * Vector3f.new(s.x or 0, s.y or 0, s.z or 0) end)
                local wx, wy, wz = gp.x, gp.y, gp.z
                if off then wx, wy, wz = gp.x + off.x, gp.y + off.y, gp.z + off.z end
                local rot = safe(function() return (gr * quat_from_euler(s.rx or 0, s.ry or 0, s.rz or 0)):normalized() end)
                pcall(function() bwep.cart_joint:call("set_Position", Vector3f.new(wx, wy, wz)) end)
                if rot then pcall(function() bwep.cart_joint:call("set_Rotation", rot) end) end
                pcall(function() bwep.cart_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
                return
            end
        end
        local cj = (cart.active or cart.tune) and bwep.cart_joint or nil
        if not cj then return end
        local c = bcfg(bwep.wid or 4400)
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
        local c = bcfg(bwep.wid or 4400)
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
        local function BDUMP(s) dbg.result = s end   -- [LOG ENTFERNT 2026-07-24] Debug-Datei-Dump raus (re4_bolt_ammo_dbg.json); No-Op, Aufrufe unveraendert
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
        -- [KEYFRAME-PROGRAMM 2026-07-24] Hat wp4400 eine Keyframe-Bahn (reload_adv)? Dann den nativen
        -- Cart-Joint entlang der geordneten Bahn fahren (waffenrelativ, apply_shell_keys) -- der lineare Slide
        -- unten gilt dann NICHT. Eigene Bahn-Dauer (shell_dur). Ohne gespeicherte Keyframes: altes Verhalten.
        local ms = rawget(_G, "__re4_reload_mag_slide")
        local kf = ms and type(ms.has_shell_keys) == "function" and ms.has_shell_keys(bwep.wid)
                   and type(ms.apply_shell_keys) == "function" and bwep.tf ~= nil
        local dur = (kf and tonumber(ms.shell_dur)) or cart.dur
        local t = (os.clock() - cart.t0) / math.max(dur, 0.01); if t > 1.0 then t = 1.0 end
        if not cart.snd and t >= 0.6 then cart.snd = true; bsnd("insert") end
        if kf then
            ms.apply_shell_keys(bwep.tf, bwep.cart_joint, bwep.wid or 0, t)
            pcall(function() bwep.cart_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
            if t >= 1.0 then cart.insert = false; bolt_add_one() end
            return
        end
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
            name = "Shotgunshell"; thumb = bcfg(bwep.wid or 4400)
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
    -- [CYCLE-SUPPRESS LEON wp4400 2026-07-20] native Bolt-Cycle-Anim nach dem Schuss
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
        local CYCLE_NODE = "wp4400_general_0513_Aim_Fire_after"

        local function _sup_gun_go()
            local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return end
            local ctx = safe(function() return cm:call("getPlayerContextRef") end); if not ctx then return end
            local hu  = safe(function() return ctx:call("get_HeadUpdater") end); if not hu then return end
            local gun = safe(function() return hu:call("get_EquipWeapon") end); if not gun then return end
            return safe(function() return gun:call("get_GameObject") end)
        end

        re.on_frame(function()
            _G.__re4_bolt_in_cycle = false
            if not _sup_motion_t then return end
            if not (bwep.wid ~= nil) then return end
            local go = _sup_gun_go(); if not go then return end
            local mc = safe(function() return go:call("getComponent(System.Type)", _sup_motion_t) end); if not mc then return end
            local layer = safe(function() return mc:call("getLayer", 0) end); if not layer then return end
            local node = safe(function() return layer:call("get_HighestWeightMotionNode") end); if not node then return end
            local nm = safe(function() return node:call("get_MotionName") end)
            if nm and tostring(nm) == CYCLE_NODE then
                _G.__re4_bolt_in_cycle = true
                local ef = safe(function() return node:call("get_EndFrame") end)
                if ef and ef > 0 then pcall(function() node:call("set_Frame", ef) end) end
                pcall(function() layer:call("set_Speed", 100.0) end)
            end
        end)
    end


    -- [CYCLE-SUPPRESS (B)] Sound/Casing-Tracks der Cycle-Anim unterdruecken. Der Hook wird GENAU
    -- EINMAL installiert (hier bei Leon) und prueft BEIDE Gates -- Leons wp4400 und Adas wp6114 aus
    -- re4_vr_reload5_dlc.lua. Nur waehrend der jeweiligen Cycle-Anim; Schuss und Aim bleiben unberuehrt.
    if not rawget(_G, "__re4_bolt_tracks_hooked") then
        _G.__re4_bolt_tracks_hooked = true
        local td = sdk.find_type_definition("chainsaw.Gun")
        local ms = td and td:get_methods()
        if ms then
            for _, m in ipairs(ms) do
                local mn = safe(function() return m:get_name() end)
                if mn == "callbackTracks" then
                    pcall(function()
                        sdk.hook(m,
                            function(args)
                                if rawget(_G, "__re4_bolt_in_cycle") == true
                                   or rawget(_G, "__re4_bolt_in_cycle_dlc") == true then
                                    return sdk.PreHookResult.SKIP_ORIGINAL
                                end
                            end,
                            function(retval) return retval end)
                    end)
                end
            end
        end
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
        -- [KEYFRAME-PROGRAMM 2026-07-24] Cart-Joint (_10) + Waffen-Transform + wid fuer die reload_adv-
        -- Keyframe-UI/Preview exponieren (wie reload4 Z.3548). Damit zeigt der Keyframe-Tree wp4400 an und
        -- "Joint/Shell einblenden" haelt den nativen Cart-Joint an der waffenrelativen Tuning-Lage (reload_adv
        -- treibt ihn dann selbst; hier NUR publizieren). Laeuft nur bei equippter Bolt-Waffe -> kein Clobber sonst.
        _G.__re4_reload_shell_joint = bwep.cart_joint
        _G.__re4_reload_weapon_tf   = bwep.tf
        _G.__re4_reload_ui_wid      = bwep.wid
        -- [KEYFRAME-PROGRAMM 2026-07-24] Der reload_adv-Preview-Toggle soll GENAU das tun wie der
        -- Holster-Grab: das Mesh in die Hand holen (cart.tune = wie cart.active, nur ohne Ammo-Logik).
        -- Das ist DER Sichtbar-Zustand -- Scale/Position allein reichen nicht. update_cart_in_hand setzt
        -- den Joint dann an die waffenrelative Keyframe-Tuning-Lage statt an die Hand. Nur WIR verwalten
        -- dieses erzwungene tune (cart._kf_forced) -> die manuelle Vorschau-Checkbox bleibt unberuehrt.
        if rawget(_G, "__re4_shell_kf_preview") == bwep.wid then
            cart.tune = true; cart._kf_forced = true
        elseif cart._kf_forced then
            cart.tune = false; cart._kf_forced = false
        end
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
            _G.__re4_force_weapon_visible(bwep.tf, "SR M1903")
        end
        _G.__vr_block_fire_when_empty = (bolt.open or bammo_empty() or bolt.needs_cycle) and true or false
        _G.__re4_bf_who = "re4_vr_reload2.lua:2998"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
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
        -- [KEYFRAME-PROGRAMM 2026-07-24] Die ui_wid/shell_joint/weapon_tf AUCH auf den App-Entry-
        -- Paessen publizieren (nicht nur im on_frame). Sonst ueberschreibt reload.lua sie hier mit nil
        -- (kennt 4400 nicht) BEVOR reload_advs shell_preview_apply sie liest -> __re4_shell_kf_preview
        -- blieb nil, der Preview zuendete nie. reload2 laedt nach reload.lua -> gewinnt auf diesem Pass.
        _G.__re4_reload_shell_joint = bwep.cart_joint
        _G.__re4_reload_weapon_tf   = bwep.tf
        _G.__re4_reload_ui_wid      = bwep.wid
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
    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion _G.__re4_reload2_bolt_ui (79 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end
-- =====================================================================
-- ENDE BOLT-ACTION-GATTUNG
-- =====================================================================

-- =====================================================================
-- ARMBRUST-GATTUNG (wp4600) — eigener do...end-Block
-- Pfeil = Mesh-PART 5 (KEIN Joint!) + Skinning-Joint (Default "_05", im UI aenderbar).
-- Right-B macht NICHTS. Reload/Holster IMMER moeglich solange Reserve > 0.
-- Holster-Grab -> Part 5 wird sichtbar geforced + der Skinning-Joint folgt der linken
-- Hand (Pose XbowBolt = LE5SWITCH-Kopie, gestures-unabhaengig). Naehe zur Kammer -> +1.
-- Feuern bleibt NATIV. Bolt-Joint zur Hand = wie Bolt-Action update_cart_in_hand.
-- =====================================================================
do
    local XBOWS = { [4600] = true }
    local function is_xbow(wid) return wid ~= nil and XBOWS[wid] == true end

    -- Mesh-Part-Indizes des HAND-Pfeils (KEIN Joint! Der Part IST die Patrone.)
    -- Part 5 = Pfeil AUF der Waffe (geladen). Parts 20..24 = Pfeil-Parts die in der Hand
    -- erscheinen sollen. Live in der UI als Komma-Liste aenderbar (hand_parts).
    local XPART = { [4600] = { 20, 21, 22, 23, 24 } }
    -- "20,21" -> {20,21}; toleriert Leerzeichen/Muell
    local function parse_parts(str)
        local t = {}
        if type(str) == "string" then
            for n in str:gmatch("%d+") do t[#t + 1] = tonumber(n) end
        end
        return t
    end

    -- ---- Per-Waffe Tuning (JSON-persistiert) ----
    local XCFG_DEF = {
        t_rx = 0.0, t_ry = 0.0, t_rz = 0.0,   -- Daumen-Spreizung (additiv, XbowBolt/LE5SWITCH)
        cd_joint = "_03", cd_x = 0.0, cd_y = 0.0, cd_z = 0.138,   -- Kammer-Dock (Einlege-Naehe)
        dx = 0.0, dy = 0.0, dz = 0.0,         -- Hand-Dummy-Bolzen Positions-Offset (lokal zur L_Hand)
        drx = 0.0, dry = 0.0, drz = 0.0,      -- Hand-Dummy-Bolzen Rotations-Offset (Euler, Grad)
        dscale = 1.0,                          -- Hand-Dummy-Bolzen Skalierung (uniform)
    }
    local XCFG_WID = { [4600] = {} }
    local function xcfg(wid)
        local c = XCFG_WID[wid]; if not c then c = {}; XCFG_WID[wid] = c end
        for k, v in pairs(XCFG_DEF) do if c[k] == nil then c[k] = v end end
        return c
    end

    -- ---- Hand-Pose: XbowBolt = unabhaengige Kopie der LE5SWITCH-Pose (aus StingraySwitch gebacken) ----
    local XPOSES = {
        ["XbowBolt"] = { hand="left", bones = { ["L_IndexF1"]={0.924900,0.000000,-0.015000,-0.380100}, ["L_IndexF2"]={0.819200,0,0,-0.573600}, ["L_IndexF3"]={0.866000,0,0,-0.500000}, ["L_MiddleF1"]={0.896271,-0.104853,0.085188,-0.422431}, ["L_MiddleF2"]={0.705958,0,0,-0.708254}, ["L_MiddleF3"]={0.890564,0,0,-0.454858}, ["L_Palm"]={1.000000,0.000000,0.000000,0.000000}, ["L_PinkyF1"]={0.922581,-0.182263,0.075602,-0.331525}, ["L_PinkyF2"]={0.722647,0,0,-0.691217}, ["L_PinkyF3"]={0.896982,0,0,-0.442068}, ["L_RingF1"]={0.879959,-0.133028,0.090023,-0.447069}, ["L_RingF2"]={0.710167,0,0,-0.704033}, ["L_RingF3"]={0.892185,0,0,-0.451670}, ["L_Thumb1"]={0.918569,0.252866,-0.108586,-0.283724}, ["L_Thumb2"]={0.999635,0.000000,-0.027026,0.000000}, ["L_Thumb3"]={0.923391,-0.000011,0.383861,-0.000004} } },
    }
    local _xpmap, _xpmap_tf = {}, nil
    local function xpose_map()
        local tf = body_tf(); if not tf then return {} end
        if tf == _xpmap_tf and next(_xpmap) ~= nil then return _xpmap end
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
        _xpmap_tf, _xpmap = tf, map
        return map
    end
    local function xpose_apply(name, blend)
        local pose = name and XPOSES[name]; if not (pose and pose.bones) then return false end
        local map = xpose_map(); if next(map) == nil then return false end
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

    -- ---- skalare Config + Persistenz ----
    local XCFG = { enabled = true, reload_ammo = true, insert_distance = 0.15, hand_parts = "5" }
    local XCFG_PATH = "re4_vr/re4_vr_reload2_xbow.json"
    local XFIELDS = { "t_rx","t_ry","t_rz","cd_x","cd_y","cd_z","dx","dy","dz","drx","dry","drz","dscale" }
    local function xload_cfg()
        local data = safe(function() return json.load_file(XCFG_PATH) end)
        if type(data) ~= "table" then return end
        local c = data.cfg or {}
        if type(c.enabled)        == "boolean" then XCFG.enabled         = c.enabled         end
        if type(c.reload_ammo)    == "boolean" then XCFG.reload_ammo     = c.reload_ammo     end
        if type(c.insert_distance)== "number"  then XCFG.insert_distance = c.insert_distance end
        if type(c.hand_parts)     == "string"  then XCFG.hand_parts      = c.hand_parts      end
        if type(data.tune) == "table" then
            for k, v in pairs(data.tune) do local wid = tonumber(k)
                if wid and type(v) == "table" then local cc = xcfg(wid)
                    for _, f in ipairs(XFIELDS) do if type(v[f]) == "number" then cc[f] = v[f] end end
                    if type(v.cd_joint)   == "string" then cc.cd_joint   = v.cd_joint   end end end
        end
    end
    local function xsave_cfg()
        local tune = {}
        for wid in pairs(XBOWS) do
            local cc = xcfg(wid); local o = {}
            for _, f in ipairs(XFIELDS) do o[f] = cc[f] end
            o.cd_joint = cc.cd_joint
            tune[tostring(wid)] = o
        end
        pcall(function() json.dump_file(XCFG_PATH, { cfg = XCFG, tune = tune }) end)
    end
    xload_cfg()

    -- ---- Gun / Mesh / Transform ----
    local _xcm
    local function xget_gun()
        _xcm = _xcm or sdk.get_managed_singleton("chainsaw.CharacterManager"); if not _xcm then return nil end
        local ctx = safe(function() return _xcm:call("getPlayerContextRef") end); if not ctx then return nil end
        local hu = safe(function() return ctx:call("get_HeadUpdater") end); if not hu then return nil end
        -- EIGENER wid-Check (wie der Part-Finder): NUR die Armbrust wp4600 anfassen, NIE andere Waffen.
        local wid = safe(function() return hu:call("get_EquipWeaponID") end)
        local widn = (type(wid) == "userdata") and safe(function() return wid:get_field("value__") end) or wid
        if widn ~= 4600 then return nil end
        return safe(function() return hu:call("get_EquipWeapon") end)
    end
    local function xget_gun_mesh() local g = xget_gun(); return g and safe(function() return g:call("get_Mesh") end) end
    local function xget_gun_tf()
        local g = xget_gun(); if not g then return nil end
        local go = safe(function() return g:call("get_GameObject") end); if not go then return nil end
        return safe(function() return go:call("get_Transform") end)
    end

    -- [SOUND] EIGENE Sound-Funktion fuer die Armbrust (play_weapon_sound nutzt wep.tf = REVOLVER -> nil
    -- fuer die Armbrust). Triggert am SoundContainer des Armbrust-GameObjects.
    local function xplay_sound(id)
        if not id or id <= 0 then return end
        local g = xget_gun(); if not g then return end
        local go = safe(function() return g:call("get_GameObject") end); if not go or not snd_sc_td then return end
        local scn = safe(function() return go:call("getComponent(System.Type)", snd_sc_td) end)
        if scn then pcall(function() scn:call("trigger(System.UInt32)", id) end) end
    end

    -- ---- Ammo (gegen die EQUIPPTE Waffe) ----
    local function xget_wi()
        local pe = get_pe()
        local ewi = pe and safe(function() return pe:call("getEquipWeaponItem") end)
        if ewi and safe(function() return ewi:call("get_CurrentAmmoCount") end) ~= nil then return ewi end
        return nil
    end
    local function xloaded()  local wi = xget_wi(); return wi and tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)) end
    local function xcap()     local wi = xget_wi(); return wi and tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0 end
    local function xreserve()
        local wi = xget_wi(); if not wi then return 0 end
        local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end); if not ammo_id then return 0 end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController"); if not inv then return 0 end
        return tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0
    end

    -- ---- Part 5 sichtbar forcen (gewinnt gegen den WeaponMeshPartsDisp-Track) ----
    local function xhand_part_list()
        -- UI-Liste (hand_parts) hat Vorrang; sonst Code-Default XPART
        local list = parse_parts(XCFG.hand_parts)
        if #list == 0 then list = XPART[get_equip_wid()] or { 5 } end
        return list
    end
    -- Mesh-Part-Trick verworfen (ISOLATE blendete die ganze Armbrust aus). Hand-Bolzen = eigener
    -- DUMMY-Shell (rendert mit Skelett, kein Schuss). xpart_show bleibt No-Op (Aufrufer unveraendert).
    local function xpart_show(_on) end

    -- ==== HAND-DUMMY-BOLZEN (chainsaw.ShellDummyBase via ArrowShellGenerator) ====
    -- requestGenerateDummy am Generator der Armbrust -> visueller Bolzen (eigenes GO mit Skelett).
    -- Abfangen per persistentem Hook auf ShellDummyBase.requestStart (Globals -> ueberleben Reset).
    -- Siehe Notiz. NUR Armbrust (Generator nur an wp4600 gefunden).
    local XIDENT = Quaternion.new(1, 0, 0, 0)
    if not rawget(_G, "__re4_xbow_dummy_hook") then
        pcall(function()
            local td = sdk.find_type_definition("chainsaw.ShellDummyBase")
            local m = td and (td:get_method("requestStart") or td:get_method("start"))
            if m then
                sdk.hook(m,
                    function(args)
                        if rawget(_G, "__re4_xbow_dummy_await") == true then
                            local this = sdk.to_managed_object(args[2])
                            if this then _G.__re4_xbow_dummy_obj = this; _G.__re4_xbow_dummy_await = false end
                        end
                    end,
                    function(ret) return ret end)
                _G.__re4_xbow_dummy_hook = true
            end
        end)
    end
    local function xfind_child(go, name)
        local tf = go and sc(go, "get_Transform")
        local ch = tf and sc(tf, "get_Child")
        while ch do
            local cgo = sc(ch, "get_GameObject")
            if cgo and tostring(sc(cgo, "get_Name")) == name then return cgo end
            ch = sc(ch, "get_Next")
        end
    end
    local function xget_generator()
        local g = xget_gun(); if not g then return nil end
        local go = sc(g, "get_GameObject"); if not go then return nil end
        local agg = xfind_child(go, "ArrowShellGenerator"); if not agg then return nil end
        return safe(function() return agg:call("getComponent(System.Type)", sdk.typeof("chainsaw.ArrowShellGenerator")) end)
    end
    local function xrequest_dummy()
        local gen = xget_generator(); if not gen then return end
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position")
        local pos = hp and Vector3f.new(hp.x, hp.y, hp.z) or Vector3f.new(0, 0, 0)
        _G.__re4_xbow_dummy_await = true
        pcall(function() gen:call("requestGenerateDummy", pos, XIDENT, nil) end)
    end
    local _xdummy_req = 0
    -- [DROP] freier Fall + Rotation beim Loslassen ohne Einlegen (wie Mag-Drop, kosmetisch ~1.2s).
    local xdrop = { active = false, sx = 0, sy = 0, sz = 0, t0 = 0 }
    local XDROP_DUR, XGRAV = 1.8, 4.5
    -- ============================================================================================
    -- [NO_LAG XBOW 2026-08-18] Der Hand-Bolzen (Dummy-GO vom ArrowShellGenerator, KEIN Mesh-Klon)
    -- hing der Hand beim Laufen hinterher -- dasselbe Symptom wie damals die Mag-/Trommel-Klone.
    -- Der Fix dort war NICHT mehr Pässe, sondern das NATIVE PARENTEN ans L_Hand-Joint
    -- (re4_vr_reload2.lua:1258 Revolver-Klon, re4_vr_reload.lua:5679 Shell, holster.lua:905):
    -- die Engine propagiert die Transform des Kindes VOR dem Skinning -> kein Render-Versatz.
    -- Danach wird nur noch die LOKALE Pose gesetzt; die bisherigen Offsets (dx/dy/dz, drx/dry/drz)
    -- waren ohnehin schon hand-relativ gerechnet (hr * off) und gelten damit 1:1 als lokale Werte --
    -- deshalb aendert sich an der Funktion, den Slidern und der JSON NICHTS.
    -- ENTKOPPELT wird ueberall dort, wo die Pose NICHT hand-relativ ist:
    --   * Drop (freier Fall in Weltkoordinaten),
    --   * Keyframe-Bahn beim Einlegen (xkf_place_dummy rechnet WAFFEN-relativ),
    --   * beim Beenden/Verlieren des Dummys (sonst gilt der naechste faelschlich als geparentet).
    -- Zustand in einem GLOBAL (wie __re4_xbow_dummy_obj/_await): kostet keinen Local-Slot und die
    -- arrow-Tabelle ist hier oben noch gar nicht deklariert (Z.4014).
    -- RUECKBAU: _G.__re4_xbow_dummy_nolag = false -> exakt das alte Welt-Setzen.
    -- ============================================================================================
    local function xdummy_set_parent(dummy, on)
        local tf = dummy and safe(function() return dummy:call("get_Transform") end); if not tf then return false end
        if on then
            if rawget(_G, "__re4_xbow_dummy_parented") == true then return true end
            if rawget(_G, "__re4_xbow_dummy_nolag") == false then return false end
            local bt = body_tf(); if not bt then return false end
            pcall(function() tf:call("set_Parent", bt) end)
            if pcall(function() tf:call("set_ParentJoint", "L_Hand") end) then
                _G.__re4_xbow_dummy_parented = true
                return true
            end
            pcall(function() tf:call("set_Parent", nil) end)   -- halb geparentet nicht stehen lassen
            return false
        end
        if rawget(_G, "__re4_xbow_dummy_parented") == true then
            pcall(function() tf:call("set_Parent", nil) end)
        end
        _G.__re4_xbow_dummy_parented = false
        return false
    end
    -- show=true: Dummy an L_Hand+Offset (+Scale), Lebenszeit halten.
    -- show=false: laeuft ein Drop -> frei fallen + drehen lassen; sonst Dummy beenden/freigeben.
    local function xupdate_dummy(show)
        local dummy = rawget(_G, "__re4_xbow_dummy_obj")
        local alive = dummy ~= nil and safe(function() return dummy:call("get_Valid") end) == true
        if not show then
            if xdrop.active and alive then
                xdummy_set_parent(dummy, false)   -- [NO_LAG XBOW] Fall laeuft in WELT-Koordinaten
                local t = os.clock() - xdrop.t0
                if t <= XDROP_DUR then
                    pcall(function() dummy:call("setLifeTime", 999.0) end)   -- waehrend des Falls am Leben halten
                    local fall = 0.7 * t + 0.5 * XGRAV * t * t               -- v0=0.7 m/s -> sofort gerade, aber gemaechlich
                    local s = xcfg(4600).dscale or 1.0
                    local tf = safe(function() return dummy:call("get_Transform") end)
                    if tf then
                        pcall(function() tf:call("set_Position", Vector3f.new(xdrop.sx, xdrop.sy - fall, xdrop.sz)) end)
                        local rot = safe(function() return quat_from_euler(t * 220, 0, 0):normalized() end)   -- sanftes Taumeln, eine Achse
                        if rot then pcall(function() tf:call("set_Rotation", rot) end) end
                        pcall(function() tf:call("set_LocalScale", Vector3f.new(s, s, s)) end)
                    end
                    return
                end
                xdrop.active = false   -- Fall ausgelaufen -> beenden
            end
            if alive then
                xdummy_set_parent(dummy, false)   -- [NO_LAG XBOW] vor dem Beenden vom Joint loesen
                pcall(function() dummy:call("requestEnd") end)   -- sauber beenden (sonst schwebt er weiter)
                pcall(function() dummy:call("setLifeTime", 0.0) end)
            end
            _G.__re4_xbow_dummy_obj = nil; _G.__re4_xbow_dummy_await = false
            _G.__re4_xbow_dummy_parented = false   -- [NO_LAG XBOW] naechster Dummy faengt ungeparentet an
            return
        end
        xdrop.active = false   -- neuer Griff/Vorschau -> evtl. laufenden Fall abbrechen
        if not alive then
            _G.__re4_xbow_dummy_obj = nil
            _G.__re4_xbow_dummy_parented = false   -- [NO_LAG XBOW] Dummy weg -> Merker mit weg
            _xdummy_req = _xdummy_req + 1
            if (_xdummy_req % 20) == 0 then xrequest_dummy() end
            return
        end
        pcall(function() dummy:call("setLifeTime", 999.0) end)
        local c = xcfg(4600)
        -- [NO_LAG XBOW] Geparentet ans L_Hand -> nur LOKALE Pose setzen; die Welt-Position macht die
        -- Engine, und zwar VOR dem Skinning -> der Bolzen klebt an der Hand statt nachzulaufen.
        -- Dieselben Werte wie unten, nur ohne die Handrotation davor (die steckt jetzt im Parent).
        if xdummy_set_parent(dummy, true) then
            local tfp = safe(function() return dummy:call("get_Transform") end); if not tfp then return end
            local sp = c.dscale or 1.0
            pcall(function() tfp:call("set_LocalPosition", Vector3f.new(c.dx or 0, c.dy or 0, c.dz or 0)) end)
            pcall(function() tfp:call("set_LocalRotation", quat_from_euler(c.drx or 0, c.dry or 0, c.drz or 0)) end)
            pcall(function() tfp:call("set_LocalScale", Vector3f.new(sp, sp, sp)) end)
            return
        end
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position"); local hr = lh and sc(lh, "get_Rotation")
        if not (hp and hr) then return end
        local off = safe(function() return hr * Vector3f.new(c.dx or 0, c.dy or 0, c.dz or 0) end) or Vector3f.new(0, 0, 0)
        local tf = safe(function() return dummy:call("get_Transform") end); if not tf then return end
        pcall(function() tf:call("set_Position", Vector3f.new(hp.x + off.x, hp.y + off.y, hp.z + off.z)) end)
        local rot = safe(function() return (hr * quat_from_euler(c.drx or 0, c.dry or 0, c.drz or 0)):normalized() end)
        if rot then pcall(function() tf:call("set_Rotation", rot) end) end
        local s = c.dscale or 1.0
        pcall(function() tf:call("set_LocalScale", Vector3f.new(s, s, s)) end)
    end
    -- Drop von der aktuellen Dummy-Position starten (aus dem Holster-Loslassen aufgerufen).
    local function xstart_drop()
        local dummy = rawget(_G, "__re4_xbow_dummy_obj")
        local tf = dummy and safe(function() return dummy:call("get_Transform") end)
        local p = tf and safe(function() return tf:call("get_Position") end)
        if p then
            xdrop.active = true; xdrop.sx, xdrop.sy, xdrop.sz = p.x, p.y, p.z; xdrop.t0 = os.clock()
            -- [NO_LAG XBOW] Startpunkt ist oben schon als WELT-Position gelesen -> jetzt vom Joint loesen,
            -- sonst faellt der Bolzen relativ zur mitlaufenden Hand statt zur Welt.
            xdummy_set_parent(dummy, false)
        end
    end

    -- ---- Waffen-Transform (nur fuer Kammer-Dock-Naehe; Pfeil = Mesh-Part 5, KEIN Joint!) ----
    local xwep = { wid=nil, tf=nil }
    local function xrefresh()
        local wid = get_equip_wid()
        if not (XCFG.enabled and is_xbow(wid)) then xwep.wid, xwep.tf = nil, nil; return end
        xwep.wid = wid
        if not (xwep.tf and safe(function() return xwep.tf:call("get_Position") end)) then
            xwep.tf = xget_gun_tf()
        end
    end

    local arrow = { active=false, insert=false, tune=false, t0=0, dur=0.40 }
    local _xpart_forced = false
    -- Persistenter Vorschau-Schalter NUR fuer's Tuning (Slider): wird NICHT von xsoft_reset/
    -- Waffen-Flicker gekillt, damit der Dummy beim Offset-Justieren sichtbar bleibt.
    local xprev = false

    local function xcan_load()
        if arrow.active or arrow.insert then return false end
        return (xloaded() or 0) < xcap() and xreserve() > 0
    end

    -- ---- Part 5 (Pfeil-Mesh) sichtbar halten, solange Pfeil "in der Hand" / Vorschau ----
    local function update_arrow_in_hand()
        if not (arrow.active or arrow.tune) then return end
        xpart_show(true); _xpart_forced = true
    end

    -- [KEYFRAME-PROGRAMM 2026-07-24] Armbrust ins reload_adv-Keyframe-Programm holen. Der sichtbare
    -- Pfeil ist der Hand-Dummy (__re4_xbow_dummy_obj) -- statt an der Hand wird er im Keyframe-Modus an die
    -- WAFFENRELATIVE Bahn gesetzt (wie 4400/Skull Shaker). xkf_active liefert die Bahn-Pose (Preview =
    -- shell_live, Insert = shell_pose_at), xkf_place_dummy setzt den Dummy per Welt-Pose relativ zu xwep.tf.
    local function xkf_active()
        local ms = rawget(_G, "__re4_reload_mag_slide"); if not ms then return nil end
        local kf_prev = rawget(_G, "__re4_shell_kf_preview") == 4600
        local kf_ins  = arrow.insert and type(ms.has_shell_keys) == "function" and ms.has_shell_keys(4600)
        if not (kf_prev or kf_ins) then return nil end
        local px, py, pz, rx, ry, rz
        if kf_ins and type(ms.shell_pose_at) == "function" then
            local dur = tonumber(ms.shell_dur) or arrow.dur or 0.4
            local t = (os.clock() - (arrow.t0 or 0)) / math.max(dur, 0.01); if t > 1.0 then t = 1.0 end
            px, py, pz, rx, ry, rz = ms.shell_pose_at(4600, t)
        end
        if not px and kf_prev then local s = ms.shell_live or {}; px, py, pz, rx, ry, rz = s.x or 0, s.y or 0, s.z or 0, s.rx or 0, s.ry or 0, s.rz or 0 end
        if not px then return nil end
        return px, py, pz, rx, ry, rz
    end
    local function xkf_place_dummy()
        local px, py, pz, rx, ry, rz = xkf_active(); if not px then return false end
        local dummy = rawget(_G, "__re4_xbow_dummy_obj")
        if not (dummy and safe(function() return dummy:call("get_Valid") end) == true) then return false end
        -- [NO_LAG XBOW] Die Keyframe-Bahn ist WAFFEN-relativ und wird in Weltkoordinaten gesetzt ->
        -- fuer ihre Dauer vom L_Hand-Joint loesen (danach parentet xupdate_dummy wieder an).
        xdummy_set_parent(dummy, false)
        local wtf = xwep.tf or xget_gun_tf(); if not wtf then return false end
        local gp = sc(wtf, "get_Position"); local gr = sc(wtf, "get_Rotation"); if not (gp and gr) then return false end
        local off = safe(function() return gr * Vector3f.new(px, py, pz) end)
        local wx, wy, wz = gp.x, gp.y, gp.z
        if off then wx, wy, wz = gp.x + off.x, gp.y + off.y, gp.z + off.z end
        local rot = safe(function() return (gr * quat_from_euler(rx, ry, rz)):normalized() end)
        local tf = safe(function() return dummy:call("get_Transform") end); if not tf then return false end
        local s = xcfg(4600).dscale or 1.0
        pcall(function() tf:call("set_Position", Vector3f.new(wx, wy, wz)) end)
        if rot then pcall(function() tf:call("set_Rotation", rot) end) end
        pcall(function() tf:call("set_LocalScale", Vector3f.new(s, s, s)) end)
        return true
    end

    -- ---- Kammer-Dock (Einlege-Naehe an der Waffe) ----
    local function xchamber_world()
        if not xwep.tf then return nil end
        local c = xcfg(xwep.wid or 4600)
        local j = sc(xwep.tf, "getJointByName", c.cd_joint or "_00"); if not j then return nil end
        local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation"); if not (jp and jr) then return nil end
        local off = safe(function() return jr * Vector3f.new(c.cd_x, c.cd_y, c.cd_z) end); if not off then return jp end
        return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
    end

    -- ---- ammocount +1 (einzeln; Reserve -1) ----
    -- EquipType.Main cachen (fuer inv:reload).
    local _xet_cache = nil
    local function xequip_type_main()
        if _xet_cache ~= nil then return _xet_cache end
        local td = sdk.find_type_definition("chainsaw.EquipType")
        local f = td and td:get_field("Main")
        if f then _xet_cache = f:get_data(nil) end
        return _xet_cache
    end

    -- +1 laden: bei der Armbrust werden write_dword/addAmmoCount von der Engine RE-SYNCT (greifen nicht).
    -- Einziger Pfad der wirklich laedt = ENGINE-Reload inv:reload(EquipType.Main, 1, false) (wie reload.lua).
    -- Erfolg an Reserve-Delta erkannt; Reserve zieht inv:reload selbst -> KEIN manueller Abzug.
    local function xadd_one()
        if not XCFG.reload_ammo then return end
        local pe = get_pe(); local inv = pe and sc(pe, "get_InventoryController"); if not inv then return end
        local wi = get_live_wi()
        local loaded = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or 0
        local cap = wi and (tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0) or 0
        -- [CRASH-GUARD 2026-07-09] Unbekanntes/0-cap NIE als "Platz frei" werten. Armbrust = 1-Schuss-Waffe:
        -- rutschte cap=0 durch (wi kurz nicht lesbar), rief xadd_one inv:reload auf die VOLLE Waffe -> nativer
        -- c0000005 in CsInventoryController.reload (Crash-Log: einzige wp4600-Zeile = reload PRE ohne POST bei
        -- eqAmmo=1/gunAmmo=1). Fallback cap=1 -> voll bleibt voll, kein Reload auf 1/1.
        if cap <= 0 then cap = 1 end
        if loaded >= cap then return end
        local ammo_id = wi and safe(function() return wi:call("get_CurrentAmmo") end)
        local function read_reserve()
            return (ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0) or 0
        end
        local r_b4 = read_reserve()
        if r_b4 <= 0 then return end
        local et = xequip_type_main()
        if et and _G.__re4_safe_inv_reload then _G.__re4_load_and_book(inv, et, 1, false) end   -- [CRASH-HARDEN 2026-07-17] engine-Gate enableReloadItem gegen null-Item-AV
        local loaded_af = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or loaded
        if loaded_af > loaded then xplay_sound(37656823) end   -- [SOUND] nur bei echtem +1
    end

    -- ---- Einlegen: Naehe Hand->Kammer -> kurzes Fenster, dann +1 (Part 5 bleibt solange sichtbar) ----
    local function start_arrow_insert()
        arrow.t0 = os.clock(); arrow.insert = true; arrow.active = false
        return true
    end
    local function xcheck_insert_proximity()
        if not arrow.active then return end   -- nur beim echten Holster-Griff einlegen, nicht in der Vorschau
        if arrow.insert then return end
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position"); if not hp then return end
        local gp = xchamber_world(); if not gp then return end
        local d = math.sqrt((hp.x-gp.x)^2 + (hp.y-gp.y)^2 + (hp.z-gp.z)^2)
        if d <= (XCFG.insert_distance or 0.15) then start_arrow_insert() end
    end
    local function update_arrow_insert()
        if not arrow.insert then return end
        xpart_show(true); _xpart_forced = true
        local t = (os.clock() - arrow.t0) / math.max(arrow.dur, 0.01)
        if t >= 1.0 then arrow.insert = false; xadd_one() end   -- Part 5 wird danach dem Engine-Track ueberlassen
    end

    -- ---- Hand-Pose XbowBolt + Daumen-Tuning ----
    local _xbow_fade = {}
    local function apply_xbow_pose()
        local want = (arrow.active or arrow.insert or arrow.tune or xprev) and "XbowBolt" or nil
        -- [POSE_FADE] beim Loslassen ueber POSE_FADE_DUR zurueckblenden statt snappen
        local fname, b = _G.__re4_pose_fade_step(_xbow_fade, want)
        if not fname then return end
        xpose_apply(fname, b)
        local c = xcfg(xwep.wid or 4600)
        if c.t_rx ~= 0 or c.t_ry ~= 0 or c.t_rz ~= 0 then
            local bt = body_tf(); local tj = bt and sc(bt, "getJointByName", "L_Thumb1")
            local cur = tj and sc(tj, "get_LocalRotation")
            if cur then pcall(function() tj:call("set_LocalRotation", (cur * quat_from_euler(c.t_rx*b, c.t_ry*b, c.t_rz*b)):normalized()) end) end
        end
    end

    -- ---- Holster-Grab -> Pfeil in die Hand (chained vor die bestehende Kette) ----
    local function xset_arrow_in_hand(active)
        if active then
            if not xcan_load() then return false end
            arrow.active = true
            xplay_sound(3511992014)   -- [SOUND] Pfeil aus dem Ammo-Holster gegriffen
            return true
        end
        if arrow.active then xstart_drop(); xplay_sound(288425943) end   -- losgelassen ohne Einlegen -> faellt + Sound
        arrow.active = false
        return true
    end
    local _orig_x = _G.__re4_reload_set_mag_in_hand
    _G.__re4_reload_set_mag_in_hand = function(active)
        if is_xbow(get_equip_wid()) then return xset_arrow_in_hand(active) end
        if _orig_x then return _orig_x(active) end
        return false
    end

    -- ---- Reset / Frame-Loop / Render-Pass ----
    local function xsoft_reset()
        arrow.active = false; arrow.insert = false; arrow.tune = false; arrow.snd = false
        if _xpart_forced then xpart_show(false); _xpart_forced = false end
        xupdate_dummy(false)   -- Hand-Dummy-Bolzen freigeben
    end

    local _xprev_wid = nil
    re.on_frame(function()
        -- [HAND-DUMMY] Hand-Bolzen anzeigen bei Vorschau (arrow.tune / Tuning-xprev) ODER echtem Griff.
        -- [KEYFRAME-PROGRAMM] ODER wenn der reload_adv-Keyframe-Preview fuer 4600 an ist (Dummy spawnen).
        xupdate_dummy(arrow.active or arrow.insert or arrow.tune or xprev or (rawget(_G, "__re4_shell_kf_preview") == 4600))
        xrefresh()
        if xwep.wid ~= _xprev_wid then
            local was_xbow = (_xprev_wid ~= nil)
            xsoft_reset()
            if was_xbow and not xwep.wid then
                _G.__vr_mag_in_hand = false
            end
            _xprev_wid = xwep.wid
        end
        if not xwep.wid then return end
        -- Right-B abfangen -> KEIN nativer Reload (Binding schluckt B, solange dies true ist). B macht nichts.
        _G.__vr_manual_reload_consume_b = true
        xcheck_insert_proximity()

        -- Holster-Gate: buzzen nur wenn NICHTS nachladbar (Reserve leer oder Mag voll)
        _G.__re4_reload_grab_empty = not ((xreserve() > 0) and ((xloaded() or 0) < xcap()))
        -- Globals fuer motion/arm_chain (Hand-Following aktiv, solange Pfeil in der Hand)
        _G.__vr_mag_in_hand = (arrow.active or arrow.insert) and true or false
    end)

    local function xapply_pass()
        if not (XCFG.enabled and is_xbow(get_equip_wid())) then
            if _xpart_forced then xpart_show(false); _xpart_forced = false end
            return
        end
        -- [KEYFRAME-PROGRAMM 2026-07-24] ui_wid + weapon_tf fuer die reload_adv-Keyframe-UI/Preview
        -- publizieren -- AUF DEM APP-ENTRY-PASS (nicht nur on_frame), sonst ueberschreibt reload.lua sie mit
        -- nil bevor shell_preview_apply liest. shell_joint = nil: der Pfeil ist ein Dummy-GO, KEIN Joint ->
        -- reload_advs Native-Preview soll nichts anfassen (wir setzen den Dummy selbst per xkf_place_dummy).
        _G.__re4_reload_ui_wid      = xwep.wid
        _G.__re4_reload_weapon_tf   = xwep.tf
        _G.__re4_reload_shell_joint = nil
        local kf_prev = rawget(_G, "__re4_shell_kf_preview") == 4600
        local cond = (arrow.active or arrow.insert or arrow.tune or xprev or kf_prev)
        if cond then
            update_arrow_insert()     -- Einlege-Timer -> +1
        end
        apply_xbow_pose()             -- IMMER aufrufen: [POSE_FADE] tickt auch nach dem Loslassen weiter
        xupdate_dummy(cond)           -- SPAET setzen (gewinnt gegen ShellDummy.lateUpdate); treibt auch den Drop
        xkf_place_dummy()             -- [KEYFRAME-PROGRAMM] im Keyframe-Modus den Dummy an die Bahn ueberschreiben (No-Op sonst)
    end
    -- [5-HOOK-STACK 2026-07-22, "sonst trailed das Mesh der Hand nach"] UpdateMotion fehlte als
    -- einzige Stufe -> genau in dieser Luecke schreibt die Engine die Hand-Joints neu, waehrend der
    -- Bolzen noch auf der alten L_Hand-Pose sitzt. Voller Stack = LockScene(pre) + UpdateMotion +
    -- LateUpdateBehavior + UpdateJointExpression + BeginRendering(pre), siehe arm_chain.
    pcall(function() re.on_pre_application_entry("LockScene", xapply_pass) end)
    pcall(function() re.on_application_entry("UpdateMotion", xapply_pass) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", xapply_pass) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", xapply_pass) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", xapply_pass) end)

    -- [WOBBLE-FIX] Bolzen-Dummy NACH motion.lua's BeginRendering-POST (attach_left_hand) nochmal auf die
    -- finale VR-Hand setzen -> klebt, statt 1 Pass hinterherzuhaengen (wie reposition_cart_late beim Revolver).
    -- Nur Reposition (kein Spawn/Drop/Lifetime); Fall verwaltet seine eigene Position.
    local function xreposition_dummy_late()
        if not (XCFG.enabled and is_xbow(get_equip_wid())) then return end
        -- [KEYFRAME-PROGRAMM] Im Keyframe-Modus den Dummy an die waffenrelative Bahn (NACH motion.lua) -> return.
        if xkf_place_dummy() then return end
        if not (arrow.active or arrow.insert or arrow.tune or xprev) then return end
        if xdrop.active then return end
        local dummy = rawget(_G, "__re4_xbow_dummy_obj")
        local alive = dummy ~= nil and safe(function() return dummy:call("get_Valid") end) == true
        if not alive then return end
        local c = xcfg(4600)
        -- [NO_LAG XBOW] Geparentet -> hier nur die LOKALE Pose nachziehen (falls im UI geschoben wird);
        -- die Welt-Position rechnet die Engine aus dem L_Hand-Joint, deshalb gibt es hier nichts
        -- nachzuholen. Der Welt-Weg darunter bleibt unveraendert der Fallback (Parenten fehlgeschlagen
        -- oder per __re4_xbow_dummy_nolag=false abgeschaltet).
        if rawget(_G, "__re4_xbow_dummy_parented") == true then
            local tfl = safe(function() return dummy:call("get_Transform") end); if not tfl then return end
            pcall(function() tfl:call("set_LocalPosition", Vector3f.new(c.dx or 0, c.dy or 0, c.dz or 0)) end)
            pcall(function() tfl:call("set_LocalRotation", quat_from_euler(c.drx or 0, c.dry or 0, c.drz or 0)) end)
            return
        end
        local bt = body_tf(); local lh = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lh and sc(lh, "get_Position"); local hr = lh and sc(lh, "get_Rotation")
        if not (hp and hr) then return end
        local off = safe(function() return hr * Vector3f.new(c.dx or 0, c.dy or 0, c.dz or 0) end) or Vector3f.new(0, 0, 0)
        local tf = safe(function() return dummy:call("get_Transform") end); if not tf then return end
        pcall(function() tf:call("set_Position", Vector3f.new(hp.x + off.x, hp.y + off.y, hp.z + off.z)) end)
        local rot = safe(function() return (hr * quat_from_euler(c.drx or 0, c.dry or 0, c.drz or 0)):normalized() end)
        if rot then pcall(function() tf:call("set_Rotation", rot) end) end
    end
    pcall(function() re.on_application_entry("BeginRendering", xreposition_dummy_late) end)

    re.on_script_reset(function()
        if _xpart_forced then xpart_show(false); _xpart_forced = false end
        xwep.wid, xwep.tf = nil, nil
        xsoft_reset()
        _xcm = nil
        _G.__vr_mag_in_hand = false
    end)

    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion _G.__re4_reload2_xbow_ui (65 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end
-- =====================================================================
-- ENDE ARMBRUST-GATTUNG
-- =====================================================================

re.on_script_reset(function()
    -- [RESET-RESTORE] Reset Scripts wiped nur Lua, NICHT die Szene -> der Joint bleibt in seiner letzten
    -- (evtl. offenen) Override-Rotation/-Position stehen. Der neu startende Script wuerde die dann als
    -- neue "Ruhe" capturen -> Trommel klappt beim naechsten Right-B zu weit auf (Save/Load heilte es, weil
    -- die Szene neu lud). Darum HIER, solange wir die echte Ruhe noch kennen, den Joint zuruecksetzen.
    if wep.cyl_joint then
        -- [RESET-DIAG temp] aktuellen (offenen?) _04-Stand + worauf wir zuruecksetzen loggen
        -- [log entfernt]
        if wep.cyl_rest_rot then pcall(function() wep.cyl_joint:call("set_LocalRotation", wep.cyl_rest_rot) end) end
        if wep.cyl_rest_pos then pcall(function() wep.cyl_joint:call("set_LocalPosition", wep.cyl_rest_pos) end) end
    end
    if wep.spin_joint and wep.spin_rest_rot then pcall(function() wep.spin_joint:call("set_LocalRotation", wep.spin_rest_rot) end) end
    if wep.bullet_joints then   -- evtl. in der Hand gehaltene/versteckte Kugeln wieder auf sichtbar
        for _, b in ipairs(wep.bullet_joints) do pcall(function() b.joint:call("set_LocalScale", b.vis) end) end
    end
    character_manager = nil
    _pe_cache = nil
    wep.wid, wep.tf, wep.cyl_joint, wep.cyl_rest_rot, wep.cyl_rest_pos, wep.bullet_joints, wep.insert_joint, wep.spin_joint, wep.spin_rest_rot, wep.hand_cart_joint, wep.hand_cart_vis = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
    cyl_st.open = false; cyl_st.prog = 0.0; cyl_st._prev_b = false
    reload2_st.cart = false
    drop2.active = false
    if cart_destroy then cart_destroy() end
    if wep.hammer_joint and wep.hammer_rest_rot then pcall(function() wep.hammer_joint:call("set_LocalRotation", wep.hammer_rest_rot) end) end
    hammer_st.hand_frac = 0.0; hammer_st.ham_frac = 0.0; hammer_st.cocked = false; hammer_st.cock_running = false; hammer_st.prev_seq = nil; _G.__vr_rev_cock_frac = 0
    eject.active = false; eject.items = {}; eject.armed = true
    spin_st.target = 0.0; spin_st.current = 0.0; spin_st.prev_seq = nil
end)

-- ---------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Reload2" raus (268 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- =====================================================================
-- RED9-GATTUNG (wp4002) — eigener do...end-Block. KOMPLETT eigenstaendig,
-- reload.lua fasst 4002 nicht mehr an (aus pistols/TOP_LOADER/CHAMBER gezogen).
-- Munition (Stripper-Clip + Kugeln = Parts 5,20,21) ist KEIN Joint -> wir
-- zeigen sie als MESH-KLON in der Hand (siehe Notiz):
-- eigenes GameObject + via.motion.Motion (baut Skelett!) + via.render.Mesh +
-- setMesh(lebender Gun-Holder) + set_Material(Gun-Material) + Parts isolieren.
-- Right-B: nativer Reload geblockt (consume_b). KEIN sdk.hook -> Reset Scripts reicht.
-- =====================================================================
do
    local R9 = 4002
    local function is_red9(wid) return wid == R9 end

    local RCFG = { enabled = true, parts = "5,20,21", single_part = "22",
        dx = 0.0, dy = 0.0, dz = 0.0, drx = 0.0, dry = 0.0, drz = 0.0, dscale = 1.0,
        -- EIGENER Offset + Pose-Tuning der EINZELPATRONE (Part 22, mode "single") — getrennt vom Stripper-Clip:
        sdx = 0.0, sdy = 0.0, sdz = 0.0, sdrx = 0.0, sdry = 0.0, sdrz = 0.0, sdscale = 1.0,
        st_rx = 0.0, st_ry = 0.0, st_rz = 0.0, -- Daumen-Tuning der Einzelpatrone (additiv, L_Thumb1)
        sti_rx = 0.0, sti_ry = 0.0, sti_rz = 0.0, -- Zeigefinger-Tuning der Einzelpatrone (additiv, L_IndexF1..3)
        s_thumb_str = 0.0, s_index_str = 0.0, -- Einzelpatrone: Finger Richtung GERADE strecken (0=Pose-Kruemmung, 1=gestreckt; Daumen alle 3 Gelenke)
        s_insert_dist = 0.12, -- Einzelpatrone: EIGENER Einlege-Abstand (Clip nutzt weiterhin insert_dist)
        -- [SHELL-RATIO 2026-08-12] Wieviel Munition EINE eingelegte Einzelpatrone bringt: 1 = 1:1,
        -- 2 = 1:2 (wie das Shotgun-Ratio, nur fuer den Red9-Einzelladeweg). Gedeckelt auf freie
        -- Kapazitaet und vorhandene Reserve. Der Stripper-Clip bleibt davon unberuehrt.
        shell_ratio = 1,
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
    local RCFG_PATH = "re4_vr/re4_vr_reload2_red9.json"
    local RFIELDS = { "parts","single_part","dx","dy","dz","drx","dry","drz","dscale",
        "sdx","sdy","sdz","sdrx","sdry","sdrz","sdscale","st_rx","st_ry","st_rz",
        "sti_rx","sti_ry","sti_rz","s_thumb_str","s_index_str","s_insert_dist",
        "t_rx","t_ry","t_rz","i_rx","i_ry","i_rz",
        "si_rx","si_ry","si_rz","rack_z","rack_grab","dock_x","dock_y","dock_z","rack_rx","rack_ry","rack_rz",
        "reload_ammo","insert_dist","insert_dur","ip_joint","ip_x","ip_y","ip_z","insert_drop","shell_ratio" }
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

    -- [NACKTES UI 2026-08-12] Kopie des Ratio-Schalters fuers Public-Menue, direkt unter dem
    -- Shotgun-Ratio (das haengt auf Prioritaet 60, deshalb hier 61). Gleiche Wirkung wie der
    -- Schalter im Dev-Tree -- beide schreiben RCFG.shell_ratio und speichern sofort.
    -- Eigene ##-IDs (nak_r9) -> keine Kollision mit den Dev-Tree-Buttons.
    if _G.__re4_ui_add then
        _G.__re4_ui_add(61, "reload_red9_ratio_naked", function()
            imgui.text_colored("Red9 Shell Ratio", 0xFF00A5FF)
            local rr = math.max(1, math.floor(tonumber(RCFG.shell_ratio) or 1))
            local b1 = (rr == 1) and "[1:1]" or " 1:1 "
            if imgui.button(b1 .. "##nak_r9ratio1") then RCFG.shell_ratio = 1; rsave_cfg() end
            imgui.same_line()
            local b2 = (rr == 2) and "[1:2]" or " 1:2 "
            if imgui.button(b2 .. "##nak_r9ratio2") then RCFG.shell_ratio = 2; rsave_cfg() end
        end)
    end

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
        -- [SHELL-RATIO 2026-08-12] Eine eingelegte Patrone bringt RCFG.shell_ratio Schuss (1:1 / 1:2),
        -- gedeckelt auf freie Kapazitaet und Reserve -- dasselbe Modell wie das Shotgun-Ratio.
        local want = math.max(1, math.floor(tonumber(RCFG.shell_ratio) or 1))
        if cap > 0 and want > (cap - loaded) then want = cap - loaded end
        if want > reserve then want = reserve end
        if want < 1 then want = 1 end
        local et = r9_equip_type_main()
        if et and _G.__re4_safe_inv_reload then _G.__re4_load_and_book(inv, et, want, false) end   -- [CRASH-HARDEN 2026-07-17] engine-Gate enableReloadItem gegen null-Item-AV
        local loaded_af = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or loaded
        if loaded_af > loaded then r9_play_sound(R9SND.mag_insert) end   -- Sound nur bei echtem Nachladen
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
        -- [SHELL-KEYFRAMES 2026-07-24] Red9 mit Keyframe-Bahn? Zwei Modi = zwei virtuelle wids
        -- (Einzelpatrone=40021, Stripper-Clip=4002). Dauer + Bahn kommen dann aus reload_adv statt dem Drop.
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
            -- Clip entlang der Keyframe-Bahn (relativ zur Waffe), inkl. Rotation. Die Mesh-Parts (Clip-Bundle
            -- ODER Einzelpatrone-Part) haengen am selben clip.obj -> ein Transform bewegt alle sichtbaren Parts.
            local gtf = rget_gun_tf(); local gp = gtf and sc(gtf, "get_Position"); local gr = gtf and sc(gtf, "get_Rotation")
            local tf = safe(function() return clip.obj:call("get_Transform") end)
            if tf and gp and gr then
                -- [ANLAUF 2026-07-24] Red9-Einzelpatrone (40021): weicher Anlauf von der ECHTEN Start-Pos
                -- (Hand, waffen-lokal in insert.l*) zu Keyframe #1 -> kein Sprung. anl = Anteil der Bahn-Zeit;
                -- danach die normale Keyframe-Bahn (t auf [anl,1] -> [0,1] re-mappt). Nur single; waffen-relativ.
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
                _G.__re4_bf_who = "re4_vr_reload2.lua:4593"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
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
        _G.__re4_bf_who = "re4_vr_reload2.lua:4607"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
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
        -- [SHELL-KEYFRAMES 2026-07-24] Keyframe-Tuning: der "einblenden"-Toggle (reload_adv) zeigt den Clip
        -- an der Tuning-Lage. Modus (Einzelpatrone/Stripper-Clip) kommt aus __re4_r9_kf_mode (UI-Umschalter).
        -- ui_wid = mode-abhaengige virtuelle wid (40021 single / 4002 strip) -> Keyframe-UI zeigt/faehrt den Satz.
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
        _G.__re4_bf_who = "re4_vr_reload2.lua:4674"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        _G.__vr_block_two_hand = false
        _G.__vr_slide_rack_active = false   -- [FL_RACK] Flag bei Script-Reset freigeben
        _G.__re4_reload_grab_empty = false
        _G.__vr_slide_hand_world_pos = nil; _G.__vr_slide_hand_world_rot = nil; _G.__vr_slide_dock_blend_factor = 0
        r9_destroy(); _rcm = nil
    end)

    -- [DEV-UI ENTFERNT 2026-08-19, Public Release] Zeichenfunktion _G.__re4_reload2_red9_ui (131 Zeilen) raus -- sie hing am geloeschten Tree und wurde nirgends mehr gerufen. Funktionen/Settings unveraendert.
end
-- =====================================================================
-- ENDE RED9-GATTUNG
-- =====================================================================


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
    if t == rawget(_G, "__re4_round_seen_reload2") then return end
    _G["__re4_round_seen_reload2"] = t

    _pe_cache = nil
end)
