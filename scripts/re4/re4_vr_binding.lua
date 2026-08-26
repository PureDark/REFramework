-- PORTED TO C++: src/mods/vr/games/re4/RE4VRBinding.cpp (kept as reference)
return

-- =====================================================================
-- RE4 VR Controller Bindings — ViGEm-Version (1:1 Übersetzung des
-- HID-Hook-Scripts, Stand 2026-06-04; Original: re4_vr_binding.lua.hid_bak)
-- =====================================================================
-- Branches (Priorität wie im HID-Script):
-- 1. in_boat (gm02_500_00_2 — Boot-Section)
-- 2. in_throwsight (gm02_500_00_1 — Fish-Boss)
-- 3. in_menu (GUI/Inventory/Map)
-- 4. ks_active (Killswitch)
-- 5. in_binoculars (Fernglas-Gimmick)
-- 6. GAMEPLAY (Default, L.A-Longpress Leon/Ada)
--
-- HID→ViGEm-Mapping:
-- LTrigBottom+AnalogLeft → LT(1.0) | LTrigTop → LB
-- RTrigBottom+AnalogRight → RT(1.0) | RTrigTop → RB
-- LStickPush → LS | RStickPush → RS | CLeft → BACK | CRight → START
-- Decide|RDown → A | Cancel|RRight → B | RLeft → X | RUp → Y
-- LUp/LDown/LLeft/LRight → DPAD_*
-- =====================================================================

if reframework:get_game_name() ~= "re4" then return end
if not vigem then return end

vr_controller_type = "index"

-- Knife/Grenade Globals (read by other scripts)
if vr_knife_swing == nil then vr_knife_swing = false end
if vr_grenade_throw == nil then vr_grenade_throw = false end
if vr_is_grenade_equipped == nil then vr_is_grenade_equipped = false end
if vr_holster_knife == nil then vr_holster_knife = false end
if vr_knife_equip == nil then vr_knife_equip = false end
if vr_knife_active == nil then vr_knife_active = false end
if __vr_melee_physical_active == nil then __vr_melee_physical_active = false end
--- Optional: set `_G.__vr_disable_motion_grenade_rt = true` for trigger-only grenades (no swing→RT).
--- Knife motion→RT requires left grip (or holster chest R-grip-as-L-grip); otherwise only real RT fires
--- (avoids accidental 3rd-person melee from right-hand swings; grenade path still uses grenade_motion_rt_armed).

local re4 = require("utility/RE4")
local ok_ks, killswitch = pcall(function()
    return require("re4vr/re4_vr_killswitch")
end)
if not ok_ks or not killswitch then
    return
end

-- ============================================================
-- [REF_OVERLAY] REFramework-VR-Menü Toggle (L.Trigger + L.B), Port aus RE9.
-- OpenVR-only. Sound-ID kommt später (REFUI_TOGGLE_SOUND = 0 = stumm).
-- ============================================================
local PREFS_PATH = "re4_vr/re4_vr_bindings.json"
-- [LA_TIMING] long_press_sec = Haltezeit ab der Links-A als Longpress zaehlt (Default 1,5 s).
-- short_min_sec = Mindest-Haltezeit, damit ein Tap als Shortpress zaehlt (0 = jeder Tap; anheben
-- gegen versehentliches Antippen). Beide in Sekunden, im Binding-UI einstellbar.
-- [QUICKTURN_180 2026-08-02] enable_180_rotation = Doppel-Tipp linker Stick runter -> 180-Grad-
-- Kehrtwende (Port aus RE9). DEFAULT AUS -- bewusst, weil ein versehentlicher Doppel-Tipp sonst mitten
-- im Gefecht die Blickrichtung dreht.
-- turn180_window_sec = maximale PAUSE zwischen dem ersten und dem zweiten Tipp (RE9-Wert 0.17 s).
local PREFS = { hide_ref_overlay = false, long_press_sec = 1.5, short_min_sec = 0.0, enable_180_rotation = false, turn180_window_sec = 0.17, turn180_ly_sec = 0.10, turn180_rb_sec = 0.35, enable_snapturn = false, snapturn_deg = 45, snapturn_thresh = 0.75, turn180_sec = 0.15 }
do
    local ok, loaded = pcall(json.load_file, PREFS_PATH)
    if ok and type(loaded) == "table" then
        if loaded.hide_ref_overlay ~= nil then
            PREFS.hide_ref_overlay = loaded.hide_ref_overlay and true or false
        end
        if type(loaded.long_press_sec) == "number" then PREFS.long_press_sec = loaded.long_press_sec end
        if type(loaded.short_min_sec) == "number" then PREFS.short_min_sec = loaded.short_min_sec end
        if loaded.enable_180_rotation ~= nil then
            PREFS.enable_180_rotation = loaded.enable_180_rotation and true or false
        end
        if type(loaded.turn180_window_sec) == "number" then PREFS.turn180_window_sec = loaded.turn180_window_sec end
        if type(loaded.turn180_ly_sec) == "number" then PREFS.turn180_ly_sec = loaded.turn180_ly_sec end
        if type(loaded.turn180_sec) == "number" then PREFS.turn180_sec = loaded.turn180_sec end
        if type(loaded.turn180_rb_sec) == "number" then PREFS.turn180_rb_sec = loaded.turn180_rb_sec end
        if loaded.enable_snapturn ~= nil then
            PREFS.enable_snapturn = loaded.enable_snapturn and true or false
        end
        if type(loaded.snapturn_deg) == "number" then PREFS.snapturn_deg = loaded.snapturn_deg end
        if type(loaded.snapturn_thresh) == "number" then PREFS.snapturn_thresh = loaded.snapturn_thresh end
    end
end
local function save_prefs() pcall(json.dump_file, PREFS_PATH, PREFS) end

-- ============================================================
-- [SNAPTURN-UI] EINE Funktion, zwei Orte
-- ============================================================
-- Der nackte Public-Bereich zeigt immer nur eine KOPIE dessen, was auch im Dev-Tree
-- liegt. Damit beide nie auseinanderlaufen, wird hier genau einmal gezeichnet und an
-- beiden Stellen aufgerufen. `sfx` haengt an jede imgui-ID -- ohne eigene IDs wuerde
-- ImGui die doppelten Labels als DASSELBE Element behandeln und der zweite Haken waere
-- tot. Der Wert dahinter ist derselbe (PREFS), die Haken zeigen also immer dasselbe.
local function draw_snapturn_ui(sfx)
    local c2, v2 = imgui.checkbox("Enable Snapturn##st" .. sfx, PREFS.enable_snapturn)
    if c2 then
        PREFS.enable_snapturn = v2
        -- [2026-08-11] Hier stand `qt.st_armed = true`. `qt` ist aber erst ~Z. 1060 als
        -- local definiert -- in dieser Funktion war es deshalb ein GLOBALES nil, der
        -- Zugriff warf, und das `save_prefs()` darunter lief nie. Symptom: Haken liess
        -- sich ausschalten, war nach "Reset Scripts" aber wieder an (die JSON behielt
        -- den alten Wert). Die Scharfschaltung ist ohnehin ueberfluessig: der Laufzeit-
        -- Block schaltet selbst wieder scharf, sobald der Stick Richtung Mitte geht,
        -- und im Aus-Zweig sowieso.
        save_prefs()
    end
    if not PREFS.enable_snapturn then return end

    imgui.text("   Degree:")
    for _, d in ipairs({ 30, 45, 90 }) do
        imgui.same_line()
        if (tonumber(PREFS.snapturn_deg) or 45) == d then
            imgui.text_colored("[" .. d .. "]", 0xFF66FF66)
        elseif imgui.button(tostring(d) .. "##snapdeg" .. sfx) then
            PREFS.snapturn_deg = d
            save_prefs()
        end
    end
    -- Die Schwelle ist eine Feinjustage und gehoert NUR in den Dev-Tree. Der Wert dahinter
    -- ist derselbe PREFS-Eintrag wie ueberall -- was hier eingestellt wird, gilt damit
    -- automatisch auch fuer den Haken im nackten Public-Bereich.
    if sfx == "dev" then
        local c3, v3 = imgui.drag_float("Ausloese-Schwelle##snapthr" .. sfx,
            tonumber(PREFS.snapturn_thresh) or 0.75, 0.01, 0.30, 0.99, "%.2f")
        if c3 then PREFS.snapturn_thresh = v3; save_prefs() end
    end
end

local _ref_overlay_synced = false
local _ref_overlay_tick = 0
local lt_b_overlay_was = false
-- REFramework-VR-Menue Toggle-Sound.
-- [2026-08-04] Frueher ZWEI GuiSoundType-Enums (an=3555778714 / aus=4166037141) ueber den
-- GuiSoundManager. Jetzt EIN Sound fuer beide Richtungen, und zwar eine Wwise-TriggerId auf dem
-- SoundContainer des PLAYER-BODY (derselbe Container wie die Gesten-Sprueche). Diese ID ist bei
-- JEDEM Charakter dieselbe -> laeuft fuer Leon, Ada und die Mercs-Chars gleich.
local REFUI_SOUND = 801086617

-- Knife Grip Tracking
local prev_l_grip = false

-- Grenade Throw Cooldown
local grenade_throw_cooldown = 0
local GRENADE_COOLDOWN_FRAMES = 60

-- Motion grenade: brief RT pulse on first throw-detection frame (rising edge).
local grenade_rt_pulse_frames = 0
local prev_vr_grenade_throw = false

-- ============================================================
-- Helpers
-- ============================================================
local function safe(fn)
    local ok, res = pcall(fn)
    return ok and res or nil
end

local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

-- ============================================================
-- Live Equip-ID (Grenade-Gate auch während Killswitch korrekt)
-- ============================================================
-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: einmal pro Frame aufloesen statt bei
-- jedem Aufruf. Semantik unveraendert, alter Weg bleibt als Fallback. NOT-AUS: `_G.__re4_fc_off = true`.
pcall(function() require("re4vr/re4_vr_frame_cache") end)

local function binding_cm()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.get_managed_singleton("chainsaw.CharacterManager") end
    return sdk.get_managed_singleton("chainsaw.CharacterManager")
end

local function binding_ctx()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.ctx() end
    local cm = binding_cm()
    if not cm then return nil end
    return safe(function() return cm:call("getPlayerContextRef") end)
end

local character_manager_binding = nil

local function get_binding_equip_weapon_id()
    -- [FRAME-CACHE] Die 0-Sonderregel dieser Funktion bleibt: der Cache liefert die ROHE ID,
    -- hier gilt weiterhin "0 heisst keine Waffe" -> nil.
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then
        local w = _fc.equip_wid()
        if type(w) == "number" and w ~= 0 then return w end
        return nil
    end
    if not character_manager_binding then
        character_manager_binding = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    if not character_manager_binding then return nil end
    local ctx = safe(function()
        return character_manager_binding:call("getPlayerContextRef")
    end)
    if not ctx then return nil end
    local h_updater = safe(function() return ctx:call("get_HeadUpdater") end)
    if not h_updater then return nil end
    local wid = safe(function() return h_updater:call("get_EquipWeaponID") end)
    if wid == nil then return nil end
    if type(wid) == "number" then
        return wid ~= 0 and wid or nil
    end
    if type(wid) == "userdata" then
        local v = safe(function() return wid:get_field("value__") end)
        if type(v) == "number" then
            return v ~= 0 and v or nil
        end
    end
    return nil
end

local function binding_is_grenade_equipped_live()
    local w = get_binding_equip_weapon_id()
    return w ~= nil and w >= 5400 and w <= 5410
end

-- [GRAPPLE] true wenn der Spieler gerade niedergerungen/gegrappelt wird (Hund reisst nieder ->
-- RT-Mashing zum Losreissen). Live verifiziert: get_IsInGrappleDamage=true, stabil (kein Flackern).
-- Genutzt, um beim Messer den RT-Mute auszunehmen (echter Trigger darf feuern/wehren).
local function player_in_grapple()
    if not character_manager_binding then
        character_manager_binding = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    if not character_manager_binding then return false end
    local ctx = binding_ctx()
    if not ctx then return false end
    return safe(function() return ctx:call("get_IsInGrappleDamage") end) == true
end

-- [BATTLE] true wenn der Spieler im Kampf-State ist. Battle ist KEIN eigener State-Wert, sondern ein
-- Flag-Bit (0x1000000000000000, Bit 60), das oben auf die Lokomotion (Idle/Walk/Run) draufgeODERt wird
-- -> per Bit-Test pruefen, nicht per Gleichheit. Live live verifiziert (get_State = "None, Battle").
-- Analog zu player_in_grapple: dient dazu, den rohen RT im Kampf durchfeuern zu lassen.
local BATTLE_FLAG = 0x1000000000000000
local function player_in_battle()
    if not character_manager_binding then
        character_manager_binding = sdk.get_managed_singleton("chainsaw.CharacterManager")
    end
    if not character_manager_binding then return false end
    local ctx = binding_ctx()
    if not ctx then return false end
    local state = safe(function() return ctx:call("get_State") end)
    if type(state) ~= "number" then return false end
    return (state & BATTLE_FLAG) ~= 0
end

-- ============================================================
-- Stage Detection (Fish Bossfight / Boat — beide Stage 46900)
-- ============================================================
local function stage_parent_chain_has(prefix)
    local cm = binding_cm()
    if not cm then return false end
    local ctx = binding_ctx()
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
            if name and string.find(tostring(name), prefix, 1, true) then
                return true
            end
        end
        current = parent_tf
    end
    return false
end

-- [ADA_A_RAW_ZONE 2026-07-20] Stellen, an denen das SPIEL selbst ein langes A verlangt
-- (Hold-Prompt). Dort darf Adas A-Longpress-Remap (kurz=A / lang=RB) NICHT greifen, sonst
-- kommt beim Halten nie ein A an. Zone = gleiche Stage + Abstand < radius zur Merkposition.
-- Positionen kommen aus dem Monitor-Dump (Zeile "Stage/Space" + "Map"). Live erweiterbar via
-- _G.__re4_ada_raw_a_zones = { {stage=44210, x=.., y=.., z=.., r=3.0},... }
local ADA_RAW_A_ZONES = {
    { stage = 44210, x = -0.06,  y = -0.81, z = 181.36, r = 3.0 },
    { stage = 51859, x = -29.79, y =  6.20, z =  -2.30, r = 3.0 },   -- Dump 2026-07-20 22:20:57
    { stage = 51504, x = -33.42, y = 28.89, z = -69.48, r = 3.0 },   -- Dump 2026-07-20 22:52:22
    -- [2026-07-21] Dump 21:33:51: chainsaw.GimmickFixCameraController + Occupied PL_USE_ITEM_WAIT(6)
    -- = das Spiel wartet auf gehaltenes A ("Item benutzen"). Position aus dem Gameplay-Frame direkt
    -- davor/danach (21:34:40, Stage 55852) -- der Event-Frame selbst steht an derselben Stelle.
    { stage = 55852, x = 116.22, y = -29.01, z = -69.86, r = 3.0 },  -- Dump 2026-07-21 21:33:51
    -- [2026-07-21] Dump 22:44:19, Stage 56104 (Space 56101). Position aus dem Gameplay-Frame; der
    -- Event-Frame davor (22:44:07, Gimmick/ParentGimmick) steht mit 207.78/50.29/-94.69 praktisch
    -- an derselben Stelle (11 cm Unterschied) -> 3 m Radius deckt beide sicher ab.
    { stage = 56104, x = 207.78, y = 50.29, z = -94.80, r = 3.0 },   -- Dump 2026-07-21 22:44:19
    { stage = 60870, x = 25.75,  y =  1.44, z = 248.27, r = 3.0 },   -- Dump 2026-07-22 13:49:56 (Space 60850)
    { stage = 60880, x = 40.14,  y = -3.66, z = 260.06, r = 3.0 },   -- Dump 2026-07-22 14:00:06 (Space 60880)
}
local function is_ada_raw_a_zone()
    local zones = rawget(_G, "__re4_ada_raw_a_zones")
    if type(zones) ~= "table" then zones = ADA_RAW_A_ZONES end
    local cm = binding_cm()
    if not cm then return false end
    local ctx = binding_ctx()
    if not ctx then return false end
    local stage = safe(function() return ctx:call("get_CurrentStageID") end)
    if not stage then return false end
    local body = safe(function() return ctx:call("get_BodyGameObject") end)
    if not body then return false end
    local tf = safe(function() return body:call("get_Transform") end)
    if not tf then return false end
    local p = safe(function() return tf:get_position() end)
    if not p then return false end
    for _, z in ipairs(zones) do
        if tonumber(stage) == z.stage then
            local dx, dy, dz = p.x - z.x, p.y - z.y, p.z - z.z
            local r = z.r or 3.0
            if (dx * dx + dy * dy + dz * dz) <= (r * r) then return true end
        end
    end
    return false
end

local function is_throwsight_stage() return stage_parent_chain_has("gm02_500_00_1") end
local function is_boat_stage()       return stage_parent_chain_has("gm02_500_00_2") end

-- [SYMBOL_RIDDLE 2026-07-17] Erkennt EXAKT den Symbol-Raetsel-Zustand: Stage 44110 UND die Busy-Kamera ist
-- der GimmickFixCameraController -- identisches Gate wie der Symbol-Riddle-HMD-Offset in re4_vr_firstperson.
-- Grund fuer die Cam-Bedingung: oeffnet man in derselben Stage 44110 das ECHTE Pause-Menue, ist die Busy-Cam
-- KEIN GimmickFix -> nur das Raetsel trifft zu, das Menue-DPAD-Blaettern bleibt unangetastet. td in _G gecacht.
-- [SYMBOL/CHURCH/STONE-RIDDLE] Deckt ALLE GimmickFix-Raetsel mit identischen R-Stick->LB/RB-Bindings ab:
-- Stage 44110 (Symbol), 45401 (Church, Monitor-Dump 2026-07-18 02:43) UND 51503/51502 (Stone-Riddle -- gleiche
-- Stages + Busy-Cam wie der Stone-Riddle-HMD-Offset in re4_vr_firstperson, 2026-07-19 verdrahtet).
-- Name historisch beibehalten. Menue-Sicherheit gratis: oeffnet man in derselben Stage das ECHTE Menue, ist
-- die Busy-Cam KEIN GimmickFix -> is_symbol_riddle=false -> die DPAD-Menue-Branch unten greift wieder.
local function is_symbol_riddle()
    local cm = binding_cm()
    if not cm then return false end
    local ctx = binding_ctx()
    if not ctx then return false end
    local st = safe(function() return ctx:call("get_CurrentStageID") end)
    if st ~= 44110 and st ~= 45401 and st ~= 51503 and st ~= 51502 then return false end
    local cs = sdk.get_managed_singleton("chainsaw.CameraSystem")
    local main = cs and safe(function() return cs:call("get_MainCameraController") end)
    local busy = main and safe(function() return main:call("get_BusyCameraController") end)
    if not busy then return false end
    local td = rawget(_G, "__re4_gimmickfix_td")
    if not td then td = sdk.find_type_definition("chainsaw.GimmickFixCameraController"); _G.__re4_gimmickfix_td = td end
    if not td then return false end
    return safe(function() return busy:get_type_definition():is_a(td) end) == true
end

-- [TURRET 2026-07-16] MG-Turret erkennen (CameraDefine.GimmickType.InstalledMachineGun, live verifiziert
-- Stage 66101). EIGENER Signalweg, NICHT die grosse Kanone (gm84_572 / __re4_at_cannon in weapons2) -- das
-- ist ein anderes Gimmick. Gelesen aus dem StateParam der Busy-Kamera (wie der Monitor GimmickType liest),
-- jeden Frame frisch -> nie stale. Enum-Wert zur Ladezeit aufgeloest (Fallback 6, falls das TDB mal wackelt).
local TURRET_GIMMICK = (function()
    local t = sdk.find_type_definition("chainsaw.CameraDefine.GimmickType")
    if t then for _, fld in ipairs(t:get_fields() or {}) do
        if fld:is_static() and fld:get_name() == "InstalledMachineGun" then
            local ok, v = pcall(function() return fld:get_data(nil) end)
            if ok and type(v) == "number" then return v end
        end
    end end
    return 6   -- Fallback (live verifiziert: InstalledMachineGun = 6)
end)()
local function is_turret_mounted()
    local busy = killswitch.get_busy_controller and killswitch.get_busy_controller()
    if not busy then return false end
    local sp = safe(function() return busy:get_field("_CurrentStateParam") end)
    if not sp then return false end
    local gt = safe(function() return sp:get_field("<GimmickType>k__BackingField") end)
    if type(gt) ~= "number" then gt = gt and safe(function() return gt:get_field("value__") end) end
    return gt == TURRET_GIMMICK
end

-- ============================================================
-- Menu Detection
-- ============================================================
local cached_singletons = {
    guiManager = nil,
    attacheCaseManager = nil,
    mapManager = nil,
    pauseManager = nil,
    armouryManager = nil,
}

local function cache_menu_singletons()
    if not cached_singletons.guiManager then
        cached_singletons.guiManager = sdk.get_managed_singleton("chainsaw.GuiManager")
    end
    if not cached_singletons.attacheCaseManager then
        cached_singletons.attacheCaseManager = sdk.get_managed_singleton("chainsaw.AttacheCaseManager")
    end
    if not cached_singletons.mapManager then
        cached_singletons.mapManager = sdk.get_managed_singleton("chainsaw.MapManager")
    end
    if not cached_singletons.pauseManager then
        cached_singletons.pauseManager = sdk.get_managed_singleton("share.PauseManager")
    end
    if not cached_singletons.armouryManager then
        cached_singletons.armouryManager = sdk.get_managed_singleton("chainsaw.ArmouryManager")
    end
end

