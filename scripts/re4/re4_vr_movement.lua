-- ============================================================
-- RE4 VR Movement — PORTED TO C++
-- Builtin implementation: src/mods/vr/games/re4/RE4VRMovement.cpp
-- This Lua file is a no-op so leftover autorun copies cannot double-write
-- the player transform / joints.
-- ============================================================
return

if reframework:get_game_name() ~= "re4" then return end

local ok_ks, killswitch = pcall(function() return require("re4vr/re4_vr_killswitch") end)
if not ok_ks or not killswitch then
    killswitch = { is_active = function() return false end }
end

local function safe(fn)
    local ok, r = pcall(fn)
    return ok and r or nil
end

-- ---- Config (persistiert) ----
local CFG_PATH = "re4_vr/re4_vr_movement.json"

-- [SCOPE] Aim-Versatz PRO WAFFE x PRO ZUSTAND. 4 Zustaende (iron sight + 3 Scopes),
-- 4 Waffen (LE5/M1903/Stingray/CQBR). Pro Slot: x_r/z_r (Augen-Versatz rechts) + yaw (Bullet-Yaw-Gain).
-- Pitch-Gain ist GLOBAL (scope_pitch_gain), nicht hier.
-- [SW 2026-07-19] 6105 (Anti-Materiel = Stingray-Klon) + 6114 (Hunting Rifle = Bolt-Rifle-Klon)
-- MUESSEN hier stehen: zur LAUFZEIT gibt es KEINEN Fallback (scope_slot unten, ~1803: unbekannte wid
-- -> gar kein Versatz). Der `or "4401"`-Fallback existiert nur im UI -- deshalb sah das Menue vollstaendig
-- aus, waehrend im Spiel nichts griff. Startwerte sind in re4_vr_movement.json von 4401/4400 vorbelegt.
local SCOPE_WIDS   = { "4202", "4400", "4401", "4402", "6105", "6114" }   -- LE5, SR M1903, Stingray, CQBR, SW Anti-Materiel, SW Hunting Rifle
local SCOPE_STATES = { "ironsight", "normal", "thermal", "hipower" }
local function new_scope_slot() return { x_r = 0.0, z_r = 0.0, yaw = 0.0 } end
local function new_scope_sets()
    local t = {}
    for _, w in ipairs(SCOPE_WIDS) do
        t[w] = {}
        for _, s in ipairs(SCOPE_STATES) do t[w][s] = new_scope_slot() end
    end
    return t
end

local cfg = {
    enabled = true,
    -- [POSE_FREEZE 2026-08-11] Pose, die der Fork im Scope an den Compositor meldet:
    -- 0 = wie frueher, 1 = eingefrorene (Bild bleibt weltfest), 2 = frische (Bild klebt
    -- am Display). Regler steht bei den Scope-Werten; alte Builds ignorieren ihn.
    scope_submit_mode = 2,
    hmd_yaw_drive = true,    -- [HMD_YAW_DRIVE] _Yaw vom HMD treiben (konsolidiert aus re4_vr_hmd_movement.lua)
    yaw_offset_deg = 0.0,    -- zusätzlicher Yaw-Offset auf den Body (+ = links)
    -- [ROOMSCALE 2026-08-11] Sammelschalter fuer echtes Roomscale. AUS = jede Zeile
    -- verhaelt sich exakt wie bisher; die vorhandenen Regler werden nie ueberschrieben,
    -- sondern nur zur Laufzeit uebersteuert. Bekannte Einschraenkung, solange er an ist:
    -- es gibt KEINE Kollision -- physisch in eine Wand laufen schiebt den Body hindurch.
    -- Weitere Bausteine (Kopfhoehe->Ducken, Lean-Zone, Recentering) kommen einzeln dazu.
    roomscale = false,
    -- Unterpunkte, alle nur wirksam wenn `roomscale` an ist:
    -- [2026-08-11] Lehnen startet AUS: mit 0,25 m Radius verschluckt es normales Gehen im
    -- Spielbereich komplett -- der Charakter bewegt sich dann gar nicht mit. Wer lehnen
    -- will, schaltet es bewusst dazu und faengt klein an (~0,10 m).
    rs_lean = false,         -- Kopf darf den Body bis rs_lean_radius verlassen (Um-die-Ecke-lehnen)
    rs_lean_radius = 0.10,   -- m
    rs_recenter = true,      -- zusaetzliche Recentering-Ausloeser (Killswitch-Ende, Teleport)
    rs_crouch = false,       -- physisches Ducken loest den echten Hock-Zustand aus (drueckt B)
    rs_crouch_pct = 0.20,    -- Anteil der Standhoehe, ab dem "geduckt" gilt (0.20 = 20 % tiefer)
    rs_stand_height = 0.0,   -- kalibrierte Standhoehe des Users (0 = noch nie kalibriert)
    hmd_follow = true,       -- Body-Position folgt dem physischen HMD (RoomScale)
    hmd_follow_deadzone = 0.005, -- m, nur gegen Tracking-Rauschen
    hmd_follow_alpha = 0.25,     -- Anteil des Offsets der pro Frame übertragen wird (smooth, kein Stepping)
    hip_follow = true,           -- Hip-Yaw hart an den Stick koppeln (kein Anim-Nachlerpen)
    spine_yaw_deg = 0.0,         -- Yaw-Offset auf Spine_1/Spine_2/Neck_0/Neck_1 (synchron)
    ub_lock = false,             -- Oberkoerper steif (lokale Spine/Neck-Pose eingefroren)
    ub_trim_deg = 0.0,           -- Yaw-Trim auf die eingefrorene Torso-Pose (deg)
    ub_lock_world = true,        -- UB-Lock im Welt-Modus (Anim kann Block nicht kippen)
    spine_pin = true,            -- [SPINE_PIN] Torso-Kette hart auf Transform-
                                 -- relative Stand-Pose genagelt (Pos+Rot,
                                 -- keine Anim-Bewegung mehr)
    pin_z = {                    -- pro Wirbel: Verschiebung nach HINTEN (m,
                                 -- Transform-Z) auf die gepinnte Pose —
                                 -- gegen Schulter/Torso-ins-Bild beim Drehen
        Hip = 0.0,   -- verschiebt Huefte+BEINE — NUR IM RENNEN (jog/dash,
                     -- weich ein-/ausgeblendet); Beine animieren weiter,
                     -- Spine_0 wird gegenkompensiert (Oberkoerper steht)
        Spine_0 = 0.0, Spine_1 = 0.0, Spine_2 = 0.0,
        Neck_0 = 0.0, Neck_1 = 0.0, Head = 0.0,
    },
    pin_z_hip_walk = 0.0,        -- [HIP_WALK_Z] eigener "Beine nach hinten"-Wert NUR
                                 -- beim normalen Gehen (walk, weich geblendet) — analog
                                 -- zu pin_z.Hip (=Rennen), getrennt regelbar
    -- [HIP_CROUCH_Z SEPARAT 2026-07-22] Frueher galt pin_z.Hip fuer Rennen UND Crouch.
    -- Jetzt eigener Wert fuers Hocken. nil = noch nie eingestellt -> erbt pin_z.Hip (Verhalten
    -- bleibt exakt wie vorher, bis der Slider einmal bewegt wird).
    pin_z_hip_crouch = nil,
    pin_x_hip = 0.0,             -- [HIP_X] Huefte+Beine seitlich (Transform-X),
                                 -- IMMER aktiv; Spine_0 wird gegenkompensiert
    pin_x = {                    -- [PIN_X] pro Wirbel: Verschiebung SEITLICH
                                 -- (m, Transform-X) auf die gepinnte Pose
        Spine_0 = 0.0, Spine_1 = 0.0, Spine_2 = 0.0,
        Neck_0 = 0.0, Neck_1 = 0.0, Head = 0.0,
    },
    pin_ub_z = 0.0,              -- [PIN_UB] Oberkoerper GEMEINSAM: Z nach hinten
    pin_ub_x = 0.0,              -- (m) + X seitlich (m) + Yaw (Grad) — wirkt
                                 -- [UB_X_CROUCH 2026-07-22] NUR ausserhalb des Crouch
    pin_ub_x_crouch = 0.0,       -- [UB_X_CROUCH] eigener Seitwaerts-Wert NUR im Crouch
                                 -- (vorher wurde im Crouch gar kein X verrechnet -> 0 = wie bisher)
    pin_ub_yaw = 0.0,            -- auf ALLE Spine_0/1/2 + Neck_0/1 zusammen
    pin_ub_z_crouch = 0.0,       -- [CROUCH_UB_Z] eigener Z-nach-hinten-Wert NUR
                                 -- im Crouch (Pin dort geloest -> rein additiver
                                 -- Positions-Offset auf die UB-Joints, Rotation
                                 -- bleibt nativ damit die Hocke animiert)
    pin_hip_yaw = 0.0,           -- [HIP_YAW] Huefte+Beine um die Hochachse
                                 -- drehen; Spine_0 kompensiert gegen
                                 -- (Oberkoerper bleibt stehen)
    pin_spine1_roll = 0.0,       -- Roll (Grad) um die Transform-Vorwaertsachse
                                 -- auf die gepinnte Spine_1-Rotation (alles
                                 -- darueber kippt seitlich als Block mit)
    body_yaw_speed = 12.0,       -- Drehrate Body->Cam (1/s, differentiell)
    yaw_hmd_target = false,      -- Yaw-Ziel inkl. HMD-Drehung — AUS: HMD im
                                 -- Ziel = Mikro-Drehungen bei jedem Kopfwackeln
                                 -- -> Tippeln im Stand (2026-06-06 beobachtet)
    cam_body_rotate = true,      -- [CAM_BODY_ROTATE] Body-Rotate gegen die
                                 -- gerenderte Kamera: Ziel IMMER inkl. HMD,
                                 -- Nudge via (forward - perp) und Rate
                                 -- angle/720*dt*speed. Speist owned_yaw,
                                 -- damit der enforce-Stack es haelt.
    stop_skip = true,            -- Stop-Anims (Jog/Dash/Walk-End) ueberspringen (Einnicken weg)
    stop_skip_frames = 30.0,     -- wie viele Startframes der Stop-Anim geskippt werden
    start_skip = true,           -- Start-Anims (Walk/Jog/Dash-START) ueberspringen —
                                 -- die Anlauf-Verrenkung (Lean/Dip) faellt weg
    start_skip_frames = 30.0,    -- wie viele Frames der Start-Anim geskippt werden
    no_pivot = false,            -- Jog-Turn/Pivot-Anims (R90/R180) deaktivieren
    -- [SCOPE_EYE] PER-SCOPE Augen-Versatz im Scope-Freeze (dominantes Auge aufs Scope). Kugel haengt
    -- an der Muendung, nicht am Auge -> dieser Render-Versatz ist fuers Zielen gratis. Aktives Scope
    -- kommt von weapons.lua (__re4_scope_id, via montierter Attachment-ItemID: normal/thermal/hipower).
    -- NUR rechtes Auge (linkes Auge entfernt). x_r = X, z_r = Tiefe (kosmetisch);
    -- yaw = Kugel-Yaw-Korrektur (Gain) = eye_x * yaw (Parallaxe rausrechnen; 0 = keine Korrektur).
    -- scope_pitch_gain = wie weit der Blick dem Waffen-Pitch folgt (1.0 = 1:1; >1 = Kopf kippt
    -- weiter). GLOBAL fuer alle Waffen/Zustaende.
    scope_pitch_gain = 1.0,
    scope_sets = new_scope_sets(),   -- [scope_sets[wid][state]] = { x_r, z_r, yaw }; state = ironsight/normal/thermal/hipower
    -- [SCOPE_BULLET_XR 2026-08-11] EIGENER Kugel-Yaw-Gain fuer OpenXR bei alternierendem
    -- Rendern (= master-Fork). Gilt global fuer alle Waffen, weil er wie der OpenVR-Wert mit
    -- eye_x multipliziert wird und dadurch von selbst mit dem Augenversatz der Waffe skaliert.
    -- Greift AUSSCHLIESSLICH bei OpenXR ohne Multipass; im upscaler (Multipass) bleibt die
    -- Korrektur aus, unter OpenVR gilt weiter der Wert pro Waffe x Optik.
    scope_yaw_xr = 0.0,
    -- [STEPFALL_GRAV 2026-07-22, uebernommen aus re4_zzz_stepfall.lua]
    -- Rueckwaerts/seitwaerts treppab lief der Spieler kurz "auf Luft" ueber die Kante, fiel
    -- ruckartig und bekam einen Stagger. Fix: Gravitation des GroundAdsorbers waehrend der
    -- Bewegung anheben (24 -> 150) -- der Absatz wird so schnell durchfallen, dass Fall- und
    -- Landungs-Anim (und damit der Stagger) gar nicht anspringen. Beim Stehenbleiben und bei
    -- Reset Scripts geht der Originalwert zurueck.
    -- TOT getestet, nicht wiederholen: GroundSearchRadius, GroundSearchDistance, FallLimitHeight,
    -- MoveVelocity.y-Klemme, forceSetGroundState (letzteres sperrt den Abstieg = Schweben).
    grav_fix = true,          -- Toggle, falls es doch mal Aerger macht
    grav_value = 150.0,       -- Zielwert waehrend Bewegung (Original 24)
    -- [AUFZUG 2026-07-22] Rueckgebaut auf AUS: __re4_ks_keep_movement ist NICHT aufzugsspezifisch
    -- (Gondel, Minecart, Ashley-Carry haengen mit dran) -> zu breit, zu riskant. Beide Fixes gehen
    -- bei JEDEM Killswitch aus; Aufzug-Ausnahmen kommen spaeter gezielt, wenn man die
    -- konkreten Aufzuege/Stages nennt.
    grav_in_elevator = false,
    -- [LAGMOVE 2026-07-22, uebernommen aus re4_zzz_stepfall.lua Teil 2]
    -- Anlaufen und Stehenbleiben hatten das typische 3rd-Person-Gummiband. Die Anlauf-ANIM
    -- ist schon weg (START_SKIP unten), es war die Geschwindigkeit selbst: firstperson nimmt
    -- pro Frame nur den BETRAG der nativen Bewegung und dreht ihn in die Stick-/HMD-Richtung
    -- -> die native Beschleunigungs-/Auslauframpe wird 1:1 geerbt.
    -- Gemessen: Stillstand nach Loslassen -- Walk ~500 ms / 0.30 m, Rennen ~100 ms / 0.45 m.
    -- Werte unten sind live erspielt ("Loslaufen fast perfekt", Nachlauf weg).
    lag_boost_on = true,
    lag_boost_target = 2.01,  -- Zielgeschwindigkeit (m/s); gemessener Endspeed lag bei 2.43
    lag_boost_max = 2.41,     -- Deckel fuer den Zuschuss (m/s)
    lag_boost_window = 0.40,  -- nur so lange nach dem Stick-Ausschlag zuschiessen (s)
    lag_brake_on = true,
    lag_brake_gain = 0.00,    -- 0 = sofort stehen, 1 = wie ohne Fix
    -- WICHTIG: Das Bremsfenster muss LAENGER sein als der Nachlauf (~500 ms). Endet es
    -- frueher, nimmt die Engine ihre Restgeschwindigkeit wieder auf und der Rest bleibt.
    lag_brake_window = 1.50,
}
local function save_cfg() pcall(function() json.dump_file(CFG_PATH, cfg) end) end
pcall(function()
    local d = json.load_file(CFG_PATH)
    if type(d) == "table" then
        if d.enabled ~= nil then cfg.enabled = d.enabled == true end
        if d.hmd_yaw_drive ~= nil then cfg.hmd_yaw_drive = d.hmd_yaw_drive == true end
        if type(d.yaw_offset_deg) == "number" then cfg.yaw_offset_deg = d.yaw_offset_deg end
        if type(d.scope_yaw_xr) == "number" then cfg.scope_yaw_xr = d.scope_yaw_xr end
        if d.roomscale ~= nil then cfg.roomscale = d.roomscale == true end
        if d.rs_lean ~= nil then cfg.rs_lean = d.rs_lean == true end
        if type(d.rs_lean_radius) == "number" then cfg.rs_lean_radius = d.rs_lean_radius end
        if d.rs_recenter ~= nil then cfg.rs_recenter = d.rs_recenter == true end
        if d.rs_crouch ~= nil then cfg.rs_crouch = d.rs_crouch == true end
        if type(d.rs_crouch_pct) == "number" then cfg.rs_crouch_pct = d.rs_crouch_pct end
        if type(d.rs_stand_height) == "number" then cfg.rs_stand_height = d.rs_stand_height end
        if d.hmd_follow ~= nil then cfg.hmd_follow = d.hmd_follow == true end
        if type(d.hmd_follow_deadzone) == "number" then cfg.hmd_follow_deadzone = d.hmd_follow_deadzone end
        if type(d.hmd_follow_alpha) == "number" then cfg.hmd_follow_alpha = d.hmd_follow_alpha end
        if d.hip_follow ~= nil then cfg.hip_follow = d.hip_follow == true end
        if type(d.spine_yaw_deg) == "number" then cfg.spine_yaw_deg = d.spine_yaw_deg end
        if d.ub_lock ~= nil then cfg.ub_lock = d.ub_lock == true end
        if type(d.ub_trim_deg) == "number" then cfg.ub_trim_deg = d.ub_trim_deg end
        if d.ub_lock_world ~= nil then cfg.ub_lock_world = d.ub_lock_world == true end
        if d.spine_pin ~= nil then cfg.spine_pin = d.spine_pin == true end
        if d.grav_fix ~= nil then cfg.grav_fix = d.grav_fix == true end
        if type(d.grav_value) == "number" then cfg.grav_value = d.grav_value end
        if d.grav_in_elevator ~= nil then cfg.grav_in_elevator = d.grav_in_elevator == true end
        if d.lag_boost_on ~= nil then cfg.lag_boost_on = d.lag_boost_on == true end
        if type(d.lag_boost_target) == "number" then cfg.lag_boost_target = d.lag_boost_target end
        if type(d.lag_boost_max) == "number" then cfg.lag_boost_max = d.lag_boost_max end
        if type(d.lag_boost_window) == "number" then cfg.lag_boost_window = d.lag_boost_window end
        if d.lag_brake_on ~= nil then cfg.lag_brake_on = d.lag_brake_on == true end
        if type(d.lag_brake_gain) == "number" then cfg.lag_brake_gain = d.lag_brake_gain end
        if type(d.lag_brake_window) == "number" then cfg.lag_brake_window = d.lag_brake_window end
        if type(d.pin_z) == "table" then
            for k in pairs(cfg.pin_z) do
                if type(d.pin_z[k]) == "number" then cfg.pin_z[k] = d.pin_z[k] end
            end
        end
        if type(d.pin_z_hip_walk) == "number" then cfg.pin_z_hip_walk = d.pin_z_hip_walk end
        if type(d.pin_z_hip_crouch) == "number" then cfg.pin_z_hip_crouch = d.pin_z_hip_crouch end
        if type(d.pin_x_hip) == "number" then cfg.pin_x_hip = d.pin_x_hip end
        if type(d.pin_x) == "table" then
            for k in pairs(cfg.pin_x) do
                if type(d.pin_x[k]) == "number" then cfg.pin_x[k] = d.pin_x[k] end
            end
        end
        if type(d.pin_ub_z) == "number" then cfg.pin_ub_z = d.pin_ub_z end
        if type(d.pin_ub_z_crouch) == "number" then cfg.pin_ub_z_crouch = d.pin_ub_z_crouch end
        if type(d.pin_ub_x) == "number" then cfg.pin_ub_x = d.pin_ub_x end
        if type(d.pin_ub_x_crouch) == "number" then cfg.pin_ub_x_crouch = d.pin_ub_x_crouch end
        if type(d.pin_ub_yaw) == "number" then cfg.pin_ub_yaw = d.pin_ub_yaw end
        if type(d.pin_hip_yaw) == "number" then cfg.pin_hip_yaw = d.pin_hip_yaw end
        if type(d.pin_spine1_roll) == "number" then cfg.pin_spine1_roll = d.pin_spine1_roll end
        if type(d.pin_pose) == "table" then cfg.pin_pose = d.pin_pose end
        if type(d.crouch_pose) == "table" then cfg.crouch_pose = d.crouch_pose end
        if type(d.body_yaw_speed) == "number" then cfg.body_yaw_speed = d.body_yaw_speed end
        if d.yaw_hmd_target ~= nil then cfg.yaw_hmd_target = d.yaw_hmd_target == true end
        if d.cam_body_rotate ~= nil then cfg.cam_body_rotate = d.cam_body_rotate == true end
        if d.stop_skip ~= nil then cfg.stop_skip = d.stop_skip == true end
        if type(d.stop_skip_frames) == "number" then cfg.stop_skip_frames = d.stop_skip_frames end
        if d.start_skip ~= nil then cfg.start_skip = d.start_skip == true end
        if type(d.start_skip_frames) == "number" then cfg.start_skip_frames = d.start_skip_frames end
        if d.no_pivot ~= nil then cfg.no_pivot = d.no_pivot == true end
        if type(d.scope_pitch_gain) == "number" then cfg.scope_pitch_gain = d.scope_pitch_gain end
        if type(d.scope_sets) == "table" then
            -- Neues Format = scope_sets[wid][state]; erkennbar an einem Waffen-Key.
            local is_new = false
            for _, w in ipairs(SCOPE_WIDS) do if type(d.scope_sets[w]) == "table" then is_new = true; break end end
            if is_new then
                for _, w in ipairs(SCOPE_WIDS) do
                    local ws = d.scope_sets[w]
                    if type(ws) == "table" then
                        for _, st in ipairs(SCOPE_STATES) do
                            local s = ws[st]
                            if type(s) == "table" then
                                for _, f in ipairs({ "x_r", "z_r", "yaw" }) do
                                    if type(s[f]) == "number" then cfg.scope_sets[w][st][f] = s[f] end
                                end
                            end
                        end
                    end
                end
            else
                -- Migration: altes flaches Format (normal/thermal/hipower) war Stingray-Tuning -> nach 4401.
                for _, st in ipairs({ "normal", "thermal", "hipower" }) do
                    local s = d.scope_sets[st]
                    if type(s) == "table" then
                        for _, f in ipairs({ "x_r", "z_r", "yaw" }) do
                            if type(s[f]) == "number" then cfg.scope_sets["4401"][st][f] = s[f] end
                        end
                    end
                end
            end
        end
    end
end)
_G.__vr_zbob_tau = nil   -- ZBOB ausgebaut (bringt 0); firstperson-Filter entfernt

