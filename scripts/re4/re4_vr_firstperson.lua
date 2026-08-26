-- PORTED TO C++: src/mods/vr/games/re4/RE4VRFirstPerson.cpp (kept as reference)
return

-- ============================================================
-- RE4 VR FirstPerson (v6 — minimal)
-- Kamera = Head-Joint + Offset-Slider (Body-relativ).
-- NUR Position setzen — HMD-Rotation macht REFramework selbst.
-- Killswitch-aware (Cutscenes: Kamera nicht anfassen).
-- Movement follows HMD: Stick-Bewegung folgt der Blickrichtung
-- (1:1 aus dem alten Script portiert, ohne EMA).
-- Recoil lebt jetzt in re4_vr_recoil.lua.
-- ============================================================

if reframework:get_game_name() ~= "re4" then return end

local ok_ks, killswitch = pcall(function() return require("re4vr/re4_vr_killswitch") end)
if not ok_ks or not killswitch then
    killswitch = { is_active = function() return false end }
end

local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end

-- ---- Config (persistiert) ----
local CFG_PATH = "re4_vr/re4_vr_firstperson.json"
local cfg = {
    off_x = 0.0,                  -- rechts (m), Body-relativ
    off_y = 0.0,                  -- hoch (m), relativ zum Root-Joint (Augenhoehe!)
    off_z = 0.0,                  -- vor (m), Body-relativ
    event_off_x = 0.0,            -- [STONE-RIDDLE] eigener HMD-Offset in WELT-Koordinaten NUR fuer das
    event_off_y = 0.0,            -- GimmickFix-Kamera-Event (Stage 51503 an fixer Position). Verschiebt die
    event_off_z = 0.0,            -- primary camera direkt (binocular-Technik, world-space). 0/0/0 = no-op.
    event2_off_x = 0.0,           -- [POWER-RIDDLE] Zweites GimmickFix-Kamera-Event, exakt dieselbe Technik +
    event2_off_y = 0.0,           -- dieselben drei Gates wie Stone-Riddle, nur andere Stage/Position
    event2_off_z = 0.0,           -- (61400 @ 115.55/18.50/-93.56, Monitor-Dump 2026-07-15 22:43). 0/0/0 = no-op.
                                  -- Key-Name bleibt bewusst event2_* (Umbenennen wuerde gespeicherte Werte verwerfen).
    event3_off_x = 0.0,           -- [POWER-RIDDLE2] Drittes GimmickFix-Kamera-Event, gleiche Technik + Gates
    event3_off_y = 0.0,           -- (61305 @ 90.83/18.50/-91.04, Monitor-Dump 2026-07-15 23:05). 0/0/0 = no-op.
    event3_off_z = 0.0,           -- Andere Stage als Power-Riddle 1 (61400) -> die Gates koennen nicht kollidieren.
    event4_off_x = 0.0,           -- [DUMPSTER-RIDDLE] Viertes GimmickFix-Kamera-Event, gleiche Technik + Gates
    event4_off_y = 0.0,           -- (63108 @ -13.89/21.77/-122.40, Monitor-Dump 2026-07-16 00:30). 0/0/0 = no-op.
    event4_off_z = 0.0,           -- Wieder eigene Stage -> keine Kollision mit 51503/51502, 61400, 61305.
    event5_mono = true,           -- [SYMBOL-RIDDLE MONO 2026-08-15] Waehrend GENAU dieses Events Mono-Rendering
                                  -- (beide Augen dasselbe Bild), wie beim Scope. Angemeldet wird es ueber den
                                  -- Broker `__re4_mono_request` in re4_vr_scope.lua -- NIE direkt
                                  -- `set_mono_rendering` rufen, sonst nehmen zwei Stellen sich gegenseitig den
                                  -- Zustand weg. Schaltet sich beim Verlassen des Gates selbst wieder ab.
    event5_off_x = 0.0,           -- [SYMBOL-RIDDLE] Fuenftes GimmickFix-Kamera-Event, gleiche Technik + Gates
    event5_off_y = 0.0,           -- (44110 @ 10.75/12.87/107.76, Monitor-Dump 2026-07-17 22:43). 0/0/0 = no-op.
    event5_off_z = 0.0,           -- Eigene Stage -> keine Kollision mit 51503/51502, 61400, 61305, 63108.
    event6_off_x = 0.0,           -- [CHURCH-RIDDLE] Sechstes GimmickFix-Kamera-Event, gleiche Technik + Gates
    event6_off_y = 0.0,           -- (45401 @ 106.80/11.63/100.55, Monitor-Dump 2026-07-18 02:43). 0/0/0 = no-op.
    event6_off_z = 0.0,           -- Eigene Stage -> keine Kollision mit den fuenf anderen Riddles.
    turret_off_x = 0.0,           -- [TURRET] eigener HMD-Offset in WELT-Koordinaten fuer die MG-Turret
    turret_off_y = 0.0,           -- (GimmickType InstalledMachineGun). Gate = NUR dieser Gimmick, kein
    turret_off_z = 0.0,           -- Stage/Radius noetig. Technik wie die Riddle-Offsets. 0/0/0 = no-op.
    -- [LADDER RAUS 2026-07-23] ladder_off_* ist ersatzlos gestrichen: seit Leon mit leon_evt_off
    -- einen eigenen Satz fuer alle Nagel-Events hat, faellt die Leiter automatisch dorthin (Ada in
    -- ada_box_off) -- der eigene Zweig war nur noch ein zweiter Wert fuer dieselbe Sache. Keys sind
    -- auch aus re4_vr_firstperson.json entfernt. Rueckweg: Zweig + Slider neu anlegen.
    jetski_off_x = 0.0,           -- [JETSKI] additiver HMD-Offset fuer die Jetski-Fahr-Stages (592xx, KS4),
    jetski_off_y = 0.0,           -- BODY-relativ wie cart_off. Gate = __re4_jetski_active (killswitch).
    jetski_off_z = 0.0,           -- Eigene Werte statt der alten JETSKI_CFG -- justiert wird per Slider. 0 = no-op.
    boat_off_x = 0.0,             -- [BOAT] additiver HMD-Offset fuer die Boot-Fahrt (get_IsBoat, KS4), BODY-relativ
    boat_off_y = 0.0,             -- wie jetski_off. Gate = __re4_boat_active (killswitch, NICHT throwsight).
    boat_off_z = 0.0,             -- justiert wird per Slider "Boat". 0 = no-op.
    begcrouch_off_x = 0.0,        -- [BEGINNING_CROUCH] additiver HMD-Offset fuer den ForceCrouch-KS4 (Stages 40501/
    begcrouch_off_y = 0.0,        -- 40502), BODY-relativ wie jetski_off. Gate = __re4_forcecrouch_ks4_active
    begcrouch_off_z = 0.0,        -- (killswitch). justiert wird per Slider "Beginning Crouch". 0 = no-op.
    -- [ADA_FORCECROUCH 2026-07-22] Eigener HMD-Offset NUR fuer Ada im ForceCrouch (enger Gang).
    -- Vorher erbte dieser Fall den Ada-Universal-Satz (ada_box_off, fuer Kistentritt/Grapple getunt,
    -- -0.08 auf Z = nach hinten). Additiv + body-relativ wie cart_off. Startwert = eben diese -0.08,
    -- der Einbau aendert also nichts; ab hier justieren. Leon ist nicht betroffen.
    ada_fc_off_x = 0.0,
    ada_fc_off_y = 0.0,
    ada_fc_off_z = -0.08,
    -- [LEON_FORCECROUCH 2026-07-23] Eigener HMD-Offset NUR fuer Leon im NORMALEN ForceCrouch
    -- (enger Kriech-Gang). Das 40501/40502-Durchquetsch-Event ist ausgenommen -- das hat begcrouch_off.
    leon_fc_off_x = 0.0,
    leon_fc_off_y = 0.0,
    leon_fc_off_z = 0.0,
    ada_box_off_x = 0.0,          -- [ADA_BOXBREAK 2026-07-21] additiver HMD-Offset NUR fuer ADA
    ada_box_off_y = 0.0,          -- (ch3a8z0_body) beim Fass-/Kistentritt (__re4_boxbreak_active, KS4).
    ada_box_off_z = 0.0,          -- BODY-relativ wie cart_off. Leon haengt an leon_evt_off (s.u.).
    -- [LEON_EVENTS 2026-07-23, "kann leon auch die selben -0.08 in z haben"] Gegenstueck zu
    -- ada_box_off: der bisher hart auf 0/0/0 stehende else-Zweig bekommt einen eigenen, justierbaren
    -- Satz -- gilt fuer ALLE Head-Nagel-Events ohne eigenen Offset (Grapple, Fass-/Kistentritt, Fatal-/
    -- Roundhouse-Tritt, Ashley-Event, KS2/KS4-Zonen). Additiv + body-relativ wie ada_box_off.
    -- HINWEIS: der Zweig ist "nicht Ada", faengt also auch die spielbaren Ashley-Passagen mit ein.
    leon_evt_off_x = 0.0,
    leon_evt_off_y = 0.0,
    leon_evt_off_z = -0.08,
    acrouch_off_x = 0.0,          -- [ASHLEY_CROUCH] eigener HMD-Offset NUR wenn Ashley (ch0a1z0_body) UND
    acrouch_off_y = 0.0,          -- im Crouch. ABSOLUT (ersetzt off_x/y/z). Leon-Crouch +
    acrouch_off_z = 0.0,          -- Ashley-Stand bleiben unberuehrt. Laeuft im GAMEPLAY (kein KS) -> vom
                                  -- Head-Nagel nicht erfasst, deshalb als einziger Offset hier noch noetig.
    -- [MINECART] alle drei Loren-Zustaende (Intro-Einstieg/Intro-Fahrt/RailCar-Fahrt) ankern die Cam am
    -- gepinnten Head (Guard oben in compute_and_set). cart_off_* = ADDITIVER Zusatz-Offset NUR fuer die
    -- Loren-Stages (obendrauf auf off_x/y/z, Body-relativ) -> Kart-Sitz justierbar OHNE die Gameplay-Augenhoehe.
    cart_off_x = 0.0, cart_off_y = 0.0, cart_off_z = 0.0,
    -- [OFFSETS ENTFERNT 2026-07-15] RAUS, samt ihrer Keys in re4_vr_firstperson.json: box_off_* (Fass-/
    -- Kistentritt), fk_off_* (Fatal-/Roundhouse-Tritt), ladder_off_* + upladder_off_* (schraege/senkrechte
    -- Leiter), ashley_off_* (Ashley-Event), grap_off_* (Grapple). Grund: Sie existierten nur, um die Kamera
    -- aus dem Body zu schieben, der in diesen Anims ins Bild schwenkte. Der Head-Nagel (s. compute_and_set)
    -- setzt die Cam stattdessen fest in den Kopf -> der Body ist per Definition dahinter, ein Offset ist
    -- gegenstandslos. Vom bestaetigt.
    -- Bleiben: acrouch_off (Ashley-Crouch, laeuft im Gameplay ohne KS -> kein Nagel), cart_off (Loren,
    -- Kart-Sitz ist getunt und laeuft unveraendert), event_off (Stone-Riddle, Welt-Koordinaten = andere Technik).
    -- [HEADPIN_FADE 2026-07-15] Ausblend-Zeit (s) beim VERLASSEN des Head-Nagels -> zurueck ins normale
    -- Gameplay. Gilt fuer die RUHIGEN Events (KS2-Zonen/Fass-Kistentritt/Leiter/Ashley-Event), NICHT fuer
    -- die KAMPF-Zustaende Grapple + Fatal-/Roundhouse (Kamera muss sofort da sein) und nicht fuer die Loren.
    -- 0 = hart umschalten wie frueher.
    headpin_fade_dur = 0.25,
    movement_stabilization = true, -- Stick-Movement-Override aktiv
    movement_follows_hmd = true,   -- Bewegungsrichtung folgt HMD-Yaw
    bob_tau = 0.5,                 -- Bob-Restfilter Zeitkonstante (s), 0 = aus
    surge_tau = 0.35,              -- Surge-Filter (Kapsel-Tempo-Puls), 0 = aus
    crouch_cam_lerp = true,        -- Stand->Crouch: Kamera-Hoehe weich absacken
    crouch_cam_tau = 0.18,         -- Lerp-Zeitkonstante fuer das Absacken (s)
    standup_cam_track = true,      -- Crouch->Stand: Bob-Lag aussetzen (Kamera folgt Kopf zuegig hoch)
    hide_streaming_dummy = true,   -- pinken StreamingDummy-Cube ausblenden (hook-frei)
    recenter_on_killswitch = true, -- [RECENTER] bei jedem Killswitch-Eintritt Headset-Yaw neutralisieren
    -- [BINO 2026-07-22] Fernglas-Zoom: die Werte lagen hartkodiert in re4_vr_binding.lua
    -- (Tabelle bino_zoom). Kein eigenes Bino-Script -- die Regler gehoeren hierher (Kamera-Thema),
    -- die Mechanik bleibt im Binding und liest die Werte ueber _G.__re4_bino_cfg.
    -- Der Offset schiebt die primaere Kamera entlang der Blickrichtung (+ = nach vorne/naeher ran).
    bino_start = 2.5,              -- Startwert beim Anlegen des Fernglases
    bino_min   = -7.0,             -- weitester Zoom zurueck
    bino_max   = 2.5,              -- weitester Zoom nach vorne
    bino_speed = 3.0,              -- Zoom-Geschwindigkeit am linken Stick
    -- [FORCETWIRLER 2026-08-02] In manchen Events zwingt das Spiel die Blickrichtung auf ein
    -- Schluesselereignis. Live gemessen (Live-Abfrage, Stage st43_310): PlayerCameraController.get_IsForceTwirler
    -- == true UND get_IsControlEnable == false, WAEHREND CamState BattleNormal (= bei uns Gameplay),
    -- OccupiedInfo UNSET und GimmickType Invalid sind -> ueber den Killswitch NICHT zu fassen, das ist
    -- ein reiner Kamera-Effekt ("ForceTwirler"). Getestet und bestaetigt: laeuft.
    block_force_twirler = true,    -- erzwungene Kameraschwenks abbrechen (stopForceTwirler)
}
-- [BINO] Werte ans Binding durchreichen (dort wird gezoomt). Nach dem Laden und nach jeder
-- Slider-Aenderung aufgerufen; das Binding faellt ohne dieses Global auf seine Defaults zurueck.
local function publish_bino()
    _G.__re4_bino_cfg = { start = cfg.bino_start, min = cfg.bino_min,
                          max = cfg.bino_max, speed = cfg.bino_speed }
