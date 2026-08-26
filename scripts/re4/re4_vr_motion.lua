-- Builtin implementation: src/mods/vr/games/re4/RE4VRMotion.cpp
return

-- =====================================================================
-- RE4 VR MOTION CONTROLS - Pure Hand-Joint Binding (RE9-Style Pipeline)
-- =====================================================================
-- Bindet R_Hand und L_Hand Joints des Spieler-Bodys an die VR Controller.
-- Reine Controller -> Joint Pipeline mit modernen RE9-Techniken:
-- * sc/sf Helpers (variadische pcall-Wrapper)
-- * controller_to_world einheitliche Pose-Pipeline
-- * Runtime + Controller-aware OpenXR-Korrektur
-- * Shared Config re4_vr/re4_vr_motion.json (Read-Modify-Write)
-- * Standing-Origin Cache + RE9 Hook-Stack (LockScene/LateUpdateBehavior/BeginRendering)
-- * Smoothing-State + Cross-Script-Globals (_G.__vr_rh_world etc.)
-- * Init-Gate auf vrmod-Controller-Bereitschaft
-- =====================================================================

if reframework:get_game_name() ~= "re4" then
    return
end


-- ---------------------------------------------------------------------
-- Optionale Module
-- ---------------------------------------------------------------------
local ok_ks, killswitch = pcall(function()
    return require("re4vr/re4_vr_killswitch")
end)
if not ok_ks then killswitch = nil end

local ok_re4, re4 = pcall(function()
    return require("utility/RE4")
end)
if not ok_re4 then re4 = nil end


-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function sc(obj, method, ...)
    if not obj then return nil end
    local ok, r = pcall(function(...) return obj:call(method, ...) end, ...)
    return ok and r or nil
end

local function sf(obj, name)
    if not obj then return nil end
    local ok, r = pcall(function() return obj:get_field(name) end)
    return ok and r or nil
end

local function deg2rad(d)
    return d * 0.0174532925
end

local function vec3_new(x, y, z) return Vector3f.new(x, y, z) end