-- [HMD_YAW_DRIVE] Das Engine-_Yaw wird vom HMD getrieben (Block weiter unten,
-- konsolidiert aus dem fruehern re4_vr_hmd_movement.lua) -> die Engine dreht den
-- Body NATIV. Mein praydog-Body-Transform-Write (cam_body_rotate) wuerde dagegen
-- arbeiten + den HMD-Yaw doppeln -> hart aus. Der aktive Yaw-Follow (liest
-- _CameraRotation = jetzt HMD-getriebene Kamera) bleibt als sanfter Body-Abgleich.
cfg.cam_body_rotate = false

-- ---- Getter ----
local character_manager = nil
local camera_system = nil
local player_cam_td = sdk.find_type_definition("chainsaw.PlayerCameraController")

local function quat_rotate_vec3(q, v)
    local ok, r = pcall(function() return q * v end)
    if ok and r then return r end
    return v
end

-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: einmal pro Frame aufloesen statt bei
-- jedem Aufruf. Semantik unveraendert, alter Weg bleibt als Fallback. NOT-AUS: `_G.__re4_fc_off = true`.
pcall(function() require("re4vr/re4_vr_frame_cache") end)

local function get_body_transform()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.body_tf() end
    if not character_manager then
        character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    local ctx = character_manager and safe(function()
        return character_manager:call("getPlayerContextRef")
    end)
    if not ctx then return nil end
    local body = safe(function() return ctx:call("get_BodyGameObject") end)
    if not body then return nil end
    return safe(function() return body:call("get_Transform") end)
end

-- Aktiver PlayerCameraController (nur wenn Gameplay-Kamera läuft)
local function get_player_cam_controller()
    if not camera_system then
        camera_system = sdk.get_managed_singleton("chainsaw.CameraSystem")
    end
    local main = camera_system and safe(function()
        return camera_system:call("get_MainCameraController")
    end)
    local busy = main and safe(function() return main:call("get_BusyCameraController") end)
    if not busy then return nil end
    local ok_pc, is_pc = pcall(function()
        return player_cam_td and busy:get_type_definition():is_a(player_cam_td)
    end)
    if not ok_pc or not is_pc then return nil end
    return busy
end

local function is_ks_active()
    -- [THROWSIGHT] Del-Lago-Harpunen-Stage: der Killswitch ist dort bewusst AUS (First-Person),
    -- aber Bewegung darf NICHT laufen — Leon sitzt nativ im Boot, sonst schwebt der Body.
    -- Darum hier wie "KS aktiv" behandeln -> alle movement-Gates pausieren. NUR diese Stage.
    if rawget(_G, "__re4_throwsight_active") == true then return true end
    -- [KS_KEEP_MOVEMENT 2026-07-16] Voll-aus-KS (KS1/4/5), der movement absichtlich weiterlaufen laesst
    -- (Turn-Kopplung, waehrend arm_chain/motion aus sind + resetBasePose die Joints freigab). Test ueber die
    -- Stage, final an KS1/4/5. -> movement NICHT pausieren.
    if rawget(_G, "__re4_ks_keep_movement") == true then return false end
    local ok, v = pcall(killswitch.is_active)
    return ok and v == true
end

-- [PIN_RELEASE] "zweiter Killswitch": NUR den Spine/Crouch-Pin loesen (Char
-- huepft/klettert nativ drueber), HMD-Yaw + Hard-Yaw bleiben aktiv. Greift
-- zusaetzlich zum vollen is_ks_active bei den Pin-Gates.
local function is_pin_release()
    if type(killswitch.is_pin_release) ~= "function" then return false end
    local ok, v = pcall(killswitch.is_pin_release)
    return ok and v == true
end

-- [CROUCH] Hock-Animation als Trigger (killswitch liest MotionFsm2). Der
-- harte Spine-Pin nagelt Torso+Head auf die Steh-Pose -> Crouch wuerde nur
-- die Beine senken, Kamera/Oberkoerper blieben oben. Waehrend Crouch den
-- Pin loesen (s. apply_spine_pin); rel bleibt erhalten -> nach dem Crouch
-- exakt dieselbe Steh-Pose wie vorher.
local function is_crouch_active()
    if type(killswitch.is_crouch_active) ~= "function" then return false end
    local ok, v = pcall(killswitch.is_crouch_active)
    return ok and v == true
end

-- ---- Harter Yaw-Follow ----
-- Kamera-Yaw (geflattet) -> Body-Rotation, jede Frame, ohne Lerp.
local last_yaw_quat = nil

-- ---- Hip-Follow ----
-- Die Turn-Anim rotiert den Hip LOKAL gegen und pendelt langsam ein -> Hip
-- lerpt sichtbar nach, obwohl der Root hart steht. Fix: Im Stand den
-- natürlichen Yaw-Offset Hip<->Root sampeln (Referenz), beim Drehen den
-- Hip-Yaw hart auf Root-Yaw*Referenz zwingen. Pitch/Roll der Anim bleiben.
local hip_state = { joint = nil, ref_offset = nil }

local function yaw_quat_of(rot)
    if not rot then return nil end
    local fwd = rot * Vector3f.new(0, 0, 1)
    fwd.y = 0.0
    local len = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
    if len < 0.0001 then return nil end
    fwd = Vector3f.new(fwd.x / len, 0.0, fwd.z / len)
    return safe(function() return fwd:to_quat() end)
end

-- [LOGFLUT 2026-08-02] Wie in arm_chain/motion: der Gueltigkeitstest ruft absichtlich get_Position auf,
-- und REFramework schreibt jede Engine-Exception SYNCHRON ins Log (in der Invoke-Schicht, vor unserem
-- pcall -- das faengt den Lua-Fehler, nicht die Logzeile). Hier ist es weniger kritisch als in den
-- anderen beiden Dateien, weil bei Misserfolg `hip_state.joint = nil` gesetzt und der Joint danach neu
-- gesucht wird -- der Test wiederholt sich also nicht endlos auf derselben toten Referenz.
-- Zeitsperre trotzdem, damit ein Joint, der beim Neusuchen sofort wieder tot ist, nicht jeden Frame
-- eine Zeile erzeugt.
-- [LOGFLUT GEDROSSELT 2026-08-02] Wie in arm_chain/motion: der Gueltigkeitstest ruft absichtlich
-- get_Position auf, und REFramework schreibt jede Engine-Exception synchron ins Log (vor unserem
-- pcall). Hier am wenigsten kritisch, weil bei Misserfolg `hip_state.joint` genullt und der Joint neu
-- gesucht wird -- die Zeitsperre verhindert nur, dass ein sofort wieder toter Joint jeden Frame eine
-- Zeile erzeugt.
local _hipjv_bad = -999
local function get_hip_joint(tf)
    if hip_state.joint then
        if (os.clock() - _hipjv_bad) < 0.5 then return nil end
        local ok = pcall(function() return hip_state.joint:call("get_Position") end)
        if ok then return hip_state.joint end
        _hipjv_bad = os.clock()
        hip_state.joint = nil
    end
    if not tf then return nil end
    local j = safe(function() return tf:call("getJointByName", "Hip") end)
    if j then hip_state.joint = j end
    return hip_state.joint
end

local function is_user_turning()
    if not vrmod then return false end
    local ax = safe(function() return vrmod:get_right_stick_axis() end)
    return ax ~= nil and math.abs(ax.x) > 0.1
end

local function apply_hip_follow(tf, root_yaw_quat)
    if not cfg.hip_follow then return end
    if not tf or not root_yaw_quat then return end

    local hip = get_hip_joint(tf)
    if not hip then return end
    local hr = safe(function() return hip:call("get_Rotation") end)
    if not hr then return end

    local hip_yaw = yaw_quat_of(hr)
    if not hip_yaw then return end

    if not is_user_turning() then
        -- Referenz im Stand mitlernen: offset = root_yaw^-1 * hip_yaw
        local off = safe(function()
            return (root_yaw_quat:conjugate() * hip_yaw):normalized()
        end)
        if off then
            if hip_state.ref_offset then
                hip_state.ref_offset = safe(function()
                    return hip_state.ref_offset:slerp(off, 0.1)
                end) or off
            else
                hip_state.ref_offset = off
            end
        end
        return
    end

    -- Beim Drehen: Hip-Yaw hart auf Root-Yaw * Referenz zwingen
    if not hip_state.ref_offset then return end
    local desired_yaw = safe(function()
        return (root_yaw_quat * hip_state.ref_offset):normalized()
    end)
    if not desired_yaw then return end
    local correction = safe(function()
        return (desired_yaw * hip_yaw:conjugate()):normalized()
    end)
    if not correction then return end
    local new_rot = safe(function() return (correction * hr):normalized() end)
    if not new_rot then return end
    pcall(function() hip:call("set_Rotation", new_rot) end)
end

-- ---- Spine/Neck Yaw-Offset ----
-- Ein Slider, synchron auf Spine_1 / Spine_2 / Neck_0 / Neck_1:
-- Welt-Y-Yaw-Rotation auf die Joint-Rotation draufmultipliziert.
local SPINE_YAW_JOINTS = { "Spine_1", "Spine_2", "Neck_0", "Neck_1" }
local spine_joint_cache = {}

local function get_spine_joint(tf, name)
    local j = spine_joint_cache[name]
    if j then
        local ok = pcall(function() return j:call("get_Position") end)
        if ok then return j end
        spine_joint_cache[name] = nil
    end
    if not tf then return nil end
    j = safe(function() return tf:call("getJointByName", name) end)
    if j then spine_joint_cache[name] = j end
    return j
end

local spine_last_written = {}

local function quat_approx_equal(a, b)
    if not a or not b then return false end
    local dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    if dot < 0 then dot = -dot end
    return dot > 0.9999995
end

-- [IKLEG_CLEANUP ENTFERNT 2026-07-15] War der einmalige Restore fuer das am 2026-06-06 ausgebaute
-- IKLEG_STAB (hatte CenterPositionCtrl=WorldOffset + CenterOffset in die IkLeg2 geschrieben, was nach
-- dem Ausbau kleben geblieben waere). LIVE BELEGT, dass es NIE gelaufen ist: die Routine gibt nach 300
-- Versuchen auf (ikleg_cleanup_tries) -- beim Spiel-Neustart brennen die im Hauptmenue ab, wo es noch
-- keinen Body gibt. Beim Aufzug-Test 2026-07-15 mit Log statt Schreiben blieb die Log-Datei leer:
-- die Komponente wurde kein einziges Mal erreicht. Toter Code, raus (der Kommentar sagte selbst
-- "kann nach ein paar Sessions komplett raus"). Spart nebenbei 3 Top-Level-Locals.

-- [SPINE_PIN] Spine_2 + Neck_0 + Neck_1 hart festnageln ( 2026-06-06:
-- "komplett auf einen Punkt, keine Bewegung egal wohin"). Welt-Pose =
-- Transform-Pose * (im Stand gecapturte Rel-Pose) — reitet auf Translation
-- + Yaw des Body, aber KEINE Anim kann Position ODER Rotation bewegen
-- (Laufen/Rennen/Drehen/Aim egal). Enforce im vollen 5-Phasen-Stack
-- (Engine schreibt zwischen den Phasen). Killswitch-Anims bleiben nativ.
-- Volle Torso-Kette: nur Spine_2+Necks reichte NICHT — das Mesh haengt
-- great. an Hip/Spine_1, die weiter animierten ("bewegt sich wie sau").
-- Fehlende Joint-Namen werden uebersprungen (Spine_0/Waist je nach Rig).
-- ANKER = Root-Joint (joints[0]): dessen LOKALE Pose ist per Definition
-- transform-relativ -> lokal einfrieren haengt den Block direkt an den
-- Transform. (Hip als WELT-Anker scheiterte: Welt-Writes schluckt der
-- Engine-Pose-Recompute, der starre Block ritt auf der Hueft-Anim.)
-- Parent-Kette live verifiziert (get_Parent, 2026-06-06): root -> Hip ->
-- Spine_0 -> Spine_1 -> Spine_2 -> Neck_0 -> Neck_1 -> Head (linear).
-- "Null_Offset" haengt PARALLEL unter root (Geschwister von Hip!) — der
-- Engine-Offset-Joint fuer weiche Ganzkoerper-Shifts (Anlauf-Lean). Er wird
-- SEPARAT roh-lokal gepinnt, NICHT in der Ketten-Ableitung (dort als
-- vermeintlicher Hip-Parent eingereiht hat er den Torso schief abgeleitet
-- -> "linke Schulter wieder defekt").
local PIN_JOINTS = { "Hip", "Spine_0", "Spine_1", "Spine_2",
                     "Neck_0", "Neck_1", "Head" }
local spinepin = { tf = nil, joints = nil, rel = nil }

-- [PIN_UB] Oberkoerper-Glieder fuer die gemeinsamen Z/X/Yaw-Slider
local UB_JOINTS = {
    Spine_0 = true, Spine_1 = true, Spine_2 = true,
    Neck_0 = true, Neck_1 = true,
}