-- [CHAPTER_RESULT] Das Post-Kapitel-/Ergebnis-Menue (z.B. "ChapterEnd" nach einem Boss) setzt
-- KEINES der Standard-Menue-Signale (kein PauseLock/HudOff/AttacheCase/Map) -> lief faelschlich im
-- Gameplay-Branch (Left-A/B "Zurueck" reagierte nicht). Per GUI-Scan verifiziert: offen ist u.a.
-- chainsaw.GuiType.ChapterEnd. Wir fragen GuiManager:isOpenGui fuer den Ergebnis-Cluster ab.
local CHAPTER_RESULT_GUI_NAMES = {
    "ChapterEnd", "ChapterDetailResult", "ChapterDetailResultGuide", "ChapterStats", "GameClearResult",
}
local chapter_gui_vals = nil   -- { int,... }
local render_default_val = nil
local function resolve_chapter_gui_enums()
    if chapter_gui_vals then return end
    chapter_gui_vals = {}
    local td = sdk.find_type_definition("chainsaw.GuiType")
    if td then
        for _, nm in ipairs(CHAPTER_RESULT_GUI_NAMES) do
            local f = safe(function() return td:get_field(nm) end)
            local v = f and safe(function() return f:get_data(nil) end)
            if type(v) == "userdata" then v = safe(function() return v:get_field("value__") end) end
            if type(v) == "number" then chapter_gui_vals[#chapter_gui_vals + 1] = v end
        end
    end
    local rtd = sdk.find_type_definition("chainsaw.RenderOutputType")
    local rf = rtd and safe(function() return rtd:get_field("Default") end)
    local rv = rf and safe(function() return rf:get_data(nil) end)
    if type(rv) == "userdata" then rv = safe(function() return rv:get_field("value__") end) end
    render_default_val = type(rv) == "number" and rv or 0
end
local function is_chapter_result_gui_open()
    local gm = cached_singletons.guiManager
    if not gm then return false end
    resolve_chapter_gui_enums()
    for _, gv in ipairs(chapter_gui_vals) do
        local open = safe(function() return gm:call("isOpenGui", gv, render_default_val) end)
        if open == true then return true end
    end
    return false
end

-- [FILE_READER] Dokument-/Buch-Leser (in-world FUND beim Aufheben UND Inventar-Ansicht).
-- Setzt KEIN Standard-Menue-Signal (kein HudOff/PauseLock/AttacheCase) -> lief faelschlich im
-- Gameplay-Branch (rechter A/L-A "Schliessen/Blaettern" reagierte nicht). Per GUI-Vollscan
-- verifiziert (re4_guiscan.log): im Fund-Leser sind FileDetail + FileSelect offen. Wir behandeln
-- beide als Menue -> in_menu-Branch (B=Schliessen via L.A, DPAD=Blaettern via L.Trigger+R-Stick).
local FILE_READER_GUI_NAMES = { "FileDetail", "FileSelect" }
local file_reader_gui_vals = nil
local function resolve_file_reader_enums()
    if file_reader_gui_vals then return end
    file_reader_gui_vals = {}
    local td = sdk.find_type_definition("chainsaw.GuiType")
    if td then
        for _, nm in ipairs(FILE_READER_GUI_NAMES) do
            local f = safe(function() return td:get_field(nm) end)
            local v = f and safe(function() return f:get_data(nil) end)
            if type(v) == "userdata" then v = safe(function() return v:get_field("value__") end) end
            if type(v) == "number" then file_reader_gui_vals[#file_reader_gui_vals + 1] = v end
        end
    end
    resolve_chapter_gui_enums()   -- stellt render_default_val sicher
end
local function is_file_reader_gui_open()
    local gm = cached_singletons.guiManager
    if not gm then return false end
    resolve_file_reader_enums()
    for _, gv in ipairs(file_reader_gui_vals) do
        local open = safe(function() return gm:call("isOpenGui", gv, render_default_val) end)
        if open == true then return true end
    end
    return false
end

-- [IGNORE_HUD_OFF 2026-07-17] Parameter ignore_hud_off: laesst NUR die get_IsHudOff-Quelle weg, alle
-- anderen (Pause, PauseLock, Koffer, Typewriter, Map, Chapter-Result) zaehlen weiter.
-- WOFUER: "HUD aus" ist KEIN Menue -- das Spiel blendet es auch bei Events aus ("force look" vor dem
-- Ausweich-Prompt, live belegt: hudOff=true, paused/pauseLock/case alle false). Dadurch landete das
-- Binding im MENU-Branch und der Ausweich-Grip war tot. Mit is_any_menu_open(true) laesst sich fragen:
-- "ist ein ECHTES Menue offen?" -> nur dann darf ein Gameplay-Binding schweigen.
-- Ohne Parameter (= false/nil) verhaelt sich die Funktion EXAKT wie vorher -- alle bestehenden Aufrufer
-- (Branch-Split, X-Mute, __re4_frame_is_gameplay) sind unberuehrt. NICHT hudOff generell rausnehmen:
-- dann liefe bei jedem HUD-aus-Event das volle Gameplay-Binding.
local function is_any_menu_open(ignore_hud_off)
    cache_menu_singletons()
    if not (re4 and re4.player and re4.body) then
        return true
    end
    -- [PAUSE] Globaler Pause-Flag (share.PauseManager.isPaused): greift auch bei "Pause WAEHREND
    -- Cutscene", wo KEINE GUI-Flags gesetzt sind (IsHudOff/PauseLock/InGameMenu alle false, nur
    -- Cutscene-HUD/EventPauseSkip offen). Live verifiziert: pausiert=true, Gameplay/Cutscene-Playback=false.
    if cached_singletons.pauseManager then
        local ok, paused = pcall(function()
            return cached_singletons.pauseManager:call("isPaused()")
        end)
        if ok and paused == true then return true end
    end
    if not ignore_hud_off and cached_singletons.guiManager then
        local ok, hudOff = pcall(function()
            return cached_singletons.guiManager:call("get_IsHudOff")
        end)
        if ok and hudOff == true then return true end
    end
    if cached_singletons.guiManager then
        local ok, pauseLock = pcall(function()
            return cached_singletons.guiManager:call("get_hasOccupiedPauseMenuSystemLock")
        end)
        if ok and pauseLock == true then return true end
    end
    if cached_singletons.attacheCaseManager then
        local ok, inventoryOpen = pcall(function()
            return cached_singletons.attacheCaseManager:call("get_IsAttacheCaseBusy")
        end)
        if ok and inventoryOpen == true then return true end
    end
    -- [TYPEWRITER/ARMOURY] Schreibmaschine = Koffer (rechts) + Archivbox/Aufbewahrung (links). get_IsAttacheCaseBusy
    -- deckt NUR den Koffer ab -> die Archivbox fiel bisher durch und landete im KS-Branch (falsche Bindings, X/Move
    -- tot). get_IsTypewriterWindow (chainsaw.ArmouryManager) ist true, solange das GANZE Typewriter-Fenster offen
    -- ist -> deckt beide Seiten ab. Live live verifiziert: im Typewriter true, sonst false.
    if cached_singletons.armouryManager then
        local ok, tw = pcall(function()
            return cached_singletons.armouryManager:call("get_IsTypewriterWindow")
        end)
        if ok and tw == true then return true end
    end
    if cached_singletons.mapManager then
        local ok, mapOpen = pcall(function()
            -- [2026-08-09] Methodenname EXAKT klein anfangend, KEIN "get_" davor.
            -- "get_IsMapGuiOpen" existiert NICHT (live belegt 2026-08-07, s. re4_vr_ui.lua):
            -- der Call warf jeden Frame in den pcall, die Karte galt damit NIE als Menue --
            -- deshalb fehlte in ihr das Menue-Binding (L.Trigger + R-Stick -> DPAD).
            return cached_singletons.mapManager:call("isMapGuiOpen")
        end)
        if ok and mapOpen == true then return true end
    end
    -- [CHAPTER_RESULT] Post-Kapitel-/Ergebnis-Screen (ChapterEnd etc.) -> als Menue behandeln.
    if is_chapter_result_gui_open() then return true end
    -- [FILE_READER] Dokument-/Buch-Leser (Fund + Inventar) -> als Menue behandeln.
    if is_file_reader_gui_open() then return true end
    return false
end

-- [MAP_TRIGGERS 2026-08-15] Ist GERADE die Kartenansicht offen?
-- Eigene, kleine Abfrage statt eines Flags: nur die laufende Antwort des Spiels zaehlt, es gibt
-- nichts zu setzen und nichts zurueckzusetzen -- damit kann beim Ein- oder Austritt aus der Karte
-- auch kein Zustand in einem anderen Branch haengenbleiben.
-- Methodenname EXAKT klein anfangend, KEIN "get_" davor -- "get_IsMapGuiOpen" existiert nicht
-- (live belegt 2026-08-07, dieselbe Falle wie oben in is_any_menu_open).
-- Gilt fuer Leon UND Ada; in den Mercs gibt es keine Karte, dort ist die Abfrage immer false.
local function is_map_open_now()
    if not cached_singletons.mapManager then return false end
    local ok, open = pcall(function()
        return cached_singletons.mapManager:call("isMapGuiOpen")
    end)
    return ok and open == true
end

-- ============================================================
-- Binoculars Detection + Zoom State
-- ============================================================
local function is_binoculars_active()
    local cm = binding_cm()
    if not cm then return false end
    local ctx = binding_ctx()
    if not ctx then return false end
    local body = safe(function() return ctx:call("get_BodyGameObject") end)
    if not body then return false end
    local tf = safe(function() return body:call("get_Transform") end)
    if not tf then return false end
    local child = safe(function() return tf:call("get_Child") end)
    if not child then return false end
    local count = 0
    while child and count < 200 do
        count = count + 1
        local child_go = safe(function() return child:call("get_GameObject") end)
        if child_go then
            local ok_cn, child_name = pcall(function() return child_go:call("get_Name") end)
            if ok_cn and child_name and tostring(child_name) == "Binoculars" then
                return true
            end
        end
        child = safe(function() return child:call("get_Next") end)
    end
    return false
end

-- Both frame callbacks need the same scene walk.  The result is valid only
-- for this engine frame; without a frame counter the old direct path remains.
local function is_binoculars_active_this_frame()
    local ok, frame = pcall(re.get_frame_count)
    if not ok or type(frame) ~= "number" then return is_binoculars_active() end
    local c = rawget(_G, "__re4_bino_scan_cache")
    if type(c) == "table" and c.frame == frame then return c.active == true end
    local active = is_binoculars_active()
    if type(c) ~= "table" then
        c = {}
        _G.__re4_bino_scan_cache = c
    end
    c.frame, c.active = frame, active
    return active
end

-- [BINO 2026-07-22] Die vier Werte sind jetzt Slider im Tree "RE4VR - First Person"
-- (Unterpunkt "Fernglas (Zoom)"), persistiert in der firstperson-JSON und hier ueber
-- _G.__re4_bino_cfg gelesen. Die Zahlen unten bleiben als Fallback stehen, falls firstperson
-- noch nicht geladen hat -> Verhalten dann exakt wie vorher.
local bino_zoom = {
    active        = false,
    offset        = 0.0,
    start_offset  = 2.5,
    min_offset    = -7.0,
    max_offset    = 2.5,
    stick_speed   = 3.0,
}
local function bino_val(key, fallback)
    local c = rawget(_G, "__re4_bino_cfg")
    if type(c) == "table" and type(c[key]) == "number" then return c[key] end
    return fallback
end

-- Binoculars Zoom: Detection + Stick-Input + Camera offset every frame
-- [BF/SCHUSS/NEEDS-DIAG 2026-07-20 ENTFERNT 2026-07-21] Der komplette rack_diag-Beobachter (eigener
-- re.on_frame mit BF-/SHOT-/NEEDS-Zweig) ist raus -- er lief jeden Frame nur fuer das Log.
re.on_frame(function()
    local bino_found = is_binoculars_active_this_frame()

    if bino_found then
        if not bino_zoom.active then
            bino_zoom.active = true
            bino_zoom.offset = bino_val("start", bino_zoom.start_offset)
        end
        if vrmod and vrmod:is_hmd_active() and vrmod:is_using_controllers() then
            local stick_y = vrmod:get_left_stick_axis().y
            if math.abs(stick_y) > 0.1 then
                bino_zoom.offset = bino_zoom.offset - stick_y * bino_val("speed", bino_zoom.stick_speed) * 0.016
                bino_zoom.offset = clamp(bino_zoom.offset,
                    bino_val("min", bino_zoom.min_offset), bino_val("max", bino_zoom.max_offset))
            end
        end
    else
        if bino_zoom.active then
            bino_zoom.active = false
            bino_zoom.offset = 0.0
        end
    end

    if bino_zoom.offset == 0.0 then return end

    local camera = sdk.get_primary_camera()
    if not camera then return end
    local cam_go = safe(function() return camera:call("get_GameObject") end)
    if not cam_go then return end
    local cam_tf = safe(function() return cam_go:call("get_Transform") end)
    if not cam_tf then return end

    local cam_pos = safe(function() return cam_tf:get_position() end)
    local cam_rot = safe(function() return cam_tf:get_rotation() end)
    if not cam_pos or not cam_rot then return end

    local forward = cam_rot * Vector4f.new(0, 0, 1, 0)
    cam_tf:set_position(
        Vector4f.new(
            cam_pos.x + forward.x * bino_zoom.offset,
            cam_pos.y + forward.y * bino_zoom.offset,
            cam_pos.z + forward.z * bino_zoom.offset,
            cam_pos.w
        ), true
    )
end)

-- ============================================================
-- L.AButton Long Press
-- Leon: Short = Map (BACK), Long = CMD Ashley (RS)
-- Ada: Short = RB/Grapple, Long = Map (BACK)
-- ============================================================
local LONG_PRESS_FRAMES = 135  -- ~1.5s at 90fps

-- [COMBO_GRACE 2026-08-11] Beide Halte-Kombos (Trigger-Menue + A/A-Easteregg) galten als
-- losgelassen, sobald EIN EINZIGER Frame lang einer der beiden Knoepfe nicht als gedrueckt
-- gelesen wurde -- an der Trigger-Schwelle oder bei einem Tracking-Aussetzer passiert das
-- staendig. Die Uhr fing dann unbemerkt neu an, und die Kombo "ging einfach nicht".
-- Jetzt zaehlt erst als losgelassen, wer laenger als diese Karenz offen ist.
local COMBO_GRACE_SEC = 0.15

-- [DUAL_TRIGGER_MENU] Beide Trigger 2s halten → START (Hauptmenü), wie RE9. -- [2026-07-20] 3.0 -> 2.0
local DUAL_TRIGGER_HOLD_SEC = 2.0
local dual_trigger_start_clock = nil
local dual_trigger_fired = false
local dual_trigger_gap_clock = nil
-- [START_HOLD 2026-08-11] START wurde nur EINEN Frame lang gesendet -- verpasst das Spiel den,
-- passiert gar nichts. Gleicher Mechanismus wie beim L.AButton-Longpress weiter unten: die
-- Taste ueber mehrere Frames halten.
local START_HOLD_FRAMES = 20
local start_hold_timer = 0

-- [EASTER_EGG_FLAMETHROWER] Beide A-Buttons 5s im Gameplay halten → Flamethrower (wp4701)
-- in die Aufbewahrung (chainsaw.ArmouryManager) + Belohnungs-Sound. Einmal pro Hold.
local EE_FLAME_HOLD_SEC = 5.0
local EE_FLAME_SOUND    = 764414311   -- GuiSoundType-Enum ( gewaehlt)
local EE_FLAME_ITEM_ID  = 275957056   -- Flamethrower-Item
local ee_flame_clock = nil
local ee_flame_fired = false
local ee_flame_gap_clock = nil
local la_hold = {
    pressed = false,
    frames = 0,
    fired_long = false,
    short_timer = 0,
    short_is_ada = false,
}

-- [CHAR_STICKY 2026-07-19] "Ada ist fuer Ada, Leon fuer Leon -- immer."
-- Diese Funktion hatte eine EIGENE Body-Pruefung ohne Absicherung: setzt die Erkennung fuer einen
-- Frame aus (Body kurz weg bei Waffenwechsel/Holster/Laden), lieferte sie false = "Leon". Damit
-- konnte Ada fuer einzelne Frames in Leons Gameplay-Zweig und Leons Tastenbelegung rutschen --
-- beim L.A-Longpress genau der Moment, in dem der Grapple nicht kommt.
-- Jetzt ueber das zentrale __re4_char_now (motion.lua / weapons2.lua): das haelt den letzten
-- BEKANNTEN Charakter fest und ueberbrueckt genau diese Aussetzer.
-- LEON-NEUTRAL: liefert char_now "leon", ist das Ergebnis false -- exakt wie vorher.
-- Fallback auf die alte Direktpruefung, falls char_now (noch) nicht geladen ist.
-- [MERC_GAMEPLAY_BRANCH 2026-08-03] Laeuft gerade Mercenaries? Publiziert von
-- re4_vr_merc.lua (chainsaw.MercenariesManager.get_GuiManager lebt nur im Mercs).
-- Bewusst NUR das Global lesen: keine eigenen Singleton-Lookups pro Frame, und ohne
-- geladenes Mercs-Script ist das Ergebnis false -- Leon/Ada bleiben exakt wie bisher.
local function is_mercs_active()
    return rawget(_G, "__re4_in_mercs") == true
end

local function is_ada_active()
    local fn = rawget(_G, "__re4_char_now")
    if type(fn) == "function" then
        local ok, ch = pcall(fn)
        if ok and ch ~= nil then return ch == "ada" end
    end
    local cm = binding_cm()
    if not cm then return false end
    local ctx = binding_ctx()
    if not ctx then return false end
    local body = safe(function() return ctx:call("get_BodyGameObject") end)
    if not body then return false end
    local bname = safe(function() return body:call("get_Name") end)
    if not bname then return false end
    return tostring(bname) == "ch3a8z0_body"
end

-- [ADA_PITCH_GUI 2026-07-22] Solange bei ADA das Gui-Element Gui_ui2022 gezeichnet wird,
-- ist der Pitch (rechter Stick-Y) frei -- sonst greift weiter der RY-Lock unten (Pitch vom HMD).
-- Trigger ist ALLEIN diese GUI ("wenn ich das Gui sehe, Pitch aufheben, fertig"); Stage/Position
-- brauchen wir nicht, die GUI erscheint ja nur dort.
-- NUR ADA: bei Leon bleibt alles wie bisher (geteilte Datei -- Gate nicht entfernen).
-- Die Zeitschwelle faengt Frames ab, in denen das Element mal nicht gezeichnet wird.
-- [DODGE_GIMMICK 2026-07-22] Das fette, bildschirmfuellende "Ausweichen!"-Overlay laesst sich
-- NICHT ueber GUI-Namen fassen: im Event-Moment werden nur laengst bekannte Elemente gezeichnet, und
-- selbst wenn man ALLE ausblendet, erscheint das Prompt weiter (Toggle-Probe, 2026-07-22).
-- Per Sweep-Probe (alle 130 Boolean-Getter des PlayerContext) wurde stattdessen der ZUSTAND gemessen:
-- 17:15:58 IsInvincible/isLocked false->true, Occupied 23, PlayerCameraState 15 (Grappled)
-- 17:15:58 Busy-Cam -> GimmickMotionCameraController (camType 4)
-- 17:16:02 Busy-Cam -> GimmickOperateCameraController (camType 5) <-- DAS Druck-Fenster (~5 s)
-- 17:16:07 Occupied 38 / EventCamera -> Cutscene, danach Gameplay
-- Getriggert wird deshalb auf die GRUPPE: Stage 60871 + Occupied 23 + BusyCameraType 5.
-- Ausweichen liegt normal auf dem rechten Stick-Klick -- in dem Moment kaum zu treffen, und freie
-- Knoepfe gibt es keine mehr. Darum hier: linker Grip feuert in diesem Fenster ein B.
-- Der Aufruf steht bewusst HINTER der l_grip-Abfrage (siehe Aufrufstellen) -> die Singleton-Lookups
-- laufen nur, wenn der Grip wirklich gedrueckt ist, nicht jeden Frame.
-- [DODGE_GMK_STAGE2 2026-07-22] Zweites Ausweich-Fenster im Monitordump gefunden: Stage 60874
-- (Space 60880, 19:31:23/19:32:29) -- gleiche Gruppe, GimmickOperate + Occupied 23. Darum Set statt Zahl.
local DODGE_GMK_STAGES  = { [60871] = true, [60874] = true }
local DODGE_GMK_PRIO    = 23      -- CH_JACKED_GMK_HIGH
local DODGE_GMK_CAMTYPE = 5       -- CameraDefine.CameraControlType.GimmickOperate

local function enum_num(v)
    if type(v) == "number" then return v end
    if type(v) == "userdata" then return safe(function() return v:get_field("value__") end) end
    return nil
end

local function is_dodge_gimmick_now()
    local cm = binding_cm()
    local pctx = binding_ctx()
    if not pctx then return false end
    if not DODGE_GMK_STAGES[enum_num(safe(function() return pctx:call("get_CurrentStageID") end)) or -1] then return false end
    local occ = safe(function() return pctx:call("get_OccupiedInfo") end)
    if enum_num(occ and safe(function() return occ:call("get_Priority") end)) ~= DODGE_GMK_PRIO then return false end
    local csys = sdk.get_managed_singleton("chainsaw.CameraSystem")
    local main = csys and safe(function() return csys:call("get_MainCameraController") end)
    return enum_num(main and safe(function() return main:call("get_BusyCameraType") end)) == DODGE_GMK_CAMTYPE
end

-- [RECT_PROMPT 2026-07-22] Zweite Quicktime-Aufforderung in Stage 60874. Sie benutzt DASSELBE
-- GUI-Element wie das Ausweichen (Gui_ui2191_3) und dieselbe Zustands-Gruppe (Stage/Occupied 23,
-- camType wechselt bei BEIDEN zwischen 4 und 5) -- unterscheidbar ist sie nur INNEN, live gemessen
-- per re4_zzz_guiprobe (20:09:28/34/42 alt gegen 20:09:45 neu):
-- Ausweichen: c_btn_circle_anime vis=true (m_btn "<ICON AVOID-F>"), c_btn_rect_anime vis=false
-- NEU: c_btn_rect_anime vis=true (m_btn "<ICON CP11_HS-F>"), c_btn_circle_anime false
-- Deshalb: beim Zeichnen den Control-Baum nach "c_btn_rect_anime" absuchen und dessen Sichtbarkeit
-- als Frische-Stempel merken (0.15 s, gleiches Muster wie __re4_is_dodge_prompt). Der Baum-Lauf
-- passiert nur, wenn dieses eine Element gezeichnet wird -- also nur waehrend des Prompts.
-- Umgebunden wird der linke Grip hier auf RB (das Ausweichen bleibt unveraendert auf B).
local rect_prompt_last = -999
-- [LEON_LB_PROMPT 2026-07-23] Frische-Stempel fuer Leons Gegenstueck (siehe is_leon_lb_prompt_now).
local leon_lb_last = -999
-- [DODGE_CIRCLE 2026-07-31] Eigener Stempel fuer das AUSWEICHEN. Grund: crosshair.lua stempelt
-- __re4_dodge_prompt_seen auf den GANZEN Container "Gui_ui2191_3" -- und den teilen sich laut den
-- Messungen oben Adas Rect-Prompt (c_btn_rect_anime) und Leons LB-Prompt (c_btn_rect). Dadurch wurde der
-- linke Grip auch bei DIESEN Prompts zu B = Crouch, obwohl gar kein Ausweichen anstand (Playtester:
-- "crouche in hektischen Situationen aus dem Nichts"). Das Ausweichen selbst zeigt c_btn_circle_anime
-- (live gemessen 2026-07-22) -> hier positiv belegen statt den Container zu raten.
local dodge_circle_last = -999
local function find_ctl(c, want, depth, budget)
    while c and budget.n < 80 do
        budget.n = budget.n + 1
        local nm = safe(function() return c:call("get_Name") end)
        if nm and tostring(nm) == want then return c end
        if depth < 5 then
            local ch = safe(function() return c:call("get_Child") end)
            if ch then local hit = find_ctl(ch, want, depth + 1, budget); if hit then return hit end end
        end
        c = safe(function() return c:call("get_Next") end)
    end
    return nil
end

local ADA_PITCH_GUI = "Gui_ui2022"
local ada_pitch_gui_last = -999
re.on_pre_gui_draw_element(function(element, context)
    local go = element:call("get_GameObject")
    local n = go and go:call("get_Name")
    if n and tostring(n) == ADA_PITCH_GUI then ada_pitch_gui_last = os.clock() end
    -- [RECT_PROMPT] nur dieses eine Element -> der Baum-Lauf laeuft nicht im Normalbetrieb.
    if n and tostring(n) == "Gui_ui2191_3" then
        local view = safe(function() return element:call("get_View") end)
        local ch = view and safe(function() return view:call("get_Child") end)
        local hit = ch and find_ctl(ch, "c_btn_rect_anime", 0, { n = 0 })
        if hit and safe(function() return hit:call("get_Visible") end) == true then
            rect_prompt_last = os.clock()
        end
        -- [LEON_LB_PROMPT 2026-07-23] Leon nutzt im selben Gui_ui2191_3 das Control "c_btn_rect"
        -- (OHNE _anime; per re4_zzz_rectprompt.log bestaetigt, Stage 44101). Exakter Name -> trennt es
        -- sauber von Adas "c_btn_rect_anime".
        local lhit = ch and find_ctl(ch, "c_btn_rect", 0, { n = 0 })
        if lhit and safe(function() return lhit:call("get_Visible") end) == true then
            leon_lb_last = os.clock()
        end
        -- [DODGE_CIRCLE 2026-07-31] Das Ausweichen selbst: c_btn_circle_anime sichtbar
        -- (Gegenstueck zu den beiden Rect-Controls oben, gleicher Baum, gleicher Frame).
        local dhit = ch and find_ctl(ch, "c_btn_circle_anime", 0, { n = 0 })
        if dhit and safe(function() return dhit:call("get_Visible") end) == true then
            dodge_circle_last = os.clock()
        end
    end
    return true
end)
-- [RECT_PROMPT] frisch gezeichnet (0.15 s) UND in der Stage, in der die Aufforderung vorkommt.
local function is_rect_prompt_now()
    if (os.clock() - rect_prompt_last) >= 0.15 then return false end
    local cm = binding_cm()
    local pctx = binding_ctx()
    if not pctx then return false end
    return enum_num(safe(function() return pctx:call("get_CurrentStageID") end)) == 60874
end
-- [LEON_LB_PROMPT 2026-07-23] Leons Gegenstueck: dieselbe Gui_ui2191_3, aber das sichtbare
-- Control ist "c_btn_rect" und der geforderte Knopf LB statt RB. Es ist eine GEGNER-ATTACKE (Ausweichen)
-- -> kann in JEDER Stage kommen, deshalb KEIN Stage-Gate. Stattdessen hart auf Leon (not is_ada_active)
-- begrenzt, damit es Adas stage-gegateten RB-Prompt nie kapert.
local function is_leon_lb_prompt_now()
    if (os.clock() - leon_lb_last) >= 0.15 then return false end
    return not is_ada_active()
end
-- [DODGE_CIRCLE 2026-07-31] "Ist JETZT das Ausweichen dran?" -- zwei Wege, damit nichts kaputtgeht:
-- 1. POSITIV: c_btn_circle_anime frisch gezeichnet (Xbox-Symbolsatz, s. Stempel im GUI-Hook).
-- 2. FALLBACK: der alte Container-Stempel aus crosshair.lua (deckt den PS-Symbolsatz Gui_ui2150 ab,
-- fuer den es keine Control-Messung gibt) -- aber NUR, wenn nicht gleichzeitig der Rect- oder der
-- LB-Prompt lebt. Genau diese beiden teilen sich den Container und haben bisher das falsche B erzeugt.
-- crosshair.lua bleibt unangetastet.
local function is_dodge_prompt_now()
    if (os.clock() - dodge_circle_last) < 0.15 then return true end
    local fn = rawget(_G, "__re4_is_dodge_prompt")
    if type(fn) ~= "function" or fn() ~= true then return false end
    return not is_rect_prompt_now() and not is_leon_lb_prompt_now()
end

-- [PROMPT_GRIP 2026-07-31] Prompt-gebundene Grip-Bindings zentral, mit FLANKE + EINMAL-IMPULS
-- statt "solange der Grip gehalten wird". Warum:
-- * Level-Trigger schickte den Knopf jeden Frame des Fensters raus -- ein B, das nach dem Ausweichen
-- noch anliegt, ist im Normalzustand CROUCH.
-- * Zwei getrennte Bloecke (Dodge-Prompt vor der if/elseif-Kette) konnten gleichzeitig feuern:
-- bei Leons LB-Prompt gingen B UND LB raus.
-- Jetzt: EINE Prioritaetskette (Rect > LB > Ausweichen > Gimmick-Fenster), pro Prompt-Fenster genau ein
-- Impuls (4 Frames, zusaetzlich Zeit-Deadline wie beim Ada-A-Impuls -- Frames allein frieren ein, wenn
-- der Zweig zwischendurch nicht laeuft). Wieder scharf wird es beim Loslassen des Grips (= Mashing
-- funktioniert weiter) oder wenn das Fenster 0.2 s zu ist.
-- WICHTIG fuer die Funktion: gezuendet wird NICHT auf der Grip-Flanke, sondern sobald Fenster UND Grip
-- zusammen anliegen -- wer den Grip schon vor dem Prompt haelt (in der Hektik der Normalfall), weicht
-- trotzdem aus.
local pgrip = { fired = false, btn = nil, frames = 0, until_t = 0, win_t = -999 }
local function apply_prompt_grip(f, grip_down)
    local now = os.clock()
    if grip_down then
        -- Reihenfolge = Prioritaet; is_dodge_gimmick_now macht Engine-Lookups und laeuft deshalb
        -- weiterhin nur bei gedruecktem Grip (Kurzschluss wie vorher).
        local btn = nil
        -- [AUSWEICHEN GEHT VOR 2026-08-02, "jetzt geht nicht mal mehr ausweichen"]
        -- Alle drei Prompts teilen sich den Container Gui_ui2191_3. Bis eben stand die Kette
        -- Rect > LB > Ausweichen -- war beim Ausweichen gleichzeitig "c_btn_rect" gezeichnet, griff
        -- der LB-Zweig zuerst und schickte LB statt B. Das Ausweichen fiel damit komplett aus,
        -- obwohl es korrekt erkannt wurde.
        -- "c_btn_circle_anime sichtbar" ist der POSITIVE Beleg fuer das Ausweichen (live gemessen
        -- 2026-07-22) -- daran gibt es nichts zu priorisieren, das ist eindeutig. Deshalb steht es
        -- jetzt ganz vorn. Der Crouch-Fix vom 31.07. bleibt unangetastet: Das falsche B entstand aus
        -- dem CONTAINER-Stempel (Fallback in is_dodge_prompt_now), nicht aus diesem Control --
        -- und der Fallback steht weiterhin hinter Rect und LB.
        -- Reihenfolge nach dem Fix vom 2026-08-02:
        -- 1. Adas Rect-Prompt (RB) -- stage-gegatet auf 60874, bleibt UNANGETASTET vorn. Der
        -- Ausweich-Beleg steht bewusst NICHT davor: waere bei Ada gleichzeitig
        -- c_btn_circle_anime sichtbar (nie gemessen), wuerde B ihren RB-Prompt kapern.
        -- 2. Ausweichen (B) ueber den POSITIVEN Beleg c_btn_circle_anime. Muss VOR den LB-Zweig,
        -- denn genau dort lag der Fehler: beim Ausweichen war gleichzeitig "c_btn_rect"
        -- gezeichnet, der LB-Zweig griff zuerst und schickte LB -- das Ausweichen fiel komplett
        -- aus, obwohl es korrekt erkannt wurde.
        -- 3. Leons LB-Prompt, danach der Container-Fallback (der das falsche Crouch erzeugt hatte
        -- und deshalb weiterhin hinter Rect UND LB steht -> Crouch-Fix vom 31.07. bleibt heil).
        if is_rect_prompt_now() then btn = "RB"
        elseif (os.clock() - dodge_circle_last) < 0.15 then btn = "B"
        elseif is_leon_lb_prompt_now() then btn = "LB"
        elseif is_dodge_prompt_now() then btn = "B"
        elseif is_dodge_gimmick_now() then btn = "B" end
        if btn then
            pgrip.win_t = now
            if not pgrip.fired then
                pgrip.fired   = true
                pgrip.btn     = btn
                pgrip.frames  = 4
                pgrip.until_t = now + 0.12
            end
        elseif (now - pgrip.win_t) > 0.20 then
            pgrip.fired = false          -- Fenster zu -> fuer das naechste wieder scharf
        end
    else
        pgrip.fired = false              -- Grip losgelassen -> wieder scharf
    end
    if (pgrip.frames or 0) > 0 and now > (pgrip.until_t or 0) then pgrip.frames = 0 end
    if (pgrip.frames or 0) > 0 and pgrip.btn then
        f[pgrip.btn] = true
        pgrip.frames = pgrip.frames - 1
    end
end

-- [PROMPT_RT 2026-07-31] Dasselbe Muster fuer den Finisher-RT (Gui_ui2200): bisher wurde RT jeden
-- Frame des Frische-Fensters durchgereicht, solange der Trigger lag -- ein RT, der nach dem Finisher noch
-- anliegt, ist im Normalzustand wieder Messer-Flip/Angriff. Jetzt ein Einmal-Impuls pro Fenster
-- (6 Frames / 0.15 s -- etwas laenger als beim Grip, der Finisher darf auf keinen Fall verschluckt werden).
-- Wieder scharf beim Loslassen des Triggers (Mashing bleibt moeglich) oder wenn das Fenster 0.2 s zu ist.
-- Der FLIPPED-Zweig (Stich-Geste) bleibt unangetastet -- der Shake ist von sich aus ein kurzer Impuls.
local rtp = { fired = false, frames = 0, until_t = 0, win_t = -999 }
local function apply_finisher_rt(f, window_on, trigger_down)
    local now = os.clock()
    if window_on and trigger_down then
        rtp.win_t = now
        if not rtp.fired then
            rtp.fired   = true
            rtp.frames  = 6
            rtp.until_t = now + 0.15
        end
    elseif (not trigger_down) or (now - rtp.win_t) > 0.20 then
        rtp.fired = false            -- Trigger los ODER Fenster zu -> fuers naechste Prompt wieder scharf
    end
    if (rtp.frames or 0) > 0 and now > (rtp.until_t or 0) then rtp.frames = 0 end
    if (rtp.frames or 0) > 0 then
        f.RT = 1.0
        rtp.frames = rtp.frames - 1
    end
end
local function ada_pitch_free()
    if (os.clock() - ada_pitch_gui_last) >= 0.25 then return false end
    return is_ada_active()
end

-- GUI/System-Sound abspielen (chainsaw.GuiSoundManager, immer geladen — RE4-Pendant
-- zu RE9 "Resident"). enum = chainsaw.gui.GuiSoundType-Wert.
local function play_gui_sound(enum)
    if not enum or enum == 0 then return end
    local gsm = sdk.get_managed_singleton("chainsaw.GuiSoundManager")
    if gsm then
        pcall(function() gsm:call("wwiseTriggerTarget(chainsaw.gui.GuiSoundType)", enum) end)
    end
end

-- [BODY_SOUND 2026-08-04] Wwise-TriggerId auf dem SoundContainer des aktuellen PLAYER-BODY
-- spielen -- derselbe Container, auf dem auch die Gesten-Sprueche liegen (Leon ch0a0z0_body,
-- Ada ch3a8z0_body, Mercs-Chars ihre eigenen). Kein Charakter-Gate noetig: die verwendete ID sitzt
-- belegt auf jedem dieser Container unter derselben Nummer.
-- KEIN Komponenten-Cache (ueberlebt sonst keinen Savegame-Load) -- laeuft nur bei Tastendruck.
local _body_snd_t = sdk.typeof("soundlib.SoundContainer")
local function play_body_sound(id)
    if not (id and id > 0 and _body_snd_t) then return end
    local cm = binding_cm(); if not cm then return end
    local ctx = binding_ctx(); if not ctx then return end
    local go = safe(function() return ctx:call("get_BodyGameObject") end); if not go then return end
    local con = safe(function() return go:call("getComponent(System.Type)", _body_snd_t) end)
    if not con then return end
    pcall(function() con:call("trigger(System.UInt32)", id) end)
end

-- [EASTER_EGG_FLAMETHROWER] Flamethrower in die Aufbewahrung legen + Belohnungs-Sound.
-- [FIX 2026-07-17] Pro SPIELSTAND statt globalem Flag: der alte PREFS.flamethrower_granted lag in der Config
-- (ueberlebt "Neues Spiel") -> blockierte den Grant auch dort, wo der FT gar nicht im Archiv liegt (genau der
-- Fall: Flag true, aber kein FT im Typewriter). Jetzt haengt alles an existsItem gegen die AKTUELLE Aufbewahrung:
-- FT fehlt -> spawnen + Sound; FT schon da -> nichts (kein Doppel, kein Spam-Sound). Kein Config-Flag mehr noetig.
local function grant_flamethrower_to_armoury()
    local am = sdk.get_managed_singleton("chainsaw.ArmouryManager")
    if not am then return end           -- ohne Aufbewahrung kein Erfolg -> spaeter erneut moeglich
    local has = false
    pcall(function() has = am:call("existsItem", EE_FLAME_ITEM_ID) end)
    if has then return end              -- schon in dieser Aufbewahrung -> nichts tun
    local added = false
    local gu  = sdk.find_type_definition("chainsaw.ChainsawGuiUtil")
    local gen = gu and gu:get_method("generateItem")
    if gen then
        local item = nil
        -- generateItem(itemId, itemCount, durability, ammoId, ammoCount, changeId)
        pcall(function() item = gen:call(nil, EE_FLAME_ITEM_ID, 1, -1, -1, 100, false) end)
        if item then added = pcall(function() am:call("addArmouryItem(chainsaw.Item)", item) end) end
    end
    if added then
        play_gui_sound(EE_FLAME_SOUND)  -- Belohnungs-Sound nur bei echtem Neuzugang
    end
end

-- ============================================================
-- Edge Detection with Hold-Timer
-- ============================================================
local EDGE_HOLD_FRAMES = 4

local edge_state = {
    r_a   = { prev = false, timer = 0 },
    r_b   = { prev = false, timer = 0 },
    r_jc  = { prev = false, timer = 0 },
    l_a_b = { prev = false, timer = 0 },
}

local function edge_detect(state_entry, current_pressed)
    if current_pressed then
        if not state_entry.prev then
            state_entry.prev = true
            state_entry.timer = EDGE_HOLD_FRAMES
        end
        if state_entry.timer > 0 then
            state_entry.timer = state_entry.timer - 1
            return true
        end
        return false
    else
        state_entry.prev = false
        state_entry.timer = 0
        return false
    end
end

-- ============================================================
-- ViGEm Init (RE9-Pattern)
-- ============================================================
local inited = false
local vr = nil
local left_joystick = nil
local right_joystick = nil
local ACT = {}

local function safe_digital(action_handle, hand)
    if not action_handle or not hand then return false end
    local ok, v = pcall(vr.is_action_active, vr, action_handle, hand)
    if not ok then return false end
    return v and true or false
end

local function ensure_init()
    if inited then return true end
    if not vrmod then return false end
    vr = vrmod

    local ok_c, controllers = pcall(vr.get_controllers, vr)
    if not ok_c or not controllers or #controllers < 2 then return false end

    local ok_l, lh = pcall(vr.get_left_joystick, vr)
    local ok_r, rh = pcall(vr.get_right_joystick, vr)
    left_joystick  = ok_l and lh or nil
    right_joystick = ok_r and rh or nil
    if left_joystick == nil or right_joystick == nil then return false end

    ACT.trigger     = vr:get_action_trigger()
    ACT.grip        = vr:get_action_grip()
    ACT.a_button    = vr:get_action_a_button()
    ACT.b_button    = vr:get_action_b_button()
    ACT.joy_click   = vr:get_action_joystick_click()
    ACT.weapon_dial = vr:get_action_weapon_dial()
    ACT.dpad_up     = vr:get_action_dpad_up()
    ACT.dpad_down   = vr:get_action_dpad_down()
    ACT.dpad_left   = vr:get_action_dpad_left()
    ACT.dpad_right  = vr:get_action_dpad_right()

    local ok3 = false
    pcall(function() ok3 = vigem.init() end)
    if not ok3 then return false end

    inited = true
    return true
end

-- ============================================================
-- Per-Frame State Container
-- ============================================================
-- [QUICKTURN_180 2026-08-02] 180-Grad-Kehrtwende per DOPPEL-TIPP linker Stick nach UNTEN.
-- 1:1 portiert aus RE9 (re9_vr_bindings.lua, dt_*-Block): gleiche Schwellen, gleiches Doppel-Tipp-
-- Fenster (0.17 s) und dieselbe Frame-Zaehlung, damit sich das Timing identisch anfuehlt.
-- EINZIGER Unterschied: in RE9 lautete die native Kombi "Stick runter + B", in RE4 ist es
-- "Stick runter + RB" -> die Sequenz feuert hier RB statt B. Zustandsmaschine unveraendert.
--
-- Ablauf: Stick runter (<= -0.7) -> loslassen (>= -0.3) -> innerhalb 0.17 s WIEDER runter
-- => 10 Frames Sequenz: LY hart auf -1.0, ab Frame 5 zusaetzlich RB.
-- danach Cooldown bis der Stick wirklich losgelassen wurde + 60 Frames Nachlauf.
-- Wir setzen nur ZUSAETZLICH (f.RB = true), es wird NICHTS weggegatet -- Adas RB-Longpress und
-- alle anderen RB-Setter bleiben unberuehrt.
-- DEFAULT AUS (PREFS.enable_180_rotation, Toggle im Tree "RE4VR - Binding").
-- Alles in EINER Tabelle (inkl. Funktionen) wegen des 200-Local-Limits pro Datei.
-- ============================================================
-- [2026-08-10 ZEITBASIERT] Die Sequenz lief frueher ueber FRAMES (4 + 6 = 10). Gemessen
-- wurde: die Erkennung feuert sauber (8 von 8 Doppel-Tipps, seq 1..10, Gate offen), das
-- Spiel macht daraus aber nichts. Bei 60 fps waren die 6 RB-Frames 100 ms -- in VR laeuft
-- das Spiel mit 90-120 fps, damit blieben nur 50-66 ms uebrig, zu wenig zum Erkennen der
-- gehaltenen Kombi. Deshalb jetzt in SEKUNDEN, unabhaengig von der Bildrate, und ueber
-- zwei Slider im Tree einstellbar.
local qt = {
    DOWN = -0.7, RELEASE = -0.3, WINDOW = 0.17,
    LY_SEC = 0.10,    -- Stick allein nach hinten, bevor RB dazukommt
    RB_SEC = 0.35,    -- danach BEIDE zusammen gehalten
    POST_FRAMES = 60,
    phase = 0, window_time = 0.0, seq = 0, cooldown = false, post = 0,
    t0 = 0.0,         -- Startzeit der laufenden Sequenz
}
-- Snapturn-Scharfschaltung als Feld, nicht als neues local (200-Local-Limit pro Datei).
qt.st_armed = true
qt.reset = function()
    qt.phase = 0; qt.window_time = 0.0; qt.seq = 0; qt.cooldown = false; qt.post = 0
end
qt.update = function(ly, dt)
    if qt.seq > 0 then
        qt.seq = qt.seq + 1
        local ly_s = tonumber(PREFS.turn180_ly_sec) or qt.LY_SEC
        local rb_s = tonumber(PREFS.turn180_rb_sec) or qt.RB_SEC
        if (os.clock() - qt.t0) > (ly_s + rb_s) then
            qt.seq = 0; qt.cooldown = true; qt.phase = 0; qt.post = qt.POST_FRAMES
        end
        return
    end
    if qt.post > 0 then qt.post = qt.post - 1 end
    if qt.cooldown then
        -- erst wieder scharf, wenn der Stick tatsaechlich losgelassen wurde
        if ly > qt.RELEASE then qt.cooldown = false end
        return
    end
    if qt.phase == 0 then
        if ly <= qt.DOWN then qt.phase = 1 end
    elseif qt.phase == 1 then
        if ly >= qt.RELEASE then qt.phase = 2; qt.window_time = 0.0 end
    elseif qt.phase == 2 then
        qt.window_time = qt.window_time + dt
        -- [QT_WINDOW_SLIDER] Fenster live aus den PREFS (Slider im Binding-Tree), Fallback = RE9-Wert.
        if ly <= qt.DOWN then
            qt.seq = 1; qt.phase = 0; qt.t0 = os.clock()   -- zweiter Tipp im Fenster -> Sequenz laeuft
        elseif qt.window_time > (tonumber(PREFS.turn180_window_sec) or qt.WINDOW) then
            qt.phase = 0                    -- Fenster verstrichen -> war ein normaler Rueckwaertsgang
        end
    end
end

local function new_frame_state(lx, ly, rx, ry)
    return {
        A = false, B = false, X = false, Y = false,
        LB = false, RB = false,
        LS = false, RS = false,
        BACK = false, START = false,
        DPAD_UP = false, DPAD_DOWN = false, DPAD_LEFT = false, DPAD_RIGHT = false,
        LT = 0.0, RT = 0.0,
        LX = lx, LY = ly, RX = rx, RY = ry,
    }
end

local function apply_frame(f)
    -- [RED9_RELOAD_AIM] Waehrend der nativen Red9-Reload-Anim Aim (LT) forcen -> die linke-Hand-Reload-
    -- Anim ist an den Aim-/Hold-Zustand gekoppelt; ohne Aim bewegt sich die linke Hand nicht. motion
    -- published das Flag nur fuer wp4002 + Reload-Node, also keine Wirkung auf andere Waffen/Zustaende.
    -- [GATE] nur im Gameplay -> im Menu/Boot/KS nie LT forcen (Red9-Reload-Anim laeuft dort eh nicht).
    if rawget(_G, "__vr_red9_reloading") == true and rawget(_G, "__re4_frame_is_gameplay") == true then f.LT = 1.0 end
    -- [AIM_INPUT] Export fuer motion.lua Aim-Transition: der INPUT fuehrt
    -- dem Engine-Kamera-Sprung voraus (is_aim/IsShootEnable flippt erst
    -- NACH dem Sprung -> zu spaet als Flanken-Trigger).
    -- [BOLT_REAIM 2026-08-09 -- am selben Tag umgebaut] Bolt Rifle: nach dem Schuss
    -- wird der GEHALTENE Griff/Aim echt abgebrochen und bleibt abgebrochen. Es wird
    -- ausdruecklich KEIN neues Zielen erzwungen (das war die alte Zeitfenster-Variante):
    -- wer weiterzoomen will, muss den Grip/Trigger loslassen und neu druecken -- das Spiel
    -- sieht dann eine echte Flanke statt eines Dauerdrucks.
    -- BEWUSST ENG GEHALTEN, das ist der Eingabepfad:
    -- * `__re4_bolt_aim_cut_t` setzt AUSSCHLIESSLICH weapons.lua, und nur bei einem
    -- Repetierer + echter Shoot-Node + gehaltenem Aim. Ohne Bolt-Schuss existiert die Globale nicht.
    -- * die Sperre gilt nur, solange die equippte Waffe ein Repetierer ist UND Gameplay laeuft --
    -- faellt eines davon weg, faellt der Stempel weg (kein haengendes Aim-Verbot).
    -- [ADA 2026-08-15] 6114 (Hunting Rifle, Separate Ways) ist derselbe Repetierer wie 4400 --
    -- vorher stand hier ein harter 4400-Vergleich, bei Ada wurde der Stempel also sofort
    -- geloescht statt den Griff abzubrechen.
    -- * losgelassen heisst: f.LT ist in diesem Frame ohnehin < 0.5 -> Stempel weg, der
    -- naechste Druck zoomt wieder voellig normal.
    -- Steht NACH allen f.LT-Settern (die forcen alle 1.0, keiner nullt) und VOR dem Export
    -- an vigem, damit hier nichts dazwischenkommt.
    do
        if rawget(_G, "__re4_bolt_aim_cut_t") ~= nil then
            local held = (tonumber(f.LT) or 0) >= 0.5
            local _bw  = rawget(_G, "__re4_scope_wid")
            if not held
               or (_bw ~= 4400 and _bw ~= 6114)
               or rawget(_G, "__re4_frame_is_gameplay") ~= true then
                _G.__re4_bolt_aim_cut_t = nil
            else
                f.LT = 0.0
            end
        end
    end

    _G.__vr_aim_input = (f.LT or 0) >= 0.5
    -- [KART-KIPPAUSGLEICH PER HMD 2026-08-02] minecart.lua setzt dieses Global AUSSCHLIESSLICH, wenn
    -- alle drei Bedingungen zutreffen: echte Kart-Fahrt, lebendes GmRailCar, laufende Kippphase
    -- (|Tilt| ueber Schwelle und ReturnTilt==false). Sonst ist es nil und hier passiert gar nichts --
    -- der LINKE Stick bleibt in jedem anderen Zustand voellig unberuehrt (er ist sonst die Bewegung!).
    -- Ist es gesetzt, gewinnt es gegen den Stick, damit Kopf und Daumen sich nicht gegenseitig aufheben.
    do
        local lean = tonumber(rawget(_G, "__re4_cart_lean_lx"))
        if lean and lean ~= 0.0 then f.LX = lean end
    end
    -- [QUICKTURN_180 2026-08-02] Doppel-Tipp linker Stick runter -> Kehrtwende (s. qt-Block oben).
    -- Steht bewusst HIER (eine Stelle fuer ALLE Branches): Leon und Ada teilen sich apply_frame, damit
    -- muss der Port nicht in beide Gameplay-Zweige dupliziert werden. Gate = reines Gameplay
    -- (kein Menu/Boot/Throwsight/Binoculars/Killswitch/Turret/Jetski) -- im Menue waere der Doppel-Tipp
    -- eine normale Cursor-Bewegung. Ausserhalb dieses Zustands wird die Zustandsmaschine zurueckgesetzt,
    -- sonst haengt eine halb gelaufene Phase ueber den Branch-Wechsel hinweg.
    -- ============================================================
    -- [SNAPTURN 2026-08-10] Rechter Stick dreht in Stufen statt stufenlos
    -- ============================================================
    -- WARUM AM ENGINE-YAW UND NICHT AN DER VR-ORIGIN: re4_vr_movement.lua setzt
    -- `vrmod:set_rotation_offset(yaw_to_quat(-hmd))` JEDEN Frame, um das Headset im Bild
    -- auszugleichen. Ein Snap ueber die Origin waere im naechsten Frame ueberschrieben --
    -- zwei Regler auf derselben Groesse, die bekannte Falle.
    --
    -- Movement dreht die Welt ueber `_Yaw` am PlayerCameraController und arbeitet dort
    -- rein ADDITIV (es liest _Yaw, legt das HMD-Delta drauf, schreibt zurueck). Genau
    -- deshalb ist dieselbe Stelle fuer uns unbedenklich: unser einmaliger Sprung wird von
    -- movement im naechsten Frame als neuer Ausgangswert uebernommen, nicht bekaempft.
    -- Am Movement-Script selbst wird NICHTS geaendert.
    --
    -- Gate ist reines Gameplay -- gilt damit fuer Leon, Ada und Mercenaries gleichermassen.
    -- Haken AUS = keine einzige Zeile wirksam, der Stick geht durch wie bisher.
    do
        if PREFS.enable_snapturn and rawget(_G, "__re4_frame_pure_gameplay") == true then
            local rx  = tonumber(f.RX) or 0.0
            local thr = tonumber(PREFS.snapturn_thresh) or 0.75

            -- Erst wieder scharf, wenn der Stick zurueck Richtung Mitte war (halbe
            -- Schwelle als Hysterese) -- sonst springt Dauerhalten endlos weiter.
            if math.abs(rx) < (thr * 0.5) then qt.st_armed = true end

            if qt.st_armed and math.abs(rx) >= thr then
                qt.st_armed = false
                -- Vorzeichen: das Engine-Yaw laeuft der Stickrichtung entgegen -- Stick nach
                -- rechts muss also einen NEGATIVEN Yaw-Schritt geben.
                local d = math.rad(tonumber(PREFS.snapturn_deg) or 45) * (rx > 0 and -1 or 1)
                -- Nur anfassen, wenn der Controller wirklich der Gameplay-Kamera gehoert.
                pcall(function()
                    local cs   = sdk.get_managed_singleton("chainsaw.CameraSystem")
                    local main = cs and cs:call("get_MainCameraController")
                    local busy = main and main:call("get_BusyCameraController")
                    local td   = sdk.find_type_definition("chainsaw.PlayerCameraController")
                    if busy and td and busy:get_type_definition():is_a(td) then
                        local y = busy:get_field("_Yaw")
                        if y then busy:set_field("_Yaw", y + d) end
                    end
                end)
                -- [2026-08-11] Hier stand `__re4_snapturn_t` fuer den Body-Follow in
                -- re4_vr_movement.lua (Verdacht: Snapturn schiebt den Spieler nach vorn).
                -- Gemessen bewegt sich der Koerper beim Turn nur Zehntelmillimeter --
                -- der Verdacht ist widerlegt, beide Haelften sind wieder raus.
            end

            -- Der rohe Stick darf jetzt NICHT zusaetzlich ans Pad, sonst dreht die Engine
            -- stufenlos weiter und der Sprung geht darin unter. NUR die X-Achse; RY
            -- (hoch/runter) bleibt unangetastet.
            f.RX = 0.0
        else
            qt.st_armed = true
        end
    end

    do
        if PREFS.enable_180_rotation and rawget(_G, "__re4_frame_pure_gameplay") == true then
            qt.update(tonumber(f.LY) or 0.0, 1.0 / 60.0)
            if qt.seq > 0 then
                -- [TURN180 2026-08-11 NEU GEBAUT] Kein Tastenspiel mehr (frueher: LY auf -1.0
                -- halten und RB dazu). Das schickte die native Kombi ins Spiel, und die kam
                -- gegen unseren eigenen Yaw-Antrieb nicht an: gemessen drehte der Koerper
                -- 130-190 Grad, die Kamera folgte nicht, danach zog es alles zurueck.
                -- Jetzt drehen wir selbst -- exakt derselbe Weg wie beim Snapturn oben,
                -- nur um 180 Grad statt um die Snapturn-Schrittweite. Damit ist die Drehung
                -- sofort da, bleibt stehen und ist mit unserem Yaw-System per Konstruktion
                -- vertraeglich (Kopf-zu-Koerper-Verhaeltnis bleibt unveraendert).
                -- Statt sofort: Restwinkel anlegen, der unten ueber die eingestellte Dauer
                -- abgearbeitet wird (0 = sofort, wie zuvor).
                qt.turn_left = math.pi
                qt.turn_last = os.clock()

                -- Einmal ausloesen reicht: Sequenz sofort beenden, Cooldown wie gehabt, damit
                -- ein gehaltener Stick nicht endlos weiterdreht.
                qt.seq = 0; qt.cooldown = true; qt.phase = 0; qt.post = qt.POST_FRAMES
            end

            -- [TURN180_LERP 2026-08-11] Die Drehung ueber die eingestellte Dauer verteilen.
            -- Laeuft ausserhalb der Ausloesung weiter, bis der Restwinkel aufgebraucht ist.
            if (qt.turn_left or 0.0) > 0.0 then
                local dur = tonumber(PREFS.turn180_sec) or 0.15
                local now = os.clock()
                local dt  = now - (qt.turn_last or now)
                qt.turn_last = now

                local step
                if dur <= 0.001 then
                    step = qt.turn_left
                else
                    step = math.pi * (dt / dur)
                    if step > qt.turn_left then step = qt.turn_left end
                end

                qt.turn_left = qt.turn_left - step

                pcall(function()
                    local cs   = sdk.get_managed_singleton("chainsaw.CameraSystem")
                    local main = cs and cs:call("get_MainCameraController")
                    local busy = main and main:call("get_BusyCameraController")
                    local td   = sdk.find_type_definition("chainsaw.PlayerCameraController")
                    if busy and td and busy:get_type_definition():is_a(td) then
                        local y = busy:get_field("_Yaw")
                        if y then busy:set_field("_Yaw", y + step) end
                    end
                end)
            end
        elseif qt.phase ~= 0 or qt.seq > 0 or qt.cooldown or qt.post > 0 then
            qt.reset()
        end
    end

    -- [ROOMSCALE_CROUCH 2026-08-11] Eigener Block, bewusst AUSSERHALB des Snapturn-Zweigs
    -- (dort haette er nur mit eingeschaltetem Snapturn gefeuert). Der Kopfhoehen-Vergleich
    -- in re4_vr_movement.lua setzt die Marke, hier wird EIN Frame lang B gedrueckt --
    -- derselbe Weg wie von Hand. Die Marke wird sofort verbraucht, und ohne den
    -- Roomscale-Haken setzt sie ueberhaupt niemand.
    -- [2026-08-11] Ein einzelner Frame war zu kurz: das Log zeigt 32x "B angefordert",
    -- waehrend der Hock-Zustand nie umsprang. Deshalb wird die Marke in einen Zaehler
    -- umgesetzt und B ueber MEHRERE Frames gehalten -- wie ein echter Tastendruck.
    if rawget(_G, "__re4_want_crouch_press") == true then
        _G.__re4_want_crouch_press = false
        _G.__re4_crouch_press_frames = 4
    end
    local cpf = tonumber(rawget(_G, "__re4_crouch_press_frames")) or 0
    if cpf > 0 then
        _G.__re4_crouch_press_frames = cpf - 1
        f.B = true
    end
    -- [SCOPE_SENS 2026-08-09] Beim Zielen durch ein MONTIERTES Scope den rechten
    -- Stick daempfen -- unabhaengig davon, was man als Sensitivity eingestellt hat,
    -- also immer dasselbe Verlangsamungs-Verhaeltnis im Zoom.
    -- Sitzt bewusst hier, direkt vor dem Export an vigem: damit gewinnt der Faktor gegen
    -- ALLE f.RX/f.RY-Setter weiter oben, ohne dass einer davon angefasst werden muss
    -- (bekannte Falle).
    -- `vr_scope_active` ist nur bei echtem Scope true -- Iron Sight bleibt unberuehrt,
    -- weil scope_aim dort false ist (weapons.lua: scope_aim = on and not iron_sight).
    do
        local sf = tonumber(rawget(_G, "__re4_scope_sens_factor"))
        if sf and sf < 1.0 and sf > 0.0 and rawget(_G, "vr_scope_active") == true then
            f.RX = (f.RX or 0.0) * sf
            f.RY = (f.RY or 0.0) * sf
        end
    end

    pcall(vigem.set_axis, "LX", clamp(f.LX, -1.0, 1.0))
    pcall(vigem.set_axis, "LY", clamp(f.LY, -1.0, 1.0))
    pcall(vigem.set_axis, "RX", clamp(f.RX, -1.0, 1.0))
    pcall(vigem.set_axis, "RY", clamp(f.RY, -1.0, 1.0))
    -- [ERST LOSLASSEN 2026-08-12] Nach einem Holster-Grab zaehlt der Grip erst wieder als Zielen,
    -- wenn er einmal losgelassen wurde. Setzt re4_vr_holster.lua bei jedem Grab; hier steht die
    -- Durchsetzung unmittelbar vor dem Versand ans Pad, weil f.LT an acht Stellen gesetzt wird.
    -- Kein Timer: gehalten -> LT bleibt 0, losgelassen -> Latch faellt und der naechste Druck zielt.
    if rawget(_G, "__re4_aim_relatch") == true then
        f.LT = 0.0
        -- Geloest wird ausschliesslich am ROHEN Grip: solange der Finger zu ist, bleibt das Latch --
        -- egal ob LT in dieser Phase ueberhaupt gemappt wird.
        if rawget(_G, "__vr_raw_l_grip") ~= true then _G.__re4_aim_relatch = false end
    end
    -- [MAP_TRIGGERS 2026-08-15] In der Kartenansicht zoomen LT und RT die Karte -- das soll dort
    -- NICHT mehr passieren, gezoomt wird ausschliesslich mit dem rechten Stick.
    -- Geblockt wird nur die AUSGABE ans Pad, unmittelbar vor dem Versand: der Trigger selbst wird
    -- weiter gelesen, deshalb bleibt "L.Trigger + R-Stick -> DPAD" (in_menu-Branch, f.DPAD_*)
    -- vollstaendig erhalten -- die DPAD-Flags stehen zu diesem Zeitpunkt laengst.
    -- Bewusst hier statt im Branch: f.LT wird an acht Stellen gesetzt (und f.RT an ebenso vielen),
    -- so hat der Block garantiert das letzte Wort, egal welcher Branch gerade lief.
    -- KEIN Latch, kein Timer, kein Global: die Abfrage gilt genau fuer diesen Frame. Faellt die
    -- Karte zu, ist der naechste Frame wieder voellig unveraendert -- es kann nichts haengenbleiben.
    local map_block_triggers = is_map_open_now()
    if map_block_triggers then f.LT = 0.0 end
    pcall(vigem.set_trigger, "LT", f.LT)
    -- [BURST 2026-07-23 UMGEBAUT] Frueher wurde hier RT auf 0 gezogen, sobald N Schuesse gefallen
    -- waren. Das ist prinzipbedingt unzuverlaessig: dieser Block laeuft einmal pro Lua-Frame, die
    -- Waffe feuert aber nach ihrer eigenen Kadenz -- bei niedriger Bildrate rutschen Schuesse durch,
    -- genau das gemeldete "Einzelschuss feuert durch". Die Begrenzung sitzt jetzt am nativen
    -- Schuss selbst (PRE-Hook auf chainsaw.PlayerEquipment.execFire, s. Block am Dateiende):
    -- frameunabhaengig, weil sie pro Schuss statt pro Frame greift.
    -- Hier bleibt nur noch die Trigger-Flanke stehen -- sie sagt dem Hook, wann ein neuer Druck
    -- beginnt und der Zaehler wieder bei 0 anfaengt.
    do
        local rt_down = (f.RT or 0) >= 0.5
        if rt_down and not _G.__vr_burst_prev_rt then
            _G.__vr_burst_press_id = (tonumber(rawget(_G, "__vr_burst_press_id")) or 0) + 1
        end
        _G.__vr_burst_rt_down   = rt_down
        _G.__vr_burst_prev_rt   = rt_down
    end
    -- [KNIFE_RT_MUTE 2026-07-03] Messer in der Hand -> rechten Trigger stilllegen (kein RT).
    -- __re4_knife_equipped kommt aus re4_vr_weapons.lua (is_knife_equipped, jeden Frame gesetzt).
    -- [GATE 2026-07-06] NUR im reinen Gameplay muten (wie [KNIFE_X_MUTE] darunter). Sonst schluckt der
    -- Mute RT in JEDEM Menu/Boot/Throwsight/KS -> die Branches setzen RT dort bewusst (z.B. in_menu:
    -- r_trigger->f.RT=1.0 fuer Kaufen/Bestaetigen) und duerfen NICHT von diesem Post-Branch-Mute
    -- ueberschrieben werden. __re4_frame_is_gameplay wird von der Branch-Funktion gesetzt.
    if rawget(_G, "__re4_knife_equipped") == true and rawget(_G, "__re4_frame_is_gameplay") == true then
        f.RT = 0.0
        -- [KNIFE_FINISHER 2026-07-10] Bei sichtbarem Finisher-Prompt (Gui_ui2200) haengt es am Flip-Zustand:
        -- * FLIPPED (Reverse-Grip): Stich-Geste (Shake) noetig -> RT NICHT durchlassen (der Shake feuert RT).
        -- * NORMAL: der physische RT wird durchgelassen -> RT-Zug feuert den Finisher direkt.
        -- Ohne Prompt bleibt RT stillgelegt -> der physische Trigger togglet stattdessen den Flip (s. KNIFE_FLIP).
        -- [PROMPT_RT 2026-07-31] Der NORMAL-Fall laeuft jetzt ueber apply_finisher_rt (Einmal-
        -- Impuls statt Dauer-RT, s. Definition oben). Der Aufruf steht bewusst AUSSERHALB der
        -- Prompt-Abfrage: die Funktion muss ihren Zustand auch pflegen, wenn das Fenster zu ist --
        -- sonst bliebe sie mit gehaltenem Trigger fuer das naechste Prompt stumpf.
        local _fin_on = (type(rawget(_G, "__re4_is_finisher_prompt")) == "function"
                         and _G.__re4_is_finisher_prompt() == true)
        local _flip   = rawget(_G, "__vr_knife_flip") == true
        -- FLIPPED (Reverse-Grip): Stich-Geste (Shake) feuert RT, der physische Trigger NICHT.
        if _fin_on and _flip and rawget(_G, "__re4_knife_finisher_shake") == true then f.RT = 1.0 end
        -- NORMAL: roher Trigger-Global (Local `r_trigger` ist in apply_frame immer nil -- [FIX 2026-07-21]).
        apply_finisher_rt(f, _fin_on and not _flip, rawget(_G, "__vr_raw_r_trigger") == true)
    end
    -- [LH_CLONE FINISHER 2026-07-10] Klon ist NICHT engine-equippt -> das knife_equipped-Gate oben greift nicht.
    -- Gleiche Zwei-Fall-Logik wie oben, bei sichtbarem Prompt:
    -- * FLIPPED: Stich-Geste (Shake) noetig -> RT NICHT durchlassen (auch kein Gun-RT), nur der Shake feuert.
    -- * NORMAL: RT bleibt ungemutet (Gameplay-Branch) -> physischer RT feuert den Finisher.
    if rawget(_G, "__re4_knife_left_clone") == true and rawget(_G, "__re4_frame_is_gameplay") == true
       and type(rawget(_G, "__re4_is_finisher_prompt")) == "function"
       and _G.__re4_is_finisher_prompt() == true then
        if rawget(_G, "__vr_knife_flip") == true then
            f.RT = (rawget(_G, "__re4_knife_finisher_shake") == true) and 1.0 or 0.0
        end
    end
    -- [GRAPPLE-WEHREN] wird universell ganz unten (vor set_trigger) behandelt, unabh. Messer/Branch/Aim.
    -- [KNIFE_X_MUTE] Messer equipt ODER geworfen (in der Luft) -> X (= Gamepad-X, nativer Reload)
    -- stilllegen. Sonst loest der rechte B-Button beim/nach dem Wurf einen nativen Pistol-Reload der
    -- zuletzt gehaltenen Schusswaffe aus. Laeuft in apply_frame (nach dem Fuellen von f.X) -> greift sicher.
    -- [BARE_HANDS_X_MUTE] Genauso bei BARE HANDS (keine Waffe equipt, EquipWeaponID < 0): dort deutet die
    -- Engine "Reload" als "zuletzt geholsterte Waffe ziehen + laden" (Waffe spawnt in der Hand, Mag dropt).
    -- X hat bare-handed keine legitime Funktion (Ziehen laeuft ueber das Holster-System) -> stilllegen.
    local bind_wid = get_binding_equip_weapon_id()
    local is_bare_hands = (bind_wid == nil) or (bind_wid < 0)
    -- NUR im reinen Gameplay muten (X_MUTE_GATE): in Menu/Boot/Throwsight/KS/Binoculars ist X eine
    -- legitime Funktion (z.B. Inventar-Objekte bewegen/managen) und darf NICHT geschluckt werden.
    if (rawget(_G, "__re4_knife_equipped") == true or rawget(_G, "__re4_knife_flying") == true
       or is_bare_hands) and rawget(_G, "__re4_frame_is_gameplay") == true then
        f.X = false   -- Button = boolean! (0.0 waere truthy -> wuerde X DRUECKEN statt muten)
    end
    -- [GESTURE_SHIFT 2026-07-21] Laeuft gerade eine Gesten-Kombi (LT + R.A/R.B, nur bare hands im
    -- Gameplay), darf das A NICHT zusaetzlich als Xbox-A rausgehen (sonst greift/interagiert Leon dabei).
    -- Das X (R.B) ist bare-handed schon vom [BARE_HANDS_X_MUTE] oben stillgelegt -> hier nur A.
    if rawget(_G, "__re4_gest_mute") == true then f.A = false end
    -- [GRAPPLE-WEHREN] Niedergerungen/gegrappelt (Hund packt, get_IsInGrappleDamage=true) -> den rohen
    -- Trigger feuern lassen, egal welcher Branch/Aim/Messer. Sonst bleibt RT im Grab gesperrt: der Grab
    -- ist ein Killswitch-State -> binding laeuft im ks_active-Branch -> apply_rt_attack reicht RT nur bei
    -- Aim durch, und im Grab zielt man nicht. Ganz zuletzt gesetzt = gewinnt ueber alle Branches.
    if rawget(_G, "__vr_raw_r_trigger") == true and player_in_grapple() then f.RT = 1.0 end
    -- [BATTLE-RT] Im Kampf-State (Battle-Flag) den rohen RT durchfeuern lassen, egal welcher Branch/Aim.
    -- Gleiches Muster wie Grapple oben (ganz zuletzt gesetzt = gewinnt ueber alle Branches).
    -- [MESSER-FLIP AUSNAHME 2026-07-17] ABER NICHT, wenn das rechte Messer RT gerade fuer den FLIP besitzt:
    -- sonst macht ein RT-Druck im Battle-State BEIDES -- Flip (Z.923, mutet nicht) UND nativer Attack (hier).
    -- Live belegt (rt_probe 19:11): knife_eq=T, gameplay=T, finisher=. -> Mute setzt f.RT=0, Battle-RT drehte
    -- es zurueck. Der Messer-Angriff laeuft in VR ueber den physischen Swing (motion), NIE ueber RT -> RT
    -- gehoert hier dem Flip. Beim Finisher-Prompt besitzt der Flip RT NICHT (RT = Finisher) -> dann darf's feuern.
    local knife_owns_rt = rawget(_G, "__re4_knife_equipped") == true
        and rawget(_G, "__re4_knife_hand") ~= "left"
        and not (type(rawget(_G, "__re4_is_finisher_prompt")) == "function" and _G.__re4_is_finisher_prompt() == true)
    -- [RT-UMBAUTEN 2026-07-21 KOMPLETT ZURUECKGENOMMEN] Hier standen heute zwei Guards:
    -- (1) kein Durchreichen bei __vr_block_fire_when_empty und (2) Aim-Pflicht + Prompt-Ausnahme.
    -- Beide sollten den nativen Quick-Knife verhindern (Engine equippt bei RT ohne Aim das Messer,
    -- per Hook belegt: "von: NATIV"). Kosten waren zu hoch: (1) machte aus einem haengenden Rack-Zwang
    -- ein Dry-Fire bei VOLLER Waffe, (2) legte den RT-Nahkampf-Prompt lahm, sobald crosshair.lua den
    -- Prompt-Zeitstempel nicht liefert (z.B. im Killswitch) -- und QTEs ohne Gui_ui2200 haetten dasselbe
    -- Problem. RISIKO ZU GROSS -> Zeile steht wieder EXAKT wie vorher. Das Messer wird stattdessen dort
    -- unterbunden, wo es entsteht: am nativen equipWeapon (Diagnose laeuft in re4_zzz_knife_who2.lua).
    if rawget(_G, "__vr_raw_r_trigger") == true and player_in_battle() and not knife_owns_rt then f.RT = 1.0 end
    -- [MAP_TRIGGERS 2026-08-15] Gegenstueck zu LT oben, mit demselben Frame-Ergebnis (`map_block_triggers`,
    -- nur EINE Abfrage pro Frame). Steht bewusst als LETZTE Zeile vor dem Versand: Grapple-RT und Battle-RT
    -- direkt darueber setzen RT branchunabhaengig auf 1.0 -- stuende der Block frueher, drehten sie ihn zurueck.
    if map_block_triggers then f.RT = 0.0 end
    pcall(vigem.set_trigger, "RT", f.RT)
    -- [MERCHANT-DIAG 2026-07-20 ENTFERNT 2026-07-21] re4_merchant_a.log raus (Ursache steht, Fix ist
    -- der ADA_A-MENUE-UEBERNAHME-Block weiter unten).
    pcall(vigem.set_button, "A", f.A)
    pcall(vigem.set_button, "B", f.B)
    pcall(vigem.set_button, "X", f.X)
    pcall(vigem.set_button, "Y", f.Y)
    pcall(vigem.set_button, "LB", f.LB)
    pcall(vigem.set_button, "RB", f.RB)
    pcall(vigem.set_button, "LS", f.LS)
    pcall(vigem.set_button, "RS", f.RS)
    pcall(vigem.set_button, "BACK", f.BACK)
    pcall(vigem.set_button, "START", f.START)
    pcall(vigem.set_button, "DPAD_UP", f.DPAD_UP)
    pcall(vigem.set_button, "DPAD_DOWN", f.DPAD_DOWN)
    pcall(vigem.set_button, "DPAD_LEFT", f.DPAD_LEFT)
    pcall(vigem.set_button, "DPAD_RIGHT", f.DPAD_RIGHT)
    -- [DPAD_EQUIP 2026-07-17] Das DPad ist der native Waffen-Shortcut = ein GEWOLLTER Wechsel -> Freifahrt
    -- fuer den KNIFE_KEEP_OUT-Block (weapons.lua hookt requestChangeWeaponAction und laesst ihn ins Leere
    -- laufen, solange ein Messer in der Hand ist). Ohne das hier waere mit Messer in der Hand KEIN
    -- DPad-Waffenwechsel mehr moeglich -- derselbe Kollateralschaden wie beim Holster-Zug.
    -- Dasselbe Zeitfenster-Global wie holster.lua (Holster-Grab / Auto-Redraw-Restore) setzt.
    -- Der Engine-Klau nach dem Killswitch kommt OHNE Input -> faellt nicht in dieses Fenster -> bleibt geblockt.
    if f.DPAD_UP or f.DPAD_DOWN or f.DPAD_LEFT or f.DPAD_RIGHT then
        _G.__re4_our_equip_until = os.clock() + 0.5
    end

    -- [PAD-SPIEGEL 2026-07-22] Rein lesende Diagnose: was WIR in diesem Frame ans virtuelle Pad
    -- geschickt haben. Ein von uns gesendeter Knopf erscheint der Engine als normaler Spieler-Input --
    -- ein daraus folgender Waffenwechsel steht im Trace dann als "NATIV" und war bisher nicht von
    -- echtem Engine-Verhalten zu unterscheiden. Kein Eingriff in irgendeinen Eingabepfad.
    _G.__re4_last_pad = string.format(
        "RT=%.2f LT=%.2f A=%s B=%s X=%s Y=%s LB=%s RB=%s LS=%s RS=%s DP=%s%s%s%s LX=%.2f LY=%.2f RX=%.2f RY=%.2f",
        tonumber(f.RT) or 0, tonumber(f.LT) or 0,
        f.A and 1 or 0, f.B and 1 or 0, f.X and 1 or 0, f.Y and 1 or 0,
        f.LB and 1 or 0, f.RB and 1 or 0, f.LS and 1 or 0, f.RS and 1 or 0,
        f.DPAD_UP and "U" or "-", f.DPAD_DOWN and "D" or "-", f.DPAD_LEFT and "L" or "-", f.DPAD_RIGHT and "R" or "-",
        tonumber(f.LX) or 0, tonumber(f.LY) or 0, tonumber(f.RX) or 0, tonumber(f.RY) or 0)
end

local was_active = false

-- ============================================================
-- Main Frame (ersetzt den share.hid.Device-update-Hook)
-- ============================================================
re.on_frame(function()
    if not ensure_init() then return end

    local vr_active = vr:is_hmd_active() and vr:is_using_controllers()
    if not vr_active then
        -- Beim Deaktivieren einmal Neutral-Frame senden (kein stale Input)
        if was_active then
            apply_frame(new_frame_state(0, 0, 0, 0))
            was_active = false
        end
        return
    end
    was_active = true

    -- [REF_OVERLAY] DLL-State einmal syncen, dann gedrosselt re-asserten
    -- (fängt Overlay-Respawns nach SteamVR-Szenenwechsel / REF-Reset). OpenVR-only.
    if overlay then
        if not _ref_overlay_synced then
            _ref_overlay_synced = true
            pcall(overlay.set_enabled, not PREFS.hide_ref_overlay)
        end
        if PREFS.hide_ref_overlay then
            _ref_overlay_tick = _ref_overlay_tick + 1
            if _ref_overlay_tick >= 30 then
                _ref_overlay_tick = 0
                pcall(overlay.tick)
            end
        end
    end

    local vr_left_stick_axis = vr:get_left_stick_axis()
    -- [SCOPE_NO_WALK 2026-08-08] Beim Zielen durch ein montiertes Scope wird nicht
    -- gelaufen -- beides zusammen ergibt ohnehin keinen Sinn, UND es ist die Ursache eines
    -- teuren Problems: das Spiel setzt `_IsViaScope` zurueck, sobald man sich bewegt (live
    -- gemessen: kippt nach 2.5 s), danach faellt unser kompletter Scope-Zweig weg und baut
    -- sich erst Sekunden spaeter wieder auf.
    -- Neutralisiert wird die QUELLE, nicht die einzelnen Setter -- damit sind alle Verbraucher
    -- unten (auch der Boot-/Jetski-Zweig) automatisch mit erfasst, ohne sie einzeln zu gaten
    -- (bekannte Falle).
    -- Nur auf unserem Fork (`__re4_scope_native`), abschaltbar ueber `__re4_scope_no_walk`.
    -- Der Stick-Zoom in re4_vr_scope.lua liest vrmod direkt und bleibt davon unberuehrt.
    if rawget(_G, "__re4_scope_native") == true and rawget(_G, "__re4_scope_no_walk") ~= false then
        local zero = nil
        pcall(function() zero = Vector2f.new(0.0, 0.0) end)
        vr_left_stick_axis = zero or { x = 0.0, y = 0.0 }
    end
    local vr_right_stick_axis = vr:get_right_stick_axis()

    -- Physical right stick (comfort/body turn) — movement.lua advances stored forward when active.
    _G.__vr_user_stick_active =
        (math.abs(vr_right_stick_axis.x) > 0.12 or math.abs(vr_right_stick_axis.y) > 0.12)

    -- [REVOLVER COCK] rohe rechte-Stick-Y publishen -> reload2 nutzt Stick-DOWN zum Hahn-Spannen (wp4500).
    -- Y ist fuer die Kamera eh gesperrt (decoupled pitch) -> Konflikt-frei. Reines Lesen, keine Bindung geaendert.
    _G.__vr_right_stick_y = vr_right_stick_axis.y or 0

    -- HMD movement: sim yaw on stick rotates body only (view stays decoupled via stored apply_hmd baseline).
    if rawget(_G, "__vr_hmd_movement_enabled") == true
        and rawget(_G, "__vr_camera_decoupled") == true
        and rawget(_G, "__vr_save_restore_active") ~= true then
        local in_menu_sim = false
        if re4.is_in_inventory_menu then
            in_menu_sim = re4.is_in_inventory_menu()
        end
        if not in_menu_sim then
            local sim_x = _G.__vr_yaw_sim_x or 0.0
            if math.abs(sim_x) > 0.001 then
                local ax = vr_right_stick_axis.x + sim_x
                if ax < -1.0 then ax = -1.0 elseif ax > 1.0 then ax = 1.0 end
                vr_right_stick_axis = Vector2f.new(ax, vr_right_stick_axis.y)
            end
        end
    end

    -- Frame-State: Sticks 1:1 durchreichen
    local f = new_frame_state(
        vr_left_stick_axis.x or 0, vr_left_stick_axis.y or 0,
        vr_right_stick_axis.x or 0, vr_right_stick_axis.y or 0)

    -- [BACKWARD] KEIN Magnitude-Cap: normales Rueckwaertsgehen kann das
    -- Spiel nativ (voller Stick = Backpedal). Eingegriffen wird nur bei
    -- Dash rueckwaerts (NO_BACK_SPRINT unten).
    local moving_backward = f.LY < 0

    --- re4_vr_holster.lua sets this when bare-handed + holstered so R grip does not reach the virtual gamepad (avoids ghost re-equip); holster still reads raw vrmod grip for draw.
    local function right_grip_maps_to_gamepad()
        if not safe_digital(ACT.grip, right_joystick) then
            return false
        end
        if rawget(_G, "__vr_in_holster_zone") == true then
            return false
        end
        -- [BARE_HANDS] Leere Haende -> Right-Grip NICHT ans Gamepad. Sonst mappt der Grip auf
        -- f.LB (Weapon/Knife-Ready) und das Spiel zieht automatisch die letzte Waffe hervor.
        -- Waffen kommen NUR bewusst ueber die Holster (die ziehen selbst per requestEquip);
        -- am Holster ist __vr_in_holster_zone oben eh schon true. (Deckt f.LB/f.RT/f.RB ab.)
        if rawget(_G, "__vr_bare_hands") == true then
            -- [STAGGER_DRAW] Ausnahme: kurz nach einem Damage-Stagger (State.Damage, Latch aus holster.lua)
            -- DARF der Right-Grip die letzte Waffe wieder ziehen (die versteckt die Engine im Stagger).
            -- Ausserhalb des Fensters bleibt der Auto-Draw bei bare hands gesperrt wie bisher.
            local u = tonumber(rawget(_G, "__vr_stagger_recent_until"))
            if not (u and os.clock() < u) then
                return false
            end
        end
        if rawget(_G, "__vr_block_shoot_ready") == true then
            return false
        end
        if rawget(_G, "__vr_holster_block_right_grip_gamepad") == true then
            return false
        end
        if rawget(_G, "__vr_block_aim") == true then   -- z.B. Bolt-Action offen -> kein Aimen
            return false
        end
        return true
    end

    --- re4_vr_holster.lua: knife ready via R grip — stowed-knife holster while bare, or knife equipped + R grip held.
    local function holster_right_grip_counts_as_knife_ready()
        return rawget(_G, "__vr_holster_rgrip_as_knife_ready") == true
            and safe_digital(ACT.grip, right_joystick)
    end

    --- re4_vr_holster.lua: R hand over left_chest slot + R grip → same as left grip for knife LB / swing / holster edge.
    local l_grip_from_left = safe_digital(ACT.grip, left_joystick)
    local holster_left_chest_rgrip_as_lgrip = rawget(_G, "__vr_holster_left_chest_rgrip_as_left_grip") == true
        and safe_digital(ACT.grip, right_joystick)
    local l_grip_effective = l_grip_from_left or holster_left_chest_rgrip_as_lgrip
    --- while left hand is in the head-flashlight zone, do not map L grip to Knife Ready (LB).
    local head_flash_blocks_l_grip_melee = rawget(_G, "__vr_in_head_flashlight_zone") == true
    --- [MAG_HOLSTER] linke Hand in der Mag-Holster-Zone -> L grip NICHT als Messer-Ready (LB) (re4_vr_holster.lua)
    local mag_holster_blocks_l_grip_melee = rawget(_G, "__vr_in_mag_holster_zone") == true
    --- [TWO_HAND_IK / TEMP] Linker Grip ist vom Messer ENTKOPPELT -> frei fuer 2-Hand-IK.
    --- Die Messer-Funktion bleibt komplett im Script: der Holster-Chest-R-Grip-Pfad loest weiter
    --- Knife-Ready/Swing aus, nur der LINKE Grip nicht mehr. Flag auf false = altes Verhalten zurueck.
    local TWO_HAND_FREE_LEFT_GRIP = true
    local l_grip_melee_from_left = l_grip_from_left and not head_flash_blocks_l_grip_melee
            and not mag_holster_blocks_l_grip_melee
    if TWO_HAND_FREE_LEFT_GRIP then l_grip_melee_from_left = false end
    local l_grip_effective_for_melee = l_grip_melee_from_left
        or holster_left_chest_rgrip_as_lgrip
    --- [SLIDE_RACK] waehrend Rack noetig: linker Grip = Slide-Grab, NICHT Messer (re4_vr_reload.lua)
    if rawget(_G, "__vr_rack_block_left_knife") == true then l_grip_effective_for_melee = false end

    -- [GRENADE_IN_HAND] binding_is_grenade_equipped_live liest die MAIN-WeaponID -> erkennt eine ueber das
    -- Holster gezogene Granate nicht (Main bleibt z.B. LE5) -> f.LB (Messer-Ready) feuerte beim Wurf-Grip.
    -- __vr_grenade_in_hand (get_IsEquipGrenade, vom Holster-Script) ist das ehrliche "Granate wirklich in Hand".
    local gren_live_binding = binding_is_grenade_equipped_live() or rawget(_G, "__vr_grenade_in_hand") == true

    local grenade_motion_rt = false
    do
        local signal = ((vr_is_grenade_equipped == true) or gren_live_binding) and (vr_grenade_throw == true)
        if signal and not prev_vr_grenade_throw then
            grenade_rt_pulse_frames = 6
        end
        prev_vr_grenade_throw = signal
        if grenade_rt_pulse_frames > 0 then
            grenade_motion_rt = true
            grenade_rt_pulse_frames = grenade_rt_pulse_frames - 1
        end
    end

    --- Knife swing and grenade throw both use RT. Grenade-Wurf wird jetzt von
    --- re4_vr_weapons release-to-throw (Grip-Loslassen) gegated -> RT-Puls darf
    --- auch ohne gehaltenen Grip feuern (beim Release ist Grip naturgemaess los).
    local right_grip_hold_raw = safe_digital(ACT.grip, right_joystick)
    local grenade_motion_rt_armed = grenade_motion_rt

    --- Throwable out: block knife-motion→RT and phantom LB knife-ready grips.
    local grenade_blocks_right_hand_knife_motion = (vr_is_grenade_equipped == true) or gren_live_binding
    local disable_motion_grenade_rt = rawget(_G, "__vr_disable_motion_grenade_rt") == true

    -- Inputs
    local l_trigger  = safe_digital(ACT.weapon_dial, left_joystick)
    local r_trigger  = safe_digital(ACT.trigger, right_joystick)
    _G.__vr_raw_r_trigger = r_trigger == true   -- roher phys. Trigger, IMMER (unabh. Waffe/Branch/Aim) -> Grapple-RT
    -- [KNIFE_FLIP 2026-07-03] Messer in der Hand: RT-Flanke togglet den 180°-Reverse-Grip-Flip. Der
    -- RT-Output ist beim Messer eh stillgelegt (KNIFE_RT_MUTE) -> der physische Trigger ist frei dafuer.
    -- motion.lua lerpt __vr_knife_flip in die Flip-Stellung. Kein Messer -> zurueck auf nativ.
    -- [KNIFE_HAND 2026-07-07] Nur wenn das Messer in der RECHTEN Hand ist: der RT-Flip gehoert rechts.
    -- Messer links -> RT flippt NICHT (linker Flip laeuft spaeter ueber den linken Trigger, eigener Schritt).
    if rawget(_G, "__re4_knife_equipped") == true and rawget(_G, "__re4_knife_hand") ~= "left" then
        -- Im Grapple (Wehren) feuert der Trigger statt zu flippen -> Flip-Toggle hier aussetzen,
        -- prev_rt aber weiter pflegen (kein Phantom-Toggle beim Verlassen des Grabs).
        -- [FINISHER 2026-07-10] Bei sichtbarem Finisher-Prompt togglet RT NICHT den Flip -> RT ist dann echter
        -- RT (Finisher, s. KNIFE_RT_MUTE oben). Sonst wuerde der Finisher-Zug auch noch den Flip umschalten.
        if r_trigger and not (rawget(_G, "__vr_knife_flip_prev_rt") == true) and not player_in_grapple()
           and not (type(rawget(_G, "__re4_is_finisher_prompt")) == "function" and _G.__re4_is_finisher_prompt() == true) then
            _G.__vr_knife_flip = not (rawget(_G, "__vr_knife_flip") == true)
        end
        _G.__vr_knife_flip_prev_rt = r_trigger == true
    else
        _G.__vr_knife_flip_prev_rt = false
        -- [KNIFE_FLIP LINKS] Flip NICHT zwangs-auf-false, wenn das Messer LINKS liegt -> dann gehoert der
        -- Toggle dem LINKEN Trigger (Block direkt unten). Nur ohne Links-Messer hart nativ zuruecksetzen.
        if rawget(_G, "__re4_knife_hand") ~= "left" and rawget(_G, "__re4_knife_left_clone") ~= true then _G.__vr_knife_flip = false end
    end

    -- [KNIFE_FLIP LINKS 2026-07-07] Messer in der LINKEN Hand: der LINKE Trigger togglet den Flip, GENAU
    -- wie rechts der RT. LT ist zugleich der DPAD-Shift (Halten). Unterscheidung: KURZER Tap (< LT_FLIP_TAP
    -- Sek.) = Flip; laenger Halten = DPAD (apply_dpad_shift wird erst ab derselben Schwelle scharf). Gleicher
    -- Toggle-Global __vr_knife_flip wie rechts -> motion wendet den Flip an (Links-Pin spiegelt die Offsets).
    -- Im Grapple (Wehren) kein Flip. Rechter Pfad voellig unberuehrt (Preservation).
    -- [KNIFE_FLIP LINKS 2026-07-07] Flip auf LOSLASSEN -> KEIN Zucken beim Halten. Kurzer Tap
    -- (Release < LT_FLIP_TAP) = Flip; laenger gehalten = DPAD (kein Flip). Der Flip feuert genau beim
    -- Loslassen -> Verzoegerung = nur die eigene Tap-Dauer, KEIN fixer Zusatz-Delay. Sobald als Halten
    -- erkannt (>= Schwelle), DPAD-Shift scharf + Flip beim Loslassen unterdrueckt. NUR wenn Messer LINKS;
    -- sonst macht LT ausnahmslos DPAD-Shift. Im Grapple kein Flip.
    local lt_flip_shift = false   -- true = als DPAD-Hold erkannt -> apply_dpad_shift scharf
    local LT_FLIP_TAP = tonumber(rawget(_G, "__re4_knife_lt_flip_tap")) or 0.18
    if (rawget(_G, "__re4_knife_equipped") == true and rawget(_G, "__re4_knife_hand") == "left") or rawget(_G, "__re4_knife_left_clone") == true then
        if l_trigger then
            if rawget(_G, "__vr_lt_flip_prev") ~= true then
                _G.__vr_lt_flip_press_t = os.clock()          -- Rising Edge: Tap-Timer starten
                _G.__vr_lt_flip_hold = false
            end
            if rawget(_G, "__vr_lt_flip_hold") ~= true
                    and (os.clock() - (tonumber(rawget(_G, "__vr_lt_flip_press_t")) or os.clock())) >= LT_FLIP_TAP then
                _G.__vr_lt_flip_hold = true                    -- Halten erkannt -> DPAD, Flip beim Loslassen unterdruecken
            end
            lt_flip_shift = rawget(_G, "__vr_lt_flip_hold") == true
        else
            if rawget(_G, "__vr_lt_flip_prev") == true and rawget(_G, "__vr_lt_flip_hold") ~= true
                    and not player_in_grapple() then
                _G.__vr_knife_flip = not (rawget(_G, "__vr_knife_flip") == true)   -- kurzer Tap -> Flip togglen
            end
            _G.__vr_lt_flip_hold = false
        end
        _G.__vr_lt_flip_prev = l_trigger == true
    else
        _G.__vr_lt_flip_prev = false
        _G.__vr_lt_flip_hold = false
    end
    local l_abutton  = safe_digital(ACT.a_button, left_joystick)
    local r_abutton  = safe_digital(ACT.a_button, right_joystick)
    local l_bbutton  = safe_digital(ACT.b_button, left_joystick)
    local r_bbutton  = safe_digital(ACT.b_button, right_joystick)
    -- [MANUAL_RELOAD] autoritative B-Quelle fuer re4_vr_reload.lua (dessen right_b_down liest
    -- NUR das hier, statt selbst ueber vrmod zu lesen -> kein stale Action-Handle). VOR dem
    -- Consume publiziert, damit der echte Tastendruck ankommt. NICHT entfernen.
    _G.__vr_raw_r_bbutton = r_bbutton
    -- [MANUAL_RELOAD] rechter B wird von der manuellen Reload-Logik konsumiert
    -- (re4_vr_reload.lua setzt das Flag, wenn die equippte Waffe verwaltet wird).
    -- Dann NICHT als Reload (Gamepad-X) weiterreichen -> kein nativer Reload.
    -- [MENU_B_FIX 2026-07-17] ABER im Menue/Typewriter NICHT konsumieren: dort ist R.B = Xbox-X (Move Item /
    -- Inventar-Aktion). Sonst schluckt eine equippte Manual-Reload-Waffe (reload2/reload3 lassen das Flag an)
    -- den B auch im Inventar -> "X geht nicht". is_any_menu_open ist hier schon aufrufbar (Def. Z.~321).
    if rawget(_G, "__vr_manual_reload_consume_b") == true and not is_any_menu_open() then r_bbutton = false end
    local l_joyclick = safe_digital(ACT.joy_click, left_joystick)
    local r_joyclick = safe_digital(ACT.joy_click, right_joystick)
    local l_dpad_up    = safe_digital(ACT.dpad_up, left_joystick)
    local l_dpad_down  = safe_digital(ACT.dpad_down, left_joystick)
    local l_dpad_left  = safe_digital(ACT.dpad_left, left_joystick)
    local l_dpad_right = safe_digital(ACT.dpad_right, left_joystick)

    local handle_pause = false
    pcall(function()
        if vr:should_handle_pause() then
            handle_pause = true
            vr:set_handle_pause(false)
        end
    end)

    -- DPAD-Shift: L.Trigger gehalten + R-Stick → DPAD; sonst echte dpad-Actions.
    local function apply_dpad_shift()
        -- [KNIFE_FLIP LINKS] Messer links: LT wird erst ab der Halteschwelle DPAD-Shift (lt_flip_shift),
        -- damit der kurze Flip-Tap KEIN DPAD ausloest. Sonst (kein Links-Messer) wirkt LT sofort (Preservation).
        local shift_on = l_trigger and ((rawget(_G, "__re4_knife_hand") ~= "left" and rawget(_G, "__re4_knife_left_clone") ~= true) or lt_flip_shift)
        if shift_on then
            if vr_right_stick_axis.y >= 0.9 then f.DPAD_UP = true
            elseif vr_right_stick_axis.y <= -0.9 then f.DPAD_DOWN = true end
            if vr_right_stick_axis.x >= 0.9 then f.DPAD_RIGHT = true
            elseif vr_right_stick_axis.x <= -0.9 then f.DPAD_LEFT = true end
            -- R-Stick geht waehrend des Shifts NUR in die Waffenwahl —
            -- nicht ans Pad (sonst rotiert Kamera/Char im Hintergrund mit).
            f.RX = 0.0
        else
            if l_dpad_up then f.DPAD_UP = true end
            if l_dpad_down then f.DPAD_DOWN = true end
            if l_dpad_left then f.DPAD_LEFT = true end
            if l_dpad_right then f.DPAD_RIGHT = true end
        end
    end

    -- L.Grip → Knife Ready (LB): GECLEART 2026-07-07 (toter Pfad). Der linke Grip ist jetzt FREI und
    -- gehoert re4_vr_knife_lefthand.lua (Messer mit LINKS aus dem Holster ziehen). Diese Funktion feuert
    -- bewusst NICHTS mehr (kein f.LB, kein vr_holster_knife ueber links) -> keine Doppelbelegung.
    local function apply_l_grip_knife()
        -- no-op (linker Grip komplett dem Links-Messer-Script ueberlassen)
    end

    -- R.Trigger/Motion → RT inkl. Grenade-Cooldown (Boot/KS/Bino/Gameplay identisch)
    local function apply_rt_attack()
        if grenade_throw_cooldown > 0 then
            grenade_throw_cooldown = grenade_throw_cooldown - 1
            vr_knife_swing = false  -- suppress residual swing from throw motion
        end
        if vr_grenade_throw == true or vr_is_grenade_equipped == true or gren_live_binding then
            grenade_throw_cooldown = GRENADE_COOLDOWN_FRAMES
        end

        -- [KNIFE_MELEE_REWORK] Messer-Swing zuendet NICHT mehr RT (kein natives 3rd-Person-Melee via
        -- Trigger mehr). Das ECHTE, selbst-detektierte Messer-Melee (Velocity-Swing + eigene Kollision
        -- gegen Gegner UND Breakables + requestDamage, Muster wie RE9-Axt) kommt in re4_vr_weapons.lua
        -- und konsumiert vr_knife_swing dort direkt. Nur noch der Granaten-Wurf triggert Motion->RT.
        local motion_attack = (grenade_motion_rt_armed and not disable_motion_grenade_rt)

        -- Slide-Rack (RE9-Muster): leeres Mag -> Feuern gesperrt bis nachgeladen UND gerackt.
        -- Gilt nur fuer das Gun-Feuern; Messer/Granate (motion_attack) bleibt erlaubt.
        local block_empty = (rawget(_G, "__vr_block_fire_when_empty") == true) and not motion_attack
        -- [RT-DIAG 2026-07-20 ENTFERNT 2026-07-21] RT-BYPASS-Log raus.

        -- [SND] Dry-Fire: leere/gesperrte Waffe + Schuss-Trigger gezogen -> reload.lua
        -- liest die Flanke und spielt den Klick. (Messer/Granate = motion_attack zaehlt nicht.)
        _G.__re4_empty_trigger_held = (r_trigger and block_empty and not motion_attack) and true or false

        -- [QUICK-KNIFE-BLOCK] RT nur an die Engine geben, wenn wirklich gezielt wird (Aim) ODER ein
        -- Granaten-Wurf laeuft. Sonst loest RT OHNE Aim bei einer Schusswaffe den nativen Quick-Knife aus
        -- (Engine zieht das Messer -> __re4_knife_equipped wird true -> unser Flip griff faelschlich).
        -- Das echte Messer wird via KNIFE_RT_MUTE separat behandelt; sein Flip laeuft ueber r_trigger.
        local aiming = rawget(_G, "__vr_aim_input") == true
        if ((r_trigger and aiming) or motion_attack) and not block_empty then
            f.RT = 1.0
            _G.__re4_rt_given_t = os.clock()   -- [RT-DIAG] WIR haben RT freigegeben
        end
        -- [GRENADE-AIM-FORCE 2026-07-23, Log-belegt] Der native Granaten-Wurf braucht RT UND Aim (f.LT)
        -- GLEICHZEITIG. Der Wurf loest beim Grip-LOSLASSEN aus -> in dem Moment ist der Grip weg, apply_r_grip_aim
        -- setzt f.LT NICHT mehr (aim=0). Beleg: re4_grenade_diag.log -- an JEDEM gthrow=1-Frame aim=0, rtgiven=1
        -- -> RT ohne Aim -> Granate fliegt nicht, throw_pending clemmt. FIX: waehrend des Wurf-Pulses (motion_attack,
        -- die 6 grenade_rt_pulse_frames) Aim kuenstlich halten, damit der native Wurf durchlaeuft. Nur der
        -- Granaten-Puls -> beruehrt kein anderes Feuern. apply_r_grip_aim nullt f.LT nie -> kein Konflikt.
        if motion_attack then f.LT = 1.0 end
    end

    -- [SCOPE_GRIP_DELAY 2026-08-11, gemessen] Bei Scope-Waffen (Sniper) rutschte beim
    -- Gripdruck GENAU EIN Frame Aim durch, bevor re4_vr_holster.lua sein
    -- `__vr_holster_grab_armed` setzen konnte (Log: +0.024 s aim_in=true, +0.075 s
    -- scope=true). Das native Aim ist ein Latch -- der eine Frame reicht, die Sniper rastet
    -- ins Scope, der Scope-Killswitch legt daraufhin das Holster still und der Grab beim
    -- Loslassen laeuft ins Leere. Deshalb: Aim ab der DRUCKFLANKE kurz zurueckhalten, damit
    -- das Holster-Script eine Chance hat, sich zu melden. Wird in dieser Zeit kein Grab
    -- angemeldet, aimt es ganz normal weiter -- nur eben ein paar Millisekunden spaeter.
    -- Gilt NUR fuer Scope-Waffen; alle anderen Waffen bleiben unveraendert sofort.
    -- Der Zustand MUSS den Frame ueberdauern: diese Funktion lebt im Frame-Handler, ein
    -- `local` hier waere jeden Frame frisch -- dann sieht der Code jedes Mal eine neue
    -- Druckflanke und sperrt das Aim dauerhaft (genau das ist beim ersten Versuch passiert).
    -- Darum Globals mit Praefix statt Locals.
    local SCOPE_GRIP_AIM_DELAY = 0.08   -- s

    local function scope_grip_aim_blocked(grip_now)
        grip_now = grip_now and true or false

        if rawget(_G, "__re4_scope_wid") == nil then
            _G.__vr_scope_grip_edge_t = nil
            _G.__vr_scope_grip_prev = grip_now
            return false
        end

        local prev = rawget(_G, "__vr_scope_grip_prev") == true

        if grip_now and not prev then
            _G.__vr_scope_grip_edge_t = os.clock()
        elseif not grip_now then
            _G.__vr_scope_grip_edge_t = nil
        end

        _G.__vr_scope_grip_prev = grip_now

        local t = tonumber(rawget(_G, "__vr_scope_grip_edge_t"))
        return t ~= nil and (os.clock() - t) < SCOPE_GRIP_AIM_DELAY
    end

    -- R.Grip → Holster-Melee: Knife Ready (LB) | sonst Aim (LT) (KS/Bino/Gameplay identisch)
    local function apply_r_grip_aim()
        if holster_right_grip_counts_as_knife_ready() and not grenade_blocks_right_hand_knife_motion then
            f.LB = true
        elseif rawget(_G, "__re4_knife_equipped") == true then
            -- [KNIFE_THROW] Messer equippt: rechter Grip ist der WURF (weapons.lua liest ihn roh via
            -- is_right_grip_held) -> hier KEIN f.LT, damit das Messer beim Grip NICHT aimt/zoomt.
            -- Nur beim Messer; alle anderen Waffen behalten rechter Grip = Aim (LT) unten.
        elseif scope_grip_aim_blocked(safe_digital(ACT.grip, right_joystick)) then
            -- [SCOPE_GRIP_DELAY] Erste Millisekunden nach der Druckflanke: noch kein Aim, damit
            -- das Holster-Script sich melden kann (Begruendung und Messwerte oben).
        elseif rawget(_G, "__vr_holster_grab_armed") == true then
            -- [HOLSTER_GRAB] Aim NUR aus, wenn die Grip-Presse IN einer Zone BEGANN (echter Greifvorgang).
            -- Mit gedruecktem Aim ueber ein Holster HOVERN sperrt das Aim NICHT mehr (die Presse begann
            -- ausserhalb -> grab_armed bleibt false). Genau wie beim Grab: nur Presse-in-Zone zaehlt.
        elseif (function()
                    local u = tonumber(rawget(_G, "__vr_post_stow_until")); return u ~= nil and os.clock() < u
                end)() then
            -- [POST_STOW] NUR kurz NACH dem Wegstecken einer Waffe (Grab in einer Zone) KEIN Aim -> verhindert,
            -- dass der Aim-Auto-Draw die gerade weggesteckte Waffe sofort zurueckzieht (Flackern), bis
            -- __vr_bare_hands greift. WICHTIG: die alte pauschale Zonen-Sperre ist raus -> Zielen mit einer
            -- Waffe in der Hand bleibt frei, auch wenn die Hand zufaellig in einer Holster-Zone liegt.
        elseif rawget(_G, "__vr_bare_hands") == true then
            -- [BARE_HANDS] Leere Haende: KEIN Aim -> das Spiel wuerde sonst automatisch die letzte
            -- Waffe ziehen. Waffen holt man bewusst ueber die Holster (Messer-Dummy / Pistolen-Huefte).
        elseif rawget(_G, "__vr_knife_in_hand") == true then
            -- [MELEE_NO_AIM] NUR Messer: das ist ein echter Eigenwurf (kfly) -> rechter Grip = Wurf, KEIN Aim.
            -- GRANATE gehoert hier NICHT rein: ihr Wurf laeuft ueber den NATIVEN Pfad (weapons.lua setzt
            -- vr_grenade_throw -> RT), der das native Aim (f.LT) BRAUCHT. Aim sperren = Granate fliegt nicht +
            -- native Nahkampf-Aktion zieht das Messer. f.LB (Messer-Ready) wird bei Granate ueber
            -- gren_live_binding/__vr_grenade_in_hand geblockt, nicht ueber die Aim-Sperre.
        elseif right_grip_maps_to_gamepad() then
            f.LT = 1.0
        end
    end

    -- [REF_OVERLAY] L.Trigger + L.B → REFramework-VR-Menü togglen. Steht VOR dem
    -- Branch-Split, gilt damit in ALLEN Branches. Unterdrückt L.B→Y bei aktivem Combo.
    do
        local combo = l_trigger and l_bbutton
        if combo and not lt_b_overlay_was then
            -- [REF_UI 2026-08-14] Dieselbe Kombi macht jetzt ZWEI Dinge, bewusst beide:
            --  1) Das MENUE selbst auf/zu -- im neuen Fork ist das die Flaeche an der linken
            --     Hand, unter OpenXR als Quad-Layer, unter OpenVR als SteamVR-Overlay.
            --     Braucht reframework:set_draw_ui aus dem neuen Fork; mit einer aelteren DLL
            --     schlaegt der pcall fehl und es bleibt beim alten Verhalten darunter.
            --  2) Wie bisher das Palm-Overlay des re_vr-Plugins schalten. Es FOLGT jetzt dem
            --     Menuezustand statt eigenstaendig zu togglen -- sonst wuerde es im neuen Fork
            --     genau das Overlay verstecken, auf dem unser Menue liegt.
            local want_ui = true
            local ok_ui = pcall(function()
                want_ui = not reframework:is_drawing_ui()
                reframework:set_draw_ui(want_ui)
            end)

            if overlay then
                PREFS.hide_ref_overlay = ok_ui and (not want_ui) or (not PREFS.hide_ref_overlay)
                save_prefs()
                pcall(overlay.set_enabled, not PREFS.hide_ref_overlay)
            end

            -- [2026-08-04] EIN Sound fuer beide Richtungen, auf dem Player-Body-Container.
            -- Steht jetzt ausserhalb des overlay-Zweigs: er soll auch dann kommen, wenn nur
            -- das Menue geschaltet wurde (Plugin nicht geladen).
            play_body_sound(REFUI_SOUND)
        end
        lt_b_overlay_was = combo
        if combo then l_bbutton = false end  -- L.B nicht zusätzlich als Y senden
    end

    -- [DUAL_TRIGGER_MENU] Beide Trigger 3s halten → START (Hauptmenü). Pre-Branch,
    -- gilt in allen Branches; feuert einmal pro Hold (Edge), Anwendung weiter unten.
    local dual_trigger_start = false
    do
        if l_trigger and r_trigger then
            dual_trigger_gap_clock = nil   -- wieder beide da -> Karenz verfaellt
            if not dual_trigger_start_clock then dual_trigger_start_clock = os.clock() end
            if not dual_trigger_fired
                and (os.clock() - dual_trigger_start_clock) >= DUAL_TRIGGER_HOLD_SEC then
                dual_trigger_start = true
                dual_trigger_fired = true
            end
        elseif dual_trigger_start_clock then
            -- [COMBO_GRACE] Kurzes Flackern an der Trigger-Schwelle ist KEIN Loslassen: die Uhr
            -- laeuft weiter, bis die Kombo laenger als COMBO_GRACE_SEC offen ist. `fired` wird
            -- bewusst erst zusammen mit der Uhr geloescht, sonst feuert es waehrend der Karenz
            -- jeden Frame erneut (die 2 s sind ja laengst durch).
            if not dual_trigger_gap_clock then dual_trigger_gap_clock = os.clock() end
            if (os.clock() - dual_trigger_gap_clock) >= COMBO_GRACE_SEC then
                dual_trigger_start_clock = nil
                dual_trigger_fired = false
                dual_trigger_gap_clock = nil
            end
        else
            dual_trigger_fired = false
            dual_trigger_gap_clock = nil
        end
    end

    local ks_active = killswitch.is_active()
    local in_throwsight = is_throwsight_stage()
    local in_boat = is_boat_stage()
    local in_menu = is_any_menu_open()
    -- [ADA_A MENUE-UEBERNAHME 2026-07-20 -- per Log bewiesen] Adas rechtes A reicht das A erst
    -- beim LOSLASSEN nach (noetig fuer den Longpress = RB/Haken). Bestaetigt man im Menue mit A, laeuft
    -- beim Schliessen sofort der Gameplay-Zweig -- der sah den noch gedrueckten Knopf als FRISCHE Presse
    -- und schickte beim Loslassen ein A hinterher: der Haendler ging sofort wieder auf (Log: "A ueber
    -- UNSER Gamepad, 0.02s nach Menue-Ende"). Bei Leon gibt es das nicht, weil sein A sofort feuert.
    -- FIX: solange ein Menue offen ist, den Tastenzustand mitfuehren -> die Presse gilt beim Verlassen
    -- als BEREITS GESEHEN, es gibt keine frische Flanke und damit kein nachgereichtes A.
    if in_menu then
        local st0 = rawget(_G, "__re4_ada_ra")
        if type(st0) ~= "table" then st0 = {}; _G.__re4_ada_ra = st0 end
        st0.prev = r_abutton
        st0.down_t = nil; st0.fired_rb = false; st0.a_timer = 0
    end
    -- [MERCHANT-DIAG ENTFERNT 2026-07-21] Menue-Verlassen-Zeitstempel + Log raus.
    local in_binoculars = is_binoculars_active_this_frame()
    local in_turret = is_turret_mounted()   -- [TURRET] MG-Turret (InstalledMachineGun)
    local in_jetski = rawget(_G, "__re4_jetski_active") == true   -- [JETSKI] KS4-Flag aus dem killswitch (Stages 592xx)
    local boat_active = rawget(_G, "__re4_boat_active") == true    -- [BOAT] KS4-Flag aus dem killswitch (get_IsBoat, Fahrt/VehicleCam -- NICHT der Einstieg auf ActionCam)

    -- [TEMP DODGE-DIAG 2026-07-17 ENTFERNT 2026-07-21] re4_dodge_diag.log samt Singleton-Abfragen raus.

    -- [BACK_GUARD] Verlaesst man ein Menue mit noch gehaltenem Links-A, darf das gehaltene A im
    -- Gameplay/KS NICHT sofort als BACK/Xbox-Select (= Map-Ansicht) durchschlagen. Latch solange
    -- in_menu + A gehalten -> unten wird f.BACK geschluckt, bis A physisch losgelassen ist.
    -- [TURRET 2026-07-16] GENAU DIESELBE Falle beim Absteigen von der MG-Turret: dort ist Links-A = B
    -- (Dismount); beim Aussteigen laeuft fuer ein paar Frames der ks_active-/Gameplay-Branch, der das noch
    -- gehaltene A als BACK->Map durchschlagen laesst ("Map geht sofort auf"). Also in_turret mitguarden.
    if (in_menu or in_turret) and l_abutton then la_hold.back_guard = true end

    -- [KS_X_GUARD 2026-08-18] Dasselbe Muster fuer den rechten B (= Gamepad-X = nativer Reload), aber
    -- fuer das KS-ENDE. Im Killswitch/Cutscene darf X wirken (eigener Branch weiter unten) -- ein Druck,
    -- der IM KS begonnen hat, darf danach aber nicht ins Gameplay weiterlaufen: waehrend der Uebergabe
    -- ist die Engine typischerweise frueher "Gameplay" als unser ks_active, und ein noch gehaltenes X
    -- feuert dort den nativen Reload. Also latchen und erst nach echtem LOSLASSEN wieder freigeben
    -- (Aufloesung unten bei f.BACK/BACK_GUARD, Reset im on_script_reset).
    -- Gemerkt wird am ROHEN Knopf (__vr_raw_r_bbutton, Z.1803): r_bbutton ist bei verwalteten Waffen
    -- schon vom Reload-Modul konsumiert (Z.1810) -> der Latch wuerde sonst nie zustande kommen.
    -- Das Flag liegt bewusst in der bestehenden la_hold-Tabelle (kein neues Upvalue in dieser sehr
    -- grossen on_frame-Funktion).
    if ks_active and rawget(_G, "__vr_raw_r_bbutton") == true then la_hold.ks_x_guard = true end

    -- [X_MUTE_GATE] Merkt fuer apply_frame, ob dieser Frame REINES Gameplay ist. Nur dann darf der
    -- bare-hands/Messer-X-Mute greifen. In Menu/Boot/Throwsight/KS/Binoculars ist X eine legitime
    -- Funktion (Inventar-Objekte bewegen etc.) und darf NICHT stillgelegt werden.
    _G.__re4_frame_is_gameplay = (not in_menu and not in_boat and not in_throwsight
        and not in_binoculars and not ks_active)
    -- [WARUM-EXPORT 2026-08-18] NUR Diagnose, kein Verhalten: welcher der fuenf Zustaende das Flag
    -- gerade auf false zieht. Hintergrund: der Quick-Knife-Block in weapons.lua steigt bei
    -- `__re4_frame_is_gameplay ~= true` sofort aus -- im Crash-/RT-Log stand bei JEDEM nativen
    -- requestEquipKnife "battle_ok=0" und `qk_blocked=0`, der Block hat also nie gegriffen. Ohne
    -- diesen String liesse sich nur raten, welcher Zustand es war.
    _G.__re4_gameplay_why = (_G.__re4_frame_is_gameplay and "gameplay")
        or ((in_menu and "menu") or (in_boat and "boat") or (in_throwsight and "throwsight")
            or (in_binoculars and "bino") or (ks_active and "killswitch") or "?")
    -- [PURE_GAMEPLAY_EXPORT 2026-07-21] NUR ein Export, KEIN Verhalten: wie __re4_frame_is_gameplay,
    -- aber zusaetzlich ohne Turret und Jetski (die beiden haben eigene Branches, fehlen aber oben, weil der
    -- X-Mute sie bewusst mitnimmt). Liest der Wild-West-Twirl (weapons2.lua) fuer sein RT-Halte-Gate.
    -- Nichts im Binding wertet das aus -> bestehende Bindings bleiben unberuehrt.
    _G.__re4_frame_pure_gameplay = _G.__re4_frame_is_gameplay and (not in_turret) and (not in_jetski)

    -- [GESTURE_SHIFT 2026-07-21] L.Trigger = Shift (bleibt DPAD-Shift wie bisher). Zusaetzlich, aber
    -- AUSSCHLIESSLICH mit LEEREN HAENDEN und in reinem Gameplay: LT+R.A -> Geste "point", LT+R.B -> "fuck_you"
    -- (re4_vr_guestures.lua). Steht VOR dem Branch-Split -> gilt fuer Leon UND Ada identisch.
    -- Nur die Zuendung (Flanke) wird exportiert; das Muten von A passiert in apply_frame ueber __re4_gest_mute.
    -- Mit Waffe/Messer in der Hand ist das komplett inaktiv -> A/B verhalten sich unveraendert.
    do
        -- [RECHTE HAND FREI 2026-07-21] Kriterium ist die RECHTE Hand, nicht "gar nichts in der Hand":
        -- gar keine Waffe zaehlt, UND das Messer in der LINKEN Hand zaehlt auch (dann ist rechts frei).
        -- Messer rechts oder eine Schusswaffe -> keine Geste.
        local right_free = rawget(_G, "__vr_bare_hands") == true
        if not right_free
           and rawget(_G, "__re4_knife_equipped") == true
           and rawget(_G, "__re4_knife_hand") == "left" then
            right_free = true
        end
        if right_free and rawget(_G, "__re4_knife_hand") == "right" then right_free = false end
        -- [KEINE GESTEN IN MERCENARIES 2026-08-04] NUR ueber is_mercs_active -- das ist ein
        -- Global, das re4_vr_merc.lua getickt setzt, also pro Frame stabil.
        --
        -- ACHTUNG, teuer bezahlt am 04.08.: hier stand zusaetzlich ein gesture_body_ok, das den
        -- Body-GO-Namen LIVE pro Frame nachschlug. Schlaegt so ein Lookup in EINEM Frame fehl, wird g
        -- nil -> __re4_gest_mute faellt auf false -> das A geht als Xbox-A durch (Waffe wird gezogen),
        -- und weil die Hand dann nicht mehr leer ist, faellt auch der [BARE_HANDS_X_MUTE] weg und das
        -- R.B schlaegt als X durch (Magazin fliegt raus). Genau das ist beim Stinkefinger passiert.
        -- In einem Eingabepfad hat ein Live-Lookup nichts verloren.
        local g = nil
        if l_trigger and _G.__re4_frame_pure_gameplay and right_free
           and not is_mercs_active() then
            if r_abutton then g = "point" elseif r_bbutton then g = "fuck_you" end
        end
        _G.__re4_gest_mute = (g ~= nil)
        if g and g ~= rawget(_G, "__re4_gest_prev") then _G.__re4_gesture_fire = g end
        _G.__re4_gest_prev = g
    end

    -- [EASTER_EGG_FLAMETHROWER] Beide A-Buttons 5s im Gameplay → Flamethrower in Aufbewahrung.
    local both_a = l_abutton and r_abutton
    do
        -- [NUR LEON 2026-08-11] Das Easteregg legt den Flamethrower in die Aufbewahrung der
        -- Kampagne -- es gehoert also zu Leon und sonst niemandem. Bis heute fehlte jede
        -- Charakter-Pruefung, es zuendete auch bei Ada und in den Mercenaries.
        -- Beide Abfragen sind die im Script etablierten: is_ada_active() haengt am stabilen
        -- __re4_char_now (ueberbrueckt Body-Aussetzer), is_mercs_active() liest nur ein
        -- geticktes Global -- kein Live-Lookup im Eingabepfad (teuer bezahlt am 04.08.).
        local in_gameplay = not in_menu and not in_boat and not in_throwsight
            and not in_binoculars and not ks_active
            and not is_ada_active() and not is_mercs_active()
        if both_a and in_gameplay then
            ee_flame_gap_clock = nil   -- wieder beide da -> Karenz verfaellt
            if not ee_flame_clock then ee_flame_clock = os.clock() end
            if not ee_flame_fired and (os.clock() - ee_flame_clock) >= EE_FLAME_HOLD_SEC then
                ee_flame_fired = true
                grant_flamethrower_to_armoury()
            end
        elseif ee_flame_clock then
            -- [COMBO_GRACE] Wie beim Trigger-Menue: ein einzelner Frame ohne einen der beiden
            -- A-Buttons hat die vollen 5 s zurueckgeworfen. Kurze Aussetzer zaehlen nicht mehr.
            if not ee_flame_gap_clock then ee_flame_gap_clock = os.clock() end
            if (os.clock() - ee_flame_gap_clock) >= COMBO_GRACE_SEC then
                ee_flame_clock = nil
                ee_flame_fired = false
                ee_flame_gap_clock = nil
            end
        else
            ee_flame_fired = false
            ee_flame_gap_clock = nil
        end
    end

    if in_boat and not in_menu then
        -- L.JoystickClick → LS
        if l_joyclick then f.LS = true end

        -- L.Trigger → Aim Hold (LT)
        if l_trigger then f.LT = 1.0 end

        -- L.Grip → LB (Knife Ready) DIREKT wie alter Mod (roher Grip, kein Melee-Gate) + Holster on release
        local l_grip_boot = safe_digital(ACT.grip, left_joystick)
        if l_grip_boot then f.LB = true end
        if prev_l_grip and not l_grip_boot then vr_holster_knife = true end
        prev_l_grip = l_grip_boot

        -- L.AButton → BACK (Map)
        if l_abutton then f.BACK = true end

        -- L.BButton → Y
        if l_bbutton then f.Y = true end

        -- Pause/Menu
        if handle_pause then f.START = true end

        -- R.JoystickClick → B (Edge Detection)
        if edge_detect(edge_state.r_jc, r_joyclick) then f.B = true end

        -- R.Trigger → RT DIREKT (wie im alten developer-Mod: kein Aim-Gate im Boot; die native
        -- Boot-Steuerung braucht den Quick-Knife/Aim-Gating-Kram aus apply_rt_attack nicht).
        if r_trigger then f.RT = 1.0 end

        -- R.Grip → LB DIREKT wie alter Mod (roher Grip, kein bare-hands/Holster-Gate im Boot)
        if safe_digital(ACT.grip, right_joystick) then f.LB = true end

        -- R.AButton → A (Edge Detection)
        if edge_detect(edge_state.r_a, r_abutton) then f.A = true end

        -- R.BButton → X (Edge Detection)
        if edge_detect(edge_state.r_b, r_bbutton) then f.X = true end


    elseif in_throwsight and not in_menu then
        -- [THROWSIGHT] `and not in_menu`: bei offenem Menue greift der in_menu-Zweig (Navigation),
        -- nicht die Wurf-Buttons. Linker Stick bleibt AN (nativ durchgereicht) -> Ausweichen im
        -- Boot moeglich. Die frueher stoerende Kamera-Verschiebung kam aus
        -- firstperson.movement_stabilization (separat gesperrt / bei KS3 ohnehin inaktiv),
        -- NICHT vom nativen Stick -> kein Grund mehr, ihn hier zu sperren.

        -- L.Trigger → LB
        if l_trigger then f.LB = true end

        -- L.Grip → Aim Hold (LT)
        -- [ERST LOSLASSEN] Den ROHEN Grip zusaetzlich veroeffentlichen: das Latch darf sich nur loesen,
        -- wenn der Finger wirklich offen ist. An `f.LT` gemessen verfiel es zu frueh -- in der Holster-
        -- Zone wird der Grip zeitweise gar nicht auf LT gemappt, also war LT dort 0 trotz gedruecktem
        -- Grip (genau das war der Fall "geht ausser beim ersten Mal").
        local _lgrip = safe_digital(ACT.grip, left_joystick) and true or false
        _G.__vr_raw_l_grip = _lgrip
        if _lgrip then f.LT = 1.0 end

        -- L.AButton → B (Edge Detection)
        if edge_detect(edge_state.l_a_b, l_abutton) then f.B = true end

        -- L.BButton → Y
        if l_bbutton then f.Y = true end

        -- Pause/Menu
        if handle_pause then f.START = true end

        -- R.Trigger → LB
        if r_trigger then f.LB = true end

        -- R.Grip → LB (wie R.Trigger — beide werfen die Harpune). ROHER Grip, KEINE gameplay-gated
        -- right_grip_maps_to_gamepad: im Throwsight (Del-Lago) sind bare_hands/Holster/block_shoot_ready
        -- sinnlos und blockten den Harpunen-Wurf. Wie im Boot-Branch (roher Grip). [[menu_branch_no_gameplay_gating]]
        if safe_digital(ACT.grip, right_joystick) then f.LB = true end

        -- R.AButton → A (Edge Detection)
        if edge_detect(edge_state.r_a, r_abutton) then f.A = true end

        -- R.BButton → X (Edge Detection)
        if edge_detect(edge_state.r_b, r_bbutton) then f.X = true end


    elseif in_menu then
        -- [DODGE_PROMPT bei HUD-AUS 2026-07-17] Der Ausweich-Prompt landet hier statt im Gameplay-Branch:
        -- das Spiel blendet fuer diese Sequenz das HUD aus ("force look"), und get_IsHudOff zaehlt in
        -- is_any_menu_open als Menue. LIVE BELEGT (re4_dodge_diag, Stage 43302):
        -- PROMPT=JA lgrip=true ks=false menu=true -> Branch=MENU || paused=false hudOff=TRUE
        -- pauseLock=false case=false
        -- Also: kein echtes Menue, nur HUD aus. Prompt-Erkennung und Grip waren die ganze Zeit in Ordnung.
        --
        -- WARUM HIER und nicht vor dem Branch-Split: dort wuerde L.Grip->B AUCH im ECHTEN Menue feuern
        -- (B = Zurueck/Abbrechen -> man fliegt staendig aus dem Inventar). Genau die Falle, vor der der
        -- Kommentar im Gameplay-Zweig warnt ("der X-Mute, der mal das ganze Inventar lahmgelegt hat").
        -- is_any_menu_open(true) fragt "ist ein ECHTES Menue offen?" (alles ausser hudOff) -> nur wenn
        -- NEIN, gehoert der Grip dem Ausweichen. Pause/Koffer/Map/Typewriter bleiben damit unberuehrt.
        -- Reihenfolge: VOR "L.Grip -> LB" unten, damit f.LB gleich wieder abgeraeumt werden kann -- sonst
        -- kaeme zusaetzlich LB (Weapon-Ready) im Ausweich-Moment.
        -- KOSTEN: is_any_menu_open(true) wird dank Kurzschluss nur ausgewertet, wenn Prompt UND Grip
        -- anliegen -> ein paar Frames pro Kampf, nicht pro Menue-Frame.
        -- Der Gameplay-Zweig unten behaelt seinen eigenen Dodge-Code (dort ist hudOff=false).
        local dodge_hudoff = false
        -- [RECT_PROMPT 2026-07-22] Die zweite Aufforderung (c_btn_rect_anime, "<ICON CP11_HS-F>")
        -- laeuft mit demselben HUD-Aus -> sie landet ebenfalls HIER im Menue-Zweig, nicht im Gameplay-
        -- oder KS-Zweig. Deshalb dieselbe Behandlung wie beim Ausweichen, nur auf RB statt B.
        -- VOR dem Ausweich-Block: waehrend dieses Prompts trifft dessen Zustands-Gruppe ebenfalls zu.
        if is_rect_prompt_now() and l_grip_from_left and not is_any_menu_open(true) then
            dodge_hudoff = true      -- teilt sich das Flag: unten kein zusaetzliches LB
            f.RB = true
        elseif is_leon_lb_prompt_now() and l_grip_from_left and not is_any_menu_open(true) then
            dodge_hudoff = true      -- [LEON_LB_PROMPT] Leon: linker Grip = LB (statt Adas RB)
            f.LB = true
        elseif type(rawget(_G, "__re4_is_dodge_prompt")) == "function" and _G.__re4_is_dodge_prompt()
           and l_grip_from_left and not is_any_menu_open(true) then
            dodge_hudoff = true
            f.B = true
        end

        -- [SYMBOL_RIDDLE 2026-07-17] NUR im Symbol-Raetsel (is_symbol_riddle: Stage 44110 + GimmickFix-Busy-Cam):
        -- rechter Stick links -> Xbox LB, rechts -> Xbox RB. DAUERDRUCK, solange gekippt (kein Edge; so gewollt:
        -- Symbole wechseln). Additiv zu L.Grip->LB / R.Grip->RB unten. Das ECHTE Menue (symbol_riddle=false) bleibt
        -- unberuehrt -> dort blaettert der Stick weiter per DPAD-Shift (unten mit 'and not symbol_riddle' gegated).
        local symbol_riddle = is_symbol_riddle()
        if symbol_riddle then
            if vr_right_stick_axis.x <= -0.5 then f.LB = true
            elseif vr_right_stick_axis.x >= 0.5 then f.RB = true end
        end

        -- L.JoystickClick → LS
        if l_joyclick then f.LS = true end

        -- L.Trigger → LT (Left Trigger) + DPAD-Shift (L.Trigger + R-Stick → DPAD)
        if l_trigger then
            f.LT = 1.0
            -- [SYMBOL_RIDDLE] Im Raetsel gehoert der R-Stick den Bumpern (oben) -> hier KEIN DPAD (sonst Doppel).
            if not symbol_riddle then
                if vr_right_stick_axis.y >= 0.9 then f.DPAD_UP = true
                elseif vr_right_stick_axis.y <= -0.9 then f.DPAD_DOWN = true end
                if vr_right_stick_axis.x >= 0.9 then f.DPAD_RIGHT = true
                elseif vr_right_stick_axis.x <= -0.9 then f.DPAD_LEFT = true end
            end
            -- R-Stick waehrend des Shifts nicht ans Pad (sonst Doppel-Nav)
            f.RX = 0.0
            f.RY = 0.0
        end

        -- L.Grip → LB (Left Shoulder)
        -- [DODGE] Im Ausweich-Fenster (HUD aus, kein echtes Menue) gehoert der Grip dem B oben -> kein LB.
        if safe_digital(ACT.grip, left_joystick) and not dodge_hudoff then f.LB = true end

        -- L.AButton → B (Edge Detection)
        -- [LONG_LATCH] edge_detect immer aufrufen (State frisch halten), aber B unterdruecken solange
        -- der Longpress-Latch haelt (A wurde beim Map-Oeffnen noch gehalten) -> kein Sofort-Cancel.
        if edge_detect(edge_state.l_a_b, l_abutton) and not la_hold.long_consumed then f.B = true end

        -- L.BButton → Y
        if l_bbutton then f.Y = true end

        -- Pause/Menu
        if handle_pause then f.START = true end

        -- R.JoystickClick → RS
        if r_joyclick then f.RS = true end

        -- R.Trigger → RT (Right Trigger)
        if r_trigger then f.RT = 1.0 end

        -- R.Grip → RB (Right Shoulder). ROHER Grip wie L.Grip->LB drueber. KEINE gameplay-gated
        -- right_grip_maps_to_gamepad im Menue-Branch: deren Gates (bare_hands/holster/block_shoot_ready)
        -- gelten nur im Gameplay und blockten RB faelschlich im Inventar (bare hands).
        if safe_digital(ACT.grip, right_joystick) then f.RB = true end

        -- R.AButton → A
        if r_abutton then f.A = true end

        -- R.BButton → X (Edge Detection)
        if edge_detect(edge_state.r_b, r_bbutton) then f.X = true end


    elseif in_turret then
        -- [TURRET 2026-07-16] MG-Turret (InstalledMachineGun). Kopie der Gameplay-Bindings mit DREI Ausnahmen
        -- (so gewollt): (1) rechter Stick FREI in X UND Y, (2) rechter Trigger RAW durchgereicht (kein Messer-/
        -- Granaten-Gating), (3) Links-A = Xbox-B (Feuer) statt Map/Longpress. Der Rest ist wie Gameplay.
        -- REIHENFOLGE: steht VOR ks_active -> uebersteuert die KS1 (camstate:15/Gimmick), in der die Turret sonst
        -- haengt (Stick gelockt, L.A=Map, RT gegated). Steht NACH in_menu -> oeffnet man mittendrin ein Menue,
        -- greift der Menue-Branch (kein Stale, jeder Frame frisch ausgewertet). Andere Ausnahmen (Boot/Throwsight)
        -- sind andere Gimmicks/Stages -> nie gleichzeitig, bleiben unberuehrt.

        -- (1) Rechter Stick FREI: roh durchreichen. Die Post-Branch-Locks (RY-Lock / KS2-Lock) sind unten fuer
        -- in_turret exemptet, sonst wuerde der RY sofort wieder auf 0 gezogen.
        f.RX = vr_right_stick_axis.x or 0.0
        f.RY = vr_right_stick_axis.y or 0.0

        -- L.JoystickClick → LS [wie Gameplay]
        if l_joyclick then f.LS = true end
        -- L.Trigger → DPAD Shift (Hold) [wie Gameplay]
        apply_dpad_shift()
        -- L.Grip → Knife Ready (LB) [wie Gameplay]
        apply_l_grip_knife()
        -- (3) L.AButton → Xbox-B (Feuer) statt Map/Longpress
        if l_abutton then f.B = true end
        -- L.BButton → Y [wie Gameplay]
        if l_bbutton then f.Y = true end
        -- Pause/Menu [wie Gameplay]
        if handle_pause then f.START = true end
        -- R.JoystickClick → B [wie Gameplay]
        if r_joyclick then f.B = true end
        -- (2) R.Trigger RAW → RT (durchgereicht; RT-Mutes greifen hier eh nicht, __re4_frame_is_gameplay=false)
        if r_trigger then f.RT = 1.0 end
        -- R.Grip → Holster-Melee LB | Aim LT [wie Gameplay]
        apply_r_grip_aim()
        -- R.AButton → A [wie Gameplay]
        if r_abutton then f.A = true end
        -- R.BButton → X [wie Gameplay]
        if r_bbutton then f.X = true end

    elseif in_jetski then
        -- [JETSKI 2026-07-16] Jetski-Fahrt (KS4, Stages 592xx aus dem killswitch). Steht VOR ks_active
        -- -> Jetski IST KS4 (ks_active=true) und wuerde sonst vom KS-Branch geschluckt (Stick gelockt,
        -- RT gegated). NACH in_menu -> Menue mitten im Jetski greift normal. Die Post-Branch-Locks
        -- (RY-Lock / KS2-Lock) sind fuer in_jetski exemptet -> dieser Branch ist die EINZIGE Quelle der
        -- Stick-Achsen im Jetski.
        --
        -- STEUERUNG (so gewollt): BEIDE Sticks wirken als normaler LINKER Stick (volle Boot-Steuerung).
        -- Der linke Stick ist normal, der rechte ist eine KOPIE davon. Pro Achse gewinnt der staerker
        -- ausgelenkte -> mit beiden Haenden steuerbar, Neutralstellung des einen stoert den anderen nicht.
        -- Die rechten Kamera-Achsen sind tot (Blick kommt in VR vom Kopf/HMD).
        -- R.Trigger wird RAW durchgereicht (kein Messer-/Granaten-Gating).
        local jx_l = vr_left_stick_axis.x or 0.0
        local jy_l = vr_left_stick_axis.y or 0.0
        local jx_r = vr_right_stick_axis.x or 0.0
        local jy_r = vr_right_stick_axis.y or 0.0
        f.LX = (math.abs(jx_r) > math.abs(jx_l)) and jx_r or jx_l   -- betragsgroesser gewinnt
        f.LY = (math.abs(jy_r) > math.abs(jy_l)) and jy_r or jy_l
        f.RX = 0.0
        f.RY = 0.0

        -- L.JoystickClick → LS
        if l_joyclick then f.LS = true end
        -- L.Trigger → DPAD Shift (Hold)
        apply_dpad_shift()
        -- L.Grip → Knife Ready (LB)
        apply_l_grip_knife()
        -- L.AButton → BACK (Map)
        if l_abutton then f.BACK = true end
        -- L.BButton → Y
        if l_bbutton then f.Y = true end
        -- Pause/Menu
        if handle_pause then f.START = true end
        -- R.JoystickClick → B
        if r_joyclick then f.B = true end
        -- (2) R.Trigger RAW → RT (durchgereicht, kein Gating)
        if r_trigger then f.RT = 1.0 end
        -- R.Grip → Holster-Melee LB | Aim LT
        apply_r_grip_aim()
        -- R.AButton → A
        if r_abutton then f.A = true end
        -- R.BButton → X
        if r_bbutton then f.X = true end

    elseif ks_active then
        -- KILLSWITCH: wie Gameplay, aber ohne Longpress/Edges
        -- L.JoystickClick → LS
        if l_joyclick then f.LS = true end

        -- L.Trigger → DPAD Shift (Hold)
        apply_dpad_shift()

        -- L.Grip → Knife Ready (LB)
        apply_l_grip_knife()

        -- [DODGE_GIMMICK 2026-07-22] Ausweich-Fenster (Stage 60871 + Occupied 23 +
        -- GimmickOperate-Kamera): linker Grip feuert B = Ausweichen. Rein ADDITIV -- es wird nichts
        -- geblockt, ausserhalb des Fensters bleibt der Grip unveraendert. Der Zustands-Check laeuft
        -- nur, wenn der Grip gedrueckt ist (Kurzschluss), kostet also nicht jeden Frame Lookups.
        -- [RECT_PROMPT 2026-07-22] Zweite Aufforderung derselben Stelle -> linker Grip = RB.
        -- Vorrang vor dem Ausweichen, damit nie beide Knoepfe gleichzeitig feuern (die Zustands-Gruppe
        -- des Ausweichens trifft waehrend dieses Prompts ebenfalls zu).
        if l_grip_from_left then
            if is_rect_prompt_now() then f.RB = true
            elseif is_leon_lb_prompt_now() then f.LB = true
            elseif is_dodge_gimmick_now() then f.B = true end
        end

        -- L.AButton → BACK (Map)
        if l_abutton then f.BACK = true end

        -- L.BButton → Y
        if l_bbutton then f.Y = true end

        -- Pause/Menu
        if handle_pause then f.START = true end

        -- R.JoystickClick → B
        if r_joyclick then f.B = true end

        -- R.Trigger/Motion → RT
        apply_rt_attack()

        -- R.Grip → Holster-Melee LB | Aim LT
        apply_r_grip_aim()

        -- R.AButton → A
        if r_abutton then f.A = true end

        -- R.BButton → X
        -- [KS_X_FLANKE 2026-08-18] Frueher PEGEL (`if r_bbutton then ...`) -- damit ging X in JEDEM
        -- KS-Frame neu raus, solange der Knopf gedrueckt war. Genau das ist die Falle beim Uebergang
        -- Cutscene -> Gameplay: die Engine ist im Zweifel schon frueher im Gameplay als unser
        -- ks_active, und ein gehaltenes X wird dort zum NATIVEN RELOAD. Jetzt wie in den Zweigen
        -- Boot/Throwsight/Menue (Z.2191/2234/2330) ueber edge_detect -> ein kurzer Impuls pro Druck
        -- statt Dauerdruck; das Fenster schrumpft von "solange gehalten" auf EDGE_HOLD_FRAMES.
        -- Nebeneffekt (gewollt): edge_state.r_b wird jetzt auch im KS mitgefuehrt, dadurch gilt ein
        -- durchgehend gehaltener Knopf nach dem Zweigwechsel nicht mehr als frische Flanke.
        if edge_detect(edge_state.r_b, r_bbutton) then f.X = true end


    elseif in_binoculars then
        -- BINOCULARS: Gameplay-Bindings, aber L.Stick = Zoom (genullt),
        -- R.Stick ×2.0 Sensitivity
        f.LX, f.LY = 0.0, 0.0
        f.RX = (vr_right_stick_axis.x or 0) * 2.0
        f.RY = (vr_right_stick_axis.y or 0) * 2.0

        -- L.JoystickClick → LS
        if l_joyclick then f.LS = true end

        -- L.Trigger → DPAD Shift (liest die ROHE R-Stick-Achse)
        apply_dpad_shift()

        -- L.Grip → Knife Ready (LB)
        apply_l_grip_knife()

        -- L.AButton → BACK (Map)
        if l_abutton then f.BACK = true end

        -- L.BButton → Y
        if l_bbutton then f.Y = true end

        -- Pause/Menu
        if handle_pause then f.START = true end

        -- R.JoystickClick → B
        if r_joyclick then f.B = true end

        -- R.Trigger/Motion → RT
        apply_rt_attack()

        -- R.Grip → Holster-Melee LB | Aim LT
        apply_r_grip_aim()

        -- R.AButton → A
        if r_abutton then f.A = true end

        -- R.BButton → X
        if r_bbutton then f.X = true end


    -- ===================================================================
    -- GAMEPLAY (MERCENARIES) [MERC_GAMEPLAY_BRANCH 2026-08-03]
    -- ===================================================================
    -- Eigener Gameplay-Zweig fuer den Mercenaries-DLC. ALLE sechs Charaktere
    -- teilen ihn (ausdruecklicher Wunsch: "da koennen ruhig alle Charaktere
    -- dieselben Bindings haben"). AKTUELL EINE 1:1-KOPIE von Leons Zweig ganz
    -- unten -- bewusst, damit sich beim Anlegen NICHTS aendert. Mercs-eigene
    -- Bindings kommen ab jetzt NUR hier rein; Leon und Ada bleiben unberuehrt.
    --
    -- Steht bewusst VOR dem Ada-Zweig: in Mercs ist Ada ebenfalls spielbar
    -- (KindID 380000 / ch3a8z0_MC_body). Stuende Ada zuerst, landete sie im
    -- Kampagnen-Zweig von Separate Ways.
    --
    -- Erkennung ueber __re4_in_mercs (re4_vr_merc.lua, ueber
    -- MercenariesManager.get_GuiManager). Ist das Script nicht geladen, ist
    -- das Global nil -> der Zweig ist schlicht nie aktiv, alles wie vorher.
    elseif is_mercs_active() then
        -- GAMEPLAY (MERCENARIES)
        if bino_zoom.active then
            bino_zoom.active = false
            bino_zoom.offset = 0.0
        end

        -- L.JoystickClick → LS
        if l_joyclick then f.LS = true end

        -- L.Trigger → DPAD Shift (Hold)
        apply_dpad_shift()

        -- L.Grip → Knife Ready (LB)
        apply_l_grip_knife()

        -- [MERC_LA_STICKS 2026-08-03] In Mercenaries hat Links-A WEDER Short- NOCH
        -- Longpress (kein Ashley-Befehl, keine Map ueber Halten). Stattdessen loest die
        -- Taste BEIDE Stick-Klicks gleichzeitig aus: RS + LS in einem Druck.
        -- Bei der Easter-Egg-Geste (beide A gehalten) bleibt sie stumm -- wie ueberall.
        --
        -- la_hold wird hier bewusst leergehalten: die Timer-Zweige HINTER dem Branch-Split
        -- lesen es weiter, und ein stehengebliebener Zaehler wuerde spaeter ein Phantom-BACK
        -- oder -RS ausloesen (dieselbe Falle wie im Ada-Zweig).
        if l_abutton and not both_a then
            f.RS = true
            f.LS = true
        end
        la_hold.pressed = false
        la_hold.frames = 0
        la_hold.fired_long = false

        -- L.BButton → Y
        if l_bbutton then f.Y = true end

        -- Pause/Menu
        if handle_pause then f.START = true end

        -- R.JoystickClick → B
        if r_joyclick then f.B = true end

        -- Prompt-Kette am linken Grip (Rect > LB > Ausweichen > Gimmick), wie bei Leon
        apply_prompt_grip(f, l_grip_from_left)

        -- R.Trigger/Motion → RT
        apply_rt_attack()

        -- R.Grip → Holster-Melee LB | Aim LT
        apply_r_grip_aim()

        -- R.AButton → A (unterdrueckt waehrend Easter-Egg-Geste beide A)
        if r_abutton and not both_a then f.A = true end

        -- [X_TOT_IM_GAMEPLAY] R.BButton → X bleibt AUS, exakt wie bei Leon und Ada:
        -- X gehoert im Gameplay komplett uns (Mag-Drop/Klappe/Trommel), der native
        -- Reload darf nie feuern.
        -- if r_bbutton then f.X = true end
        --
        -- [BOW_NATIVE_X 2026-08-05] EINE Ausnahme: der Compound Bow (6304) hat KEINEN
        -- manuellen Ladeweg (in re4_vr_reload.lua steht nur sein Name) -- er laedt nativ, also
        -- braucht genau diese Waffe das Xbox-X. Damit nichts durchflimmert:
        -- * edge_detect wird IMMER gerufen (auch wenn die Waffe nicht passt), sonst bleibt
        -- state.prev auf true haengen und die naechste Flanke faellt aus;
        -- es liefert einen sauberen kurzen Tastendruck (EDGE_HOLD_FRAMES) statt Dauerdruck.
        -- * nur im reinen Gameplay, nur mit gezogenem Bogen, nie waehrend der Easter-Egg-Geste
        -- (beide A) und nie mit Messer in der Hand (das muted X weiter unten ohnehin).
        -- * ist B von einem Reload-Modul konsumiert, ist r_bbutton oben schon false.
        local r_b_edge = edge_detect(edge_state.r_b, r_bbutton)
        if r_b_edge and not both_a
            and rawget(_G, "__vr_dbg_wep_id") == 6304
            and rawget(_G, "__re4_frame_pure_gameplay") == true
            and rawget(_G, "__re4_knife_equipped") ~= true then
            f.X = true
        end

    -- ===================================================================
    -- GAMEPLAY (ADA / SEPARATE WAYS) [DLC_GAMEPLAY_BRANCH 2026-07-19]
    -- ===================================================================
    -- Eigener Gameplay-Zweig fuer Ada. AKTUELL EINE 1:1-KOPIE von Leons Zweig
    -- darunter -- bewusst, damit sich beim Anlegen NICHTS aendert. Ab jetzt
    -- koennen hier Ada-spezifische Bindings eingebaut werden, ohne Leon zu
    -- beruehren; sein Zweig bleibt unveraendert der else-Fall.
    --
    -- ALLE ANDEREN BRANCHES (Boot/Throwsight/Menue/Turret/Jetski/KS/Fernglas)
    -- bleiben bewusst GEMEINSAM -- nur Gameplay ist gesplittet.
    --
    -- HINWEIS: greift is_ada_active fuer einen Frame daneben (Body kurz weg),
    -- laeuft Ada in Leons Zweig. Solange beide identisch sind, faellt das nicht
    -- auf; sobald hier Ada-eigene Bindings stehen, gehoert die Erkennung auf das
    -- sticky __re4_char_now umgestellt.
    elseif is_ada_active() then
        -- GAMEPLAY (ADA)
        if bino_zoom.active then
            bino_zoom.active = false
            bino_zoom.offset = 0.0
        end

        -- L.JoystickClick → LS
        if l_joyclick then f.LS = true end

        -- L.Trigger → DPAD Shift (Hold)
        apply_dpad_shift()

        -- L.Grip → Knife Ready (LB)
        apply_l_grip_knife()

        -- [ADA_LA 2026-07-21] Ada braucht keinen Ashley-Befehl -> ihr linkes A ist DIREKT
        -- Xbox-BACK (Select/Karte), ohne Longpress und ohne Shortpress-Timer. Leons Zweig behaelt
        -- seinen Longpress unveraendert (kurz = Ashley, lang = Karte).
        -- Der la_hold-Zustand wird hier bewusst leer gehalten: die Timer-Zweige nach dem Branch-Split
        -- lesen ihn weiter, und ein stehengebliebener Zaehler wuerde spaeter ein Phantom-BACK/RS
        -- ausloesen (genau die Falle beim Verlassen des Haendlers).
        if l_abutton and not both_a then f.BACK = true end
        la_hold.pressed = false
        la_hold.frames = 0
        la_hold.fired_long = false

        -- L.BButton → Y
        if l_bbutton then f.Y = true end

        -- Pause/Menu
        if handle_pause then f.START = true end

        -- [DUAL_TRIGGER_MENU] Entfernt: lief nur hier im Gameplay-Branch und feuerte dauerhaft. Die
        -- globale Edge-Version (Pre-Branch + Anwendung unten, ~Z.1525) deckt ALLE Branches ausser Menue ab.

        -- R.JoystickClick → B
        if r_joyclick then f.B = true end

        -- [PROMPT_GRIP 2026-07-31] Ersetzt die beiden frueheren Bloecke ([DODGE_PROMPT 2026-07-15]
        -- und [DODGE_GIMMICK/RECT_PROMPT 2026-07-22]) durch EINEN Aufruf. Zwei Aenderungen im Verhalten:
        -- 1. EINE Prioritaetskette (Rect > LB > Ausweichen > Gimmick-Fenster) statt zwei Bloecke, die
        -- gleichzeitig feuern konnten (bei Leons LB-Prompt gingen B UND LB raus).
        -- 2. Einmal-Impuls statt Dauer-B, und "Ausweichen" wird ueber c_btn_circle_anime positiv belegt
        -- statt ueber den geteilten Container Gui_ui2191_3 -> kein Crouch mehr aus dem Nichts.
        -- Die alten Sicherungen gelten unveraendert: dieser Branch laeuft im Menue/Boot/Throwsight/KS gar
        -- nicht erst, alle Zuend-Bedingungen sind 0.15s-Frische-Fenster (nichts kann haengenbleiben), und
        -- L.Grip setzt im Gameplay sonst kein f.XXX (apply_l_grip_knife ist no-op).
        apply_prompt_grip(f, l_grip_from_left)

        -- R.Trigger/Motion → RT
        apply_rt_attack()

        -- R.Grip → Holster-Melee LB | Aim LT
        apply_r_grip_aim()

        -- R.AButton → A (unterdrueckt waehrend Easter-Egg-Geste beide A)
        -- [ADA_A_LONGPRESS 2026-07-20] Rechtes A: KURZ druecken = Xbox A, LANG halten = RB (Grapple).
        -- Ersetzt den Doppeltipp (ging in der Praxis nicht sauber). Mechanik wie beim L.A-Longpress:
        -- * Beim Halten passiert erstmal NICHTS -- A wird bis zum Loslassen zurueckgehalten.
        -- * Loslassen VOR der Schwelle -> A wird als kurzer Impuls (10 Frames) nachgereicht.
        -- * Schwelle erreicht, ohne loszulassen -> RB feuert sofort (20 Frames) und das A entfaellt.
        -- State als Global (binding.lua sitzt nah am 200-Local-Limit), Schwelle live tunbar:
        -- _G.__re4_ada_a_long_sec (Default 0.35 s). Nur in DIESEM Branch -- Leons Zweig hat weiter nur f.A.
        -- [ADA_A 2026-07-20] Rechtes A: KURZ druecken = Xbox A, LANG halten = RB (Greifhaken).
        -- Da A und RB auf DEMSELBEN Knopf liegen, kann A erst beim Loslassen entschieden werden --
        -- vorher weiss niemand, ob es kurz oder lang wird. A wird deshalb als kurzer Impuls nachgereicht.
        -- SAUBERES DESIGN (nach Doppel-Interakt an Tuer und Haendler, Befund):
        -- 1) IMPULS KURZ (4 Frames statt 10): ein langer Impuls wirkt wie "gedrueckt halten" und das
        -- Spiel macht daraus zwei Interaktionen (Tuer-Anim lief zweimal).
        -- 2) COOLDOWN: nach einem ausgeloesten A fuer 0.25 s kein weiteres -- kein Nachfeuern.
        -- 3) ZUSTAND IMMER PFLEGEN: st.prev wird auch ausserhalb dieses Zweiges aktualisiert (Menue-Block
        -- weiter oben). Sonst gilt ein noch gehaltener Knopf beim Branch-Wechsel als FRISCHE Presse
        -- und loest ein zweites A aus -- genau das passierte beim Verlassen des Haendlers.
        -- Schwelle live tunbar: _G.__re4_ada_a_long_sec (Default 0.35 s). Darunter = normaler Shortpress.
        do
            local st = rawget(_G, "__re4_ada_ra")
            if type(st) ~= "table" then st = {}; _G.__re4_ada_ra = st end
            local now = os.clock()
            local hold = tonumber(rawget(_G, "__re4_ada_a_long_sec")) or 0.35
            -- [ADA_A_RAW_ZONE 2026-07-20] In der Zone A 1:1 durchreichen (Spiel verlangt langes A).
            -- Zustand trotzdem pflegen, sonst gilt ein gehaltener Knopf beim Verlassen als frische Presse.
            if is_ada_raw_a_zone() then
                if r_abutton and not both_a then f.A = true end
                st.prev = r_abutton; st.down_t = nil; st.fired_rb = false
                st.a_timer = 0; st.rb_timer = 0
                st.a_until = 0; st.rb_until = 0
            elseif r_abutton and not st.prev then
                st.down_t = now; st.fired_rb = false
            elseif r_abutton and st.down_t and not st.fired_rb and (now - st.down_t) >= hold then
                st.fired_rb = true
                st.rb_timer = 20                      -- Longpress -> RB (Greifhaken), KEIN A
                st.rb_until = now + 0.22              -- [ADA_A_IMPULS_DEADLINE] siehe unten
            elseif (not r_abutton) and st.prev then
                -- Loslassen: war es kurz genug UND liegt der letzte Impuls lange genug zurueck -> A
                if not st.fired_rb and (now - (st.last_a or -999)) > 0.25 then
                    st.a_timer = 4
                    st.a_until = now + 0.10           -- [ADA_A_IMPULS_DEADLINE]
                    st.last_a  = now
                end
                st.down_t = nil; st.fired_rb = false
            end
            st.prev = r_abutton
            -- [ADA_A_IMPULS_DEADLINE 2026-07-20 -- per re4_zzz_ada_a_dump BEWIESEN] Die Impuls-
            -- Timer sind FRAME-Zaehler und ticken nur, wenn dieser Zweig laeuft. Waehrend des
            -- Killswitchs (Haken-Fahrt) laeuft er nicht -> der RB-Impuls fror bei 15 ein und wurde
            -- SEKUNDEN spaeter drueben weitergereicht: der Haken feuerte ein zweites Mal (im Log
            -- ueber 5435.8 -> 5438.9 -> 5441.6 verteilt, firedRB dabei laengst false).
            -- FIX: zusaetzliche ZEIT-Deadline. Frames bleiben als Untergrenze (FPS-Einbruch soll den
            -- Impuls nicht verschlucken), aber nach Ablauf der Deadline ist er ersatzlos tot.
            if (st.a_timer or 0) > 0 and now > (st.a_until or 0) then st.a_timer = 0 end
            if (st.rb_timer or 0) > 0 and now > (st.rb_until or 0) then st.rb_timer = 0 end
            if (st.a_timer or 0) > 0 and not both_a then f.A = true; st.a_timer = st.a_timer - 1 end
            if (st.rb_timer or 0) > 0 then f.RB = true; st.rb_timer = st.rb_timer - 1 end
        end

        -- [X_TOT_IM_GAMEPLAY 2026-07-31] R.BButton → X hier ENTFERNT (Ada-Gameplay).
        -- Im Gameplay hat X ausschliesslich von UNS vergebene Aufgaben (Mag-Drop, Klappe/Trommel,
        -- Slide) -- jede nachladbare Waffe ist von einem Reload-Modul verwaltet, der native Reload
        -- ist nie erwuenscht. Bisher hing das allein am Per-Frame-Flag __vr_manual_reload_consume_b
        -- (:1238): war es fuer EINEN Frame false (HUD-aus zaehlt dort als Menue, Waffenwechsel-/
        -- Zieh-Frame), ging der rohe B als Xbox-X raus und die Engine spielte ihre eigene Reload-Anim
        -- ("kommt in hektischen Situationen manchmal durch", Playtester). Kein Gate mehr, kein Rennen.
        -- ALLE anderen Branches (Menue/Boot/Throwsight/Turret/Jetski/KS/Fernglas) bleiben unveraendert
        -- -- dort ist X legitim (Move Item / Inventar).
        -- if r_bbutton then f.X = true end
    else
        -- GAMEPLAY
        if bino_zoom.active then
            bino_zoom.active = false
            bino_zoom.offset = 0.0
        end

        -- L.JoystickClick → LS
        if l_joyclick then f.LS = true end

        -- L.Trigger → DPAD Shift (Hold)
        apply_dpad_shift()

        -- L.Grip → Knife Ready (LB)
        apply_l_grip_knife()

        -- L.AButton → Longpress. [1:1 BASIS 2026-07-20] Ada laeuft BEWUSST exakt wie Leon:
        -- Short = CMD Ashley (RS), Long = Map (BACK). Der frueher hier aktive Ada-Sonderfall
        -- (Short = RB/Grapple, Long = Map) ist damit AUS -- erst eine stabile gemeinsame Basis,
        -- Abweichungen kommen spaeter bewusst in den Ada-Gameplay-Branch. Zum Reaktivieren:
        -- ada_mode wieder auf is_ada_active setzen (die Timer-Zweige unten lesen es weiterhin).
        local ada_mode = false
        -- [LA_TIMING] Schwellen aus dem UI (Sekunden -> Frames @ ~90fps). long = Halten bis Longpress;
        -- short_min = Mindest-Haltezeit fuer einen gueltigen Shortpress-Tap.
        local long_frames = math.floor((tonumber(PREFS.long_press_sec) or 1.5) * 90 + 0.5)
        if long_frames < 3 then long_frames = 3 end
        local short_min_frames = math.floor((tonumber(PREFS.short_min_sec) or 0.0) * 90 + 0.5)
        if both_a then
            -- Easter-Egg-Geste (beide A) laeuft: L.A-Longpress/Short unterdruecken
            la_hold.pressed = false
            la_hold.frames = 0
            la_hold.fired_long = false
        elseif l_abutton then
            if not la_hold.pressed then
                la_hold.pressed = true
                la_hold.frames = 0
                la_hold.fired_long = false
            end
            la_hold.frames = la_hold.frames + 1
            if la_hold.frames >= long_frames and not la_hold.fired_long then
                -- 20-Frame-Halte-Timer (wie beim Short), damit BACK sicher registriert
                la_hold.long_timer = 20
                la_hold.long_is_ada = ada_mode
                la_hold.fired_long = true
                -- [LONG_LATCH] A ist beim Ausloesen NOCH gehalten. Sobald BACK die Map oeffnet, wird
                -- in_menu true -> der Menue-Branch mappt das gehaltene Links-A auf B (=Cancel) und
                -- schliesst die Map sofort. Latch bis A losgelassen -> Links-A im Menue unterdrueckt.
                la_hold.long_consumed = true
            end
        else
            -- [LA_TIMING] Short nur, wenn der Tap lang genug gehalten wurde (short_min) und kein Long feuerte.
            if la_hold.pressed and not la_hold.fired_long and la_hold.frames >= short_min_frames then
                la_hold.short_timer = 20
                la_hold.short_is_ada = ada_mode
            end
            la_hold.pressed = false
            la_hold.frames = 0
            la_hold.fired_long = false
        end

        -- L.BButton → Y
        if l_bbutton then f.Y = true end

        -- Pause/Menu
        if handle_pause then f.START = true end

        -- [DUAL_TRIGGER_MENU] Entfernt: lief nur hier im Gameplay-Branch und feuerte dauerhaft. Die
        -- globale Edge-Version (Pre-Branch + Anwendung unten, ~Z.1525) deckt ALLE Branches ausser Menue ab.

        -- R.JoystickClick → B
        if r_joyclick then f.B = true end

        -- [PROMPT_GRIP 2026-07-31] Ersetzt die beiden frueheren Bloecke ([DODGE_PROMPT 2026-07-15]
        -- und [DODGE_GIMMICK/RECT_PROMPT 2026-07-22]) durch EINEN Aufruf. Zwei Aenderungen im Verhalten:
        -- 1. EINE Prioritaetskette (Rect > LB > Ausweichen > Gimmick-Fenster) statt zwei Bloecke, die
        -- gleichzeitig feuern konnten (bei Leons LB-Prompt gingen B UND LB raus).
        -- 2. Einmal-Impuls statt Dauer-B, und "Ausweichen" wird ueber c_btn_circle_anime positiv belegt
        -- statt ueber den geteilten Container Gui_ui2191_3 -> kein Crouch mehr aus dem Nichts.
        -- Die alten Sicherungen gelten unveraendert: dieser Branch laeuft im Menue/Boot/Throwsight/KS gar
        -- nicht erst, alle Zuend-Bedingungen sind 0.15s-Frische-Fenster (nichts kann haengenbleiben), und
        -- L.Grip setzt im Gameplay sonst kein f.XXX (apply_l_grip_knife ist no-op).
        apply_prompt_grip(f, l_grip_from_left)

        -- R.Trigger/Motion → RT
        apply_rt_attack()

        -- R.Grip → Holster-Melee LB | Aim LT
        apply_r_grip_aim()

        -- R.AButton → A (unterdrueckt waehrend Easter-Egg-Geste beide A)
        if r_abutton and not both_a then f.A = true end

        -- [X_TOT_IM_GAMEPLAY 2026-07-31] R.BButton → X hier ENTFERNT (Leon-Gameplay).
        -- Begruendung identisch zum Ada-Zweig oben: X gehoert im Gameplay komplett uns, der native
        -- Reload soll NIE feuern. Nebenwirkung (bewusst): ist eine Kategorie in der Reload-Config
        -- ausgeschaltet (category_enabled in handled, re4_vr_reload.lua:1242), laesst sich diese
        -- Waffe im Gameplay gar nicht mehr nachladen -- Nachladen kommt dann nur ueber die Geste.
        -- if r_bbutton then f.X = true end
    end

    -- [DUAL_TRIGGER_MENU] Beide Trigger 3s → START (Hauptmenü), in ALLEN Branches AUSSER Menue
    -- (dort ist man schon drin -> START wuerde es nur wieder schliessen/togglen).
    -- [START_HOLD 2026-08-11] Nicht mehr ein einzelner Frame: der Edge startet einen Timer,
    -- und solange der laeuft, liegt START an (wie der L.AButton-Longpress weiter unten).
    -- Das `not in_menu` bleibt pro Frame stehen -- sobald das Menue oben ist, hoert es von
    -- selbst auf zu senden und togglet nichts wieder zu.
    if dual_trigger_start then start_hold_timer = START_HOLD_FRAMES end
    if start_hold_timer > 0 then
        if not in_menu then f.START = true end
        start_hold_timer = start_hold_timer - 1
    end

    -- L.AButton Short Press timer (läuft außerhalb der Branches)
    if la_hold.short_timer > 0 then
        if la_hold.short_is_ada then
            f.BACK = true   -- Ada short press = Map (getauscht mit long)
        else
            f.RS = true     -- Leon short press = CMD Ashley (getauscht mit long)
        end
        la_hold.short_timer = la_hold.short_timer - 1
    end

    -- L.AButton Long Press timer (läuft außerhalb der Branches, hält Taste 20 Frames)
    -- EXAKT der bewährte Shortpress-Mechanismus: 20 Frames f.BACK feuern, sonst nichts.
    if (la_hold.long_timer or 0) > 0 then
        if la_hold.long_is_ada then
            f.RB = true     -- Ada long press = RB/Grapple
        else
            f.BACK = true   -- Leon long press = Map (identisch zum alten Shortpress-BACK)
        end
        la_hold.long_timer = la_hold.long_timer - 1
    end

    -- [BACK_GUARD] Solange das aus dem Menue gehaltene Links-A nicht losgelassen wurde: JEDES BACK
    -- schlucken (deckt KS-Branch-Direkt-BACK UND Longpress-Timer ab) -> kein Sprung in die Map.
    if la_hold.back_guard then f.BACK = false end

    -- [KS_X_GUARD] Ein X-Druck, der im Killswitch begonnen hat, wird ab dem Moment geschluckt, in dem
    -- der KS vorbei ist -- im KS selbst soll X weiter wirken, deshalb das `not ks_active`. Deckt jeden
    -- Zweig ab, der nach dem KS drankommt (Gameplay/Mercs-Bogen/Turret/Jetski/Bino/Boot/Menue), weil
    -- diese Zeile NACH allen Branches steht. Freigabe: physisches Loslassen (direkt darunter).
    if la_hold.ks_x_guard and not ks_active then f.X = false end

    -- [LONG_LATCH] Latch loesen sobald A physisch losgelassen ist — auch wenn wir gerade im Menue/Map
    -- sind (dort laeuft der Gameplay-Release-Zweig nicht). Danach ist Links-A = B/Cancel wieder frei.
    if not l_abutton then la_hold.long_consumed = false; la_hold.back_guard = false end
    -- [KS_X_GUARD] Latch loesen, sobald der rechte B PHYSISCH los ist (roher Wert, nicht der vom
    -- Reload-Modul konsumierte) -- danach ist der naechste Druck wieder ein ganz normaler.
    if rawget(_G, "__vr_raw_r_bbutton") ~= true then la_hold.ks_x_guard = false end

    -- RY-Lock (wie RE9): Pitch kommt vom HMD, rechter Stick-Y wird gesperrt.
    -- DPAD-Shift liest die rohe Achse und bleibt unberührt.
    -- Ausnahmen: _G.__vr_unlock_ry = true gibt die Achse frei; im Menue ist
    -- der rechte Stick ein normaler Stick (Navigation) -> RY nicht sperren.
    -- [THROWSIGHT] Del-Lago-Harpune: Y-Achse ans native Spiel durchreichen (hoch/runter zielen).
    -- [BINOCULAR] Fernglas-Zoom: rechter Stick-Y frei -> Pitch mit dem Stick (Kopf bleibt entkoppelt).
    -- [ADA_PITCH_GUI] Ada + Gui_ui2022 sichtbar -> RY frei (siehe ada_pitch_free oben). Leon unberuehrt.
    if rawget(_G, "__vr_unlock_ry") ~= true and not in_menu and not in_throwsight and not in_binoculars
       and not rawget(_G, "__re4_at_cannon") and not in_turret and not in_jetski
       and not ada_pitch_free() then
        f.RY = 0.0
    end

    -- [KS2_STICK_LOCK 2026-07-15] Bei JEDEM KS2 den rechten Stick KOMPLETT sperren -- also auch der YAW
    -- (RX), der sonst als einzige Achse noch durchgeht (RY ist oben schon gesperrt: Pitch kommt vom HMD).
    -- KS2 = First-Person + Body sichtbar, Quelle sind fast nur die ~155 KS2-Zonen aus
    -- re4_vr_killswitch_zones.json (KS2_CAM_STATES ist leer) -> dort soll sich die Kamera gar nicht per
    -- Stick drehen lassen.
    -- DIESELBEN AUSNAHMEN WIE DER RY-LOCK DARUEBER -- alle drei sind noetig, nicht kuerzen:
    -- in_menu -> dort ist der rechte Stick ein normaler Navigations-Stick. Ohne diesen Schutz
    -- waere die Menue-Navigation tot, sobald man AUS einer KS2-Zone das Menue oeffnet
    -- (dieselbe Falle wie beim X-Mute, s. [[Notiz]]).
    -- in_throwsight -> Del-Lago-Harpune LAEUFT SELBST ALS KS2 (killswitch ~1353: activating_reason
    -- "throwsight_ks2", seit dem KS3->KS2-Umbau 2026-07-15). Ohne diese Ausnahme
    -- sperrt dieser Block dort das Zielen komplett -> Bosskampf unspielbar.
    -- in_binoculars -> Fernglas braucht den Stick fuer Pitch/Zoom (Kopf ist entkoppelt).
    -- AUS: diesen Block loeschen -> Yaw ist im KS2 wieder frei.
    -- [KS4_STICK_LOCK 2026-07-19] Zusaetzlich zu KS2 auch bei JEDEM KS4 den rechten Stick komplett sperren
    -- (Yaw RX + Pitch RY). KS4 = passive Fahr-/Sonderfaelle (Aufzug 59100, ElevatorTrouble, Gondel, Minecart,
    -- Ashley-Carry,...) -> movement laeuft nicht, der Body dreht eh nicht mit; hier soll sich auch die native
    -- Cam nicht per Stick drehen. DIESELBEN AUSNAHMEN: Jetski/Turret zielen per Stick (in_jetski/in_turret),
    -- Boot gibt den Stick unten (boat_active) wieder frei -> alle drei bleiben spielbar.
    -- [KS4_STICK_EXEMPT 2026-07-19] NACHTRAG: throwsight / Boot / Minecart sind zwar KS4(bzw. KS2)-
    -- Events, dort soll der rechte Stick aber GENAU WIE IM NORMALEN GAMEPLAY laufen (Yaw frei, Pitch weiter
    -- vom HMD ueber den RY-Lock darueber). Sie werden hier explizit ausgenommen -- NICHT ueber den
    -- boat_active-Override unten (der greift erst ab der VehicleCam-Fahrt, nicht schon beim Einsteigen,
    -- und deckt Minecart gar nicht ab). Flags kommen aus dem killswitch:
    -- __re4_railcar_mode = die eigentliche LOREN-FAHRT (an den Wagen geparentet, STAGE-UNABHAENGIG,
    -- killswitch ~1752 "railcar_mode"). NUR die Fahrt!
    -- [2026-07-19] Das Loren-INTRO (__re4_minecart_ks4_active / __re4_minecart2_ks4_active,
    -- Stage 55201/55202) bleibt ABSICHTLICH gesperrt -- dort soll sich die Cam nicht per Stick drehen.
    -- Also NICHT wieder in diese Liste aufnehmen.
    -- in_boat = Stage gm02_500_00_2 (ganze Bootsfahrt, inkl. Einstieg).
    -- [BULLETRUSH_STICK 2026-08-05] Der Mercenaries-Ragemodus laeuft seit heute als KS4
    -- (killswitch-Zweig "ks4_bulletrush"), damit die native Pruegel-Anim sauber spielt. Anders als
    -- die passiven KS4-Faelle (Aufzug/Gondel/Lore) ist das aber AKTIVES Gameplay -- der rechte Stick
    -- muss dort weiter drehen. Das Flag setzt ausschliesslich re4_vr_merc.lua und ist ausserhalb von
    -- Mercenaries immer false -> Leons Kampagne und Adas DLC bleiben exakt wie bisher gesperrt.
    local ks_stick_exempt = in_boat
        or rawget(_G, "__re4_railcar_mode") == true
        or rawget(_G, "__re4_force_ks4_bulletrush") == true
    if not in_menu and not in_throwsight and not in_binoculars and not in_turret and not in_jetski
       and not ks_stick_exempt
       and (killswitch.is_ks2() == true
            or (type(killswitch.is_ks4) == "function" and killswitch.is_ks4() == true)) then
        f.RX = 0.0
        f.RY = 0.0
    end

    -- [BOAT_STICK 2026-07-18] Im Boot (parented, __re4_boat_active = Fahrt/VehicleCam, NICHT der Einstieg) den
    -- GESAMTEN rechten Stick ROH durchreichen (RX+RY) -> nativ frei umsehen/zielen. Steht NACH den Stick-Locks
    -- oben (RY-Lock/KS2-Lock) und ueberschreibt sie bewusst. NUR wenn NICHT im Menue: oeffnet man mittendrin ein
    -- Menue, greift der Menue-Branch (rechter Stick = Navigation) -> deshalb `and not in_menu` (Menue hat Vorrang).
    if boat_active and not in_menu then
        f.RX = vr_right_stick_axis.x or 0.0
        f.RY = vr_right_stick_axis.y or 0.0
    end

    -- [NO_BACK_SPRINT] Rueckwaerts kann man nicht sprinten (FP-Regel):
    -- Dash (L3) bei Rueckwaerts-Stick schlucken — sonst dreht die Engine
    -- den Char 180 und rennt zur Kamera (Spasmus gegen den Body-Yaw).
    if moving_backward then
        f.LS = false
    end

    apply_frame(f)
