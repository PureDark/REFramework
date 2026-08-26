-- Builtin implementation: src/mods/vr/games/re4/RE4VRReload4.cpp
return
-- =====================================================================
-- [RACK-DIAG 2026-07-21 ENTFERNT] Das globale __re4_rkdiag (re4_rack_diag.log) ist raus -- es schrieb
-- ueber KSQUELLE/INHAND/RESTORE dauerhaft 1-2 io.open pro Sekunde und kostete FPS. Wer es zur Analyse
-- zurueckholt: others/re4_vr_reload4_dlc.bak_2026-07-21_pre_diagclean.
-- RE4 VR - Manual Reload 4: SEPARATE WAYS (DLC) - Handfeuerwaffen
-- Pfad: reframework/autorun/re4_vr_reload4_dlc.lua
-- =====================================================================
-- EXAKTE KOPIE von re4_vr_reload.lua, aber AUSSCHLIESSLICH fuer die
-- Separate-Ways-Waffen. Alle Maincampaign-IDs sind aus den Tabellen
-- entfernt -> category_of liefert dort nil und dieses File fasst sie
-- nicht an. Umgekehrt kennt re4_vr_reload.lua keine 61xx-ID -> kein
-- Konflikt, beide koennen parallel laufen.
--
-- ABGEDECKT (reload4 = Handfeuer):
-- 6112 Punisher MC <- 4001 Punisher
-- (6113 Samurai Edge ist RAUS -> re4_vr_reload5_dlc.lua, sie ist eine Red9)
-- 6103 Blacktail AC <- 4003 Blacktail
-- 6104 MP-AF <- 4200 TMP
-- 6100 Sawed-off W-870 <- 4100 W-870
-- Der Rest (6101 Chicago w/Drum, 6102 Blast Crossbow, 6105 Anti-Materiel,
-- 6114 Hunting Rifle, 6106/6111 RL) lebt in re4_vr_reload5_dlc.lua.
-- 6107/6108 (Tactical/Elite Knife) haben keinen Reload.
--
-- EIGENE PERSISTENZ: reframework/data/re4_vr/re4_vr_reload4_dlc.json
-- (beim Anlegen 1:1 aus re4_vr_reload.json der Basiswaffen befuellt ->
-- alle getunten Werte sind von Anfang an da und divergieren ab jetzt).
--
-- ADA-HINWEIS: bewusst KEIN Character-Gate (ch3a8z0_body). Die 61xx-IDs
-- existieren nur im DLC -- die WeaponID ist das praezisere Gate, und ein
-- Body-Check wuerde bei Leon-Abschnitten INNERHALB des DLC falsch greifen.
-- =====================================================================

-- =====================================================================
-- RE4 VR MANUAL RELOAD — Portierung von re9_vr_reload.lua
-- =====================================================================
-- Struktur 1:1 nach RE9: Master-Toggle + per-Waffengattung-Toggle
-- (Pistolen / SMG / Shotguns / Magnum / Rifles), an dem ALLES fuer die
-- jeweilige Gattung haengt. RE9-Logik je Gattung wird stufenweise
-- nachgezogen; aktuell implementiert: PISTOLEN — Mag-Drop.
--
-- Mag-Drop (RE9-Mechanik 1:1):
-- * Rechter B-Knopf wird im BINDING abgefangen (re4_vr_binding.lua setzt
-- r_bbutton=false, solange _G.__vr_manual_reload_consume_b gesetzt ist)
-- -> Gamepad-X (= Reload) kommt nie beim Spiel an -> kein nativer Reload.
-- Genau wie RE9 (dort konsumiert das Binding den B-Knopf).
-- * Wir lesen B direkt (vrmod) fuer die Trigger-Flanke und droppen das
-- Magazin im Welt-Raum: t = elapsed/drop_duration (clamp 1),
-- fall = drop_distance * t*t, joint:set_Position(sx, sy - fall, sz)
-- (Schreiben in LateUpdateBehavior, sonst clobbert die Engine-Pose).
--
-- Joints pro Pistole (visuell identifiziert): wp4004 Mag=_14, Slide=_01.
-- Andere Pistolen per UI eintragen (Cycler-Probe).
--
-- NAECHSTE STUFEN (RE9 abschauen): Slide-Rack, Grip-Distanz-Zonen,
-- Mag-Holster + Mag-in-Hand-Spawn, Knife-Block, Reload-Mathematik
-- (Ammo via chainsaw.WeaponItem.addAmmoCount), Haptik, Sounds; dann SMG/
-- Shotgun/Magnum/Rifle als eigene Gattungs-Zweige.
-- =====================================================================

local CFG_PATH = "re4_vr/re4_vr_reload4_dlc.json"

-- =====================================================================
-- [DLC LET-GO] WICHTIGSTER UNTERSCHIED ZU re4_vr_reload.lua
-- =====================================================================
-- reload.lua darf die geteilten __vr_*-Globals jeden Frame auf false/nil schreiben, solange es
-- die Waffe nicht verwaltet -- es ist das ERSTE Reload-Script und die spaeteren (reload2/3/4/5)
-- ueberschreiben danach. Dieses File laedt ALPHABETISCH SPAETER, also gewinnen seine Writes.
-- Wuerde es genauso blind nullen, killt es bei JEDER Maincampaign-Waffe die Ausgaben von
-- reload.lua/reload2/reload3 (Revolver, Bolt, Armbrust, Chicago, RL, Red9...).
-- Deshalb hier das Muster von reload3 (`if not rwep.wid then return end`): freigeben NUR an der
-- FLANKE verwaltet->nicht-verwaltet, danach die Finger von den Globals lassen.
-- Als Globals statt Locals gehalten -- reload.lua kratzt am Lua-200-Local-Limit, die Kopie auch.
_G.__re4_r4dlc_had = _G.__re4_r4dlc_had or false
_G.__re4_r4dlc_release = function()
    if not _G.__re4_r4dlc_had then return end   -- wir hielten sie nie -> nichts anfassen
    _G.__re4_r4dlc_had = false
    _G.__vr_manual_reload_consume_b = false
    _G.__vr_block_fire_when_empty   = false
    _G.__re4_bf_who = "re4_vr_reload4_dlc.lua:84"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    _G.__vr_needs_rack              = false
    _G.__vr_rack_block_left_knife   = false
    _G.__vr_rack_hand_pose          = nil
    _G.__re4_reload_grab_empty      = false
    _G.__vr_motion_paused           = false
    -- [FIX 2026-07-19] Mag-Hand-Pose gehoert hierher (Flanke), NICHT in update_mag_in_hand:
    -- dort lief sie bei jeder fremden Waffe und hat Leons Pose jeden Frame genullt.
    _G.__vr_mag_hand_pose           = nil
    _G.__vr_mag_hand_trx, _G.__vr_mag_hand_try, _G.__vr_mag_hand_trz = nil, nil, nil
end

-- [SAFE_GIBT_IMMER_EINEN_WERT 2026-07-31] Ohne das explizite `return nil` liefert diese
-- Funktion im Fehlerfall GAR KEINEN Wert (nicht nil, NICHTS). In tostring(safe(...)) kommt dann
-- kein Argument an -> "bad argument #1 to 'tostring' (value expected)" -> der ganze umgebende
-- Aufruf stirbt. Genau daran ist am 31.07. der Bogen-Reload gestorben. Im Erfolgsfall unveraendert.
local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end
local function sc(o, m, ...) if not o then return nil end local a = {...}
    local ok, r = pcall(function() return o:call(m, table.unpack(a)) end); return ok and r or nil end
local function sf(o, n) if not o then return nil end local ok, r = pcall(function() return o:get_field(n) end); return ok and r or nil end
-- Produktiv-Logging ENTFERNT. Die gesamte Diagnose lebt in re4_vr_reload_diag.lua,
-- ENTFERNT 2026-08-15: auch der State-Export (publish_dbg / _G.__re4_reload_dbg) ist raus,
-- das zugehoerige Diag-Script existiert nicht mehr. rlog bleibt als No-Op stehen.
local function rlog(_) end

local function ease(t) return t * t * (3.0 - 2.0 * t) end   -- smoothstep

-- Quaternion aus Euler-Grad (Quaternion.new ist W,X,Y,Z)
local function quat_from_euler(rx, ry, rz)
    local hx, hy, hz = math.rad(rx) * 0.5, math.rad(ry) * 0.5, math.rad(rz) * 0.5
    local qx = Quaternion.new(math.cos(hx), math.sin(hx), 0, 0)
    local qy = Quaternion.new(math.cos(hy), 0, math.sin(hy), 0)
    local qz = Quaternion.new(math.cos(hz), 0, 0, math.sin(hz))
    return qz * qy * qx
end

-- =====================================================================
-- Konfiguration
-- =====================================================================
local CFG = {
    enabled         = true,   -- Master
    pistols_enabled = true,
    smgs_enabled    = true,
    shotguns_enabled= true,
    magnum_enabled  = true,
    rifles_enabled  = true,
    -- Mag-Drop: freier Fall mit Gravitation (Welt-Einheiten/s^2)
    gravity         = 9.8,
    -- Hand-Pose (gestures.lua) waehrend das Mag in der linken Hand ist
    mag_hold_pose   = "MAG",
    -- (Daumen-Abspreizung ist jetzt PRO WAFFE in MAGHAND[wid].t_rx/t_ry/t_rz)
    -- Mag-Insert (Slide-in von der Hand in die Kammer)
    insert_dur      = 0.18,
    insert_distance = 0.15,   -- ab dieser Hand->Waffe-Distanz (m) snappt das Mag in die Kammer
    -- [INSERT-PUNCH 2026-07-21] 1:1 aus re4_vr_reload.lua (Leon). REIN OPTISCH/HAPTISCH --
    -- Ammo-Reload, Rack-Logik und Slide-Lock feuern unveraendert im selben Frame wie vorher.
    insert_punch    = true,   -- Ease-in (beschleunigt bis zum Anschlag) statt Smoothstep
    insert_overshoot= 0.005,  -- m ueber die Ruhelage hinaus in den Schacht
    insert_settle   = 0.07,   -- s Rueckfedern in die Ruhelage
    -- [MANUAL_INSERT 2026-08-15] 1:1 aus re4_vr_reload.lua (Leon): das Mag faehrt NICHT auf einer
    -- Zeitbahn ein, sondern wird mit dem Controller bis zum Anschlag hochgeschoben -- und laesst sich
    -- dabei wieder herausziehen. Gemessen am HANDABSTAND (rohe Controller), nie gegen Waffe/Weltanker.
    -- Gilt fuer Adas Waffen mit Druecken-Geste (M.PUSH_WIDS in reload_adv), also 6103/6104/6112.
    insert_manual   = true,   -- aus = alles exakt wie vorher (Zeitbahn)
    -- [WEG RELATIV 2026-08-15] Kein absoluter Meterwert mehr, sondern ein ANTEIL der Strecke, die
    -- beim Andocken noch vor dir liegt (gemessen wird Hand -> Ladepunkt, angedockt wird schon bei
    -- insert_distance). Fester Weg = das Mag sprang rein, weil er lange vor dem Schacht aufgebraucht
    -- war. 0.85 = eingerastet, wenn 85 Prozent der Reststrecke zurueckgelegt sind. 1:1 wie bei Leon.
    insert_travel   = 0.09,
    -- [SELBST-EINRASTEN 2026-08-16] Ab diesem Anteil des Weges rastet das Magazin von SELBST
    -- ein -- die letzten Prozent macht die Bahn allein. 1.00 = aus (wie bisher, ganz bis zum
    -- Anschlag schieben). 0.90 = die letzten 10 %% laufen automatisch.
    -- Warum das hilft: die Hand faehrt zum Schluss einen Bogen, die Restbewegung liegt also
    -- immer schraeger zur Schachtachse und traegt kaum noch zum Fortschritt bei -- genau
    -- dort fuehlt es sich zaeh an.
    -- Wirkt NUR im Handschub; die Zeitbahn laeuft ohnehin bis 1.0 durch.
    insert_snap_at  = 0.80,   -- m Handweg vom Andocken bis zum Einrasten
    insert_back_out = 0.02,   -- m Rueckweg HINTER den Andockpunkt -> Mag wieder in die Hand
    insert_redock   = 0.01,   -- m, die man danach wieder vorschieben muss, damit es neu andockt
    insert_haptic   = 0.85,   -- Amplitude des Einrast-Pulses (0 = aus)
    -- [SND-TIMING 2026-07-21, "der Klack kommt ein kleines bisschen zu spaet"] Ab welchem Fortschritt
    -- der Einschub-Phase (0..1) der Einrast-Sound startet. War hart auf 0.90 -- weil der Sound selbst eine
    -- Anlaufzeit hat, hoerte man ihn erst NACH dem Aufschlag. Kleiner = frueher. Slider statt Konstante,
    -- damit du es am Desktop nachziehen kannst (in VR ist ImGui nicht lesbar).
    insert_snd_at   = 0.80,
    reload_ammo     = true,   -- beim Insert echten Ammo-Reload ausfuehren (Mag fuellen + Reserve abziehen)
    -- Slide-Rack (RE9-Muster): leer -> RT blockiert bis nachgeladen UND Slide gerackt
    rack_enabled    = true,   -- Empty-Block + Slide-Rack-Pflicht an
    rack_grab_dist  = 0.18,   -- linke Hand muss so nah an den Slide-Joint zum Grabben (hardcoded)
    rack_pull_dist  = 0.09,   -- (unbenutzt seit 1:1-Zug; Zug-Weg = Slide-Travel)
    rack_haptic     = true,   -- Haptik-Puls beim Rack
    rack_pose       = "rack-slide",  -- LINKE-Hand-Pose beim Slide-Grab (gestures.lua)
    -- [RACK_POSE_ANGLE 2026-07-31] NUR PISTOLEN (hier: Punisher MC 6112 / Blacktail AC 6103):
    -- zwei Rack-Posen je nach Annaeherungsrichtung der linken Hand, slide-lokal in der XZ-Ebene
    -- gemessen -- 0 Grad = von HINTEN (globale rack_pose), 90 Grad = von der SEITE (rack_pose_side).
    -- Seitenneutral (|x|), Hoehe egal. Identisch zu Leons re4_vr_reload.lua, aber ADAS Posen/JSON.
    rack_pose_side     = "MAGRack",  -- Pose bei seitlicher Annaeherung
    rack_pose_side_deg = 45,         -- ab wie viel Grad gilt die Annaeherung als "von der Seite"
    -- [SND] Eigene Waffen-Sounds (SoundContainer-Trigger)
    sound_enabled   = true,   -- Mag/Slide/DryFire-Sounds abspielen
    mag_floor_delay = 0.45,   -- Verzoegerung (s) bis der Mag-Boden-Aufprall-Sound kommt
    -- [SHOTGUN] Shell-Reload-Verhaeltnis: 1 Einfuehrbewegung laedt so viele Shells (1=1:1, 2=1:2). Default 1:2.
    shotgun_ratio   = 2,
    pump_haptic_delay = 0.0,  -- [SHOTGUN PUMP] Delay (s) der Pump-Haptik (hin/zurueck) -> aufs Audio legbar
}

-- Mag-in-Hand Pose pro Waffe (Offset im Hand-Frame + Rotation in Grad + Daumen-Abspreizung t_*)
local MAGHAND = {}
local function maghand(wid)
    local m = MAGHAND[wid]
    if not m then
        m = { x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, t_rx = 0, t_ry = 0, t_rz = 0, f_curl = 0 }
        MAGHAND[wid] = m
    end
    return m
end

-- Slide-Rack-Zustand (RE9-Muster): needs=true sperrt das Feuern bis gerackt.
-- Wird gesetzt sobald das Magazin leer ist, NUR durch die Rack-Geste geloescht.
local rack = { needs = false, grab_active = false, armed = false, gx = 0, gy = 0, gz = 0, frac = 0, pulled = false,
               pushed = false,                    -- [SHOTGUN PUMP] nach vollem Zug wieder nach vorn geschoben (RE9-Modell: HER-Sound)
               has_mag = false,                  -- Mag drin? (Slide -0.015) vs leer (Slide -0.060)
               empty = false,                     -- [EMPTY_SLIDE] Waffe LEER (loaded<=0, frisch) -> Slide hinten, schon VOR dem Mag-Drop
               empty_when_dropped = false,        -- war die Waffe beim Drop LEER? -> Rack noetig nach Reload
               tuning = false, tune_frac = 0,    -- tuning = UI-Vorschau der Slide-Pose
               dock_tune = false,                -- Hand-Pose-Einstellmodus: Hand ans Slide-Dock zwingen (ohne Reload-Zyklus)
               dock_blend = 0,                   -- [DOCK_LERP] 0..1 Blend der Hand zum Slide-Dock (sanft hin/weg)
               _last_grip = false, _last_dist = -1 }   -- fuer Diag-Export

-- [SHELL_EJECT] W-870-Spass: Shell aus dem geoeffneten Chamber werfen. Start = Chamber-Position
-- (per-Waffe Offset von der _04-Shell-Ruhepose), danach Flug (spaeter). SCHRITT 1: nur die
-- Startposition tunen (Preview-Toggle haelt die Shell an der Offset-Stelle).
-- sx/sy/sz/srx/sry/srz = Chamber-Startposition (Offset von _04-Ruhepose, lokal).
-- vx/vy/vz = Abschuss-Geschwindigkeit (lokal, m/s; vx=rechts), grav = Fallbeschleunigung (lokal -Y),
-- dur = Flugdauer (s), spin = Taumel-Rotation (Grad/s um lokales X).
local SHELL_EJECT = {}   -- [wid] = { sx,sy,sz, srx,sry,srz, vx,vy,vz, grav,dur,spin }
local SHELL_EJECT_DEF = { sx=0.0, sy=0.0, sz=0.0, srx=0.0, sry=0.0, srz=0.0,
                          vx=0.8, vy=0.5, vz=0.0, grav=4.0, dur=0.7, spin=540.0 }
local function shell_eject_cfg(wid)
    local s = SHELL_EJECT[wid]
    if not s then s = {}; for k,v in pairs(SHELL_EJECT_DEF) do s[k]=v end; SHELL_EJECT[wid] = s end
    return s
end
local shell_eject = { preview = false, flying = false, t = 0.0, last_clock = 0.0, _prev_pulled = false }
-- [SHOTGUN] Z-Offset von der _04-Shell-Ruhepose zum CHAMBER-Port (lokal, Waffen-Frame). Wird sowohl
-- fuer die Insert-Distanz (Hand->Chamber) ALS AUCH das Insert-ZIEL (Shell gleitet in den Port) genutzt.
local SHOTGUN_CHAMBER_Z = { [6100] = -0.093 }   -- [DLC] Sawed-off W-870 = 1:1 W-870 (4100)
-- [DOCK-PORT PRO WAFFE] Exakter Andock-Spot fuers Mag/Shell-Einlegen = LIVE-Weltpos eines FESTEN
-- Gun-Joints (bewegt sich NICHT mit der Hand) + Offset in dessen lokalem Z. Der Insert-Proximity misst
-- Hand->diesen Punkt (statt Hand->Griff). { joint = Name, z = Offset }.
local DOCK_PORT = {}   -- [DLC] leer: 4001/4003/4200/4100 haben keinen eigenen Andock-Port (das waren LE5/Striker/Skull Shaker)
-- [LEVER_PORT] Exakter GREIF-Punkt fuer den Break-Action-Hebel (linke Hand). Gun-Joint + Offset in
-- dessen lokalem Z. Sonst misst der Greif-Gate Hand->joint_02-Ursprung (zu weit). { joint, z }.
local LEVER_PORT = {}   -- [DLC] leer: keine Break-Action im reload4-Set

-- [CHAMBER] Top-Loader-Zustand (Red9): die Waffe hat kein Magazin, sondern einen Chamber,
-- den der rechte B-Knopf auf-/zuschiebt (Joint in Z verschieben). open=true -> offen.
-- base = einmal (im geschlossenen Zustand) erfasste Ruhe-LocalPosition des Chamber-Joints.
local chamber = { open = false, blend = 0.0, base = nil, base_joint = nil }

-- [DOCK_LERP] Ramp-Schritt pro Frame fuer das Hand->Slide-Andocken (linear, dann
-- smoothstep-geglaettet). 1:1 aus RE9 (re9_vr_reload_advanced DOCK_BLEND_SPEED).
local DOCK_BLEND_SPEED = 0.10
-- Slide-Rack-Posen HARDCODED pro Pistole als ABSOLUTE lokale Z (wie RE9 SLIDE_BIND_POSE).
-- KEINE Laufzeit-Erfassung -> keine kumulative Drift bei Reset Scripts.
-- rest_z = gechambered/Ruhe (Slide vorne)
-- park_z = Mag drin, noch nicht gerackt (leicht hinten)
-- back_z = leer / Rack-Endpunkt (voll hinten)
-- dock_x/y/z = Versatz der LINKEN Hand relativ zum Slide-Joint (lokales Slide-Frame),
-- damit die Hand am Slide GREIFT statt daneben zu haengen. Per Feedback justiert.
-- rack_rx/ry/rz = Rotations-Offset (Grad) der LINKEN Hand relativ zur Slide-Rotation
-- waehrend des Grabs -> feste, tunebare Hand-Pose (steif, folgt nicht dem Controller).
local SLIDE_POSE = {
    -- [DLC] Alle Werte 1:1 aus re4_vr_reload.lua von der jeweiligen Basiswaffe uebernommen.
    [6112] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- Punisher MC <- Punisher (4001)
    [6103] = { rest_z = 0.10042, park_z = 0.08542, back_z = 0.06042, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- Blacktail AC <- Blacktail (4003)
    [6104] = { rest_z = -0.07458, park_z = -0.07458, back_z = -0.10500, dock_x = 0.045, dock_y = 0.032, dock_z = -0.192, rack_rx = 53.7, rack_ry = 285.7, rack_rz = -86.1 },   -- [TMP _09 2026-07-20 -- gemessen] Ruhe (Slide ZU) = -0.07458. Die TMP hat KEIN Hold-Open: der Slide steht auch bei leerer Waffe vorne, deshalb park_z = rest_z. Rack = kurzer Zug nach hinten (back_z) und wieder vor. rest_z war vorher 0.10042 -- falsch vom Punisher geerbt.
    [6100] = { rest_z = 0.42500, park_z = 0.42500, back_z = 0.30000, dock_x = 0.0, dock_y = 0.0, dock_z = 0.0, rack_rx = 0.0, rack_ry = 0.0, rack_rz = 0.0 },   -- Sawed-off W-870 <- W-870 (4100)
}
-- [POSE2_OFFSETS 2026-08-06 -- Port aus re4_vr_reload.lua] ZWEITER Offset-Satz (sdock_*/srack_*)
-- = die SEITEN-Pose beim Slide-Rack (MAGRack). Bisher hatte dieses File nur EINEN Satz: die Finger-
-- Weiche (rack.pose_side) schaltete zwar korrekt zwischen "rack-slide" und "MAGRack" um, Handlage und
-- Handrotation blieben aber in beiden Faellen gleich -> es sah aus, als kaeme immer dieselbe Pose.
-- Nur Pistolen werten den zweiten Satz aus (s. publish_dock); rest_z/park_z/back_z bleiben EINFACH:
-- das ist der Slide-WEG der Waffe, keine Eigenschaft der Handpose.
-- Startwerte identisch zu Leon: Pose 1 = Punisher-Werte, Pose 2 = Blacktail-Werte.
local SLIDE_POSE_DEFAULT = { rest_z = 0.06174, park_z = 0.04674, back_z = 0.03174,
    dock_x  = 0.0,   dock_y  = 0.0,    dock_z  = 0.0,    rack_rx  = 0.0, rack_ry  = 0.0,   rack_rz  = 0.0,
    sdock_x = 0.077, sdock_y = -0.008, sdock_z = -0.056, srack_rx = 4.7, srack_ry = 153.7, srack_rz = -37.6 }

-- [CRASH-HARDEN 2026-07-17] EINZIGER sicherer Weg, den nativen Inventar-Reload aufzurufen. Warum noetig:
-- chainsaw.CsInventoryController.reload dereferenziert das equippte Gun-/Ammo-Item OHNE Null-Check. Beim
-- frame-genauen Uebergang (Um-Equippen mitten im Reload, 0-Ammo-Wechsel) ist dieses Item kurz null -> die
-- native reduce-Kette liest null -> Access Violation c0000005 -> FULL GAME CRASH (belegt re2_framework_log
-- 19:37:30, "Exception... CsInventoryController.reload"). Die pcall um den Call faengt eine AV NICHT.
-- Der bisherige Guard (equip_wid == wep.wid) hatte noch ein Fenster. Der Crash ist konkret das NULL GUN-ITEM
-- im Equip-Uebergang (Kommentar 2026-07-14: equip_wid zeigt schon die neue Waffe, das Gun-Item ist aber noch
-- null). Genau DAS abfragen: getEquippedWeapon(EquipType) liefert das equippte WeaponItem, null = kein Item =
-- Crash-Fall -> dann NICHT reload'en. Wichtig: KEIN enableReloadItem-Gate (2026-07-17 verworfen) -- der prueft
-- die VOLLE Reload-Gueltigkeit nach Engine-Semantik und lehnt unseren eigenen VR-Reload-Flow ab (Sentinel Nine:
-- auf 0, nachgeladen -> blieb 0). getEquippedWeapon blockt NUR den echten null-Fall, keine legitimen Reloads.
-- Global (kein neuer Top-Level-Local; reload.lua ist am 200-Local-Limit) -> reload2/reload3 nutzen denselben Helfer.
-- [RELOAD-WATCHDOG 2026-07-21 ENTFERNT] Der PRE/POST-Watchdog um den nativen reduce/reload
-- (re4_reload_watch.log) ist raus. Die Crash-Guards selbst (getEquippedWeapon-null-Check, Ammo-Guard,
-- Drain-Split, __re4_safe_reduce) sind UNVERAENDERT drin -- nur das Protokoll faellt weg.
-- Zum Wiederholen einer Crash-Analyse: others/re4_vr_reload4_dlc.bak_2026-07-21_pre_diagclean.
-- [CRASH-HARDEN 2026-07-18 v2] Reserve-Abzug OHNE den nativen chainsaw.CsInventoryController.reduce.
-- WARUM v1 (count-Guard) versagte: getItemCountSum liefert eine PLAUSIBLE Zahl, aber der native reduce laeuft
-- intern ueber die Item-Rows und deref't eine "stale/Spiegel"-Row mit null-Innenobjekt -> c0000005 (RCX=0) ->
-- FULL CRASH (belegt 12:51:04 UND erneut 13:14:45, trotz count>=n). getItemCountSum ist laut eigenem Kommentar
-- Z.1648 ohnehin unzuverlaessig (ItemID:ToString-Marshalling). Zaehler != Deref-Sicherheit.
-- EFFEKTIV: den nativen reduce NIE rufen. Die AV kann nur IM nativen reduce passieren -> rufen wir ihn nie,
-- kann er nie crashen. Stattdessen die Reserve an den echten getItems-Rows runterzaehlen (dieselbe Enumeration,
-- die __re4_item_count_sum als ZUVERLAESSIG nutzt). set_CurrentItemCount ist ein managed Setter auf einem per
-- safe bestaetigten Nicht-null-Row-Objekt -> deref't nichts selbst -> keine AV moeglich. Schlimmster Fall
-- (Setter greift nicht): Reserve bleibt 1 zu hoch -- rein kosmetisch, NIE ein Crash. reduce laedt keine Waffe,
-- der Ladepfad (reload/addAmmoCount/write_dword) ist getrennt und lief schon davor -> KEINE Funktionsbeschneidung.
-- Global, damit reload2/reload3 denselben Helfer nutzen.
-- [DLC SHARED HELPERS] Die folgenden _G-Helfer sind mit re4_vr_reload.lua IDENTISCH und werden dort
-- schon definiert (laedt alphabetisch zuerst). `= _G.x or...` laesst die ERSTE Definition gewinnen.
-- Wichtig bei __re4_reload_apply_pose*: die Funktion haengt am POSES-Store IHRES Files -- wuerde die
-- DLC-Kopie gewinnen, liefen alle Hand-Posen (auch die der Maincampaign) gegen den DLC-Store.
_G.__re4_safe_reduce = _G.__re4_safe_reduce or function(inv, ammo_id, n)
    n = tonumber(n); if not inv or ammo_id == nil or not n or n <= 0 then return false end
    local want  = tostring(ammo_id)
    local items = safe(function() return inv:call("getItems") end); if not items then return false end
    local cnt   = tonumber(safe(function() return items:call("get_Count") end)) or 0
    local rem   = n
    for i = 0, cnt - 1 do
        if rem <= 0 then break end
        local it = safe(function() return items:call("get_Item(System.Int32)", i) end)
        if it then
            local iid = safe(function() return it:call("get_ItemId") end)
            if iid and tostring(iid) == want then
                local have = tonumber(safe(function() return it:call("get_CurrentItemCount") end)) or 0
                if have > 0 then
                    local take = math.min(have, rem)
                    -- [FIX 2026-07-18] chainsaw.Item hat KEIN set_CurrentItemCount (mein alter Call verpuffte,
                    -- Row blieb stehen -> Reserve nie abgezogen). Echter Mutator = reduceCount(n), direkt am
                    -- non-null Row-Objekt -> zuverlaessig UND kein Controller-null-Deref (kein Crash).
                    pcall(function() it:call("reduceCount", take) end)
                    rem = rem - take
                end
            end
        end
    end
    return rem < n   -- true = es wurde etwas abgezogen
end
-- [NATIVER RELOAD AUSGEBAUT 2026-08-01] Diese Fassung ist die FALLBACK-Definition fuer den Fall,
-- dass re4_vr_reload.lua nicht laedt (`x = x or function...`, laedt alphabetisch spaeter -> normalerweise
-- schlaeft sie). Genau darin lag aber noch der native chainsaw.CsInventoryController.reload -- der Call,
-- der im Log die Zeile vor dem Absturz war ("inv:reload(20) ok=false"). Bei einem Ladefehler in reload.lua
-- waere er still wieder aktiv gewesen; siehe [[Notiz]].
-- Jetzt meldet die Fallback-Fassung nur noch `false` = "ich habe nicht geladen". Die Aufrufer im DLC-Script
-- haben dafuer alle ihren eigenen Nachschlag (addAmmoCount auf __re4_live_wi + __re4_safe_reduce), der
-- genau bei false anspringt -- es faellt also nichts aus, es wird nur nicht mehr nativ geladen.
-- Der komplette alte Rumpf steht unten als Kommentar, Backup: others/re4_vr_reload4_dlc.bak_2026-08-01_pre_native_removal.lua
_G.__re4_safe_inv_reload = _G.__re4_safe_inv_reload or function(inv, et, n, refill)
    return false
end
-- [GELOESCHT 2026-08-12] Hier lag der auskommentierte alte native Reload-Weg
-- (inv:reload samt Reentranz-Sperre und drain/refill-Zweig). Toter Code mit scharfem
-- Call -- raus statt aufbewahrt. Alte Fassung: others/*_pre_accessor.lua

local function slide_pose(wid)
    local sp = SLIDE_POSE[wid]
    if not sp then
        sp = {}
        for k, v in pairs(SLIDE_POSE_DEFAULT) do sp[k] = v end
        SLIDE_POSE[wid] = sp
    end
    -- fehlende Felder (aus alter JSON) mit Default auffuellen
    for k, v in pairs(SLIDE_POSE_DEFAULT) do if sp[k] == nil then sp[k] = v end end
    return sp
end
-- [EMPTY-RELOAD SLIDE] Riot Gun: nach Leerschuss (auf 0) + Reload wird NICHT gepumpt, sondern an einem
-- EIGENEN Lade-Slide-Joint (_08) nach hinten gezogen (pistolen-artig: ziehen -> loslassen -> schnappt
-- vor -> chambert). Eigene Travel-Pose (rest/park/back/dock) + eigene Hand-Pose. NUR dieser Sonderfall;
-- zwischen den Schuessen bleibt alles Pump (_01).
local SLIDE_POSE2 = {}
local function slide_pose2(wid)
    local sp = SLIDE_POSE2[wid]
    if not sp then sp = {}; for k, v in pairs(SLIDE_POSE_DEFAULT) do sp[k] = v end; SLIDE_POSE2[wid] = sp end
    for k, v in pairs(SLIDE_POSE_DEFAULT) do if sp[k] == nil then sp[k] = v end end
    return sp
end
local EMPTY_RELOAD_JOINT = {}   -- [DLC] leer: Basis 4100 (W-870) hat keinen _08-Lade-Slide (das war die Riot Gun)
-- [SHELL_PART_FIX] Waffen die den Shell-Sub-Mesh-Part-Trick (Lern-Diff) nutzen, ohne _08-Lade-Slide.
local SHELL_PART_LEARN = {}   -- (Lern-Diff-Pfad; aktuell keine Waffe -> Riot Gun laeuft ueber EMPTY_RELOAD_JOINT)
-- HINWEIS: Skull Shaker (6001) rendert seine Huelse NICHT als statischen Sub-Mesh-Part, sondern ueber
-- die Engine-Komponente chainsaw.ShotgunShellGenerator (prozedural). Part-Toggle/Force ist daher
-- WIRKUNGSLOS -> getragene Shell muss ueber den Generator/eigene Instanz geloest werden (offen).
-- [SHELL_PART_PERSIST] Gelernter Shell-Part-Index pro WeaponID (nur Lern-Diff-Pfad) -> auf Disk gesichert.
local SHELL_PARTS = {}
-- [SHELL_PART_FIXED 2026-07-18] FEST bestaetigter Shell-Sub-Mesh-Part fuer Static-Mesh-Shotguns, die NICHT
-- ueber den Lern-Diff laufen (kein EMPTY_RELOAD_JOINT/SHELL_PART_LEARN). Striker (4102): Part 1 LIVE
-- verifiziert (A/B-Test: Force Part 1 -> Huelse in der Hand sichtbar). Deckungsgleich mit dem Skull-Shaker-
-- Clone (isoliert Part 1) -> Part 1 = Huelse ueber die Shotgun-Modelle. Fallback in sg_mesh, wenn nichts gelernt.
local SHELL_PART_FIXED = {}   -- [DLC] leer: Basis 4100 nutzt keinen festen Shell-Part (das war die Striker)
-- [SHELL_SPAWN] Waffen deren getragene Huelse NICHT als statischer Mesh-Part existiert (die Engine
-- generiert die Kammer-Huelse prozedural via chainsaw.ShotgunShellGenerator -> bei 0 Ammo ist NICHTS
-- da zum Forcen). Loesung: wir instanziieren das Shell-Prefab der Waffe (_UserData._Prefab) EINMAL
-- und docken die Instanz jeden Frame an die _04-Joint-Weltpose (die folgt via mag_to_hand der Hand).
-- Skull Shaker (6001) nutzt JETZT den Part-1-Mesh-Clone (s. [SHELL_CLONE] weiter unten) statt der
-- gespawnten Prefab -> daher hier NICHT mehr gelistet (Tabelle leer, kein Prefab-Spawn mehr).
local SHELL_SPAWN = {}
-- [SHELL_CLONE] Skull Shaker (6001): die getragene Shell (Mag-Holster -> Hand) ist ein MESH-CLONE
-- von Part 1 der Waffe (Technik wie reload2-Revolver: Motion+Mesh+setMesh+Material+Part isolieren),
-- KEIN Joint/Prefab mehr. Eigene Hand-Offsets, weil der Clone anders liegt als der alte _04-Joint.
-- preview = UI-Vorschau zum Tunen. Als Global -> kein Main-Chunk-Local (reload.lua ist voll).
-- [ABKAPSELUNG 2026-07-19] Hier stand `_G.__re4_ss_clone` -- DIESELBE Tabelle, die
-- re4_vr_reload.lua fuer Leons Skull Shaker (6001) benutzt. Dieses File nutzt sie fuer die
-- Sawed-off (6100). Beide Scripte speichern die Tabelle in ihre eigene JSON -> ein Tuning an
-- Adas Shell wanderte in Leons Skull-Shaker-Werte. Jetzt EIGENE Tabelle.
-- Startwerte werden EINMALIG aus Leons Tabelle KOPIERT (kein Verweis!), damit nichts springt --
-- ab dem ersten Tunen laufen die beiden vollstaendig getrennt.
_G.__re4_ss_clone_dlc = _G.__re4_ss_clone_dlc or (function()
    local t = { part = 1, x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0, scale = 1.0, preview = false }
    local src = rawget(_G, "__re4_ss_clone")
    if type(src) == "table" then for k, v in pairs(src) do t[k] = v end end
    return t
end)()
-- [NO_CYCLE_AFTER_SHOT] Waffen die NACH dem Schuss KEIN Cyceln brauchen (frei ballern bis 0). Der Cycle
-- ist NUR Teil des Ladens (nach jeder Einfuehrbewegung). Striker = Drehschalter nur beim Nachladen.
local NO_CYCLE_AFTER_SHOT = {}   -- [DLC] leer: die Sawed-off ist wie die W-870 eine echte Pump-Gun -> Pump nach dem Schuss bleibt
-- [NO_RELOAD_CYCLE 2026-07-17] Waffen die nach einem TAKTISCHEN Shell-Insert (noch geladen) KEINEN
-- Cycle/Pump brauchen -> frei weiterballern; nur der 0-Reload chambert (bei der Riot Gun per Slide-Rack _08).
-- NUR die Riot Gun (4101)! NICHT NO_CYCLE_AFTER_SHOT nehmen -- da stehen auch Striker (4102, braucht den
-- Drehschalter-Cycle nach JEDER Shell) und Skull Shaker (6001, Break-Action-Cock) drin, die ihren Reload-
-- Cycle behalten MUESSEN. W-870 (4100, echte Pump-Gun) ist ohnehin nicht hier -> Pump bleibt.
local NO_RELOAD_CYCLE = {}   -- [DLC] leer (war nur Riot Gun 4101)
-- [DRYFIRE_ONLY_WHEN_EMPTY] Feuer-Block/Dry-Fire NUR bei wirklich leerer Waffe (nicht nach Schuss/Drum).
-- Striker (semi-auto Drum) ballert frei bis 0. Andere Shotguns: normales Verhalten.
local DRYFIRE_ONLY_WHEN_EMPTY = {}   -- [DLC] leer (war nur Striker 4102)
-- [ROTARY_CYCLE] Waffen deren "slide"-Joint KEIN Z-Slide, sondern ein DREHSCHALTER ist (Striker joint_01).
-- Cycle-Input = Left Grip + Left Trigger (wie LE5-Schalter): joint_01 dreht ~rz Grad, Hand folgt, dann
-- clear_rack (eine Drehung pro geladener Shell). NUR diese Waffen; Pump-/Pistolen-Pfade unberuehrt.
local ROTARY_CYCLE = {}   -- [DLC] leer: kein Drehschalter im reload4-Set
-- [BREAK_ACTION] Lever/Klappe-Shotguns: slide-Joint ist ein Pitch-Hebel (joint_02), kein Z-Slide.
-- Skull Shaker: Hebel runterklappen (oeffnen) -> Shells oben rein -> hochklappen (schliessen/cocken).
-- BASIS: nur als Flag + aus der Z-Slide-Logik ausgegatet; die eigentliche Mechanik kommt noch.
local BREAK_ACTION = {}   -- [DLC] leer: keine Break-Action im reload4-Set
-- Dreh-Euler (Grad) bei voller Drehung; eine Achse setzen. Default 15 Grad um lokales Z -> per UI tunen.
-- grab_dist = Abstand Hand->Schalter (m), ab dem gegriffen wird (eigener Wert, NICHT der Pump-Wert).
-- rx/ry/rz=Joint-Rotation bei voll (Rotary: gedreht; Break: aufgeklappt). pitch_range=Controller-Pitch-Grad
-- fuer voll auf<->zu (nur Break). grab_dist=Greif-Distanz. lerp=Dreh-Geschw. (nur Rotary).
local ROTARY_DEFAULT = { rx = 0.0, ry = 0.0, rz = 15.0, grab_dist = 0.15, lerp = 0.06, pitch_range = 55.0 }
-- Per-Waffe-Defaults (JSON ueberschreibt nach Tunen). Striker: RotZ -80. Skull Shaker: Pitch-Klappe (RotX -60 Startwert).
local ROTARY = {}   -- [DLC] leer: kein Drehschalter/Hebel im reload4-Set
local function rotary_cfg(wid)
    local r = ROTARY[wid]
    if not r then r = {}; for k, v in pairs(ROTARY_DEFAULT) do r[k] = v end; ROTARY[wid] = r end
    for k, v in pairs(ROTARY_DEFAULT) do if r[k] == nil then r[k] = v end end
    return r
end
-- Laufzeit: prog 0..1 Dreh-Fortschritt, dir +1=hin/-1=zurueck/0=ruht, preview = UI-Tuning haelt die Drehung
-- _grip_latched = die aktuelle Grip-Haltung gehoert dem Schalter (blockt Two-Hand bis Loslassen+Neugriff)
local rotary = { prog = 0.0, dir = 0, _prev_trig = false, _prev_grip = false, _grip_latched = false, preview = false, _last_dist = -1 }
-- [BREAK_ACTION] Klapphebel-State (Skull Shaker joint_02). RIGHT-B togglet open; prog 0=zu..1=auf (gelerped).
local break_st = { prog = 0.0, open = false, _prev_b = false, _was_open = false, preview = false }
-- Joint-Finder: beliebigen Waffen-Joint live verschieben, um den echten Slide zu finden
local finder = { active = false, name = "_01", idx = 1, x = 0.0, y = 0.0, z = 0.0, base = nil, base_name = nil }

-- Waffen-Namen (WeaponID -> Klarname). Fuer UI-Anzeige aller Pro-Waffe-Settings.
local WEAPON_NAMES = {
    [4000]="SG-09 R", [4001]="Punisher", [4002]="Red9", [4003]="Blacktail", [4004]="Matilda",
    [4005]="Don Quixote", [4100]="W-870", [4101]="Riot Gun", [4102]="Striker", [4200]="TMP",
    [4201]="Chicago Sweeper", [4202]="LE 5", [4400]="SR M1903", [4401]="Stingray",
    [4402]="CQBR Assault Rifle", [4500]="Broken Butterfly", [4501]="Killer7", [4502]="Handcannon",
    [4600]="Bolt Thrower", [4701]="Flamethrower", [4702]="P.R.L. 9412", [4800]="Silent Crossbow",
    [4801]="XJF-350 Compound Bow", [4900]="Rocket Launcher", [4901]="Rocket Launcher (Special)",
    [4902]="Infinite Rocket Launcher", [5000]="Combat Knife", [5001]="Fighting Knife",
    [5002]="Kitchen Knife", [5003]="Boot Knife", [5004]="Water Pipe", [5005]="Giant Rock",
    [5006]="Primal Knife", [5400]="Hand Grenade", [5401]="Heavy Grenade", [5402]="Flash Grenade",
    [5403]="Chicken Egg", [5404]="Brown Chicken Egg", [5405]="Gold Chicken Egg",
    [5500]="Unlimited Bottomless Ammo", [6000]="Sentinel Nine", [6001]="Skull Shaker",
    [6100]="Sawed-off W-870", [6101]="Chicago Sweeper w/ Drum", [6102]="Blast Crossbow",
    [6103]="Blacktail AC", [6104]="MP-AF", [6105]="Anti-Materiel Rifle", [6106]="Rocket Launcher (SW)",
    [6107]="Tactical Knife", [6108]="Elite Knife", [6109]="Scorcher XL", [6110]="XM96E1",
    [6111]="Infinite Rocket Launcher (SW)", [6112]="Punisher MC", [6113]="Samurai Edge",
    [6114]="Hunting Rifle", [6300]="XM96E1 (MC)", [6301]="Blacktail AC (MC)", [6302]="Quickdraw Army",
    [6304]="EJF-338 Compound Bow", [6305]="Hot Dogger",
}
local function weapon_name(wid) return wid and WEAPON_NAMES[wid] or nil end
local function wp_label(wid)
    local n = weapon_name(wid)
    return n and string.format("wp%s (%s)", tostring(wid), n) or ("wp" .. tostring(wid or "-"))
end

-- Waffen-Kategorien (per WeaponID). Pistolen bestaetigt; Rest folgt.
local CATEGORIES = {
    -- [DLC] NUR Separate-Ways-IDs. Die Maincampaign-Waffen gehoeren re4_vr_reload.lua --
    -- dieses File fasst sie NICHT an (category_of liefert dort nil -> alle Gates greifen nicht).
    pistols = { [6103]=true, [6112]=true },   -- Blacktail AC / Punisher MC
    -- [6113 RAUS 2026-07-19] Die Samurai Edge ist EXAKT eine Red9 -> Top-Loader, kein Mag.
    -- Sie lebt jetzt komplett in re4_vr_reload5_dlc.lua (Klon des Red9-Blocks aus reload2).
    -- NIE hier wieder eintragen: zwei Files duerfen nie dieselbe WeaponID verwalten.
    smgs    = { [6104]=true },                             -- MP-AF (TMP-Klon)
    shotguns= { [6100]=true },                             -- Sawed-off W-870
    magnum  = {},
    rifles  = {},   -- Anti-Materiel (6105) / Hunting Rifle (6114) -> re4_vr_reload5_dlc.lua
}

-- Per-Waffe Joints: mag = Magazin-Joint, slide = Slide-Joint
local JOINTS = {
    -- [DLC] 1:1 von der jeweiligen Basiswaffe. Im DLC live gegenpruefen (Cycler im UI).
    [6112] = { mag = "_14", slide = "_01" },   -- Punisher MC <- 4001
    [6103] = { mag = "_14", slide = "_01" },   -- Blacktail AC <- 4003
    [6104] = { mag = "_04", slide = "_09" },   -- MP-AF <- TMP 4200
    [6100] = { mag = "_04", slide = "_01" },   -- Sawed-off <- W-870 4100 (Shell=_04, Pump=_01)
}

-- [POSE PER WAFFE] Eigene Hand-Posen pro wid (Mag-Halten + Slide-Rack). Fallback = globale
-- CFG.mag_hold_pose / CFG.rack_pose -> Waffen OHNE Eintrag (alle Pistolen) bleiben EXAKT gleich.
-- Nur Waffen mit eigenem Eintrag (z.B. SMGs) nutzen ihre eigene gecapturete Pose.
-- [DLC] MP-AF erbt die TMP-Pose, Sawed-off die Shotgun-Shell-Pose.
-- [PUNISHER/BLACKTAIL 2026-07-19] 6112/6103 explizit auf "MAG" -- Leons Pistolen holen sich
-- diese Pose ueber den GLOBALEN Wert (CFG.mag_hold_pose = "MAG"). Bei Ada stand der global auf ""
-- (leer = keine Pose, Finger frei) -> das Punisher-Magazin wurde ohne Handpose gehalten.
-- Explizit pro Waffe ist stabiler: ueberlebt jeden Klick auf "Globale Pose entfernen".
local MAG_POSE  = { [6104] = "TMPMAG", [6100] = "Shotgunshell", [6112] = "MAG", [6103] = "MAG" }
local RACK_POSE = { [6100] = "SGPUMP", [6103] = "MAGRack", [6104] = "rack-slide" }   -- [TMP 2026-07-20] MP-AF-Slide = dieselbe Pose wie der Samurai-Edge-Slide ("Red9Slide" ist laut Code eine 1:1-Kopie von "rack-slide"); geladen aus re4_vr_reload4_dlc.json -> ADAS Haende -- [DLC] Sawed-off = W-870-Pumpgriff; Blacktail AC = MAGRack (wie 4003)
local RACK_POSE_EMPTY = {}   -- [DLC] leer (war nur Riot Gun 4101)
-- [INSERT-DIST PRO GATTUNG] Abstand Hand->Waffe (m), ab dem das Mag reingleitet. KEIN globaler
-- Wert: jede Gattung hat ihren eigenen. Pistolen-Wert wird beim Laden aus dem alten
-- CFG.insert_distance uebernommen; SMGs/etc. starten als Kopie des Pistolen-Werts.
local INSERT_DIST = { pistols = 0.15, smgs = 0.15, shotguns = 0.15, magnum = 0.15, rifles = 0.15 }
-- [INSERT-DIST PRO WAFFE] Optionaler Override pro WeaponID. Gesetzt = gilt VOR dem Gattungs-Wert,
-- nil = Gattungs-Wert (INSERT_DIST[cat]). So kann z.B. die TMP einen eigenen Wert haben, ohne die
-- LE5 (gleiche Gattung smgs) zu aendern. Nur Waffen mit Eintrag weichen ab.
local INSERT_DIST_WID = {}
-- [SHOTGUN-RATIO PRO WAFFE] Optionaler Override pro WeaponID (Shells pro Einfuehrbewegung). Gesetzt =
-- gilt VOR dem globalen CFG.shotgun_ratio, nil = globaler Wert. So hat z.B. die Striker ein anderes
-- Ratio als die W-870, ohne die andere zu aendern.
local SHOTGUN_RATIO_WID = {}

-- [POSE-STORE] Die gecaptureten Hand-Pose-DATEN (Finger-Quaternionen) gehoeren zu unseren
-- Reloads -> hier in reload.lua besitzen + anwenden, persistiert in re4_vr_reload.json ("poses").
-- gestures.lua ist NUR Capture-Tool: beim Laden importieren wir neue Captures aus gestures.json.
-- POSES[name] = { hand = "left"/"right", bones = { [bone] = {w,x,y,z} } }
local POSES = {}

-- [CHAMBER_HOLD_PERSIST] Per-Waffe (DATEN, nicht Logik): bei diesen Waffen den Nach-Rack-
-- Halt (rest_z) NICHT beim 1. Schuss loesen, sondern bis die Waffe wirklich LEER ist.
-- Grund: deren Engine-Slide-Anim schliesst nach dem Schuss nicht sauber -> Slide schnappt
-- sichtbar zurueck. Matilda/Punisher (nil) behalten das Original-Verhalten 1:1.
-- Diag (re4_reload_diag.log, SLIDE_OFF_REST) belegt: auch Punisher (4001) bleibt nach dem 1. Schuss
-- voll hinten haengen (lz hinter back_z) -> die Engine schliesst den Slide nach manuellem Reload bei
-- KEINER Standard-Pistole. Daher ALLE Standard-Pistolen persistieren (rest_z halten bis leer).
local CHAMBER_HOLD_PERSIST = { [6103] = true, [6112] = true }   -- [DLC] Standardpistolen (6113 -> reload5_dlc)

-- [ENGINE_CLOSES_SLIDE] Per-Waffe (DATEN, nicht Logik): das Slide-SCHLIESSEN (zurueck auf
-- gechambert/vorne) macht die ENGINE selbst (ihre Reload/Chamber-Anim faehrt den Slide vor).
-- Bei diesen Waffen forcen WIR KEINEN rest_z-Halt -> kein falscher rest_z-Sprung. Es werden
-- NUR park_z (MITTEL: 0 Ammo / Mag-Drop) und back_z (Rack-Zugweg) genutzt; die geschlossene
-- Position ist Sache der Engine (Gate in apply_slide_park gibt im Ruhezustand eh schon zurueck).
-- Matilda/Punisher (nil) behalten _chambered_hold (deren Engine schliesst nach manuellem
-- Reload NICHT -> Slide wuerde sonst offen klemmen, s. Slide-Rack-Saga). Schrittweise ausweiten.
-- [TMP SLIDE-RACK 2026-07-20] 6104 (MP-AF = Adas TMP) ist hier RAUS: sie bekommt ein echtes
-- Slide-Rack ueber Joint _09. Vorher "Engine schliesst selbst" -> keine Rack-Bedingung vorhanden.
local ENGINE_CLOSES_SLIDE = {}

-- [SHOTGUN] Per-Waffe-Set: Pump-Action-Shotguns laufen den shell-by-shell Lade-Pfad (Shell in die
-- Hand greifen statt Mag-Drop; Insert addiert SHOTGUN_SHELL_RATIO statt vollem Mag; kein B-Eject;
-- Release legt die Shell zurueck statt sie fallen zu lassen). Sonst 1:1 die bestehende Pipeline
-- (Shell-Joint folgt der Hand via update_mag_in_hand, Pump = Slide-Rack auf slide=_01).
local SHOTGUNS = { [6100] = true }   -- [DLC] Sawed-off W-870
local function is_shotgun(wid) return wid ~= nil and SHOTGUNS[wid] == true end
-- [SHOTGUN] Reload-Verhaeltnis: 1 Einfuehrbewegung laedt so viele Shells (gedeckelt auf cap-loaded
-- und Reserve). UI schaltet 1:1 (=1) / 1:2 (=2). Default 1:2 wie RE9. Persistiert in CFG.
-- (Wert lebt in CFG.shotgun_ratio.)

-- [TOP_LOADER] Per-Waffe (DATEN): Waffen OHNE herausfallendes Magazin, die von oben mit
-- einem Schnelllader / Einzelpatronen geladen werden (Red9). Bei diesen ist das Modell
-- grundsaetzlich anders: KEIN Mag-Auswurf -> der Mag-Holster darf NICHT auf mag_out warten,
-- sondern ist IMMER greifbar solange Reserve-Ammo da ist (sonst Leer-Puls). Alles hier ist
-- gekapselt: nur Waffen in dieser Tabelle laufen den Sonderpfad, alle anderen 1:1 wie bisher.
local TOP_LOADER = {}   -- (Red9/4002 ausgezogen -> jetzt eigener Aufbau in reload2.lua)

-- [CHAMBER] Per-Waffe: welcher Joint ist der Chamber + wie weit faehrt er beim Oeffnen (Z).
-- Rechter B togglet diesen Joint zwischen Ruhe (zu) und Ruhe+z (offen). Red9: Joint _01, +0.115.
-- (Visuell ermittelt mit dem Joint-Cycler.) Gekapselt: nur Waffen hier haben das Chamber-Modell.
local CHAMBER = {}   -- (Red9/4002 ausgezogen -> eigener Aufbau in reload2.lua)
-- [CHAMBER] Ramp-Schritt pro Frame fuer das weiche Auf-/Zufahren (0..1), smoothstep im Apply.
local CHAMBER_BLEND_SPEED = 0.10

local function category_of(wid)
    for cat, set in pairs(CATEGORIES) do if set[wid] then return cat end end
    return nil
end
local function category_enabled(cat)
    return cat and CFG[cat .. "_enabled"] == true
end

local function load_cfg()
    local data = safe(function() return json.load_file(CFG_PATH) end)
    if type(data) ~= "table" then return end
    local c = data.cfg or data
    -- "enabled" (Master) NICHT mehr laden -> bleibt immer true. Jede Gattung haengt an ihrem
    -- eigenen Toggle (pistols_enabled/smgs_enabled/...). Master-Toggle entfernt.
    for _, k in ipairs({ "pistols_enabled","smgs_enabled","shotguns_enabled","magnum_enabled","rifles_enabled","reload_ammo","rack_enabled","rack_haptic","sound_enabled" }) do
        if type(c[k]) == "boolean" then CFG[k] = c[k] end
    end
    CFG.enabled = true   -- Master gibt's nicht mehr (immer an)
    for _, k in ipairs({ "gravity","insert_dur","insert_distance","rack_grab_dist","mag_floor_delay","shotgun_ratio","pump_haptic_delay",
                         "insert_overshoot","insert_settle","insert_haptic","insert_snd_at",
                         "insert_travel","insert_back_out","insert_redock","insert_snap_at",   -- [MANUAL_INSERT]
                         "rack_pose_side_deg" }) do   -- [INSERT-PUNCH] / [RACK_POSE_ANGLE]
        if type(c[k]) == "number" then CFG[k] = c[k] end
    end
    if type(c.insert_punch) == "boolean" then CFG.insert_punch = c.insert_punch end   -- [INSERT-PUNCH]
    if type(c.insert_manual) == "boolean" then CFG.insert_manual = c.insert_manual end   -- [MANUAL_INSERT]
    if type(c.mag_hold_pose) == "string" and c.mag_hold_pose ~= "" then CFG.mag_hold_pose = c.mag_hold_pose end
    if type(c.rack_pose) == "string" then CFG.rack_pose = c.rack_pose end
    if type(c.rack_pose_side) == "string" and c.rack_pose_side ~= "" then CFG.rack_pose_side = c.rack_pose_side end   -- [RACK_POSE_ANGLE]
    -- Legacy: altes GLOBALES Daumen-Offset (vor der Per-Waffe-Umstellung) fuer Migration merken
    local legacy_thumb = nil
    if type(c.thumb_rx) == "number" or type(c.thumb_ry) == "number" or type(c.thumb_rz) == "number" then
        legacy_thumb = { rx = c.thumb_rx or 0, ry = c.thumb_ry or 0, rz = c.thumb_rz or 0 }
    end
    local thumb_present = {}
    if type(data.maghand) == "table" then
        for k, v in pairs(data.maghand) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                MAGHAND[wid] = { x = v.x or 0, y = v.y or 0, z = v.z or 0,
                                 rx = v.rx or 0, ry = v.ry or 0, rz = v.rz or 0,
                                 t_rx = v.t_rx or 0, t_ry = v.t_ry or 0, t_rz = v.t_rz or 0,
                                 f_curl = v.f_curl or 0 }   -- [ADA_FINGER_CURL] sonst beim Laden verloren
                if v.t_rx ~= nil or v.t_ry ~= nil or v.t_rz ~= nil then thumb_present[wid] = true end
            end
        end
    end
    -- [SHELL_CLONE] Skull Shaker Part-1-Clone-Offsets (Global) laden
    if type(data.shell_clone) == "table" then
        local scl = _G.__re4_ss_clone_dlc
        for _, kk in ipairs({ "part", "x", "y", "z", "rx", "ry", "rz", "scale" }) do
            if type(data.shell_clone[kk]) == "number" then scl[kk] = data.shell_clone[kk] end
        end
    end
    -- [SHELL_EJECT] Chamber-Startposition pro Waffe laden
    if type(data.shell_eject) == "table" then
        for k, v in pairs(data.shell_eject) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local e = shell_eject_cfg(wid)
                for _, kk in ipairs({ "sx","sy","sz","srx","sry","srz","vx","vy","vz","grav","dur","spin" }) do
                    if type(v[kk]) == "number" then e[kk] = v[kk] end
                end
            end
        end
    end
    -- [DLC] Seed: die Werte kommen bereits fertig aus re4_vr_reload4_dlc.json (beim Anlegen 1:1
    -- aus re4_vr_reload.json der Basiswaffen kopiert). Hier nur der Fallback, falls eine DLC-Waffe
    -- gar keinen Eintrag hat -> erbt die Punisher-MC-Pose (6112).
    if legacy_thumb and not thumb_present[6112] then
        local m = maghand(6112)
        m.t_rx, m.t_ry, m.t_rz = legacy_thumb.rx, legacy_thumb.ry, legacy_thumb.rz
    end
    if MAGHAND[6112] then
        local s = MAGHAND[6112]
        for _, w in ipairs({ 6103, 6104, 6100 }) do   -- 6113 raus -> reload5_dlc
            if not MAGHAND[w] then
                MAGHAND[w] = { x=s.x, y=s.y, z=s.z, rx=s.rx, ry=s.ry, rz=s.rz, t_rx=s.t_rx, t_ry=s.t_ry, t_rz=s.t_rz }
            end
        end
    end
    -- ([PORT]-Bloecke der Maincampaign-IDs 4001/4004/4000/4003/6000/42xx ENTFERNT -- dieses File
    -- kennt nur 61xx. Der Seed darueber macht dasselbe fuer die DLC-Waffen.)
    -- [JOINTS CODE-ONLY] Joints werden BEWUSST NICHT mehr aus der JSON geladen. Sie sind Code-
    -- Konstanten (einmal visuell bestimmt, in der JOINTS-Tabelle oben). Frueher hat ein verklickter
    -- Cycler-Wert (z.B. LE5 mag=_03 statt _04) die JSON ueberschrieben und still den Code-Default
    -- ueberstimmt -> falscher Drop-Joint. Nie wieder: die Code-Tabelle ist die einzige Wahrheit.
    -- (Der Cycler unten setzt nur IN-MEMORY zum Probieren; Fund wird im Code hardcodiert.)
    -- Slide-Hand-Dock (Position + Rotations-Offset) pro Waffe; rest/park/back bleiben hardcoded
    if type(data.slide_dock) == "table" then
        for k, v in pairs(data.slide_dock) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local sp = slide_pose(wid)
                -- [POSE2_OFFSETS] sdock_*/srack_* = zweiter Satz (Seiten-/MAG-Rack-Pose). Fehlen sie in
                -- einer alten JSON, bleibt der Blacktail-Startwert aus SLIDE_POSE_DEFAULT stehen.
                for _, f in ipairs({ "dock_x","dock_y","dock_z","rack_rx","rack_ry","rack_rz","rest_z","park_z","back_z",
                                     "sdock_x","sdock_y","sdock_z","srack_rx","srack_ry","srack_rz" }) do
                    if type(v[f]) == "number" then sp[f] = v[f] end
                end
            end
        end
    end
    -- [EMPTY-RELOAD SLIDE] _08-Travel/Dock laden (Riot Gun)
    if type(data.slide_dock2) == "table" then
        for k, v in pairs(data.slide_dock2) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local sp = slide_pose2(wid)
                for _, f in ipairs({ "dock_x","dock_y","dock_z","rack_rx","rack_ry","rack_rz","rest_z","park_z","back_z" }) do
                    if type(v[f]) == "number" then sp[f] = v[f] end
                end
            end
        end
    end
    -- [POSE PER WAFFE] gecapturete Hand-Posen pro Waffe laden (Pistolen ohne Eintrag = global)
    if type(data.mag_pose) == "table" then
        for k, v in pairs(data.mag_pose) do local wid = tonumber(k); if wid and type(v) == "string" then MAG_POSE[wid] = v end end
    end
    if type(data.rack_pose_w) == "table" then
        for k, v in pairs(data.rack_pose_w) do local wid = tonumber(k); if wid and type(v) == "string" then RACK_POSE[wid] = v end end
    end
    -- [INSERT-DIST PRO GATTUNG] kein globaler Wert: Pistolen erben den alten CFG.insert_distance,
    -- andere Gattungen ihren gespeicherten Wert ODER (ungetunt) eine Kopie des Pistolen-Werts.
    INSERT_DIST.pistols = CFG.insert_distance or INSERT_DIST.pistols
    local _sd = (type(data.insert_dist) == "table") and data.insert_dist or {}
    for _, cat in ipairs({ "pistols", "smgs", "shotguns", "magnum", "rifles" }) do
        if type(_sd[cat]) == "number" then INSERT_DIST[cat] = _sd[cat]
        elseif cat ~= "pistols" then INSERT_DIST[cat] = INSERT_DIST.pistols end
    end
    -- [INSERT-DIST PRO WAFFE] Per-WeaponID-Override laden (wid-keys als String).
    if type(data.insert_dist_wid) == "table" then
        for k, v in pairs(data.insert_dist_wid) do
            local wid = tonumber(k); if wid and type(v) == "number" then INSERT_DIST_WID[wid] = v end
        end
    end
    if type(data.shotgun_ratio_wid) == "table" then
        for k, v in pairs(data.shotgun_ratio_wid) do
            local wid = tonumber(k); if wid and type(v) == "number" then SHOTGUN_RATIO_WID[wid] = v end
        end
    end
    -- [SHELL_PART_PERSIST] gelernte Shell-Sub-Mesh-Part-Indizes pro Waffe laden (Liste von Indizes).
    -- Mutieren (nicht neu zuweisen) -> der Alias _sg_shell_by_wid = SHELL_PARTS bleibt gueltig.
    if type(data.shell_parts) == "table" then
        for k, v in pairs(data.shell_parts) do
            local wid = tonumber(k)
            if wid and type(v) == "table" and #v > 0 then SHELL_PARTS[wid] = v end
        end
    end
    -- [ROTARY_CYCLE] Drehschalter-Werte pro Waffe laden (ueberschreibt die Code-Defaults nach dem Tunen).
    if type(data.rotary) == "table" then
        for k, v in pairs(data.rotary) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                local rr = rotary_cfg(wid)
                for _, f in ipairs({ "rx", "ry", "rz", "grab_dist", "lerp", "pitch_range" }) do
                    if type(v[f]) == "number" then rr[f] = v[f] end
                end
            end
        end
    end
    -- [POSE-STORE] 1) Pose-DATEN aus reload.json laden
    if type(data.poses) == "table" then
        for name, v in pairs(data.poses) do
            if type(v) == "table" and type(v.bones) == "table" then POSES[name] = { hand = v.hand, bones = v.bones } end
        end
    end
    -- [POSE-STORE] 2) neue Captures aus gestures.json importieren (gestures = nur Capture-Tool).
    -- gestures-Version gewinnt (frischester Capture). Faellt weg wenn gestures.json geloescht.
    local gj = safe(function() return json.load_file("re4_vr/re4_vr_gestures_capture.json") end)
    local gp = gj and (gj.poses or gj)
    if type(gp) == "table" then
        for name, v in pairs(gp) do
            if type(v) == "table" and type(v.bones) == "table" then POSES[name] = { hand = v.hand, bones = v.bones } end
        end
    end
    -- KEIN Uebernehmen von Matilda-Werten mehr: die Punisher (und jede andere Pistole) wird
    -- eigenstaendig getunt. Slide-Dock/Rack/Slide-Z starten auf Code-Default (0 bzw. neutral).
end
local function save_cfg()
    local jt = {}
    for wid, v in pairs(JOINTS) do jt[tostring(wid)] = { mag = v.mag, slide = v.slide } end
    local c = {}
    for k, v in pairs(CFG) do c[k] = v end
    local mh = {}
    for wid, v in pairs(MAGHAND) do mh[tostring(wid)] = v end
    local se = {}
    for wid, v in pairs(SHELL_EJECT) do se[tostring(wid)] = v end
    local sdk_dock = {}
    for wid, v in pairs(SLIDE_POSE) do
        sdk_dock[tostring(wid)] = { dock_x = v.dock_x, dock_y = v.dock_y, dock_z = v.dock_z,
                                    rack_rx = v.rack_rx, rack_ry = v.rack_ry, rack_rz = v.rack_rz,
                                    -- [POSE2_OFFSETS] zweiter Satz (Seiten-/MAG-Rack-Pose)
                                    sdock_x = v.sdock_x, sdock_y = v.sdock_y, sdock_z = v.sdock_z,
                                    srack_rx = v.srack_rx, srack_ry = v.srack_ry, srack_rz = v.srack_rz,
                                    rest_z = v.rest_z, park_z = v.park_z, back_z = v.back_z }
    end
    -- [EMPTY-RELOAD SLIDE] _08-Travel/Dock pro Waffe (Riot Gun) separat
    local sdk_dock2 = {}
    for wid, v in pairs(SLIDE_POSE2) do
        sdk_dock2[tostring(wid)] = { dock_x = v.dock_x, dock_y = v.dock_y, dock_z = v.dock_z,
                                     rack_rx = v.rack_rx, rack_ry = v.rack_ry, rack_rz = v.rack_rz,
                                     rest_z = v.rest_z, park_z = v.park_z, back_z = v.back_z }
    end
    local mpose, rpose = {}, {}
    for wid, v in pairs(MAG_POSE)  do mpose[tostring(wid)] = v end
    for wid, v in pairs(RACK_POSE) do rpose[tostring(wid)] = v end
    -- INSERT_DIST ist pro GATTUNG (string-keys pistols/smgs/...) -> direkt speichern
    local idist = {}; for cat, v in pairs(INSERT_DIST) do idist[cat] = v end
    -- [INSERT-DIST PRO WAFFE] Per-WeaponID-Override separat speichern (wid-keys als String).
    local idist_w = {}; for wid, v in pairs(INSERT_DIST_WID) do idist_w[tostring(wid)] = v end
    -- [SHOTGUN-RATIO PRO WAFFE] Per-WeaponID-Override (Shells pro Einfuehrbewegung).
    local sratio_w = {}; for wid, v in pairs(SHOTGUN_RATIO_WID) do sratio_w[tostring(wid)] = v end
    -- [ROTARY_CYCLE] Drehschalter-Werte pro Waffe persistieren (rx/ry/rz/grab_dist/lerp).
    local rotcfg = {}
    for wid, v in pairs(ROTARY) do
        rotcfg[tostring(wid)] = { rx = v.rx, ry = v.ry, rz = v.rz, grab_dist = v.grab_dist, lerp = v.lerp, pitch_range = v.pitch_range }
    end
    -- [SHELL_PART_PERSIST] gelernte Shell-Sub-Mesh-Part-Indizes pro Waffe (Liste von Part-Indizes).
    local sparts = {}
    for wid, v in pairs(SHELL_PARTS) do sparts[tostring(wid)] = v end
    -- [SHELL_CLONE] Skull Shaker Part-1-Clone-Offsets (Global) persistieren
    local sscl = _G.__re4_ss_clone_dlc or {}
    local sclone = { part = sscl.part, x = sscl.x, y = sscl.y, z = sscl.z, rx = sscl.rx, ry = sscl.ry, rz = sscl.rz, scale = sscl.scale }
    pcall(function() json.dump_file(CFG_PATH, { cfg = c, joints = jt, maghand = mh, shell_eject = se, slide_dock = sdk_dock, slide_dock2 = sdk_dock2, mag_pose = mpose, rack_pose_w = rpose, insert_dist = idist, insert_dist_wid = idist_w, shotgun_ratio_wid = sratio_w, poses = POSES, rotary = rotcfg, shell_parts = sparts, shell_clone = sclone }) end)
end

-- =====================================================================
-- Player / Waffe
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
local function get_body()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.body_go() end
    local ctx = get_ctx(); return ctx and sc(ctx, "get_BodyGameObject")
end
local function body_tf()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.body_tf() end
    local b = get_body(); return b and sc(b, "get_Transform")
end

-- =====================================================================
-- [POSE-STORE] Hand-Pose anwenden (eigene Engine -> KEINE gestures.lua-Abhaengigkeit).
-- Finger-Joint-LocalRotation aus POSES[name].bones schreiben (nlerp bei blend<1).
-- Exponiert als _G.__re4_reload_apply_pose; motion.lua ruft das an (statt gestures).
-- =====================================================================
local _pmap_tf, _pmap = nil, {}
local function pose_build_map()
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
local function pose_apply(name, blend)
    local pose = name and POSES[name]
    if not pose or not pose.bones then return false end
    local map = pose_build_map(); if next(map) == nil then return false end
    blend = blend or 1.0
    if blend <= 0.0 then return true end
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
    -- [ADA_FINGER_CURL 2026-07-19] EIN Kruemmungswert pro Waffe, ADDITIV auf die Pose.
    -- Zweck: Adas Finger sind kleiner als Leons -> die geerbte Pose greift zu weit/zu eng. Statt die
    -- Pose neu zu capturen (das liefe ueber das GEMEINSAME gestures.json und wuerde Leons Pose treffen)
    -- bleibt Leons Pose der unveraenderte BASISWERT und Ada bekommt nur ein Delta obendrauf.
    -- Mechanik 1:1 wie der bewaehrte Mag-Daumen-Offset bzw. knife_flip_finger_open in motion.lua:
    -- additive Rotation um die lokale X-Achse, links gespiegelt (-X), post-multipliziert.
    -- Der DAUMEN bleibt aussen vor -- der hat mit t_rx/t_ry/t_rz bereits sein eigenes Tuning.
    -- Gilt nur fuer Posen, die DIESES File anwendet (Dispatch unten) -> fuer Leon unerreichbar.
    do
        local mw = get_equip_wid()
        local mh = mw and MAGHAND[mw]
        local curl = mh and tonumber(mh.f_curl) or 0
        if curl ~= 0 then
            local h = math.rad(curl) * 0.5
            for bone in pairs(pose.bones) do
                if not bone:find("Thumb") then
                    local j = map[bone]
                    if j then
                        local hh = bone:find("^L_") and -h or h
                        local add = Quaternion.new(math.cos(hh), math.sin(hh), 0, 0)
                        local cur = safe(function() return j:call("get_LocalRotation") end)
                        if cur then pcall(function() j:call("set_LocalRotation", (cur * add):normalized()) end) end
                    end
                end
            end
        end
    end
    return true
end
-- [POSE-ABKAPSELUNG 2026-07-19] Hier stand ein `or`-Guard -- und weil re4_vr_reload.lua
-- alphabetisch VORHER laedt und hart setzt, hat dieses File seine eigene POSES-Tabelle NIE benutzt:
-- Adas Fingerposen kamen immer aus LEONS Tabelle. Eine Pose fuer Adas kleinere Finger nachzujustieren
-- haette damit Leons Pose mitveraendert -- genau das, was nie passieren darf.
-- Jetzt Dispatch nach Waffen-ID (Muster wie __re4_reload_set_mag_in_hand):
-- DLC-Waffe (category_of ~= nil) -> UNSERE POSES-Tabelle, aus re4_vr_reload4_dlc.json
-- alles andere -> unveraendert an die vorherige Funktion (Leon/reload2/3)
-- LEON-NEUTRAL: fuer seine IDs wird 1:1 dieselbe Funktion mit denselben Argumenten aufgerufen.
-- [ZURUECKGENOMMEN 2026-07-19] Hier stand ein Dispatch-Wrapper auf __re4_reload_apply_pose.
-- Er hat Leons Mag-in-Hand-Posen lahmgelegt -> wieder der urspruengliche or-Guard.
_G.__re4_reload_apply_pose = _G.__re4_reload_apply_pose or pose_apply
-- [KNIFE_HAND 2026-07-07] Externe Pose (bones-Dict DIREKT, ohne POSES/Namen) anwenden. re4_vr_knife_
-- lefthand.lua liefert die selbst-gespiegelte Links-Messer-Pose -> unabhaengig von gestures/POSES.
-- Gleicher Joint-Writer wie pose_apply (nlerp bei blend<1).
_G.__re4_reload_apply_pose_bones = _G.__re4_reload_apply_pose_bones or function(bones, blend)
    if type(bones) ~= "table" then return false end
    local map = pose_build_map(); if next(map) == nil then return false end
    blend = blend or 1.0
    if blend <= 0.0 then return true end
    for bone, v in pairs(bones) do
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
    return true
end
-- Pose-Namen (sortiert) fuer die UI-Picker -> unabhaengig von gestures
-- [POSE-ABKAPSELUNG] Das globale Hook bleibt Leons (er besitzt den Namensraum fuer SEINE UI).
-- Fuer die UI DIESES Files gibt es einen eigenen Zugriff auf die EIGENE POSES-Tabelle -- sonst
-- haette der Picker hier Leons Posenliste angezeigt und Adas eigene Posen nie zur Auswahl gestellt.
_G.__re4_reload_pose_names = _G.__re4_reload_pose_names or function()
    local t = {}; for n in pairs(POSES) do t[#t+1] = n end; table.sort(t); return t
end
_G.__re4_reload4_pose_names = function()
    local t = {}; for n in pairs(POSES) do t[#t+1] = n end; table.sort(t); return t
end
local function search_tree(tf, target, depth)
    if not tf or depth < 0 then return nil end
    local child = sc(tf, "get_Child"); local n = 0
    while child and n < 128 do
        n = n + 1
        local go = sc(child, "get_GameObject")
        local gn = go and sc(go, "get_Name")
        if gn and tostring(gn) == target and sc(go, "get_DrawSelf") ~= false then return go, child end
        local fgo, ftf = search_tree(child, target, depth - 1)
        if fgo then return fgo, ftf end
        child = sc(child, "get_Next")
    end
end
-- [GO_SUFFIX 2026-07-19] Waffen-GOs heissen nicht immer exakt "wp####": bei Ada (Separate
-- Ways) haengen Punisher MC / Rocket Launcher als "wp6112_AO" / "wp6111_AO" im Baum (verifiziert
-- mit re4_zzz_weaponhide_probe). Exakter Vergleich fand sie nie -> Waffe galt als nicht vorhanden.
-- Reihenfolge "" -> "_AO" -> "_MC" ist WICHTIG: wo es ein plain-GO gibt, ist "_AO" ein
-- Schatten-Proxy und darf NICHT gewinnen.
local function find_weapon(wid)
    local bt = body_tf(); if not bt then return nil, nil end
    local base = string.format("wp%04d", wid)
    for _, suffix in ipairs({ "", "_AO", "_MC" }) do
        local go, tf = search_tree(bt, base .. suffix, 5)
        if go then return go, tf end
    end
    return nil, nil
end

-- [TYPE_DEFS] Alle via/chainsaw-Typ-Handles in EINER Tabelle (statt je 1 Top-Level-Local) ->
-- spart Slots gegen das Lua-200-Local-Limit im Haupt-Chunk. Neue Typen hier ergaenzen, NICHT
-- als neues `local` anlegen.
local TD = {
    pe     = sdk.typeof("chainsaw.PlayerEquipment"),
    snd_sc = sdk.typeof("soundlib.SoundContainer"),
    mfsm2  = sdk.typeof("via.motion.MotionFsm2"),
    motion = sdk.typeof("via.motion.Motion"),
}

-- PlayerEquipment + equippte WeaponItem (fuer den echten Ammo-Reload)
local _pe_cache = nil
local function get_pe()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.pe() end
    if _pe_cache and safe(function() return _pe_cache:call("get_Context") end) then return _pe_cache end
    local ctx = get_ctx(); local head = ctx and sc(ctx, "get_HeadGameObject")
    _pe_cache = head and sc(head, "getComponent(System.Type)", TD.pe)
    return _pe_cache
end
local function get_weapon_item()
    -- [ACCESSOR 2026-08-12] zuerst die ECHTE, persistente Instanz (s. reload.lua,
    -- __re4_real_wi). Alles darunter sind KOPIEN -> Schreiben verpufft.
    local _rw = _G.__re4_real_wi and _G.__re4_real_wi()
    if _rw then return _rw end
    local pe = get_pe(); return pe and sc(pe, "getEquipWeaponItem")
end

-- LIVE equippte WeaponItem aus dem Inventory (wie der Holster) — NICHT die Kopie von getEquipWeaponItem
local function enum_value(o)
    if type(o) == "number" then return o end
    local v = sf(o, "value__"); return type(v) == "number" and v or nil
end
-- [LOG-FLUT 2026-08-01] Identisch zu reload.lua (und zu holster.lua seit 2026-07-20):
-- `sc(g,"ToString")` auf einer System.Guid schlaegt fehl und REFramework schreibt JEDE Warnung
-- SYNCHRON in re2_framework_log.txt. In der Schleife ueber die Inventar-Zeilen sind das Dutzende
-- Plattenzugriffe in einer Millisekunde -- im Log direkt vor dem Absturz vom 01:24:50 zu sehen.
-- Statt Invoke: die Guid ueber ihre Rohfelder vergleichbar machen (reine Feldlesungen, kein Log).
local function guid_to_string(g)
    if g == nil then return nil end
    if type(g) == "string" then return g end
    local sets = _G.__re4_guid_sets or { {"mData1","mData2","mData3","mData4"}, {"_a","_b","_c","_d"} }
    _G.__re4_guid_sets = sets
    local pick = _G.__re4_guid_fields
    if pick == nil then
        for _, f in ipairs(sets) do
            if safe(function() return g:get_field(f[1]) end) ~= nil then pick = f; break end
        end
        _G.__re4_guid_fields = pick or false
    end
    if pick and pick ~= false then
        local out = {}
        for i = 1, #pick do out[i] = tostring(safe(function() return g:get_field(pick[i]) end)) end
        return table.concat(out, "-")
    end
    return nil
end
local equip_type_main_cache = nil
local function get_equip_type_main()
    if equip_type_main_cache ~= nil then return equip_type_main_cache end
    local td = sdk.find_type_definition("chainsaw.EquipType")
    local f = td and td:get_field("Main")
    if f then equip_type_main_cache = f:get_data(nil) end
    return equip_type_main_cache
end
-- Inventory-Row-Item (autoritativ, mit Reserve-Anbindung) — KEIN Cache.
-- Guid-Match bevorzugt, sonst WeaponId-Match.
local function get_inv_row_weapon_item()
    local pe = get_pe(); if not pe then return nil end
    local inv = sc(pe, "get_InventoryController"); if not inv then return nil end
    local list = sc(inv, "getInventoryItemList"); if not list then return nil end
    local cnt = sc(list, "get_Count") or 0
    local et = get_equip_type_main()
    local want = et and guid_to_string(sc(inv, "getEquippedID", et))
    want = want and string.lower(want)
    local wid = get_equip_wid()
    local by_wid = nil
    for i = 0, cnt - 1 do
        local row = sc(list, "get_Item", i)
        if row then
            local rid = guid_to_string(sc(row, "get_ID"))
            if want and rid and string.lower(rid) == want then return row end
            if wid and enum_value(sc(row, "get_WeaponId")) == wid then by_wid = by_wid or row end
        end
    end
    return by_wid
end

local function get_live_weapon_item()
    local ewid = get_equip_wid()
    -- =========================================================================================
    -- 0) [ACCESSOR 2026-08-12] DIE EINZIGE PERSISTENTE INSTANZ. Wortgleich zu re4_vr_reload.lua
    -- (beide Dateien bleiben gleich). Live gemessen (#wi_write_probe, Laeufe 3+4):
    -- `getEquipWeaponItem` / `getEquippedWeapon` / die Zeilen aus `getInventoryItemList` liefern
    -- pro Aufruf eine FRISCHE KOPIE (Adresse springt jeden Tick, @pe als Kontrolle steht still) --
    -- Schreiben wirkt im selben Tick und ist danach weg. Nur `pe:getEquipWeaponAccessor()`
    -- (chainsaw.CsInventoryItem, stabile Adresse) haelt in `<Item>k__BackingField` das ECHTE
    -- chainsaw.WeaponItem: dort wirkt `setAmmoCount` sofort, das HUD folgt im selben Tick.
    -- Macht den crashenden nativen reload UEBERFLUESSIG statt ihn abzusichern.
    -- RUECKBAU:  _G.__re4_use_accessor_item = false   |  Zaehler: __re4_acc_hit / __re4_acc_miss
    -- Details: [[reference_re4_echte_weaponitem_instanz]]
    -- =========================================================================================
    if rawget(_G, "__re4_use_accessor_item") ~= false then
        local pe_a = get_pe()
        local acc  = pe_a and safe(function() return pe_a:call("getEquipWeaponAccessor") end)
        local real = acc and safe(function() return acc:call("get_Item") end)
        if real and safe(function() return real:call("get_CurrentAmmoCount") end) ~= nil then
            -- Beim Waffenwechsel kann der Accessor kurz noch die ALTE Waffe halten.
            local rwid = safe(function() return real:call("get_WeaponId"):get_field("value__") end)
            if ewid == nil or rwid == nil or rwid == ewid then
                _G.__re4_acc_hit = (tonumber(rawget(_G, "__re4_acc_hit")) or 0) + 1
                return real
            end
        end
        _G.__re4_acc_miss = (tonumber(rawget(_G, "__re4_acc_miss")) or 0) + 1
    end
    -- 1) Gecachtes Gun-Item (Schuss/Reload schreiben darauf) NUR nutzen wenn es (a) noch VALID ist
    -- (get_IsValid -> tote Instanz nach Waffenwechsel/Save-Load ausschliessen) UND (b) EINDEUTIG die
    -- AKTUELL equippte Waffe traegt (cwid == ewid, beide gueltig). Frueher gab `not cwid`/`not ewid` das
    -- stale Item zurueck (totes Item -> cwid=nil -> falsche Waffe: cap/Ammo-ID der ALTEN Waffe -> Reload
    -- rechnet Mist). [[Notiz]]
    local cached = rawget(_G, "__re4_live_wi")
    if cached
       and safe(function() return cached:call("get_IsValid") end) == true
       and safe(function() return cached:call("get_CurrentAmmoCount") end) ~= nil then
        local cwid = safe(function() return cached:call("get_WeaponId"):get_field("value__") end)
        if ewid and cwid and cwid == ewid then return cached end
    end
    -- 2) Das ECHTE equippte Item (getEquipWeaponItem) — immer die aktuelle Waffe, korrekte cap/Ammo-ID.
    local pe0 = get_pe()
    local eqwi = pe0 and safe(function() return pe0:call("getEquipWeaponItem") end)
    if eqwi and safe(function() return eqwi:call("get_CurrentAmmoCount") end) ~= nil then return eqwi end
    -- 3) Fallback: Inventory-Row (Guid bevorzugt, sonst WeaponId)
    return get_inv_row_weapon_item()
end

-- Das ECHTE Gun-WeaponItem cachen: reduceAmmoCount (Schuss) + addAmmoCount (Reload)
-- laufen beide auf dem Live-Item -> wir merken es uns in _G.__re4_live_wi.
if not _G.__re4_ammo_hooks then
    _G.__re4_ammo_hooks = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.WeaponItem")
        local function cache(args)
            local wi = safe(function() return sdk.to_managed_object(args[2]) end)
            if wi then _G.__re4_live_wi = wi end
        end
        for _, name in ipairs({ "reduceAmmoCount", "addAmmoCount" }) do
            local m = td and td:get_method(name)
            if m then sdk.hook(m, function(args) cache(args) end, function(r) return r end) end
        end
        -- RE-ACQUIRE OHNE SCHUSS: die HUD liest get_CurrentAmmoCount jeden Frame auf dem
        -- ECHTEN Laufzeit-Item. Nur cachen wenn der Cache leer ist (nach Reset/Waffenwechsel)
        -- UND die WeaponId der equippten Waffe entspricht -> billig (early-return wenn gecacht),
        -- kein "erst schiessen" mehr noetig. (sdk.hook -> braucht GAME-NEUSTART, nicht nur Reset.)
        local gca = td and td:get_method("get_CurrentAmmoCount")
        if gca then
            sdk.hook(gca, function(args)
                if rawget(_G, "__re4_live_wi") ~= nil then return end
                local wi = safe(function() return sdk.to_managed_object(args[2]) end)
                if not wi then return end
                local cwid = safe(function() return wi:call("get_WeaponId"):get_field("value__") end)
                local ewid = get_equip_wid()
                if cwid and ewid and cwid == ewid then _G.__re4_live_wi = wi end
            end, function(r) return r end)
        end
    end)
end

-- geladene Munition der Waffe setzen.
-- WICHTIG: forceSetAmmoCount/setAmmoCount sind nur der SAVE-Pfad (greifen zur Laufzeit NICHT,
-- darum heilt Save/Load). Der LAUFZEIT-Pfad (HUD) ist reduceAmmoCount (das nutzt auch das
-- Schiessen). Zum Leeren auf 0 ziehen wir die Munition per reduceAmmoCount auf 0 runter.
local function drain_to_zero(wi)
    if not wi then return false end
    local function cur() return sc(wi, "get_CurrentAmmoCount") or 0 end
    local function still() return cur() > 0 end
    if not still() then return true end
    -- ROHE SPEICHER-SCHREIBUNG: _CurrentAmmoCount @0x44 (Int32). Das ist das Feld, das
    -- get_CurrentAmmoCount + HUD lesen und das Feuern beschreibt. write_dword umgeht
    -- set_field/Methoden-Eigenheiten komplett.
    _G.__re4_carry_capture(wi, "re4_vr_reload4_dlc.lua:1122", nil)   -- [MAG-REST] merken, bevor genullt wird
    pcall(function() wi:write_dword(0x44, 0) end)
    -- (set_field("_CurrentAmmoCount") ENTFERNT: das Feld ist nur per Offset 0x44 schreibbar,
    -- nicht per Namen -> warf jedes Mal "Attempted to set invalid field" ins REFwk-Overlay.)
    -- Fallbacks (falls beides nicht greift): die Methoden der Reihe nach.
    if still() then pcall(function() wi:call("reduceAmmoCount", cur()) end) end
    if still() then pcall(function() wi:call("addAmmoCount", -cur(), false) end) end
    if still() then pcall(function() wi:call("forceSetAmmoCount", 0) end) end
    if still() then pcall(function() wi:call("setAmmoCount", 0) end) end
    return true
end
local function set_gun_loaded(n)
    local wi  = get_live_weapon_item()
    local row = get_inv_row_weapon_item()
    if n == 0 then
        -- Mag-Drop -> Munition LEEREN (Laufzeit, HUD geht auf 0)
        drain_to_zero(wi)
        if row and row ~= wi then drain_to_zero(row) end
        return true
    end
    -- andere Werte: Save-Pfad (selten genutzt)
    local ok = pcall(function() wi:call("forceSetAmmoCount", n) end)
    if not ok then ok = pcall(function() wi:call("setAmmoCount", n) end) end
    return ok
end

-- =====================================================================
-- Waffen-Cache (Mag-Joint)
-- =====================================================================
local wep = { wid = nil, tf = nil, mag_joint = nil, slide_joint = nil, slide_rest_lp = nil }
local _weapon_reacquired = false   -- [SAVE_LOAD] Flag: gleiche Waffe neu instanziiert
local function refresh_weapon()
    local wid = get_equip_wid()
    if not wid or wid == 0 then wep.wid, wep.tf, wep.mag_joint, wep.slide_joint, wep.slide_rest_lp = nil, nil, nil, nil, nil; return end
    -- [TOP_LOADER] Bei Chamber-Waffen reicht die Transform (kein Mag-Joint) -> Gate auf wep.tf.
    if wep.wid == wid and (wep.mag_joint or TOP_LOADER[wid]) and wep.tf and safe(function() return wep.tf:call("get_Position") end) then return end
    -- [HOOK-VERDACHT 2026-07-20] Nach dem Enterhaken wird die Waffe neu instanziiert und HIER neu
    -- aufgeloest. Bleibt dabei der Slide-Joint leer, laeuft die ganze Rack-Mechanik ins Leere -> kein
    -- rack.needs, kein Feuer-Block, man kann nach dem Nachladen ohne Rack ballern. Jede Neuaufloesung
    -- protokollieren (selten, kein Dauerfeuer): vorher/nachher, damit der Verlust sichtbar wird.
    -- [DROSSEL 2026-07-20] Diese Neuaufloesung laeuft bei Waffen OHNE Joint-Konfiguration (z.B. Adas
    -- Messer 6108) in JEDEM Frame erneut und hat das Log komplett zugemuellt. Nur noch loggen, wenn sich
    -- die Waffen-ID tatsaechlich aendert -- der Dauerlauf selbst bleibt sichtbar ueber einen Zaehler.
    do
        rack._refresh_n = (rack._refresh_n or 0) + 1
        if rack._refresh_last ~= wid then
            rack._refresh_n = 0
            rack._refresh_last = wid
        end
    end
    -- [SAVE_LOAD] Gleiche WeaponId, aber Re-Resolve noetig (alte tf ungueltig) = neue
    -- Instanz durch Save-Load/Respawn. Der Waffenwechsel-Reset greift hier NICHT (wid
    -- unveraendert) -> separat signalisieren, sonst bleibt stale Lua-State haengen.
    local same_wid = (wep.wid == wid)
    wep.wid, wep.tf, wep.mag_joint, wep.slide_joint, wep.slide_rest_lp = nil, nil, nil, nil, nil
    wep.slide_joint2 = nil   -- [EMPTY-RELOAD SLIDE] _08 (Riot Gun)
    wep.cycle_rest_rot = nil -- [ROTARY_CYCLE] Ruhe-Rotation des Drehschalters (Striker)
    local cfg = JOINTS[wid] or { mag = "", slide = "" }
    -- [TOP_LOADER] Red9 & Co: KEIN Mag/Slide noetig. Transform aufloesen, Joints optional.
    if TOP_LOADER[wid] then
        local go, tf = find_weapon(wid); if not tf then return end
        wep.wid, wep.tf = wid, tf
        wep.mag_joint   = (cfg.mag   and cfg.mag   ~= "") and sc(tf, "getJointByName", cfg.mag)   or nil
        wep.slide_joint = (cfg.slide and cfg.slide ~= "") and sc(tf, "getJointByName", cfg.slide) or nil
        if same_wid then _weapon_reacquired = true end
        return
    end
    if not (cfg.mag and cfg.mag ~= "") then return end
    local go, tf = find_weapon(wid); if not tf then return end
    local j = sc(tf, "getJointByName", cfg.mag); if not j then return end
    wep.wid, wep.tf, wep.mag_joint = wid, tf, j
    -- Slide-Joint (fuer Slide-Rack), gleicher Waffen-Transform
    wep.slide_joint = (cfg.slide and cfg.slide ~= "") and sc(tf, "getJointByName", cfg.slide) or nil
    -- [ROTARY/BREAK] Ruhe-Rotation des Dreh-/Klapp-Joints merken. BIND-Pose (get_BaseLocalRotation),
    -- NICHT live: nach Reset Scripts ist die Klappe evtl. noch offen (Engine-Zustand ueberlebt den
    -- Lua-Reset). Live wuerde dann die OFFENE Lage als "Ruhe" merken -> naechstes RIGHT-B legt den
    -- Oeffnungs-Delta obendrauf. Bind-Pose = stabile Zu-Ruhe (Klappe schnappt nach Reset zu, State
    -- wieder konsistent). Fallback auf live, falls die Methode fehlt.
    if (ROTARY_CYCLE[wid] or BREAK_ACTION[wid]) and wep.slide_joint then
        wep.cycle_rest_rot = sc(wep.slide_joint, "get_BaseLocalRotation") or sc(wep.slide_joint, "get_LocalRotation")
        -- [BREAK_ACTION] Klappe beim Erwerb einmalig auf die Zu-Ruhe setzen -> nach Reset Scripts (Engine
        -- haelt _02 evtl. noch offen) schnappt sie sofort zu, passend zum frischen break_st (open=false).
        -- Kein Snap/Delta beim ersten RIGHT-B. Nur Break-Action (Striker unangetastet).
        if BREAK_ACTION[wid] and wep.cycle_rest_rot then
            pcall(function() wep.slide_joint:call("set_LocalRotation", wep.cycle_rest_rot) end)
        end
    end
    -- [EMPTY-RELOAD SLIDE] separater Lade-Slide-Joint (_08) fuer den Empty-Reload-Chamber (Riot Gun)
    local erj = EMPTY_RELOAD_JOINT[wid]
    wep.slide_joint2 = (erj and erj ~= "") and sc(tf, "getJointByName", erj) or nil
    if same_wid then _weapon_reacquired = true end
end

-- [EMPTY-RELOAD SLIDE] aktiver Rack-Joint + Pose: im Empty-Reload-Modus der Lade-Slide (_08) mit
-- eigener Travel-Pose, sonst der normale Slide/Pump (_01). Eine Stelle -> alle Rack-Funktionen folgen.
local function rack_joint()
    if rack.empty_reload and wep.slide_joint2 then return wep.slide_joint2 end
    return wep.slide_joint
end
local function rack_slide_pose()
    if rack.empty_reload then return slide_pose2(wep.wid or 0) end
    return slide_pose(wep.wid or 0)
end

-- =====================================================================
-- [SND] Waffen-Sounds: Trigger-IDs auf dem SoundContainer der equippten Waffe.
-- PER-WAFFE (jede Pistole hat eigene Trigger-IDs in ihrem SoundContainer).
-- IDs holen mit #re4_sound_player.lua -> Treenode "Equipped Weapon (live)" -> id=-Spalte.
-- Fehlende ID = nil -> play_weapon_sound returnt still (kein falscher Sound).
-- =====================================================================
local SND_BY_WID = {
    -- [DLC] Sound-IDs 1:1 von der Basiswaffe. Falls im DLC etwas stumm/falsch klingt: die echten
    -- IDs mit #re4_sound_player.lua ("Equipped Weapon (live)") ziehen und hier eintragen.
    [6112] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=1757452382, mag_floor=3140689763, slide_back=943565871, mag_holster=1839787494 },   -- Punisher MC <- Punisher (4001)
    [6103] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=1757452382, mag_floor=3140689763, slide_back=943565871, mag_holster=1839787494 },   -- Blacktail AC <- Blacktail (4003, = Punisher-IDs)
    [6104] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=1757452382, mag_floor=3140689763, slide_back=943565871, mag_holster=1839787494 },   -- MP-AF <- TMP (4200)
    [6100] = { dry_fire=812850326, mag_eject=1466005368, mag_insert=942865223, mag_floor=1351699582, slide_back=741230436, mag_holster=1839787494 },   -- Sawed-off <- W-870 (4100)
}
-- aktuelle Waffen-Sounds (nach equippter wid). nil-tolerant.
local function snd(key)
    local t = wep.wid and SND_BY_WID[wep.wid]
    return t and t[key] or nil
end
-- 1:1 wie der Sound-Player (#re4_sound_player.lua): simple trigger(uint32) ist
-- hoerbar fuer alle Matilda-IDs. (Full-Sig gelang lautlos -> stumm, verworfen.)
local _sg_our_sound = false   -- [SG PUMP DIAG temp] true waehrend unserer eigenen Trigger-Calls
local function play_weapon_sound(id)
    if not CFG.sound_enabled or not id or id <= 0 then return end
    local tf = wep.tf; if not tf then return end
    local go = safe(function() return tf:call("get_GameObject") end)
    if not go or not TD.snd_sc then return end
    local scn = safe(function() return go:call("getComponent(System.Type)", TD.snd_sc) end)
    if not scn then return end
    _sg_our_sound = true
    pcall(function() scn:call("trigger(System.UInt32)", id) end)
    _sg_our_sound = false
end

-- [SG PUMP MUTE] Die Shotgun-Engine spielt nach JEDEM Schuss automatisch den Pump-Cock-Sound,
-- obwohl wir die Pump-Bewegung (_01) unterdruecken -> klingt falsch. Diese Engine-Auto-Pump-ID
-- pro Waffe am SoundContainer-Trigger blocken. NUR die Engine-Variante (ours=false): unser eigener
-- manueller Pump-Sound (play_weapon_sound -> ours=true) bleibt durch, falls wir die ID dort nutzen.
-- sdk.hook -> braucht GAME-NEUSTART. Guard ueberlebt Reset Scripts.
local AUTO_PUMP_MUTE = { [6100] = 1964290782 }   -- [DLC] Sawed-off: W-870-Auto-Pump-ID als Start
if not _G.__sg_pump_mute_dlc4_v4 then
    _G.__sg_pump_mute_dlc4_v4 = true
    -- [log entfernt]
    -- soundlib.SoundManager.postRequestInfo(RequestInfo) = globaler Sound-Funnel: ALLE Sounds laufen
    -- hier durch (auch Motion-SE, die am Weapon-SoundContainer vorbeigehen -> deshalb sah der
    -- Container-Hook den Pump nie). RequestInfo erbt von SoundTriggerInfo -> _TriggerId@0x10, _EventId@0x14.
    local td = sdk.find_type_definition("soundlib.SoundManager")
    local m  = td and td:get_method("postRequestInfo(soundlib.SoundManager.RequestInfo)")
    if m then
        sdk.hook(m,
            function(args)
                if not is_shotgun(wep.wid) then return end
                local tid, eid
                pcall(function()
                    local info = sdk.to_managed_object(args[3])
                    if info then tid = info:read_dword(0x10); eid = info:read_dword(0x14) end
                end)
                -- [log entfernt]
                local mute_id = AUTO_PUMP_MUTE[wep.wid]
                if mute_id and (not _sg_our_sound) and (tid == mute_id or eid == mute_id) then
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end,
            function(r) return r end)
    end
end

-- [LET-GO] true nur wenn handled~=nil (in on_frame gesetzt). Gate fuer Render-Paesse +
-- Holster-Grab: Toggle aus -> wir schreiben/greifen NICHTS, alles nativ.
local _managed = false

-- ist die aktuell equippte Waffe von uns verwaltet (Master + Gattung + Joints)?
local function handled()
    -- KEIN Master mehr -> jede Gattung haengt allein an ihrem eigenen Toggle (category_enabled).
    local wid = get_equip_wid(); if not wid then return nil end
    local cat = category_of(wid); if not category_enabled(cat) then return nil end
    if TOP_LOADER[wid] then return wid end   -- [TOP_LOADER] Chamber-Modell, kein Mag-Joint noetig
    local jc = JOINTS[wid]; if not (jc and jc.mag and jc.mag ~= "") then return nil end
    return wid
end

-- =====================================================================
-- Mag-Drop (RE9-Mathe, Welt-Raum)
-- =====================================================================
local drop = { active = false, use_module = false, joint = nil, sx = 0, sy = 0, sz = 0, t0 = 0 }
local mag_hand = { active = false, joint = nil }   -- Mag in der linken Hand (nach Mag-Holster-Grab)
local mag_insert = { active = false, joint = nil, t0 = 0, dur = 0.18 }  -- Slide-in Hand->Kammer
-- "Mag drin?" wird ABGELEITET (kein getracktes Flag -> kann nicht desyncen/haengen):
-- drin = kein manueller Flow aktiv (kein Drop gehalten, nicht in Hand, kein Insert).
local function mag_is_present() return not (drop.active or mag_hand.active or mag_insert.active) end
local mag_tune = { active = false }   -- reiner Einstell-Modus (positionieren), getrennt vom Reload-Flow

-- [MAG_OUT] Anti-Doppeldrop: sobald das Mag ausgeworfen ist, kommt KEIN zweites mehr
-- (force_eject droppt sonst bei jedem B ein neues Mag aus der Kammer). Das Flag wird
-- frisch aus der Engine GEHEILT: sobald live_loaded_count > 0 (Mag wieder geladen),
-- faellt es automatisch auf false -> kann nicht haengen bleiben (das war der alte
-- Bug, der B nach Reset/Save-Load totmachte). Kein gecachter kritischer Gate-State.
local mag_out = false
local mag_out_store = {}   -- [MAG_OUT] per WeaponId gemerkter Draussen-Zustand (ueberlebt Waffenwechsel)
local mag_retained = 0     -- [MAG_RETAIN] geladene Patronen beim Drop gemerkt (UI zeigt 0, intern bleiben sie)

local function start_mag_drop()
    if not wep.mag_joint then return false end
    mag_hand.active = false   -- neuer Drop -> Mag nicht mehr in der Hand
    mag_insert.active = false -- evtl. laufenden Insert abbrechen
    mag_insert.settle = false   -- [INSERT-PUNCH] Nachfedern mit abbrechen
    mag_tune.active = false   -- Einstell-Modus weicht dem echten Reload
    -- [MAG_RETAIN] Geladenen Stand MERKEN, bevor die UI auf 0 geht. Die Patronen gehen
    -- NICHT verloren: beim Insert kommt der Stand zurueck (+ Reserve oben drauf bis Cap).
    -- UI zeigt 0, solange das Mag draussen ist (Anforderung).
    if CFG.reload_ammo then
        local pe0 = get_pe()
        local cur = pe0 and tonumber(sc(pe0, "getCurrentGunAmmo"))   -- echter HUD-Stand
        if not cur then
            local wi0 = get_live_weapon_item()
            cur = wi0 and (sc(wi0, "get_CurrentAmmoCount") or 0) or 0
        end
        mag_retained = cur or 0
        set_gun_loaded(0)   -- UI auf 0
        -- [ACCESSOR-FOLGE 2026-08-12] Die 0 oben ist UNSER Werk (HUD "Magazin raus") und wirkt seit
        -- dem Accessor-Umbau wirklich. Die Kammer-Pruefung beim Einsetzen darf sie nicht als
        -- "Kammer leer" werten -- sonst racken alle Magazinwaffen nach JEDEM Reload.
        rack._zeroed_by_us = true
    end
    -- bevorzugt das Advanced-Modul (Slide-aus-der-Kammer + Fall)
    local ms = _G.__re4_reload_mag_slide
    if ms then
        ms.current_mag_joint = wep.mag_joint
        local bd_ok = ms.begin_drop(wep.mag_joint, wep.wid, CFG.insert_dur)   -- Slide-Out = Insert-Speed
        if bd_ok then
            drop.active, drop.use_module, drop.joint = true, true, wep.mag_joint
            rlog(string.format("mag-drop START (slide) wp%s", tostring(wep.wid)))
            return true
        end
    end
    -- Fallback: einfacher Gravity-Drop im Welt-Raum
    local p = sc(wep.mag_joint, "get_Position")
    if not p then return false end
    drop.joint, drop.use_module = wep.mag_joint, false
    drop.sx, drop.sy, drop.sz = p.x, p.y, p.z
    -- [ENTKOPPEL_ROT] Weltrotation beim Drop-Start einfrieren -> Mag folgt am Boden NICHT der
    -- Waffenrotation (wie der Modul-Pfad in reload_adv). Feste Weltpose bis stop_mag_drop.
    do local r = sc(wep.mag_joint, "get_Rotation")
       if r then drop.srw, drop.srx, drop.sry, drop.srz = r.w, r.x, r.y, r.z else drop.srw = nil end end
    drop.t0 = os.clock()
    drop.active = true
    rlog(string.format("mag-drop START (fall) wp%s @(%.3f,%.3f,%.3f)", tostring(wep.wid), p.x, p.y, p.z))
    return true
end
local function stop_mag_drop()
    if drop.use_module then local ms = _G.__re4_reload_mag_slide; if ms then ms.cancel() end end
    drop.active, drop.use_module, drop.joint = false, false, nil
end
local DROP_FALL_DUR = 1.0   -- [DROP-AUTOCLEAR] Sek bis der kosmetische Fall ausgelaufen ist
local function update_mag_drop()
    if not drop.active then return end
    if drop.use_module then
        local ms = _G.__re4_reload_mag_slide
        if ms then ms.tick() end
        return
    end
    if not drop.joint then return end
    local t = os.clock() - drop.t0
    -- [DROP-AUTOCLEAR] Der freie Fall ist rein kosmetisch. Nach DROP_FALL_DUR die Drop-Phase BEENDEN,
    -- sonst haengt drop.active=true -> flow_active=true -> Feuer FUER IMMER gesperrt (Soft-Lock; bei der
    -- Shotgun mit noch geladenem Ammo = "habe Munition, kann nicht schiessen"). Darf nie passieren.
    if t > DROP_FALL_DUR then
        -- Shotgun: die losgelassene Shell ist nur Deko (Ammo unveraendert) -> _04 zurueck in die Ruhepose,
        -- damit die gechamberte Shell wieder sichtbar ist. Pistole: Mag ist echt ausgeworfen (mag_out
        -- blockt weiter) -> liegen lassen.
        if is_shotgun(wep.wid) and wep.mag_joint and wep.rest_lp then
            pcall(function() wep.mag_joint:call("set_LocalPosition", Vector3f.new(wep.rest_lp.x, wep.rest_lp.y, wep.rest_lp.z)) end)
            if wep.rest_lr then
                pcall(function() wep.mag_joint:call("set_LocalRotation",
                    Quaternion.new(wep.rest_lr.w, wep.rest_lr.x, wep.rest_lr.y, wep.rest_lr.z)) end)
            end
        end
        drop.active, drop.joint = false, nil
        return
    end
    local fall = 0.5 * CFG.gravity * t * t              -- s = 1/2 g t^2 (freier Fall)
    pcall(function() drop.joint:call("set_Position", Vector3f.new(drop.sx, drop.sy - fall, drop.sz)) end)
    -- [ENTKOPPEL_ROT] Weltrotation jeden Frame festhalten -> Mag bleibt starr, folgt nicht der Waffe.
    if drop.srw then pcall(function() drop.joint:call("set_Rotation", Quaternion.new(drop.srw, drop.srx, drop.sry, drop.srz)) end) end
end

-- ---- Mag in der LINKEN Hand halten (nach Mag-Holster-Grab) ----
local lhand_joint = nil
local function get_left_hand()
    local bt = body_tf(); if not bt then return nil end
    local valid = lhand_joint and safe(function() return lhand_joint:get_Valid() end)
    if not valid then lhand_joint = sc(bt, "getJointByName", "L_Hand") or sc(bt, "getJointByName", "L_Arm_Hand") end
    return lhand_joint
end
local thumb_joint = nil
local function get_thumb_joint()
    local bt = body_tf(); if not bt then return nil end
    local valid = thumb_joint and safe(function() return thumb_joint:get_Valid() end)
    if not valid then thumb_joint = sc(bt, "getJointByName", "L_Thumb1") end
    return thumb_joint
end


local function update_mag_in_hand()
    -- [FIX 2026-07-19] ZUSTAENDIGKEITS-GATE. Diese Funktion lief bei JEDER Waffe und hat
    -- __vr_mag_hand_pose auf nil gesetzt, sobald hier kein Mag in der Hand war -- also auch, wenn
    -- LEON eine seiner Waffen haelt. Da dieses File alphabetisch NACH re4_vr_reload.lua laedt,
    -- laufen seine Apply-Passes SPAETER: Leons Script setzte die Pose, wir haben sie im selben
    -- Frame wieder genullt -> Leons Mag-in-Hand-Posen waren tot.
    -- Die Pose-Globals gehoeren dem Script, das die Waffe verwaltet. Ist das nicht dieses hier,
    -- fassen wir sie NICHT an. Das Aufraeumen beim Loslassen macht __re4_r4dlc_release an der
    -- Flanke (und nur dann, wenn wir sie wirklich gehalten haben).
    if not _managed then return end
    -- aktiv durch echten Reload-Grab ODER reinen Einstell-Modus
    local joint = (mag_hand.active and mag_hand.joint) or (mag_tune.active and wep.mag_joint) or nil
    if not joint then
        -- Mag nicht (mehr) in der Hand -> Hand-Pose dem Spiel zurueckgeben
        _G.__vr_mag_hand_pose = nil
        _G.__vr_mag_hand_trx, _G.__vr_mag_hand_try, _G.__vr_mag_hand_trz = nil, nil, nil
        return
    end
    local wid_for = (mag_hand.active and mag_hand.wid) or wep.wid or 0
    local m = maghand(wid_for)
    -- Greif-Pose (Finger) + Daumen-Spreizung NICHT hier direkt anwenden (Pre-Anim -> Engine
    -- ueberschreibt). Stattdessen Pose-NAME + Daumen-Offset publizieren; motion.lua wendet
    -- es im POST-ANIM-Pass an (eigener Global, voellig getrennt von der Rack-Slide-Pose).
    -- leere mag_hold_pose = KEINE Pose erzwungen (Finger frei -> zum Aufnehmen einer neuen Pose).
    -- [POSE PER WAFFE] eigene Pose dieser Waffe bevorzugen, sonst globale (Pistolen unveraendert).
    local _mp = (wep.wid and MAG_POSE[wep.wid]) or CFG.mag_hold_pose
    _G.__vr_mag_hand_pose = (_mp and _mp ~= "" and _mp) or nil
    _G.__vr_mag_hand_trx, _G.__vr_mag_hand_try, _G.__vr_mag_hand_trz = m.t_rx, m.t_ry, m.t_rz
    -- [SHELL_CLONE] Skull Shaker (6001): den Mag-Joint (_04, Part 1 ist daran geskinnt) NICHT in die
    -- Hand ziehen -> sonst haengt Part 1 doppelt zum Mesh-Clone in der Hand. Finger-Pose (oben schon
    -- publiziert) bleibt; die sichtbare Shell ist der Clone. _04 bleibt in Ruhe (Engine-kontrolliert).
    if wep.wid == 6001 then return end
    local lh = get_left_hand(); if not lh then return end
    local hp = sc(lh, "get_Position"); if not hp then return end
    local hr = sc(lh, "get_Rotation")
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

-- Chamber-Ruhepose (lokal) des Mag-Joints erfassen, solange unmanipuliert
local function capture_mag_rest()
    if not wep.mag_joint then return end
    if drop.active or mag_hand.active or mag_insert.active then return end
    -- [RUHELAGE HAERTEN 2026-08-17] Wie in re4_vr_reload.lua: diese live gemessene Nulllage ist der
    -- Endpunkt der Einschubachse -- faengt sie einen Engine-/Eigen-Zustand ein, zeigt die Achse falsch
    -- und der Handschub kommt nicht vom Andockpunkt weg. Zwei Luecken zu: die Nachfeder-Phase schreibt
    -- die Mag-Position selbst und laeuft NACH `active`; in Nicht-Gameplay-Frames (Killswitch/Cutscene/
    -- Menue) posiert die Engine Waffe und Mag. Nur bei ausdruecklichem `false` blocken -- ist das Binding
    -- nicht aktiv (Global nil), wird wie bisher gemessen (ohne Ruhelage gaebe es keinen Insert).
    if mag_insert.settle then return end
    if rawget(_G, "__re4_frame_is_gameplay") == false then return end
    if shell_eject.preview or shell_eject.flying then return end   -- [SHELL_EJECT] _04 verschoben -> NICHT als Ruhepose erfassen (Drift)
    if mag_out then return end   -- [MAG_OUT] Mag-Mesh ist versteckt -> NICHT als Ruhepose erfassen
    local lp = sc(wep.mag_joint, "get_LocalPosition")
    local lr = sc(wep.mag_joint, "get_LocalRotation")
    if lp then wep.rest_lp = { x = lp.x, y = lp.y, z = lp.z } end
    if lr then wep.rest_lr = { w = lr.w, x = lr.x, y = lr.y, z = lr.z } end
    -- (Slide-Ruhepose wird NICHT mehr erfasst -> Slide-Z ist hartcodiert absolut, s. SLIDE_POSE)
    -- [SHOTGUN CHAMBER] Chamber-Port (waffen-lokaler Offset) jetzt erfassen, solange _04 in Ruhe ist:
    -- echte _04-Weltpos + (-0.093 in _04-lokalem Z) = Port-Welt; dann relativ zur Waffen-Transform
    -- speichern -> shotgun_chamber_world rechnet ihn spaeter mit der Live-Waffen-Transform zurueck.
    local zoff = is_shotgun(wep.wid) and SHOTGUN_CHAMBER_Z[wep.wid]
    if zoff and wep.tf then
        local jw = sc(wep.mag_joint, "get_Position")
        local jr = sc(wep.mag_joint, "get_Rotation")
        local gp = sc(wep.tf, "get_Position")
        local gr = sc(wep.tf, "get_Rotation")
        if jw and jr and gp and gr then
            local cw  = safe(function() return jw + jr * Vector3f.new(0, 0, zoff) end)            -- Port-Welt
            local rel = cw and safe(function() return gr:conjugate() * (cw - gp) end)             -- waffen-lokal
            if rel then wep.chamber_off = { x = rel.x, y = rel.y, z = rel.z } end
        end
    end
end

-- Slide-in: Mag von der aktuellen (Hand-)Lokalpose in die Chamber-Ruhepose
local function start_mag_insert()
    if not (wep.mag_joint and wep.rest_lp) then return false end
    local lp = sc(wep.mag_joint, "get_LocalPosition"); if not lp then return false end
    local lr = sc(wep.mag_joint, "get_LocalRotation")
    mag_insert.joint = wep.mag_joint
    mag_insert.slp = { x = lp.x, y = lp.y, z = lp.z }
    mag_insert.slr = lr and { w = lr.w, x = lr.x, y = lr.y, z = lr.z } or nil
    mag_insert.rlp = wep.rest_lp
    mag_insert.rlr = wep.rest_lr
    -- [SHOTGUN] Insert-ZIEL = Chamber-Port (rest + -0.093 Z), nicht die vordere _04-Ruhe -> die Shell
    -- gleitet IN den Ladeport statt nach vorne zu fliegen.
    local zoff = SHOTGUN_CHAMBER_Z[wep.wid]
    if zoff then mag_insert.rlp = { x = wep.rest_lp.x, y = wep.rest_lp.y, z = wep.rest_lp.z + zoff } end
    -- [SHELL-KEYFRAMES 2026-07-24] Nutzt diese Waffe (6100 Sawed-off W-870) die Keyframe-Bahn
    -- (reload_adv, KEYFRAME_INSERT)? Dann faehrt update_mag_insert die geordnete Bahn ab und der lineare
    -- Slide + Overshoot unten gelten NICHT mehr -- die Shell klebt an der Waffe, Start = 1. Keyframe.
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        mag_insert.keyframe = (ms and type(ms.has_shell_keys) == "function" and ms.has_shell_keys(wep.wid)) == true
    end
    mag_insert.t0  = os.clock()
    mag_insert.dur = CFG.insert_dur
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if mag_insert.keyframe and ms and tonumber(ms.shell_dur) then
            -- [INSERT = EJECT RUECKWAERTS 2026-07-25] 1:1 wie in re4_vr_reload.lua: Waffen mit
            -- rueckwaerts gefahrener Auswurf-Bahn haben ihre EIGENE Einschub-Dauer. Ohne das zogen Adas
            -- Waffen weiter shell_dur (die gemeinsame Schrotflinten-Shell-Dauer) und ihre Mags gingen
            -- sichtbar langsamer rein als Leons.
            mag_insert.dur = ((type(ms.kf_insert_dur) == "function") and tonumber(ms.kf_insert_dur(wep.wid)))
                or tonumber(ms.shell_dur)   -- [SHELL-KEYFRAMES] eigene Bahn-Dauer
        end
    end
    mag_insert.active = true
    mag_insert.snd_played = false   -- [SND] Einrast-Sound einmal pro Insert
    -- [MANUAL_INSERT 2026-08-15] Handschub scharf machen -- 1:1 wie in re4_vr_reload.lua: Nullpunkt ist
    -- der Handabstand im Moment des Andockens, alles weitere misst sich dagegen. Quelle fuer "welche
    -- Waffe" ist M.PUSH_WIDS aus reload_adv (die mit Druecken-Geste); die Geste ist zwingend, weil sie
    -- die Hand am Magazin haelt. `__re4_insert_manual_wid[wid] = false` nimmt eine Waffe wieder raus.
    -- Liefert die Messung nichts (Controller-Globals fehlen), bleibt es still bei der Zeitbahn.
    mag_insert.manual = false
    mag_insert.prog = 0.0
    -- [NOTBREMSE 2026-08-17] Startwerte fuer den Handschub-Watchdog (1:1 aus re4_vr_reload.lua,
    -- Begruendung dort in update_mag_insert). Bei JEDEM Andocken frisch.
    mag_insert.wd_t0  = os.clock()
    mag_insert.wd_max = 0.0
    do
        -- [WELTWEG WAR DER FEHLER 2026-08-18 -- 1:1 wie in re4_vr_reload.lua] Der Watchdog verglich
        -- die WELTPOSITION der linken Hand (`__vr_lh_ctrl_raw`, durch `controller_to_world` gelaufen)
        -- zwischen Andocken und jetzt. Beim Laufen wandert die mit dem Spieler: im Leon-Log standen
        -- so 12 METER "Handweg" waehrend eines Einschubs -> die 6-cm-Schwelle war sofort erreicht,
        -- die Notbremse schaltete `manual` ab und startete die Zeitbahn. Ergebnis: das Magazin fuhr
        -- von allein hinein, waehrend der Controller ganz woanders war.
        -- Jetzt dieselbe Groesse wie in der Kopplung: linke Hand GEGEN rechte Hand -- Fortbewegung
        -- faellt heraus, der Watchdog zuendet nur noch bei echtem Schub ohne Fortschritt.
        local _l0 = rawget(_G, "__vr_lh_ctrl_raw")
        local _r0 = rawget(_G, "__vr_rh_ctrl_raw")
        if _l0 and _r0 then
            mag_insert.wd_lp0 = { x = _l0.x - _r0.x, y = _l0.y - _r0.y, z = _l0.z - _r0.z }
        else
            mag_insert.wd_lp0 = nil
        end
    end
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        local ex = rawget(_G, "__re4_insert_manual_wid")
        local ok_wid = (ms and type(ms.PUSH_WIDS) == "table" and ms.PUSH_WIDS[wep.wid] == true)
                       and (type(ex) ~= "table" or ex[wep.wid] ~= false)
        -- Nullpunkt = HANDABSTAND im Moment des Andockens (wie bei Leon). Zwei Alternativen wurden am
        -- 15.08. probiert und wieder ausgebaut, s. Notiz in re4_vr_reload.lua bei __re4_mag_push_dist.
        if CFG.insert_manual ~= false and ok_wid and type(rawget(_G, "__re4_mag_push_dist")) == "function" then
            mag_insert.d0 = _G.__re4_mag_push_dist()
            mag_insert.manual = (mag_insert.d0 ~= nil)
            mag_insert.p0 = nil   -- [1:1] Nullpunkt der Achsen-Kopplung neu setzen
            -- [WEGWERF-DIAG 2026-08-15] nach der Messung ersatzlos loeschen
            _G.__re4_dg_src, _G.__re4_dg_d0, _G.__re4_dg_start = "ada", mag_insert.d0, os.clock()
            _G.__re4_dg_travel = tonumber(CFG.insert_travel)
            _G.__re4_dg_dur    = tonumber(mag_insert.dur)
            _G.__re4_dg_manual = mag_insert.manual
        end
    end
    -- [INSERT-PUNCH] Ziel der Einschub-Phase liegt um insert_overshoot weiter in Einschubrichtung;
    -- danach federt es in insert_settle zurueck. Rein optisch.
    mag_insert.olp = nil
    mag_insert.settle = false
    do
        local ov = tonumber(CFG.insert_overshoot) or 0.0
        -- [MANUAL_INSERT] Kein Overshoot beim Handschub: dort IST die Hand die Position.
        if ov > 0.0 and not mag_insert.keyframe and not mag_insert.manual then   -- [SHELL-KEYFRAMES] Keyframe-Bahn hat keinen linearen Overshoot
            local a2, b2 = mag_insert.slp, mag_insert.rlp
            local dx, dy, dz = b2.x - a2.x, b2.y - a2.y, b2.z - a2.z
            local len = math.sqrt(dx*dx + dy*dy + dz*dz)
            if len > 1e-5 then
                mag_insert.olp = { x = b2.x + dx/len*ov, y = b2.y + dy/len*ov, z = b2.z + dz/len*ov }
            end
        end
    end
    -- [PUSH_POSE 2026-07-21] Wie bei Leon: Mag verlaesst die Hand -> universelle Nachdrueck-Pose
    -- aus reload_adv zuenden. Adas Reload ist eine eigene Kopie, deshalb steht der Aufruf hier nochmal.
    -- [MANUAL_INSERT] Im Handschub als HALTEN (begin_push_hold): die Pose bleibt stehen, solange
    -- geschoben wird -- damit klebt die Hand unten am Magazin und faehrt mit hoch. Aufgeloest wird
    -- sie beim Einrasten, beim Rueckzieher und als Sicherung im Frame-Tick.
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if mag_insert.manual and ms and type(ms.begin_push_hold) == "function" then
            pcall(ms.begin_push_hold, wep.wid)
        elseif ms and type(ms.start_push) == "function" then
            pcall(ms.start_push, wep.wid)
        end
    end
    rlog("mag-insert START")
    return true
end
local function update_mag_insert()
    -- [INSERT-PUNCH] Nachfedern aus dem Overshoot in die Ruhelage. Laeuft NACH dem Insert (der ist da
    -- inkl. Ammo/Rack schon abgeschlossen) und schreibt NUR die Position.
    if mag_insert.settle and mag_insert.joint then
        local st = (os.clock() - mag_insert.settle_t0) / math.max(tonumber(CFG.insert_settle) or 0.07, 0.01)
        if st >= 1.0 then st = 1.0; mag_insert.settle = false end
        local o, r2 = mag_insert.olp, mag_insert.rlp
        if o and r2 then
            local u2 = ease(st)
            pcall(function() mag_insert.joint:call("set_LocalPosition",
                Vector3f.new(o.x + (r2.x - o.x) * u2, o.y + (r2.y - o.y) * u2, o.z + (r2.z - o.z) * u2)) end)
        end
    end
    if not mag_insert.active or not mag_insert.joint then return end
    local t = (os.clock() - mag_insert.t0) / math.max(mag_insert.dur, 0.01)
    -- [MANUAL_INSERT 2026-08-15] Handschub: t kommt aus dem zurueckgelegten Handweg statt aus der Uhr.
    -- 0 = Andockpunkt, 1 = eingerastet; dazwischen beliebig vor und zurueck, weil die Bahn t jedes Mal
    -- frisch auswertet und sich nichts merkt.
    if mag_insert.manual then
        -- Fortschritt = Annaeherung der Haende seit dem Andocken.
        local d = _G.__re4_mag_push_dist()
        if d and mag_insert.d0 then
                        -- [1:1-KOPPLUNG 2026-08-15] Das Magazin klebt am CONTROLLER, statt einen
            -- Fortschritt aus einer Distanz-Differenz zu rechnen. Gemessen war der alte Weg
            -- (Hoehe des Controllers) nachweislich unbrauchbar: prog lief rueckwaerts,
            -- waehrend eingeschoben wurde, und brauchte fuer die letzten 10 %% eine ganze
            -- Sekunde -- weil die virtuelle Hand ab dem Andocken per IK am Magazin haengt und
            -- mit der Controller-Hoehe nichts mehr zu tun hat.
            -- Jetzt: die Controller-Position wird auf die ECHTE Einschubachse projiziert
            -- (Andockpunkt -> Ruhelage, mit der Waffe gedreht). Damit dreht die Messung mit
            -- der Waffe mit -> gekippt einschieben geht, und die Bewegung ist die der Hand.
            -- Der Nullpunkt `p0` faengt den Griff-Versatz ab (die Hand haelt das Mag ja mit
            -- Abstand), sodass 0 = Andockpunkt und 1 = eingerastet gilt.
            -- ZURUECK auf den alten Weg: `_G.__re4_mag_11 = false`.
            local _p11 = nil
            if rawget(_G, "__re4_mag_11") ~= false then
                local _ms = rawget(_G, "__re4_reload_mag_slide")
                local _lp = rawget(_G, "__vr_lh_ctrl_raw")
                local _b  = mag_insert.olp or mag_insert.rlp
                if _ms and type(_ms.dock_world) == "function" and wep.tf and _lp
                   and mag_insert.slp and _b then
                    -- [KEIN WELTANKER 2026-08-15] Gemessen wird NICHT mehr gegen `dock_world`
                    -- (ein Punkt an der Waffe): beim LAUFEN wandert der mit, und die
                    -- Fortbewegung zaehlt als Einschub -> das Magazin flackerte.
                    -- Das ist derselbe Fehler wie damals beim W-870-Pump; der Merksatz dazu:
                    -- Zuggesten IMMER zwei Koerperteile gegeneinander messen, nie gegen etwas,
                    -- das Spiel oder Script bewegen. Also LINKE gegen RECHTE Hand -- laeuft man,
                    -- wandern beide gemeinsam und es faellt heraus.
                    -- Anders als beim Pump aber RICHTUNGSBEHAFTET: nicht der Abstand (der ist
                    -- beim Magazin falsch herum -- man schiebt an der anderen Hand VORBEI nach
                    -- oben), sondern die Komponente entlang der Einschubachse. Damit dreht die
                    -- Messung mit der Waffe mit und gekipptes Einschieben funktioniert weiter.
                    -- ZWINGEND die ROHEN Controller-Positionen: die Handjoints haengen im
                    -- Einschub per IK am Magazin -> Rueckkopplung.
                    local _rp = rawget(_G, "__vr_rh_ctrl_raw")
                    local _A  = _rp and Vector3f.new(_rp.x, _rp.y, _rp.z) or nil
                    local _wr = sc(wep.tf, "get_Rotation")
                    if _A and _wr then
                        local _a = mag_insert.slp
                        local _ax = _wr * Vector3f.new(_b.x - _a.x, _b.y - _a.y, _b.z - _a.z)
                        local _L2 = _ax.x * _ax.x + _ax.y * _ax.y + _ax.z * _ax.z
                        if _L2 > 1e-8 then
                            _p11 = ((_lp.x - _A.x) * _ax.x + (_lp.y - _A.y) * _ax.y
                                  + (_lp.z - _A.z) * _ax.z) / _L2
                            if mag_insert.p0 == nil then
                                mag_insert.p0 = _p11
                                -- [WEGWERF-DIAG 2026-08-15] Achsen-Kenndaten EINMAL beim
                                -- Andocken veroeffentlichen -- nach der Messung loeschen.
                                _G.__re4_dg_axlen = math.sqrt(_L2)
                                _G.__re4_dg_alp   = string.format("%.4f/%.4f/%.4f", _a.x, _a.y, _a.z)
                                _G.__re4_dg_blp   = string.format("%.4f/%.4f/%.4f", _b.x, _b.y, _b.z)
                                _G.__re4_dg_p0    = _p11
                            end
                            _p11 = _p11 - mag_insert.p0
                        end
                    end
                end
            end
            if _p11 then
                mag_insert.prog = _p11
            else
            mag_insert.prog = (mag_insert.d0 - d) / math.max(tonumber(CFG.insert_travel) or 0.09, 0.01)
            end
            -- [WEGWERF-DIAG 2026-08-15]
            _G.__re4_dg_d, _G.__re4_dg_prog = d, mag_insert.prog
        end
        t = mag_insert.prog or 0.0
        -- Hinter den Andockpunkt zurueck -> das Mag liegt wieder in der linken Hand. Gebucht wird erst
        -- am Anschlag (t>=1), es geht also keine Reload-Logik verloren.
        if t <= -((tonumber(CFG.insert_back_out) or 0.02) / math.max(tonumber(CFG.insert_travel) or 0.09, 0.01)) then
            mag_insert.active = false
            mag_insert.settle = false
            mag_insert.manual = false
            do
                local ms = rawget(_G, "__re4_reload_mag_slide")
                if ms and type(ms.end_push_hold) == "function" then pcall(ms.end_push_hold) end
            end
            mag_hand.joint = mag_insert.joint
            mag_hand.wid   = wep.wid
            -- Sentinel: erst wieder andocken, wenn ein Stueck VORgeschoben wurde (sonst klebt es im
            -- naechsten Frame sofort wieder an -- die Hand steht ja noch in der Andock-Distanz).
            mag_hand.redock_d = true
            -- In der Hand bleibt es NUR bei gehaltenem Grip, sonst faellt es sofort (drop im Frame-Tick,
            -- weil drop_mag_simple weiter unten in der Datei steht -- Lua-Local-Reihenfolge).
            mag_hand.active    = (mag_hand.grip_held == true)
            mag_hand.want_drop = (not mag_hand.active) or nil
            rlog(mag_hand.active and "mag-insert ZURUECK in die Hand (Handschub)"
                or "mag-insert ZURUECK, aber kein Grip -> faellt")
            return
        end
        -- [NOTBREMSE 2026-08-17] 1:1 aus re4_vr_reload.lua (volle Begruendung dort): schiebt die Hand
        -- nachweislich (Maximalabstand > 6 cm seit dem Andocken), bleibt der Schub nach 1.5 s aber unter
        -- 5 Prozent, faellt DIESER EINE Insert auf die Zeitbahn zurueck. Haelt man die Hand still, zuendet
        -- sie nicht. `end_push_hold` hier selbst rufen -- der Abschluss unten macht das nur im
        -- manual-Zweig, den wir gerade abschalten. Diagnose: `_G.__re4_mag_wd_hits`.
        -- Adas Sonderfall (rastet bei ~50 Prozent ein) ist davon unberuehrt: dort ist prog gross, nicht klein.
        if not mag_insert.visual and mag_insert.wd_t0 and (os.clock() - mag_insert.wd_t0) > 1.5
           and (tonumber(mag_insert.prog) or 0) < 0.05 then
            -- Gegenstueck zum Andocken: ebenfalls linke GEGEN rechte Hand (s. wd_lp0).
            local _l0 = mag_insert.wd_lp0
            local _lr = rawget(_G, "__vr_lh_ctrl_raw")
            local _rr = rawget(_G, "__vr_rh_ctrl_raw")
            local _ln = (_lr and _rr) and { x = _lr.x - _rr.x, y = _lr.y - _rr.y, z = _lr.z - _rr.z } or nil
            if _l0 and _ln then
                local _dx, _dy, _dz = _ln.x - _l0.x, _ln.y - _l0.y, _ln.z - _l0.z
                local _md = math.sqrt(_dx*_dx + _dy*_dy + _dz*_dz)
                if _md > (tonumber(mag_insert.wd_max) or 0) then mag_insert.wd_max = _md end
            end
            if (tonumber(mag_insert.wd_max) or 0) > 0.06 then
                mag_insert.manual = false
                mag_insert.t0     = os.clock()   -- Zeitbahn beginnt JETZT (das Mag steht am Andockpunkt)
                mag_insert.wd_t0  = nil
                local ms = rawget(_G, "__re4_reload_mag_slide")
                if ms and type(ms.end_push_hold) == "function" then pcall(ms.end_push_hold) end
                _G.__re4_mag_wd_hits = (tonumber(rawget(_G, "__re4_mag_wd_hits")) or 0) + 1
                rlog(string.format("mag-insert NOTBREMSE (Ada): Handschub ohne Fortschritt (prog=%.3f, Handweg=%.3f m) -> Zeitbahn",
                    tonumber(mag_insert.prog) or 0, tonumber(mag_insert.wd_max) or 0))
                t = 0.0
            end
        end
        if t < 0.0 then t = 0.0 end
    end
    if t > 1.0 then t = 1.0 end
    -- [SND] Einrast-Sound kurz vor dem Anschlag, einmalig. Mit Punch spaeter (0.90), damit Klack und
    -- Aufschlag zusammenfallen; ohne Punch bleibt das alte Timing (0.75).
    -- [SND-TIMING 2026-07-21] Schwelle jetzt aus CFG.insert_snd_at (Default 0.80 statt hart 0.90).
    -- [MANUAL_INSERT] Im Handschub spielt hier NICHTS: jede Wegschwelle liegt vor dem Anschlag und
    -- laesst sich zurueckziehen. Der Klack kommt unten beim echten Einrasten (t >= 1).
    if not mag_insert.manual
       and not mag_insert.snd_played and t >= ((CFG.insert_punch ~= false) and (tonumber(CFG.insert_snd_at) or 0.80) or 0.75) then
        mag_insert.snd_played = true
        play_weapon_sound(snd("mag_insert"))
    end
    -- [SHELL-KEYFRAMES 2026-07-24] Waffen mit Keyframe-Bahn (6100): Shell-Joint entlang der
    -- geordneten Keyframes setzen -- der lineare Slide darunter gilt fuer sie NICHT mehr.
    if mag_insert.keyframe then
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if ms and type(ms.apply_shell_keys) == "function" and wep.tf then
            ms.apply_shell_keys(wep.tf, mag_insert.joint, wep.wid or 0, t)
        end
    else
    -- [INSERT-PUNCH] Ease-IN statt Smoothstep -> beschleunigt bis zum Anschlag.
    -- [MANUAL_INSERT] Im Handschub LINEAR: die Hand IST die Position. Jede Kurve wuerde bedeuten, dass
    -- das Mag anders laeuft als die Hand -- und beim Zurueckziehen faende man den Anschlag nicht wieder.
    local u = mag_insert.manual and t
        or ((CFG.insert_punch ~= false) and (t * t * t) or ease(t))
    local a, b = mag_insert.slp, (mag_insert.olp or mag_insert.rlp)
    pcall(function() mag_insert.joint:call("set_LocalPosition",
        Vector3f.new(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u)) end)
    if mag_insert.slr and mag_insert.rlr then
        local s, r = mag_insert.slr, mag_insert.rlr
        local rw, rx, ry, rz = r.w, r.x, r.y, r.z
        if (s.w*rw + s.x*rx + s.y*ry + s.z*rz) < 0 then rw, rx, ry, rz = -rw, -rx, -ry, -rz end
        local w, x, y, z = s.w+(rw-s.w)*u, s.x+(rx-s.x)*u, s.y+(ry-s.y)*u, s.z+(rz-s.z)*u
        local len = math.sqrt(w*w + x*x + y*y + z*z)
        if len > 1e-6 then pcall(function() mag_insert.joint:call("set_LocalRotation", Quaternion.new(w/len, x/len, y/len, z/len)) end) end
    end
    end   -- [SHELL-KEYFRAMES] Ende else-Zweig (linearer Slide)
    -- [SELBST-EINRASTEN] Im Handschub genuegt `insert_snap_at` des Weges; die Bahn oben hat
    -- das Magazin dann fast am Ziel, den Rest macht der Abschluss. Ausserhalb des Handschubs
    -- bleibt es bei 1.0, damit die Zeitbahn unveraendert laeuft.
    local _snap = 1.0
    if mag_insert.manual then
        _snap = tonumber(CFG.insert_snap_at) or 1.0
        if _snap < 0.5 then _snap = 0.5 elseif _snap > 1.0 then _snap = 1.0 end
    end
    if t >= _snap then
        mag_insert.active = false
        -- [MANUAL_INSERT] Der Einrast-Klack gehoert an DIESEN Moment -- hier ist das Magazin
        -- tatsaechlich eingerastet. Danach das Halten der Druecken-Pose aufloesen (normale
        -- Zurueck-Phase samt Links-Ausfade). Beides ganz vorn, damit es auch greift, wenn unten
        -- irgendein Zweig frueh aussteigt.
        if mag_insert.manual then
            if not mag_insert.snd_played then
                mag_insert.snd_played = true
                play_weapon_sound(snd("mag_insert"))
            end
            mag_insert.manual = false
            local ms = rawget(_G, "__re4_reload_mag_slide")
            if ms and type(ms.end_push_hold) == "function" then pcall(ms.end_push_hold) end
        end
        -- [INSERT-PUNCH] Anschlag: Nachfedern starten + kurzer harter Haptik-Puls (rechte Hand haelt die Waffe).
        if mag_insert.olp then
            mag_insert.settle = true
            mag_insert.settle_t0 = os.clock()
        end
        do
            local hamp = tonumber(CFG.insert_haptic) or 0.0
            if hamp > 0.0 then
                pcall(function()
                    local rj = vrmod and vrmod:get_right_joystick()
                    if rj then vrmod:trigger_haptic_vibration(0.0, 0.06, 90.0, hamp, rj) end
                end)
            end
        end
        rack._ammo_input_t = os.clock()   -- [RACK-LOCK] Ammo gerade eingelegt -> Shaft/Slide-Grab 2s sperren
        -- [MAG_OUT] PHYSISCH ein frisches Mag in der Kammer -> Anti-Doppeldrop-Flag loesen.
        -- An den INSERT gekoppelt, NICHT an loaded>0 (Ammo kann 0 bleiben: leeres Mag, keine
        -- Reserve, addAmmoCount-Problem) -> sonst bleibt mag_out haengen und B ist tot.
        mag_out = false
        -- Rack NUR noetig wenn die Waffe beim Drop LEER war (komplett auf 0 geschossen).
        -- Taktischer Reload (noch Patronen drin) -> KEIN Rack, Slide direkt vor (gechambert).
        -- [LEERE KAMMER 2026-07-23] `empty_when_dropped` wird beim Waffenwechsel mit geloescht
        -- (Regel "nach dem Wechsel immer schussbereit"). Wer leergeschossen hat, das Mag auswirft,
        -- wegwechselt und spaeter mit gefundener Munition zurueckkommt, bekam deshalb KEIN Rack --
        -- obwohl die Kammer leer ist. Der Ladestand unmittelbar vor dem Einsetzen (`_ld`) sagt das
        -- unabhaengig vom Wechsel. Bewusst NUR fuer Waffen mit echtem Slide-Rack: Shotguns laufen im
        -- Zweig darunter (Pump/Drehschalter/Klappe), Bolt-Action, Bogen und Armbrust haben hier keinen
        -- Eintrag. Ohne diese Einschraenkung koennte rack.needs eine Waffe dauerhaft feuersperren.
        -- Ladestand UNMITTELBAR vor dem Einsetzen -- selbe Quelle wie der EMPTY_RELOAD_JOINT-Block
        -- weiter unten (pe:getCurrentGunAmmo, kein Cache; Fallback Live-Item). Muss HIER schon
        -- feststehen, sonst ist die Variable an dieser Stelle nil und die Bedingung wirkungslos --
        -- genau das war der Fehler beim ersten Anlauf (Blacktail verlangte kein Rack).
        local _pe0 = get_pe()
        local _loaded0 = _pe0 and tonumber(safe(function() return _pe0:call("getCurrentGunAmmo") end))
        if _loaded0 == nil then
            local _wi0 = get_live_weapon_item()
            _loaded0 = _wi0 and tonumber(safe(function() return _wi0:call("get_CurrentAmmoCount") end)) or nil
        end
        -- [ACCESSOR-FOLGE 2026-08-12] `_empty_chamber` bleibt fuer den Waffenwechsel-Fall erhalten
        -- (dort ist `empty_when_dropped` geloescht, die Kammer aber echt leer), zaehlt aber NICHT,
        -- wenn die 0 von unserem eigenen Mag-Drop-Leeren stammt.
        local _empty_chamber = (_loaded0 == 0) and (not is_shotgun(wep.wid))
                               and (rack._zeroed_by_us ~= true)
        if rack.empty_when_dropped or _empty_chamber then
            rack.needs = true   -- sticky, nur durch Rack-Geste/Wechsel/Reset geclear't
        else
            rack.needs = false
            -- [SLIDE_STUCK_BACK FIX 2026-07-03] Taktischer Reload nach einer VORHER leeren Kammer
            -- (2. Mag-Zyklus: leer geschossen -> Drop -> Insert): die Engine hatte den Slide bei 0
            -- Ammo zurueckgelockt (~0.0574). Ein EINMALIGER rest_z-Snap reicht NICHT -> die Engine
            -- spielt nach manuellem Reload keine Schliess-Anim, und apply_slide_park returnt danach
            -- early (nichts aktiv) -> der Slide blieb auf 0.0574 haengen (rein optisch; ld=20, Waffe
            -- schiesst). FIX wie nach einem Rack: _chambered_hold setzen -> apply_slide_park HAELT den
            -- Slide jeden Frame auf rest_z bis zum 1. Schuss (dann uebernimmt die Engine-Anim).
            -- _prev_gun_ammo nil = frischer Schuss-Vergleich (sonst loest der Halt sofort). Fuer
            -- ENGINE_CLOSES_SLIDE-Waffen NICHT (deren Engine faehrt den Slide selbst vor).
            if not ENGINE_CLOSES_SLIDE[wep.wid] then
                rack._chambered_hold = true
                _G.__re4_ch_who = "1541(true)"   -- [CH-DIAG 2026-07-20] wer setzt den Slide-Halt?
                rack._prev_gun_ammo  = nil
            end
            -- Sofort-Snap (Erst-Effekt; der Halt oben zieht danach jeden Frame nach).
            if wep.slide_joint and not ENGINE_CLOSES_SLIDE[wep.wid] then
                local cur = sc(wep.slide_joint, "get_LocalPosition")
                if cur then
                    local sp2 = slide_pose(wep.wid or 0)
                    pcall(function() wep.slide_joint:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp2.rest_z)) end)
                end
            end
        end
        -- [EMPTY-RELOAD SLIDE] Riot Gun: war die Waffe VOR diesem Insert komplett leer (0 geladen)?
        -- -> dieser Reload chambert per _08-Lade-Slide (Slide-Rack, ziehen). VOR dem Ammo-Add lesen
        -- (= Vor-Reload-Stand). ZUERST bestimmt -- das Chamber-Fenster unten braucht empty_reload.
        if EMPTY_RELOAD_JOINT[wep.wid] then
            -- [EMPTY-DETECT FIX 2026-07-17] Loaded-Stand FRISCH per pe:getCurrentGunAmmo (kein Cache, laut Code
            -- zuverlaessig, gleiche Quelle wie force_eject). Frueher ueber get_live_weapon_item (Cache) ->
            -- liest im Insert-Frame oft nil -> _ld==0 verfehlt -> empty_reload NIE gesetzt -> Rack faellt nach
            -- Leerschuss weg. Fallback auf das Live-Item nur, wenn der Engine-Read fehlt. False-Positive-Guard
            -- bleibt: NUR bei ECHTEM 0 (nil -> NICHT setzen).
            local _pe = get_pe()
            local _ld = _pe and tonumber(safe(function() return _pe:call("getCurrentGunAmmo") end))
            if _ld == nil then
                local _wi = get_live_weapon_item()
                _ld = _wi and tonumber(safe(function() return _wi:call("get_CurrentAmmoCount") end)) or nil
            end
            -- STICKY: einmal leer-nachgeladen -> Slide-Modus bleibt bis zum Rack (clear_rack) / Wechsel.
            if _ld == 0 then rack.empty_reload = true end
        end
        -- [SHOTGUN] Shell eingelegt -> Chamber-Fenster (rack.needs) oeffnen.
        -- [RIOT GUN 2026-07-17] NUR die Riot Gun (NO_RELOAD_CYCLE) braucht bei taktischem Reload KEINEN
        -- Pump -- frei weiterballern; nur der 0-Reload chambert (Slide-Rack _08, empty_reload). Der alte
        -- `if is_shotgun then rack.needs=true` erzwang bei JEDEM Shell-Insert ein Pump-Fenster (+ IK-Freeze via
        -- __vr_slide_rack_active) -- Ueberbleibsel aus der Pump-Gun-Zeit. ALLE anderen Shotguns unveraendert:
        -- W-870 = Pump nach jedem Shell; Striker = Drehschalter-Cycle; Skull Shaker = Cock.
        if is_shotgun(wep.wid) then
            if not NO_RELOAD_CYCLE[wep.wid] or rack.empty_reload then rack.needs = true end
        end
        rack.empty_when_dropped = false
        rack._zeroed_by_us      = false   -- [ACCESSOR-FOLGE] Merker verbraucht, Zyklus zu Ende
        -- echter Ammo-Reload (wie das Game): Mag fuellen + Reserve abziehen
        if CFG.reload_ammo then
            local wi  = get_live_weapon_item()
            local pe  = get_pe()
            local inv = pe and sc(pe, "get_InventoryController")
            -- ECHTE Reserve = Inventar-Anzahl des Ammo-Items.
            local reserve, ammo_id = 0, wi and safe(function() return wi:call("get_CurrentAmmo") end)
            if inv and ammo_id then
                reserve = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0
            end
            if is_shotgun(wep.wid) then
                -- [ROTARY_DEFER 2026-07-18] Striker (ROTARY_CYCLE): Ammo NICHT beim Insert zaehlen ->
                -- erst am Drehschalter (update_rotary_cycle ruft rotary.do_load am Dreh-Peak). Hier nur
                -- pending markieren. Alle anderen Shotguns (W-870/Riot/Skull): sofort laden wie bisher --
                -- rotary.do_load ist der alte Insert-Shotgun-Zweig 1:1, nur ausgelagert als rotary-Tabellen-
                -- feld (KEIN neuer Main-Chunk-Local wegen 200-Limit). Ratio = SHOTGUN_RATIO_WID/CFG unveraendert.
                if ROTARY_CYCLE[wep.wid] then rotary.pending = true
                else rotary.do_load() end
            else
                -- [RUNTIME-FIX 0/0] FRUEHER: write_dword(0x44) auf `wi`. Waehrend des Reloads ist
                -- `wi` aber oft NICHT das Laufzeit-Item (__re4_live_wi stale -> Spiegel/Inv-Row) ->
                -- der Write greift nicht, ABER die Reserve wird abgezogen = 0/0 (per re4_reload_diag.log
                -- RELOAD_ZERO @wp4001 bestaetigt). JETZT: Engine-Reload-Pfad wie der Shotgun-Zweig
                -- (inv:reload ueber EquipType greift auf das ECHTE equippte Gun-Item, item-unabhaengig).
                -- Ziel = min(cap, retained+reserve). ZWEI Quellen getrennt behandeln:
                -- (1) Reserve-Anteil `used` via Engine-Reload (greift aufs echte Gun-Item, zieht Reserve).
                -- (2) Retained-Anteil (Rounds aus dem gedroppten Mag, schon bezahlt) -> frei auf target
                -- auffuellen OHNE Reserve-Abzug. (Frueherer Fix gatete ALLES auf used>0 -> bei reserve=0
                -- + retained>0 wurde nichts geladen = 0; per re4_reload_diag.log @wp6000 bestaetigt.)
                local cap    = wi and (sc(wi, "get_CurrentAmmoMax") or 0) or 0
                local target = math.min(cap, (mag_retained or 0) + reserve)
                local used   = math.max(0, target - (mag_retained or 0))   -- Reserve-Anteil
                local pe_h = get_pe()
                local function gun_ammo() return pe_h and tonumber(safe(function() return pe_h:call("getCurrentGunAmmo") end)) or nil end
                local function read_rsv() return (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or reserve) or reserve end
                local r_b4 = reserve
                local b4   = gun_ammo() or 0
                local et   = get_equip_type_main()
                -- (1) Reserve-Anteil laden. WICHTIG: nur wenn wirklich eine Waffe live equippt ist
                -- (EquipWeaponID >= 0). Bei wid=-1 (mitten im Waffen-/Mag-Wechsel) ist das Main-Gun-Item
                -- null -> der native reload dereferenziert null -> c0000005 (pcall faengt die AV NICHT).
                -- [CRASH-HARDEN 2026-07-14] Der >=0-Guard reichte nicht: beim Um-Equippen mitten im Reload
                -- (auch bei manuellem Nachladen) zeigt get_equip_wid schon die NEUE Waffe (>=0=ok), aber das
                -- Gun-Item ist im Uebergangsframe noch null -> Crash. Zusaetzlich verlangen, dass die live
                -- equippte Waffe == der Reload-Waffe (wep.wid) ist. Stimmt sie nicht -> Invoke ueberspringen.
                if et and inv and used > 0 and (get_equip_wid() or -1) >= 0 and get_equip_wid() == wep.wid then
                    _G.__re4_load_and_book(inv, et, used, false)
                end
                -- [log entfernt]
                local af  = gun_ammo() or b4
                local got = math.max(0, af - b4)
                if got > 0 and inv and ammo_id and read_rsv() >= r_b4 then   -- Reserve nur ziehen wenn Engine es nicht tat
                    _G.__re4_safe_reduce(inv, ammo_id, got)
                end
                -- (2) Retained-Anteil: auf target auffuellen (frei, KEIN Reserve-Abzug)
                if (gun_ammo() or af) < target then
                    pcall(function() wi:write_dword(0x44, target) end)
                    local now = gun_ammo() or (b4 + got)
                    if now < target and wi then pcall(function() wi:call("addAmmoCount", target - now, false) end) end
                end
                mag_retained = 0
            end
        else
            rlog("mag-insert FERTIG")
        end
    end
end

-- Chamber-Weltpunkt = Waffen-Transform (zuverlaessig) * gecachter Chamber-Offset (waffen-lokal).
-- Der Offset wird in capture_mag_rest aus der ECHTEN _04-Weltposition im Ruhezustand + dem
-- -0.093-Z-Port (in _04-lokalem Z) abgeleitet. So bleibt der Port fix an der Waffe, auch waehrend
-- _04 beim Reload der Hand folgt. (Parent-Joint-Ansatz war kaputt -> d war 0.3-0.8m daneben.)
local function shotgun_chamber_world()
    if not (wep.tf and wep.chamber_off) then return nil end
    local gp = sc(wep.tf, "get_Position"); local gr = sc(wep.tf, "get_Rotation")
    if not (gp and gr) then return nil end
    local co  = wep.chamber_off
    local off = safe(function() return gr * Vector3f.new(co.x, co.y, co.z) end); if not off then return nil end
    return Vector3f.new(gp.x + off.x, gp.y + off.y, gp.z + off.z)
end

-- [DOCK-PORT] Andock-Spot = LIVE-Weltpos eines FESTEN Gun-Joints + Offset in dessen lokalem Z.
-- Der Joint bewegt sich (anders als der Mag-Joint) NICHT mit der Hand -> Live-Transform direkt nutzbar.
local function dock_port_world()
    local cfg = wep.wid and DOCK_PORT[wep.wid]; if not cfg then return nil end
    if not wep.tf then return nil end
    local j = sc(wep.tf, "getJointByName", cfg.joint); if not j then return nil end
    local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation")
    if not (jp and jr) then return nil end
    local off = safe(function() return jr * Vector3f.new(cfg.x or 0, cfg.y or 0, cfg.z or 0) end); if not off then return nil end
    return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
end
-- [LEVER_PORT] Greif-Punkt des Break-Hebels (wie dock_port_world, eigene Tabelle).
local function lever_port_world()
    local cfg = wep.wid and LEVER_PORT[wep.wid]; if not cfg or not wep.tf then return nil end
    local j = sc(wep.tf, "getJointByName", cfg.joint); if not j then return nil end
    local jp = sc(j, "get_Position"); local jr = sc(j, "get_Rotation")
    if not (jp and jr) then return nil end
    local off = safe(function() return jr * Vector3f.new(0, 0, cfg.z) end); if not off then return nil end
    return Vector3f.new(jp.x + off.x, jp.y + off.y, jp.z + off.z)
end

-- Proximity: Mag in Hand nah genug an die Waffe -> automatisch in die Kammer sliden
local function check_mag_insert_proximity()
    if not mag_hand.active then return end
    local lh = get_left_hand(); if not lh then return end
    local hp = sc(lh, "get_Position"); if not hp then return end
    -- Bezugspunkt: exakter DOCK-PORT (festes Joint + Z-Offset) wenn fuer die Waffe definiert,
    -- sonst rechte Hand (Griff) / Waffen-Root.
    -- [ADA-LADEPUNKT 2026-08-15] Hier fehlte der Einleit-Punkt aus reload_adv, den Leons
    -- check_mag_insert_proximity laengst abfragt. Ohne ihn fiel die Kette direkt auf
    -- `__vr_rh_world` durch -- also auf die RECHTE HAND. Die Andock-Kugel lag damit um die
    -- ganze Waffenhand statt um den Kammereingang, und das Magazin rutschte auch dann hinein,
    -- wenn man es seitlich neben die Kammer hielt (live berichtet, MP-AF 6104).
    -- Die Werte selbst waren immer da: DOCK_ALLOWED und der docks-Eintrag fuer 6104 sind
    -- identisch zu Leons TMP 4200 (joint "_03", y -0.097, z -0.052) -- nur abgefragt wurden
    -- sie nie. Liefert dock_world nichts (Joint fehlt an der Waffe), bleibt es exakt beim
    -- bisherigen Verhalten -- der Fallback steht unveraendert dahinter.
    local _advp = nil
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if ms and type(ms.dock_world) == "function" and wep.tf then
            _advp = ms.dock_world(wep.tf, wep.wid or 0)
        end
    end
    local gp = dock_port_world() or _advp or rawget(_G, "__vr_rh_world") or (wep.tf and sc(wep.tf, "get_Position"))
    if not gp then return end
    local dx, dy, dz = hp.x - gp.x, hp.y - gp.y, hp.z - gp.z
    local d = math.sqrt(dx*dx + dy*dy + dz*dz)
    mag_hand.dist = d   -- fuer UI-Anzeige
    local cat = wep.wid and category_of(wep.wid)
    -- [INSERT-DIST PRO WAFFE] Per-Waffe-Override vor dem Gattungs-Wert.
    local idist = (wep.wid and INSERT_DIST_WID[wep.wid]) or (cat and INSERT_DIST[cat]) or INSERT_DIST.pistols
    -- [MANUAL_INSERT 2026-08-15] Nach einem Rueckzieher (Mag wieder in der Hand) steht die Hand noch
    -- mitten in der Andock-Distanz -- ohne Sperre klebte das Mag im naechsten Frame sofort wieder an.
    -- Also: Abstand beim Rueckzieher merken (Sentinel `true` = beim naechsten Durchlauf einmalig
    -- merken, update_mag_insert kann ihn nicht selbst ausrechnen) und erst wieder andocken, wenn man
    -- ihn um insert_redock VORgeschoben hat -- oder normal weit weggegangen ist.
    if mag_hand.redock_d ~= nil then
        if mag_hand.redock_d == true then
            mag_hand.redock_d = d
            return
        elseif d > idist then
            mag_hand.redock_d = nil            -- normal weit weg -> alles wieder wie immer
        elseif d <= (mag_hand.redock_d - (tonumber(CFG.insert_redock) or 0.01)) then
            mag_hand.redock_d = nil            -- wieder Richtung Waffe geschoben -> andocken erlauben
        else
            return                             -- im Totband: NICHT andocken
        end
    end
    if d <= idist then
        mag_hand.active = false
        start_mag_insert()
    end
end

-- Mag-in-Hand aktivieren (Holster-Grab ODER UI-Tuning-Toggle)
local function mag_to_hand()
    if not wep.mag_joint then return false end
    stop_mag_drop()
    mag_insert.active = false   -- evtl. laufenden Insert abbrechen
    mag_insert.settle = false   -- [INSERT-PUNCH] Nachfedern mit abbrechen
    mag_tune.active = false     -- echter Grab beendet den Einstell-Modus
    mag_hand.active = true
    mag_hand.joint = wep.mag_joint
    mag_hand.wid = wep.wid
    mag_hand.redock_d = nil     -- [MANUAL_INSERT] frischer Grab -> keine Andock-Sperre aus einem alten Rueckzieher
    return true
end

-- Mag faellt von der aktuellen (Hand-)Position auf den Boden (Gravity, wie der B-Drop-Fall)
local function drop_mag_simple()
    if not wep.mag_joint then return false end
    local p = sc(wep.mag_joint, "get_Position"); if not p then return false end
    drop.joint, drop.use_module = wep.mag_joint, false
    drop.sx, drop.sy, drop.sz = p.x, p.y, p.z
    -- [ENTKOPPEL_ROT] Weltrotation einfrieren -> Mag dreht sich am Boden nicht mit der Waffe.
    do local r = sc(wep.mag_joint, "get_Rotation")
       if r then drop.srw, drop.srx, drop.sry, drop.srz = r.w, r.x, r.y, r.z else drop.srw = nil end end
    drop.t0 = os.clock()
    drop.active = true
    return true
end
-- vom Holster-Script gerufen: Mag in der Hand AN (Grip gedrueckt) / AUS (Grip los)
-- [RESERVE-FIX 2026-07-08] getItemCountSum(ItemID) liefert 0, OBWOHL das Ammo-Item mit Count im selben
-- Inventar liegt (per getItems live verifiziert; Ursache: ItemID:ToString gibt keinen String -> das
-- Enum-Marshalling in getItemCountSum scheitert). ZUVERLAESSIG: getItems durchgehen, per tostring(ItemId)
-- matchen und CurrentItemCount summieren (deckt gestackte Ammo). Global -> reload2/reload3 nutzen dasselbe.
-- Gilt fuer ALLE Waffen/Items. [[Notiz]]
_G.__re4_item_count_sum = _G.__re4_item_count_sum or function(inv, id)
    if not (inv and id) then return 0 end
    local want = tostring(id)
    local items = safe(function() return inv:call("getItems") end); if not items then return 0 end
    local n = tonumber(safe(function() return items:call("get_Count") end)) or 0
    local sum = 0
    for i = 0, n - 1 do
        local it = safe(function() return items:call("get_Item(System.Int32)", i) end)
        if it then
            local iid = safe(function() return it:call("get_ItemId") end)
            if iid and tostring(iid) == want then
                sum = sum + (tonumber(safe(function() return it:call("get_CurrentItemCount") end)) or 0)
            end
        end
    end
    return sum
end

-- [TOP_LOADER] aktuelle Reserve-Ammo der equippten Waffe (ohne dass vorher geschossen
-- werden musste). Nutzt das Live-Item, faellt auf getEquipWeaponItem zurueck (nur fuer die
-- Ammo-ItemID), dann die korrekte getItems-Zaehlung. 0 wenn nichts ermittelbar.
local function current_reserve()
    local wi = get_live_weapon_item()
    if not wi then local pe0 = get_pe(); wi = pe0 and safe(function() return pe0:call("getEquipWeaponItem") end) end
    if not wi then return 0 end
    local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end); if not ammo_id then return 0 end
    local pe2 = get_pe(); local inv2 = pe2 and sc(pe2, "get_InventoryController"); if not inv2 then return 0 end
    return tonumber(safe(function() return _G.__re4_item_count_sum(inv2, ammo_id) end)) or 0
end

-- [SHOTGUN GIMMICK] 1 Patrone RAUSPUMPEN: loaded -1 -> shell_bank +1 (kein Verlust, kein Inventar-
-- Gefummel). Gibt true zurueck wenn was rausging (loaded>0) -> dann fliegt die Shell. Funktioniert
-- bei JEDER Reserve (auch 0). Beim Reload kommen die Bank-Patronen zuerst gratis zurueck.
-- [SHOTGUN GIMMICK] Rein kosmetisch: Shell fliegt beim unnoetigen Pump solange Munition geladen ist.
-- KEINE Ammo-Aenderung (Shotgun-Chamber laesst sich per WeaponItem nicht dekrementieren -> wuerde eh
-- nicht greifen). Kostet so per Definition nichts. Gibt true zurueck wenn die Shell fliegen soll.
local function pump_one_out()
    local wi = get_live_weapon_item(); if not wi then return false end
    local loaded = tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)) or 0
    return loaded > 0
end

-- [SMIH_KETTE 2026-07-19] Hier stand ein `or`-Guard:
-- _G.__re4_reload_set_mag_in_hand = _G.__re4_reload_set_mag_in_hand or function(active)
-- re4_vr_reload.lua (Leon) laedt ALPHABETISCH VORHER ("." < "4") und setzt die Funktion hart.
-- Der Guard hat Adas Version deshalb NIE installiert: beim Griff an den Mag-Holster antwortete
-- Leons Closure, die fuer 61xx nichts verwaltet -> return false -> kein Mag in der Hand, obwohl
-- mag_out=true, MAG_JOINT=true und Reserve da waren (im Log verifiziert).
--
-- Fix = exakt das Muster, das re4_vr_reload5_dlc.lua:769 schon benutzt: vorherige Funktion
-- aufheben, nach Zustaendigkeit entscheiden, sonst DURCHREICHEN.
-- LEON BLEIBT UNBERUEHRT: fuer jede ID, die dieses File nicht kennt (category_of == nil, alle
-- Maincampaign-IDs), wird 1:1 die vorher registrierte Funktion aufgerufen -- gleiche Funktion,
-- gleiche Argumente, gleicher Rueckgabewert.
-- Vorgaenger als GLOBAL sichern, nicht als local: dieses File steht am 200-Local-Limit
-- (ein `local` hier bricht die Kompilierung mit "too many local variables").
_G.__re4_smih_prev_r4 = _G.__re4_reload_set_mag_in_hand
_G.__re4_reload_set_mag_in_hand = function(active)
    -- Nicht unsere Waffe? -> an die bestehende Kette weiterreichen (Leon/reload2/reload3).
    if category_of(get_equip_wid()) == nil then
        local prev = rawget(_G, "__re4_smih_prev_r4")
        if prev then return prev(active) end
        return false
    end
    -- [MANUAL_INSERT 2026-08-15] Haelt die linke Hand den Grip GERADE? Diese Funktion ist die einzige
    -- verlaessliche Quelle: das Holster ruft sie flankenweise beim Druecken und beim Loslassen. Waehrend
    -- eines laufenden Inserts ist mag_hand.active false -- der Loslass-Zweig unten macht dann nichts,
    -- und ohne diesen Merker wuesste der Rueckzieher nicht, dass der Finger laengst offen ist.
    -- Steht NACH der Weiterreichung: fuer Leons Waffen fuehrt reload.lua seinen eigenen Merker.
    mag_hand.grip_held = (active == true)
    if active then
        if not _managed then return false end      -- [LET-GO] Toggle aus -> kein Grab, alles nativ
        if is_shotgun(wep.wid) then
            -- [SHOTGUN] Shell aus dem Holster in die linke Hand (Joint _04 folgt der Hand wie ein Mag).
            -- KEIN mag_out noetig (man wirft kein Mag aus) -> nur greifbar wenn Reserve da ist und die
            -- Roehre nicht schon voll. Insert per Naehe addiert dann SHOTGUN_RATIO Shells.
            -- [STRIKER] Nach einer eingelegten Shell MUSS erst der Drehschalter gedreht werden (rack.needs)
            -- bevor die naechste Shell geholt werden darf. Nur ROTARY_CYCLE-Waffen (W-870/Riot Gun: frei laden).
            if ROTARY_CYCLE[wep.wid] and rack.needs then return false end
            if BREAK_ACTION[wep.wid] and not (rawget(_G, "__vr_break_open") == true) then return false end   -- [SKULL SHAKER] Shell nur bei OFFENEM Hebel holbar
            if mag_hand.active or mag_insert.active then return false end
            local wi0    = get_live_weapon_item()
            local loaded = wi0 and (sc(wi0, "get_CurrentAmmoCount") or 0) or 0
            local cap0   = wi0 and (sc(wi0, "get_CurrentAmmoMax") or 0) or 0
            -- greifbar wenn Reserve da UND Roehre nicht voll
            if current_reserve() <= 0 or (cap0 > 0 and loaded >= cap0) then return false end
            local ok = mag_to_hand()
            if ok then rlog("shotgun shell-in-hand AN"); play_weapon_sound(snd("mag_holster")) end
            return ok
        end
        -- Nur erlauben wenn die Kammer LEER ist (Mag schon draussen, mag_out=true).
        -- Es gibt nur EINEN Mag-Joint: bei vollem Mag wuerde der Holster-Grab das
        -- Kammer-Mag herausziehen (Mag verschwindet aus der Waffe). Schon ein Mag in
        -- der Hand? -> auch blocken (kein zweites).
        if TOP_LOADER[wep.wid] then
            -- [CLIP zurueckgestellt] Red9: kein Mag-Joint, Clip-Visual noch ungeloest -> Holster-
            -- Grab macht (noch) nichts. Funktionaler Reload = Chamber via B + Ammo per Insert.
            return false
        end
        if mag_hand.active then return false end   -- kein zweites Mag in die Hand
        if not mag_out then return false end
        local ok = mag_to_hand()
        if ok then rlog("mag-in-hand AN"); play_weapon_sound(snd("mag_holster")) end
        return ok
    end
    -- Grip losgelassen
    if is_shotgun(wep.wid) then
        -- [SHOTGUN] Shell nicht eingefuehrt -> faellt auf den Boden (wie ein Pistolen-Mag), NICHT
        -- zurueck in die Ruhepose. _04 wird von der aktuellen (Hand-)Position mit Gravity gedroppt.
        if mag_hand.active then
            mag_hand.active = false
            drop_mag_simple()
            rlog("shotgun shell losgelassen -> faellt auf den Boden")
        end
        return true
    end
    if TOP_LOADER[wep.wid] then return true end
    -- war das Mag noch in der Hand (nicht per Naehe inserted) -> faellt auf den Boden.
    if mag_hand.active then
        mag_hand.active = false
        drop_mag_simple()
        rlog("mag losgelassen -> faellt auf den Boden")
    end
    return true
end

-- FORWARD-DECL: live_loaded_count ist erst weiter unten (SLIDE-RACK-Sektion)
-- definiert. force_eject ruft es aber HIER schon -> ohne Forward-Decl zeigt der
-- Name auf eine nil-Globale -> Crash bei jedem B-Druck (bricht on_frame ab, bevor
-- der Mag-Drop startet). Forward-decl macht beide zum selben Upvalue. [[feedback-lua-forward-decl]]
local live_loaded_count

-- ROBUSTER Mag-Auswurf: raeumt JEDEN Zwischenzustand ab (laufender Insert,
-- Mag-in-Hand, Tuning, haengender/alter Drop, ungueltiger Joint nach Save-Load)
-- und startet immer einen frischen Drop aus der Kammer. Nie blockiert.
local function force_eject()
    -- [UNLIMITED] Waffe mit Unlimited-Ammo (Spezial-Upgrade/Infinite-Script) muss NIE
    -- nachladen -> B-Drop stilllegen (sonst haengt der Reload-Flow). Frisch gelesen.
    if _G.__re4_is_unlimited and _G.__re4_is_unlimited() then return false end
    refresh_weapon()                 -- Joint nach Save-Load/Wechsel neu aufloesen
    if not wep.mag_joint then return false end
    -- [MAG_OUT] Mag ist schon draussen -> NICHT noch eins droppen (Anti-Doppeldrop).
    -- mag_out wird per live_loaded_count>0 geheilt (siehe on_frame), kann nicht haengen.

    if mag_out then return false end
    -- [KEIN DROP OHNE RESERVE 2026-08-12] Ohne Nachschub wird das Magazin gar nicht erst
    -- ausgeworfen -- gilt fuer JEDE Waffe, nicht nur fuer die, bei der es auffiel.
    if (tonumber(current_reserve()) or 0) <= 0 then
        return false
    end
    -- RE9-Latch: war die Waffe JETZT (vor dem Drop) leer? -> nach dem Reload Rack noetig.
    -- Taktischer Wechsel mit Patronen drin (loaded>0) -> KEIN Rack noetig.
    -- [STALE-FIX 2026-07-08] FRISCHER Engine-Read (pe:getCurrentGunAmmo = kein Cache, laut Code zuverlaessig)
    -- statt live_loaded_count -> das geht ueber das gecachte __re4_live_wi und liest nach Save-Load stale 0
    -- -> empty_when_dropped faelschlich true -> rack.needs latcht -> Dauer-Dry-Fire TROTZ Munition (gamebreaking).
    -- Regel bleibt exakt: Rack nur wenn die Gun beim Drop WIRKLICH 0 hatte. Fallback wenn pe/Read fehlt.
    do
        local pe_ee = get_pe()
        local fresh_ga = pe_ee and tonumber(safe(function() return pe_ee:call("getCurrentGunAmmo") end))
        if fresh_ga ~= nil then rack.empty_when_dropped = (fresh_ga == 0)
        else rack.empty_when_dropped = (live_loaded_count() == 0) end
        -- [KAMMER 2026-08-12] Der Read oben kann bereits UNSERE 0 sehen (mehrere Stellen nullen
        -- die Waffe beim Auswurf). War beim Nullen etwas im Magazin, war die Kammer NICHT leer
        -- -> kein Rack verlangen. Quelle ist der gemerkte Magazinrest.
        if (tonumber(rawget(_G, "__re4_mag_carry")) or 0) > 0 then rack.empty_when_dropped = false end
    end
    rack._chambered_hold = false   -- [CHAMBER_HOLD] neuer Reload-Zyklus -> Halt aus
    -- NIE blockiert: jeden laufenden Zwischenzustand abraeumen, Mag in Ruhepose, frisch
    -- droppen. KEIN Gate (das hatte B nach Reset/Save-Load tot gemacht).
    stop_mag_drop()
    mag_hand.active   = false
    mag_insert.active = false
    mag_insert.settle = false   -- [INSERT-PUNCH] Nachfedern mit abbrechen
    mag_tune.active   = false
    if wep.rest_lp then
        pcall(function() wep.mag_joint:call("set_LocalPosition",
            Vector3f.new(wep.rest_lp.x, wep.rest_lp.y, wep.rest_lp.z)) end)
    end
    if wep.rest_lr then
        pcall(function() wep.mag_joint:call("set_LocalRotation",
            Quaternion.new(wep.rest_lr.w, wep.rest_lr.x, wep.rest_lr.y, wep.rest_lr.z)) end)
    end
    local started = start_mag_drop()
    if started then mag_out = true end   -- [MAG_OUT] erst bei erfolgreichem Drop setzen
    if started then play_weapon_sound(snd("mag_eject")) end  -- [SND] Mag verlaesst die Waffe (Boden folgt verzoegert)
    return started
end

-- =====================================================================
-- Rechter B-Knopf -> Mag-Drop (RE9-Prinzip: Binding faengt B ab)
-- =====================================================================
-- Das Binding (re4_vr_binding.lua) unterdrueckt den rechten B -> Gamepad-X
-- (= nativer Reload), solange _G.__vr_manual_reload_consume_b gesetzt ist.
-- Wir lesen den B-Knopf direkt (nicht-konsumierend) fuer die Trigger-Flanke.
-- WICHTIG: NUR das Action-Handle cachen, den right_joystick JEDEN Call FRISCH holen.
-- Ein gecachtes Joystick-Handle wird stale (frueh gegriffen vor Controller-Init /
-- nach SteamVR-Szenenwechsel) -> is_action_active liefert lautlos false OHNE Fehler
-- -> setzt sich nie zurueck -> B reagiert dauerhaft nicht. 1:1 wie left_grip_down.
-- B kommt aus dem Binding (re4_vr_binding.lua): es liest den rechten B-Knopf ohnehin jeden
-- Frame und publiziert ihn VOR dem Consume als _G.__vr_raw_r_bbutton. Das ist die EINE
-- autoritative Quelle (Binding re-initialisiert die VR-Actions bei Reset). KEIN eigener
-- vrmod-Read mehr hier -> kein stale Action-Handle, das B wiederholt totlegt.
local function right_b_down()
    return rawget(_G, "__vr_raw_r_bbutton") == true
end
local _b_prev = false
-- [SND] Timer/Flanken fuer die Waffen-Sounds
local _mag_floor_at  = 0       -- os.clock-Ziel fuer den verzoegerten Mag-Boden-Sound
local _drop_prev     = false   -- Drop-Aktiv-Flanke (Auswurf ODER Holster-Release-Fall)
local _empty_trig_prev = false -- leere-Waffe-Trigger-Flanke (Dry-Fire)

-- =====================================================================
-- Frame-Loops
-- =====================================================================
-- Killswitch-fuer-Haende: wenn der manuelle Reload fuer die equippte Pistole AUS
-- ist und die NATIVE Reload-Anim (L4) laeuft, motion.lua pausieren -> die Engine
-- animiert die Haende selbst (statt Controller-Pin). Kein Kamera-Killswitch.
local native_pause_active = false
local function update_native_reload_pause()
    local wid = get_equip_wid()
    local manual_off = wid and category_of(wid) == "pistols" and not handled()
    local in_reload = false
    if manual_off then
        local body = get_body()
        local mfsm2 = body and sc(body, "getComponent(System.Type)", TD.mfsm2)
        local node = mfsm2 and sc(mfsm2, "getCurrentNodeName", 4)
        node = node and tostring(node) or ""
        in_reload = node:find("Reload", 1, true) ~= nil
    end
    if in_reload and not native_pause_active then
        native_pause_active = true
        _G.__vr_motion_paused = true
    elseif not in_reload and native_pause_active then
        native_pause_active = false
        _G.__vr_motion_paused = false
    end
end

-- =====================================================================
-- SLIDE-RACK (RE9-Muster): leer -> RT blockiert bis nachgeladen UND gerackt
-- =====================================================================
-- Geladene Patronen ROBUST lesen — jeden Frame frisch, KEIN event-gecachtes Item
-- (Cache veraltet nach Reset/Save/ohne-Schuss). Quellen-Kaskade, erste gueltige zaehlt.
local function read_loaded_of(wi, want_wid)
    if not wi then return nil end
    if want_wid then
        local cwid = safe(function() return wi:call("get_WeaponId"):get_field("value__") end)
        if cwid and cwid ~= want_wid then return nil end   -- falsches Item -> ignorieren
    end
    local n = safe(function() return wi:call("get_CurrentAmmoCount") end)
    return (type(n) == "number") and n or nil
end
-- (Zuweisung an die Forward-Decl oben, NICHT 'local function' -> selber Upvalue)
live_loaded_count = function()
    -- KONSISTENZ ist alles: lesen vom GLEICHEN Item auf das set_gun_loaded/addAmmoCount
    -- schreiben (get_live_weapon_item). Sonst sieht der Block-Check nach dem Drop noch
    -- Munition -> Schiessen ohne Mag. getCurrentGunAmmo war eine andere Quelle -> raus.
    local ewid = get_equip_wid()
    local n = read_loaded_of(get_live_weapon_item(), ewid)
    if n then return n end
    -- Fallback nur falls das Live-Item mal fehlt
    return read_loaded_of(get_weapon_item(), nil)
end

-- [GUN_STATE] chainsaw.Gun = Waffen-Runtime auf dem Waffen-GO. Traegt CurrentState; bei 0 Ammo
-- = AmmoEmpty -> Engine lockt den Slide hinten. set_CurrentState/setState entriegelt.
-- ([CLEANUP] toter `local _gun_type` entfernt -- war nie benutzt.)
-- Live-Gun der EQUIPPTEN Waffe DIREKT aus PlayerEquipment.WeaponList holen
-- (Dictionary<WeaponID, Arms>; fuer Pistolen ist Arms = chainsaw.Gun). Kein Hook, keine
-- Baum-Suche, kein Neustart. PlayerEquipment kriegen wir zuverlaessig (get_pe).
local function get_gun()
    local pe = get_pe(); if not pe then _G.__re4_gun_dbg = "no_pe"; return nil end
    local wl = safe(function() return pe:get_field("WeaponList") end)
    if not wl then _G.__re4_gun_dbg = "no_WeaponList"; return nil end
    local ewid = get_equip_wid(); if not ewid then _G.__re4_gun_dbg = "no_ewid"; return nil end
    -- 1) Versuch get_Item (Enum-Key direkt + als Zahl)
    for _, key in ipairs({ safe(function() return pe:call("get_EquipWeaponID") end), ewid }) do
        if key ~= nil then
            local a = safe(function() return wl:call("get_Item", key) end)
            if a and safe(function() return a:call("get_CurrentState") end) ~= nil then _G.__re4_gun_dbg = "OK(get_Item)"; return a end
        end
    end
    -- 2) Fallback: ueber die internen _entries iterieren und die Arms mit passender WeaponID nehmen
    local entries = safe(function() return wl:get_field("_entries") end)
    local cnt = tonumber(safe(function() return wl:get_field("_count") end)) or 0
    if not entries then _G.__re4_gun_dbg = "no_entries"; return nil end
    for i = 0, cnt - 1 do
        local v = safe(function() local e = entries[i]; return e and e:get_field("value") end)
        if v then
            local vwid = safe(function() return v:call("get_WeaponID"):get_field("value__") end)
            if vwid == ewid and safe(function() return v:call("get_CurrentState") end) ~= nil then
                _G.__re4_gun_dbg = "OK(iter)"; return v
            end
        end
    end
    _G.__re4_gun_dbg = "not_found(cnt=" .. cnt .. ")"
    return nil
end
local function gun_state_val()
    local g = get_gun(); if not g then return nil end
    local s = safe(function() return g:call("get_CurrentState") end)
    if type(s) == "number" then return s end                                  -- Enum kommt als Zahl
    if type(s) == "userdata" then return safe(function() return s:get_field("value__") end) end
    return nil
end
-- Enum-Werte holen (AmmoEmpty fuer die Leer-Erkennung, Holding zum Entriegeln nach dem Rack).
local _state_td = sdk.find_type_definition("chainsaw.Gun.State")
local function _enum_num(name)
    local v = _state_td and safe(function() return _state_td:get_field(name):get_data(nil) end)
    if type(v) == "number" then return v end
    return v and safe(function() return v:get_field("value__") end)
end
local _ammoempty_num    = _enum_num("AmmoEmpty")
local _gun_state_holding = _state_td and safe(function() return _state_td:get_field("Holding"):get_data(nil) end)
-- Wert -> Name Map fuer lesbare Logs (AmmoEmpty/Holding/Fire/Reload/...)
local _state_names = {}
pcall(function()
    if not _state_td then return end
    for _, f in ipairs(_state_td:get_fields()) do
        if f:is_static() then
            local v = f:get_data(nil)
            local num = (type(v) == "number") and v or (type(v) == "userdata" and safe(function() return v:get_field("value__") end))
            if num then _state_names[num] = f:get_name() end
        end
    end
end)
local function gun_state_name()
    local v = gun_state_val()
    if v == nil then return "NIL(keine Gun)" end
    return string.format("%s(%s)", _state_names[v] or "?", tostring(v))
end
-- [EMPTY] Sieht die ENGINE die Waffe als leer? (Gun.CurrentState==AmmoEmpty) -> zuverlaessig,
-- unabhaengig vom kaputten Ammo-Zaehler. Das treibt "0 Ammo -> Slide MITTEL".
local function gun_is_empty()
    local v = gun_state_val()
    return (v ~= nil and _ammoempty_num ~= nil and v == _ammoempty_num) or false
end
-- [RACK-ZWANG HART 2026-07-20 -- per Log bewiesen] Unser Feuer-Block (f.RT weglassen) reicht NICHT:
-- die Engine sieht den Trigger auch ohne unser virtuelles Gamepad, deshalb fiel trotz gesetztem Block ein
-- Schuss -- und bei "leer + Trigger" zieht sie sogar selbst das Messer (Quick-Knife). Wirksam ist nur der
-- ENGINE-Zustand: solange ein Rack aussteht, die Gun aktiv in AmmoEmpty halten. Genau das tut die Engine
-- bei Leons Pistolen von sich aus; Adas Blacktail AC chambert dagegen sofort nach dem Reload.
-- Gegenstueck zu gun_chamber -- wird NUR gerufen, solange rack.needs steht, und faellt mit clear_rack weg.
-- GLOBAL statt local: reload4_dlc.lua sitzt am 200-Local-Limit (ein weiterer Top-Level-Local
-- sprengt die Datei: "too many local variables"). Closure faengt get_gun/_ammoempty_num als Upvalue.
-- [KAMMER-RUECKHALT 2026-07-20 -- Zustands-Weg per Log widerlegt] set_CurrentState(AmmoEmpty)
-- verliert das Rennen: die Engine schreibt den State JEDEN Frame auf Holding zurueck (Log: "vorher=3
-- nachher=2" im Dauerlauf) und im Trigger-Frame gewinnt sie ("vorher=1"=Fire) -> Schuss trotz Block.
-- Was die Engine NICHT ueberschreiben kann, ist eine leere Kammer. Also: nach dem 0-Reload die geladene
-- Munition zurueckhalten (Wert merken, Kammer auf 0) und beim Rack (clear_rack) exakt wieder einsetzen.
-- Die Reserve ist da laengst korrekt abgezogen -- es geht NUR um die Zahl in der Waffe.
-- GLOBAL statt local: reload4_dlc.lua sitzt am 200-Local-Limit.
_G.__re4_gun_hold_empty = function()
    local pe = get_pe(); if not pe then return end
    local cur = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end))
    if not cur or cur <= 0 then return end          -- schon leer -> nichts zu tun
    rack.hold_ammo = math.max(tonumber(rack.hold_ammo) or 0, cur)   -- hoechsten gesehenen Stand merken
    -- [ROBUST 2026-07-20] write_dword allein greift nicht zuverlaessig: get_live_weapon_item liefert
    -- waehrend/nach dem Reload oft NICHT das Laufzeit-Item (Kommentar im Insert-Pfad sagt dasselbe).
    -- Deshalb ZWEI Wege und danach VERIFIZIEREN -- sonst bleibt die Waffe feuerbereit (2. Zyklus-Bug).
    local wi = get_live_weapon_item()
    _G.__re4_carry_capture(wi, "re4_vr_reload4_dlc.lua:2211", nil)   -- [MAG-REST] merken, bevor genullt wird
    if wi then pcall(function() wi:write_dword(0x44, 0) end) end
    local now = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or cur
    if now > 0 and wi then pcall(function() wi:call("addAmmoCount", -now, false) end) end
    now = tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or now
end
-- Gegenstueck: beim Rack die zurueckgehaltene Ladung wieder einsetzen (gleiche Bausteine wie der Insert-Pfad).
_G.__re4_gun_release_hold = function()
    local n = tonumber(rack.hold_ammo) or 0
    rack.hold_ammo = nil
    if n <= 0 then return end
    local wi = get_live_weapon_item(); if not wi then return end
    pcall(function() wi:write_dword(0x44, n) end)
    local pe = get_pe()
    local now = pe and tonumber(safe(function() return pe:call("getCurrentGunAmmo") end)) or 0
    if now < n then pcall(function() wi:call("addAmmoCount", n - now, false) end) end
end
-- Gun aus AmmoEmpty holen (= "Patrone gechambert") -> Engine lockt den Slide nicht mehr.
local function gun_chamber()
    local g = get_gun(); if not (g and _gun_state_holding ~= nil) then return end
    pcall(function() g:call("set_CurrentState(chainsaw.Gun.State)", _gun_state_holding) end)
end

local _rack_lj = nil
local function rack_haptic(amp, dur)
    if not CFG.rack_haptic or not vrmod then return end
    if not _rack_lj then pcall(function() _rack_lj = vrmod:get_left_joystick() end) end   -- linke Hand rackt
    if _rack_lj then pcall(function() vrmod:trigger_haptic_vibration(0.0, dur or 0.06, 169.385, amp or 0.9, _rack_lj) end) end
end

-- [SHOTGUN PUMP] Haptik mit optionalem Delay (CFG.pump_haptic_delay) -> aufs Audio legbar.
-- Delay<=0 -> sofort. Sonst in die Queue, service_haptics feuert wenn die Zeit erreicht ist.
local _haptic_queue = {}
local function queue_haptic(amp, dur)
    local d = tonumber(CFG.pump_haptic_delay) or 0
    if d <= 0 then rack_haptic(amp, dur); return end
    _haptic_queue[#_haptic_queue + 1] = { at = os.clock() + d, amp = amp, dur = dur }
end
local function service_haptics()
    local n = #_haptic_queue
    if n == 0 then return end
    local now = os.clock()
    local i = 1
    while i <= #_haptic_queue do
        local h = _haptic_queue[i]
        if now >= h.at then rack_haptic(h.amp, h.dur); table.remove(_haptic_queue, i)
        else i = i + 1 end
    end
end

-- [ROTARY_DEFER 2026-07-18] Der Shotgun-Ammo-Add (Reserve->Mag in Ratio) als Feld auf der
-- bestehenden rotary-Tabelle = KEIN neuer Main-Chunk-Local (200-Limit). Logik 1:1 aus dem alten Insert-
-- Shotgun-Zweig, nur wi/reserve/loaded frisch recomputet (zum Aufruf-Zeitpunkt). Aufrufer: nicht-Rotary
-- Shotguns beim Insert (sofort), Striker am Drehschalter-Peak (update_rotary_cycle).
rotary.do_load = function()
    if not CFG.reload_ammo then return end
    local wi  = get_live_weapon_item()
    local pe  = get_pe()
    local inv = pe and sc(pe, "get_InventoryController")
    local ammo_id = wi and safe(function() return wi:call("get_CurrentAmmo") end)
    local reserve = 0
    if inv and ammo_id then reserve = tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or 0 end
    local loaded = wi and (sc(wi, "get_CurrentAmmoCount") or 0) or 0
    local cap    = wi and (sc(wi, "get_CurrentAmmoMax") or 0) or 0
    -- [SHELL-RATIO-SYNC 2026-07-24] Ratio kommt jetzt zentral aus reload1 (ein Schalter fuer Leon+Ada);
    -- eigene Tabelle nur noch Fallback, falls reload1 nicht geladen ist.
    local ratio  = math.max(1, math.floor(tonumber((rawget(_G, "__re4_shotgun_ratio_get") and _G.__re4_shotgun_ratio_get(wep.wid)) or SHOTGUN_RATIO_WID[wep.wid] or CFG.shotgun_ratio) or 2))
    local add    = math.min(ratio, math.max(0, cap - loaded), reserve)
    if add <= 0 then return end
    -- loaded erhoehen: ENGINE-Reload inv:reload (einziger Pfad der wirklich greift; write_dword/addAmmoCount
    -- werden re-synct), Fallback addAmmoCount. VERLUSTSICHER: Reserve nur abziehen wenn der Pfad sie nicht selbst zog.
    -- [ACCESSOR 2026-08-12] echte Instanz zuerst; __re4_live_wi kann eine Leiche sein, wi eine Kopie.
    local awi   = (_G.__re4_real_wi and _G.__re4_real_wi()) or rawget(_G, "__re4_live_wi") or wi
    local b4    = awi and (sc(awi, "get_CurrentAmmoCount") or loaded) or loaded
    local r_b4  = reserve
    local et    = get_equip_type_main()
    -- [CRASH-HARDEN] nativer reload nur bei live equippter, passender Waffe (sonst null-Gun-Item -> c0000005).
    if et and inv and (get_equip_wid() or -1) >= 0 and get_equip_wid() == wep.wid then _G.__re4_load_and_book(inv, et, add, false) end
    local af    = awi and (sc(awi, "get_CurrentAmmoCount") or b4) or b4
    if af <= b4 then pcall(function() awi:call("addAmmoCount", add, true) end); af = awi and (sc(awi, "get_CurrentAmmoCount") or b4) or b4 end
    if af <= b4 then pcall(function() awi:call("addAmmoCount", add, false) end); af = awi and (sc(awi, "get_CurrentAmmoCount") or b4) or b4 end
    local gained = math.max(0, af - b4)
    if gained > 0 then
        local function read_rsv() return (inv and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv, ammo_id) end)) or r_b4) or r_b4 end
        -- Reserve nur manuell ziehen wenn der genutzte Pfad sie NICHT selbst gezogen hat.
        if read_rsv() >= r_b4 and inv and ammo_id then _G.__re4_safe_reduce(inv, ammo_id, gained) end
    end
end

local function clear_rack()
    -- [EMPTY-RELOAD SLIDE] War's der _08-Lade-Slide? -> _08 nach vorn (rest) schnappen + Modus beenden
    -- (danach wieder normaler Pump). Vor dem _01-Handling, damit es unabhaengig von ENGINE_CLOSES_SLIDE laeuft.
    local was_er = rack.empty_reload
    rack.empty_reload = false
    if was_er and wep.slide_joint2 then
        local cur = sc(wep.slide_joint2, "get_LocalPosition")
        if cur then
            local sp2 = slide_pose2(wep.wid or 0)
            pcall(function() wep.slide_joint2:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp2.rest_z)) end)
        end
    end
    rack.needs = false
    _G.__re4_needs_who = "2117(false)"   -- [NEEDS-DIAG 2026-07-20] wer aendert den Rack-Zwang?
    rack.grab_active = false
    rack.pulled = false
    rack.pushed = false
    rack.frac = 0
    _G.__vr_needs_rack = false
    _G.__vr_block_fire_when_empty = false
    _G.__re4_bf_who = "re4_vr_reload4_dlc.lua:2122"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    _G.__vr_rack_block_left_knife = false
    -- [KAMMER-RUECKHALT] Rack ausgefuehrt -> zurueckgehaltene Ladung zurueck in die Waffe.
    _G.__re4_gun_release_hold()
    -- [GUN_STATE] Engine aus AmmoEmpty holen (Patrone gechambert) -> rack.empty wird false.
    gun_chamber()
    -- [ENGINE_CLOSES_SLIDE] Bei diesen Waffen schliesst die Engine den Slide selbst -> wir forcen
    -- NICHTS (kein _chambered_hold, kein rest_z-Snap). Das Gate in apply_slide_park gibt dann im
    -- Ruhezustand zurueck -> Engine kontrolliert den Slide.
    if ENGINE_CLOSES_SLIDE[wep.wid] then
        rack._chambered_hold = false
        _G.__re4_ch_who = "2215(false)"   -- [CH-DIAG 2026-07-20] wer setzt den Slide-Halt?
        rack._prev_gun_ammo = nil
        return
    end
    if ROTARY_CYCLE[wep.wid] then   -- [ROTARY_CYCLE] kein Position-Snap/Chamber-Hold (joint_01 dreht, kein Z)
        rack._chambered_hold = false
        _G.__re4_ch_who = "2220(false)"   -- [CH-DIAG 2026-07-20] wer setzt den Slide-Halt?
        rack._prev_gun_ammo = nil
        return
    end
    -- [CHAMBER_HOLD] Slide ab jetzt auf ZU halten (Engine spielt die Schliess-Anim nach unserem
    -- manuellen Reload nicht). Wird beim ersten Schuss geloescht (dann uebernimmt die Engine).
    rack._chambered_hold = true
    _G.__re4_ch_who = "2226(true)"   -- [CH-DIAG 2026-07-20] wer setzt den Slide-Halt?
    rack._prev_gun_ammo = nil   -- frischer Schuss-Vergleich
    -- Slide nach dem Rack auf rest_z (vorne/gechambert) schnappen (Sofort-Effekt; Engine zieht nach).
    if wep.slide_joint then
        local cur = sc(wep.slide_joint, "get_LocalPosition")
        if cur then
            local sp = slide_pose(wep.wid or 0)
            pcall(function() wep.slide_joint:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp.rest_z)) end)
        end
    end
end

-- Empty-Detect + Block-Globals pflegen
-- [DIAG 2026-07-21 ENTFERNT] Hier stand __re4_rack_joint_watch (ZUSTAND/CHHOLD/JOINT-Logs nach
-- re4_rack_diag.log + die __re4_dbg_*-Globals; beides am 2026-08-15 entfernt). Reine Diagnose,
-- kein Verhalten. Original: others/re4_vr_reload4_dlc.bak_2026-07-21_pre_diagclean.

local function update_rack_state()
    if rack.tuning then return end   -- UI-Vorschau: Live-Logik aussetzen
    if TOP_LOADER[wep.wid] then
        -- [TOP_LOADER] kein Slide-Rack. Chamber-Blend einmal pro Frame Richtung Ziel rampen
        -- (open=1, zu=0) -> apply_chamber zeichnet die smoothstep-Kurve. Feuern sperren solange offen.
        local target = chamber.open and 1.0 or 0.0
        if chamber.blend < target then chamber.blend = math.min(target, chamber.blend + CHAMBER_BLEND_SPEED)
        elseif chamber.blend > target then chamber.blend = math.max(target, chamber.blend - CHAMBER_BLEND_SPEED) end
        _G.__vr_block_fire_when_empty = chamber.open and true or false
        _G.__re4_bf_who = "re4_vr_reload4_dlc.lua:2162"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
        return
    end
    if handled() == nil then         -- nur an "Manual Pistol Reload" gekoppelt, kein Extra-Toggle
        rack.empty = false
        if rack.needs or _G.__vr_block_fire_when_empty then clear_rack() end
        return
    end
    local loaded   = live_loaded_count()
    local flow_active = not mag_is_present()   -- Drop/in-Hand/Insert laeuft gerade
    local is_empty = (type(loaded) == "number") and loaded <= 0   -- frischer Engine-Read
    rack.has_mag   = (type(loaded) == "number" and loaded > 0)
    -- [EMPTY_SLIDE] Slide-Trigger = Waffe LEER. Quelle = ENGINE Gun.CurrentState==AmmoEmpty
    -- (zuverlaessig!), NICHT der kaputte Ammo-Zaehler (las nach dem Reload falsch 0 -> Slide
    -- blieb auf MITTEL statt zu). Nach dem Rack setzt gun_chamber Holding -> nicht mehr leer.
    -- [EMPTY_SLIDE] Slide auf MITTEL (halb hinten) SOFORT bei 0 Ammo -> game-eigenes
    -- isGunAmmoEmpty (greift auch im IgnoreClerMask-Zwischenstate, anders als State==AmmoEmpty).
    -- Nach dem Reload wieder false -> kein Konflikt mit dem Nach-Rack-Schliess-Halt.
    local pe_e = get_pe()
    rack.empty = (pe_e and safe(function() return pe_e:call("isGunAmmoEmpty") end)) == true
    -- [RIOT GUN SELF-HEAL 2026-07-17 "was passiert wenn wir beim Nachladen staggered werden"] Bei
    -- NO_RELOAD_CYCLE (Riot Gun) ist der Rack NUR noetig, solange die Gun nach dem 0-Reload UN-gechambert
    -- bleibt (isGunAmmoEmpty=true). Ist sie feuerbereit (rack.empty=false) -- weil ein Stagger/Engine-Event
    -- zwischendrin gechambert hat ODER empty_reload faelschlich gelatcht war -- dann ist KEIN Rack noetig:
    -- den sticky Latch loesen, sonst bleibt "kann schiessen UND Hand will ans Rack" haengen. Feuert genau
    -- einmal (danach empty_reload=false). Der ECHTE 0-Reload haelt rack.empty=true bis zur Rack-Geste -> hier
    -- NICHT vorzeitig geloescht. NUR die Riot Gun (NO_RELOAD_CYCLE); alle anderen Shotguns unberuehrt.
    -- [RACK IST PFLICHT nach 0-Reload 2026-07-17 "auf 0 + nachladen = Slide-Rack Pflicht"] Der fruehere
    -- Self-Heal (loeschte rack.needs, sobald die Engine die Riot Gun beim Reload chamberte -> rack.empty=false)
    -- ist RAUS. Er nahm faelschlich auch den gewollten Leer-Reload-Rack weg. Jetzt bleibt der Rack Pflicht,
    -- bis die Rack-Geste (clear_rack) ihn loest. (Damit ist die alte Stagger-beim-Nachladen-Heilung entfernt.)
    -- [CHAMBER_HOLD] Schuss erkennen (echte Gun-Ammo SINKT) -> Nach-Rack-Halt loesen, ab dann
    -- spielt die Engine die Slide-Anim selbst. getCurrentGunAmmo ist zuverlaessig (kein Cache).
    if rack._chambered_hold then
        local ga = pe_e and tonumber(safe(function() return pe_e:call("getCurrentGunAmmo") end))
        if CHAMBER_HOLD_PERSIST[wep.wid] then
            -- [CHAMBER_HOLD_PERSIST] NICHT beim Schuss loesen -> Slide bleibt zu, bis die Waffe
            -- leer ist (rack.empty oben aus isGunAmmoEmpty). Dann normaler Leer-Slide (park_z).
            if rack.empty then rack._chambered_hold = false end
        else
            if ga and rack._prev_gun_ammo and ga < rack._prev_gun_ammo then rack._chambered_hold = false end
        end
        rack._prev_gun_ammo = ga
    end
    -- needs_rack wird hier NICHT abgeleitet (das war der Fehler). Es wird beim Insert
    -- gelatcht (nur wenn vorher leer) und NUR durch die Rack-Geste geclear't -> sticky,
    -- ueberlebt das Nachladen. Genau RE9. Geclear't ausserdem bei Waffenwechsel/Reset.
    -- [SHOTGUN] Nach JEDEM Schuss ist ein Pump noetig. Schuss = __vr_shot_seq steigt (crosshair-Hook).
    -- Nur Shotgun; Pistolen unberuehrt. Setzt needs_pump -> naechster Pump = noetig (kein Gimmick).
    if is_shotgun(wep.wid) then
        local seq = tonumber(rawget(_G, "__vr_shot_seq")) or 0
        -- [SHOTGUN] Pump nach Schuss NUR wenn danach noch Munition in der Kammer ist (rack.has_mag).
        -- Hat der Schuss auf 0 geleert -> KEIN Pump (man chambert keine leere Kammer; jetzt wird
        -- nachgeladen). Sonst haengt ein unmoeglicher Pump bei 0 -> wirkt wie ein Soft-Lock.
        -- [NO_CYCLE_AFTER_SHOT] Striker: kein Cycle nach dem Schuss (frei ballern bis 0); nur beim Laden.
        if rack._prev_shot_seq and seq > rack._prev_shot_seq and rack.has_mag and not NO_CYCLE_AFTER_SHOT[wep.wid] then rack.needs = true end
        rack._prev_shot_seq = seq
    end
    -- [SHOTGUN] needs_rack pre-empted in motion die Support-Hand (undockt sie sofort). Bei der Shotgun
    -- soll die Hand im Pump-Fenster (nach Schuss) AUF dem Vordergriff bleiben (Two-Hand-IK) -> daher
    -- needs_rack hier NICHT melden. Der echte Pump undockt ohnehin via slide_dock_blend (grab_active).
    -- Andere Waffen: needs_rack lenkt die linke Hand wie gehabt an den Slide.
    _G.__vr_needs_rack             = rack.needs and not is_shotgun(wep.wid)
    -- [IK-GATE] Slide-Rack-Grab aktiv -> motion sperrt die Two-Hand-IK (sonst dreht ein bereits
    -- gehaltener rechter Grip die Waffe waehrend des Rackens). Erst nach Rack-Ende wieder IK.
    _G.__vr_slide_rack_active      = rack.grab_active == true
    -- [PUMP_NO_Z 2026-08-13] Fehlte hier komplett: motion.lua sperrt anhand dieses Flags waehrend des
    -- Pumps die Waffen-Laengsachse (und X), damit die Waffe nicht zum Koerper wandert. Leons Shotguns
    -- setzen es seit jeher (re4_vr_reload.lua:3799), Adas Sawed-off lief ohne -- also ohne Stabilisierung
    -- im Pump-Fenster. Bewusst direkt neben dem autoritativen slide_rack_active-Write, damit es nicht
    -- auf true haengen bleiben kann.
    _G.__vr_shotgun_pump_active    = (rack.grab_active and wep.wid and is_shotgun(wep.wid)) == true
    -- Feuern gesperrt wenn: Rack noetig ODER Mag physisch draussen (mag_out, bis nachgeladen)
    -- ODER gerade ein Flow laeuft ODER die Waffe LEER ist (loaded<=0, frisch aus der Engine).
    -- mag_out + is_empty heilen ueber loaded>0 -> kein Dauer-Block nach echtem Reload.
    if BREAK_ACTION[wep.wid] then
        -- [SKULL SHAKER] Block/Dry-Fire wenn leer ODER Cock aussteht (rack.needs nach Schuss) ODER Hebel OFFEN
        -- (solange aufgeklappt = nicht schiessbar, bis wieder zu). Cock/Close (clear_rack) hebt rack.needs auf.
        -- [LIVE-EMPTY] rack.empty = pe:isGunAmmoEmpty (jeden Frame frisch, KEIN Cache), statt is_empty
        -- (live_loaded_count -> gecachtes __re4_live_wi, nach Save-Load stale 0 -> Fehl-Dry-Fire).
        _G.__vr_block_fire_when_empty = rack.empty or rack.needs or (rawget(_G, "__vr_break_open") == true)
        _G.__re4_bf_who = "re4_vr_reload4_dlc.lua:2236"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    elseif DRYFIRE_ONLY_WHEN_EMPTY[wep.wid] then
        -- [STRIKER] Block/Dry-Fire wenn leer ODER ein Cycle aussteht (rack.needs nach JEDER nachgelegten
        -- Shell) -> RT gesperrt BIS am Schalter gedreht wurde (clear_rack loescht needs).
        -- KEIN flow_active/mag_out-Block (Drum = Fehl-Block) und kein after-shot-Block (NO_CYCLE_AFTER_SHOT).
        -- [LIVE-EMPTY] rack.empty statt is_empty (kein Cache).
        _G.__vr_block_fire_when_empty = rack.empty or rack.needs
        _G.__re4_bf_who = "re4_vr_reload4_dlc.lua:2242"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    else
        -- [LIVE-EMPTY 2026-07-08] Grundregel: die Engine entscheidet ueber "kann nicht feuern" via rack.empty
        -- (pe:isGunAmmoEmpty, frisch). Bei den meisten Waffen bleibt die Gun bis zur Rack-Geste in AmmoEmpty.
        -- [RIOT GUN RACK-PFLICHT 2026-07-17 "auf 0 + nachladen = Slide-Rack Pflicht"] AUSNAHME: die Riot
        -- Gun (NO_RELOAD_CYCLE) ist semi-auto -> die Engine CHAMBERT beim 0-Reload sofort (isGunAmmoEmpty=false)
        -- -> rack.empty allein blockt NICHT -> man konnte ohne Rack weiterballern. Darum zusaetzlich den sticky
        -- Empty-Reload-Latch: nach 0 + Nachladen bleibt Feuern gesperrt, bis der _08-Slide-Rack (clear_rack ->
        -- empty_reload=false) gezogen wurde. Genau wie bei den anderen Waffen.
        -- [RACK-ZWANG 2026-07-20 -- per Log BEWIESEN] rack.needs FEHLTE hier. Ablauf laut
        -- re4_rack_diag.log: leergeschossen -> DROP fresh_ga=0 -> empty_when_dropped=true -> INSERT setzt
        -- rack.needs=true (Z.~1506) -- aber diese Zeile fragt needs gar nicht ab. Der native Reload
        -- chambert die Waffe (isGunAmmoEmpty=false) -> rack.empty=false -> Block faellt weg -> man konnte
        -- nach dem Nachladen OHNE Slide-Rack weiterfeuern. needs ist der sticky Latch, der erst durch die
        -- Rack-Geste (clear_rack) faellt -- genau das gewuenschte Verhalten.
        -- UNGEFAEHRLICH fuer Pistolen: needs wird nach einem SCHUSS nur im is_shotgun-Zweig gesetzt
        -- (Z.~2223), bei Pistolen also ausschliesslich beim 0-Reload.
        _G.__vr_block_fire_when_empty  = rack.empty or rack.needs or mag_out or flow_active
            or (NO_RELOAD_CYCLE[wep.wid] and rack.empty_reload)
        -- [RACK-ZWANG HART] Solange ein Rack aussteht: die Engine im Leer-Zustand halten. Ohne das feuert
        -- sie am Binding vorbei weiter (und zieht bei Trigger auf leer den Quick-Knife). Faellt automatisch
        -- weg, sobald clear_rack rack.needs loescht -> dann chambert gun_chamber wie gehabt.
        -- [STILLGELEGT 2026-07-20] Kammer-Rueckhalt/AmmoEmpty-Halten sind BEIDE gescheitert:
        -- der Zustand wird von der Engine jeden Frame ueberschrieben, und eine echt leere Kammer
        -- provoziert den Quick-Knife (Messer zuckt bei gedruecktem Trigger hervor). Aufruf deaktiviert.
        -- if rack.needs and not mag_out and not flow_active then _G.__re4_gun_hold_empty end
        _G.__re4_bf_who = "re4_vr_reload4_dlc.lua:2251"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    end
    _G.__vr_rack_block_left_knife  = rack.needs   -- linker Grip frei fuer Slide-Grab (Messer aus)
end

-- Linker Grip (vrmod, wie der Holster). Liefert (gedrueckt, left_joystick).
-- 1:1 aus re9_vr_reload.lua get_left_grip_pressed: left_joystick JEDEN Aufruf frisch
-- holen (nicht cachen -> wird sonst stale -> is_action_active schlaegt fehl).
local function left_grip_down()
    if not vrmod then return false end
    -- [STALE_HANDLE_FIX] Action-Handle UND Joystick JEDEN Frame frisch holen (nicht cachen): nach
    -- Save-Load/Szenenwechsel geht das gecachte Grip-Handle stale -> is_action_active lautlos false
    -- -> Pump-Grab tot bis Reset. Frisch holen heilt sich in-place. [[project-re4-vr-mag-holster-stale-grip]]
    local act, lj
    pcall(function() act = vrmod:get_action_grip() end)
    pcall(function() lj  = vrmod:get_left_joystick() end)
    if not act or not lj then return false end
    local ok, v = pcall(function() return vrmod:is_action_active(act, lj) end)
    return ok and v == true
end

-- [ROTARY_CYCLE] Linker Trigger (vrmod weapon_dial-Action, wie motion is_left_trigger_held). Nur LESEN,
-- normale Funktion bleibt. Handle jeden Frame frisch (Stale-Handle-Fix wie beim Grip).
local function left_trigger_down()
    if not vrmod then return false end
    local ok, v = pcall(function()
        local act = vrmod:get_action_weapon_dial()
        local lj  = vrmod:get_left_joystick()
        if not (act and lj) then return false end
        return vrmod:is_action_active(act, lj)
    end)
    return ok and v == true
end

-- [BREAK_ACTION] Pitch des LINKEN Controllers in Grad (forward.y-Winkel). Runterkippen -> sinkt.
-- Treibt den Klapphebel (joint_02). Handle jeden Frame frisch.
local function left_ctrl_pitch_deg()
    if not vrmod then return nil end
    local ok, p = pcall(function()
        local cs = vrmod:get_controllers(); if not cs or #cs < 1 then return nil end
        local q = vrmod:get_rotation(cs[1]); q = q and q:to_quat()
        if not q then return nil end
        local f = q * Vector3f.new(0, 0, 1)
        local y = f.y; if y > 1 then y = 1 elseif y < -1 then y = -1 end
        return math.deg(math.asin(y))
    end)
    return ok and p or nil
end

-- Linke CONTROLLER-Welt-Position (1:1 aus RE9 SD.get_left_controller_pos). WICHTIG:
-- fuer Grab-Distanz UND Zug den Controller nehmen, NICHT den L_Hand-Bone — der wird
-- beim Dock an den Slide gepinnt, sonst waere die Zug-Bewegung immer null.
local function get_left_controller_pos()
    if not vrmod then return nil end
    local ok, pos = pcall(function()
        local controllers = vrmod:get_controllers()
        if not controllers or #controllers < 1 then return nil end
        return vrmod:get_position(controllers[1])
    end)
    return ok and pos or nil
end

-- Rack-Geste (RE9-Verfahren): linke Hand am Slide + LINKER GRIP greift -> Grip
-- HALTEN und ganz nach hinten ziehen (Slide folgt via frac) -> Grip LOSLASSEN = fertig.
-- "armed": Grip muss einmal losgelassen worden sein, bevor neu gegriffen werden kann.
local function update_rack_gesture()
    if rack.tuning then return end   -- UI-Vorschau: Geste aussetzen
    if ROTARY_CYCLE[wep.wid] or BREAK_ACTION[wep.wid] then return end   -- [ROTARY/BREAK] eigener Pfad, kein Pull-Rack
    -- [SHOTGUN PUMP-FENSTER] Pump (= Slide-Grab am Schaft) NUR wenn rack.needs -> d.h. einmal nach
    -- jedem Schuss (shot_seq, s.u.) oder nach einer Shell-Reload. AUSSERHALB des Fensters racket die
    -- Shotgun NICHT -> der linke Grip am Schaft ist frei fuer Two-Hand-IK (motion). Gilt jetzt fuer
    -- ALLE Waffen gleich (kein is_shotgun-Sonderfall mehr = "immer pumpbar" war der Two-Hand-Killer).
    if not rack.needs then
        rack.grab_active = false; rack.pulled = false; rack.pushed = false; rack.frac = 0; rack.armed = false
        rack._pump_ref_z = nil; rack._pump_init_dist = nil   -- [SHOTGUN] Pull-to-Pump-Referenzen frisch fuers naechste Fenster
        _G.__re4_rack_dbg = "kein Rack noetig (needs=false)"
        rack._last_grip = false; rack._last_dist = -1; return
    end
    if not wep.slide_joint or (rack.empty_reload and not wep.slide_joint2) then refresh_weapon() end
    local sj  = rack_joint()   -- [EMPTY-RELOAD SLIDE] _08 im Empty-Reload-Modus, sonst _01 (Pump/Slide)
    -- Linke Hand-WELT-Ziel (motion, Controller-getrieben, GAME-WORLD) fuer Grab-Distanz + Zug.
    -- NICHT der L_Hand-Bone (wird beim Dock an den Slide gepinnt -> Zug=0) und NICHT
    -- der vrmod-Controller (anderer Koordinatenraum -> dist=129!). Dieses Global setzt
    -- motion VOR dem IK -> vom Dock unberuehrt -> bewegt sich frei mit dem Controller.
    -- [SHOTGUN] rohe un-gedockte Hand (__vr_lh_ctrl_world): noetig fuer den nahtlosen Pull-to-Pump
    -- aus der Two-Hand-Haltung (sonst gepinnt = Zug 0). Andere Waffen wie gehabt.
    local hp
    if is_shotgun(wep.wid) then
        hp = rawget(_G, "__vr_lh_ctrl_world") or rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
    else
        hp = rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
    end
    if not hp then local lh = get_left_hand(); hp = lh and sc(lh, "get_Position") end
    local sp  = sj and sc(sj, "get_Position")
    local grip = left_grip_down()
    rack._last_grip = grip
    rack._dbg_hp = hp   -- [PUMP_DIAG] gelesene Hand-Welt (muss sich beim Ziehen bewegen, sonst Deadlock)
    rack._last_dist = (hp and sp) and math.sqrt((hp.x-sp.x)^2 + (hp.y-sp.y)^2 + (hp.z-sp.z)^2) or -1
    -- [RACK-DIAG IM MONITOR-DUMP 2026-07-21, "Sliderack steht an, alles geht, aber er registriert
    -- meine Controllerbewegung nicht"] Reine VEROEFFENTLICHUNG der ohnehin gefuehrten Werte -- kein Log,
    -- keine Verhaltensaenderung. #Monitor.lua schreibt sie in den Dump, damit im Fall der Faelle
    -- ablesbar ist, WORAN der Grab scheitert: armed=false -> der linke Grip wurde nie losgelassen
    -- (Scharfmachen fehlt); dist > grab_dist -> Hand zu weit vom Slide-Joint.
    _G.__re4_rack_dbg = string.format("needs=%s armed=%s grab=%s grip=%s dist=%.3f (max %.3f) wid=%s",
        tostring(rack.needs), tostring(rack.armed), tostring(rack.grab_active), tostring(grip),
        tonumber(rack._last_dist) or -1, tonumber(CFG.rack_grab_dist) or 0, tostring(wep.wid))
    if not (sj and hp and sp) then return end

    if not rack.grab_active then
        -- [RACK-LOCK] Kein Grab solange eine Patrone in der Hand ist (mag_hand.active) ODER gerade in die
        -- Kammer gleitet (mag_insert.active). Bei NICHT-Shotgun zusaetzlich 2s nach Ammo-Input sperren.
        -- Shotgun NICHT nach-sperren -> direkt nach Shell-Einlegen soll man pumpen koennen.
        -- [FIX] mag_insert.active war frueher NICHT mitgesperrt: beim leeren Nachladen (rack.needs=true)
        -- greift die linke Hand direkt am Slide waehrend der Insert-Animation -> die Rack-Geste startete
        -- MITTEN im Insert und zog den Slide auf back_z ("viel zu weit hinten"). Der _ammo_input_t-Lock
        -- greift erst NACH Insert-Ende (zu spaet). Waehrend eine Patrone in die Kammer gleitet, darf nie
        -- gerackt werden -> beide Phasen sperren.
        if mag_hand.active or mag_insert.active then rack.armed = false; rack._pump_ref_z = nil; return end
        if not is_shotgun(wep.wid) and rack._ammo_input_t and (os.clock() - rack._ammo_input_t) < 0.2 then
            rack.armed = false; return
        end

        if is_shotgun(wep.wid) and not rack.empty_reload then
            -- [SHOTGUN PULL-TO-PUMP] Nahtlos aus der Two-Hand-Haltung: KEIN Grip-Release noetig. Bedingung:
            -- Grip gehalten + Hand am Schaft (Naehe) + echter RUECKWAERTS-Zug. Erst der Zug startet den Pump
            -- (vorher bleibt Two-Hand-IK aktiv). Zug GUN-RELATIV gemessen (Hand-Z im Slide-Frame) -> immun
            -- gegen Waffen-Bewegung/-Drehung. Referenz = vorderster Punkt; Pull = Rueckweichung davon.
            if grip and rack._last_dist >= 0 and rack._last_dist <= CFG.rack_grab_dist then
                local srot = sc(sj, "get_Rotation")
                local rel  = srot and safe(function() return srot:conjugate() * Vector3f.new(hp.x - sp.x, hp.y - sp.y, hp.z - sp.z) end)
                local cz   = rel and rel.z or 0
                -- [RE9_PUMP 2026-08-13] Ausloeser = Annaeherung der beiden HAENDE, exakt wie bei Leons
                -- Shotguns (re4_vr_reload.lua:4002). Der alte gun-relative Zug hing an der Waffe und
                -- koppelte damit zurueck auf PUMP_NO_Z/X, auf das Laufen und auf die Controller-Richtung.
                -- Selbstnachziehend: waechst der Abstand, wandert die Referenz mit -- man darf in Ruhe
                -- an den Schaft greifen. Der gun-relative Anker bleibt als Fallback erhalten.
                local rhp = rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
                local dist_now = rhp and math.sqrt((hp.x-rhp.x)^2 + (hp.y-rhp.y)^2 + (hp.z-rhp.z)^2) or nil
                if dist_now and not rack._pump_init_dist then rack._pump_init_dist = dist_now end
                local pull = 0
                if dist_now and rack._pump_init_dist then
                    pull = rack._pump_init_dist - dist_now
                    if pull < 0 then rack._pump_init_dist = dist_now; pull = 0 end
                end
                if pull > (CFG.pump_start_pull or 0.04) then
                    rack.grab_active = true; rack.armed = false; rack.pulled = false; rack.pushed = false; rack.frac = 0
                    rack.gx, rack.gy, rack.gz = hp.x, hp.y, hp.z   -- Anker = jetzt -> frac startet bei 0 (kein Sprung)
                    -- [LAUFEN 2026-08-12] Zweiter Anker: die Waffenhand. Ohne ihn steckt die Fortbewegung im Zug
                    -- (Gehen/Drehen bewegt BEIDE Haende) und der Slide ging nur im Stand.
                    do local _rhr = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos"); rack.rgx, rack.rgy, rack.rgz = _rhr and _rhr.x or nil, _rhr and _rhr.y or nil, _rhr and _rhr.z or nil end
                    rack.g_relz = cz   -- [PUMP] gun-relativer Z-Anker (nur noch Fallback)
                    -- [RE9_PUMP] Handabstand JETZT als Nullpunkt einfrieren + Maximum zuruecksetzen.
                    rack._pump_init_dist = dist_now
                    rack._pump_max = 0
                    rack._pump_ref_z = nil
                    rack_haptic(0.25, 0.03)
                    rack.pump_off = nil
                    local shp = rawget(_G, "__vr_support_hand_world_pos")
                    if shp then
                        local d = Vector3f.new(shp.x - sp.x, shp.y - sp.y, shp.z - sp.z)
                        local inv = srot and safe(function() return srot:conjugate() end)
                        rack.pump_off = (inv and safe(function() return inv * d end)) or d
                    end
                end
            else
                rack._pump_ref_z = nil; rack._pump_init_dist = nil   -- Hand weg vom Schaft / Grip los -> Referenzen reset
            end
            return
        end

        -- Nicht-Shotgun ODER Shotgun-Empty-Reload (_08-Lade-Slide): Release-arm + Proximity-Grab,
        -- pistolen-artig (ziehen -> loslassen -> schnappt vor -> chambert). Grip einmal loslassen = scharf.
        if not grip then rack.armed = true; return end   -- Grip erst loslassen -> scharf
        if not rack.armed then return end
        if (rack._last_dist >= 0) and (rack._last_dist <= CFG.rack_grab_dist) then
            rack.grab_active = true
            rack.armed = false
            rack.pulled = false
            rack.pushed = false
            rack.frac = 0
            -- [ROHER CONTROLLER 2026-07-20] Anker aus der UNGEDOCKTEN Hand (__vr_lh_ctrl_world,
            -- von motion VOR dem IK publiziert). hp ist die GEDOCKTE Hand -- sobald der Rack-Dock
            -- greift, ist sie unsere eigene Vorgabe und der Zug wuerde sich selbst messen (Zug 0 /
            -- snappy). NUR Anker und Zug -- Naehe-Pruefung, _last_dist und Pose-Distanz bleiben auf hp.
            local hpr = rawget(_G, "__vr_lh_ctrl_world") or hp
            rack.gx, rack.gy, rack.gz = hpr.x, hpr.y, hpr.z
            -- [LAUFEN 2026-08-12] Zweiter Anker: die Waffenhand. Ohne ihn steckt die Fortbewegung im Zug
            -- (Gehen/Drehen bewegt BEIDE Haende) und der Slide ging nur im Stand.
            do local _rhr = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos"); rack.rgx, rack.rgy, rack.rgz = _rhr and _rhr.x or nil, _rhr and _rhr.y or nil, _rhr and _rhr.z or nil end
            -- [PUMP] gun-relativer Z-Anker (fuer Shotgun/_08 frac-Zug; Pistolen ignorieren ihn)
            local _srot = sc(sj, "get_Rotation")
            local _rel = _srot and safe(function() return _srot:conjugate() * Vector3f.new(hp.x - sp.x, hp.y - sp.y, hp.z - sp.z) end)
            rack.g_relz = _rel and _rel.z or nil
            -- [RACK_POSE_ANGLE 2026-07-31] Annaeherungsrichtung der Hand EINMAL beim Greifen
            -- bestimmen (0 Grad = von hinten, 90 Grad = von der Seite; |x| -> seitenneutral, Y egal)
            -- und bis zum Loslassen halten. Nur Pistolen werten es aus (s. apply_rack_hand_pose).
            -- [POSE2_OFFSETS 2026-08-06] Im Einstellmodus (dock_tune) NICHT neu bestimmen -- sonst reisst
            -- der naechste Greifvorgang die Vorschau-Auswahl aus der UI wieder weg.
            rack.pose_side = rack.dock_tune and rack.pose_side or false
            if _rel and not rack.dock_tune then
                local _at2 = math.atan2 or math.atan
                local _ang = math.deg(_at2(math.abs(_rel.x or 0), -(_rel.z or 0)))
                rack.pose_side = _ang >= (tonumber(CFG.rack_pose_side_deg) or 45)
                rack._pose_ang = _ang   -- nur Anzeige im UI
                -- [RACK_DBG] Winkel + Entscheidung fuer den Wegwerf-Dump (re4_zzz_now_dump.lua)
                _G.__re4_rack_pose_dbg = string.format("wid=%s ang=%.1f schwelle=%s -> %s",
                    tostring(wep.wid), _ang, tostring(CFG.rack_pose_side_deg),
                    rack.pose_side and "SEITLICH" or "hinten")
            end
            rack_haptic(0.25, 0.03)
            rack.pump_off = nil
        end
        return
    end

    -- gegriffen + Grip gehalten -> Slide folgt dem RUECKWAERTS-Zug entlang der Gun-Achse.
    if grip then
        local sp_pose = rack_slide_pose()   -- [EMPTY-RELOAD SLIDE] _08-Travel im Empty-Reload, sonst _01
        local travel = math.max(math.abs(sp_pose.back_z - sp_pose.park_z), 0.005)   -- Slide-Travel = Zieh-Weg (1:1)
        local pull
        if is_shotgun(wep.wid) and rack._pump_init_dist then
            -- [RE9_PUMP 2026-08-13] Zug = Annaeherung der beiden HAENDE (RE9-Modell, wie reload.lua:4103).
            -- Kein Waffen-, Welt- oder Achsenbezug -> immun gegen PUMP_NO_Z/X, gegen Laufen und gegen
            -- die Controller-Richtung.
            local rhp = rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
            local hpr = rawget(_G, "__vr_lh_ctrl_world") or hp
            if rhp then
                local dist_now = math.sqrt((hpr.x-rhp.x)^2 + (hpr.y-rhp.y)^2 + (hpr.z-rhp.z)^2)
                pull = rack._pump_init_dist - dist_now
                if not rack.pulled and pull < 0 then
                    rack._pump_init_dist = dist_now; pull = 0; rack._pump_max = 0
                end
                if pull < 0 then pull = 0 end
                if (rack._pump_max or 0) < pull then rack._pump_max = pull end
            else
                pull = 0
            end
        elseif is_shotgun(wep.wid) then
            -- FALLBACK (kein Handabstand messbar): wie frueher gun-relativ.
            -- [PUMP] Zug GUN-RELATIV messen: Hand-Z im Slide-Frame (cz) gegen den beim Greifen
            -- gemerkten Anker (g_relz). Dreht sich die Waffe beim Ziehen, springt eine WELT-Projektion
            -- (frac-Gehuepfe -> Pump klemmt, bes. geradeaus). Gun-relativ ist orientierungsunabhaengig.
            local srot = sc(sj, "get_Rotation")
            local spos = sc(sj, "get_Position")
            local cz
            if srot and spos then
                local rel = safe(function() return srot:conjugate() * Vector3f.new(hp.x-spos.x, hp.y-spos.y, hp.z-spos.z) end)
                cz = rel and rel.z
            end
            if cz and rack.g_relz then
                pull = rack.g_relz - cz   -- nach hinten gezogen -> cz sinkt -> pull steigt
                if pull < 0 then pull = 0 end
            else
                pull = 0
            end
        else
            -- Nicht-Shotgun: Welt-Projektion der Controller-Verschiebung auf die Slide-Rueckwaerts-Achse.
            -- [ROHER CONTROLLER] gegen denselben ungedockten Bezug wie der Anker (s. oben).
            local hpr = rawget(_G, "__vr_lh_ctrl_world") or hp
            local px, py, pz = hpr.x - rack.gx, hpr.y - rack.gy, hpr.z - rack.gz
            -- [LAUFEN 2026-08-12] Bewegung der Waffenhand abziehen -> uebrig bleibt die Bewegung der
            -- Ziehhand GEGEN die Waffe. Rueckbau: _G.__re4_rack_relative = false
            if rack.rgx and rawget(_G, "__re4_rack_relative") ~= false then
                local _rhn = rawget(_G, "__vr_rh_ctrl_raw") or rawget(_G, "__vr_rh_world") or rawget(_G, "__vr_unified_rh_pos")
                if _rhn then px = px - (_rhn.x - rack.rgx); py = py - (_rhn.y - rack.rgy); pz = pz - (_rhn.z - rack.rgz) end
            end
            local srot = sc(sj, "get_Rotation")
            local bd = srot and safe(function() return srot * Vector3f.new(0, 0, -1) end)
            if bd then
                local bl = math.sqrt(bd.x*bd.x + bd.y*bd.y + bd.z*bd.z)
                if bl > 1e-6 then bd = Vector3f.new(bd.x/bl, bd.y/bl, bd.z/bl) end
                pull = px*bd.x + py*bd.y + pz*bd.z
                if pull < 0 then pull = 0 end
            else
                pull = math.sqrt(px*px + py*py + pz*pz)
            end
        end
        local f = pull / travel
        rack.frac = (f > 1.0) and 1.0 or f
        if rack.frac >= 1.0 and not rack.pulled then
            rack.pulled = true
            -- [SND] Slide-Sound beim Zurueckziehen (voll hinten). Pistolen: 2. Sound (vor) beim
            -- Loslassen/Snap. Shotgun: 2. Sound beim Nach-vorn-Schieben (siehe unten, RE9-Modell).
            play_weapon_sound(snd("slide_back"))
            if is_shotgun(wep.wid) then queue_haptic(0.95, 0.07) end   -- [SHOTGUN PUMP] Haptik HIN (delaybar, 2. Puls beim Vorschieben)
        end
        -- [SHOTGUN PUMP] RE9-Pump-Modell (re9_vr_weapons.lua): nach vollem Zug wieder nach VORN
        -- geschoben (frac faellt zurueck) -> HER-Sound + Zyklus fertig, OHNE Loslassen. Nur Shotgun;
        -- Pistolen behalten Snap-on-Release (unten). frac<=0.15 = praktisch wieder vorn/gechambert.
        if is_shotgun(wep.wid) and not rack.empty_reload and rack.pulled and not rack.pushed and rack.frac <= 0.15 then
            rack.pushed = true
            play_weapon_sound(snd("slide_back"))    -- HER: nach vorne gepumpt
            queue_haptic(0.95, 0.07)                 -- [SHOTGUN PUMP] Haptik ZURUECK (delaybar)
            if rack.needs then clear_rack() end   -- noetiger Pump: chambern + Empty-Block weg
            -- [SHOTGUN PUMP] Grab BEHALTEN (clear_rack setzt es false) + Zyklus zuruecksetzen ->
            -- ohne Loslassen direkt weiterpumpen (auch nahtlos vom noetigen in den Spass-Pump).
            rack.grab_active = true
            rack.pulled = false
            rack.pushed = false
            rack._pump_max = 0           -- [RE9_PUMP] naechster Zug misst frisch
            rack._pump_init_dist = nil   -- (sonst blockiert die alte Referenz den Folgepump)
        end
        return
    end

    -- Grip losgelassen
    -- [RACKEV] Entscheidender Moment: war voll gezogen? wo steht der Slide? wird rest_z gesnappt?
    -- [log entfernt]
    if rack.pulled and not rack.pushed then
        -- voll gezogen, aber NICHT nach vorn gepumpt (Shotgun) bzw. Pistole losgelassen -> Snap nach
        -- vorn = HER-Sound. (Shotgun: hat er schon nach vorn gepumpt, lief der Sound oben + grab endete.)
        clear_rack()
        rack_haptic(0.95, 0.07)
        play_weapon_sound(snd("slide_back"))   -- [SND] Slide schnellt nach vorn
    else
        rack.grab_active = false; rack.frac = 0; rack.pulled = false; rack.pushed = false; rack.armed = true
    end
end

-- [ROTARY_CYCLE] Striker-Drehschalter: nach jeder geladenen Shell (rack.needs) am Schalter (Left Grip)
-- den Left Trigger druecken -> joint_01 dreht ~rz Grad (Animation hin+zurueck), Hand folgt (Dock+Pose),
-- am Peak clear_rack (chambert + rack.needs weg). Eine Drehung pro Shell. Nur ROTARY_CYCLE-Waffen.
local function update_rotary_cycle()
    if not ROTARY_CYCLE[wep.wid] then
        _G.__vr_block_two_hand = false; rotary._grip_latched = false; rotary._prev_grip = false; return
    end
    if rotary.preview then rack.grab_active = true; _G.__vr_block_two_hand = true; return end   -- UI-Tuning: Hand am Schalter, Two-Hand blocken
    local grip = left_grip_down()
    local trig = left_trigger_down()
    -- [SWITCH-GRIP-LATCH] Eine Grip-FLANKE waehrend ein Cycle noetig ist (rack.needs) gehoert dem
    -- Schalter -> diese Grip-Haltung blockt Two-Hand-IK (Schalter+Vordergriff liegen zu nah). Erst
    -- Loslassen + erneut Greifen erlaubt Two-Hand. Nur diese Waffe (Flag wird sonst nie true gesetzt).
    if grip and not rotary._prev_grip and rack.needs then rotary._grip_latched = true end
    if not grip then rotary._grip_latched = false end
    rotary._prev_grip = grip
    _G.__vr_block_two_hand = rotary._grip_latched == true
    -- Distanz Hand -> Drehschalter (joint_01) fuer den Greif-Gate (rohe un-gedockte Hand)
    local r = rotary_cfg(wep.wid)
    local hp = rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_unified_lh_pos") or rawget(_G, "__vr_lh_joint_pos")
    local sp = wep.slide_joint and sc(wep.slide_joint, "get_Position")
    rotary._last_dist = (hp and sp) and math.sqrt((hp.x-sp.x)^2 + (hp.y-sp.y)^2 + (hp.z-sp.z)^2) or -1
    local near = (rotary._last_dist >= 0) and (rotary._last_dist <= (r.grab_dist or 0.15))
    local at_switch = (rack.needs == true) and grip and near   -- am Schalter = Cycle noetig + Grip + nah genug
    if rotary.dir == 0 then rotary.prog = 0.0 end   -- [IDLE] keine Drehung aktiv -> prog auf 0 (sonst haengt es vom UI-Preview auf 1.0 fest)
    -- Trigger-FLANKE am Schalter -> eine Drehung starten (nur wenn gerade keine laeuft)
    if at_switch and trig and not rotary._prev_trig and rotary.dir == 0 and rotary.prog <= 0.0001 then
        rotary.dir = 1
        rack_haptic(0.30, 0.04)
        play_weapon_sound(snd("cycle"))   -- [STRIKER] Drehschalter-Dreh-Sound beim Start der Drehung
    end
    rotary._prev_trig = trig
    local SPD = r.lerp or 0.06   -- [STRIKER] Dreh-Lerp (per UI tunebar)
    if rotary.dir == 1 then
        rotary.prog = math.min(1.0, rotary.prog + SPD)
        if rotary.prog >= 1.0 then
            if rotary.pending then rotary.do_load(); rotary.pending = false end   -- [ROTARY_DEFER] Ammo (Ratio) kommt ERST hier, am Dreh-Peak -- nicht beim Insert
            clear_rack()                       -- Cycle fertig: chambert + rack.needs weg (Position-Snaps fuer ROTARY gegated)
            rotary.dir = -1                    -- zurueckdrehen (Dreh-Sound lief schon beim Start)
        end
    elseif rotary.dir == -1 then
        rotary.prog = math.max(0.0, rotary.prog - SPD)
        if rotary.prog <= 0.0 then rotary.dir = 0 end
    end
    -- Hand am Schalter halten (Dock + StrikerReload-Pose) solange am Schalter ODER waehrend der Drehung
    rack.grab_active = (at_switch or rotary.dir ~= 0) == true
end

-- [BREAK_ACTION] Skull Shaker Klapphebel (joint_02): RIGHT-B togglet auf/zu (gelerped). KEINE linke Hand.
-- Auf -> Reload (Shells holbar) + Fire blockiert. Voll zu -> Cock/Chamber (clear_rack). prog 0=zu..1=auf
-- treibt die Rotation in apply_slide_pass. Lerp = rotary_cfg.lerp.
local function update_break_action()
    if not BREAK_ACTION[wep.wid] then
        _G.__vr_break_open = false; break_st.open = false; break_st._was_open = false; return
    end
    if break_st.preview then _G.__vr_break_open = (break_st.prog > 0.15); return end   -- UI-Tuning: Slider treibt prog
    local r = rotary_cfg(wep.wid)
    -- RIGHT-B-FLANKE togglet auf/zu
    local b = right_b_down()
    if b and not break_st._prev_b then
        break_st.open = not break_st.open
        play_weapon_sound(snd("break_open"))   -- Klapp-Sound (auf/zu)
    end
    break_st._prev_b = b
    -- prog Richtung Ziel lerpen (auf=1, zu=0)
    local target = break_st.open and 1.0 or 0.0
    local SPD = r.lerp or 0.06
    if break_st.prog < target then
        break_st.prog = math.min(target, break_st.prog + SPD)
    elseif break_st.prog > target then
        break_st.prog = math.max(target, break_st.prog - SPD)
        if break_st.prog <= 0.0 and break_st._was_open then
            break_st._was_open = false
            if rack.needs then clear_rack() end                  -- voll zu = cocken/chambern
        end
    end
    if break_st.open then break_st._was_open = true end
    _G.__vr_break_open = (break_st.open or break_st.prog > 0.15) == true   -- offen -> Fire-Block + Shell-Insert
end

-- [BREAK_PUMP_SND] Nach JEDEM Schuss der Break-Action (wp6001) ein FESTES Cock-Fenster forcen:
-- __vr_pump_anim_active = true fuer SKULLSHAKER_PUMP_FORCE_DUR s, __vr_pump_anim_progress linear 0..1
-- darueber. Treibt Dreh-Loop (motion skullshaker_cock_spin), Cock-Pose (shakerloop) + die 2x Rack-Sounds.
-- WARUM geforct statt nativen "PumpAction"-Node lesen: die Engine spielt den Node nach einmal-leer-
-- geschossen + Reload NICHT mehr -> der Loop fiel aus. Geforct ueber die Schuss-Flanke (__vr_shot_seq,
-- crosshair-Hook) kommt er IMMER und in exakt gleicher Laenge.
local BREAK_PUMP_SND_ID = 3370013164
local SKULLSHAKER_PUMP_FORCE_DUR = 0.55   -- Cock-Fenster-Laenge (s): Dreh-Dauer (1 Umdrehung) + Sound-Sequenz
local _pumpsnd = { t0 = nil, prev_seq = nil, first_at = nil, second_at = nil }
local function update_break_pump_sound()
    if not BREAK_ACTION[wep.wid] then
        _pumpsnd.t0 = nil; _pumpsnd.prev_seq = nil; _pumpsnd.first_at = nil; _pumpsnd.second_at = nil
        _G.__vr_pump_anim_active = false; _G.__vr_pump_anim_progress = nil; return
    end
    local now = os.clock()
    -- Schuss-Flanke (globaler crosshair-Hook). Init ohne Trigger (prev_seq nil -> nur merken, nicht
    -- feuern -> kein Geister-Cock beim Equip, wenn der globale seq schon hochgezaehlt war).
    local seq = tonumber(rawget(_G, "__vr_shot_seq")) or 0
    if _pumpsnd.prev_seq == nil then
        _pumpsnd.prev_seq = seq
    elseif seq > _pumpsnd.prev_seq then
        _pumpsnd.prev_seq  = seq
        _pumpsnd.t0        = now          -- neues Cock-Fenster (Dreh + Pose); retriggert auch ein laufendes
        _pumpsnd.first_at  = now + 0.1    -- Sound-Sequenz pro Schuss neu planen (auch bei Ueberlappung)
        _pumpsnd.second_at = nil
    end
    -- Fenster-Status -> Dreh-Loop + Cock-Pose (motion liest beide Globals)
    if _pumpsnd.t0 and (now - _pumpsnd.t0) < SKULLSHAKER_PUMP_FORCE_DUR then
        _G.__vr_pump_anim_active   = true
        _G.__vr_pump_anim_progress = (now - _pumpsnd.t0) / SKULLSHAKER_PUMP_FORCE_DUR
    else
        _pumpsnd.t0 = nil
        _G.__vr_pump_anim_active   = false
        _G.__vr_pump_anim_progress = nil
    end
    -- 2x Rack-Sound: 1. = 0.1s nach Schuss, 2. = 0.42s nach dem 1.
    if _pumpsnd.first_at and now >= _pumpsnd.first_at then
        play_weapon_sound(BREAK_PUMP_SND_ID)
        _pumpsnd.first_at  = nil
        _pumpsnd.second_at = now + 0.42
    end
    if _pumpsnd.second_at and now >= _pumpsnd.second_at then
        play_weapon_sound(BREAK_PUMP_SND_ID)
        _pumpsnd.second_at = nil
    end
end

-- IK-Dock: solange gegriffen, die linke Hand ans Slide-Welt-Ziel ziehen.
-- re4_vr_arm_chain.lua liest __vr_slide_hand_world_pos und loest die Arm-Kette darauf
-- (nur aktiv wenn gesetzt -> kein Einfluss aufs normale Arm-IK). Konzept aus RE9 SD.
-- [DOCK_LERP] Blend EINMAL pro Frame rampen (NICHT in publish_dock -> das laeuft
-- 5x/Frame: on_frame + 4 Slide-Override-Paesse, wuerde 5x hochzaehlen). Ziel = 1 wenn
-- gegriffen/Tuning, sonst 0. Publiziert eine smoothstep-Kurve fuer weiches In/Out.
local function update_dock_blend()
    local want = ((rack.grab_active or rack.dock_tune) and wep.slide_joint) and 1.0 or 0.0
    local b = rack.dock_blend or 0
    if b < want then b = math.min(b + DOCK_BLEND_SPEED, want)
    elseif b > want then
        -- [PUMP-REDOCK] Shotguns: Slide-Dock beim LOESEN schneller runterrampen. Der SLIDE_RACK-
        -- PRIORITY-Block (motion) haelt die Support-Hand undocked solange slide_dock_blend > 0.001 ->
        -- je schneller der nach dem Pump faellt, desto frueher re-dockt die Hand an den Vordergriff
        -- = kein kurzes Abheben beim Dauerfeuer+Pumpen. NUR Shotguns; Pistolen-Slide unberuehrt.
        local down = is_shotgun(wep.wid) and 0.30 or DOCK_BLEND_SPEED
        b = math.max(b - down, want)
    end
    rack.dock_blend = b
    _G.__vr_slide_dock_blend_factor = b * b * (3.0 - 2.0 * b)   -- smoothstep
end

local function publish_dock()
    -- [DOCK_LERP] Gate auf dock_blend (nicht grab_active): solange der Blend > 0 ist
    -- (auch beim Weg-Lerp nach dem Loslassen) bleibt das Slide-Ziel gesetzt, damit die
    -- Konsumenten (arm_chain Position, motion Rotation) sauber zurueck-interpolieren.
    local rj = rack_joint()   -- [EMPTY-RELOAD SLIDE] _08 im Empty-Reload-Modus, sonst _01
    if (rack.dock_blend or 0) > 0.001 and rj then
        local p = sc(rj, "get_Position")
        local r = sc(rj, "get_Rotation")
        local sd = rack_slide_pose()
        if is_shotgun(wep.wid) and rack.pump_off and not ROTARY_CYCLE[wep.wid] then   -- [ROTARY] Drehschalter-Waffen nie den Pump-Zweig -> immer Dock-/Rot-Offsets unten
            -- [SHOTGUN PUMP] Hand = Slide-Pos + (Slide-Rot * gemerkter lokaler Offset) -> wandert mit
            -- dem Pump, Position behaelt den Support-Offset. Rotation = live Support-Hand-Rotation.
            if p and r then
                local off = safe(function() return r * rack.pump_off end)
                if off then p = Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
            end
            local srot = rawget(_G, "__vr_support_hand_world_rot")
            if srot then r = srot end
        else
            -- [POSE2_OFFSETS 2026-08-06] Welcher der beiden Offset-Saetze gilt? Bei Pistolen
            -- entscheidet das dieselbe Weiche wie bei der Finger-Pose (rack.pose_side, EINMAL beim
            -- Greifen bestimmt): seitliche Annaeherung -> MAG-Rack-Pose mit IHREN Offsets (sdock_*/
            -- srack_*), sonst die Default-Pose mit ihren (dock_*/rack_*). Alle anderen Gattungen und
            -- der _08-Empty-Reload-Slide nehmen unveraendert nur den ersten Satz.
            local dX, dY, dZ = sd.dock_x, sd.dock_y, sd.dock_z
            local rX, rY, rZ = sd.rack_rx, sd.rack_ry, sd.rack_rz
            if rack.pose_side and not rack.empty_reload and wep.wid and category_of(wep.wid) == "pistols" then
                dX, dY, dZ = sd.sdock_x or dX, sd.sdock_y or dY, sd.sdock_z or dZ
                rX, rY, rZ = sd.srack_rx or rX, sd.srack_ry or rY, sd.srack_rz or rZ
            end
            if p and r and (dX ~= 0 or dY ~= 0 or dZ ~= 0) then
                local off = safe(function() return r * Vector3f.new(dX, dY, dZ) end)
                if off then p = Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
            end
            -- Rotations-Offset auf die Slide-Rotation -> feste, tunebare Hand-Pose (Grad).
            if r and (rX ~= 0 or rY ~= 0 or rZ ~= 0) then
                r = safe(function() return (r * quat_from_euler(rX, rY, rZ)):normalized() end) or r
            end
        end
        _G.__vr_slide_hand_world_pos = p
        _G.__vr_slide_hand_world_rot = r
    else
        -- [PUSH_DOCK 2026-07-21] Erst pruefen, ob gerade nachgedrueckt wird -- publish_dock laeuft
        -- 5x/Frame und wuerde das Push-Dock sonst jedes Mal wieder abraeumen (genau der Bug bei Leon).
        if not rack.publish_push_dock() then
            -- [DOCK-RELEASE 2026-07-24] Fallende Flanke -> Zeitstempel fuer den Links-Ausfade in
            -- motion.lua (wie beim KS4-Austritt, nur links). Globals hier weiter HART leeren (Original).
            if rack.pushdock_was_active then
                _G.__re4_reload_lexit_t = os.clock()
                rack.pushdock_was_active = false
            end
            _G.__vr_slide_hand_world_pos = nil
            _G.__vr_slide_hand_world_rot = nil
            _G.__vr_slide_dock_blend_factor = 0
        end
    end
end

-- [PUSH_DOCK 2026-07-21] 1:1 wie in re4_vr_reload.lua: IK-Dock-Ziel am MAGAZIN-Joint, damit die
-- linke Hand waehrend des Nachdrueckens fest an der Waffe steht statt am Controller zu haengen.
-- Offsets/Blend kommen aus reload_adv (universell, also fuer Leon und Ada dieselben Werte).
-- [200-LOCAL-LIMIT] bewusst als Feld der bestehenden rack-Tabelle, NICHT als neues Top-Level-Local.
function rack.publish_push_dock()
    local ms = rawget(_G, "__re4_reload_mag_slide")
    if not (ms and type(ms.push_blend) == "function" and wep.mag_joint) then return false end
    if (rack.dock_blend or 0) > 0.001 then return false end   -- Slide-Dock hat Vorrang
    local b = tonumber(ms.push_blend()) or 0.0
    if b <= 0.001 then return false end
    local p = sc(wep.mag_joint, "get_Position")
    local r = sc(wep.mag_joint, "get_Rotation")
    if not (p and r) then return false end
    local o = ms.push or {}
    -- [ADA] Positions-Offset ueber den Getter holen: bei Ada steckt ihr Zusatz-Offset (kleinere Haende)
    -- schon drin, bei Leon sind es exakt seine px/py/pz. Rotation bleibt fuer beide dieselbe.
    local ox, oy, oz = 0, 0, 0
    if type(ms.push_pos) == "function" then
        -- [PUSH-Y PRO WAFFE 2026-07-25] wep.wid MITGEBEN (1:1 wie in re4_vr_reload.lua): sonst zieht der
        -- Y-Zusatz das globale __re4_reload_ui_wid, das in fremden publish_dock-Passes schon eine andere
        -- (oder gar keine) Waffe zeigen kann -- genau deshalb blieb der Slider bei der MP-AF wirkungslos.
        local ok2, a, b2, c2 = pcall(ms.push_pos, wep.wid)
        if ok2 then ox, oy, oz = a or 0, b2 or 0, c2 or 0 end
    else
        ox, oy, oz = o.px or 0, o.py or 0, o.pz or 0
    end
    if ox ~= 0 or oy ~= 0 or oz ~= 0 then
        local off = safe(function() return r * Vector3f.new(ox, oy, oz) end)
        if off then p = Vector3f.new(p.x + off.x, p.y + off.y, p.z + off.z) end
    end
    if (o.rx or 0) ~= 0 or (o.ry or 0) ~= 0 or (o.rz or 0) ~= 0 then
        r = safe(function() return (r * quat_from_euler(o.rx or 0, o.ry or 0, o.rz or 0)):normalized() end) or r
    end
    _G.__vr_slide_hand_world_pos    = p
    _G.__vr_slide_hand_world_rot    = r
    _G.__vr_slide_dock_blend_factor = b
    -- [DOCK-RELEASE 2026-07-24] Wie bei Leon: Push-Dock AKTIV markieren + laufenden Links-Ausfade
    -- abbrechen (Dock hat Vorrang). Der Ausfade selbst laeuft in motion.lua (__re4_reload_lexit_apply).
    rack.pushdock_was_active = true
    _G.__re4_reload_lexit_t = nil
    return true
end

-- Slide-Pose treiben solange gerackt werden muss:
-- ungegriffen -> Park (leer, leicht hinten); gegriffen -> Park..Voll-Hinten per frac
local function apply_slide_park()
    if not CFG.enabled then return end
    if TOP_LOADER[wep.wid] then return end   -- [TOP_LOADER] kein Slide-Modell (Chamber via apply_chamber)
    if ROTARY_CYCLE[wep.wid] or BREAK_ACTION[wep.wid] then return end   -- [ROTARY/BREAK] slide-Joint ist Rotation/Hebel, kein Z-Slide
    -- [SHOTGUN_PUMP_SUPPRESS] Die Shotgun-Engine racked das Pump-Joint _01 nach JEDEM Schuss selbst
    -- (AfterShoot-Node: _01 faehrt rest->back->rest). Das wollen wir MANUELL machen -> den nativen
    -- Pump unterdruecken, indem wir _01 jeden Post-Anim-Pass hart auf rest_z (vorn/gechambert) halten.
    -- AUSNAHME: waehrend unseres eigenen manuellen Racks (grab_active) ODER UI-Vorschau (tuning) ->
    -- dann faellt es durch zur normalen Logik unten (frac-getriebener Zug).
    if is_shotgun(wep.wid) then
        if rack.empty_reload then
            -- [EMPTY-RELOAD SLIDE] Pump-Joint _01 IMMER vorn (rest) halten (wird in diesem Modus nicht
            -- benutzt); der _08-Lade-Slide wird unten generisch via rack_joint/rack_slide_pose getrieben.
            local j1 = wep.slide_joint
            if j1 then
                local cur = sc(j1, "get_LocalPosition")
                if cur then
                    local sp1 = slide_pose(wep.wid or 0)
                    pcall(function() j1:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp1.rest_z)) end)
                end
            end
            -- fall through -> generischer Block treibt _08
        elseif not (rack.grab_active or rack.tuning) then
            local sj = wep.slide_joint
            if sj then
                local cur = sc(sj, "get_LocalPosition")
                if cur then
                    local sp = slide_pose(wep.wid or 0)
                    pcall(function() sj:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp.rest_z)) end)
                end
            end
            return
        end
        -- manuelles Rack laeuft -> weiter unten der grab_active-Zweig (frac-Zug)
    end
    -- Slide treiben solange: 0 Ammo / Mag draussen / Rack noetig / gerackt / Vorschau / Nach-Rack-Halt.
    if not (rack.empty or mag_out or rack.needs or rack.grab_active or rack.tuning or rack._chambered_hold) then
        -- [SLIDE-SELBSTHEILUNG 2026-07-21, "geschossen, Hook-Attacke, Slide wieder hinten -- das
        -- hatten wir schon 10000x"] GRUND fuer die Endlosschleife: die vorhandene Reparatur (s. weiter
        -- unten im on_frame) haengt an EINEM Ausloeser -- __re4_damage_end_t, also dem Stagger-Ende. Eine
        -- Hook-Attacke ist kein Damage -> kein Stempel -> keine Heilung. Jeder neue Event-Typ (Cutscene,
        -- Melee, KS) faellt wieder durchs Raster, und es wird wieder ein Ausloeser nachgetragen.
        -- DESHALB HIER ZUSTANDSBASIERT statt ereignisbasiert: in genau dem Moment, in dem wir den Slide
        -- NICHT treiben (Waffe feuerbereit, kein Rack/Mag/Grab/Tuning), darf er auch nicht hinten stehen.
        -- Tut er es doch, hat ihn ein Event dort liegen lassen -> EINMALIG auf rest_z snappen und wie nach
        -- einem Rack halten (_chambered_hold, loest sich beim 1. Schuss von selbst).
        -- SCHUTZ gegen Kampf mit der Engine-Animation:
        -- * ENGINE_CLOSES_SLIDE-Waffen ausgenommen -- die schliessen selbst.
        -- * mind. 0.35s seit dem letzten Schuss (__vr_shot_seq vom Crosshair-Hook): der Schuss-Rueckstoss
        -- zieht den Slide kurz zurueck, das ist NORMAL und darf nicht korrigiert werden.
        -- * Toleranz: erst ab halbem Weg Richtung back_z (Ausreisser/Feinbewegungen bleiben unberuehrt).
        -- * throttle 1x/0.5s -> kein Frame-Kampf, falls die Engine dagegenhaelt.
        do
            local sj0 = wep.slide_joint
            local sp0 = sj0 and slide_pose(wep.wid or 0)
            if sj0 and sp0 and not ENGINE_CLOSES_SLIDE[wep.wid] then
                local seq = tonumber(rawget(_G, "__vr_shot_seq"))
                if seq and seq ~= rack._heal_seq then rack._heal_seq = seq; rack._heal_shot_t = os.clock() end
                local quiet = (os.clock() - (rack._heal_shot_t or -999)) > 0.35
                local cur0  = quiet and sc(sj0, "get_LocalPosition") or nil
                if cur0 then
                    -- "hinten" = Weg von rest_z Richtung back_z, als VERHAELTNIS gerechnet (damit das
                    -- Vorzeichen egal ist -- Default ist rest_z 0.06174 > back_z 0.03174, andere Waffen
                    -- koennen es umgekehrt haben).
                    -- SCHWELLE, nachgerechnet am LIVE GEMESSENEN Fehlerwert (Kommentar 2026-07-20: die
                    -- Engine zog den Slide auf 0.0579): 0.0579 liegt nur ~13 % des Weges hinter rest_z --
                    -- eine "halber Weg"-Schwelle haette diesen Fall NICHT gefangen. Darum 10 %, zusaetzlich
                    -- abgesichert mit einer absoluten Mindestabweichung von 2 mm gegen Rundungsrauschen.
                    local span = (sp0.back_z or sp0.rest_z) - sp0.rest_z
                    local off  = cur0.z - sp0.rest_z
                    if span ~= 0 and (off / span) > 0.10 and math.abs(off) > 0.002
                       and (os.clock() - (tonumber(rack._heal_fix_t) or 0)) > 0.5 then
                        rack._heal_fix_t = os.clock()
                        pcall(function() sj0:call("set_LocalPosition", Vector3f.new(cur0.x, cur0.y, sp0.rest_z)) end)
                        rack._chambered_hold = true
                        _G.__re4_slide_grund = "SELBSTHEILUNG (Slide stand hinten ohne Grund)"
                        return
                    end
                end
            end
        end
        _G.__re4_slide_grund = "AUS (Engine haelt den Slide)"   -- [SLIDE_GRUND] wir fassen ihn gar nicht an
        return
    end
    local sj = rack_joint(); if not sj then return end   -- [EMPTY-RELOAD SLIDE] _08 im Empty-Reload, sonst _01
    local cur = sc(sj, "get_LocalPosition"); if not cur then return end   -- x/y bleiben, nur Z setzen
    local sp = rack_slide_pose()
    local z
    -- [SLIDE_GRUND 2026-07-19] Jeder Zweig sagt, WARUM der Slide dort steht. Ein Log, das nur
    -- Zustaende zeigt, konnte die Frage "wieso steht der Slide hinten" nicht beantworten -- die
    -- entscheidende Bedingung (empty_when_dropped) war nirgends exportiert. Jetzt protokolliert die
    -- Funktion ihre eigene Entscheidung; das Diagnose-Script liest sie nur noch ab.
    if rack.tuning then
        z = sp.park_z + (sp.back_z - sp.park_z) * rack.tune_frac
        _G.__re4_slide_grund = "tuning(UI-Vorschau)"
    elseif rack.grab_active then
        z = sp.park_z + (sp.back_z - sp.park_z) * rack.frac   -- 1:1 gezogen: Park -> Voll-Hinten
        _G.__re4_slide_grund = "grab_active(Hand zieht)"
    elseif rack._chambered_hold then
        if ENGINE_CLOSES_SLIDE[wep.wid] then _G.__re4_slide_grund = "chambered_hold->Engine"; return end
        z = sp.rest_z   -- NACH dem Rack zu halten (Engine spielt die Kammer-Schliess-Anim nicht;
                        -- bis zum naechsten Schuss forcen, dann uebernimmt die Engine-Anim)
        _G.__re4_slide_grund = "chambered_hold(rest)"
    elseif rack.needs or rack.empty_when_dropped or rack.empty then
        z = sp.park_z   -- 0 Ammo ODER leer nach Drop -> Slide auf MITTEL bis gerackt
        -- WELCHE der drei Bedingungen hat ausgeloest? Genau das war die offene Frage.
        _G.__re4_slide_grund = string.format("PARK weil needs=%s empty_when_dropped=%s empty=%s",
            tostring(rack.needs), tostring(rack.empty_when_dropped), tostring(rack.empty))
    else
        if ENGINE_CLOSES_SLIDE[wep.wid] then _G.__re4_slide_grund = "taktisch->Engine"; return end
        z = sp.rest_z   -- taktischer Mag-Out (noch Patronen) -> Slide vorne/gechambert
        _G.__re4_slide_grund = "taktisch(rest)"
    end
    _G.__re4_slide_grund_z = z
    _G.__re4_slide_grund_t = os.clock()
    pcall(function() sj:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, z)) end)
end

-- Rack-Handpose (Finger) der LINKEN Hand. Greift bei echtem Rack (Hand am Slide angedockt)
-- UND im Einstell-Toggle (dock_tune), damit man beim Posen die ganze Hand sieht.
-- NICHT waehrend das Mag getragen/eingesetzt wird (Konflikt mit der Mag-Halte-Pose).
-- Wir wenden die Pose NICHT selbst an (unsere Passes sind PRE-Anim -> Engine ueberschreibt).
-- Stattdessen den Pose-NAMEN publizieren; motion.lua wendet ihn im POST-ANIM-Pass an
-- (exakt wie die Flashlight-Knife-Pose) -> ueberschreibt die Engine-Finger-Animation.
local function apply_rack_hand_pose()
    -- [POSE PER WAFFE] eigene Rack-Pose dieser Waffe bevorzugen, sonst globale (Pistolen unveraendert).
    -- [EMPTY-RELOAD SLIDE] Im _08-Modus eigene Hand-Pose (RiotSLide) statt der Pump-Pose (SGPUMP).
    -- [RACK_POSE_ANGLE 2026-07-31] Pistolen (6112/6103) haben ZWEI Posen, ausgewaehlt beim Greifen
    -- (rack.pose_side). RACK_POSE[wid] wird fuer Pistolen daher nicht mehr gelesen -- der Alt-Eintrag
    -- 6103 = "MAGRack" ist wirkungslos, MAGRack kommt jetzt ueber den Seiten-Zweig fuer BEIDE Pistolen.
    local _rp
    if rack.empty_reload and wep.wid and RACK_POSE_EMPTY[wep.wid] then
        _rp = RACK_POSE_EMPTY[wep.wid]
    elseif wep.wid and category_of(wep.wid) == "pistols" then
        _rp = rack.pose_side and CFG.rack_pose_side or CFG.rack_pose
    else
        _rp = (wep.wid and RACK_POSE[wep.wid]) or CFG.rack_pose
    end
    if not CFG.enabled or not _rp or _rp == "" or mag_hand.active or mag_insert.active then
        _G.__vr_rack_hand_pose = nil; return
    end
    local want = false
    if rack.dock_tune then
        want = true
    elseif rack.needs then
        -- [POSE ERST AM RACK 2026-07-19] Frueher genuegte NAEHE (rack._last_dist <= rack_grab_dist)
        -- -> die Hand nahm die Rack-Pose schon ein, sobald sie in die Naehe der Waffe kam. Jetzt nur
        -- noch, wenn wirklich gegriffen wird (grab_active). dock_tune (UI-Vorschau) bleibt unberuehrt.
        want = rack.grab_active
    end
    _G.__vr_rack_hand_pose = want and _rp or nil
end

-- [FINDER] Waffen-Transform fuer den Finder, UNABHAENGIG von wep.tf: bei einer noch nicht
-- konfigurierten Waffe (z.B. Red9, deren Platzhalter-Mag-Joint nicht aufloest) bleibt wep.tf
-- nil -> sonst koennte man die Joints gar nicht durchsuchen. Hier direkt per find_weapon holen.
local function finder_tf()
    if wep.tf then return wep.tf end
    local wid = get_equip_wid(); if not wid or wid == 0 then return nil end
    local _, tf = find_weapon(wid)
    return tf
end

-- [FINDER] alle Joint-Namen der aktuell equippten Waffe (fuer den Index-Slider).
-- 1) echte Joint-Liste der Transform (get_Joints). 2) Fallback: generische Pistolen-Joint-
-- Namen abklopfen (getJointByName ist erprobt). Per wid gecacht.
local _jn_cache = { wid = nil, names = nil }
local function weapon_joint_names()
    local wid = wep.wid or get_equip_wid()
    if _jn_cache.wid == wid and _jn_cache.names and #_jn_cache.names > 0 then return _jn_cache.names end
    local tf = finder_tf(); if not tf then return {} end
    local names, seen = {}, {}
    local arr = safe(function() return tf:call("get_Joints") end)
    if arr then
        local n = safe(function() return arr:get_size() end)
        if n and n > 0 then
            for i = 0, n - 1 do
                local jt = safe(function() return arr:get_element(i) end)
                local nm = jt and safe(function() return jt:call("get_Name") end)
                if nm and nm ~= "" and not seen[nm] then seen[nm] = true; names[#names+1] = nm end
            end
        end
    end
    if #names == 0 then
        local cand = { "root" }
        for i = 0, 30 do cand[#cand+1] = string.format("_%02d", i) end
        for _, nm in ipairs({ "_100","_101","_102","_103","_104","_105" }) do cand[#cand+1] = nm end
        for _, nm in ipairs(cand) do
            if not seen[nm] and sc(tf, "getJointByName", nm) then seen[nm] = true; names[#names+1] = nm end
        end
    end
    if #names > 0 then _jn_cache = { wid = wid, names = names } end
    return names
end

-- Joint-Finder: verschiebt den gewaehlten Joint um einen festen Offset von seiner
-- (einmal erfassten) Ruhepose -> man sieht welcher Joint der Slide ist.
local function apply_finder()
    if not finder.active then return end
    local tf = finder_tf(); if not tf then return end
    local j = sc(tf, "getJointByName", finder.name); if not j then return end
    if finder.base_name ~= finder.name or not finder.base then
        local lp = sc(j, "get_LocalPosition"); if not lp then return end
        finder.base = { x = lp.x, y = lp.y, z = lp.z }
        finder.base_name = finder.name
    end
    pcall(function() j:call("set_LocalPosition",
        Vector3f.new(finder.base.x + finder.x, finder.base.y + finder.y, finder.base.z + finder.z)) end)
end

-- [CHAMBER] Top-Loader (Red9): rechter B togglet den Chamber auf/zu.
local function toggle_chamber()
    chamber.open = not chamber.open
    rlog("chamber " .. (chamber.open and "AUF" or "ZU"))
    play_weapon_sound(snd("chamber"))   -- [SND] Chamber auf UND zu = derselbe Sound
end

-- [SHELL_EJECT] Shell-Joint _04 in die Chamber-Startposition setzen (Offset von der Ruhepose).
-- SCHRITT 1: nur Preview (Flug kommt spaeter). Im Override-Pass halten gegen die Engine.
local function apply_shell_eject()
    if not is_shotgun(wep.wid) then return end
    if not (wep.mag_joint and wep.rest_lp) then return end
    if not (shell_eject.preview or shell_eject.flying) then return end   -- sonst Engine kontrolliert _04
    local s = shell_eject_cfg(wep.wid)
    local rl = wep.rest_lp
    local px, py, pz = rl.x + s.sx, rl.y + s.sy, rl.z + s.sz
    local spin_deg = 0.0
    if shell_eject.flying then
        local t = shell_eject.t or 0
        px = px + (s.vx or 0) * t
        py = py + (s.vy or 0) * t - 0.5 * (s.grav or 4.0) * t * t   -- Bogen: hoch dann fallen
        pz = pz + (s.vz or 0) * t
        spin_deg = (s.spin or 0) * t                                -- Taumeln
    end
    pcall(function() wep.mag_joint:call("set_LocalPosition", Vector3f.new(px, py, pz)) end)
    if wep.rest_lr then
        local base = Quaternion.new(wep.rest_lr.w, wep.rest_lr.x, wep.rest_lr.y, wep.rest_lr.z)
        local rot = safe(function() return (base * quat_from_euler(s.srx + spin_deg, s.sry, s.srz)):normalized() end)
        if rot then pcall(function() wep.mag_joint:call("set_LocalRotation", rot) end) end
    end
end

-- [SHELL_EJECT] Flug-State 1x/Frame fortschreiben (NICHT in apply_shell_eject -> das laeuft 4x/Frame).
-- Trigger: Pump voll zurueckgezogen (rack.pulled-Flanke = Chamber offen) -> Shell fliegt aus dem Chamber.
local function update_shell_eject()
    if not is_shotgun(wep.wid) then shell_eject.flying = false; shell_eject._prev_pulled = false; return end
    local now = os.clock()
    local dt = now - (shell_eject.last_clock or now)
    shell_eject.last_clock = now
    if dt < 0 or dt > 0.1 then dt = 0.016 end   -- Sprung-Schutz (Pause/Ladebildschirm)
    -- Trigger: rack.pulled steigende Flanke (Chamber offen), nicht im Tuning-Preview.
    -- [DIAG temp] Zustand beim Pump-Grab mitloggen (throttled) -> warum kein Gimmick?
    -- [log entfernt]
    -- [GIMMICK] Pump passiert jetzt NUR noch im rack.needs-Fenster (nach Schuss/Reload). Auf der
    -- rack.pulled-Flanke (Chamber offen) fliegt die Shell kosmetisch raus, solange geladen (pump_one_out).
    if rack.pulled and not shell_eject._prev_pulled and not shell_eject.preview then
        if pump_one_out() then
            shell_eject.flying = true
            shell_eject.t = 0.0
        end
    end
    shell_eject._prev_pulled = rack.pulled
    if shell_eject.flying then
        shell_eject.t = (shell_eject.t or 0) + dt
        local s = shell_eject_cfg(wep.wid)
        if shell_eject.t >= (s.dur or 0.7) then shell_eject.flying = false end   -- Flug vorbei -> Engine chambert frisch
    end
end

-- [CHAMBER] Chamber-Joint in den Override-Paessen halten: offen -> Ruhe+z, zu -> nicht forcen
-- (Engine-Pose stellt zu). Ruhepose wird einmal im geschlossenen Zustand erfasst.
local function apply_chamber()
    local cc = CHAMBER[wep.wid]; if not cc then return end
    local tf = wep.tf; if not tf then return end
    local j = sc(tf, "getJointByName", cc.joint); if not j then return end
    -- Ruhepose (zu) NUR im voll geschlossenen Zustand erfassen (blend == 0).
    if chamber.blend <= 0.0001 and (chamber.base_joint ~= cc.joint or not chamber.base) then
        local lp = sc(j, "get_LocalPosition")
        if lp then chamber.base = { x = lp.x, y = lp.y, z = lp.z }; chamber.base_joint = cc.joint end
    end
    -- Solange irgendwie offen (auch beim Zufahren) den interpolierten Z-Offset schreiben.
    if chamber.base and chamber.blend > 0.0001 then
        local t = chamber.blend
        local s = t * t * (3 - 2 * t)   -- smoothstep
        pcall(function() j:call("set_LocalPosition",
            Vector3f.new(chamber.base.x, chamber.base.y, chamber.base.z + cc.z * s)) end)
    end
end

-- Kompakter State-Export fuer das EXTERNE Diag-Script (re4_vr_reload_diag.lua).
-- Ein Tabellen-Write pro Frame, KEIN Logging im Produktiv-Pfad.

-- Zentraler Reset des KOMPLETTEN Reload-States. Bei JEDEM Waffenwechsel / Unequip /
-- Enemy-Grab (Spiel holstert die Waffe zwangsweise) aufgerufen -> kein haengender
-- Zwischenstand (halber Drop/Insert, Mag-in-Hand, stale Block/needs_rack). Macht den
-- Ablauf grab- und save-load-fest: nach jedem Wechsel wird der State frisch hergeleitet.
local function reset_reload_state()
    stop_mag_drop()
    drop.active       = false
    mag_hand.active   = false
    mag_insert.active = false
    mag_insert.settle = false   -- [INSERT-PUNCH] Nachfedern mit abbrechen
    mag_tune.active   = false
    rack.grab_active  = false
    rack.armed        = false
    rack.frac         = 0
    rack.pulled       = false
    rack.needs        = false
    _G.__re4_needs_who = "3008(false)"   -- [NEEDS-DIAG 2026-07-20] wer aendert den Rack-Zwang?
    rack.has_mag      = false
    rack.empty_when_dropped = false
    rack._zeroed_by_us = false  -- [ACCESSOR-FOLGE] Merker darf einen Wechsel nicht ueberleben
    rack.empty_reload = false   -- [EMPTY-RELOAD SLIDE] Modus bei Wechsel/Reset aus
    rotary.prog = 0.0; rotary.dir = 0; rotary._prev_trig = false; rotary.pending = false   -- [ROTARY_CYCLE] Dreh-State (+ deferred Ammo) bei Wechsel/Reset aus
    rotary._grip_latched = false; rotary._prev_grip = false; _G.__vr_block_two_hand = false   -- [SWITCH-GRIP-LATCH] aus
    break_st.prog = 0.0; break_st.open = false; break_st._was_open = false; break_st._prev_b = false; _G.__vr_break_open = false   -- [BREAK_ACTION] Hebel zu + ready nach Wechsel
    rack._pump_ref_z = nil
    rack.pump_off    = nil   -- [PUMP_OFF STALE] sonst behaelt eine vorher gepumpte Shotgun (W-870/Riot) ihren
                             -- lokalen Pump-Offset; bei der naechsten Shotgun (Striker = is_shotgun!) nimmt
                             -- publish_dock faelschlich den Pump-Zweig und ignoriert deren Dock-/Rot-Offsets.
    -- [GOLDEN RULE] Schuss-Sequenz-Baseline beim Wechsel NEU syncen, sonst triggert die Shotgun-
    -- Schuss-Erkennung (seq > _prev_shot_seq) faelschlich rack.needs=true auf der frisch gezogenen
    -- Waffe (globaler __vr_shot_seq ist von anderen Waffen schon hochgezaehlt) -> Waffe waere NICHT
    -- ready (erst nach Pump feuerbar). nil -> naechster Frame setzt _prev_shot_seq = aktueller seq.
    rack._prev_shot_seq = nil
    rack._chambered_hold = false   -- [CHAMBER_HOLD] bei Wechsel/Reset aus
    _G.__re4_ch_who = "3171(false)"   -- [CH-DIAG 2026-07-20] wer setzt den Slide-Halt?
    chamber.open = false; chamber.blend = 0.0; chamber.base = nil; chamber.base_joint = nil   -- [TOP_LOADER] Chamber zu + Ruhepose neu erfassen
    -- mag_out NICHT hier nullen -> per-Waffe persistent (Wiederherstellung im on_frame-Branch)
    _G.__vr_block_fire_when_empty   = false
    _G.__re4_bf_who = "re4_vr_reload4_dlc.lua:3021"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
    _G.__vr_needs_rack              = false
    _G.__vr_rack_block_left_knife   = false
    _G.__vr_manual_reload_consume_b = false
    _G.__vr_slide_hand_world_pos    = nil
    _G.__vr_slide_hand_world_rot    = nil
    _G.__vr_slide_dock_blend_factor = 0      -- [DOCK_LERP] harter Reset: kein Weg-Lerp
    rack.dock_blend                 = 0
    _G.__vr_rack_hand_pose          = nil
    -- [WI_CACHE] gecachtes Live-Item ist nach Waffenwechsel stale (alte Instanz gleicher
    -- WeaponId -> getReloadableCount=0). Invalidieren -> get_live_weapon_item resolved frisch
    -- (Inventory-Row mit Reserve), bis der naechste Schuss/Reload es neu cached.
    _G.__re4_live_wi = nil
    -- [STALE JOINTS 2026-07-20 -- per Log bewiesen] Bisher wurde NUR das Item invalidiert, nicht die
    -- Waffen-/Joint-Referenzen. Nach dem Enterhaken (Waffe wird entzogen + neu instanziiert) schrieb das
    -- Modul deshalb weiter auf die ALTE Instanz: unser Log zeigte einen sauber geparkten Slide (0.0854),
    -- waehrend die ECHTE Waffe vorne stand und die Engine sie als feuerbereit sah (gun_state 2 -> 3).
    -- Folge: Rack-Zwang wirkungslos, Schuss ohne Rack, Quick-Knife moeglich -- und zwar erst NACH dem
    -- ersten Haken, davor beliebig oft korrekt. Genau das Muster, das man beschrieben hat.
    -- Referenzen daher mit invalidieren -> refresh_weapon loest beim naechsten Frame frisch auf.
    wep.wid, wep.tf, wep.mag_joint, wep.slide_joint = nil, nil, nil, nil
    wep.slide_joint2, wep.slide_rest_lp, wep.cycle_rest_rot = nil, nil, nil
end
local _last_handled_wid = nil
local _red9_prev_reloading = false   -- [RED9_NATIVE_AMMO] Flanke der nativen Reload-Anim (motion publiziert __vr_red9_reloading)

-- [SHELL_PART] Forward-Decl: on_frame (unten) ruft sg_update_parts, definiert wird es weiter unten
-- (zusammen mit sg_force_shell_parts, das apply_slide_pass nutzt). [[feedback-lua-forward-decl]]
local sg_update_parts, sg_force_shell_parts
local update_shell_spawn   -- [SHELL_SPAWN] forward-decl (im on_frame aufgerufen, weiter unten definiert)

re.on_frame(function()
    -- [LET-GO] update_native_reload_pause (Motion-Pause bei nativem Reload) ENTFERNT aus reload:
    -- die Hand-Trennung waehrend der Reload-Anim gehoert in den Killswitch, nicht hierher.
    if not CFG.enabled then
        _managed = false
        _G.__re4_r4dlc_release()   -- [DLC LET-GO] nur an der Flanke freigeben, s. Helfer oben
        return
    end
    refresh_weapon()
    -- Waffenwechsel / Unequip / Enemy-Grab -> kompletten Reload-State sauber resetten
    local hwid = handled()
    if hwid ~= _last_handled_wid then
        -- [MAG_OUT] Draussen-Zustand pro Waffe merken/wiederherstellen -> Drop ueberlebt
        -- den Waffenwechsel. Der Mesh-Hold (apply_mag_out_hidden) haelt das Mag dann
        -- jeden Frame aus der Kammer -> B bleibt korrekt blockiert (Mag ist ja draussen).
        -- [RACK-ZWANG UEBERLEBT DEN WECHSEL 2026-07-20 -- per Log bewiesen] reset_reload_state
        -- loescht rack.needs. Das feuert bei JEDEM kurzen Waffenwechsel -- Granate werfen, Messer,
        -- Enterhaken, Stagger (dort meldet die Engine kurz wid=-1 bzw. eine andere Waffe). Danach war
        -- der Rack-Zwang weg und man konnte ohne Slide-Rack weiterfeuern. Belegt im Log:
        -- 19:11:47 MANAGED AUS wid=5400 -> NEEDS false (Zeile 3008) -> 19:11:51 Blacktail zurueck.
        -- Fix nach dem BEWAEHRTEN Muster von mag_out: pro Waffe merken und beim Zurueckwechseln
        -- wiederherstellen. Geloescht wird er weiterhin nur durch ein echtes Rack (clear_rack).
        -- [STAGGER_MAGOUT 2026-07-24] 1:1 wie in re4_vr_reload.lua (Leon): waehrend eines
        -- Staggers/Enemy-Grabs meldet die Engine KEINE Waffe -> hwid wird nil. Kommt sie zurueck, holte
        -- die Zeile unten mag_out aus dem Store -- "Mag draussen" ohne jeden laufenden Flow, und da das
        -- Heilen ueber loaded>0 bewusst entfernt ist, blieb der Feuer-Block fuer immer stehen
        -- = Dry-Fire mit voller Waffe. REGEL: A -> B (echter Wechsel) stellt den Store her,
        -- A -> nil -> A (Waffe war nur kurz weg) NICHT -- die Engine hat in der Abwesenheit selbst
        -- gechambert. rack._gone_wid statt neuem Local (200-Limit; reset_reload_state fasst es nicht an).
        -- rack.needs bleibt ABSICHTLICH beim alten Verhalten (Rack-Zwang soll den Wechsel ueberleben).
        -- [MAG_RETAIN PRO WAFFE 2026-07-25] Identisch zu re4_vr_reload.lua nachgezogen: mag_retained
        -- war global -> eine Waffe mit gedropptem Rest-Mag verliert ihre Runden an die naechste Waffe, die
        -- nachlaedt (target=min(cap,mag_retained+reserve), danach Zaehler auf 0). Jetzt pro Waffe.
        if _last_handled_wid then
            mag_out_store[_last_handled_wid] = mag_out
            rack._needs_store = rack._needs_store or {}   -- [200-LIMIT] Feld statt neuem Local
            rack._needs_store[_last_handled_wid] = rack.needs
            rack._retained_store = rack._retained_store or {}   -- [MAG_RETAIN PRO WAFFE] ebenfalls Feld (200-Limit)
            rack._retained_store[_last_handled_wid] = mag_retained
            if hwid == nil then rack._gone_wid = _last_handled_wid end   -- Waffe nur WEG, kein Wechsel
        end
        reset_reload_state()
        if hwid and rack._gone_wid == hwid then
            mag_out = false                  -- dieselbe Waffe kommt nach der Abwesenheit zurueck
            mag_out_store[hwid] = false      -- Store mitloeschen -> spaeterer Wechsel holt ihn nicht zurueck
            -- Mag gilt als drin (Engine hat selbst gechambert) -> Notiz abgegolten, sonst wuerde
            -- derselbe Rest beim naechsten Nachladen ein zweites Mal gutgeschrieben.
            mag_retained = 0
            if rack._retained_store then rack._retained_store[hwid] = nil end
            rack._gone_wid = nil
        else
            mag_out = (hwid and mag_out_store[hwid]) or false
            mag_retained = (hwid and rack._retained_store and rack._retained_store[hwid]) or 0
            if hwid then rack._gone_wid = nil end
        end
        rack.needs = (hwid and rack._needs_store and rack._needs_store[hwid]) or false
        _last_handled_wid = hwid
    end
    -- [SAVE_LOAD] Gleiche Waffe, aber neu instanziiert (Save-Load/Respawn) -> stale
    -- Lua-State (mag_out/mag_hand/rack/...) wie bei Reset Scripts neu initialisieren,
    -- sonst klemmt z.B. der Holster-Grab. Engine haelt nach dem Laden das Mag in der
    -- Kammer -> mag_out = false. Nur wenn verwaltete Waffe.
    if _weapon_reacquired then
        _weapon_reacquired = false
        if hwid then
            reset_reload_state()
            mag_out = false
            -- [REGAL LEEREN 2026-07-24] Nach Save-Load/Respawn gilt NICHTS von vorher: die Engine
            -- haelt alle Mags in der Kammer und chambert selbst. Darum BEIDE Notiz-Regale komplett
            -- leeren (nicht nur die aktuelle Waffe) -- sonst holt ein spaeterer Waffenwechsel einen alten
            -- mag_out oder rack.needs zurueck und die Waffe verlangt ein Rack, das laengst erledigt war.
            -- Bei "Reset Scripts" passiert das ohnehin von selbst: beide Regale sind Datei-Locals und
            -- werden beim Neuladen frisch angelegt.
            mag_out_store = {}
            rack._needs_store = nil
            rack._gone_wid    = nil
            -- [MAG_RETAIN PRO WAFFE] drittes Regal mitleeren: nach Save-Load/Respawn haelt die Engine
            -- alle Mags in der Kammer, ein alter Rest-Notiz wuerde sonst Gratis-Munition schenken.
            rack._retained_store = nil
            mag_retained = 0
        end
    end
    -- [LET-GO] Waffe NICHT verwaltet ("Manual Pistol Reload" AUS, keine Pistole, kein Joint):
    -- reload laesst KOMPLETT los -> alle Globals frei, KEINE Writes, KEINE Pausen. Nativer
    -- Reload + Ammo-Zaehlung liegen voll bei der Engine. Hand-Trennung waehrend der Reload-Anim
    -- macht der Killswitch (separat), NICHT dieses Script.
    if not hwid then
        _managed = false
        _G.__re4_r4dlc_release()   -- [DLC LET-GO] nur an der Flanke freigeben, s. Helfer oben
        return
    end
    _managed = true
    _G.__re4_r4dlc_had = true   -- [DLC LET-GO] wir halten die Globals gerade -> beim Loslassen einmal freigeben

    -- [RED9_NATIVE_AMMO] Der native Reload spielt nur die Anim, verteilt aber KEINE Ammo. Daher beim
    -- Ende der Anim (__vr_red9_reloading true->false, von motion.lua) einmal VERLUSTSICHER auffuellen:
    -- nur die Luecke bis Cap, Reserve entsprechend abziehen. Hat die Engine doch transferiert (loaded
    -- schon == target), ist used=0 -> kein Doppel.
    do
        local reloading = rawget(_G, "__vr_red9_reloading") == true
        if (hwid == 4002) and _red9_prev_reloading and (not reloading) and CFG.reload_ammo then
            local wi = get_live_weapon_item()
            if wi then
                local cap     = tonumber(safe(function() return wi:call("get_CurrentAmmoMax") end)) or 0
                local ammo_id = safe(function() return wi:call("get_CurrentAmmo") end)
                local pe2     = get_pe(); local inv2 = pe2 and sc(pe2, "get_InventoryController")
                local function gun_ammo() return pe2 and tonumber(safe(function() return pe2:call("getCurrentGunAmmo") end)) or nil end
                local function read_rsv() return (inv2 and ammo_id) and (tonumber(safe(function() return _G.__re4_item_count_sum(inv2, ammo_id) end)) or 0) or 0 end
                local r_b4    = read_rsv()
                local b4      = gun_ammo() or (tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end)) or 0)
                local target  = math.min(cap, b4 + r_b4)
                local used    = math.max(0, target - b4)
                if used > 0 then
                    -- [RUNTIME-FIX 0/0] Engine-Reload primaer (greift aufs ECHTE Gun-Item), write_dword nur Fallback.
                    local et = get_equip_type_main()
                    -- [CRASH-HARDEN 2026-07-14] nur wenn der Red9 (4002) noch live equippt ist (sonst null-Gun-Item -> AV).
                    if et and inv2 and (get_equip_wid() or -1) == 4002 then _G.__re4_load_and_book(inv2, et, used, false) end
                    local af = gun_ammo() or b4
                    if af <= b4 then pcall(function() wi:write_dword(0x44, target) end); af = gun_ammo() or target end
                    local gained = math.max(0, af - b4)
                    if gained > 0 and inv2 and ammo_id and read_rsv() >= r_b4 then
                        _G.__re4_safe_reduce(inv2, ammo_id, gained)
                    end
                end
            end
        end
        _red9_prev_reloading = reloading
    end

    capture_mag_rest()   -- Chamber-Ruhepose laufend erfassen (fuer den Insert)
    -- [MANUAL_INSERT 2026-08-15] SICHERUNG: das Halten der Druecken-Pose darf NIE einen laufenden
    -- Handschub ueberleben. Den Insert brechen mehrere fremde Wege ab (Mag fallen lassen, neuer Grab,
    -- Waffenwechsel, Save-Load) -- die kennen den Push nicht. Ein Frame ohne aktiven Handschub reicht,
    -- dann faehrt die Pose normal zurueck statt am Magazin zu kleben.
    -- NUR wenn wir die Waffe auch wirklich fuehren (hwid): sonst raeumte Adas Script Leons Push ab.
    do
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if hwid and ms and ms.push_hold == true and not (mag_insert.active and mag_insert.manual) then
            if type(ms.end_push_hold) == "function" then pcall(ms.end_push_hold) end
        end
    end
    -- [MANUAL_INSERT] Rueckzieher OHNE gehaltenen Grip -> das Mag faellt. Hier statt direkt im
    -- Rueckzieher, weil drop_mag_simple erst weiter unten in der Datei steht.
    if mag_hand.want_drop then
        mag_hand.want_drop = nil
        mag_hand.redock_d  = nil
        if not mag_hand.active and not drop.active then
            drop_mag_simple()
            rlog("mag nach Rueckzieher losgelassen -> faellt auf den Boden")
        end
    end
    check_mag_insert_proximity()   -- Mag nah an der Waffe -> auto-insert
    update_shell_spawn()   -- [SHELL_SPAWN] getragene Huelse als eigene Instanz (Waffen ohne statischen Shell-Part)
    -- Mag-Joint ans Advanced-Modul reichen (fuer Live-Preview im UI)
    if _G.__re4_reload_mag_slide then _G.__re4_reload_mag_slide.current_mag_joint = wep.mag_joint end
    -- Self-Heal: haengender/alter Drop bei Equip-Wechsel ODER ungueltigem Joint
    -- (z.B. nach Save-Load wird der Mag-Joint neu erzeugt) sauber abraeumen
    if drop.active and not drop.use_module then
        local bad = (drop.joint ~= wep.mag_joint)
            or not safe(function() return drop.joint:get_Valid() end)
        if bad then stop_mag_drop() end
    end

    -- verwaltete Pistole? -> Binding soll den rechten B abfangen (kein nativer Reload)
    -- [RED9_NATIVE] Top-Loader (Red9): KEIN B-Intercept -> der native Reload feuert (Engine spielt die
    -- Top-Fill-Anim inkl. Clip). Waehrend dieser Anim schaltet motion.lua sich selbst aus (native_reload_active).
    local on = (hwid ~= nil) and not TOP_LOADER[hwid]
    _G.__vr_manual_reload_consume_b = on

    -- [MAG_OUT] KEIN Heilen ueber loaded>0! "Mag physisch draussen" darf NICHT an den
    -- Ammo-Zaehler gekoppelt sein: mit Infinite Ammo / Engine-Refill ist loaded nach dem
    -- Drop sofort wieder >0 -> das hat mag_out faelschlich geloest und den Holster-Grab
    -- blockiert. mag_out wird NUR durch physisches Wieder-Einsetzen (Insert-Complete) ODER
    -- Waffenwechsel/Reset geloescht. [[feedback-no-cached-state-for-critical-gates]]

    -- [MAG_OUT] UI auf 0 HALTEN solange das Mag draussen ist (Anzeige, gegen Engine-Re-Sync).
    -- Der echte Stand ist in mag_retained gemerkt -> beim Insert kommt er zurueck. NICHT
    -- waehrend des Inserts (mag_insert.active), sonst wuerde der Fuell-Wert sofort genullt.
    if mag_out and not mag_insert.active then
        local wi = get_live_weapon_item()
        if wi and (sc(wi, "get_CurrentAmmoCount") or 0) > 0 then
            _G.__re4_carry_capture(wi, "re4_vr_reload4_dlc.lua:3584", nil)   -- [MAG-REST] merken, bevor genullt wird
            pcall(function() wi:write_dword(0x44, 0) end)
        end
    end

    -- [MAG_AVAIL] Fuer den Holster: gibt es ueberhaupt etwas zu greifen? (gemerkter Mag-Stand
    -- ODER Reserve > 0). Mag draussen + NICHTS da -> Holster sperren + Leer-Haptik.
    do
        if is_shotgun(wep.wid) then
            -- [SHOTGUN] Shell-Holster Sperr-Puls wenn Reserve leer ODER Roehre voll (loaded>=cap).
            -- Sonst offen (greifbar). Wie der Grab selbst (set_mag_in_hand) es auch blockt.
            local wifull = get_live_weapon_item()
            local lo = wifull and (sc(wifull, "get_CurrentAmmoCount") or 0) or 0
            local cp = wifull and (sc(wifull, "get_CurrentAmmoMax") or 0) or 0
            local full = (cp > 0 and lo >= cp)
            -- [STRIKER] Cycle ausstehend (rack.needs) -> Holster gesperrt (erst drehen). grab_empty=true
            -- -> der Holster-Modul feuert den gewohnten Sperr-Haptic-Puls. Nur ROTARY_CYCLE-Waffen.
            local rotary_block = (ROTARY_CYCLE[wep.wid] == true) and (rack.needs == true)
            -- [SKULL SHAKER] Holster gesperrt (Sperr-Puls) solange der Hebel ZU ist (erst aufklappen).
            local break_block = (BREAK_ACTION[wep.wid] == true) and not (rawget(_G, "__vr_break_open") == true)
            _G.__re4_reload_grab_empty = (not mag_hand.active and not mag_insert.active and (current_reserve() <= 0 or full or rotary_block or break_block))
        elseif TOP_LOADER[wep.wid] then
            -- [TOP_LOADER] Red9: kein mag_out-Konzept -> Verfuegbarkeit haengt NUR an der Reserve.
            -- Holster immer greifbar wenn Reserve>0, sonst Leer-Puls (grab_empty=true).
            _G.__re4_reload_grab_empty = (not mag_hand.active and not mag_insert.active and current_reserve() <= 0)
        else
            local avail = false
            if mag_out and not mag_hand.active and not mag_insert.active then
                local reserve = 0
                local wi = get_live_weapon_item()
                local ammo_id = wi and safe(function() return wi:call("get_CurrentAmmo") end)
                local pe2 = get_pe(); local inv2 = pe2 and sc(pe2, "get_InventoryController")
                if inv2 and ammo_id then
                    reserve = tonumber(safe(function() return _G.__re4_item_count_sum(inv2, ammo_id) end)) or 0
                end
                avail = ((mag_retained or 0) + reserve) > 0
            end
            _G.__re4_reload_grab_empty = (mag_out and not mag_hand.active and not mag_insert.active and not avail)
        end
    end

    -- Slide-Rack: Empty-Block pflegen + Rack-Geste auswerten
    update_rack_state()
    -- [STAGGER_HEAL 2026-07-19] Stagger-Ende (fallende Flanke von __re4_damage_active, vom killswitch) ->
    -- Slide zu + fire-ready wie ein Waffenwechsel. Behebt "Slide steckt hinten, wenn man mitten im Slide-Rack
    -- staggered wird". clear_rack snappt slide_joint auf rest_z + setzt _chambered_hold (haelt bis 1. Schuss).
    -- Nur bei Slide-Waffe (wep.slide_joint). Kein neuer Local (rack._prev_damage = Feld) -- reload.lua am 200-Limit.
    -- [SLIDE-STAGGER-GUARD 2026-07-20] Wie bei der Red9: wird man mitten im Slide-Rack getroffen,
    -- bleibt der Slide irgendwo hinten stehen (Engine zieht ihn auf ihren eigenen Wert). Der Killswitch
    -- stempelt das Damage-ENDE (__re4_damage_end_t) -- diese Funktion laeuft waehrend des Staggers gar
    -- nicht (Engine meldet keine Waffe), kann die Flanke also nicht selbst sehen.
    -- WICHTIG (Lehre vom 2026-07-20): NICHT clear_rack rufen! Das chambert intern die Waffe und nimmt
    -- den Rack-Zwang mit -> man koennte nach dem Nachladen ohne Rack weiterfeuern. Hier NUR die
    -- Slide-Position korrigieren, und auch das nur, wenn KEIN Rack aussteht (steht eins an, gehoert der
    -- Slide korrekt nach hinten). Genau einmal pro Stempel.
    do
        local det = tonumber(rawget(_G, "__re4_damage_end_t"))
        if det and rack._heal_done_t ~= det and (os.clock() - det) < 3.0
           and not rack.needs and not rack.empty and not mag_out and wep.slide_joint then
            rack._heal_done_t = det
            local sp  = slide_pose(wep.wid or 0)
            local cur = sc(wep.slide_joint, "get_LocalPosition")
            if sp and cur then
                pcall(function() wep.slide_joint:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp.rest_z)) end)
            end
            rack.grab_active = false; rack.pulled = false; rack.pushed = false; rack.frac = 0
            -- [HALTEN 2026-07-20] Ein einmaliger Snap reicht NICHT: apply_slide_park laesst den
            -- Slide danach wieder los ("AUS (Engine haelt den Slide)") und die Engine zieht ihn erneut
            -- nach hinten (gemessen 0.0579, noch hinter back_z). _chambered_hold haelt ihn auf rest_z,
            -- bis der erste Schuss faellt -- genau wie nach einem normalen Rack. Chambert NICHTS an der
            -- Engine (das macht nur gun_chamber in clear_rack), nimmt also keinen Rack-Zwang mit.
            rack._chambered_hold = true
        end
    end
    service_haptics()    -- [SHOTGUN PUMP] verzoegerte Pump-Haptik faellig? -> feuern
    update_rack_gesture()
    update_rotary_cycle()   -- [ROTARY_CYCLE] Striker-Drehschalter (early-return fuer Nicht-Rotary-Waffen)
    update_break_action()   -- [BREAK_ACTION] Skull Shaker Klapphebel (early-return fuer Nicht-Break-Waffen)
    update_break_pump_sound()   -- [BREAK_PUMP_SND] 2x Klapp-Sound waehrend der nativen PumpAction-Anim
    -- [IK-GATE] AUTORITATIV jeden Frame publizieren (update_rack_state hat fruehe returns -> dort
    -- konnte das Global auf true haengen bleiben = IK fuer die Waffe tot bis Wechsel). Hier nie stuck.
    _G.__vr_slide_rack_active = (rack.grab_active) == true   -- [SLIDE_RACK] Rack-Freeze nur fuer Z-Slide-Waffen. [SKULL SHAKER] break_open friert NICHT mehr ein (Klappe auf = Gun bleibt frei beweglich) -- __vr_break_open ist nur bei 6001 je true, daher gekapselt
    _G.__vr_empty_reload_active = rack.empty_reload == true   -- [EMPTY-RELOAD RACK] Riot Gun _08-Zug: Gun NICHT einfrieren (motion liest das) -> folgt der Hand statt starr zu stehen
    -- [MAG-DOCK-LOCK] AUTORITATIV jeden Frame: linke Hand haelt gerade Mag/Shell (oder Insert laeuft,
    -- oder <0.2s nach dem letzten Ammo-Input) -> die Support-Hand darf NICHT an den Schaft docken
    -- (sonst springt die "volle" Hand vorne auf den Vordergriff). motion.lua liest dieses Global.
    _G.__vr_mag_in_hand = (mag_hand.active or mag_insert.active
        or (rack._ammo_input_t and (os.clock() - rack._ammo_input_t) < 0.2)) and true or false
    -- [SHELL-KEYFRAMES 2026-07-24] Shell-Joint + Waffen-Transform + wid fuer die Keyframe-UI/Preview
    -- in reload_adv exponieren (jeden Frame, damit die Vorschau auch ohne laufenden Insert greift).
    _G.__re4_reload_shell_joint = wep.mag_joint
    _G.__re4_reload_weapon_tf   = wep.tf
    _G.__re4_reload_ui_wid      = wep.wid
    update_shell_eject() -- [SHELL_EJECT] Flug-State fortschreiben (nach rack.pulled gesetzt ist)
    update_dock_blend()  -- [DOCK_LERP] Blend 1x/Frame rampen (vor publish_dock)
    publish_dock()  -- IK-Dock-Ziel fuer arm_chain (Hand an den Slide) waehrend gegriffen

    -- [SHELL_PART] enabled-Part-Set bei loaded>0 merken + bei 0 den Shell-Part-Diff bilden
    -- (1x/Frame; das eigentliche Einschalten passiert im vollen Override-Stack via sg_force_shell_parts).
    -- Riot Gun ueber EMPTY_RELOAD_JOINT, Break-Action (Skull Shaker) ueber SHELL_PART_LEARN -> sonst
    -- wird sg_update_parts fuer 6001 NIE aufgerufen und der Shell-Part nie gelernt (Shell unsichtbar).
    if EMPTY_RELOAD_JOINT[wep.wid] or SHELL_PART_LEARN[wep.wid] then
        local wi = get_live_weapon_item()
        local loaded = wi and tonumber(safe(function() return wi:call("get_CurrentAmmoCount") end))
        sg_update_parts(loaded)
    end

    -- [SND] Mag-Boden-Sound verzoegert: bei Drop-START (Auswurf ODER Holster-Release-
    -- Fall) Timer setzen, nach mag_floor_delay einmalig abspielen (Mag knallt auf Boden).
    if drop.active and not _drop_prev then
        _mag_floor_at = os.clock() + (CFG.mag_floor_delay or 0.45)
    end
    _drop_prev = drop.active
    if _mag_floor_at > 0 and os.clock() >= _mag_floor_at then
        _mag_floor_at = 0
        play_weapon_sound(snd("mag_floor"))
    end
    -- [SND] Dry-Fire: leere/gesperrte Waffe + Schuss-Trigger gezogen (Flanke vom Binding).
    local et = rawget(_G, "__re4_empty_trigger_held") == true
    if et and not _empty_trig_prev then play_weapon_sound(snd("dry_fire")) end
    _empty_trig_prev = et

    -- B-Flanke -> ROBUSTER Mag-Auswurf. Niemals blockiert: force_eject raeumt
    -- jeden Zwischenzustand ab und startet immer einen frischen Drop.
    local bd = right_b_down()
    if on and bd and not _b_prev then
        -- [SHOTGUN] Kein B-Eject: die Shotgun wirft kein Mag aus, das Pumpen macht die linke Hand
        -- (Pump = slide=_01 ueber das Slide-Rack-System). B bleibt fuer Shotguns wirkungslos.
        if is_shotgun(wep.wid) then
            -- nichts
        elseif CHAMBER[wep.wid] then toggle_chamber() else force_eject() end
    end
    _b_prev = bd
end)

-- Joint-Write NACH der Engine-Pose (sonst clobbert die Engine den Drop)
-- [MAG_OUT] Mag-Mesh aus der Kammer halten solange das Mag "draussen" ist (persistenter
-- Drop ueber Waffenwechsel). Engine setzt das Mag beim Equip neu in die Kammer -> wir
-- skalieren den Mag-Joint jeden Frame auf 0 (unsichtbar). NUR wenn kein Flow laeuft:
-- Drop-Animation/Mag-in-Hand/Insert duerfen das Mag normal zeigen.
local mag_hidden_applied = false
local function apply_mag_out_hidden()
    -- [TUNE-SICHTBAR 2026-07-19] mag_tune.active MUSS hier mit rein: sonst wird das Mag im
    -- Einstell-Modus auf Scale 0 gesetzt (unsichtbar), waehrend update_mag_in_hand es brav an die
    -- Hand zieht -> der Toggle "Mag in Hand halten" zeigte bei mag_out=true schlicht nichts.
    local should_hide = mag_out and wep.mag_joint
        and not drop.active and not mag_hand.active and not mag_insert.active
        and not mag_tune.active
    if should_hide then
        pcall(function() wep.mag_joint:call("set_LocalScale", Vector3f.new(0, 0, 0)) end)
        mag_hidden_applied = true
    elseif mag_hidden_applied then
        -- wieder einblenden sobald draussen-Zustand endet ODER ein Flow das Mag zeigt
        if wep.mag_joint then
            pcall(function() wep.mag_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
        end
        mag_hidden_applied = false
    end
end

-- [SHELL_PART] (Riot Gun) Die gechamberte Shell ist ein Sub-Mesh-PART des Gun-Meshes. Die Engine
-- disabled diesen Part bei leerer Kammer (0) -> bei 0 ist nichts zum Anzeigen da (Bone-Scale-Force
-- reicht nicht). RE9-Mechanismus: setPartsEnable(part, true) am via.render.Mesh. Part-Index AUTOMATISCH
-- (Diff: enabled bei loaded>0 minus enabled bei 0 = der Shell-Part), kein Hardcode.
local _sg = { tf = nil, mesh = nil, e1 = nil, shell = nil, empty = false }
local _sg_shell_by_wid = SHELL_PARTS   -- [PERSIST] ermittelter Shell-Part-Index pro WeaponID (Modell-fix) -> ueberlebt Waffenwechsel UND (via Disk) Script-Reset
local function sg_mesh()
    if wep.tf ~= _sg.tf or not _sg.mesh then
        _sg.tf = wep.tf; _sg.mesh = nil; _sg.e1 = nil; _sg.empty = false
        -- [PERSIST] Part-Index aus dem Per-Waffe-Cache wiederherstellen: nach Wechsel-zurueck-bei-leer
        -- wuerde der Diff sonst nie laufen (Waffe war nie loaded>0 seit dem Wechsel) -> keine Shell.
        _sg.shell = _sg_shell_by_wid[wep.wid] or SHELL_PART_FIXED[wep.wid]
        local go = wep.tf and safe(function() return wep.tf:call("get_GameObject") end)
        if go then _sg.mesh = safe(function() return go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh")) end) end
    end
    return _sg.mesh
end
local function sg_part_on(m, i)
    local v; pcall(function() v = m:call("getPartsEnable", i) end); return v == true
end
-- on_frame: e1 (enabled-Set bei loaded>0) EINMAL merken; den Shell-Part EINMAL per Diff ermitteln und
-- dann STABIL behalten (NICHT bei jedem Reload neu diffen -> nach dem 1. Chambern wuerde der Diff leer).
-- Der Part-Index ist fix (gleiches Gun-Modell). _sg.empty = Kammer leer (steuert das Force unten). (forward-declared)
sg_update_parts = function(loaded)
    if not (EMPTY_RELOAD_JOINT[wep.wid] or SHELL_PART_LEARN[wep.wid]) then return end   -- [SHELL_PART_FIX] auch Break-Action (Skull Shaker) lernt den Shell-Part
    local m = sg_mesh(); if not m then return end
    -- Gate auf KAMMER leer (rack.empty=isGunAmmoEmpty), NICHT loaded==0: nach der 1. Shell ist loaded=1
    -- (Roehre), aber die Kammer ist bis zum _08-Rack leer -> sonst zeigt die 2. Shell nicht.
    _sg.empty = (rack.empty == true)
    if loaded and loaded > 0 and not _sg.empty then
        -- e1 nur bei voller Kammer erfassen (Kammer-Shell-Part ist dann AN -> im Set enthalten).
        if not _sg.e1 then
            local set = {}
            for i = 0, 255 do if sg_part_on(m, i) then set[#set+1] = i end end
            _sg.e1 = set
        end
    elseif _sg.empty and _sg.e1 and (not _sg.shell or #_sg.shell == 0) then
        -- Shell-Part EINMAL bestimmen (nachlaufen bis nicht leer; Engine disabled evtl. 1-2 Frames spaeter).
        -- Danach bleibt _sg.shell stehen -> jede weitere Shell bei 0 nutzt denselben Part.
        local sh = {}
        for _, p in ipairs(_sg.e1) do if not sg_part_on(m, p) then sh[#sh+1] = p end end
        if #sh > 0 then
            _sg.shell = sh; _sg_shell_by_wid[wep.wid] = sh   -- [PERSIST] Index merken -> ueberlebt Waffenwechsel
            pcall(save_cfg)   -- [SHELL_PART_PERSIST] frisch gelernten Index auf Disk -> reset-fest (einmalig pro Waffe)
        end
    end
end
-- apply_slide_pass: Shell-Part-Sichtbarkeit steuern (forward-declared, voller Override-Stack).
-- on=true (Shell in der Hand): IMMER sichtbar erzwingen, egal ob Kammer leer ODER voll -> sonst ist
-- die getragene Huelse beim Nachladen mit voller Kammer weg (z.B. 2. Shell NACH dem Chamber-Rack).
-- on=false (nicht getragen): nur bei LEERER Kammer (_sg.empty) ausschalten (Phantom-Huelse weg);
-- bei voller Kammer NICHTS anfassen -> die Engine zeigt die gechamberte Huelse selbst.
sg_force_shell_parts = function(on)
    local m = sg_mesh(); if not m then return end   -- ZUERST: sg_mesh kann _sg (inkl. _sg.shell) bei Waffenwechsel reset/restore
    if not _sg.shell or #_sg.shell == 0 then return end   -- NACH sg_mesh pruefen -> nie nil in der Schleife
    if not on and not _sg.empty then return end   -- volle Kammer + nicht getragen -> Engine machen lassen
    for _, p in ipairs(_sg.shell) do
        pcall(function() m:call("setPartsEnable(System.UInt64, System.Boolean)", p, on and true or false) end)
    end
end

-- ---------------------------------------------------------------------
-- [SHELL_SPAWN] Getragene Huelse als EIGENE Instanz (Waffen ohne statischen Shell-Part, z.B.
-- Break-Action: Engine generiert die Huelse via ShotgunShellGenerator prozedural -> bei 0 Ammo
-- nichts da). Wir instanziieren das Shell-Prefab der Waffe (Generator._UserData._Prefab) einmal
-- und docken die Instanz an die _04-Joint-Weltpose (folgt via mag_to_hand bereits der Hand).
-- ---------------------------------------------------------------------
local _spawn = { go = nil, tf = nil, wid = nil }
local _go_destroy = nil
do
    local t = sdk.find_type_definition("via.GameObject")
    _go_destroy = t and t:get_method("destroy(via.GameObject)")
end
local function destroy_spawn_go()
    if _spawn.go and _go_destroy then pcall(function() _go_destroy:call(nil, _spawn.go) end) end
    _spawn.go, _spawn.tf = nil, nil
end
-- Generator-Komponente der equippten Waffe (child-GO "ShotgunShellGeneratorBase").
-- ROBUST per Typ-Name: die Komponente kann chainsaw.ShotgunShellGenerator ODER die GmActor-
-- Subklasse sein -> getComponent(exakter Typ) wuerde die andere verfehlen. Wir matchen "ShellGenerator".
local function find_shell_generator()
    if not wep.tf then return nil end
    local child = sc(wep.tf, "get_Child"); local n = 0
    while child and n < 64 do
        n = n + 1
        local go = sc(child, "get_GameObject")
        local nm = go and sc(go, "get_Name")
        if nm and tostring(nm):find("ShellGenerator", 1, true) then
            local comps = safe(function() return go:call("get_Components") end)
            if comps then
                for _, c in ipairs(comps) do
                    local td = safe(function() return c:get_type_definition() end)
                    local tn = td and safe(function() return td:get_full_name() end)
                    if tn and tn:find("ShellGenerator", 1, true) then return c end
                end
            end
        end
        child = sc(child, "get_Next")
    end
    return nil
end
-- Shell-Instanz sicherstellen (einmal pro Waffe aus dem Prefab des Generators erzeugen).
local function ensure_shell_spawn()
    if _spawn.go and _spawn.wid == wep.wid and safe(function() return _spawn.go:call("get_Valid") end) then
        return _spawn.go
    end
    if _spawn.go and _spawn.wid ~= wep.wid then destroy_spawn_go() end
    local gen = find_shell_generator(); if not gen then _G.__re4_shellspawn_dbg = "no_generator"; return nil end
    local ud = safe(function() return gen:call("get_UserData") end); if not ud then _G.__re4_shellspawn_dbg = "no_userdata"; return nil end
    local prefab = safe(function() return ud:get_field("_Prefab") end); if not prefab then _G.__re4_shellspawn_dbg = "no_prefab"; return nil end
    if safe(function() return prefab:call("get_Ready") end) == false then _G.__re4_shellspawn_dbg = "prefab_not_ready"; return nil end
    local pos = sc(wep.mag_joint, "get_Position") or rawget(_G, "__vr_lh_world") or sc(wep.tf, "get_Position")
    if not pos then _G.__re4_shellspawn_dbg = "no_pos"; return nil end
    local rot = rawget(_G, "__vr_lh_rot") or Quaternion.new(1, 0, 0, 0)
    local go = safe(function() return prefab:call("instantiate(via.vec3, via.Quaternion)", pos, rot) end)
    if not go then _G.__re4_shellspawn_dbg = "instantiate_nil"; return nil end
    pcall(function() go:call("set_UpdateSelf", false) end)   -- Shell-Script/Physik aus -> reine Optik, Transform steuern WIR
    _spawn.go = go; _spawn.tf = sc(go, "get_Transform"); _spawn.wid = wep.wid
    _G.__re4_shellspawn_dbg = "SPAWNED ok"
    return go
end
-- Per-Frame: beim Tragen die Shell-Instanz an die _04-Joint-Weltpose docken, sonst verstecken.
update_shell_spawn = function()
    if not (wep.wid and SHELL_SPAWN[wep.wid]) then
        if _spawn.go then destroy_spawn_go() end
        return
    end
    local carrying = (mag_hand.active or mag_insert.active) and wep.mag_joint
    if not carrying then
        if _spawn.go then pcall(function() _spawn.go:call("set_DrawSelf", false) end) end
        return
    end
    local go = ensure_shell_spawn(); if not go or not _spawn.tf then return end
    local jp = sc(wep.mag_joint, "get_Position")
    local jr = sc(wep.mag_joint, "get_Rotation")
    if jp then pcall(function() _spawn.tf:call("set_Position", jp) end) end
    if jr then pcall(function() _spawn.tf:call("set_Rotation", jr) end) end
    pcall(function() go:call("set_DrawSelf", true) end)
end

-- [SHELL_CLONE] Skull Shaker (6001): getragene Shell = MESH-CLONE von Part 1 an der linken Hand.
-- Ersetzt die gespawnte Prefab. Technik wie reload2-Revolver (via.motion.Motion baut Skelett +
-- via.render.Mesh + setMesh(lebender Gun-Holder) + Gun-Material + Part isolieren). Offsets aus dem
-- Global _G.__re4_ss_clone_dlc. Ganzer Block als IIFE (sofort aufgerufene Funktion) -> EIGENER Scope,
-- KEIN Main-Chunk-Local (reload.lua ist am 200-Local-Limit; ein do-Block wuerde die 7 Locals zum
-- Main-Chunk zaehlen und ihn ueberlaufen lassen). Die Hook-Closures (ss_apply) ueberleben.
-- Siehe Notiz.
;(function()
    local SS_WID = 6001
    local ssc = { obj = nil, mesh = nil, parts_sig = nil }
    local function ss_gun_mesh()
        if not wep.tf then return nil end
        local go = sc(wep.tf, "get_GameObject")
        return go and sc(go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    end
    local function ss_destroy()
        if ssc.obj then pcall(function()
            local td = sdk.find_type_definition("via.GameObject"); local d = td and td:get_method("destroy(via.GameObject)")
            if d then d:call(nil, ssc.obj) end
        end) end
        ssc.obj, ssc.mesh, ssc.parts_sig = nil, nil, nil
    end
    local function ss_spawn()
        if ssc.obj then return true end
        local gmesh = ss_gun_mesh(); if not gmesh then return false end
        local holder = safe(function() return gmesh:call("getMesh") end); if not holder then return false end
        local gmat = safe(function() return gmesh:call("get_Material") end)
        local go_td = sdk.find_type_definition("via.GameObject")
        local create = go_td and go_td:get_method("create(System.String)")
        local go = create and safe(function() return create:call(nil, "vr_ss_shell") end); if not go then return false end
        pcall(function() go:add_ref() end)
        pcall(function() go:call("createComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)   -- KERN: baut Skelett
        local mesh = safe(function() return go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
        if not mesh then return false end
        pcall(function() mesh:call("setMesh", holder) end)
        if gmat then pcall(function() mesh:call("set_Material", gmat) end) end
        pcall(function() mesh:call("set_DrawDefault", true) end)
        pcall(function() mesh:call("set_Enabled", true) end)
        pcall(function() mesh:call("set_FrustumCulling", false) end)
        ssc.obj, ssc.mesh = go, mesh
        -- [NO_LAG] nativ ans L_Hand-Joint parenten (wie Holster-Fix): Engine propagiert die Transform VOR
        -- dem Skinning -> kein 3-4-Frame-Render-Versatz beim Laufen. Danach nur noch LOKALE Pose setzen.
        ssc.parented = false
        local ctf = safe(function() return go:call("get_Transform") end)
        local bt2 = body_tf()
        if ctf and bt2 then
            pcall(function() ctf:call("set_Parent", bt2) end)
            if pcall(function() ctf:call("set_ParentJoint", "L_Hand") end) then ssc.parented = true end
        end
        return true
    end
    local function ss_isolate()
        if not ssc.mesh then return end
        local part = math.floor((_G.__re4_ss_clone_dlc.part or 1) + 0.5)
        local sig = "part:" .. tostring(part)
        if ssc.parts_sig == sig then return end
        local applied = true
        for i = 0, 48 do
            if not pcall(function() ssc.mesh:call("setPartsEnable", i, i == part) end) then applied = false end
        end
        if applied then ssc.parts_sig = sig end
    end
    -- NUR Position/Rotation/Scale auf die aktuelle L_Hand ziehen (kein Spawn/Isolate). Von beiden
    -- Paessen genutzt -> im POST schlank wie reload2s reposition_cart_late.
    local function ss_place()
        if not ssc.obj then return end
        local cfg = _G.__re4_ss_clone_dlc
        local tf = safe(function() return ssc.obj:call("get_Transform") end); if not tf then return end
        local scl = cfg.scale or 1.0
        -- [NO_LAG] geparentet ans L_Hand: nur LOKALE Pose setzen (Offset = wie vorher hand-relativ),
        -- die Engine macht die Welt-Position -> kein Render-Versatz beim Laufen.
        if ssc.parented then
            pcall(function() tf:call("set_LocalPosition", Vector3f.new(cfg.x or 0, cfg.y or 0, cfg.z or 0)) end)
            pcall(function() tf:call("set_LocalRotation", quat_from_euler(cfg.rx or 0, cfg.ry or 0, cfg.rz or 0)) end)
            pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
            return
        end
        -- Fallback (nicht geparentet): alter Welt-Weg.
        local bt = body_tf(); local lhj = bt and sc(bt, "getJointByName", "L_Hand")
        local hp = lhj and sc(lhj, "get_Position"); if not hp then return end
        local hr = lhj and sc(lhj, "get_Rotation")
        local wx, wy, wz = hp.x, hp.y, hp.z
        if hr then
            local off = safe(function() return hr * Vector3f.new(cfg.x or 0, cfg.y or 0, cfg.z or 0) end)
            if off then wx, wy, wz = hp.x + off.x, hp.y + off.y, hp.z + off.z end
        end
        local rot = hr and safe(function() return (hr * quat_from_euler(cfg.rx or 0, cfg.ry or 0, cfg.rz or 0)):normalized() end)
        local okp = pcall(function() tf:set_position(Vector3f.new(wx, wy, wz), true) end)   -- no_dirty gegen Jitter
        if not okp then pcall(function() tf:call("set_Position", Vector3f.new(wx, wy, wz)) end) end
        if rot then local okr = pcall(function() tf:set_rotation(rot) end); if not okr then pcall(function() tf:call("set_Rotation", rot) end) end end
        pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
    end
    -- [KEYFRAME-PROGRAMM 2026-07-24] Skull Shaker in die reload_adv-Keyframe-Bahn holen. Der Clone
    -- bleibt an der L_Hand geparentet (bewaehrt sichtbar), wird im Keyframe-Modus aber per WELT-Pose an die
    -- WAFFENRELATIVE Bahn gesetzt (gr*off relativ zu wep.tf) -- exakt das Red9-Muster (r9_update_insert),
    -- das an einem hand-geparenteten Clone zuverlaessig rendert. Preview haelt an der Tuning-Lage
    -- (ms.shell_live), der Insert faehrt shell_pose_at(6001, t) ab.
    -- Rueckgabe: px,py,pz,rx,ry,rz (waffenrelativ) oder nil, wenn kein Keyframe-Modus.
    local function ss_kf_pose()
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if not (ms and ms.KEYFRAME_INSERT and ms.KEYFRAME_INSERT[SS_WID] == true) then return nil end
        local kf_preview = rawget(_G, "__re4_shell_kf_preview") == SS_WID
        local kf_insert  = mag_insert.active == true and type(ms.has_shell_keys) == "function" and ms.has_shell_keys(SS_WID) == true
        if not (kf_preview or kf_insert) then return nil end
        if kf_insert and type(ms.shell_pose_at) == "function" then
            local dur = tonumber(mag_insert.dur) or tonumber(ms.shell_dur) or 0.4
            local t = (os.clock() - (mag_insert.t0 or 0)) / math.max(dur, 0.01); if t > 1.0 then t = 1.0 end
            local x, y, z, rx, ry, rz = ms.shell_pose_at(SS_WID, t)
            if x then return x, y, z, rx, ry, rz end
        end
        if kf_preview then
            local s = ms.shell_live or {}
            return s.x or 0, s.y or 0, s.z or 0, s.rx or 0, s.ry or 0, s.rz or 0
        end
        return nil
    end
    -- Clone an die waffenrelative Keyframe-Pose setzen: WELT-Pose (auch am hand-geparenteten Clone, wie r9_set_tf).
    local function ss_place_kf(px, py, pz, rx, ry, rz)
        if not (ssc.obj and wep.tf) then return end
        local tf = safe(function() return ssc.obj:call("get_Transform") end); if not tf then return end
        local gp = sc(wep.tf, "get_Position"); local gr = sc(wep.tf, "get_Rotation"); if not (gp and gr) then return end
        local cfg = _G.__re4_ss_clone_dlc; local scl = cfg.scale or 1.0
        local off = safe(function() return gr * Vector3f.new(px, py, pz) end)
        local wx, wy, wz = gp.x, gp.y, gp.z
        if off then wx, wy, wz = gp.x + off.x, gp.y + off.y, gp.z + off.z end
        local rot = safe(function() return (gr * quat_from_euler(rx, ry, rz)):normalized() end)
        local okp = pcall(function() tf:set_position(Vector3f.new(wx, wy, wz), true) end)
        if not okp then pcall(function() tf:call("set_Position", Vector3f.new(wx, wy, wz)) end) end
        if rot then local okr = pcall(function() tf:set_rotation(rot) end); if not okr then pcall(function() tf:call("set_Rotation", rot) end) end end
        pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
    end
    -- Voller Pass (4 Nicht-POST-Paesse): Spawn/Isolate/Destroy + Positionieren.
    local function ss_apply()
        if not CFG.enabled or wep.wid ~= SS_WID then if ssc.obj then ss_destroy() end return end
        local cfg = _G.__re4_ss_clone_dlc
        local kf_prev = rawget(_G, "__re4_shell_kf_preview") == SS_WID   -- [KEYFRAME-PROGRAMM] reload_adv-Preview blendet den Clone ein
        local show = mag_hand.active or mag_insert.active or cfg.preview or kf_prev
        if not show then if ssc.obj then ss_destroy() end return end
        if not ssc.obj then if not ss_spawn() then return end end
        ss_isolate()
        local kx, ky, kz, krx, kry, krz = ss_kf_pose()
        if kx then ss_place_kf(kx, ky, kz, krx, kry, krz) else ss_place() end
    end
    -- [WOBBLE-FIX] BeginRendering-POST: NUR nachziehen, NACH motion.lua's finalem L_Hand-Write
    -- (attach_left_hand im POST). Schlank wie reload2s reposition_cart_late -> kein Spawn/Isolate im POST.
    local function ss_repos_late()
        if not ssc.obj or wep.wid ~= SS_WID then return end
        local cfg = _G.__re4_ss_clone_dlc
        local kf_prev = rawget(_G, "__re4_shell_kf_preview") == SS_WID
        if not (mag_hand.active or mag_insert.active or cfg.preview or kf_prev) then return end
        local kx, ky, kz, krx, kry, krz = ss_kf_pose()
        if kx then ss_place_kf(kx, ky, kz, krx, kry, krz) else ss_place() end
    end
    -- voller Override-Stack; POST = schlanke Reposition NACH motion (gegen Wabbeln)
    pcall(function() re.on_pre_application_entry("LockScene", ss_apply) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", ss_apply) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", ss_apply) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", ss_apply) end)
    pcall(function() re.on_application_entry("BeginRendering", ss_repos_late) end)
end)()

-- [SHELL_CLONE SAWED-OFF 2026-07-24] Sawed-off W-870 (6100): die native _04-Shell ist beim
-- Keyframe-Preview nicht sichtbar (Shell-Part nie gelernt, Engine skaliert leere Kammer auf 0). Wie in
-- reload5 spawnen wir stattdessen die getragene Huelse als EIGENE Mesh-Instanz (Gun-Mesh geklont, ein
-- Part isoliert) und positionieren sie an der Keyframe-Bahn (Preview = Tuning-Lage, Insert = Bahn abfahren).
-- Part-Index + Scale kommen als Globals aus reload_adv (Slider im Keyframe-Tree). Eigener IIFE-Scope
-- (kein Main-Chunk-Local -> Datei ist am 200-Local-Limit). Siehe Notiz.
;(function()
    local SO_WID = 6100
    local soc = { obj = nil, mesh = nil, parts_sig = nil }
    local function so_gun_mesh()
        if not wep.tf then return nil end
        local go = sc(wep.tf, "get_GameObject")
        return go and sc(go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    end
    local function so_destroy()
        if soc.obj then pcall(function()
            local td = sdk.find_type_definition("via.GameObject"); local d = td and td:get_method("destroy(via.GameObject)")
            if d then d:call(nil, soc.obj) end
        end) end
        soc.obj, soc.mesh, soc.parts_sig = nil, nil, nil
    end
    local function so_spawn()
        if soc.obj then return true end
        local gmesh = so_gun_mesh(); if not gmesh then return false end
        local holder = safe(function() return gmesh:call("getMesh") end); if not holder then return false end
        local gmat = safe(function() return gmesh:call("get_Material") end)
        local go_td = sdk.find_type_definition("via.GameObject")
        local create = go_td and go_td:get_method("create(System.String)")
        local go = create and safe(function() return create:call(nil, "vr_so_shell") end); if not go then return false end
        pcall(function() go:add_ref() end)
        pcall(function() go:call("createComponent(System.Type)", sdk.typeof("via.motion.Motion")) end)   -- KERN: baut Skelett
        local mesh = safe(function() return go:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh")) end)
        if not mesh then return false end
        pcall(function() mesh:call("setMesh", holder) end)
        if gmat then pcall(function() mesh:call("set_Material", gmat) end) end
        pcall(function() mesh:call("set_DrawDefault", true) end)
        pcall(function() mesh:call("set_Enabled", true) end)
        pcall(function() mesh:call("set_FrustumCulling", false) end)
        soc.obj, soc.mesh = go, mesh
        -- [SCENE-PARENT 2026-07-24] Der Clone MUSS in den Szenen-Graph, sonst rendert das geskinnte
        -- Mesh nicht (nur create = Objekt existiert, zeichnet aber nichts). Alle anderen Clones im Projekt
        -- parenten (Red9 an L_Hand, Bogen an die Waffe); der "ohne Hand"-Copy/Paste liess das weg -> unsichtbar.
        -- Hier an die WAFFEN-Transform parenten: lokaler Frame = Waffen-Root -> die Keyframes sind ohnehin
        -- waffenrelativ, so_place setzt danach nur noch die LOKALE Pose (klebt an der Waffe, kein Welt-Drift).
        soc.parented = false
        local ctf = safe(function() return go:call("get_Transform") end)
        if ctf and wep.tf then
            if pcall(function() ctf:call("set_Parent", wep.tf) end) then soc.parented = true end
        end
        return true
    end
    local function so_isolate()
        if not soc.mesh then return end
        local part = math.floor((tonumber(rawget(_G, "__re4_shell_clone_part")) or 1) + 0.5)
        local sig = "part:" .. tostring(part)
        if soc.parts_sig == sig then return end
        local applied = true
        for i = 0, 48 do
            if not pcall(function() soc.mesh:call("setPartsEnable", i, i == part) end) then applied = false end
        end
        if applied then soc.parts_sig = sig end
    end
    -- Position an der Keyframe-Bahn (relativ zur WAFFE, wie shell_preview_apply): World = wep.pos + wep.rot * off.
    local function so_place(px, py, pz, rx, ry, rz)
        if not soc.obj then return end
        local tf = safe(function() return soc.obj:call("get_Transform") end); if not tf then return end
        local scl = tonumber(rawget(_G, "__re4_shell_clone_scale")) or 1.0
        -- [SCENE-PARENT] An wep.tf geparentet -> lokaler Frame = Waffen-Root -> Keyframe-Pose DIREKT lokal
        -- setzen (identische Mathematik wie der alte gr*off-Welt-Weg, nur ohne Nachziehen/Drift).
        if soc.parented then
            pcall(function() tf:call("set_LocalPosition", Vector3f.new(px, py, pz)) end)
            pcall(function() tf:call("set_LocalRotation", quat_from_euler(rx, ry, rz)) end)
            pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
            return
        end
        -- Fallback (nicht geparentet): alter Welt-Weg relativ zur Waffe.
        if not wep.tf then return end
        local gp = sc(wep.tf, "get_Position"); local gr = sc(wep.tf, "get_Rotation"); if not (gp and gr) then return end
        local off = safe(function() return gr * Vector3f.new(px, py, pz) end)
        local wx, wy, wz = gp.x, gp.y, gp.z
        if off then wx, wy, wz = gp.x + off.x, gp.y + off.y, gp.z + off.z end
        local rot = safe(function() return (gr * quat_from_euler(rx, ry, rz)):normalized() end)
        pcall(function() tf:call("set_Position", Vector3f.new(wx, wy, wz)) end)
        if rot then pcall(function() tf:call("set_Rotation", rot) end) end
        pcall(function() tf:call("set_LocalScale", Vector3f.new(scl, scl, scl)) end)
    end
    local function so_apply()
        if not CFG.enabled or wep.wid ~= SO_WID then if soc.obj then so_destroy() end return end
        local ms = rawget(_G, "__re4_reload_mag_slide")
        if not ms then if soc.obj then so_destroy() end return end
        local preview   = rawget(_G, "__re4_shell_kf_preview") == SO_WID
        local inserting = mag_insert.active and mag_insert.keyframe
        if not (preview or inserting) then if soc.obj then so_destroy() end return end
        if not soc.obj then if not so_spawn() then return end end
        so_isolate()
        local px, py, pz, rx, ry, rz
        if inserting and type(ms.shell_pose_at) == "function" then
            local t = (os.clock() - mag_insert.t0) / math.max(mag_insert.dur, 0.01); if t > 1.0 then t = 1.0 end
            px, py, pz, rx, ry, rz = ms.shell_pose_at(SO_WID, t)
        end
        if not px then
            local s = ms.shell_live or {}
            px, py, pz, rx, ry, rz = s.x or 0, s.y or 0, s.z or 0, s.rx or 0, s.ry or 0, s.rz or 0
        end
        so_place(px, py, pz, rx, ry, rz)
    end
    pcall(function() re.on_pre_application_entry("LockScene", so_apply) end)
    pcall(function() re.on_application_entry("LateUpdateBehavior", so_apply) end)
    pcall(function() re.on_application_entry("UpdateJointExpression", so_apply) end)
    pcall(function() re.on_pre_application_entry("BeginRendering", so_apply) end)
    pcall(function() re.on_application_entry("BeginRendering", so_apply) end)
end)()

local function apply_drop_pass()
    if not CFG.enabled then return end
    update_mag_drop()
    update_mag_in_hand()
    update_mag_insert()
    apply_mag_out_hidden()
end
pcall(function() re.on_pre_application_entry("LockScene", apply_drop_pass) end)
pcall(function() re.on_application_entry("LateUpdateBehavior", apply_drop_pass) end)
pcall(function() re.on_application_entry("BeginRendering", apply_drop_pass) end)

-- [ENTKOPPEL_ROT/HMD] Der gedroppte Mag ist ein ANIMIERTER Waffen-Joint -> braucht den VOLLEN
-- Joint-Override-Stack (wie apply_slide_pass). Der Drop-Pass oben deckt nur LockScene-pre +
-- LateUpdateBehavior + BeginRendering-POST ab; es fehlten UpdateJointExpression + BeginRendering-PRE.
-- In UpdateJointExpression schreibt die Engine den Joint aus der HMD-gefuehrten Waffenpose zurueck ->
-- ohne unseren Write in diesem Pass wackelte das gefallene Mag mit dem Kopf. Nur der reine Drop-Write
-- (kein mag_in_hand/insert -> die haben eigenes POST-Timing gegen motion.lua).
local function apply_drop_joint_pass()
    if not CFG.enabled then return end
    if drop.active then update_mag_drop() end
end
pcall(function() re.on_application_entry("UpdateJointExpression", apply_drop_joint_pass) end)
pcall(function() re.on_pre_application_entry("BeginRendering", apply_drop_joint_pass) end)

-- Slide-Park + Joint-Finder schreiben ANIMIERTE Joints -> brauchen den VOLLEN
-- Joint-Override-Stack wie re4_vr_arm_chain.lua (LockScene-pre + LateUpdateBehavior
-- + UpdateJointExpression + BeginRendering-pre), sonst ueberschreibt die Engine den Write.
local function apply_slide_pass()
    if not CFG.enabled then return end
    -- [LET-GO] Joint-Writes (Chamber/Slide/Dock/Rack-Pose) NUR wenn die Waffe verwaltet ist.
    -- Toggle aus -> _managed=false -> wir schreiben NICHTS, die Engine kontrolliert die Waffe.
    if _managed then
        if CHAMBER[wep.wid] then apply_chamber() end   -- [TOP_LOADER] Chamber statt Slide
        apply_slide_park()
        -- [ROTARY/BREAK] slide-Joint ist eine Rotation (Striker Drehschalter _01 / Skull Shaker Klappe _02).
        -- Ruhe-Rotation um (rx,ry,rz)*prog drehen. prog 0 = Ruhe (Engine ueberlassen). prog-Quelle je Typ.
        if (ROTARY_CYCLE[wep.wid] or BREAK_ACTION[wep.wid]) and wep.slide_joint and wep.cycle_rest_rot then
            local p = ROTARY_CYCLE[wep.wid] and (rotary.prog or 0) or (break_st.prog or 0)
            if p > 0.0001 then
                local r = rotary_cfg(wep.wid)
                local q = quat_from_euler(r.rx * p, r.ry * p, r.rz * p)
                local newrot = safe(function() return (wep.cycle_rest_rot * q):normalized() end)
                if newrot then pcall(function() wep.slide_joint:call("set_LocalRotation", newrot) end) end
            end
        end
        -- [EMPTY-RELOAD SLIDE] _08-Lade-Slide ZU halten (rest_z = gechambert) WANN IMMER kein aktiver
        -- Empty-Reload-Zug laeuft. Die Engine schliesst den _08 nach dem manuellen Zug NICHT (wie der
        -- Pistolen-Slide) -> clear_rack snappt ihn nur 1x, danach zieht die Engine ihn wieder hinten.
        -- Hier im VOLLEN Override-Stack jeden Pass forcen. Waehrend des Zugs (rack.empty_reload) NICHT
        -- anfassen -> da treibt ihn apply_slide_park via frac. Per-Waffe (EMPTY_RELOAD_JOINT), kein _01.
        if EMPTY_RELOAD_JOINT[wep.wid] and wep.slide_joint2 and not rack.empty_reload then
            local cur = sc(wep.slide_joint2, "get_LocalPosition")
            if cur then
                local sp2 = slide_pose2(wep.wid or 0)
                pcall(function() wep.slide_joint2:call("set_LocalPosition", Vector3f.new(cur.x, cur.y, sp2.rest_z)) end)
            end
        end
        -- [SHELL_VISIBLE] Shell beim Tragen (Grab/Tuning/Insert) sichtbar erzwingen, im VOLLEN
        -- Override-Stack (dieser Pass laeuft auch in UpdateJointExpression + BeginRendering-pre):
        -- (1) _04-Bone-Scale auf 1 (Engine skaliert ihn bei leerer Kammer auf 0),
        -- (2) Shell-Sub-Mesh-PART einschalten (Engine disabled ihn bei 0 -> ohne das ist nichts da).
        if is_shotgun(wep.wid) and wep.wid ~= 6001 and wep.mag_joint and (mag_hand.active or mag_tune.active or mag_insert.active or rawget(_G, "__re4_shell_kf_preview") == wep.wid) then   -- [SHELL-KEYFRAMES] reload_adv-Keyframe-Preview blendet die Shell auch ohne Grab/Tuning ein (1 Toggle reicht)
            -- [SHELL_CLONE] Skull Shaker (6001) NICHT: dort ist die getragene Shell der Part-1-Clone,
            -- die gun-eigene _04-Shell bleibt versteckt (sonst doppelte Shell).
            pcall(function() wep.mag_joint:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
            sg_force_shell_parts(true)    -- Shell-Sub-Mesh-Part sichtbar (bei 0 sonst weg)
        else
            sg_force_shell_parts(false)   -- nicht getragen -> Shell-Part aus (leere Kammer zeigt keine Huelse)
        end
        apply_shell_eject()   -- [SHELL_EJECT] Shell in Chamber-Startposition (Preview/Flug)
        -- Dock-Ziel der Hand JEDEN Pass NACH dem Slide-Setzen frisch publizieren -> arm_chain
        -- liest in jedem der 4 Override-Paesse die aktuelle Slide-Position -> kein Nachhinken.
        publish_dock()
        apply_rack_hand_pose()   -- Finger-Pose bei Rack-Dock + im Einstell-Toggle
    end
    -- Finder ist ein UI-Tuning-Tool (nur aktiv wenn finder.active) -> unabhaengig von _managed.
    if not (rack.needs or rack.tuning) then apply_finder() end
end
pcall(function() re.on_pre_application_entry("LockScene", apply_slide_pass) end)
pcall(function() re.on_application_entry("LateUpdateBehavior", apply_slide_pass) end)
pcall(function() re.on_application_entry("UpdateJointExpression", apply_slide_pass) end)
pcall(function() re.on_pre_application_entry("BeginRendering", apply_slide_pass) end)

-- =====================================================================
-- UI (RE9-Struktur: per-Gattung Toggle, alles haengt daran)
-- =====================================================================
local function category_row(label, key)
    local c, v = imgui.checkbox("##mr_" .. key, CFG[key])
    imgui.same_line(); imgui.text_colored("Enable", 0xFF00FF00)
    imgui.same_line(); imgui.text(label)
    if c then CFG[key] = v; save_cfg() end
    return v
end

-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Reload 4 (Separate Ways)" raus (613 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- [GUN_DIAG] TEMP Gun-Diagnose-Log ENTFERNT (2026-07-03) -> war die 201. Top-Level-Local
-- (Limit 200 gesprengt, Script lud nicht mehr). Fokus liegt aufs [SLIDEBUG]-Log (Slide-Park-Bug).

load_cfg()
-- [POSE-STORE] importierte Posen (aus gestures.json) sofort in reload.json backen ->
-- damit die Daten in reload.json liegen und gestures.lua spaeter geloescht werden kann.
save_cfg()
-- Beim Script-Reload keinen stale Feuer-Block hinterlassen
_G.__vr_block_fire_when_empty = false
_G.__re4_bf_who = "re4_vr_reload4_dlc.lua:4201"   -- [BF-DIAG 2026-07-20] wer hat den Feuer-Block zuletzt gesetzt?
_G.__vr_needs_rack = false
_G.__vr_rack_block_left_knife = false
-- Fire-gecachtes Live-Item beim Reload leeren -> der get_CurrentAmmoCount-Hook akquiriert
-- das ECHTE Laufzeit-Item frisch neu (kein stale Item nach Reset Scripts).
_G.__re4_live_wi = nil

-- =====================================================================
-- [FIRE-GATE 2026-07-20 -- Ursache per Log+Live-Abfrage belegt]
-- PROBLEM: Unser Feuer-Block (f.RT weglassen) erreicht die Engine NICHT. Das VR-Framework reicht den
-- echten Controller-Trigger zusaetzlich direkt weiter -- belegt im Log: "SHOT von_uns=false
-- block_fire=true", also Schuss OHNE unser Gamepad. Bei den meisten Waffen faellt das nicht auf, weil
-- die Engine sie nach dem 0-Reload als leer fuehrt und dann von sich aus nicht feuert. Bei Adas
-- Blacktail AC chambert sie dagegen selbst (gemessen: getCurrentGunAmmo=0 UND isGunAmmoEmpty=false)
-- -> die echte Bremse faellt weg und nur unsere wirkungslose bleibt.
--
-- LOESUNG: Nicht den Trigger abfangen, sondern der Engine IHRE EIGENE Frage beantworten.
-- chainsaw.PlayerEquipment.isEnableFire ist die Pruefung des Spiels "darf jetzt gefeuert werden?".
-- Solange ein Rack aussteht, antworten wir false. Damit ist der Eingabeweg egal.
--
-- ABSICHERUNG (mehrfach, weil eine haengende Sperre = tote Waffe = gamebreaking):
-- * nur wenn dieses Modul die Waffe verwaltet (_managed)
-- * nur wenn wirklich ein Rack aussteht (rack.needs)
-- * nicht im Killswitch/KS4, nicht waehrend Mag-Flow (Drop/Hand/Insert)
-- * Not-Aus jederzeit: _G.__re4_fire_gate = false
-- ACHTUNG: sdk.hook -> erst nach GAME-NEUSTART aktiv, "Reset Scripts" genuegt NICHT.
-- =====================================================================
if not _G.__re4_fire_gate_hook then
    _G.__re4_fire_gate_hook = true
    _G.__re4_fire_gate = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        local m  = td and td:get_method("isEnableFire")
        if not m then return end
        sdk.hook(m,
            function() end,
            function(retval)
                local ok = pcall(function()
                    if rawget(_G, "__re4_fire_gate") ~= true then return end
                    if not _managed then return end
                    if not rack.needs then return end
                    if _G.__re4_holster_killswitch == true or rawget(_G, "__re4_ks4_active") == true then return end
                    if drop.active or mag_hand.active or mag_insert.active then return end
                    -- false zurueckgeben -> Engine feuert nicht, spielt ihren eigenen Dry-Fire
                    retval = sdk.to_ptr(0)
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
    if t == rawget(_G, "__re4_round_seen_reload4") then return end
    _G["__re4_round_seen_reload4"] = t

    _pe_cache = nil

    -- Ladezustand der letzten Runde: in der neuen ist die Waffe frisch.
    if type(rack) == "table" then
        rack.needs              = false
        rack.empty              = false
        rack.empty_when_dropped = false
        rack._zeroed_by_us      = false
        rack.empty_reload       = false
        rack.armed              = false
        rack.grab_active        = false
        rack.pulled             = false
        rack.pushed             = false
    end
end)