local function spinepin_resolve(tf)
    if spinepin.tf == tf and spinepin.joints then return true end
    spinepin.tf = tf
    spinepin.joints = nil
    -- spinepin.rel bleibt absichtlich stehen: die gecapturte Pose ist
    -- Skelett-generisch — nach Save-Load greift der Pin sofort wieder,
    -- ohne auf ein neues Stand-Capture zu warten.
    local list, names = {}, {}
    local root = safe(function()
        local js = tf:call("get_Joints")
        return js and js[0] or nil
    end)
    if root then
        list[#list + 1] = root
        names[#names + 1] = "root"
    end
    for _, name in ipairs(PIN_JOINTS) do
        local j = safe(function() return tf:call("getJointByName", name) end)
        if j then
            list[#list + 1] = j
            names[#names + 1] = name
        end
    end
    if #list == 0 then return false end
    spinepin.joints = list
    spinepin.names = names
    -- Null_Offset separat (Parallel-Joint unter root, kein Kettenglied)
    spinepin.null_off = safe(function() return tf:call("getJointByName", "Null_Offset") end)
    return true
end

-- Yaw-Helfer lokal HIER definiert — flat_yaw_of/yaw_to_quat stehen weiter
-- unten im File und waeren an dieser Stelle nil (Forward-Decl-Falle).
local function spin_yaw_of(rot)
    local f = rot * Vector3f.new(0, 0, 1)
    local len = math.sqrt(f.x * f.x + f.z * f.z)
    if len < 0.0001 then return nil end
    return math.atan(f.x / len, f.z / len)
end

local function spin_yaw_quat(yaw)
    local h = yaw * 0.5
    return Quaternion.new(math.cos(h), 0.0, math.sin(h), 0.0)
end

-- Quaternion um beliebige (normierte) Achse — fuer den Spine_1-Roll
local function spin_axis_quat(ax, ay, az, rad)
    local h = rad * 0.5
    local s = math.sin(h)
    return Quaternion.new(math.cos(h), ax * s, ay * s, az * s)
end

-- Capture/Enforce: ALLE Joints als LOKALE Pose (Parent-relativ) —
-- Root-Joint-Local = transform-relativ (Anker), Rest = starre Kette.
-- Die Engine rechnet Welt-Posen aus den Locals neu -> garantiert starr.
-- ENTDRILLEN beim Capture: RE4s Idle ist Kontrapost (Becken seitlich,
-- Brust/Kopf per Look-At zurueckgedreht) — nur den Anker geradedrehen
-- liess den eingebackenen Gegen-Twist durch den Torso wickeln. Darum:
-- pro Kettenglied den WELT-Yaw (relativ zum Transform) neutralisieren
-- (Pitch/Roll der Haltung bleiben) und die Locals daraus neu ableiten.
-- Annahme: Listenreihenfolge = Parent-Kette (root->Hip->Spine->Neck->Head).
local function spinepin_capture(tf)
    local tr = safe(function() return tf:call("get_Rotation") end)
    local tri = tr and safe(function() return tr:conjugate() end)
    if not (tr and tri) then return end

    -- 1) Welt-Rotationen einsammeln und pro Joint im Yaw geradedrehen
    local fixed_rel = {}
    for i, j in ipairs(spinepin.joints) do
        local wr = safe(function() return j:call("get_Rotation") end)
        if not wr then return end
        local rel_r = safe(function() return (tri * wr):normalized() end)
        if not rel_r then return end
        local y = safe(function() return spin_yaw_of(rel_r) end)
        if y and y ~= 0.0 then
            local f = safe(function() return (spin_yaw_quat(-y) * rel_r):normalized() end)
            if f then rel_r = f end
        end
        fixed_rel[i] = rel_r
    end

    -- 2) Locals aus den begradigten Welt-Posen ableiten.
    -- Nebenbei pro Joint das Konjugat der PARENT-Rotation (rel-zu-Transform)
    -- merken: damit laesst sich der Z-Offset-Slider (Transform-Raum,
    -- "nach hinten") in den jeweiligen Parent-Raum drehen.
    local rel = {}
    local par_inv = {}
    for i, j in ipairs(spinepin.joints) do
        local lp = safe(function() return j:call("get_LocalPosition") end)
        if not lp then return end
        local lr
        if i == 1 then
            lr = fixed_rel[1]
            par_inv[i] = nil   -- Parent = Transform -> Identitaet
        else
            lr = safe(function()
                return (fixed_rel[i - 1]:conjugate() * fixed_rel[i]):normalized()
            end)
            par_inv[i] = safe(function() return fixed_rel[i - 1]:conjugate() end)
        end
        if not lr then return end
        rel[i] = { p = lp, r = lr }
    end
    -- Null_Offset roh-lokal capturen (im Stand = neutraler Offset)
    local null_rel = nil
    if spinepin.null_off then
        local lp = safe(function() return spinepin.null_off:call("get_LocalPosition") end)
        local lr = safe(function() return spinepin.null_off:call("get_LocalRotation") end)
        if lp and lr then null_rel = { p = lp, r = lr } end
    end

    -- [TWO_POSE] Pose-Tupel zurueckgeben statt direkt in spinepin zu schreiben
    -- -> Caller legt sie in den passenden Slot (Steh- ODER Hock-Pose).
    return rel, par_inv, null_rel
end

-- [PIN_PERSIST] Gecapturte Pose auf Platte: jede Session/Save-Load captured
-- sonst eine LEICHT andere Stance -> "sieht jedes Mal anders aus".
local function spinepin_store(rel, par_inv, null_rel, cfg_key)
    if not (rel and spinepin.names) then return end
    local store = { joints = {} }
    for i, nm in ipairs(spinepin.names) do
        local r = rel[i]
        local pi = par_inv and par_inv[i]
        if r then
            store.joints[nm] = {
                px = r.p.x, py = r.p.y, pz = r.p.z,
                rw = r.r.w, rx = r.r.x, ry = r.r.y, rz = r.r.z,
                iw = pi and pi.w or nil, ix = pi and pi.x or nil,
                iy = pi and pi.y or nil, iz = pi and pi.z or nil,
            }
        end
    end
    if null_rel then
        store.null = {
            px = null_rel.p.x, py = null_rel.p.y, pz = null_rel.p.z,
            rw = null_rel.r.w, rx = null_rel.r.x,
            ry = null_rel.r.y, rz = null_rel.r.z,
        }
    end
    cfg[cfg_key] = store
    save_cfg()
end

-- gibt rel, par_inv, null_rel zurueck (oder nil bei fehlender/kaputter Pose)
local function spinepin_restore(cfg_key)
    local store = cfg[cfg_key]
    if type(store) ~= "table" or type(store.joints) ~= "table" then return nil end
    if not spinepin.names then return nil end
    local rel, par_inv = {}, {}
    for i, nm in ipairs(spinepin.names) do
        local s = store.joints[nm]
        if not (type(s) == "table" and type(s.px) == "number" and type(s.rw) == "number") then
            return nil
        end
        rel[i] = {
            p = Vector3f.new(s.px, s.py, s.pz),
            r = Quaternion.new(s.rw, s.rx, s.ry, s.rz),
        }
        if type(s.iw) == "number" then
            par_inv[i] = Quaternion.new(s.iw, s.ix, s.iy, s.iz)
        end
    end
    local null_rel = nil
    local n = store.null
    if type(n) == "table" and type(n.px) == "number" then
        null_rel = {
            p = Vector3f.new(n.px, n.py, n.pz),
            r = Quaternion.new(n.rw, n.rx, n.ry, n.rz),
        }
    end
    return rel, par_inv, null_rel
end

local function apply_spine_pin(can_capture)
    if not cfg.spine_pin then
        spinepin.rel = nil
        _G.__vr_surge_bridged = false
        return
    end
    if is_ks_active() then return end
    -- [PIN_RELEASE] Nur Pin loesen, Char huepft/klettert nativ drueber; HMD/Yaw laufen
    -- weiter. Body animiert selbst -> Surge gehoert auf die Kamera.
    -- [2026-07-15] Schlafend: PIN_RELEASE_CAM_STATES ist leer (alle Traversal-States sind KS2).
    -- Mechanik bleibt -- ein Eintrag dort reicht, um sie zurueckzuholen.
    if is_pin_release() then _G.__vr_surge_bridged = false; return end

    -- [CROUCH_RELEASE] Pin waehrend der Hock-Anim aussetzen: die Engine beugt
    -- die Wirbelsaeule runter, die Joints animieren nativ -> der Head sinkt,
    -- die Kamera folgt (Kapsel-XZ + Head-Y). rel NICHT nilen -> nach dem
    -- Aufstehen greift exakt dieselbe Steh-Pose wieder. (Der Oberkoerper
    -- lehnt sich beim Crouch-Walk leicht vor — bewusst akzeptiert; ein
    -- harter Crouch-Pin verhinderte das Crouchen ueberhaupt.)
    if is_crouch_active() then return end

    local tf = get_body_transform()
    if not tf then return end

    -- [SPAWN_GUARD] Save-Load/Tod baut den Player neu: alte Joint-Handles
    -- sind Leichen, Writes laufen still ins Leere ("kein Joint mehr
    -- festgenagelt", Status log AKTIV). Anker validieren, bei Leiche nur
    -- die Joints neu aufloesen — die gecapturte Pose (rel/par_inv/null_rel)
    -- ist Skelett-generisch und bleibt, Pin greift sofort wieder.
    if spinepin.joints then
        local probe = spinepin.joints[1]
        local alive = probe and pcall(function() return probe:call("get_Position") end)
        if not alive then
            spinepin.tf = nil
            spinepin.joints = nil
            spinepin.null_off = nil
        end
    end

    if not spinepin_resolve(tf) then return end
    if not spinepin.rel then
        _G.__vr_surge_bridged = false
        -- 1) Persistierte Steh-Pose von Platte (einmal pro Script-Lauf):
        -- Pin greift SOFORT nach Game-Start/Load, gleiche Optik jede Session
        if not spinepin.cfg_tried then
            spinepin.cfg_tried = true
            local r, pi, nr = spinepin_restore("pin_pose")
            if r then
                spinepin.rel, spinepin.par_inv, spinepin.null_rel = r, pi, nr
                return
            end
        end
        -- 2) im ruhigen Stand: sauber capturen + auf Platte sichern.
        -- 3) [INSTANT_FALLBACK] sonst SOFORT provisorisch aus der laufenden
        -- Anim capturen (Entdrill neutralisiert die Verdrehung, Pitch/
        -- Roll mid-step sind klein) — Pin greift ab Frame 1, Upgrade
        -- auf die saubere Stand-Pose passiert unten automatisch.
        if can_capture then
            local a = _G.__vr_anim_l0
            local r, pi, nr = spinepin_capture(tf)
            if r then
                spinepin.rel, spinepin.par_inv, spinepin.null_rel = r, pi, nr
                if a and a:lower():find("stand", 1, true) then
                    spinepin.provisional = nil
                    spinepin_store(r, pi, nr, "pin_pose")
                else
                    spinepin.provisional = true
                end
            end
        end
        return
    end
    -- Provisorische Pose beim ersten ruhigen Stand still ersetzen + sichern
    if spinepin.provisional and can_capture then
        local a = _G.__vr_anim_l0
        if a and a:lower():find("stand", 1, true) then
            local r, pi, nr = spinepin_capture(tf)
            if r then
                spinepin.rel, spinepin.par_inv, spinepin.null_rel = r, pi, nr
                spinepin.provisional = nil
                spinepin_store(r, pi, nr, "pin_pose")
            end
        end
    end
    local cur_rel, cur_par_inv, cur_null = spinepin.rel, spinepin.par_inv, spinepin.null_rel
    -- Bridge aktiv: firstperson darf den Surge-Shift NICHT nochmal auf die
    -- Kamera legen (Head traegt ihn schon) — sonst Doppel-Shift = Body
    -- ragt tempo-proportional vorn ins Bild.
    _G.__vr_surge_bridged = true

    -- [HIP_RUN_Z] Blendfaktor fuer den Hip/Beine-Offset: nur im Rennen
    -- (jog/dash), weich rein/raus (~0.1s) — 1x/Frame im Capture-Slot ticken
    if can_capture then
        local a = _G.__vr_anim_l0
        local running, walking = false, false
        if a then
            a = a:lower()
            running = (a:find("jog", 1, true) or a:find("dash", 1, true)
                or a:find("run", 1, true)) ~= nil
            -- [HIP_WALK_Z] normales Gehen (NICHT Rennen): eigener Hip-Z-Offset
            walking = (not running) and (a:find("walk", 1, true) ~= nil)
        end
        local rb = spinepin.run_blend or 0.0
        spinepin.run_blend = rb + ((running and 1.0 or 0.0) - rb) * 0.15
        local wb = spinepin.walk_blend or 0.0
        spinepin.walk_blend = wb + ((walking and 1.0 or 0.0) - wb) * 0.15
    end

    -- [SURGE_BRIDGE] Kamera faehrt die geglaettete Surge-Bahn (firstperson,
    -- bis 0.25m hinter der Kapsel beim Beschleunigen). Der Anker uebernimmt
    -- denselben Welt-Versatz (in Transform-Lokalraum gedreht), sonst laeuft
    -- der hart gepinnte Body der Kamera in Z voraus (frueher IkLeg-Job).
    local anchor_p = cur_rel[1] and cur_rel[1].p
    local sdx = tonumber(_G.__vr_surge_dx) or 0.0
    local sdz = tonumber(_G.__vr_surge_dz) or 0.0
    if anchor_p and (sdx ~= 0.0 or sdz ~= 0.0) then
        local tr = safe(function() return tf:call("get_Rotation") end)
        local tri = tr and safe(function() return tr:conjugate() end)
        local off = tri and safe(function()
            return tri * Vector3f.new(sdx, 0.0, sdz)
        end)
        if off then
            anchor_p = Vector3f.new(anchor_p.x + off.x, anchor_p.y + off.y,
                                    anchor_p.z + off.z)
        end
    end

    -- [UB_Z_DELTA 2026-07-22] Referenz fuer die Holster-OPTIK ist das normale Gehen/Stehen.
    -- Hier (Steh-Pin) ist die Abweichung also 0; der Crouch-Pin unten setzt sie auf seine Differenz.
    -- re4_vr_holster.lua verschiebt damit NUR die Mesh-Klone -- Greifpunkte bleiben unberuehrt.
    _G.__re4_ub_z_delta = 0.0

    for i, j in ipairs(spinepin.joints) do
        local rel = cur_rel[i]
        if rel then
            local p = (i == 1 and anchor_p) and anchor_p or rel.p
            -- [PIN_Z] Slider-Offset "nach hinten" (Transform-Z) in den
            -- Parent-Raum der gepinnten Pose drehen und addieren
            local name = spinepin.names and spinepin.names[i]
            local zo = name and cfg.pin_z[name]
            -- [PIN_X] per-Wirbel Seitwaerts-Offset (Transform-X)
            local xo = (name and cfg.pin_x[name]) or 0.0
            -- [PIN_UB] gemeinsamer Oberkoerper-Offset auf alle Spine+Neck
            local is_ub = name and UB_JOINTS[name]
            if is_ub then
                zo = (zo or 0.0) + (cfg.pin_ub_z or 0.0)
                -- [UB_X_CROUCH 2026-07-22] pin_ub_x gilt nur hier (Steh-Pin) -- im Crouch laeuft der
                -- eigene Wert pin_ub_x_crouch im Crouch-Pin. Dieser Zweig laeuft im Crouch ohnehin nicht.
                xo = xo + (cfg.pin_ub_x or 0.0)
            end
            -- [HIP_RUN_Z] Hip-Z nur im Rennen (geblendet); [HIP_X] seitlich
            -- IMMER. Spine_0 kompensiert jeweils gegen, damit der
            -- Oberkoerper nicht mitwandert
            if name == "Hip" then
                zo = (zo or 0.0) * (spinepin.run_blend or 0.0)
                    + (cfg.pin_z_hip_walk or 0.0) * (spinepin.walk_blend or 0.0)
                xo = xo + (cfg.pin_x_hip or 0.0)
            elseif name == "Spine_0" then
                zo = (zo or 0.0)
                    - (cfg.pin_z.Hip or 0.0) * (spinepin.run_blend or 0.0)
                    - (cfg.pin_z_hip_walk or 0.0) * (spinepin.walk_blend or 0.0)
                xo = xo - (cfg.pin_x_hip or 0.0)
            end
            if (zo and zo ~= 0.0) or xo ~= 0.0 then
                local v = Vector3f.new(xo, 0.0, -(zo or 0.0))
                local pi = cur_par_inv and cur_par_inv[i]
                if pi then
                    local rv = safe(function() return pi * v end)
                    if rv then v = rv end
                end
                p = Vector3f.new(p.x + v.x, p.y + v.y, p.z + v.z)
            end
            local r = rel.r
            -- [HIP_YAW] Huefte+Beine um die Hochachse; Spine_0 dreht exakt
            -- gegen, damit der Oberkoerper stehen bleibt
            local hy = cfg.pin_hip_yaw or 0.0
            if hy ~= 0.0 and (name == "Hip" or name == "Spine_0") then
                local axis = Vector3f.new(0.0, 1.0, 0.0)
                local pi = cur_par_inv and cur_par_inv[i]
                if pi then
                    local ra = safe(function() return pi * axis end)
                    if ra then axis = ra end
                end
                local ang = (name == "Hip") and hy or -hy
                local q = spin_axis_quat(axis.x, axis.y, axis.z, math.rad(ang))
                local turned = safe(function() return (q * r):normalized() end)
                if turned then r = turned end
            end
            -- [PIN_UB_YAW] Oberkoerper-Yaw: jedes Spine/Neck-Glied um die
            -- Transform-Hochachse drehen (verteilter Twist wie der alte
            -- spine_yaw-Slider, aber auf der gepinnten Pose)
            if is_ub and (cfg.pin_ub_yaw or 0.0) ~= 0.0 then
                local axis = Vector3f.new(0.0, 1.0, 0.0)
                local pi = cur_par_inv and cur_par_inv[i]
                if pi then
                    local ra = safe(function() return pi * axis end)
                    if ra then axis = ra end
                end
                local q = spin_axis_quat(axis.x, axis.y, axis.z,
                    math.rad(cfg.pin_ub_yaw))
                local turned = safe(function() return (q * r):normalized() end)
                if turned then r = turned end
            end
            -- [PIN_ROLL] Spine_1 um die Transform-Vorwaertsachse kippen —
            -- die Kette darueber (Spine_2/Necks/Head/Schultern) folgt starr.
            if name == "Spine_1" and (cfg.pin_spine1_roll or 0.0) ~= 0.0 then
                local axis = Vector3f.new(0.0, 0.0, 1.0)
                local pi = cur_par_inv and cur_par_inv[i]
                if pi then
                    local ra = safe(function() return pi * axis end)
                    if ra then axis = ra end
                end
                local q = spin_axis_quat(axis.x, axis.y, axis.z,
                    math.rad(cfg.pin_spine1_roll))
                local rolled = safe(function() return (q * r):normalized() end)
                if rolled then r = rolled end
            end
            pcall(function()
                j:call("set_LocalPosition", p)
                j:call("set_LocalRotation", r)
            end)
        end
    end

    -- Null_Offset separat festnageln (Anlauf-Lean/Stop-Blend der Engine)
    if spinepin.null_off and cur_null then
        pcall(function()
            spinepin.null_off:call("set_LocalPosition", cur_null.p)
            spinepin.null_off:call("set_LocalRotation", cur_null.r)
        end)
    end
end

-- [STOP_SKIP] SnappyControls-Pattern (alphaZomega): an den Stop-Anim-Nodes
-- im MotionFsm2 Layer 0 die Startframes skippen (_StartFrame +
-- _OverwriteInterpolation an der Motion-Action) -> das heftige Einnicken
-- nach dem Rennen/Gehen faellt weg. FSM-Patches ueberleben Reset Scripts ->
-- Restore laeuft bei Toggle-Off UND on_script_reset.
local STOP_NODES = {
    "ch0_540_JOG_END", "ch0_550_JOG_END_LIGHT", "general_0381_stop_jog",
    "ch0_740_DASH_END", "ch0_749_DASH_CANCEL",
    "ch0_406_WALK_END_FRONT", "ch0_446_WALK_END_BACK", "general_0380_stop_walk",
    "ch0_1406_CROUCH_WALK_END_FRONT", "ch0_1446_CROUCH_WALK_END_BACK",
}
-- [START_SKIP] Gegenstueck fuer die Anlauf-Anims (Lean/Dip beim Losgehen).
-- Node-Namen aus re4vr_fsm_dump.log (2026-06-06).
-- WALK-Starts: voller Skip inkl. _OverwriteInterpolation (Re-Crossfade ok,
-- weil aus dem Stand gestartet wird).
local START_NODES = {
    "ch0_400_WALK_START_FRONT", "ch0_440_WALK_START_BACK", "ch0_490_WALK_START_TURN",
    "ch0_1400_CROUCH_WALK_START_FRONT", "ch0_1440_CROUCH_WALK_START_BACK",
    "ch0_1490_CROUCH_WALK_START_TURN",
}
-- RUN-Starts (Jog/Dash): Frame-Skip JA (Dip weg), aber KEIN
-- _OverwriteInterpolation. Beim Walk->Run wird die Loco-Subtree gewechselt
-- (Walk.* -> Run.*); das erzwungene Re-Interpolieren ueber InterpolationFrame
-- (40, CrossFade) frisst kurz die Vorwaerts-Geschwindigkeit = der gefuehlte
-- "kurze Halt vor dem Rennen". Ohne Overwrite blendet die Engine nativ weiter.
local RUN_START_NODES = {
    "ch0_500_JOG_START", "ch0_700_DASH_START", "ch0_1500_CROUCH_TO_JOG_START",
}
local stop_skip_state = { applied = false, last_ctx = nil }
local start_skip_state = { applied = false, last_ctx = nil }

local function get_motion_fsm()
    if not character_manager then
        character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    local ctx = character_manager and safe(function()
        return character_manager:call("getPlayerContextRef")
    end)
    if not ctx then return nil, nil end
    local updater = safe(function() return ctx:get_field("_BodyUpdater") end)
    local mfsm = updater and safe(function()
        return updater:get_field("<MotionFsm>k__BackingField")
    end)
    return mfsm, ctx
end

local function apply_skip_nodes(nodes, frames, enable, overwrite_interp)
    if overwrite_interp == nil then overwrite_interp = true end
    local mfsm, ctx = get_motion_fsm()
    if not mfsm then return false, nil end
    local layer = safe(function() return mfsm:call("getLayer", 0) end)
    local tree = layer and safe(function() return layer:get_tree_object() end)
    if not tree then return false, nil end

    local touched = false
    for _, name in ipairs(nodes) do
        local node = safe(function() return tree:get_node_by_name(name) end)
        if node then
            local acts = safe(function() return node:get_actions() end)
            if not (acts and acts[1]) then
                acts = safe(function() return node:get_unloaded_actions() end)
            end
            if acts then
                pcall(function()
                    for _, act in ipairs(acts) do
                        local ok_sf, sf = pcall(function() return act._StartFrame end)
                        if ok_sf and sf ~= nil then
                            if enable then
                                -- [COLLAPSE] Anim auf ~1 Frame zusammenfalten: StartFrame ans Ende
                                -- der Anim (_EndFrame) -> komplette Start/Stop-Anim faellt weg, egal
                                -- wie lang sie ist. Fallback = fester Frameskip, falls _EndFrame fehlt.
                                local ef = safe(function() return act._EndFrame end)
                                act._StartFrame = (type(ef) == "number" and ef > 0) and ef or frames
                            else
                                act._StartFrame = 0.0
                            end
                            act._OverwriteInterpolation = (enable and overwrite_interp) or false
                            touched = true
                        end
                    end
                end)
            end
        end
    end
    return touched, ctx
end