end
local function save_cfg() pcall(function() json.dump_file(CFG_PATH, cfg) end) end
pcall(function()
    local d = json.load_file(CFG_PATH)
    if type(d) == "table" then
        if d.off_x ~= nil then cfg.off_x = d.off_x end
        if d.off_y ~= nil then cfg.off_y = d.off_y end
        if d.off_z ~= nil then cfg.off_z = d.off_z end
        if type(d.cart_off_x) == "number" then cfg.cart_off_x = d.cart_off_x end
        if type(d.cart_off_y) == "number" then cfg.cart_off_y = d.cart_off_y end
        if type(d.cart_off_z) == "number" then cfg.cart_off_z = d.cart_off_z end
        if type(d.headpin_fade_dur) == "number" then cfg.headpin_fade_dur = d.headpin_fade_dur end
        if d.block_force_twirler ~= nil then cfg.block_force_twirler = d.block_force_twirler and true or false end
        if type(d.event_off_x) == "number" then cfg.event_off_x = d.event_off_x end
        if type(d.event_off_y) == "number" then cfg.event_off_y = d.event_off_y end
        if type(d.event_off_z) == "number" then cfg.event_off_z = d.event_off_z end
        if type(d.event2_off_x) == "number" then cfg.event2_off_x = d.event2_off_x end
        if type(d.event2_off_y) == "number" then cfg.event2_off_y = d.event2_off_y end
        if type(d.event2_off_z) == "number" then cfg.event2_off_z = d.event2_off_z end
        if type(d.event3_off_x) == "number" then cfg.event3_off_x = d.event3_off_x end
        if type(d.event3_off_y) == "number" then cfg.event3_off_y = d.event3_off_y end
        if type(d.event3_off_z) == "number" then cfg.event3_off_z = d.event3_off_z end
        if type(d.event4_off_x) == "number" then cfg.event4_off_x = d.event4_off_x end
        if type(d.event4_off_y) == "number" then cfg.event4_off_y = d.event4_off_y end
        if type(d.event4_off_z) == "number" then cfg.event4_off_z = d.event4_off_z end
        if type(d.event5_mono) == "boolean" then cfg.event5_mono = d.event5_mono end
        if type(d.event5_off_x) == "number" then cfg.event5_off_x = d.event5_off_x end
        if type(d.event5_off_y) == "number" then cfg.event5_off_y = d.event5_off_y end
        if type(d.event5_off_z) == "number" then cfg.event5_off_z = d.event5_off_z end
        if type(d.event6_off_x) == "number" then cfg.event6_off_x = d.event6_off_x end
        if type(d.event6_off_y) == "number" then cfg.event6_off_y = d.event6_off_y end
        if type(d.event6_off_z) == "number" then cfg.event6_off_z = d.event6_off_z end
        if type(d.turret_off_x) == "number" then cfg.turret_off_x = d.turret_off_x end
        if type(d.turret_off_y) == "number" then cfg.turret_off_y = d.turret_off_y end
        if type(d.turret_off_z) == "number" then cfg.turret_off_z = d.turret_off_z end
        if type(d.jetski_off_x) == "number" then cfg.jetski_off_x = d.jetski_off_x end
        if type(d.jetski_off_y) == "number" then cfg.jetski_off_y = d.jetski_off_y end
        if type(d.jetski_off_z) == "number" then cfg.jetski_off_z = d.jetski_off_z end
        if type(d.boat_off_x) == "number" then cfg.boat_off_x = d.boat_off_x end
        if type(d.boat_off_y) == "number" then cfg.boat_off_y = d.boat_off_y end
        if type(d.boat_off_z) == "number" then cfg.boat_off_z = d.boat_off_z end
        if type(d.begcrouch_off_x) == "number" then cfg.begcrouch_off_x = d.begcrouch_off_x end
        if type(d.begcrouch_off_y) == "number" then cfg.begcrouch_off_y = d.begcrouch_off_y end
        if type(d.begcrouch_off_z) == "number" then cfg.begcrouch_off_z = d.begcrouch_off_z end
        if type(d.ada_fc_off_x) == "number" then cfg.ada_fc_off_x = d.ada_fc_off_x end
        if type(d.ada_fc_off_y) == "number" then cfg.ada_fc_off_y = d.ada_fc_off_y end
        if type(d.ada_fc_off_z) == "number" then cfg.ada_fc_off_z = d.ada_fc_off_z end
        if type(d.ada_box_off_x) == "number" then cfg.ada_box_off_x = d.ada_box_off_x end
        if type(d.ada_box_off_y) == "number" then cfg.ada_box_off_y = d.ada_box_off_y end
        if type(d.ada_box_off_z) == "number" then cfg.ada_box_off_z = d.ada_box_off_z end
        if type(d.leon_fc_off_x) == "number" then cfg.leon_fc_off_x = d.leon_fc_off_x end
        if type(d.leon_fc_off_y) == "number" then cfg.leon_fc_off_y = d.leon_fc_off_y end
        if type(d.leon_fc_off_z) == "number" then cfg.leon_fc_off_z = d.leon_fc_off_z end
        if type(d.leon_evt_off_x) == "number" then cfg.leon_evt_off_x = d.leon_evt_off_x end
        if type(d.leon_evt_off_y) == "number" then cfg.leon_evt_off_y = d.leon_evt_off_y end
        if type(d.leon_evt_off_z) == "number" then cfg.leon_evt_off_z = d.leon_evt_off_z end
        if type(d.acrouch_off_x) == "number" then cfg.acrouch_off_x = d.acrouch_off_x end
        if type(d.acrouch_off_y) == "number" then cfg.acrouch_off_y = d.acrouch_off_y end
        if type(d.acrouch_off_z) == "number" then cfg.acrouch_off_z = d.acrouch_off_z end
        if d.movement_stabilization ~= nil then cfg.movement_stabilization = d.movement_stabilization == true end
        if d.movement_follows_hmd ~= nil then cfg.movement_follows_hmd = d.movement_follows_hmd == true end
        if type(d.bob_tau) == "number" then cfg.bob_tau = d.bob_tau end
        if type(d.surge_tau) == "number" then cfg.surge_tau = d.surge_tau end
        if d.crouch_cam_lerp ~= nil then cfg.crouch_cam_lerp = d.crouch_cam_lerp == true end
        if type(d.crouch_cam_tau) == "number" then cfg.crouch_cam_tau = d.crouch_cam_tau end
        if d.standup_cam_track ~= nil then cfg.standup_cam_track = d.standup_cam_track == true end
        if d.hide_streaming_dummy ~= nil then cfg.hide_streaming_dummy = d.hide_streaming_dummy == true end
        if d.recenter_on_killswitch ~= nil then cfg.recenter_on_killswitch = d.recenter_on_killswitch == true end
        if type(d.bino_start) == "number" then cfg.bino_start = d.bino_start end
        if type(d.bino_min)   == "number" then cfg.bino_min   = d.bino_min   end
        if type(d.bino_max)   == "number" then cfg.bino_max   = d.bino_max   end
        if type(d.bino_speed) == "number" then cfg.bino_speed = d.bino_speed end
    end
end)
publish_bino()   -- [BINO] Startwerte sofort ans Binding, auch ohne UI-Besuch

-- ---- Getter ----
-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: einmal pro Frame aufloesen statt bei
-- jedem Aufruf. Semantik unveraendert, alter Weg bleibt als Fallback. NOT-AUS: `_G.__re4_fc_off = true`.
pcall(function() require("re4vr/re4_vr_frame_cache") end)

local function get_player_ctx()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.ctx() end
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    if not cm then return nil end
    return safe(function() return cm:call("getPlayerContextRef") end)
end

-- =====================================================================
-- [PERF 2026-08-17] Die sieben Event-Offset-Funktionen (event, event2..6, turret) laufen in VIER
-- Phasen pro Frame. Jede von ihnen fragt, sobald ihr Offset gesetzt ist, zuerst die Stage-ID ab und
-- haengelt sich dann durch CameraSystem -> MainCameraController -> BusyCameraController, um zu
-- pruefen, ob ihr Event ueberhaupt laeuft. Im Profiler waren das 0.395 ms/Frame -- und in der
-- ausgelieferten Config sind ALLE sieben Offsets gesetzt, die Ketten laufen also wirklich alle:
-- gezaehlt rund 96 Engine-Calls pro Frame, nur fuer die Frage "bin ich zustaendig?".
--
-- Beide Antworten sind innerhalb eines Frames konstant -- die Stage wechselt nicht mitten im Frame,
-- und die Busy-Kamera auch nicht. Sie werden deshalb einmal pro Frame geholt und danach aus einer
-- Lua-Variable beantwortet. An den Bedingungen selbst aendert sich nichts, jede Funktion prueft
-- weiterhin exakt dasselbe.
--
-- NOT-AUS: `_G.__re4_fp_perf_off = true` -> jede Funktion fragt wieder selbst (Stand des Backups
--          others/re4_vr_firstperson.bak_2026-08-17_pre_perf.lua)
-- =====================================================================
local function fp_perf_on()
    return rawget(_G, "__re4_fp_perf_off") ~= true
end

local _fp_frame = 0
local _fp_stage, _fp_stage_f = nil, -1
local _fp_busy,  _fp_busy_f  = nil, -1

local function fp_stage_cached()
    local ctx = get_player_ctx(); if not ctx then return nil end
    if not fp_perf_on() then
        return safe(function() return ctx:call("get_CurrentStageID") end)
    end
    if _fp_stage_f == _fp_frame then return _fp_stage end
    _fp_stage = safe(function() return ctx:call("get_CurrentStageID") end)
    _fp_stage_f = _fp_frame
    return _fp_stage
end

local function fp_busy_cached()
    if not camera_system then camera_system = sdk.get_managed_singleton("chainsaw.CameraSystem") end
    if not fp_perf_on() then
        local main = camera_system and safe(function() return camera_system:call("get_MainCameraController") end)
        return main and safe(function() return main:call("get_BusyCameraController") end) or nil
    end
    if _fp_busy_f == _fp_frame then return _fp_busy end
    local main = camera_system and safe(function() return camera_system:call("get_MainCameraController") end)
    _fp_busy = main and safe(function() return main:call("get_BusyCameraController") end) or nil
    _fp_busy_f = _fp_frame
    return _fp_busy
end

-- [ADA_ONLY 2026-07-21] Aktuell gesteuerter Body = Ada? (ch3a8z0_body -- Name aus der
-- Body-Tabelle in re4_vr_materials.lua verifiziert). Adas Koerper ist kleiner/anders proportioniert
-- als Leons -> beim Fass-/Kistentritt sitzt die Kamera anders. Gate fuer den boxbreak-Offset unten:
-- schlaegt die Abfrage fehl (nil/anderer Body), gilt IMMER der bisherige Leon-Weg.
local function is_ada_now()
    local ctx = get_player_ctx()
    local body = ctx and safe(function() return ctx:call("get_BodyGameObject") end)
    local name = body and safe(function() return body:call("get_Name") end)
    return name == "ch3a8z0_body"
end

-- [ASHLEY_CROUCH] Aktuell gesteuerter Body = Ashley? (Leon = ch0a0z0_body, Ashley = ch0a1z0_body)
local function is_ashley_now()
    local ctx = get_player_ctx()
    local body = ctx and safe(function() return ctx:call("get_BodyGameObject") end)
    local name = body and safe(function() return body:call("get_Name") end)
    return name == "ch0a1z0_body"
end

local function get_body_transform()
    local ctx = get_player_ctx()
    if not ctx then return nil end
    local body = safe(function() return ctx:call("get_BodyGameObject") end)
    if not body then return nil end
    return safe(function() return body:call("get_Transform") end)
end

local function get_camera_joint()
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local go = safe(function() return cam:call("get_GameObject") end)
    if not go then return nil end
    local tf = safe(function() return go:call("get_Transform") end)
    if not tf then return nil end
    local joints = safe(function() return tf:call("get_Joints") end)
    return joints and joints[0] or nil
end

-- Head-Joint (gecacht, validiert) — Kamera am HEAD: zusammen mit der
-- IkLeg2-Stabilisierung (movement.lua) ist der Head ruhig. Root-Anker +
-- IkLeg2 waere invertierter Bob (Memo Headbob-Session, nicht wiederholen).
local head_cache = { joint = nil }

local function is_joint_valid(j)
    if not j then return false end
    local ok = pcall(function() return j:call("get_Position") end)
    return ok
end

local function get_head_joint()
    if is_joint_valid(head_cache.joint) then return head_cache.joint end
    head_cache.joint = nil
    local btf = get_body_transform()
    if not btf then return nil end
    local j = safe(function() return btf:call("getJointByName", "Head") end)
    if j and is_joint_valid(j) then
        head_cache.joint = j
        return j
    end
    return nil
end