end)

-- =====================================================================
-- [PUBLIC-UI] Nacktes Haupt-UI (ohne Tree): Kopie des 180-Grad-Toggles fuers spaetere Release.
-- Derselbe PREFS-Wert wie im Dev-Tree -- beide Haken zeigen also immer dasselbe.
-- Reihenfolge zentral ueber #re4_vr_menu.lua (Platz 60); ohne Dispatcher eigener Callback.
-- =====================================================================
do
    local draw = function()
        local c, v = imgui.checkbox("Enable 180 degree turn", PREFS.enable_180_rotation)
        if c then
            PREFS.enable_180_rotation = v
            if not v then qt.reset() end
            save_prefs()
        end

        draw_snapturn_ui("pub")

        -- [PUBLIC-UI 2026-08-11] Kopie des Roomscale-Hakens aus dem Movement-Tree, ganz
        -- unten unter Snapturn. Der Wert liegt in re4_vr_movement.lua (dort auch die
        -- Persistenz) und wird ueber zwei kleine Funktionen geteilt -- so zeigen beide
        -- Haken immer dasselbe und keiner ueberschreibt den anderen.
        -- Fehlt das Movement-Script, wird der Haken gar nicht erst gezeichnet.
        local rs_get = rawget(_G, "__re4_roomscale_get")
        local rs_set = rawget(_G, "__re4_roomscale_set")
        if type(rs_get) == "function" and type(rs_set) == "function" then
            local cr, vr_ = imgui.checkbox("Enable Roomscale", rs_get())
            if cr then rs_set(vr_) end
        end
    end
    local add = rawget(_G, "__re4_ui_add")
    if type(add) == "function" then add(60, "binding_180turn", draw) else re.on_draw_ui(draw) end