local function apply_stop_skip(enable)
    local touched, ctx = apply_skip_nodes(STOP_NODES, cfg.stop_skip_frames, enable)
    if touched then
        stop_skip_state.applied = enable
        stop_skip_state.last_ctx = ctx
    end
    return touched
end

local function apply_start_skip(enable)
    -- Walk-Starts: Skip + Re-Interpolation (Default true).
    local t_walk = apply_skip_nodes(START_NODES, cfg.start_skip_frames, enable, true)
    -- Run-Starts: Skip OHNE _OverwriteInterpolation -> kein Halt beim Walk->Run.
    local t_run, ctx = apply_skip_nodes(RUN_START_NODES, cfg.start_skip_frames, enable, false)
    local touched = t_walk or t_run
    if touched then
        start_skip_state.applied = enable
        start_skip_state.last_ctx = ctx
    end
    return touched
end

-- [NO_PIVOT] SnappyControls 1:1: die Pivot-States am JogLoop-Node leeren ->
-- harte Jog-Drehungen (R90/R180, auch der Rueckwaerts-180er) existieren nicht
-- mehr; unser Body-Yaw haelt die Richtung. Restore: emplace + State-ID 109
-- (= JogTurn-Node, alphaZomega-Werte).
local no_pivot_state = { applied = false, last_ctx = nil }

local function apply_no_pivot(disable)
    local mfsm, ctx = get_motion_fsm()
    if not mfsm then return false end
    local layer = safe(function() return mfsm:call("getLayer", 0) end)
    local tree = layer and safe(function() return layer:get_tree_object() end)
    if not tree then return false end

    local ok = pcall(function()
        local states = tree:get_node_by_name("JogLoop"):get_data():get_states()
        while disable and states[1] do states:erase(1) end
        while not disable and not states[1] do states:emplace(0) end
        if states[1] then states[1] = 109 end
    end)

    -- Jog-STEERING toeten (jog_curve_R/L): DampingAngle-Action am
    -- JogLoop-Child. Diag zeigte: Engine steuert den Body jede Frame zur
    -- Laufrichtung -> Patt mit unserem Body-Yaw bei ~120° schief. Damping
    -- riesig = Engine dreht nicht mehr, Body gehoert unserem Yaw.
    pcall(function()
        local jloop = tree:get_node_by_name("JogLoop"):get_children()[2]
        local turner = jloop:get_actions()[1] or jloop:get_unloaded_actions()[1]
        if turner and turner["<DampingAngle>k__BackingField"] then
            turner["<DampingAngle>k__BackingField"]._DampingTime = disable and 99.0 or 0.5
        end
    end)

    if ok then
        no_pivot_state.applied = disable
        no_pivot_state.last_ctx = ctx
    end
    return ok
end

-- Re-Apply bei Player-Wechsel (Load/Tod baut den FSM neu auf)
local function update_stop_skip()
    local _, ctx = get_motion_fsm()
    if not ctx then return end
    if cfg.stop_skip and ctx ~= stop_skip_state.last_ctx then
        apply_stop_skip(true)
    end
    if cfg.start_skip and ctx ~= start_skip_state.last_ctx then
        apply_start_skip(true)
    end
    if cfg.no_pivot and ctx ~= no_pivot_state.last_ctx then
        apply_no_pivot(true)
    end
end

local bw_motion = nil   -- gecachte via.motion.Motion (Anim-Export)

-- Layer0-Anim-Name pro Frame exportieren (LockScene = exakt 1x/Game-Frame).
local function update_anim_export()
    local tf = get_body_transform()
    -- [ANIM_EXPORT_CACHE 2026-08-02] bw_motion MUSS mit zurueckgesetzt werden:
    -- nach einem Savegame-Load ist das Body-GameObject neu, der Cache zeigt auf
    -- die tote via.motion.Motion, getLayer scheitert still -> __vr_anim_l0 bleibt
    -- dauerhaft nil -> run_blend=0 -> "Beine nach hinten (Rennen)" wirkt nicht mehr
    -- (im Log belegt: export='nil' bei sauber lesbarem L0-Namen). Erholte sich
    -- frueher NUR durch "Reset Scripts" -> sah nach einem Vorfuehreffekt aus.
    if not tf then _G.__vr_anim_l0 = nil bw_motion = nil return end
    if not bw_motion then
        local go = safe(function() return tf:call("get_GameObject") end)
        bw_motion = go and safe(function()
            return go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
        end)
    end
    if not bw_motion then _G.__vr_anim_l0 = nil return end
    local layer = safe(function() return bw_motion:call("getLayer", 0) end)
    local node = layer and safe(function() return layer:call("get_HighestWeightMotionNode") end)
    local name = node and safe(function() return node:call("get_MotionName") end)
    _G.__vr_anim_l0 = (type(name) == "string" and name ~= "") and name or nil
    -- [ANIM_EXPORT_CACHE 2026-08-02] Zweite Sicherung: der Transform kann nach dem
    -- Load gueltig sein, waehrend die gecachte Motion schon tot ist (tf-Zweig oben
    -- greift dann nie). Kein Name -> Cache verwerfen, naechster Frame holt frisch.
    if not _G.__vr_anim_l0 then bw_motion = nil end
end

local function flat_yaw_of(rot)
    local f = rot * Vector3f.new(0, 0, 1)
    local len = math.sqrt(f.x * f.x + f.z * f.z)
    if len < 0.0001 then return nil end
    return math.atan(f.x / len, f.z / len)
end

local function yaw_to_quat(yaw)
    local half = yaw * 0.5
    return Quaternion.new(math.cos(half), 0.0, math.sin(half), 0.0)
end

-- [UB_LOCK] Oberkoerper steif: LOKALE Rotationen der Spine/Neck-Kette beim
-- Aktivieren einfrieren und pro Phase erzwingen. Body-relativ -> Stick-Drehen
-- bleibt frei (der alte WELT-Lock hatte den "dreht nicht mit"-Bug).
-- Vor allem gegen Lauf-/Lean-Anims, die in die Kamera durchschlagen.
-- [WELT-MODUS] (ub_lock_world): Welt-Rotation = BodyYaw * eingefrorene
-- Rel-Pose, spaet im Frame erzwungen — Hueft-/Lauf-Anim kann den Block
-- nicht mehr kippen. Re-Basing auf aktuellen Body-Yaw fixt den alten
-- "dreht nicht mit"-Bug.
local ub_lock_pose = nil   -- LOKAL-Modus: name -> lokale Rotation (Quat)
local ub_lock_rel = nil    -- WELT-Modus: name -> Rotation relativ Body-Yaw
local ub_lock_base = nil   -- Trim-Basis (Joint 1: raw local + parent/world rot)
local ub_trim_applied = nil

local function apply_ub_lock(can_capture)
    if not cfg.ub_lock then
        ub_lock_pose = nil
        ub_lock_rel = nil
        ub_lock_base = nil
        return
    end
    if is_ks_active() then return end
    local tf = get_body_transform()
    if not tf then return end

    if cfg.ub_lock_world then
        -- [WELT-MODUS] Welt-Rotation absolut erzwingen (spaete Korrektur)
        local brot = safe(function() return tf:call("get_Rotation") end)
        local byaw = brot and flat_yaw_of(brot)
        if not byaw then return end
        local bq = yaw_to_quat(byaw)
        if not ub_lock_rel then
            -- Capture nur im stabilen Slot (LockScene-pre, nach Yaw-Write)
            if not can_capture then return end
            local inv = safe(function() return bq:conjugate() end)
            if not inv then return end
            local rel = {}
            for _, name in ipairs(SPINE_YAW_JOINTS) do
                local j = get_spine_joint(tf, name)
                local w = j and safe(function() return j:call("get_Rotation") end)
                local r = w and safe(function() return (inv * w):normalized() end)
                if not r then return end
                rel[name] = r
            end
            ub_lock_rel = rel
        end
        local trim = cfg.ub_trim_deg or 0.0
        local tq = nil
        if trim ~= 0.0 then
            local half = math.rad(trim) * 0.5
            tq = Quaternion.new(math.cos(half), 0.0, math.sin(half), 0.0)
        end
        for _, name in ipairs(SPINE_YAW_JOINTS) do
            local j = get_spine_joint(tf, name)
            local r = ub_lock_rel[name]
            if j and r then
                local tgt
                if tq then
                    tgt = safe(function() return (bq * tq * r):normalized() end)
                else
                    tgt = safe(function() return (bq * r):normalized() end)
                end
                if tgt then
                    pcall(function() j:call("set_Rotation", tgt) end)
                end
            end
        end
        return
    end

    -- Lazy-Capture beim (Re-)Aktivieren: aktuelle lokale Pose einfrieren
    if not ub_lock_pose then
        if not can_capture then return end
        local pose = {}
        local complete = true
        for _, name in ipairs(SPINE_YAW_JOINTS) do
            local j = get_spine_joint(tf, name)
            local lr = j and safe(function() return j:call("get_LocalRotation") end)
            if lr then
                pose[name] = lr
            else
                complete = false
            end
        end
        if not complete then return end
        -- Trim-Basis am ERSTEN Joint: ganzer Torso dreht als Block.
        -- (Trim an jedem Joint wuerde sich die Kette runter aufaddieren.)
        local first = SPINE_YAW_JOINTS[1]
        local j1 = get_spine_joint(tf, first)
        local w1 = j1 and safe(function() return j1:call("get_Rotation") end)
        local p1j = j1 and safe(function() return j1:call("get_Parent") end)
        local p1 = p1j and safe(function() return p1j:call("get_Rotation") end)
        if not (w1 and p1) then return end
        ub_lock_pose = pose
        ub_lock_base = { raw = pose[first], parent = p1, world = w1 }
        ub_trim_applied = nil
    end

    -- [UB_TRIM] Yaw-Trim in die eingefrorene Pose einbacken (gegen die
    -- schraege 3rd-Person-Grundhaltung); Re-Bake nur bei Slider-Aenderung
    local trim = cfg.ub_trim_deg or 0.0
    if ub_trim_applied ~= trim and ub_lock_base then
        local first = SPINE_YAW_JOINTS[1]
        if trim == 0.0 then
            ub_lock_pose[first] = ub_lock_base.raw
            ub_trim_applied = trim
        else
            local half = math.rad(trim) * 0.5
            local y = Quaternion.new(math.cos(half), 0.0, math.sin(half), 0.0)
            local inv = safe(function() return ub_lock_base.parent:conjugate() end)
            local nl = inv and safe(function()
                return (inv * y * ub_lock_base.world):normalized()
            end)
            if nl then
                ub_lock_pose[first] = nl
                ub_trim_applied = trim
            end
        end
    end

    for _, name in ipairs(SPINE_YAW_JOINTS) do
        local j = get_spine_joint(tf, name)
        local q = ub_lock_pose[name]
        if j and q then
            pcall(function() j:call("set_LocalRotation", q) end)
        end
    end
end

local function apply_spine_yaw(tf)
    local deg = cfg.spine_yaw_deg or 0.0
    if deg == 0.0 or not tf then return end
    local half = math.rad(deg) * 0.5
    local yaw_off = Quaternion.new(math.cos(half), 0.0, math.sin(half), 0.0)
    for _, name in ipairs(SPINE_YAW_JOINTS) do
        local j = get_spine_joint(tf, name)
        if j then
            local r = safe(function() return j:call("get_Rotation") end)
            -- Anti-Akkumulation: wenn die Rotation noch unsere eigene letzte
            -- Schreibung ist (Anim eingefroren, z.B. Pause), NICHT erneut
            -- draufrechnen — sonst Dauerdrehung.
            if r and not quat_approx_equal(r, spine_last_written[name]) then
                local nr = safe(function() return (yaw_off * r):normalized() end)
                if nr then
                    pcall(function() j:call("set_Rotation", nr) end)
                    spine_last_written[name] = nr
                end
            end
        end
    end
end

-- [CROUCH_UB_Z] Im Crouch ist der Spine-Pin geloest (Body animiert nativ —
-- sonst liesse sich nicht hocken). Damit der Oberkoerper trotzdem nicht
-- nach vorn ins Bild lehnt: ein rein ADDITIVER Z-nach-hinten-Offset auf die
-- UB-Joints, NUR Position (Rotation bleibt nativ -> die Hock-Beuge animiert
-- weiter). Muster wie apply_spine_yaw: Basis 1x/Frame frisch NACH dem
-- Anim-Update lesen (capture_base in LateUpdateBehavior), dann in den spaeten
-- Phasen ABSOLUT (base+Offset) schreiben -> idempotent, kein Aufschaukeln,
-- aber kein Einfrieren. = zweiter Oberkoerper-Zustand neben dem Steh-Pin.
-- [CROUCH_PIN] forward-decl (Upvalue): apply_crouch_ub_z liest crouchpin.rel
local crouchpin = { rel = nil, par_inv = nil, null_rel = nil,
                    cfg_tried = false, capture_req = false }

local crouch_ubz = { base = nil }
local function apply_crouch_ub_z(capture_base)
    if not cfg.spine_pin then return end           -- selber Master wie der Pin
    -- Rigide Crouch-Pose gepinnt? Dann hat apply_crouch_pin das Sagen ueber die
    -- UB-Joints -> der additive Slider wuerde dagegenschreiben. Aussetzen.
    if crouchpin.rel then return end
    local z = cfg.pin_ub_z_crouch or 0.0
    if z == 0.0 then crouch_ubz.base = nil; return end
    if is_ks_active() then return end
    if not is_crouch_active() then crouch_ubz.base = nil; return end
    local tf = get_body_transform()
    if not tf then return end
    if not spinepin_resolve(tf) then return end
    if not (spinepin.joints and spinepin.names) then return end
    local tr = safe(function() return tf:call("get_Rotation") end)
    local tri = tr and safe(function() return tr:conjugate() end)
    if not (tr and tri) then return end

    -- Native UB-Basis 1x/Frame einsammeln (post-anim -> echte Hock-Pose)
    if capture_base then
        local base = {}
        for i, name in ipairs(spinepin.names) do
            if UB_JOINTS[name] then
                base[i] = safe(function() return spinepin.joints[i]:call("get_LocalPosition") end)
            end
        end
        crouch_ubz.base = base
    end
    local base = crouch_ubz.base
    if not base then return end

    for i, name in ipairs(spinepin.names) do
        if UB_JOINTS[name] and base[i] then
            -- transform-Z "nach hinten" in den Parent-Raum des Joints drehen
            -- (wie der pin_ub_z-Offset, nur auf die native Basis addiert)
            local parent = spinepin.joints[i - 1]
            local pw = parent and safe(function() return parent:call("get_Rotation") end)
            local v = Vector3f.new(0.0, 0.0, -z)
            if pw then
                local relp = safe(function() return (tri * pw):normalized() end)
                local pinv = relp and safe(function() return relp:conjugate() end)
                local rv = pinv and safe(function() return pinv * v end)
                if rv then v = rv end
            end
            local p = base[i]
            pcall(function()
                spinepin.joints[i]:call("set_LocalPosition",
                    Vector3f.new(p.x + v.x, p.y + v.y, p.z + v.z))
            end)
        end
    end
end

