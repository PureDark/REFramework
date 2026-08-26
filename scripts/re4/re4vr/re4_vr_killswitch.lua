-- =====================================================================
-- RE4 VR Killswitch (neu, nach RE9-Vorbild re9_vr_killswitch.lua)
-- Pfad: reframework/autorun/re4vr/re4_vr_killswitch.lua
-- =====================================================================
-- Zentrale Steuerung: VR-Scripts fragen is_active ab und pausieren,
-- wenn das Spiel die Kontrolle hat (Cutscenes/Events/Nicht-Gameplay-Kamera).
--
-- Kriterien (RE4):
-- 1. Echte Cutscene: chainsaw.CameraSystem:get_IsEventCamera
-- chainsaw.GuiManager:get_IsPlayingEvent
-- 2. BusyCameraController-Typ (polymorpher Slot):
-- Gameplay = chainsaw.PlayerCameraController, alles andere
-- (MainMenu/Event-Typen) = Killswitch.
-- 3. Force-Toggle (UI, Debug).
--
-- Wie RE9: evaluate laeuft auf UpdateScene, Edge-Tracking
-- (just_activated/just_deactivated) + anim_blend_back (0..1 ueber 0.2s
-- nach Deaktivierung, fuer weiches Zurueckblenden der Hand-Overrides).
-- =====================================================================

if reframework:get_game_name() ~= "re4" then
return {}
end

-- Builtin C++ RE4VRKillswitch; kept below as reference.
return {}

local function safe(fn)
    local ok, res = pcall(fn)
    return ok and res or nil
end

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------
local killswitch_active = false
local pin_release_active = false   -- [PIN_RELEASE] nur Pin loesen, HMD/Yaw bleiben (schlafend)
local jumpdown_until = 0.0          -- [ECHTES RUNTERSPRINGEN] Halte-Fenster: JumpDown/jumpoff/large-Node -> voller KS
local JUMPDOWN_HOLD  = 0.5          -- Nachlauf nach dem letzten Sprung-Node-Frame (robust gegen Oszillation)
local jumpdown_confirmed = false   -- [ECHTES RUNTERSPRINGEN] echter Sprung-Einstieg gesehen -> Fenster ueber
                                   -- die GANZE Flugphase halten (JumpLoop-Node matcht nichts, aber CamState
                                   -- bleibt luftig). Stolper-Step macht das NIE scharf -> bleibt First-Person.
local ks2_active = false           -- [KS2] motion/arm AUS + First-Person, NUR Head/Hair aus
                                   -- (Body sichtbar, Kopf-Schatten bleibt = wie Gameplay-Mesh)
local ks3_active = false           -- [KS3] motion/arm AUS + First-Person, GESAMTES Mesh aus
                                   -- (frueher "fp_only")
local ks4_active = false           -- [KS4] wie KS2 (Head/Hair aus, Body sichtbar) ABER zusaetzlich
                                   -- ALLE Scripte aus (auch die ungateten: gestures/haptic/knife/
                                   -- reload/unlimited). Nur First-Person + Bindings bleiben. Fuer Kicks.
local ks5_active = false           -- [KS5] wie KS4 (ALLE Scripte aus + First-Person) ABER GESAMTES Mesh aus
                                   -- (wie KS3). Fuer die 2. Minecart-Szene (VehicleCam-Fahrt).
local boxbreak_active = false      -- [KS4-BOXBREAK] NUR der Fass-/Kisten-Tritt (get_IsBoxBreak).
                                   -- Untermenge von KS4 -> firstperson nutzt dann einen eigenen HMD-Offset.
-- [FP_LATCH] Sobald das Token EINMAL waehrend einer Nicht-Gameplay-Episode (gleicher State)
-- auftaucht, halten wir die Stufe fuer die GANZE Episode -> kein Flackern, auch wenn das
-- Token (z.B. "Jacked") nur 1 Frame da ist. Reset, sobald der State wechselt.
local fp_latch = false
local fp_latch_state = nil
local fp_latch_level = 0           -- 2 = KS2, 3 = KS3 (welche Stufe diese Episode gelatcht hat)
local was_active = false
local prev_full_off = false   -- [JOINT_RELEASE] war letzten Frame ein "voll aus"-KS (KS1/4/5) aktiv?
local current_controller = nil       -- Typname des BusyCameraControllers
local previous_controller = nil
local current_cam_state = nil        -- PlayerCameraState (Zahl), nur bei PlayerCameraController
local current_stage = nil
local current_space = nil
local activating_reason = nil

-- [ZONES] map+position-basierte KS2/KS3-Zuweisung. Jede Zone:
-- { stage, space, x, y, z, r, level(2|3), camstate, name }
-- Default-Radius 3 m. Persistiert in reframework/data/re4_killswitch_zones.json.
-- Erfasst wird die Position vom EVENT-EINTRITT (eingefroren), nicht die Live-Pos
-- -> Erfassung (Monitor-Button) und Laufzeit-Abgleich lesen exakt dieselbe Stelle.
local KS_ZONES = {}
local ZONES_FILE = "re4_vr/re4_vr_killswitch_zones.json"
local cur_episode_entry = nil    -- { stage, space, camstate, pos={x,y,z} } - laufendes Nicht-Gameplay-Event
local last_episode_entry = nil   -- dito, letztes beendetes (Button auch NACH dem Event drueckbar)

local function load_zones()
    local ok, data = pcall(function() return json.load_file(ZONES_FILE) end)
    KS_ZONES = (ok and type(data) == "table") and data or {}
end

local function save_zones()
    pcall(function() json.dump_file(ZONES_FILE, KS_ZONES) end)
end
load_zones()

-- [FP_GATE 2026-07-21] EIN Schalter fuer alle First-Person-Killswitches. AN (Default) = alles
-- wie bisher. AUS = KS2/KS3/KS4/KS5 haben keine Wirkung mehr und fallen auf KS1 zurueck, also die
-- native 3rd-Person-Darstellung, um die sich das Spiel selbst kuemmert. Erkennung, Zonen, Stages und
-- Captures laufen unveraendert weiter -- nur das ERGEBNIS wird umgebogen (eine Stelle, s. evaluate).
-- Als Global, damit andere Scripte es lesen koennen, ohne einen Top-Level-Local zu kosten.
local KS_CFG_FILE = "re4_vr/re4_vr_killswitch_cfg.json"
_G.__re4_ks_fp_enabled = true
-- [KS2_ALS_KS4] true = jedes KS2 feuert als KS4 (Default seit 2026-07-21). false = altes Verhalten.
_G.__re4_ks2_as_ks4 = true
-- [EVT60874 MID-EVENT-FP 2026-07-22] Das Event in Stage 60874 (Space 60880, Monitordump
-- 15:04:24: ActionCameraController + Occupied CH_JACKED_GMK_HIGH(23)) startet ABSICHTLICH in
-- 3rd-Person (KS1) und soll erst MITTEN DRIN auf First-Person umschalten. Umgesetzt als Timer:
-- ab Betreten der Stage laeuft die Uhr, nach dieser Verzoegerung wird KS4 erzwungen.
-- Stage 60874 kam im gesamten Monitordump-Verlauf NUR bei diesem Event vor -> als Gate eindeutig.
-- WERT ERSPIELT 2026-07-22: 1.2 s ("dann ist es perfekt"). Slider wieder entfernt, Wert fest.
-- Ab dem Umschalten sollen ausserdem ALLE Meshes aus sein -> der Branch setzt zusaetzlich
-- __re4_evt60874_fullhide, das re4_vr_materials.lua auswertet (dort fp_only_now).
local EVT60874_DELAY = 1.2
-- [EVT40510 TIMED-KS4 2026-07-22] Umgekehrter Fall zu EVT60874: die Cutscene in Stage 40510
-- (Monitordump 21:49:14, EventCamera + Occupied CUT_SCENE(38), Space 40500) startet als KS4
-- (First-Person, Head/Hair aus, Scripte aus) und faellt nach dieser Zeit auf KS1 (Standard) zurueck.
local EVT40510_DELAY = 5.5   -- WERT ERSPIELT 2026-07-22, Bereich 5.3-6.5 getestet
-- Zeitstempel der beiden Stellen-Timer beim Script-Load nullen: Globals ueberleben "Reset Scripts",
-- sonst gilt eine Uhr als "laengst abgelaufen" und der KS4-Teil wird beim naechsten Mal uebersprungen.
_G.__re4_evt40510_t = nil
_G.__re4_gang3rd_t  = nil
do
    local ok, d = pcall(function() return json.load_file(KS_CFG_FILE) end)
    if ok and type(d) == "table" then
        if type(d.fp_enabled) == "boolean" then _G.__re4_ks_fp_enabled = d.fp_enabled end
        if type(d.ks2_as_ks4) == "boolean" then _G.__re4_ks2_as_ks4 = d.ks2_as_ks4 end
    end
end
local function save_ks_cfg()
    pcall(function() json.dump_file(KS_CFG_FILE, { fp_enabled = _G.__re4_ks_fp_enabled,
                                                   ks2_as_ks4 = _G.__re4_ks2_as_ks4 }) end)
end

local force_killswitch = false

local anim_blend_back = 0.0
local anim_blend_back_t = 0
local ANIM_BLEND_DURATION = 0.2
-- [KS4_EXIT_FADE 2026-07-17] Vorframe-Zustand von ks4_active -> eigene Flanke fuers Verlassen von KS4
-- (setzt _G.__re4_ks4_exit_t; motion.lua macht daraus den Hand-Lerp). Wird in re.on_script_reset genullt.
local prev_ks4_exit = false
-- [EXIT_FADE FUER KS2/KS3 2026-07-20] Der weiche Hand-Uebergang lief bisher NUR beim
-- KS4-Ende. KS2 und KS3 endeten hart. Jetzt speisen alle drei denselben Stempel
-- (__re4_ks4_exit_t) -> EIN Slider in motion.lua regelt weiterhin alle drei Flanken.
local prev_ks2_exit, prev_ks3_exit = false, false

-- ---------------------------------------------------------------------
-- Getter (Singletons gecacht)
-- ---------------------------------------------------------------------
local character_manager = nil
local camera_system = nil
local gui_manager = nil

local function get_character_manager()
    if not character_manager then
        character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    return character_manager
end

local function get_camera_system()
    if not camera_system then
        camera_system = sdk.get_managed_singleton("chainsaw.CameraSystem")
    end
    return camera_system
end

local function get_gui_manager()
    if not gui_manager then
        gui_manager = sdk.get_managed_singleton("chainsaw.GuiManager")
    end
    return gui_manager
end

-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: einmal pro Frame aufloesen statt bei
-- jedem Aufruf. Semantik unveraendert, alter Weg bleibt als Fallback. NOT-AUS: `_G.__re4_fc_off = true`.
pcall(function() require("re4vr/re4_vr_frame_cache") end)

local function get_player_context()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.ctx() end
    local cm = get_character_manager()
    if not cm then return nil end
    return safe(function() return cm:call("getPlayerContextRef") end)
end

local function get_player_body()
    local ctx = get_player_context()
    if not ctx then return nil end
    return safe(function() return ctx:call("get_BodyGameObject") end)
end

-- [ZONES] Welt-Position des Spielers (Body-Transform) — exakt die Quelle, die auch der
-- Monitor anzeigt, damit erfasste Zonen-Mitte und Laufzeit-Abgleich identisch sind.
local function get_player_pos()
    local body = get_player_body()
    if not body then return nil end
    local tf = safe(function() return body:call("get_Transform") end)
    if not tf then return nil end
    return safe(function() return tf:call("get_Position") end)
end

-- [GIMMICK_FLAG] Interaktions-Flags am PlayerContext, die ~0.2s VOR dem zugehoerigen
-- CamState kippen (Auto-Attach an Tuer/Leiter/Terrain/Gondel...). Solange eins true ist,
-- wird der Frame NICHT als Gameplay/Pin-Release behandelt -> faellt in den else-Zweig ->
-- Killswitch (KS1) greift sofort, kein First-Person-Durchclippen mehr vor der Korrektur.
-- 2. Fang-Weg = AutoMove aus GAMEPLAY_CAM_STATES raus (Auto-Move-Takeover-Frames). -
-- Liste 2026-07-06 (Tueren clippen am schlimmsten). [[NotizRotation_couples_movement]]
local GIMMICK_FLAGS = {
    -- [TUER RAUS 2026-07-06] get_IsDoorPass / get_IsOpenDoubleDoor ENTFERNT: get_IsOpenDoubleDoor
    -- haengt nach dem Durchrennen STALE true (live gemessen) -> player_gimmick_active blieb ewig
    -- true -> Gameplay-Zweig griff nie -> KS1/native 3rd-Person klebte nach der Tuer. Tuer ist jetzt
    -- komplett neutral (kein KS-Eingriff mehr), fuer die saubere Diagnose (re4_zz_doorram_diag).
    -- get_IsLadder RAUS: eigener Leiter->KS4-Branch (player_is_ladder). (LadderVertical war eh dauerhaft true.)
    -- get_IsTerrainAction RAUS 2026-07-07 (Option A wie Tueren): das Flag wurde beim Ranrennen VOR
    -- dem TerrainAction_Window-CamState true -> Lead-in fiel auf KS1 = kurzer 3rd-Person-Blitz. Jetzt
    -- neutral -> Lead-in bleibt First-Person/Gameplay (kein Blitz), dann uebernimmt TerrainAction_Window
    -- -> KS3. Trade-off: beim vollen Ranrennen ggf. minimales First-Person-Clipping (wie Tueren).
    "get_IsTerrainUpWithPartner",                    -- Klettern / Partner-Boost (noch drin, ungetestet)
    "get_IsHookShot",                                -- Enterhaken
    "get_IsLiftActing",                              -- Hebel / Lift
    -- get_IsMoveGimmickRide RAUS 2026-07-12 (wie Tuer/Terrain oben): Aufzug 2 (Stage 53302/53300) setzt dieses
    -- Flag durchgehend true UND es haengt nach dem Aussteigen STALE true (live via re4_elevator_diag: gimmick=
    -- MoveGimmickRide in JEDER Zeile, auch bei y=12.13 unter dem Aufzug). CamState ist dabei "Normal" (Gameplay),
    -- aber das Flag blockte den Gameplay-Zweig -> KS1/3rd-Person, "kommt nicht mehr raus". Trade-off: echte
    -- Gondeln/Loren loesen jetzt keinen KS mehr ueber dieses Flag (falls noetig -> space-gegatet wieder rein).
    -- "get_IsMoveGimmickRide", -- Gondel / Lore
    -- get_IsBoxBreak RAUS: das ist Leons Fass-/Kisten-TRITT -> soll KS4 (First-Person) statt
    -- KS1 (3rd-Person). Wird unten als eigener KS4-Flag-Trigger behandelt (player_is_boxbreak).
}
local function player_gimmick_active()
    local ctx = get_player_context(); if not ctx then return false end
    for _, fn in ipairs(GIMMICK_FLAGS) do
        if safe(function() return ctx:call(fn) end) == true then return true end
    end
    return false
end

-- [COOP-JACKED / RAEUBERLEITER] Der Partner-Boost (Raeuberleiter) laeuft im Spiel als CamState
-- "Normal" (= ganz normales Gameplay) -> ohne Eingriff bleibt volles VR-Movement an, das Movement-
-- Script klebt die FP-Kamera an den Kopf und der Char rutscht mit Momentum in/durch die Wand.
-- Solides Merkmal (live gemessen 2026-07-07): OccupiedInfo.Priority == PL_JACKED_COOP_READY (im
-- normalen Gameplay ist die Priority UNSET). Wird wie ein Gimmick-Flag behandelt (gimmick_ng) ->
-- Frame faellt in den else-Zweig -> KS1 (native 3rd-Person), kein Durchclippen. Enum-Int lazy
-- aufgeloest (TDB evtl. beim ersten Frame noch nicht bereit -> bleibt nil, naechster Frame neu).
local COOP_JACKED_PRIO = nil
local function coop_jacked_prio()
    if COOP_JACKED_PRIO == nil then
        local td = sdk.find_type_definition("chainsaw.OccupiedMediatorPriority")
        local f = td and safe(function() return td:get_field("PL_JACKED_COOP_READY") end)
        local v = f and safe(function() return f:get_data(nil) end)
        if type(v) ~= "number" then
            v = type(v) == "userdata" and safe(function() return v:get_field("value__") end) or nil
        end
        COOP_JACKED_PRIO = v
    end
    return COOP_JACKED_PRIO
end
local function player_is_coop_jacked()
    local want = coop_jacked_prio(); if want == nil then return false end
    local ctx = get_player_context(); if not ctx then return false end
    local occ = safe(function() return ctx:call("get_OccupiedInfo") end)
    if not occ then return false end
    local prio = safe(function() return occ:call("get_Priority") end)
    return prio == want
end

-- [GRAPPLED 2026-07-15] Gegner packt Leon (am Krauser gefunden, gilt aber ueberall -> GLOBAL, -Wahl).
-- Der Griff hat ZWEI Phasen, die beide auf KS1/3rd-Person fielen (Monitor-Dump 2026-07-15 09:10):
-- (1) ~1s chainsaw.ActionCameraController -> kein PlayerCameraController -> else-Zweig, KS1 [ctrl_name]
-- (2) PlayerCameraController + CamState Grappled(26) -> KS1 [camstate:26]
-- Nur den CamState 26 umzubiegen wuerde Phase 1 stehen lassen = 3rd-Person-Blitz beim Zupacken.
-- Gemeinsames Merkmal BEIDER Phasen: OccupiedInfo.Priority == GRAPPLED (im Gameplay UNSET, nach dem
-- Griff sofort wieder UNSET -> kein Stale). Ein Branch deckt damit den ganzen Griff.
-- [GRAPPLED_FATAL 2026-07-15] Der TOEDLICHE Griff ist ein EIGENER Enum-Wert: GRAPPLED_FATAL(19) --
-- er fiel deshalb trotz des Branches hier weiter auf KS1 (Monitor-Dump 22:07:32: ActionCameraController,
-- kein CamState, Priority=GRAPPLED_FATAL(19), "KS1 (voll)") = exakt der 3rd-Person-Blitz, den dieser
-- Branch eigentlich beseitigen soll. Auf so gewollt bekommt er jetzt dasselbe KS2 wie der normale Griff.
-- Darum ist das hier ein SET aus mehreren Prios statt eines einzelnen Werts.
-- NICHT verwechseln mit GRAPPLED_ASSIST(17) = PartnerRescue -> KS3 (eigener Eintrag in KS3_CAM_STATES)
-- und NICHT mit FatalKick: der hat UNSET(0) und bleibt unberuehrt (ist ein Tritt, kein Griff).
-- Enum-Ints lazy aufgeloest wie bei coop_jacked (TDB im 1. Frame evtl. noch nicht bereit -> nil, neuer
-- Versuch). Loest sich einer der Namen nicht auf, zaehlen die anderen weiter (kein Totalausfall).
local GRAPPLED_PRIO = nil
local function grappled_prio()
    if GRAPPLED_PRIO == nil then
        local td = sdk.find_type_definition("chainsaw.OccupiedMediatorPriority")
        if not td then return nil end
        local set, n = {}, 0
        for _, nm in ipairs({ "GRAPPLED", "GRAPPLED_FATAL" }) do
            local f = safe(function() return td:get_field(nm) end)
            local v = f and safe(function() return f:get_data(nil) end)
            if type(v) ~= "number" then
                v = type(v) == "userdata" and safe(function() return v:get_field("value__") end) or nil
            end
            if type(v) == "number" then set[v] = true; n = n + 1 end
        end
        if n == 0 then return nil end   -- TDB noch nicht bereit -> nicht cachen, naechster Frame neu
        GRAPPLED_PRIO = set
    end
    return GRAPPLED_PRIO
end
local function player_is_grappled()
    local want = grappled_prio(); if want == nil then return false end
    local ctx = get_player_context(); if not ctx then return false end
    local occ = safe(function() return ctx:call("get_OccupiedInfo") end)
    if not occ then return false end
    local prio = safe(function() return occ:call("get_Priority") end)
    return type(prio) == "number" and want[prio] == true
end

-- [KICK/BARREL] get_IsBoxBreak = Leons Tritt gegen Fass/Kiste (Fingerprint 2026-07-06: CamState
-- bleibt Gameplay Normal/Combat, KEIN Fatal-Flag -> nur dieses Flag markiert den Tritt). -> KS4
-- (First-Person + Head/Hair aus + alle Scripte aus). Flag ist im Stehen false (live geprueft).
local function player_is_boxbreak()
    local ctx = get_player_context(); if not ctx then return false end
    return safe(function() return ctx:call("get_IsBoxBreak") end) == true
end

-- [LEITER] get_IsLadder = an/auf der Leiter (live geprueft: true nur hier, Door/RunPassThrough false).
-- TEST: soll KS4 sein (First-Person, Head/Hair aus, Body sichtbar, alle Scripte aus).
local function player_is_ladder()
    local ctx = get_player_context(); if not ctx then return false end
    return safe(function() return ctx:call("get_IsLadder") end) == true
end

-- [LEITER-AUSSTIEG] player_is_ladder_exit ist weiter unten definiert (nach motion_cache/
-- find_motion, die es braucht). EndFrame-basiert statt FrontPassThrough (das war Sackgasse:
-- FrontPassThrough war die ganze Leiter true). Siehe Diag re4_zz_ladder_node.log.

local function get_busy_controller()
    local csys = get_camera_system()
    if not csys then return nil end
    local main = safe(function() return csys:call("get_MainCameraController") end)
    if not main then return nil end
    return safe(function() return main:call("get_BusyCameraController") end)
end

-- ---------------------------------------------------------------------
-- Crouch-Erkennung (Animations-getriggert, wie im dev-firstperson)
-- MotionFsm2.getCurrentNodeName(0) enthaelt "CROUCH" sobald die
-- Hock-Locomotion laeuft. Body-Wechsel (Save-Load/Tod) invalidiert den
-- gecachten Component-Handle.
-- ---------------------------------------------------------------------
local mfsm2_cache = { comp = nil, body = nil }
local mfsm2_td = sdk.typeof and sdk.typeof("via.motion.MotionFsm2")

local function find_mfsm2(body)
    local m = mfsm2_td and safe(function()
        return body:call("getComponent(System.Type)", mfsm2_td)
    end)
    if m then return m end
    local comps = safe(function() return body:call("get_Components") end)
    if comps then
        for _, c in ipairs(comps) do
            local td = safe(function() return c:get_type_definition() end)
            local tn = td and safe(function() return td:get_full_name() end)
            if tn and tn:lower():find("motionfsm2", 1, true) then
                return c
            end
        end
    end
    return nil
end

local function is_crouch_active()
    local body = get_player_body()
    if not body then
        mfsm2_cache.comp = nil
        mfsm2_cache.body = nil
        return false
    end
    if body ~= mfsm2_cache.body then
        mfsm2_cache.comp = nil
        mfsm2_cache.body = body
    end
    mfsm2_cache.comp = mfsm2_cache.comp or find_mfsm2(body)
    if not mfsm2_cache.comp then return false end
    local node = safe(function() return mfsm2_cache.comp:call("getCurrentNodeName", 0) end)
    if not node then return false end
    return tostring(node):upper():find("CROUCH", 1, true) ~= nil
end

-- [FP_ONLY/FEIN] Enthaelt IRGENDEIN MotionFsm2-Layer-Node das Token? (Substring, case-insensitiv)
-- Nutzt denselben gecachten Component-Handle wie is_crouch_active.
local function player_node_has(token)
    if not token or token == "" then return false end
    local body = get_player_body()
    if not body then mfsm2_cache.comp = nil; mfsm2_cache.body = nil; return false end
    if body ~= mfsm2_cache.body then mfsm2_cache.comp = nil; mfsm2_cache.body = body end
    mfsm2_cache.comp = mfsm2_cache.comp or find_mfsm2(body)
    if not mfsm2_cache.comp then return false end
    local tok = token:lower()
    for layer = 0, 7 do
        local n = safe(function() return mfsm2_cache.comp:call("getCurrentNodeName", layer) end)
        if type(n) == "string" and n:lower():find(tok, 1, true) then return true end
    end
    return false
end

-- [CLIP-EBENE] via.motion.Motion-Cache: die ECHTE Clip-Ebene (JackFrom-Helfer). Noetig,
-- weil die FSM-Nodes (player_node_has) feine Gimmicks NICHT trennen (Tuer und Schublade
-- zeigen beide Jacked/Locked). JackFrom unterscheidet: Tuer ":Open" vs Schublade ":OpenLow".
local motion_cache = { comp = nil, body = nil }
local motion_td = sdk.typeof and sdk.typeof("via.motion.Motion")
local function find_motion(body)
    return motion_td and safe(function() return body:call("getComponent(System.Type)", motion_td) end)
end