end

-- ============================================================
-- [LA_TIMING] UI: Links-A Tap/Hold-Zeiten einstellen (persistiert in re4_vr_bindings.json)
-- ============================================================
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Binding" raus (27 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- ============================================================
-- Cleanup
-- ============================================================
re.on_script_reset(function()
    inited = false
    vr = nil
    left_joystick = nil
    right_joystick = nil
    ACT = {}
    prev_l_grip = false
    grenade_throw_cooldown = 0
    grenade_rt_pulse_frames = 0
    prev_vr_grenade_throw = false
    la_hold.pressed = false
    la_hold.frames = 0
    la_hold.fired_long = false
    la_hold.short_timer = 0
    la_hold.back_guard = false
    la_hold.ks_x_guard = false   -- [KS_X_GUARD] halb gesetzten Latch nicht ueber Reset Scripts schleppen
    was_active = false
    lt_b_overlay_was = false
    _ref_overlay_synced = false
    _ref_overlay_tick = 0
    qt.reset()   -- [QUICKTURN_180] halb gelaufene Doppel-Tipp-Phase nicht ueber den Reset schleppen
    dual_trigger_start_clock = nil
    dual_trigger_fired = false
    dual_trigger_gap_clock = nil
    start_hold_timer = 0
    ee_flame_clock = nil
    ee_flame_fired = false
    ee_flame_gap_clock = nil
    for _, v in pairs(edge_state) do
        v.prev = false
        v.timer = 0
    end
end)