-- ============================================================
-- [LEANING_LADDER DIAG temp] Reset-Scripts-freundlich. Findet heraus, WELCHE GmLadderBase-Methode beim
-- Besteigen feuert + welcher Leiter-Typ -> re4_leaning_diag.log. Aufraeumen, sobald geklaert.
-- ============================================================
if not _G.__re4_ll_diag2 then
    _G.__re4_ll_diag2 = true
    local function llog(s) end
    local ladder_td   = sdk.find_type_definition("chainsaw.GmLadderBase")
    local leaning_def = sdk.find_type_definition("chainsaw.GmLeaningLadder")
    llog(string.format("INIT ladder_td=%s leaning_def=%s", tostring(ladder_td ~= nil), tostring(leaning_def ~= nil)))
    local _seen = {}   -- dedup: jede (Methode|Typ)-Kombi nur einmal loggen (applyMove/updateGimmick feuern per-Frame)
    if ladder_td then
        for _, mn in ipairs({ "tryUse", "requestUse", "onAcceptUse", "applyMove", "updateGimmick" }) do
            local m = ladder_td:get_method(mn)
            llog("method " .. mn .. " = " .. tostring(m ~= nil))
            if m then
                pcall(function()
                    sdk.hook(m, function(args)
                        pcall(function()
                            local ladder = sdk.to_managed_object(args[1])
                            local tn  = ladder and ladder:get_type_definition():get_full_name()
                            local key = mn .. "|" .. tostring(tn)
                            if not _seen[key] then
                                _seen[key] = true
                                local isl = ladder and leaning_def and ladder:get_type_definition():is_a(leaning_def)
                                llog("FIRE " .. mn .. " type=" .. tostring(tn) .. " is_leaning=" .. tostring(isl))
                            end
                        end)
                    end, nil)
                end)
            end
        end
    end
    local _ll_t = 0
    re.on_frame(function()
        local ctx = get_player_ctx()
        local il = ctx and safe(function() return ctx:call("get_IsLadder") end)
        if il ~= true then return end
        _ll_t = _ll_t + 1
        if _ll_t % 60 ~= 0 then return end
        local ks4 = nil
        if type(killswitch.is_ks4) == "function" then local o, v = pcall(killswitch.is_ks4); if o then ks4 = v end end
        llog(string.format("CLIMB mounted=%s active=%s is_ks4=%s", tostring(rawget(_G, "__re4_leaning_ladder_mounted")),
            tostring(rawget(_G, "__re4_leaning_ladder_active")), tostring(ks4)))
    end)
end

local function active()
    if not vrmod then return false end
    if not vrmod:is_hmd_active() then return false end
    local ok, ks_on = pcall(killswitch.is_active)
    if ok and ks_on then
        -- [KS2/KS3] First-Person BLEIBT (motion/arm sind aus). KS1 (voll) -> native 3rd-Person.
        local keep_fp = false
        if type(killswitch.is_ks2) == "function" then local o, v = pcall(killswitch.is_ks2); if o and v == true then keep_fp = true end end
        if type(killswitch.is_ks3) == "function" then local o, v = pcall(killswitch.is_ks3); if o and v == true then keep_fp = true end end
        if type(killswitch.is_ks4) == "function" then local o, v = pcall(killswitch.is_ks4); if o and v == true then keep_fp = true end end
        if type(killswitch.is_ks5) == "function" then local o, v = pcall(killswitch.is_ks5); if o and v == true then keep_fp = true end end
        if not keep_fp then return false end
    end
    return true
end

-- ---- vr_camera_fix Export (Basis fuer das Motion-Script) ----
-- Das Motion-Script braucht die Kamera-Basis OHNE HMD-Playspace-Offset
-- (die Kamera-Matrix enthaelt den schon -> Haende driften beim physischen
-- Gehen). camera_pos = unsere Head-Anker-Position, camera_rot = geflatteter
-- Game-Kamera-Yaw (NUR GELESEN aus _CameraRotation, nie geschrieben).
_G.vr_camera_fix = _G.vr_camera_fix or {}
_G.vr_camera_fix.active = false

local camera_system = nil
local player_cam_td = sdk.find_type_definition("chainsaw.PlayerCameraController")
local gimmickfix_cam_td = sdk.find_type_definition("chainsaw.GimmickFixCameraController")
-- [TURRET 2026-07-16] Enum-Wert der MG-Turret (CameraDefine.GimmickType.InstalledMachineGun) zur Ladezeit
-- aufloesen (Fallback 6, live verifiziert). Fuer apply_turret_hmd_offset weiter unten.
local TURRET_GIMMICK = (function()
    local t = sdk.find_type_definition("chainsaw.CameraDefine.GimmickType")
    if t then for _, fld in ipairs(t:get_fields() or {}) do
        if fld:is_static() and fld:get_name() == "InstalledMachineGun" then
            local ok, v = pcall(function() return fld:get_data(nil) end)
            if ok and type(v) == "number" then return v end
        end
    end end
    return 6
end)()

local function get_game_cam_yaw()
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

    local cam_rot = safe(function() return busy:get_field("_CameraRotation") end)
    if not cam_rot then return nil end
    local fwd = cam_rot * Vector3f.new(0, 0, 1)
    fwd.y = 0.0
    local len = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
    if len < 0.0001 then return nil end
    fwd = Vector3f.new(fwd.x / len, 0.0, fwd.z / len)
    return safe(function() return fwd:to_quat() end)
end

-- =====================================================================
-- [FORCETWIRLER 2026-08-02] Erzwungene Kameraschwenks abbrechen.
-- Das Spiel dreht in manchen Events die Blickrichtung auf ein Schluesselereignis; in VR reisst das
-- den Kopf mit. Der Zustand haengt NICHT am CamState (der bleibt Gameplay), sondern allein am
-- PlayerCameraController: get_IsForceTwirler == true, get_IsControlEnable == false.
-- Gegenmittel: solange ein Schwenk laeuft, jeden Frame stopForceTwirler rufen.
-- stopForceTwirler ist VOID -> kein Rueckgabewert-Risiko (s. SKIP_ORIGINAL-Falle), und es wird
-- weder ein nativer Call geblockt noch ein Eingabepfad gegatet -- der Schwenk wird nur beendet.
-- Reicht das irgendwo nicht, waere der naechste Schritt requestForceTwirlerBase(...) zu blocken --
-- ACHTUNG: die gibt BOOLEAN zurueck, also zwingend sdk.to_ptr(0) im Post-Hook, sonst Registermuell-Crash.
-- =====================================================================
local ftw = { twirl = false, control = true, stopped = 0 }   -- nur Anzeige, kein Verhalten
-- [FTW_BACKOFF 2026-08-04] Wird vom UI-Block gesetzt, solange dessen Zeile gezeichnet wird.
-- MUSS hier oben stehen: der on_frame-Block weiter unten liest sie, und eine erst spaeter
-- deklarierte local waere dort schlicht nil (die Falle, die schon zweimal Zeit gekostet hat).
local ftw_ui_open = false

-- Aktiver Controller, aber nur wenn es die SPIELERKAMERA ist: bei Event-/Gimmick-/Vehicle-Kameras
-- gibt es gar keinen ForceTwirler (und die Methode existiert dort nicht).
local function get_player_cam()
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

-- [FTW_BACKOFF 2026-08-04 -- Crash beim Pumpen] Der Block hier stand als Verursacher einer
-- Exception-FLUT im re2_framework_log: 2957 Zeilen in EINER Sekunde (00:01:34), fast alle
-- "c0000005 in chainsaw.PlayerCameraController.get_IsControlEnable", dazwischen
-- InvalidOperationException aus via.GameObject.getComponent/get_Transform = zerstoerte Objekte.
-- Ursache: waehrend eines Objektwechsels (Pumpen tauscht Waffen-/Shell-Objekte) ist der
-- BusyCameraController kurz ungueltig. is_a geht noch durch, der GETTER greift ins Leere.
-- safe/pcall helfen NICHT: REFramework schreibt die Engine-Exception synchron auf die Platte,
-- BEVOR unser pcall sie sieht (bekannte Falle, hat schon einmal die Eingaben lahmgelegt).
--
-- Drei Absicherungen, KEIN Verhaltenswechsel solange die Kamera lebt:
-- 1. Backoff: liefert get_IsForceTwirler nil (= Call fehlgeschlagen), 0.5 s lang gar nichts
-- mehr an dieser Kamera anfassen. Ein echter Schwenk dauert deutlich laenger, der Stop
-- kommt also weiterhin rechtzeitig.
-- 2. get_IsControlEnable nur noch fuer die UI-Zeile abfragen (Tree offen), nicht jeden Frame.
-- 3. Nur im reinen Gameplay stochern -- in Menue/Laden/Killswitch werden Objekte abgeraeumt,
-- genau dort entstand die Flut.
local ftw_block_until = 0.0   -- os.clock-Zeitpunkt, ab dem wieder gefragt werden darf
local ftw_fail_streak = 0     -- [FTW_GATE_RAUS] Fehlschlaege in Folge -> Backoff wird laenger

re.on_frame(function()
    _fp_frame = _fp_frame + 1   -- [PERF] Frame-Grenze fuer fp_stage_cached / fp_busy_cached
    if os.clock() < ftw_block_until then return end
    -- [FTW_GATE_RAUS 2026-08-06, "der Twirler wirkt nicht mehr"] Hier stand Absicherung 3 vom
    -- 04.08.: `if __re4_frame_is_gameplay ~= true then return end`. Das war ein Denkfehler -- das Flag
    -- ist laut re4_vr_binding.lua:1658 u.a. `not ks_active`, und erzwungene Kameraschwenks laufen
    -- IMMER mit aktivem Killswitch (Blick auf ein Schluesselereignis). Das Gate sperrte den Block also
    -- exakt in den Momenten, fuer die er gebaut wurde -> stopForceTwirler wurde nie erreicht.
    -- Gegen die Logflut vom 04.08. (2957 Zeilen/s beim Pumpen) hat es ohnehin nichts beigetragen:
    -- die kam aus wiederholten Calls auf einen toten Controller, nicht aus Menue/KS. Dagegen wirkt
    -- der Backoff -- der bleibt und ist jetzt zusaetzlich progressiv.
    local cam = get_player_cam()
    if not cam then
        -- Keine Spielerkamera (Event-/Vehicle-/Gimmick-Kamera oder gerade abgeraeumt). Kurz Ruhe geben,
        -- sonst laufen get_MainCameraController/get_BusyCameraController jeden Frame auf Objekte, die
        -- im Umbau sind -- genau daher kamen die InvalidOperationException-Zeilen im Flut-Log.
        ftw.twirl = false
        ftw_block_until = os.clock() + 0.20
        return
    end

    local tw = safe(function() return cam:call("get_IsForceTwirler") end)
    if tw == nil then
        -- Controller ist gerade ungueltig -> Ruhe, statt jeden Frame eine AV zu provozieren.
        -- Progressiv: 0.5 s, dann 1 s, dann 2 s (Deckel). Haelt eine laengere Umbauphase (Pumpen,
        -- Waffenwechsel, Ladephase) bei ~1 Logzeile alle 2 s statt hunderten pro Sekunde.
        ftw.twirl = false
        ftw_fail_streak = math.min(ftw_fail_streak + 1, 3)
        ftw_block_until = os.clock() + math.min(0.5 * (2 ^ (ftw_fail_streak - 1)), 2.0)
        return
    end
    ftw_fail_streak = 0   -- Kamera antwortet wieder -> naechster Fehlschlag startet klein
    ftw.twirl = (tw == true)

    -- [NUR ANZEIGE] Kostet sonst einen zweiten Call pro Frame auf demselben Objekt.
    if ftw_ui_open then
        ftw.control = safe(function() return cam:call("get_IsControlEnable") end) ~= false
    end

    if not cfg.block_force_twirler then return end
    if not ftw.twirl then return end
    safe(function() cam:call("stopForceTwirler") end)
    ftw.stopped = ftw.stopped + 1
end)

-- [MINECART HAND-ROLL FIX] Im railcar ist die aktive Kamera ein VehicleCameraController (KEIN
-- PlayerCameraController) -> get_game_cam_yaw gibt nil -> frueher setzte der Guard vr_camera_fix.active=false
-- -> motion fiel fuer die Hand-Basis auf die ROHE primary-camera-Rotation zurueck, und die ROLLT mit dem Cart
-- -> Hand/Waffe rollte mit. Fix: aus der primary camera einen FLACHEN Yaw ziehen (fwd.y=0 flacht Pitch; ein
-- Roll um die Blickachse laesst die Vorwaerts-Z unveraendert -> faellt automatisch raus) -> reiner Yaw, kein
-- Roll -> die Haende bleiben weltstabil. NUR fuer die Minecart-Zustaende genutzt (Guard).
local function get_primary_cam_flat_yaw()
    local cam = sdk.get_primary_camera(); if not cam then return nil end
    local go = safe(function() return cam:call("get_GameObject") end); if not go then return nil end
    local tf = safe(function() return go:call("get_Transform") end); if not tf then return nil end
    local rot = safe(function() return tf:call("get_Rotation") end); if not rot then return nil end
    local fwd = rot * Vector3f.new(0, 0, 1)
    fwd.y = 0.0
    local len = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
    if len < 0.0001 then return nil end
    fwd = Vector3f.new(fwd.x / len, 0.0, fwd.z / len)
    return safe(function() return fwd:to_quat() end)
end

-- [BOB_FILTER] Kamera-Anker = Kapsel + Tiefpass(Head − Kapsel).
-- Schluckt den Rest-Bob (Schritt-Zyklen 0.38-0.45s, gemessen via
-- re4vr_bob_diag), folgt langsamem Echtem (Ducken/Treppen) mit ~tau
-- Verzoegerung. Nur fuer die RESTgroesse gedacht: Body vorher via
-- IkLeg+UB-Lock stabilisieren, sonst Body/Kamera-Divergenz (Memo
-- Anti-Surge). EMA-Update 1x pro Game-Frame (LockScene-pre).
local bob_filter = { ema = nil, last_t = nil }

-- Forward-Decl (Upvalue): apply_bob_filter liest crouch_cam.standup_until fuer
-- den Aufsteh-Bypass; das Table wird unten bei der Lerp-Logik weiter genutzt.
local crouch_cam = { ema = nil, was = false, until_t = nil, last_t = nil, standup_until = nil }

-- [CAPY] Kapsel-Y kurz glaetten (fest, kein Slider): die Boden-Physik (PCC)
-- schreibt nur jeden 2. Frame -> 30Hz-Treppchen, die sonst 1:1 ueber den
-- Kapsel-Anker ins Auge gehen (transform_diag-Befund). 0.12s brueckt die
-- Stufen, folgt Haengen praktisch ohne Lag. (War schon mal drin und wirksam,
-- flog beim Komplett-Revert 2026-06-06 mit raus.)
local capy = { ema = nil, last_t = nil }
local CAPY_TAU = 0.12