-- [CROUCH_PIN] Eigene gepinnte HOCK-Pose, Pendant zum Steh-Pin (apply_spine_pin).
-- duckt sich im Stand, drueckt den PIN-Button -> die native Hock-Pose des
-- Oberkoerpers wird EINMAL gecaptured (entdrillt) + auf Platte gesichert. Ab
-- dann wird im Crouch genau diese Pose absolut gehalten -> kein Vorlehnen beim
-- Crouch-Walk mehr (HMD schaut nicht mehr auf den eigenen Ruecken).
-- LEHRE 2026-06-10: NIE im aktiven Slot re-capturen (= Kamera-Fly-out durch
-- Rueckkopplung). Capture laeuft NUR per Button (capture_req), und dafuer wird
-- der Enforce einen Frame ausgesetzt -> der post-anim LateUpdateBehavior-Pass
-- liest die NATIVE Hock-Pose. Kein Feedback, kein Anker-Weglaufen.
local function apply_crouch_pin(can_capture)
    if not cfg.spine_pin then return end   -- Master aus: Pose-Slot behalten
    if is_ks_active() then return end
    if is_pin_release() then return end    -- [PIN_RELEASE] nur Pin loesen
    if not is_crouch_active() then
        -- Crouch verlassen: Pose-Slot BEHALTEN (greift beim naechsten Crouch
        -- sofort wieder), nur den offenen Capture-Wunsch verwerfen.
        crouchpin.capture_req = false
        return
    end

    local tf = get_body_transform()
    if not tf then return end

    -- Spawn-Guard wie beim Steh-Pin: tote Joint-Handles neu aufloesen
    if spinepin.joints then
        local probe = spinepin.joints[1]
        local alive = probe and pcall(function() return probe:call("get_Position") end)
        if not alive then
            spinepin.tf = nil; spinepin.joints = nil; spinepin.null_off = nil
        end
    end
    if not spinepin_resolve(tf) then return end
    if not (spinepin.joints and spinepin.names) then return end

    -- Capture-Wunsch (Button): Enforce diesen Frame AUSSETZEN. Im post-anim
    -- LateUpdateBehavior-Pass (can_capture) die native Hock-Pose greifen +
    -- sichern. In allen anderen Passes nur returnen (native bleibt sichtbar).
    if crouchpin.capture_req then
        if can_capture then
            local r, pi, nr = spinepin_capture(tf)
            if r then
                crouchpin.rel, crouchpin.par_inv, crouchpin.null_rel = r, pi, nr
                crouchpin.capture_req = false
                spinepin_store(r, pi, nr, "crouch_pose")
            end
        end
        return
    end

    -- Persistierte Hock-Pose 1x pro Script-Lauf von Platte ziehen
    if not crouchpin.rel then
        if not crouchpin.cfg_tried then
            crouchpin.cfg_tried = true
            local r, pi, nr = spinepin_restore("crouch_pose")
            if r then crouchpin.rel, crouchpin.par_inv, crouchpin.null_rel = r, pi, nr end
        end
        if not crouchpin.rel then
            -- nichts gepinnt -> native Crouch: Body animiert selbst, Surge gehoert
            -- auf die Kamera (firstperson) -> Bridge AUS.
            _G.__vr_surge_bridged = false
            return
        end
    end

    -- Enforce: gecapturete Hock-Pose ABSOLUT auf die Kette schreiben (root-Anker
    -- + Hip + Spine + Neck + Head). Beine (nicht in PIN_JOINTS) animieren weiter,
    -- der Torso steht starr im Crouch. Der Slider "Oberkoerper nach hinten IM
    -- CROUCH" (pin_ub_z_crouch) wird HIER auf die UB-Joints addiert (in den
    -- Parent-Raum gedreht, wie pin_ub_z im Steh-Pin) -> wirkt MIT dem Pin statt
    -- dagegen (frueher separat in apply_crouch_ub_z -> wurde vom Pin ueberschrieben).
    local cur_rel, cur_par_inv, cur_null = crouchpin.rel, crouchpin.par_inv, crouchpin.null_rel
    local ubz = cfg.pin_ub_z_crouch or 0.0
    -- [UB_Z_DELTA 2026-07-22] Wie weit der Oberkoerper im Crouch ANDERS steht als beim Gehen
    -- (Referenz = Steh-Pin). Genau um diesen Betrag sitzen die am Spine haengenden Holster-Meshes
    -- verschoben; re4_vr_holster.lua zieht sie damit optisch zurecht. Reines Info-Global.
    _G.__re4_ub_z_delta = ubz - (cfg.pin_ub_z or 0.0)
    -- [HIP_CROUCH_Z] "Beine nach hinten" im Crouch: VOLL (kein run_blend) -> verschiebt
    -- Hip+Beine nach hinten, Spine_0 kompensiert gegen (Oberkoerper bleibt stehen).
    -- Gleiche Mechanik wie der HIP_RUN_Z-Block im Steh-Pin, nur ohne Rennen-Blend.
    -- [SEPARAT 2026-07-22] Eigener Wert pin_z_hip_crouch; solange er nie gesetzt wurde
    -- (nil), gilt weiterhin pin_z.Hip (=Rennen) -> unveraendertes Verhalten.
    local hipz = cfg.pin_z_hip_crouch or ((cfg.pin_z and cfg.pin_z.Hip) or 0.0)

    -- [SURGE_BRIDGE] WIE im Steh-Pin: die Kamera (Head) faehrt beim Beschleunigen
    -- eine geglaettete Surge-Bahn (firstperson). Der hart gepinnte Anker MUSS
    -- denselben Welt-Versatz mitgehen, sonst laeuft die Kamera dem Body voraus
    -- = Body ragt tempo-proportional vorn ins Bild ("lehnt sich beim Crouch-Walk
    -- vor"). __vr_surge_bridged=true -> firstperson legt den Shift NICHT nochmal
    -- auf die Kamera (Head traegt ihn schon).
    _G.__vr_surge_bridged = true
    local anchor_p = cur_rel[1] and cur_rel[1].p
    local sdx = tonumber(_G.__vr_surge_dx) or 0.0
    local sdz = tonumber(_G.__vr_surge_dz) or 0.0
    if anchor_p and (sdx ~= 0.0 or sdz ~= 0.0) then
        local tr = safe(function() return tf:call("get_Rotation") end)
        local tri = tr and safe(function() return tr:conjugate() end)
        local off = tri and safe(function()
            return tri * Vector3f.new(sdx, 0.0, sdz)
        end)
        if off then
            anchor_p = Vector3f.new(anchor_p.x + off.x, anchor_p.y + off.y,
                                    anchor_p.z + off.z)
        end
    end

    for i, j in ipairs(spinepin.joints) do
        local rel = cur_rel[i]
        if rel then
            local p = (i == 1 and anchor_p) and anchor_p or rel.p
            local name = spinepin.names and spinepin.names[i]
            -- Z-Offsets sammeln: UB-Slider (alle Spine/Neck) + Hip-Slider (Hip
            -- nach hinten, Spine_0 als Gegenkompensation).
            local zo = 0.0
            -- [UB_X_CROUCH 2026-07-22] "Oberkoerper seitlich" hat im Crouch einen EIGENEN Wert
            -- (pin_ub_x_crouch); der Steh-Slider pin_ub_x gilt ab jetzt nur noch ausserhalb des Crouch.
            -- Vorher wurde im Crouch-Pin ueberhaupt kein X verrechnet -> Default 0.0 = wie bisher.
            local xo = 0.0
            if name and UB_JOINTS[name] then
                zo = zo + ubz
                xo = xo + (cfg.pin_ub_x_crouch or 0.0)
            end
            if name == "Hip" then
                zo = zo + hipz
            elseif name == "Spine_0" then
                zo = zo - hipz
            end
            if zo ~= 0.0 or xo ~= 0.0 then
                local v = Vector3f.new(xo, 0.0, -zo)
                local pi = cur_par_inv and cur_par_inv[i]
                if pi then
                    local rv = safe(function() return pi * v end)
                    if rv then v = rv end
                end
                p = Vector3f.new(p.x + v.x, p.y + v.y, p.z + v.z)
            end
            pcall(function()
                j:call("set_LocalPosition", p)
                j:call("set_LocalRotation", rel.r)
            end)
        end
    end
    if spinepin.null_off and cur_null then
        pcall(function()
            spinepin.null_off:call("set_LocalPosition", cur_null.p)
            spinepin.null_off:call("set_LocalRotation", cur_null.r)
        end)
    end
end

-- [CAM_BODY_ROTATE v2] Body-Yaw-Follow + SLOT-Prinzip: Write in pre-Update-
-- Transform — das LETZTE Wort der Frame VOR dem Bone-Bake. Engine-Dreh-
-- versuche (jog_turn/jog_curve beim Rueckwaertsflip) werden dadurch komplett
-- ueberstempelt, nicht rate-limitiert zurueckgeholt (das gab das 120°-Patt).
-- Lua-Aequivalent: WIR BESITZEN den Yaw (owned_yaw) — 1x/Frame differentiell
-- Richtung Cam avancieren (LockScene-pre, Speed-Slider wie gehabt), und in
-- den spaeten Phasen (UpdateMotion/LateUpdateBehavior/BeginRendering pre+post)
-- ERZWINGEN: Engine-Writes dazwischen werden voll revertiert.
-- Idle/Aligned: Engine schreibt nichts -> Ist==owned -> kein Write (Tippel-fix
-- bleibt strukturell erhalten).
local BODY_YAW_EPS_DEG = 0.05
local body_yaw_last_t = nil
local owned_yaw = nil   -- rad; nil = Engine besitzt den Body (Aim/KS/Cutscene)
-- (flat_yaw_of / yaw_to_quat nach oben verschoben — UB-Lock-Welt-Modus braucht sie frueher)

-- [CBR_DIAG] Temporaerer Diagnose-Log fuer "Body folgt nicht". Liest alle
-- Guard-Bedingungen unabhaengig und schreibt gedrosselt nach data/.
local cbr_diag_last_t = nil
local function cbr_diag()
    do return end   -- [LOG AUS 2026-07-06]
    local now = os.clock()
    if cbr_diag_last_t and (now - cbr_diag_last_t) < 0.5 then return end
    cbr_diag_last_t = now
    local enabled   = cfg.enabled == true
    local cbr       = cfg.cam_body_rotate == true
    local ks        = is_ks_active()
    local hmd       = (vrmod and vrmod:is_hmd_active()) == true
    local aim       = _G.is_aim == true
    local pcc       = get_player_cam_controller() ~= nil
    local cam       = sdk.get_primary_camera()
    local wm        = cam and safe(function() return cam:call("get_WorldMatrix") end)
    local tf        = get_body_transform()
    local body_rot  = tf and safe(function() return tf:call("get_Rotation") end)
    local byaw      = body_rot and flat_yaw_of(body_rot)

    local function deg_or_nil(y) return y and string.format("%.1f", math.deg(y)) or "nil" end

    -- (1) get_WorldMatrix (aktuelles, falsches Ziel)
    local cam_world = nil
    if wm then
        local fx, fz = -wm[2].x, -wm[2].z
        local l = math.sqrt(fx*fx + fz*fz)
        if l > 0.0001 then cam_world = math.atan(fx/l, fz/l) end
    end
    -- (2) PlayerCameraController._CameraRotation (Legacy-Quelle, stick-getrieben)
    local pccobj = get_player_cam_controller()
    local camrot = pccobj and safe(function() return pccobj:get_field("_CameraRotation") end)
    local camrot_yaw = camrot and flat_yaw_of(camrot)
    -- (3) rohe HMD-Rotation
    local hq = safe(function() return vrmod:get_transform(0):to_quat() end)
    local hmd_yaw = hq and flat_yaw_of(hq)
    -- (4) rotation_offset
    local ro = safe(function() return vrmod:get_rotation_offset() end)
    local off_yaw = ro and flat_yaw_of(ro)
    -- (5) Welt-Blickrichtung = rotation_offset * HMD
    local look_yaw = nil
    if ro and hq then
        local okm, lq = pcall(function() return ro * hq end)
        if okm and lq then look_yaw = flat_yaw_of(lq) end
    end

    -- [log entfernt]
end

local function apply_hard_yaw(sample)
    if sample then cbr_diag() end
    if not cfg.enabled then owned_yaw = nil return end
    if is_ks_active() then
        last_yaw_quat = nil
        body_yaw_last_t = nil
        owned_yaw = nil
        return
    end
    if not (vrmod and vrmod:is_hmd_active()) then owned_yaw = nil return end
    -- Avancieren nur 1x/Frame (LockScene-pre); Re-Applies laufen separat.
    if not sample then return end

    -- [AIM_NATIVE] Beim Zielen richtet die ENGINE den Body selbst zur Kamera
    -- aus (Aim-Stance) — nichts tun, Ownership abgeben.
    if _G.is_aim == true then
        body_yaw_last_t = nil
        owned_yaw = nil
        return
    end


    local pcc = get_player_cam_controller()
    if not pcc then
        last_yaw_quat = nil
        body_yaw_last_t = nil
        owned_yaw = nil
        return
    end

    -- [CAM_BODY_ROTATE] Frischer Body-Rotate-Pfad (parallel zum Legacy-
    -- owned_yaw-Lerp darunter). Ziel IMMER die gerenderte Kamera inkl. HMD;
    -- der Body folgt dem physischen Kopfdrehen. Wir avancieren owned_yaw
    -- (nicht direkt die Engine-Transform-angles), damit der enforce-Stack es
    -- gegen Engine-Writes haelt — sonst kein RE4-Halt (5-Hook-Lehre).
    if cfg.cam_body_rotate then
        local tf = get_body_transform()
        if not tf then return end
        local body_rot = safe(function() return tf:call("get_Rotation") end)
        if not body_rot then return end
        local body_yaw = flat_yaw_of(body_rot)
        if not body_yaw then return end
        if owned_yaw == nil then owned_yaw = body_yaw end

        -- Ziel-Forward = gerenderte Kamera inkl. HMD. wm[2] = Kamera-+Z
        -- (Backward); Body-Forward ist 180° dazu -> invertieren (RE4-Konvention).
        local cam = sdk.get_primary_camera()
        local wm = cam and safe(function() return cam:call("get_WorldMatrix") end)
        if not wm then return end
        local tfx, tfz = -wm[2].x, -wm[2].z
        local tlen = math.sqrt(tfx * tfx + tfz * tfz)
        if tlen < 0.0001 then return end
        tfx, tfz = tfx / tlen, tfz / tlen

        -- Ziel-Yaw = Spielkamera-Yaw (camWM) + roher HMD-Yaw. camWM trägt in
        -- RE4 KEIN Kopf-Yaw (Runtime legt das Headset erst beim Rendern auf),
        -- also den HMD-Yaw hier dazurechnen, damit der Body dem Blick folgt.
        local target_yaw = math.atan(tfx, tfz)
        local hq = safe(function() return vrmod:get_transform(0):to_quat() end)
        local hmd_yaw = hq and flat_yaw_of(hq)
        if hmd_yaw then target_yaw = target_yaw + hmd_yaw end   -- [WATCH] Vorzeichen
        if cfg.yaw_offset_deg ~= 0.0 then
            target_yaw = target_yaw + math.rad(cfg.yaw_offset_deg)
        end
        tfx, tfz = math.sin(target_yaw), math.cos(target_yaw)

        -- dt (Rate-Limit)
        local now = os.clock()
        local dt = 0.011
        if body_yaw_last_t then
            dt = now - body_yaw_last_t
            if dt <= 0.0 then dt = 0.011 elseif dt > 0.1 then dt = 0.1 end
        end
        body_yaw_last_t = now

        -- player_forward aus owned_yaw (RE4-Ownership statt Engine-Ist,
        -- gegen Tippeln). forward = (sin y, 0, cos y).
        local pfx, pfz = math.sin(owned_yaw), math.cos(owned_yaw)

        -- orientedAngle(player_forward -> target, +Y): atan2(crossY, dot)
        local dot    = pfx * tfx + pfz * tfz
        local crossY = pfz * tfx - pfx * tfz
        local angle  = math.atan(crossY, dot)        -- rad, signed
        local deg    = math.deg(angle)
        if math.abs(deg) >= 0.001 then
            -- Senkrechte zu forward in Richtung STEIGENDER Yaw = (fz, 0, -fx).
            -- right zeigt VOM Ziel WEG: -sign(angle)*perp ->
            -- (forward - right) zeigt zum Ziel (kurzer Bogen, konvergiert).
            local perpx, perpz = pfz, -pfx
            local s = (angle > 0.0) and 1.0 or -1.0
            local prx, prz = -s * perpx, -s * perpz
            local k = (math.abs(deg) / 720.0) * dt * (cfg.body_yaw_speed or 12.0)
            local nfx = pfx + (pfx - prx) * k
            local nfz = pfz + (pfz - prz) * k
            local nlen = math.sqrt(nfx * nfx + nfz * nfz)
            if nlen >= 0.00001 then
                owned_yaw = math.atan(nfx / nlen, nfz / nlen)
                if owned_yaw > math.pi then owned_yaw = owned_yaw - 2.0 * math.pi
                elseif owned_yaw < -math.pi then owned_yaw = owned_yaw + 2.0 * math.pi end
            end
        end

        last_yaw_quat = yaw_to_quat(owned_yaw)

        -- Erzwingen nur bei Engine-Abweichung (Tippel-fix wie Legacy-Pfad)
        local diff = owned_yaw - body_yaw
        if diff > math.pi then diff = diff - 2.0 * math.pi
        elseif diff < -math.pi then diff = diff + 2.0 * math.pi end
        local q = nil
        if math.abs(diff) >= math.rad(BODY_YAW_EPS_DEG) then
            q = yaw_to_quat(owned_yaw)
            pcall(function() tf:call("set_Rotation", q) end)
        end
        apply_hip_follow(tf, q or yaw_to_quat(owned_yaw))
        return
    end

    -- NUR LESEN. Yaw-Ziel: gerenderte Kamera (inkl. HMD-Drehung, World-
    -- Matrix) ODER nur Stick-Kamera (_CameraRotation).
    -- Ohne HMD-Anteil bleibt der Body beim physischen Kopfdrehen stehen ->
    -- Schulter wandert ins Bild (clav_diag: bis 87° Yaw-Abweichung im Stand).
    -- [PIN_1TO1] Solange der Spine-Pin steht, gilt -Order "ALLES an
    -- einer Position": Ziel IMMER inkl. HMD (gerenderte Kamera) und Snap
    -- statt Lerp — unabhaengig von den Slidern.
    local pin_hard = cfg.spine_pin and spinepin.rel ~= nil
    local fwd
    if cfg.yaw_hmd_target or pin_hard then
        local cam = sdk.get_primary_camera()
        local wm = cam and safe(function() return cam:call("get_WorldMatrix") end)
        if not wm then return end
        -- wm[2] = Kamera-+Z (Backward) — gleiche Konvention wie
        -- cam_rot*(0,0,1) unten, Inversion danach identisch
        fwd = Vector3f.new(wm[2].x, 0.0, wm[2].z)
    else
        local cam_rot = safe(function() return pcc:get_field("_CameraRotation") end)
        if not cam_rot then return end
        fwd = cam_rot * Vector3f.new(0, 0, 1)
        fwd.y = 0.0
    end

    -- Flatten auf Yaw. Body-Forward ist 180° zur Kamera-Forward gedreht,
    -- daher Richtung invertieren (sonst schaut Leon nach hinten).
    local len = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
    if len < 0.0001 then return end
    fwd = Vector3f.new(-fwd.x / len, 0.0, -fwd.z / len)
    local yaw_quat = safe(function() return fwd:to_quat() end)
    if not yaw_quat then return end

    -- Zusätzlicher Yaw-Offset (Slider), Rotation um Welt-Y
    if cfg.yaw_offset_deg ~= 0.0 then
        local half = math.rad(cfg.yaw_offset_deg) * 0.5
        local off = Quaternion.new(math.cos(half), 0.0, math.sin(half), 0.0)
        local ok_m, combined = pcall(function() return (off * yaw_quat):normalized() end)
        if ok_m and combined then yaw_quat = combined end
    end

    last_yaw_quat = yaw_quat

    -- dt fuer Rate-Limit
    local now = os.clock()
    local dt = 0.011
    if body_yaw_last_t then
        dt = now - body_yaw_last_t
        if dt <= 0.0 then dt = 0.011 elseif dt > 0.1 then dt = 0.1 end
    end
    body_yaw_last_t = now

    local tf = get_body_transform()
    if not tf then return end
    local body_rot = safe(function() return tf:call("get_Rotation") end)
    if not body_rot then return end

    local body_yaw = flat_yaw_of(body_rot)
    if not body_yaw then return end

    -- Ownership-Uebernahme ohne Sprung: vom Ist-Yaw starten
    if owned_yaw == nil then owned_yaw = body_yaw end

    local tfwd = yaw_quat * Vector3f.new(0, 0, 1)
    local target_yaw = math.atan(tfwd.x, tfwd.z)

    -- owned_yaw differentiell Richtung Cam avancieren (NICHT vom Engine-Ist —
    -- der enthaelt den Drehversuch dieses Frames, der gleich revertiert wird)
    local d = target_yaw - owned_yaw
    if d > math.pi then d = d - 2.0 * math.pi
    elseif d < -math.pi then d = d + 2.0 * math.pi end

    if math.abs(d) >= math.rad(BODY_YAW_EPS_DEG) then
        local k = dt * (cfg.body_yaw_speed or 12.0)
        if k > 1.0 then k = 1.0 end
        if pin_hard then k = 1.0 end   -- [PIN_1TO1] Snap, kein Nachlaufen
        owned_yaw = owned_yaw + d * k
        if owned_yaw > math.pi then owned_yaw = owned_yaw - 2.0 * math.pi
        elseif owned_yaw < -math.pi then owned_yaw = owned_yaw + 2.0 * math.pi end
    end

    -- Erzwingen: nur schreiben wenn Engine abgewichen ist (Tippel-fix)
    local diff = owned_yaw - body_yaw
    if diff > math.pi then diff = diff - 2.0 * math.pi
    elseif diff < -math.pi then diff = diff + 2.0 * math.pi end
    local q = nil
    if math.abs(diff) >= math.rad(BODY_YAW_EPS_DEG) then
        q = yaw_to_quat(owned_yaw)
        pcall(function() tf:call("set_Rotation", q) end)
    end

    -- Hip hart mitnehmen (kein Anim-Nachlerpen beim Drehen)
    apply_hip_follow(tf, q or yaw_to_quat(owned_yaw))
end

-- Enforcement in den spaeten Phasen (Phasen-Order): Engine-Drehversuche
-- ZWISCHEN den Phasen voll zuruecksetzen. Kein Avancieren, nur erzwingen.
local function enforce_hard_yaw()
    if owned_yaw == nil then return end
    if not cfg.enabled then return end
    if is_ks_active() then return end
    if _G.is_aim == true then return end
    local tf = get_body_transform()
    if not tf then return end
    local body_rot = safe(function() return tf:call("get_Rotation") end)
    if not body_rot then return end
    local body_yaw = flat_yaw_of(body_rot)
    if not body_yaw then return end
    local diff = owned_yaw - body_yaw
    if diff > math.pi then diff = diff - 2.0 * math.pi
    elseif diff < -math.pi then diff = diff + 2.0 * math.pi end
    if math.abs(diff) < math.rad(BODY_YAW_EPS_DEG) then return end
    local q = yaw_to_quat(owned_yaw)
    pcall(function() tf:call("set_Rotation", q) end)
end

-- ---- HMD Body-Follow (RoomScale) ----
-- Body-Position folgt dem physischen HMD-Versatz (lehnen/gehen im Raum).
-- Pro Frame: horizontaler HMD-Offset zur Standing-Origin -> in Welt
-- transformiert (gleiche Pipeline wie Hand-Tracking: rot_offset, dann
-- Kamera-Rotation) -> Body verschieben -> Standing-Origin aufs HMD
-- nachziehen, damit die View nicht doppelt wandert.
-- (quat_rotate_vec3 nach oben verschoben — [SHOULDER_PIN] braucht es frueher.)

local hmd_follow_last = { t = nil }

-- [AUTO_CENTER] Pro Spawn/Map-Load die Standing-Origin hart aufs HMD setzen:
-- das HMD steht je Session/Load woanders im Raum — der Playspace-Versatz
-- landete sonst als konstanter Links/Rechts-Offset zwischen Kamera und Body
-- ("HMD-Offset mal weiter links als in der anderen Map").
local auto_center = { ctx = nil }

local function apply_auto_center()
    if not (vrmod and vrmod:is_hmd_active()) then return end
    if not character_manager then
        character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    local ctx = character_manager and safe(function()
        return character_manager:call("getPlayerContextRef")
    end)
    if not ctx or ctx == auto_center.ctx then return end
    local hmd = safe(function() return vrmod:get_position(0) end)
    local so = safe(function() return vrmod:get_standing_origin() end)
    if not (hmd and so) then return end
    auto_center.ctx = ctx
    so.x = hmd.x
    so.z = hmd.z
    pcall(function() vrmod:set_standing_origin(so) end)
end

-- [ROOMSCALE-RECENTER 2026-08-11] Origin hart aufs HMD ziehen, X/Z wie apply_auto_center
-- (Y bleibt). Wird von den zusaetzlichen Ausloesern unten benutzt.
local function roomscale_recenter()
    local hmd = safe(function() return vrmod:get_position(0) end)
    local so  = safe(function() return vrmod:get_standing_origin() end)
    if not (hmd and so) then return end
    so.x = hmd.x
    so.z = hmd.z
    pcall(function() vrmod:set_standing_origin(so) end)
end

-- Zwei Ausloeser, die apply_auto_center nicht abdeckt (es feuert nur bei neuem
-- Player-Context, also Spawn/Map-Load):
--   1. Killswitch-ENDE: waehrend Cutscene/Sonderfall laeuft der Follow nicht, danach steht
--      der aufgelaufene Versatz sonst dauerhaft im Raum.
--   2. Teleport: springt der Body in EINEM Frame weiter als 3 m, war es kein Gehen.
-- Beides nur mit Roomscale-Haken; ohne ihn passiert hier gar nichts.
local rs_prev_ks   = false
local rs_prev_pos  = nil
local function roomscale_recenter_events()
    if not (cfg.roomscale and cfg.rs_recenter) then
        rs_prev_ks, rs_prev_pos = false, nil
        return
    end

    local ks = is_ks_active()
    if rs_prev_ks and not ks then roomscale_recenter() end
    rs_prev_ks = ks
    if ks then rs_prev_pos = nil; return end

    local tf  = get_body_transform()
    local pos = tf and safe(function() return tf:call("get_Position") end)
    if not pos then rs_prev_pos = nil; return end

    if rs_prev_pos then
        local dx, dz = pos.x - rs_prev_pos.x, pos.z - rs_prev_pos.z
        if (dx * dx + dz * dz) > (3.0 * 3.0) then roomscale_recenter() end
    end
    rs_prev_pos = { x = pos.x, z = pos.z }
end

-- [ROOMSCALE-CROUCH 2026-08-11] Physisches Ducken loest den ECHTEN Hock-Zustand aus.
-- Bewusst ueber den normalen Knopf (B) statt ueber eine erzwungene Animation: damit sehen
-- Crouch-Pin, Hip-Werte und alles andere exakt dasselbe wie beim Ducken per Stick.
--
-- Kein eigener Zustand: verglichen wird IST (is_crouch_active) gegen SOLL (Kopfhoehe).
-- Weichen sie ab, geht genau EIN Druck raus und danach 0,6 s Ruhe -- so kann sich nichts
-- aufschaukeln, und ein per Stick ausgeloester Crouch wird nicht bekaempft.
-- Gemessen wird gegen die KALIBRIERTE Standhoehe des Spielers, nicht gegen feste
-- Zentimeter: ein 2,00-m-Spieler duckt sich tiefer als ein 1,60-m-Spieler.

-- [ROOMSCALE 2026-08-11] Forward-Deklaration: die Definition steht weiter unten, und eine
-- erst spaeter angelegte local waere hier oben eine ganz andere (globale) Variable.
-- Gebraucht wird sie, weil `__re4_frame_pure_gameplay` aus dem Binding hier nie true war --
-- movement hat mit pure_gameplay_only() ohnehin seine eigene, verlaessliche Pruefung.
local pure_gameplay_only

local rs_prev_hmd = nil       -- Kopfposition des letzten Aufrufs (Delta-Modus)
-- [ROOMSCALE 2026-08-11] Gesammelte, noch nicht geschriebene Strecke (s. Kommentar unten).
local rs_pending = { x = 0.0, z = 0.0 }

local rs_crouch_next_t = 0.0
local function roomscale_crouch()
    if not (cfg.roomscale and cfg.rs_crouch) then
        return
    end
    if is_ks_active() then return end
    local pg_ok, pg_why = pure_gameplay_only()
    if not pg_ok then
        return
    end

    local stand = cfg.rs_stand_height or 0.0
    if stand < 0.5 then return end

    local hmd = safe(function() return vrmod:get_position(0) end)
    if not hmd then return end

    local pct     = cfg.rs_crouch_pct or 0.20
    local down_at = stand * (1.0 - pct)
    local up_at   = stand * (1.0 - pct * 0.6)   -- Hysterese, sonst flattert es am Rand

    local want
    if hmd.y < down_at then want = true
    elseif hmd.y > up_at then want = false
    else
        return                                   -- dazwischen: gar nichts tun
    end

    local ist = (is_crouch_active() == true)
    if want == ist then return end

    local now = os.clock()
    if now < rs_crouch_next_t then return end
    rs_crouch_next_t = now + 0.6
    _G.__re4_want_crouch_press = true            -- re4_vr_binding.lua drueckt B
end

local function apply_hmd_body_follow()
    if not cfg.enabled or not cfg.hmd_follow then return end
    if is_ks_active() then return end
    if not (vrmod and vrmod:is_hmd_active()) then return end
    if not get_player_cam_controller() then return end

    local hmd = safe(function() return vrmod:get_position(0) end)
    local so = safe(function() return vrmod:get_standing_origin() end)
    if not hmd or not so then return end


    -- Horizontaler Versatz im Tracking-Space
    local dx = hmd.x - so.x
    local dz = hmd.z - so.z
    local dist2 = dx * dx + dz * dz

    -- [ROOMSCALE 2026-08-11] Umstellung von "Versatz jagen" auf "Bewegung uebertragen":
    -- Roomscale nimmt die Strecke, die der Kopf SEIT DEM LETZTEN AUFRUF zurueckgelegt hat,
    -- und schiebt Body und Origin um exakt diese Strecke -- jeden Frame, ohne Schwelle.
    -- Grund (gemessen): die Pose ist jeden Aufruf frisch (44/s), der aufgelaufene Versatz
    -- musste aber erst die Deadzone knacken und wurde dann in einem Rutsch von ~5 cm
    -- abgebaut -- 5 bis 14 Spruenge pro Sekunde statt fluessiger Bewegung.
    -- WICHTIG: `rs_prev_hmd` wird erst NACH dem Anwenden fortgeschrieben. Wuerde es hier
    -- oben passieren, ginge jede Bewegung verloren, die unter der Schwelle abbricht --
    -- der Body bliebe dauerhaft zurueck.
    local rs_delta = false
    if cfg.roomscale and not cfg.rs_lean and rs_prev_hmd then
        dx = hmd.x - rs_prev_hmd.x
        dz = hmd.z - rs_prev_hmd.z
        dist2 = dx * dx + dz * dz
        rs_delta = true
        -- Sicherung: 20 cm in EINEM Aufruf kann kein Schritt sein, sondern eine Pause
        -- (Cutscene, Killswitch, Menue, Tracking-Aussetzer). Solche Spruenge werden NICHT
        -- uebertragen -- sonst schiesst der Body quer durch den Raum. Nur neu einnorden.
        if dist2 > (0.20 * 0.20) then
            rs_prev_hmd = { x = hmd.x, z = hmd.z }
            return
        end
    end
    -- [ROOMSCALE-LEAN 2026-08-11] Mit Lean-Zone darf der Kopf den Body bis zum Radius
    -- verlassen, ohne dass der Body nachrutscht -- erst DARUEBER hinaus wird gefolgt
    -- (der Soft-Knee unten zieht den Radius ohnehin ab). Ohne Roomscale gilt weiter die
    -- reine Rausch-Deadzone, der Wert des Users wird nicht angefasst.
    local dead = cfg.hmd_follow_deadzone or 0.0
    if cfg.roomscale and cfg.rs_lean then
        dead = math.max(dead, cfg.rs_lean_radius or 0.0)
    end
    -- Im Delta-Modus ist die Deadzone nur noch ein Rausch-Gatter: was hier durchfaellt, ist
    -- Tracking-Rauschen und darf verworfen werden, alles andere kommt sofort an.
    if rs_delta then dead = 0.0002 end
    if dist2 < (dead * dead) then
        return
    end

    -- [SOFT_FOLLOW] Sanft lerpen statt 1:1-Zittern:
    -- (1) Soft-Knee: nur den Anteil JENSEITS der Deadzone uebertragen —
    -- vorher schaltete die Kante hart (voller Offset an/aus) und
    -- Kopfwackeln genau am Rand wurde zum Body-Stepping.
    -- (2) Zeitbasiert (dt-exponentiell) statt pro Frame: "Staerke" fuehlt
    -- sich bei 60fps an wie bisher, ist aber framerate-unabhaengig
    -- und bei kleinen Werten butterweich.
    local dist = math.sqrt(dist2)
    local knee = (dist - dead) / dist
    -- [ROOMSCALE 2026-08-11] Der Soft-Knee zieht die Deadzone ab -- direkt hinter der Kante
    -- kommt deshalb nur ein Bruchteil der Bewegung an (6 mm Versatz bei 5 mm Deadzone = 17 %),
    -- und mit 1:1-Staerke fuehlt sich genau das ungleichmaessig an: kleine Schritte werden
    -- geschluckt, groessere schnappen. Bei reinem Roomscale (ohne Lehn-Zone) wird deshalb die
    -- VOLLE Strecke uebertragen und die Deadzone ist nur noch ein Rausch-Gatter.
    -- Mit Lehn-Zone bleibt der Knee: dort SOLL nur der Ueberschuss ankommen.
    if cfg.roomscale and not cfg.rs_lean then knee = 1.0 end
    if rs_delta then knee = 1.0 end     -- eine Strecke wird nicht beschnitten
    dx = dx * knee
    dz = dz * knee

    -- [ROOMSCALE 2026-08-11] Mit Haken 1:1 nachziehen, sonst der eingestellte Wert.
    -- Bewusst als Effektivwert und NICHT durch Schreiben in cfg: dein 0,25 bleibt stehen
    -- und ist beim Ausschalten sofort wieder da.
    local alpha = cfg.roomscale and 1.0 or (cfg.hmd_follow_alpha or 0.25)
    if alpha > 0.99 then alpha = 0.99 elseif alpha < 0.01 then alpha = 0.01 end
    local now = os.clock()
    local dt = hmd_follow_last.t and math.min(now - hmd_follow_last.t, 0.1) or 0.016
    hmd_follow_last.t = now
    local a = 1.0 - math.exp(math.log(1.0 - alpha) * dt * 60.0)
    if rs_delta then a = 1.0 end        -- die Strecke ist schon "pro Frame", nichts daempfen
    dx = dx * a
    dz = dz * a

    -- Tracking -> Welt (wie controller_to_world im Motion-Script)
    local delta = Vector3f.new(dx, 0.0, dz)
    local rot_off = safe(function() return vrmod:get_rotation_offset() end)
    if rot_off then
        delta = quat_rotate_vec3(rot_off, delta)
    end

    local cam = sdk.get_primary_camera()
    local cam_go = cam and safe(function() return cam:call("get_GameObject") end)
    local cam_tf = cam_go and safe(function() return cam_go:call("get_Transform") end)
    local cam_rot = cam_tf and safe(function() return cam_tf:call("get_Rotation") end)
    if not cam_rot then return end
    -- [ROOMSCALE 2026-08-11] Die Kamerarotation enthaelt PITCH und ROLL. Eine waagerechte
    -- Trackingstrecke damit zu drehen macht sie kuerzer/schief, sobald man den Kopf neigt --
    -- und beim Gehen nickt der Kopf staendig. Genau das moduliert die Schrittweite und
    -- sieht als Zittern/Nachziehen aus. Fuer Roomscale deshalb NUR das Yaw benutzen.
    -- Ohne Roomscale bleibt es exakt wie bisher.
    if cfg.roomscale then
        local cyaw = flat_yaw_of(cam_rot)
        if cyaw then cam_rot = yaw_to_quat(cyaw) end
    end
    delta = quat_rotate_vec3(cam_rot, delta)
    delta.y = 0.0


    -- Body horizontal verschieben
    local tf = get_body_transform()
    if not tf then return end
    local pos = safe(function() return tf:call("get_Position") end)
    if not pos then return end
    -- [ROOMSCALE 2026-08-11] MESSBEFUND: in dieser Phase (LockScene, pre) ist der Write
    -- verloren -- angefordert 0,3-0,57 m pro Sekunde, tatsaechlich angekommen 0,001 m.
    -- Die Engine schreibt die Position danach neu. Genau dieses Hin und Her erzeugt auch
    -- das Zappeln an Jacke und Holster. Deshalb wird die Strecke hier nur GESAMMELT und
    -- spaeter in der Enforce-Phase geschrieben -- dieselbe Stelle, an der auch das Yaw
    -- gegen die Engine durchgesetzt wird. Ohne Roomscale bleibt der alte Direkt-Write.
    if cfg.roomscale then
        rs_pending.x = rs_pending.x + delta.x
        rs_pending.z = rs_pending.z + delta.z
    else
        pcall(function()
            tf:call("set_Position", Vector3f.new(pos.x + delta.x, pos.y, pos.z + delta.z))
        end)
    end


    -- Standing-Origin um den GLEICHEN Anteil Richtung HMD ziehen (Y bleibt!)
    pcall(function()
        so.x = so.x + dx
        so.z = so.z + dz
        vrmod:set_standing_origin(so)
    end)

    -- Erst JETZT fortschreiben: bis hierher wurde die Strecke tatsaechlich angewandt.
    rs_prev_hmd = { x = hmd.x, z = hmd.z }
end
-- ============================================================
-- [HMD_YAW_DRIVE] (konsolidiert aus dem fruehern re4_vr_hmd_movement.lua)
-- Treibt das Engine-Kamera-Yaw-Feld _Yaw (chainsaw.PlayerCameraController)
-- vom HMD -> die Engine dreht Body + Kamera NATIV (wie der Stick).
-- Doppel-HMD-Vermeidung: rotation_offset = -hmd_yaw gleicht das Headset im
-- Bild aus (get_transform(0) = rohes Tracking -> kein Feedback). Anti-Jitter:
-- _CameraRotation einmal direkt auf den ungedaempften Zielwert (nur Yaw).
-- Killswitch-aware. Eigener Toggle cfg.hmd_yaw_drive (NICHT cfg.enabled).
-- ============================================================
local hmd_yaw_pcc  = nil   -- aus dem updateCameraPosition-Hook (richtige Instanz + Timing)
local hmd_yaw_prev = nil

local function hmd_wrap(a)
    if a > math.pi then return a - 2.0 * math.pi
    elseif a < -math.pi then return a + 2.0 * math.pi end
    return a
end
local function hmd_raw_yaw()
    local hq = safe(function() return vrmod:get_transform(0):to_quat() end)
    return hq and flat_yaw_of(hq)
end
local function hmd_yaw_active()
    if not cfg.hmd_yaw_drive then return false end
    if not (vrmod and vrmod:is_hmd_active()) then return false end
    if is_ks_active() then return false end
    return true
end
-- [SCOPE_FREEZE] Pitch-Follow-State: Basis-Gun-Pitch beim Scope-Eintritt; Blick folgt dem Delta.
local scope_pitch_base = nil
local SCOPE_PITCH_SIGN = 1.0   -- live tunebar: auf -1.0 stellen falls der Blick falsch herum kippt
-- [SCOPE] Aktiver Slot = scope_sets[wid][state]. state = montiertes Scope (__re4_scope_id) oder
-- "ironsight" (kein Scope montiert). wid von weapons.lua (__re4_scope_wid). nil = unbekannte Waffe -> kein Versatz.
local function active_scope_slot()
    local w = rawget(_G, "__re4_scope_wid")
    -- [ADA 1:1 2026-08-15] Adas beide Scope-Waffen sind 1:1-Nachbauten von Leons Waffen und
    -- sollen sich exakt wie diese anfuehlen. Statt die Werte zu KOPIEREN (dann driften sie
    -- auseinander, sobald an Leon nachgestellt wird -- 6105 hatte z.B. schon eine Stuetzstelle
    -- weniger als 4401), greifen sie direkt auf den Slot der Vorlage zu. Was an Leon getunt
    -- wird, gilt damit sofort auch fuer Ada. RUECKBAU: `_G.__re4_ada_uses_leon_scope = false`.
    if rawget(_G, "__re4_ada_uses_leon_scope") ~= false then
        if     w == 6105 then w = 4401
        elseif w == 6114 then w = 4400 end
    end
    local ws = w and cfg.scope_sets[tostring(w)]
    if not ws then return nil end
    local state = rawget(_G, "__re4_scope_id") or "ironsight"
    return ws[state] or ws.ironsight
end
-- [BOLT-VERSATZ 2026-08-09 -- VERWORFEN, NICHT NOCHMAL PROBIEREN]
-- Nach dem Bolt-Zyklus springt `__re4_scope_aim_pitch` um +16..28 Grad (die Waffe steht
-- real verkippt, gemessen in data/re4_bolt_scope.log) und der Blick-Freeze traegt den
-- Versatz 1:1 in den rotation_offset -> Bild schief. Der Versuch, hier stattdessen den
-- KAMERA-Pitch zu nehmen, war falsch: das Scope sitzt AN DER WAFFE, der Blick MUSS ihrer
-- Zielrichtung folgen (s. Kommentar in drive_hmd_yaw) -- sonst schaut man am Okular vorbei
-- ("anders schief", im Spiel bestaetigt). Die Ursache ist die verkippte Waffe,
-- nicht die Blickquelle. Deshalb hier wieder unveraendert der Waffen-Pitch.

local function drive_hmd_yaw()
    -- [SCOPE_FREEZE] Beim Zielen durch ein montiertes Scope (ViaScope-Flag von re4_vr_weapons):
    -- HMD-Wobble neutralisieren (rotation_offset = conjugate(HMD)), ABER den Blick-Pitch der Waffen-
    -- Zielrichtung folgen lassen (Stick-Aim hoch/runter) -> Scope bleibt im Bild. Yaw bleibt eingefroren.
    -- Position: standing_origin = HMD-Position -> Kopf-Versatz = 0.
    if rawget(_G, "__re4_force_killswitch_scope") ~= true then scope_pitch_base = nil end
    if rawget(_G, "__re4_force_killswitch_scope") == true then
        local roff = nil
        local hq = safe(function() return vrmod:get_transform(0):to_quat() end)
        if hq then
            local off = hq:conjugate()
            -- [SCOPE_FREEZE] Blick folgt der ABSOLUTEN Waffen-Zielrichtung (kein Entry-Base mehr) ->
            -- egal ob die Waffe vorm Aimen hoch/runter gehalten wurde, das Scope-Bild sitzt gerade.
            -- gain = 1.0 = 1:1 (= Blick exakt auf Lauf-Pitch). conjugate(HMD) nivelliert, pq legt den Pitch drauf.
            local ap = tonumber(rawget(_G, "__re4_scope_aim_pitch"))
            if ap then
                local delta = ap * SCOPE_PITCH_SIGN * (cfg.scope_pitch_gain or 1.0)
                local h = math.rad(delta) * 0.5
                local pq = Quaternion.new(math.cos(h), math.sin(h), 0, 0)   -- Pitch um lokale X-Achse
                off = safe(function() return (pq * off):normalized() end) or off
            end
            roff = off
            pcall(function() vrmod:set_rotation_offset(off) end)
        end
        local hmd = safe(function() return vrmod:get_position(0) end)
        local so  = safe(function() return vrmod:get_standing_origin() end)
        if hmd and so then
            -- [SCOPE_EYE_X/Z] Augen-Versatz PRO WAFFE x ZUSTAND (iron sight + 3 Scopes) von weapons.lua.
            local sset  = active_scope_slot()
            _G.__re4_scope_eye = 0   -- NUR rechtes Auge (weapons.lua Mono-Auge synchron halten)
            local eye_x = (sset and sset.x_r) or 0.0
            local eye_z = (sset and sset.z_r) or 0.0
            -- BLICKRELATIV + kopf-yaw-stabil: praydog macht current_relative_pos = rotation_offset*(hmd-so).
            -- Wir pre-rotieren mit inv(rotation_offset) -> ergibt fix (eye_x,0,eye_z) im Kamera-Frame:
            -- X=rein seitlich, Z=rein Tiefe, UND unabhaengig von der Kopf-Rotation (Scope wandert nicht mehr).
            local pre = roff and safe(function() return roff:conjugate() * Vector3f.new(eye_x, 0.0, eye_z) end)
            if pre then
                so.x, so.y, so.z = hmd.x - pre.x, hmd.y - pre.y, hmd.z - pre.z
            else
                so.x, so.y, so.z = hmd.x - eye_x, hmd.y, hmd.z - eye_z
            end
            pcall(function() vrmod:set_standing_origin(so) end)
            -- [SCOPE_BULLET] Yaw-Korrektur (rad) fuer den Bullet-Hook publishen: NUR eye_x (Z fliesst NICHT ein!)
            -- [2026-08-11 GEMESSEN] Die Korrektur gilt NUR bei alternierendem Rendern. Dort
            -- traegt der Augen-Versatz oben in die EINE Spielkamera, an der die Scope-Kamera
            -- haengt -- die Kugel muss also gegengedreht werden. Im Multipass bleibt die
            -- Hauptkamera mittig (gemessen: Abstand Kugelachse zu Blickachse 0,001 m), der
            -- Term ueberdreht den Schuss dann um volle 13,8 Grad nach links.
            -- Darum an der RENDERTECHNIK haengen, nicht an der Waffe: der master meldet
            -- konstant false, der upscaler seinen echten Zustand.
            -- [2026-08-11, im Spiel erspielt] Gebraucht wird die Korrektur AUSSCHLIESSLICH
            -- im master unter OpenVR. Unter OpenXR trifft es dort ohne sie, und im
            -- Multipass ebenfalls (gemessen: Abstand Kugelachse zu Blickachse 0,001 m).
            -- Also: OpenXR oder Multipass -> aus, sonst der eingestellte Wert. Der Wert in
            -- der JSON bleibt dabei unangetastet, er wird nur nicht angewandt.
            -- [XR-EIGENWERT 2026-08-11] Aus dem frueheren harten "bei OpenXR aus" ist ein
            -- eigener Gain geworden: unter OpenXR trifft der master ohne Korrektur zwar
            -- besser als mit dem OpenVR-Wert, aber nicht exakt. Die drei Faelle:
            --   Multipass (upscaler)            -> 0, die Hauptkamera bleibt ohnehin mittig
            --   OpenXR ohne Multipass (master)  -> cfg.scope_yaw_xr (global, ein Regler)
            --   sonst (master + OpenVR)         -> unveraendert der Wert pro Waffe x Optik
            local mp, xr = false, false
            pcall(function()
                if vrmod.is_using_multipass and vrmod:is_using_multipass() then mp = true end
                if vrmod.is_openxr_loaded and vrmod:is_openxr_loaded() then xr = true end
            end)
            local gain
            if mp then gain = 0.0
            elseif xr then gain = cfg.scope_yaw_xr or 0.0
            else gain = (sset and sset.yaw) or 0.0 end
            _G.__re4_scope_bullet_yaw = eye_x * gain
            _G.__re4_scope_bullet_src = mp and "multipass" or (xr and "openxr" or "openvr")
        end
        hmd_yaw_prev = nil
        return
    end
    if not hmd_yaw_active() then
        -- Inaktiv (Cutscene/HMD aus/Toggle): Offset neutral, Baseline neu nehmen.
        -- AUSNAHME: haelt der Recenter gerade einen Event-Offset, NICHT auf 0 zwingen.
        hmd_yaw_prev = nil
        if not rawget(_G, "__vr_recenter_hold") then
            pcall(function() vrmod:set_rotation_offset(yaw_to_quat(0.0)) end)
        end
        return
    end
    if not hmd_yaw_pcc then return end
    local hmd = hmd_raw_yaw()
    if not hmd then return end
    if hmd_yaw_prev == nil then hmd_yaw_prev = hmd end
    local d = hmd_wrap(hmd - hmd_yaw_prev)
    hmd_yaw_prev = hmd
    -- HMD-Yaw-Delta in das Engine-Kamera-Yaw -> Engine dreht Body + Kamera.
    local yaw = safe(function() return hmd_yaw_pcc:get_field("_Yaw") end)
    local yaw_new = nil
    if yaw then
        yaw_new = hmd_wrap(yaw + d)
        pcall(function() hmd_yaw_pcc:set_field("_Yaw", yaw_new) end)
    end
    -- [ANTI-JITTER] Engine daempft das Kamera-Yaw -> Saegezahn. Output-Yaw direkt
    -- auf den ungedaempften Zielwert (_Yaw+pi, Body<->Kamera-Konvention), NUR Yaw.
    if yaw_new then
        local cam_rot = safe(function() return hmd_yaw_pcc:get_field("_CameraRotation") end)
        local cur = cam_rot and flat_yaw_of(cam_rot)
        if cur then
            local dyaw = hmd_wrap((yaw_new + math.pi) - cur)
            local new_cr = yaw_to_quat(dyaw) * cam_rot
            pcall(function() hmd_yaw_pcc:set_field("_CameraRotation", new_cr) end)
            local main = safe(function() return hmd_yaw_pcc:get_field("_MainCameraController") end)
            if main then pcall(function() main:set_field("_CameraRotation", new_cr) end) end
        end
    end
    -- Headset im Bild ausgleichen (sonst Doppel-HMD).
    pcall(function() vrmod:set_rotation_offset(yaw_to_quat(-hmd)) end)
end
if player_cam_td then
    local m = player_cam_td:get_method("updateCameraPosition")
    if m then
        sdk.hook(m,
            function(args) hmd_yaw_pcc = sdk.to_managed_object(args[2]) end,
            function(retval) pcall(drive_hmd_yaw); return retval end)
    else
    end
end

-- ---- Hooks ----
-- LockScene (pre): HMD-Follow + frischen Kamera-Yaw lesen + owned_yaw
-- avancieren + schreiben. UpdateMotion/LateUpdateBehavior/BeginRendering
-- (pre+post): ERZWINGEN — Engine-Drehversuche zwischen den Phasen voll
-- revertieren (Phasen-Order, analog 5-Phasen-Stack der Joint-Overrides).
re.on_pre_application_entry("LockScene", function()
    apply_auto_center()
    roomscale_recenter_events()
    roomscale_crouch()
    apply_hmd_body_follow()
    apply_hard_yaw(true)
    apply_ub_lock(true)   -- einziger Capture-Slot (stabil, nach Yaw-Write)
    update_stop_skip()
    update_anim_export()
    apply_spine_pin(true)   -- Capture-Slot (frischer Anim-Export) + Enforce
    apply_crouch_pin()
end)
-- [ROOMSCALE 2026-08-11] Die in LockScene gesammelte Strecke hier schreiben -- dieselbe
-- Phase, in der auch das Yaw gegen die Engine durchgesetzt wird. In LockScene-pre war der
-- Write nachweislich verloren (0,001 m von 0,5 m). Wird nichts gesammelt, passiert nichts.
local function roomscale_flush_body()
    if not cfg.roomscale then rs_pending.x, rs_pending.z = 0.0, 0.0; return end
    if rs_pending.x == 0.0 and rs_pending.z == 0.0 then return end

    local tf = get_body_transform()
    if not tf then rs_pending.x, rs_pending.z = 0.0, 0.0; return end
    local pos = safe(function() return tf:call("get_Position") end)
    if not pos then rs_pending.x, rs_pending.z = 0.0, 0.0; return end

    pcall(function()
        tf:call("set_Position", Vector3f.new(pos.x + rs_pending.x, pos.y, pos.z + rs_pending.z))
    end)
    rs_pending.x, rs_pending.z = 0.0, 0.0
end

re.on_application_entry("LateUpdateBehavior", function()
    roomscale_flush_body()
    enforce_hard_yaw()
    -- Spine/Neck-Yaw NUR hier: einmal pro Frame, direkt nach dem Anim-Update.
    -- (Basis ist frisch von der Engine -> additiver Offset akkumuliert nicht.
    -- In LockScene-pre wäre die Basis die eigene Schreibung der Vorframe -> Dauerdrehung.)
    -- UNABHAENGIG von cfg.enabled (Hard-Yaw-Master) — eigener Feature-Schalter
    -- ist der Slider selbst (0 = aus). Frueher hing er mit am Master: Slider
    -- wirkte "tot", wenn Hard Body-Yaw aus war.
    if not is_ks_active() then
        apply_ub_lock()
        local tf = get_body_transform()
        if tf then apply_spine_yaw(tf) end
    end
    -- [SPINE_PIN] LateUpdateBehavior ist PFLICHT-Slot (Memo Joint-Override
    -- 5-Hook-Stack) — ohne ihn ueberschreibt die Engine die Pins jeden Frame.
    apply_spine_pin()
    apply_crouch_pin(true)    -- post-anim: native Hock-Pose capturen (nur Button)
    apply_crouch_ub_z(true)   -- post-anim: native UB-Basis capturen + Offset
end)
re.on_application_entry("BeginRendering", function()
    enforce_hard_yaw()
    apply_ub_lock()
    apply_spine_pin()
    apply_crouch_pin()
    apply_crouch_ub_z(false)
end)
-- [SCOPE_FREEZE_LATE] Kopfbewegung leckt durch den Freeze: rotation_offset wird in updateCameraPosition
-- (Frame-Mitte) gesetzt, praydog rendert spaeter mit FRISCHEREM HMD -> Rest-Kopfdrehung bleibt, vom
-- Zoom vergroessert (= "schlimmer bei Kopfbewegung"). Hier im spaetesten Pass mit dem frischesten HMD
-- nochmal setzen -> Leck-Fenster so klein wie moeglich. Closure (kein top-level local).
-- [POSE_FREEZE 2026-08-11] Den Freeze zusaetzlich IM FORK setzen. Das Nachschreiben aus
-- Lua erreicht nur zwei Punkte pro Frame; danach holt der Renderer die HMD-Pose erneut
-- (im Multipass je Pass) und der Compositor reprojiziert das fertige Bild noch einmal
-- gegen die frische Kopfhaltung -- deshalb wabbelte selbst der Scope-RAND. Mit dem Flag
-- liefert der Fork ueberall dieselbe eingefrorene Rotation. Alte Builds ohne die Funktion
-- laufen unveraendert weiter (Existenzpruefung).
local pose_freeze_now = false
local pose_submit_now = nil
local function apply_pose_freeze(on)
    if vrmod == nil or vrmod.set_pose_freeze == nil then return end

    -- [SUBMIT-MODUS] Live umschaltbar (Regler unten), damit die Richtung im Spiel
    -- entschieden werden kann: 0 = wie frueher, 1 = eingefrorene Pose an den Compositor
    -- (dreht die Differenz nach), 2 = frische Pose (dreht nichts nach).
    local want_mode = math.floor(cfg.scope_submit_mode or 2)
    if want_mode ~= pose_submit_now and vrmod.set_pose_freeze_submit ~= nil then
        if pcall(function() vrmod:set_pose_freeze_submit(want_mode) end) then
            pose_submit_now = want_mode
        end
    end

    if on == pose_freeze_now then return end
    if pcall(function() vrmod:set_pose_freeze(on) end) then pose_freeze_now = on end
end

re.on_application_entry("BeginRendering", function()
    if rawget(_G, "__re4_force_killswitch_scope") ~= true then
        apply_pose_freeze(false)
        return
    end
    apply_pose_freeze(true)
    local hq = safe(function() return vrmod:get_transform(0):to_quat() end)
    if not hq then return end
    local off = hq:conjugate()
    local ap = tonumber(rawget(_G, "__re4_scope_aim_pitch"))
    if ap then
        local h = math.rad(ap * SCOPE_PITCH_SIGN * (cfg.scope_pitch_gain or 1.0)) * 0.5
        off = safe(function() return (Quaternion.new(math.cos(h), math.sin(h), 0, 0) * off):normalized() end) or off
    end
    pcall(function() vrmod:set_rotation_offset(off) end)
    local hmd = safe(function() return vrmod:get_position(0) end)
    local so  = safe(function() return vrmod:get_standing_origin() end)
    if hmd and so then
        local sset  = active_scope_slot()
        local eye_x = (sset and sset.x_r) or 0.0
        local eye_z = (sset and sset.z_r) or 0.0
        local pre = safe(function() return off:conjugate() * Vector3f.new(eye_x, 0.0, eye_z) end)
        if pre then so.x, so.y, so.z = hmd.x - pre.x, hmd.y - pre.y, hmd.z - pre.z
        else       so.x, so.y, so.z = hmd.x - eye_x, hmd.y, hmd.z - eye_z end
        pcall(function() vrmod:set_standing_origin(so) end)
    end
end)
-- UB-Lock braucht den vollen Phasen-Stack (Engine-Anim schreibt ZWISCHEN den
-- Phasen): UpdateMotion + UpdateJointExpression + pre-BeginRendering dazu.
-- Body-Yaw-Enforcement laeuft in denselben Slots mit.
-- =====================================================================
-- [STEPFALL_GRAV 2026-07-22] Gravitation des GroundAdsorbers waehrend der Bewegung anheben.
-- Uebernommen aus dem Wegwerf-Script re4_zzz_stepfall.lua (dort erspielt: ab ~150 ist der
-- Rueckwaerts-Treppab-Stepfall weg). Details siehe cfg.grav_fix oben.
-- Originalwert wird EINMAL gesichert, bevor wir schreiben (nie live nachmessen, wenn schon
-- ueberschrieben) und beim Nicht-Bewegen / Ausschalten / Reset zurueckgestellt.
-- =====================================================================
local grav_orig = nil
local grav_active = false

-- [PURE_GAMEPLAY_GATE 2026-07-22, "im Menue kann ich die Kamera bewegen, wenn diese
-- Settings an sind"] Gravitations-Fix UND Anlauf/Bremse duerfen AUSSCHLIESSLICH im reinen
-- Gameplay laufen. is_ks_active allein reicht nicht: das Menue ist KEIN Killswitch, dort
-- schlaegt aber der Navigations-Stick aus -> unsere Stick-Flanke schob die Position.
-- Drei Quellen, alle noetig:
-- killswitch.is_pure_gameplay -> kein KS, kein Pin-Release, kein Cutscene-CamState
-- share.PauseManager.isPaused -> faengt auch "Pause waehrend Cutscene" (dort ist keine GUI-Flag gesetzt)
-- GuiManager.hasOccupiedPauseMenuSystemLock -> Inventar/Karte/Typewriter u.ae.
local pg_cache = { pause = nil, gui = nil }
-- [PUBLIC-UI 2026-08-11] Der Roomscale-Haken soll zusaetzlich im nackten Public-Bereich
-- (re4_vr_binding.lua) stehen. Beide Haken muessen denselben Wert zeigen und beide muessen
-- speichern -- deshalb hier zwei kleine Funktionen statt einer kopierten Variable.
_G.__re4_roomscale_get = function() return cfg.roomscale == true end
_G.__re4_roomscale_set = function(v)
    cfg.roomscale = v and true or false
    save_cfg()
end

-- (oben forward-deklariert -- deshalb hier ohne `local`, sonst waeren es zwei Variablen)
-- Zweiter Rueckgabewert = Grund (nur fuer die Diagnose; alle Aufrufer werten nur den
-- ersten Wert aus, an deren Verhalten aendert sich nichts).
function pure_gameplay_only()
    if is_ks_active() then return false, "killswitch" end
    if rawget(_G, "__re4_ks_active") == true then return false, "ks_global" end
    if type(killswitch.is_pure_gameplay) == "function" then
        local ok, v = pcall(killswitch.is_pure_gameplay)
        if not (ok and v == true) then
            return false, "killswitch.is_pure_gameplay=" .. tostring(ok and v or "call fehlgeschlagen")
        end
    end
    if not pg_cache.pause then pg_cache.pause = sdk.get_managed_singleton("share.PauseManager") end
    if pg_cache.pause then
        local ok, paused = pcall(function() return pg_cache.pause:call("isPaused()") end)
        if ok and paused == true then return false, "PauseManager.isPaused" end
    end
    if not pg_cache.gui then pg_cache.gui = sdk.get_managed_singleton("chainsaw.GuiManager") end
    if pg_cache.gui then
        local ok, lock = pcall(function() return pg_cache.gui:call("get_hasOccupiedPauseMenuSystemLock") end)
        if ok and lock == true then return false, "GuiManager.PauseMenuSystemLock" end
    end
    return true
end

local function ground_adsorber()
    if not character_manager then
        character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    local c = character_manager and safe(function() return character_manager:call("getPlayerContextRef") end)
    local bu = c and safe(function() return c:call("get_BodyUpdater") end)
    return bu and safe(function() return bu:call("get_GroundAdsorber") end), c
end

local function apply_grav_fix()
    local ga, c = ground_adsorber()
    if not (ga and c) then return end

    local cur = safe(function() return ga:get_field("_GravitationalAcceleration") end)
    if grav_orig == nil and type(cur) == "number" and cur > 0 and cur < 100 then grav_orig = cur end
    if grav_orig == nil then return end

    grav_active = false
    -- NUR im reinen Gameplay (kein KS, kein Menue, keine Pause, keine Cutscene) -- ueberall sonst
    -- faehrt das Spiel den Koerper selbst. Der Zweig unten stellt den Originalwert wieder her.
    -- [AUFZUG] Ausnahmen kommen spaeter gezielt pro Aufzug -- hier bewusst KEIN pauschales Flag.
    if cfg.grav_fix and pure_gameplay_only() then
        local moving = (safe(function() return c:call("get_IsRun") end) == true)
            or (safe(function() return c:call("get_IsWalk") end) == true)
            or (tonumber(safe(function() return c:call("get_MoveIntensity") end)) or 0) > 0.1
        -- Leiter und bewusster Sprung ausgenommen: dort soll die normale Gravitation gelten.
        if moving and safe(function() return c:call("get_IsLadder") end) ~= true
                  and safe(function() return c:call("get_IsJumping") end) ~= true then
            grav_active = true
            pcall(function() ga:set_field("_GravitationalAcceleration", cfg.grav_value) end)
            return
        end
    end
    if type(cur) == "number" and math.abs(cur - grav_orig) > 0.01 then
        pcall(function() ga:set_field("_GravitationalAcceleration", grav_orig) end)
    end
end

re.on_frame(apply_grav_fix)

-- =====================================================================
-- [LAGMOVE 2026-07-22] Anlauf-Boost + Nachlauf-Bremse (aus re4_zzz_stepfall.lua Teil 2).
-- BOOST: fuellt beim Losgehen die Luecke zwischen Ist- und Zielgeschwindigkeit auf und endet
-- von selbst, sobald das Spiel schnell genug ist (Zuschuss wird dann 0) -- kein Uebertempo.
-- BREMSE: skaliert nach dem Loslassen das native Frame-Delta (0 = sofort stehen).
-- Beides schiebt die Body-Position direkt -> Kollision wird umgangen, darum klein halten und
-- an Waenden/Kanten im Auge behalten. Gates: kein Killswitch, keine Leiter, kein Sprung, am Boden.
-- Laeuft im UpdateMotion-Hook NACH firstperson.apply_movement_stabilization (movement.lua laedt
-- alphabetisch spaeter als firstperson.lua -> unser Callback ist der zweite).
-- =====================================================================
local lagm = {
    pad_td = sdk.find_type_definition("via.hid.GamePad"),
    last_pos = nil, last_t = nil, spd = 0.0,
    pad_was = 0.0, edge_t = nil, edge_kind = nil,
    boost_now = 0.0, brake_now = false,
}

local function lag_pad_axis()
    local gp = sdk.get_native_singleton("via.hid.GamePad")
    if not gp or not lagm.pad_td then return 0.0 end
    local pad = safe(function() return sdk.call_native_func(gp, lagm.pad_td, "get_LastInputDevice") end)
    if not pad then return 0.0 end
    local a = pad and safe(function() return pad:call("get_AxisL") end)
    return a and math.sqrt((a.x or 0)^2 + (a.y or 0)^2) or 0.0
end

local function apply_lag_fix()
    if not (cfg.lag_boost_on or cfg.lag_brake_on) then return end
    -- Ausserhalb des reinen Gameplays KOMPLETT still -- inklusive Zustand zuruecksetzen, damit
    -- beim Wiedereinstieg keine alte Stick-Flanke aus dem Menue nachwirkt.
    if not pure_gameplay_only() then
        lagm.last_pos, lagm.last_t = nil, nil
        lagm.edge_t, lagm.edge_kind, lagm.pad_was = nil, nil, 0.0
        lagm.boost_now, lagm.brake_now = 0.0, false
        return
    end
    local ga, c = ground_adsorber()
    if not c then return end
    local go = safe(function() return c:call("get_BodyGameObject") end)
    local btf = go and safe(function() return go:call("get_Transform") end)
    if not btf then return end
    local cur = safe(function() return btf:call("get_Position") end)
    if not cur then return end

    local now = os.clock()
    local dt = lagm.last_t and math.min(math.max(now - lagm.last_t, 0.001), 0.1) or 0.016
    lagm.last_t = now

    -- native Geschwindigkeit (XZ) aus dem Frame-Delta
    local dx, dz = 0.0, 0.0
    if lagm.last_pos then dx, dz = cur.x - lagm.last_pos.x, cur.z - lagm.last_pos.z end
    local step = math.sqrt(dx * dx + dz * dz)
    lagm.spd = step / dt

    -- Stick-Flanken (das ist der Wille des Spielers, nicht der Zustand der Figur)
    local pad = lag_pad_axis()
    if pad >= 0.5 and lagm.pad_was < 0.5 then
        lagm.edge_t, lagm.edge_kind = now, "START"
    elseif pad < 0.15 and lagm.pad_was >= 0.15 then
        lagm.edge_t, lagm.edge_kind = now, "STOP"
    end
    lagm.pad_was = pad

    -- KS/Menue/Pause haengen schon am pure_gameplay_only-Gate oben; hier bleiben nur noch
    -- die Gameplay-internen Ausnahmen.
    local blocked = (safe(function() return c:call("get_IsLadder") end) == true)
        or (safe(function() return c:call("get_IsJumping") end) == true)
    if ga and safe(function() return ga:call("get_Ground") end) ~= true then blocked = true end

    lagm.boost_now, lagm.brake_now = 0.0, false
    if not blocked and lagm.edge_t then
        local since = now - lagm.edge_t
        if cfg.lag_boost_on and lagm.edge_kind == "START" and pad >= 0.5
            and since <= cfg.lag_boost_window then
            local add = math.min(math.max(cfg.lag_boost_target - lagm.spd, 0.0), cfg.lag_boost_max)
            if add > 0.001 then
                local md = safe(function() return c:call("get_MoveDirection") end)
                local ml = md and math.sqrt((md.x or 0)^2 + (md.z or 0)^2) or 0
                if ml > 1e-4 then
                    local k = (add * dt) / ml
                    pcall(function() btf:call("set_Position",
                        Vector3f.new(cur.x + md.x * k, cur.y, cur.z + md.z * k)) end)
                    lagm.boost_now = add
                end
            end
        elseif cfg.lag_brake_on and lagm.edge_kind == "STOP" and pad < 0.15
            and since <= cfg.lag_brake_window and lagm.last_pos and step > 0.0001 then
            local g = math.min(math.max(cfg.lag_brake_gain, 0.0), 1.0)
            pcall(function() btf:call("set_Position",
                Vector3f.new(lagm.last_pos.x + dx * g, cur.y, lagm.last_pos.z + dz * g)) end)
            lagm.brake_now = true
        end
    end

    lagm.last_pos = safe(function() return btf:call("get_Position") end) or cur
end

re.on_application_entry("UpdateMotion", function()
    enforce_hard_yaw()
    apply_ub_lock()
    apply_spine_pin()
    apply_crouch_pin()
    apply_lag_fix()          -- [LAGMOVE] nach firstperson.apply_movement_stabilization
end)
re.on_application_entry("UpdateJointExpression", function()
    apply_ub_lock()
    apply_spine_pin()
    apply_crouch_pin()
    apply_crouch_ub_z(false)
end)
re.on_pre_application_entry("BeginRendering", function()
    enforce_hard_yaw()
    apply_ub_lock()
    apply_spine_pin()
    apply_crouch_pin()
    apply_crouch_ub_z(false)
end)

-- ---- UI ----
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Movement" raus (283 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

re.on_script_reset(function()
    -- [STEPFALL_GRAV] Gravitation zurueck auf den Spielwert, sonst bleibt sie ueberschrieben
    if grav_orig ~= nil then
        local ga = ground_adsorber()
        if ga then pcall(function() ga:set_field("_GravitationalAcceleration", grav_orig) end) end
    end
    -- FSM-Patches ueberleben Reset Scripts -> sauber zuruecksetzen
    if stop_skip_state.applied then
        pcall(function() apply_stop_skip(false) end)
    end
    if start_skip_state.applied then
        pcall(function() apply_start_skip(false) end)
    end
    if no_pivot_state.applied then
        pcall(function() apply_no_pivot(false) end)
    end
    character_manager = nil
    camera_system = nil
    last_yaw_quat = nil
    body_yaw_last_t = nil
    owned_yaw = nil
    hmd_yaw_pcc = nil          -- [HMD_YAW_DRIVE]
    hmd_yaw_prev = nil
    hip_state.joint = nil
    hip_state.ref_offset = nil
    spine_joint_cache = {}
    spine_last_written = {}
    ub_lock_pose = nil
    ub_lock_rel = nil
    ub_lock_base = nil
    spinepin.tf = nil
    spinepin.joints = nil
    spinepin.rel = nil
    spinepin.names = nil
    spinepin.par_inv = nil
    spinepin.null_off = nil
    spinepin.null_rel = nil
    crouch_ubz.base = nil
    -- crouchpin.rel/par_inv/null_rel NICHT nilen: Skelett-generisch, greift nach
    -- Reset sofort wieder (cfg_tried bleibt -> kein erneutes Platte-Laden noetig).
    crouchpin.capture_req = false
    _G.__vr_surge_bridged = false
    auto_center.ctx = nil
    bw_motion = nil
end)

-- =====================================================================
-- [SQUEEZE_ANTIBEAM 2026-07-21] 1:1 uebernommen aus re4_vr_squeeze_antibeam.lua (konsolidiert).
-- Logik UNVERAENDERT, nur alle Namen mit sqab_ praefixiert (Kollision mit movement-Locals ausgeschlossen)
-- und ein eigenes sqab_safe (movements safe verschluckt false -> hier bewusst das Original behalten).
--
-- Belegt: der Durchquetsch-Squeeze "jackt" den Spieler (MotionJackFsm2, Node "Jacked.None"). Beim Bug feuert
-- 0.08s nach Session-Ende ein ZWEITER Jack am selben Ort -> Beam+Anim-Replay (echte Nachbarspalten: 7-10s Abstand).
-- Fix: den Jack-Setup des ZWEITEN Jacks blocken. setupJackLayer richtet den Jack-Layer ein -> Aufruf
-- <RETRIG_WINDOW nach einem Squeeze-Ende UND nahe dessen Ausgang = Fehl-Trigger -> SKIP_ORIGINAL.
-- Der Pin (Body auf Ausgang) bleibt als Sicherheitsnetz.
-- [LOG AUS 2026-08-18] Der Diagnose-Log (Ring -> re4_vr/re4_antibeam.json) ist stillgelegt:
-- sqab_dlog ist ein leerer Rumpf, alle Aufrufstellen bleiben unveraendert stehen.
-- =====================================================================
local function sqab_safe(fn) local ok, r = pcall(fn); if ok then return r end end
local SQAB_RETRIG_WINDOW = 1.5   -- s: Jack so kurz nach Squeeze-Ende = Fehl-Trigger
local SQAB_SAME_SPOT     = 3.5   -- m: am selben Ausgang = dieselbe Spalte

local sqab_gm_td = sdk.find_type_definition("chainsaw.GimmickMotionCameraController")

local function sqab_dlog(_s) end

local function sqab_body_tf()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = sqab_safe(function() return cm:call("getPlayerContextRef") end); if not ctx then return nil end
    local body = ctx and sqab_safe(function() return ctx:call("get_BodyGameObject") end); if not body then return nil end
    return sqab_safe(function() return body:call("get_Transform") end)
end

local function sqab_in_gimmick()
    local cs = sdk.get_managed_singleton("chainsaw.CameraSystem")
    local main = cs and sqab_safe(function() return cs:call("get_MainCameraController") end)
    local busy = main and sqab_safe(function() return main:call("get_BusyCameraController") end)
    if not (busy and sqab_gm_td) then return false end
    return sqab_safe(function() return busy:get_type_definition():is_a(sqab_gm_td) end) == true
end

local function sqab_dist(a, b)
    if not (a and b) then return 1e9 end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- === Session-Tracking + Pin-Netz (on_frame-Pass) ===
local sqab_active   = false
local sqab_last     = nil        -- letzte Body-Pos der laufenden Session
_G.__re4_sq_end_t = _G.__re4_sq_end_t or -999
_G.__re4_sq_exit  = _G.__re4_sq_exit or nil
local sqab_pin      = false
local sqab_pin_pos  = nil

local function sqab_tick()
    local now = os.clock()
    local a = sqab_in_gimmick()
    local tf = sqab_body_tf(); if not tf then return end
    local p = sqab_safe(function() return tf:call("get_Position") end); if not p then return end
    local pp = { x = p.x, y = p.y, z = p.z, w = (type(p) == "userdata" and p.w) or 1.0 }

    if a and not sqab_active then
        sqab_active = true; sqab_pin = false
        local dt = now - _G.__re4_sq_end_t
        local d_ex = sqab_dist(pp, _G.__re4_sq_exit)
        if dt < SQAB_RETRIG_WINDOW and _G.__re4_sq_exit and d_ex < SQAB_SAME_SPOT then
            sqab_pin = true; sqab_pin_pos = _G.__re4_sq_exit
            sqab_dlog(string.format("RE-TRIGGER (dt=%.2fs d_ausgang=%.1f) -> PIN+Block aktiv", dt, d_ex))
        else
            sqab_dlog(string.format("SQUEEZE START (dt=%.2fs d_ausgang=%.1f)", dt, d_ex))
        end
        sqab_last = pp
    end

    if a then
        if sqab_pin and sqab_pin_pos then
            local ok = pcall(function() tf:call("set_Position", Vector4f.new(sqab_pin_pos.x, sqab_pin_pos.y, sqab_pin_pos.z, pp.w)) end)
            if not ok then pcall(function() tf:call("set_Position", Vector3f.new(sqab_pin_pos.x, sqab_pin_pos.y, sqab_pin_pos.z)) end) end
        else
            sqab_last = pp
        end
        return
    end

    if sqab_active and not a then
        sqab_active = false
        _G.__re4_sq_exit  = sqab_pin and sqab_pin_pos or sqab_last
        _G.__re4_sq_end_t = now
        sqab_dlog(string.format("aus (ausgang=%.1f/%.1f/%.1f)", _G.__re4_sq_exit.x, _G.__re4_sq_exit.y, _G.__re4_sq_exit.z))
        sqab_pin = false
    end
end

pcall(function() re.on_application_entry("BeginRendering", sqab_tick) end)

-- === Jack-Block (Hook, einmalig) ===
-- [CRASHFIX 2026-08-01] Der Block sass bis heute auf `MotionJackSuppliedHolder.setupJackLayer`
-- und hat das Spiel beim Verlassen der ERSTEN Spalte zerlegt. Aus dem Dump (12:40:01) belegt:
-- * Crash = c0000005 an re4+0x400c150, Instruktion `mov dword ptr [rcx+374h],edx` mit rcx=0,
-- Aufrufer laut Callstack `chainsaw.GmInterstice1Motion.startJackPl`.
-- * `re4_antibeam.json` derselben Sekunde: "aus (ausgang=...)" -> 0.37s spaeter 2x
-- ">> setupJackLayer GEBLOCKT" -> Crash. Der Block war also der letzte Schritt vor dem AV.
-- * Der Grund steht in der TDB: **setupJackLayer gibt System.Int32 zurueck** (den JackLayerIndex).
-- SKIP_ORIGINAL mit Post-Hook `return ret` liefert dem Aufrufer damit einen UNDEFINIERTEN Index;
-- startJackPl holt sich darueber den Layer (calcLayer -> Nullable<CharacterMotionJackLayer>),
-- bekommt null und schreibt hinein. NIE eine Funktion mit Rueckgabewert blind skippen.
-- ERSTER VERSUCH (verworfen): eine Ebene hoeher blocken, `GmInterstice1Motion.startJackPl` (System.Void).
-- Kein Beam, kein Crash -- ABER: **der Spieler blieb nach der Spalte fuer immer in KS4.** Live gemessen
-- (Live-Abfrage, 2026-08-01, waehrend der Zustand hing): `PlayerBaseContext.get_OccupiedInfo:get_Priority`
-- stand dauerhaft auf `CH_JACKED_GMK_HIGH (23)`. Der Grund ist zwingend: der OccupiedMediator hatte die
-- Reservierung bereits AKZEPTIERT (deshalb lief startJackPl ja an); aufgeloest wird die Belegung erst vom
-- ENDE des Jacks -- und der startete nie. `is_gimmick_ks3_spot` (killswitch.lua, Zweig (b)) liest genau
-- diese Prio und haelt KS4 damit unbegrenzt; die 0.3s Exit-Grace laufen ins Leere, weil die Bedingung
-- dauerhaft wahr bleibt. Der Block dazu steht stillgelegt am Ende dieses Blocks.
--
-- AKTUELLER WEG: wieder auf `setupJackLayer` -- aber mit **definiertem Rueckgabewert**. Damit laeuft
-- startJackPl durch (Occupancy wird normal auf- und wieder abgebaut, KS4 endet wie frueher), nur der
-- Jack-Layer wird nicht neu eingerichtet -> der Beam bleibt weg. Zurueckgegeben wird `get_JackLayerIndex`
-- des Holders selbst (Backing-Field 0x50), also der Index, den die Funktion ohnehin verwaltet -- kein
-- geratener Wert. **Laesst der sich nicht lesen, wird NICHT geblockt** (CALL_ORIGINAL): lieber ein Beam
-- als ein zweiter Nullzeiger.
-- Zeit-/Distanz-Gate unveraendert (RETRIG_WINDOW / SAME_SPOT), der Pin bleibt Sicherheitsnetz.
-- Der Global-Guard bleibt: laeuft die alte Datei versehentlich noch mit, wird NICHT doppelt gehookt.
if not rawget(_G, "__re4_jackblock_hooked") then
    _G.__re4_jackblock_hooked = true

    -- Gate 1:1 aus dem alten setupJackLayer-Hook uebernommen, nur als eigene Funktion.
    local function sqab_is_retrigger(tag)
        local dt = os.clock() - (rawget(_G, "__re4_sq_end_t") or -999)
        if dt >= SQAB_RETRIG_WINDOW then return false end
        local ex = rawget(_G, "__re4_sq_exit")
        local tf = sqab_body_tf()
        local p  = tf and sqab_safe(function() return tf:call("get_Position") end)
        local d  = (p and ex) and sqab_dist({ x = p.x, y = p.y, z = p.z }, ex) or 1e9
        if ex and d < SQAB_SAME_SPOT then
            sqab_dlog(string.format(">> %s GEBLOCKT (dt=%.2fs d=%.1f)", tag, dt, d))
            return true
        end
        sqab_dlog(string.format(">> %s durch (dt=%.2fs d=%.1f) -- nicht nah genug", tag, dt, d))
        return false
    end

    local sqab_jh = sdk.find_type_definition("chainsaw.MotionJackSuppliedHolder")
    local sqab_m_setup = sqab_jh and sqab_jh:get_method("setupJackLayer")
    if sqab_m_setup then
        -- Rueckgabewert-Uebergabe PRE -> POST. Kein Verschachteln moeglich: der Hook laeuft im selben
        -- Thread und POST folgt unmittelbar auf PRE.
        local sqab_skip_ret = nil
        sdk.hook(sqab_m_setup,
            function(args)
                sqab_skip_ret = nil
                if not sqab_is_retrigger("setupJackLayer") then
                    return sdk.PreHookResult.CALL_ORIGINAL
                end
                -- args[1] = vm-Context, args[2] = this (der Holder), args[3] = LayerType
                local holder = sqab_safe(function() return sdk.to_managed_object(args[2]) end)
                local idx    = holder and sqab_safe(function() return holder:call("get_JackLayerIndex") end)
                if type(idx) ~= "number" then
                    -- Ohne gueltigen Index NICHT skippen -- sonst wieder undefinierter Rueckgabewert.
                    sqab_dlog("   !! JackLayerIndex nicht lesbar -> DURCHGELASSEN (Beam moeglich, aber kein Crash)")
                    return sdk.PreHookResult.CALL_ORIGINAL
                end
                sqab_skip_ret = idx
                sqab_dlog(string.format("   -> Rueckgabe JackLayerIndex=%d statt Muell", idx))
                return sdk.PreHookResult.SKIP_ORIGINAL
            end,
            function(retval)
                if sqab_skip_ret ~= nil then
                    local v = sqab_skip_ret
                    sqab_skip_ret = nil
                    return sdk.to_ptr(v)
                end
                return retval
            end)
        sqab_dlog("Jack-Hook gesetzt (setupJackLayer, mit Rueckgabewert)")
    else
        sqab_dlog("setupJackLayer NICHT gefunden")
    end

    -- [STILLGELEGT 2026-08-01] Der startJackPl-Weg. Verhindert den Beam ebenfalls und crasht nicht,
    -- laesst aber die Occupancy stehen -> KS4 klebt (oben belegt). Nur zurueckholen, wenn zusaetzlich
    -- die Belegung selbst aufgeloest wird (Ansatzpunkte: `GmOMUnitBase.checkForEndJack` /
    -- `endJackThenReject`). `GmInterstice` hat kein startJackPl, `GmOMUnitBase` auch nicht -- es gibt
    -- also KEINEN gemeinsamen Basis-Hookpunkt, jede Jack-Klasse braucht ihren eigenen.
    --[==[
    local function sqab_hook_startjack(tname)
        local td = sdk.find_type_definition(tname)
        local m  = td and td:get_method("startJackPl")
        if not m then
            sqab_dlog(tname .. ".startJackPl NICHT gefunden")
            return
        end
        sdk.hook(m,
            function(args)
                if sqab_is_retrigger(tname .. ".startJackPl") then
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(ret) return ret end)
        sqab_dlog(tname .. ".startJackPl gehookt")
    end
    sqab_hook_startjack("chainsaw.GmInterstice1Motion")   -- deckt via Vererbung GmIntersticeAndDeadBody mit
    sqab_hook_startjack("chainsaw.GmIntersticeWithEm")    -- Spalte mit Gegner drin, eigene Klasse
    ]==]
end

