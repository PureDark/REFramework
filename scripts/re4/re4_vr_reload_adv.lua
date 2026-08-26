-- Builtin implementation: src/mods/vr/games/re4/RE4VRReloadAdv.cpp
return

-- =====================================================================
-- RE4 VR MANUAL RELOAD — ADVANCED Mag-Slide (Portierung re9_vr_reload_advanced.lua)
-- =====================================================================
-- Stellt das Modul _G.__re4_reload_mag_slide bereit. re4_vr_reload.lua
-- delegiert den Mag-Drop hierher (Fallback = einfacher Gravity-Drop).
--
-- Zwei Phasen wie RE9:
-- 1) "slide" (LOKAL): Mag-Joint interpoliert rest -> exit (eased) ueber
-- slide_duration -> slidet aus der Kammer (exit = lokaler Austritts-Vektor).
-- 2) "fall" (WELT): danach freier Fall (Gravitation) von der ausgefahrenen
-- Position -> Mag faellt weg.
-- Exit-Vektor + Dauer pro Waffe, im UI tunbar (mit Live-Preview).
-- =====================================================================

local CFG_PATH = "re4_vr/re4_vr_reload_adv.json"

local M = {}

-- [SAFE_GIBT_IMMER_EINEN_WERT 2026-07-31] Ohne das explizite `return nil` liefert diese
-- Funktion im Fehlerfall GAR KEINEN Wert (nicht nil, NICHTS). In tostring(safe(...)) kommt dann
-- kein Argument an -> "bad argument #1 to 'tostring' (value expected)" -> der ganze umgebende
-- Aufruf stirbt. Genau daran ist am 31.07. der Bogen-Reload gestorben. Im Erfolgsfall unveraendert.
local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end
local function sc(o, m, ...) if not o then return nil end local a = {...}
    local ok, r = pcall(function() return o:call(m, table.unpack(a)) end); return ok and r or nil end
local function sf(o, n) if not o then return nil end local ok, r = pcall(function() return o:get_field(n) end); return ok and r or nil end

-- smoothstep
local function ease(t) return t * t * (3.0 - 2.0 * t) end

-- Quaternion aus Euler-Grad (Quaternion.new ist W,X,Y,Z) — identisch zu reload.lua
local function quat_from_euler(rx, ry, rz)
    local hx, hy, hz = math.rad(rx) * 0.5, math.rad(ry) * 0.5, math.rad(rz) * 0.5
    local qx = Quaternion.new(math.cos(hx), math.sin(hx), 0, 0)
    local qy = Quaternion.new(math.cos(hy), 0, math.sin(hy), 0)
    local qz = Quaternion.new(math.cos(hz), 0, 0, math.sin(hz))
    return safe(function() return (qz * qy * qx):normalized() end)
end
-- normalisierte Quaternion-Interpolation (kuerzester Weg via Vorzeichen-Check)
local function qnlerp(aw, ax, ay, az, bw, bx, by, bz, t)
    if (aw*bw + ax*bx + ay*by + az*bz) < 0 then bw, bx, by, bz = -bw, -bx, -by, -bz end
    local w, x, y, z = aw+(bw-aw)*t, ax+(bx-ax)*t, ay+(by-ay)*t, az+(bz-az)*t
    local l = math.sqrt(w*w + x*x + y*y + z*z)
    if l < 1e-6 then return aw, ax, ay, az end
    return w/l, x/l, y/l, z/l
end

-- [FLOOR] Boden-Y unter dem Spieler = Player-Body-Root (die Fuesse stehen am Boden).
-- Damit das Mag bis zum Boden faellt statt auf einer fixen Distanz (fall_dist) zu stoppen.
local floor_cm = nil
local function get_floor_y()
    if not floor_cm then floor_cm = sdk.get_managed_singleton("chainsaw.CharacterManager") end
    local ctx  = floor_cm and sc(floor_cm, "getPlayerContextRef")
    local body = ctx and sc(ctx, "get_BodyGameObject")
    local tf   = body and sc(body, "get_Transform")
    local p    = tf and sc(tf, "get_Position")
    if p then return p.y end
    return nil
end

-- ---- Default-Config + per-Waffe ----
-- Offset RELATIV zur Mag-Ruhepose: nur runter (Y), KEIN X/Z -> Mag gleitet gerade aus dem
-- Schacht statt quer zu fliegen. Pro Waffe im UI tunebar (z.B. etwas Z falls noetig).
M.default_exit = { x = 0.0, y = -0.10, z = 0.0 }
M.slide_duration_default = 0.18
M.gravity_default = 9.8
-- [RE9-STYLE FALL] kontrollierter Fall NACH dem Slide: faellt fall_dist (m) ueber fall_dur (s),
-- t^2-eased, dann Stopp (statt freier Gravitation, die unbegrenzt beschleunigt -> "wegfliegen").
M.fall_dist_default = 0.85
M.fall_dur_default  = 0.55
-- [LANDE_POSE] Ziel-Weltrotation (Euler-Grad), in die das Mag WAEHREND des Falls hineindreht
-- (nlerp von der "fliegt raus"-Rotation -> Liege-Pose). Aus = nur die Flug-Rotation gepinnt.
-- Default = an der Punisher (wp4001) getunte Liege-Pose -> gilt fuer ALLE Mag-Waffen ohne eigene
-- Pose. Weltrotation, also fuer alle Mags gleich brauchbar (Patronen-/Rifle-Waffen droppen kein Mag).
M.land_default = { on = true, rx = 89.5, ry = -157.5, rz = 125.0 }
-- per WeaponID: { exit = {x,y,z}, slide_dur, gravity, fall_dist, fall_dur }
M.weapons = {
    [4004] = { exit = { x = 0.0, y = -0.10, z = 0.0 }, slide_dur = 0.18, gravity = 9.8 },
}

-- =====================================================================
-- [EINLEIT-PUNKT 2026-07-23] Kammereingang pro Waffe als JOINT + Versatz -- dasselbe Muster,
-- das bei den Langwaffen schon laeuft (RDOCK in re4_vr_reload3.lua, Chicago = _03 + Offset).
-- Warum: der Mag-Einschub startete bisher an der HANDPOSITION. Steht die Hand schraeg zur Kammer,
-- laeuft die Gerade mitten durchs Waffenmesh, und beim Laufen wird der Weg zusaetzlich falsch.
-- Mit einem festen Punkt am Waffen-Skelett ist der Start IMMER gleich -- unabhaengig von Hand,
-- Blickrichtung und Laufgeschwindigkeit.
-- X ist bei diesen Waffen logischerweise 0 (mittig), Y/Z bestimmen Hoehe und Tiefe am Schacht.
-- Referenz: Sentinel Nine (6000) = joint _03, Y -0.092, Z -0.061.
M.dock_default = { joint = "_03", x = 0.0, y = -0.092, z = -0.061 }
M.docks = {
    [6000] = { joint = "_03", x = 0.0, y = -0.092, z = -0.061 },   -- Sentinel Nine (-Messung)
    [4003] = { joint = "_03", x = 0.0, y = -0.087, z = -0.057 },   -- Blacktail (-Messung)
    [6103] = { joint = "_03", x = 0.0, y = -0.087, z = -0.057 },   -- Blacktail AC (Ada) -- baugleich
    [4000] = { joint = "_03", x = 0.0, y = -0.087, z = -0.068 },   -- SG-09 R (-Messung)
    [4001] = { joint = "_03", x = 0.0, y = -0.075, z = -0.050 },   -- Punisher (-Messung)
    [6112] = { joint = "_03", x = 0.0, y = -0.075, z = -0.050 },   -- Punisher MC (Ada) -- baugleich
    [6300] = { joint = "_03", x = 0.0, y = -0.075, z = -0.050 },   -- [MC_6300 2026-08-04] XM96E1 (Mercenaries) -- Punisher-Werte als Start
    [6301] = { joint = "_03", x = 0.0, y = -0.087, z = -0.057 },   -- [MC_6301 2026-08-15] Blacktail AC (Mercenaries) -- 1:1 die gemessenen Blacktail-Werte (4003)
    [4004] = { joint = "_03", x = 0.0, y = -0.077, z = -0.0949 },   -- Matilda 
    -- TMP und Adas MP-AF sind baugleich -> identische Werte.
    [4200] = { joint = "_03", x = 0.0, y = -0.097, z = -0.052 },   -- TMP (Leon) -- Z 
    [6104] = { joint = "_03", x = 0.0, y = -0.097, z = -0.052 },   -- MP-AF (Ada, TMP-Klon) -- wie TMP
    [4501] = { joint = "_03", x = 0.0, y = -0.097, z = -0.070 },   -- Killer7 (-Messung)
    -- Red9 und Adas Samurai Edge sind TOP-LOADER: das Magazin kommt von OBEN in die Waffe, deshalb
    -- sind Y und Z hier positiv -- kein Vorzeichenfehler ( ausdruecklich bestaetigt).
    [4002] = { joint = "_03", x = 0.0, y = 0.064, z = 0.051 },     -- Red9 (-Messung)
    [6113] = { joint = "_03", x = 0.0, y = 0.064, z = 0.051 },     -- Samurai Edge (Ada, Red9-Klon)
    -- [LE 5 RAUS 2026-07-23] Die LE 5 hat keine Kammer, sondern einen Bananenclip, der schlicht
    -- angesteckt wird -- ihr Einschub von der Hand aus sah bereits gut aus. Kein Startpunkt fuer sie.
    -- Ihre Einlege-DISTANZ laeuft weiterhin ueber DOCK_PORT[4202] in re4_vr_reload.lua (_03, Z +0.087).
}