local function apply_bob_filter(hp, frame_tick)
    local tau = cfg.bob_tau or 0
    if tau <= 0.001 then
        bob_filter.ema = nil
        return hp
    end
    -- [STANDUP_TRACK] Aufstehen (Crouch->Stand): Bob-Lag fuers Aufsteh-Fenster
    -- aussetzen, damit die Kamera dem schnell hochkommenden Kopf folgt — sonst
    -- ist der Body kurz im Weg (Spine-Pin rastet sofort auf Steh-Pose). ema=nil
    -- -> der Passthrough-Zweig unten re-latcht jeden Frame = kein Lag nach oben.
    if cfg.standup_cam_track and crouch_cam.standup_until
        and os.clock() < crouch_cam.standup_until then
        bob_filter.ema = nil
    end
    local btf = get_body_transform()
    local bp = btf and safe(function() return btf:call("get_Position") end)
    if not bp then return hp end

    if frame_tick then
        local nowc = os.clock()
        local dtc = capy.last_t and math.min(nowc - capy.last_t, 0.1) or 0.016
        capy.last_t = nowc
        if not capy.ema or math.abs(bp.y - capy.ema) > 0.5 then
            capy.ema = bp.y   -- Teleport/Spawn: hart aufsetzen
        else
            local ac = 1.0 - math.exp(-dtc / CAPY_TAU)
            capy.ema = capy.ema + (bp.y - capy.ema) * ac
        end
    end
    if capy.ema then bp = Vector3f.new(bp.x, capy.ema, bp.z) end

    local rel = Vector3f.new(hp.x - bp.x, hp.y - bp.y, hp.z - bp.z)
    local e = bob_filter.ema
    if not e then
        bob_filter.ema = rel
        return hp
    end
    local dx, dy, dz = rel.x - e.x, rel.y - e.y, rel.z - e.z
    -- Teleport/Cutscene/Stance-Sprung (>0.5m): hart re-latchen statt gleiten
    if (dx * dx + dy * dy + dz * dz) > 0.25 then
        bob_filter.ema = rel
        return hp
    end
    if frame_tick then
        local now = os.clock()
        local dt = bob_filter.last_t and math.min(now - bob_filter.last_t, 0.1) or 0.016
        bob_filter.last_t = now
        local a = 1.0 - math.exp(-dt / tau)
        bob_filter.ema = Vector3f.new(e.x + dx * a, e.y + dy * a, e.z + dz * a)
        e = bob_filter.ema
    end
    return Vector3f.new(bp.x + e.x, bp.y + e.y, bp.z + e.z)
end

-- [SURGE_FILTER] Die Kapsel pulsiert pro Schritt im Tempo (gemessen:
-- Walk ±47%, Jog ±15% — Root-Motion bremst/schiebt). Dead-Reckoning:
-- Kamera-Basis laeuft mit EMA-geglaetteter Geschwindigkeit, wird weich
-- zur echten Kapsel gezogen (Fehler bleibt gebunden). Stillstand
-- (<0.3 m/s) rastet schnell ein -> kein Nachgleiten beim Stoppen.
local surge = { px = nil, pz = nil, vx = 0, vz = 0, lx = nil, lz = nil, last_t = nil }

local function apply_surge_filter(hp, bp, frame_tick)
    local tau = cfg.surge_tau or 0
    if tau <= 0.001 or not bp then
        surge.px = nil
        _G.__vr_surge_dx, _G.__vr_surge_dz = nil, nil
        return hp
    end
    if frame_tick then
        local now = os.clock()
        local dt = surge.last_t and math.min(now - surge.last_t, 0.1) or 0.016
        surge.last_t = now
        if not surge.px or not surge.lx then
            surge.px, surge.pz = bp.x, bp.z
            surge.vx, surge.vz = 0, 0
        else
            local rvx = (bp.x - surge.lx) / dt
            local rvz = (bp.z - surge.lz) / dt
            local rspeed = math.sqrt(rvx * rvx + rvz * rvz)
            local ex = bp.x - surge.px
            local ez = bp.z - surge.pz
            if (ex * ex + ez * ez) > 1.0 then
                -- Teleport/Cutscene: hart neu aufsetzen
                surge.px, surge.pz, surge.vx, surge.vz = bp.x, bp.z, 0, 0
            elseif rspeed < 0.3 then
                -- Stillstand: schnell einrasten
                local a = 1.0 - math.exp(-dt / 0.07)
                surge.px = surge.px + ex * a
                surge.pz = surge.pz + ez * a
                surge.vx, surge.vz = 0, 0
            else
                -- Drehen erkennen am BODY-YAW statt an der Velocity-Richtung:
                -- die Velocity wackelt beim Gehen JEDEN Schritt (Tempo-Puls
                -- ±47% + Seitwaerts-Sway, bis ~30° Wobble) und riss das alte
                -- dirdot-Gate staendig auf -> der Snap-Zweig (0.07s, ignoriert
                -- tau!) injizierte den Schritt-Puls zurueck. Der Body-Yaw ist
                -- beim Geradeauslaufen totenstill (wir besitzen ihn 1:1).
                local yaw_rate = 0.0
                local btf2 = get_body_transform()
                local br = btf2 and safe(function() return btf2:call("get_Rotation") end)
                if br then
                    local f = br * Vector3f.new(0.0, 0.0, 1.0)
                    local yl = math.sqrt(f.x * f.x + f.z * f.z)
                    if yl > 0.0001 then
                        local yaw = math.atan(f.x / yl, f.z / yl)
                        if surge.lyaw then
                            local dyw = yaw - surge.lyaw
                            if dyw > math.pi then dyw = dyw - 2.0 * math.pi
                            elseif dyw < -math.pi then dyw = dyw + 2.0 * math.pi end
                            yaw_rate = math.abs(dyw) / dt
                        end
                        surge.lyaw = yaw
                    end
                end
                -- Entprellen: 1-Frame-Kopfzucker (>Schwelle fuer einen Tick)
                -- riss sonst einzelne Snap-Blips in die glatte Bahn (Diag:
                -- 1.96/2.30-Paare). Erst ab 3 Frames anhaltendem Drehen.
                if yaw_rate > math.rad(60) then
                    surge.turn_n = (surge.turn_n or 0) + 1
                else
                    surge.turn_n = 0
                end
                if surge.turn_n >= 3 then
                    local a = 1.0 - math.exp(-dt / 0.07)
                    surge.px = surge.px + ex * a
                    surge.pz = surge.pz + ez * a
                    surge.vx, surge.vz = rvx, rvz
                else
                    local av = 1.0 - math.exp(-dt / tau)
                    surge.vx = surge.vx + (rvx - surge.vx) * av
                    surge.vz = surge.vz + (rvz - surge.vz) * av
                    surge.px = surge.px + surge.vx * dt
                    surge.pz = surge.pz + surge.vz * dt
                    -- Drift-Bindung PROGRESSIV statt pauschal: der alte
                    -- Dauerpull zur rohen Kapsel re-injizierte den Schritt-
                    -- Puls (Slider wirkte kaum). Unter 0.10m Fehler: kein
                    -- Pull (Puls bleibt komplett draussen, Kamera faehrt
                    -- konstante Geschwindigkeit). Darueber quadratisch
                    -- zunehmend; den Rest faengt der 0.25m-Deckel.
                    local fx0 = bp.x - surge.px
                    local fz0 = bp.z - surge.pz
                    local fl0 = math.sqrt(fx0 * fx0 + fz0 * fz0)
                    if fl0 > 0.10 then
                        local t = (fl0 - 0.10) / 0.15
                        if t > 1.0 then t = 1.0 end
                        local ap = (1.0 - math.exp(-dt / 0.15)) * t * t
                        surge.px = surge.px + fx0 * ap
                        surge.pz = surge.pz + fz0 * ap
                    end
                end
                -- harter Fehler-Deckel: Kamera nie weiter als 0.25m von
                -- der echten Kapsel-Bahn weg
                local fx = bp.x - surge.px
                local fz = bp.z - surge.pz
                local fl = math.sqrt(fx * fx + fz * fz)
                if fl > 0.25 then
                    local s = 1.0 - (0.25 / fl)
                    surge.px = surge.px + fx * s
                    surge.pz = surge.pz + fz * s
                end
            end
        end
        surge.lx, surge.lz = bp.x, bp.z
    end
    if not surge.px then
        _G.__vr_surge_dx, _G.__vr_surge_dz = nil, nil
        return hp
    end
    -- Export fuer movement.lua: SPINE_PIN-Bridge schiebt den SICHTBAREN
    -- Body auf dieselbe geglaettete Bahn -> keine Body/Kamera-Divergenz.
    -- Kamera-Shift laeuft IMMER hier: im Pin-Modus ankert die Kamera auf
    -- der rohen Kapsel (PIN_ANCHOR) und braucht den Shift genau 1x —
    -- gleicher Betrag wie die Bridge am Body = synchron.
    _G.__vr_surge_dx = surge.px - bp.x
    _G.__vr_surge_dz = surge.pz - bp.z
    return Vector3f.new(hp.x + (surge.px - bp.x), hp.y, hp.z + (surge.pz - bp.z))
end

-- [CROUCH_CAM_LERP] Beim Reingehen ins Crouch sackt der Head-Joint (und damit
-- die HMD-Kamera) schnell ab -> Pop. Wir glaetten NUR die ABWAERTS-Bewegung der
-- Kamera-Hoehe und NUR im Crouch-Eintritts-Fenster (steigende Flanke). Die
-- Flanken-Erkennung selbst laeuft IMMER (auch wenn der Abwaerts-Lerp aus ist),
-- weil die fallende Flanke das Aufsteh-Fenster (standup_until) fuer den
-- Bob-Bypass in apply_bob_filter armt. (crouch_cam ist oben forward-deklariert.)
local CROUCH_CAM_WINDOW = 0.8   -- Eintritts-Fenster Stand->Crouch (s)
local STANDUP_WINDOW    = 0.5   -- Aufsteh-Fenster Crouch->Stand (s)

local function is_crouch_now()
    if type(killswitch.is_crouch_active) ~= "function" then return false end
    local ok, v = pcall(killswitch.is_crouch_active)
    return ok and v == true
end

local function apply_crouch_cam_lerp(y, frame_tick)
    local crouching = is_crouch_now()
    local now = os.clock()
    -- Flanken IMMER auswerten (Toggle-unabhaengig, damit beide Mechaniken armen):
    if crouching and not crouch_cam.was then
        -- Stand->Crouch: Absack-Fenster oeffnen, ema auf aktuelle (noch stehende)
        -- Hoehe latchen -> die folgende Abwaerts-Anim wird nachgezogen.
        crouch_cam.until_t = now + CROUCH_CAM_WINDOW
        crouch_cam.ema = y
        crouch_cam.last_t = now
    elseif (not crouching) and crouch_cam.was then
        -- Crouch->Stand: Aufsteh-Fenster fuer den Bob-Bypass (apply_bob_filter).
        crouch_cam.standup_until = now + STANDUP_WINDOW
        crouch_cam.until_t = nil
    end
    crouch_cam.was = crouching

    local tau = cfg.crouch_cam_tau or 0
    if not cfg.crouch_cam_lerp or tau <= 0.001 then
        crouch_cam.ema = y; crouch_cam.until_t = nil
        return y
    end

    local in_window = crouch_cam.until_t ~= nil and now < crouch_cam.until_t and crouching
    if not in_window then
        crouch_cam.ema = y          -- passthrough, ema synchron halten
        crouch_cam.until_t = nil
        return y
    end

    if crouch_cam.ema == nil then crouch_cam.ema = y end
    if frame_tick then
        local dt = crouch_cam.last_t and math.min(now - crouch_cam.last_t, 0.1) or 0.016
        crouch_cam.last_t = now
        if y < crouch_cam.ema then
            -- Kamera sackt ab -> weich nachziehen (Lag = sanfter Lerp nach unten)
            local a = 1.0 - math.exp(-dt / tau)
            crouch_cam.ema = crouch_cam.ema + (y - crouch_cam.ema) * a
        else
            crouch_cam.ema = y       -- Kopf gleich/hoeher -> nie nach oben laggen
        end
        if math.abs(crouch_cam.ema - y) < 0.005 then
            crouch_cam.until_t = nil -- konvergiert -> Fenster schliessen
        end
    end
    return crouch_cam.ema
end

-- [LADDER_CLIMB] Klettert der Spieler gerade an einer Leiter? = Killswitch KS4 UND get_IsLadder.
-- (Boxbreak ist auch KS4, wird aber im Offset-Block VORHER abgefangen + hat kein get_IsLadder.)
-- KS3-Ausstieg oben ist NICHT KS4 -> false -> Defaults. Reine firstperson-Erkennung, kein Hook/Neustart.
local function on_ladder_climb()
    -- [LADDER 2026-07-16] Frueher NUR is_ks4 (Leiter war KS4). Seit die Leiter KS2 sein kann, KS2 ODER KS4
    -- akzeptieren -- sonst gibt die Funktion bei KS2 false zurueck und ladder_now/der Ladder-Offset fallen weg.
    local is_fp = false
    if type(killswitch.is_ks2) == "function" then local o, v = pcall(killswitch.is_ks2); if o and v == true then is_fp = true end end
    if not is_fp and type(killswitch.is_ks4) == "function" then local o, v = pcall(killswitch.is_ks4); if o and v == true then is_fp = true end end
    if not is_fp then return false end
    local ctx = get_player_ctx()
    return ctx and safe(function() return ctx:call("get_IsLadder") end) == true
end

-- [ASHLEY_OFFSET] Laeuft gerade eines der Gimmick-KS3-Events (Stage 53303/53302, GimmickMotionCameraController)?
-- Erkennung ueber den activating_reason des Killswitch (ks3_gimmick) -> eigener HMD-Offset-Satz fuer BEIDE.
local function is_gimmick_ks3_now()
    if type(killswitch.get_activating_controller) ~= "function" then return false end
    local ok, r = pcall(killswitch.get_activating_controller)
    return ok and r == "ks3_gimmick"
end