-- true wenn IRGENDEINE gejackte Motion-Layer einen JackFrom-Helfer hat, dessen Name auf das
-- Token ENDET (case-insensitiv). Ende-Match trennt sauber ":Open" (Tuer) von ":OpenLow"
-- (Schublade) - "Open" ist Teilstring von "OpenLow", daher KEIN Substring-, sondern Suffix-Match.
local function player_jack_has(token)
    if not token or token == "" then return false end
    local body = get_player_body()
    if not body then motion_cache.comp = nil; motion_cache.body = nil; return false end
    if body ~= motion_cache.body then motion_cache.comp = nil; motion_cache.body = body end
    motion_cache.comp = motion_cache.comp or find_motion(body)
    local m = motion_cache.comp
    if not m then return false end
    local tok = token:lower()
    local lc = safe(function() return m:call("getLayerCount") end) or 0
    for i = 0, lc - 1 do
        local lay = safe(function() return m:call("getLayer", i) end)
        if lay and safe(function() return lay:call("get_Jacked") end) == true then
            local jf = safe(function() return lay:call("get_JackFrom") end)
            local nm = jf and safe(function() return jf:call("get_Name") end)
            if type(nm) == "string" then
                nm = nm:lower()
                if #nm >= #tok and nm:sub(-#tok) == tok then return true end
            end
        end
    end
    return false
end

-- [LEITER-AUSSTIEG] Der gejackte Kletter-Layer (L9, Clip konstant "Helper_ch0a0z0_body:Use")
-- traegt die Phase in der ANIM-LAENGE (get_EndFrame), NICHT im Clip-Namen (Diag re4_ladder_node.log):
-- Einstieg unten = 38 fr (motion id:220), Kletter-Loop (pro Sprosse) = 19 fr (id:223/224),
-- AUSSTIEG oben = 166 fr (id:225).
-- Sobald die lange Ausstiegs-Anim laeuft, schwingt der Body in die Kamera -> KS3.
-- NT allein taugt NICHT (im Loop saegezahnt NT auch bis 1.0); der EndFrame-Sprung trennt sauber.
-- Muss VOR player_is_ladder (KS4) geprueft werden.
--
-- [2026-07-14] Die Sprossen sind EIGENE Clips (id:223/224, ef=19), id:225 (ef=166) ist KOMPLETT das
-- Ueber-die-Kante-Schwingen -> der GANZE id:225 soll KS3 sein. (Der fruehere Bug "kein mesh die ganze
-- Leiter hoch" lag NICHT hier, sondern am Stage-55300-Override in materials.lua, der in KS4 den Body
-- ausblendete; der ist jetzt auf railcar_mode gegatet. Diag: re4_ladder_diag.log.)
local LADDER_EXIT_ENDFRAME = 100  -- Schwelle >> Loop(19)/Einstieg(38), << Ausstieg(166) = "das ist der Ausstiegs-Clip"
local ladder_exit_latched = false -- [STICKY] einmal Ausstieg erkannt -> KS3 halten bis wieder Gameplay
-- cam_is_gameplay = is_gameplay_camstate(st), vom Aufrufer reingereicht (Funktion ist vor dessen Def).
local function player_is_ladder_exit(cam_is_gameplay)
    local ctx = get_player_context(); if not ctx then return false end
    -- [STICKY] Zwei Flicker-Quellen, beide vom Latch abgefangen:
    -- (1) KS4->KS3-Einstieg: EndFrame wechselt nicht in EINEM Frame sauber Loop(19)->166, die >100-
    -- Bedingung wackelt -> einmal erkannt = KS3 bleibt (EndFrame darf schwanken).
    -- (2) KS3->Gameplay-Ausstieg: get_IsLadder wird schon bei NT~0.71 false + der gejackte Layer ist
    -- dann sofort weg. Wuerde man hier loesen, flackerte KS3->KS1 (CamState noch "Ladder"=kein
    -- Gameplay=else=native 3rd-Person) fuer ein paar Frames. Darum NICHT bei IsLadder-false loesen,
    -- sondern erst wenn der CamState WIEDER ECHTES GAMEPLAY ist (Rueberklettern ganz durch).
    if ladder_exit_latched then
        if cam_is_gameplay then ladder_exit_latched = false; return false end
        return true
    end
    if safe(function() return ctx:call("get_IsLadder") end) ~= true then return false end
    local body = get_player_body()
    if not body then motion_cache.comp = nil; motion_cache.body = nil; return false end
    if body ~= motion_cache.body then motion_cache.comp = nil; motion_cache.body = body end
    motion_cache.comp = motion_cache.comp or find_motion(body)
    local m = motion_cache.comp
    if not m then return false end
    local lc = safe(function() return m:call("getLayerCount") end) or 0
    for i = 0, lc - 1 do
        local lay = safe(function() return m:call("getLayer", i) end)
        if lay and safe(function() return lay:call("get_Jacked") end) == true then
            local ef = tonumber(safe(function() return lay:call("get_EndFrame") end))
            if ef and ef > LADDER_EXIT_ENDFRAME then ladder_exit_latched = true; return true end
        end
    end
    return false
end

-- ---------------------------------------------------------------------
-- Gameplay-State-Allowlist (INVERSIONS-Ansatz): der VR-Zustand (Spine-Pin,
-- Hard-Yaw, HMD-_Yaw) gilt NUR fuer reines Gameplay. Bei JEDEM anderen
-- PlayerCameraState (Leiter/Vault/Grapple/Fall/Finisher/...) schaltet der
-- Killswitch ALLES ab -> rohe native Animation. Statt die vielen Spezial-
-- States zu listen, listen wir die WENIGEN Gameplay-States; alles ausserhalb
-- = aus (auch kuenftig neu auftauchende States defaulten sicher auf "aus").
-- CROUCH-States stehen drin -> bleiben Gameplay (Crouch-Pin uebernimmt).
-- Quelle: chainsaw.CameraDefine.PlayerCameraState (live verifiziert).
-- HINWEIS: "ForceCrouch" ist hier GAMEPLAY (wie Crouch) -> volle VR-Steuerung, kein Killswitch,
-- Kopf/Haar per Gameplay-Material-Regel eh aus. Weil ForceCrouch UND Crouch beide Gameplay sind,
-- flackert der Intro-Wechsel ForceCrouch<->Crouch nicht mehr (kein Zustandssprung, kein Halte-Fenster).
local GAMEPLAY_CAM_STATES = {
    "Normal", "Jog", "Sprint", "Combat", "BattleNormal",
    -- "AutoMove", -- [GIMMICK] RAUS 2026-07-06: AutoMove ist der Auto-Attach-Takeover an
    -- Tuer/Leiter/Terrain/Gondel -> soll KS ausloesen, nicht Gameplay bleiben.
    -- Faellt jetzt in den else-Zweig (KS1, zone-settable). 2. Fang = GIMMICK_FLAGS.
    "WallAlongJog", "QuickTurm", "CrouchQuickTurm", "Crouch", "ForceCrouch",
    "Hold", "HoldVariation", "HoldIronSight", "HoldGrenade", "HoldExtraScope",
    "HoldOpticalScope", "HoldSpecialOpticalScope", "ViaScope",
    "PumpAction", "RifleChangeWeapon",
    -- "FatalKick" verschoben nach KS2_CAM_STATES (Killswitch feuert, aber First-Person bleibt).
}

-- [PIN_RELEASE] "zweiter Killswitch": States, in denen NUR der Spine/Crouch-Pin
-- gelöst wird (Char hüpft/klettert nativ drüber), aber HMD-Yaw + Hard-Yaw AKTIV
-- bleiben (Blick/Kamera-Kontrolle behalten). Voller Killswitch (alles aus) gilt
-- weiter fuer alle States ausserhalb BEIDER Listen. Per Test kategorisieren.
-- [2026-07-15 STILLGELEGT, NICHT ENTFERNT] Liste ist LEER: die komplette Sprung-/Absatz-Kette
-- (Fall / Fall_Jump / TerrainAction_Jump) steht jetzt in KS2_CAM_STATES -- so gewollt, alle Traversal-
-- Aktionen KS2 + Head-Nagel. Die Pin-Release-Mechanik bleibt vollstaendig erhalten (pin_release_active,
-- is_pinrelease_camstate, der Auswertungs-Zweig): ein Eintrag hier reicht, um sie zurueckzuholen.
-- Nebeneffekt: is_airborne_camstate baut auf dieser Liste auf -> mit leerer Liste ist "luftig" nur noch
-- Landing. Das jumpdown-Fenster ist damit faktisch redundant (die ganze Kette ist ohnehin KS2 ueber die
-- Liste), aber unveraendert funktionsfaehig.
local PIN_RELEASE_CAM_STATES = {}

-- ============================================================
-- DREI First-Person-Killswitch-Stufen (per Substate/Node-Regel zuweisbar):
-- KS2 = motion/arm AUS, First-Person, NUR Head/Hair aus (Body sichtbar, Kopf-Schatten bleibt)
-- KS3 = motion/arm AUS, First-Person, GESAMTES Mesh aus
-- KS1 (voll / 3rd-Person) ist der Default fuer alles Nicht-Gameplay, das hier NICHT gelistet ist.
-- Listen DEFAULT LEER -> beim Durchspielen (Monitor = "Rucksack") gezielt fuellen.
-- Zuweisung per CamState-Name ODER per Regel:
-- { state=<CamStateName>, jack={ "<suffix>",... } } -> Clip-Ebene: gejackter JackFrom-Helfer
-- endet auf <suffix> (Suffix-Match!).
-- { state=<CamStateName>, node={ "<token>",... } } -> FSM-Node enthaelt <token> (Substring).
-- (Regel greift, wenn CamState == state UND die jack- ODER node-Bedingung passt.)
-- KS3 hat Vorrang vor KS2, falls beide matchen.
-- ============================================================
-- [KS3 -> KS2 KOMPLETT 2026-07-15] KS3 (First-Person + GANZES Mesh aus) gibt es nicht mehr. Es war immer
-- nur die Notloesung dagegen, dass in bestimmten Anims der Body in die Kamera schwenkt. Seit die Cam in
-- diesen Zustaenden fest am Head-Joint sitzt (Head-Nagel in re4_vr_firstperson.lua), liegt der Body per
-- Definition HINTER der Kamera -> Mesh-Aus ist ueberfluessig, KS2 (nur Head/Hair aus) reicht ueberall.
-- Das traegt sich selbst: KS2 ist Teil des Nagel-Gates (ks2_now) -> wer hier KS2 setzt, bekommt den Nagel
-- automatisch mit. Die frueheren KS3-CamStates stehen deshalb jetzt hier:
-- TerrainAction_Window (36) -- Body schwingt beim Fenster-Durchsteigen in die Kamera.
-- TerrainAction (22) -- Kanten rauf/runter steigen.
-- [TRAVERSAL KOMPLETT -> KS2 2026-07-15] so gewollt: ALLE Traversal-Aktionen KS2 + Nagel, keine Ausnahme.
-- Damit ist die Familie konsistent (vorher: 22/36 = KS2, die Geschwister = KS1 oder Pin-Release -> sichtbarer
-- Bruch im selben Move). Dazugekommen:
-- TerrainAction_2m (40) -- wie 22, nur hohe Kante. War KS1 -> derselbe Move hatte zwei Ergebnisse.
-- Fall_Window (37) -- Lead-in zu 36 (Fenster). War KS1 -> 3rd-Person-Blitz direkt vor dem KS2-Teil.
-- Landing (23) -- Landephase. Hatte KS2 nur ueber den jumpdown-Pfad (bewusster Sprung), sonst KS1.
-- Fall (28) + Fall_Jump (39) + TerrainAction_Jump (38) -- waren Pin-Release, jetzt ebenfalls KS2.
-- TerrainUpWithPartner (34) + _1m (35) -- Partner-Boost/Raeuberleiter.
-- HookShot (29) -- Enterhaken.
-- 34/35/29 haengen ZUSAETZLICH an GIMMICK_FLAGS (get_IsTerrainUpWithPartner / get_IsHookShot). Die Flags
-- bleiben drin: sie schieben nur aus Gameplay/Pin-Release in den else-Zweig, die Stufe entscheidet dann
-- diese Liste. ACHTUNG Lead-in: steht das Flag VOR dem CamState (wie einst get_IsTerrainAction, s. Kommentar
-- bei GIMMICK_FLAGS), ist der Vorlauf-Frame noch ein Gameplay-CamState -> nicht in dieser Liste -> KS1-Blitz.
-- Falls das auftritt: das jeweilige Flag aus GIMMICK_FLAGS raus (exakt der Fix von damals), NICHT hier drehen.
-- Damage (13) -- alle Damage-Reaktionen. Greift auch im DAMAGE_HOLD-Fenster (damage_int zwingt
-- oszillierende Frames auf Damage).
-- PartnerRescue (31) -- Occupied Priority=GRAPPLED_ASSIST(17), kein GimmickType-Flag.
-- AutoMove
-- Rueckbau eines einzelnen Eintrags = hier raus -> faellt auf KS1 (voll/3rd-Person) zurueck.
local KS2_CAM_STATES = {
    -- Traversal (komplett, s. Kommentar oben)
    "TerrainAction", "TerrainAction_2m", "TerrainAction_Jump", "TerrainAction_Window",
    "Fall", "Fall_Jump", "Fall_Window", "Landing",
    "TerrainUpWithPartner", "TerrainUpWithPartner_1m", "HookShot",
    -- [HOOKSHOT WIEDER DRIN 2026-07-20] Der Test hat gezeigt: der Haken-KS2 ist NICHT die Ursache
    -- des Reload-/Messer-Problems. Also wieder aufgenommen -- Seilhaken laeuft wie zuvor als KS2
    -- (First-Person, Kopf/Haare aus, Scripte bleiben AN).
    -- Rest
    "Damage", "PartnerRescue", "AutoMove",
}
local KS2_RULES = {
    -- LEER bis solides Merkmal steht. Animations-/JackFrom-Erkennung war NICHT zuverlaessig
    -- (mehrere Anims pro Tuer). Solider Weg = PlayerBaseContext (State/ActingType/OccupiedInfo)
    -- statt Clip-Ebene. Wird ueber den Monitor an der Tuer verifiziert, dann hier eingetragen.
}

-- [GLOBAL KS3 -- 2026-07-15 STILLGELEGT, NICHT ENTFERNT] CamStates, die IMMER (ueberall im Spiel,
-- unabhaengig von Zone/Position) KS3 ausloesen. Liste ist LEER: alle vier Eintraege
-- (TerrainAction_Window/Damage/PartnerRescue/AutoMove) sind nach KS2_CAM_STATES gewandert, weil der
-- Head-Nagel das Mesh-Aus ueberfluessig macht (s. Kommentar dort).
-- Die KS3-Mechanik bleibt komplett erhalten (ks3_active, is_ks3, dieser Auswertungs-Pfad): Sollte im
-- naechsten Playthrough doch eine Stelle das GANZE Mesh aus brauchen, reicht ein Eintrag hier --
-- kein Wiederaufbau noetig.
local KS3_CAM_STATES = {}
local KS3_RULES = {}

-- [KS4] Mesh wie KS2 (Head/Hair aus, Body + Kopf-Schatten sichtbar) ABER zusaetzlich ALLE
-- Scripte aus (auch die ungateten). Nur First-Person + Bindings bleiben. Fuer Leons Fatal-
-- Kick (18) + Roundhouse-Kick (19): native Kick-Anim spielt sauber, kein VR-Script funkt rein.
-- (IsFatalKill hat KEINEN eigenen CamState -> andere Kamera, bleibt unangetastet.)
local KS4_CAM_STATES = { "FatalKick", "FatalRoundKick" }
local KS4_RULES = {}

-- Namen -> Enum-Int aufloesen (einmal, lazy, alle Listen in einem Pass).
-- read_cam_state liefert den Int.
local CAMSTATE_ENUM = "chainsaw.CameraDefine.PlayerCameraState"
local gameplay_vals = nil       -- { [int]=true }
local pinrelease_vals = nil      -- { [int]=true }
local ks2_vals = nil             -- { [int]=true } [KS2]
local ks2_rules = nil            -- { {state=int, node=...} } [KS2]
local ks3_vals = nil             -- { [int]=true } [KS3]
local ks3_rules = nil            -- { {state=int, node=...} } [KS3]
local ks4_vals = nil             -- { [int]=true } [KS4]
local ks4_rules = nil            -- { {state=int, node=...} } [KS4]
-- [FORCECROUCH] KORREKTUR 2026-07-15: Hier stand, ForceCrouch laufe "als normaler KS2-CamState (Eintrag in
-- KS2_CAM_STATES)". Das war FALSCH und hat beim Lesen in die Irre gefuehrt -- KS2_CAM_STATES war leer.
-- Tatsaechlich steht ForceCrouch in GAMEPLAY_CAM_STATES (s. dort) und ist normales Gameplay: volle
-- VR-Steuerung, keine Sonderlogik, und weil Crouch UND ForceCrouch beide Gameplay sind, flackert der
-- Wechsel zwischen beiden nicht. Seit 2026-07-15 bekommt es zusaetzlich den Head-Nagel -- ueber das
-- Info-Flag __re4_forcecrouch_active, NICHT ueber einen KS-Grad (s. forcecrouch_int unten).
-- [DAMAGE_HOLD] Waehrend der Damage-Reaktion (Treffer/Stagger) oszilliert die CamState pro Frame
-- zwischen Damage (->KS2, frueher KS1/KS3) und BattleNormal/Gameplay (->GAMEPLAY) -> Killswitch flackert
-- -> Arme zucken. Ein Halte-Fenster behandelt oszillierende Gameplay-Frames waehrend Damage als Damage
-- -> stabiler Zustand, kein Flicker.
local damage_int = nil
-- [WIEDERHERGESTELLT 2026-07-20] Diese beiden Zaehler gingen bei einer Reparatur an dieser Datei verloren.
-- Folge: evaluate brach JEDEN Frame an "now < fc_ks4_until" ab (Vergleich mit nil) -- und weil der
-- Aufruf in einem pcall steckt, blieb der Abbruch unsichtbar. Der Killswitch lieferte dadurch dauerhaft
-- KEINEN Kamera-Zustand mehr; alles was daran haengt (u.a. der Waffen-Restore im Holster) war tot.
local fc_ks4_until = 0     -- [FORCECROUCH] Halte-Fenster fuer den KS4 der Start-Stage
local evt60874_t0 = nil    -- [EVT60874] Startzeit des Mid-Event-Umschalters (nil = nicht in der Stage)
local damage_until = 0     -- [DAMAGE_HOLD] Halte-Fenster der Damage-Reaktion
-- [WIEDERHERGESTELLT 2026-07-20] Diese Konstante ging bei einer Reparatur an dieser Datei verloren.
-- Folge: evaluate starb bei JEDEM Damage-Frame an "arithmetic on nil (DAMAGE_HOLD)" -- unsichtbar,
-- weil der Aufruf in einem pcall steckt. Danach lieferte der Killswitch dauerhaft nichts mehr
-- (kein CamState, kein "pure gameplay"), und alles was daran haengt war tot: Waffen-Restore,
-- Rack-Zwang, Messer-Handling. Genau das Bild "nach dem Haken ist alles kaputt".
-- 0.35 s: deckt die oszillierenden Gameplay-Frames waehrend der Damage-Reaktion ab (s. Kommentar oben).
local DAMAGE_HOLD = 0.35
-- [HOOKSHOT 2026-07-20] Enum-Ints + Zeitstempel des letzten Enterhaken-CamStates. Der daraus gebaute
-- KS4-Override wurde ZURUECKGENOMMEN (in KS4 sind alle Scripte aus -> der Auto-Redraw holt die Waffe
-- nach dem Haken nicht zurueck, man stand mit leeren Haenden da). Die Werte bleiben ungenutzt stehen.
local hookshot_int, gimmick_int = nil, nil
local hookshot_seen_t = 0
local landing_int = nil          -- [ECHTES RUNTERSPRINGEN]
local forcecrouch_int = nil      -- [FORCECROUCH_HEADPIN]