-- =====================================================================
-- [FEUER-BEGRENZUNG 2026-07-23] Einzelschuss/Burst am NATIVEN Schuss statt am Trigger.
--
-- GEMESSEN (Wegwerf-Probe re4_zzz_firemode, 2026-07-23) -- und der erste Versuch war falsch:
-- Ein PRE-Hook auf `execFire` mit SKIP_ORIGINAL bleibt wirkungslos. Im Log steht auch warum:
-- `BulletShellGenerator.requestFire` laeuft JEDES Mal rund eine Millisekunde VOR `execFire` --
-- das Projektil ist da also schon erzeugt, execFire kommt zu spaet zum Blocken. Ebenso wenig
-- taugt ein Block am ShellGenerator selbst: dort waeren Munition und Sound bereits durch.
--
-- RICHTIGER HEBEL ist die Frage, die das Spiel VOR dem Schuss stellt:
-- `chainsaw.PlayerEquipment.isEnableFire`. Antwortet sie false, feuert die Engine nicht --
-- genau dieses Muster laeuft erprobt in re4_vr_reload4_dlc.lua (Rack-Sperre der DLC-Waffen).
-- Der Weg ist ausserdem frameunabhaengig, weil das Spiel selbst fragt, wann immer es feuern will.
--
-- LOGIK: Pro Trigger-Druck (Flanke oben in apply_frame -> __vr_burst_press_id) faengt der Zaehler
-- neu an; gezaehlt werden die tatsaechlichen Schuesse ueber den Schuss-Zaehler des Crosshair-Hooks
-- (__vr_shot_seq). Sind so viele Schuesse gefallen wie erlaubt (__vr_burst_count, Einzelschuss = 1),
-- antwortet das Gate false, bis der Trigger losgelassen und neu gedrueckt wird.
--
-- SICHERHEIT (eine haengende Feuersperre waere gamebreaking):
-- * nur wenn der Modus ausdruecklich aktiv ist (__vr_burst_active von motion.lua)
-- * nur im reinen Gameplay
-- * nur solange der Trigger gehalten wird -- losgelassen ist die Sperre sofort weg
-- * Not-Aus jederzeit: _G.__re4_burst_gate = false
-- ACHTUNG: sdk.hook -> erst nach GAME-NEUSTART aktiv, "Reset Scripts" genuegt NICHT.
-- =====================================================================
if not _G.__re4_burst_gate_hook then
    _G.__re4_burst_gate_hook = true
    _G.__re4_burst_gate = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        local m  = td and td:get_method("isEnableFire")
        if not m then return end   -- isEnableFire nicht gefunden -> Feuer-Begrenzung inaktiv
        sdk.hook(m,
            function() end,
            function(retval)
                pcall(function()
                    -- [PUMP/EMPTY FRAMEUNABHAENGIG 2026-07-23] Der Feuer-Block bei leerer/ungepumpter
                    -- Waffe (__vr_block_fire_when_empty) lief bisher NUR ueber RT (apply_frame, 1x/Frame).
                    -- Bei niedriger Framerate rutscht ein Schuss durch, bevor RT genullt wird -- man kann
                    -- die W-870 ohne Pump weiterfeuern. isEnableFire wird von der Engine PRO Schuss gefragt,
                    -- ist also frameunabhaengig. Nur im reinen Gameplay blocken; die Reload-Module setzen
                    -- den Flag ohnehin nur bei echtem Bedarf (leer / Pump aussteht / Slide offen).
                    if rawget(_G, "__vr_block_fire_when_empty") == true
                       and rawget(_G, "__re4_frame_is_gameplay") == true then
                        retval = sdk.to_ptr(0)
                        return
                    end
                    if rawget(_G, "__re4_burst_gate") ~= true then return end
                    if rawget(_G, "__vr_burst_active") ~= true then return end
                    if rawget(_G, "__re4_frame_is_gameplay") ~= true then return end
                    if rawget(_G, "__vr_burst_rt_down") ~= true then return end   -- losgelassen = frei
                    local n = tonumber(rawget(_G, "__vr_burst_count")) or 0
                    if n <= 0 then return end
                    -- Neuer Trigger-Druck -> Startpunkt des Schuss-Zaehlers merken
                    local press = tonumber(rawget(_G, "__vr_burst_press_id")) or 0
                    if press ~= (tonumber(rawget(_G, "__vr_burst_seen_press")) or -1) then
                        _G.__vr_burst_seen_press = press
                        _G.__vr_burst_start_seq  = tonumber(rawget(_G, "__vr_shot_seq")) or 0
                    end
                    local fired = (tonumber(rawget(_G, "__vr_shot_seq")) or 0)
                                - (tonumber(rawget(_G, "__vr_burst_start_seq")) or 0)
                    if fired >= n then retval = sdk.to_ptr(0) end   -- false -> Engine feuert nicht
                end)
                return retval
            end)
    end)