-- [HEADPIN_FADE 2026-07-15] State fuer das Ausblenden des Head-Nagels. EIN Table statt mehrerer Locals
-- (Datei ist unkritisch bei 48, aber das Muster bleibt sauber). was = lief der Nagel im Vorframe;
-- t = Zeitpunkt des Verlassens; ax/ay/az = der zuletzt im Nagel benutzte Zusatz-Offset (Kart/Grapple/0),
-- damit der Fade von der EXAKT zuletzt gezeigten Pin-Position ausgeht und nicht von einer anderen.
local headpin_fade = { was = false, t = 0.0, ax = 0.0, ay = 0.0, az = 0.0 }

-- ---- Kamera an den Head-Joint klemmen (NUR Position) ----
local function compute_and_set(frame_tick)
    if not active() then
        _G.vr_camera_fix.active = false
        return
    end

    local hj = get_head_joint()
    if not hj then
        _G.vr_camera_fix.active = false
        return
    end

    -- ============================================================
    -- [MINECART] Alle drei Loren-Zustaende: Intro-Einstieg (55201/ActionCam, __re4_minecart_ks4_active),
    -- Intro-Fahrt (55201/VehicleCam, __re4_minecart2_ks4_active) und die echte RailCar-Fahrt
    -- (__re4_railcar_mode). Kamera = Head + statischer Basis-Offset (+ additiver cart_off_*). KEIN
    -- PIN_ANCHOR/bob/surge/Tilt-Offset. PIN: nur die echte Fahrt (railcar) hat den Spine-Pin (Kopf stabil,
    -- macht Cart-Tilt selbst mit); BEIDE Intro-KS laufen OHNE Pin -> Cam folgt dem nativen Cutscene-Head.
    -- Im railcar ruft arm_chain den Pin (Reihenfolge vor IK).
    -- ============================================================
    -- [HEAD-NAGEL 2026-07-15] Cam = Head-Joint + Offset, OHNE bob/surge/Kapsel-Anker/Tilt/Crouch-Lerp.
    -- KERNIDEE: Die Event-HMD-Offsets (Tritt, Leitern, Ashley-Event, Grapple) existierten NUR, weil
    -- in diesen Anims der Body ins Bild schwenkte -- man hat die Kamera per Offset aus dem Body geschoben.
    -- Sitzt die Cam dagegen fest IM Kopf, kann der Body per Definition nicht ins Bild: er haengt immer
    -- dahinter. Damit werden box_off/ladder_off/upladder_off/ashley_off gegenstandslos.
    -- GATE = die BESTEHENDEN Event-Erkennungen, NICHT der Killswitch-Grad: die Offsets verteilen sich auf
    -- KS3 (Ashley-Event) und KS4 (Tritt/Leitern), ein KS2-Gate haette gar nichts davon erwischt.
    -- BEWUSST DRAUSSEN: __re4_fatalkick_active (Fatal/Roundhouse, gewollt ihn unveraendert) und der
    -- Ashley-Crouch (laeuft im Gameplay ganz ohne KS -> acrouch_off bleibt noetig).
    -- Weil dieser Zweig VOR der Offset-Kette unten steht und returnt, sind die alten Offsets automatisch
    -- tot -- nichts geloescht, Rueckweg = Eintrag hier wieder rausnehmen.
    local grappled_now = rawget(_G, "__re4_grappled_active") == true
    local boxbreak_now = rawget(_G, "__re4_boxbreak_active") == true
    local ashley_ev_now = is_gimmick_ks3_now()
    local ladder_now = on_ladder_climb()
    -- [FATALKICK 2026-07-15] Fatal-/Roundhouse-Tritt bekommt den Nagel jetzt auch -> fk_off_* entfernt.
    -- Der Roundhouse dreht Leon um die eigene Achse; genau dabei schwenkte der Body ins Bild, wogegen der
    -- Offset half. Mit Cam IM Kopf erledigt sich das.
    local fatalkick_now = rawget(_G, "__re4_fatalkick_active") == true
    -- [FORCECROUCH 2026-07-15] Erzwungenes Ducken (enger Gang). BLEIBT Gameplay -- kein KS2! Das wuerde alle
    -- Scripte abschalten (kein Movement mehr) und den Wechsel ForceCrouch<->Crouch wieder flackern lassen.
    -- Der Nagel haengt aber nicht am KS-Grad, also bekommt es ihn hier direkt ueber das Killswitch-Flag.
    -- ACHTUNG, anders als die uebrigen Nagel-Zustaende: hier bewegt man sich SELBST -> der Bob-Filter faellt
    -- weg. Wenn das im Gang unangenehm wird, ist es diese Zeile.
    local forcecrouch_now = rawget(_G, "__re4_forcecrouch_active") == true
    -- [GONDEL 2026-07-15] Gondel-Fahrt (KS4: alle Scripte aus, nur First-Person). Nagel wie bei der Lore --
    -- man faehrt nativ mit, die Cam sitzt im Kopf, der Body bleibt dahinter. Weil motion/movement in KS4
    -- gar nicht laufen, arbeitet auch nichts gegen das ParentGimmick -> kein Un-Parenting noetig.
    -- Bekannte Einschraenkung: das Gondel-MESH fuhr im Test nicht mit (wie frueher die "alten Kanonen") --
    -- das liegt am Mesh/an der Transform, nicht hier. Details im Killswitch-Branch 1e2.
    local gondola_now = rawget(_G, "__re4_gondola_active") == true
    -- [JETSKI 2026-07-16] Jetski-Fahr-Stages (592xx, KS4). Wie Gondel/Lore faehrt man nativ mit, die Cam sitzt
    -- im Kopf, der Body bleibt dahinter. Eigener body-relativer Zusatz-Offset (jetski_off_*), justiert wird.
    local jetski_now = rawget(_G, "__re4_jetski_active") == true
    -- [BOAT 2026-07-18] Boot-Fahrt (get_IsBoat, KS4, nicht throwsight). Wie Jetski: nativ mitfahren, Cam im Kopf,
    -- eigener body-relativer Zusatz-Offset (boat_off_*), justiert wird.
    local boat_now = rawget(_G, "__re4_boat_active") == true
    -- [BEGINNING_CROUCH 2026-07-16] ForceCrouch-KS4 (Stages 40501/40502). Eigener body-relativer Offset, justiert wird.
    local begcrouch_now = rawget(_G, "__re4_forcecrouch_ks4_active") == true
    -- [KS2 GENERELL 2026-07-15] KS2 = First-Person + Body sichtbar (nur Head/Hair aus) -- also GENAU die
    -- Konstellation, in der der Body ins Bild schwenken kann. Quelle sind fast nur die ~96 KS2-Zonen aus
    -- re4_vr_killswitch_zones.json (KS2_CAM_STATES ist leer), verteilt ueber das ganze Spiel. Wenn eine
    -- dieser Stellen den Nagel nicht vertraegt (z.B. weil man dort noch laeuft und den ungefilterten
    -- Kopf-Bob spuert): hier ks2_now aus dem headpin_now rausnehmen -> alles wie vorher.
    local ks2_now = false
    if type(killswitch.is_ks2) == "function" then
        local o, v = pcall(killswitch.is_ks2); if o then ks2_now = v == true end
    end
    -- [KS4 GENERELL 2026-07-17, Entscheidung] KS4 bekommt den Nagel jetzt PAUSCHAL -- analog ks2_now.
    -- WARUM: KS4 = First-Person + Body sichtbar (nur Head/Hair aus) -> derselbe Fall wie KS2, der Body kann
    -- ins Bild schwenken. Bisher holte sich JEDER KS4-Fall den Nagel ueber sein EIGENES Flag (Gondel/Jetski/
    -- Kistentritt/BeginCrouch) -- eine per Monitor-Button gesetzte KS4-ZONE hatte deshalb GAR KEINEN Nagel.
    -- Die vier Einzel-Flags bleiben stehen: sie sind jetzt teils redundant, tragen aber ihren eigenen
    -- Offset (jetski_off/begcrouch_off, s. unten) -- ohne sie wuesste die Offset-Kette nicht, welcher Fall laeuft.
    local ks4_now = false
    if type(killswitch.is_ks4) == "function" then
        local o, v = pcall(killswitch.is_ks4); if o then ks4_now = v == true end
    end
    local headpin_now = grappled_now or boxbreak_now or ashley_ev_now or ladder_now or ks2_now
        or fatalkick_now or forcecrouch_now or gondola_now or jetski_now or boat_now or begcrouch_now or ks4_now
    -- [LOREN-VORRANG 2026-07-17] Die Loren sind SELBST KS4 -> mit ks4_now oben rutschen sie ploetzlich in
    -- headpin_now und bekaemen unten 0/0/0 statt cart_off -- der getunte Kart-Sitz waere weg. Darum hier
    -- als eigene Variable und in der Offset-Kette VORRANG (frueher lief das ueber den else-Zweig, der mit
    -- ks4_now nie mehr erreicht wuerde). Reihenfolge unkritisch: KS4-Loren und KS2 schliessen sich aus.
    local cart_now = rawget(_G, "__re4_railcar_mode") == true
        or rawget(_G, "__re4_minecart_ks4_active") == true
        or rawget(_G, "__re4_minecart2_ks4_active") == true
    if cart_now or headpin_now then
        local head = safe(function() return hj:call("get_Position") end)
        if not head then _G.vr_camera_fix.active = false; return end
        local cam_pos = head
        -- Basis-Augenhoehe + ADDITIVER Zusatz. Nur die Loren haben noch einen eigenen Satz (cart_off, der
        -- Kart-Sitz ist getunt und bleibt). Alle Head-Nagel-Events laufen mit 0 = reine Augenhoehe am Kopf --
        -- genau der Sinn der Sache: kein Offset mehr noetig, wenn die Cam IM Kopf sitzt.
        local ax, ay, az
        -- [LOREN-VORRANG 2026-07-17] cart_now ZUERST: die Loren sind selbst KS4 und wuerden sonst seit
        -- ks4_now im 0/0/0-Zweig landen -> Kart-Sitz weg. Ersetzt den frueheren else-Zweig (der mit
        -- pauschalem ks4_now nie mehr erreicht wuerde). Verhalten sonst unveraendert.
        if cart_now then
            ax, ay, az = cfg.cart_off_x, cfg.cart_off_y, cfg.cart_off_z
        -- [LADDER RAUS 2026-07-23] Hier stand ein eigener Leiter-Zweig (cfg.ladder_off_*). Er faellt
        -- weg -> die Leiter landet unten im Figuren-Satz (Ada: ada_box_off, sonst: leon_evt_off), also in
        -- genau derselben Mathe, nur mit EINEM gepflegten Wert. ladder_now bleibt bestehen, es haengt der
        -- Head-Pin und das Rueckblenden (headpin_now) daran.
        elseif jetski_now then
            -- [JETSKI 2026-07-16] Eigener additiver Offset fuer die Jetski-Fahr-Stages (body-relativ). justiert wird.
            ax, ay, az = cfg.jetski_off_x, cfg.jetski_off_y, cfg.jetski_off_z
        elseif boat_now then
            -- [BOAT 2026-07-18] Eigener additiver Offset fuer die Boot-Fahrt (body-relativ, KS4). justiert wird.
            ax, ay, az = cfg.boat_off_x, cfg.boat_off_y, cfg.boat_off_z
        elseif begcrouch_now then
            -- [BEGINNING_CROUCH 2026-07-16] Eigener additiver Offset fuer den ForceCrouch-KS4 (body-relativ). justiert wird.
            ax, ay, az = cfg.begcrouch_off_x, cfg.begcrouch_off_y, cfg.begcrouch_off_z
        elseif forcecrouch_now and is_ada_now() then
            -- [ADA_FORCECROUCH 2026-07-22] Eigener Satz NUR fuer Ada im ForceCrouch. Muss VOR
            -- dem Ada-Universal-Zweig stehen, sonst erbt der enge Gang weiterhin dessen -0.08 auf Z.
            ax, ay, az = cfg.ada_fc_off_x, cfg.ada_fc_off_y, cfg.ada_fc_off_z
        elseif forcecrouch_now then
            -- [LEON_FORCECROUCH 2026-07-23] Leon im normalen ForceCrouch (enger Kriech-Gang).
            -- Das 40501/40502-Durchquetsch-Event ist begcrouch_now und steht als elseif DAVOR -> es
            -- landet nicht hier, ist also ausgenommen. Ada wurde eine Zeile vorher gefangen.
            ax, ay, az = cfg.leon_fc_off_x, cfg.leon_fc_off_y, cfg.leon_fc_off_z
        elseif is_ada_now() then
            -- [ADA UNIVERSAL 2026-07-21, "koennen wir das nicht universal nehmen, hier wuerde
            -- derselbe Offset passen"] Zuerst nur fuer den Fass-/Kistentritt gebaut (Dump 21:29:59
            -- "ks4_boxbreak:20"), dann per Grapple-Dump (22:14:16, "ks2_grappled", Occupied GRAPPLED(16))
            -- bestaetigt: Adas Body (ch3a8z0_body) sitzt in JEDEM dieser Nagel-Events gleich anders als
            -- Leons. Darum gilt der Satz jetzt fuer ALLE Head-Nagel-Zustaende, die keinen EIGENEN Offset
            -- haben -- also Grapple, Fass-/Kistentritt, Fatal-/Roundhouse-Tritt, Ashley-Event, KS2/KS4-Zonen.
            -- NICHT betroffen (haben eigene Werte, stehen als elseif VOR diesem Zweig): Loren, Leiter,
            -- Jetski, Boot, Beginning-Crouch.
            -- Leon faellt unveraendert in den 0/0/0-Zweig -> fuer ihn aendert sich nichts.
            -- Config-Key heisst weiterhin ada_box_* (der eingestellte Wert bleibt so erhalten).
            ax, ay, az = cfg.ada_box_off_x, cfg.ada_box_off_y, cfg.ada_box_off_z
        else
            -- [LEON_EVENTS 2026-07-23] Frueher hart 0/0/0 (reine Augenhoehe am Kopf). Jetzt derselbe
            -- justierbare Satz wie bei Ada, nur eigene Keys -> Leon (und die Ashley-Passagen) koennen
            -- dieselben -0.08 auf Z bekommen. Slider stehen unter dem Ada-Block. 0/0/0 = altes Verhalten.
            ax, ay, az = cfg.leon_evt_off_x, cfg.leon_evt_off_y, cfg.leon_evt_off_z
        end
        -- [HEADPIN_FADE] Trennlinie ist KAMPF vs. RUHE, nicht der KS-Grad:
        -- Rueckblend JA -> KS2-Zonen, Leiter, Fass-/Kistentritt, Ashley-Event. Danach muss man nicht
        -- sofort reagieren, da ist der weiche Uebergang nur schoener.
        -- Rueckblend NEIN -> Grapple (beide Phasen) UND Fatal-/Roundhouse-Tritt. Danach steht man MITTEN
        -- IM KAMPF (beim Roundhouse wartet der naechste Gegner) und braucht die Kamera sofort -- ein
        -- Blend wuerde Reaktionszeit kosten. Der Fass-/Kistentritt ist bewusst NICHT hier: der ist
        -- Umgebungs-Interaktion, kein Kampf.
        -- Loren: KEIN Rueckblend (wie bisher). ACHTUNG 2026-07-17: frueher ergab sich das von selbst, weil
        -- die Loren nicht in headpin_now steckten -- seit ks4_now (KS4 pauschal) tun sie das, denn sie SIND
        -- KS4. Ohne das explizite "not cart_now" haetten sie ab jetzt still einen Blend beim Aussteigen
        -- bekommen. Verhalten also unveraendert, aber die Bedingung muss es jetzt ausdruecklich sagen.
        -- Zusatz-Offset mitmerken -> der Ausblend startet exakt an der zuletzt gezeigten Pin-Position.
        if headpin_now and not grappled_now and not fatalkick_now and not cart_now then
            headpin_fade.was = true
            headpin_fade.ax, headpin_fade.ay, headpin_fade.az = ax, ay, az
        else
            headpin_fade.was = false
        end
        local ox = cfg.off_x + ax
        local oy = cfg.off_y + ay
        local oz = cfg.off_z + az
        if ox ~= 0 or oy ~= 0 or oz ~= 0 then
            local btf = get_body_transform()
            local rr = btf and safe(function() return btf:call("get_Rotation") end)
            if rr then
                local fwd   = rr * Vector3f.new(0, 0, 1)
                local right = rr * Vector3f.new(1, 0, 0)
                cam_pos = Vector3f.new(
                    head.x + right.x * ox + fwd.x * oz,
                    head.y + oy,
                    head.z + right.z * ox + fwd.z * oz)
            end
        end
        local cj = get_camera_joint()
        if not cj then return end
        pcall(function() cj:call("set_Position", cam_pos) end)
        -- [HAND-ROLL FIX] railcar-Kamera = VehicleCameraController -> get_game_cam_yaw nil. Fallback auf den
        -- flachen primary-cam-Yaw (statt active=false) -> motion nutzt einen ROLLFREIEN Yaw fuer die Hand-Basis
        -- statt der rollenden Rohkamera -> Waffe/Hand rollt nicht mehr mit dem Cart.
        local yaw = get_game_cam_yaw() or get_primary_cam_flat_yaw()
        if yaw then
            _G.vr_camera_fix.camera_pos = cam_pos
            _G.vr_camera_fix.camera_rot = yaw
            _G.vr_camera_fix.active = true
        else
            _G.vr_camera_fix.active = false
        end
        return
    end

    -- [HEADPIN_FADE] Kante: Der Nagel lief im Vorframe, jetzt nicht mehr -> Ausblend-Fenster oeffnen.
    -- Ab hier laeuft die normale Kette (Bob/Kapsel/Crouch-Lerp) weiter; ganz unten, kurz vor set_Position,
    -- wird ihr Ergebnis mit der Pin-Position gemischt, bis das Fenster zu ist.
    if headpin_fade.was then
        headpin_fade.was = false
        headpin_fade.t = os.clock()
    end

    local hp = safe(function() return hj:call("get_Position") end)
    if not hp then return end

    -- [PIN_ANCHOR] Pin-Modus (movement setzt __vr_surge_bridged): Kamera
    -- ankert auf der KAPSEL-ACHSE statt am Head — der gepinnte Head sitzt
    -- vor der Drehachse, beim 1:1-Drehen kreist sonst der Anker um den
    -- Body (Welt schiebt beim Kopfdrehen seitlich = "fuerchterlich").
    -- Hoehe bleibt vom Head (gepinnt+CAPY = stabil), XZ = Kapsel
    -- (drehinvariant; Surge-Glaettung legt der Filter unten drauf).
    if _G.__vr_surge_bridged == true then
        local btf0 = get_body_transform()
        local bp0 = btf0 and safe(function() return btf0:call("get_Position") end)
        if bp0 then hp = Vector3f.new(bp0.x, hp.y, bp0.z) end
    end

    hp = apply_bob_filter(hp, frame_tick)
    do
        local btf = get_body_transform()
        local bp = btf and safe(function() return btf:call("get_Position") end)
        hp = apply_surge_filter(hp, bp, frame_tick)
    end

    local cam_pos = hp
    -- [OFFSET-KETTE 2026-07-15] Nur noch EIN Sonderfall. Boxbreak (Tritt), Fatal-/Roundhouse-Tritt,
    -- Ashley-Event (Gimmick-KS3) und beide Leitern sind hier RAUS: die laufen jetzt oben ueber den
    -- Head-Nagel (Cam im Kopf, Body kann nicht ins Bild) und erreichen diese Kette gar nicht mehr --
    -- ihre Offsets waren damit gegenstandslos und wurden samt JSON-Keys entfernt.
    local ox, oy, oz = cfg.off_x, cfg.off_y, cfg.off_z
    if is_crouch_now() and is_ashley_now() then
        -- [ASHLEY_CROUCH HMD 2026-07-12] NUR Ashley (ch0a1z0_body) im Crouch: eigener HMD-Offset-Satz
        -- (absolut, ersetzt off_x/y/z). Ashley-Stand unberuehrt. Laeuft im GAMEPLAY ohne Killswitch ->
        -- kein Head-Nagel -> bleibt noetig.
        ox, oy, oz = cfg.acrouch_off_x, cfg.acrouch_off_y, cfg.acrouch_off_z
        -- [LEON_CROUCH ENTFERNT 2026-07-12] Leon im Crouch nutzt wieder die Basis-Offsets (off_x/y/z = Default).
    end
    if ox ~= 0 or oy ~= 0 or oz ~= 0 then
        local btf = get_body_transform()
        local rr = btf and safe(function() return btf:call("get_Rotation") end)
        if rr then
            local fwd   = rr * Vector3f.new(0, 0, 1)
            local right = rr * Vector3f.new(1, 0, 0)
            cam_pos = Vector3f.new(
                hp.x + right.x * ox + fwd.x * oz,
                hp.y + oy,
                hp.z + right.z * ox + fwd.z * oz)
        end
    end

    -- Stand->Crouch: Absacken der Kamera-Hoehe weich lerpen (nur abwaerts).
    cam_pos = Vector3f.new(cam_pos.x, apply_crouch_cam_lerp(cam_pos.y, frame_tick), cam_pos.z)

    -- [HEADPIN_FADE 2026-07-15] Nach dem Verlassen des Head-Nagels ueber headpin_fade_dur von der
    -- Pin-Position in die normale (bob-gefilterte/kapsel-verankerte) Kamera blenden, statt zu snappen.
    -- Die Pin-Position wird JEDEN Frame neu gerechnet (Head folgt ja weiter) -- eine gemerkte Weltposition
    -- wuerde veralten, sobald sich der Spieler bewegt. ax/ay/az = der Zusatz-Offset, den der Nagel zuletzt
    -- benutzt hat -> der Blend startet exakt dort, wo das Bild gerade stand. dur=0 -> Slider aus, hart.
    if headpin_fade.t > 0.0 then
        local dur = tonumber(cfg.headpin_fade_dur) or 0.0
        local el = os.clock() - headpin_fade.t
        if dur <= 0.001 or el >= dur then
            headpin_fade.t = 0.0
        else
            local pin = Vector3f.new(hp.x, hp.y, hp.z)
            local px = cfg.off_x + headpin_fade.ax
            local py = cfg.off_y + headpin_fade.ay
            local pz = cfg.off_z + headpin_fade.az
            if px ~= 0 or py ~= 0 or pz ~= 0 then
                local btf2 = get_body_transform()
                local rr2 = btf2 and safe(function() return btf2:call("get_Rotation") end)
                if rr2 then
                    local fwd2   = rr2 * Vector3f.new(0, 0, 1)
                    local right2 = rr2 * Vector3f.new(1, 0, 0)
                    pin = Vector3f.new(
                        hp.x + right2.x * px + fwd2.x * pz,
                        hp.y + py,
                        hp.z + right2.z * px + fwd2.z * pz)
                end
            end
            local f = el / dur                       -- 0 = noch Pin, 1 = ganz normale Kamera
            cam_pos = Vector3f.new(
                pin.x + (cam_pos.x - pin.x) * f,
                pin.y + (cam_pos.y - pin.y) * f,
                pin.z + (cam_pos.z - pin.z) * f)
        end
    end

    local cj = get_camera_joint()
    if not cj then return end
    pcall(function() cj:call("set_Position", cam_pos) end)

    -- Basis fuer Motion exportieren (ohne HMD-Offset, wie dev-Pipeline)
    local yaw = get_game_cam_yaw()
    if yaw then
        _G.vr_camera_fix.camera_pos = cam_pos
        _G.vr_camera_fix.camera_rot = yaw
        _G.vr_camera_fix.active = true
    else
        _G.vr_camera_fix.active = false
    end