-- [KEIN AUTO-ANLEGEN 2026-07-23] Frueher legte diese Funktion fuer JEDE Waffe ohne Eintrag
-- automatisch einen mit den Vorgabewerten an -- dadurch bekam z.B. die LE 5 nach dem Entfernen den
-- fremden Standardpunkt und ihr Magazin schwebte heran. Ohne ausdruecklichen Eintrag gibt es jetzt
-- KEINEN Punkt, und der Aufrufer bleibt bei seinem bisherigen Verhalten.
function M.dock(wid)
    return M.docks[wid]
end

-- Nur fuer die UI: Eintrag anlegen, wenn man ihn dort bewusst einstellen will.
function M.dock_or_create(wid)
    local d = M.docks[wid]
    if not d then
        d = { joint = M.dock_default.joint, x = M.dock_default.x,
              y = M.dock_default.y, z = M.dock_default.z }
        M.docks[wid] = d
    end
    return d
end

-- Weltposition des Einleit-Punktes: Joint-Position + (Joint-Rotation * Versatz).
-- Rueckgabe nil, wenn der Joint an dieser Waffe nicht existiert -> Aufrufer faellt auf sein
-- bisheriges Verhalten zurueck (nichts wird schlechter als vorher).
-- [HARTE SCHRANKE 2026-07-23] AUSSCHLIESSLICH Pistolen und SMGs. Rifles, Shotguns, Revolver,
-- Bogen, Armbrust und Raketenwerfer duerfen diesen Punkt NIE benutzen -- auch dann nicht, wenn ueber
-- die UI oder eine alte JSON versehentlich ein Eintrag fuer sie entsteht.
M.DOCK_ALLOWED = {
    [4000] = true, [4001] = true, [4002] = true, [4003] = true, [4004] = true,   -- Pistolen (Leon)
    [4501] = true, [6000] = true,                                                -- Killer7, Sentinel Nine
    [4200] = true,                                                               -- TMP (SMG)
    [6112] = true, [6103] = true, [6113] = true, [6104] = true,                  -- Ada: Punisher, Blacktail, Samurai Edge, MP-AF
    [6300] = true,                                                               -- [MC_6300] XM96E1 (Mercenaries), Magazinpistole
    [6301] = true,                                                               -- [MC_6301] Blacktail AC (Mercenaries), Magazinpistole <- 4003
}

function M.dock_world(weapon_tf, wid)
    if not weapon_tf then return nil end
    if M.DOCK_ALLOWED[wid or 0] ~= true then return nil end
    local d = M.dock(wid or 0); if not d then return nil end
    local j = sc(weapon_tf, "getJointByName", d.joint); if not j then return nil end
    local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation")
    if not (jp and jr) then return nil end
    local off = safe(function() return jr * Vector3f.new(d.x, d.y, d.z) end); if not off then return nil end
    return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
end

-- Derselbe Punkt, aber LOKAL im Raum der Waffen-Transform -- das braucht der Mag-Joint, der ueber
-- set_LocalPosition gefuehrt wird.
function M.dock_local(weapon_tf, wid)
    local w = M.dock_world(weapon_tf, wid); if not w then return nil end
    local gp = sc(weapon_tf, "get_Position"); local gr = sc(weapon_tf, "get_Rotation")
    if not (gp and gr) then return nil end
    local rel = safe(function() return gr:conjugate() * (w - gp) end)
    return rel and { x = rel.x, y = rel.y, z = rel.z } or nil
end

function M.wcfg(wid)
    local w = M.weapons[wid]
    if not w then
        w = { exit = { x = M.default_exit.x, y = M.default_exit.y, z = M.default_exit.z },
              slide_dur = M.slide_duration_default, gravity = M.gravity_default }
        M.weapons[wid] = w
    end
    if not w.exit then w.exit = { x = M.default_exit.x, y = M.default_exit.y, z = M.default_exit.z } end
    if not w.slide_dur then w.slide_dur = M.slide_duration_default end
    if not w.gravity then w.gravity = M.gravity_default end
    if not w.fall_dist then w.fall_dist = M.fall_dist_default end
    if not w.fall_dur then w.fall_dur = M.fall_dur_default end
    if not w.land then w.land = { on = M.land_default.on, rx = M.land_default.rx, ry = M.land_default.ry, rz = M.land_default.rz } end
    return w
end

-- =====================================================================
-- [SHELL-KEYFRAMES 2026-07-24] Keyframe-gesteuerter Shell/Mag-Einschub (analog zum Twirl-System
-- __re4_ww_okeys_by_wid). Statt eines linearen Slides Hand->Kammer faehrt die Shell eine GEORDNETE
-- Keyframe-Bahn ab -- Position UND Rotation, IMMER relativ zur Waffe (klebt an ihr, kein World-Drift).
-- Keyframe 1 = Andockpunkt (fester Start; die Hand-Position wird ignoriert), letzter = Kammer.
-- NUR Waffen in KEYFRAME_INSERT nutzen das; fuer die gilt der alte lineare Einschub NICHT mehr
-- (reload.lua fragt has_shell_keys und ueberspringt dann seinen Slide). Store global, String-Keys fuer JSON.
-- =====================================================================
M.KEYFRAME_INSERT = { [4102] = true, [4100] = true, [4101] = true, [4500] = true, [4502] = true, [4002] = true, [40021] = true, [6100] = true, [6001] = true, [4400] = true, [4600] = true }   -- [bestaetigt] Striker + W-870 + Riot Gun + Butterfly + Handcannon + Red9 (4002=Stripper-Clip, 40021=Einzelpatrone -- 2 Modi, virtuelle wid) + Sawed-off W-870 (6100) + Skull Shaker (6001, Break-Action -- getragene Shell = Mesh-Clone an der Hand, folgt im Keyframe-Modus der waffenrelativen Bahn) + SR M1903 (4400, Bolt-Action -- nativer _10-Cart-Joint, reload2) + Bolt Thrower/Armbrust (4600, Dummy-Shell-GO, reload2). Nach und nach erweitern.
_G.__re4_shell_keys_by_wid = _G.__re4_shell_keys_by_wid or {}
M.shell_live = M.shell_live or { x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0 }   -- aktuelle Tuning-Lage
M.shell_preview = false     -- Toggle: Joint an der Tuning-Lage halten (zum Ausrichten in VR)
M.shell_prev_t = 0.0        -- Vorschau-Fortschritt 0..1 (Bahn abfahren)
M.shell_dur = M.shell_dur or 0.40   -- [SHELL-KEYFRAMES] eigene Bahn-Dauer s (1. -> letzter Keyframe), UNABHAENGIG von insert_dur
M.r9_anlauf = M.r9_anlauf or 0.30   -- [ANLAUF] Red9-Einzelpatrone (40021): Anteil der Bahn-Zeit fuer den weichen Anlauf Hand -> Keyframe #1 (0 = aus/harter Start)
-- [SHELL_CLONE 2026-07-24] Waffen, deren native Shell im Preview unsichtbar ist (Engine schrumpft leere
-- Kammer): statt des Joints wird ein Mesh-Clone gespawnt (reload4_dlc). Part-Index + Scale hier tunen.
M.SHELL_CLONE = { [6100] = true }   -- Sawed-off W-870
M.shell_clone_part  = M.shell_clone_part  or 1     -- welcher Gun-Mesh-Part = die Shell (durchdrehen bis nur die Huelse steht)
M.shell_clone_scale = M.shell_clone_scale or 1.0

function M.shell_keys(wid)
    local t = _G.__re4_shell_keys_by_wid[wid]
    if not t then t = {}; _G.__re4_shell_keys_by_wid[wid] = t end
    return t
end
-- [INSERT = EJECT RUECKWAERTS 2026-07-25] Test-Schalter pro Waffe: statt einer EIGENEN Insert-Bahn
-- (oder dem alten linearen Slide) faehrt der Einschub einfach die AUSWURF-Bahn rueckwaerts ab --
-- letzter Eject-Keyframe (Mag frei) -> Keyframe #1 (Mag in der Kammer). Kein zweiter Datensatz, keine
-- Kopie: es wird dieselbe Quelle gelesen, ein Nachtunen des Auswurfs zieht also automatisch mit.
-- Laeuft ueber has_shell_keys/shell_pose_at, die reload.lua ohnehin schon fragt -> dort keine Aenderung.
-- Wie bei jeder Keyframe-Bahn gilt: Start ist ein FESTER Punkt an der Waffe, die Handposition wird
-- beim Einschub ignoriert (genau wie beim Shell-Insert der Schrotflinten).
-- Default: ALLE Waffen mit Auswurf-Bahn (Leon + Ada). Das ist die Basis im CODE -- load_cfg legt die
-- JSON nur noch DRUEBER, statt die Tabelle zu ersetzen. So kann ein save_cfg aus dem laufenden Spiel
-- den Satz nicht mehr leerraeumen, und ein bewusst abgeschalteter Eintrag (false in der JSON) gewinnt
-- trotzdem gegen den Default.
M.rev_insert_by_wid = M.rev_insert_by_wid or {
    [4000] = true, [4001] = true, [4003] = true, [4004] = true, [4200] = true, [4501] = true, [6000] = true,
    [6103] = true, [6112] = true,   -- 6104 (MP-AF) ist ausgebaut, s. KEYFRAME_EJECT
    [6300] = true,                  -- [MC_6300] XM96E1 (Mercenaries) -- wirkt erst mit eigenen Eject-Keyframes
    [6301] = true,                  -- [MC_6301] Blacktail AC (Mercenaries) <- 4003
}
M.rev_insert_dur = M.rev_insert_dur or 0.35   -- eigene Einschub-Dauer s, unabhaengig von eject_dur/shell_dur
function M.uses_rev_insert(wid)
    return (wid ~= nil and M.rev_insert_by_wid[wid] == true and M.has_eject_keys(wid)) == true