-- CamState-Namen -> Enum-Ints aufloesen (einmalig, sobald die TDB bereit ist).
local function resolve_state_vals()
    if gameplay_vals ~= nil then return end
    local gp, pr, k2, k3, k4 = {}, {}, {}, {}, {}
    local td = sdk.find_type_definition(CAMSTATE_ENUM)
    local fields = td and safe(function() return td:get_fields() end)
    if not fields then return end
    local want_gp, want_pr, want_k2, want_k3, want_k4 = {}, {}, {}, {}, {}
    for _, n in ipairs(GAMEPLAY_CAM_STATES) do want_gp[n] = true end
    for _, n in ipairs(PIN_RELEASE_CAM_STATES) do want_pr[n] = true end
    for _, n in ipairs(KS2_CAM_STATES) do want_k2[n] = true end
    for _, n in ipairs(KS3_CAM_STATES) do want_k3[n] = true end
    for _, n in ipairs(KS4_CAM_STATES) do want_k4[n] = true end
    local name_to_int = {}
    for _, f in ipairs(fields) do
        local ok_s = safe(function() return f:is_static() end)
        local nm = safe(function() return f:get_name() end)
        if ok_s and nm then
            local v = safe(function() return f:get_data(nil) end)
            if type(v) ~= "number" then
                v = type(v) == "userdata" and safe(function() return v:get_field("value__") end) or nil
            end
            if type(v) == "number" then
                name_to_int[nm] = v
                if want_gp[nm] then gp[v] = true end
                if want_pr[nm] then pr[v] = true end
                if want_k2[nm] then k2[v] = true end
                if want_k3[nm] then k3[v] = true end
                if want_k4[nm] then k4[v] = true end
            end
        end
    end
    -- Nichts aufgeloest (TDB noch nicht bereit?) -> NICHT cachen, naechsten
    -- Frame neu versuchen. Bis dahin defaulten die Helfer sicher.
    if next(name_to_int) == nil then return end
    -- Regel-State-Namen -> Int aufloesen (KS2 + KS3)
    local function build_rules(src)
        local out = {}
        for _, r in ipairs(src) do
            local si = name_to_int[r.state]
            if si ~= nil and r.node then out[#out + 1] = { state = si, node = r.node } end
        end
        return out
    end
    gameplay_vals, pinrelease_vals = gp, pr
    ks2_vals, ks2_rules = k2, build_rules(KS2_RULES)
    ks3_vals, ks3_rules = k3, build_rules(KS3_RULES)
    ks4_vals, ks4_rules = k4, build_rules(KS4_RULES)
    damage_int = name_to_int["Damage"]   -- [DAMAGE_HOLD]
    -- [ENUM-DIAG 2026-07-20 ENTFERNT 2026-07-21] Das einmalige re4_camstate_ints.log ist raus.
    hookshot_int = name_to_int["HookShot"]   -- [HOOKSHOT->GIMMICK KS4]
    gimmick_int  = name_to_int["Gimmick"]    -- [HOOKSHOT->GIMMICK KS4]
    landing_int = name_to_int["Landing"] -- [ECHTES RUNTERSPRINGEN] Landephase (nach Flug)
    forcecrouch_int = name_to_int["ForceCrouch"]   -- [FORCECROUCH_HEADPIN]
    gimmick_int = name_to_int["Gimmick"]           -- [ELEVATOR5] Button-Druck am Aufzug (Startschuss)
end

-- true = voller VR-Zustand erlaubt (Gameplay). nil/unaufloesbar -> sicher AN.
local function is_gameplay_camstate(st)
    if st == nil then return true end
    resolve_state_vals()
    if gameplay_vals == nil then return true end   -- nicht abwuergen
    return gameplay_vals[st] == true
end

-- true = NUR Pin loesen (HMD/Yaw bleiben). Nur sinnvoll wenn NICHT gameplay.
local function is_pinrelease_camstate(st)
    if st == nil then return false end
    resolve_state_vals()
    if pinrelease_vals == nil then return false end
    return pinrelease_vals[st] == true
end

-- [ECHTES RUNTERSPRINGEN] "luftig": Flug- ODER Landephase eines Sprungs. Nur zusammen mit
-- jumpdown_confirmed benutzt -> haelt den vollen KS ueber den ganzen Sprung (Fall_Jump ->
-- TerrainAction_Jump -> Landing), auch waehrend JumpLoop (Node matcht keinen Sprung-Token).
local function is_airborne_camstate(st)
    if st == nil then return false end
    if is_pinrelease_camstate(st) then return true end
    return landing_int ~= nil and st == landing_int
end

-- Generischer Stufen-Matcher: true wenn (a) State direkt in der CamState-Liste steht ODER
-- (b) eine Regel matcht: State == rule.state UND ein MotionFsm2-Layer-Node enthaelt rule.node.
local function match_level(st, vals, rules)
    if st == nil then return false end
    resolve_state_vals()
    if vals and vals[st] then return true end
    if rules then
        for _, r in ipairs(rules) do
            if r.state == st then
                -- (b1) JackFrom-Bedingung auf der Clip-Ebene (Suffix-Match) — falls gesetzt
                if r.jack then
                    local jt = r.jack
                    if type(jt) == "string" then jt = { jt } end
                    for _, tk in ipairs(jt) do
                        if player_jack_has(tk) then return true end
                    end
                end
                -- (b2) FSM-Node-Bedingung (Substring) — falls gesetzt
                if r.node then
                    local toks = r.node
                    if type(toks) == "string" then toks = { toks } end
                    for _, tk in ipairs(toks) do
                        if player_node_has(tk) then return true end
                    end
                end
            end
        end
    end
    return false
end
local function is_ks2_camstate(st) return match_level(st, ks2_vals, ks2_rules) end
local function is_ks3_camstate(st) return match_level(st, ks3_vals, ks3_rules) end
local function is_ks4_camstate(st) return match_level(st, ks4_vals, ks4_rules) end

-- [ZONES] KS-Level (2|3|4) fuer einen Event-Eintritt, wenn er in eine Zone faellt.
-- Match = gleiche Stage (nur Gate gegen Koordinaten-Kollision anderer Maps)
-- UND (Zone ohne camstate ODER gleicher camstate = gleicher Event-Typ)
-- UND Distanz <= Radius (KUGEL um die Event-Mitte, NICHT die ganze Stage).
-- Bei Ueberlappung: KS3 hat Vorrang, sonst die naechstgelegene Zone.
-- [KS4-ZONE 2026-07-17] KS4 laeuft ueber die "naechstgelegene"-Regel mit (kein Sonderrang): die KS-Grade
-- sind NICHT linear (KS3 = Mesh ganz aus / KS4 = Head+Hair aus, aber ALLE Scripte aus) -- ein Vorrang waere
-- willkuerlich. Ueberlappende Zonen verschiedener Grade also bewusst vermeiden, dann ist es eindeutig.
local function zone_level_for(entry)
    if not entry or not entry.pos then return nil end
    local px, py, pz = entry.pos.x, entry.pos.y, entry.pos.z
    local best_lvl, best_d2 = nil, nil
    for _, z in ipairs(KS_ZONES) do
        if z.stage == entry.stage and (z.camstate == nil or z.camstate == entry.camstate) then
            local dx, dy, dz = px - z.x, py - z.y, pz - z.z
            local d2 = dx * dx + dy * dy + dz * dz
            local r = z.r or 3.0
            if d2 <= r * r then
                if z.level == 3 then return 3 end
                if best_lvl == nil or d2 < best_d2 then best_lvl, best_d2 = z.level, d2 end
            end
        end
    end
    return best_lvl
end

-- ---------------------------------------------------------------------
-- Kriterien
-- ---------------------------------------------------------------------
local player_cam_td = sdk.find_type_definition("chainsaw.PlayerCameraController")
local gimmick_motion_td = sdk.find_type_definition("chainsaw.GimmickMotionCameraController")  -- [GIMMICK_KS3_SPOT]

local function is_real_cutscene()
    local csys = get_camera_system()
    if csys then
        local ev = safe(function() return csys:call("get_IsEventCamera") end)
        if ev == true then return true, "IsEventCamera" end
    end
    local gm = get_gui_manager()
    if gm then
        local pe = safe(function() return gm:call("get_IsPlayingEvent") end)
        -- [FIX 2026-07-10] IsPlayingEvent haengt nach einem Event noch kurz true, WAEHREND die PlayerCamera
        -- schon zurueck ist (CamState BattleNormal) -> das war der Uebergangs-3rd-Person nach der Cutscene.
        -- Nur als Cutscene werten, wenn NICHT die Player-Kamera aktiv ist (echte Cutscene = Nicht-Player-Cam,
        -- z.B. GimmickFixCameraController). PlayerCamera aktiv + IsPlayingEvent = Uebergang -> KEIN Killswitch
        -- (VR-First-Person). Der IsEventCamera-Zweig oben bleibt unberuehrt (starkes Signal fuer echte Cutscene).
        if pe == true then
            local busy = get_busy_controller()
            local is_pc = false
            if busy and player_cam_td then
                local ok, v = pcall(function() return busy:get_type_definition():is_a(player_cam_td) end)
                is_pc = ok and v == true
            end
            if not is_pc then return true, "IsPlayingEvent" end
        end
    end
    return false, nil
end

local function is_player_camera_active()
    local busy = get_busy_controller()
    if not busy then return false end
    local ok, is_pc = pcall(function()
        return player_cam_td and busy:get_type_definition():is_a(player_cam_td)
    end)
    return ok and is_pc == true
end

-- PlayerCameraState (Enum-Zahl) vom aktiven PlayerCameraController
local function read_cam_state(busy)
    if not busy then return nil end
    local sp = safe(function() return busy:get_field("_CurrentStateParam") end)
    if not sp then return nil end
    local st = safe(function() return sp:get_field("<State>k__BackingField") end)
    if st == nil then return nil end
    if type(st) == "number" then return st end
    local v = safe(function() return st:get_field("value__") end)
    if type(v) == "number" then return v end
    return nil
end

-- [GONDEL 2026-07-15] GimmickType (Enum-Zahl) vom aktiven PlayerCameraController -- selbes StateParam wie
-- read_cam_state, nur ein anderes Feld (Monitor liest es genauso: <GimmickType>k__BackingField).
local function read_gimmick_type(busy)
    if not busy then return nil end
    local sp = safe(function() return busy:get_field("_CurrentStateParam") end)
    if not sp then return nil end
    local gt = safe(function() return sp:get_field("<GimmickType>k__BackingField") end)
    if gt == nil then return nil end
    if type(gt) == "number" then return gt end
    local v = safe(function() return gt:get_field("value__") end)
    if type(v) == "number" then return v end
    return nil
end

-- [GONDEL 2026-07-15] Alle GimmickType-Enum-Werte, deren NAME mit "Gondola" beginnt (Monitor-Dump zeigte
-- "GondolaL" -- das L deutet auf Geschwister wie GondolaR hin, die wir nie gesehen haben). Ueber den Namen
-- statt hart auf den einen Int: kostet nichts und faengt Varianten mit, ohne dass wir sie kennen muessen.
-- Lazy (TDB evtl. im 1. Frame nicht bereit -> nil, naechster Frame neu), Muster wie coop_jacked_prio.
local GONDOLA_VALS = nil
local function gondola_vals()
    if GONDOLA_VALS ~= nil then return GONDOLA_VALS end
    local td = sdk.find_type_definition("chainsaw.CameraDefine.GimmickType")
    local fields = td and safe(function() return td:get_fields() end)
    if not fields then return nil end
    local out = {}
    for _, f in ipairs(fields) do
        local ok, nm = pcall(function() return f:get_name() end)
        if ok and type(nm) == "string" and nm:sub(1, 7) == "Gondola" then
            local v = safe(function() return f:get_data(nil) end)
            if type(v) ~= "number" then
                v = (type(v) == "userdata") and safe(function() return v:get_field("value__") end) or nil
            end
            if type(v) == "number" then out[v] = true end
        end
    end
    GONDOLA_VALS = out
    return GONDOLA_VALS
end

-- [GONDEL 2026-07-15] Steht Leon auf der Gondel? Live-Dump 2026-07-15 13:54 (Stage 56100):
-- CamState=Gimmick(15) GimmickType=GondolaL Player.State=ParentGimmick Occupied=CH_JACKED_GMK_HIGH(23)
-- -> fiel auf KS1 (voll/3rd-Person) ueber [camstate:15].
-- Anders als die Aufzuege meldet sich die Gondel per BENANNTEM GimmickType -> kein Positions-Raten noetig
-- (die Lift-Box mit ihrem viermal danebengeratenen ymax war genau daran gescheitert, dass GIMMICK-TYP "-" war).
-- [GONDEL-PARENT 2026-07-22] Stages, in denen der Spieler nachweislich an einem Gimmick haengt,
-- ohne dass die Engine es sonst irgendwo meldet (GIMMICK-TYP "-", Occupied UNSET, normale Player-Kamera).
-- BEWUSST eine Liste mit EINEM Eintrag: das ParentGimmick-Bit gilt auch fuer Leitern/Quetschstellen --
-- ohne Stage-Gate wuerde der Block quer durchs Spiel feuern.
local GONDOLA_PARENT_STAGES = { [60850] = true }
-- chainsaw.PlayerDefine.State ist eine BITMASKE; ParentGimmick = Bit 53 (= 9007199254740992).
-- Test per Modulo statt Bit-Operator (bleibt bei diesen Groessenordnungen exakt, verifiziert am
-- Dump-Wert 1161928703861587969 -> 1161928703861587969 % 2^54 = 9007199254740993 >= 2^53).
local PARENT_GIMMICK_BIT = 9007199254740992
local function has_parent_gimmick()
    local ctx = get_player_context(); if not ctx then return false end
    local v = safe(function() return ctx:call("get_State") end)
    if type(v) ~= "number" then
        v = (type(v) == "userdata") and safe(function() return v:get_field("value__") end) or nil
    end
    if type(v) ~= "number" then return false end
    local ok, r = pcall(function() return (v % (PARENT_GIMMICK_BIT * 2)) >= PARENT_GIMMICK_BIT end)
    return ok and r == true
end

local function is_on_gondola()
    local vals = gondola_vals(); if not vals then return false end
    local busy = get_busy_controller(); if not busy then return false end
    if not player_cam_td then return false end
    local ok, v = pcall(function() return busy:get_type_definition():is_a(player_cam_td) end)
    if not (ok and v == true) then return false end
    local gt = read_gimmick_type(busy)
    return gt ~= nil and vals[gt] == true
end

-- [BEARTRAP 2026-07-17] Alle GimmickType-Werte, deren NAME mit "LegHoldTrap" beginnt. Live gemessen,
-- waehrend man in der Falle sass: State=Gimmick(15) + GimmickType=LegHoldTrap(2).
-- ENUM-DUMP 2026-07-17 (chainsaw.CameraDefine.GimmickType, 16 Werte): es gibt genau EIN "LegHoldTrap",
-- KEINE Varianten (anders als Gondola, das L/R hat). Der Prefix-Match ist hier also gleichwertig zum
-- harten Int -- er bleibt nur, damit ein spaeteres Game-Update mit LegHoldTrapL/_Big von selbst mitlaeuft.
-- WICHTIG (= man-Wunsch "jede Beartrap ohne Abklappern"): dieser eine Typ gilt fuer ALLE Fallen im
-- Spiel -- die Erkennung haengt an keiner Stage und keiner Position, also gibt es nichts abzuklappern.
-- Lazy wie gondola_vals (TDB im 1. Frame evtl. nicht bereit -> nil, naechster Frame neu).
local LEGTRAP_VALS = nil
local function legtrap_vals()
    if LEGTRAP_VALS ~= nil then return LEGTRAP_VALS end
    local td = sdk.find_type_definition("chainsaw.CameraDefine.GimmickType")
    local fields = td and safe(function() return td:get_fields() end)
    if not fields then return nil end
    local out = {}
    for _, f in ipairs(fields) do
        local ok, nm = pcall(function() return f:get_name() end)
        if ok and type(nm) == "string" and nm:sub(1, 11) == "LegHoldTrap" then
            local v = safe(function() return f:get_data(nil) end)
            if type(v) ~= "number" then
                v = (type(v) == "userdata") and safe(function() return v:get_field("value__") end) or nil
            end
            if type(v) == "number" then out[v] = true end
        end
    end
    LEGTRAP_VALS = out
    return LEGTRAP_VALS
end

-- [BEARTRAP 2026-07-17] Steckt Leon in einer Beartrap? BEIDE Bedingungen gekoppelt (Entscheidung,
-- nicht nur GimmickType wie bei der Gondel): CamState == Gimmick(15) UND GimmickType == LegHoldTrap*.
-- Warum gekoppelt: der GimmickType steht im StateParam auch dann noch, wenn der State schon weiter ist
-- (STALE -- dieselbe Falle wie get_IsOpenDoubleDoor \ get_IsMoveGimmickRide, s. GIMMICK_FLAGS oben).
-- Das Gimmick-Gate ist die Flanke, die den KS wieder loslaesst, sobald das Befreien durch ist.
local function is_in_legholdtrap()
    local vals = legtrap_vals(); if not vals then return false end
    resolve_state_vals()   -- gimmick_int aufloesen: wird sonst erst im is_pc-Branch WEIT unten gesetzt,
                           -- also nach diesem Force-Branch -> waere hier nil. Idempotent/billig.
    if gimmick_int == nil then return false end
    local busy = get_busy_controller(); if not busy then return false end
    if not player_cam_td then return false end
    local ok, v = pcall(function() return busy:get_type_definition():is_a(player_cam_td) end)
    if not (ok and v == true) then return false end
    -- [KS-FORCE-BRANCH] CamState hier LIVE vom busy lesen, NICHT current_cam_state: das ist in
    -- Force-Branches eingefroren. [[Notiz]]
    if read_cam_state(busy) ~= gimmick_int then return false end
    local gt = read_gimmick_type(busy)
    return gt ~= nil and vals[gt] == true
end

local function read_stage_space()
    local ctx = get_player_context()
    if not ctx then return nil, nil end
    local stage = safe(function() return ctx:call("get_CurrentStageID") end)
    local space = safe(function() return ctx:call("get_CurrentSpaceID") end)
    return stage, space
end

-- [GIMMICK_KS3_SPOT 2026-07-12] Ans EVENT gekoppelt (kein Radius/Zeit): solange der busy-Kamera-Controller
-- ein GimmickMotionCameraController ist UND wir in einer der Gimmick-Stages sind -> KS3 (First-Person,
-- gesamtes Mesh aus). Der Controller-Wechsel zurueck auf PlayerCameraController beendet KS3.
-- Der Aufzug (auch Stage 53302) faellt NICHT rein: er nutzt PlayerCameraController, nicht GimmickMotion.
-- Stages begrenzen auf diese Map-Region (sonst wuerde JEDES GimmickMotion-Event so laufen).
-- 54400 = Quetsch-Event ("durchquetschen"). Das LightArea-Flag taugte NICHT als Merkmal: es heisst nur
-- "Licht/Lampe an" und gilt im GANZEN Level 54400 (auch beim normalen Rumlaufen) -> zog das ganze Level auf
-- KS3. Der GimmickMotionCameraController dagegen ist NUR beim Durchquetschen aktiv (per Monitor-Dump verglichen:
-- Event = GimmickMotionCameraController + Occupied CH_JACKED_GMK_HIGH; normal = PlayerCameraController).
-- [50401/50500 2026-07-19] Weitere Durchquetsch-Stelle (Monitor verifiziert: GimmickMotionCameraController
-- + Occupied CH_JACKED_GMK_HIGH, exakt wie 54400). DIESE Passage QUERT eine Stage-Grenze: Einstieg 50401 ->
-- Ausgang 50500 -> beide noetig, sonst blitzt/3rd-persont die zweite Haelfte. Lief mangels Eintrag auf KS1 ->
-- jetzt KS4 (First-Person). Beam-Schutz (Jack-Block) war dort schon aktiv (stageunabhaengig).
-- [55850 2026-07-21 -- Monitordump 20:58:22] Durchquetschen in Adas DLC-Stage. Monitor-verifiziert
-- exakt wie 54400/50401: GimmickMotionCameraController + Occupied CH_JACKED_GMK_HIGH(23). Der Killswitch
-- ist charakterunabhaengig -> Leon-Mechanik gilt 1:1, inkl. Antibeam (__re4_in_squeeze) gegen den
-- Rueckbeam am Spaltenende, den wir bei Leon ewig gesucht haben.
-- [55851 2026-07-21 -- Monitordump 21:04:17] Diese Passage QUERT eine Stage-Grenze, exakt wie
-- 50401 -> 50500 bei Leon: beim Austritt steht die Stage schon auf 55851, waehrend Cam + Occupied noch
-- das Quetsch-Event melden. Ohne Eintrag faellt is_gimmick_ks3_spot dort auf false -> KS1 = native
-- 3rd-Person blitzt kurz auf (live belegt: "Stage/Space: 55851 / 55850... Killswitch: KS1 (voll)").
-- Beide Stages noetig, der Exit-Grace allein deckt das nicht ab (er greift erst, wenn das Event ENDET).
-- [55852 2026-07-21 -- Monitordump 21:23:03] Naechste Quetschstelle derselben Passage, gleiche
-- Signatur (GimmickMotion + CH_JACKED_GMK_HIGH, Space 55850, Map 138.07/-28.99/-60.86). Ohne Eintrag KS1.
-- [61302 2026-07-21 -- Monitordump 23:36:29] Quetschstelle im Power-/Riddle-Bereich (Space 61303),
-- Signatur wie immer: GimmickMotionCameraController + Occupied CH_JACKED_GMK_HIGH(23). Ohne Eintrag KS1.
-- [61301 2026-07-21 -- Monitordump 23:40:33] Naechste Quetschstelle im selben Space 61303,
-- identische Signatur (GimmickMotion + CH_JACKED_GMK_HIGH). Wie 55850/51/52 laufen auch hier mehrere
-- Stages derselben Passage hintereinander -> jede braucht ihren Eintrag.
-- [60880 2026-07-22 -- Monitordump 14:00:06/14:01:28] Quetschstelle bei ADA (Space 60880),
-- identische Signatur: GimmickMotionCameraController + Occupied CH_JACKED_GMK_HIGH(23), davor
-- Gameplay/Jog an fast derselben Position (43.96/-3.66/252.95 -> 43.77/-3.66/252.55). Ohne Eintrag KS1.
local GKS3_STAGES = { [53303] = true, [53302] = true, [54400] = true, [50401] = true, [50500] = true, [55850] = true, [55851] = true, [55852] = true, [61302] = true, [61301] = true, [60880] = true }
-- [ZWEI EVENTS IN EINER STAGE 2026-07-21] In 55850 leben ZWEI GimmickMotion-Events: das Durchquetschen
-- (Occupied CH_JACKED_GMK_HIGH, Space 55850) und die Mini-Demo weiter unten (Occupied MINI_DEMO, Space
-- 51502). Die Kamera-Klasse ist bei BEIDEN identisch -> sie taugt hier nicht zur Unterscheidung, sonst
-- kaescht der erste Block (Squeeze) auch die Mini-Demo. In diesen Stages entscheidet deshalb AUSSCHLIESSLICH
-- die Occupied-Priority, welches Event laeuft. Kein Nachteil: die Priority haelt am Ende sogar laenger als
-- die Cam (genau der Blitz-Fix von 2026-07-19), der Latch + Exit-Grace bleibt unveraendert.
local PRIO_ONLY_STAGES = { [55850] = true }
-- [SQUEEZE-PRIO 2026-07-19] Occupied-Priority des Durchquetschens = CH_JACKED_GMK_HIGH (live verifiziert;
-- Demos nutzen GMK_DEMO(12)/CH_JACKED_GMK_HIGHEST_FOR_DEMO(30)). Lazy aufgeloest wie coop/grappled (TDB im
-- 1. Frame evtl. noch nicht bereit -> nil, naechster Frame neu). Nur fuer den Blitz-Schutz am Squeeze-Ende.
local SQUEEZE_HIGH_PRIO = nil
local function squeeze_high_prio()
    if SQUEEZE_HIGH_PRIO == nil then
        local td = sdk.find_type_definition("chainsaw.OccupiedMediatorPriority")
        local f = td and safe(function() return td:get_field("CH_JACKED_GMK_HIGH") end)
        local v = f and safe(function() return f:get_data(nil) end)
        if type(v) ~= "number" then
            v = type(v) == "userdata" and safe(function() return v:get_field("value__") end) or nil
        end
        SQUEEZE_HIGH_PRIO = v
    end
    return SQUEEZE_HIGH_PRIO
end
-- [BLITZ-FIX 2026-07-19] STAGE-GATED bleibt bewusst: CH_JACKED_GMK_HIGH ist die Klasse "high-prio
-- Gimmick-Jack", nicht beweisbar NUR Durchquetschen -> nach -Kriterium an die Stages gebunden. Der
-- 3rd-Person-Blitz am Spalten-Ende kam daher, dass KS4 an der GimmickMotion-Cam hing, die 1-2 Frames FRUEHER
-- loslaesst als das Occupied (live belegt: cam=PlayerCameraController waehrend prio noch CH_JACKED_GMK_HIGH).
-- Fix: KS4 greift jetzt auch bei Occupied==CH_JACKED_GMK_HIGH (haelt laenger) + Exit-Grace (~0.3s nachhalten)
-- ueber den Cam->Gameplay-Uebergang. Alles NUR innerhalb der GKS3_STAGES. Generalisieren = Stage-Check raus.
local function is_gimmick_ks3_spot()
    local stage = read_stage_space()
    if not GKS3_STAGES[stage] then return false end
    local raw = false
    -- (a) GimmickMotion-Kamera -- in PRIO_ONLY_STAGES uebersprungen (dort teilen sich zwei Events dieselbe Cam)
    if gimmick_motion_td and not PRIO_ONLY_STAGES[stage] then
        local busy = get_busy_controller()
        if busy then
            local ok, is_g = pcall(function() return busy:get_type_definition():is_a(gimmick_motion_td) end)
            if ok and is_g == true then raw = true end
        end
    end
    -- (b) Occupied CH_JACKED_GMK_HIGH -- haelt am Ende laenger als die Cam (Blitz-Schutz)
    if not raw then
        local want = squeeze_high_prio()
        if want ~= nil then
            local ctx = get_player_context()
            local occ = ctx and safe(function() return ctx:call("get_OccupiedInfo") end)
            local prio = occ and safe(function() return occ:call("get_Priority") end)
            if type(prio) ~= "number" then
                prio = type(prio) == "userdata" and safe(function() return prio:get_field("value__") end) or prio
            end
            if prio == want then raw = true end
        end
    end
    if raw then _G.__re4_squeeze_latch_t = os.clock(); return true end
    -- Exit-Grace: KS4 nach dem Event ~0.3s halten -> Cam->Gameplay-Uebergang ohne 3rd-Person-Blitz
    if (os.clock() - (rawget(_G, "__re4_squeeze_latch_t") or -1e9)) < 0.30 then return true end
    return false
end

-- [MINIDEMO_KS4 2026-07-21 -- Monitordump 20:13:03] Gimmick-Motion-Event in Stage 55850, das mangels
-- Eintrag auf KS1 (native 3rd-Person) lief. Der Dump beweist, dass es KEINE echte Cutscene ist
-- ("Cutscene: nein"): Busy-Controller = GimmickMotionCameraController, Occupied-Priority = MINI_DEMO(40),
-- CamState unlesbar ("-"). Also exakt die Klasse des Durchquetschens, nur mit anderer Priority -> dieselbe
-- Mechanik wie is_gimmick_ks3_spot, aber BEWUSST GETRENNT gehalten:
-- * eigene Stage-Liste -> MINI_DEMO ist eine allgemeine Demo-Prio, ohne Stage-Gate zoge es JEDE Mini-Demo
-- im Spiel auf KS4 (genau die Falle, die bei CH_JACKED_GMK_HIGH beschrieben ist).
-- * eigener Reason -> "ks3_gimmick" schaltet in firstperson.lua den Squeeze-Head-Nagel + Antibeam;
-- beides gehoert hier nicht hin (Head-Nagel kommt in KS4 ohnehin pauschal).
-- Der 3rd-Person-Toggle (__re4_ks_fp_enabled) braucht hier KEINE Sonderbehandlung: er greift zentral ueber
-- is_ks4 am Dateiende -- steht er auf aus, bleibt die Szene 3rd-Person und alle Scripte ruhen (= KS1-Bild).
local MINIDEMO_KS4_STAGES = { [55850] = true }
local MINIDEMO_PRIO = nil
local function minidemo_prio()
    if MINIDEMO_PRIO ~= nil then return MINIDEMO_PRIO end
    local td = sdk.find_type_definition("chainsaw.OccupiedMediatorPriority")
    local f = td and safe(function() return td:get_field("MINI_DEMO") end)
    local v = f and safe(function() return f:get_data(nil) end)
    if type(v) ~= "number" then v = (type(v) == "userdata") and safe(function() return v:get_field("value__") end) or v end
    if type(v) == "number" then MINIDEMO_PRIO = v end
    return MINIDEMO_PRIO
end
local function is_minidemo_ks4_spot()
    local stage = read_stage_space()
    if not MINIDEMO_KS4_STAGES[stage] then return false end
    local raw = false
    -- (a) GimmickMotion-Kamera -- in PRIO_ONLY_STAGES uebersprungen: dort laeuft auch das Durchquetschen
    -- ueber dieselbe Cam, und das gehoert in den Squeeze-Block (1f), nicht hierher.
    if gimmick_motion_td and not PRIO_ONLY_STAGES[stage] then
        local busy = get_busy_controller()
        if busy then
            local ok, is_g = pcall(function() return busy:get_type_definition():is_a(gimmick_motion_td) end)
            if ok and is_g == true then raw = true end
        end
    end
    -- (b) Occupied MINI_DEMO -- haelt am Ende laenger als die Cam (Blitz-Schutz, wie beim Squeeze belegt)
    if not raw then
        local want = minidemo_prio()
        if want ~= nil then
            local ctx = get_player_context()
            local occ = ctx and safe(function() return ctx:call("get_OccupiedInfo") end)
            local prio = occ and safe(function() return occ:call("get_Priority") end)
            if type(prio) ~= "number" then
                prio = type(prio) == "userdata" and safe(function() return prio:get_field("value__") end) or prio
            end
            if prio == want then raw = true end
        end
    end
    if raw then _G.__re4_minidemo_latch_t = os.clock(); return true end
    -- Exit-Grace: KS4 ~0.3s nachhalten -> Cam->Gameplay-Uebergang ohne 3rd-Person-Blitz
    if (os.clock() - (rawget(_G, "__re4_minidemo_latch_t") or -1e9)) < 0.30 then return true end
    return false
end

-- [GFIX_KS5 2026-07-21 -- Monitordump 21:37:13] Nach dem A-Halte-Event laeuft eine cutscene-AEHNLICHE
-- Sequenz (Cutscene-Flag steht auf "nein"), in der man sich selbst sieht -- in KS4 also kopflos, weil dort
-- nur Head/Hair ausgeblendet werden. gewollt das GESAMTE Mesh aus -> KS5.
-- ABGRENZUNG (wichtig): Dieses Event lief bisher im Squeeze-Block mit (Reason "ks3_gimmick"), weil in
-- Stage 55852 die Occupied-Priority identisch ist (CH_JACKED_GMK_HIGH). Der Squeeze-Block gilt aber AUCH
-- FUER LEON -- dort darf nichts geaendert werden. Sauberes Trennmerkmal ist die KAMERA:
-- Durchquetschen = GimmickMotionCameraController | dieses Event = GimmickFixCameraController
-- Beide Bedingungen (Cam UND Prio) werden verlangt; die A-Halte-Stelle in derselben Stage nutzt zwar auch
-- GimmickFix, aber Priority PL_USE_ITEM_WAIT(6) -> sie kann hier nicht mitgefangen werden.
local gimmick_fix_td = sdk.find_type_definition("chainsaw.GimmickFixCameraController")
local GFIX_KS5_STAGES = { [55852] = true }

-- [GFIX_KS4 2026-07-23 -- Monitordump 20:38] Ein Event mit chainsaw.GimmickFixCameraController,
-- Occupied-Priority CH_JACKED_GMK_LOW(3), Stage 44400. Der Monitor stufte es als KS1 ein und es
-- flackerte sekuendlich gegen ein natives KS4. Der gewollt es stabil als KS4. Streng gegated wie
-- der KS5-Spot: NUR diese Stage UND diese Kamera UND diese Priority -- die A-Halte-Stellen (Prio 6)
-- oder andere GimmickFix-Events fallen NICHT hinein.
local GFIX_KS4_STAGES = { [44400] = true }
local GFIX_LOW_PRIO = nil
local function gfix_low_prio()
    if GFIX_LOW_PRIO == nil then
        local td = sdk.find_type_definition("chainsaw.OccupiedMediatorPriority")
        local f = td and safe(function() return td:get_field("CH_JACKED_GMK_LOW") end)
        local v = f and safe(function() return f:get_data(nil) end)
        if type(v) ~= "number" then
            v = type(v) == "userdata" and safe(function() return v:get_field("value__") end) or nil
        end
        GFIX_LOW_PRIO = v or 3   -- Fallback: Dump zeigte (3)
    end
    return GFIX_LOW_PRIO
end
local function is_gimmickfix_ks4_spot()
    if not GFIX_KS4_STAGES[read_stage_space()] then return false end
    if not gimmick_fix_td then return false end
    local busy = get_busy_controller(); if not busy then return false end
    local ok, is_g = pcall(function() return busy:get_type_definition():is_a(gimmick_fix_td) end)
    if not (ok and is_g == true) then return false end
    local want = gfix_low_prio()
    local ctx = get_player_context()
    local occ = ctx and safe(function() return ctx:call("get_OccupiedInfo") end)
    local prio = occ and safe(function() return occ:call("get_Priority") end)
    if type(prio) ~= "number" then
        prio = type(prio) == "userdata" and safe(function() return prio:get_field("value__") end) or prio
    end
    return prio == want
end
local function is_gimmickfix_ks5_spot()
    if not GFIX_KS5_STAGES[read_stage_space()] then return false end
    local raw = false
    if gimmick_fix_td then
        local busy = get_busy_controller()
        if busy then
            local ok, is_g = pcall(function() return busy:get_type_definition():is_a(gimmick_fix_td) end)
            if ok and is_g == true then
                local want = squeeze_high_prio()   -- CH_JACKED_GMK_HIGH, lazy aus der TDB (Muster wie oben)
                if want ~= nil then
                    local ctx = get_player_context()
                    local occ = ctx and safe(function() return ctx:call("get_OccupiedInfo") end)
                    local prio = occ and safe(function() return occ:call("get_Priority") end)
                    if type(prio) ~= "number" then
                        prio = type(prio) == "userdata" and safe(function() return prio:get_field("value__") end) or prio
                    end
                    if prio == want then raw = true end
                end
            end
        end
    end
    if raw then _G.__re4_gfix_latch_t = os.clock(); return true end
    -- Exit-Grace wie beim Squeeze: 0.3s nachhalten -> kein 3rd-Person-Blitz am Uebergang
    if (os.clock() - (rawget(_G, "__re4_gfix_latch_t") or -1e9)) < 0.30 then return true end
    return false
end

-- [DEMO_EXCLUDE 2026-07-16] Laeuft gerade eine "Zwischendemo"/ein Gimmick-Motion-Event? (Busy-Controller =
-- GimmickMotionCameraController). Damit kann ein Stage-Force die Demos AUSSPAREN: dort soll die native
-- 3rd-Person laufen, kein KS-Force (normales Gameplay laeuft ueber PlayerCameraController). Ohne Stage-Grenze.
local function is_gimmick_motion_now()
    if not gimmick_motion_td then return false end
    local busy = get_busy_controller()
    if not busy then return false end
    local ok, is_g = pcall(function() return busy:get_type_definition():is_a(gimmick_motion_td) end)
    return ok and is_g == true
end

-- [DEMO_EXCLUDE 2026-07-16] Occupied-Prioritaeten, deren NAME "FOR_DEMO" enthaelt (z.B.
-- CH_JACKED_GMK_HIGHEST_FOR_DEMO) = gescriptete Demo-Events (Tuer-in-Ashley-Hold u.a.), die NATIV laufen
-- sollen. Anders als die GimmickMotion-Demos laufen die ueber PlayerCameraController -> is_gimmick_motion_now
-- faengt sie NICHT. Ueber den Namen statt hart auf 30: faengt Varianten mit. Lazy (Muster wie gondola_vals).
local DEMO_PRIOS = nil
local function demo_prios()
    if DEMO_PRIOS ~= nil then return DEMO_PRIOS end
    local td = sdk.find_type_definition("chainsaw.OccupiedMediatorPriority")
    local fields = td and safe(function() return td:get_fields() end)
    if not fields then return nil end
    local out = {}
    for _, f in ipairs(fields) do
        local ok, nm = pcall(function() return f:get_name() end)
        if ok and type(nm) == "string" and nm:find("FOR_DEMO", 1, true) then
            local v = safe(function() return f:get_data(nil) end)
            if type(v) ~= "number" then v = (type(v) == "userdata") and safe(function() return v:get_field("value__") end) or nil end
            if type(v) == "number" then out[v] = true end
        end
    end
    DEMO_PRIOS = out
    return DEMO_PRIOS
end
local function is_demo_priority_now()
    local vals = demo_prios(); if not vals then return false end
    local ctx = get_player_context(); if not ctx then return false end
    local occ = safe(function() return ctx:call("get_OccupiedInfo") end); if not occ then return false end
    local p = safe(function() return occ:call("get_Priority") end)
    if type(p) ~= "number" then p = p and safe(function() return p:get_field("value__") end) end
    return type(p) == "number" and vals[p] == true
end

-- [CARRY_SWITCH 2026-07-16] Traegt Leon gerade jemanden (Ashley)? <TargetJacked> ist true beim Tragen (auch
-- durch die Tuer), nil sobald die Cutscene sie uebernimmt. Zusammen mit der Stage der praezise Schalter:
-- gleiche Stage 68105, aber NACH der Cutscene TargetJacked=nil -> kein KS4-Force -> normales Gameplay.
local function is_carrying()
    local ctx = get_player_context(); if not ctx then return false end
    return safe(function() return ctx:get_field("<TargetJacked>k__BackingField") end) == true
end

-- [ELEVATOR_59100 2026-07-16] Aufzug gm81_511 (GmElevator) in Stage 59100 -> waehrend man drin steht KS4
-- (unser Aufzug-KS: resetBasePose beim Eintritt + movement fuer Yaw). Erkennung: get_IsPlInElevator auf
-- den GmElevator. Component gecacht, bei Stage-Wechsel/Verlust neu gesucht. NUR Stage 59100 -> kollidiert
-- NICHT mit den alten Aufzuegen (die ueber motion-Unparent/Zonen auf GAMEPLAY forcen).
local elev_td_59100 = sdk.typeof and sdk.typeof("chainsaw.GmElevator")
local elev59100_comp = nil
local function find_elevator_59100()
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager"); if not gm then return nil end
    local arr = safe(function() return gm:get_field("_MoveArray") end); if not arr then return nil end
    local n = safe(function() return arr:get_size() end) or 0
    for i = 0, n - 1 do
        local core = safe(function() return arr:get_element(i) end)
        local go = core and safe(function() return core:call("get_GameObject") end)
        local comp = go and elev_td_59100 and safe(function() return go:call("getComponent(System.Type)", elev_td_59100) end)
        if comp then return comp end   -- Stage 59100 hat nur einen GmElevator (gm81_511)
    end
    return nil
end
local function is_riding_elevator_59100()
    if read_stage_space() ~= 59100 then elev59100_comp = nil; return false end
    if not elev59100_comp then elev59100_comp = find_elevator_59100() end
    if not elev59100_comp then return false end
    return safe(function() return elev59100_comp:call("get_IsPlInElevator") end) == true
end

-- [JETSKI 2026-07-16] Jetski-Fahr-Stages (Space 59200), 1:1 aus dem alten Mod uebernommen (dort als
-- "Passthrough/Override"-Stages behandelt, wie Minecart). Auf diesen Stages -> KS4 (wie Minecart/Gondel:
-- alle Scripte aus, First-Person, Body sichtbar) + resetBasePose beim Eintritt. Die Jetski-BusyCam
-- (VehicleCam) gibt Position/Kamera komplett vor -> KEIN __re4_ks_keep_movement (movement wuerde gegen die
-- BusyCam arbeiten). Firstperson liest __re4_jetski_active fuer einen EIGENEN body-relativen HMD-Offset.
-- Stage-Liste = exakt die Stages, die im alten Mod die JETSKI_CFG-Offsets bekamen (identisch fuer KS + Offset).
local JETSKI_KS4_STAGES = {
    [59103]=true,   -- [MONITORDUMP 2026-07-16] Anfahr-/Fahr-Stage (Space 59200), VehicleCam -> KS4 wie die 592xx
    [59201]=true,[59202]=true,[59203]=true,[59204]=true,[59205]=true,[59206]=true,[59207]=true,
    [59209]=true,[59210]=true,[59211]=true,[59214]=true,[59215]=true,[59216]=true,[59217]=true,
    [59218]=true,[59219]=true,[59220]=true,[59221]=true,[59222]=true,
}
local function is_jetski_stage()
    return JETSKI_KS4_STAGES[read_stage_space()] == true
end

-- [MINECART_KS4 55201/55202 2026-07-12/07-13] Die Loren-Intros laufen ueber chainsaw.ActionCameraController
-- (Einstieg) bzw. chainsaw.VehicleCameraController (Fahrt-Intro) -- beides KEIN PlayerCameraController -> fiele in
-- den else-Zweig = KS1 (3rd-Person). Hier stattdessen KS4: ALLE Scripte aus + First-Person + Head/Hair aus, Body
-- sichtbar. Stage-Gate zwingend: ActionCam laeuft auch woanders (Grapple/Niederringen), VehicleCam beim Del-Lago-
-- Boot (46900) -> ohne Stage-Gate traefe es das mit. 55201 = Loren Part 1, 55202 = Loren Part 2 (Cart heisst dort
-- gm81_504_00_2, Part 1 = gm84_500). Der ECHTE Ride beider Parts ist stage-unabhaengig -> faellt durch auf 1h.
local MINECART_KS4_STAGES = { [55201] = true, [55202] = true }
local action_camera_td  = sdk.find_type_definition("chainsaw.ActionCameraController")
local vehicle_camera_td = sdk.find_type_definition("chainsaw.VehicleCameraController")
-- Rueckgabe: "cart" (ActionCameraController = Einstieg) | "cart2" (VehicleCameraController = Fahrt) | nil.
-- Beide -> KS4, aber getrennt geflaggt, damit firstperson pro Szene einen eigenen HMD-Offset legen kann.
local function minecart_ks4_kind()
    if not MINECART_KS4_STAGES[read_stage_space()] then return nil end
    local busy = get_busy_controller()
    if not busy then return nil end
    local td = safe(function() return busy:get_type_definition() end)
    if not td then return nil end
    local function isa(t)
        if not t then return false end
        local ok, v = pcall(function() return td:is_a(t) end)
        return ok and v == true
    end
    if isa(action_camera_td)  then return "cart"  end
    if isa(vehicle_camera_td) then return "cart2" end
    return nil
end

-- [JETSKI SITZ-ERKENNUNG 2026-07-16] Nur die Anfahr-Stage 59103 STARTET, waehrend Leon noch zu Fuss zum
-- Jetski laeuft (PlayerCameraController) -> KS4 wuerde dort zu frueh zuenden. Deshalb NUR fuer 59103
-- zusaetzlich verlangen, dass die Fahrt-Kamera VehicleCameraController busy ist (= sitzt tatsaechlich auf dem
-- Jetski, wie Minecart kind "cart2"). Zu Fuss = PlayerCameraController; Anfahr-Cutscene = EventCameraController
-- (wird eh von is_real_cutscene abgefangen). Die reinen Fahr-Stages 592xx: da sitzt man immer schon -> Stage
-- reicht, kein Kamera-Check ("danach ist es egal"). Del-Lago-Boot nutzt auch VehicleCam, aber Stage 46900.
local function is_on_jetski()
    local stage = read_stage_space()
    if not JETSKI_KS4_STAGES[stage] then return false end
    if stage ~= 59103 then return true end   -- 592xx: reine Fahrt -> Stage genuegt
    local busy = get_busy_controller()       -- 59103: erst wenn die Fahrt-Kamera aktiv ist
    if not busy or not vehicle_camera_td then return false end
    local ok, is_v = pcall(function() return busy:get_type_definition():is_a(vehicle_camera_td) end)
    return ok and is_v == true
end

-- [BOAT 2026-07-18] Generische "sitzt auf einem Boot"-Erkennung ueber die native Engine-Wahrheit
-- (PlayerBaseContext.get_IsBoat) -- stageunabhaengig, greift auf JEDEM Boot (nicht nur Del-Lago 46900).
-- Der throwsight-Fisch-Boss wird im Boot-KS4-Branch SEPARAT per is_throwsight_stage ausgeschlossen.
local function is_on_boat()
    local ctx = get_player_context()
    if not ctx then return false end
    if safe(function() return ctx:call("get_IsBoat") end) ~= true then return false end
    -- [BOAT-EINSTIEG 2026-07-18] get_IsBoat ist SCHON beim Einsteigen true, aber der Einstieg laeuft auf dem
    -- ActionCameraController (= "cart", wie der Minecart-Einstieg), die FAHRT auf VehicleCameraController.
    -- so gewollt: Einsteigen soll KS1 bleiben, erst IM Boot (Fahrt) KS4. Also: ActionCameraController busy
    -- -> hier NICHT als Boot zaehlen -> der Boot-KS4-Branch feuert nicht -> ActionCam faellt auf KS1 zurueck.
    local busy = get_busy_controller()
    if busy and action_camera_td then
        local ok, is_a = pcall(function() return busy:get_type_definition():is_a(action_camera_td) end)
        if ok and is_a == true then return false end
    end
    return true
end

-- [RAILCAR_MODE 2026-07-12] Auf dem Schienenwagen (an das Kart geparentet) laeuft NUR motion + arm_chain +
-- firstperson; Head/Hair aus (Body sichtbar); ALLES andere (movement/holster/reload/gestures/haptic/knife/...)
-- aus. STAGE-UNABHAENGIG (die Fahrt wechselt staendig die Stage): Merkmal = getPlayerRailCar ~= nil (ein
-- Spieler-Schienenwagen existiert) UND Player.State traegt ParentGimmick (an den Wagen geparentet). Das Intro
-- (55201) hat KEIN ParentGimmick -> bleibt KS4/KS5. Elevator/Boot haben keinen RailCar -> greifen nicht mit.
-- Umsetzung: killswitch AN + ks4 (Head/Hair aus, Body sichtbar, ungatete Scripte aus, firstperson bleibt) +
-- Flag __re4_railcar_mode, das motion/arm_chain TROTZ killswitch weiterlaufen laesst.
local railcar_mgr = nil
local parentgimmick_bit = nil
local function resolve_parentgimmick_bit()
    if type(parentgimmick_bit) == "number" then return end
    local td = sdk.find_type_definition("chainsaw.PlayerDefine.State")
    local fields = td and safe(function() return td:get_fields() end)
    if not fields then return end
    for _, f in ipairs(fields) do
        if safe(function() return f:is_static() end) and safe(function() return f:get_name() end) == "ParentGimmick" then
            local v = safe(function() return f:get_data(nil) end)
            if type(v) ~= "number" then
                v = type(v) == "userdata" and safe(function() return v:get_field("value__") end) or nil
            end
            if type(v) == "number" then parentgimmick_bit = v end
            return
        end
    end
end
local function is_on_railcar()
    if not railcar_mgr then railcar_mgr = sdk.get_managed_singleton("chainsaw.RailCarManager") end
    if not railcar_mgr then return false end
    local car = safe(function() return railcar_mgr:call("getPlayerRailCar") end)
    if car == nil then return false end   -- gar kein Spieler-Schienenwagen -> definitiv nicht auf dem Cart
    -- (a) [EINSTIEGS-BLITZ-FIX] VehicleCameraController aktiv = Fahrt-Kamera -> SOFORT railcar_mode, auch bevor
    -- ParentGimmick gesetzt ist (sonst 1-2 Frames else=KS1 = kurzer 3rd-Person-Blitz). Das Intro (55201) wird
    -- vom Minecart-Gate DAVOR abgefangen (KS5), erreicht diese Funktion also nicht.
    local busy = get_busy_controller()
    if busy and vehicle_camera_td then
        local ok, is_v = pcall(function() return busy:get_type_definition():is_a(vehicle_camera_td) end)
        if ok and is_v == true then return true end
    end
    -- (b) sonst: an das Kart geparentet (ParentGimmick) -> deckt Frames ab, wo die Kamera kurz wechselt
    resolve_parentgimmick_bit()
    if type(parentgimmick_bit) ~= "number" then return false end
    local ctx = get_player_context()
    if not ctx then return false end
    local st = safe(function() return ctx:call("get_State") end)
    if type(st) ~= "number" then
        st = type(st) == "userdata" and safe(function() return st:get_field("value__") end) or nil
    end
    if type(st) ~= "number" then return false end
    return (st & parentgimmick_bit) ~= 0
end

-- [THROWSIGHT] Del-Lago-Bootkampf mit Harpune: Stage 46900_46900 UND Leons Body ist ans
-- Boot-Objekt "gm02_500_00_1" reparented. NUR dieser Abschnitt bleibt First-Person (KS aus).
-- Die reine Bootfahrt (gm02_500_00_2) bekommt bewusst KEINE Ausnahme -> bleibt 3rd-Person.
-- Erkennung 1:1 aus re4_vr_binding (dort solide bewaehrt). Live verifiziert: im Boss laeuft ein
-- VehicleCameraController (kein PlayerCameraController) -> fiele sonst auf KS1 (voll).
local function is_throwsight_stage()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    if not cm then return false end
    local ctx = safe(function() return cm:call("getPlayerContextRef") end)
    if not ctx then return false end
    local stage = safe(function() return ctx:call("get_CurrentStageID") end)
    local space = safe(function() return ctx:call("get_CurrentSpaceID") end)
    if not stage or not space then return false end
    if tostring(stage) .. "_" .. tostring(space) ~= "46900_46900" then return false end
    local body = safe(function() return ctx:call("get_BodyGameObject") end)
    if not body then return false end
    local tf = safe(function() return body:call("get_Transform") end)
    if not tf then return false end
    local current = tf
    for i = 1, 10 do
        local parent_tf = safe(function() return current:call("get_Parent") end)
        if not parent_tf then return false end
        local parent_go = safe(function() return parent_tf:call("get_GameObject") end)
        if parent_go then
            local name = safe(function() return parent_go:call("get_Name") end)
            if name and string.find(tostring(name), "gm02_500_00_1", 1, true) then
                return true
            end
        end
        current = parent_tf
    end
    return false
end

-- ---------------------------------------------------------------------
-- Evaluate (RE9-Muster: ein zentraler Pass pro Frame auf UpdateScene)
-- ---------------------------------------------------------------------
-- [LEANING_LADDER] Erkennung schraeger Leitern: Hook auf GmLadderBase.tryUse (feuert beim Besteigen).
-- Ist die Leiter eine GmLeaningLadder (schraeg, NICHT GmUprightLadder) -> Latch _G.__re4_leaning_ladder_mounted.
-- Downstream NUR im ks4_ladder-Branch (Klettern) genutzt + im Gameplay-Branch zurueckgesetzt (off ladder).
-- sdk.hook -> Game-Neustart noetig; Guard gegen Doppel-Hook bei Reset Scripts.
if not _G.__re4_leaning_ladder_hook then
    _G.__re4_leaning_ladder_hook = true
    local ladder_td   = sdk.find_type_definition("chainsaw.GmLadderBase")
    local leaning_def = sdk.find_type_definition("chainsaw.GmLeaningLadder")
    local m = ladder_td and ladder_td:get_method("tryUse")
    if m and leaning_def then
        pcall(function()
            sdk.hook(m, function(args)
                pcall(function()
                    local ladder = sdk.to_managed_object(args[1])   -- args[1]=this (Ladder), args[2]=user-GO
                    if ladder and ladder:get_type_definition():is_a(leaning_def) then
                        _G.__re4_leaning_ladder_mounted = true
                    end
                end)
            end, nil)
        end)
    end
end

-- [ELEVATOR 2026-07-12] "Reverse-Killswitch": Aufzug (Stage 53202) ist KEIN natives KS-Event (CamState bleibt
-- "Normal"), flackert aber offenbar kurz weg -> killswitch kippt auf 3rd-Person/motion-Jank. In der von->bis-Box
-- GAMEPLAY PINNEN: killswitch AUS -> movement/motion/firstperson bleiben AN, First-Person, Head/Hair via
-- Gameplay-Material-Regel aus. Live-Player-Pos (haelt die ganze Fahrt).
local ELEV = {
    stage = 53202,
    x1 = 130.45, y1 = 27.33, z1 = 64.28,   -- Start
    x2 = 131.32, y2 = 33.20, z2 = 63.60,   -- Ende
    mxz = 3.0,                              -- XZ-Toleranz (m)
    start_release = 0.005,                  -- [UNTEN] Pin erst ein Fitzel NACH dem Start (nachdem Y hochgeht):
                                            -- untere Kante = min-Y PLUS diesen Wert.
    top_release   = 0.005,                  -- [OBEN] Pin ein Fitzel VOR dem Ziel loesen: obere Kante = max-Y MINUS.
}
local function is_in_elevator()
    if read_stage_space() ~= ELEV.stage then return false end
    local p = get_player_pos()
    if not p then return false end
    local xmin = math.min(ELEV.x1, ELEV.x2) - ELEV.mxz
    local xmax = math.max(ELEV.x1, ELEV.x2) + ELEV.mxz
    local zmin = math.min(ELEV.z1, ELEV.z2) - ELEV.mxz
    local zmax = math.max(ELEV.z1, ELEV.z2) + ELEV.mxz
    local ymin = math.min(ELEV.y1, ELEV.y2) + ELEV.start_release   -- [UNTEN] Pin erst ein Fitzel nach dem Start
    local ymax = math.max(ELEV.y1, ELEV.y2) - ELEV.top_release     -- [OBEN] Pin ein Fitzel VOR dem Ziel loesen
    return p.x >= xmin and p.x <= xmax and p.z >= zmin and p.z <= zmax and p.y >= ymin and p.y <= ymax
end

-- [ELEVATOR_TROUBLE 2026-07-19] Das "ElevatorTrouble"-Event (Monitordump: CamState=Gimmick +
-- GimmickType=ElevatorTrouble, Stage 53202) soll KS4 sein (First-Person, Head/Hair aus, alle Scripte aus)
-- statt der Aufzug-GAMEPLAY-Gate. Erkennung wie Beartrap: GEKOPPELT CamState==Gimmick UND GimmickType-Name
-- beginnt mit "ElevatorTrouble" (GimmickType bleibt STALE, wenn der State schon weiter ist -> Gimmick-Gate
-- als Flanke). Ueber den Namen statt hart auf den Int (faengt evtl. Varianten mit). Lazy wie legtrap_vals.
local ELEVTROUBLE_VALS = nil
local function elevtrouble_vals()
    if ELEVTROUBLE_VALS ~= nil then return ELEVTROUBLE_VALS end
    local td = sdk.find_type_definition("chainsaw.CameraDefine.GimmickType")
    local fields = td and safe(function() return td:get_fields() end)
    if not fields then return nil end
    local out = {}
    for _, f in ipairs(fields) do
        local ok, nm = pcall(function() return f:get_name() end)
        if ok and type(nm) == "string" and nm:sub(1, 15) == "ElevatorTrouble" then
            local v = safe(function() return f:get_data(nil) end)
            if type(v) ~= "number" then
                v = (type(v) == "userdata") and safe(function() return v:get_field("value__") end) or nil
            end
            if type(v) == "number" then out[v] = true end
        end
    end
    ELEVTROUBLE_VALS = out
    return ELEVTROUBLE_VALS
end
local function is_elevator_trouble()
    local vals = elevtrouble_vals(); if not vals then return false end
    resolve_state_vals()   -- gimmick_int aufloesen (Force-Branch laeuft vor dem is_pc-Zweig)
    if gimmick_int == nil then return false end
    local busy = get_busy_controller(); if not busy then return false end
    if not player_cam_td then return false end
    local ok, v = pcall(function() return busy:get_type_definition():is_a(player_cam_td) end)
    if not (ok and v == true) then return false end
    -- [KS-FORCE-BRANCH] CamState LIVE vom busy (current_cam_state ist hier eingefroren).
    if read_cam_state(busy) ~= gimmick_int then return false end
    local gt = read_gimmick_type(busy)
    return gt ~= nil and vals[gt] == true
end

-- [ELEVATOR2 2026-07-12] Aufzug Stage 53302 (Studierzimmer-Keller). Force-Trigger = (a) Parent-Flag ODER
-- (b) Positions-Box. Der Parent-Check taugt allein NICHT: motion.lua un-parentet jeden Frame -> die Kette ist
-- beim Pruefen meist schon null (live gemessen: get_Parent == null trotz Aufzug). Deshalb ist die Y-Box der
-- stabile Trigger (wie Aufzug 1). WICHTIG: Puffer nach AUSSEN -- oben live gemessen y=19.027, ein Fitzel nach
-- innen (altes y_release) schnitt genau da ab -> Force fiel oben aus = "bricht beim Hochfahren".
local ELEV2 = {
    stage = 53302,
    x1 = 89.77, y1 = 19.03, z1 = 107.50,   -- oben
    x2 = 90.14, y2 = 13.22, z2 = 108.50,   -- unten
    mxz = 3.0, y_pad = 0.30,               -- XZ-Toleranz / Y-Puffer nach AUSSEN (oben+unten sicher drin)
}
local function is_in_elevator2_zone()
    if read_stage_space() ~= ELEV2.stage then return false end
    local p = get_player_pos()
    if not p then return false end
    local xmin = math.min(ELEV2.x1, ELEV2.x2) - ELEV2.mxz
    local xmax = math.max(ELEV2.x1, ELEV2.x2) + ELEV2.mxz
    local zmin = math.min(ELEV2.z1, ELEV2.z2) - ELEV2.mxz
    local zmax = math.max(ELEV2.z1, ELEV2.z2) + ELEV2.mxz
    local ymin = math.min(ELEV2.y1, ELEV2.y2) - ELEV2.y_pad   -- unten mit Puffer
    local ymax = math.max(ELEV2.y1, ELEV2.y2) + ELEV2.y_pad   -- oben mit Puffer
    return p.x >= xmin and p.x <= xmax and p.z >= zmin and p.z <= zmax and p.y >= ymin and p.y <= ymax
end
-- [ELEV_LIVE_CAM 2026-07-15] Frischer PlayerCameraState fuer die Aufzug-Zonen-Pruefung.
-- WARUM: current_cam_state wird erst im is_pc-Branch WEIT unten gesetzt (Z.~1113/1128). Der Aufzug-Force
-- returnt lange davor -> ab dem ersten Force-Frame friert current_cam_state auf dem Wert von VOR dem Aufzug
-- ein (Gameplay = 2). Der ZONE_VORTRITT verglich also die gespeicherten KS-Zonen (Button = camstate 15,
-- aufgenommen als die Erkennung dort noch lief) gegen einen toten Wert -> zone_level_for lieferte immer nil
-- -> Button-KS2 kam nie. Live lesen statt cachen (dasselbe Muster wie bei den anderen kritischen Gates).
-- nil, wenn kein PlayerCameraController aktiv (Cutscene/Gimmick-Cam) -- dann matcht nur eine camstate-lose Zone.
local function read_live_cam_state()
    local busy = get_busy_controller()
    if not busy or not player_cam_td then return nil end
    local ok, v = pcall(function() return busy:get_type_definition():is_a(player_cam_td) end)
    if not (ok and v == true) then return nil end
    return read_cam_state(busy)
end

-- [ELEVATOR3 2026-07-15] Lift (gm81_507_00_リフト), Stage 55300. Wie Aufzug 1/2: das Parent-Flag taugt allein
-- NICHT (motion.lua un-parentet jeden Frame -> Kette beim Pruefen meist null) -> Positions-Box = stabiler Trigger.
-- XZ leicht driftend (X 178->179 / Z 89.5->88.3) -> Saeule mit Puffer. Konstanten inline (kein ELEV3-Table).
local function is_in_elevator3_zone()
    if read_stage_space() ~= 55300 then return false end
    local p = get_player_pos()
    if not p then return false end
    return p.x >= 175.5 and p.x <= 181.6      -- X ~178.2 durchgehend +/- Puffer
       and p.z >= 85.8  and p.z <= 92.0       -- Z ~88.6 durchgehend +/- Puffer
       -- [Y 2026-07-15] ymin = -75.14: deckt den Button (-74.545) MIT ab -> lueckenlose First-Person, kein
       -- KS1-Frame im Uebergang Button->Fahrt. Der Button-KS2 darf bleiben: bei passender Zone gibt ihm
       -- der Vortritt unten kurz KS2 (auch first-person, nur Head/Hair aus) -> nie das stoerende KS1/3rd.
       -- KEIN ymax (bewusst): der Schacht ist eine Saeule, und wie hoch die Fahrt endet, wurde nie gemessen
       -- (der alte Decision-Logger machte bei y=-8 zu). Jedes geratene ymax (-19.08 / -12.50 / -6.00) lag
       -- zu tief -> Force fiel MITTEN in der Fahrt weg -> KS1/3rd-Person. Das obere Ende braucht die Box
       -- nicht zu kennen: die Cutscene oben faengt der is_real_cutscene-Guard im Force-Branch ab, eine
       -- gespeicherte KS-Zone der ZONE_VORTRITT dort, und beim Aussteigen verlaesst man die XZ-Saeule.
       and p.y >= -75.14
end
local function is_parented_to_elevator()
    return rawget(_G, "__re4_on_elevator2") == true
end

-- [ELEVATOR5 2026-07-15] Aufzug in Space 56200 (Stage 56300 unten <-> 56201 oben; die Stage WECHSELT
-- waehrend der Fahrt, es ist EIN Aufzug). Live per Monitor-Dump an beiden Endpunkten gemessen:
-- unten 16:07 -> Stage 56300, Map 300.90 / -3.26 / -105.52
-- oben 16:10 -> Stage 56201, Map 300.80 / 48.23 / -105.36
-- Dieser Aufzug ist anders als 1/2/3: KEIN Transform-Parenting (Body-Parent-Kette ist leer, live belegt
-- per re4_zz_elev_diag.lua) -> motions Un-Parenting greift hier nie, __re4_on_elevator2 bleibt false.
-- Waehrend der Fahrt ist der CamState 0/Normal, also von normalem Herumstehen NICHT unterscheidbar --
-- es gibt kein CamState-/Flag-Muster, an dem man die Fahrt festmachen koennte. Die KS2-Blitze
-- (cam 27 -> 15) dauern ~1s und sind nur das Ein-/Aussteigen.
-- TRIGGER daher: in der Kabine (Stage + XZ-Radius) UND Y bewegt sich. Steht die Kabine, bleibt es
-- Gameplay (einsteigen, Knopf druecken, umsehen); sobald es losfaehrt -> KS4 (alles aus, nativ mitfahren).
-- XZ-Radius bewusst grosszuegig (4m): die Dump-Werte sind fast identisch, weil man mittig stand --
-- das ist NICHT die Kabinenbreite. Kein enges XZ raten (Lehre vom Lift gestern).
-- Gemessene Endpunkte (Monitor-Dumps 16:07 unten / 16:10 oben). Der Aufzug haelt nur an diesen beiden.
local ELEV5_X, ELEV5_Z, ELEV5_R = 300.85, -105.44, 4.0
local ELEV5_Y_UNTEN, ELEV5_Y_OBEN, ELEV5_Y_TOL = -3.26, 48.23, 1.5
-- target = der Endpunkt, zu dem gefahren wird (der ANDERE als der Startpunkt). moved_once = hat sich die
-- Kabine seit dem Knopfdruck ueberhaupt schon bewegt? Beides noetig, s. elevator5_update.
local elev5 = { latch = false, prev_gim = false, y = nil, t = 0.0, still_since = 0.0,
                target = nil, moved_once = false }
local function is_in_elevator5_cabin()
    local stg = read_stage_space()
    -- BEIDE Stages: die Stage WECHSELT waehrend der Fahrt (56300 unten <-> 56201 oben, Space bleibt 56200).
    -- Nur eine davon -> der Latch riss mitten in der Fahrt ab.
    if stg ~= 56300 and stg ~= 56201 then return false end
    local p = get_player_pos(); if not p then return false end
    if p.y < -10.0 or p.y > 55.0 then return false end   -- Sicherheitsnetz gegen ganz andere Orte der Stage
    local dx, dz = p.x - ELEV5_X, p.z - ELEV5_Z
    return (dx * dx + dz * dz) <= (ELEV5_R * ELEV5_R)
end
local function elev5_at_endpoint(y)
    return math.abs(y - ELEV5_Y_UNTEN) <= ELEV5_Y_TOL or math.abs(y - ELEV5_Y_OBEN) <= ELEV5_Y_TOL
end
-- [ELEVATOR5 LATCH] Startschuss = der Button-Gimmick, NICHT die Y-Bewegung: waehrend der Fahrt ist der
-- CamState 0/Normal und damit von normalem Stehen ununterscheidbar (live belegt). Beim Button dagegen
-- steht CamState=Gimmick(15) + Player.State=ParentGimmick (Dump 16:20:23).
-- Scharf: in der Kabine + an einem Endpunkt + der Gimmick ist gerade VORBEI (Flanke 15 -> nicht-15).
-- -> Der Knopf selbst bleibt dadurch unberuehrt (laeuft weiter ueber die gecapturte KS2-Zone), der
-- Latch greift erst danach. Gilt oben wie unten -- man kann an beiden Enden druecken.
-- Aus: anderer Endpunkt erreicht ODER Stillstand >1.5s ODER Kabine verlassen.
-- -> Das Stillstands-Netz ist Absicht: ohne es haengt der Latch fuer immer, falls die Fahrt mal nicht
-- am erwarteten Y ankommt (Zwischenstopp/Abbruch) -> man saesse dauerhaft im Killswitch fest.
-- CamState LIVE lesen (read_live_cam_state), nicht current_cam_state: das ist in Force-Branches
-- eingefroren -- dieselbe Falle, die den Aufzug-Button gekostet hat.
local function elevator5_update()
    local p = get_player_pos()
    if not p then elev5.latch = false; elev5.prev_gim = false; elev5.y = nil; return false end
    resolve_state_vals()   -- gimmick_int aufloesen: passiert sonst erst im is_pc-Branch WEIT unten, also
                           -- nach diesem Branch -> waere hier beim ersten Frame nil. Ist idempotent/billig.
    local now = os.clock()
    local cam = read_live_cam_state()
    local gim = (gimmick_int ~= nil and cam == gimmick_int)
    if elev5.prev_gim and not gim and elev5_at_endpoint(p.y) then
        elev5.latch = true                      -- Gimmick vorbei + wir stehen am Endpunkt -> Fahrt beginnt
        elev5.y = p.y; elev5.t = now; elev5.still_since = now
        elev5.moved_once = false
        -- [FIX 2026-07-15] ZIEL = der ANDERE Endpunkt. Vorher wurde gegen BEIDE geprueft -> beim Losfahren
        -- steht man ja noch am Start, also war "Ziel erreicht" ab dem ersten Frame wahr -> Latch fiel
        -- sofort wieder = das Flackern.
        elev5.target = (math.abs(p.y - ELEV5_Y_UNTEN) <= ELEV5_Y_TOL) and ELEV5_Y_OBEN or ELEV5_Y_UNTEN
    end
    elev5.prev_gim = gim
    if elev5.latch then
        if (now - elev5.t) >= 0.15 then
            if math.abs(p.y - (elev5.y or p.y)) > 0.05 then
                elev5.still_since = now
                elev5.moved_once = true   -- ab jetzt darf das Stillstands-Netz greifen
            end
            elev5.y = p.y; elev5.t = now
        end
        -- Ziel erreicht -> fertig.
        if elev5.target and math.abs(p.y - elev5.target) <= ELEV5_Y_TOL then elev5.latch = false end
        -- Sicherheitsnetz gegen ein ewig haengendes Latch (Fahrt kommt nie am Ziel an). ERST scharf, wenn
        -- die Kabine sich mindestens einmal bewegt hat: zwischen Knopfdruck und Anfahren steht y still --
        -- ohne diesen Guard feuerte das Netz WAEHREND des Anlaufs und riss den Latch weg (Flackern #2).
        if elev5.moved_once and (now - elev5.still_since) > 1.5 then elev5.latch = false end
    end
    return elev5.latch
end

local function evaluate_core()
    pin_release_active = false   -- default; nur im is_pc-Branch ggf. gesetzt
    ks2_active = false           -- default; nur im is_pc-Branch ggf. gesetzt
    ks3_active = false
    ks4_active = false
    ks5_active = false
    boxbreak_active = false
    _G.__re4_leaning_ladder_active = false   -- [LEANING_LADDER] default aus; nur ks4_ladder-Branch setzt true
    _G.__re4_minecart_ks4_active = false     -- [MINECART_OFFSET] default aus; nur der Minecart-KS4-Spot (ActionCam) setzt true
    _G.__re4_minecart2_ks4_active = false    -- [MINECART2_OFFSET] default aus; nur der Minecart-KS4-Spot (VehicleCam) setzt true
    _G.__re4_grappled_active = false         -- [GRAPPLE_OFFSET] default aus; nur der Grapple-Branch (1i) setzt true
    _G.__re4_gondola_active = false          -- [GONDEL] default aus; nur der Gondel-Branch (1e2) setzt true
    _G.__re4_railcar_mode = false            -- [RAILCAR] default aus; nur der RailCar-Mode setzt true (motion/arm trotz KS an)
    _G.__re4_jetski_active = false           -- [JETSKI] default aus; nur der Jetski-Branch (Stages 592xx) setzt true
    _G.__re4_boat_active = false             -- [BOAT] default aus; nur der Boot-KS4-Branch (get_IsBoat, nicht throwsight) setzt true
    _G.__re4_forcecrouch_ks4_active = false  -- [FORCECROUCH_KS4] default aus; nur der 40501/40502-ForceCrouch-Branch setzt true
    _G.__re4_in_squeeze = false              -- [ANTIBEAM] an nur im Durchquetschen (ks3_gimmick) -> re4_vr_squeeze_antibeam nutzt es
    _G.__re4_ks_keep_movement = false        -- [KS_KEEP_MOVEMENT] default aus; wird gesetzt, wenn movement trotz voll-aus-KS (KS1/4/5) weiterlaufen soll (Turn-Kopplung). Test: ueber die Stage; final: an KS1/4/5 allgemein.
    -- 1. Force (UI/Debug)
    if force_killswitch then
        killswitch_active = true
        activating_reason = "force"
        return
    end

    -- 1b. [SCOPE_KILLSWITCH] Externes Force-Flag (von re4_vr_weapons gesetzt, wenn die Waffe
    -- per montiertem Scope gezielt wird = _IsViaScope). Gewinnt VOR der Gameplay-Allowlist
    -- (in der "ViaScope" sonst als Gameplay zaehlt) -> alles aus (motion/materials/firstperson).
    if rawget(_G, "__re4_force_killswitch_scope") == true then
        killswitch_active = true
        activating_reason = "viascope"
        return
    end

    -- 1c. [BOLT_CYCLE] Externes Force-Flag (von re4_vr_weapons gesetzt): wp4400 im Iron-Sight, waehrend
    -- die native Bolt-Cycle-Anim "Aim_Fire.PumpAction" laeuft (CamState=PumpAction, s. Monitordump 2026-07-18).
    -- [BOLTCYCLE->KS4 2026-07-18] FRUEHER killswitch_active pur = KS1 (voll) -> firstperson AUS -> die native
    -- Nachlade-Anim wurde in 3rd-Person gezeigt. Jetzt KS4: First-Person BLEIBT (keep_fp in firstperson.active),
    -- Head/Hair + alle Scripte aus -> das Spiel animiert den Bolt-Reload kurz selbst, aber aus Leons Augen.
    if rawget(_G, "__re4_force_killswitch_bolt") == true then
        killswitch_active = true
        ks4_active = true
        _G.__re4_ks4_active = true
        activating_reason = "boltcycle"
        return
    end

    -- 1c1. [BULLETRUSH 2026-08-05] Mercenaries-Ragemodus. Externes Force-Flag, gesetzt von
    -- re4_vr_merc.lua aus `Ch6CommonHeadUpdater.get_PlayingBulletRush` (mit re4_zzz_rage_probe
    -- gemessen). Waehrend der Rage pruegelt der Body nativ und beamt sich von Gegner zu Gegner,
    -- der CamState bleibt dabei aber Gameplay (BattleNormal/Combat) -> ohne diesen Zweig laeuft
    -- alles als Gameplay weiter und die VR-Haende stehen mitten in der Anim herum.
    -- KS4 (Muster boltcycle): First-Person bleibt, Head/Hair aus, ALLE Scripte aus -> die native
    -- Anim spielt sauber aus Weskers Augen, der Head-Nagel in firstperson haengt an ks4_now.
    -- KAMPAGNE UNBERUEHRT: das Flag setzt ausschliesslich das Mercs-Script und faellt ausserhalb
    -- von Mercenaries immer auf false (dort zusaetzlich mit harter Zeitgrenze abgesichert).
    if rawget(_G, "__re4_force_ks4_bulletrush") == true then
        killswitch_active = true
        ks4_active = true
        _G.__re4_ks4_active = true
        pin_release_active = false
        activating_reason = "ks4_bulletrush"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    -- 1c2. [ELEVATOR_TROUBLE 2026-07-19] Das ElevatorTrouble-Gimmick -> KS4 (First-Person, Head/Hair aus,
    -- alle Scripte aus). MUSS VOR der Aufzug-GAMEPLAY-Gate stehen (die pinnt sonst GAMEPLAY). Muster = Gondel-KS4.
    if is_elevator_trouble() then
        killswitch_active = true
        ks4_active = true
        _G.__re4_ks4_active = true
        pin_release_active = false
        _G.__re4_throwsight_active = false
        activating_reason = "ks4_elevatortrouble"
        return
    end

    -- 1d. [ELEVATOR] Reverse-Killswitch: in der Aufzug-Box GAMEPLAY pinnen (killswitch AUS) -> alle Scripte
    -- (movement/motion/firstperson) bleiben AN, First-Person, Head/Hair via Gameplay-Regel aus. VOR der
    -- Cutscene-/KS-Erkennung, damit ein Flackern den killswitch nicht kurz aktiviert.
    if is_in_elevator() then
        killswitch_active = false
        pin_release_active = false
        _G.__re4_throwsight_active = false
        activating_reason = "gameplay_elevator"
        fp_latch = false; fp_latch_state = nil; fp_latch_level = 0
        return
    end

    -- 1e0. [ELEVATOR5] Aufzug Space 56200 (Stage 56300 unten <-> 56201 oben, EIN Aufzug -- s. Helfer oben).
    -- Kabine steht -> normales Gameplay (einsteigen, umsehen). Knopf -> unberuehrt, laeuft ueber die
    -- gecapturte KS2-Zone. Fahrt (Latch, s.o.) -> GAMEPLAY forcieren (First-Person, alle Scripte an).
    --
    -- MESSSTAND 2026-07-15 (per Probe-Script an beiden Endpunkten + ueber die ganze Fahrt gemessen,
    -- nativ gegen "alle Scripte an" -- die frueheren Behauptungen hier waren FALSCH und sind korrigiert):
    -- * NICHT am KS-Grad drehen -- das stimmt weiter, aber NICHT aus dem alten Grund. Der alte
    -- Kommentar behauptete "bei KS1 ist JEDE Zeile unseres Lua aus". Das ist FALSCH:
    -- __re4_ks4_active ist bei KS1 false (s.u. Z.1511), und 12 Scripte haben ueberhaupt kein Gate
    -- (u.a. reload/reload2/reload3/reload_adv mit zusammen ~170 Transform-Writes). KS1 schaltet
    -- WENIGER ab als KS4/KS5, nicht mehr.
    -- * VR-DLL/Playspace ist AUSGESCHLOSSEN: primary-Camera minus Camera-Joint war ueber alle
    -- Fahrten exakt 0.000 -- die VR-DLL rechnet nachweislich nichts drauf.
    -- * Die KAPSEL ist AUSGESCHLOSSEN: sie landet nativ wie mit Scripten auf exakt -3.261 (oben
    -- 48.233). Auch rel_head (Kopf ueber Kapsel) ist in beiden Faellen gleich (~1.57 / ~1.59).
    -- * capy/bob/crouch_cam_lerp (firstperson) sind AUSGESCHLOSSEN: EMA-Lag holt sich bei Stillstand
    -- ein, der Versatz blieb aber stehen. ikleg_cleanup (movement) ebenfalls -- lief nachweislich
    -- NIE (Log blieb leer) und ist inzwischen geloescht.
    -- * EINZIGER gemessener Unterschied nativ<->Scripte: das Skelett ist mit Scripten zwischen den
    -- Paessen EINGEFROREN (d+0.0cm), nativ lebt es (d-1.0..-2.0cm zwischen motion und late).
    -- * HEISSE SPUR (-These, unwiderlegt): Es muss ein PERSISTENTER Engine-Zustand sein, kein
    -- laufender Schreibzugriff -- denn ein Gate stoppt nur das Schreiben, es nimmt einen bereits
    -- gesetzten Zustand nicht zurueck. Das erklaert "KS1 != alle Scripte aus" als einziges.
    -- Zu pruefen sind daher Dinge, die ein Gate PRINZIPIELL nicht erreicht: einmalige Writes beim
    -- Script-Load, sdk.hooks (ueberleben sogar Reset Scripts -> Game-Neustart noetig) und erzeugte
    -- GameObjects. ACHTUNG bei Tests: Reset Scripts raeumt so etwas NICHT weg -> Save-Load/Neustart,
    -- sonst misst man den klebenden Zustand vom Vorlauf (hat diese Session mehrfach verfaelscht).
    -- * OFFEN: Fuss-Joints mit Scripten gegen die native Baseline (nativ FUSS_L/R = +0.09 ueber der
    -- Kapsel, stur, auch bei voller Fahrt). Probe-Script dafuer liegt gesichert im Scratchpad.
    -- Der Trigger (Gimmick-Flanke am Endpunkt + Stage + XZ-Radius) bleibt, weil er sauber funktioniert --
    -- er ist die Grundlage, falls man die Fahrt spaeter doch anders behandeln will.
    if is_in_elevator5_cabin() then
        if elevator5_update() and not is_real_cutscene() then
            killswitch_active = false
            pin_release_active = false
            _G.__re4_throwsight_active = false
            activating_reason = "gameplay_elevator5"
            fp_latch = false; fp_latch_state = nil; fp_latch_level = 0
            return
        end
    else
        -- Kabine verlassen -> Latch faellt. Ohne Reset misst der naechste Eintritt gegen ein uraltes y
        -- bzw. der Latch haengt.
        elev5.latch = false; elev5.prev_gim = false; elev5.y = nil
        elev5.target = nil; elev5.moved_once = false
    end

    -- 1e. [ELEVATOR2] Aufzug 53302 (Studierzimmer-Keller): Trigger = Parent-Kette (エレベータ). Solange der
    -- Aufzug uns parentet -> GAMEPLAY forcieren (killswitch AUS): alle Scripte AN (movement/motion/firstperson),
    -- First-Person, Head/Hair via Gameplay-Material-Regel aus. Zusaetzlich un-parentet motion.lua jeden Frame
    -- (gegen Clipping). VOR Cutscene/KS-Erkennung, damit ein Flackern den killswitch nicht kurz aktiviert.
    if (is_parented_to_elevator() or is_in_elevator2_zone() or is_in_elevator3_zone()) and not is_real_cutscene() then
        -- [ELEVATOR2_ZONE_VORTRITT] Wenn fuer die aktuelle Pos+CamState eine KS2/KS3-Zone gespeichert ist
        -- (z.B. der Button-Druck IM Aufzug), dieser den Vortritt lassen: NICHT Gameplay forcen, sondern zur
        -- normalen Erkennung durchfallen (die die Zone als KS2/KS3 greift). Ohne passende Zone -> Gameplay.
        local ep = get_player_pos()
        local estg, espc = read_stage_space()
        -- [ELEV_LIVE_CAM] LIVE lesen, nicht current_cam_state: das ist hier eingefroren (s. Helper oben).
        local ecam = read_live_cam_state()
        local zlvl = ep and zone_level_for({ stage = estg, camstate = ecam,
            pos = { x = ep.x, y = ep.y, z = ep.z } })
        if not zlvl then
            -- [ELEVATOR2_ZONE_CAPTURE] Event-Eintritt fuer den Monitor mit-erfassen, damit KS2-Zonen (Button)
            -- auch IM Aufzug speicherbar sind (sonst "kein Event-Eintritt erfasst", weil der else-Zweig, der
            -- cur_episode_entry sonst setzt, hinter diesem return liegt). Frisch pro Frame = Monitor markiert
            -- immer den aktuellen Moment (Button-Pos + CamState).
            -- [ELEV_LIVE_CAM] ecam statt current_cam_state: sonst speichert eine Neuaufnahme IM Aufzug den
            -- eingefrorenen Wert (2) statt des echten -> die neue Zone waere von Geburt an tot.
            if ep then
                cur_episode_entry = { stage = estg, space = espc, camstate = ecam,
                    pos = { x = ep.x, y = ep.y, z = ep.z } }
            end
            killswitch_active = false
            pin_release_active = false
            _G.__re4_throwsight_active = false
                activating_reason = "gameplay_elevator2"
            fp_latch = false; fp_latch_state = nil; fp_latch_level = 0
            return
        end
        -- sonst: Zone matcht -> durchfallen, normale Erkennung greift die KS2/KS3-Zone
    end

    -- 1e2. [GONDEL] Gondel-Fahrt (GimmickType GondolaL, Stage 56100) -> KS4: ALLE Scripte aus (auch die
    -- ungateten), NUR First-Person + Bindings bleiben. Ohne Eingriff faellt die Fahrt ueber CamState
    -- "Gimmick"(15) auf KS1/3rd-Person (live belegt, Dump 13:54).
    -- WARUM KS4 und nicht Gameplay-Force wie bei den Aufzuegen: In der Gondel wird nur gefahren, nicht
    -- geschossen -- Gameplay-Force wurde probiert und ging nicht. KS4 hat zudem den Vorteil, dass
    -- motion/movement gar nicht laufen: damit arbeitet NICHTS gegen das ParentGimmick -> das Un-Parenting,
    -- das die Aufzuege brauchen, entfaellt hier. Effektiv native Fahrt + First-Person (Muster =
    -- Minecart-Intro, ebenfalls KS4 + Head-Nagel). __re4_gondola_active -> firstperson nagelt die Cam
    -- an den Head-Joint.
    --
    -- BEKANNTE EINSCHRAENKUNG ( 2026-07-15, KEIN Killswitch-Problem): Das Gondel-MESH bewegt sich in
    -- VR nicht mit -- man faehrt gefuehlt ohne Gondel vom Start zum Ziel. Laut dasselbe Muster wie
    -- frueher bei den "alten Kanonen", also ein generelles VR-Problem mit bewegten Gimmick-Meshes und
    -- nicht spezifisch fuer diese Stelle. KS1 (alles nativ, 3rd-Person) waere die Alternative und wurde
    -- getestet -- First-Person ist trotz der stehenden Gondel lieber. Wer das echt loesen will:
    -- Ansatzpunkt ist die Gondel-TRANSFORM/das Mesh, nicht der Killswitch-Grad.
    -- CUTSCENE-GUARD wie bei ELEVATOR2/3: geht die Fahrt am Ende in ein Event ueber, gewinnt die Cutscene
    -- (KS1, korrekt) -- der Force wuerde sie sonst ueberschreiben.
    -- [GONDEL->KS5 2026-08-16] Auf Wunsch von KS4 auf KS5 gehoben = identisch zu KS4 (alle Scripte aus,
    -- First-Person, Head-Nagel), NUR zusaetzlich das GESAMTE Mesh aus (materials.lua: fp_only_now = ks3 or ks5).
    -- Der kurz zuvor probierte GAMEPLAY-Force ist damit wieder raus.
    -- Muster = MINIDEMO_KS5 (Branch 1f2): ks4_active MUSS mitgesetzt werden -- der Head-Nagel in
    -- firstperson.lua und binding.lua fragen is_ks4; bei reinem ks5_active melden beide false und die
    -- Kamera haengt nicht mehr am Head-Joint. ks5_active haengt am 3rd-Person-Toggle (__re4_ks_fp_enabled):
    -- Toggle aus -> nur KS4, sonst waere Leon in 3rd-Person unsichtbar.
    -- Rueckbau auf reines KS4 = die ks5_active-Zeile loeschen.
    if is_on_gondola() and not is_real_cutscene() then
        killswitch_active = true
        ks4_active = true
        if _G.__re4_ks_fp_enabled ~= false then ks5_active = true end
        pin_release_active = false
        _G.__re4_throwsight_active = false
        _G.__re4_gondola_active = true
        activating_reason = "ks5_gondola"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    -- [GONDEL-PARENT 2026-07-22] Auf dieser Gondel greift die normale Erkennung NICHT: der Monitor
    -- meldet GIMMICK-TYP "-", Occupied UNSET und die ganz normale PlayerCameraController -- es gibt kein
    -- Merkmal, an dem is_on_gondola anschlagen koennte, der Killswitch blieb auf GAMEPLAY.
    -- Erkennung daher ueber das ParentGimmick-BIT im Player.State (Rechnung s. Helfer oben), ENG GEGATED:
    -- nur Stage 60850, nur mit der normalen Gameplay-Kamera (echte Events laufen ueber andere Kameras und
    -- werden von den Bloecken DAVOR abgefangen -- dieser ist bewusst der letzte), keine Cutscene.
    -- HINWEIS aus dem Test 2026-07-22: KS4 behebt das Glitchen NICHT (mit KS4 waren alle Scripte aus und
    -- es glitchte identisch -> Ursache ist die vrmod-Kern-Kamera auf bewegter Plattform, wie beim
    -- Aufzug-Float). Der Block bleibt auf so gewollt trotzdem drin; sichtbar entschaerft wird es ueber
    -- das Ausblenden der FREMDEN Kabinen in re4_vr_materials.lua (die eigene PLGondola bleibt sichtbar).
    -- Bewusst OHNE __re4_in_squeeze: der Antibeam gehoert zum Durchquetschen (blockt dort einen zweiten
    -- setupJackLayer) und hat mit einer fahrenden Gondel nichts zu tun.
    if GONDOLA_PARENT_STAGES[read_stage_space()] and has_parent_gimmick() and not is_real_cutscene() then
        local busy = get_busy_controller()
        local is_pc_cam = true   -- ohne Busy-Controller (= normales Gameplay) gilt die Player-Kamera
        if busy and player_cam_td then
            local ok, r = pcall(function() return busy:get_type_definition():is_a(player_cam_td) end)
            is_pc_cam = (ok and r == true)
        end
        if is_pc_cam then
            killswitch_active = true
            ks4_active = true
            pin_release_active = false
            _G.__re4_throwsight_active = false
            activating_reason = "ks4_gondola_parent"
            fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
            return
        end
    end

    -- [BEARTRAP 2026-07-17] Beinschlinge/Beartrap -> KS2 (First-Person, Head/Hair aus, Body sichtbar,
    -- Scripte bleiben AN). Live gemessen, waehrend man drin sass: State=Gimmick(15) +
    -- GimmickType=LegHoldTrap(2) -> fiel vorher auf KS1 (voll/3rd-Person) ueber [camstate:15], genau
    -- wie einst die Gondel. Erkennung ueber den GimmickType-NAMEN (nicht die Stage/Position) -> gilt
    -- fuer JEDE Beartrap im Spiel, ohne dass wir sie einzeln abklappern muessen (so gewollt).
    -- KS2 statt KS4: das Befreien ist ein Tast-/Button-Event, die Scripte sollen dabei weiterlaufen;
    -- ueber ks2_now greift zudem der Head-Nagel -> der Body bleibt hinter der Kamera.
    -- CUTSCENE-GUARD wie bei Gondel/ELEVATOR2/3: geht es am Ende in ein Event ueber, gewinnt die
    -- Cutscene (KS1, korrekt) -- der Force wuerde sie sonst ueberschreiben.
    -- [KS2 -> KS4 2026-07-22, "beartrap kann dafuer immer KS4 sein"] Frueher KS2 (Scripte an). Jetzt
    -- KS4 = alle Scripte aus + resetBasePose beim Eintritt. Der Head-Nagel bleibt (ks4_now steht in
    -- headpin_now), der Body liegt weiter hinter der Kamera. Explizit KS4 statt "KS2 + Promotion", damit
    -- es KS4 bleibt, auch wenn der KS2_ALS_KS4-Schalter mal aus ist.
    if is_in_legholdtrap() and not is_real_cutscene() then
        killswitch_active = true
        ks4_active = true
        pin_release_active = false
        _G.__re4_throwsight_active = false
        activating_reason = "ks4_beartrap"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    -- [ASHLEY-CARRY TEST 2026-07-16] Stage 68102 + 68103 (Folgestage, Trage-Abschnitt geht weiter) -> KS4
    -- (unser Aufzug-/Sonderfall-KS). Trigger: diese Stages AUSSER in der Zwischendemo. Die Demo laeuft ueber
    -- GimmickMotionCameraController (Gameplay ueber PlayerCameraController) -> is_gimmick_motion_now sperrt
    -- den Force dort -> Demo bleibt nativ (3rd-Person, posed das Skelett eh selbst neu). Cutscene-Guard wie
    -- Gondel. Weitere Folgestage = Nummer in den Vergleich aufnehmen. Rueckbau = diesen Block loeschen.
    -- [ELEVATOR_59100] Aufzug gm81_511 in Stage 59100. [2026-07-19] Von KS4 auf GAMEPLAY umgestellt:
    -- als KS4 wuerde ihn der neue KS4-Yaw-Lock (binding.lua) erfassen -> rechter Stick tot. GAMEPLAY = alle
    -- Scripte AN (movement/motion/firstperson), First-Person, Head/Hair via Gameplay-Material-Regel aus, Yaw frei.
    -- Demos/echte Cutscenes weiter ausgenommen (dann native Erkennung/KS1).
    if is_riding_elevator_59100()
       and not is_real_cutscene() and not is_gimmick_motion_now() and not is_demo_priority_now() then
        killswitch_active = false
        pin_release_active = false
        _G.__re4_throwsight_active = false
        activating_reason = "gameplay_elevator_59100"
        fp_latch = false; fp_latch_state = nil; fp_latch_level = 0
        return
    end

    -- [JETSKI] Jetski-Fahr-Stages (592xx) -> KS4 wie Minecart/Gondel. Demos/echte Cutscenes ausgenommen
    -- (dann bleibt native 3rd-Person). __re4_jetski_active fuer den firstperson-Offset. KEIN keep_movement.
    if is_on_jetski()
       and not is_real_cutscene() and not is_gimmick_motion_now() and not is_demo_priority_now() then
        killswitch_active = true
        ks4_active = true
        pin_release_active = false
        _G.__re4_throwsight_active = false
        _G.__re4_jetski_active = true
        activating_reason = "ks4_jetski"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    -- [BOAT_KS4 2026-07-18] Boot-Fahrt (native get_IsBoat) -> KS4 wie Jetski (First-Person, Head/Hair aus,
    -- Body sichtbar, ALLE Scripte aus, nativ mitfahren). throwsight (Fisch-Boss, gm02_500_00_1) ist EXPLIZIT
    -- ausgenommen -> bleibt exakt wie es war. Steht NACH dem Jetski-Branch -> Jetski behaelt Vorrang (auch ein
    -- "Boot"). Demos/echte Cutscenes ausgenommen. __re4_boat_active fuer den firstperson-Offset "Boat".
    if is_on_boat() and not is_throwsight_stage()
       and not is_real_cutscene() and not is_gimmick_motion_now() and not is_demo_priority_now() then
        killswitch_active = true
        ks4_active = true
        pin_release_active = false
        _G.__re4_throwsight_active = false
        _G.__re4_boat_active = true
        activating_reason = "ks4_boat"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    -- [FORCECROUCH_KS4 40501 -> 40502 2026-07-16] In der ersten Anfangsstage 40501 laeuft ein Force-Crouch-
    -- Durchquetsch-Event (Leon quetscht sich durch einen Spalt, geht danach in Stage 40502 ueber) -> KS4
    -- (First-Person, ALLE Scripte aus, Body sichtbar), wie Minecart/Gondel.
    -- [ZEIT-HYSTERESE gegen Flackern 2026-07-16, -Design] Das Event ist unverkennbar ForceCrouch, aber der
    -- CamState springt im Kriech-Gang zwischen ForceCrouch und Crouch, und der Stagewechsel 40501->40502 hat
    -- kurze Nicht-ForceCrouch-Frames -> reines CamState-Gate flackert. Loesung: NUR in Stage 40501 auf
    -- ForceCrouch triggern; jeder ForceCrouch-Frame schiebt fc_ks4_until ~1s vor. KS4 bleibt an, solange
    -- os.clock < fc_ks4_until -> ueberbrueckt die Crouch-Zwischenframes UND traegt den KS ~1s weich in Stage
    -- 40502 hinein. Danach laeuft 40502 ganz normal weiter (weicher Uebergang in die neue Stage). Kein Gate auf
    -- 40502 noetig: das Zeitfenster laeuft von selbst ab. Space-Gate 40500 -> greift nur in der Anfangsregion.
    -- [KS-FORCE-BRANCH] read_live_cam_state statt current_cam_state (letzteres ist hier eingefroren).
    do
        local now = os.clock()
        local fc_stg, fc_spc = read_stage_space()
        if fc_stg == 40501 and fc_spc == 40500
           and forcecrouch_int ~= nil and read_live_cam_state() == forcecrouch_int then
            fc_ks4_until = now + 1.0                  -- ForceCrouch gesehen -> KS4 bis 1s danach halten
        end
        if now < fc_ks4_until and not is_real_cutscene() then
            killswitch_active = true
            ks4_active = true
            pin_release_active = false
            _G.__re4_throwsight_active = false
            _G.__re4_forcecrouch_active = false   -- Gameplay-ForceCrouch-Head-Nagel aus: KS4 nagelt selbst
            _G.__re4_forcecrouch_ks4_active = true -- [BEGINNING_CROUCH] eigener HMD-Offset im firstperson
            activating_reason = "ks4_forcecrouch"
            fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
            return
        end
    end

    -- [GANG_3RD 60874 2026-07-22] Der lange gerade Gang in Stage 60874 soll KOMPLETT in
    -- 3rd-Person laufen: alles sehen, alle Scripte aus, aber weiter steuern und laufen koennen.
    -- Umsetzung = KS1 (voll): firstperson/materials/motion/movement sind aus (3rd-Person, Koerper
    -- sichtbar, keine Joint-Pins), binding laeuft im ks_active-Zweig -> der linke Stick wird nativ
    -- durchgereicht, gelaufen und gedreht wird also wie im 3rd-Person-Original.
    -- Strecke aus den Monitordumps, beide Stage 60874 (Space wechselt 60880->60874, daher NICHT
    -- auf den Space gaten):
    -- Pos 1 (Start, 20:03:07): 30.80 / 1.32 / 232.38
    -- Pos 2 (Ende, 20:18:14): 0.46 / 2.66 / 232.14
    -- Gegatet wird der Abstand zur VERBINDUNGSSTRECKE (Punkt-Segment), Radius 3 m -- also ein
    -- Schlauch entlang des Gangs statt zweier Kugeln.
    -- ACHTUNG: steht VOR dem EVT60874-Block -> im Schlauch gewinnt 3rd-Person auch waehrend der
    -- Quicktime-Events (die dortige First-Person-/Fullhide-Umschaltung greift dann bewusst nicht).
    -- Das Fullhide-Flag und die Event-Uhr werden hier zurueckgesetzt, damit nichts kleben bleibt.
    -- [JOINT_RELEASE 2026-07-22] Der allgemeine resetBasePose-Block unten haengt an der Flanke
    -- "voll-aus wird neu betreten". Kommt man aus dem EVT60874-KS4 in den Schlauch, war full_off
    -- schon true -> keine Flanke -> die von motion/arm_chain/movement gepinnten Joints bleiben
    -- stehen (sichtbar, weil hier 3rd-Person laeuft). Darum eine EIGENE Flanke pro Eintritt, und
    -- 0.5 s lang nachhalten: unsere Scripte koennen im selben und im naechsten Frame noch schreiben.
    -- Zustand als Global (kein Top-Level-Local -- die Datei ist nah am 200er-Limit).
    do
        local in_gang = false
        if read_stage_space() == 60874 then
            local gp = get_player_pos()
            if gp then
                local ax, ay, az = 30.80, 1.32, 232.38
                local abx, aby, abz = 0.46 - ax, 2.66 - ay, 232.14 - az
                local apx, apy, apz = gp.x - ax, gp.y - ay, gp.z - az
                local ab2 = abx * abx + aby * aby + abz * abz
                local t = 0.0
                if ab2 > 0.0 then t = (apx * abx + apy * aby + apz * abz) / ab2 end
                if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
                local dx, dy, dz = apx - abx * t, apy - aby * t, apz - abz * t
                in_gang = (dx * dx + dy * dy + dz * dz) <= 9.0
            end
        end
        if not in_gang then
            _G.__re4_gang3rd_t = nil
        else
            local gt = rawget(_G, "__re4_gang3rd_t")
            if gt == nil then gt = os.clock(); _G.__re4_gang3rd_t = gt end
            if (os.clock() - gt) < 0.5 then
                local gbody = get_player_body()
                local gtf = gbody and safe(function() return gbody:call("get_Transform") end)
                if gtf then pcall(function() gtf:call("resetBasePose") end) end
            end
            killswitch_active = true          -- KS1: keine Stufe gesetzt = voll aus / 3rd-Person
            pin_release_active = false
            -- [KEIN keep_movement 2026-07-22, "movementpin steht alles noch"] __re4_ks_keep_movement
            -- schaltet in movement.lua die KS-Pause ab -> Spine-/Hip-/Neck-Pins laufen weiter und
            -- verbiegen die in 3rd-Person sichtbare Pose. Gelaufen wird hier nativ: binding reicht im
            -- ks_active-Zweig den linken Stick durch, also bleibt die Figur steuerbar, ohne dass eines
            -- unserer Scripte Joints anfasst -- genau das Bild der normalen KS1-Phasen dieser Szene.
            _G.__re4_evt60874_fullhide = false
            evt60874_t0 = nil
            activating_reason = "gang3rd_60874"
            return
        end
    end

    -- [EVT60874 MID-EVENT-FP 2026-07-22] Event in Stage 60874: startet bewusst in 3rd-Person
    -- (KS1) und schaltet erst nach EVT60874_DELAY (1.2 s) auf First-Person (KS4) um -- ab da
    -- zusaetzlich ALLE Meshes aus (Flag __re4_evt60874_fullhide, ausgewertet in re4_vr_materials).
    -- Solange die Uhr laeuft, passiert hier NICHTS -> das Event bleibt KS1, genau wie gewuenscht.
    -- Der Zeitstempel wird beim Verlassen der Stage zurueckgesetzt, es bleibt also nichts haengen.
    -- Gate = allein Stage 60874: die kam im gesamten Monitordump-Verlauf NUR bei diesem Event vor
    -- (der Space bleibt 60880, es ist eine eigene Event-Sub-Stage). Ein Controller-Check ist damit
    -- unnoetig -- und er haette einen zusaetzlichen Top-Level-Local gekostet (Datei ist nah am Limit).
    -- [KLEMM-FIX 2026-07-22, "kommt nicht mehr raus"] Die Stage 60874 bleibt nach dem Event
    -- offenbar bestehen -> ein Gate allein auf die Stage haelt KS4 fuer immer. Deshalb zusaetzlich an
    -- die EVENT-Signatur gekoppelt: Occupied-Priority CH_JACKED_GMK_HIGH (dieselbe, ueber die auch das
    -- Durchquetschen erkannt wird). Faellt die Prio weg, ist das Event vorbei -> Branch laesst sofort los.
    do
        local ev_stg = read_stage_space()
        local ev_on = false
        if ev_stg == 60874 then
            local want = squeeze_high_prio()
            if want ~= nil then
                local ectx = get_player_context()
                local eocc = ectx and safe(function() return ectx:call("get_OccupiedInfo") end)
                local eprio = eocc and safe(function() return eocc:call("get_Priority") end)
                if type(eprio) ~= "number" then
                    eprio = type(eprio) == "userdata" and safe(function() return eprio:get_field("value__") end) or eprio
                end
                ev_on = (eprio == want)
            end
        end
        if ev_on then
            if evt60874_t0 == nil then evt60874_t0 = os.clock() end
            if (os.clock() - evt60874_t0) >= EVT60874_DELAY and not is_real_cutscene() then
                killswitch_active = true
                ks4_active = true
                pin_release_active = false
                -- [FULLHIDE] Ab hier ganzes Mesh aus (materials liest dieses Flag). Nur waehrend
                -- des Umschalt-Fensters gesetzt -- vor Ablauf der Uhr und nach der Stage ist es false,
                -- der 3rd-Person-Teil am Anfang zeigt Ada also normal.
                _G.__re4_evt60874_fullhide = true
                activating_reason = "ks4_evt60874"
                fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
                return
            end
            _G.__re4_evt60874_fullhide = false     -- Uhr laeuft noch -> 3rd-Person, Mesh sichtbar
        else
            evt60874_t0 = nil
            _G.__re4_evt60874_fullhide = false
        end
    end

    local carry_stg = read_stage_space()
    if (carry_stg == 68102 or carry_stg == 68103 or carry_stg == 68105)
       and is_carrying()
       and not is_real_cutscene() and not is_gimmick_motion_now() and not is_demo_priority_now() then
        killswitch_active = true
        ks4_active = true
        pin_release_active = false
        _G.__re4_throwsight_active = false
        _G.__re4_ks_keep_movement = true   -- [TEST] movement trotz KS4 weiterlaufen lassen (Turn-Kopplung)
        activating_reason = "ks4_ashley_carry"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    -- 1f. [GIMMICK_KS3_SPOT] Gimmick-Kamera-Event in Stage 53303 (GimmickMotionCameraController) statt
    -- KS1/3rd-Person. Ans Event gekoppelt (kein Radius). VOR der Cutscene-Erkennung, die es sonst als
    -- Event kaescht (KS1).
    -- [KS3 -> KS2 2026-07-15] War KS3 (ganzes Mesh aus). Jetzt KS2: firstperson nagelt hier ohnehin die
    -- Cam an den Head (is_gimmick_ks3_now ist Teil des Nagel-Gates) -> Body liegt hinter der Kamera,
    -- Mesh-Aus war doppelt gemoppelt. activating_reason bleibt "ks3_gimmick": firstperson.lua erkennt das
    -- Event genau an diesem String (is_gimmick_ks3_now) -- umbenennen wuerde den Head-Nagel abschalten.
    -- [KS2 -> KS4 2026-07-19] Durchquetschen (GimmickMotionCameraController) ist ein ParentGimmick:
    -- in KS2 liefen movement/motion mit und un-parenteten den Spieler jeden Frame vom Quetsch-Gimmick ->
    -- am ENDE Desync -> Rueckglitch an den Anfang der Spalte. KS4 = ALLE Scripte aus, kein Un-Parenting ->
    -- die native Quetschbewegung laeuft sauber durch (wie Gondel/Minecart). Head-Nagel kommt in KS4 pauschal;
    -- Reason bleibt "ks3_gimmick" (firstperson erkennt den Nagel an diesem String, s. is_gimmick_ks3_now).
    -- 1e2. [GFIX_KS5 2026-07-21] MUSS VOR dem Squeeze-Block stehen: der wuerde dasselbe Event ueber
    -- die Priority mitfangen (Reason "ks3_gimmick") und es waere nur KS4 = Koerper ohne Kopf sichtbar.
    -- KS5 = ganzes Mesh aus. ks4_active wird MITgesetzt, sonst faellt der Head-Nagel in firstperson weg
    -- (haengt an is_ks4) -- die Lektion vom Mini-Demo-Event heute.
    -- [GFIX_KS4 2026-07-23] Stage 44400 + GimmickFix + CH_JACKED_GMK_LOW(3) -> stabil KS4.
    if is_gimmickfix_ks4_spot() then
        killswitch_active = true
        ks4_active = true
        _G.__re4_ks4_active = true
        pin_release_active = false
        _G.__re4_throwsight_active = false
        activating_reason = "ks4_gfix"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    if is_gimmickfix_ks5_spot() then
        killswitch_active = true
        ks4_active = true
        if _G.__re4_ks_fp_enabled ~= false then ks5_active = true end
        pin_release_active = false
        _G.__re4_throwsight_active = false
        activating_reason = "ks5_gfix"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    if is_gimmick_ks3_spot() then
        -- [KS4 2026-07-19] Squeeze = KS4 (First-Person). Der Beam-Bug haengt NICHT am KS-Grad (Test 2026-07-19:
        -- auch KS1/native 3rd-Person beamt zurueck) -> Ursache = vrmod-Kern-Kamera (wie Aufzug-Float), kein Lua.
        killswitch_active = true
        ks4_active = true
        _G.__re4_ks4_active = true
        _G.__re4_in_squeeze = true   -- [ANTIBEAM] zuverlaessiges "im Squeeze"-Flag fuer die Rueckwaerts-Sprung-Korrektur
        pin_release_active = false
        _G.__re4_throwsight_active = false
        activating_reason = "ks3_gimmick"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    -- 1f2. [MINIDEMO_KS5 2026-07-21] Stage 55850: Gimmick-Motion-Event (Occupied MINI_DEMO), lief bisher
    -- als KS1 in 3rd-Person. Jetzt KS5 = wie KS4 (alle Scripte aus + First-Person), ABER GESAMTES Mesh aus --
    -- so gewollt fuer genau dieses eine Event. Die native Bewegung laeuft dadurch sauber durch (kein
    -- Un-Parenting durch movement/motion, dieselbe Begruendung wie beim Durchquetschen).
    -- MUSS wie 1f VOR der Cutscene-/Controller-Klassifizierung stehen, die es sonst als Event auf KS1 zieht.
    -- Kein __re4_ks_keep_movement: in der Demo fuehrt die Engine, eigener Stick-Input wuerde dagegenhalten.
    -- [3RD-PERSON-TOGGLE] is_ks5 ist als EINZIGE Stufe NICHT gegated (Minecart soll immer FP bleiben) --
    -- deshalb hier explizit: Toggle aus -> ks4_active statt ks5_active. Dann meldet is_ks4 wegen des
    -- zentralen Gates false (= 3rd-Person-Bild wie KS1) und das Mesh bleibt sichtbar, waehrend die Scripte
    -- ueber __re4_ks4_active trotzdem ruhen. Wuerde man ks5_active setzen, waere Leon in 3rd-Person unsichtbar.
    if is_minidemo_ks4_spot() then
        killswitch_active = true
        -- [KS4+KS5 2026-07-21, "KS5 sieht komisch aus, KS4 treibt die Joints wieder an"] KS5 ALLEIN
        -- reicht NICHT: der Head-Nagel in firstperson.lua haengt an is_ks4 (ks4_now, s. dortiger Block
        -- "KS4 GENERELL"), und auch binding.lua fragt is_ks4. Bei reinem ks5_active melden beide false ->
        -- die Kamera wird NICHT an den Head-Joint geklemmt und folgt der nativen Animation nicht mehr.
        -- Deshalb BEIDE Flags: ks4_active liefert das komplette KS4-Verhalten (Nagel + Joint-Antrieb),
        -- ks5_active legt nur das "gesamtes Mesh aus" obendrauf (materials.lua: fp_only_now = ks3 or ks5).
        -- Ungefaehrlich: __re4_fatalkick_active braucht zusaetzlich den Kick-CamState (hier nil) und
        -- die Loren-Offsets haengen an ihren eigenen Flags -> keine fremde Offset-Kette wird gekapert.
        ks4_active = true
        if _G.__re4_ks_fp_enabled ~= false then ks5_active = true end
        pin_release_active = false
        _G.__re4_throwsight_active = false
        activating_reason = "ks5_minidemo"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    -- 1g. [MINECART_KS4 55201] Loren-Stage 55201 (ActionCam=Einstieg / VehicleCam=Fahrt) -> KS4: alle Scripte aus,
    -- First-Person, Head/Hair aus, Body sichtbar. VOR der Cutscene-/Controller-Klassifizierung (sonst else = KS1).
    -- Getrennt geflaggt (minecart vs minecart2), damit firstperson pro Szene einen eigenen HMD-Offset legen kann.
    local mc_kind = minecart_ks4_kind()
    if mc_kind then
        killswitch_active = true
        pin_release_active = false
        _G.__re4_throwsight_active = false
        if mc_kind == "cart2" then
            ks4_active = true                      -- [KS4 2026-07-13] frueher KS5 (ganzes Mesh aus); jetzt KS4 =
            _G.__re4_minecart2_ks4_active = true   -- Body sichtbar + Spine-Pin (Fahrt-Intro braucht stabilen Koerper)
            activating_reason = "minecart2_ks4"
            fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        else
            ks4_active = true                      -- [KS4] alle Scripte aus + First-Person, Head/Hair aus, Body sichtbar
            _G.__re4_minecart_ks4_active = true    -- [MINECART_OFFSET] ActionCam-Einstieg
            activating_reason = "minecart_ks4"
            fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        end
        return
    end

    -- 1h. [RAILCAR_MODE] An den Schienenwagen geparentet -> nur motion/arm_chain/firstperson, Rest aus (s. Helfer
    -- oben). NACH dem Minecart-Intro-Gate (55201): das Intro hat kein ParentGimmick, greift also hier eh nicht mit.
    if is_on_railcar() then
        killswitch_active = true
        ks4_active = true                      -- Head/Hair aus, Body sichtbar, ungatete Scripte aus, firstperson bleibt
        pin_release_active = false
        _G.__re4_throwsight_active = false
        _G.__re4_railcar_mode = true           -- [RAILCAR] motion + arm_chain laufen TROTZ killswitch weiter
        activating_reason = "railcar_mode"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        return
    end

    -- 1i. [GRAPPLED] Gegner haelt Leon fest -> KS2 (First-Person, nur Head/Hair aus) statt KS1/3rd-Person.
    -- VOR der Controller-/Cutscene-Klassifizierung: Phase 1 des Griffs laeuft auf ActionCameraController und
    -- wuerde sonst unten im else-Zweig als KS1 [ctrl_name] landen, bevor dieser Branch je drankaeme.
    -- NACH dem Minecart-Gate (1g nutzt ebenfalls ActionCameraController) -> Loren-Einstieg bleibt KS4.
    -- [GRAPPLE_OFFSET 2026-07-15] Gilt fuer BEIDE Phasen (ActionCam + Grappled): firstperson.lua nagelt die
    -- Kamera dann direkt an den Head-Joint (+ eigener grap_off_*), ohne Bob/Kapsel-Anker -- Muster wie die
    -- Loren. Der Body kann so gar nicht ins Bild schwenken (Kamera sitzt IM Kopf) -> KS2 reicht, Mesh muss
    -- nicht wie bei KS3 ganz weg.
    if player_is_grappled() then
        killswitch_active = true
        pin_release_active = false
        _G.__re4_throwsight_active = false
        _G.__re4_grappled_active = true
        -- [GRAPPLE_KS3_65100 2026-07-16] NUR Stage 65100 (so gewollt): dort Grapple auf KS3 (ganzes Mesh
        -- aus) statt KS2. Grund: der Head-Nagel reicht hier nicht -- der Body schwenkt trotzdem ins Bild,
        -- KS2 (Body sichtbar) zeigt ihn. KS3 nimmt das gesamte Mesh weg. Ueberall SONST bleibt KS2 (dort
        -- greift der Nagel wie im Kommentar oben). Erweitern = weitere Stage in den Vergleich aufnehmen.
        local stg = read_stage_space()
        if stg == 65100 then
            -- [KS3 NUR NOCH BEI DAMAGE 2026-07-20] War KS3 (ganzes Mesh aus); jetzt KS4, damit KS3
            -- ausschliesslich der Damage-Zustand ist. ACHTUNG/BEOBACHTEN: KS4 blendet nur Head/Hair aus,
            -- der Body ist wieder sichtbar -- genau deswegen stand hier mal KS3 ("Body schwenkt ins Bild").
            -- Faellt das negativ auf, ist die Rueckkehr eine Zeile: ks4_active -> ks3_active + fp_latch_level 3.
            ks4_active = true
            _G.__re4_ks4_active = true
            activating_reason = "ks4_grappled"
            fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
        else
            ks2_active = true
            activating_reason = "ks2_grappled"
            fp_latch = true; fp_latch_state = nil; fp_latch_level = 2
        end
        return
    end

    -- [EVT40510 KS4 2026-07-22] Das Event in Stage 40510 soll KS4 sein statt KS1:
    -- First-Person bleibt, Head/Hair aus, alle Scripte aus -- statt in 3rd-Person zu kippen.
    -- Monitordump 21:49:14: EventCameraController, Cutscene=JA (IsEventCamera),
    -- Occupied CUT_SCENE(38), Stage 40510 / Space 40500, Map -183.43 / 6.53 / 85.46.
    -- Gate = Stage 40510 + echte Cutscene, steht bewusst VOR dem allgemeinen Cutscene-Zweig
    -- darunter. ACHTUNG: damit ist JEDE Cutscene dieser Stage KS4, nicht nur diese eine --
    -- falls das zu breit ist, hier zusaetzlich auf die Position gaten (wie beim Gang-Schlauch).
    -- [TIMED 2026-07-22] Wie bei Ada (EVT60874), nur andersherum: die ersten EVT40510_DELAY
    -- Sekunden KS4, danach faellt der Block durch -> der allgemeine Cutscene-Zweig darunter macht
    -- daraus wieder KS1 (Standard). Uhr laeuft ab dem ersten Frame in Stage+Cutscene und wird beim
    -- Verlassen geloescht. Zeitstempel als Global (kein Top-Level-Local -- Datei nah am 200er-Limit),
    -- beim Script-Load einmal genullt, damit "Reset Scripts" ihn nicht konserviert.
    -- [POSITIONS-GATE 2026-07-22] Stage+Cutscene allein war zu breit -> zusaetzlich 3 m Umkreis
    -- um die erfasste Event-Position (Monitordump 21:49:14: -183.43 / 6.53 / 85.46).
    -- Entschieden wird EINMAL beim Eintritt: passt die Position, laeuft die Uhr (t0 = Startzeit);
    -- passt sie nicht, wird -1 gemerkt = "diese Cutscene nicht" -> faellt sofort auf KS1 durch.
    -- Waehrend der Cutscene wird die Position NICHT mehr geprueft (der Char bewegt sich darin,
    -- sonst wuerde KS4 mittendrin abreissen).
    if read_stage_space() == 40510 and is_real_cutscene() then
        local t0 = rawget(_G, "__re4_evt40510_t")
        if t0 == nil then
            local ep = get_player_pos()
            local hit = false
            if ep then
                local dx, dy, dz = ep.x - (-183.43), ep.y - 6.53, ep.z - 85.46
                hit = (dx * dx + dy * dy + dz * dz) <= 9.0
            end
            t0 = hit and os.clock() or -1
            _G.__re4_evt40510_t = t0
        end
        if t0 >= 0 and (os.clock() - t0) < EVT40510_DELAY then
            killswitch_active = true
            ks4_active = true
            pin_release_active = false
            activating_reason = "ks4_evt40510"
            fp_latch = true; fp_latch_state = nil; fp_latch_level = 4
            return
        end
        -- Uhr abgelaufen: NICHT zurueckstellen (sonst flackert es zwischen KS4 und KS1) -- einfach
        -- durchfallen lassen, den Rest macht der Cutscene-Zweig.
    else
        _G.__re4_evt40510_t = nil
    end

    -- 2. Echte Cutscene
    local cut, why = is_real_cutscene()
    if cut then
        killswitch_active = true
        activating_reason = why
        _G.__re4_throwsight_active = false
        return
    end

    -- 2b. [THROWSIGHT] Del-Lago-Harpunen-Abschnitt: First-Person (keep_fp koppelt an die NATIVE Kamera ->
    -- der native Harpunen-Wurf folgt der Blickrichtung, kein seitlicher Versatz), motion/movement/holster
    -- ueber is_active automatisch dormant. Die throwsight-Bindings + RY-Freigabe greifen weiter
    -- (binding prueft in_throwsight VOR ks_active).
    -- Global fuer die ThrowSight-Ziellinie (weapons.lua) weiter setzen.
    -- [KS3 -> KS2 2026-07-15] War KS3 (ganzes Mesh aus). Jetzt KS2 -> Head/Hair aus, Body sichtbar, dafuer
    -- greift ueber ks2_now der Head-Nagel (Cam fest am Head-Joint, ohne Bob/Kapsel-Anker). Im Boot bewegt
    -- man sich nicht selbst, der Filter fehlt also nicht. ACHTUNG falls Del-Lago komisch wird: das ist die
    -- Stelle -- hier zurueck auf ks3_active/fp_latch_level 3, dann ist alles wie vorher.
    if is_throwsight_stage() then
        _G.__re4_throwsight_active = true
        killswitch_active = true
        ks2_active = true
        pin_release_active = false
        activating_reason = "throwsight_ks2"
        fp_latch = true; fp_latch_state = nil; fp_latch_level = 2
        return
    end
    _G.__re4_throwsight_active = false

    -- 3. BusyCameraController-Typ: nur PlayerCameraController = Gameplay
    local busy = get_busy_controller()
    local ctrl_name = nil
    if busy then
        ctrl_name = safe(function() return busy:get_type_definition():get_full_name() end)
    end
    if ctrl_name ~= current_controller then
        previous_controller = current_controller
        current_controller = ctrl_name
    end

    local is_pc = false
    if busy and player_cam_td then
        local ok, v = pcall(function()
            return busy:get_type_definition():is_a(player_cam_td)
        end)
        is_pc = ok and v == true
    end

    if is_pc then
        -- PlayerCameraController aktiv. 3 Stufen je nach PlayerCameraState:
        -- (a) Gameplay-State -> voller VR-Zustand (alles an)
        -- (b) Pin-Release-State -> NUR Pin loesen, HMD/Yaw bleiben
        -- (c) sonst (Ladder/Grapple/Finisher/...) -> voller Killswitch (alles aus)
        local st = read_cam_state(busy)
        current_cam_state = st
        _G.__re4_ks_cam_now = function() return current_cam_state end   -- [FORENSIK]
        -- [GIMMICK_FLAG] Interaktions-Flag steht (Auto-Attach an Tuer/Leiter/...) -> diesen
        -- Frame NICHT als Gameplay/Pin-Release werten, auch wenn der CamState noch ein Gameplay-
        -- State ist (kippt ~0.2s spaeter). Faellt so in den else-Zweig -> KS1 (zone-settable).
        local gimmick_ng = player_gimmick_active() or player_is_coop_jacked()
        -- [FORCECROUCH] KORREKTUR 2026-07-15: stand faelschlich als "KS2-CamState" hier. Ist GAMEPLAY
        -- (GAMEPLAY_CAM_STATES) -- volle VR-Steuerung; die alte Flicker-/Crouch-Absorptions-Sonderlogik
        -- ist entfernt, weil Crouch und ForceCrouch denselben Zustand haben. Head-Nagel laeuft separat
        -- ueber __re4_forcecrouch_active.
        resolve_state_vals()
        -- [DAMAGE_HOLD] Damage-Frame -> Halte-Fenster schaerfen. Oszillierender Gameplay-Frame WAEHREND
        -- des Fensters -> als Damage behandeln -> kein Flicker der Arme im Stagger.
        if damage_int ~= nil and st == damage_int then
            damage_until = os.clock() + DAMAGE_HOLD
        end
        if damage_int ~= nil and os.clock() < damage_until and is_gameplay_camstate(st) then
            st = damage_int
            current_cam_state = st
        end
        -- [STAGGER_HEAL 2026-07-19] Universelles Stagger-Signal fuer ALLE Reload-Scripts: true waehrend
        -- der Damage-Reaktion (+ DAMAGE_HOLD). Die Reload-Scripts schnappen auf der FALLENDEN Flanke ihren Slide
        -- auf rest (Stagger = wie Waffenwechsel -> Slide zu, fire-ready). Deckt Pistolen/LE5/Red9/Rifles ab.
        -- [DAMAGE-ENDE-STEMPEL 2026-07-20] Die Reload-Scripte koennen die fallende Flanke NICHT
        -- selbst erkennen: waehrend der Damage-Reaktion meldet die Engine keine Waffe (Diag-Log: wid=-1
        -- ueber die ganze Phase), ihre Frame-Funktion steigt vorher aus und sieht den Wechsel nie.
        -- Deshalb hier -- der Killswitch laeuft immer -- den Zeitpunkt des Damage-ENDES veroeffentlichen.
        -- Die Reload-Module heilen ihren Slide dann, sobald sie wieder laufen (Waffe zurueck), genau
        -- einmal pro Stempel.
        do
            local _dmg_now = (damage_int ~= nil and os.clock() < damage_until) and true or false
            if rawget(_G, "__re4_damage_active") == true and _dmg_now == false then
                _G.__re4_damage_end_t = os.clock()
            end
            _G.__re4_damage_active = _dmg_now
        end
        -- [ECHTES RUNTERSPRINGEN] Ein BEWUSSTER Sprung-Einstieg (Node "JUMP_xM"/"JumpDown"/"jumpoff"/
        -- "JUMP_LARGE") macht das Fenster scharf UND setzt jumpdown_confirmed. Danach wird das Fenster
        -- ueber die GANZE Flugphase gehalten, solange der CamState luftig ist (Fall_Jump ->
        -- TerrainAction_Jump -> Landing) — auch waehrend "JumpLoop", das keinen Sprung-Token matcht.
        -- [2026-07-15] Faktisch redundant, seit die ganze Sprung-/Terrain-Kette in KS2_CAM_STATES steht:
        -- der Listen-Zweig unten liefert fuer dieselben States ohnehin KS2. Bleibt unveraendert drin --
        -- er greift eine Stufe frueher (vor der Gameplay-Pruefung) und faengt so oszillierende Frames ab.
        local now = os.clock()
        if player_node_has("jumpdown") or player_node_has("jumpoff")
                or player_node_has("jump_large") or player_node_has("_jump_") then
            jumpdown_confirmed = true
            jumpdown_until = now + JUMPDOWN_HOLD
        end
        if jumpdown_confirmed then
            if is_airborne_camstate(st) then
                jumpdown_until = now + JUMPDOWN_HOLD      -- Flug/Landung -> Fenster nachfuellen
            elseif is_gameplay_camstate(st) then
                jumpdown_confirmed = false                 -- gelandet, zurueck im Gameplay -> fertig
            end
        end
        if player_is_boxbreak() then
            -- [KICK/BARREL] Fass-/Kisten-Tritt (get_IsBoxBreak) -> ueber das FLAG geforct
            -- (CamState bleibt Gameplay Normal/Combat, greift also nicht ueber die CamState-Listen).
            -- [KS4 -> KS2 2026-07-22, "nur das Kisten-Kicken"] War KS4 (alle Scripte aus). Jetzt KS2:
            -- First-Person, Head/Hair aus, Body sichtbar, Scripte bleiben AN (Haende/Waffen/Gesten laufen
            -- waehrend des Tritts weiter). Der HMD-Offset bleibt: firstperson haengt den Head-Nagel + den
            -- ada_box-Offset direkt an __re4_boxbreak_active (boxbreak_now steht eigenstaendig in
            -- headpin_now), NICHT am KS-Grad -> KS2/KS4 macht fuer den Offset keinen Unterschied.
            -- WICHTIG: dieser eine KS2 muss vom globalen KS2_ALS_KS4-Schalter AUSGENOMMEN werden (s. dort),
            -- sonst wird er sofort wieder zu KS4 hochgestuft.
            killswitch_active = true
            ks2_active = true
            boxbreak_active = true
            pin_release_active = false
            activating_reason = "ks2_boxbreak:" .. tostring(st)
            fp_latch = false; fp_latch_state = nil; fp_latch_level = 2
        elseif player_is_ladder_exit(is_gameplay_camstate(st)) then
            -- [LEITER-AUSSTIEG] oberes Rueber-den-Rand-Steigen (gejackte Anim EndFrame>100 = 166fr).
            -- VOR dem Leiter-KS4-Branch, sonst faengt player_is_ladder den Ausstieg als KS4 ab.
            -- [KS3 -> KS2 2026-07-15] War KS3, weil der Body hier in die Kamera schwingt. Genau das
            -- erledigt jetzt der Head-Nagel (KS2 ist Teil des Nagel-Gates) -> Mesh-Aus unnoetig.
            killswitch_active = true
            ks2_active = true
            pin_release_active = false
            activating_reason = "ks2_ladder_exit:" .. tostring(st)
            fp_latch = true; fp_latch_state = st; fp_latch_level = 2
        elseif player_is_ladder() then
            -- [LEITER] an der Leiter (get_IsLadder) -> KS2 (TEST 2026-07-16, war KS4). KS2 = First-Person,
            -- Head/Hair aus, Body sichtbar, ABER Scripte bleiben AN (anders als KS4). Zweck: der Yaw-Stick
            -- soll dann tot sein (KS2_STICK_LOCK greift bei is_ks2). Rueckweg = ks2->ks4 + level 2->4 + reason.
            killswitch_active = true
            ks2_active = true
            pin_release_active = false
            activating_reason = "ks2_ladder:" .. tostring(st)
            fp_latch = true; fp_latch_state = st; fp_latch_level = 2
            -- [LEANING_LADDER] NUR beim Klettern (KS4) + wenn eine schraege Leiter bestiegen wurde
            -- (tryUse-Latch). firstperson.lua legt dann den additiven HMD-Offset drauf. Der KS3-Ausstieg
            -- (eigener Branch oben) laesst das Flag false -> Defaults.
            _G.__re4_leaning_ladder_active = (rawget(_G, "__re4_leaning_ladder_mounted") == true)
        elseif now < jumpdown_until then
            killswitch_active = true
            -- [KS3 -> KS2 2026-07-15] Runterspringen war KS3 (ganzes Mesh aus). Jetzt KS2 (nur Head/Hair
            -- aus) -> ueber ks2_now greift der Head-Nagel, der Body bleibt hinter der Kamera.
            ks2_active = true
            pin_release_active = false
            activating_reason = "jumpdown:" .. tostring(st)
            fp_latch = false; fp_latch_state = nil; fp_latch_level = 0
        elseif is_gameplay_camstate(st) and not gimmick_ng then
            killswitch_active = false
            activating_reason = nil
            fp_latch = false; fp_latch_state = nil; fp_latch_level = 0
            _G.__re4_leaning_ladder_mounted = false   -- [LEANING_LADDER] off ladder (reines Gameplay) -> Latch loeschen
            -- Event vorbei -> Eintritts-Fingerprint als "letztes Event" sichern
            -- (Monitor-Button laesst sich so auch NACH dem Event noch druecken).
            if cur_episode_entry then last_episode_entry = cur_episode_entry; cur_episode_entry = nil end
        elseif is_pinrelease_camstate(st) and not gimmick_ng then
            killswitch_active = false       -- HMD-Yaw + Hard-Yaw bleiben aktiv
            pin_release_active = true        -- nur Spine/Crouch-Pin loesen
            activating_reason = "pinrelease:" .. tostring(st)
            fp_latch = false; fp_latch_state = nil; fp_latch_level = 0
        else
            -- [FP_LATCH] Nicht-Gameplay-State. Neue Episode (State-Wechsel) -> Latch reset
            -- + Event-Eintritts-Fingerprint (Stage/Pos/CamState) EINFRIEREN fuer den Zonen-Abgleich.
            if st ~= fp_latch_state then
                fp_latch = false; fp_latch_state = st; fp_latch_level = 0
                local p = get_player_pos()
                local stg, spc = read_stage_space()
                cur_episode_entry = {
                    stage = stg, space = spc, camstate = st,
                    pos = p and { x = p.x, y = p.y, z = p.z } or nil,
                }
            end
            if not fp_latch then
                -- [ZONES] map+position zuerst (Kugel um die Event-Mitte); KS3 vor KS2.
                -- Danach (Fallback) die alten CamState-Listen/Node-Regeln, falls je ein
                -- solides Nicht-Positions-Merkmal dazukommt.
                local zlvl = zone_level_for(cur_episode_entry)
                if zlvl == 3 then fp_latch = true; fp_latch_level = 3
                -- [KS4-ZONE 2026-07-17] Ohne diesen Zweig faellt eine per Button gesetzte KS4-Zone STUMM
                -- durch (zone_level_for liefert 4, hier wurde nur 2|3 behandelt) -> Zone gespeichert, aber
                -- wirkungslos. fp_latch_level=4 wird unten schon zu ks4_active verarbeitet.
                elseif zlvl == 4 then fp_latch = true; fp_latch_level = 4
                elseif zlvl == 2 then fp_latch = true; fp_latch_level = 2
                elseif is_ks3_camstate(st) then fp_latch = true; fp_latch_level = 3
                elseif is_ks4_camstate(st) then fp_latch = true; fp_latch_level = 4
                elseif is_ks2_camstate(st) then fp_latch = true; fp_latch_level = 2 end
            end
            -- [HOOKSHOT->GIMMICK KS4 2026-07-20] Der "Gimmick"-CamState direkt nach dem Enterhaken
            -- (Landung/Absetz-Anim) laeuft sonst als KS1 = volle 3rd-Person. Innerhalb des Fensters
            -- (Default 1.5 s, live ueber __re4_hookshot_ks4_sec) wird daraus KS4 -> First-Person bleibt.
            -- War zwischenzeitlich testweise raus; er ist NICHT die Ursache der Reload-/Messer-Probleme.
            if hookshot_int ~= nil and st == hookshot_int then
                hookshot_seen_t = os.clock()
                _G.__re4_hookshot_recent_until = os.clock() + (tonumber(rawget(_G, "__re4_hookshot_grace_sec")) or 4.0)
            end
            if gimmick_int ~= nil and st == gimmick_int and hookshot_seen_t > 0
               and (os.clock() - hookshot_seen_t) < (tonumber(rawget(_G, "__re4_hookshot_ks4_sec")) or 1.5) then
                fp_latch = true; fp_latch_level = 4
            end
            -- [DAMAGE_KS3 2026-07-17, so gewollt "alles was Zustand Damage ist -> KS3 statt KS4/KS2"] JEDE
            -- Damage-Reaktion auf KS3 (ganzes Mesh aus) -- egal ob sie vorher auf KS2 (Normalfall) ODER KS4
            -- (KS4-Zone) aufgeloest hat. Grund wie der Grapple-Override: Body schwenkt trotz Head-Nagel ins Bild.
            -- Frueher nur Stage 65100 (DAMAGE_KS3_65100 2026-07-16), dann nur KS2->KS3; jetzt WIRKLICH jeder
            -- Damage-State. st==damage_int deckt auch das DAMAGE_HOLD-Fenster ab (oben auf damage_int gezwungen).
            if fp_latch and damage_int ~= nil and st == damage_int
               and (fp_latch_level == 2 or fp_latch_level == 4) then
                fp_latch_level = 3
            end
            killswitch_active = true
            if fp_latch and fp_latch_level == 3 then
                ks3_active = true            -- [KS3] First-Person + gesamtes Mesh aus
                activating_reason = "ks3:" .. tostring(st)
            elseif fp_latch and fp_latch_level == 4 then
                ks4_active = true            -- [KS4] FP + Head/Hair aus (Body sichtbar) + ALLE Scripte aus
                activating_reason = "ks4:" .. tostring(st)
            elseif fp_latch and fp_latch_level == 2 then
                ks2_active = true            -- [KS2] First-Person + nur Head/Hair aus
                activating_reason = "ks2:" .. tostring(st)
            else
                activating_reason = "camstate:" .. tostring(st)   -- KS1 (voll)
            end
        end
    else
        current_cam_state = nil
        killswitch_active = true
        activating_reason = ctrl_name or "no_controller"
        fp_latch = false; fp_latch_state = nil; fp_latch_level = 0
        -- [HOOK-ZWISCHENKAMERA 2026-07-20] Fremde Kamera-Controller laufen normal als KS1 (volle
        -- 3rd-Person) -- so soll es auch bleiben. AUSNAHME: direkt nach einem Enterhaken schiebt sich
        -- fuer ~1 s ein chainsaw.ActionCameraController dazwischen (Monitor-Dump 19:15:49), und genau
        -- da sah man sich in der 3rd-Person. Innerhalb des Haken-Fensters daher KS4 statt KS1.
        -- Eng gegatet ueber hookshot_seen_t: greift NUR nach einem Haken. Leon hat keinen Enterhaken,
        -- ihn kann dieser Zweig also nie treffen. Fenster = derselbe Wert wie beim Gimmick-Nachlauf.
        if hookshot_seen_t > 0
           and (os.clock() - hookshot_seen_t) < (tonumber(rawget(_G, "__re4_hookshot_ks4_sec")) or 1.5) then
            ks4_active = true
            _G.__re4_ks4_active = true
            fp_latch = true; fp_latch_level = 4
            activating_reason = "ks4_hook_actioncam"
        end
    end
end

local function evaluate()
    local prev = killswitch_active

    evaluate_core()


    -- [KS2_ALS_KS4 2026-07-21, "ueberall wo KS2 ist kann eigentlich immer der KS4 feuern"]
    -- Jedes erkannte KS2 wird als KS4 behandelt. Unterschied in der Praxis: KS4 schaltet zusaetzlich die
    -- ungateten Scripte ab (Gesten/Messer/Reload/Haptik) und gibt beim Eintritt das Skelett per
    -- resetBasePose an die Engine zurueck -- genau das, was in 3rd-Person und auch sonst gewollt ist.
    -- Motion und arm_chain waren in KS2 ohnehin schon aus (die haengen an is_active).
    -- Bewusst als SCHALTER statt Loeschung: KS2 bleibt komplett erhalten und ist eine Zeile weit zurueck.
    -- KS3 bleibt unberuehrt (ist ohnehin stillgelegt), KS5 sowieso.
    -- [BOXBREAK AUSGENOMMEN 2026-07-22, "nur das Kisten-Kicken"] Der Fass-/Kisten-Tritt soll
    -- BEWUSST KS2 bleiben (Scripte an), nicht wie alle anderen KS2 zu KS4 hochgestuft werden. Erkennbar
    -- an boxbreak_active (setzt nur der Kick-Block). Alle uebrigen KS2 werden weiter zu KS4 promotet.
    if _G.__re4_ks2_as_ks4 ~= false and ks2_active and not boxbreak_active then
        ks2_active = false
        ks4_active = true
    end

    -- [FP_GATE 2026-07-21] Der Schalter greift NICHT hier: die Stufen bleiben vollstaendig
    -- erhalten, damit KS4 weiterhin ALLE Scripte abschaltet (__re4_ks4_active unten). Umgebogen wird
    -- allein die First-Person-DARSTELLUNG -- siehe die is_ks2/3/4-Abfragen am Dateiende, die bei
    -- ausgeschaltetem Toggle false melden. Ergebnis: Szene laeuft in 3rd-Person, Scripte bleiben aus.

    -- [KS4] Globales Flag fuer die ungateten Scripte (gestures/haptic/knife/reload/unlimited):
    -- die kennen den Killswitch nicht, bailen aber ueber dieses Flag im Kick (KS4).
    -- [FP_GATE 2026-07-21] Toggle AUS -> in JEDEM Killswitch alle ungateten Scripte abschalten,
    -- nicht nur in KS4/KS5. Grund: KS2/KS3 lassen Gesten/Messer/Reload bewusst weiterlaufen, weil man
    -- in First-Person nur den Kopf ausblendet. In 3rd-Person sieht man den ganzen Koerper -- dort muss
    -- alles ruhen, sonst hantiert Leon sichtbar in der Szene herum.
    _G.__re4_ks4_active = ks4_active or ks5_active
        or (_G.__re4_ks_fp_enabled == false and killswitch_active)
    -- [KS_GLOBAL 2026-07-15] killswitch_active als GLOBAL. Zweck: Scripte killswitch-aware machen, die den
    -- Killswitch nicht requiren koennen -- reload.lua steht bei 196, motion.lua bei 198 von 200 Top-Level-
    -- Locals, und das uebliche Muster (require + killswitch-Variable + ks_active-Helfer) kostet DREI
    -- neue Locals und kippt sie sofort. Ein Global kostet keinen Slot:
    -- if rawget(_G, "__re4_ks_active") == true then return end
    -- Wer requiren KANN, soll weiter killswitch.is_active nehmen (typsicher, kein Global-Raten).
    _G.__re4_ks_active = killswitch_active
    -- [KS4-BOXBREAK] firstperson liest dies fuer den eigenen HMD-Offset NUR beim Fass-Tritt.
    _G.__re4_boxbreak_active = boxbreak_active
    -- [KS4-FATALKICK] firstperson liest dies fuer einen EIGENEN HMD-Offset beim Fatal-/Roundhouse-Tritt.
    -- NUR der echte Kick-CamState (is_ks4_camstate = FatalKick/FatalRoundKick) darf das setzen! Die LEITER
    -- (und andere Flag-KS4) sind AUCH ks4_active -> ohne diesen CamState-Check klaute Fatalkick dem
    -- Ladder-Offset (und jedem anderen KS4) den Offset-Zweig -> deren Slider taten nichts. boxbreak eh raus.
    _G.__re4_fatalkick_active = ks4_active and (not boxbreak_active)
        and (current_cam_state ~= nil and is_ks4_camstate(current_cam_state) == true)
    -- [FORCECROUCH_HEADPIN 2026-07-15] Reines Info-Flag fuer firstperson (Head-Nagel), KEIN Killswitch:
    -- ForceCrouch ist und bleibt Gameplay (volle VR-Steuerung, kein Flackern gegen Crouch). Der Nagel
    -- haengt nicht am KS-Grad -> er kann hier trotzdem greifen. current_cam_state ist an dieser Stelle
    -- frisch (evaluate_core lief schon); ausserhalb des is_pc-Zweigs ist es nil -> Flag sauber false.
    _G.__re4_forcecrouch_active = (forcecrouch_int ~= nil and current_cam_state == forcecrouch_int)

    current_stage, current_space = read_stage_space()

    -- [KS4_EXIT_FADE 2026-07-17, so gewollt] Zeitstempel beim VERLASSEN von KS4 -> motion.lua lerpt BEIDE
    -- Haende weich von der nativen Engine-Pose zum Controller, statt hart zu snappen. Muster 1:1 wie der
    -- erprobte [RELOAD-FADE] im Minecart (motion.lua, __re4_railcar_reload_fade).
    -- NUR KS4 (ausdruecklich so gewuenscht) -- deshalb eine EIGENE Flanke auf ks4_active statt der
    -- allgemeinen killswitch_active-Kante darunter.
    -- WARUM NICHT anim_blend_back: das existiert zwar genau dafuer ("weiches Zurueckblenden der
    -- Hand-Overrides", s. Header) und wird auch berechnet -- aber es liest NIEMAND (toter Export, per Grep
    -- ueber alle aktiven Scripte belegt) und es feuert bei JEDEM KS-Ende, nicht nur bei KS4. Unangetastet
    -- gelassen, damit nichts kippt, falls es doch mal jemand verdrahtet.
    -- Die DAUER steht bewusst nicht hier, sondern als Slider in motion.lua (dort sind die Hand-Regler und
    -- dort passiert der Lerp) -> hier nur das WANN, kein Timing.
    -- [EXIT_FADE 2026-07-20] ALLE drei Flanken (KS4, KS3, KS2) setzen denselben Stempel. Damit
    -- blendet motion.lua die Haende auch nach Leiter/Sprung/Traversal/Damage weich ein statt hart zu
    -- springen. Wechselt ein Zustand direkt in einen anderen (z.B. KS3 -> KS2), feuert nur die Flanke
    -- des tatsaechlich beendeten -- der Stempel wird dabei hoechstens neu gesetzt, nie doppelt gezaehlt.
    if (prev_ks4_exit and not ks4_active)
       or (prev_ks3_exit and not ks3_active)
       or (prev_ks2_exit and not ks2_active) then
        _G.__re4_ks4_exit_t = os.clock()
    end
    prev_ks4_exit = ks4_active
    prev_ks3_exit = ks3_active
    prev_ks2_exit = ks2_active

    -- Edge: Deaktivierung -> blend_back 1.0 -> 0.0 ueber ANIM_BLEND_DURATION
    if prev and not killswitch_active then
        anim_blend_back = 1.0
        anim_blend_back_t = os.clock()
    end
    if anim_blend_back > 0.0 then
        local el = os.clock() - anim_blend_back_t
        if el >= ANIM_BLEND_DURATION then
            anim_blend_back = 0.0
        else
            anim_blend_back = 1.0 - (el / ANIM_BLEND_DURATION)
        end
    end

    -- [JOINT_RELEASE 2026-07-16] Bei EINTRITT in einen "voll aus"-Killswitch (KS1/KS4/KS5) das Skelett EINMAL
    -- an die Engine zurueckgeben: resetBasePose loest die von unseren Pins festgehaltene Pose (movement/
    -- arm_chain/motion pinnen Hip/Spine/Neck/Arme; im statischen Zustand treibt die Engine sie NICHT neu an
    -- -> unser letzter Write klebt, auch nach Script-Aus). resetBasePose gibt die Joints an die Engine zurueck,
    -- die dann neu antreibt -- wie die "Zwischendemo"/Save-Load. NUR KS1/4/5: KS2/KS3 lassen die Joint-Setz-
    -- Scripte ABSICHTLICH laufen -> dort NICHT resetten. Edge-getriggert (einmal pro Eintritt).
    do
        local ks1 = killswitch_active and not ks2_active and not ks3_active and not ks4_active and not ks5_active
        local full_off = ks1 or ks4_active or ks5_active
        -- [FP_GATE 2026-07-21, "die Arme sind krumm"] Toggle AUS -> auch KS2/KS3 gelten als voll-aus.
        -- Sonst bleibt die zuletzt von uns geschriebene Pose an den Joints kleben (die Engine treibt sie im
        -- statischen Zustand nicht neu an) -- in First-Person unsichtbar, in 3rd-Person sofort zu sehen.
        if _G.__re4_ks_fp_enabled == false and killswitch_active then full_off = true end
        if full_off and not prev_full_off then
            local body = get_player_body()
            local tf = body and safe(function() return body:call("get_Transform") end)
            if tf then pcall(function() tf:call("resetBasePose") end) end
        end
        prev_full_off = full_off
    end

    was_active = prev
end

re.on_pre_application_entry("UpdateScene", function()
    -- [FEHLER-DIAG 2026-07-20] pcall verschluckt JEDEN Laufzeitfehler in evaluate -> der ganze
    -- Killswitch-Zustand bliebe auf den Startwerten (camstate=nil, killswitch_active=false) stehen, ohne
    -- dass irgendwo etwas auffaellt. Genau dieses Bild meldet holster.lua. Fehler daher EINMAL sichtbar
    -- machen (danach still, kein Log-Dauerfeuer): reframework/data/re4_killswitch_error.log
    local ok, err = pcall(evaluate)
    -- [QUELLE-DIAG 2026-07-20 ENTFERNT 2026-07-21] Der KSQUELLE-Tick (rkdiag, 1x/s) ist raus.
    -- Fehler EINMAL in einem Global hinterlegen: KEINE Datei, kein Log. Anzeigen kann
    -- ihn ein "#"-Werkzeug -- die Produktivscripte schreiben nichts mehr auf die Platte.
    if not ok and not _G.__re4_ks_err then
        _G.__re4_ks_err = tostring(err)
    end
end)

-- ---------------------------------------------------------------------
-- KEINE UI (-Vorgabe): der Killswitch hat keine eigene Oberflaeche.
-- Status/State-Details werden ausschliesslich im Monitoring-Script (#monitor.lua)
-- ueber die unten exportierten Getter angezeigt.
-- ---------------------------------------------------------------------

re.on_script_reset(function()
    killswitch_active = false
    pin_release_active = false
    ks2_active = false
    ks3_active = false
    ks5_active = false
    fp_latch = false
    fp_latch_state = nil
    fp_latch_level = 0
    damage_until = 0.0
    jumpdown_until = 0.0
    jumpdown_confirmed = false
    was_active = false
    prev_full_off = false
    prev_ks4_exit = false          -- [KS4_EXIT_FADE] Flanke frisch: kein Phantom-Fade nach Reset Scripts
    _G.__re4_ks4_exit_t = nil      -- laufendes Fade-Fenster verwerfen
    anim_blend_back = 0.0
    force_killswitch = false
    character_manager = nil
    camera_system = nil
    gui_manager = nil
    mfsm2_cache.comp = nil
    mfsm2_cache.body = nil
    motion_cache.comp = nil
    motion_cache.body = nil
    cur_episode_entry = nil
    last_episode_entry = nil
    load_zones()
end)

-- ---------------------------------------------------------------------
-- Exports (RE9-Form)
-- ---------------------------------------------------------------------
-- =====================================================================
-- [PUBLIC-UI 2026-07-23] Schalter fuer die Public-Version: steht OHNE Tree direkt im nackten
-- Hauptmenue und ist 1:1 derselbe Schalter wie im Dev-Tree darunter (gleiches Global, gleiches Save)
-- -- nur mit einem Namen, den ein Spieler versteht. Zweck: beim Release wird schlicht jeder Block
-- mit dem Marker [DEV-UI] entfernt, dann bleibt genau diese schlanke Menueflaeche uebrig; die
-- Entwicklerfassung behaelt beides und laesst sich unveraendert weiterentwickeln.
-- REGEL: hier kommt NUR rein, was ausdruecklich benannt wurde -- nichts eigenmaechtig nachziehen.
-- =====================================================================
do
    local draw = function()
        local on = _G.__re4_ks_fp_enabled ~= false
        local ch, v = imgui.checkbox("Enable Firstperson Events", on)
        if ch then _G.__re4_ks_fp_enabled = (v == true); save_ks_cfg() end
    end
    -- Reihenfolge zentral ueber #re4_vr_menu.lua (Platz 20); ohne Dispatcher eigener Callback.
    local add = rawget(_G, "__re4_ui_add")
    if type(add) == "function" then add(20, "ks_fp_events", draw) else re.on_draw_ui(draw) end
end

-- [DEV-UI ENTFERNT 2026-07-23] Der Tree "RE4VR - Killswitch" ist raus. Grund: dieses Script
-- liegt im Unterordner re4vr/ und wird von einem frueh ladenden Script eingebunden, sein Tree stand
-- deshalb IMMER oberhalb des Menue-Dispatchers -- statt das zu sortieren, faellt der Tree weg.
-- Der Public-Schalter "Enable Firstperson Events" oben bleibt unveraendert.
-- MERKE: Damit hat auch "KS2 immer als KS4 behandeln" keine Oberflaeche mehr. Das Verhalten selbst
-- ist unberuehrt -- `_G.__re4_ks2_as_ks4` wird weiterhin geladen und gespeichert und laesst sich in
-- der Killswitch-JSON umstellen; nur der Haken dafuer ist weg.

return {
    is_active                 = function() return killswitch_active end,
    is_pin_release            = function() return pin_release_active end,
    -- [FP_GATE 2026-07-21] Diese drei sagen "First-Person-Darstellung an": firstperson (Kamera,
    -- Head-Nagel, Offsets), materials (Mesh ausblenden) und binding (Stick-Lock) haengen daran.
    -- Toggle AUS -> sie melden false, die Szene bleibt also in 3rd-Person. Die Stufen selbst laufen
    -- unveraendert weiter, insbesondere schaltet KS4 weiterhin alle Scripte ab (__re4_ks4_active).
    -- KS5 (Minecart) ist bewusst NICHT gegated und bleibt in beiden Stellungen wie es ist.
    is_ks2                    = function() return ks2_active and _G.__re4_ks_fp_enabled ~= false end,
    is_ks3                    = function() return ks3_active and _G.__re4_ks_fp_enabled ~= false end,
    -- [JETSKI IMMER FP 2026-07-21] Wie das Minecart (KS5): die Jetski-Fahrt bleibt in JEDER
    -- Toggle-Stellung First-Person. Erkannt am eigenen Flag des Jetski-Zweigs, nicht an der Stufe.
    is_ks4                    = function()
        if ks4_active and rawget(_G, "__re4_jetski_active") == true then return true end
        return ks4_active and _G.__re4_ks_fp_enabled ~= false
    end,
    is_ks5                    = function() return ks5_active end,       -- [KS5] FP + ALLE Scripte aus + GESAMTES Mesh aus
    is_fp_only                = function() return ks3_active end,       -- Alias (= KS3, Rueckwaertskompat)
    just_activated            = function() return killswitch_active and not was_active end,
    just_deactivated          = function() return not killswitch_active and was_active end,

    is_cutscene_active        = function() return killswitch_active end,
    is_real_cutscene          = function() local c = is_real_cutscene(); return c end,
    is_crouch_active          = function() return is_crouch_active() end,
    is_player_camera_active   = function() return is_player_camera_active() end,
    -- [AUTO_REDRAW] STRIKT: nur reines Gameplay (aktiver PlayerCameraController + Gameplay-CamState,
    -- kein voller KS, kein Pin-Release, keine Cutscene). current_cam_state==nil = Cutscene/Event -> false.
    -- Gate fuer holster.lua Auto-Redraw: Leiter/Vault/Finisher/Grapple/Fall laufen ueber vollen KS -> false.
    is_pure_gameplay          = function()
        if killswitch_active then return false end
        if pin_release_active then return false end
        if current_cam_state == nil then return false end
        return is_gameplay_camstate(current_cam_state)
    end,
    get_busy_controller       = function() return get_busy_controller() end,

    get_controller            = function() return current_controller end,
    get_previous_controller   = function() return previous_controller end,
    get_cam_state             = function() return current_cam_state end,
    -- [FORENSIK 2026-07-20] Auch als Global, damit eigenstaendige Diag-Scripte den CamState lesen
    -- koennen, ohne das Modul zu requiren (sie laufen sonst gegen das Fallback-Dummy).

    get_stage_name            = function() return current_stage end,
    get_space_id              = function() return current_space end,
    get_anim_blend_back       = function() return anim_blend_back end,
    get_activating_controller = function() return activating_reason end,

    -- [ZONES] map+position-basierte KS2/KS3-Zuweisung (vom Monitor bedient).
    -- mark_current_zone(level, radius): friert das aktuelle (oder zuletzt beendete)
    -- Nicht-Gameplay-Event als Zone ein. Liefert (true, zone) oder (false, grund).
    mark_current_zone = function(level, radius)
        -- [KS4-ZONE 2026-07-17, so gewollt] Level 4 zusaetzlich erlaubt (Button im Monitor, analog KS2/KS3).
        -- KS4 = Head/Hair aus + ALLE Scripte aus (Aufzug-/Sonderfall-KS). fp_latch_level=4 wird im is_pc-Branch
        -- bereits zu ks4_active verarbeitet -- es fehlte nur der Weg von der Zone dorthin (s. zone_level_for-
        -- Auswertung) und diese Schranke hier.
        if level ~= 2 and level ~= 3 and level ~= 4 then return false, "level muss 2, 3 oder 4 sein" end
        local e = cur_episode_entry or last_episode_entry
        if not e or not e.pos then return false, "kein Event-Eintritt erfasst" end
        local z = {
            stage = e.stage, space = e.space,
            x = e.pos.x, y = e.pos.y, z = e.pos.z,
            r = radius or 3.0, level = level, camstate = e.camstate,
            name = string.format("KS%d stage=%s cam=%s", level, tostring(e.stage), tostring(e.camstate)),
        }
        KS_ZONES[#KS_ZONES + 1] = z
        save_zones()
        return true, z
    end,
    remove_last_zone          = function()
        if #KS_ZONES == 0 then return false, "keine Zonen" end
        local z = table.remove(KS_ZONES)
        save_zones()
        return true, z
    end,
    reload_zones              = function() load_zones(); return #KS_ZONES end,
    get_zones                 = function() return KS_ZONES end,
    get_zone_count            = function() return #KS_ZONES end,
    get_current_entry         = function() return cur_episode_entry or last_episode_entry end,

    -- Kompat-Helper (arm_chain & Co. nutzen die vom alten Killswitch)
    get_player_context        = function() return get_player_context() end,
    get_player_body           = function() return get_player_body() end,

    -- [FP_GATE 2026-07-21] Schalter fuer alle First-Person-Killswitches (siehe oben).
    get_fp_enabled            = function() return _G.__re4_ks_fp_enabled ~= false end,
    set_fp_enabled            = function(v) _G.__re4_ks_fp_enabled = (v == true); save_ks_cfg() end,
}