end

-- ---- Movement follows HMD (Port aus dem alten Script, ohne EMA) ----
local gamepad_td = sdk.find_type_definition("via.hid.GamePad")

local function get_left_input_axis()
    if vrmod and vrmod.is_using_controllers and vrmod:is_using_controllers() then
        local axis = vrmod:get_left_stick_axis()
        if axis and axis:length() > 0.0 then return axis end
    end
    local gp = sdk.get_native_singleton("via.hid.GamePad")
    if not gp or not gamepad_td then return Vector2f.new(0, 0) end
    local pad = safe(function() return sdk.call_native_func(gp, gamepad_td, "get_LastInputDevice") end)
    if not pad then return Vector2f.new(0, 0) end
    return safe(function() return pad:call("get_AxisL") end) or Vector2f.new(0, 0)
end

local move_state = {
    has_valid_position = false,
    last_player_position = nil,
    last_time = nil,
}

local function apply_movement_stabilization()
    if not cfg.movement_stabilization then
        move_state.has_valid_position = false
        return
    end
    -- [GAMEPLAY_ONLY 2026-07-11] Der Stick-set_Position unten (zweiter Bewegungspfad neben dem
    -- Gamepad-Movement) darf NUR in reinem Gameplay laufen. Bei JEDEM Killswitch (Gimmick/AutoMove/
    -- Leiter/Vault/Kick/Throwsight/Damage/...) ist die Char-Bewegung nativ animiert (fest) — der
    -- Stick wuerde den Body aus der Animation ziehen -> Kamera loest sich vom Char, man clippt/haut
    -- ab (nativ unmoeglich). Frueher nur KS4+Throwsight gegated -> KS1/2/3 leckten diesen Pfad.
    -- Klettern/Leiter laeuft ueber das native Gamepad (ViGEm LY), NICHT ueber diesen set_Position ->
    -- bleibt unberuehrt. ==== REVERT: zurueck auf das alte ks4_now/throwsight-Gate. ====
    local ks_now = safe(function() return killswitch.is_active() end) == true
    if ks_now or rawget(_G, "__re4_throwsight_active") == true then
        move_state.has_valid_position = false
        move_state.last_time = nil
        return
    end
    if not active() then
        move_state.has_valid_position = false
        move_state.last_time = nil
        return
    end

    local body_tr = get_body_transform()
    if not body_tr then
        move_state.has_valid_position = false
        return
    end
    local cam_joint = get_camera_joint()
    if not cam_joint then return end

    local now = os.clock()
    if not move_state.last_time then move_state.last_time = now end
    local dt = now - move_state.last_time
    move_state.last_time = now
    if dt < 0.001 then dt = 0.001 end
    if dt > 0.1 then dt = 0.1 end

    local cur = safe(function() return body_tr:call("get_Position") end)
    if not cur then return end

    if move_state.has_valid_position and move_state.last_player_position then
        local delta = cur - move_state.last_player_position
        delta.y = 0.0
        local speed = delta:length()
        speed = math.min(speed, 1.0)

        local camera_rot = safe(function() return cam_joint:call("get_Rotation") end)
        if camera_rot then
            -- HMD-Yaw auf die Bewegungsrichtung draufrechnen
            if cfg.movement_follows_hmd and vrmod then
                local t0 = safe(function() return vrmod:get_transform(0) end)
                local hmd_quat = t0 and safe(function() return t0:to_quat() end)
                if hmd_quat and hmd_quat.w then
                    local rot_offset = safe(function() return vrmod:get_rotation_offset() end)
                    if rot_offset then
                        local combined = rot_offset * hmd_quat
                        local siny = 2.0 * (combined.w * combined.y + combined.z * combined.x)
                        local cosy = 1.0 - 2.0 * (combined.y * combined.y + combined.x * combined.x)
                        local hmd_yaw = math.atan(siny, cosy)
                        local half = hmd_yaw * 0.5
                        local hmd_flat = Quaternion.new(math.cos(half), 0, math.sin(half), 0)
                        camera_rot = camera_rot * hmd_flat
                    end
                end
            end

            local camera_dir = camera_rot * Vector3f.new(0, 0, 1)
            local axis_l = get_left_input_axis()
            if axis_l:length() > 0.0 then
                local flat_camera_dir = Vector3f.new(camera_dir.x, 0.0, camera_dir.z):normalized()
                local flat_camera_rot = flat_camera_dir:to_quat()
                local axis_l_dir = (flat_camera_rot * Vector3f.new(axis_l.x, 0.0, -axis_l.y)):normalized()
                if axis_l_dir:length() > 0.0 then
                    local new_pos = move_state.last_player_position + (axis_l_dir * speed)
                    new_pos.y = cur.y
                    pcall(function() body_tr:call("set_Position", new_pos) end)
                end
            end
        end
    end

    move_state.last_player_position = safe(function() return body_tr:call("get_Position") end)
    move_state.has_valid_position = true