end
-- Insert-Dauer fuer die Rueckwaerts-Bahn (reload.lua fragt das, sonst gilt weiter shell_dur).
function M.kf_insert_dur(wid)
    if M.uses_rev_insert(wid) then return M.rev_insert_dur end
    return nil
end

-- Nutzt die Waffe die Keyframe-Bahn? Allowlist + mind. 1 Keyframe -> sonst faellt reload.lua auf den alten Slide.
function M.has_shell_keys(wid)
    if M.uses_rev_insert(wid) then return true end   -- [INSERT = EJECT RUECKWAERTS]
    if M.KEYFRAME_INSERT[wid or 0] ~= true then return false end
    local t = _G.__re4_shell_keys_by_wid[wid]
    return (t and #t >= 1) == true
end
-- Interpolierte lokale Pose (x,y,z,rx,ry,rz) am Fortschritt tt (0..1) entlang der geordneten Keyframes.
function M.shell_pose_at(wid, tt)
    -- [INSERT = EJECT RUECKWAERTS] Zeit spiegeln und aus der Auswurf-Bahn lesen: tt=0 (Einschub-Start)
    -- landet auf dem LETZTEN Eject-Keyframe (Mag frei), tt=1 auf dem ersten (Mag steckt).
    if M.uses_rev_insert(wid) then return M.eject_pose_at(wid, 1.0 - (tonumber(tt) or 0.0)) end
    local k = _G.__re4_shell_keys_by_wid[wid]
    if not k or #k == 0 then return nil end
    if #k == 1 or tt <= 0.0 then local a = k[1]; return a.x, a.y, a.z, a.rx, a.ry, a.rz end
    if tt >= 1.0 then local a = k[#k]; return a.x, a.y, a.z, a.rx, a.ry, a.rz end
    local seg = tt * (#k - 1)
    local i = math.floor(seg) + 1; if i >= #k then i = #k - 1 end
    local f = seg - (i - 1)
    local a, b = k[i], k[i + 1]
    return a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f,
           a.rx + (b.rx - a.rx) * f, a.ry + (b.ry - a.ry) * f, a.rz + (b.rz - a.rz) * f
end
-- Shell-Joint entlang der Keyframe-Bahn setzen: lokale Pose -> Welt ueber die Waffen-Transform (klebt an der Waffe).
function M.apply_shell_keys(weapon_tf, joint, wid, tt)
    if not (weapon_tf and joint) then return false end
    local x, y, z, rx, ry, rz = M.shell_pose_at(wid, tt)
    if not x then return false end
    local gp = sc(weapon_tf, "get_Position"); local gr = sc(weapon_tf, "get_Rotation")
    if not (gp and gr) then return false end
    local off = safe(function() return gr * Vector3f.new(x, y, z) end)
    if off then pcall(function() joint:call("set_Position", Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z)) end) end
    local q = safe(function() return (gr * quat_from_euler(rx, ry, rz)):normalized() end)
    if q then pcall(function() joint:call("set_Rotation", q) end) end
    return true
end
-- Keyframe an den aktuellen Tuning-Werten ANHAENGEN (Reihenfolge = Bahn-Reihenfolge: 1=Start... n=Kammer).
function M.shell_add_key(wid)
    local t = M.shell_keys(wid)
    local s = M.shell_live
    t[#t + 1] = { x = s.x, y = s.y, z = s.z, rx = s.rx, ry = s.ry, rz = s.rz }
    M.save_cfg()
end
-- [SHELL-KEYFRAMES] Preview: haelt den Shell-Joint an der Tuning-Lage (relativ zur Waffe), zum Ausrichten.
-- Joint + Waffen-Transform kommen als Globals aus reload.lua (jeden Frame gesetzt).
local function shell_preview_apply()
    local wid = tonumber(rawget(_G, "__re4_reload_ui_wid")) or 0
    -- [SHELL-KEYFRAMES] Fuer Clone-Waffen (Revolver): signalisiert reload2, den Patronen-Clone zu spawnen,
    -- solange der Keyframe-Preview an ist -> ein Toggle blendet den Clone ein UND haelt ihn an der Tuning-Lage.
    _G.__re4_shell_kf_preview = (M.shell_preview and M.KEYFRAME_INSERT[wid] == true) and wid or nil
    -- [SHELL_CLONE] Part-Index + Scale fuer den Mesh-Clone (reload4_dlc) jeden Pass exponieren.
    _G.__re4_shell_clone_part  = M.shell_clone_part
    _G.__re4_shell_clone_scale = M.shell_clone_scale
    if not M.shell_preview then return end
    if M.KEYFRAME_INSERT[wid] ~= true then return end
    local joint = rawget(_G, "__re4_reload_shell_joint")
    local tf = rawget(_G, "__re4_reload_weapon_tf")
    if not (joint and tf) then return end
    local s = M.shell_live
    local gp = sc(tf, "get_Position"); local gr = sc(tf, "get_Rotation")
    if not (gp and gr) then return end
    local off = safe(function() return gr * Vector3f.new(s.x, s.y, s.z) end)
    if off then pcall(function() joint:call("set_Position", Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z)) end) end
    local q = safe(function() return (gr * quat_from_euler(s.rx, s.ry, s.rz)):normalized() end)
    if q then pcall(function() joint:call("set_Rotation", q) end) end
    -- [SHELL-KEYFRAMES 2026-07-24] Wie reload5 (update_cart_in_hand, set_LocalScale 1): die Engine
    -- skaliert den Shell-/Patronen-Joint bei leerer Kammer auf 0 = unsichtbar. Ohne das bleibt die Shell
    -- im Preview unsichtbar (z.B. Sawed-off), obwohl der Joint korrekt an der Tuning-Lage sitzt.
    pcall(function() joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
end
pcall(function() re.on_application_entry("LateUpdateBehavior", shell_preview_apply) end)
pcall(function() re.on_application_entry("BeginRendering", shell_preview_apply) end)

-- =====================================================================
-- [MAG-EJECT-KEYFRAMES 2026-07-24] Keyframe-gesteuerter Mag-AUSWURF -- exakt dasselbe Muster wie
-- die Shell-Insert-Keyframes oben, nur fuer die Gegenrichtung. Ersetzt in M.tick die Phase "slide"
-- (bisher ein linearer Zug Ruhe -> Exit-Punkt) durch eine GEORDNETE Bahn, Position UND Rotation,
-- IMMER relativ zur Waffe (das Mag klebt an ihr, kein World-Drift beim Laufen/Drehen).
-- Keyframe 1 = Mag steckt in der Kammer (Start), letzter = Mag ist frei -- ab dort uebernimmt
-- unveraendert die Phase "fall" (freier Fall + Lande-Pose), gesnapshottet am letzten Keyframe.
-- EIGENER Store + EIGENE Allowlist: die perfekt getunten Insert-Keyframes bleiben unangetastet.
-- Waffen ohne Eintrag/ohne Keyframe behalten 1:1 den alten linearen Slide.
-- =====================================================================
-- Freigeschaltet: Blacktail, Punisher, SG-09 R, Matilda, TMP, Killer7, Sentinel Nine (DLC, laeuft
-- ueber den Leon-Pfad in reload.lua). Ohne >=2 eigene Keyframes laeuft fuer eine Waffe weiterhin der
-- alte lineare Slide -- Freischalten allein aendert also nichts.
-- [ADA 2026-07-25] Separate Ways: 6103/6104/6112 sind mit ihren Leon-Pendants baugleich, ihre
-- Keyframes wurden 1:1 aus 4003/4200/4001 in die JSON kopiert (eigene Eintraege, kein Alias -> spaeter
-- unabhaengig nachtunbar). Ihr Drop laeuft ueber reload4_dlc, ruft aber dasselbe M.begin_drop hier.
-- [6104 RAUS 2026-07-25] Adas MP-AF ist AUSGEBAUT: bei ihr kam die Bahn nie sichtbar an
-- (Waffe/Joint werden gemeldet, die Bewegung landet trotzdem nirgends -- ungeklaert, wird spaeter
-- zusammen mit der Sawed-off gesucht). Sie laeuft damit wieder auf dem alten linearen Slide.
-- NICHT wieder eintragen, ohne dass die Ursache gefunden ist. Leons TMP (4200) ist nicht betroffen.
-- [2026-08-15] Wiedereintrag wurde probiert und noch am selben Tag zurueckgenommen: das Mag ging
-- verkantet rein (Leons 4200-Bahn traegt Rotationen rx 17 / ry 12.5 / rz 21.5, die an ihrer Waffe
-- schief stehen). Der Befund von 07-25 gilt also weiter.
-- [MC_6300 2026-08-04] XM96E1 (Mercenaries) laeuft wie die uebrigen Magazinpistolen ueber
-- reload.lua; Keyframes werden unten wie bei Adas Klonen aus der Punisher (4001) vorbefuellt.
M.KEYFRAME_EJECT = { [4003] = true, [4001] = true, [4000] = true, [4004] = true, [4200] = true, [4501] = true, [6000] = true,
                     [6103] = true, [6112] = true, [6300] = true, [6301] = true }   -- [MC_6301] Blacktail AC <- 4003
_G.__re4_mag_eject_keys_by_wid = _G.__re4_mag_eject_keys_by_wid or {}
M.eject_live = M.eject_live or { x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0 }   -- aktuelle Tuning-Lage
M.eject_preview = false     -- Toggle: Mag-Joint an der Tuning-Lage halten (zum Ausrichten in VR)
M.eject_prev_t = 0.0        -- Vorschau-Fortschritt 0..1 (Bahn abfahren)
M.eject_dur = M.eject_dur or 0.35   -- Bahn-Dauer s (1. -> letzter Keyframe), UNABHAENGIG von insert_dur

-- [ADA: EIGENE KOPIE 2026-07-25 "kein Kuddelmuddel"] Adas Waffen haben EIGENE Keyframes, kein
-- Nachschlagen bei Leon zur Laufzeit. Die Startwerte hier sind 1:1 Leons Stand vom 2026-07-25
-- (6103<-4003, 6104<-4200, 6112<-4001), weil die Waffen baugleich sind. Ab dem ersten eigenen
-- Keyframe in der JSON gilt nur noch die JSON -- diese Tabelle ist reine Erstbefuellung, damit die
-- Werte nicht wieder verschwinden, wenn ein save_cfg aus dem laufenden Spiel die Datei ueberschreibt.
local EJECT_SEED = {
    [6103] = {   -- Blacktail AC <- 4003
        { x = 0.0, y =  0.000, z =  0.000, rx = 0.0, ry = 0.0, rz = 0.0 },
        { x = 0.0, y = -0.102, z = -0.029, rx = 0.0, ry = 0.0, rz = 0.0 },
    },
    -- 6104 (MP-AF) bewusst NICHT hier: ausgebaut, s. KEYFRAME_EJECT.
    [6112] = {   -- Punisher MC <- 4001
        { x = 0.0, y =  0.000, z =  0.000, rx = 0.0, ry = 0.0, rz = 0.0 },
        { x = 0.0, y = -0.102, z = -0.017, rx = 0.0, ry = 0.0, rz = 0.0 },
    },
    [6300] = {   -- [MC_6300] XM96E1 (Mercenaries) <- 4001, damit die Bahn nicht auf den linearen
                 -- Slide zurueckfaellt. Eigener Satz -> spaeter unabhaengig nachtunbar.
        { x = 0.0, y =  0.000, z =  0.000, rx = 0.0, ry = 0.0, rz = 0.0 },
        { x = 0.0, y = -0.102, z = -0.017, rx = 0.0, ry = 0.0, rz = 0.0 },
    },
    [6301] = {   -- [MC_6301 2026-08-15] Blacktail AC (Mercenaries) <- 4003, dieselben Werte wie
                 -- Adas Blacktail-Klon (6103). Eigener Satz -> spaeter unabhaengig nachtunbar.
        { x = 0.0, y =  0.000, z =  0.000, rx = 0.0, ry = 0.0, rz = 0.0 },
        { x = 0.0, y = -0.102, z = -0.029, rx = 0.0, ry = 0.0, rz = 0.0 },
    },
}
-- Nur befuellen, was noch gar nichts hat -- ein vorhandener (getunter) Satz wird NIE angefasst.
function M.seed_eject_keys()
    for wid, arr in pairs(EJECT_SEED) do
        local cur = _G.__re4_mag_eject_keys_by_wid[wid]
        if not (cur and #cur >= 1) then
            local t = {}
            for _, k in ipairs(arr) do
                t[#t + 1] = { x = k.x, y = k.y, z = k.z, rx = k.rx, ry = k.ry, rz = k.rz }
            end
            _G.__re4_mag_eject_keys_by_wid[wid] = t
        end
    end
end

function M.eject_keys(wid)
    local t = _G.__re4_mag_eject_keys_by_wid[wid]
    if not t then t = {}; _G.__re4_mag_eject_keys_by_wid[wid] = t end
    return t
end
-- Nutzt die Waffe die Auswurf-Bahn? Allowlist + mind. 2 Keyframes (Start + Ende) -> sonst alter Slide.
function M.has_eject_keys(wid)
    if M.KEYFRAME_EJECT[wid or 0] ~= true then return false end
    local t = _G.__re4_mag_eject_keys_by_wid[wid]
    return (t and #t >= 2) == true
end
-- Interpolierte lokale Pose (x,y,z,rx,ry,rz) am Fortschritt tt (0..1) entlang der geordneten Keyframes.
function M.eject_pose_at(wid, tt)
    local k = _G.__re4_mag_eject_keys_by_wid[wid]
    if not k or #k == 0 then return nil end
    if #k == 1 or tt <= 0.0 then local a = k[1]; return a.x, a.y, a.z, a.rx, a.ry, a.rz end
    if tt >= 1.0 then local a = k[#k]; return a.x, a.y, a.z, a.rx, a.ry, a.rz end
    local seg = tt * (#k - 1)
    local i = math.floor(seg) + 1; if i >= #k then i = #k - 1 end
    local f = seg - (i - 1)
    local a, b = k[i], k[i + 1]
    return a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f,
           a.rx + (b.rx - a.rx) * f, a.ry + (b.ry - a.ry) * f, a.rz + (b.rz - a.rz) * f
end
-- Mag-Joint entlang der Auswurf-Bahn setzen: lokale Pose -> Welt ueber die Waffen-Transform.
function M.apply_eject_keys(weapon_tf, joint, wid, tt)
    if not (weapon_tf and joint) then return false end
    local x, y, z, rx, ry, rz = M.eject_pose_at(wid, tt)
    if not x then return false end
    local gp = sc(weapon_tf, "get_Position"); local gr = sc(weapon_tf, "get_Rotation")
    if not (gp and gr) then return false end
    local off = safe(function() return gr * Vector3f.new(x, y, z) end)
    if off then pcall(function() joint:call("set_Position", Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z)) end) end
    local q = safe(function() return (gr * quat_from_euler(rx, ry, rz)):normalized() end)
    if q then pcall(function() joint:call("set_Rotation", q) end) end
    return true
end
-- Keyframe an den aktuellen Tuning-Werten ANHAENGEN (Reihenfolge = Bahn: 1=Kammer... n=frei/Fall-Start).
function M.eject_add_key(wid)
    local t = M.eject_keys(wid)
    local s = M.eject_live
    t[#t + 1] = { x = s.x, y = s.y, z = s.z, rx = s.rx, ry = s.ry, rz = s.rz }
    M.save_cfg()
end
-- [MAG-EJECT-KEYFRAMES] Aktuelle Ruhelage des Mags (in der Kammer) als Tuning-Lage uebernehmen --
-- damit Keyframe #1 exakt dort sitzt, wo das Mag steckt, statt ihn von Hand zu suchen.
function M.eject_grab_rest()
    local joint = rawget(_G, "__re4_reload_shell_joint")
    local tf = rawget(_G, "__re4_reload_weapon_tf")
    if not (joint and tf) then return false end
    local jp = sc(joint, "get_Position"); local jr = sc(joint, "get_Rotation")
    local gp = sc(tf, "get_Position");     local gr = sc(tf, "get_Rotation")
    if not (jp and jr and gp and gr) then return false end
    local rel = safe(function() return gr:conjugate() * (jp - gp) end)
    if not rel then return false end
    local s = M.eject_live
    s.x, s.y, s.z = rel.x, rel.y, rel.z
    -- Rotation bewusst NICHT mitgelesen: gemessene Live-Rotationen fangen Engine-State ein
    -- (siehe Red9-rest_z-Falle). Rot X/Y/Z bleiben, wie sie stehen, und werden von Hand gesetzt.
    return true
end
-- [MAG-EJECT-KEYFRAMES] Preview: haelt den Mag-Joint an der Tuning-Lage (relativ zur Waffe).
-- Joint + Waffen-Transform kommen als Globals aus reload.lua (jeden Frame gesetzt); fuer Pistolen
-- ist __re4_reload_shell_joint == wep.mag_joint, also genau der Joint, den wir tunen wollen.
local function eject_preview_apply()
    local wid = tonumber(rawget(_G, "__re4_reload_ui_wid")) or 0
    -- Signal fuer reload.lua: das Mag ist verschoben -> NICHT als Ruhepose erfassen (sonst Drift).
    _G.__re4_mag_eject_kf_preview = (M.eject_preview and M.KEYFRAME_EJECT[wid] == true) and wid or nil
    if not M.eject_preview then return end
    if M.KEYFRAME_EJECT[wid] ~= true then return end
    local joint = rawget(_G, "__re4_reload_shell_joint")
    local tf = rawget(_G, "__re4_reload_weapon_tf")
    if not (joint and tf) then return end
    local s = M.eject_live
    local gp = sc(tf, "get_Position"); local gr = sc(tf, "get_Rotation")
    if not (gp and gr) then return end
    local off = safe(function() return gr * Vector3f.new(s.x, s.y, s.z) end)
    if off then pcall(function() joint:call("set_Position", Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z)) end) end
    local q = safe(function() return (gr * quat_from_euler(s.rx, s.ry, s.rz)):normalized() end)
    if q then pcall(function() joint:call("set_Rotation", q) end) end
    -- Wie beim Shell-Preview: die Engine skaliert einen "leeren" Joint evtl. auf 0 -> sichtbar halten.
    pcall(function() joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
end
pcall(function() re.on_application_entry("LateUpdateBehavior", eject_preview_apply) end)
pcall(function() re.on_application_entry("BeginRendering", eject_preview_apply) end)
-- [TUNING] Preview nie ueber einen Script-Reset hinaus anlassen (Mag haenge sonst in der Luft).
pcall(function() re.on_script_reset(function()
    M.eject_preview = false; _G.__re4_mag_eject_kf_preview = nil
end) end)

function M.load_cfg()
    local data = safe(function() return json.load_file(CFG_PATH) end)
    if type(data) ~= "table" then return end
    -- [SHELL-KEYFRAMES] eigene Bahn-Dauer laden.
    if type(data.shell_dur) == "number" then M.shell_dur = data.shell_dur end
    if type(data.r9_anlauf) == "number" then M.r9_anlauf = data.r9_anlauf end   -- [ANLAUF]
    if type(data.shell_clone_part) == "number" then M.shell_clone_part = data.shell_clone_part end   -- [SHELL_CLONE]
    if type(data.shell_clone_scale) == "number" then M.shell_clone_scale = data.shell_clone_scale end
    -- [SHELL-KEYFRAMES] geordnete Bahn-Keyframes pro Waffe laden (String-Keys -> wid-Zahl).
    if type(data.shell_keys) == "table" then
        _G.__re4_shell_keys_by_wid = {}
        for kk, arr in pairs(data.shell_keys) do
            local wn = tonumber(kk)
            if wn and type(arr) == "table" then
                local t2 = {}
                for _, kf in ipairs(arr) do
                    if type(kf) == "table" then
                        t2[#t2 + 1] = { x = tonumber(kf.x) or 0.0, y = tonumber(kf.y) or 0.0, z = tonumber(kf.z) or 0.0,
                                        rx = tonumber(kf.rx) or 0.0, ry = tonumber(kf.ry) or 0.0, rz = tonumber(kf.rz) or 0.0 }
                    end
                end
                _G.__re4_shell_keys_by_wid[wn] = t2
            end
        end
    end
    -- [MAG-EJECT-KEYFRAMES] Auswurf-Bahn pro Waffe laden (eigener Block, String-Keys -> wid-Zahl).
    if type(data.eject_dur) == "number" then M.eject_dur = data.eject_dur end
    -- [INSERT = EJECT RUECKWAERTS] Schalter pro Waffe + eigene Einschub-Dauer.
    if type(data.rev_insert_dur) == "number" then M.rev_insert_dur = data.rev_insert_dur end
    if type(data.rev_insert_by_wid) == "table" then
        -- MERGE statt Ersetzen: der Code-Default bleibt die Basis (sonst raeumt eine alte JSON ihn weg),
        -- die JSON entscheidet nur pro Waffe -- auch explizites false, damit Abschalten erhalten bleibt.
        for kk, vv in pairs(data.rev_insert_by_wid) do
            local wn = tonumber(kk)
            if wn then M.rev_insert_by_wid[wn] = (vv == true) end
        end
    end
    if type(data.mag_eject_keys) == "table" then
        _G.__re4_mag_eject_keys_by_wid = {}
        for kk, arr in pairs(data.mag_eject_keys) do
            local wn = tonumber(kk)
            if wn and type(arr) == "table" then
                local t2 = {}
                for _, kf in ipairs(arr) do
                    if type(kf) == "table" then
                        t2[#t2 + 1] = { x = tonumber(kf.x) or 0.0, y = tonumber(kf.y) or 0.0, z = tonumber(kf.z) or 0.0,
                                        rx = tonumber(kf.rx) or 0.0, ry = tonumber(kf.ry) or 0.0, rz = tonumber(kf.rz) or 0.0 }
                    end
                end
                _G.__re4_mag_eject_keys_by_wid[wn] = t2
            end
        end
    end
    -- [PUSH_POSE] universeller Block (nicht pro Waffe)
    if type(data.push) == "table" then
        if type(data.push.on) == "boolean" then M.push.on = data.push.on end
        for _, k in ipairs({ "in_dur", "hold", "out_dur", "release_dur", "curl", "thumb", "rx", "ry", "rz", "px", "py", "pz", "ada_px", "ada_py", "ada_pz", "reload_speed", "fall_grav_mult" }) do
            if type(data.push[k]) == "number" then M.push[k] = data.push[k] end
        end
        -- [POSE1] gecapturte Bones (kopierte "pose1") uebernehmen, wenn vorhanden.
        if type(data.push.bones) == "table" and next(data.push.bones) ~= nil then
            M.push.bones = data.push.bones
        end
    end
    -- [PUSH-Y PRO WAFFE] Zusatz-Hoehe pro WeaponID laden (String-Keys -> wid-Zahl).
    if type(data.push_y_by_wid) == "table" then
        M.push_y_by_wid = {}
        for kk, vv in pairs(data.push_y_by_wid) do
            local wn, yv = tonumber(kk), tonumber(vv)
            if wn and yv then M.push_y_by_wid[wn] = yv end
        end
    end
    if type(data.docks) == "table" then
        for k, v in pairs(data.docks) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                M.docks[wid] = { joint = v.joint or M.dock_default.joint,
                                 x = tonumber(v.x) or 0.0,
                                 y = tonumber(v.y) or M.dock_default.y,
                                 z = tonumber(v.z) or M.dock_default.z }
            end
        end
    end
    if type(data.weapons) ~= "table" then return end
    for k, v in pairs(data.weapons) do
        local wid = tonumber(k)
        if wid and type(v) == "table" then
            M.weapons[wid] = {
                exit = { x = (v.exit and v.exit.x) or 0.0, y = (v.exit and v.exit.y) or -0.10, z = (v.exit and v.exit.z) or 0.0 },
                slide_dur = tonumber(v.slide_dur) or M.slide_duration_default,
                gravity = tonumber(v.gravity) or M.gravity_default,
                fall_dist = tonumber(v.fall_dist) or M.fall_dist_default,
                fall_dur  = tonumber(v.fall_dur)  or M.fall_dur_default,
                land = { on = (v.land and v.land.on) == true,
                         rx = tonumber(v.land and v.land.rx) or 0.0,
                         ry = tonumber(v.land and v.land.ry) or 0.0,
                         rz = tonumber(v.land and v.land.rz) or 0.0 },
            }
        end
    end
end
function M.save_cfg()
    local out = {}
    for wid, v in pairs(M.weapons) do
        out[tostring(wid)] = { exit = v.exit, slide_dur = v.slide_dur, gravity = v.gravity, fall_dist = v.fall_dist, fall_dur = v.fall_dur, land = v.land }
    end
    local dout = {}
    for wid, d in pairs(M.docks) do dout[tostring(wid)] = { joint = d.joint, x = d.x, y = d.y, z = d.z } end
    -- [SHELL-KEYFRAMES] geordnete Bahn-Keyframes pro Waffe persistieren.
    local skout = {}
    for wid, arr in pairs(_G.__re4_shell_keys_by_wid or {}) do
        local t2 = {}
        for _, k in ipairs(arr) do t2[#t2 + 1] = { x = k.x, y = k.y, z = k.z, rx = k.rx, ry = k.ry, rz = k.rz } end
        skout[tostring(wid)] = t2
    end
    -- [MAG-EJECT-KEYFRAMES] Auswurf-Bahn pro Waffe persistieren (eigener Block).
    local ekout = {}
    for wid, arr in pairs(_G.__re4_mag_eject_keys_by_wid or {}) do
        local t2 = {}
        for _, k in ipairs(arr) do t2[#t2 + 1] = { x = k.x, y = k.y, z = k.z, rx = k.rx, ry = k.ry, rz = k.rz } end
        ekout[tostring(wid)] = t2
    end
    -- [PUSH-Y PRO WAFFE] Zusatz-Hoehe pro WeaponID persistieren (nur Eintraege != 0).
    local pyout = {}
    for wid, yv in pairs(M.push_y_by_wid or {}) do
        if tonumber(yv) and yv ~= 0 then pyout[tostring(wid)] = yv end
    end
    -- [INSERT = EJECT RUECKWAERTS] Schalter pro Waffe persistieren (true UND false, s. load_cfg).
    local riout = {}
    for wid, vv in pairs(M.rev_insert_by_wid or {}) do riout[tostring(wid)] = (vv == true) end
    pcall(function() json.dump_file(CFG_PATH, { weapons = out, push = M.push, docks = dout, shell_keys = skout, shell_dur = M.shell_dur, r9_anlauf = M.r9_anlauf, shell_clone_part = M.shell_clone_part, shell_clone_scale = M.shell_clone_scale, mag_eject_keys = ekout, eject_dur = M.eject_dur, push_y_by_wid = pyout, rev_insert_by_wid = riout, rev_insert_dur = M.rev_insert_dur }) end)
end

-- =====================================================================
-- [PUSH_POSE 2026-07-21] Waehrend das Mag in die Waffe geschoben wird, hat die linke Hand
-- nichts mehr zu halten -> sie geht kurz in eine UNIVERSELLE "Handballen-Druecken"-Pose (flache
-- Hand) und lerpt danach zurueck. Rein optisch, keine Reload-Logik.
--
-- Warum hier: die Pose ist bewusst waffenunabhaengig (im Gegensatz zu MAG_POSE[wid] in reload.lua).
-- Angewandt wird sie ueber den Joint-Writer aus reload.lua (__re4_reload_apply_pose_bones), der
-- vom AKTUELLEN Zustand zum Ziel nlerpt -> der Blend-Faktor ergibt automatisch das Ein-/Ausblenden
-- gegen die gerade anliegende Mag-Halte-Pose. Registriert NACH motion.lua (Ladereihenfolge m < r),
-- laeuft also in denselben Passes spaeter -> die Push-Pose gewinnt, solange sie aktiv ist.
--
-- Linke Hand: Finger beugen um -Z, L_Thumb1 um +X, L_Thumb2/3 um +Y (aus den Captures abgeleitet).
-- [HANDBALLEN 2026-07-21] pose1 war eine 1:1-Kopie der MAG-Halte-Pose (nur Daumen 8 Grad anders)
-- -> unsichtbar. Jetzt eine eigene, generierte Pose: Finger weitgehend gestreckt = flacher Handballen,
-- der von unten gegen das Mag drueckt. Dazu Offsets fuer die GANZE Hand (L_Hand): Rotation, damit die
-- Handflaeche zum Magazinboden zeigt, und Position, damit sie daran klebt. Beide werden mit dem
-- Blend skaliert -> fahren sauber rein und wieder raus. Alles rein optisch.
-- [KRUEMMUNG 2026-07-21] Alle vier Finger deutlich eingerollt (Faust am Magazinboden),
-- der Daumen bleibt wie er war -- er hat einen eigenen Wert und wird davon nicht beruehrt.
M.push = { on = true, in_dur = 0.07, hold = 0.10, out_dur = 0.14, curl = 85.0, thumb = 15.0,
           release_dur = 0.20,   -- [DOCK-RELEASE 2026-07-24] Wie lang die Hand nach dem Push weich vom Magazin-Dock zum Controller ausfadet (statt hart zu snappen). Von reload.lua/reload4_dlc.lua gelesen. 0 = aus (hartes Verhalten wie frueher).
           reload_speed = 1.0,   -- [MASTER-TEMPO 2026-07-23] Zeitfaktor fuers gesamte Reinladen: <1 = langsamer, >1 = schneller. Skaliert Insert-Dauer UND Push-Phasen gleich -> Verhaeltnis bleibt.
           fall_grav_mult = 2.5,   -- [FALL-GEWICHT 2026-07-23] globaler Gravity-Faktor fuer den gedroppten Mag-Fall (1 = 9.8 realistisch, hoeher = schwerer/schneller). Das Mag "schwebte wie Papier".
           rx = 0.0, ry = 0.0, rz = 0.0,      -- Hand-Rotations-Offset (Grad, lokal am L_Hand)
           px = 0.0, py = 0.0, pz = 0.0,      -- Hand-Positions-Offset (m, relativ zum Magazin-Joint)
           -- [ADA 2026-07-21] Ada hat kleinere Haende -> leicht andere Lage am selben Magazin.
           -- ZUSAETZLICHER Positions-Offset, der NUR bei ihr oben drauf kommt (Rotation bleibt geteilt).
           -- Leon ist damit per Definition unberuehrt: bei ihm sind diese drei Werte nie im Spiel.
           ada_px = 0.0, ada_py = 0.0, ada_pz = 0.0 }
local push_t0 = nil
-- [TUNING 2026-07-21, "Button druecken und dann in VR tunen geht nicht"] Dauer-Toggle: haelt die
-- Pose+Offsets permanent auf Blend 1.0, damit man sie in VR am EINGERASTETEN Magazin ausrichten kann
-- (das Mag steckt dann normal in der Waffe = exakt die Endlage des Inserts). Wird BEWUSST nicht
-- gespeichert und beim Script-Reset geloescht -> kann nicht versehentlich im Spiel anbleiben.
M.push_tune = false

local function push_quat(deg, axis, sign)
    local r = math.rad(deg) * 0.5 * (sign or 1.0)
    local q = { math.cos(r), 0.0, 0.0, 0.0 }
    q[axis] = math.sin(r)
    return q
end
-- [POSE1 2026-07-21] Die Nachdrueck-Pose ist die gecapturte "pose1" (linke Hand). Ihre Bones
-- liegen 1:1 in re4_vr_reload_adv.json unter push.bones -- kopiert aus POSES["pose1"] in
-- re4_vr_reload.json, damit adv nicht von reloads Pose-Store abhaengt. Fehlt der Block (geloeschte
-- JSON), faellt es auf die generierte flache Hand zurueck (curl/thumb-Slider).
local function push_bones()
    if type(M.push.bones) == "table" and next(M.push.bones) ~= nil then return M.push.bones end
    local b = { L_Palm = push_quat(0, 4) }
    for _, pre in ipairs({ "L_IndexF", "L_MiddleF", "L_RingF", "L_PinkyF" }) do
        for i = 1, 3 do b[pre .. i] = push_quat(M.push.curl, 4, -1.0) end   -- -Z = einrollen (links)
    end
    b.L_Thumb1 = push_quat(M.push.thumb, 2)      -- +X
    b.L_Thumb2 = push_quat(M.push.thumb * 0.5, 3) -- +Y
    b.L_Thumb3 = push_quat(M.push.thumb * 0.5, 3)
    return b
end

-- [PUSH-PROBE 2026-07-21] temporaer: warum ist die Pose nicht sichtbar? Loggt Zuendung, Blend und

-- [PUSH_WIDS 2026-07-21] Nur Pistolen mit Magazin-Reload duerfen nachdruecken. Alles andere
-- (Schrotflinten, Gewehre, Revolver ohne Mag, Bogen, Werfer...) hat kein Magazin, das man mit dem
-- Handballen hochschiebt -- dort waere die Geste schlicht falsch.
M.PUSH_WIDS = {
    [4000] = true,  -- SG-09 R
    [4001] = true,  -- Punisher
    [4003] = true,  -- Blacktail
    [4004] = true,  -- Matilda
    [4501] = true,  -- Killer7
    [6000] = true,  -- Sentinel Nine (DLC)
    [6103] = true,  -- Blacktail AC (Separate Ways)
    [6112] = true,  -- Punisher MC (Separate Ways)
    [6300] = true,  -- XM96E1 (Mercenaries)
    [6301] = true,  -- Blacktail AC (Mercenaries) -- baugleich zu Leons Blacktail (4003)
    -- [TMP 2026-07-21] Maschinenpistolen mit Stangenmagazin -- wird genauso mit dem Handballen
    -- hochgeschoben wie ein Pistolenmag, die Geste passt also 1:1. Beide Charaktere:
    [4200] = true,  -- TMP (Leon)
    [6104] = true,  -- MP-AF (Ada, Separate Ways -- die SW-TMP)
}

-- Von reload.lua / reload4_dlc.lua beim Insert-Start gerufen, mit der WeaponID der aktuellen Waffe.
-- Ohne ID (alter Aufruf) passiert nichts -> lieber keine Geste als eine falsche.
function M.start_push(wid)
    if M.push.on == false then return end
    if not (type(wid) == "number" and M.PUSH_WIDS[wid]) then return end
    push_t0 = os.clock()
    -- [PUSH-Y PRO WAFFE 2026-07-25] Die Waffe, zu der DIESE Geste gehoert, festhalten. Sie ist die
    -- verlaesslichste Quelle fuer den Y-Zusatz: __re4_reload_ui_wid wird von fuenf Scripten jeden
    -- Frame beschrieben, und publish_dock laeuft mehrfach pro Frame in fremden Passes -- dort kann
    -- das Global schon die naechste/keine Waffe zeigen.
    M.push_wid = wid
end
function M.stop_push() push_t0 = nil end

-- [MANUAL_INSERT 2026-08-15] Beim Einschieben VON HAND dauert der Push so lange, wie der Spieler
-- braucht -- die feste Bahn Rein/Halten/Zurueck passt dafuer nicht. Deshalb ein HALTEN: die Geste
-- startet ganz normal (Rein-Lerp), bleibt dann auf 1.0 stehen, und erst beim Einrasten bzw. beim
-- Zurueckziehen laeuft die Zurueck-Phase ab. Alles andere (Pose, Hand-Dock ans Magazin, Offsets,
-- DOCK-RELEASE) bleibt damit exakt der bisherige Weg -- es wird nur die Uhr angehalten.
M.push_hold = false
function M.begin_push_hold(wid)
    M.start_push(wid)                     -- respektiert push.on UND PUSH_WIDS
    M.push_hold = (push_t0 ~= nil)        -- nur halten, wenn die Geste ueberhaupt angelaufen ist
end
function M.end_push_hold()
    if not M.push_hold then return end
    M.push_hold = false
    -- Uhr so stellen, dass genau noch die Zurueck-Phase uebrig ist -- danach faellt push_t0 wie immer
    -- von selbst weg und der Links-Ausfade (release_dur) uebernimmt.
    local tm = M.time_mult()
    push_t0 = os.clock() - ((M.push.in_dur or 0) * tm + (M.push.hold or 0) * tm)
end
-- UI-Test: Pose einmal komplett durchfahren (Rein/Halten/Zurueck), auch ohne Reload.
function M.start_push_test() push_t0 = os.clock() end

-- [POSE_CROSSFADE 2026-08-15] Der aktuelle Push-Blend wird veroeffentlicht, damit die Mag-in-Hand-Pose
-- in motion.lua GEGENLAEUFIG dazu ausblenden kann. Vorher liefen beide unabhaengig: die Mag-Pose fadete
-- zeitbasiert gegen die native Animation und wird im spaeteren Pass geschrieben, ueberdeckte also die
-- laengst fertige Push-Pose -- und wenn sie endete, erschien die Push-Pose schlagartig. Genau das war
-- das Snappy. Mit dem gemeinsamen Wert blendet die eine Pose exakt so weit auf, wie die andere abbaut.
local function push_apply()
    local blend
    if M.push_tune then
        blend = 1.0                                   -- [TUNING] dauerhaft halten
    elseif M.push_hold then
        -- [MANUAL_INSERT] Halten heisst NICHT sofort voll: erst die normale Rein-Rampe (in_dur)
        -- fahren, DANN oben stehenbleiben. Vorher sprang der Blend in einem Frame auf 1.0 -- damit
        -- war "Rein-Lerp s" wirkungslos und der Wechsel zwischen den beiden Handposen snappte.
        if not push_t0 then
            blend = 1.0
        else
            local e2 = os.clock() - push_t0
            local i2 = M.push.in_dur * M.time_mult()
            blend = (e2 < i2) and (e2 / math.max(i2, 0.01)) or 1.0
        end
    else
        if not push_t0 then _G.__re4_push_blend = nil; return end
        local e = os.clock() - push_t0
        local tm = M.time_mult()
        local i_dur, h_dur, o_dur = M.push.in_dur*tm, M.push.hold*tm, M.push.out_dur*tm
        local total = i_dur + h_dur + o_dur
        if e >= total then push_t0 = nil; _G.__re4_push_blend = nil; return end
        if e < i_dur then blend = e / math.max(i_dur, 0.01)
        elseif e < i_dur + h_dur then blend = 1.0
        else blend = 1.0 - ((e - i_dur - h_dur) / math.max(o_dur, 0.01)) end
    end
    if blend <= 0.0 then _G.__re4_push_blend = nil; return end
    _G.__re4_push_blend = blend
    local w = rawget(_G, "__re4_reload_apply_pose_bones")
    if type(w) == "function" then pcall(w, push_bones(), blend) end

end

-- [HAND-DOCK 2026-07-21, "sie muss wie beim Sliderack feststehen und der Waffe folgen"]
-- Die Hand wird NICHT mehr per Joint-Offset verbogen (das kaempft gegen die Controller-IK und
-- wandert mit dem Controller mit). Stattdessen exakt der Weg des Slide-Racks: reload.lua
-- veroeffentlicht waehrend des Pushs ein IK-Dock-Ziel am MAGAZIN-Joint (__vr_slide_hand_world_pos/
-- _rot + Blend), arm_chain zieht die linke Hand dorthin und motion uebernimmt die Rotation.
-- Damit steht die Hand fest an der Waffe, egal wo der Controller ist. Die Offsets unten
-- (rx/ry/rz, px/py/pz) sind die Lage RELATIV zum Magazin-Joint -- reload.lua holt sie hier ab.
-- Positions-Offset fuer den AKTUELLEN Charakter (Leon = px/py/pz, Ada = px/py/pz + ada_*).
-- Charakter kommt aus dem zentralen __re4_char_now (motion/weapons2), wie ueberall sonst.
-- Zeitfaktor -> Multiplikator fuer Dauern (Speed 1.0 = unveraendert; 0.5 = doppelt so lang).
function M.time_mult()
    local sp = tonumber(M.push.reload_speed) or 1.0
    if sp < 0.2 then sp = 0.2 end
    return 1.0 / sp
end

-- [PUSH-Y PRO WAFFE 2026-07-25] Der Push-Block bleibt universell -- nur die HOEHE (Y) bekommt
-- pro WeaponID einen ZUSATZ-Wert, der oben drauf kommt. Default 0 => exakt das bisherige Verhalten,
-- eine Waffe ohne Eintrag merkt nichts davon. Betrifft naturgemaess nur Mag-Waffen (nur die haben
-- ueberhaupt eine Push-Geste). Gilt fuer Leon UND Ada, weil Adas Waffen eigene wids haben (6103...).
M.push_y_by_wid = M.push_y_by_wid or {}
-- Aktuell gefuehrte Waffe: dieselbe Quelle wie die UI-Trees hier (reload.lua und reload4_dlc.lua
-- setzen __re4_reload_ui_wid jeden Frame). Unbekannte/fremde wid -> Zusatz 0, also unveraendert.
-- Reihenfolge der Quellen, absteigend verlaesslich:
-- 1) explizit uebergebene wid (der Aufrufer kennt seine Waffe -- reload.lua/reload4_dlc geben wep.wid mit)
-- 2) M.push_wid: die Waffe, mit der die laufende Push-Geste gestartet wurde
-- 3) das globale __re4_reload_ui_wid (nur noch Notnagel/UI -- wird von mehreren Scripten beschrieben)
local function push_wid_now()
    return tonumber(rawget(_G, "__re4_reload_ui_wid")) or tonumber(rawget(_G, "__vr_equip_wid")) or 0
end
function M.push_y_extra(wid)
    local w = wid or M.push_wid or push_wid_now()
    return tonumber(M.push_y_by_wid[w]) or 0.0
end

function M.push_pos(wid)
    local p = M.push
    local ada = false
    local fn = rawget(_G, "__re4_char_now")
    if type(fn) == "function" then
        local ok, ch = pcall(fn)
        ada = (ok and ch == "ada")
    end
    local ye = M.push_y_extra(wid)   -- [PUSH-Y PRO WAFFE] Zusatz-Hoehe der aktuellen Waffe
    if not ada then return p.px or 0, (p.py or 0) + ye, p.pz or 0 end
    return (p.px or 0) + (p.ada_px or 0), (p.py or 0) + (p.ada_py or 0) + ye, (p.pz or 0) + (p.ada_pz or 0)
end

function M.push_blend()
    if M.push_tune then return 1.0 end
    -- [MANUAL_INSERT] Hand bleibt am Magazin, bis es einrastet -- aber erst NACH der Rein-Rampe
    -- (in_dur), damit der Weg dorthin geblendet wird und nicht springt. Gegenstueck zu push_apply.
    if M.push_hold and push_t0 then
        local e2 = os.clock() - push_t0
        local i2 = M.push.in_dur * M.time_mult()
        if e2 >= i2 then return 1.0 end
        local b2 = e2 / math.max(i2, 0.01)
        return b2 * b2 * (3.0 - 2.0 * b2)            -- smoothstep, wie unten
    end
    if not push_t0 then return 0.0 end
    local e = os.clock() - push_t0
    local tm = M.time_mult()
    local i_dur, h_dur, o_dur = M.push.in_dur*tm, M.push.hold*tm, M.push.out_dur*tm
    local total = i_dur + h_dur + o_dur
    if e >= total then return 0.0 end
    local b
    if e < i_dur then b = e / math.max(i_dur, 0.01)
    elseif e < i_dur + h_dur then b = 1.0
    else b = 1.0 - ((e - i_dur - h_dur) / math.max(o_dur, 0.01)) end
    if b < 0.0 then b = 0.0 end
    return b * b * (3.0 - 2.0 * b)   -- smoothstep, wie der Slide-Dock-Blend
end

pcall(function() re.on_pre_application_entry("LockScene",         push_apply) end)
pcall(function() re.on_application_entry("LateUpdateBehavior",    push_apply) end)
pcall(function() re.on_application_entry("UpdateJointExpression", push_apply) end)
pcall(function() re.on_pre_application_entry("BeginRendering",    push_apply) end)
-- [PASS-FIX 2026-07-21, per Probe-Log] Die Pose WURDE geschrieben (blend bis 1.00), war aber unsichtbar:
-- motion.lua wendet die Mag-/Rack-Hand-Pose im BeginRendering-POST-Pass an, unser Pre-Pass laeuft davor
-- -> motion hat jeden Frame drueber geschrieben. Deshalb zusaetzlich im POST-Pass anwenden; da motion
-- frueher geladen wird (m < r), laufen wir dort NACH ihm und gewinnen.
pcall(function() re.on_application_entry("BeginRendering",        push_apply) end)

-- ---- Drop-State (eine Mag-Joint) ----
M.drop = { active = false, phase = nil, joint = nil, wid = nil, t0 = 0,
           lx0 = 0, ly0 = 0, lz0 = 0, ex = 0, ey = 0, ez = 0,
           sx = 0, sy = 0, sz = 0, slide_dur = 0.18, gravity = 9.8 }

-- joint = via.Joint des Magazins, wid = WeaponID, dur_override = Slide-Dauer (z.B. Insert-Dauer)
function M.begin_drop(joint, wid, dur_override, exit_local)
    if not joint then return false end
    local lp = sc(joint, "get_LocalPosition"); if not lp then return false end
    local w = M.wcfg(wid)
    local d = M.drop
    d.joint, d.wid = joint, wid
    d.lx0, d.ly0, d.lz0 = lp.x, lp.y, lp.z
    -- [EINLEIT-PUNKT ALS DROP-ZIEL 2026-07-23] Ist ein absolutes lokales Ziel uebergeben (der
    -- Einleit-Punkt, exakt derselbe wie beim Reinsliden), gleitet das Mag GENAU dorthin raus -- also
    -- rueckwaerts die Kammerachse entlang, dann faellt es. Ohne Ziel: alter Weg (Ruhe + Exit-Vektor).
    if type(exit_local) == "table" and exit_local.x then
        d.ex, d.ey, d.ez = exit_local.x, exit_local.y, exit_local.z
    else
        -- [RELATIV] Exit = Ruhe-Pos + Offset -> Mag gleitet nur um den Offset (z.B. rein runter),
        -- NICHT auf eine absolute Lokal-Pos (die das Mag quer in X/Z zerren wuerde).
        d.ex, d.ey, d.ez = lp.x + w.exit.x, lp.y + w.exit.y, lp.z + w.exit.z
    end
    -- [SLIDE-OUT = INSERT-SPEED] wenn das Hauptscript eine Dauer mitgibt (Insert-Dauer), die
    -- nehmen -> Rausgleiten genauso schnell wie das Reingleiten. Sonst per-Waffe slide_dur.
    d.slide_dur, d.gravity = (dur_override and dur_override > 0 and dur_override) or w.slide_dur, w.gravity
    d.fall_dist, d.fall_dur = w.fall_dist, w.fall_dur
    -- [MAG-EJECT-KEYFRAMES] Hat die Waffe eine Auswurf-Bahn, faehrt die Phase "slide" diese ab
    -- (eigene Dauer, unabhaengig von insert_dur/slide_dur). Sonst bleibt alles wie bisher.
    d.use_keys = M.has_eject_keys(wid) == true
    if d.use_keys then d.slide_dur = M.eject_dur end
    d.vx, d.vz, d.lpt = 0, 0, nil   -- [INHERIT_VEL] Geschwindigkeits-Tracker fuer diesen Drop zuruecksetzen
    d.t0 = os.clock()
    d.phase = "slide"
    d.active = true
    return true
end

function M.cancel()
    M.drop.active = false
    M.drop.joint = nil
    M.drop.phase = nil
end

function M.is_active() return M.drop.active == true end

function M.tick()
    local d = M.drop
    if not d.active or not d.joint then return end
    if d.phase == "slide" then
        -- [MAG-EJECT-KEYFRAMES 2026-07-24] Auswurf entlang der geordneten Bahn statt linearem Zug.
        -- Linear ueber die Keyframes (wie beim Insert): die Form steckt in den Keyframes selbst, ein
        -- zusaetzliches Easing wuerde ihre Abstaende verzerren. Fehlt die Waffen-Transform, faellt der
        -- Drop auf den alten Slide zurueck -- nichts wird schlechter als vorher.
        if d.use_keys then
            local wtf = rawget(_G, "__re4_reload_weapon_tf")
            if wtf then
                local t = (os.clock() - d.t0) / math.max(d.slide_dur, 0.01)
                if t > 1.0 then t = 1.0 end
                M.apply_eject_keys(wtf, d.joint, d.wid, t)
                if t >= 1.0 then
                    -- Letzter Keyframe erreicht -> ab hier uebernimmt der Fall (identisch zum alten Pfad):
                    -- Weltpose einfrieren, Boden-Y merken, Phase wechseln.
                    local p = sc(d.joint, "get_Position")
                    if p then d.sx, d.sy, d.sz = p.x, p.y, p.z end
                    local r = sc(d.joint, "get_Rotation")
                    if r then d.srw, d.srx, d.sry, d.srz = r.w, r.x, r.y, r.z end
                    d.floor_y = get_floor_y()
                    d.phase = "fall"
                    d.t0 = os.clock()
                end
                return
            end
            d.use_keys = false
        end
        -- [GRAVITY-DROP 2026-07-08] KEIN Lauf-Impuls-Tracking mehr: das Mag faellt am Ende senkrecht mit
        -- Gewicht (freier Fall), folgt NICHT mehr der Spielerbewegung. Slide = reines Rausgleiten aus dem Schacht.
        local t = (os.clock() - d.t0) / math.max(d.slide_dur, 0.01)
        if t > 1.0 then t = 1.0 end
        local u = ease(t)
        -- Rausgleiten entlang des (lokalen) Magazinschachts = sichtbares "aus der Waffe sliden".
        -- Richtung/Distanz pro Waffe ueber Exit X/Y/Z (lokal) im Advanced-UI einstellbar.
        pcall(function()
            d.joint:call("set_LocalPosition", Vector3f.new(
                d.lx0 + (d.ex - d.lx0) * u,
                d.ly0 + (d.ey - d.ly0) * u,
                d.lz0 + (d.ez - d.lz0) * u))
        end)
        if t >= 1.0 then
            -- ausgefahrene Welt-Position als Fall-Start snapshotten
            local p = sc(d.joint, "get_Position")
            if p then d.sx, d.sy, d.sz = p.x, p.y, p.z end
            -- [ENTKOPPEL_ROT] Welt-Rotation im selben Moment einfrieren -> das gefallene Mag folgt
            -- danach NICHT mehr der Waffenrotation (Symptom: Mag lag am Boden, drehte sich aber mit
            -- der Waffe mit, weil nur die Position gepinnt war). Analog zur Messer-Detach-Loesung:
            -- feste Weltpose, keine Kopplung an die Waffe, bis das Mag weggeraeumt wird (Insert/Grab).
            local r = sc(d.joint, "get_Rotation")
            if r then d.srw, d.srx, d.sry, d.srz = r.w, r.x, r.y, r.z end
            -- [FLOOR] Boden-Ziel beim Fall-Start merken -> Mag faellt bis zum Boden, nicht fixe Distanz.
            d.floor_y = get_floor_y()
            d.phase = "fall"
            d.t0 = os.clock()
        end
        return
    end
    -- Phase "fall": ECHTER Gravity-Fall (Gewicht). Das Mag faellt beschleunigt SENKRECHT bis zum Boden und
    -- bleibt dann liegen. KEIN geerbter Lauf-Impuls mehr (das Mitziehen/Feder-Drift sah kacke aus, 07-08).
    local t = os.clock() - d.t0
    local g = (d.gravity or 9.8) * (tonumber(M.push.fall_grav_mult) or 1.0)   -- [FALL-GEWICHT] globaler Faktor
    local fall = 0.5 * g * t * t                        -- s = ½·g·t² (freier Fall mit Gewicht)
    -- [FLOOR] bis zum Boden (Exit-Y -> Boden + 2cm Bodenfreiheit). Fallback = fixe fall_dist ohne Boden-Y.
    local total = d.fall_dist or 0.85
    if d.floor_y then
        total = d.sy - (d.floor_y + 0.02)
        if total < 0 then total = 0 end
    end
    if fall > total then fall = total end               -- am Boden anhalten (kein Durchfallen/Wegschiessen)
    local tf = (total > 1e-4) and (fall / total) or 1.0 -- Fall-Fortschritt 0..1 (nur fuer die Lande-Pose-Rotation)
    -- SENKRECHT runter: Start-XZ halten. Das Mag hat Gewicht und faellt gerade, statt dem Spieler zu folgen.
    pcall(function() d.joint:call("set_Position", Vector3f.new(d.sx, d.sy - fall, d.sz)) end)
    -- [ENTKOPPEL_ROT / LANDE_POSE] Weltrotation jeden Frame festhalten -> Mag bleibt starr im Raum,
    -- dreht sich nicht mit der Waffe (bis stop_mag_drop bei Insert/Grab die Drop-Phase beendet).
    -- Ist die Lande-Pose aktiv, wird ueber den Fall (tf 0->1) von der Flug-Rotation in die tunebare
    -- Liege-Pose (Welt-Euler) hineininterpoliert -> "fliegt raus" wandelt sich zu "liegt am Boden".
    if d.srw then
        local rw, rx, ry, rz = d.srw, d.srx, d.sry, d.srz
        local lc = M.wcfg(d.wid).land
        if lc and lc.on then
            local tq = quat_from_euler(lc.rx, lc.ry, lc.rz)
            if tq then rw, rx, ry, rz = qnlerp(d.srw, d.srx, d.sry, d.srz, tq.w, tq.x, tq.y, tq.z, tf) end
        end
        pcall(function() d.joint:call("set_Rotation", Quaternion.new(rw, rx, ry, rz)) end)
    end
end

-- =====================================================================
-- Live-Preview (Mag im UI auf exit-Pose halten zum Tunen)
-- =====================================================================
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
M.preview = { active = false, until_t = 0, joint = nil, lx0 = 0, ly0 = 0, lz0 = 0, wid = nil }

-- vom Hauptscript gesetzt: aktueller Mag-Joint (damit Preview ohne Doppelsuche geht)
M.current_mag_joint = nil

function M.start_preview(seconds)
    local j = M.current_mag_joint
    if not j then return end
    local lp = sc(j, "get_LocalPosition"); if not lp then return end
    M.preview.joint = j
    M.preview.lx0, M.preview.ly0, M.preview.lz0 = lp.x, lp.y, lp.z
    M.preview.wid = get_equip_wid()
    M.preview.until_t = os.clock() + (seconds or 5.0)
    M.preview.active = true
end
function M.tick_preview()
    if not M.preview.active then return end
    if os.clock() >= M.preview.until_t or not M.preview.joint then
        M.preview.active = false; M.preview.joint = nil; return
    end
    local w = M.wcfg(M.preview.wid)
    pcall(function()
        M.preview.joint:call("set_LocalPosition", Vector3f.new(
            M.preview.lx0 + w.exit.x, M.preview.ly0 + w.exit.y, M.preview.lz0 + w.exit.z))
    end)
end

-- Preview-Pose NACH der Engine-Pose schreiben
pcall(function() re.on_application_entry("LateUpdateBehavior", function() M.tick_preview() end) end)
pcall(function() re.on_application_entry("BeginRendering", function() M.tick_preview() end) end)

-- =====================================================================
-- UI (unter der Pistolen-Sektion gedacht; eigener Header)
-- =====================================================================
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Reload Adv" raus (233 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- [TUNING] Nie ueber einen Script-Reset hinaus anlassen.
pcall(function() re.on_script_reset(function() M.push_tune = false end) end)

M.load_cfg()
M.seed_eject_keys()   -- [ADA: EIGENE KOPIE] nur befuellen, was leer geblieben ist (getunte Saetze bleiben)
_G.__re4_reload_mag_slide = M