local function vec3_subtract(a, b)
    return Vector3f.new(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function vec3_add(a, b)
    return Vector3f.new(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function vec3_lerp(a, b, t)
    return Vector3f.new(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t
    )
end

local function quat_slerp(a, b, t)
    if not a or not b then return b end
    local ok, r = pcall(function() return a:slerp(b, t) end)
    return ok and r or b
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


-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------
local cache = {
    rh_world = nil, rh_rot = nil,
    lh_world = nil, lh_rot = nil,
    standing_origin = nil,
    standing_origin_set = false,
}

local right_hand = { joint = nil, enabled = true }
local left_hand  = { joint = nil, enabled = true }

local rot_smooth = { hands = 0.0 }
-- Positions-Glaettung gegen Controller-Mikrozittern (0 = roh wie RE9).
-- Hoehere Werte = ruhiger, aber mehr Nachzieh-Gefuehl beim schnellen Zielen.
local pos_smooth = { hands = 0.0 }

-- [KS4_EXIT_FADE 2026-07-17, so gewollt] Nach dem Verlassen eines KS4 BEIDE Haende weich von der nativen
-- Engine-Pose zum Controller lerpen statt hart snappen. Muster 1:1 vom erprobten [RELOAD-FADE] im Minecart.
-- Der Killswitch setzt _G.__re4_ks4_exit_t beim KS4-Austritt (nur KS4, eigene Flanke). dur = Slider unten
-- ("KS4-Austritt: Haende einblenden"), 0 = hart/aus. from = pro Hand EINMAL eingefrorene Startpose.
-- Als GLOBAL, NICHT local: motion.lua ist am 200-Top-Level-Local-Limit (vier neue locals sprengen es,
-- live belegt). Daten + beide Fade-Funktionen laufen deshalb ueber _G.__re4_ks4fade. `or` -> ein
-- Reload behaelt einen manuell gesetzten dur (load_config ueberschreibt ihn ohnehin aus der JSON).
_G.__re4_ks4fade = _G.__re4_ks4fade or { dur = 0.35, from = {} }

-- [TWO_HAND_IK] Beide Haende an der Waffe + beide Grip-Buttons -> die Waffe folgt der
-- Linie rechte Hand -> linke Hand (look-at). Modifiziert cache.rh_rot (Waffe + RH-Hand
-- drehen mit). Gegated auf grosse/zweihaendige Waffen. Tunings persistieren (two_hand_cfg).
local two_hand = {
    enabled     = true,
    min_dist    = 0.04,   -- Hand-Abstand min (m), darunter kein Blend (Haende zu nah)
    max_dist    = 0.90,   -- Hand-Abstand max (m), darueber kein Blend (linke Hand zu weit)
    blend_speed = 0.05,   -- Ein-/Ausblend-Geschwindigkeit pro Frame (sanfter = kein Snap-Gefuehl beim Engage)
    pitch       = 0.0,    -- (Schwenk-Ansatz braucht keine Korrektur; Felder bleiben fuer evtl. Feintuning)
    yaw         = 0.0,
    roll        = 0.0,    -- Roll kommt vom Schwenk-Ansatz aus der rechten Hand -> keine 90-Grad-Korrektur noetig
    blend       = 0.0,    -- Laufzeit (0..1)
    active      = false,  -- Laufzeit: 2-Hand-IK greift gerade (beide Grips + in Reichweite) -> Support-Dock erzwingen
    _dbg_dist   = -1,     -- Laufzeit-Anzeige
    -- [RACK_FREEZE RAUS 2026-07-31] Der Rack-Freeze (Waffenrotation waehrend des Rackens
    -- einfrieren) ist ERSATZLOS GESTRICHEN -- er fuehlte sich bei jeder Waffe steif an. Waehrend des
    -- Racks rampt nur noch die Two-Hand-IK aus; die Waffe folgt frei der rechten Hand. Die beiden
    -- Laufzeit-Felder bleiben als tote Altlast NICHT stehen -> entfernt.
    _pump_ref_pos   = nil,    -- [PUMP_NO_Z] Laufzeit: Waffenposition im ersten Pump-Frame (Laengsachsen-Referenz)
    _pump_ref_cam   = nil,    -- [PUMP_NO_Z] dazu die Kameraposition -> Anker wandert beim Laufen mit
    _smooth_rot     = nil,    -- [SNAP_SOFTEN] Laufzeit: zuletzt ausgegebene (geglaettete) Waffenrotation
    _engage_swing0  = nil,    -- [REL_ENGAGE] Laufzeit: Schwenk-Nullpunkt beim Greifen (relativer Engage = kein Hochkippen)
    _rack_release   = 0,      -- [RACK_RELEASE] Laufzeit: Frames-Countdown fuer den sanften Freeze-Exit-Lerp
}
-- [SNAP_SOFTEN] Grosse 1-Frame-Spruenge der Waffenrotation (Rack-Freeze-Exit, harte Gate-Wechsel)
-- sanft einblenden; kleine Aenderungen (normales Zielen, Schwenks) 1:1 durchlassen -> keine Aim-Latenz.
local TWO_HAND_SNAP_COS  = 0.966   -- cos(~15 Grad): nur Spruenge GROESSER als das werden eingeblendet
local TWO_HAND_SNAP_EASE = 0.25    -- Einblend-Anteil pro Frame (kleiner = sanfter)
local RACK_RELEASE_FRAMES = 12     -- [RACK_RELEASE] nach dem Freeze-Exit so viele Frames IMMER lerpen (frozen -> live), schwellenunabhaengig
local smoothing  = { right_pos = nil, right_rot = nil, left_pos = nil, left_rot = nil }

local init_state = {
    initialized = false,
    frame_counter = 0,
}

local body_cache = { go = nil, transform = nil }


-- ---------------------------------------------------------------------
-- Runtime + Controller Detection
-- ---------------------------------------------------------------------
local vr_runtime = "openvr"           -- "openvr" | "openxr"
local selected_controller = "steamvr" -- "steamvr" | "metavr"


-- ---------------------------------------------------------------------
-- Shared Config (re4_vr/re4_vr_motion.json)
-- ---------------------------------------------------------------------
local CONFIG_FILE = "re4_vr/re4_vr_motion.json"

-- OpenXR-Korrektur (von RE9 uebernommen, immer gleich fuer OpenXR-Runtime)
local openxr_correction = {
    pos_x = 0.015, pos_y = -0.006, pos_z = -0.104,
    rot_pitch = -16.341, rot_yaw = -2.011, rot_roll = -0.754,
}

local OPENXR_CORRECTION_DEFAULTS = {
    pos_x = 0.015, pos_y = -0.006, pos_z = -0.104,
    rot_pitch = -16.341, rot_yaw = -2.011, rot_roll = -0.754,
}

-- Quest/Touch-Korrektur (ctrl_correction aus RE9, spieleunabhaengig immer
-- gleich — getunte RE9-Werte als Default). Kommt NUR bei
-- selected_controller == "metavr" pauschal obendrauf; Index/steamvr = Baseline.
local ctrl_correction = {
    pos_x = -0.004, pos_y = -0.002, pos_z = -0.002,
    rot_pitch = 0.0, rot_yaw = 0.0, rot_roll = 5.606,
}

local CTRL_CORRECTION_DEFAULTS = {
    pos_x = -0.004, pos_y = -0.002, pos_z = -0.002,
    rot_pitch = 0.0, rot_yaw = 0.0, rot_roll = 5.606,
}

-- euler(deg) -> Quaternion (W,X,Y,Z). Wird auch von der OpenXR-Rot-Korrektur (Z.~392) gebraucht.
local function quat_from_euler_deg(px, py, pz)
    local function ax(a, x, y, z)
        local h = math.rad(a) * 0.5
        local s = math.sin(h)
        return Quaternion.new(math.cos(h), x * s, y * s, z * s)
    end
    local q = ax(py, 0, 1, 0) * ax(px, 1, 0, 0) * ax(pz, 0, 0, 1)
    local ok, n = pcall(function() return q:normalized() end)
    return ok and n or q
end

-- Linke Hand: globaler Offset (Position im Hand-Frame (m) + lokale Rotation (deg)). Persistiert in der motion-JSON.
local hand_offset = {
    L = { px = 0.0, py = 0.0, pz = 0.0, rx = 0.0, ry = 0.0, rz = 0.0 },
}

-- Rechte Hand: per-Waffe Offset, auf das NEUE System adaptiert -> wird auf den R_Hand-Joint
-- angewandt (NICHT auf eine Waffen-GO wie frueher). Key = Weapon-ID als String, "none" = keine Waffe.
-- Alle Werte default 0.0; Tabelle wird lazy beim ersten Zugriff erzeugt.
local WEAPON_NONE_KEY = "none"
local function new_weapon_offset()
    return { px = 0.0, py = 0.0, pz = 0.0, rx = 0.0, ry = 0.0, rz = 0.0 }
end
local weapon_offset = {}
local function get_weapon_offset(key)
    key = key or WEAPON_NONE_KEY
    if not weapon_offset[key] then weapon_offset[key] = new_weapon_offset() end
    return weapon_offset[key]
end

-- [WEP_REL_PERSIST] Auto-kalibrierter Hand->Waffe-Offset PRO WAFFE, persistent +
-- EINGEFROREN. Jede Waffe wird EINMAL sauber kalibriert (im Ruhezustand, wo
-- Skip/Pin nicht reinfunken) -> gespeichert -> bei jedem weiteren Equip wird der
-- gespeicherte Wert wiederverwendet, NIE neu gesampelt. Damit bleibt die Waffe
-- stabil und dein Per-Waffe-Offset (weapon_offset) gilt stabil darueber.
local weapon_rel = {}   -- key(string) -> { px,py,pz, qx,qy,qz,qw }
local function wo_is_default(o)
    return o.px == 0 and o.py == 0 and o.pz == 0 and o.rx == 0 and o.ry == 0 and o.rz == 0
end

-- [SUPPORT_HAND] Linke Hand dockt an den Waffen-Vordergriff (Dev-Pattern,
-- portiert aus re4_vr_motion.lua.dev_bak — OHNE Two-Hand-Aim-Modul).
-- Dock-Punkt = RH-Pose + ein einziger Offset (aim-unabhaengig). Dock/Undock
-- mit Hysterese, kein Undock waehrend Recoil.
local support = {
    enabled = true,
    force_dock = false,
    docked = false,
    -- [GRIP_LATCH_REACH 2026-07-19] Grenze fuer den Grip-Latch, als ANTEIL der ECHTEN
    -- Armreichweite (__vr_arm_chain_L_maxreach, von arm_chain aus den Knochenlaengen +
    -- Shoulder-Follow berechnet). Bewusst KEIN fester Meterwert: Ada und Leon haben
    -- unterschiedlich lange Arme -- ein Fixwert waere bei einer der beiden falsch.
    -- 1.0 = bis ans absolute Limit inkl. voll ausgeschoepftem Shoulder-Follow (= Gummi-Arm),
    -- kleiner = frueher loesen. 0.75 laesst den Shoulder-Follow arbeiten, bricht aber ab
    -- bevor es aussieht wie Kaugummi.
    grip_latch_reach = 0.75,
    blend_speed = 0.050,        -- global (Dock-Distanzen sind per-Waffe)
    blend_factor = 0.0,
    target_blend = 0.0,
    aim_blend = 0.0,            -- [SUPPORT_AIM] 0 = Idle-Dock, 1 = Aim-Dock (smooth gerampt)
    aim_preview = false,        -- [SUPPORT_AIM] Tuning-Hilfe: erzwingt aim_blend=1 ohne Trigger
    switch_docked = false,      -- [SWITCH_DOCK] LE5: Hand gerade am Verstell-Schalter (joint_05) statt Vordergriff
    switch_preview = false,     -- [SWITCH_DOCK] Tuning-Hilfe: erzwingt Switch-Dock ohne Naehe/Grip
    switch_aim_preview = false, -- [SWITCH_DOCK] Tuning-Hilfe: erzwingt Switch-Dock UND Aim-Blend=1 in einem
    switch2_preview = false,    -- [SWITCH_DOCK2] Tuning-Hilfe: Switch-Dock + Hebel auf Burst-Stellung (zeigt set2, no-aim)
    switch2_aim_preview = false,-- [SWITCH_DOCK2] Tuning-Hilfe: Switch-Dock + Hebel auf Burst + Aim-Blend=1 (zeigt set2 aim)
    switch2_blend = 0.0,        -- [SWITCH_DOCK2] geglaetteter Pose1<->Pose2 Blend (0=Full-Auto-Pose, 1=Single/Burst-Pose), eigener Lerp
    switch_blend_lock = false,  -- [SWITCH_DOCK] solange ein Switch-Dock noch AUSBLENDET weiter Switch-Pose nutzen (kein Schaft-Flackern beim Grip-Loslassen)
    fire_mode = 0,              -- [FIRE_MODE] 0=Full (default), 1=Burst, 2=Single. Zyklus Full->Burst->Single->Full
    prev_fire_mode = 0,         -- [FIRE_MODE] Flanke fuer Umleg-Sound
    burst_active = false,       -- [BURST] abgeleitet: fire_mode~=0 (Hebel weg von Full). Feuer-Block/switch2 nutzen das
    burst_preview = false,      -- [BURST] Tuning-Hilfe: zeigt den Hebel auf Burst-Winkel
    single_preview = false,     -- [FIRE_MODE] Tuning-Hilfe: zeigt den Hebel auf Single-Winkel
    burst_anim = 0.0,           -- [BURST] sanft gelerpter aktueller Hebel-Winkel
    prev_switch_trigger = false,-- [BURST] Flanken-Tracking Left-Trigger fuer den Burst-Toggle am Schalter
}

-- Support Hand Offset PRO WAFFE (Key = Weapon-ID-String wie weapon_offset).
-- Neue/ungetunte Waffen starten auf 0 -> jede Waffe einzeln einstellen.
local support_offset = {}
local function get_support_offset(key)
    key = key or WEAPON_NONE_KEY
    if not support_offset[key] then
        support_offset[key] = {
            pos_x = 0.0, pos_y = 0.0, pos_z = 0.0,
            rot_pitch = 0.0, rot_yaw = 0.0, rot_roll = 0.0,
            -- Dock-Distanzen pro Waffe (Pose startet 0, Distanzen mit Defaults)
            dock_threshold = 0.110, undock_threshold = 0.150,
            -- [PUMP_GRIP 2026-08-07, "ich wuerde gerne erstmal die Hand drankleben"]
            -- NUR Pump-Shotguns (s. PUMP_GRIP_JOINT): dort ist der Vordergriff KEIN starres
            -- Stueck Waffe, sondern der bewegliche Pump-Slide (_01, Weg park_z->back_z = 12,5 cm).
            -- Der normale Zielpunkt haengt an der rechten Hand und kann dem nicht folgen -> die
            -- Hand haengt daneben und wandert weg. Ist grip_on gesetzt, wird der Zielpunkt statt
            -- dessen AM JOINT verankert; grip_x/y/z ist der Feinversatz IM JOINT-FRAME.
            -- Alle anderen Waffen sehen davon nichts (Tabelle gated).
            grip_on = true, grip_x = 0.0, grip_y = 0.0, grip_z = 0.0,
            -- [GRIP_SLIDE 2026-08-07] Gleitende Stuetzhand statt festgenagelter Punkt --
            -- so loesen es native VR-Shooter: die Hand haengt nicht an EINEM Punkt, sondern darf
            -- entlang der Waffenachse (Joint-Z, dieselbe wie der Pump-Zug) in einem Bereich
            -- gleiten. Reicht der Arm nicht, rutscht die Hand am Rohr zurueck statt neben die
            -- Waffe gezogen zu werden -- der Fehler liegt dann ENTLANG der Waffe (unsichtbar)
            -- statt Richtung Schulter (sichtbar daneben). Beide 0 = altes Verhalten, fester Punkt.
            grip_back = 0.0, grip_fwd = 0.0,
            grip_anchor = false,  -- [GRIP_ANCHOR_RH] Zusatz gegen Einfrieren beim Laufen
            grip_noroll = false,  -- [GRIP_NO_ROLL] Zusatz gegen Kreisen beim Rollen

        }
    end
    return support_offset[key]
end


-- [SUPPORT_AIM] OPTIONALES zweites Support-Offset PRO WAFFE fuer den Aim-Zustand.
-- Nur "Kipp"-Waffen brauchen es: beim Aim kippt die Waffe, das Idle-Dock passt dann
-- nicht mehr. Existiert KEIN Eintrag -> Waffe nutzt immer das Idle-Offset (unveraendert).
-- Wird per UI angelegt (vom Idle-Offset geseedet) und dann separat getunt.
local support_offset_aim = {}
local function get_support_offset_aim(key)   -- nil wenn nicht angelegt
    return support_offset_aim[key or WEAPON_NONE_KEY]
end
-- Aim-Offset anlegen (vom aktuellen Idle-Offset kopiert) bzw. entfernen.
local function ensure_support_offset_aim(key)
    key = key or WEAPON_NONE_KEY
    if not support_offset_aim[key] then
        local i = get_support_offset(key)
        support_offset_aim[key] = {
            pos_x = i.pos_x, pos_y = i.pos_y, pos_z = i.pos_z,
            rot_pitch = i.rot_pitch, rot_yaw = i.rot_yaw, rot_roll = i.rot_roll,
            blend_in = 0.18, blend_out = 0.18,   -- [SUPPORT_AIM] Ramp-Speed pro Waffe (no-aim->aim / aim->no-aim)
        }
    end
    return support_offset_aim[key]
end

-- [SWITCH_DOCK] LE5-exklusiv: zweites Dock-Ziel = Feuerwahl-Schalter (joint_05). Eigener
-- Offset + eigene Distanz (Hand -> Schalter). Bei Left-Grip dockt die Hand an den Schalter
-- statt an den Vordergriff, wenn die freie Hand in Schalter-Range ist (ueberschreibt den
-- Vordergriff-Dock). Pose wird spaeter separat gecaptured.
local SWITCH_DOCK_WEAPONS = { [4202] = true, [4201] = true }   -- LE5, Chicago Sweeper (gleiches System, eigene Offsets/Burst-Werte per-Waffe via UI/JSON)
-- [SWITCH ONE-SHOT] Waffen, bei denen nach JEDEM Umlegen die Hand SOFORT vom Schalter loest
-- (neuer Grip-Druck am Schalter noetig zum naechsten Umstellen). Chicago Sweeper = ja; LE5 = nein
-- (dort mehrfaches Umlegen pro gehaltenem Grip moeglich). Per-Waffe -> LE5 bleibt unveraendert.
local SWITCH_ONESHOT = { [4201] = true }
-- [FIRE_MODE] Pro Waffe der Schalter-Zyklus (geordnete Mode-Liste). 0=Full, 1=Burst, 2=Single.
-- LE5 hat 3 physische Stellungen (Full/Burst/Single), die Sweeper nur 2 (Full/Burst=Single via count).
local FIRE_MODE_CYCLE = {
    [4202] = { 0, 1, 2 },   -- LE5: Full -> Burst -> Single -> Full
    [4201] = { 0, 1 },      -- Chicago Sweeper: Full -> Burst(=Single via burst_count 1) -> Full
}
local function fire_mode_cycle(wid) return FIRE_MODE_CYCLE[wid] or { 0, 1, 2 } end
local function fire_mode_has_single(wid)
    for _, m in ipairs(fire_mode_cycle(wid)) do if m == 2 then return true end end
    return false
end
-- naechster Modus im Zyklus der Waffe (nach dem aktuellen). Faellt auf Full (0) zurueck.
local function fire_mode_next(wid, cur)
    local cyc = fire_mode_cycle(wid)
    for i, m in ipairs(cyc) do
        if m == cur then return cyc[(i % #cyc) + 1] end
    end
    return cyc[1] or 0
end
local support_offset_switch = {}
local function get_support_offset_switch(key)   -- nil wenn nicht angelegt
    return support_offset_switch[key or WEAPON_NONE_KEY]
end
local function ensure_support_offset_switch(key)
    key = key or WEAPON_NONE_KEY
    if not support_offset_switch[key] then
        support_offset_switch[key] = {
            pos_x = 0.0, pos_y = 0.0, pos_z = 0.0,
            rot_pitch = 0.0, rot_yaw = 0.0, rot_roll = 0.0,
            dock_dist = 0.060,    -- eng halten -> kein staendiges Hin-und-Her zwischen Schalter und Schaft
            blend_speed = 0.150,  -- eigener Lerp Schalter (hoeher = zackiger; Vordergriff nutzt support.blend_speed)
            idx_rx = 0.0, idx_ry = 0.0, idx_rz = 0.0,  -- additiver Zeigefinger-Curl fuer die "OK"-Geste
            burst_rot = 0.0,  -- [BURST] Schalter-Hebel-Rotation (joint_05) = Burst-Fire-Position (Grad, Pitch)
            burst_count = 3,  -- [BURST] Schuss pro Trigger-Zug im Burst-Modus
            single_rot = 0.0, -- [FIRE_MODE] Schalter-Hebel-Rotation = Single-Fire-Position (Grad, Pitch)
            lever_lerp = 0.18,-- [FIRE_MODE] Lerp-Faktor der Hebel-Schwenk-Anim beim Umstellen (kleiner = geschmeidiger/langsamer)
        }
    end
    return support_offset_switch[key]
end
-- [SWITCH_DOCK] OPTIONALES zweites Switch-Offset fuer den AIM-Zustand (analog support_offset_aim,
-- aber fuer den Schalter-Dock). Existiert kein Eintrag -> der Schalter nutzt immer das Idle-Switch-
-- Offset (kein Aim-Blend). Pose bleibt dieselbe; nur Position/Rotation blendet.
local support_offset_switch_aim = {}
local function get_support_offset_switch_aim(key)
    return support_offset_switch_aim[key or WEAPON_NONE_KEY]
end
local function ensure_support_offset_switch_aim(key)
    key = key or WEAPON_NONE_KEY
    if not support_offset_switch_aim[key] then
        local i = get_support_offset_switch(key) or {}
        support_offset_switch_aim[key] = {
            pos_x = i.pos_x or 0.0, pos_y = i.pos_y or 0.0, pos_z = i.pos_z or 0.0,
            rot_pitch = i.rot_pitch or 0.0, rot_yaw = i.rot_yaw or 0.0, rot_roll = i.rot_roll or 0.0,
            blend_in = 0.18, blend_out = 0.18,
        }
    end
    return support_offset_switch_aim[key]
end

-- [SWITCH_DOCK2] OPTIONALES zweites Switch-Offset-Paar fuer die ZWEITE Hebel-Stellung
-- (burst_active = Single/Burst-Position). Manche Waffen (z.B. Chicago Sweeper) brauchen je
-- Hebelstellung eine eigene Hand-Pose, weil der rigide 1:1-Pivot-Follow sonst komisch aussieht.
-- Existiert KEIN Eintrag (z.B. LE5) -> es bleibt beim einen Paar + 1:1-Pivot-Follow (unveraendert).
-- support_offset_switch2 = no-aim, support_offset_switch2_aim = aim. Nur pos/rot; dock_dist/Finger/
-- burst-Werte bleiben im ersten Paar (support_offset_switch).
local support_offset_switch2 = {}
local function get_support_offset_switch2(key)
    return support_offset_switch2[key or WEAPON_NONE_KEY]
end
local function ensure_support_offset_switch2(key)
    key = key or WEAPON_NONE_KEY
    if not support_offset_switch2[key] then
        local i = get_support_offset_switch(key) or {}
        support_offset_switch2[key] = {
            pos_x = i.pos_x or 0.0, pos_y = i.pos_y or 0.0, pos_z = i.pos_z or 0.0,
            rot_pitch = i.rot_pitch or 0.0, rot_yaw = i.rot_yaw or 0.0, rot_roll = i.rot_roll or 0.0,
            lerp = 0.15,   -- [SWITCH_DOCK2] Pose1<->Pose2 Blend-Speed (hoeher = schneller; gilt no-aim + aim)
        }
    end
    return support_offset_switch2[key]
end
local support_offset_switch2_aim = {}
local function get_support_offset_switch2_aim(key)
    return support_offset_switch2_aim[key or WEAPON_NONE_KEY]
end
local function ensure_support_offset_switch2_aim(key)
    key = key or WEAPON_NONE_KEY
    if not support_offset_switch2_aim[key] then
        local i = get_support_offset_switch2(key) or {}
        support_offset_switch2_aim[key] = {
            pos_x = i.pos_x or 0.0, pos_y = i.pos_y or 0.0, pos_z = i.pos_z or 0.0,
            rot_pitch = i.rot_pitch or 0.0, rot_yaw = i.rot_yaw or 0.0, rot_roll = i.rot_roll or 0.0,
        }
    end
    return support_offset_switch2_aim[key]
end

local function read_config_raw()
    local f = io.open(CONFIG_FILE, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(json.load_string, content)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

local function write_config_raw(data)
    local ok, str = pcall(json.dump_string, data)
    if not ok or not str then return false end
    local f = io.open(CONFIG_FILE, "w")
    if not f then return false end
    f:write(str)
    f:close()
    return true
end

local function load_config()
    local data = read_config_raw()
    -- [ADA_KNIFE_RELFIX] Marker: wurde Adas Messer-Kalibrierung schon einmal um 180 Grad gedreht?
    -- Ohne den wuerde die Migration bei jedem Script-Reset erneut drehen und damit zurueckdrehen.
    if data.knife_relfix_ada == true then _G.__re4_ada_relfix = true end
    if data.knife_relfix_ada2 == true then _G.__re4_ada_relfix2 = true end   -- [ADA_KNIFE_RELFIX_2]
    if data.knife_relfix_ada3 == true then _G.__re4_ada_relfix3 = true end   -- [ADA_KNIFE_RELFIX_3]
    if type(data.knife_swing_threshold) == "number" then   -- [KNIFE_SWING] persistierte Schwung-Schwelle
        _G.__re4_knife_swing_threshold = data.knife_swing_threshold
    end
    if type(data.pose_fade_dur) == "number" then _G.__re4_pose_fade_dur = data.pose_fade_dur end   -- [POSE_FADE]
    if type(data.knife_touch) == "number" then   -- [KNIFE_BREAK] persistierte Break-Reichweite
        _G.__re4_knife_touch = data.knife_touch
    end
    if type(data.knife_reach) == "number" then _G.__re4_knife_reach = data.knife_reach end   -- [KNIFE_REACH] Stich-Gegner-Radius
    if type(data.knife_throw_threshold) == "number" then _G.__re4_knife_throw_threshold = data.knife_throw_threshold end   -- [KNIFE_THROW] Wurf-Schwelle
    if type(data.knife_flip_speed) == "number" then _G.__re4_knife_flip_speed = data.knife_flip_speed end
    -- [SKULL_SPIN_ENTFERNT 2026-07-31, "bau den ganzen Quatsch raus"] skull_spread_from/to und
    -- skull_spin_keys werden nicht mehr geladen (Spin, Keyframes und Griffpose sind ausgebaut).
    if type(data.knife_flip_finger_deg) == "number" then _G.__re4_knife_flip_finger_deg = data.knife_flip_finger_deg end   -- [KNIFE_FLIP] Finger-Oeffnung
    if type(data.knife_flip_pos_x) == "number" then _G.__re4_knife_flip_pos_x = data.knife_flip_pos_x end   -- [KNIFE_FLIP] X-Versatz
    if type(data.knife_flip_pos_y) == "number" then _G.__re4_knife_flip_pos_y = data.knife_flip_pos_y end   -- [KNIFE_FLIP] Y-Versatz
    if type(data.knife_flip_pos_z) == "number" then _G.__re4_knife_flip_pos_z = data.knife_flip_pos_z end   -- [KNIFE_FLIP] Z-Versatz
    if type(data.knife_flip_pos) == "table" then   -- [KNIFE_FLIP] PRO-MESSER Griff-Offset (map wid->{x,y,z})
        local m = {}
        for k, v in pairs(data.knife_flip_pos) do
            local id = tonumber(k)
            if id and type(v) == "table" then
                m[id] = { x = tonumber(v.x) or 0.0, y = tonumber(v.y) or 0.0, z = tonumber(v.z) or 0.0 }
            end
        end
        _G.__re4_knife_flip_pos_map = m
    end
    if type(data.knife_flip_pos_ada) == "table" then   -- [KNIFE_FLIP_ADA]
        local m = {}
        for k, v in pairs(data.knife_flip_pos_ada) do
            local id = tonumber(k)
            if id and type(v) == "table" then
                m[id] = { x = tonumber(v.x) or 0.0, y = tonumber(v.y) or 0.0, z = tonumber(v.z) or 0.0 }
            end
        end
        _G.__re4_knife_flip_pos_map_ada = m
    end
    if type(data.knife_fly) == "table" then   -- [KNIFE_THROW] Flug-Tuning (Flugdauer/Rueckkehr/Speed)
        local d = data.knife_fly
        local fc = rawget(_G, "__re4_knife_fly_cfg")
            or { speed = 12.0, gravity = 7.0, spin = 18.0, max_time = 1.5, return_delay = 0.4 }
        if type(d.max_time) == "number" then fc.max_time = d.max_time end
        if type(d.return_delay) == "number" then fc.return_delay = d.return_delay end
        if type(d.hit_return_delay) == "number" then fc.hit_return_delay = d.hit_return_delay end   -- [STECKZEIT] nach Treffer
        if type(d.speed) == "number" then fc.speed = d.speed end
        if type(d.hit_radius) == "number" then fc.hit_radius = d.hit_radius end
        if type(d.break_radius) == "number" then fc.break_radius = d.break_radius end   -- [WURF-OBJEKTRADIUS] Kisten/Vasen
        if type(d.spin) == "number" then fc.spin = d.spin end
        if type(d.spin_fly) == "number" then fc.spin_fly = d.spin_fly end    -- [SALTO] vor Treffer
        if type(d.spin_fall) == "number" then fc.spin_fall = d.spin_fall end  -- [SALTO] beim Fallen
        if type(d.dir_max_deg) == "number" then fc.dir_max_deg = d.dir_max_deg end          -- [RICHTUNGS-CLAMP]
        if type(d.hmd_force) == "boolean" then fc.hmd_force = d.hmd_force end                 -- [HMD_CAL] Force-HMD-Wurf an/aus
        if type(d.hmd_yaw) == "number" then fc.hmd_yaw = d.hmd_yaw end                        -- [HMD_CAL] Yaw-Korrektur (Grad)
        if type(d.hmd_pitch) == "number" then fc.hmd_pitch = d.hmd_pitch end                  -- [HMD_CAL] Pitch-Korrektur (Grad)
        if type(d.assist_strength) == "number" then fc.assist_strength = d.assist_strength end   -- [ZIELHILFE A]
        if type(d.assist_homing) == "number" then fc.assist_homing = d.assist_homing end         -- [ZIELHILFE B] In-Flug-Homing
        if type(d.assist_cone_deg) == "number" then fc.assist_cone_deg = d.assist_cone_deg end   -- [ZIELHILFE]
        if type(d.assist_cone_inner_deg) == "number" then fc.assist_cone_inner_deg = d.assist_cone_inner_deg end   -- [KEGEL] Voll-Lock-Winkel
        if type(d.assist_min_lat) == "number" then fc.assist_min_lat = d.assist_min_lat end       -- [ZIELWAHL] Nahbereich-Breite (m)
        if type(d.close_hit_radius) == "number" then fc.close_hit_radius = d.close_hit_radius end -- [TOTZONE] Nahtreffer-Radius (m)
        if type(d.assist_target_off_y) == "number" then fc.assist_target_off_y = d.assist_target_off_y end   -- [CENTER] Ziel-Hoehen-Offset
        if type(d.assist_flatten) == "number" then fc.assist_flatten = d.assist_flatten end       -- [ZIELHILFE] Bogen-Ausgleich
        if type(d.max_range) == "number" then fc.max_range = d.max_range end                        -- [WURF_RANGE] max Wurfweite
        if type(d.spin_ax) == "number" then fc.spin_ax = d.spin_ax end                      -- [SALTO] freie Achse
        if type(d.spin_ay) == "number" then fc.spin_ay = d.spin_ay end
        if type(d.spin_az) == "number" then fc.spin_az = d.spin_az end
        if type(d.spin_ax_l) == "number" then fc.spin_ax_l = d.spin_ax_l end                 -- [SALTO_L] Links-Wurf-Achse (separat)
        if type(d.spin_ay_l) == "number" then fc.spin_ay_l = d.spin_ay_l end
        if type(d.spin_az_l) == "number" then fc.spin_az_l = d.spin_az_l end
        if type(d.v_min) == "number" then fc.v_min = d.v_min end   -- [WURF_RANGE]
        if type(d.v_max) == "number" then fc.v_max = d.v_max end
        _G.__re4_knife_fly_cfg = fc
    end
    if type(data.knife_land) == "table" then   -- [LANDE_POSE] persistierte Lande-Rotation
        local dl = data.knife_land
        local lr = rawget(_G, "__re4_knife_land_rot") or { rx = 1.5708, ry = 0.0, rz = 0.0 }
        if type(dl.rx) == "number" then lr.rx = dl.rx end
        if type(dl.ry) == "number" then lr.ry = dl.ry end
        if type(dl.rz) == "number" then lr.rz = dl.rz end
        _G.__re4_knife_land_rot = lr
    end
    if type(data.controller_type) == "string" then
        local c = data.controller_type
        if c == "steamvr" or c == "metavr" then
            selected_controller = c
        end
    end
    if type(data.openxr_correction) == "table" then
        for _, k in ipairs({ "pos_x", "pos_y", "pos_z", "rot_pitch", "rot_yaw", "rot_roll" }) do
            if type(data.openxr_correction[k]) == "number" then
                openxr_correction[k] = data.openxr_correction[k]
            end
        end
    end
    if type(data.ctrl_correction) == "table" then
        for _, k in ipairs({ "pos_x", "pos_y", "pos_z", "rot_pitch", "rot_yaw", "rot_roll" }) do
            if type(data.ctrl_correction[k]) == "number" then
                ctrl_correction[k] = data.ctrl_correction[k]
            end
        end
    end
    -- Linke Hand (global)
    if type(data.left_hand_offset) == "table" then
        for _, k in ipairs({ "px", "py", "pz", "rx", "ry", "rz" }) do
            if type(data.left_hand_offset[k]) == "number" then hand_offset.L[k] = data.left_hand_offset[k] end
        end
    end
    -- [SUPPORT_HAND] Offset pro Waffe (ungetunte Waffen = 0)
    if type(data.support_offset) == "table" then
        for key, s in pairs(data.support_offset) do
            if type(s) == "table" then
                local off = get_support_offset(tostring(key))
                for _, k in ipairs({ "pos_x", "pos_y", "pos_z", "rot_pitch", "rot_yaw", "rot_roll", "dock_threshold", "undock_threshold",
                                     "grip_x", "grip_y", "grip_z", "grip_back", "grip_fwd" }) do   -- [PUMP_GRIP]/[GRIP_SLIDE]
                    if type(s[k]) == "number" then off[k] = s[k] end
                end
                if type(s.grip_on) == "boolean" then off.grip_on = s.grip_on end   -- [PUMP_GRIP]
                if type(s.grip_anchor) == "boolean" then off.grip_anchor = s.grip_anchor end
                if type(s.grip_noroll) == "boolean" then off.grip_noroll = s.grip_noroll end
            end
        end
    end
    -- [SUPPORT_AIM] optionale Aim-Support-Offsets pro Waffe laden (nur falls vorhanden)
    if type(data.support_offset_aim) == "table" then
        for key, s in pairs(data.support_offset_aim) do
            if type(s) == "table" then
                local off = ensure_support_offset_aim(tostring(key))
                for _, k in ipairs({ "pos_x", "pos_y", "pos_z", "rot_pitch", "rot_yaw", "rot_roll", "blend_in", "blend_out" }) do
                    if type(s[k]) == "number" then off[k] = s[k] end
                end
            end
        end
    end
    -- [SWITCH_DOCK] optionale Schalter-Dock-Offsets pro Waffe laden (nur falls vorhanden)
    if type(data.support_offset_switch) == "table" then
        for key, s in pairs(data.support_offset_switch) do
            if type(s) == "table" then
                local off = ensure_support_offset_switch(tostring(key))
                for _, k in ipairs({ "pos_x", "pos_y", "pos_z", "rot_pitch", "rot_yaw", "rot_roll", "dock_dist", "blend_speed", "idx_rx", "idx_ry", "idx_rz", "burst_rot", "burst_count", "single_rot", "lever_lerp" }) do
                    if type(s[k]) == "number" then off[k] = s[k] end
                end
            end
        end
    end
    -- [SWITCH_DOCK] optionale Switch-Aim-Offsets pro Waffe laden (nur falls vorhanden)
    if type(data.support_offset_switch_aim) == "table" then
        for key, s in pairs(data.support_offset_switch_aim) do
            if type(s) == "table" then
                local off = ensure_support_offset_switch_aim(tostring(key))
                for _, k in ipairs({ "pos_x", "pos_y", "pos_z", "rot_pitch", "rot_yaw", "rot_roll", "blend_in", "blend_out" }) do
                    if type(s[k]) == "number" then off[k] = s[k] end
                end
            end
        end
    end
    -- [SWITCH_DOCK2] zweites Switch-Offset-Paar (Single/Burst-Stellung) laden
    if type(data.support_offset_switch2) == "table" then
        for key, s in pairs(data.support_offset_switch2) do
            if type(s) == "table" then
                local off = ensure_support_offset_switch2(tostring(key))
                for _, k in ipairs({ "pos_x", "pos_y", "pos_z", "rot_pitch", "rot_yaw", "rot_roll", "lerp" }) do
                    if type(s[k]) == "number" then off[k] = s[k] end
                end
            end
        end
    end
    if type(data.support_offset_switch2_aim) == "table" then
        for key, s in pairs(data.support_offset_switch2_aim) do
            if type(s) == "table" then
                local off = ensure_support_offset_switch2_aim(tostring(key))
                for _, k in ipairs({ "pos_x", "pos_y", "pos_z", "rot_pitch", "rot_yaw", "rot_roll" }) do
                    if type(s[k]) == "number" then off[k] = s[k] end
                end
            end
        end
    end
    if type(data.support_cfg) == "table" then
        if data.support_cfg.enabled ~= nil then support.enabled = data.support_cfg.enabled == true end
        if type(data.support_cfg.blend_speed) == "number" then support.blend_speed = data.support_cfg.blend_speed end
        if type(data.support_cfg.grip_latch_reach) == "number" then support.grip_latch_reach = data.support_cfg.grip_latch_reach end
    end
    if type(data.hand_smooth_rot) == "number" then rot_smooth.hands = data.hand_smooth_rot end
    if type(data.hand_smooth_pos) == "number" then pos_smooth.hands = data.hand_smooth_pos end
    if type(data.ks4_exit_fade) == "number" then _G.__re4_ks4fade.dur = data.ks4_exit_fade end   -- [KS4_EXIT_FADE]
    -- Rechte Hand: per-Waffe (Key = Weapon-ID als String). Null-Default-Eintraege
    -- NICHT laden (Junk vermeiden) -> ungetunte Waffen bleiben implizit auf 0.
    if type(data.weapon_offset) == "table" then
        for key, s in pairs(data.weapon_offset) do
            if type(s) == "table" then
                local tmp = new_weapon_offset()
                for _, k in ipairs({ "px", "py", "pz", "rx", "ry", "rz" }) do
                    if type(s[k]) == "number" then tmp[k] = s[k] end
                end
                if not wo_is_default(tmp) then weapon_offset[tostring(key)] = tmp end
            end
        end
    end
    weapon_offset["4004_stock"] = nil   -- [MATILDA_STOCK] alter Hand-Key aus fruehem Ansatz -> aufraeumen (jetzt "4004_stockwep", waffe-only)
    -- [WEP_REL_PERSIST] eingefrorene Kalibrierungen laden
    if type(data.weapon_rel) == "table" then
        for key, s in pairs(data.weapon_rel) do
            if type(s) == "table" and type(s.px) == "number" and type(s.qw) == "number" then
                weapon_rel[tostring(key)] = {
                    px = s.px, py = s.py, pz = s.pz,
                    qx = s.qx, qy = s.qy, qz = s.qz, qw = s.qw,
                }
            end
        end
    end
    -- [TWO_HAND_IK] Tunings laden
    if type(data.two_hand_cfg) == "table" then
        local th = data.two_hand_cfg
        if th.enabled ~= nil then two_hand.enabled = th.enabled == true end
        for _, k in ipairs({ "min_dist", "max_dist", "blend_speed", "pitch", "yaw", "roll" }) do
            if type(th[k]) == "number" then two_hand[k] = th[k] end
        end
        -- [MIGRATION] alter blend_speed-Default (0.10, nie per UI gesetzt) -> sanfterer neuer Default
        if two_hand.blend_speed == 0.10 then two_hand.blend_speed = 0.05 end
    end
end

local function save_config()
    local data = read_config_raw()
    data.controller_type = selected_controller
    data.knife_swing_threshold = rawget(_G, "__re4_knife_swing_threshold") or 3.5   -- [KNIFE_SWING] Slider-Wert
    data.pose_fade_dur = rawget(_G, "__re4_pose_fade_dur") or 0.10   -- [POSE_FADE] Rueckblend-Dauer der Hand-Posen
    data.knife_touch = rawget(_G, "__re4_knife_touch") or 0.90   -- [KNIFE_BREAK] Break-Reichweite
    data.knife_reach = rawget(_G, "__re4_knife_reach") or 0.90   -- [KNIFE_REACH] Stich-Gegner-Radius
    data.knife_throw_threshold = rawget(_G, "__re4_knife_throw_threshold") or 4.0   -- [KNIFE_THROW] Wurf-Schwelle
    data.knife_flip_speed = rawget(_G, "__re4_knife_flip_speed") or 0.18   -- [KNIFE_FLIP] Lerp-Tempo des 180°-Flips
    -- [SKULL_SPIN_ENTFERNT 2026-07-31] skull_spread_from/to + skull_spin_keys werden nicht mehr
    -- geschrieben; alte Eintraege in re4_vr_motion.json fallen beim naechsten Speichern raus.
    data.knife_flip_finger_deg = rawget(_G, "__re4_knife_flip_finger_deg") or -35.0   -- [KNIFE_FLIP] Finger-Oeffnung waehrend des Flips
    data.knife_flip_pos_x = rawget(_G, "__re4_knife_flip_pos_x") or 0.0   -- [KNIFE_FLIP] X-Versatz im Flip (Hand-Frame)
    data.knife_flip_pos_y = rawget(_G, "__re4_knife_flip_pos_y") or 0.0   -- [KNIFE_FLIP] Y-Versatz im Flip (Hand-Frame)
    data.knife_flip_pos_z = rawget(_G, "__re4_knife_flip_pos_z") or 0.0   -- [KNIFE_FLIP] Z-Versatz im Flip (Hand-Frame)
    do   -- [KNIFE_FLIP] PRO-MESSER Griff-Offset persistieren (map wid->{x,y,z}, JSON-Key = tostring(wid))
        local m = rawget(_G, "__re4_knife_flip_pos_map")
        if type(m) == "table" then
            local out = {}
            for id, v in pairs(m) do
                if type(v) == "table" then out[tostring(id)] = { x = v.x or 0.0, y = v.y or 0.0, z = v.z or 0.0 } end
            end
            data.knife_flip_pos = out
        end
    end
    do   -- [KNIFE_FLIP_ADA] Adas eigene Rechts-Flip-Map unter eigenem JSON-Key
        local m = rawget(_G, "__re4_knife_flip_pos_map_ada")
        if type(m) == "table" then
            local out = {}
            for id, v in pairs(m) do
                if type(v) == "table" then out[tostring(id)] = { x = v.x or 0.0, y = v.y or 0.0, z = v.z or 0.0 } end
            end
            data.knife_flip_pos_ada = out
        end
    end
    data.knife_relfix_ada = rawget(_G, "__re4_ada_relfix") == true   -- [ADA_KNIFE_RELFIX] einmalig-Marker
    data.knife_relfix_ada2 = rawget(_G, "__re4_ada_relfix2") == true -- [ADA_KNIFE_RELFIX_2] einmalig-Marker
    data.knife_relfix_ada3 = rawget(_G, "__re4_ada_relfix3") == true -- [ADA_KNIFE_RELFIX_3] einmalig-Marker
    do   -- [KNIFE_THROW] Flug-Tuning persistieren
        local fc = rawget(_G, "__re4_knife_fly_cfg")
        if type(fc) == "table" then
            data.knife_fly = { max_time = fc.max_time, return_delay = fc.return_delay, hit_return_delay = fc.hit_return_delay, speed = fc.speed,
                hit_radius = fc.hit_radius, break_radius = fc.break_radius,   -- [WURF-OBJEKTRADIUS]
                spin = fc.spin, spin_fly = fc.spin_fly, spin_fall = fc.spin_fall,
                dir_max_deg = fc.dir_max_deg, spin_ax = fc.spin_ax, spin_ay = fc.spin_ay, spin_az = fc.spin_az,
                spin_ax_l = fc.spin_ax_l, spin_ay_l = fc.spin_ay_l, spin_az_l = fc.spin_az_l,   -- [SALTO_L] Links-Wurf-Achse

                hmd_force = fc.hmd_force, hmd_yaw = fc.hmd_yaw, hmd_pitch = fc.hmd_pitch,   -- [HMD_CAL]
                assist_strength = fc.assist_strength, assist_homing = fc.assist_homing, assist_cone_deg = fc.assist_cone_deg, assist_cone_inner_deg = fc.assist_cone_inner_deg, assist_target_off_y = fc.assist_target_off_y, assist_flatten = fc.assist_flatten,
                max_range = fc.max_range,
                assist_min_lat = fc.assist_min_lat,       -- [ZIELWAHL] Nahbereich-Breite (m) um die Blickachse
                close_hit_radius = fc.close_hit_radius,   -- [TOTZONE] Nahtreffer-Radius (m)
                v_min = fc.v_min, v_max = fc.v_max }
        end
        local lr = rawget(_G, "__re4_knife_land_rot")   -- [LANDE_POSE] persistieren
        if type(lr) == "table" then data.knife_land = { rx = lr.rx, ry = lr.ry, rz = lr.rz } end
    end
    data.openxr_correction = {
        pos_x = openxr_correction.pos_x,
        pos_y = openxr_correction.pos_y,
        pos_z = openxr_correction.pos_z,
        rot_pitch = openxr_correction.rot_pitch,
        rot_yaw = openxr_correction.rot_yaw,
        rot_roll = openxr_correction.rot_roll,
    }
    data.ctrl_correction = {
        pos_x = ctrl_correction.pos_x,
        pos_y = ctrl_correction.pos_y,
        pos_z = ctrl_correction.pos_z,
        rot_pitch = ctrl_correction.rot_pitch,
        rot_yaw = ctrl_correction.rot_yaw,
        rot_roll = ctrl_correction.rot_roll,
    }
    data.left_hand_offset = {
        px = hand_offset.L.px, py = hand_offset.L.py, pz = hand_offset.L.pz,
        rx = hand_offset.L.rx, ry = hand_offset.L.ry, rz = hand_offset.L.rz,
    }
    local so = {}
    for key, off in pairs(support_offset) do
        -- Null-Default-Eintraege NICHT schreiben (Cleanup): pos/rot=0 + Default-Thresholds
        local def = off.pos_x == 0 and off.pos_y == 0 and off.pos_z == 0
            and off.rot_pitch == 0 and off.rot_yaw == 0 and off.rot_roll == 0
            and (off.dock_threshold == nil or off.dock_threshold == 0.11)
            and (off.undock_threshold == nil or off.undock_threshold == 0.15)
            -- [PUMP_GRIP] mit im Default-Check, sonst faellt ein getunter Griff beim Cleanup raus
            and (off.grip_x or 0) == 0 and (off.grip_y or 0) == 0 and (off.grip_z or 0) == 0
            and (off.grip_back or 0) == 0 and (off.grip_fwd or 0) == 0
            and off.grip_anchor ~= true and off.grip_noroll ~= true
            and off.grip_on ~= false
        if not def then
            so[key] = {
                pos_x = off.pos_x, pos_y = off.pos_y, pos_z = off.pos_z,
                rot_pitch = off.rot_pitch, rot_yaw = off.rot_yaw, rot_roll = off.rot_roll,
                dock_threshold = off.dock_threshold, undock_threshold = off.undock_threshold,
                grip_on = off.grip_on, grip_x = off.grip_x, grip_y = off.grip_y, grip_z = off.grip_z,  -- [PUMP_GRIP]
                grip_back = off.grip_back, grip_fwd = off.grip_fwd,  -- [GRIP_SLIDE]
                grip_anchor = off.grip_anchor, grip_noroll = off.grip_noroll,
            }
        end
    end
    data.support_offset = so
    -- [SUPPORT_AIM] optionale Aim-Support-Offsets speichern (nur angelegte Waffen)
    local soa = {}
    for key, off in pairs(support_offset_aim) do
        soa[key] = {
            pos_x = off.pos_x, pos_y = off.pos_y, pos_z = off.pos_z,
            rot_pitch = off.rot_pitch, rot_yaw = off.rot_yaw, rot_roll = off.rot_roll,
            blend_in = off.blend_in, blend_out = off.blend_out,
        }
    end
    data.support_offset_aim = soa
    -- [SWITCH_DOCK] Schalter-Dock-Offsets speichern (nur angelegte Waffen)
    local sos = {}
    for key, off in pairs(support_offset_switch) do
        sos[key] = {
            pos_x = off.pos_x, pos_y = off.pos_y, pos_z = off.pos_z,
            rot_pitch = off.rot_pitch, rot_yaw = off.rot_yaw, rot_roll = off.rot_roll,
            dock_dist = off.dock_dist, blend_speed = off.blend_speed,
            idx_rx = off.idx_rx, idx_ry = off.idx_ry, idx_rz = off.idx_rz,
            burst_rot = off.burst_rot,
            burst_count = off.burst_count,
            single_rot = off.single_rot,
            lever_lerp = off.lever_lerp,
        }
    end
    data.support_offset_switch = sos
    -- [SWITCH_DOCK] Switch-Aim-Offsets speichern (nur angelegte Waffen)
    local ssa = {}
    for key, off in pairs(support_offset_switch_aim) do
        ssa[key] = {
            pos_x = off.pos_x, pos_y = off.pos_y, pos_z = off.pos_z,
            rot_pitch = off.rot_pitch, rot_yaw = off.rot_yaw, rot_roll = off.rot_roll,
            blend_in = off.blend_in, blend_out = off.blend_out,
        }
    end
    data.support_offset_switch_aim = ssa
    -- [SWITCH_DOCK2] zweites Switch-Offset-Paar (Single/Burst-Stellung) speichern
    local ss2 = {}
    for key, off in pairs(support_offset_switch2) do
        ss2[key] = {
            pos_x = off.pos_x, pos_y = off.pos_y, pos_z = off.pos_z,
            rot_pitch = off.rot_pitch, rot_yaw = off.rot_yaw, rot_roll = off.rot_roll,
            lerp = off.lerp,
        }
    end
    data.support_offset_switch2 = ss2
    local ss2a = {}
    for key, off in pairs(support_offset_switch2_aim) do
        ss2a[key] = {
            pos_x = off.pos_x, pos_y = off.pos_y, pos_z = off.pos_z,
            rot_pitch = off.rot_pitch, rot_yaw = off.rot_yaw, rot_roll = off.rot_roll,
        }
    end
    data.support_offset_switch2_aim = ss2a
    data.support_cfg = {
        enabled = support.enabled,
        blend_speed = support.blend_speed,
        grip_latch_reach = support.grip_latch_reach,   -- [GRIP_LATCH_REACH]
    }
    data.hand_smooth_rot = rot_smooth.hands
    data.hand_smooth_pos = pos_smooth.hands
    data.ks4_exit_fade = _G.__re4_ks4fade.dur   -- [KS4_EXIT_FADE]
    local wo = {}
    for key, off in pairs(weapon_offset) do
        if not wo_is_default(off) then   -- Null-Default-Eintraege NICHT schreiben (Cleanup)
            wo[key] = { px = off.px, py = off.py, pz = off.pz,
                        rx = off.rx, ry = off.ry, rz = off.rz }
        end
    end
    data.weapon_offset = wo
    -- [WEP_REL_PERSIST] eingefrorene Hand->Waffe-Kalibrierungen speichern
    local wr = {}
    for key, r in pairs(weapon_rel) do
        wr[key] = { px = r.px, py = r.py, pz = r.pz,
                    qx = r.qx, qy = r.qy, qz = r.qz, qw = r.qw }
    end
    data.weapon_rel = wr
    -- [TWO_HAND_IK] Tunings speichern
    data.two_hand_cfg = {
        enabled = two_hand.enabled,
        min_dist = two_hand.min_dist, max_dist = two_hand.max_dist,
        blend_speed = two_hand.blend_speed,
        pitch = two_hand.pitch, yaw = two_hand.yaw, roll = two_hand.roll,
    }
    -- Alt-Feld aus dem frueheren Schema entfernen, falls noch vorhanden.
    data.hand_offset = nil
    write_config_raw(data)
end

load_config()

-- =====================================================================
-- [ADA_KNIFE_RELFIX 2026-07-19] Adas Messer-Kalibrierung um 180 Grad drehen
-- =====================================================================
-- BEFUND: weapon_rel["6108@ada"] (die EINGEFRORENE Hand->Waffe-Kalibrierung) wurde in VERDREHTER
-- Lage eingefangen -- die dokumentierte Falle "live gemessene Nulllagen fangen Engine-State ein".
-- Folge: der Ruhezustand (knife_flip.lerp = 0) zeigt das Messer VERKEHRT herum, erst der 180-Grad-
-- Flip dreht es richtig. Bewiesen im Flip-Log: 669 von 689 Zeilen mit lerp = 1.000.
--
-- Daraus entstanden DREI Symptome aus EINER Wurzel:
-- 1. die Flip-Slider wirkten auf den "normalen" Zustand (der technisch der Flip-Zustand ist)
-- 2. normale und Flip-Offsets koppelten sich gegenseitig
-- 3. DER WURF WAR TOT: re4_vr_weapons.lua:3507 sperrt das Wurf-Windup im Flip
-- (`gripping =... and (not flipped)...`) -> bei dauerhaftem Flip nie eine Loslass-Flanke.
--
-- FIX: rel_rot einmalig mit dem Flip verrechnen. Der Flip wird POST-multipliziert
-- (wrot = (hand_rot * rel_rot) * flip), also gilt rel_rot_neu = rel_rot_alt * flip.
-- Fuer flip = 180 Grad um X = Quaternion(w=0, x=1, y=0, z=0) reduziert sich das exakt auf:
-- (w, x, y, z) -> (-x, w, z, -y)
-- RECHNERISCH, nicht neu eingemessen -- neu messen wuerde denselben Engine-State wieder einfangen.
--
-- Einmalig ueber den Marker "knife_relfix_ada" (zweimal 180 Grad waere wieder verdreht).
-- LEON-NEUTRAL: greift ausschliesslich auf den Schluessel "6108@ada" (Adas Elite Knife).
if rawget(_G, "__re4_ada_relfix") ~= true then
    local r = weapon_rel["6108@ada"]
    if r and r.qw and r.qx and r.qy and r.qz then
        local w, x, y, z = r.qw, r.qx, r.qy, r.qz
        r.qw, r.qx, r.qy, r.qz = -x, w, z, -y
    end
    _G.__re4_ada_relfix = true
    pcall(save_config)   -- Marker + gedrehten Wert sofort festschreiben
end

-- [ADA_KNIFE_RELFIX_2 2026-07-20] "Bei Adas ANDEREN Messern genauso -- aber nur bei ihr."
-- Dieselbe Wurzel, dieselbe Rechnung, EIGENER Marker (sonst wuerde 6108 ein zweites Mal gedreht
-- = wieder verdreht). Aktuell existiert genau ein weiterer Ada-Key; kommen spaeter welche dazu,
-- gehoeren sie HIER in die Liste und der Marker unten muss hochgezaehlt werden (relfix2 -> 3).
-- LEON-NEUTRAL: ausschliesslich "@ada"-Schluessel, Leons Keys werden nie angefasst.
-- (Liste bewusst INLINE -- motion.lua steht am 200-Local-Limit, ein Top-Level-Local sprengt es.)
-- Marker-Kette: relfix = 6108, relfix2 = 5003, relfix3 = 5002 (Kitchen Knife). Jede Stufe dreht
-- NUR ihre eigenen Keys und genau EINMAL -- deshalb pro Nachzuegler ein neuer Marker statt Liste
-- erweitern (die alten Keys waeren sonst ein zweites Mal gedreht = wieder verkehrt herum).
if rawget(_G, "__re4_ada_relfix2") ~= true then
    for _, k in ipairs({ "5003@ada" }) do
        local r = weapon_rel[k]
        if r and r.qw and r.qx and r.qy and r.qz then
            local w, x, y, z = r.qw, r.qx, r.qy, r.qz
            r.qw, r.qx, r.qy, r.qz = -x, w, z, -y
        end
    end
    _G.__re4_ada_relfix2 = true
    pcall(save_config)
end

if rawget(_G, "__re4_ada_relfix3") ~= true then
    for _, k in ipairs({ "5002@ada" }) do   -- Kitchen Knife
        local r = weapon_rel[k]
        if r and r.qw and r.qx and r.qy and r.qz then
            local w, x, y, z = r.qw, r.qx, r.qy, r.qz
            r.qw, r.qx, r.qy, r.qz = -x, w, z, -y
        end
    end
    _G.__re4_ada_relfix3 = true
    pcall(save_config)
end


-- ---------------------------------------------------------------------
-- RE4 Player Body Discovery
-- ---------------------------------------------------------------------
local character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
local scene_td = sdk.find_type_definition("via.SceneManager")
local PLAYER_BODY_NAME = "ch0a0z0_body"

-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: einmal pro Frame aufloesen statt bei
-- jedem Aufruf. Semantik unveraendert, alter Weg bleibt als Fallback. NOT-AUS: `_G.__re4_fc_off = true`.
pcall(function() require("re4vr/re4_vr_frame_cache") end)

local function get_player_context()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.ctx() end
    if not character_manager then
        character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    if not character_manager then return nil end
    return sc(character_manager, "getPlayerContextRef")
end

local function get_scene()
    if not scene_td then return nil end
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    local ok, scene = pcall(function()
        return sdk.call_native_func(sm, scene_td, "get_CurrentScene")
    end)
    return ok and scene or nil
end

local function find_player_body()
    if body_cache.go then
        local valid = false
        pcall(function() valid = body_cache.go:get_Valid() end)
        if valid and body_cache.transform then return body_cache.transform end
    end
    body_cache.go = nil
    body_cache.transform = nil

    if re4 then
        local body = re4.body or re4.player
        if body then
            local tf = sc(body, "get_Transform")
            if tf then
                body_cache.go = body
                body_cache.transform = tf
                return tf
            end
        end
    end

    local scene = get_scene()
    if scene then
        local go = sc(scene, "findGameObject(System.String)", PLAYER_BODY_NAME)
        if go then
            local valid = false
            pcall(function() valid = go:get_Valid() end)
            if valid then
                local tf = sc(go, "get_Transform")
                if tf then
                    body_cache.go = go
                    body_cache.transform = tf
                    return tf
                end
            end
        end
    end

    return nil
end


-- ---------------------------------------------------------------------
-- Equipped Weapon ID (fuer per-Waffe Right-Hand Offset)
-- ---------------------------------------------------------------------
local function get_equip_weapon_id()
    local ctx = get_player_context()
    if not ctx then return nil end
    local h_updater = sc(ctx, "get_HeadUpdater")
    if not h_updater then return nil end
    local wid = sc(h_updater, "get_EquipWeaponID")
    if wid == nil then return nil end
    if type(wid) == "userdata" then
        local backing = sf(wid, "value__")
        if type(backing) == "number" then return backing end
    end
    if type(wid) == "number" then return wid end
    return nil
end

-- [RL_SHARE] Alle Rocket-Launcher-Varianten sind physisch identisch -> EINE gemeinsame Offset-Config.
-- Offset-Key auf 4900 normalisieren: support_offset/_aim/_switch + weapon_offset gelten damit fuer
-- 4900/4901/4902 gemeinsam (Tuning einer gilt fuer alle; kein JSON-Clobber durch fehlende per-Waffe-Eintraege).
local OFFSET_KEY_ALIAS = { [4901] = 4900, [4902] = 4900 }   -- 4901 RL Special, 4902 Infinite RL -> 4900
-- [KNIFE_WEP_ADA] Key fuer den WAFFE-only Messer-Offset (Messer relativ zur Hand).
-- Getrennt von "5001" (= Hand-Offset) und von "5001@ada" in weapon_rel (= Kalibrierung).
-- Als Global, weil motion.lua am 200-Local-Limit steht.
-- [KNIFE_FLIP_ADA] Rechts-Flip-Offsets pro Charakter: EIGENE Map fuer Ada statt Schluessel-Suffix.
-- Grund: diese Map ist NUMERISCH verschluesselt (m[kid]) und wird an mehreren Stellen so indiziert --
-- ein String-Suffix haette dort Typmischung erzeugt. Zwei Maps sind hier das kleinere Uebel.
-- Persistenz: "knife_flip_pos" (Leon) und "knife_flip_pos_ada" (Ada) in re4_vr_motion.json.
_G.__re4_knife_flip_map_r = _G.__re4_knife_flip_map_r or function()
    local fn = rawget(_G, "__re4_char_now")
    local ch = (type(fn) == "function") and fn() or nil
    if ch == "ada" then
        local m = rawget(_G, "__re4_knife_flip_pos_map_ada")
        if type(m) ~= "table" then m = {}; _G.__re4_knife_flip_pos_map_ada = m end
        return m, true
    end
    -- [ZURUECKGENOMMEN 2026-07-19] Hier stand ein Hard-Guard, der bei UNBEKANNTEM Charakter eine leere
    -- Scratch-Tabelle lieferte statt Leons Map. Das schuetzte zwar vor versehentlichem Schreiben, nahm
    -- aber LEON in genau diesen Frames seine Flip-Offsets weg (nil-Erkennung = Aussetzer, kommt vor).
    -- Lesen faellt deshalb wieder wie im Original auf Leons Map zurueck; das eigentliche Risiko war
    -- ohnehin nur das SCHREIBEN aus dem UI -- und das ist dort gegated (siehe UI-Block "Flip Griff-Offset").
    local m = rawget(_G, "__re4_knife_flip_pos_map")
    if type(m) ~= "table" then m = {}; _G.__re4_knife_flip_pos_map = m end
    return m, false
end

_G.__re4_knife_wep_key = _G.__re4_knife_wep_key or function(wid)
    local fn = rawget(_G, "__re4_char_now")
    local ch = (type(fn) == "function") and fn() or nil
    return tostring(wid) .. "_knifewep" .. ((ch == "ada") and "@ada" or "")
end
local function knife_wep_key(wid) return _G.__re4_knife_wep_key(wid) end

local function current_weapon_key()
    local wid = get_equip_weapon_id()
    if wid == nil then return WEAPON_NONE_KEY end
    wid = OFFSET_KEY_ALIAS[wid] or wid
    -- [KNIFE_ADA 2026-07-19] Hier BEWUSST KEIN Charakter-Suffix: dieser Key verschluesselt
    -- weapon_offset, und das wird auf die HAND angewandt (apply_hand_offset, ~Z.2019) -- nicht
    -- auf die Waffe. Ein Suffix haette hier zwei Schaeden angerichtet: es loest das eigentliche
    -- Problem nicht (Messer sitzt falsch IN der Hand), und ein neuer Key startet bei 0 -> der
    -- getunte Hand-Offset waere als Ada schlagartig weg.
    -- Die charakter-getrennte Messer-Lage gehoert an den WAFFEN-Offset, nicht hierher.
    return tostring(wid)
end


-- ---------------------------------------------------------------------
-- Joint Discovery
-- ---------------------------------------------------------------------
-- [LOGFLUT 2026-08-02] Gleiches Muster wie in arm_chain.lua: Die Gueltigkeit wird geprueft, indem
-- absichtlich get_Position aufgerufen wird. REFramework schreibt aber JEDE Engine-Exception SYNCHRON
-- ins Framework-Log -- in der Invoke-Schicht, also BEVOR unser pcall sie abfaengt. `pcall` verhindert
-- den Lua-Fehler, NICHT die Logzeile. Bei einem dauerhaft toten Joint sind das Hunderte Zeilen pro
-- Sekunde (gemessen: 665 in einer Sekunde, Log auf 10 MB), und waehrend die Platte beschrieben wird,
-- kommt der Script-Thread nicht hinterher -> Eingaben laufen ins Leere.
-- Logik unveraendert, nur die Haeufigkeit gedeckelt: ein eben noch ungueltiger Joint wird 0.5 s lang
-- nicht erneut angefasst. Wird er wieder gueltig, faellt er aus der Merkliste.
-- [LOGFLUT GEDROSSELT 2026-08-02] Gleiches Muster und gleicher Grund wie in arm_chain.lua: Der
-- Gueltigkeitstest ruft absichtlich get_Position auf, und REFramework schreibt jede Engine-Exception
-- SYNCHRON ins Log -- vor unserem pcall, das nur den Lua-Fehler abfaengt, nicht die Logzeile.
-- Ein eben noch ungueltiger Joint wird 0.5 s lang nicht erneut angefasst; ein gueltiger wird
-- weiterhin jeden Frame geprueft. Vom gegengetestet: kein spuerbarer Unterschied.
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

local function find_joints()
    local pt = find_player_body()
    if not pt then
        right_hand.joint = nil
        left_hand.joint = nil
        return
    end
    if not is_joint_valid(right_hand.joint) then
        right_hand.joint = sc(pt, "getJointByName", "R_Hand")
    end
    if not is_joint_valid(left_hand.joint) then
        left_hand.joint = sc(pt, "getJointByName", "L_Hand")
    end
end

-- [KILLSWITCH_RESTORE] Beim Killswitch hoeren motion/arm_chain auf zu schreiben. ABER:
-- write_joint_pose setzt das Hand-Joint per set_Position (Welt) -> die Engine speichert das
-- als LOCAL-Position des Hand-Joints. Die native Anim (z.B. Jump-Down ch0_357_JUMPDOWN)
-- animiert nur Knochen-ROTATIONEN, NIE die Knochen-Translation -> unsere verbogene Hand-
-- Local-Position bleibt kleben und der Unterarm streckt sich gummiartig zur eingefrorenen
-- Hand (Stretch, konstant ~0.4 m statt ~0.23 m Knochenlaenge, eingefroren ueber die ganze
-- Nicht-Gameplay-Episode). Diagnose: re4_stretch_diag.log, Stretch begann EXAKT mit ks=AKTIV.
-- Fix: solange der Killswitch aktiv ist, die Hand-Local-Position hart auf die Bind-Pose
-- (get_BaseLocalPosition) zuruecksetzen. Gefahrlos, weil die Anim die Translation nie
-- schreibt -> macht NUR unsere eigene Verformung rueckgaengig; die ROTATION laesst die
-- native Anim frei treiben.
local function restore_hand_local_to_bind(h)
    if not h then return end
    local bp = sc(h, "get_BaseLocalPosition")
    if bp then pcall(function() h:call("set_LocalPosition", bp) end) end
end
local function restore_hands_native()
    find_joints()
    restore_hand_local_to_bind(right_hand.joint)
    restore_hand_local_to_bind(left_hand.joint)
end


-- ---------------------------------------------------------------------
-- Weapon-Attach (RE9-Muster, RE4-adaptiert)
-- Die equippte wpXXXX-GO wird pro Phase DIREKT auf die Hand-Pose
-- geschrieben statt auf die Engine-Verkettung zu warten (kein Nachziehen).
-- Der rigid Offset Hand->Waffe wird von der Engine-Verkettung gesampelt
-- (selbstkalibrierend, -Offsets bleiben unberuehrt).
-- ---------------------------------------------------------------------
local wep_attach_enabled = true
local wep_cache = { id = nil, go = nil, tf = nil, rel_pos = nil, rel_rot = nil, calib = nil }

-- Kalibrierung pro Equip: erst CALIB_WAIT Frames (Draw-Anim ausklingen lassen),
-- dann CALIB_SAMPLE Frames die rechte Hand NICHT schreiben (native Engine-
-- Verkettung pur) und den rigid Offset exakt samplen -> danach EINGEFROREN.
local CALIB_WAIT = 25
local CALIB_SAMPLE = 5

-- [WEP_REL_PERSIST] aktuelle (frisch kalibrierte) rel-Pose pro Waffe einfrieren+speichern
-- =====================================================================
-- [KNIFE_ADA 2026-07-19] weapon_rel PRO CHARAKTER -- aber NUR fuer Messer.
-- =====================================================================
-- weapon_rel ist die EINGEFRORENE Hand->Waffe-Kalibrierung, verschluesselt mit tostring(wid).
-- Bei Ada sitzt das Messer anders in der Hand; "Re-Kalibrieren" wuerde ohne Trennung direkt
-- LEONS Wert ueberschreiben -- der GAU, den man ausgeschlossen haben will.
--
-- Loesung ohne zweite Datei und ohne Format-Umbau: fuer Ada + Messer bekommt der Schluessel ein
-- Suffix ("5001@ada"). Leons Schluessel ("5001") werden dadurch NIE angefasst -- weder gelesen
-- noch geschrieben noch geloescht. Alle anderen Waffen bleiben bewusst gemeinsam: es wurde
-- als Umfang ausdruecklich "nur Messer" gewaehlt.
--
-- Unbekannter Body (__re4_char_now == nil) -> KEIN Suffix, also Leons Schluessel. Das ist hier
-- sicher, weil in dem Zustand ohnehin keine Kalibrierung laeuft; und ein falsches "@ada"-Suffix
-- waere schlimmer als ein kurzzeitig gemeinsamer Schluessel.
-- Als Globals, nicht als Locals: motion.lua steht am 200-Local-Limit, und __re4_char_now wird
-- von weapons2.lua/holster.lua mitbenutzt. Guarded -> egal welches File zuerst laedt, erste
-- Definition gewinnt (alle drei sind identisch).
-- [CHAR_STICKY 2026-07-19] Die Erkennung setzt zeitweise aus (Body kurz weg: Waffenwechsel,
-- Holster, Ladebildschirm) -> sie lieferte nil, und JEDER Key, der am Charakter haengt, rutschte fuer
-- ein paar Frames in LEONS Namensraum: knife_wep_key ("6108_knifewep@ada" -> "6108_knifewep" = 0, also
-- die eben getunte Messer-Pose schlagartig weg) und __re4_knife_flip_map_r (Slider schreiben in Adas
-- Map, das Apply liest Leons -> der Flip-Slider "tut nichts"). BEWIESEN in re4_vr_motion.json: dort
-- standen Ada-Eintraege sowohl unter "6108" als auch unter "6108@ada".
-- Fix: letzter BEKANNTER Charakter statt nil. Ein echter Wechsel liefert sofort wieder einen validen
-- Body-Namen und aktualisiert; ueberbrueckt wird nur der Aussetzer. Strikt sicherer als vorher --
-- der alte nil-Zweig war faktisch schon "Leon", nur unbeabsichtigt.
_G.__re4_char_now = _G.__re4_char_now or function()
    local n = nil
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    local ok, ctx = pcall(function() return cm and cm:call("getPlayerContextRef") end)
    if ok and ctx then
        local okb, b = pcall(function() return ctx:call("get_BodyGameObject") end)
        if okb and b then
            local okn, nm = pcall(function() return b:call("get_Name") end)
            if okn and nm ~= nil then n = tostring(nm) end
        end
    end
    local c = nil
    -- [ADA_MERCS_BODY 2026-08-03] In Mercenaries heisst Adas Body "ch3a8z0_MC_body"
    -- (SW-KindID 380000 + _MC-Suffix) -- das MODELL ist dasselbe wie in Separate Ways.
    -- Ohne diese Zeile lieferte die Erkennung dort nil: knife_wep_key fiel auf "6107_knifewep"
    -- (= Leons Namensraum) zurueck, und der Seed-Guard im Flip-UI legte gar keinen Eintrag an
    -- -> "die Slider machen nichts". Bewusst DERSELBE Wert "ada": das Tuning gilt damit in
    -- beiden Modi (ausdruecklicher Wunsch: "das sollte dasselbe Model sein 1:1").
    -- LEON-NEUTRAL: nur ein zusaetzlicher Body-Name, alle uebrigen Zweige unveraendert.
    if n == "ch3a8z0_body" or n == "ch3a8z0_MC_body" then c = "ada"
    elseif n == "ch0a0z0_body" or n == "ch0a1z0_body" then c = "leon" end
    if c then _G.__re4_char_last = c; return c end
    return nil   -- [STICKY ZURUECKGENOMMEN] siehe unten
end
-- Messer, deren Kalibrierung pro Charakter getrennt wird. Deckungsgleich mit FL_KNIFE_IDS
-- weiter unten (dort erst ab Z. ~2683 definiert, hier aber schon gebraucht).
_G.__re4_knife_rel_split_ids = _G.__re4_knife_rel_split_ids or
    { [5000]=true, [5001]=true, [5002]=true, [5003]=true, [5006]=true, [6107]=true, [6108]=true, [6305]=true }

local function rel_key(wid)
    if not wid then return nil end
    local k = tostring(wid)
    if not _G.__re4_knife_rel_split_ids[wid] then return k end
    local fn = rawget(_G, "__re4_char_now")
    if type(fn) == "function" and fn() == "ada" then return k .. "@ada" end
    return k
end

local function store_weapon_rel()
    if not (wep_cache.id and wep_cache.rel_pos and wep_cache.rel_rot) then return end
    -- [PERSIST-FIX] Existiert schon eine gespeicherte Basis fuer diese Waffe? -> NICHT ueberschreiben.
    -- Stattdessen die gespeicherte in den Cache laden (der Live-Sample koennte im Blend gemessen sein
    -- = schlechter). So bleibt der Nullpunkt ueber Save-Load/Sessions STABIL. Nur die ERSTE, saubere
    -- Kalibrierung wird gespeichert. Bewusstes Neu-Kalibrieren loescht weapon_rel[id] vorher (Button).
    local ex = weapon_rel[rel_key(wep_cache.id)]   -- [KNIFE_ADA] charakter-getrennter Schluessel
    if ex then
        wep_cache.rel_pos = Vector3f.new(ex.px, ex.py, ex.pz)
        wep_cache.rel_rot = Quaternion.new(ex.qw, ex.qx, ex.qy, ex.qz)
        wep_cache.frozen = true
        return
    end
    local p, q = wep_cache.rel_pos, wep_cache.rel_rot
    weapon_rel[rel_key(wep_cache.id)] = {   -- [KNIFE_ADA]
        px = p.x, py = p.y, pz = p.z, qx = q.x, qy = q.y, qz = q.z, qw = q.w,
    }
    wep_cache.frozen = true      -- ab jetzt nicht mehr neu sampeln
    pcall(save_config)
end

local function find_weapon()
    local wid = get_equip_weapon_id()
    -- [PARRY_KEEP_GUN 2026-07-31, "beim Parry mit dem Messer LINKS soll die Waffe rechts bleiben"]
    -- Waehrend eines Links-Klon-Parrys equippt die Engine das Messer; ohne das hier wuerde find_weapon
    -- dem Messer folgen und die Schusswaffe aus der rechten Hand nehmen. Also: normalerweise
    -- mitschreiben, was rechts haengt -- und im Parry-Fenster die gemerkte Waffe weiterfuehren.
    -- STRENG GEGATET (-Bedingung): das Fenster setzt re4_vr_weapons2.lua AUSSCHLIESSLICH im Zweig
    -- __re4_knife_left_clone. Ein Parry mit dem ECHTEN Messer rechts laeuft hier nie durch -> dort
    -- bleibt alles wie bisher (Waffe kommt nicht zurueck, genau so gewollt).
    -- Zeitbasiert -> laeuft von selbst ab, kann nicht haengenbleiben.
    -- Merker als Feld auf wep_cache, NICHT als Top-Level-Local: motion.lua ist am 200-Local-Limit
    -- (zwei neue Locals hier haben es sofort gerissen).
    -- Messer-IDs inline, weil FL_KNIFE_IDS erst weiter unten im File definiert und hier nicht sichtbar
    -- ist -- deckungsgleich mit FL_KNIFE_IDS/KNIFE_IDS_SWING halten.
    do
        local kn = (wid == 5000 or wid == 5001 or wid == 5002 or wid == 5003
                 or wid == 5006 or wid == 6107 or wid == 6108 or wid == 6305)
        -- [FIX 2026-07-31, Log-Beweis] `wid > 0` ist entscheidend: nach dem Parry steht die equippte
        -- Waffe auf -1 ("gar nichts", equipWeapon mit 0xFFFFFFFF). Ohne diese Bedingung galt -1 als
        -- gueltige Nicht-Messer-Waffe und hat den Merker sofort ueberschrieben -> es gab nichts mehr
        -- zurueckzuholen. Genau deshalb hat der erste Versuch nichts bewirkt.
        if wid and wid > 0 and not kn then
            wep_cache._parry_last_gun = wid
        else
            local ut = tonumber(rawget(_G, "__re4_parry_keep_gun_until"))
            if ut and os.clock() < ut and wep_cache._parry_last_gun then
                wid = wep_cache._parry_last_gun
            end
        end
    end
    if not wid or wid == 0 then
        wep_cache.id, wep_cache.go, wep_cache.tf = nil, nil, nil
        wep_cache.rel_pos, wep_cache.rel_rot = nil, nil
        wep_cache.calib = nil
        wep_cache.settle = nil
        return
    end
    if wep_cache.id == wid and wep_cache.tf then
        -- [SAVE-LOAD] get_Valid mitpruefen: nach Save-Load ist die alte Waffen-Instanz TOT
        -- (stale Pointer liefert zwar noch eine Position, aber get_Valid=false). Nur wenn wirklich
        -- noch gueltig -> behalten. Sonst unten neu finden + die GESPEICHERTE Basis (stored) wieder
        -- anwenden. Verhindert, dass eine tote tf posiert wird waehrend die echte Waffe nativ floatet.
        local ok = pcall(function() return wep_cache.tf:call("get_Position") end)
        local valid = ok and (sc(wep_cache.tf, "get_Valid") ~= false)
        if valid then return end
    end
    wep_cache.id, wep_cache.go, wep_cache.tf = nil, nil, nil
    wep_cache.rel_pos, wep_cache.rel_rot = nil, nil
    wep_cache.settle = nil
    -- [WEP_REL_PERSIST] gespeicherten Offset wiederverwenden -> NICHT neu kalibrieren
    -- (so kann weder Skip noch Pin den Wert je wieder veraendern). Nur wenn keiner
    -- existiert: einmal sauber kalibrieren (im Ruhezustand) + speichern.
    local stored = weapon_rel[rel_key(wid)]   -- [KNIFE_ADA]
    if stored then
        wep_cache.rel_pos = Vector3f.new(stored.px, stored.py, stored.pz)
        wep_cache.rel_rot = Quaternion.new(stored.qw, stored.qx, stored.qy, stored.qz)
        wep_cache.calib = nil
        wep_cache.frozen = true     -- eingefroren -> NIE neu sampeln
    else
        wep_cache.calib = { wait = CALIB_WAIT, sample = CALIB_SAMPLE }
        wep_cache.frozen = false
    end

    local pt = find_player_body()
    if not pt then return end
    -- [GO_SUFFIX 2026-07-19] Waffen-GOs heissen NICHT immer exakt "wp####". Bei Ada (Separate
    -- Ways) haengen z.B. Punisher MC und Rocket Launcher als "wp6112_AO" / "wp6111_AO" im Baum --
    -- verifiziert mit re4_zzz_weaponhide_probe. Der frühere exakte Vergleich fand sie nie ->
    -- wep_cache.go/tf blieben leer -> die Waffe wurde NIE an die VR-Hand gehaengt und blieb an ihrer
    -- nativen Position stehen. Das sah aus wie "unsichtbar", war aber ein Fund-Problem: alle
    -- Render-Flags (DrawDefault/Enabled/Scale/Joints) waren nachweislich in Ordnung.
    -- Suffixe wie in der alten Mod (re4_vr_weapons.lua SUFFIXES): "" -> "_AO" -> "_MC".
    -- REIHENFOLGE IST WICHTIG: bei anderen Waffen ist "_AO" ein SCHATTEN-PROXY neben dem echten
    -- GO. Nur wenn es kein plain "wp####" gibt, darf der Suffix-Treffer genommen werden -- sonst
    -- haengen wir die Hand an den Schatten statt an die Waffe.
    local base = string.format("wp%04d", wid)
    local function scan(name)
        local child = sc(pt, "get_Child")
        local count = 0
        while child and count < 64 do
            count = count + 1
            local go = sc(child, "get_GameObject")
            local gname = go and sc(go, "get_Name")
            if gname and tostring(gname) == name then
                -- Duplikate (Throwables x2): den sichtbaren nehmen
                local draw = sc(go, "get_DrawSelf")
                if draw ~= false then return go, child end
            end
            child = sc(child, "get_Next")
        end
        return nil, nil
    end
    for _, suffix in ipairs({ "", "_AO", "_MC" }) do
        local go, tf = scan(base .. suffix)
        if go then
            wep_cache.id = wid
            wep_cache.go = go
            wep_cache.tf = tf
            return
        end
    end
end

-- Rigid-Offset Hand->Waffe aus der NATIVEN Engine-Verkettung lesen
-- (nur waehrend des Kalibrier-Fensters; Hand wird dabei nicht geschrieben).
local function sample_weapon_rel_direct()
    if not wep_cache.tf then return false end
    if not is_joint_valid(right_hand.joint) then return false end
    local hp = sc(right_hand.joint, "get_Position")
    local hr = sc(right_hand.joint, "get_Rotation")
    local wp = sc(wep_cache.tf, "get_Position")
    local wr = sc(wep_cache.tf, "get_Rotation")
    if not (hp and hr and wp and wr) then return false end

    local ok_i, hri = pcall(function() return hr:conjugate() end)
    if not ok_i or not hri then return false end
    local rel_pos = quat_rotate_vec3(hri, vec3_subtract(wp, hp))
    local ok_r, rel_rot = pcall(function() return (hri * wr):normalized() end)
    if not ok_r or not rel_rot then return false end

    wep_cache.rel_pos = rel_pos
    wep_cache.rel_rot = rel_rot
    return true
end

-- Kalibrier-State-Machine (laeuft nur im LateUpdateBehavior-Pass)
local function update_weapon_calibration()
    local c = wep_cache.calib
    if not c or not wep_cache.tf then return end
    -- [RECOIL_ON_HAND 2026-07-31] Nicht waehrend eines Kicks sampeln: seit der Recoil auf der Hand liegt,
    -- wuerde eine im Kick gemessene Nulllage die Verkippung DAUERHAFT einfrieren (wep_cache.frozen +
    -- save_config). Ein paar Frames warten kostet nichts. [[Notiz]]
    do
        local rc = rawget(_G, "vr_recoil")
        if rc and rc.active then return end
    end
    if c.wait > 0 then
        c.wait = c.wait - 1
        return
    end
    if sample_weapon_rel_direct() then
        c.sample = c.sample - 1
        if c.sample <= 0 then
            wep_cache.calib = nil   -- rel ist eingefroren
            store_weapon_rel()      -- [WEP_REL_PERSIST] einfrieren + speichern
        end
    end
end

-- Waehrend Sample-Fenster ODER Settle-Phase rechte Hand + Waffe NICHT schreiben
local function weapon_calib_suspends_hand()
    if wep_cache.settle ~= nil then return true end
    local c = wep_cache.calib
    return c ~= nil and c.wait <= 0
end

-- Waffenwechsel laeuft? (Engine-Flag) -> Draw-/Holster-Anim NATIV durchlaufen
-- lassen (rechte Hand frei), danach frisch kalibrieren.
local was_weapon_changing = false

local function is_weapon_changing()
    local ctx = get_player_context()
    if not ctx then return false end
    local v = sc(ctx, "get_IsWeaponChanging")
    return v == true
end

-- Settle-Phase nach Flag-Ende: weiter nativ + samplen, bis der rel-Offset
-- KONVERGIERT (sonst lockt man mitten im Blend -> Hand neben dem Griff,
-- siehe Log wp4402/4902: Werte pendeln 0.31-0.41 ohne Ende).
local SETTLE_EPS = 0.002      -- m, Frame-zu-Frame
local SETTLE_STABLE_FRAMES = 3
local SETTLE_TIMEOUT = 40

local function update_weapon_changing_gate()
    local changing = is_weapon_changing()
    if was_weapon_changing and not changing and not wep_cache.frozen then
        -- Wechsel beendet -> Settle-Phase starten (lockt bei Konvergenz).
        -- Bei eingefrorenem (gespeichertem) Offset NICHT -> Wert bleibt stabil.
        wep_cache.settle = { stable = 0, timeout = SETTLE_TIMEOUT, last = nil }
        wep_cache.calib = nil
    end
    was_weapon_changing = changing
    return changing
end

local function update_weapon_settle()
    local s = wep_cache.settle
    if not s then return end
    if not wep_cache.tf then wep_cache.settle = nil return end

    local prev = wep_cache.rel_pos
    if sample_weapon_rel_direct() and prev then
        local d = math.sqrt(
            (wep_cache.rel_pos.x - prev.x)^2 +
            (wep_cache.rel_pos.y - prev.y)^2 +
            (wep_cache.rel_pos.z - prev.z)^2)
        if d < SETTLE_EPS then
            s.stable = s.stable + 1
        else
            s.stable = 0
        end
    end
    s.timeout = s.timeout - 1
    if s.stable >= SETTLE_STABLE_FRAMES or s.timeout <= 0 then
        wep_cache.settle = nil
        store_weapon_rel()      -- [WEP_REL_PERSIST] einfrieren + speichern
    end
end

-- [SKULL_SHAKER_COCK] Schritt 2 (2026-06-20): waehrend die native Cock-Anim laeuft
-- (__vr_pump_anim_active = PumpAction-Node aktiv, nur wp6001) die Waffe in Pitch loopen
-- lassen. Pivot = rechte Hand (Waffe bleibt an ihr verankert; Two-Hand ist im Fenster aus).
-- Zeit-getrieben (os.clock seit steigender Flanke) -> dreht weiter, solange die Anim laeuft;
-- endet die Anim, faellt der Offset weg und die Waffe ist sofort wieder normal.
-- [WIEDER DRIN 2026-07-31] Nur die KEYFRAMES/Vorschau sind raus -- die Drehung selbst
-- ist exakt der bewaehrte Stand von vor den Keyframes (feste Formel, 1x 360 Grad ueber die Anim).
local skull_spin = { t0 = nil }
local SKULL_SPIN_PERIOD = 0.40   -- s pro voller Umdrehung (nur Fallback, falls Anim-Fortschritt fehlt)
local SKULL_SPIN_DIR = -1        -- Drehrichtung (so gewollt: andersrum)
local SKULL_SPIN_TURNS = 1.0     -- genau 1x 360deg ueber die Anim-Dauer
local function skullshaker_cock_spin(wrot)
    if rawget(_G, "__vr_pump_anim_active") ~= true then skull_spin.t0 = nil; return wrot end
    -- Fortschritt 0..1 aus reload.lua (NormalizeTime der Waffen-Anim) -> exakt SKULL_SPIN_TURNS Umdrehungen.
    local prog = tonumber(rawget(_G, "__vr_pump_anim_progress"))
    local frac
    if prog then
        frac = prog < 0 and 0 or prog
    else
        local now = os.clock()   -- Fallback: zeitbasiert, falls kein Fortschritt da
        if not skull_spin.t0 then skull_spin.t0 = now end
        frac = (now - skull_spin.t0) / SKULL_SPIN_PERIOD
    end
    local h = (SKULL_SPIN_DIR * frac * SKULL_SPIN_TURNS * (2 * math.pi)) * 0.5
    local pitch = Quaternion.new(math.cos(h), math.sin(h), 0, 0)   -- Rotation um lokale X-Achse (Pitch)
    local ok, r = pcall(function() return (wrot * pitch):normalized() end)
    if ok and r then return r end
    return wrot
end

-- Waffe direkt auf die (frisch geschriebene) Hand-Pose setzen
-- [KNIFE_FLIP 2026-07-03] 180°-Reverse-Grip-Flip des Messers, per RT getoggelt (binding setzt
-- __vr_knife_flip). Wir lerpen sanft in die Flip-Stellung und ueberlagern dem Messer-Transform eine
-- Rotation um bis zu 180°. Achse = lokale X (Pitch); falls "Griff oben" eine andere Achse braucht,
-- KNIFE_FLIP_EULER anpassen (Grad, mit lerp skaliert).
local knife_flip = { lerp = 0.0, prev_target = 0.0 }
local KNIFE_FLIP_SPEED = 0.18                 -- Lerp/Frame (~0.15s bei 90fps)
local KNIFE_FLIP_EULER = { 180.0, 0.0, 0.0 }  -- welche Achse(n) flippen (Grad bei voll geflippt)
local KNIFE_FLIP_SND = 1007228839             -- Sound bei jedem Flip (hin UND zurueck)
local _knife_snd_td = sdk.typeof("soundlib.SoundContainer")
local function knife_play_sound(id)
    local go = wep_cache.go
    if not (go and id and _knife_snd_td) then return end
    local ok, scn = pcall(function() return go:call("getComponent(System.Type)", _knife_snd_td) end)
    if ok and scn then pcall(function() scn:call("trigger(System.UInt32)", id) end) end
end
local function knife_flip_spin(wrot)
    if rawget(_G, "__re4_knife_equipped") ~= true then knife_flip.lerp = 0.0; knife_flip.prev_target = 0.0; return wrot end
    local target = (rawget(_G, "__vr_knife_flip") == true) and 1.0 or 0.0
    -- [KNIFE_FLIP SND] Flanke des Ziels (Tastendruck) -> Flip-Sound, bei hin UND zurueck. prev_target
    -- wird auf erste Detektion gesetzt -> kein Mehrfach-Trigger in den mehreren attach_weapon-Paessen.
    if knife_flip.prev_target ~= target then
        knife_flip.prev_target = target
        knife_play_sound(KNIFE_FLIP_SND)
    end
    local spd = tonumber(rawget(_G, "__re4_knife_flip_speed")) or KNIFE_FLIP_SPEED
    if knife_flip.lerp < target then knife_flip.lerp = math.min(target, knife_flip.lerp + spd)
    elseif knife_flip.lerp > target then knife_flip.lerp = math.max(target, knife_flip.lerp - spd) end
    if knife_flip.lerp <= 0.0001 then return wrot end
    local e = KNIFE_FLIP_EULER
    local flip = quat_from_euler_deg(e[1] * knife_flip.lerp, e[2] * knife_flip.lerp, e[3] * knife_flip.lerp)
    local ok, r = pcall(function() return (wrot * flip):normalized() end)
    if ok and r then return r end
    return wrot
end

-- [KNIFE_FLIP KS] Bei JEDEM Killswitch (Cutscene, z.B. Finisher-Kill) MUSS das Messer nativ stehen.
-- motion pinnt in KS nicht (attach_weapon uebersprungen) -> das Messer behaelt sonst seine geflippte
-- LOKALE Rotation und folgt der Hand-Bone verkehrt (native Anim sticht mit dem Griff zu). Fix: aktuelle
-- Weltrotation um den (Rest-)Flip zuruecknehmen -> lokale Rotation wird nativ, ab dann folgt es korrekt.
-- Global-Closure (schliesst ueber wep_cache/knife_flip) -> KEINE neue top-level local (motion knapp).
_G.__re4_knife_ks_restore_native = function()
    if rawget(_G, "__re4_knife_equipped") ~= true then return end
    -- [FLIP_MERKEN 2026-07-15] Der Flip MUSS im KS visuell aus (sonst Griff-Stich, s.o.) -- aber der
    -- WUNSCH-Zustand darf dabei nicht verloren gehen. Vorher wurde __vr_knife_flip hart auf false gesetzt
    -- und weggeworfen -> JEDER Treffer/Stagger (= KS3/Damage) hat den Reverse-Grip gekillt, obwohl nur die
    -- Finisher-Cutscene gemeint war. Jetzt: merken, nach dem KS wiederherstellen (Restore-Punkt im tick,
    -- direkt hinter dem KS-Block). Nur beim Wechsel true->false merken; die Folgeframes im KS sehen bereits
    -- false und duerfen den Merker nicht ueberschreiben.
    if rawget(_G, "__vr_knife_flip") == true then _G.__re4_knife_flip_pre_ks = true end
    knife_flip.lerp = 0.0
    knife_flip.prev_target = 0.0
    _G.__vr_knife_flip = false
    -- [KNIFE_KS_FOLLOW] motion pinnt in KS nicht (attach_weapon uebersprungen) -> das Messer friert sonst
    -- in der Luft ein (Stagger/Cutscene). Die VR-Hand (cache.rh_world) ist in KS aus -> darum an den
    -- NATIVEN R_Hand-Joint pinnen (gleicher Mount-Offset rel_pos/rel_rot, OHNE Flip=nativ) -> das Messer
    -- folgt der nativen Anim statt einzufrieren.
    if right_hand.joint and wep_cache.tf and wep_cache.rel_pos and wep_cache.rel_rot then
        local hw = sc(right_hand.joint, "get_Position")
        local hr = sc(right_hand.joint, "get_Rotation")
        if hw and hr then
            local wpos = vec3_add(hw, quat_rotate_vec3(hr, wep_cache.rel_pos))
            local ok, wrot = pcall(function() return (hr * wep_cache.rel_rot):normalized() end)
            if ok and wrot then
                pcall(function() wep_cache.tf:call("set_Position", wpos) end)
                pcall(function() wep_cache.tf:call("set_Rotation", wrot) end)
            end
        end
    end
end

local function attach_weapon()
    if not wep_attach_enabled then return end
    -- [MERC_BOW_PIN 2026-08-06] Krausers Compound Bow wird nicht mehr pro Frame in WELT-Koordinaten
    -- nachgezogen (das war der Nachlauf), sondern haengt NATIV am Hand-Joint -- genau wie die Magazin-/
    -- Shell-Klone aus dem Mag-Holster (re4_vr_reload.lua: set_Parent + set_ParentJoint, danach nur noch
    -- lokale Pose). Das erledigt re4_vr_merc.lua; hier NUR aussteigen, damit sich beide nicht um die
    -- Transform pruegeln. Flag setzt ausschliesslich das Mercs-Script -> Kampagne unberuehrt.
    if rawget(_G, "__re4_merc_bow_pinned") == true then return end
    -- [KNIFE_THROW] Waehrend das geworfene Messer fliegt NICHT an die Hand pinnen -> sonst kaempfen
    -- Flug-Override (weapons.lua knife_flight_apply) und Hand-Pin um die Transform = Messer zappelt.
    if rawget(_G, "__re4_knife_flying") == true then return end
    if not wep_cache.tf or not wep_cache.rel_pos or not wep_cache.rel_rot then return end

    -- [KNIFE_HAND 2026-07-07] Messer in der LINKEN Hand? Dann an die linke Hand pinnen (Offsets sagittal
    -- gespiegelt: Pos-X negiert, Rot (w,-x,y,z)). PRESERVATION: der rechte Pfad bleibt exakt der alte
    -- Default. Startwerte der Spiegelung sind ein Ausgangspunkt (im UI/Config spaeter feintunbar).
    -- [KNIFE_HAND] Die linke Hand (cache.lh_world) wird im Render-Pass ERST NACH attach_weapon berechnet
    -- (attach_left_hand kommt danach; am Pass-Anfang auf nil gesetzt) -> hier meist nil. Fallback auf die
    -- publizierten Globals __vr_lh_world/__vr_lh_rot (max. 1 Frame alt, fuer den Pin unkritisch), sonst
    -- fiele der Branch faelschlich auf den rechten else-Zweig zurueck.
    local lw = cache.lh_world or rawget(_G, "__vr_lh_world")
    local lr = cache.lh_rot   or rawget(_G, "__vr_lh_rot")
    local hand_world, hand_rot, rel_pos, rel_rot
    if rawget(_G, "__re4_knife_hand") == "left" and lw and lr then
        hand_world, hand_rot = lw, lr
        local rp = wep_cache.rel_pos
        local rr = wep_cache.rel_rot
        -- [KNIFE_HAND] Basis = gespiegelter rechter Offset; darauf der PRO-MESSER Links-Feinschliff aus der
        -- Map __re4_knife_lh_off_map[wid] (Slider in re4_vr_knife_lefthand.lua). Pos additiv im Hand-Frame,
        -- Rot lokal an die Waffe. Fehlt ein Eintrag -> 0 (Preservation, = reine Spiegelung wie bisher).
        local o = nil
        do local mm = rawget(_G, "__re4_knife_lh_off_map"); if mm and wep_cache.id then o = mm[wep_cache.id] end end
        rel_pos = Vector3f.new(-rp.x + (o and o.px or 0.0), rp.y + (o and o.py or 0.0), rp.z + (o and o.pz or 0.0))
        rel_rot = Quaternion.new(rr.w, -rr.x, rr.y, rr.z)
        if o and (o.rx ~= 0 or o.ry ~= 0 or o.rz ~= 0) then
            local rq = quat_from_euler_deg(o.rx, o.ry, o.rz)
            if rq then local okr, r2 = pcall(function() return (rel_rot * rq):normalized() end); if okr and r2 then rel_rot = r2 end end
        end
    else
        if not (cache.rh_world and cache.rh_rot) then return end
        hand_world, hand_rot = cache.rh_world, cache.rh_rot
        rel_pos, rel_rot = wep_cache.rel_pos, wep_cache.rel_rot
        -- [MATILDA_STOCK] Waffe-only Versatz: bewegt NUR die Waffe relativ zur Hand (auf rel_pos/rel_rot),
        -- die HAND bleibt 1:1 wie ohne Stock. Nur Matilda+Stock. Muster wie der Knife-Hand-Offset oben
        -- (Pos additiv im Hand-Frame, Rot lokal an die Waffe). Getunt via get_weapon_offset("4004_stockwep").
        if cache.matilda_stock then
            local o = get_weapon_offset("4004_stockwep")
            rel_pos = Vector3f.new(rel_pos.x + o.px, rel_pos.y + o.py, rel_pos.z + o.pz)
            if o.rx ~= 0 or o.ry ~= 0 or o.rz ~= 0 then
                local rq = quat_from_euler_deg(o.rx, o.ry, o.rz)
                if rq then local okr, r2 = pcall(function() return (rel_rot * rq):normalized() end); if okr and r2 then rel_rot = r2 end end
            end
        end
        -- [EGG_5403 2026-07-18] Der Offset "5403" wirkt (oben, apply_hand_offset) fuer das Ei NICHT auf die Hand
        -- -> hier stattdessen WAFFE-only additiv auf rel_pos/rel_rot (Pos im Hand-Frame, Rot lokal an die Waffe),
        -- exakt wie MATILDA_STOCK. So schiebt dein bestehender 5403-Slider NUR das Ei relativ zur Hand; die Hand
        -- bleibt 1:1. Damit laesst sich das Ei sauber in die Hand einschieben (auch den kaputten weapon_rel-Versatz
        -- kompensieren). Nutzt DENSELBEN Key "5403" wie der bestehende per-Waffe Slider -> nichts neu einzustellen.
        -- [KNIFE_WEP_ADA 2026-07-19] Messer WAFFE-only relativ zur Hand -- exakt das Muster von
        -- MATILDA_STOCK/5403 darueber. Grund: "Right Hand Offset (per Weapon)" verschiebt die HAND
        -- (apply_hand_offset), das Messer folgt starr; du brauchst aber die Lage des Messers IN der
        -- Hand. Eigener Key pro Messer, fuer Ada mit "@ada"-Suffix -> Leons Wert bleibt unberuehrt.
        -- Neue Keys starten auf 0 -> solange nichts getunt ist, aendert sich GAR NICHTS.
        do
            local split = rawget(_G, "__re4_knife_rel_split_ids")
            if split and wep_cache.id and split[wep_cache.id] then
                local o = get_weapon_offset(knife_wep_key(wep_cache.id))
                rel_pos = Vector3f.new(rel_pos.x + o.px, rel_pos.y + o.py, rel_pos.z + o.pz)
                if o.rx ~= 0 or o.ry ~= 0 or o.rz ~= 0 then
                    local rq = quat_from_euler_deg(o.rx, o.ry, o.rz)
                    if rq then local okr, r2 = pcall(function() return (rel_rot * rq):normalized() end); if okr and r2 then rel_rot = r2 end end
                end
            end
        end
        -- [BOW_6102 2026-07-19] Blast Crossbow: ihre eingefrorene Kalibrierung traegt einen festen
        -- ~15cm-Versatz (weapon_rel 6102: px -0.146 / py -0.058). Der ist NICHT einmalig falsch gemessen --
        -- er kommt nach dem Loeschen reproduzierbar zurueck, ist also der Modell-Ursprung der Waffe.
        -- Gleiche Behandlung wie beim Ei 5403: WAFFE-only gegensteuern (Pos im Hand-Frame, Rot lokal an
        -- die Waffe), die HAND bleibt 1:1. Eigener Key "6102" -> per-Waffe-Slider im UI, startet bei 0.
        if wep_cache.id == 6102 then
            -- EIGENER Key "6102_bowwep": "6102" ist bereits der HAND-Offset (current_weapon_key) und
            -- ist getunt -- derselbe Key wuerde den Wert doppelt anwenden.
            local o = get_weapon_offset("6102_bowwep")
            rel_pos = Vector3f.new(rel_pos.x + o.px, rel_pos.y + o.py, rel_pos.z + o.pz)
            if o.rx ~= 0 or o.ry ~= 0 or o.rz ~= 0 then
                local rq = quat_from_euler_deg(o.rx, o.ry, o.rz)
                if rq then local okr, r2 = pcall(function() return (rel_rot * rq):normalized() end); if okr and r2 then rel_rot = r2 end end
            end
        end
        -- [SKULL_SPIN_ENTFERNT 2026-07-31] Hier lagen die Skull-Shaker-Spin-Keyframes (Waffen-Offset
        -- x/y/z + rx/ry/rz am Drehwinkel waehrend der Cock-Anim). Komplett raus -- wp6001 bekommt in
        -- attach_weapon keine Sonderbehandlung mehr.
        if wep_cache.id == 5403 then
            local o = get_weapon_offset("5403")
            rel_pos = Vector3f.new(rel_pos.x + o.px, rel_pos.y + o.py, rel_pos.z + o.pz)
            if o.rx ~= 0 or o.ry ~= 0 or o.rz ~= 0 then
                local rq = quat_from_euler_deg(o.rx, o.ry, o.rz)
                if rq then local okr, r2 = pcall(function() return (rel_rot * rq):normalized() end); if okr and r2 then rel_rot = r2 end end
            end
        end
        -- [EGG_5405 ADA 2026-07-21] Adas Ei = wp5405, exakt derselbe Fall wie Leons 5403 oben:
        -- WAFFE-only additiv auf rel_pos/rel_rot -> das Ei laesst sich in der Hand ausrichten, ohne die
        -- HAND mitzuziehen (der "Right Hand Offset (per Weapon)"-Slider wuerde die Hand verschieben).
        -- EIGENER Key "5405" -> Leons 5403-Wert bleibt voellig unberuehrt; der neue startet auf 0,
        -- solange nichts getunt ist, aendert sich also GAR NICHTS.
        if wep_cache.id == 5405 then
            local o = get_weapon_offset("5405")
            rel_pos = Vector3f.new(rel_pos.x + o.px, rel_pos.y + o.py, rel_pos.z + o.pz)
            if o.rx ~= 0 or o.ry ~= 0 or o.rz ~= 0 then
                local rq = quat_from_euler_deg(o.rx, o.ry, o.rz)
                if rq then local okr, r2 = pcall(function() return (rel_rot * rq):normalized() end); if okr and r2 then rel_rot = r2 end end
            end
        end
    end

    local wpos = vec3_add(hand_world, quat_rotate_vec3(hand_rot, rel_pos))
    local ok, wrot = pcall(function() return (hand_rot * rel_rot):normalized() end)
    if not ok or not wrot then return end
    wrot = skullshaker_cock_spin(wrot)   -- [SKULL_SHAKER_COCK] Pitch-Loop waehrend der Cock-Anim
    wrot = knife_flip_spin(wrot)         -- [KNIFE_FLIP] 180°-Reverse-Grip-Flip (RT-Toggle)
    if _G.__re4_wildwest_apply then wpos, wrot = _G.__re4_wildwest_apply(wpos, wrot) end   -- [WILDWEST] Twirl + Pivot um Trigger-Joint (Pos+Rot; re4_vr_wildwest.lua)
    -- [KNIFE_FLIP] Nach dem Flip das Messer verschieben -> Griff sitzt sauber in der Hand. Offset im
    -- HAND-Frame (rh_rot, wie die Basis-Waffenpose rel_pos) -> konsistente Achsen, kein Welt-Y-Koppeln.
    -- Rotation/Rest unveraendert; skaliert mit dem Flip-Lerp; X/Y/Z per Slider.
    if rawget(_G, "__re4_knife_equipped") == true and (knife_flip.lerp or 0) > 0.0001 then
        -- [KNIFE_FLIP] Griff-Offset PRO MESSER (verschiedene Klingengroessen passen nach dem 180°-Flip
        -- unterschiedlich). Map in _G (keine neue top-level local; motion knapp). Fallback = alter globaler
        -- Wert (Preservation), bis das jeweilige Messer im UI getunt wird.
        local kid = wep_cache and wep_cache.id
        -- [KNIFE_FLIP LINKS] Messer links: EIGENE Pro-Messer Flip-Offset-Map (getunt im Links-Treenode),
        -- im LINKEN Hand-Frame angelegt; NICHT gespiegelt (eigene Werte). Rechts unveraendert (Preservation).
        local is_left   = rawget(_G, "__re4_knife_hand") == "left"
        -- [KNIFE_FLIP_ADA] rechts: charakter-abhaengige Map (links ist schon ueber eigene Dateien getrennt)
        local m   = is_left and rawget(_G, "__re4_knife_flip_lh_map") or (_G.__re4_knife_flip_map_r())
        local p   = (m and kid) and m[kid] or nil
        local px  = p and p.x or (is_left and 0.0 or (tonumber(rawget(_G, "__re4_knife_flip_pos_x")) or 0.0))
        local py  = p and p.y or (is_left and 0.0 or (tonumber(rawget(_G, "__re4_knife_flip_pos_y")) or 0.0))
        local pz  = p and p.z or (is_left and 0.0 or (tonumber(rawget(_G, "__re4_knife_flip_pos_z")) or 0.0))
        local frame_rot = is_left and (cache.lh_rot or rawget(_G, "__vr_lh_rot")) or cache.rh_rot
        local ox = px * knife_flip.lerp
        local oy = py * knife_flip.lerp
        local oz = pz * knife_flip.lerp
        -- [FLIP_ENTKOPPELT 2026-07-19] Der WAFFE-only Messer-Offset (knifewep, weiter oben auf rel_pos)
        -- wirkte in BEIDEN Zustaenden, der Flip-Offset nur in einem -> jedes Tuning am einen verschob
        -- zwangsläufig auch den anderen. Genau das war der Bug ("die EINEN Slider verfaelschen die ANDEREN").
        -- Fix: seinen POSITIONS-Anteil mit dem Flip-Lerp wieder herausrechnen. Ergebnis:
        -- lerp = 0 -> nur knifewep-Position (ein Satz X/Y/Z)
        -- lerp = 1 -> nur Flip-Position (eigener Satz X/Y/Z)
        -- Beide Zustaende sind damit unabhaengig tunbar. Die ROTATION bleibt in beiden gleich (unveraendert) --
        -- gewollt, es soll sich nur die Lage in der Hand verschieben.
        -- LEON-NEUTRAL: greift nur ueber den Key knifewep, und der ist ausschliesslich fuer Ada gesetzt
        -- ("6108_knifewep@ada"). Fuer Leon ist der Offset ueberall 0 -> die Rechnung ist dort exakt ein No-Op.
        if not is_left and frame_rot and kid then
            local sp = rawget(_G, "__re4_knife_rel_split_ids")
            if sp and sp[kid] then
                local ko = get_weapon_offset(knife_wep_key(kid))
                if ko and (ko.px ~= 0 or ko.py ~= 0 or ko.pz ~= 0) then
                    local l = knife_flip.lerp
                    ox = ox - ko.px * l
                    oy = oy - ko.py * l
                    oz = oz - ko.pz * l
                end
            end
        end
        if (ox ~= 0 or oy ~= 0 or oz ~= 0) and frame_rot then
            local off = quat_rotate_vec3(frame_rot, Vector3f.new(ox, oy, oz))
            if off then wpos = vec3_add(wpos, off) end
        end
    end
    -- [RECOIL] VERSCHOBEN 2026-07-31 -> attach_right_hand ([RECOIL_ON_HAND]). Hier lag der Kick auf
    -- wpos/wrot, also HINTER dem Hand-Pin: die Waffe kickte, die Hand blieb stehen. Jetzt sitzt er auf
    -- cache.rh_world/rh_rot, aus denen wpos/wrot unten gebaut werden -> Hand und Waffe kicken gemeinsam.
    -- NICHT wieder hier einbauen, sonst wirkt der Recoil doppelt.
    -- [MERC_WEP_HOOK 2026-08-03, "im mercs script verankern, damit wir am maingame nichts aendern"]
    -- Letzte Station vor dem Schreiben: das Mercenaries-Script darf Pos/Rot einer EIGENEN Waffe komplett
    -- ersetzen (z.B. Krausers Compound Bow, der an die LINKE Hand gehoert). Muster wie __re4_wildwest_apply
    -- darueber. Die Funktion existiert NUR, wenn re4_vr_merc.lua sie setzt -> in der Kampagne ist die Zeile
    -- ein reiner nil-Check, es aendert sich dort GAR NICHTS.
    -- ACHTUNG ( 2026-08-03): fuer eine so uebernommene Waffe sind ALLE Slider hier oben tot --
    -- "Right Hand Offset (per Weapon)", weapon_rel und die WAFFE-only Keys wirken nicht mehr, weil
    -- Pos+Rot komplett ersetzt werden. Getunt wird eine solche Waffe NUR im Mercenaries-Tree.
    if _G.__re4_merc_wep_apply then
        -- hand_rot MUSS mitgegeben werden: __vr_rh_rot wird erst am Ende des Ticks publiziert,
        -- der Hook wuerde sonst mit der Rotation des VORIGEN Passes rechnen -> die Waffe zappelt
        -- um die Differenz ( 2026-08-03: "die Waffe wabbelt").
        local mp, mr = _G.__re4_merc_wep_apply(wpos, wrot, wep_cache.id, hand_rot)
        if mp and mr then wpos, wrot = mp, mr end
    end
    pcall(function() wep_cache.tf:call("set_Position", wpos) end)
    pcall(function() wep_cache.tf:call("set_Rotation", wrot) end)
end


-- ---------------------------------------------------------------------
-- [NATIVE_ANIM] ENTFERNT 2026-06-20: Der Voll-Kill waehrend der nativen Break-Action-Cock-Anim
-- ("Aim_Fire.PumpAction") wurde verworfen. Test ergab: die native Anim spielt IMMER an Ort und
-- Stelle (Engine uebernimmt die Waffe waehrend des Nodes), egal ob VR-Motion laeuft oder nicht.
-- Plan: native Anim unterdruecken + Cock + die 2x Rack-Sounds (ID 3370013164) selbst nachbauen.
-- reload.lua publiziert __vr_pump_anim_active weiterhin als Trigger fuer den Nachbau.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Killswitch
-- ---------------------------------------------------------------------
local function is_killswitch_active()
    if _G.__vr_motion_paused == true then return true end
    -- [RAILCAR] Auf dem Schienenwagen laeuft motion TROTZ Killswitch weiter -- AUSSER waehrend eines nativen
    -- Reloads (Mounted-Gun): dann motion aus, damit die native Nachlade-Anim sauber durchspielt.
    if rawget(_G, "__re4_railcar_mode") == true then
        if rawget(_G, "__re4_railcar_reloading") ~= true then return false end
        -- reload aktiv -> NICHT force-on; faellt durch zu killswitch.is_active (aktiv) -> pause = motion aus.
    end
    -- [THROWSIGHT] Del-Lago-Harpunen-Stage: Kamera bleibt First-Person (KS aus), aber die
    -- Motion-Manipulation (Arme/Waffen/Joints) soll HIER pausieren -> sieht sonst kaputt aus.
    -- NUR diese Stage. materials/firstperson bleiben davon unberuehrt (laufen als Gameplay).
    if rawget(_G, "__re4_throwsight_active") == true then return true end
    if killswitch and killswitch.is_active then
        local ok, active = pcall(killswitch.is_active)
        if ok and active then return true end
    end
    return false
end

-- [NATIVE_ANIM] Solange die native Red9-Reload-Anim laeuft, dieses Motion-Script komplett aus
-- (als waere es disabled). NUR motion. wid + MotionFsm2 jeden Frame frisch aus dem Context
-- (robust nach Save/Load). Nur wp4002 + Node mit "RELOAD".
local _nr_td = sdk.typeof("via.motion.MotionFsm2")
local _nr = { go = nil, comp = nil }
local function native_reload_active()
    local r = false
    repeat
        local ctx = get_player_context(); if not ctx then break end
        local hu = sc(ctx, "get_HeadUpdater"); if not hu then break end
        local w = sc(hu, "get_EquipWeaponID")
        local wid = (type(w) == "userdata") and sf(w, "value__") or w
        if wid ~= 4002 then break end
        local go = sc(ctx, "get_BodyGameObject"); if not go then break end
        if _nr.go ~= go then _nr.go = go; _nr.comp = nil end
        if not _nr.comp then _nr.comp = _nr_td and sc(go, "getComponent(System.Type)", _nr_td) or nil end
        local m = _nr.comp; if not m then break end
        for layer = 0, 6 do
            local n = sc(m, "getCurrentNodeName", layer)
            if n and tostring(n):find("RELOAD", 1, true) then r = true; break end
        end
    until true
    -- [RED9_RELOAD_AIM] Flag fuer binding.lua: waehrend dieser Anim Aim (LT) forcen, sonst spielt die
    -- Engine die linke-Hand-Reload-Anim nicht (an den Aim-/Hold-Zustand gekoppelt).
    _G.__vr_red9_reloading = r
    return r
end

-- [NATIVE_ANIM] Beim Aussteigen die von motion veroeffentlichten Hand-ZIELE auf nil setzen -> genau der
-- "motion nicht geladen"-Zustand. Dann hat die Arm-IK kein Ziel mehr (sie liest exakt diese Globals)
-- und laesst die Arme der nativen Anim. Ohne das blieben die alten Ziele stehen -> Arme steif.
local function release_motion_targets()
    _G.__vr_lh_world = nil; _G.__vr_lh_rot = nil; _G.__vr_lh_joint_pos = nil; _G.__vr_lh_joint_rot = nil; _G.__vr_unified_lh_pos = nil
    _G.__vr_rh_world = nil; _G.__vr_rh_rot = nil; _G.__vr_rh_joint_pos = nil; _G.__vr_rh_joint_rot = nil; _G.__vr_unified_rh_pos = nil
end




-- ---------------------------------------------------------------------
-- Camera + VR Data
-- ---------------------------------------------------------------------
local function get_camera_data()
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local go = sc(cam, "get_GameObject")
    if not go then return nil end
    local tf = sc(go, "get_Transform")
    if not tf then return nil end
    local wm = sc(cam, "get_WorldMatrix")
    if not wm then return nil end
    local rot = sc(tf, "get_Rotation")
    if not rot then return nil end

    local position = Vector3f.new(wm[3].x, wm[3].y, wm[3].z)
    local rotation = rot

    -- Optionale Integration mit re4_vr_firstperson CameraFix
    if _G.vr_camera_fix and _G.vr_camera_fix.active then
        if _G.vr_camera_fix.camera_pos then position = _G.vr_camera_fix.camera_pos end
        if _G.vr_camera_fix.camera_rot then rotation = _G.vr_camera_fix.camera_rot end
    end

    return { position = position, rotation = rotation }
end

local function get_vr_data()
    if not vrmod then return nil end
    local controllers = vrmod:get_controllers()
    if not controllers or #controllers < 2 then return nil end
    return {
        hmd_pos   = vrmod:get_position(0),
        right_pos = vrmod:get_position(controllers[2]),
        right_rot = vrmod:get_rotation(controllers[2]),
        left_pos  = vrmod:get_position(controllers[1]),
        left_rot  = vrmod:get_rotation(controllers[1]),
    }
end


-- ---------------------------------------------------------------------
-- Controller -> World Pose (RE9 Pattern)
-- ---------------------------------------------------------------------
local function controller_to_world(ctrl_pos_raw, ctrl_rot_raw, cam_data)
    if not ctrl_pos_raw or not cam_data then return nil, nil end

    local ctrl_pos = Vector3f.new(ctrl_pos_raw.x, ctrl_pos_raw.y, ctrl_pos_raw.z)

    if not cache.standing_origin_set then
        local so = vrmod:get_standing_origin()
        if so then
            cache.standing_origin = Vector3f.new(so.x, so.y, so.z)
        else
            local hmd = vrmod:get_position(0)
            cache.standing_origin = Vector3f.new(hmd.x, hmd.y, hmd.z)
        end
        cache.standing_origin_set = true
    end

    local ctrl_relative = vec3_subtract(ctrl_pos, cache.standing_origin)

    local rot_off = vrmod:get_rotation_offset()
    if rot_off then
        ctrl_relative = quat_rotate_vec3(rot_off, ctrl_relative)
    end

    local ctrl_world = quat_rotate_vec3(cam_data.rotation, ctrl_relative)
    local world_pos = vec3_add(cam_data.position, ctrl_world)

    local world_rot = cam_data.rotation
    if ctrl_rot_raw then
        local ok, ctrl_quat = pcall(function() return ctrl_rot_raw:to_quat() end)
        if ok and ctrl_quat then
            if rot_off then
                local ok_ro, rotated = pcall(function() return (rot_off * ctrl_quat):normalized() end)
                if ok_ro then ctrl_quat = rotated end
            end
            local ok2, combined = pcall(function()
                return (cam_data.rotation * ctrl_quat):normalized()
            end)
            if ok2 then world_rot = combined end

            -- OpenXR Rotations-Korrektur (uebernommen aus RE9, immer gleich)
            if vr_runtime == "openxr"
               and (openxr_correction.rot_pitch ~= 0 or openxr_correction.rot_yaw ~= 0 or openxr_correction.rot_roll ~= 0) then
                local oxr_rot_fix = quat_from_euler_deg(
                    openxr_correction.rot_pitch,
                    openxr_correction.rot_yaw,
                    openxr_correction.rot_roll
                )
                if oxr_rot_fix then
                    local ok_fix, fixed = pcall(function() return (world_rot * oxr_rot_fix):normalized() end)
                    if ok_fix then world_rot = fixed end
                end
            end

            -- Quest/Touch Rotations-Korrektur (RE9 ctrl_correction, nur metavr)
            if selected_controller == "metavr"
               and (ctrl_correction.rot_pitch ~= 0 or ctrl_correction.rot_yaw ~= 0 or ctrl_correction.rot_roll ~= 0) then
                local ctrl_rot_fix = quat_from_euler_deg(
                    ctrl_correction.rot_pitch,
                    ctrl_correction.rot_yaw,
                    ctrl_correction.rot_roll
                )
                if ctrl_rot_fix then
                    local ok_fix, fixed = pcall(function() return (world_rot * ctrl_rot_fix):normalized() end)
                    if ok_fix then world_rot = fixed end
                end
            end
        end
    end

    -- OpenXR Positions-Korrektur (lokal rotiert, danach addiert)
    if vr_runtime == "openxr"
       and (openxr_correction.pos_x ~= 0 or openxr_correction.pos_y ~= 0 or openxr_correction.pos_z ~= 0) then
        local oxr_pos_fix = Vector3f.new(openxr_correction.pos_x, openxr_correction.pos_y, openxr_correction.pos_z)
        local oxr_world_fix = quat_rotate_vec3(world_rot, oxr_pos_fix)
        world_pos = vec3_add(world_pos, oxr_world_fix)
    end

    -- Quest/Touch Positions-Korrektur (RE9 ctrl_correction, nur metavr)
    if selected_controller == "metavr"
       and (ctrl_correction.pos_x ~= 0 or ctrl_correction.pos_y ~= 0 or ctrl_correction.pos_z ~= 0) then
        local ctrl_pos_fix = Vector3f.new(ctrl_correction.pos_x, ctrl_correction.pos_y, ctrl_correction.pos_z)
        local ctrl_world_fix = quat_rotate_vec3(world_rot, ctrl_pos_fix)
        world_pos = vec3_add(world_pos, ctrl_world_fix)
    end

    return world_pos, world_rot
end


-- ---------------------------------------------------------------------
-- Joint Write
-- ---------------------------------------------------------------------
local function write_joint_pose(joint, pos, rot)
    if not joint or not pos then return end
    pcall(function() joint:call("set_Position", pos) end)
    if rot then
        pcall(function() joint:call("set_Rotation", rot) end)
    end
end

local function apply_hand_offset(pos, rot, off)
    if not pos then return pos, rot end
    if rot and (off.px ~= 0 or off.py ~= 0 or off.pz ~= 0) then
        pos = vec3_add(pos, quat_rotate_vec3(rot, Vector3f.new(off.px, off.py, off.pz)))
    end
    if rot and (off.rx ~= 0 or off.ry ~= 0 or off.rz ~= 0) then
        local rq = quat_from_euler_deg(off.rx, off.ry, off.rz)
        if rq then
            local ok, r = pcall(function() return (rot * rq):normalized() end)
            if ok then rot = r end
        end
    end
    return pos, rot
end

-- RE9-Muster: controller_to_world -> Offset -> Rot-only-Smoothing -> Joint-Write.
-- (RE9 attach_right_hand_to_controller, ohne RE9-Extras wie Arm-Clamp/Support-Dock.)
-- [HAND_CLAMP] Hand-Pin auf die Arm-Reichweite begrenzen (Daten von arm_chain veroeffentlicht:
-- __vr_arm_chain_<side>_root = Arm-Ursprung/Schulter, _maxreach = Armlaenge + erlaubtes
-- Schulter-Nachziehen). Liegt der Controller weiter weg, wird das HAND-Joint hier auf den
-- Radius geklemmt -> kein Wrist-Stretch (Hand bleibt am Arm-Ende statt zum Controller gezogen).
-- side = "R" / "L". Kein Eintrag (arm_chain aus/pausiert) -> unveraendert.
local function clamp_hand_to_arm_reach(hand_pos, side)
    if not hand_pos then return hand_pos end
    -- [MINECART] Arm-Reichweiten-Clamp im railcar AUS: der Cart schiebt den Body/die Schulter, dadurch
    -- reisst der Controller-Abstand oefter ueber die Armlaenge -> der Clamp hielt die Hand/Waffe am Arm-Ende
    -- zurueck ("haut ab"). Im Minecart soll die Waffe exakt am Controller sitzen -> hier ungeklemmt zurueck.
    if rawget(_G, "__re4_railcar_mode") == true then return hand_pos end
    local root = rawget(_G, "__vr_arm_chain_" .. side .. "_root")
    local maxr = rawget(_G, "__vr_arm_chain_" .. side .. "_maxreach")
    if not root or type(maxr) ~= "number" or maxr <= 0.05 then return hand_pos end
    local dx, dy, dz = hand_pos.x - root.x, hand_pos.y - root.y, hand_pos.z - root.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d <= maxr or d < 1e-6 then return hand_pos end
    local k = maxr / d
    return Vector3f.new(root.x + dx * k, root.y + dy * k, root.z + dz * k)
end

-- ---------------------------------------------------------------------
-- [TWO_HAND_IK] Waffe folgt der Linie rechte Hand -> linke Hand (beide Grips gehalten)
-- ---------------------------------------------------------------------
-- Welche Waffen zweihaendig gezielt werden (grosse Waffen; Pistolen sind einhaendig).
local TWO_HAND_AIM_WEAPONS = {
    [4100] = true, [4101] = true, [4102] = true,             -- Shotguns
    [4200] = true, [4201] = true, [4202] = true,             -- SMGs
    [4400] = true, [4401] = true, [4402] = true,             -- Rifles
    [4500] = true, [4501] = true, [4502] = true,             -- Magnums (zweihaendig anlegbar)
    [4600] = true,                                           -- Bolt Thrower
    [4701] = true,                                           -- Flamethrower (zweihaendig, Support-Hand flamesupport)
    [4900] = true, [4901] = true, [4902] = true,             -- Rocket Launcher
    [6000] = true, [6001] = true,                            -- DLC
    [6100] = true, [6101] = true, [6102] = true, [6104] = true, [6105] = true, [6106] = true,  -- SW
    [6111] = true, [6112] = true, [6113] = true, [6114] = true,
    -- (Boegen 4800/4801 + MC XM96E1 6300: keine Zweihand-Aim/Support-Hand bzw. einhaendige Pistole)
}
local function is_two_hand_aim_weapon()
    return wep_cache.id ~= nil and TWO_HAND_AIM_WEAPONS[wep_cache.id] == true
end

-- look-at-Rotation: +Z der erzeugten Rotation zeigt von from_pos nach to_pos.
local function look_at_rotation(from_pos, to_pos, up_hint)
    up_hint = up_hint or Vector3f.new(0, 1, 0)
    local dir = Vector3f.new(to_pos.x - from_pos.x, to_pos.y - from_pos.y, to_pos.z - from_pos.z)
    local len = math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
    if len < 0.0001 then return nil end
    dir = Vector3f.new(dir.x / len, dir.y / len, dir.z / len)
    local right = Vector3f.new(
        up_hint.y * dir.z - up_hint.z * dir.y,
        up_hint.z * dir.x - up_hint.x * dir.z,
        up_hint.x * dir.y - up_hint.y * dir.x)
    local rl = math.sqrt(right.x * right.x + right.y * right.y + right.z * right.z)
    if rl < 0.0001 then return nil end
    right = Vector3f.new(right.x / rl, right.y / rl, right.z / rl)
    local up = Vector3f.new(
        dir.y * right.z - dir.z * right.y,
        dir.z * right.x - dir.x * right.z,
        dir.x * right.y - dir.y * right.x)
    local m00, m01, m02 = right.x, up.x, dir.x
    local m10, m11, m12 = right.y, up.y, dir.y
    local m20, m21, m22 = right.z, up.z, dir.z
    local trace = m00 + m11 + m22
    local qw, qx, qy, qz
    if trace > 0 then
        local s = 0.5 / math.sqrt(trace + 1.0)
        qw = 0.25 / s; qx = (m21 - m12) * s; qy = (m02 - m20) * s; qz = (m10 - m01) * s
    elseif m00 > m11 and m00 > m22 then
        local s = 2.0 * math.sqrt(1.0 + m00 - m11 - m22)
        qw = (m21 - m12) / s; qx = 0.25 * s; qy = (m01 + m10) / s; qz = (m02 + m20) / s
    elseif m11 > m22 then
        local s = 2.0 * math.sqrt(1.0 + m11 - m00 - m22)
        qw = (m02 - m20) / s; qx = (m01 + m10) / s; qy = 0.25 * s; qz = (m12 + m21) / s
    else
        local s = 2.0 * math.sqrt(1.0 + m22 - m00 - m11)
        qw = (m10 - m01) / s; qx = (m02 + m20) / s; qy = (m12 + m21) / s; qz = 0.25 * s
    end
    return Quaternion.new(qw, qx, qy, qz)
end

-- Grip-Reads (vrmod). left_joystick/right_joystick JEDEN Aufruf frisch (nicht cachen -> stale).
local _grip_act = nil
local function grip_held(get_joystick)
    if not vrmod then return false end
    local ok, res = pcall(function()
        -- [STALE_HANDLE_FIX] Action-Handle JEDEN Frame frisch holen, nicht permanent cachen.
        -- Nach SteamVR-Szenenwechsel/Kapitel-Load/Save-Load geht das gecachte Handle stale ->
        -- is_action_active liefert lautlos false -> Grip tot bis "Reset Scripts". Frisch holen
        -- heilt sich in-place. (Gleiche Lehre wie holster.lua left_grip_pressed.)
        local act = vrmod:get_action_grip()
        local joy = get_joystick()
        if not (act and joy) then return false end
        _grip_act = act
        return vrmod:is_action_active(act, joy)
    end)
    return ok and res == true
end
local function is_left_grip_held()  return grip_held(function() return vrmod:get_left_joystick() end) end
local function is_right_grip_held() return grip_held(function() return vrmod:get_right_joystick() end) end

-- [BURST] Linker Trigger = weapon_dial-Action auf dem linken Controller (so liest binding.lua ihn,
-- ACT.weapon_dial; get_action_trigger ist nur der RECHTE Trigger). Nur LESEN -> die normale
-- Funktion des linken Triggers bleibt erhalten. Handle jeden Frame frisch (Stale-Handle-Fix).
local function is_left_trigger_held()
    if not vrmod then return false end
    local ok, res = pcall(function()
        local act = vrmod:get_action_weapon_dial()
        local joy = vrmod:get_left_joystick()
        if not (act and joy) then return false end
        return vrmod:is_action_active(act, joy)
    end)
    return ok and res == true
end

-- Inverse einer (Einheits-)Quaternion = Konjugierte. Built-in:conjugate bevorzugen.
local function quat_conjugate(q)
    if not q then return nil end
    local ok, c = pcall(function() return q:conjugate() end)
    if ok and c then return c end
    return Quaternion.new(q.w, -q.x, -q.y, -q.z)
end

-- Kuerzeste-Bogen-Rotation (Quaternion), die den Einheitsvektor a auf b dreht. KEIN Up-Vektor
-- -> kein Roll-Kippen/Flip beim Ueberkreuzen der Haende (anders als look-at). a, b normalisiert.
local function rotation_between(a, b)
    local d = a.x * b.x + a.y * b.y + a.z * b.z
    if d >= 0.999999 then return Quaternion.new(1, 0, 0, 0) end      -- gleich -> Identitaet
    if d <= -0.999999 then                                            -- antiparallel -> 180 Grad um Senkrechte
        local ax = Vector3f.new(1, 0, 0)
        if math.abs(a.x) > 0.9 then ax = Vector3f.new(0, 1, 0) end
        local cx = a.y * ax.z - a.z * ax.y
        local cy = a.z * ax.x - a.x * ax.z
        local cz = a.x * ax.y - a.y * ax.x
        local cl = math.sqrt(cx * cx + cy * cy + cz * cz)
        if cl < 1e-6 then return Quaternion.new(1, 0, 0, 0) end
        return Quaternion.new(0, cx / cl, cy / cl, cz / cl)
    end
    local cx = a.y * b.z - a.z * b.y
    local cy = a.z * b.x - a.x * b.z
    local cz = a.x * b.y - a.y * b.x
    local s = math.sqrt((1.0 + d) * 2.0)
    local inv = 1.0 / s
    local q = Quaternion.new(s * 0.5, cx * inv, cy * inv, cz * inv)
    local ok, n = pcall(function() return q:normalized() end)
    return (ok and n) or q
end

-- Modifiziert cache.rh_rot: blendet von der RH-Controller-Rotation zur look-at-Rotation
-- (RH-Welt -> rohe linke Controller-Welt). Aufruf in attach_right_hand NACH cache.rh_rot,
-- VOR dem Joint-Write -> Waffe (attach_weapon) und RH-Hand drehen gemeinsam.
-- [TWO_HAND_DIAG] Log nach reframework/data/re4_twohand.log. Gleiche Zeile -> 1x/s, sonst bis 20 Hz.
-- [LOGGING ENTFERNT 2026-08-19, Public Release] Der TWO_HAND_DIAG-Logger (schrieb nach
-- reframework/data/re4_twohand.log, war per _th_log.on=false schon abgeschaltet) ist raus.
-- Der leere Rumpf bleibt bewusst stehen, damit die vielen th_log("...")-Aufrufe im Two-Hand-Code
-- unveraendert gueltig bleiben -- exakt wie sqab_dlog/rlog/bow_log in den anderen Dateien.
local function th_log() end

local function apply_two_hand_aim(vr_data, cam_data)
    if (two_hand.blend or 0) <= 0 then two_hand._engage_swing0 = nil end   -- [REL_ENGAGE] disengaged -> Nullpunkt loeschen, naechstes Greifen re-baseline'd
    if not two_hand.enabled or not is_two_hand_aim_weapon() then two_hand.blend = 0.0; two_hand.active = false; two_hand._dbg_dist = -1
        th_log(two_hand.enabled and "not-2h-wpn" or "th-disabled"); return end
    -- [SWITCH_DOCK] Am Feuerwahl-Schalter (LE5 joint_05) gedockt -> KEINE Two-Hand-IK. Der
    -- Switch-Grab ist linker Grip + Hand nah an der Waffe = exakt die Two-Hand-Bedingung; ohne
    -- dieses Gate wuerde die Waffe beim Umstellen mit-rotieren. Switch/Burst-Verhalten bleibt.
    if support.switch_docked then two_hand.blend = 0.0; two_hand.active = false; two_hand._dbg_dist = -1; th_log("switch_dock"); return end
    -- [RACK_FREEZE RAUS 2026-07-31, "mach das rack freeze komplett raus bei allen Waffen"]
    -- Frueher wurde beim Slide-/Pump-/Bolt-Rack die Waffenrotation eingefroren (erst beim Greifen,
    -- dann ab 2 cm Zug). Beides fuehlte sich steif an: die LE5 versteifte schon beim Ansetzen, die
    -- Shotgun beim blossen Halten. Es gibt jetzt KEINEN Freeze und KEIN Ausrampen mehr: die Two-Hand-IK
    -- laeuft waehrend des Rackens/Pumpens ganz normal weiter, die Waffe dreht frei mit beiden Haenden.
    -- Die Z-Sperre der Pump-Shotgun (Waffe darf beim Pumpen nicht nach hinten wandern) sitzt NICHT
    -- hier, sondern als Positions-Korrektur in attach_right_hand -> [PUMP_NO_Z].
    -- Es gibt daher hier KEINEN Rack-Ausstieg mehr; der Rack-Zustand wird nur noch weiter unten
    -- gebraucht, um den Blend zu HALTEN (siehe [RACK_HOLD]).
    local _rack_on = rawget(_G, "__vr_slide_rack_active") == true
    -- [MAG-DOCK-LOCK] Mag/Shell in der linken Hand (oder <1.2s nach Insert) -> KEINE Two-Hand-IK
    -- (sonst dreht die Geste die Waffe zur "vollen" Hand). reload.lua setzt das Global.
    if rawget(_G, "__vr_mag_in_hand") then two_hand.blend = 0.0; two_hand.active = false; two_hand._dbg_dist = -1; th_log("mag_in_hand"); return end
    -- [SWITCH-GRIP-LATCH] Striker: der Grip am Drehschalter darf NICHT Two-Hand ausloesen (Schalter+
    -- Vordergriff zu nah). reload.lua setzt das Flag, bis losgelassen+neu gegriffen wird. Nur diese Waffe.
    if rawget(_G, "__vr_block_two_hand") then two_hand.blend = 0.0; two_hand.active = false; two_hand._dbg_dist = -1; th_log("block_two_hand"); return end
    -- [SKULL_SHAKER_COCK] Cock-Anim laeuft (nur wp6001) -> Two-Hand aus, Waffe folgt nur der rechten
    -- Hand (darauf setzt skullshaker_cock_spin den Pitch-Loop). Linke Hand ist vom Schaft geloest.
    if rawget(_G, "__vr_pump_anim_active") then two_hand.blend = 0.0; two_hand.active = false; two_hand._dbg_dist = -1; th_log("skull_cock"); return end
    if not (cache.rh_world and cache.rh_rot) then two_hand.active = false; th_log("no_rh_world"); return end

    -- rohe linke Controller-Welt (NICHT die gedockte sichtbare Hand -> sonst zirkulaer)
    local lh_raw = controller_to_world(vr_data.left_pos, vr_data.left_rot, cam_data)
    local target = 0.0
    local dist, lg, rg = -1, false, false
    if lh_raw then
        local dx, dy, dz = lh_raw.x - cache.rh_world.x, lh_raw.y - cache.rh_world.y, lh_raw.z - cache.rh_world.z
        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        two_hand._dbg_dist = dist
        lg, rg = is_left_grip_held(), is_right_grip_held()
        -- [DOCK_PROXIMITY] support.free_near (aus update_support_dock) verlangt, dass die freie Hand
        -- wirklich am Vordergriff ist -> Aim-Two-Hand dockt nicht mehr ueberall, sondern respektiert
        -- den Dock-Dist-Slider. (Vorframe-Wert; 1 Frame Latenz beim Engage ist unkritisch.)
        if lg and rg and support.free_near
            and dist >= two_hand.min_dist and dist <= two_hand.max_dist then
            target = 1.0
        end
    end
    -- [RACK_HOLD 2026-07-31, "beim Pump kann die Waffe nicht rotieren, die Two-Hand-IK geht nicht"]
    -- Waehrend Rack/Pump den Blend HALTEN statt neu zu bewerten. Grund: sobald der Slide/Pump gegriffen
    -- ist, faellt support.free_near weg (SLIDE_RACK-PRIORITY in update_support_dock) -> target waere 0
    -- und die Two-Hand-IK wuerde mitten im Zug ausrampen = Waffe haengt starr an der rechten Hand.
    -- Halten ist unkritisch, weil der Schwenk-Ansatz nur die RICHTUNG rechte->linke Hand auswertet:
    -- ein Zug ENTLANG der Laufachse aendert die kaum, die Waffe dreht also weiter frei mit den Haenden.
    if _rack_on then target = two_hand.blend end
    -- [TWO_HAND_IK] aktiv = greift gerade -> update_support_dock pinnt die linke Hand an den
    -- Vordergriff (sonst folgt sie dem eigenen Controller-Rot statt am Schaft zu kleben).
    -- Beim Rack NICHT aktiv melden: die linke Hand gehoert dem Slide, nicht dem Vordergriff.
    two_hand.active = (target == 1.0) and not _rack_on

    if two_hand.blend < target then two_hand.blend = math.min(two_hand.blend + two_hand.blend_speed, target)
    elseif two_hand.blend > target then two_hand.blend = math.max(two_hand.blend - two_hand.blend_speed, target) end

    if two_hand.blend <= 0.0 or not lh_raw then
        th_log(target == 1.0 and "engaging" or "idle",
            string.format("dist=%.3f L=%s R=%s min=%.2f max=%.2f", dist, tostring(lg), tostring(rg),
                two_hand.min_dist, two_hand.max_dist))
        return
    end
    th_log("ACTIVE", string.format("dist=%.3f L=%s R=%s", dist, tostring(lg), tostring(rg)))

    -- [TWO_HAND_IK] Schwenk-Ansatz (robust gegen Hand-Ueberkreuzen, KEIN Up-Vektor -> kein Roll-Flip):
    -- aktuelle Lauf-Welt-Richtung (einhaendig) auf die gewuenschte Richtung (rechte Hand -> linke
    -- Hand) drehen, nur die minimale Schwenk-Rotation. Der Roll bleibt der der rechten Hand
    -- (richtig kalibriert) -> keine Korrektur noetig.
    local rel = wep_cache.rel_rot
    if not rel then return end
    local wrot = nil
    pcall(function() wrot = (cache.rh_rot * rel):normalized() end)   -- aktuelle Waffenrotation (einhaendig)
    if not wrot then return end
    local cur_fwd = quat_rotate_vec3(wrot, Vector3f.new(0, 0, 1))    -- Lauf = +Z der Waffe
    local cl = math.sqrt(cur_fwd.x * cur_fwd.x + cur_fwd.y * cur_fwd.y + cur_fwd.z * cur_fwd.z)
    if cl < 1e-6 then return end
    cur_fwd = Vector3f.new(cur_fwd.x / cl, cur_fwd.y / cl, cur_fwd.z / cl)
    local dfx, dfy, dfz = lh_raw.x - cache.rh_world.x, lh_raw.y - cache.rh_world.y, lh_raw.z - cache.rh_world.z
    local dl = math.sqrt(dfx * dfx + dfy * dfy + dfz * dfz)
    if dl < 1e-5 then return end
    local des_fwd = Vector3f.new(dfx / dl, dfy / dl, dfz / dl)
    -- volle Schwenkung cur_fwd -> des_fwd (Lauf auf die Hand-Linie)
    local swing_full = rotation_between(cur_fwd, des_fwd)
    -- [REL_ENGAGE] Beim Greifen den Schwenk als Nullpunkt einfrieren; danach nur die AENDERUNG
    -- gegenueber diesem Nullpunkt anwenden. Beim Anlegen = Identitaet -> 0 Richtungsaenderung (kein
    -- Hochkippen); bewegt sich die Hand-Linie danach, schwenkt es relativ mit + re-alignt sich
    -- (Stabilisierung bleibt). Nullpunkt wird bei Disengage/Rack geloescht (s.o.) -> jedes Greifen neu.
    if not two_hand._engage_swing0 then two_hand._engage_swing0 = swing_full end
    local swing_rel = swing_full
    pcall(function() swing_rel = (swing_full * two_hand._engage_swing0:conjugate()):normalized() end)
    local swing = quat_slerp(Quaternion.new(1, 0, 0, 0), swing_rel, two_hand.blend)
    local newrot = nil
    pcall(function() newrot = (swing * cache.rh_rot):normalized() end)  -- Welt-Pre-Multiplikation
    if newrot then cache.rh_rot = newrot end
end

-- [KS4_EXIT_FADE 2026-07-17] Als GLOBALS (200-Local-Limit, s.o.). Fortschritt 0..1 (0=native Startpose,
-- 1=fertig am Controller) oder nil = aus. Setzt __re4_ks4_exit_t bewusst NICHT auf nil: beide Haende lesen
-- es im selben Frame, der erste Aufruf wuerde den zweiten sonst um den Fade bringen -- der Stempel wird bei
-- der naechsten Exit-Flanke ueberschrieben. Hier definiert (nicht oben), weil vec3_new/quat_slerp erst ab
-- hier als Upvalue sichtbar sind.
_G.__re4_ks4_exit_progress = function()
    local t = tonumber(rawget(_G, "__re4_ks4_exit_t"))
    if not t then return nil end
    local dur = _G.__re4_ks4fade.dur
    if dur <= 0.001 then return nil end
    local el = os.clock() - t
    if el < 0 or el >= dur then return nil end
    return el / dur
end
-- slot = "r"/"l". Lerpt (pos,rot) von der EINMAL eingefrorenen nativen Startpose zum uebergebenen Ziel;
-- ausserhalb des Fades unveraendert. joint = Hand-Joint (Quelle der nativen Startpose beim ersten Frame).
_G.__re4_ks4_exit_apply = function(joint, pos, rot, slot)
    local from = _G.__re4_ks4fade.from
    local rf = _G.__re4_ks4_exit_progress()
    if not rf then
        from[slot .. "_p"] = nil; from[slot .. "_r"] = nil
        return pos, rot
    end
    if not from[slot .. "_p"] and joint then
        local cp = nil; local cr = nil
        pcall(function() cp = joint:call("get_Position") end)
        pcall(function() cr = joint:call("get_Rotation") end)
        if cp then from[slot .. "_p"] = Vector3f.new(cp.x, cp.y, cp.z) end
        if cr then from[slot .. "_r"] = Quaternion.new(cr.w, cr.x, cr.y, cr.z) end
    end
    local fp = from[slot .. "_p"]
    local fr = from[slot .. "_r"]
    if fp and pos then
        pos = vec3_new(fp.x + (pos.x - fp.x) * rf, fp.y + (pos.y - fp.y) * rf, fp.z + (pos.z - fp.z) * rf)
    end
    if fr and rot then
        rot = quat_slerp(fr, rot, rf) or rot
    end
    return pos, rot
end

-- [RELOAD_LEXIT_FADE 2026-07-24] Wie der KS4-Austritt, aber NUR fuer die LINKE Hand und getriggert
-- vom Ende des Mag-Push-Docks (reload.lua/reload4_dlc.lua setzen __re4_reload_lexit_t bei der fallenden
-- Flanke). Lerpt die linke Hand von der letzten Magazin-Dock-Pose (__re4_reload_lexit_from, die der
-- linke-Hand-Pass unten JEDEN Dock-Frame frisch merkt) weich zum uebergebenen Controller-Ziel, statt
-- hart zu snappen. Dauer = geteilter Slider ms.push.release_dur (reload_adv). rf: 0=Magazin, 1=Controller.
-- Eigener Store, voellig getrennt vom KS4-Fade. Nur die linke Hand ruft das auf -> rechte bleibt roh.
_G.__re4_reload_lexit_from = _G.__re4_reload_lexit_from or { p = nil, r = nil }
_G.__re4_reload_lexit_apply = function(pos, rot)
    local t = tonumber(rawget(_G, "__re4_reload_lexit_t"))
    if not t then return pos, rot end
    local ms = rawget(_G, "__re4_reload_mag_slide")
    local dur = (ms and ms.push and tonumber(ms.push.release_dur)) or 0.0
    if dur <= 0.001 then return pos, rot end
    local el = os.clock() - t
    if el < 0 or el >= dur then return pos, rot end
    local from = _G.__re4_reload_lexit_from
    if not (from and from.p) then return pos, rot end
    local rf = el / dur
    if pos then
        pos = vec3_new(from.p.x + (pos.x - from.p.x) * rf, from.p.y + (pos.y - from.p.y) * rf, from.p.z + (pos.z - from.p.z) * rf)
    end
    if from.r and rot then rot = quat_slerp(from.r, rot, rf) or rot end
    return pos, rot
end

local function attach_right_hand(cam_data, vr_data)
    if not right_hand.enabled or not right_hand.joint then return end

    local ctrl_pos, ctrl_rot = controller_to_world(vr_data.right_pos, vr_data.right_rot, cam_data)
    if not ctrl_pos then return end

    -- rohe Controller-Rotation (pre-Offset) fuer andere Scripts (Aim-Richtung)
    cache.rh_aim_rot = ctrl_rot

    -- Basis-Korrektur = Barehands-Offset (Key "-1", Engine-ID bei unequipped),
    -- gilt IMMER (Controller -> Hand-Bone). Die Waffe sitzt damit von selbst
    -- in der Hand (Engine-Attach + Weapon-Attach).
    -- [ROHE CONTROLLER-POS 2026-07-19] Fuer Zonen-Messungen (Holster-Grab) wird die UNVERSCHOBENE
    -- Controller-Position gebraucht: hand_pos bekommt gleich per-Hand/per-Waffe Offsets, links einen
    -- anderen als rechts -- dadurch lagen die publizierten Positionen beider Haende unterschiedlich weit
    -- vom Holster-Anker, obwohl die Haende physisch an derselben Stelle waren.
    _G.__vr_rh_ctrl_raw = ctrl_pos
    local hand_pos, hand_rot = apply_hand_offset(ctrl_pos, ctrl_rot, get_weapon_offset("-1"))

    -- per-Waffe Offset OBENDRAUF: bewegt Hand PLUS Waffe zusammen (RE9-Logik)
    -- [EGG_5403 2026-07-18] AUSNAHME 5403 (Ei): sein Offset soll NUR das Ei bewegen, nicht Hand+Waffe. Darum
    -- hier die Hand-Anwendung fuer "5403" UEBERSPRINGEN; derselbe Offset wird in attach_weapon WAFFE-only auf
    -- die Ei-Pose gelegt (Muster wie MATILDA_STOCK). Alle anderen Waffen unveraendert.
    -- [EGG_5405 ADA 2026-07-21, "die Slider bewegen Ei UND Hand"] Adas Ei (5405) braucht dieselbe
    -- Ausnahme wie Leons 5403. Ohne sie wirkt derselbe Key ZWEIMAL: hier auf die Hand (Hand+Waffe
    -- zusammen) und zusaetzlich WAFFE-only in attach_weapon -> genau das beobachtete Doppelverhalten.
    if cache.weapon_key and cache.weapon_key ~= "-1" and cache.weapon_key ~= WEAPON_NONE_KEY
       and cache.weapon_key ~= "5403" and cache.weapon_key ~= "5405" then
        hand_pos, hand_rot = apply_hand_offset(hand_pos, hand_rot, get_weapon_offset(cache.weapon_key))
    end

    -- Smoothing: Rotation (RE9-Pattern) + optional Position (Anti-Zitter)
    local rh_alpha = rot_smooth.hands
    if rh_alpha > 0 then
        if smoothing.right_rot and hand_rot then
            hand_rot = quat_slerp(smoothing.right_rot, hand_rot, 1.0 - rh_alpha)
        end
    end
    local rp_alpha = pos_smooth.hands
    if rp_alpha > 0 and smoothing.right_pos then
        local k = 1.0 - rp_alpha
        hand_pos = Vector3f.new(
            smoothing.right_pos.x + (hand_pos.x - smoothing.right_pos.x) * k,
            smoothing.right_pos.y + (hand_pos.y - smoothing.right_pos.y) * k,
            smoothing.right_pos.z + (hand_pos.z - smoothing.right_pos.z) * k)
    end

    smoothing.right_pos = hand_pos
    smoothing.right_rot = hand_rot

    -- [HAND_CLAMP] Pin auf Arm-Reichweite begrenzen (nach dem Smoothing, vor dem Joint-Write).
    hand_pos = clamp_hand_to_arm_reach(hand_pos, "R")

    cache.rh_world = hand_pos
    cache.rh_rot   = hand_rot

    -- [TWO_HAND_IK] beide Haende + beide Grips -> Waffe folgt RH->LH-Linie (modifiziert cache.rh_rot)
    apply_two_hand_aim(vr_data, cam_data)

    -- [PUMP_NO_Z 2026-07-31] Waehrend eines Slide-Racks darf die Waffe nicht entlang ihrer
    -- LAENGSACHSE (waffen-lokales Z -- dieselbe Achse, auf der der Recoil-Kick sitzt) nach hinten zum
    -- Koerper wandern; beim Zug zieht die haltende Hand instinktiv mit. Sonst bleibt alles frei: X/Y,
    -- die komplette Rotation, kein Freeze. Referenz = Waffenposition im ersten Rack-Frame; danach wird
    -- jeden Frame NUR der Anteil entlang der AKTUELLEN Laengsachse herausgerechnet (Achse live gelesen
    -- -> Drehen der Waffe erzeugt keinen Sprung).
    -- [ALLE_2HAND_RACKS 2026-07-31] Galt zuerst nur fuer die Pump-Shotgun
    -- (__vr_shotgun_pump_active = grab_active + is_shotgun). Jetzt fuer JEDE Zweihandwaffe mit
    -- Slide-Rack: das generische __vr_slide_rack_active setzen ALLE reload-Dateien aus
    -- rack.grab_active (bzw. bolt.grab), und is_two_hand_aim_weapon haelt die einhaendigen
    -- Waffen (Pistolen, Red9-Flashlight-Rack) draussen. Waffen ohne Slide-Rack setzen das Global
    -- nie -> selbstgatend, keine Liste zu pflegen. Unterschied zur Shotgun: dort startet die Sperre
    -- erst ab echtem Zug (CFG.pump_start_pull), bei den uebrigen ab dem Griff an den Slide.
    -- [WEAPON_GIVE 2026-08-07, "eigentlich geht das nur, dass wir die Waffe auch clampen,
    -- sobald IK-2-Hand-Grip aktiv ist"] Der Pumpgriff sitzt ~45 cm vor der rechten Hand und liegt
    -- damit oft ausserhalb der linken Armreichweite. Bisher gab die HAND nach (clamp_hand_to_arm_reach)
    -- -> sie riss vom Griff ab. Jetzt gibt die WAFFE nach: sie weicht um genau den Reichweiten-
    -- Ueberschuss Richtung linke Schulter zurueck, der Griff kommt in Reichweite, die Hand bleibt drauf.
    -- Denselben Weg geht PUMP_NO_Z unten schon (korrigiert cache.rh_world statt der Hand).
    --
    -- NICHT WAEHREND DES PUMPENS ("die Waffe soll beim Pumpen nicht in Z nach hinten, das macht
    -- das Pumpen knackiger, sonst wabbelt die zum Koerper hin") -- dort hat PUMP_NO_Z allein das Wort.
    -- Weich ein- und ausgeblendet, sonst ruckt die Waffe im Moment des Reissens.
    do
        local pull = rawget(_G, "__re4_grip_pull")
        local pumping = (rawget(_G, "__vr_shotgun_pump_active") == true)
            or (rawget(_G, "__vr_slide_rack_active") == true)
        local want = (pull and wep_cache.id == 4100 and not pumping) and pull or nil
        local g = support.give
        if want or (g and (math.abs(g.x) > 1e-5 or math.abs(g.y) > 1e-5 or math.abs(g.z) > 1e-5)) then
            g = g or { x = 0, y = 0, z = 0 }
            local tx, ty, tz = want and want.x or 0, want and want.y or 0, want and want.z or 0
            local k = 0.25   -- Einblend-/Ausblendrate pro Aufruf
            g.x = g.x + (tx - g.x) * k
            g.y = g.y + (ty - g.y) * k
            g.z = g.z + (tz - g.z) * k
            support.give = g
            if cache.rh_world then
                cache.rh_world = Vector3f.new(cache.rh_world.x + g.x,
                                              cache.rh_world.y + g.y,
                                              cache.rh_world.z + g.z)
                -- [FIX 2026-08-07] hand_pos MUSS mit -- sonst wandert nur die Waffe und die rechte
                -- Hand bleibt am Controller stehen ("die rechte Hand haut von der Waffe ab").
                -- Exakt dieselbe Zeile fuehrt PUMP_NO_Z unten aus demselben Grund mit.
                hand_pos = cache.rh_world
            end
        end
    end

    do
        local rack_no_z = (rawget(_G, "__vr_shotgun_pump_active") == true)
            or (rawget(_G, "__vr_slide_rack_active") == true and is_two_hand_aim_weapon())
        if rack_no_z and cache.rh_world and cache.rh_rot then
            local wq = cache.rh_rot
            if wep_cache.rel_rot then
                local okw, w2 = pcall(function() return (cache.rh_rot * wep_cache.rel_rot):normalized() end)
                if okw and w2 then wq = w2 end
            end
            local ax = quat_rotate_vec3(wq, Vector3f.new(0, 0, 1))
            local r0 = two_hand._pump_ref_pos
            -- [PUMP_NO_Z MITWANDERN 2026-08-02, "Waffe bleibt in der Luft stehen und ich
            -- bekomme Gummiarme, wenn ich beim Pumpen rueckwaerts laufe"] Die Referenz war eine
            -- feste WELT-Position. Beim Laufen wandert der Spieler weg, der Anker blieb im Raum
            -- stehen -> die Sperre zog die Waffe auf den alten Punkt zurueck. Jetzt wird der Anker
            -- um die Spielerbewegung seit dem Rack-Start mitverschoben: gesperrt bleibt nur noch
            -- die ZIEHBEWEGUNG DER HAND, Laufen verschiebt Waffe und Anker gemeinsam.
            local cp = cam_data and cam_data.position
            if not r0 then
                two_hand._pump_ref_pos = Vector3f.new(cache.rh_world.x, cache.rh_world.y, cache.rh_world.z)
                two_hand._pump_ref_cam = cp and Vector3f.new(cp.x, cp.y, cp.z) or nil
            elseif ax then
                local ox, oy, oz = 0.0, 0.0, 0.0
                local c0 = two_hand._pump_ref_cam
                if c0 and cp then ox, oy, oz = cp.x - c0.x, cp.y - c0.y, cp.z - c0.z end
                local dx, dy, dz = cache.rh_world.x - (r0.x + ox),
                                   cache.rh_world.y - (r0.y + oy),
                                   cache.rh_world.z - (r0.z + oz)
                local d = dx * ax.x + dy * ax.y + dz * ax.z   -- Verschiebung ENTLANG der Laengsachse
                -- [PUMP_NO_X 2026-08-07] Zusaetzlich die QUERachse (waffen-lokales X, also
                -- links/rechts) sperren -- aber NUR wp4100 und NUR waehrend sich das Pump-Joint
                -- wirklich bewegt (__vr_shotgun_pump_active wird erst ab echtem Zug gesetzt, nicht
                -- schon beim Greifen). Damit bleibt der Pump eine reine Laengsbewegung; das
                -- seitliche Auswandern beim Ziehen faellt weg, ohne die Zweihand-IK sonst
                -- einzuschraenken. Y (hoch/runter) bleibt bewusst frei.
                local exd = 0
                local sx = nil
                if wep_cache.id == 4100 and rawget(_G, "__vr_shotgun_pump_active") == true then
                    sx = quat_rotate_vec3(wq, Vector3f.new(1, 0, 0))
                    if sx then exd = dx * sx.x + dy * sx.y + dz * sx.z end
                end
                if d ~= 0 or exd ~= 0 then
                    local nx = cache.rh_world.x - ax.x * d
                    local ny = cache.rh_world.y - ax.y * d
                    local nz = cache.rh_world.z - ax.z * d
                    if sx and exd ~= 0 then
                        nx = nx - sx.x * exd; ny = ny - sx.y * exd; nz = nz - sx.z * exd
                    end
                    cache.rh_world = Vector3f.new(nx, ny, nz)
                    hand_pos = cache.rh_world   -- Haltehand bleibt an der Waffe (kein Abrutschen)
                end
            end
        else
            two_hand._pump_ref_pos = nil   -- Pump vorbei -> naechster Pump misst frisch
            two_hand._pump_ref_cam = nil
        end
    end

    -- [SNAP_SOFTEN] Nur GROSSE 1-Frame-Spruenge der Waffenrotation (Rack-Freeze-Exit, harte Gate-
    -- Wechsel) sanft einblenden; kleine Aenderungen (normales Zielen) 1:1 durchlassen -> keine
    -- Aim-Latenz. Nur Two-Hand-Waffen (Pistolen haben keinen Schwenk -> keine Spruenge).
    if is_two_hand_aim_weapon() and two_hand._smooth_rot and cache.rh_rot then
        local a, b = two_hand._smooth_rot, cache.rh_rot
        local dot = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z
        if dot < 0 then dot = -dot end
        local releasing = (two_hand._rack_release or 0) > 0   -- [RACK_RELEASE] Fenster nach dem Freeze-Exit
        -- Im Release-Fenster IMMER lerpen (auch kleine Spruenge frozen->live), sonst nur grosse Spruenge.
        if releasing or dot < TWO_HAND_SNAP_COS then
            local eased = quat_slerp(two_hand._smooth_rot, cache.rh_rot, TWO_HAND_SNAP_EASE)
            if eased then cache.rh_rot = eased end
        end
        if releasing then two_hand._rack_release = two_hand._rack_release - 1 end
    end
    two_hand._smooth_rot = cache.rh_rot

    -- [RECOIL_ON_HAND 2026-07-31] Der Recoil sitzt jetzt auf der HAND, nicht mehr auf der Waffe
    -- (frueher in attach_weapon auf wpos/wrot). Die Waffe wird aus cache.rh_world/rh_rot abgeleitet
    -- (Pin) -> ein Kick HINTER dem Pin bewegte nur die Waffe, die Hand blieb stehen. Hier davor: Hand
    -- kippt, Waffe erbt den Kick ueber den Pin, Stuetzhand und arm_chain folgen von selbst.
    -- Drehpunkt ist damit das Handgelenk statt des Waffen-Origins (= der eigentliche Effekt).
    -- POSITION: steht NACH dem SNAP_SOFTEN-Baseline-Write (two_hand._smooth_rot) -- davor wuerde die
    -- Glaettung den Kick als "grossen Sprung" sehen und wegdaempfen.
    -- ROTATION: rc.rotation ist als Delta im WAFFEN-Frame gebaut. Damit die Waffe exakt dieselbe
    -- Drehung wie vorher bekommt, wird es in den Hand-Frame konjugiert (x = R*d*R^-1 mit R = rel_rot);
    -- W' = H*x*R = H*R*d. Ohne rel_rot (noch nicht kalibriert) direkt multiplizieren.
    do
        local rc = rawget(_G, "vr_recoil")
        if rc and rc.active and cache.rh_rot and cache.rh_world then
            if rc.position then
                -- Positions-Kick im WAFFEN-Frame (Laengsachse = nach hinten zum Spieler), wie vorher.
                local wq = cache.rh_rot
                if wep_cache.rel_rot then
                    local okw, w2 = pcall(function() return (cache.rh_rot * wep_cache.rel_rot):normalized() end)
                    if okw and w2 then wq = w2 end
                end
                local off = quat_rotate_vec3(wq, Vector3f.new(rc.position.x, rc.position.y, rc.position.z))
                if off then
                    cache.rh_world = vec3_add(cache.rh_world, off)
                    hand_pos = cache.rh_world   -- hj_pos wird unten aus hand_pos gebaut -> Joint kickt mit
                end
            end
            if rc.rotation then
                local d = rc.rotation
                if wep_cache.rel_rot then
                    local okc, dc = pcall(function()
                        return ((wep_cache.rel_rot * rc.rotation) * wep_cache.rel_rot:conjugate()):normalized()
                    end)
                    if okc and dc then d = dc end
                end
                local okr, r2 = pcall(function() return (cache.rh_rot * d):normalized() end)
                if okr and r2 then cache.rh_rot = r2 end
            end
        end
    end

    -- [REVOLVER COCK] wp4500: NUR die rechte Hand (Wrist-Roll + Versatz) zum Cocken bewegen, die WAFFE bleibt
    -- stehen. Die Waffe wird aus cache.rh_world/rh_rot platziert -> die lassen wir UNBERUEHRT; der Offset geht
    -- nur in die separate Hand-Joint-Pose (hj_pos/hj_rot) fuer write_joint_pose. So rollt die Hand um den Griff
    -- (Daumen erreicht den Hahn), ohne das Zielen zu verschieben. frac + Offsets aus reload2 (Globals). NUR 4500.
    local hj_pos, hj_rot = hand_pos, cache.rh_rot
    do
        local cf = tonumber(rawget(_G, "__vr_rev_cock_frac")) or 0
        local o = rawget(_G, "__vr_rev_cock_off")
        if cf > 0 and (wep_cache.id == 4500 or wep_cache.id == 4502) and type(o) == "table" then
            -- [SLERP] Ziel-Rotation einmal bauen, dann per cf slerpen (kuerzester Bogen) -> kein Euler-"Kreis"
            -- bei grossen Cock-Hand-Winkeln. Endpose (cf=1) identisch -> Broken Butterfly unkritisch.
            local qfull = quat_from_euler_deg(o.rx or 0, o.ry or 0, o.rz or 0)
            local rq = quat_slerp(Quaternion.new(1, 0, 0, 0), qfull, cf) or qfull
            local okr, nr = pcall(function() return (hj_rot * rq):normalized() end)
            if okr and nr then hj_rot = nr end
            local oko, off = pcall(function() return quat_rotate_vec3(hj_rot, Vector3f.new((o.px or 0) * cf, (o.py or 0) * cf, (o.pz or 0) * cf)) end)
            if oko and off then hj_pos = vec3_new(hj_pos.x + off.x, hj_pos.y + off.y, hj_pos.z + off.z) end
        end
    end

    -- [RELOAD-FADE] Kart: nach dem nativen Reload Hand+Waffe nicht hart zum Controller snappen, sondern vom
    -- erfassten nativen Reload-End-Pose ueber __re4_railcar_reload_fade (0..1) weich hinlerpen. Absolute Lerp
    -- vom EINMAL gecachten "from" -> mehrere Ticks/Frame konvergieren identisch (kein Over-Advance).
    do
        local rf = tonumber(rawget(_G, "__re4_railcar_reload_fade")) or 1.0
        if rawget(_G, "__re4_railcar_mode") == true and rf < 1.0 and right_hand.joint then
            if not rawget(_G, "__re4_reload_hand_fp") then
                local cp = right_hand.joint:call("get_Position")
                local cr = right_hand.joint:call("get_Rotation")
                if cp then _G.__re4_reload_hand_fp = Vector3f.new(cp.x, cp.y, cp.z) end
                if cr then _G.__re4_reload_hand_fr = Quaternion.new(cr.w, cr.x, cr.y, cr.z) end
            end
            local fp = rawget(_G, "__re4_reload_hand_fp")
            local fr = rawget(_G, "__re4_reload_hand_fr")
            if fp then
                hj_pos = vec3_new(fp.x + (hj_pos.x - fp.x) * rf, fp.y + (hj_pos.y - fp.y) * rf, fp.z + (hj_pos.z - fp.z) * rf)
                if cache.rh_world then
                    cache.rh_world = vec3_new(fp.x + (cache.rh_world.x - fp.x) * rf, fp.y + (cache.rh_world.y - fp.y) * rf, fp.z + (cache.rh_world.z - fp.z) * rf)
                end
            end
            if fr then
                hj_rot = quat_slerp(fr, hj_rot, rf) or hj_rot
                if cache.rh_rot then cache.rh_rot = quat_slerp(fr, cache.rh_rot, rf) or cache.rh_rot end
            end
        elseif rawget(_G, "__re4_reload_hand_fp") then
            _G.__re4_reload_hand_fp = nil; _G.__re4_reload_hand_fr = nil
        end
    end

    -- [KS4_EXIT_FADE] nach dem KS4-Austritt weich einblenden statt snappen (rechte Hand).
    -- Die WAFFE haengt NICHT am Joint, sondern an cache.rh_world/rh_rot (attach_weapon liest die spaeter)
    -- -> die MUSS mitgefadet werden, sonst steht die Waffe schon am Controller waehrend die Hand noch lerpt
    -- ( 2026-07-17: "Waffe snappy, Hand lerpt hin"). Zweiter Aufruf mit slot "r" nutzt dieselbe from
    -- (einmal aus dem Joint eingefroren) + dasselbe rf -> Hand und Waffe bewegen sich deckungsgleich.
    -- Exakt so macht es der [RELOAD-FADE] oben (fadet hj_pos UND cache.rh_world/rh_rot).
    hj_pos, hj_rot = _G.__re4_ks4_exit_apply(right_hand.joint, hj_pos, hj_rot, "r")
    if cache.rh_world or cache.rh_rot then
        cache.rh_world, cache.rh_rot = _G.__re4_ks4_exit_apply(right_hand.joint, cache.rh_world, cache.rh_rot, "r")
    end

    write_joint_pose(right_hand.joint, hj_pos, hj_rot)
    cache.rh_joint_pos = hj_pos
    cache.rh_joint_rot = hj_rot
end

-- ---------------------------------------------------------------------
-- [SUPPORT_HAND] Dock-Logik (Dev: vr_two_hands.apply_support_hand_docking,
-- hier inlined). State-Update laeuft 1x pro Frame im LockScene-Pass,
-- die Anwendung (Blend zur Dock-Pose) in allen 3 Phasen.
-- ---------------------------------------------------------------------
-- Welche Waffen ueberhaupt eine Support-Hand haben (Group A + Group B). ALLE anderen
-- (Eier, Granaten, Flammenwerfer 4701, PRL 4702, Boegen 4800/4801, MC 6300,...) bekommen
-- KEINE Support-Hand.
local SUPPORT_HAND_WEAPONS = {
    -- Group A: dockt AUTOMATISCH bei Naehe (kein Grip noetig)
    [4000] = true, [4001] = true, [4002] = true, [4003] = true, [4004] = true, [4005] = true, -- Pistolen + Don Quixote
    [4500] = true, [4501] = true, [4502] = true,                                               -- Magnums
    [6000] = true,                                                                             -- DLC Sentinel Nine
    [6103] = true, [6112] = true, [6113] = true,                                               -- SW Pistolen
    [6300] = true, [6301] = true,                                                              -- MC XM96E1 + Handcannon
    -- Group B: dockt NUR mit gehaltenem Left-Grip (+ in Range)
    [4100] = true, [4101] = true, [4102] = true,                                               -- Shotguns
    [4200] = true, [4201] = true, [4202] = true,                                               -- SMGs
    [4400] = true, [4401] = true, [4402] = true,                                               -- Rifles
    [4600] = true,                                                                             -- Bolt Thrower
    [4701] = true,                                                                             -- Flamethrower
    [4900] = true, [4901] = true, [4902] = true,                                               -- Rocket Launcher
    [6001] = true,                                                                             -- DLC Skull Shaker
    [6100] = true, [6101] = true, [6102] = true, [6104] = true, [6105] = true, [6106] = true,  -- SW Langwaffen
    [6111] = true, [6114] = true,                                                              -- SW Langwaffen
    [6304] = true,                                                                             -- MC Compound Bow
}

-- [GRIP_DOCK] Group B: Support-Hand dockt NUR wenn der Left-Grip gehalten wird (+ in Range).
-- Group-A-Waffen sind hier NICHT gelistet -> sie docken weiterhin automatisch bei Naehe.
local GRIP_DOCK_WEAPONS = {
    [4100] = true, [4101] = true, [4102] = true,
    [4200] = true, [4201] = true, [4202] = true,
    [4400] = true, [4401] = true, [4402] = true,
    [4600] = true,
    [4701] = true,
    [4900] = true, [4901] = true, [4902] = true,
    [6001] = true,
    [6100] = true, [6101] = true, [6102] = true, [6104] = true, [6105] = true, [6106] = true,
    [6111] = true, [6114] = true,
    [6304] = true,
}

local function is_support_hand_weapon()
    if not wep_cache.id then return false end
    return SUPPORT_HAND_WEAPONS[wep_cache.id] == true
end

local function vec3_distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local get_switch_joint   -- [BURST] forward-decl (Definition weiter unten, Body laeuft erst zur Laufzeit)

-- Dock-Pose = RH-Pose + Offset. [SUPPORT_AIM] Idle-Offset, optional gegen ein
-- Aim-Offset geblendet (nur wenn fuer die Waffe angelegt) -> Support-Hand kippt
-- beim Aim mit der Waffe mit.
-- [PUMP_GRIP 2026-08-07] ACHTUNG: diese Datei steht am 200-Local-Limit von Lua
-- (s. [[Notiz]]) -- ein einziges neues top-level `local` bricht
-- die ganze Datei mit "too many local variables". Darum haengt hier NICHTS an eigenen Locals:
-- die Waffenliste ist ein Global, der Joint-Cache lebt in der bestehenden support-Tabelle,
-- und der Lookup steht als Feld darin statt als eigene Funktion.
--
-- WELCHE Waffen: nur W-870 (4100) und Riot Gun (4101). Die Striker bleibt draussen.
-- Bei diesen beiden ist der Vordergriff das
-- bewegliche Slide-Teil. WELCHES Joint sagt uns re4_vr_reload.lua selbst
-- (__re4_rack_joint_name aus dessen JOINTS-Tabelle, dort slide = "_01") -> kein zweiter Ort,
-- an dem der Name gepflegt werden muss. Nur der NAME wandert, das Joint holen wir live
-- (ein Joint-Objekt ueber Frames ueberlebt keinen Savegame-Load).
_G.__re4_pump_grip_weapons = { [4100] = true, [4101] = true }   -- Striker (4102) BEWUSST NICHT: hatte nie Probleme
support.get_pump_joint = function()
    if not (wep_cache.tf and wep_cache.id) then return nil end
    if not _G.__re4_pump_grip_weapons[wep_cache.id] then return nil end
    local want = rawget(_G, "__re4_rack_joint_name")
    if type(want) ~= "string" or want == "" then return nil end
    if rawget(_G, "__re4_rack_joint_wid") ~= wep_cache.id then return nil end   -- Name gehoert zu einer anderen Waffe
    local j = wep_cache.tf:call("getJointByName", want)
    if j then support.pump_jn = want end
    return j
end

local function get_support_pose()
    if not (cache.rh_world and cache.rh_rot) then return nil, nil end
    -- [SWITCH_DOCK] am Schalter gedockt -> Switch-Offset statt Vordergriff (kein Aim-Blend).
    -- Auch waehrend der Dock noch AUSBLENDET (switch_blend_lock) -> kein Schaft-Flackern beim Loslassen.
    if support.switch_docked or (support.switch_blend_lock and (support.blend_factor or 0) > 0) then
        local sw = get_support_offset_switch(cache.weapon_key)
        if sw then
            -- [SWITCH_DOCK] Offset-Paar (idle->aim per aim_blend) aufloesen
            local function resolve(idle, aimoff)
                local px, py, pz = idle.pos_x, idle.pos_y, idle.pos_z
                local pitch, yaw, roll = idle.rot_pitch, idle.rot_yaw, idle.rot_roll
                if aimoff and support.aim_blend > 0.001 then
                    local b = support.aim_blend
                    px = px + (aimoff.pos_x - px) * b
                    py = py + (aimoff.pos_y - py) * b
                    pz = pz + (aimoff.pos_z - pz) * b
                    pitch = pitch + (aimoff.rot_pitch - pitch) * b
                    yaw   = yaw   + (aimoff.rot_yaw   - yaw)   * b
                    roll  = roll  + (aimoff.rot_roll  - roll)  * b
                end
                return px, py, pz, pitch, yaw, roll
            end
            local px, py, pz, pitch, yaw, roll = resolve(sw, get_support_offset_switch_aim(cache.weapon_key))
            -- [SWITCH_DOCK2] zweites Paar fuer die Single/Burst-Hebelstellung (nur wenn angelegt):
            -- per Hebel-Fortschritt t (0=Full-Auto-Stellung -> 1=Single/Burst) zwischen den beiden
            -- handgesetzten Posen blenden. Dann KEIN 1:1-Pivot-Follow (waere doppelt + sieht komisch aus).
            local sw2 = get_support_offset_switch2(cache.weapon_key)
            local use_endpoints = sw2 ~= nil
            if use_endpoints then
                local bx, by, bz, bpitch, byaw, broll = resolve(sw2, get_support_offset_switch2_aim(cache.weapon_key))
                -- [SWITCH_DOCK2] eigener geglaetteter Blend (support.switch2_blend, per-Waffe lerp),
                -- entkoppelt von der Hebel-Anim. Gilt fuer no-aim UND aim (beide oben in resolve).
                local t = support.switch2_blend or 0
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                px = px + (bx - px) * t
                py = py + (by - py) * t
                pz = pz + (bz - pz) * t
                pitch = pitch + (bpitch - pitch) * t
                yaw   = yaw   + (byaw   - yaw)   * t
                roll  = roll  + (broll  - roll)  * t
            end
            local off_pos = Vector3f.new(px, py, pz)
            local pos = vec3_add(cache.rh_world, quat_rotate_vec3(cache.rh_rot, off_pos))
            local rot = cache.rh_rot
            if pitch ~= 0 or yaw ~= 0 or roll ~= 0 then
                local rq = quat_from_euler_deg(pitch, yaw, roll)
                if rq then
                    local ok, r = pcall(function() return (cache.rh_rot * rq):normalized() end)
                    if ok and r then rot = r end
                end
            end
            -- [BURST] Hand folgt dem Hebel 1:1 (ein Offset-Paar, kein separates Burst-Offset): die
            -- fertige Hand-Pose um den joint-WELT-Pivot um burst_anim drehen (Achse = Joint-Welt-X).
            -- NUR wenn KEIN zweites Paar angelegt ist (sonst handgesetzte Endpunkte -> doppelt).
            local ba = support.burst_anim or 0
            if (not use_endpoints) and math.abs(ba) > 0.05 then
                pcall(function()
                    local j = get_switch_joint(); if not j then return end
                    local pivot = j:call("get_Position")
                    local jr = j:call("get_Rotation")
                    if not (pivot and jr) then return end
                    local jm = jr:to_mat4()
                    local ax, ay, az = jm[0].x, jm[0].y, jm[0].z
                    local al = math.sqrt(ax*ax + ay*ay + az*az); if al < 1e-5 then return end
                    ax, ay, az = ax/al, ay/al, az/al
                    local h = math.rad(ba) * 0.5; local s = math.sin(h)
                    local rq = Quaternion.new(math.cos(h), ax*s, ay*s, az*s)
                    local rel = Vector3f.new(pos.x - pivot.x, pos.y - pivot.y, pos.z - pivot.z)
                    local rel2 = quat_rotate_vec3(rq, rel)
                    pos = Vector3f.new(pivot.x + rel2.x, pivot.y + rel2.y, pivot.z + rel2.z)
                    rot = (rq * rot):normalized()
                end)
            end
            return pos, rot
        end
    end
    local a = get_support_offset(cache.weapon_key)
    local pos_x, pos_y, pos_z = a.pos_x, a.pos_y, a.pos_z
    local pitch, yaw, roll = a.rot_pitch, a.rot_yaw, a.rot_roll
    local aim = get_support_offset_aim(cache.weapon_key)
    if aim and support.aim_blend > 0.001 then
        local b = support.aim_blend
        pos_x = pos_x + (aim.pos_x - pos_x) * b
        pos_y = pos_y + (aim.pos_y - pos_y) * b
        pos_z = pos_z + (aim.pos_z - pos_z) * b
        pitch = pitch + (aim.rot_pitch - pitch) * b
        yaw   = yaw   + (aim.rot_yaw   - yaw)   * b
        roll  = roll  + (aim.rot_roll  - roll)  * b
    end
    -- [PUMP_GRIP 2026-08-07] Vordergriff AM PUMP-JOINT verankern statt an der rechten Hand.
    -- Nur fuer die Waffen aus PUMP_GRIP_JOINT und nur wenn grip_on gesetzt ist -- schlaegt der
    -- Joint-Lookup fehl, faellt es lautlos auf den normalen Pfad unten zurueck (nie schlechter
    -- als vorher). Bewusst NUR die Position: die Rotation bleibt wie gehabt an der rechten Hand,
    -- damit die eingestellte Handhaltung unveraendert bleibt.
    if _G.__re4_pump_grip_weapons[wep_cache.id] and a.grip_on ~= false then
        local pj = support.get_pump_joint()
        -- [GRIP_ANCHOR_RH] Anker gehoert zu EINER Waffe -- bei Wechsel wegwerfen, sonst klebt der
        -- Griff der vorigen Waffe an der neuen (Offset waere Muell).
        if support.grip_off_wid ~= wep_cache.id then
            support.grip_off, support.grip_rhprev, support.grip_off_wid = nil, nil, wep_cache.id
        end
        if pj then
            local jp = pj:call("get_Position")
            local jr = pj:call("get_Rotation")
            if jp and jr then
                -- [GRIP_SLIDE 2026-08-07] Z ist die Laengsachse im Joint-Frame (dieselbe, auf der
                -- reload den Pump-Zug misst). Ist ein Gleitbereich eingestellt, wird die Hand nicht
                -- auf grip_z festgenagelt, sondern folgt dem Controller ENTLANG dieser Achse --
                -- begrenzt auf [grip_z - grip_back, grip_z + grip_fwd]. X/Y bleiben fest, die Hand
                -- bleibt also immer auf dem Rohr. Beide Werte 0 -> exakt das bisherige Verhalten.
                local gz = a.grip_z or 0
                local gb, gf = a.grip_back or 0, a.grip_fwd or 0
                if gb > 0 or gf > 0 then
                    local lc = rawget(_G, "__vr_lh_ctrl_world")   -- roh, im selben Frame vorher gesetzt
                    if lc then
                        local okr, rl = pcall(function()
                            return jr:conjugate() * Vector3f.new(lc.x - jp.x, lc.y - jp.y, lc.z - jp.z)
                        end)
                        if okr and rl then
                            local lo, hi = gz - gb, gz + gf
                            local z = rl.z
                            if z < lo then z = lo elseif z > hi then z = hi end
                            gz = z
                        end
                    end
                end
                local gv = Vector3f.new(a.grip_x or 0, a.grip_y or 0, gz)

                -- [GRIP_ANCHOR_RH 2026-08-07] Zwei GEGENLAEUFIGE Fehler, darum getrennt behandelt:
                --
                -- (1) Beim LAUFEN friert die WELT-POSITION des Pump-Joints ein, waehrend die rechte
                -- Hand die Waffe 1:1 weitertraegt -- exakt der Befund aus [LDOCK_RH] in
                -- re4_vr_arm_chain.lua ("L_Hand trailt 0.24->0.46 m, weil das Dock einfriert").
                -- Andere Waffen haben das nie gehabt: ihr Zielpunkt ist rh_world + Offset, und
                -- die rechte Hand kann nicht einfrieren.
                -- (2) Beim ROTIEREN im Aim ist ein starrer rh-Anker falsch: gemessen sprang der
                -- Griffpunkt bis 15 cm in 10 ms, weil ein 45-cm-Hebel bei 20 Grad Drehung genau
                -- diesen Kreisbogen beschreibt. Im Two-Hand-Modus fuehrt die rechte Hand die
                -- Waffe eben NICHT starr -- sie wird zur linken Hand gedreht.
                --
                -- Loesung: nur die POSITION des Joints ueber die rechte Hand stabilisieren (gegen 1),
                -- die RICHTUNG dagegen live vom Joint nehmen (gegen 2) -- s. gv-Anwendung unten mit jr.
                -- [ZURUECK AUF EINFACH 2026-08-07, "jetzt geht gar nichts mehr"] Die reine
                -- Joint-Bindung (jps = jp) IST das Parenting und funktionierte. Die rh-Stabilisierung
                -- unten ist nur noch ein optionaler Zusatz gegen das Einfrieren beim Laufen -- AUS,
                -- bis einzeln nachgewiesen ist, dass sie mehr hilft als schadet.
                local jps = jp
                if a.grip_anchor == true and cache.rh_world and cache.rh_rot then
                    local pv = support.grip_rhprev
                    local mv = pv and math.sqrt((cache.rh_world.x - pv.x)^2 + (cache.rh_world.y - pv.y)^2
                                              + (cache.rh_world.z - pv.z)^2) or 999
                    support.grip_rhprev = cache.rh_world
                    if (not support.grip_off) or mv < 0.006 then   -- Schwelle wie in [LDOCK_RH]
                        local oki, iv = pcall(function() return cache.rh_rot:inverse() end)
                        if oki and iv then
                            local oko, ov = pcall(function()
                                return iv * Vector3f.new(jp.x - cache.rh_world.x,
                                                         jp.y - cache.rh_world.y,
                                                         jp.z - cache.rh_world.z)
                            end)
                            if oko and ov then support.grip_off = ov end
                        end
                    end
                    if support.grip_off then
                        local wo = quat_rotate_vec3(cache.rh_rot, support.grip_off)
                        if wo then
                            jps = Vector3f.new(cache.rh_world.x + wo.x,
                                               cache.rh_world.y + wo.y,
                                               cache.rh_world.z + wo.z)
                        end
                    end
                end
                -- Griff-Feinversatz mit der LIVE Joint-Rotation (jr), nicht mit der rechten Hand:
                -- dreht sich die Waffe, dreht der Griff korrekt mit dem Rohr statt auf einem
                -- Kreisbogen um die Faust zu schleudern.
                --
                -- [GRIP_NO_ROLL 2026-08-07, "beim ROLL haut die Hand komplett ab"] Gemessen:
                -- Hand steht still (Bewegung 0,0-0,1 cm), Griffpunkt springt bis 13,7 cm pro Frame.
                -- Grund ist reine Geometrie: grip_x/grip_y setzen den Griff neben die Rohrachse
                -- (hier 6,7 cm), und ein ROLL um die Achse zieht diesen Versatz auf einem Kreis mit
                -- 2 x 6,7 = 13,4 cm Durchmesser herum -- exakt der gemessene Wert.
                -- Fix: den Twist um die Rohr-Laengsachse (lokales Z) aus jr entfernen, bevor der
                -- Versatz angewandt wird. Die Hand behaelt damit ihre Lage am Rohr, waehrend sich
                -- die Waffe unter ihr dreht -- Rohrrichtung (Pitch/Yaw) wirkt weiter voll.
                -- Nur aktiv, wenn grip_noroll gesetzt ist -- sonst rollt der Griff mit (Standard).
                local jrg = jr
                if a.grip_noroll == true then   -- [GRIP_NO_ROLL] nur auf ausdruecklichen Wunsch
                    local okt, sw = pcall(function()
                        local n = math.sqrt(jr.w * jr.w + jr.z * jr.z)
                        if n < 1e-6 then return jr end                       -- 180 Grad um X/Y: kein Twist bestimmbar
                        local tw = Quaternion.new(jr.w / n, 0, 0, jr.z / n)  -- Twist-Anteil um lokales Z
                        return (jr * tw:conjugate()):normalized()            -- Swing = Rohrrichtung ohne Roll
                    end)
                    if okt and sw then jrg = sw end
                end
                local gp = vec3_add(jps, quat_rotate_vec3(jrg, gv))

                -- [WEAPON_GIVE 2026-08-07] Reichweiten-Ueberschuss der LINKEN Hand messen und
                -- als Ruecknahme-Vektor veroeffentlichen -- angewandt wird er in attach_right_hand
                -- auf die WAFFE (dort steht auch die Pump-Ausnahme). Dieselben zwei Werte, die auch
                -- clamp_hand_to_arm_reach benutzt, also exakt dieselbe Reichweiten-Definition.
                -- Der Griffpunkt wird gleich mitgezogen, sonst haengt er einen Pass hinterher.

                -- [Z_CLAMP 2026-08-07, gemessen] Der Pumpgriff sitzt fest 13,3 cm vor der
                -- rechten Hand; ob die linke Hand drankommt, entscheidet allein der Abstand zur
                -- linken Schulter. Gemessene Grenze (30 Haltepunkte): ueber = d - maxreach = 0.
                -- Ab da zog bisher clamp_hand_to_arm_reach die HAND zurueck -> sie riss vom Griff.
                -- Jetzt wird stattdessen die WAFFE entlang ihrer LAENGSACHSE zurueckgehalten, bis
                -- der Griff wieder auf der Reichweitenkugel liegt -- Hand und Waffe stoppen also
                -- gemeinsam, genau an dem Punkt, den man gehalten hat.
                -- t exakt aus dem Schnitt Strahl(gp, -achse) mit Kugel(L_root, maxreach).
                -- NUR wp4100 (W-870). Die Riot Gun bleibt vorerst aussen vor.
                if wep_cache.id == 4100 and two_hand.active and cache.rh_world and cache.rh_rot then
                    local lr = rawget(_G, "__vr_arm_chain_L_root")
                    local lm = rawget(_G, "__vr_arm_chain_L_maxreach")
                    -- [ACHSEN-FIX 2026-08-07, "die Waffe bewegt sich weiter von mir weg,
                    -- das ist das Gegenteil von Clamp"] cache.rh_rot ist die HAND-Rotation. Die
                    -- Laengsachse der WAFFE ist rh_rot * rel_rot -- genau so bildet PUMP_NO_Z sie
                    -- weiter unten. Mit der Handachse zeigte die Ruecknahme irgendwohin, teils nach
                    -- vorn statt zum Koerper.
                    local wq = cache.rh_rot
                    if wep_cache.rel_rot then
                        local okq, q2 = pcall(function() return (cache.rh_rot * wep_cache.rel_rot):normalized() end)
                        if okq and q2 then wq = q2 end
                    end
                    local ax = quat_rotate_vec3(wq, Vector3f.new(0, 0, 1))
                    -- [IK_RESERVE 2026-08-07, "der ganze linke Arm zittert beim Laufen"]
                    -- Gemessen: der Griffpunkt selbst ist ruhig (7 % Richtungsumkehr, 1,7 mm) --
                    -- das Zittern entsteht also NICHT am Ziel, sondern in der Arm-Kette. Ursache:
                    -- der Clamp haelt den Griff exakt auf der Reichweitenkugel, der Arm steht damit
                    -- dauerhaft auf 100 % Streckung. Dort ist Zwei-Knochen-IK am instabilsten (die
                    -- Ellbogenlage ist kaum noch bestimmt) -> Millimeter beim Laufen werden zu
                    -- grossen Ellbogenausschlaegen. Kleine Reserve = Arm nie ganz durchgestreckt.
                    if type(lm) == "number" then lm = lm - 0.015 end
                    if lr and type(lm) == "number" and lm > 0.05 and ax then
                        local al = math.sqrt(ax.x * ax.x + ax.y * ax.y + ax.z * ax.z)
                        if al > 1e-6 then
                            local nx, ny, nz = ax.x / al, ax.y / al, ax.z / al
                            -- [SCHLEIFE GEBROCHEN 2026-08-07, "am Clamp-Punkt kippt die Waffe"]
                            -- Gemessen werden MUSS die Lage OHNE die eigene Korrektur. Sonst misst der
                            -- Clamp seinen eigenen Effekt: gp kommt aus dem Joint, der Joint sitzt an
                            -- der bereits zurueckgezogenen Waffe -> ueber schrumpft -> Clamp laesst
                            -- nach -> Waffe vor -> ueber waechst. Dieses Pendeln dreht ueber die
                            -- Two-Hand-IK die Waffe mit = das Kippen. Also die schon angewandte
                            -- Ruecknahme (support.give) herausrechnen.
                            local sg = support.give
                            local mx = gp.x - (sg and sg.x or 0)
                            local my = gp.y - (sg and sg.y or 0)
                            local mz = gp.z - (sg and sg.z or 0)
                            local ex, ey, ez = mx - lr.x, my - lr.y, mz - lr.z
                            local ee = ex * ex + ey * ey + ez * ez
                            if ee > lm * lm then                       -- ausserhalb der Reichweite
                                local ea = ex * nx + ey * ny + ez * nz
                                local disc = ea * ea - ee + lm * lm
                                if disc >= 0 then
                                    local t = ea - math.sqrt(disc)     -- kleinste Ruecknahme
                                    if t > 0 then
                                        if t > 0.5 then t = 0.5 end    -- Sicherheitsdeckel
                                        -- nur veroeffentlichen; gp bleibt unangetastet, sonst wirkt
                                        -- die Ruecknahme doppelt (einmal ueber die Waffe, einmal hier)
                                        _G.__re4_grip_pull = { x = -nx * t, y = -ny * t, z = -nz * t }
                                    else
                                        _G.__re4_grip_pull = nil
                                    end
                                else
                                    _G.__re4_grip_pull = nil           -- Achse verfehlt die Kugel
                                end
                            else
                                _G.__re4_grip_pull = nil
                            end
                        end
                    end
                else
                    _G.__re4_grip_pull = nil
                end

                local grot = cache.rh_rot
                if pitch ~= 0 or yaw ~= 0 or roll ~= 0 then
                    local gq = quat_from_euler_deg(pitch, yaw, roll)
                    if gq then
                        local okg, rg = pcall(function() return (cache.rh_rot * gq):normalized() end)
                        if okg and rg then grot = rg end
                    end
                end
                return gp, grot
            end
        end
    end

    local off_pos = Vector3f.new(pos_x, pos_y, pos_z)

    local pos = vec3_add(cache.rh_world, quat_rotate_vec3(cache.rh_rot, off_pos))
    local rot = cache.rh_rot
    if pitch ~= 0 or yaw ~= 0 or roll ~= 0 then
        local rq = quat_from_euler_deg(pitch, yaw, roll)
        if rq then
            local ok, r = pcall(function() return (cache.rh_rot * rq):normalized() end)
            if ok and r then rot = r end
        end
    end
    return pos, rot
end

-- [BURST] LE5 Schalter-Umleg-Sound (Wwise-Trigger auf dem Weapon-SoundContainer, wie reload.lua).
local LE5_SWITCH_SOUND_ID = 812850326
local _le5_snd_sc_type = sdk.typeof("soundlib.SoundContainer")
local function play_le5_switch_sound()
    if not (wep_cache.go and _le5_snd_sc_type) then return end
    pcall(function()
        local scn = wep_cache.go:call("getComponent(System.Type)", _le5_snd_sc_type)
        if scn then scn:call("trigger(System.UInt32)", LE5_SWITCH_SOUND_ID) end
    end)
end

-- Dock/Undock-Entscheid + Blend-Fortschritt (nur im LockScene-Pass rufen)
local function update_support_dock(free_pos, support_pos)
    -- [SUPPORT_AIM] Aim-Dock-Blend rampen (__vr_aim_input fuehrt dem Kamera-Sprung voraus)
    do
        local aiming = (rawget(_G, "__vr_aim_input") == true) or support.aim_preview == true
            or support.switch_aim_preview == true or support.switch2_aim_preview == true
        local tgt = aiming and 1.0 or 0.0
        local sp_in, sp_out
        if support.switch_docked then
            local swa = get_support_offset_switch_aim(cache.weapon_key)   -- eigener Switch-Aim-Lerp
            sp_in  = (swa and swa.blend_in)  or 0.18
            sp_out = (swa and swa.blend_out) or 0.18
        else
            local aimcfg = get_support_offset_aim(cache.weapon_key)
            sp_in  = (aimcfg and aimcfg.blend_in)  or 0.18   -- no-aim -> aim
            sp_out = (aimcfg and aimcfg.blend_out) or 0.18   -- aim -> no-aim
        end
        if support.aim_blend < tgt then
            support.aim_blend = math.min(support.aim_blend + sp_in, tgt)
        elseif support.aim_blend > tgt then
            support.aim_blend = math.max(support.aim_blend - sp_out, tgt)
        end
    end

    -- [SWITCH_DOCK2] Pose1<->Pose2 Blend mit EIGENEM Lerp rampen (entkoppelt von der Hebel-Anim).
    -- Ziel = 1 in Single/Burst-Stellung (burst_active / Previews), sonst 0. Gilt no-aim + aim.
    do
        local b_tgt = (support.burst_active or support.burst_preview
            or support.switch2_preview or support.switch2_aim_preview) and 1.0 or 0.0
        local sw2 = get_support_offset_switch2(cache.weapon_key)
        local lsp = (sw2 and sw2.lerp) or 0.15
        if support.switch2_blend < b_tgt then support.switch2_blend = math.min(support.switch2_blend + lsp, b_tgt)
        elseif support.switch2_blend > b_tgt then support.switch2_blend = math.max(support.switch2_blend - lsp, b_tgt) end
    end

    -- [SWITCH_DOCK] Switch-Pose-Latch loeschen sobald der Dock vollstaendig ausgeblendet ist.
    -- Solange er noch > 0 ist, behaelt get_support_pose die Switch-Pose (kein Schaft-Flackern).
    if (support.blend_factor or 0) <= 0.0 then support.switch_blend_lock = false end

    -- [SLIDE_RACK PRIORITY] Der Slide-Rack (reload.lua) hat VORRANG vor allem hier: solange ein
    -- Rack noetig ist (Waffe auf 0 geschossen + reloaded) ODER die Hand gerade an den Slide
    -- gezogen wird, docken Support UND Switch NICHT -> die linke Hand gehoert dem Rack. Unser
    -- Support-/Schalter-/Burst-Kram greift erst wieder, wenn der Rack durch ist.
    local _needs_rack = rawget(_G, "__vr_needs_rack") == true
    local _blk_2h     = rawget(_G, "__vr_block_two_hand") == true     -- [SWITCH-GRIP-LATCH] Striker: Schalter-Grip darf nicht den Vordergriff docken
    local _pump_anim  = rawget(_G, "__vr_pump_anim_active") == true   -- [SKULL_SHAKER_COCK] Cock-Anim: linke Hand vom Schaft weg
    local _slide_dock = (tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0) > 0.001
    if _needs_rack or _blk_2h or _pump_anim or _slide_dock then
        support.switch_docked = false
        support.switch_latched = false
        support.prev_left_grip = false
        support.burst_neutral_fy = nil
        support.free_near = false   -- [DOCK_PROXIMITY] kein Two-Hand-Engage waehrend Rack
        -- [PUMP_SEAMLESS] Ist das Slide-Dock (Pump-Grab) der EINZIGE Grund, die Support-Hand NICHT
        -- loslassen: blend_factor OBEN halten -> hand_pos bleibt am Vordergriff (support_pos), das
        -- Slide-Dock (arm_chain via _sdb) reitet obendrauf und zieht 1:1 mit dem Pump. Sonst rampt
        -- blend_factor runter -> Basis faellt auf die rohe Controller-Hand (Support-Offset) -> die
        -- Hand hebt fuer 1-2 Frames vom Griff ab, bei Engage UND Release. Griff-Basis = nahtlos.
        if _slide_dock and not (_needs_rack or _blk_2h or _pump_anim) then
            support.docked = false   -- Clamp-Bypass laeuft ueber _slide_dock_b; Position haelt blend_factor oben
        elseif support.docked or support.blend_factor > 0 then
            support.docked = false
            support.target_blend = 0.0
            if support.blend_factor > 0 then
                support.blend_factor = math.max(support.blend_factor - support.blend_speed, 0.0)
            end
        end
        return
    end

    local allowed = support.enabled and is_support_hand_weapon()
        and cache.rh_world ~= nil and support_pos ~= nil and free_pos ~= nil

    if not allowed then
        support.switch_docked = false
        support.switch_latched = false
        support.prev_left_grip = false
        support.free_near = false
        if support.docked or support.blend_factor > 0 then
            support.docked = false
            support.target_blend = 0.0
            if support.blend_factor > 0 then
                support.blend_factor = math.max(support.blend_factor - support.blend_speed, 0.0)
            end
        end
        return
    end

    -- [DOCK_PROXIMITY] Einmal pro Frame: ist die freie Hand wirklich am Vordergriff? Gilt fuer ALLE
    -- Dock-Pfade. WICHTIG fuer den Two-Hand-IK (Aim): der nutzt absichtlich ein weites max_dist fuer
    -- den Schwenk und wuerde sonst beim Aimen UEBERALL docken (ignoriert den Dock-Dist-Slider). Mit
    -- diesem Flag respektiert auch der Aim-Dock exakt dock_threshold/undock_threshold. Hysterese.
    do
        local off0 = get_support_offset(cache.weapon_key)
        local dt = off0.dock_threshold or 0.110
        local ut = off0.undock_threshold or 0.150
        local d = math.min(vec3_distance(free_pos, support_pos), vec3_distance(free_pos, cache.rh_world))
        support.free_near = d < (support.free_near and ut or dt)
    end

    -- [MAG-DOCK-LOCK] Linke Hand haelt gerade ein Mag/Shell (oder <1.2s nach dem Insert) -> NICHT
    -- an den Schaft/Vordergriff docken (sonst springt die volle Hand vorne auf die Waffe). Hat
    -- Vorrang vor ALLEN Dock-Pfaden unten (Switch/Force/two_hand/Grip/Proximity). reload.lua setzt das Global.
    if rawget(_G, "__vr_mag_in_hand") then
        support.switch_docked = false
        support.switch_latched = false
        support.prev_left_grip = false
        if support.docked or support.blend_factor > 0 then
            support.docked = false
            support.target_blend = 0.0
            if support.blend_factor > 0 then
                support.blend_factor = math.max(support.blend_factor - support.blend_speed, 0.0)
            end
        end
        return
    end

    -- [SWITCH_DOCK] LE5: Schalter-Dock-Entscheid. Hat VORRANG vor Vordergriff/two_hand/Proximity.
    -- Bei gehaltenem Left-Grip (oder Force/Preview) entscheidet die Distanz freie Hand -> Schalter,
    -- ob an joint_05 statt an den Schaft gedockt wird. Eng (dock_dist) -> kein staendiges Umschalten.
    local sw = SWITCH_DOCK_WEAPONS[wep_cache.id] and get_support_offset_switch(cache.weapon_key)
    if sw then
        local grip = is_left_grip_held()
        local sw_off = Vector3f.new(sw.pos_x, sw.pos_y, sw.pos_z)
        local switch_pos = vec3_add(cache.rh_world, quat_rotate_vec3(cache.rh_rot, sw_off))
        local d_switch = vec3_distance(free_pos, switch_pos)
        support.switch_dbg_d = d_switch   -- [DIAG] live in der UI-Statuszeile
        -- Grip-Druck-FLANKE: einmalig latchen (Schalter wenn im Radius, sonst Schaft)
        if grip and not support.prev_left_grip then
            support.switch_latched = (d_switch < (sw.dock_dist or 0.060))
            -- frischer Grip am SCHAFT (nicht am Schalter) -> Switch-Pose-Latch sofort aufheben
            -- (sonst klebte die Hand bei schnellem Re-Grip waehrend des Ausblendens an der Switch-Pose)
            if not support.switch_latched then support.switch_blend_lock = false end
        end
        if not grip then support.switch_latched = false; support._sw_consumed = false end   -- [ONE-SHOT] Grip-Release hebt die Sperre auf
        support.prev_left_grip = grip
        -- Dock-Zustand: gelatcht solange Grip gehalten (kein Springen); Preview ueberschreibt
        if support.switch_preview or support.switch_aim_preview
            or support.switch2_preview or support.switch2_aim_preview then
            support.switch_docked = true
        else
            support.switch_docked = (grip and support.switch_latched) == true
        end
        -- [FIRE_MODE] am Schalter + Grip: Left-Trigger-FLANKE zykelt Full->Burst->Single->Full.
        -- Tastenkombi (Left-Grip wird ohnehin gehalten). Left-Trigger behaelt normale Funktion (nur gelesen).
        if support.switch_docked and grip then
            local trig = is_left_trigger_held()
            if trig and not support.prev_switch_trigger then
                support.fire_mode = fire_mode_next(wep_cache.id, support.fire_mode or 0)
                -- [SWITCH ONE-SHOT] Chicago Sweeper: nach EINEM Umlegen ist Left-Grip SOFORT wirkungslos
                -- (weder Schalter noch Vordergriff docken) bis der Grip physisch losgelassen + neu gedrueckt
                -- wird. switch_latched=false loest den Schalter; _sw_consumed sperrt zusaetzlich den
                -- Vordergriff-Dock (s. GRIP_DOCK-Gate unten). Geleert nur bei Grip-Release.
                if SWITCH_ONESHOT[wep_cache.id] then support.switch_latched = false; support._sw_consumed = true end
            end
            support.prev_switch_trigger = trig
        else
            support.prev_switch_trigger = false
        end
    else
        support.switch_docked = false
        support.switch_latched = false
        support.prev_left_grip = false
        support._sw_consumed = false
    end

    -- [FIRE_MODE] fire_mode gegen den Zyklus der aktuellen Waffe validieren (nach Waffenwechsel:
    -- z.B. LE5 auf Single=2 -> Sweeper hat nur {0,1} -> auf Full zuruecksetzen).
    do
        local ok_m = false
        for _, m in ipairs(fire_mode_cycle(wep_cache.id)) do if m == (support.fire_mode or 0) then ok_m = true; break end end
        if not ok_m then support.fire_mode = 0 end
    end
    -- [FIRE_MODE] burst_active = abgeleitet (Hebel weg von Full) -> Feuer-Block + switch2 nutzen das
    support.burst_active = (support.fire_mode or 0) ~= 0
    -- [FIRE_MODE] Sound bei JEDEM Moduswechsel (Flanke von fire_mode)
    if (support.fire_mode or 0) ~= (support.prev_fire_mode or 0) then
        play_le5_switch_sound()
        support.prev_fire_mode = support.fire_mode or 0
    end

    if support.switch_docked then
        support.switch_blend_lock = true   -- [SWITCH_DOCK] Latch: beim Loslassen die Switch-Pose ausblenden, NICHT auf Schaft springen
        support.docked = true
        support.target_blend = 1.0
        local sbs = (sw and sw.blend_speed) or 0.150   -- eigener, zackigerer Switch-Lerp
        if support.blend_factor < support.target_blend then
            support.blend_factor = math.min(support.blend_factor + sbs, support.target_blend)
        elseif support.blend_factor > support.target_blend then
            support.blend_factor = math.max(support.blend_factor - sbs, support.target_blend)
        end
        return
    end

    -- [TWO_HAND_IK] aktiv -> linke Hand an den Vordergriff pinnen. Blend mit blend_speed REINLERPEN
    -- (statt hart auf 1.0 zu snappen) -> gleicher weicher Andock wie der Nicht-Aim-Pfad unten.
    if support.force_dock or two_hand.active then
        support.docked = true
        support.target_blend = 1.0
        if support.blend_factor < support.target_blend then
            support.blend_factor = math.min(support.blend_factor + support.blend_speed, support.target_blend)
        end
        return
    end

    -- [GRIP_DOCK] Group-B-Waffen (Langwaffen) docken NUR mit gehaltenem Left-Grip. Ohne Grip
    -- gar nicht erst docken / sofort wieder loesen. Group A (Pistolen/Magnums) ist hier nicht
    -- gelistet -> dockt weiterhin automatisch bei Naehe. (Force Dock + two_hand.active oben
    -- bleiben unberuehrt; der two_hand-Pfad verlangt ohnehin schon Left-Grip.)
    if GRIP_DOCK_WEAPONS[wep_cache.id] and (not is_left_grip_held() or support._sw_consumed) then
        if support.docked or support.blend_factor > 0 then
            support.docked = false
            support.target_blend = 0.0
            if support.blend_factor > 0 then
                support.blend_factor = math.max(support.blend_factor - support.blend_speed, 0.0)
            end
        end
        return
    end

    local off = get_support_offset(cache.weapon_key)
    local dock_threshold = off.dock_threshold or 0.110
    local undock_threshold = off.undock_threshold or 0.150

    local distance_to_support = vec3_distance(free_pos, support_pos)
    local distance_to_weapon = vec3_distance(free_pos, cache.rh_world)
    local effective_distance = math.min(distance_to_support, distance_to_weapon)

    if not support.docked then
        if effective_distance < dock_threshold then
            support.docked = true
            support.target_blend = 1.0
        end
    else
        -- [GRIP_LATCH 2026-07-19] Ist die Hand ueber den LEFT GRIP angedockt (Group-B-
        -- Langwaffen), haelt der GRIP das Dock -- nicht die Distanz. Vorher konnte die IK-Hand
        -- mitten im Halten abreissen, sobald man mit dem Controller ueber undock_threshold
        -- hinauskam (Arm gestreckt, Waffe bewegt sich, Recoil-Nachlauf...). Das Loslassen
        -- des Grips loest weiterhin sauber -- das macht der GRIP_DOCK-Block weiter oben
        -- (~2429), der bei losem Grip docked=false setzt und rausspringt.
        -- BEWUSST NUR fuer GRIP_DOCK_WEAPONS: Group A (Pistolen/Magnums) dockt ohne Grip
        -- allein ueber Naehe -- dort MUSS die Distanz weiter loesen, sonst klebt die Hand fest.
        local grip_latched = GRIP_DOCK_WEAPONS[wep_cache.id] and is_left_grip_held()
        -- [GRIP_LATCH_REACH 2026-07-19]...aber NICHT unbegrenzt: haelt man die Waffe mit
        -- der rechten Hand weit weg (z.B. an den rechten Bildrand), zieht der Shoulder-Follow in
        -- arm_chain die Schulter mit und der linke Arm wird zu Gummi. Der Latch bricht daher, wenn
        -- der DOCKPUNKT weiter von der linken Oberarm-Wurzel entfernt ist als grip_latch_reach *
        -- der echten Armreichweite.
        -- WARUM Schulter->Dockpunkt und nicht Controller->Waffe: gestreckt wird der ARM, und der
        -- haengt an der Schulter -- wo der linke Controller gerade ist, ist dafuer egal.
        -- root/maxreach kommen live von arm_chain (publish_clamp_anchors) aus den ECHTEN
        -- Knochenlaengen -> gilt fuer Ada und Leon gleichermassen ohne Fixwert.
        -- Sind sie nil (hand_clamp aus), bleibt es beim alten reinen Distanz-Verhalten.
        if grip_latched then
            local l_root = rawget(_G, "__vr_arm_chain_L_root")
            local l_max  = rawget(_G, "__vr_arm_chain_L_maxreach")
            if l_root and l_max and support_pos then
                local reach = vec3_distance(l_root, support_pos)
                if reach > (l_max * (support.grip_latch_reach or 0.75)) then
                    grip_latched = false   -- ueberstreckt -> Distanz-Regel unten darf wieder loesen
                end
            end
        end
        -- [RECOIL-GATE RAUS 2026-07-31, "ist meine Hand ausserhalb der Distanz hat sie sich zu
        -- loesen, Recoil ist dabei furzegal"] Hier stand `and not recoil_active` -- solange der Recoil
        -- lief, wurde das Dock NICHT geloest und die Entfernung gar nicht mehr geprueft. Beim Feuern ist
        -- der Recoil praktisch durchgehend aktiv -> die linke Hand klebte an der Waffe, egal wie weit sie
        -- weg war. Gedacht war der Schutz gegen das Abreissen bei den paar Zentimetern Rueckstoss, er hat
        -- aber nicht zwischen "Rueckstoss" und "Hand einen halben Meter weg" unterschieden.
        -- Jetzt entscheidet allein die Distanz (undock_threshold, pro Waffe einstellbar).
        if not grip_latched
            and distance_to_support > undock_threshold
            and distance_to_weapon > undock_threshold
        then
            support.docked = false
            support.target_blend = 0.0
        end
    end

    if support.blend_factor < support.target_blend then
        support.blend_factor = math.min(support.blend_factor + support.blend_speed, support.target_blend)
    elseif support.blend_factor > support.target_blend then
        support.blend_factor = math.max(support.blend_factor - support.blend_speed, support.target_blend)
    end
end

local function attach_left_hand(cam_data, vr_data, update_dock)
    if not left_hand.enabled or not left_hand.joint then return end

    local ctrl_pos, ctrl_rot = controller_to_world(vr_data.left_pos, vr_data.left_rot, cam_data)
    if not ctrl_pos then return end

    _G.__vr_lh_ctrl_raw = ctrl_pos   -- [ROHE CONTROLLER-POS] s. rechte Hand
    local hand_pos, hand_rot = apply_hand_offset(ctrl_pos, ctrl_rot, hand_offset.L)

    local l_alpha = rot_smooth.hands
    if l_alpha > 0 then
        if smoothing.left_rot and hand_rot then
            hand_rot = quat_slerp(smoothing.left_rot, hand_rot, 1.0 - l_alpha)
        end
    end
    local lp_alpha = pos_smooth.hands
    if lp_alpha > 0 and smoothing.left_pos then
        local k = 1.0 - lp_alpha
        hand_pos = Vector3f.new(
            smoothing.left_pos.x + (hand_pos.x - smoothing.left_pos.x) * k,
            smoothing.left_pos.y + (hand_pos.y - smoothing.left_pos.y) * k,
            smoothing.left_pos.z + (hand_pos.z - smoothing.left_pos.z) * k)
    end
    smoothing.left_pos = hand_pos
    smoothing.left_rot = hand_rot

    -- [PUMP-ZUG] Rohe (UN-gedockte) linke Hand-Welt publizieren -> der Shotgun-Pump liest die fuer
    -- die Zug-Erkennung. MUSS vor der Dock-Ueberschreibung stehen, sonst gepinnt (Zug=0). So kann der
    -- Pump nahtlos aus der Two-Hand-Haltung starten (Hand bleibt sichtbar gedockt, Zug kommt vom Controller).
    _G.__vr_lh_ctrl_world = hand_pos

    -- [SUPPORT_HAND] Smoothing trackt die FREIE Hand; Dock-Blend kommt danach.
    local support_pos, support_rot
    if (support.enabled and is_support_hand_weapon()) or support.blend_factor > 0 then
        support_pos, support_rot = get_support_pose()
    end
    -- [PUMP] Live Support-Hand-Welt-Pose exportieren: reload nutzt sie als Pump-Hand-Ziel, damit
    -- beim Pumpen der getunte Support-Offset/-Rotation gilt (statt der rohen Slide-Joint-Pose).
    _G.__vr_support_hand_world_pos = support_pos
    _G.__vr_support_hand_world_rot = support_rot
    if update_dock == true then
        update_support_dock(hand_pos, support_pos)
    end
    if support.blend_factor > 0 and support_pos then
        if support.blend_factor >= 1.0 then
            hand_pos = support_pos
            hand_rot = support_rot or hand_rot
        else
            hand_pos = vec3_lerp(hand_pos, support_pos, support.blend_factor)
            if support_rot then
                hand_rot = quat_slerp(hand_rot, support_rot, support.blend_factor)
            end
        end
    end

    -- [HAND_CLAMP] Pin auf Arm-Reichweite begrenzen (vor cache + Joint-Write -> auch der
    -- veroeffentlichte __vr_lh_world ist geclampt, arm_chain solvt aufs gleiche Ziel).
    -- ABER: bei GEDOCKTER Support-Hand NICHT clampen -> sonst zieht der Clamp die Hand bei
    -- weit ausgeschwenkter Waffe (rechte Hand nach links) vom Vordergriff weg (Y-Drop Richtung
    -- linke Schulter). Dock hat Vorrang; der Arm darf strecken (wie im Dev-two_hands: "prefer dock").
    -- [PUMP_NO_CLAMP] Auch waehrend das Slide-Dock ein-/ausblendet (Pump-Grab) NICHT clampen:
    -- der SLIDE_RACK-PRIORITY-Block setzt support.docked=false BEVOR das Slide-Dock voll greift ->
    -- sonst yankt der Clamp die gestreckte Hand fuer 1-2 Frames zur Schulter (sichtbares Abheben
    -- vom Pump-Griff), bis der Slide-Blend hochkommt. Slide-Dock hat denselben "prefer dock"-Vorrang.
    local _slide_dock_b = tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0
    if not support.docked and _slide_dock_b <= 0.001 then
        hand_pos = clamp_hand_to_arm_reach(hand_pos, "L")
    -- [TWO_HAND_CLAMP 2026-07-19] AUSNAHME vom "prefer dock": im ZWEIHAND-IK (beide Grips an der
    -- Waffe) wird trotzdem geclampt. Drueckt man die Waffe von sich weg, ist die linke Hand vorne am
    -- Lauf und damit zuerst am Reichweiten-Ende -> ohne Clamp streckt sichtbar das Handgelenk.
    -- Geclampt wird auf dieselbe Armreichweite wie sonst; die Waffe folgt dann sauber, statt zu zerren.
    -- NUR im Zweihand-Fall: Pump-/Slide-Dock und normaler Support-Griff behalten ihren Vorrang.
    elseif two_hand.active then
        -- [DOPPELREGLER 2026-08-07, "sicher dass nicht der Arm-Clamp zittert, weil ich nach
        -- vorne gehe?"] Bei wp4100 haelt der Z-Clamp die WAFFE bereits so, dass der Pumpgriff in
        -- Reichweite bleibt. Laeuft der Hand-Clamp zusaetzlich, regeln ZWEI Regler dieselbe Groesse
        -- an derselben Grenze -- beim Laufen wandert die Schulter, die Reichweitenkugel wandert mit,
        -- und beide schaukeln sich auf = Zittern des ganzen Arms. Also hier aussetzen; die Waffe
        -- sorgt schon dafuer, dass die Hand drankommt (inkl. 1,5 cm Reserve gegen Vollstreckung).
        if wep_cache.id ~= 4100 then
            hand_pos = clamp_hand_to_arm_reach(hand_pos, "L")
        end
    end

    -- cache.lh_world = ROHER Controller: __vr_lh_world -> reload misst den Rack-Zug (frac). ROH lassen!
    cache.lh_world = hand_pos
    cache.lh_rot   = hand_rot

    -- [SLIDE_DOCK] Beim Slide-Grab die sichtbare Hand ans Dock: ROTATION + POSITION.
    -- [LDOCK_RH 2026-07-03] Position aufs von arm_chain ANGEKERTE Ziel (__vr_ldock_anchored, an der
    -- soliden rechten Hand) schreiben statt auf den Controller -> kein Flackern zwischen zwei Schreibern
    -- beim Rangehen (motion vs arm_chain zogen an verschiedene Ziele). Der Rack-Zug bleibt heil, weil
    -- cache.lh_world oben ROH bleibt (nur die sichtbare Joint-Pos dockt, nicht die Zug-Quelle).
    local sdock_rot = rawget(_G, "__vr_slide_hand_world_rot")
    local sblend    = tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0
    local wrot      = hand_rot
    local write_pos = hand_pos
    if sblend > 0.001 then
        if sdock_rot then
            wrot = (sblend >= 0.999) and sdock_rot or quat_slerp(hand_rot, sdock_rot, sblend)
        end
        -- arm_chain hat das L-Ziel schon fertig gelerpt -> 1:1 uebernehmen, KEIN zweiter Lerp hier
        -- (sonst zwei verschiedene Startpunkte = Flackern beim Ranblenden).
        local anch = rawget(_G, "__vr_ldock_anchored")
        if anch then write_pos = anch end
        -- [RELOAD_LEXIT_FADE 2026-07-24] Solange das Push-Dock aktiv ist, die AKTUELLE Magazin-Pose
        -- der linken Hand mitschreiben -> beim Dock-Ende ist das die "from"-Pose fuer den weichen Ausfade.
        _G.__re4_reload_lexit_from = { p = write_pos, r = wrot }
    end

    -- [KS4_EXIT_FADE] nach dem KS4-Austritt weich einblenden statt snappen (linke Hand).
    write_pos, wrot = _G.__re4_ks4_exit_apply(left_hand.joint, write_pos, wrot, "l")
    -- [RELOAD_LEXIT_FADE 2026-07-24] nach dem Mag-Push weich von der Magazin-Pose zum Controller
    -- ausfaden statt hart zu snappen (nur linke Hand; Dauer = Slider "Snap-Ausfaden s" in reload_adv).
    write_pos, wrot = _G.__re4_reload_lexit_apply(write_pos, wrot)

    write_joint_pose(left_hand.joint, write_pos, wrot)
    cache.lh_joint_pos = write_pos
    cache.lh_joint_rot = wrot
    -- [ARM_SYNC 2026-08-07, gemessen] __vr_lh_joint_pos (= das IK-Ziel von re4_vr_arm_chain.lua)
    -- wurde bisher NUR am Ende des normalen Ticks veroeffentlicht. attach_left_hand laeuft aber in
    -- mehreren Paessen -- in den uebrigen blieb das Global stehen, waehrend die Hand schon neu
    -- geschrieben war. Messung: bis 155 mm Unterschied im Ziel INNERHALB eines Frames, 32 % der
    -- Frames betroffen (re4_zzz_armzitter.log) -> die Kette loeste den Arm mehrfach verschieden
    -- = Zappeln des ganzen Arms beim Laufen. Hier gesetzt ist es in JEDEM Pass frisch.
    -- Gegated auf die zwei Pump-Shotguns, damit keine andere Waffe ihr Verhalten aendert.
    if _G.__re4_pump_grip_weapons[wep_cache.id] then
        _G.__vr_lh_joint_pos = write_pos
        _G.__vr_lh_joint_rot = wrot
    end
end

-- [REPIN_LEFT 2026-08-07, "wenn ich am Pump bin und dabei nach vorne gehe, zittert die Hand"]
-- URSACHE: der Pass "UpdateJointExpression" ruft attach_right_hand + attach_weapon, aber KEIN
-- attach_left_hand. Die Waffe (und damit jedes Joint an ihr) wird dort also neu positioniert,
-- die linke Hand bleibt auf dem Stand des vorherigen Passes stehen. Im Stehen unsichtbar; beim
-- Laufen wandert die Waffe pro Pass mehrere Millimeter -> die Hand springt zwischen "mitgezogen"
-- und "hinterher" = Zittern. Dieselbe Falle wie damals beim Messer in der linken Hand
-- ("alle-5-Paesse-Lektion", s. Kommentar im Haupt-Tick).
--
-- ABSICHTLICH SCHMAL: nur die sichtbare Joint-Pose wird nachgezogen. KEIN update_support_dock,
-- KEIN Smoothing, KEIN Slide-Dock-Blend, keine Fades -- die haben ihren Pass schon gehabt und
-- duerfen nicht zweimal pro Frame laufen. Es wird nur dann angefasst, wenn die Hand ohnehin
-- am Dock haengt (blend_factor >= 1) -- beim Ein-/Ausblenden bleibt der alte Pfad allein zustaendig.
--
-- GILT FUER ALLE ZWEIHANDWAFFEN. Ein Joint pro Waffe ist dafuer NICHT noetig:
-- get_support_pose liefert bei den Pumpguns den Joint-Punkt, bei allen anderen
-- rh_world + Offset -- und beide Quellen sind in diesem Pass frisch (attach_right_hand /
-- attach_weapon laufen direkt davor). Notausgang: support.repin_off = true.
support.repin_left = function()
    if support.repin_off then return end
    if not (left_hand.joint and left_hand.enabled) then return end
    -- [SCOPE 2026-08-07, "nicht dass du mir alle 2-Hand-Waffen verbastelst"] Lief kurz fuer
    -- ALLE Zweihandwaffen. Zurueckgezogen auf die zwei Pumpguns: die eigentliche Ursache war nicht
    -- das Timing dieses Passes, sondern die einfrierende Joint-Weltposition (s. GRIP_ANCHOR_RH) --
    -- und die gibt es nur dort, wo der Griffpunkt ueberhaupt aus einem Joint kommt.
    if not _G.__re4_pump_grip_weapons[wep_cache.id] then return end
    if (support.blend_factor or 0) < 0.999 then return end          -- nur im voll gedockten Zustand
    if (tonumber(rawget(_G, "__vr_slide_dock_blend_factor")) or 0) > 0.001 then return end  -- Slide-Dock schreibt selbst
    if rawget(_G, "__re4_knife_hand") == "left" then return end     -- Messerhand gehoert dem Messer
    local p, r = get_support_pose()
    if not p then return end
    write_joint_pose(left_hand.joint, p, r or cache.lh_joint_rot)
    cache.lh_joint_pos = p
    if r then cache.lh_joint_rot = r end
    -- [ARM_SYNC 2026-08-07, "es zittert beim Vorwaertslaufen, nicht nur die Hand -- der ganze
    -- Arm"] re4_vr_arm_chain.lua nimmt ihr IK-Ziel aus __vr_lh_joint_pos, und das wird sonst NUR am
    -- Ende des normalen Ticks veroeffentlicht. Zieht dieser Pass die Hand nach, ohne das Global
    -- mitzufuehren, loest die Arm-Kette weiter auf die alte Handposition -> Hand und Arm laufen
    -- auseinander, beim Laufen mit jedem Frame anders = Zittern der ganzen Kette.
    -- arm_chain rechnet danach noch in pre-BeginRendering, greift den frischen Wert also auch ab.
    _G.__vr_lh_joint_pos = p
    if r then _G.__vr_lh_joint_rot = r end
end


-- ---------------------------------------------------------------------
-- [FLASHLIGHT] 1:1 Port aus dem Developer-Movement (re4_vr_minecart.lua):
-- ac0000_00 (Taschenlampen-GO) folgt der LINKEN Hand; sein "light"-Child
-- (Lichtkegel) zeigt in Lampenrichtung. Bei Support-Hand (beide Haende an der
-- Waffe, support.docked) wandert der Kegel ans HMD (Kamera) und das Lampen-Mesh
-- wird ausgeblendet. Geht die Support-Hand weg -> Lampe wieder in der linken Hand.
-- Offsets 1:1 aus dem Developer uebernommen, JSON-persistent.
-- ---------------------------------------------------------------------
local FL_CFG_PATH = "re4_vr/re4_vr_flashlight.json"
local fl_enabled = true
local fl_keep_on_knife = true      -- [FL_KNIFE] FL in der linken Hand lassen + Gesten-Pose beim Knife-Wechsel
local fl_knife_pose = "pose1"      -- gespeicherte Gesten-Pose (re4_vr_gestures) fuer die FL-Hand
local fl_offset       = { pos_x=0.0, pos_y=0.0, pos_z=0.0, rot_pitch=0.0, rot_yaw=0.0,   rot_roll=0.0 }
local fl_light_offset = { pos_x=0.0, pos_y=0.0, pos_z=0.0, rot_pitch=0.0, rot_yaw=180.0, rot_roll=0.0 }
local fl_state = {
    flashlight_tf=nil, light_tf=nil, body_tf=nil, last_check=0,
    flashlight_mesh=nil, mesh_hidden=false,
    docked_offset       = { pos_x=0.0, pos_y=0.15, pos_z=-0.1, rot_pitch=-45.0, rot_yaw=0.0,   rot_roll=0.0 },
    docked_light_offset = { pos_x=0.0, pos_y=0.0,  pos_z=0.0,  rot_pitch=0.0,   rot_yaw=180.0, rot_roll=0.0 },
}
local T_MESH_FL = sdk.typeof("via.render.Mesh")

local function fl_load_cfg()
    local d = nil; pcall(function() d = json.load_file(FL_CFG_PATH) end)
    if type(d) ~= "table" then return end
    if d.enabled ~= nil then fl_enabled = d.enabled == true end
    if d.keep_on_knife ~= nil then fl_keep_on_knife = d.keep_on_knife == true end
    if type(d.knife_pose) == "string" then fl_knife_pose = d.knife_pose end
    local function load_off(dst, src)
        if type(src) ~= "table" then return end
        for k,_ in pairs(dst) do if type(src[k]) == "number" then dst[k] = src[k] end end
    end
    load_off(fl_offset, d.flashlight)
    load_off(fl_light_offset, d.light)
    load_off(fl_state.docked_offset, d.docked)
    load_off(fl_state.docked_light_offset, d.docked_light)
end
local function fl_save_cfg()
    pcall(function()
        json.dump_file(FL_CFG_PATH, {
            enabled = fl_enabled,
            keep_on_knife = fl_keep_on_knife, knife_pose = fl_knife_pose,
            flashlight = fl_offset, light = fl_light_offset,
            docked = fl_state.docked_offset, docked_light = fl_state.docked_light_offset,
        })
    end)
end
fl_load_cfg()

-- [FL_KNIFE] Wird das Knife gezogen waehrend die FL in der linken Hand ist,
-- versteckt die Engine die FL-Accessory + posed die Hand zur Knife-Griff-Pose.
-- Wir erzwingen: FL bleibt sichtbar an der linken Hand + die gecapturte Gesten-
-- Pose (re4_vr_gestures) wird auf die Finger geschrieben.
local FL_KNIFE_IDS = { [5000]=true, [5001]=true, [5002]=true, [5003]=true, [5006]=true, [6107]=true, [6108]=true, [6305]=true }
-- gestures ist ein Autorun-Script -> NICHT requiren (sonst doppelte Ausfuehrung =
-- doppelter UI-Tree/ImGui-ID-Konflikt). Modul kommt via _G-Handoff, lazy gelesen.
local function get_gestures_mod() return rawget(_G, "__re4_gestures") end
-- [POSE-STORE] Pose anwenden ueber reload.lua (Besitzer der Pose-Daten); gestures nur Fallback
-- (Uebergang/Notfall). Ziel: gestures.lua loeschbar -> reload liefert apply_pose.
local function apply_pose_runtime(name, blend)
    if not name or name == "" then return false end
    local f = rawget(_G, "__re4_reload_apply_pose")
    if f then local ok, r = pcall(f, name, blend or 1.0); if ok then return r end end
    local g = get_gestures_mod()   -- Fallback solange reload-Pfad nicht da
    if g and g.apply_pose then return pcall(function() return g.apply_pose(name, blend or 1.0) end) end
    return false
end

local function fl_knife_equipped()
    local id = get_equip_weapon_id()
    return id ~= nil and FL_KNIFE_IDS[id] == true
end

-- Kamera fuer den Docked-Fall (Kegel am HMD). WICHTIG: die Cam-Transform-Rotation
-- ist in VR nur der flache Game-Yaw — die HMD-Neigung (Pitch/Roll) legt die Runtime
-- separat drauf. Volle Blickrotation = Game-Cam-Yaw ⊗ rohes Headset (identisch zu
-- compute_assist_light_world_rotation in weapons.lua, das "matcht VR view").
local function get_flashlight_camera()
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local wm = nil; pcall(function() wm = cam:call("get_WorldMatrix") end)
    if not wm then return nil end

    -- Basis-Yaw: bevorzugt firstperson-Export (geflatteter Game-Cam-Yaw),
    -- sonst Cam-Transform-Rotation.
    local base = nil
    local cam_fix = rawget(_G, "vr_camera_fix")
    if cam_fix and cam_fix.active and cam_fix.camera_rot then
        base = cam_fix.camera_rot
    else
        local go = nil; pcall(function() go = cam:call("get_GameObject") end)
        local tf = go and nil
        if go then pcall(function() tf = go:call("get_Transform") end) end
        if tf then pcall(function() base = tf:call("get_Rotation") end) end
    end
    if not base then return nil end

    -- Headset OHNE Yaw draufmultiplizieren (nur Pitch/Roll): cam_fix.camera_rot
    -- enthaelt den Kopf-Yaw schon (hmd_movement faltet ihn via _Yaw rein). Der
    -- rotation_offset ist = -hmd_yaw -> (offset * rohes_headset) hebt den Headset-
    -- Yaw auf, sodass der Yaw NICHT doppelt zaehlt (sonst laeuft der Kegel voraus).
    local rot = base
    local hmd_quat, off_quat = nil, nil
    pcall(function() hmd_quat = vrmod:get_rotation(0):to_quat() end)
    pcall(function() off_quat = vrmod:get_rotation_offset() end)
    if hmd_quat and off_quat then
        local ok, w = pcall(function() return (base * (off_quat * hmd_quat)):normalized() end)
        if ok and w then rot = w end
    elseif hmd_quat then
        local ok, w = pcall(function() return (base * hmd_quat):normalized() end)
        if ok and w then rot = w end
    end

    return { position = Vector3f.new(wm[3].x, wm[3].y, wm[3].z), rotation = rot }
end

-- [FL_ON_DETECT] Die Engine NIMMT ac0000_00 aus der Szene, wenn die Lampe aus ist (verifiziert per
-- Probe: GO weg + ActiveLightType=NONE). -> "GO gefunden" = "FL an / in Benutzung". Darum: bei JEDEM
-- Fehlschlag die Handles auf nil setzen (sonst bliebe flashlight_tf nach FL-aus stale haengen). Zeit-
-- Drossel (1s) gilt jetzt auch fuer Fehlschlaege -> kein Scene-Walk pro Frame waehrend FL aus.
local function fl_find()
    local now = os.clock()
    if now - fl_state.last_check < 1.0 then
        return fl_state.flashlight_tf ~= nil
    end
    fl_state.last_check = now
    fl_state.flashlight_mesh = nil

    local function clear()
        fl_state.flashlight_tf = nil
        fl_state.light_tf = nil
        fl_state.flashlight_mesh = nil
        fl_state.light_comp = nil
        _G.__re4_fl_mesh = nil   -- [KS3] Referenz fuer materials.lua mit aufraeumen
    end

    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm or not scene_td then clear(); return false end
    local scene = nil
    pcall(function() scene = sdk.call_native_func(sm, scene_td, "get_CurrentScene") end)
    if not scene then clear(); return false end

    local body = nil
    pcall(function() body = scene:call("findGameObject(System.String)", "ch0a0z0_body") end)
    if not body then clear(); return false end

    fl_state.body_tf = nil
    pcall(function() fl_state.body_tf = body:call("get_Transform") end)
    if not fl_state.body_tf then clear(); return false end

    local fl_tf = nil
    pcall(function() fl_tf = fl_state.body_tf:find("ac0000_00") end)
    if not fl_tf or tostring(fl_tf) == "nil" then clear(); return false end
    fl_state.flashlight_tf = fl_tf

    fl_state.light_tf = nil
    pcall(function() fl_state.light_tf = fl_state.flashlight_tf:find("light") end)
    fl_state.light_comp = nil   -- [FL_SCOPE] Light-Component-Handle bei jedem Re-Find neu aufloesen

    return true
end

local function fl_set_mesh_visible(visible)
    if not fl_state.flashlight_tf then return end
    if not fl_state.flashlight_mesh and T_MESH_FL then
        local fl_go = nil
        pcall(function() fl_go = fl_state.flashlight_tf:call("get_GameObject") end)
        if fl_go then
            pcall(function() fl_state.flashlight_mesh = fl_go:call("getComponent(System.Type)", T_MESH_FL) end)
        end
    end
    if fl_state.flashlight_mesh then
        _G.__re4_fl_mesh = fl_state.flashlight_mesh   -- [KS3] materials.lua blendet die FL im fp_only aus (motion ist da dormant)
        pcall(function() fl_state.flashlight_mesh:call("set_Enabled", visible) end)
        fl_state.mesh_hidden = not visible
    end
end

-- [FL_SCOPE] Kegel (light-Child) hart an/aus. light-Child-GO Draw/Update + die Light-Component
-- selbst (Spot/Point/Light) togglen -> Kegel verschwindet wirklich (Mesh laeuft separat).
local function fl_set_cone_visible(visible)
    if not fl_state.light_tf then return end
    pcall(function()
        local go = fl_state.light_tf:call("get_GameObject")
        if not go then return end
        go:call("set_DrawSelf", visible)
        go:call("set_UpdateSelf", visible)
        if fl_state.light_comp == nil then
            for _, tn in ipairs({ "via.render.SpotLight", "via.render.PointLight", "via.render.Light" }) do
                local t = sdk.typeof(tn)
                local c = t and go:call("getComponent(System.Type)", t)
                if c then fl_state.light_comp = c; break end
            end
            if fl_state.light_comp == nil then fl_state.light_comp = false end   -- nicht gefunden -> nicht erneut suchen
        end
        if fl_state.light_comp then fl_state.light_comp:call("set_Enabled", visible) end
    end)
end

-- [FL_SCOPE_HIDE] Beim Zielen durch ein montiertes Scope/Sniper (weapons.lua setzt vr_scope_active)
-- die Lampe KOMPLETT verstecken: Mesh aus + Kegel aus, sonst haengt sie im Scope-Bild. Laeuft AUCH
-- im Scope-Killswitch (tick ist dort sonst aus) -> separat aus dem Killswitch-Zweig aufgerufen.
-- Rueckgabe true = gerade versteckt (apply_flashlight bricht dann ab, setzt die Lampe nicht an die Hand).
local function fl_scope_update()
    if not fl_enabled then return false end
    if not fl_find() then return false end
    if rawget(_G, "vr_scope_active") == true then
        fl_set_mesh_visible(false)
        fl_set_cone_visible(false)
        fl_state.scope_hidden = true
        return true
    elseif fl_state.scope_hidden then
        fl_set_cone_visible(true)   -- Scope vorbei -> Kegel zurueck (Mesh holt FL_FORCE_ON)
        fl_state.scope_hidden = false
    end
    return false
end

-- [FL_HANDS_FREE] Die linke Hand hat "was Besseres zu tun" -> Lampe ans HMD, Mesh aus,
-- damit die Hand frei fuer Support/Switch/Rack/Mag-Reload ist. Deckt ab:
-- * support.docked = Support-Hand am Schaft/Griff (beide Haende an der Waffe)
-- * support.switch_docked = Hand am Verstell-/Burst-Schalter
-- * __vr_slide_rack_active = Slide gerade gegriffen/gezogen
-- * __vr_needs_rack = Slide-Rack noetig (leer erkannt) -> Hand muss durchladen
-- * __vr_mag_in_hand = Magazin in der linken Hand (Reload laeuft)
-- Die jeweilige Aktions-Handpose (Rack/Mag/Switch/Support) ueberschreibt danach eh
-- die Finger -> die FL-Handpose ist damit "geloest".
local function fl_busy_reason()
    -- [FL_BUSY] An den DOCK-Zustand haengen (blend_factor>0 = Hand dockt/ist am Vorder- ODER
    -- Schaltergriff), NICHT an den gehaltenen Grip. Sonst fiele busy auf nil, sobald man den
    -- Grip loslaesst, obwohl die Hand noch voll gedockt ist (blend=1.0) -> "fl"-Pose kaeme zurueck.
    -- blend deckt Support + Switch ab (beide rampen blend); Rack/Mag setzen blend=0 -> separat.
    if (support.blend_factor or 0) > 0.0 then return "support_dock" end
    if rawget(_G, "__vr_slide_rack_active") then return "slide_rack_active" end  -- Slide gegriffen/gezogen
    if rawget(_G, "__vr_mag_in_hand") then return "mag_in_hand" end             -- Mag/Shell physisch in der Hand
    if rawget(_G, "__re4_knife_hand") == "left" or rawget(_G, "__re4_knife_left_clone") == true then return "knife_left" end    -- [KNIFE_HAND] Messer LINKS (equip ODER Klon) -> Kegel ans HMD, FL-Mesh aus
    return nil
end
local function fl_left_hand_busy()
    return fl_busy_reason() ~= nil
end

-- =====================================================================
-- [ADA_LAZY 2026-07-19] Default-Pose der LINKEN Hand, wenn sie nichts zu tun hat.
-- NUR ADA (Separate Ways) -- Leon bleibt komplett unberuehrt, hartes Body-Namen-Gate.
-- Die Pose-DATEN liegen in re4_vr_reload.json ("poses"); re4_vr_gestures.lua ist reines
-- Capture-Tool und wird am Ende geloescht.
--
-- WANN NICHT: exakt die Faelle aus fl_busy_reason oben -- das ist die im Projekt bereits
-- etablierte Definition von "Hand hat was Besseres zu tun" (Support-Dock, Slide-Rack,
-- Mag/Shell in der Hand, Messer links). Keine eigene Regel erfunden.
--
-- SUPPORT-DOCK wird bewusst NICHT hart abgeschaltet, sondern ueber (1 - blend_factor)
-- ausgeblendet: fl_busy_reason meldet "support_dock" schon ab blend > 0, ein hartes Aus
-- wuerde beim Andocken kurz auf die native Anim springen (Lazy -> nativ -> Support-Pose).
-- So blendet die Lazy-Pose genau in dem Mass aus, in dem die Support-Pose einblendet.
-- Damit ist auch "Support + Aim" abgedeckt: dort ist blend_factor 1 -> Lazy = 0.
--
-- REIHENFOLGE: laeuft als ERSTES im Pose-Block (vor fl_apply_hold_pose). Alles danach
-- (Taschenlampe, Support, Rack, Mag, Switch, Messer) ueberschreibt sie mit blend 1.0 ->
-- die Lazy-Pose kann keiner anderen Pose ins Gehege kommen.
-- =====================================================================
-- ALS GLOBALS, NICHT ALS LOCALS: motion.lua steht am Lua-200-Local-Limit im Haupt-Chunk
-- (vier neue locals haben es prompt gesprengt: "too many local variables"). Gleiches Muster
-- wie __re4_wildwest_fingers / __re4_apply_left_knife_pose weiter unten im Pose-Block.
-- Der Closure sieht die Upvalues (support, apply_pose_runtime, get_player_context, sc) trotzdem.
_G.__re4_ada_body_cache = _G.__re4_ada_body_cache or { is_ada = false, t = -1.0 }
_G.__re4_apply_ada_lazy_pose = function()
    -- Ada-Gate, 2x/s neu geprueft (nicht jeden Render-Pass -- die Funktion laeuft mehrfach pro Frame).
    local c = _G.__re4_ada_body_cache
    local now = os.clock()
    if (now - c.t) >= 0.5 then
        c.t = now
        local ctx  = get_player_context()
        local body = ctx and sc(ctx, "get_BodyGameObject")
        local nm   = body and sc(body, "get_Name")
        c.is_ada = (nm ~= nil and tostring(nm) == "ch3a8z0_body")
    end
    if not c.is_ada then return end
    -- [LAZY NUR BEI ZWEIHAND 2026-07-19] Die Lazy-Pose lief bei Ada fuer JEDE Waffe. Gewollt ist
    -- sie nur, wo die linke Hand ohne Aufgabe herunterhaengt -- also bei den Zweihandwaffen
    -- (Shotguns, SMGs inkl. TMP/MP-AF, Rifles, Crossbow, Sentinel, Chicago Sweeper, RL...).
    -- Bewusst dieselbe Liste wie TWO_HAND_AIM_WEAPONS: eine Quelle, kein zweiter Satz IDs, der
    -- beim naechsten Waffen-Zuwachs vergessen wird. Bei allen anderen bleibt die Hand nativ.
    if not TWO_HAND_AIM_WEAPONS[get_equip_weapon_id() or -1] then return end
    -- Busy-Gruende AUSSER Support-Dock: Hand gehoert jemand anderem -> gar nichts tun.
    if rawget(_G, "__vr_slide_rack_active") then return end
    if rawget(_G, "__vr_mag_in_hand") then return end
    if rawget(_G, "__re4_knife_hand") == "left" or rawget(_G, "__re4_knife_left_clone") == true then return end
    -- Support-Dock: gegenlaeufig zur Support-Pose ausblenden (s. Kommentar oben).
    local blend = 1.0 - (support.blend_factor or 0.0)
    if blend <= 0.001 then return end
    apply_pose_runtime("ADAlazypose", blend)
end

local function apply_flashlight(hand_pos, hand_rot)
    if not fl_enabled then return end
    if not fl_find() then return end
    if fl_scope_update() then return end   -- [FL_SCOPE] beim Scopen versteckt -> nicht an die Hand setzen
    if not hand_pos or not hand_rot then return end

    local docked = fl_left_hand_busy()
    local active_fl_offset = fl_offset
    local active_light_offset = fl_light_offset
    local base_pos, base_rot = hand_pos, hand_rot

    if docked then
        -- [SUPPORT] Kegel ans HMD, Lampen-Mesh aus.
        active_fl_offset = fl_state.docked_offset
        active_light_offset = fl_state.docked_light_offset
        local cam = get_flashlight_camera()
        if cam and cam.position and cam.rotation then
            base_pos = cam.position
            base_rot = cam.rotation
        end
        -- [FL_FORCE_OFF] Mesh JEDEN Frame zwangs-aus (nicht nur beim Uebergang). Sonst: laesst man
        -- Aim los waehrend die Support-Hand noch dockt, re-enabled die Engine die FL-Accessory ->
        -- das Mesh taucht an der HMD-Pos (= am Kopf) wieder auf. (Two-Hand-spezifisch; Pistolen
        -- toggeln die FL-Accessory beim Aimen nicht.) Symmetrisch zu [FL_FORCE_ON]. Kegel (light-
        -- Child) bleibt unberuehrt -> nur das Mesh-Component aus.
        fl_set_mesh_visible(false)
    else
        -- [FL_FORCE_ON] Solange die linke Hand nichts Besseres tut (= nicht busy): Lampe JEDEN Frame
        -- zwangs-sichtbar halten. Das Spiel blendet die FL-Accessory beim Aimen selbst aus (game-nativ);
        -- wir forcen DrawSelf/UpdateSelf am GO + Mesh-Enable zurueck. Ausnahme: Knife gezogen UND
        -- keep_on_knife=false -> der Engine ihr Verstecken lassen.
        if not (fl_knife_equipped() and not fl_keep_on_knife) then
            pcall(function()
                local go = fl_state.flashlight_tf:call("get_GameObject")
                if go then
                    go:call("set_DrawSelf", true)
                    go:call("set_UpdateSelf", true)
                end
            end)
            fl_set_mesh_visible(true)
        end
    end

    local fl_world_offset = quat_rotate_vec3(base_rot,
        Vector3f.new(active_fl_offset.pos_x, active_fl_offset.pos_y, active_fl_offset.pos_z))
    local fl_pos = Vector3f.new(base_pos.x + fl_world_offset.x, base_pos.y + fl_world_offset.y, base_pos.z + fl_world_offset.z)

    local fl_rot = base_rot
    if active_fl_offset.rot_pitch ~= 0 or active_fl_offset.rot_yaw ~= 0 or active_fl_offset.rot_roll ~= 0 then
        local ro = quat_from_euler_deg(active_fl_offset.rot_pitch, active_fl_offset.rot_yaw, active_fl_offset.rot_roll)
        if ro then local ok, r = pcall(function() return (base_rot * ro):normalized() end); if ok then fl_rot = r end end
    end

    if fl_state.flashlight_tf then
        pcall(function() fl_state.flashlight_tf:call("set_Position", fl_pos) end)
        pcall(function() fl_state.flashlight_tf:call("set_Rotation", fl_rot) end)
    end

    if fl_state.light_tf then
        local lo = quat_rotate_vec3(fl_rot,
            Vector3f.new(active_light_offset.pos_x, active_light_offset.pos_y, active_light_offset.pos_z))
        local light_pos = Vector3f.new(fl_pos.x + lo.x, fl_pos.y + lo.y, fl_pos.z + lo.z)
        local light_rot = fl_rot
        if active_light_offset.rot_pitch ~= 0 or active_light_offset.rot_yaw ~= 0 or active_light_offset.rot_roll ~= 0 then
            local lro = quat_from_euler_deg(active_light_offset.rot_pitch, active_light_offset.rot_yaw, active_light_offset.rot_roll)
            if lro then local ok, r = pcall(function() return (fl_rot * lro):normalized() end); if ok then light_rot = r end end
        end
        pcall(function() fl_state.light_tf:call("set_Position", light_pos) end)
        pcall(function() fl_state.light_tf:call("set_Rotation", light_rot) end)
    end
end

-- ============================================================
-- [ADA_FL 2026-07-20] Ada: Kegel IMMER ans HMD (wie Leons Support-Hand-/docked-Fall).
-- KOMPLETT EIGENER PFAD -- Leons fl_find/apply_flashlight bleiben unangetastet.
-- Struktur ist identisch, nur der Body heisst anders: ch3a8z0_body > ac0000_00 > light
-- (belegt per re4_zzz_ada_light_dump). Ada hat kein FL-Mesh -> nichts aus-/einzublenden.
-- Als Globals statt Locals: motion.lua steht am 200-Local-Limit.
-- ============================================================
_G.__re4_ada_fl = _G.__re4_ada_fl or { tf = nil, light_tf = nil, last_check = 0 }

_G.__re4_ada_fl_find = function()
    local st = _G.__re4_ada_fl
    local now = os.clock()
    if now - (st.last_check or 0) < 1.0 then return st.tf ~= nil end
    st.last_check = now

    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm or not scene_td then st.tf = nil; st.light_tf = nil; return false end
    local scene = nil
    pcall(function() scene = sdk.call_native_func(sm, scene_td, "get_CurrentScene") end)
    if not scene then st.tf = nil; st.light_tf = nil; return false end

    local body = nil
    pcall(function() body = scene:call("findGameObject(System.String)", "ch3a8z0_body") end)
    if not body then st.tf = nil; st.light_tf = nil; return false end
    local btf = nil
    pcall(function() btf = body:call("get_Transform") end)
    if not btf then st.tf = nil; st.light_tf = nil; return false end

    local fl_tf = nil
    pcall(function() fl_tf = btf:find("ac0000_00") end)
    if not fl_tf or tostring(fl_tf) == "nil" then st.tf = nil; st.light_tf = nil; return false end
    st.tf = fl_tf
    st.light_tf = nil
    pcall(function() st.light_tf = st.tf:find("light") end)
    return true
end

-- Nutzt BEWUSST Leons docked-Offsets (dieselben Slider wie sein Support-Hand-Fall) -- nur gelesen.
_G.__re4_ada_fl_apply = function()
    if not fl_enabled then return end
    if not _G.__re4_ada_fl_find() then return end
    local st = _G.__re4_ada_fl

    local cam = get_flashlight_camera()
    if not cam or not cam.position or not cam.rotation then return end
    local base_pos, base_rot = cam.position, cam.rotation
    local o  = fl_state.docked_offset
    local lo = fl_state.docked_light_offset
    if not o or not lo then return end

    local wo = quat_rotate_vec3(base_rot, Vector3f.new(o.pos_x, o.pos_y, o.pos_z))
    local fl_pos = Vector3f.new(base_pos.x + wo.x, base_pos.y + wo.y, base_pos.z + wo.z)

    local fl_rot = base_rot
    if o.rot_pitch ~= 0 or o.rot_yaw ~= 0 or o.rot_roll ~= 0 then
        local ro = quat_from_euler_deg(o.rot_pitch, o.rot_yaw, o.rot_roll)
        if ro then local ok, r = pcall(function() return (base_rot * ro):normalized() end); if ok then fl_rot = r end end
    end

    pcall(function() st.tf:call("set_Position", fl_pos) end)
    pcall(function() st.tf:call("set_Rotation", fl_rot) end)

    if st.light_tf then
        local l = quat_rotate_vec3(fl_rot, Vector3f.new(lo.pos_x, lo.pos_y, lo.pos_z))
        local light_pos = Vector3f.new(fl_pos.x + l.x, fl_pos.y + l.y, fl_pos.z + l.z)
        local light_rot = fl_rot
        if lo.rot_pitch ~= 0 or lo.rot_yaw ~= 0 or lo.rot_roll ~= 0 then
            local lro = quat_from_euler_deg(lo.rot_pitch, lo.rot_yaw, lo.rot_roll)
            if lro then local ok, r = pcall(function() return (fl_rot * lro):normalized() end); if ok then light_rot = r end end
        end
        pcall(function() st.light_tf:call("set_Position", light_pos) end)
        pcall(function() st.light_tf:call("set_Rotation", light_rot) end)
    end
end

-- Dispatch: Ada -> eigener HMD-Pfad, alles andere -> unveraendert Leons Pfad.
_G.__re4_fl_dispatch = function(lh_world, lh_rot)
    local fn = rawget(_G, "__re4_char_now")
    local ch = (type(fn) == "function") and fn() or nil
    if ch == "ada" then _G.__re4_ada_fl_apply() else apply_flashlight(lh_world, lh_rot) end
end

-- [FL_HOLD_POSE] Solange die Lampe AN ist (ac0000_00 in der Szene = FL in Benutzung) UND die Hand
-- nichts Besseres tut: die GECAPTURTE native Lampen-Haltung "fl" (reload.json POSES) forcen — fuer
-- ALLE Waffen UND mit Messer, in aim + non-aim. Sonst kippt die native Aim-/Schwung-Anim die linke
-- Hand (die die Lampe haelt). Loest sich unter fl_left_hand_busy -> Aktions-Pose uebernimmt.
-- Knife: nur wenn keep_on_knife (sonst der Engine ihr Verstecken lassen). FL aus -> GO weg ->
-- flashlight_tf=nil (fl_find raeumt den Handle) -> Pose kommt gar nicht erst = klebt nicht.
local FL_HOLD_POSE = "fl"
local function fl_apply_hold_pose()
    if not fl_enabled then return end
    if not fl_state.flashlight_tf then return end                    -- FL aus (GO weg) -> keine Pose
    if fl_knife_equipped() and not fl_keep_on_knife then return end  -- Knife + nativ erlaubt
    if fl_left_hand_busy() then return end                           -- Hand hat was Besseres zu tun
    apply_pose_runtime(FL_HOLD_POSE, 1.0)
end

-- [SLIDE_RACK] re4_vr_reload.lua publiziert __vr_rack_hand_pose (Pose-Name) waehrend
-- des Slide-Grabs/Einstell-Toggles. Hier im POST-ANIM-Pass anwenden, damit die Finger-
-- Pose die Engine-Animation ueberschreibt (gleicher Mechanismus wie die Knife-Pose).
-- [POSE_FADE] geteilte Fade-Dauer fuer Insert- UND Rack-Handpose (weiter unten nutzt die Mag-Pose
-- dieselbe Konstante). Sekunden bis komplett zurueck auf die native Anim (hoeher = weicher/traeger).
-- [POSE_FADE 2026-07-20] Dauer jetzt live regelbar. GLOBAL statt Konstante, weil motion.lua am
-- 200-Local-Limit sitzt (ein weiterer Top-Level-Local kippt die Datei). Gilt bewusst GLOBAL fuer alle
-- Waffen + beide Charaktere und zusaetzlich fuer die Mag-Pose -- so war die Konstante vorher auch.
-- Regler: "RE4VR - Motion" -> Messer-Baum... siehe UI unten. 0 = hart (alter Sprung).
_G.__re4_pose_fade_dur = _G.__re4_pose_fade_dur or 0.10
local POSE_FADE_DUR = 0.10   -- nur noch Fallback, falls das Global fehlt
local _rack_pose_fade = { name = nil, release_t = nil }
local function apply_rack_hand_pose_from_reload()
    local name = rawget(_G, "__vr_rack_hand_pose")
    local blend
    if name and name ~= "" then
        _rack_pose_fade.name = name
        _rack_pose_fade.release_t = nil
        blend = 1.0
    else
        if not _rack_pose_fade.name then return end
        if not _rack_pose_fade.release_t then _rack_pose_fade.release_t = os.clock() end
        local el = os.clock() - _rack_pose_fade.release_t
        local _fd = tonumber(rawget(_G, "__re4_pose_fade_dur")) or POSE_FADE_DUR
        if _fd <= 0.001 or el >= _fd then _rack_pose_fade.name = nil; return end
        blend = 1.0 - (el / _fd)
    end
    apply_pose_runtime(_rack_pose_fade.name, blend)
end

-- [SWITCH_DOCK] LE5: am Verstell-Schalter (joint_05) gedockt -> eigene Finger-Pose
-- (Faust; Zeigefinger + Daumen frei zum filigranen Umstellen). Im Post-Anim-Pass,
-- Blend = Dock-Fortschritt (eigener, zackigerer Lerp via switch blend_speed).
local SWITCH_HAND_POSE = "LE5SWITCH"
local SWITCH_INDEX_BONES = { "L_IndexF1", "L_IndexF2", "L_IndexF3" }
local function apply_switch_hand_pose()
    if not support.switch_docked then return end
    apply_pose_runtime(SWITCH_HAND_POSE, support.blend_factor or 1.0)
    -- [SWITCH_DOCK] additiver Zeigefinger-Curl NACH der Pose (zum Schliessen der "OK"-Geste),
    -- per-LE5 getunt. Gleicher Mechanismus wie der Mag-Daumen-Offset; auf alle 3 Index-Joints.
    local sw = get_support_offset_switch(cache.weapon_key)
    if not sw then return end
    local rx, ry, rz = sw.idx_rx or 0, sw.idx_ry or 0, sw.idx_rz or 0
    if (rx == 0 and ry == 0 and rz == 0) or not left_hand.joint then return end
    pcall(function()
        local tf = left_hand.joint:call("get_Owner")
        if not tf then return end
        local hx, hy, hz = math.rad(rx)*0.5, math.rad(ry)*0.5, math.rad(rz)*0.5
        local qx = Quaternion.new(math.cos(hx), math.sin(hx), 0, 0)
        local qy = Quaternion.new(math.cos(hy), 0, math.sin(hy), 0)
        local qz = Quaternion.new(math.cos(hz), 0, 0, math.sin(hz))
        local add = qz * qy * qx
        for _, bn in ipairs(SWITCH_INDEX_BONES) do
            local j = tf:call("getJointByName", bn)
            if j then
                local cur = j:call("get_LocalRotation")
                if cur then j:call("set_LocalRotation", (cur * add):normalized()) end
            end
        end
    end)
end

-- [KNIFE_FLIP] Waehrend der Flip DURCHDREHT die Finger kurz OEFFNEN (damit das Messer durchpasst),
-- KEINE Pose noetig -> additive Streck-Rotation auf alle rechten Finger-Joints. Betrag = bump(flip_lerp)
-- = 4*x*(1-x): 0 an beiden Enden (fest gegriffen), Peak bei halbem Flip -> automatisch synchron zum
-- Flip-Tempo (nutzt denselben knife_flip.lerp). Achse/Staerke per __re4_knife_flip_finger_deg (Slider).
local KNIFE_FLIP_FINGERS = {
    "R_Thumb1","R_Thumb2","R_Thumb3",
    "R_IndexF1","R_IndexF2","R_IndexF3",
    "R_MiddleF1","R_MiddleF2","R_MiddleF3",
    "R_RingF1","R_RingF2","R_RingF3",
    "R_PinkyF1","R_PinkyF2","R_PinkyF3",
}
local function knife_flip_finger_open()
    if rawget(_G, "__re4_knife_equipped") ~= true then return end
    -- [KNIFE_FLIP LINKS] Finger der HAND oeffnen, die das Messer haelt (sonst oeffnete beim Links-Flip
    -- faelschlich die rechte Hand). L-Bones inline aus R_->L_ abgeleitet (KEINE zweite Top-Level-Tabelle,
    -- motion ist am 200-Local-Limit!). L-Flexion nutzt -X (Spiegelung der +X-Strecke rechts).
    local is_left = rawget(_G, "__re4_knife_hand") == "left"
    local hand = is_left and left_hand or right_hand
    if not (hand and hand.joint) then return end
    local lp = knife_flip.lerp or 0
    local bump = 4.0 * lp * (1.0 - lp)   -- 0 an beiden Enden, 1 bei halbem Flip
    if bump <= 0.001 then return end
    local deg = tonumber(rawget(_G, "__re4_knife_flip_finger_deg")) or -35.0
    local h = math.rad(deg * bump) * 0.5
    if is_left then h = -h end
    local add = Quaternion.new(math.cos(h), math.sin(h), 0, 0)   -- additive Rotation um lokale X (Strecken)
    pcall(function()
        local tf = hand.joint:call("get_Owner"); if not tf then return end
        for _, bn in ipairs(KNIFE_FLIP_FINGERS) do
            if is_left then bn = bn:gsub("^R_", "L_") end
            local j = tf:call("getJointByName", bn)
            if j then local cur = j:call("get_LocalRotation"); if cur then j:call("set_LocalRotation", (cur * add):normalized()) end end
        end
    end)
end

-- [PISTOL_SUPPORT] Solange die linke Hand am Schaft/Griff gedockt ist, die gecapturte Finger-Pose
-- "pose1" (gestures.json -> reload POSES) auf die linke Hand schreiben. Blend = Dock-Fortschritt.
-- Gilt fuer ALLE einhaendig gehaltenen Support-Hand-Waffen (Pistolen + Magnums + Spezial-Einhaender)
-- -> NUR die Zweihand-/Foregrip-Waffen (GRIP_DOCK_WEAPONS, Group B) bekommen sie NICHT.
-- Reihenfolge: laeuft VOR Rack/Mag/Switch-Pose -> die ueberschreiben sie beim Reload (Vorrang).
local PISTOL_SUPPORT_POSE = "pose1"
-- [SUPPORT_POSE PER WAFFE] Override fuer die Support-Hand-Pose. Gesetzt = gilt AUCH fuer Zweihand-/
-- Grip-Dock-Waffen (z.B. TMP am Vordergriff). Nicht gesetzt = Standard pose1 nur fuer Einhaender.
-- [ADArocket 2026-07-19] SW Rocket Launcher: die linke Hand hatte OHNE Aim eine voellig
-- danebenliegende Pose, weil RL eine Grip-Dock-Waffe (Group B) ist und ohne Override GAR KEINE
-- Pose bekommt -> es lief die native Anim. Der hat die Aim-Handhaltung als "ADArocket"
-- gecaptured; hier gesetzt gilt sie in BEIDEN Zustaenden (apply_pistol_support_pose kennt kein
-- Aim -- es blendet nur mit support.blend_factor, also mit dem Dock-Fortschritt).
-- Die Pose-DATEN liegen in re4_vr_reload.json ("poses"), NICHT in gestures.json:
-- re4_vr_gestures.lua ist reines Capture-Tool und wird am Ende geloescht.
local SUPPORT_POSE_BY_WID = {
    [4200] = "TMPSUpport",   -- TMP: eigene Vordergriff-Pose
    [6106] = "ADArocket",    -- SW Rocket Launcher
    [6111] = "ADArocket",    -- SW Infinite Rocket Launcher (gleiches Modell)
}
local function apply_pistol_support_pose()
    if not (wep_cache.id and is_support_hand_weapon()) then return end
    if (support.blend_factor or 0) <= 0.0 then return end   -- nur waehrend/solange gedockt
    local pose = SUPPORT_POSE_BY_WID[wep_cache.id]
    if not pose then
        if GRIP_DOCK_WEAPONS[wep_cache.id] then return end  -- Zweihand ohne Override -> keine Pose
        pose = PISTOL_SUPPORT_POSE
    end
    apply_pose_runtime(pose, support.blend_factor or 1.0)
end

-- [SWITCH_DOCK] LE5: Feuerwahl-Hebel (joint_05) drehen = "Burst Fire Position". Nur die
-- LocalRotation wird ueberschrieben -> der Hebel dreht um seinen eigenen Pivot, die Position
-- bleibt an Ort und Stelle. Additiv auf die Engine-Anim, im Post-Anim-Pass. Laeuft solange die
-- LE5 equippt ist (unabhaengig vom Hand-Dock). Achse = lokales X (Pitch); falls falsch -> Y/Z.
-- reload.lua-Konvention: Waffen-Joints heissen kurz ("_04"/"_02"/...). Der Schalter-Joint ist
-- PER WAFFE verschieden -> eigene Kandidatenliste pro wid (NIE global teilen, sonst trifft ein
-- Joint-Name die falsche Waffe). LE5 = _05, Chicago Sweeper = _06. "joint_NN" jeweils als Fallback.
local SWITCH_JOINT_CANDIDATES = {
    [4202] = { "_05", "joint_05" },   -- LE5
    [4201] = { "_06", "joint_06" },   -- Chicago Sweeper
}
local switch_joint_name = nil
local switch_joint_wid  = nil   -- Cache nur gueltig fuer die Waffe, fuer die er angelegt wurde
get_switch_joint = function()
    if not (wep_cache.tf and wep_cache.id) then return nil end
    local cands = SWITCH_JOINT_CANDIDATES[wep_cache.id]
    if not cands then return nil end
    if switch_joint_name and switch_joint_wid == wep_cache.id then
        local j = wep_cache.tf:call("getJointByName", switch_joint_name)
        if j then return j end
    end
    switch_joint_name = nil
    for _, nm in ipairs(cands) do
        local j = wep_cache.tf:call("getJointByName", nm)
        if j then switch_joint_name = nm; switch_joint_wid = wep_cache.id; return j end
    end
    return nil
end
local function apply_switch_rotation()
    if not (wep_cache.tf and SWITCH_DOCK_WEAPONS[wep_cache.id]) then return end
    local sw = get_support_offset_switch(cache.weapon_key)
    if not sw then return end
    -- [FIRE_MODE] Hebel-Zielwinkel je Stellung: Full=0, Burst=burst_rot, Single=single_rot. Sanfter Schwenk.
    -- Previews zeigen den Burst-Winkel (Tuning der Burst-Stellung).
    local fm = support.fire_mode or 0
    local target
    if fm == 2 or support.single_preview then target = sw.single_rot or 0
    elseif fm == 1 or support.burst_preview or support.switch2_preview or support.switch2_aim_preview then target = sw.burst_rot or 0
    else target = 0 end
    support.burst_anim = support.burst_anim + (target - support.burst_anim) * (sw.lever_lerp or 0.18)
    if math.abs(support.burst_anim - target) < 0.05 then support.burst_anim = target end
    local deg = support.burst_anim
    if math.abs(deg) < 0.05 then return end
    pcall(function()
        local j = get_switch_joint()
        if not j then return end
        local cur = j:call("get_LocalRotation")
        if not cur then return end
        local h = math.rad(deg) * 0.5
        local add = Quaternion.new(math.cos(h), math.sin(h), 0, 0)   -- lokale X-Achse (Pitch)
        j:call("set_LocalRotation", (cur * add):normalized())
    end)
end

-- [MAG_HAND] re4_vr_reload.lua publiziert __vr_mag_hand_pose (Pose-Name) + Daumen-Offset
-- waehrend das Mag in der linken Hand getragen wird (Holster -> Waffe). Hier im POST-ANIM-
-- Pass anwenden (ueberschreibt die Engine-Animation). VOELLIG GETRENNT von der Rack-Pose.
-- [POSE_FADE] Wenn __vr_mag_hand_pose (Insert-/Halte-Pose) verschwindet (Insert fertig), NICHT hart
-- auf die native Anim zurueckspringen, sondern ueber POSE_FADE_DUR Sekunden zurueckblenden
-- (apply_pose_runtime nlerpt current->target, blend 1..0). ZEITBASIERT (nicht pro Frame), weil diese
-- Funktion mehrfach pro Frame laeuft (LockScene + BeginRendering) -> ein Pro-Frame-Dekrement waere
-- passabhaengig zu schnell. Gilt fuer ALLE reload.lua-Waffen (Pistolen/SMG/Shotgun/Magnum).
-- (POSE_FADE_DUR ist oben bei apply_rack_hand_pose_from_reload definiert -> geteilt.)
local _mag_pose_fade = { name = nil, trx = 0, try_ = 0, trz = 0, release_t = nil }
local function apply_mag_hand_pose_from_reload()
    local name = rawget(_G, "__vr_mag_hand_pose")
    local blend
    if name and name ~= "" then
        _mag_pose_fade.name = name
        _mag_pose_fade.trx  = rawget(_G, "__vr_mag_hand_trx") or 0
        _mag_pose_fade.try_ = rawget(_G, "__vr_mag_hand_try") or 0
        _mag_pose_fade.trz  = rawget(_G, "__vr_mag_hand_trz") or 0
        _mag_pose_fade.release_t = nil
        blend = 1.0
    else
        if not _mag_pose_fade.name then return end
        -- [POSE_CROSSFADE 2026-08-15] Laeuft gerade die Druecken-Pose (reload_adv veroeffentlicht ihren
        -- Blend als __re4_push_blend), dann GEGENLAEUFIG dazu ausblenden statt zeitbasiert gegen die
        -- native Animation. Grund: diese Funktion schreibt im spaeteren Pass, ueberdeckte also die
        -- laengst fertige Push-Pose -- und wenn der Zeit-Fade endete, erschien sie schlagartig (snappy).
        -- So ergibt sich ein echter Uebergang zwischen den beiden Posen; das Tempo bestimmt weiterhin
        -- der Regler "Rein-Lerp s" der Push-Geste. Ohne laufenden Push bleibt alles wie bisher.
        local _pb = tonumber(rawget(_G, "__re4_push_blend"))
        if _pb and _pb > 0.0 then
            _mag_pose_fade.release_t = nil    -- ein spaeterer Zeit-Fade faengt sauber bei 0 an
            blend = 1.0 - _pb
            if blend <= 0.001 then _mag_pose_fade.name = nil; return end
        else
        if not _mag_pose_fade.release_t then _mag_pose_fade.release_t = os.clock() end
        local el = os.clock() - _mag_pose_fade.release_t
        local _fd = tonumber(rawget(_G, "__re4_pose_fade_dur")) or POSE_FADE_DUR
        if _fd <= 0.001 or el >= _fd then _mag_pose_fade.name = nil; return end
        blend = 1.0 - (el / _fd)
        end
    end
    apply_pose_runtime(_mag_pose_fade.name, blend)
    -- Daumen-Spreizung additiv auf L_Thumb1 (NACH der Pose), mit blend skaliert (fadet mit)
    local trx = _mag_pose_fade.trx * blend
    local try_ = _mag_pose_fade.try_ * blend
    local trz = _mag_pose_fade.trz * blend
    if (trx ~= 0 or try_ ~= 0 or trz ~= 0) and left_hand.joint then
        pcall(function()
            local tf = left_hand.joint:call("get_Owner")
            local thumb = tf and tf:call("getJointByName", "L_Thumb1")
            if thumb then
                local cur = thumb:call("get_LocalRotation")
                if cur then
                    local hx, hy, hz = math.rad(trx)*0.5, math.rad(try_)*0.5, math.rad(trz)*0.5
                    local qx = Quaternion.new(math.cos(hx), math.sin(hx), 0, 0)
                    local qy = Quaternion.new(math.cos(hy), 0, math.sin(hy), 0)
                    local qz = Quaternion.new(math.cos(hz), 0, 0, math.sin(hz))
                    thumb:call("set_LocalRotation", (cur * (qz * qy * qx)):normalized())
                end
            end
        end)
    end
end

-- ---------------------------------------------------------------------
-- [SKULL_SPIN_ENTFERNT 2026-07-31] Hier lag apply_skullshaker_cock_pose (Griffpose "ShakerGripR"
-- + Finger-Spreizung "singleaction" waehrend der Cock-Drehung, gesteuert ueber __re4_skull_spread_from/to).
-- Zusammen mit der Drehung komplett ausgebaut. Die Hebel-Auf-Pose ("skullbreak") bleibt unveraendert.
-- ---------------------------------------------------------------------

-- [SKULL_SHAKER_OPEN] Beim ÖFFNEN des Break-Action-Hebels (steigende Flanke von
-- __vr_break_open, reload.lua via RIGHT-B-Toggle, nur wp6001) die RECHTE (Waffen-)Hand
-- KURZ in die Pose "skullbreak" pulsen (Daumen nativ, Zeigefinger gekruemmt, Rest gerade)
-- und dann automatisch wieder auf original zurueck. Dreieck-Puls: rein -> Spitze -> raus.
-- ("skullbreak" ist die Hebel-Auf-Pose und die einzige Skull-Shaker-Pose, die es noch gibt.)
local SKULLSHAKER_OPEN_POSE = "skullbreak"
local SKULLSHAKER_OPEN_DUR  = 0.2    -- Snap-Haltezeit (sofort voll, KEIN Lerp beim Reingehen)
local SKULLSHAKER_OPEN_REL  = 0.15   -- Release: weiches Zurueck-Lerp zur Originalpose
local skullopen_st = { prev = false, start_t = -1 }
local function apply_skullshaker_open_pose()
    local open = rawget(_G, "__vr_break_open") == true
    local now  = os.clock()
    if open ~= skullopen_st.prev then                -- JEDE Flanke = Hebel geht auf ODER zu
        skullopen_st.start_t = now
    end
    skullopen_st.prev = open
    if skullopen_st.start_t < 0 then return end
    local dt = now - skullopen_st.start_t
    if dt >= SKULLSHAKER_OPEN_DUR + SKULLSHAKER_OPEN_REL then
        skullopen_st.start_t = -1; return            -- vorbei -> nichts schreiben -> original
    end
    local blend
    if dt <= SKULLSHAKER_OPEN_DUR then
        blend = 1.0                                   -- SNAP rein + Halten: sofort voll, kein Lerp
    else
        blend = 1.0 - (dt - SKULLSHAKER_OPEN_DUR) / SKULLSHAKER_OPEN_REL   -- nur RUECKgang lerpt
    end
    apply_pose_runtime(SKULLSHAKER_OPEN_POSE, blend)
end



-- ---------------------------------------------------------------------
-- [KNIFE_SWING] Velocity-Swing-Erkennung (1:1 Port aus RE9 update_axe_swing,
-- Knife-Preset-Werte aus RE9). Setzt vr_knife_swing (Edge + Hold-Fenster);
-- re4_vr_weapons.lua liest die Flanke fuer den requestAttack-Melee.
-- ---------------------------------------------------------------------
local KNIFE_IDS_SWING = {
    -- MUSS mit KNIFE_IDS (re4_vr_weapons.lua) synchron sein: fehlt ein Messer hier, wird der
    -- Schwung nicht erkannt -> vr_knife_swing feuert nie -> KEIN Melee/Breakables fuer das Messer.
    [5000] = true, [5001] = true, [5002] = true, [5003] = true, [5006] = true, [6107] = true,
    [6108] = true, [6305] = true,   -- 6305 = Hot Dogger; beide waren in KNIFE_IDS, fehlten aber hier
}
local knife_swing = {
    last_wp = nil, last_time = 0, velocity = 0,
    swing_end = 0, last_swing = 0,
    threshold = 3.5, hold_time = 0.15, cooldown = 0.2,   -- m/s; nur ECHTE Schwuenge (1.0 war zu niedrig -> Gehen loeste aus). Live per Slider tunebar (Global).
}
-- Threshold ueber Global (UI-Slider + Persistenz koennen ran; load_config setzt ihn evtl. vorher aus JSON).
_G.__re4_knife_swing_threshold = _G.__re4_knife_swing_threshold or knife_swing.threshold

local function update_knife_swing()
    local now = os.clock()
    -- [KNIFE_FLIP] Melee im Reverse-Grip (Flip) erlaubt — AUSSER bei sichtbarem Finisher-Prompt
    -- (RT-GUI Gui_ui2200): dann hat die Shake-Finisher-Geste Vorrang (Shake VOR Melee), kein Stich.
    -- Ohne Prompt laeuft das Shake eh ins Leere -> Melee im Flip normal. Prompt: re4_vr_crosshair.lua.
    -- last_wp nullen -> kein Velocity-Spike wenn der Prompt verschwindet und Melee wieder frei ist.
    if rawget(_G, "__vr_knife_flip") == true
       and type(rawget(_G, "__re4_is_finisher_prompt")) == "function"
       and _G.__re4_is_finisher_prompt() == true then
        vr_knife_swing = false; knife_swing.velocity = 0; knife_swing.last_wp = nil
        return
    end
    if vr_knife_swing and now >= knife_swing.swing_end then
        vr_knife_swing = false
    end
    -- ROHE rechte Controller-Position (wie RE9) — NICHT die geglaettete
    -- cache.rh_world (Smoothing + Weapon-Offset verfaelschen die Velocity).
    if not vrmod or not vrmod:is_hmd_active() then
        knife_swing.velocity = 0
        knife_swing.last_wp = nil
        return
    end
    local controllers = vrmod:get_controllers()
    if not controllers or #controllers < 2 then
        knife_swing.velocity = 0
        return
    end
    -- [KNIFE_HAND] Schwung-Velocity von der Hand, die das Messer HAELT: links=ctrls[1], rechts=ctrls[2].
    local cidx = (rawget(_G, "__re4_knife_hand") == "left") and 1 or 2
    -- [KNIFE_HAND] Wechselt die aktive Hand (z.B. Draw links: none->left), ist last_wp noch von der ANDEREN
    -- Hand -> riesiger FALSCHER Velocity-Spike -> Phantom-Swing (Melee-Sound beim Greifen). Bei Wechsel resetten.
    if knife_swing.last_cidx ~= nil and knife_swing.last_cidx ~= cidx then
        knife_swing.last_wp = nil; knife_swing.velocity = 0
        knife_swing.last_swing = now   -- Cooldown-Fenster: auch die Greif-Restbewegung nach dem Draw feuert nicht
    end
    knife_swing.last_cidx = cidx
    local wp = vrmod:get_position(controllers[cidx])
    if not wp then
        knife_swing.velocity = 0
        knife_swing.last_wp = nil
        return
    end
    local dt = now - knife_swing.last_time
    if knife_swing.last_wp and dt > 0.001 and dt < 0.2 then
        local dx = wp.x - knife_swing.last_wp.x
        local dy = wp.y - knife_swing.last_wp.y
        local dz = wp.z - knife_swing.last_wp.z
        local horiz = math.sqrt(dx * dx + dz * dz)
        if dy > 0 and dy > horiz then
            knife_swing.velocity = 0   -- reines Anheben zaehlt nicht
        else
            knife_swing.velocity = math.sqrt(dx * dx + dy * dy + dz * dz) / dt
        end
    else
        knife_swing.velocity = 0
    end
    knife_swing.last_wp = Vector3f.new(wp.x, wp.y, wp.z)
    knife_swing.last_time = now

    local wid = tonumber(cache.weapon_key)
    -- [KNIFE_HAND] Schwung-Erkennung liest jetzt die aktive Messer-Hand (oben) -> links UND rechts armen.
    local armed = wid ~= nil and KNIFE_IDS_SWING[wid] == true and not support.docked
    if armed and knife_swing.velocity >= (rawget(_G, "__re4_knife_swing_threshold") or knife_swing.threshold) then
        if now - knife_swing.last_swing >= knife_swing.cooldown then
            vr_knife_swing = true
            _G.vr_knife_velocity = knife_swing.velocity
            _G.__vr_knife_swing_t = now
            knife_swing.swing_end = now + knife_swing.hold_time
            knife_swing.last_swing = now
        end
    end
end

-- ---------------------------------------------------------------------
-- Tick (Main Pipeline)
-- ---------------------------------------------------------------------
-- [ELEVATOR2 2026-07-12] Aufzug 2 (Stage 53302) parentet den Player jeden Frame an seine Hierarchie
-- (Body -> "Parent" -> "Box" -> gm..._書斎地下のエレベータ) -> VR-Playspace faehrt mit = Clipping. Loesung:
-- JEDEN Frame den Body vom Aufzug UN-parenten (set_Parent(nil)), wenn ein Elevator-GO (Name enthaelt
-- "エレベータ" ODER "リフト") in der Parent-Kette haengt. pcall + get_Valid (set_Parent auf stale Transform = AV-Crash).
-- Laeuft VOR dem Killswitch-Bail. GLOBAL (kein Top-Level-Local -> motion.lua sitzt am 200-Limit).
_G.__re4_elevator_unparent = function()
    _G.__re4_on_elevator2 = false   -- [ELEVATOR2] default aus; jeden Frame frisch (kein stale). Unten true,
                                    -- sobald der Aufzug-Parent erkannt ist -> stabiler Trigger fuer killswitch.
    local ctx = get_player_context(); if not ctx then return end
    local body = sc(ctx, "get_BodyGameObject"); if not body then return end
    local btf = sc(body, "get_Transform"); if not btf then return end
    -- [ELEVATOR6 2026-07-16] Typ einmal cachen. GLOBAL, weil motion.lua am 200-Local-Limit sitzt.
    local td = rawget(_G, "__re4_elev_td")
    if td == nil then
        td = sdk.typeof("chainsaw.GmElevator") or false
        _G.__re4_elev_td = td
    end
    local t = sc(btf, "get_Parent")
    local on_elevator = false
    for _ = 1, 5 do
        if not t then break end
        local go = sc(t, "get_GameObject")
        if go then
            -- [ELEVATOR6 2026-07-16] Positiver Nachweis per Komponente STATT Namensraten.
            -- WARUM: Aufzug gm81_501_00_0 (Stage 62201) heisst weder エレベータ noch リフト -- die
            -- Kette ist "Parent" <- "Box" <- "gm81_501_00_0". Der Namenstest war dort blind (live
            -- belegt: jpName=false, __re4_on_elevator2 blieb false) -> kein Unparent -> movement/
            -- arm_chain kaempfen gegen die Hierarchie -> Player+Ashley+Plattform bleiben optisch
            -- stehen. getComponent trifft JEDEN Aufzug, auch kuenftige, und liefert Unterklassen
            -- mit (GmElevator ist die Basisklasse -- gleiches Prinzip wie GmAnimal->GmCrow).
            if td and sc(go, "getComponent(System.Type)", td) then on_elevator = true; break end
            local nm = sc(go, "get_Name")
            -- [ELEVATOR3 2026-07-15] Namenstest bleibt als Fallback: greift die Komponente mal nicht
            -- (Aufzug-GO ohne GmElevator in der Kette), verhalten sich エレベータ/リフト wie bisher.
            if type(nm) == "string" and (nm:find("エレベータ") or nm:find("リフト")) then on_elevator = true; break end
        end
        t = sc(t, "get_Parent")
    end
    if not on_elevator then return end
    -- [ELEVATOR2] Flag VOR dem Unparent setzen: killswitch liest dieses Flag (nicht die Parent-Kette, die wir
    -- gleich wegraeumen) -> Gameplay-Force race't nicht gegen das Unparenting.
    _G.__re4_on_elevator2 = true
    local valid = false; pcall(function() valid = btf:get_Valid() end)
    if valid then pcall(function() btf:call("set_Parent", nil) end) end
end

local function tick(do_weapon_sample)
    _G.__re4_elevator_unparent()   -- [ELEVATOR] jeden Frame vom Aufzug loesen (vor allen Bails)
    if native_reload_active() then   -- [NATIVE_ANIM] Red9-Reload: motion aus + Hand-Ziele loeschen -> native Arme
        release_motion_targets()
        smoothing.right_pos = nil
        smoothing.right_rot = nil
        smoothing.left_pos  = nil
        smoothing.left_rot  = nil
        return
    end
    if is_killswitch_active() then
        _G.__re4_knife_ks_restore_native()   -- [KNIFE_FLIP KS] Messer nativ (kein Griff-Stich im Finisher/Cutscene)
        fl_scope_update()   -- [FL_SCOPE] Lampe beim Scopen verstecken (Mesh+Kegel) -- tick ist hier sonst aus
        -- [NATIVE_ARMS] Wie der native_reload-Branch: publizierte Hand-Ziele NILEN, sonst haelt arm_chain
        -- die Arme an der letzten VR-Position steif (Hand-Ziel bleibt sonst stale -> keine nativen Arme,
        -- z.B. im Scope-Killswitch). Red9-Lehre: nil Hand-Ziel = native Arme.
        release_motion_targets()
        smoothing.right_pos = nil
        smoothing.right_rot = nil
        smoothing.left_pos  = nil
        smoothing.left_rot  = nil
        restore_hands_native()   -- [KILLSWITCH_RESTORE] verbogene Hand-Local-Position auf Bind zuruecksetzen (kein Stretch)
        return
    end

    -- [FLIP_RESTORE 2026-07-15] KS ist vorbei (der Block oben returnt sonst) -> war das Messer VOR dem KS
    -- umgedreht, wieder umdrehen. Gegenstueck zum Merker in __re4_knife_ks_restore_native. Damit ueberlebt
    -- der Reverse-Grip Treffer/Stagger/Cutscene -- vorher musste man nach jedem Treffer neu flippen (RT).
    -- Nur wenn das Messer noch equippt ist; sonst Merker still verwerfen (Waffe gewechselt = Wunsch hinfaellig).
    -- [SOFORT, KEIN LERP] Nicht nur __vr_knife_flip setzen, sondern lerp direkt auf die Endstellung: sonst
    -- dreht sich das Messer nach JEDEM Stagger sichtbar zurueck (lerp startet bei 0, s. knife_flip_spin) --
    -- beim bewussten RT-Flip ist diese Animation gewollt, hier soll es einfach stehen wie vorher.
    -- prev_target = 1.0 unterdrueckt zugleich den Flip-Sound: knife_flip_spin spielt ihn auf der
    -- Ziel-FLANKE (prev_target ~= target); mit gleichem Wert gibt es keine Flanke -> lautlos.
    if rawget(_G, "__re4_knife_flip_pre_ks") == true then
        _G.__re4_knife_flip_pre_ks = nil
        if rawget(_G, "__re4_knife_equipped") == true then
            _G.__vr_knife_flip = true
            knife_flip.lerp = 1.0
            knife_flip.prev_target = 1.0
        end
    end

    -- Init-Gate: warte bis vrmod Controller liefert
    if not init_state.initialized then
        init_state.frame_counter = init_state.frame_counter + 1
        if vrmod then
            local controllers = vrmod:get_controllers()
            if controllers and #controllers >= 2 then
                init_state.initialized = true
                right_hand.joint = nil
                left_hand.joint  = nil
                cache.standing_origin_set = false
                pcall(function()
                    if vrmod.is_openxr_loaded and vrmod:is_openxr_loaded() then
                        vr_runtime = "openxr"
                    elseif vrmod.is_openvr_loaded and vrmod:is_openvr_loaded() then
                        vr_runtime = "openvr"
                    end
                end)
                -- Pick up controller_type von Binding (falls dort geaendert)
                load_config()
            end
        end
        return
    end

    local cam_data = get_camera_data()
    if not cam_data then return end

    local vr_data = get_vr_data()
    if not vr_data then return end

    -- Standing-Origin pro Frame nachziehen (Recenter-Support)
    local so = vrmod:get_standing_origin()
    if so then
        cache.standing_origin = Vector3f.new(so.x, so.y, so.z)
        cache.standing_origin_set = true
    end

    find_joints()
    find_weapon()
    -- Kalibrierung nur im LateUpdateBehavior-Pass weiterzaehlen/sampeln
    -- (dort ist die native Verkettung Hand<->Waffe konsistent).
    if do_weapon_sample == true then
        update_weapon_calibration()
    end

    cache.weapon_key = current_weapon_key()
    -- [MATILDA_STOCK 2026-07-14] Erkennung: Matilda + Schulteraufsatz = Mesh-Part 11 am wp4004-Mesh
    -- (live via re4_matilda_stock.log bestaetigt). Setzt nur ein FLAG. Die HAND bleibt unveraendert
    -- (nutzt weiter den 4004-Offset); der Stock-Versatz wirkt WAFFE-ONLY auf rel_pos/rel_rot (s. attach_weapon).
    -- State/Typ in wep_cache gecacht (kein neues top-level local -> Lua-200-Limit).
    cache.matilda_stock = false
    if cache.weapon_key == "4004" and wep_cache.go then
        if wep_cache.stock_go ~= wep_cache.go then
            wep_cache.stock_go = wep_cache.go
            wep_cache.mesh_td = wep_cache.mesh_td or sdk.typeof("via.render.Mesh")
            wep_cache.stock_mesh = sc(wep_cache.go, "getComponent(System.Type)", wep_cache.mesh_td)
        end
        if wep_cache.stock_mesh then pcall(function() cache.matilda_stock = wep_cache.stock_mesh:call("getPartsEnable", 11) == true end) end
    end

    local is_lock_pass = (do_weapon_sample == false)

    cache.rh_world = nil
    cache.rh_rot   = nil
    cache.rh_aim_rot = nil
    cache.lh_world = nil
    cache.lh_rot   = nil
    cache.rh_joint_pos = nil
    cache.rh_joint_rot = nil
    cache.lh_joint_pos = nil
    cache.lh_joint_rot = nil

    -- Waffenwechsel: Draw-/Holster-Anim nativ zeigen (rechte Hand frei).
    -- Kalibrier-Fenster: rechte Hand + Waffe der Engine überlassen.
    local changing = false
    if do_weapon_sample == true then
        changing = update_weapon_changing_gate()
        -- Während des Wechsels kontinuierlich samplen (alles nativ ->
        -- konsistentes Paar; der letzte Sample = fertige Hand+Waffe).
        if changing and wep_cache.tf and not wep_cache.frozen then
            sample_weapon_rel_direct()
            wep_cache.calib = nil
            wep_cache.settle = nil
        elseif not changing then
            update_weapon_settle()
        end
    else
        changing = was_weapon_changing
    end
    -- [WSW_PIN] Wenn der Waffenwechsel-Skip aktiv ist (weapons.lua setzt das Flag),
    -- Hand+Waffe AUCH waehrend Wechsel/Settle an den Controller pinnen -> keine
    -- sichtbare native Draw/Holster-Anim. Das Sampling oben lief schon (liest nativ
    -- VOR dem Pin), daher bleibt die Kalibrierung korrekt.
    -- NUR waehrend des aktiven Wechsels pinnen (sichtbare Draw/Holster-Anim).
    -- Settle/Kalibrier-Phase NICHT pinnen -> dort sampelt motion.lua den Offset
    -- nativ (sonst verfaelscht der Pin die Waffen-Kalibrierung).
    local pin_during_change = rawget(_G, "__vr_wsw_pin") == true
    local did_left = false
    if (not changing and not weapon_calib_suspends_hand()) or (pin_during_change and changing) then
        attach_right_hand(cam_data, vr_data)
        -- [KNIFE_HAND] Messer LINKS: linke Hand VOR dem Waffen-Pin frisch berechnen, sonst pinnt attach_weapon
        -- mit 1-Frame-alten lh-Daten -> Messer schleudert beim Rotieren weg (die "alle-5-Paesse"-Lektion).
        if rawget(_G, "__re4_knife_hand") == "left" then attach_left_hand(cam_data, vr_data, is_lock_pass); did_left = true end
        attach_weapon()
    end
    -- [SUPPORT_HAND] Dock-State nur im LockScene-Pass updaten (1x/Frame); wenn oben schon fuers Messer -> skip.
    if not did_left then attach_left_hand(cam_data, vr_data, is_lock_pass) end

    -- [FLASHLIGHT] FL-GO direkt nach der linken Hand; Knife-Pose im Post-Anim-Pass
    if cache.lh_world then _G.__re4_fl_dispatch(cache.lh_world, cache.lh_rot) end
    if not is_lock_pass then if rawget(_G, "__re4_apply_ada_lazy_pose") then rawget(_G, "__re4_apply_ada_lazy_pose")() end; fl_apply_hold_pose(); apply_pistol_support_pose(); apply_rack_hand_pose_from_reload(); apply_mag_hand_pose_from_reload(); apply_switch_hand_pose(); apply_switch_rotation(); apply_skullshaker_open_pose(); knife_flip_finger_open(); if rawget(_G, "__re4_wildwest_fingers") then rawget(_G, "__re4_wildwest_fingers")() end; if rawget(_G, "__re4_apply_left_knife_pose") then rawget(_G, "__re4_apply_left_knife_pose")() end; if rawget(_G, "__re4_merc_apply_bow_pose") then rawget(_G, "__re4_merc_apply_bow_pose")() end end

    -- [KNIFE_SWING] Velocity nur 1x/Frame (LockScene-Pass), nach rh_world
    if is_lock_pass then update_knife_swing() end

    -- Cross-Script-Globals (analog RE9)
    _G.__vr_rh_world   = cache.rh_world
    _G.__vr_rh_rot     = cache.rh_rot
    _G.__vr_rh_aim_rot = cache.rh_aim_rot
    _G.__vr_lh_world   = cache.lh_world
    _G.__vr_lh_rot     = cache.lh_rot
    _G.__vr_support_hand_docked = support.docked
    _G.__vr_support_blend_factor = support.blend_factor

    -- [DIAG 2026-07-23, WEGWERF] Reine Sichtbarmachung des Schalter-Zustands fuer die Feuer-Probe --
    -- keine Logik, nur drei Globals. Kommt raus, sobald der Verstell-Schalter geklaert ist.
    _G.__vr_dbg_fire_mode     = support.fire_mode
    _G.__vr_dbg_switch_docked = support.switch_docked
    _G.__vr_dbg_wep_id        = wep_cache.id

    -- [BURST] Burst-Status fuer binding.lua (RT-Begrenzung). NUR fuer die LE5 + Hebel auf Burst,
    -- sonst false (sonst wuerde der Burst-Block andere Waffen treffen). Anzahl = per-LE5 Slider.
    do
        local le5 = SWITCH_DOCK_WEAPONS[wep_cache.id] and support.burst_active
        if le5 then
            _G.__vr_burst_active = true
            local swc = get_support_offset_switch(cache.weapon_key)
            -- [FIRE_MODE] Single (fire_mode==2) -> nach 1 Schuss blocken; Burst -> per-Slider count.
            if (support.fire_mode or 0) == 2 then _G.__vr_burst_count = 1
            else _G.__vr_burst_count = (swc and swc.burst_count) or 3 end
            _G.__vr_motion_owns_burst = true
        elseif rawget(_G, "__vr_motion_owns_burst") then
            -- NUR das von motion gesetzte true zuruecknehmen; sonst das Flag NICHT anfassen
            -- (reload2/CQBR-Burst darf es besitzen, sonst flackert es -> binding blockt RT faelschlich).
            _G.__vr_burst_active = false
            _G.__vr_motion_owns_burst = false
        end
    end

    _G.__vr_rh_joint_pos = cache.rh_joint_pos
    _G.__vr_rh_joint_rot = cache.rh_joint_rot
    _G.__vr_lh_joint_pos = cache.lh_joint_pos
    _G.__vr_lh_joint_rot = cache.lh_joint_rot
end


-- ---------------------------------------------------------------------
-- Hook-Stack (RE9-Muster, 1:1 re9_vr_motion.lua):
-- LockScene (pre) + LateUpdateBehavior = voller tick,
-- BeginRendering (post) = reiner Re-Attach gegen Engine-Anim-Drift
-- (kein Cache-Reset, kein Init/Weapon-Key-Update — nur Pose neu schreiben).
-- ---------------------------------------------------------------------
re.on_pre_application_entry("LockScene", function() tick(false) end)
re.on_application_entry("LateUpdateBehavior", function() tick(true) end)

re.on_application_entry("BeginRendering", function()
    if not init_state.initialized then return end
    if native_reload_active() then release_motion_targets(); return end   -- [NATIVE_ANIM] Red9-Reload: motion aus + Ziele loeschen
    if is_killswitch_active() then _G.__re4_knife_ks_restore_native(); restore_hands_native(); return end   -- [KILLSWITCH_RESTORE] +Messer nativ (kein Griff-Stich)
    local cam_data = get_camera_data()
    local vr_data = get_vr_data()
    if not cam_data or not vr_data then return end
    local did_left = false
    if (not was_weapon_changing and not weapon_calib_suspends_hand())
        or (rawget(_G, "__vr_wsw_pin") == true and was_weapon_changing) then
        attach_right_hand(cam_data, vr_data)
        -- [KNIFE_HAND] Messer LINKS: linke Hand VOR dem Pin frisch (gleiche Lektion wie im Haupt-Tick).
        if rawget(_G, "__re4_knife_hand") == "left" then attach_left_hand(cam_data, vr_data, false); did_left = true end
        attach_weapon()
    end
    if not did_left then attach_left_hand(cam_data, vr_data, false) end
    if cache.lh_world then _G.__re4_fl_dispatch(cache.lh_world, cache.lh_rot) end
    fl_apply_hold_pose()
    apply_pistol_support_pose()
    apply_rack_hand_pose_from_reload()
    apply_mag_hand_pose_from_reload()
    apply_switch_hand_pose()
    apply_switch_rotation()
    apply_skullshaker_open_pose()
    knife_flip_finger_open()
    if rawget(_G, "__re4_apply_left_knife_pose") then rawget(_G, "__re4_apply_left_knife_pose")() end
    -- [MERC_BOW_POSE 2026-08-03] Mercenaries-eigene Handposen (Krausers Compound Bow) --
    -- gleiches Muster wie die Links-Messer-Pose eine Zeile darueber: nur ein nil-Check, die
    -- Funktion existiert ausschliesslich, wenn re4_vr_merc.lua sie setzt. Muss HIER stehen
    -- (POST-Pass), sonst ueberschreibt die Engine-Anim die Finger jeden Frame.
    if rawget(_G, "__re4_merc_apply_bow_pose") then rawget(_G, "__re4_merc_apply_bow_pose")() end
end)

-- ---------------------------------------------------------------------
-- [MERC_BOW_LATE 2026-08-05, "der Bogen trailed der rechten Hand hinterher"]
-- Die gemessene Pass-Reihenfolge ist
-- LockScene -> BeginRendering(pre) -> BeginRendering(post) -> LateUpdateBehavior -> UpdateJointExpression
-- Unser Hook-Stack oben endet bei BeginRendering(post) -- im LETZTEN Pass bewegt die Engine die
-- Hand also noch einmal, die Waffe nicht mehr: genau der Nachlauf. Derselbe Trick wie beim
-- Skull-Shaker-Klon (re4_vr_reload.lua: ss_apply haengt zusaetzlich in UpdateJointExpression):
-- ein schlankes Nachziehen ganz am Ende, kein voller Tick (kein Cache-Reset, kein Weapon-Key).
--
-- HART GEGATET auf Mercenaries + Compound Bow (6304): fuer Leon, Ada und jede andere Waffe ist
-- die Funktion ein sofortiger Return -- an der Kampagne aendert sich damit nichts.
-- Faellt der Bogen dadurch je aus dem Tritt: einfach diesen Block wieder entfernen.
re.on_application_entry("UpdateJointExpression", function()
    if rawget(_G, "__re4_in_mercs") ~= true then return end
    if rawget(_G, "__vr_dbg_wep_id") ~= 6304 then return end
    if not init_state.initialized then return end
    if native_reload_active() then return end
    if is_killswitch_active() then return end
    if was_weapon_changing and rawget(_G, "__vr_wsw_pin") ~= true then return end
    if weapon_calib_suspends_hand() then return end
    local cam_data = get_camera_data()
    local vr_data = get_vr_data()
    if not cam_data or not vr_data then return end
    attach_right_hand(cam_data, vr_data)
    attach_weapon()
    -- [REPIN_LEFT 2026-08-07] Dieser Pass bewegt die Waffe OHNE attach_left_hand -> die linke Hand
    -- bliebe auf dem vorherigen Stand stehen und zittert beim Laufen. Nur die sichtbare Joint-Pose
    -- nachziehen (Details + Notausgang: support.repin_left).
    support.repin_left()
end)


-- =====================================================================
-- [PUBLIC-UI 2026-07-23] Ohne Tree im nackten Hauptmenue: die erkannte Runtime (damit Spieler
-- sehen, ob gerade OpenVR oder OpenXR laeuft) und die Headset-Auswahl SteamVR/MetaVR -- 1:1 derselbe
-- Block wie im Dev-Tree, gleiche Variable `selected_controller`, gleiches `save_config`.
-- Beim Release fliegen alle [DEV-UI]-Bloecke raus, dieser bleibt.
-- =====================================================================
-- Angemeldet wird ueber den Dispatcher #re4_vr_menu.lua (Platz 10 = ganz oben).
-- Die Zeichenfunktion liegt bewusst in einem GLOBAL statt in einem local: motion.lua hat keinen
-- freien Local-Slot mehr ("too many local variables (limit is 200)") -- auch ein do-Block half
-- nicht, weil das Limit die gleichzeitig aktiven Locals der Datei zaehlt.
_G.__re4_motion_public_draw = function()
    local hs = {
        { label = "SteamVR", value = "steamvr" },
        { label = "MetaVR",  value = "metavr"  },
    }
    imgui.text(string.format("Runtime: %s   Controller: %s", vr_runtime, selected_controller))
    imgui.text_colored("Select Headset:", 0xFF00A5FF)   -- [KNALLIG 2026-07-24] Orange (2026-07-24)
    for i, opt in ipairs(hs) do
        if i > 1 then imgui.same_line() end
        local active = (selected_controller == opt.value)
        if active then imgui.push_style_color(0, 0xFFD0E040) end
        if imgui.button(opt.label .. "##public") then
            if selected_controller ~= opt.value then
                selected_controller = opt.value
                save_config()
            end
        end
        if active then imgui.pop_style_color(1) end
    end
end

if type(rawget(_G, "__re4_ui_add")) == "function" then
    _G.__re4_ui_add(10, "motion_headset", _G.__re4_motion_public_draw)
else
    re.on_draw_ui(_G.__re4_motion_public_draw)
end

-- ---------------------------------------------------------------------
-- [DEV-UI] UI
-- ---------------------------------------------------------------------
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Motion" raus (757 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.


-- ---------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------
re.on_script_reset(function()
    right_hand.joint = nil
    left_hand.joint  = nil
    body_cache.go = nil
    body_cache.transform = nil
    wep_cache.id, wep_cache.go, wep_cache.tf = nil, nil, nil
    wep_cache.rel_pos, wep_cache.rel_rot = nil, nil
    wep_cache.calib = nil
    wep_cache.settle = nil
    cache.standing_origin_set = false
    smoothing.right_pos = nil
    smoothing.right_rot = nil
    smoothing.left_pos  = nil
    smoothing.left_rot  = nil
    init_state.initialized = false
    init_state.frame_counter = 0
    support.docked = false
    support.force_dock = false
    support.blend_factor = 0.0
    support.target_blend = 0.0
    support.aim_blend = 0.0
    support.switch2_blend = 0.0
    -- [FLASHLIGHT] Cache invalidieren (Body kann gewechselt haben)
    fl_state.flashlight_tf = nil
    fl_state.light_tf = nil
    fl_state.body_tf = nil
    fl_state.flashlight_mesh = nil
    fl_state.mesh_hidden = false
    fl_state.last_check = 0
end)