end

-- ============================================================
-- [RECENTER] (aus re4_vr_recenter.lua hierher gezogen, sinngemaess)
-- Bei JEDEM Killswitch-Eintritt EINMAL den Headset-Yaw neutralisieren: Offset =
-- -aktueller_HMD_Yaw -> die native (Killswitch-)Kamera zeigt exakt so wie das Spiel
-- sie setzt, egal wie verdreht man physisch steht. __vr_recenter_hold haelt den
-- Offset waehrend des Killswitch (sonst wischt movement.lua ihn per-Frame auf 0);
-- beim Austritt Hold los -> movement uebernimmt wieder normal (kein Restore noetig).
-- Laeuft fuer ALLE Killswitch-Stufen (is_active), nicht nur First-Person.
-- ============================================================
local function rc_yaw_of_quat(q)
    if not q then return nil end
    local f = q * Vector3f.new(0, 0, 1)
    local len = math.sqrt(f.x * f.x + f.z * f.z)
    if len < 1e-4 then return nil end
    return math.atan(f.x / len, f.z / len)
end
local function rc_yaw_quat(y)
    local h = y * 0.5
    return Quaternion.new(math.cos(h), 0.0, math.sin(h), 0.0)
end
local function recenter_neutralize_headset()
    if not vrmod then return false end
    local hq = safe(function() return vrmod:get_transform(0):to_quat() end)
    local h  = hq and rc_yaw_of_quat(hq)
    if not h then return false end
    pcall(function() vrmod:set_rotation_offset(rc_yaw_quat(-h)) end)
    return true
end

local rc_was_active = false
local function recenter_tick()
    if not cfg.recenter_on_killswitch then
        if rc_was_active then _G.__vr_recenter_hold = false; rc_was_active = false end
        return
    end
    if not (vrmod and vrmod:is_hmd_active()) then return end
    local ks = safe(function() return killswitch.is_active() end) == true
    if ks and not rc_was_active then
        recenter_neutralize_headset()
        _G.__vr_recenter_hold = true
    elseif (not ks) and rc_was_active then
        _G.__vr_recenter_hold = false
    end
    rc_was_active = ks
end

-- ---- Hooks ----
-- ============================================================
-- [GIMMICKFIX_EVENT HMD-OFFSET] Eigener HMD-Offset in WELT-Koordinaten NUR fuer EIN Event: die festgesetzte
-- GimmickFix-Kamera in Stage 51503 an fixer Position (KS1, firstperson AUS -> native Kamera). Wir verschieben
-- die PRIMARY CAMERA direkt per set_position (abgeschaut vom Binocular-Zoom in re4_vr_binding.lua), aber
-- WORLD-space (kein Body-, kein Blickrichtungs-Bezug). Gate = Stage + GimmickFixCameraController + Radius,
-- damit NUR dieses Event getroffen wird. cfg.event_off_* = 0/0/0 -> No-op. Tuning per Slider unten.
-- ============================================================
local function apply_event_hmd_offset()
    if cfg.event_off_x == 0 and cfg.event_off_y == 0 and cfg.event_off_z == 0 then return end
    local ctx = get_player_ctx(); if not ctx then return end
    local stage = fp_stage_cached()   -- [PERF] 1x pro Frame
    if stage ~= 51503 and stage ~= 51502 then return end
    local busy = fp_busy_cached()   -- [PERF] 1x pro Frame
    if not busy then return end
    if gimmickfix_cam_td == nil or safe(function() return busy:get_type_definition():is_a(gimmickfix_cam_td) end) ~= true then
        return
    end
    local btf = get_body_transform(); local bp = btf and safe(function() return btf:call("get_Position") end)
    if not bp then return end
    local dx, dy, dz = bp.x + 8.61, bp.y - 26.87, bp.z + 43.75   -- Distanz zur Event-Position (-8.61/26.87/-43.75)
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > 25.0 then
        return
    end
    -- WORLD-Offset direkt auf die primary camera (wie Binocular-Zoom, aber ohne Blickrichtung)
    local cam = sdk.get_primary_camera(); if not cam then return end
    local cgo = safe(function() return cam:call("get_GameObject") end); if not cgo then return end
    local ctf = safe(function() return cgo:call("get_Transform") end); if not ctf then return end
    local p = safe(function() return ctf:get_position() end); if not p then return end
    pcall(function() ctf:set_position(Vector4f.new(
        p.x + cfg.event_off_x, p.y + cfg.event_off_y, p.z + cfg.event_off_z, p.w), true) end)
end

-- ============================================================
-- [POWER-RIDDLE HMD-OFFSET] Zweites GimmickFix-Kamera-Event, gebaut wie Stone-Riddle oben (Welt-Koordinaten
-- per set_position auf die primary camera). Gate = dieselben DREI UND-Bedingungen, nur andere Werte:
-- (1) Stage == 61400 (Monitor-Dump 2026-07-15 22:43:24, Feld "Stage" = get_CurrentStageID)
-- (2) BusyCameraController = GimmickFixCameraController (Dump: KS1 (voll) [chainsaw.GimmickFixCameraController])
-- (3) Body < 5m von 115.55/18.50/-93.56 (Dump-Feld "Map")
-- Bewusst eine EIGENE Funktion statt die Stone-Riddle zu parametrisieren: die laeuft und wird nicht angefasst.
-- Falls das Gate nicht greift: haeufigster Grund ist eine flackernde Stage (die Stone-Riddle brauchte
-- deshalb 51503 ODER 51502) -> dann hier den Nachbarwert danebenstellen.
-- ============================================================
local function apply_event2_hmd_offset()
    if cfg.event2_off_x == 0 and cfg.event2_off_y == 0 and cfg.event2_off_z == 0 then return end
    local ctx = get_player_ctx(); if not ctx then return end
    local stage = fp_stage_cached()   -- [PERF] 1x pro Frame
    if stage ~= 61400 then return end
    local busy = fp_busy_cached()   -- [PERF] 1x pro Frame
    if not busy then return end
    if gimmickfix_cam_td == nil or safe(function() return busy:get_type_definition():is_a(gimmickfix_cam_td) end) ~= true then return end
    local btf = get_body_transform(); local bp = btf and safe(function() return btf:call("get_Position") end)
    if not bp then return end
    local dx, dy, dz = bp.x - 115.55, bp.y - 18.50, bp.z + 93.56   -- Distanz zur Event-Position (115.55/18.50/-93.56)
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > 25.0 then return end                                    -- Radius 5m, wie Stone-Riddle
    local cam = sdk.get_primary_camera(); if not cam then return end
    local cgo = safe(function() return cam:call("get_GameObject") end); if not cgo then return end
    local ctf = safe(function() return cgo:call("get_Transform") end); if not ctf then return end
    local p = safe(function() return ctf:get_position() end); if not p then return end
    pcall(function() ctf:set_position(Vector4f.new(
        p.x + cfg.event2_off_x, p.y + cfg.event2_off_y, p.z + cfg.event2_off_z, p.w), true) end)
end

-- ============================================================
-- [POWER-RIDDLE2 HMD-OFFSET] Drittes GimmickFix-Kamera-Event, gebaut wie die zwei oben. Gate = dieselben
-- DREI UND-Bedingungen, nur andere Werte:
-- (1) Stage == 61305 (Monitor-Dump 2026-07-15 23:05:10, Feld "Stage" = get_CurrentStageID)
-- (2) BusyCameraController = GimmickFixCameraController (Dump: KS1 (voll) [chainsaw.GimmickFixCameraController])
-- (3) Body < 5m von 90.83/18.50/-91.04 (Dump-Feld "Map")
-- Wieder eine eigene Funktion statt Parametrisierung: Stone-Riddle + Power-Riddle laufen und bleiben unberuehrt.
-- Falls das Gate nicht greift: haeufigster Grund ist eine flackernde Stage (Stone-Riddle braucht deshalb
-- 51503 ODER 51502) -> dann hier den Nachbarwert danebenstellen.
-- ============================================================
local function apply_event3_hmd_offset()
    if cfg.event3_off_x == 0 and cfg.event3_off_y == 0 and cfg.event3_off_z == 0 then return end
    local ctx = get_player_ctx(); if not ctx then return end
    local stage = fp_stage_cached()   -- [PERF] 1x pro Frame
    if stage ~= 61305 then return end
    local busy = fp_busy_cached()   -- [PERF] 1x pro Frame
    if not busy then return end
    if gimmickfix_cam_td == nil or safe(function() return busy:get_type_definition():is_a(gimmickfix_cam_td) end) ~= true then return end
    local btf = get_body_transform(); local bp = btf and safe(function() return btf:call("get_Position") end)
    if not bp then return end
    local dx, dy, dz = bp.x - 90.83, bp.y - 18.50, bp.z + 91.04    -- Distanz zur Event-Position (90.83/18.50/-91.04)
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > 25.0 then return end                                    -- Radius 5m, wie die anderen beiden
    local cam = sdk.get_primary_camera(); if not cam then return end
    local cgo = safe(function() return cam:call("get_GameObject") end); if not cgo then return end
    local ctf = safe(function() return cgo:call("get_Transform") end); if not ctf then return end
    local p = safe(function() return ctf:get_position() end); if not p then return end
    pcall(function() ctf:set_position(Vector4f.new(
        p.x + cfg.event3_off_x, p.y + cfg.event3_off_y, p.z + cfg.event3_off_z, p.w), true) end)
end

-- ============================================================
-- [DUMPSTER-RIDDLE HMD-OFFSET] Viertes GimmickFix-Kamera-Event, gebaut wie die drei oben. Gate = dieselben
-- DREI UND-Bedingungen, nur andere Werte:
-- (1) Stage == 63108 (Monitor-Dump 2026-07-16 00:30:04, Feld "Stage" = get_CurrentStageID)
-- (2) BusyCameraController = GimmickFixCameraController (Dump: KS1 (voll) [chainsaw.GimmickFixCameraController])
-- (3) Body < 5m von -13.89/21.77/-122.40 (Dump-Feld "Map")
-- Wieder eigene Funktion statt Parametrisierung: die drei anderen laufen und bleiben unberuehrt.
-- Falls das Gate nicht greift: haeufigster Grund ist eine flackernde Stage (Stone-Riddle braucht deshalb
-- 51503 ODER 51502) -> dann hier den Nachbarwert danebenstellen.
-- ============================================================
local function apply_event4_hmd_offset()
    if cfg.event4_off_x == 0 and cfg.event4_off_y == 0 and cfg.event4_off_z == 0 then return end
    local ctx = get_player_ctx(); if not ctx then return end
    local stage = fp_stage_cached()   -- [PERF] 1x pro Frame
    if stage ~= 63108 then return end
    local busy = fp_busy_cached()   -- [PERF] 1x pro Frame
    if not busy then return end
    if gimmickfix_cam_td == nil or safe(function() return busy:get_type_definition():is_a(gimmickfix_cam_td) end) ~= true then return end
    local btf = get_body_transform(); local bp = btf and safe(function() return btf:call("get_Position") end)
    if not bp then return end
    local dx, dy, dz = bp.x + 13.89, bp.y - 21.77, bp.z + 122.40   -- Distanz zur Event-Position (-13.89/21.77/-122.40)
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > 25.0 then return end                                    -- Radius 5m, wie die anderen drei
    local cam = sdk.get_primary_camera(); if not cam then return end
    local cgo = safe(function() return cam:call("get_GameObject") end); if not cgo then return end
    local ctf = safe(function() return cgo:call("get_Transform") end); if not ctf then return end
    local p = safe(function() return ctf:get_position() end); if not p then return end
    pcall(function() ctf:set_position(Vector4f.new(
        p.x + cfg.event4_off_x, p.y + cfg.event4_off_y, p.z + cfg.event4_off_z, p.w), true) end)
end

-- ============================================================
-- [SYMBOL-RIDDLE HMD-OFFSET 2026-07-17] Fuenftes GimmickFix-Kamera-Event, gebaut wie die vier oben. Gate =
-- dieselben DREI UND-Bedingungen, nur andere Werte:
-- (1) Stage == 44110 (Monitor-Dump 2026-07-17 22:43:48, Feld "Stage" = get_CurrentStageID)
-- (2) BusyCameraController = GimmickFixCameraController (Dump: KS1 (voll) [chainsaw.GimmickFixCameraController])
-- (3) Body < 2m von 10.75/12.87/107.76 (obere Etage = ECHTE Symbol-Riddle; Radius 2m schliesst die 2. GimmickFix eine Etage
-- tiefer bei 10.81/8.88/109.02 aus, ~4.2m entfernt -- die feuerte mit dem alten 5m-Radius faelschlich mit)
-- Wieder eigene Funktion statt Parametrisierung: die vier anderen laufen und bleiben unberuehrt.
-- Falls das Gate nicht greift: haeufigster Grund ist eine flackernde Stage (Stone-Riddle braucht deshalb
-- 51503 ODER 51502) -> dann hier den Nachbarwert danebenstellen.
-- ============================================================
local function apply_event5_hmd_offset()
    if cfg.event5_off_x == 0 and cfg.event5_off_y == 0 and cfg.event5_off_z == 0 then return end
    local ctx = get_player_ctx(); if not ctx then return end
    local stage = fp_stage_cached()   -- [PERF] 1x pro Frame
    if stage ~= 44110 then return end
    local busy = fp_busy_cached()   -- [PERF] 1x pro Frame
    if not busy then return end
    if gimmickfix_cam_td == nil or safe(function() return busy:get_type_definition():is_a(gimmickfix_cam_td) end) ~= true then return end
    local btf = get_body_transform(); local bp = btf and safe(function() return btf:call("get_Position") end)
    if not bp then return end
    local dx, dy, dz = bp.x - 10.75, bp.y - 12.87, bp.z - 107.76   -- Distanz zur ECHTEN Riddle-Position (10.75/12.87/107.76, obere Etage)
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > 4.0 then return end                                     -- Radius 2m ( 2026-07-23): schliesst die 2. GimmickFix EINE ETAGE TIEFER (10.81/8.88/109.02, ~4.2m weg) aus. Radius MUSS < ~4m bleiben, sonst greift die untere wieder.
    local cam = sdk.get_primary_camera(); if not cam then return end
    local cgo = safe(function() return cam:call("get_GameObject") end); if not cgo then return end
    local ctf = safe(function() return cgo:call("get_Transform") end); if not ctf then return end
    local p = safe(function() return ctf:get_position() end); if not p then return end
    pcall(function() ctf:set_position(Vector4f.new(
        p.x + cfg.event5_off_x, p.y + cfg.event5_off_y, p.z + cfg.event5_off_z, p.w), true) end)