end

-- =====================================================================
-- [AUTO-RELOAD-BLOCK 2026-08-17] Playtester, Riot Gun: waehrend des Shell-fuer-Shell-Nachladens
-- (3 Shells drin, bei der 4. passiert es) startet die ENGINE ihre eigene Ladeanimation und
-- wiederholt sie endlos. Kein B im Spiel -- eine Shotgun hat bei uns gar keinen B-Reload.
-- Der Weg ist der Feuerbefehl: liegt Aim an und rutscht der rechte Trigger durch, geht RT an die
-- Engine (apply_rt_attack). Geschossen wird dabei nichts, weil das Feuer-Gate oben
-- (isEnableFire + __vr_block_fire_when_empty) den Schuss abfaengt -- aber die Engine macht aus
-- einem Feuerbefehl auf eine nicht feuerbereite Waffe ihren AUTO-RELOAD, und der war bisher
-- nirgends geblockt. Bei loopReload-Waffen (Riot Gun, Skull Shaker, Revolver) laedt sie dabei
-- Schuss fuer Schuss -> die Anim laeuft weiter, solange sie nicht fertig wird.
--
-- Das Fenster ist zwischen zwei Shells offen: der Shotgun-Block in re4_vr_reload.lua haengt u.a.
-- an `flow_active = not mag_is_present()` -- das ist nur wahr, SOLANGE die Shell in der Hand ist.
-- Ist sie eingerastet und die naechste noch nicht geholt, blockt nichts mehr (die Riot Gun
-- chambert beim Laden sofort, rack.empty ist also auch false).
--
-- HEBEL: dieselbe Frage-Antwort-Technik wie beim Feuer-Block. Das Spiel fragt selbst
-- `chainsaw.PlayerEquipment.isEnableAutoReload()` (per MCP am laufenden Spiel geprueft: existiert,
-- Boolean; ein `startReload`/`endReload` wie in RE9 gibt es in RE4 NICHT). Antwortet sie false,
-- laedt die Engine nicht von selbst nach -- kein SKIP_ORIGINAL, kein Eingriff in Eingabepfade,
-- keine geaenderte Zeile im bestehenden Ablauf.
--
-- SCHARF NUR, solange eine von unseren Modulen verwaltete Waffe in der Hand ist
-- (`__vr_manual_reload_consume_b`, gesetzt in re4_vr_reload.lua:5184 und den anderen fuenf
-- Reload-Dateien). Damit sind die Waffen, die den nativen Reload BRAUCHEN, automatisch draussen:
-- Red9/Top-Loader (dort ist das Flag bewusst false) und der Compound Bow (kein Modul).
--
-- NOT-AUS: `_G.__re4_autoreload_gate = false` -> Engine laedt wieder wie im Vanilla.
-- DIAGNOSE: `_G.__re4_autoreload_blocked` zaehlt die abgelehnten Anfragen (0 = hat nie gegriffen).
-- ACHTUNG: sdk.hook -> erst nach GAME-NEUSTART aktiv, "Reset Scripts" genuegt NICHT.
-- =====================================================================
if not _G.__re4_autoreload_gate_hook then
    _G.__re4_autoreload_gate_hook = true
    _G.__re4_autoreload_gate     = true
    _G.__re4_autoreload_blocked  = 0
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        local m  = td and td:get_method("isEnableAutoReload")
        if not m then return end   -- Methode nicht gefunden -> Block entfaellt still
        sdk.hook(m,
            function() end,
            function(retval)
                pcall(function()
                    if rawget(_G, "__re4_autoreload_gate") ~= true then return end
                    -- Verwaltete Waffe? Nur dann. Kein Gameplay-Gate: genau in den HUD-aus- und
                    -- Killswitch-Frames rutscht der Trigger durch, dort muss der Block gelten.
                    if rawget(_G, "__vr_manual_reload_consume_b") ~= true then return end
                    retval = sdk.to_ptr(0)   -- false -> Engine laedt NICHT von selbst nach
                    _G.__re4_autoreload_blocked = (tonumber(rawget(_G, "__re4_autoreload_blocked")) or 0) + 1
                end)
                return retval
            end)
    end)
end