end

-- ============================================================
-- [CHURCH-RIDDLE HMD-OFFSET 2026-07-18] Sechstes GimmickFix-Kamera-Event, gebaut wie die fuenf oben. Gate =
-- dieselben DREI UND-Bedingungen, nur andere Werte:
-- (1) Stage == 45401 (Monitor-Dump 2026-07-18 02:43:02, Feld "Stage" = get_CurrentStageID)
-- (2) BusyCameraController = GimmickFixCameraController (Dump: KS1 (voll) [chainsaw.GimmickFixCameraController])
-- (3) Body < 5m von 106.80/11.63/100.55 (Dump-Feld "Map")
-- Eigene Funktion statt Parametrisierung: die fuenf anderen laufen und bleiben unberuehrt.
-- ============================================================
-- [SYMBOL-RIDDLE MONO 2026-08-15] Mono-Rendering waehrend genau dieses Events -- beide Augen
-- bekommen dasselbe Bild, wie beim Zielen durch ein montiertes Scope.
-- BEWUSST eine eigene Funktion mit demselben Gate wie `apply_event5_hmd_offset`, statt dort
-- hineinzuschreiben: die laeuft und wird nicht angefasst (so wie schon die fuenf Riddles
-- untereinander dupliziert sind). Der Unterschied zum Offset-Zweig ist wichtig -- der steigt
-- bei 0/0/0 sofort aus, Mono soll aber auch ohne eingestellten Offset zuenden.
-- Geschaltet wird NUR ueber den Broker in re4_vr_scope.lua (`__re4_mono_request`): solange
-- irgendein Anforderer true hat, ist Mono an. Direkt `set_mono_rendering` zu rufen waere die
-- bekannte Doppelregler-Falle -- Scope und Riddle wuerden sich den Zustand wegnehmen.
-- Faellt das Gate weg (andere Stage, andere Kamera, zu weit weg, Schalter aus), meldet die
-- Funktion im selben Durchlauf `false` -- sie darf deshalb NICHT vorzeitig zurueckkehren.
-- ============================================================
local function apply_event5_mono()
    local req = rawget(_G, "__re4_mono_request")
    if type(req) ~= "function" then return end   -- Scope-Script nicht geladen -> kein Broker

    local on = false
    if cfg.event5_mono then
        local ctx = get_player_ctx()
        local stage = ctx and safe(function() return ctx:call("get_CurrentStageID") end)
        if stage == 44110 then
            if not camera_system then camera_system = sdk.get_managed_singleton("chainsaw.CameraSystem") end
            local main = camera_system and safe(function() return camera_system:call("get_MainCameraController") end)
            local busy = main and safe(function() return main:call("get_BusyCameraController") end)
            if busy and gimmickfix_cam_td ~= nil
                and safe(function() return busy:get_type_definition():is_a(gimmickfix_cam_td) end) == true then
                local btf = get_body_transform()
                local bp = btf and safe(function() return btf:call("get_Position") end)
                if bp then
                    -- Dieselbe Position und derselbe 2-m-Radius wie beim Offset: der schliesst
                    -- die zweite GimmickFix-Kamera eine Etage tiefer (~4.2 m weg) aus.
                    local dx, dy, dz = bp.x - 10.75, bp.y - 12.87, bp.z - 107.76
                    on = (dx * dx + dy * dy + dz * dz) <= 4.0
                end
            end
        end
    end

    req("symbol_riddle", on)
end

-- ============================================================
local function apply_event6_hmd_offset()
    if cfg.event6_off_x == 0 and cfg.event6_off_y == 0 and cfg.event6_off_z == 0 then return end
    local ctx = get_player_ctx(); if not ctx then return end
    local stage = fp_stage_cached()   -- [PERF] 1x pro Frame
    if stage ~= 45401 then return end
    local busy = fp_busy_cached()   -- [PERF] 1x pro Frame
    if not busy then return end
    if gimmickfix_cam_td == nil or safe(function() return busy:get_type_definition():is_a(gimmickfix_cam_td) end) ~= true then return end
    local btf = get_body_transform(); local bp = btf and safe(function() return btf:call("get_Position") end)
    if not bp then return end
    local dx, dy, dz = bp.x - 106.80, bp.y - 11.63, bp.z - 100.55   -- Distanz zur Event-Position (106.80/11.63/100.55)
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > 25.0 then return end                                    -- Radius 5m, wie die anderen fuenf
    local cam = sdk.get_primary_camera(); if not cam then return end
    local cgo = safe(function() return cam:call("get_GameObject") end); if not cgo then return end
    local ctf = safe(function() return cgo:call("get_Transform") end); if not ctf then return end
    local p = safe(function() return ctf:get_position() end); if not p then return end
    pcall(function() ctf:set_position(Vector4f.new(
        p.x + cfg.event6_off_x, p.y + cfg.event6_off_y, p.z + cfg.event6_off_z, p.w), true) end)
end

-- [TURRET HMD-OFFSET 2026-07-16] Eigener Welt-Offset fuer die MG-Turret. Technik wie die Riddle-Offsets
-- (World-space set_position auf die primary camera, in allen vier Paessen). Gate ist aber EINFACHER: nur
-- GimmickType == InstalledMachineGun aus dem Busy-Kamera-StateParam -- der Gimmick-Typ IST das eindeutige
-- Signal, kein Stage/GimmickFix/Body-Radius noetig. cfg.turret_off_* = 0/0/0 -> No-op. Slider unten.
local function apply_turret_hmd_offset()
    if cfg.turret_off_x == 0 and cfg.turret_off_y == 0 and cfg.turret_off_z == 0 then return end
    local busy = fp_busy_cached()   -- [PERF] 1x pro Frame
    if not busy then return end
    local sp = safe(function() return busy:get_field("_CurrentStateParam") end)
    if not sp then return end
    local gt = safe(function() return sp:get_field("<GimmickType>k__BackingField") end)
    if type(gt) ~= "number" then gt = gt and safe(function() return gt:get_field("value__") end) end
    if gt ~= TURRET_GIMMICK then return end
    local cam = sdk.get_primary_camera(); if not cam then return end
    local cgo = safe(function() return cam:call("get_GameObject") end); if not cgo then return end
    local ctf = safe(function() return cgo:call("get_Transform") end); if not ctf then return end
    local p = safe(function() return ctf:get_position() end); if not p then return end
    pcall(function() ctf:set_position(Vector4f.new(
        p.x + cfg.turret_off_x, p.y + cfg.turret_off_y, p.z + cfg.turret_off_z, p.w), true) end)
end

-- Multi-Hook-Stack ist Pflicht: Engine schreibt das Kamera-Joint zwischen den
-- Phasen zurueck, mit nur 1 Hook bleibt die Kamera "unveraendert".
re.on_pre_application_entry("LockScene", function()
    -- [RECENTER] Killswitch-Eintritt/Austritt vor allem anderen auswerten
    pcall(recenter_tick)
    -- Movement: Frame-Basis VOR der Engine-Bewegung setzen
    if cfg.movement_stabilization and active() then
        local body_tr = get_body_transform()
        if body_tr then
            local p = safe(function() return body_tr:call("get_Position") end)
            if p then
                move_state.last_player_position = p
                move_state.has_valid_position = true
            end
        end
    end
    compute_and_set(true)   -- frame_tick: Bob-Filter-EMA 1x pro Game-Frame
    apply_event_hmd_offset(); apply_event2_hmd_offset(); apply_event3_hmd_offset(); apply_event4_hmd_offset(); apply_event5_hmd_offset(); apply_event6_hmd_offset(); apply_turret_hmd_offset()
    -- [SYMBOL-RIDDLE MONO 2026-08-15] Nur HIER, einmal pro Game-Frame -- Mono ist ein
    -- Zustand, kein Positions-Write, und braucht die drei Render-Passes unten nicht.
    apply_event5_mono()
end)
re.on_pre_application_entry("UnlockScene", function() compute_and_set(false); apply_event_hmd_offset(); apply_event2_hmd_offset(); apply_event3_hmd_offset(); apply_event4_hmd_offset(); apply_event5_hmd_offset(); apply_event6_hmd_offset(); apply_turret_hmd_offset() end)
re.on_application_entry("LateUpdateBehavior", function() compute_and_set(false); apply_event_hmd_offset(); apply_event2_hmd_offset(); apply_event3_hmd_offset(); apply_event4_hmd_offset(); apply_event5_hmd_offset(); apply_event6_hmd_offset(); apply_turret_hmd_offset() end)
re.on_application_entry("BeginRendering", function() compute_and_set(false); apply_event_hmd_offset(); apply_event2_hmd_offset(); apply_event3_hmd_offset(); apply_event4_hmd_offset(); apply_event5_hmd_offset(); apply_event6_hmd_offset(); apply_turret_hmd_offset() end)

-- Movement einmal pro Frame, nach der Engine-Bewegung
re.on_application_entry("UpdateMotion", apply_movement_stabilization)

-- ========================= StreamingDummy-Hider (pinker Cube) =========================
-- HOOK-FREI: holt alle chainsaw.StreamingDummyController aus der Szene (via.Scene.findComponents)
-- und schaltet das Mesh-Rendering ihres GameObjects aus (set_DrawDefault(false)). Der
-- Controller laeuft weiter -> Level-Streaming bleibt intakt; nur der pinke Cube ist weg.
-- Greift mit Reset Scripts (kein sdk.hook). Periodischer Re-Scan faengt neue Dummies nach
-- Level-Load/Save; gecachte Meshes werden jede Frame still gehalten (Engine re-aktiviert sonst).
local sd = {
    scene_td = sdk.find_type_definition("via.SceneManager"),
    ctrl_t   = sdk.typeof("chainsaw.StreamingDummyController"),
    mesh_t   = sdk.typeof("via.render.Mesh"),
    skin_t   = sdk.typeof("via.render.SkinnedMesh"),
    cache    = {},     -- gefundene Mesh-Components (DrawDefault wird false gehalten)
    last_scan = 0.0,
    SCAN_INTERVAL = 0.5,
}

local function sd_get_scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm or not sd.scene_td then return nil end
    return safe(function() return sdk.call_native_func(sm, sd.scene_td, "get_CurrentScene") end)
end

-- Mesh-Render auf einem GO (+ Kindern, Subtree ist winzig) ausschalten + cachen.
local function sd_hide_subtree(tf)
    if not tf then return end
    local go = safe(function() return tf:call("get_GameObject") end)
    if go then
        for _, t in ipairs({ sd.mesh_t, sd.skin_t }) do
            local m = t and safe(function() return go:call("getComponent(System.Type)", t) end)
            if m then
                pcall(function() m:call("set_DrawDefault", false) end)
                sd.cache[#sd.cache + 1] = m
            end
        end
    end
    local child = safe(function() return tf:call("get_Child") end)
    while child do
        sd_hide_subtree(child)
        child = safe(function() return child:call("get_Next") end)
    end
end

local function sd_scan()
    local scene = sd_get_scene()
    if not scene or not sd.ctrl_t then return end
    local comps = safe(function() return scene:call("findComponents(System.Type)", sd.ctrl_t) end)
    if not comps then return end
    sd.cache = {}
    local n = safe(function() return comps:get_size() end) or 0
    for i = 0, n - 1 do
        local c = safe(function() return comps[i] end)
        local go = c and safe(function() return c:call("get_GameObject") end)
        local tf = go and safe(function() return go:call("get_Transform") end)
        sd_hide_subtree(tf)
    end
end

re.on_frame(function()
    if not cfg.hide_streaming_dummy then return end
    -- gecachte Meshes still halten (billig) -> Cube bleibt aus, falls Engine re-aktiviert.
    -- Wird ein Mesh ungueltig (Level/Body neu nach Save/Load), Cache verwerfen -> SOFORT-Rescan.
    local stale = false
    for _, m in ipairs(sd.cache) do
        local valid = false
        pcall(function() valid = m:call("get_Valid") end)
        if valid then
            pcall(function() m:call("set_DrawDefault", false) end)
        else
            stale = true
        end
    end
    if stale then sd.cache = {}; sd.last_scan = 0.0 end

    -- periodisch neu suchen (faengt neue Dummies; bei stale sofort durch last_scan=0)
    local now = os.clock()
    if (now - sd.last_scan) >= sd.SCAN_INTERVAL then
        sd.last_scan = now
        pcall(sd_scan)
    end
end)

-- ---- UI ----
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - FirstPerson" raus (241 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

re.on_script_reset(function()
    bob_filter.ema = nil
    bob_filter.last_t = nil
    capy.ema = nil
    capy.last_t = nil
    surge.px, surge.pz, surge.lx, surge.lz, surge.last_t = nil, nil, nil, nil, nil
    surge.vx, surge.vz = 0, 0
    surge.lyaw = nil
    surge.turn_n = 0
    crouch_cam.ema = nil
    crouch_cam.until_t = nil
    crouch_cam.was = false
    crouch_cam.last_t = nil
    crouch_cam.standup_until = nil
    head_cache.joint = nil
    move_state.has_valid_position = false
    move_state.last_player_position = nil
    move_state.last_time = nil
    camera_system = nil
    if _G.vr_camera_fix then _G.vr_camera_fix.active = false end
    sd.cache = {}
    sd.last_scan = 0.0
    rc_was_active = false
    _G.__vr_recenter_hold = false
end)

