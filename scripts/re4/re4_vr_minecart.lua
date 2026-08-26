-- Builtin implementation: src/mods/vr/games/re4/RE4VRMinecart.cpp
return

-- re4_vr_minecart.lua — Minecart/RailCar-spezifische VR-Fixes.
-- Laeuft NUR im railcar_mode (killswitch AN, aber motion + arm_chain + firstperson bewusst weiter).
-- Hier landet alles, was auf dem Schienenwagen anders sein muss, OHNE im movement-Script zu wuehlen.
--
-- Drei Bausteine:
-- (1) __vr_anim_l0-Export -> arm_chain nutzt den Layer0-Anim-Namen fuer seinen Schulter-Capture-Slot.
-- (2) Crosshair-Force -> die Cart-Gun (4005) setzt is_aim/IsReticleDisp nie -> hier erzwingen.
-- (3) Spine-/Torso-Pin -> stabile Oberkoerper-Basis (Port aus movement.apply_spine_pin, ohne Slider),
-- damit arm_chain's Schulter-Reach-Follow nicht von der nativen AutoMove-Pose
-- rechnet -> sonst ist der Arm schnell am Anschlag ("clamped").

-- [SAFE_GIBT_IMMER_EINEN_WERT 2026-07-31] Ohne das explizite `return nil` liefert diese
-- Funktion im Fehlerfall GAR KEINEN Wert (nicht nil, NICHTS). In tostring(safe(...)) kommt dann
-- kein Argument an -> "bad argument #1 to 'tostring' (value expected)" -> der ganze umgebende
-- Aufruf stirbt. Genau daran ist am 31.07. der Bogen-Reload gestorben. Im Erfolgsfall unveraendert.
local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end
-- [RELOAD] utility/RE4 haelt die equippte Waffen-GO aktuell (re4.weapon_gameobject) -> darueber lesen wir
-- die native Reload-Anim der Cart-Gun (die laeuft an der WAFFE, nicht am Body).
local ok_re4, re4 = pcall(function() return require("utility/RE4") end)
if not ok_re4 or type(re4) ~= "table" then re4 = {} end
local function railcar_active() return rawget(_G, "__re4_railcar_mode") == true end
-- [MINECART] Die Loren-Stage 55201 hat drei Zustaende: Intro-Einstieg (ActionCam, __re4_minecart_ks4_active),
-- Intro-Fahrt (VehicleCam, __re4_minecart2_ks4_active) und die echte RailCar-Fahrt (__re4_railcar_mode).
-- [PIN-GATE] Der Spine-Pin gilt NUR in der echten Fahrt (railcar). BEIDE Intro-KS (Einstieg + Fahrt-Intro)
-- laufen OHNE Pin -> die Cam folgt dem nativen Cutscene-Head. Im railcar ruft arm_chain den Pin (vor IK).
-- (railcar_active ist genau dieses Gate -> apply_spine_pin nutzt es direkt.)

-- ---- Config (persistiert) ----
local CFG_PATH = "re4_vr/re4_vr_minecart.json"
local cfg = {
    body_down = 0.0,   -- [SITZEN] Oberkoerper (Hip + Kette darueber) absenken (m) -> auf dem Cart sitzt man
    body_back = 0.0,   -- [ZURUECK] Oberkoerper (Hip + Kette) in Hip-Local-Z schieben (m) -> weiter hinten im Kart sitzen
    -- [TILT-HMD ENTFERNT 2026-07-13] Der tilt-abhaengige HMD-Offset war nur eine Kruecke gegen die
    -- Kapsel-Verankerung (firstperson PIN_ANCHOR bei sticky __vr_surge_bridged). Jetzt ankert die Cam am
    -- gepinnten Head (der den Cart-Tilt selbst mitmacht) -> kein Offset mehr noetig. Siehe firstperson-Guard.
    yaw_follow = false,  -- [YAW-FOLLOW] AUS: bewiesen wirkungslos (rotation_offset tot fuer Vehicle-Sicht) UND
                         -- koppelt bodyYaw -> frisst in manchen Situationen die Stick-Kamera-Drehung ("Anschlag").
    yaw_sign  = 1.0,     -- Drehrichtung (1 oder -1) -- per Test justieren, falls es falschherum dreht
    -- [KIPP-AUSGLEICH PER HMD 2026-08-02] Sich mit dem Kopf zur Seite lehnen loest dasselbe aus
    -- wie der rechte Stick zur Seite -- aber NUR im Kart und NUR waehrend einer Kippphase.
    lean_enabled   = true,
    -- [EMPFINDLICHER 2026-08-02, "wir muessen uns jedoch recht stark lehnen"] Von 0.20/0.55
    -- heruntergesetzt. Die Schwelle muss ueber dem normalen Kopfwackeln beim Fahren liegen, sonst
    -- loest es ungewollt aus -- 0.10 (~6 Grad) ist bewusst gehalten, gesenkt wurde vor allem der
    -- Vollausschlag: dadurch wird aus einer leichten Neigung schon ein kraeftiger Stickwert.
    lean_threshold = 0.10,  -- ab welcher Kopfneigung es greift (Sinus des Roll: 0.10 ~ 6 Grad)
    lean_full      = 0.28,  -- ab hier voller Stickausschlag (0.28 ~ 16 Grad)
    lean_sign      = 1.0,   -- Vorzeichen umkehren, falls es in die falsche Richtung ausgleicht
    lean_tilt_min  = 0.15,  -- ab welcher Kart-Neigung die Kippphase als "laeuft" gilt (max ist OutForceTiltMax)
    -- [AUTO-RECENTER IM KART 2026-08-02] Siehe Block bei update_cart_recenter.
    recenter_enabled = true,
    recenter_dead    = 0.08,   -- m: darunter wird gar nicht nachgezogen (Vorbeugen/Umschauen bleibt frei)
    recenter_rate    = 0.35,   -- m pro Sekunde, mit der die Origin an das HMD herangezogen wird
    -- [ZUG-RUMBLE 2026-08-18] Siehe Block bei update_cart_rumble. Defaults bewusst LEISE:
    -- spuerbar, wenn man darauf achtet, aber nichts, was nach zwei Minuten nervt.
    rumble_enabled = true,
    -- [STAERKER 2026-08-18, nach dem ersten Testlauf] Grund- und Stoss-Staerke gut verdoppelt, Puls
    -- minimal laenger -> deutlicher spuerbar, aber weiterhin weit unter dem Grab-Rumble (der faehrt 0.9).
    rumble_amp     = 0.22,   -- Grundstaerke des Dauer-Rollens (0..1)   [war 0.10]
    rumble_rate    = 0.09,   -- s zwischen zwei Pulsen (kleiner = dichter/gleichmaessiger)
    rumble_dur     = 0.07,   -- s Pulslaenge (etwas kuerzer als das Intervall -> es "atmet")
    rumble_freq    = 45.0,   -- Hz -- tief = dumpfes Rollen; hoch = Summen (holster nimmt 200 fuer "Klick")
    rumble_clack   = true,   -- Schienenstoss-Akzent (das "ta-tak" macht erst den Zug daraus)
    rumble_clack_every = 1.7,-- s zwischen zwei Stoessen
    rumble_clack_amp   = 0.50,   -- [war 0.26]
    rumble_intro   = true,   -- auch waehrend der Intro-FAHRT (VehicleCam); der Einstieg bleibt immer still
    -- [TEMPO-GATE 2026-08-18] Gegen "rumpelt schon beim Kart-SCHIEBEN" und "rumpelt weiter, obwohl das
    -- Kart schon haelt": gemessen wird der Positionswechsel pro Sekunde (s. cart_speed_now).
    rumble_speed_min   = 3.0,   -- m/s: darunter passiert GAR NICHTS (Schieben/Stillstand)
    rumble_speed_full  = 9.0,   -- m/s: ab hier volle Staerke
    rumble_speed_scale = true,  -- Staerke zwischen min und full hochblenden (Auslaufen wird von selbst leiser)
}
local function save_cfg() pcall(function() json.dump_file(CFG_PATH, cfg) end) end
do
    local d = safe(function() return json.load_file(CFG_PATH) end)
    if type(d) == "table" then
        if type(d.body_down) == "number" then cfg.body_down = d.body_down end
        if type(d.body_back) == "number" then cfg.body_back = d.body_back end
        -- yaw_follow bewusst NICHT mehr laden -> bleibt aus (deprecated, verursachte Stick-Yaw-Anschlag)
        if type(d.yaw_sign) == "number" then cfg.yaw_sign = d.yaw_sign end
        if type(d.lean_enabled)   == "boolean" then cfg.lean_enabled   = d.lean_enabled end
        if type(d.lean_threshold) == "number"  then cfg.lean_threshold = d.lean_threshold end
        if type(d.lean_full)      == "number"  then cfg.lean_full      = d.lean_full end
        if type(d.lean_sign)      == "number"  then cfg.lean_sign      = d.lean_sign end
        if type(d.lean_tilt_min)  == "number"  then cfg.lean_tilt_min  = d.lean_tilt_min end
        if type(d.recenter_enabled) == "boolean" then cfg.recenter_enabled = d.recenter_enabled end
        if type(d.recenter_dead)    == "number"  then cfg.recenter_dead    = d.recenter_dead end
        if type(d.recenter_rate)    == "number"  then cfg.recenter_rate    = d.recenter_rate end
    end
end

-- ---- Body-Transform (gecacht, robust nach Save/Load) ----
-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: einmal pro Frame aufloesen statt bei
-- jedem Aufruf. Semantik unveraendert, alter Weg bleibt als Fallback. NOT-AUS: `_G.__re4_fc_off = true`.
pcall(function() require("re4vr/re4_vr_frame_cache") end)

local character_manager
local function get_body_transform()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.body_tf() end
    if not character_manager then character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager") end
    if not character_manager then return nil end
    local ctx = safe(function() return character_manager:call("getPlayerContextRef") end); if not ctx then return nil end
    local body = safe(function() return ctx:call("get_BodyGameObject") end); if not body then return nil end
    return safe(function() return body:call("get_Transform") end)
end

-- ============================================================
-- (1) Layer0-Anim-Name exportieren (1:1 aus movement.update_anim_export)
-- ============================================================
local bw_motion, bw_go = nil, nil
local T_MOTION = sdk.typeof("via.motion.Motion")
local function update_anim_export()
    local tf = get_body_transform()
    if not tf then _G.__vr_anim_l0 = nil; bw_motion = nil; return end
    local go = safe(function() return tf:call("get_GameObject") end)
    if go ~= bw_go then bw_go = go; bw_motion = nil end
    if not bw_motion and go and T_MOTION then
        bw_motion = safe(function() return go:call("getComponent(System.Type)", T_MOTION) end)
    end
    if not bw_motion then _G.__vr_anim_l0 = nil; return end
    local layer = safe(function() return bw_motion:call("getLayer", 0) end)
    local node  = layer and safe(function() return layer:call("get_HighestWeightMotionNode") end)
    local name  = node and safe(function() return node:call("get_MotionName") end)
    _G.__vr_anim_l0 = (type(name) == "string" and name ~= "") and name or nil
end

-- [RAILCAR_RELOAD] native Reload-Anim erkennen (irgendein MotionFsm2-Layer-Node enthaelt "RELOAD") ->
-- _G.__re4_railcar_reloading. motion + arm_chain + Spine-Pin pausieren solange -> native Nachlade-Anim spielt.
-- (Bewusst HIER statt in motion.lua: motion hatte sein 200-Local-Limit erreicht.)
-- [FIX 2026-07-13] Die native Reload-Anim laeuft an der WAFFE (via.motion.Motion), nicht am Body -- die
-- Body-Layer bleiben in der Mounted-Halte-Pose (Jacked/Locked). Gemessen (railcar_diag NODES): Reload =
-- Motion-Name "wp4002_tram_0810_Reload" (die Cart-Gun ist intern wp4002/Red9 im tram-Modus). Idle/Aim/Fire
-- heissen general_0500_Idle_Loop / _0510_Aim_Loop / _0512_Aim_Fire -> case-insensitive "reload" ist ein
-- sauberer Diskriminator. (Alter Code suchte "RELOAD" gross am Body -> traf nie.)
local T_MOTION = sdk.typeof("via.motion.Motion")
local wep_mo = { go = nil, comp = nil }
local function update_reload_flag()
    local reloading = false
    repeat
        local wgo = re4 and re4.weapon_gameobject; if not wgo then break end
        if wep_mo.go ~= wgo then wep_mo.go = wgo; wep_mo.comp = nil end
        if not wep_mo.comp then wep_mo.comp = T_MOTION and safe(function() return wgo:call("getComponent(System.Type)", T_MOTION) end) or nil end
        local mo = wep_mo.comp; if not mo then break end
        local lay  = safe(function() return mo:call("getLayer", 0) end)
        local node = lay and safe(function() return lay:call("get_HighestWeightMotionNode") end)
        local nm   = node and safe(function() return node:call("get_MotionName") end)
        if nm and tostring(nm):lower():find("reload", 1, true) then reloading = true end
    until true
    _G.__re4_railcar_reloading = reloading
    -- [RELOAD-FADE] Pin-Einfluss (1 = voll gepinnt, 0 = voll nativ/Reload). Reload-Start rampt REIN nach 0
    -- (Kopf gleitet in die Reload-Pose), Reload-Ende rampt RAUS nach 1 (Kopf/Hand gleiten zurueck). Gleicher Step.
    local f = tonumber(rawget(_G, "__re4_railcar_reload_fade")) or 1.0
    if reloading then
        if f > 0.0 then _G.__re4_railcar_reload_fade = math.max(0.0, f - 0.09) end
        _G.__re4_reload_hand_fp = nil; _G.__re4_reload_hand_fr = nil   -- Hand-Ease-out-Capture fuer naechstes Reload-Ende ruecksetzen
    else
        if f < 1.0 then _G.__re4_railcar_reload_fade = math.min(1.0, f + 0.09) end
    end
end

-- ============================================================
-- (3) Spine-/Torso-Pin — Port aus movement (nur die reine Pose, ohne Z/X/Yaw-Slider,
-- ohne Crouch/Run-Blend/Surge; das alles ist auf dem Cart eh 0/irrelevant).
-- ============================================================
local PIN_JOINTS = { "Hip", "Spine_0", "Spine_1", "Spine_2", "Neck_0", "Neck_1", "Head" }
local MOVE_CFG_PATH = "re4_vr/re4_vr_movement.json"

-- Persistierte Steh-Pose ("pin_pose", von movement gecaptured/gesichert) laden. Format je Joint:
-- { px,py,pz, rw,rx,ry,rz,... } -> hier nur Local-Pos + Local-Rot noetig.
local pin_map = nil          -- name -> { p = Vector3f, r = Quaternion }
local function load_pin_pose()
    if pin_map then return pin_map end
    local d = safe(function() return json.load_file(MOVE_CFG_PATH) end)
    local pp = d and d.pin_pose
    if type(pp) ~= "table" or type(pp.joints) ~= "table" then return nil end
    local m = {}
    for name, s in pairs(pp.joints) do
        if type(s) == "table" and type(s.px) == "number" and type(s.rw) == "number" then
            m[name] = { p = Vector3f.new(s.px, s.py, s.pz), r = Quaternion.new(s.rw, s.rx, s.ry, s.rz) }
        end
    end
    if next(m) == nil then return nil end
    pin_map = m
    return pin_map
end

local pin = { tf = nil, joints = nil, names = nil }
local function resolve_spine(tf)
    -- Cache; bei Save/Load (tote Handles) neu aufloesen.
    if pin.tf == tf and pin.joints then
        local probe = pin.joints[1]
        if probe and pcall(function() return probe:call("get_Position") end) then return true end
    end
    pin.tf = tf; pin.joints = nil; pin.names = nil
    local list, names = {}, {}
    -- [ROOT SKIP] root (Body-Platzierung) NICHT pinnen: auf dem Cart treibt der Wagen den root. Wir pinnen
    -- nur die Torso-Kette Hip..Head (relativ zum jeweiligen Parent) -> Stand-Pose sitzt auf dem cart-getriebenen
    -- Body, Schulter-Basis ist stabil. (movement pinnt root zusaetzlich, weil es dort gegen die Kapsel ankert.)
    for _, name in ipairs(PIN_JOINTS) do
        local j = safe(function() return tf:call("getJointByName", name) end)
        if j then list[#list + 1] = j; names[#names + 1] = name end
    end
    if #list == 0 then return false end
    pin.joints = list; pin.names = names
    return true
end

-- Pose hart auf die gepinnten Locals schreiben (Torso-Basis stabil -> arm_chain rechnet die Schulter sauber).
local function apply_spine_pin()
    if not railcar_active() then return end
    local f = tonumber(rawget(_G, "__re4_railcar_reload_fade")) or 1.0   -- [RELOAD-FADE] 1 = voller Pin, 0 = voll nativ
    if f <= 0.0 then return end   -- mitten im Reload -> Pin ganz aus, native Anim durchlassen
    local map = load_pin_pose(); if not map then return end
    local tf = get_body_transform(); if not tf then return end
    if not resolve_spine(tf) then return end
    local down = cfg.body_down or 0.0
    local back = cfg.body_back or 0.0
    for i, j in ipairs(pin.joints) do
        local rel = map[pin.names[i]]
        if rel then
            local p = rel.p
            -- [SITZEN] NUR Hip absenken -> die ganze Oberkoerper-Kette (Spine..Head, Kinder von Hip) faellt mit.
            -- Lokal-Y (Parent = root); auf dem ebenen Cart entspricht das ~Welt-unten. Slider stellt die Sitzhoehe.
            if pin.names[i] == "Hip" and (down ~= 0.0 or back ~= 0.0) then
                p = Vector3f.new(p.x, p.y - down, p.z - back)
            end
            pcall(function()
                if f < 1.0 then
                    -- [RELOAD-FADE] von der aktuellen (nativen Reload-End-)Local zur Pin-Pose blenden -> kein Snap.
                    local cp = j:call("get_LocalPosition")
                    local cr = j:call("get_LocalRotation")
                    if cp then p = Vector3f.new(cp.x + (p.x - cp.x) * f, cp.y + (p.y - cp.y) * f, cp.z + (p.z - cp.z) * f) end
                    local rr = rel.r
                    if cr then rr = cr:slerp(rel.r, f) end
                    j:call("set_LocalPosition", p)
                    j:call("set_LocalRotation", rr)
                else
                    j:call("set_LocalPosition", p)
                    j:call("set_LocalRotation", rel.r)
                end
            end)
        end
    end
end
-- [FLICKER-FIX] arm_chain ruft das VOR seinem Solve auf (korrekte Reihenfolge + alle 4 Phasen inkl.
-- UpdateJointExpression) -> die Schulter-Basis steht, bevor die 2-Bone-IK rechnet -> kein Hand-Flackern.
_G.__re4_minecart_apply_spine_pin = apply_spine_pin

-- ============================================================
-- (2) Crosshair-Force: auf dem Cart setzt die Engine is_aim/IsReticleDisp nie ->
-- hier erzwingen, damit Reticle/Bullet-Hook greifen. Laeuft NACH crosshair.lua
-- (alphabetisch spaeter geladen) -> gewinnt ueber dessen Frame-Export.
-- ============================================================
local function force_crosshair()
    if not railcar_active() then return end
    _G.is_reticle_displayed = true
    _G.is_aim = true   -- Mounted-Gun zielt eh nach vorn; falls die Aim-Pose stoert -> diese Zeile raus.
end

-- ============================================================
-- [YAW-FOLLOW] Blick-Basis dreht mit der Kart-Fahrtrichtung -> Kopf neutral = immer nach vorn aus dem Kart.
-- Wir treiben vrmod:set_rotation_offset mit dem Body-Yaw-Delta (der Body dreht mit dem Kart). __vr_recenter_hold
-- haelt es (movement wischt sonst). Beim Eintritt kalibriert (Kopf-Yaw = Fahrtrichtung). ERSTER WURF: die
-- Haende koennten noch doppelt drehen (nutzen rotation_offset + Vehicle-Yaw) -> dann Hand-Basis welt-fix nachziehen.
-- ============================================================
local YF = { entry_body = nil, entry_hmd = nil }
local function yaw_of_quat(q)
    if not q then return nil end
    local f = safe(function() return q * Vector3f.new(0, 0, 1) end); if not f then return nil end
    local l = math.sqrt(f.x * f.x + f.z * f.z); if l < 1e-4 then return nil end
    return math.atan(f.x / l, f.z / l)
end
local function yaw_to_quat(y) local h = y * 0.5; return Quaternion.new(math.cos(h), 0.0, math.sin(h), 0.0) end
local function yaw_wrap(a) while a > math.pi do a = a - 2.0 * math.pi end while a < -math.pi do a = a + 2.0 * math.pi end return a end
local function update_yaw_follow()
    if not (cfg.yaw_follow and railcar_active() and vrmod and vrmod:is_hmd_active()) then
        YF.entry_body = nil; _G.__re4_railcar_yaw_delta = nil
        return
    end
    local tf = get_body_transform(); if not tf then return end
    local br = safe(function() return tf:call("get_Rotation") end)
    local by = yaw_of_quat(br); if not by then return end
    local hq = safe(function() return vrmod:get_transform(0):to_quat() end)
    local hy = yaw_of_quat(hq); if not hy then return end
    if not YF.entry_body then YF.entry_body = by; YF.entry_hmd = hy end
    local delta = yaw_wrap(by - YF.entry_body) * (cfg.yaw_sign or 1.0)
    _G.__re4_railcar_yaw_delta = delta   -- firstperson kann die Hand-Basis um -delta korrigieren (Anti-Doppeldreh)
    _G.__vr_recenter_hold = true
    pcall(function() vrmod:set_rotation_offset(yaw_to_quat(delta - YF.entry_hmd)) end)
end

-- ============================================================
-- [MINECART KNIFE] Kam der Spieler mit Messer in den Kart, gibt das Game die Mounted-Gun NICHT (Messer im Slot,
-- z.B. wp5006). Der KnifeCloseTimer wird im Kart NICHT getickt -> weapons.lua's Timer-Holster wirkungslos.
-- Fix: aktiv auf die Main-Waffe wechseln (__re4_force_change_to_main aus holster.lua), DEFERRED im
-- updateOnFrameHead-Hook (__re4_knife_defer -- feuert auch wenn holster/weapons im Kart gegatet sind). Kontinuierlich
-- ~alle 0.4s solange ein Messer equippt ist (__re4_knife_equipped von weapons.lua) -> faengt Re-Equip ab, dann Cart-Gun.
-- ALLES hier, weil weapons.lua am 200-Local-Limit ist (keine neuen Locals dort moeglich).
-- ============================================================
local _ck_last = 0
local function cart_knife_swap()
    local in_cart = railcar_active()
        or rawget(_G, "__re4_minecart_ks4_active") == true
        or rawget(_G, "__re4_minecart2_ks4_active") == true
    if not in_cart then return end
    local now = os.clock()
    if now - _ck_last < 0.4 then return end
    _ck_last = now
    -- Universell: die deferred Funktion forced wp4005 (Cart-Gun) und ueberspringt sich selbst, wenn schon 4005 ->
    -- egal mit welcher Waffe man reinkam (Messer/Langwaffe/bare). __re4_knife_equipped nur noch fuers Log.
    local knife = rawget(_G, "__re4_knife_equipped") == true
    local ok = false
    if type(_G.__re4_knife_defer) == "function" and type(_G.__re4_force_change_to_main) == "function" then
        _G.__re4_knife_defer(_G.__re4_force_change_to_main); ok = true
    end
    -- [log entfernt]
end

-- ============================================================
-- Hooks — 5-Hook-Stack wie movement (LateUpdateBehavior ist PFLICHT: sonst ueberschreibt die Engine den Pin).
-- ============================================================
-- Spine-Pin wird von arm_chain VOR seinem Solve gerufen (s. _G.__re4_minecart_apply_spine_pin) -> hier nur
-- Anim-Export / Crosshair / HMD-Offset.
-- =====================================================================================================
-- [KIPP-AUSGLEICH PER HMD 2026-08-02, "wenn ich mich nach rechts lehne, dasselbe wie right stick
-- right -- NUR in den Karts und NUR in so einer Tiltphase"]
--
-- Live am pausierten Spiel gemessen (Live-Abfrage, genau im Kippmoment mit Aufforderung gegenzulenken):
-- chainsaw.GmRailCar: Tilt = -0.394 | TiltTop = -0.394 | OutForceTiltMax = 0.5 | ReturnTilt = false
-- Der Kart wollte dabei nach LINKS -> zu druecken war der LINKE Stick nach RECHTS. Damit gilt:
-- Tilt NEGATIV = kippt nach links -> Gegensteuern nach rechts (positives LX auf dem LINKEN Stick)
-- Die Kippphase ist also direkt am Kart ablesbar, ganz ohne GUI-/Prompt-Erkennung:
-- |Tilt| ueber Schwelle UND ReturnTilt == false -> es wird gerade gegengehalten verlangt
-- ReturnTilt == true -> Kart richtet sich auf (geschafft)
--
-- DREI GATES, alle muessen zutreffen -- sonst wird das Global gar nicht erst gesetzt und das Binding
-- bleibt voellig unberuehrt (Eingabepfade nie blind gaten, s. Session 2026-07-21):
-- 1. railcar_active -> nur in der echten Kart-Fahrt
-- 2. getPlayerRailCar lebt -> nur mit echtem Kart darunter
-- 3. |Tilt| >= lean_tilt_min UND ReturnTilt == false -> nur in der Kippphase
--
-- Gemessen wird die ECHTE Kopfneigung im Raum (vrmod:get_transform(0)), nicht die Spielkamera -- die
-- kippt mit dem Kart mit und waere als Messgroesse unbrauchbar. Der Rechts-Vektor des HMD liefert mit
-- seiner Y-Komponente direkt den Sinus des Roll: Kopf zur Seite geneigt -> Betrag steigt.
-- =====================================================================================================
local rail_manager
local function get_player_railcar()
    if not rail_manager then rail_manager = sdk.get_managed_singleton("chainsaw.RailCarManager") end
    if not rail_manager then return nil end
    return safe(function() return rail_manager:call("getPlayerRailCar") end)
end

local lean_dbg = { active = false, tilt = 0.0, roll = 0.0, out = 0.0 }
local function update_cart_lean()
    -- Standardfall: kein Eingriff. Global IMMER zuerst loeschen, damit ein einzelner ausgefallener
    -- Frame nicht zu einem haengenden Stick fuehrt.
    _G.__re4_cart_lean_lx = nil
    lean_dbg.active = false
    if cfg.lean_enabled ~= true then return end
    if not railcar_active() then return end

    local car = get_player_railcar(); if not car then return end
    local tilt = tonumber(safe(function() return car:call("get_Tilt") end)); if not tilt then return end
    local returning = safe(function() return car:call("get_ReturnTilt") end)
    lean_dbg.tilt = tilt
    -- Kippphase? Sonst raus -- im normalen Fahren darf das HMD den Stick NIE anfassen.
    if math.abs(tilt) < (cfg.lean_tilt_min or 0.15) then return end
    if returning == true then return end

    -- Echte Kopfneigung: Y-Anteil des HMD-Rechts-Vektors = sin(Roll).
    local q = safe(function() return vrmod:get_transform(0):to_quat() end); if not q then return end
    local right = safe(function() return q * Vector3f.new(1.0, 0.0, 0.0) end); if not right then return end
    local roll = -(right.y or 0.0)          -- Kopf nach rechts geneigt -> positiv
    lean_dbg.roll = roll

    local th   = cfg.lean_threshold or 0.20
    local full = math.max(th + 0.01, cfg.lean_full or 0.55)
    local mag  = math.abs(roll)
    if mag < th then return end             -- unter der Schwelle: nichts tun (Kopf-Wackeln ignorieren)
    local amt = (mag - th) / (full - th)
    if amt > 1.0 then amt = 1.0 end
    local out = amt * ((roll >= 0.0) and 1.0 or -1.0) * (cfg.lean_sign or 1.0)

    _G.__re4_cart_lean_lx = out
    lean_dbg.active = true
    lean_dbg.out = out
end

-- =====================================================================================================
-- [AUTO-RECENTER IM KART 2026-08-02, "das HMD verabschiedet sich vom Headjoint"]
--
-- Per Diagnose-Log belegt, WAS wirklich passiert (re4_cartlean_diag, Werte relativ zum Einsteigen):
-- dHEADJOINT = 0.000/0.000/0.000 -> Leons Kopf steht absolut still, nichts zieht ihn weg
-- dHMD = -0.445 / -0.640 -> der SPIELER ist physisch 45 cm zur Seite und 64 cm nach hinten
-- dORIGIN = -0.130 / -0.042 -> die Standing Origin ist kaum mitgekommen
-- OFFSET = -0.315 / -0.598 -> dieser Rest schiebt die Kamera vom Head-Joint weg
-- Also kein Script-Fehler: RoomScale uebertraegt den Versatz zwischen HMD und Origin bewusst. Beim
-- staendigen Gegenlehnen verlagert man Kopf und Oberkoerper und kommt nie exakt zurueck -- das summiert
-- sich. Ein Runtime-Recenter setzt die Origin auf die aktuelle HMD-Position, OFFSET wird 0, alles passt.
-- (Der RoomScale-Verdacht gegen movement.hmd_follow war falsch und wurde 1:1 zurueckgebaut.)
--
-- Genau das machen wir hier automatisch, aber TRAEGE statt als Sprung: Die Origin wird mit
-- recenter_rate (m/s) an das HMD herangezogen, aber erst ausserhalb einer Totzone. Damit bleibt
-- kurzes Vorbeugen oder Umschauen unveraendert moeglich -- nur die dauerhafte Drift laeuft weg.
-- NUR X und Z: die Hoehe (Y) bleibt unangetastet, sonst wandert die Augenhoehe.
-- Gate: ausschliesslich __re4_railcar_mode. Ausserhalb des Karts wird die Origin nie angefasst.
-- =====================================================================================================
local rc_last_t = nil
local rc_dbg = { off = 0.0, moved = 0.0 }
local function update_cart_recenter()
    if cfg.recenter_enabled ~= true then rc_last_t = nil; return end
    if not railcar_active() then rc_last_t = nil; return end
    if not (vrmod and vrmod:is_hmd_active()) then rc_last_t = nil; return end

    local now = os.clock()
    local dt = rc_last_t and (now - rc_last_t) or 0.0
    rc_last_t = now
    if dt <= 0.0 or dt > 0.25 then return end   -- erster Frame / Haenger: nur Zeitbasis setzen

    local hmd = safe(function() return vrmod:get_position(0) end)
    local so  = safe(function() return vrmod:get_standing_origin() end)
    if not (hmd and so) then return end

    local dx, dz = hmd.x - so.x, hmd.z - so.z
    local dist = math.sqrt(dx * dx + dz * dz)
    rc_dbg.off = dist
    rc_dbg.moved = 0.0
    local dead = cfg.recenter_dead or 0.08
    if dist <= dead then return end             -- innerhalb der Totzone: nichts tun

    -- Nur den Anteil JENSEITS der Totzone abbauen, und hoechstens so viel wie rate*dt.
    local step = math.min((cfg.recenter_rate or 0.35) * dt, dist - dead)
    if step <= 0.0 then return end
    local ux, uz = dx / dist, dz / dist
    so.x = so.x + ux * step
    so.z = so.z + uz * step
    pcall(function() vrmod:set_standing_origin(so) end)
    rc_dbg.moved = step
end

-- ============================================================
-- [ZUG-RUMBLE 2026-08-18] Leichtes Dauer-Rumpeln in beiden Controllern, solange man im Kart FAEHRT --
-- wie in einem Zug. Bewusst subtil: es soll auffallen, wenn man darauf achtet, und sonst nicht nerven.
--
-- WO ES LAEUFT: nur in der echten RailCar-Fahrt (__re4_railcar_mode) und -- optional (rumble_intro) --
-- in der Intro-FAHRT (VehicleCam, __re4_minecart2_ks4_active). Der Intro-EINSTIEG (ActionCam,
-- __re4_minecart_ks4_active) bleibt bewusst still: da sitzt man noch nicht, das waere nur Krach.
-- Ausserhalb des Karts kann hier nichts feuern -- die Gates stehen VOR jedem trigger-Aufruf, und
-- dieses Script ist ohnehin das Cart-Script.
--
-- WIE ES KLINGT: alle rumble_rate Sekunden ein kurzer Puls (rumble_dur) mit tiefer Frequenz
-- (rumble_freq ~45 Hz = dumpfes Rollen; zum Vergleich: holster nimmt 200 Hz fuer "Klick"). Die
-- Amplitude wird mit zwei ueberlagerten Sinussen moduliert statt mit Zufall -- so wird das Rollen
-- ungleichmaessig, bleibt aber ruhig und wiederholt sich nicht hoerbar. Dazu alle
-- rumble_clack_every Sekunden ein kraeftigerer Schienenstoss, ABWECHSELND links/rechts betont
-- (die Seite wechselt wie die Achsen) -- erst dieses "ta-tak" macht daraus einen Zug.
--
-- Kein eigener Sound, kein Eingriff in Bewegung/Kamera: reine Haptik ueber vrmod:trigger_haptic_vibration
-- (dieselbe API wie der Holster-Grab-Rumble, re4_vr_holster.lua:1644).
-- AUS: Haken in der UI (oder cfg.rumble_enabled = false) -> es feuert nichts mehr.
-- ============================================================
local rum = { t0 = nil, next_t = 0, next_clack = 0, side = 0 }
local rum_dbg = { on = false, amp = 0.0 }
local function cart_ride_now()
    if railcar_active() then return true end
    if cfg.rumble_intro and rawget(_G, "__re4_minecart2_ks4_active") == true then return true end
    return false
end
-- [TEMPO-GATE 2026-08-18] Der Zustand "im Kart" allein taugt nicht als Schalter: er steht schon, waehrend
-- man das Kart erst ANSCHIEBT, und er steht noch, wenn es am Ende laengst haelt. Das einzige Merkmal, das
-- durchweg da ist, ist der POSITIONSWECHSEL -> daraus die Geschwindigkeit ableiten.
-- Gemessen wird am KART selbst (RailCar-GameObject), damit das Laufen des Spielers nichts vortaeuscht;
-- ist das Kart nicht greifbar (Intro-Fahrt), faellt es auf den Body zurueck -- der ist dann ohnehin
-- ans Kart geparentet und bewegt sich mit. Welche Quelle gerade zaehlt, steht live in der UI.
-- Deltas werden erst ab 0.03 s genommen (bei 90 fps waeren Frame-Deltas fast nur Rauschen) und mit einem
-- EMA geglaettet, damit ein einzelner Ruckler weder zuendet noch aussetzt.
local spd = { t = nil, x = 0, y = 0, z = 0, v = 0.0, src = "-" }
local function cart_speed_now()
    local tf, src = nil, "-"
    local car = get_player_railcar()
    if car then
        local go = safe(function() return car:call("get_GameObject") end)
        tf = go and safe(function() return go:call("get_Transform") end) or nil
        if tf then src = "Kart" end
    end
    if not tf then tf = get_body_transform(); if tf then src = "Body" end end
    spd.src = src
    if not tf then spd.t = nil; spd.v = 0.0; return 0.0 end
    local p = safe(function() return tf:call("get_Position") end)
    if not p then return spd.v end
    local now = os.clock()
    if not spd.t then spd.t, spd.x, spd.y, spd.z = now, p.x, p.y, p.z; return spd.v end
    local dt = now - spd.t
    if dt >= 0.03 then
        local dx, dy, dz = p.x - spd.x, p.y - spd.y, p.z - spd.z
        local v = math.sqrt(dx * dx + dy * dy + dz * dz) / dt
        if v > 60.0 then v = spd.v end   -- Teleport/Stage-Wechsel nicht als Tempo werten
        spd.v = spd.v + (v - spd.v) * 0.35
        spd.t, spd.x, spd.y, spd.z = now, p.x, p.y, p.z
    end
    return spd.v
end
local function update_cart_rumble()
    if not cfg.rumble_enabled then rum.t0 = nil; rum_dbg.on = false; return end
    if not (vrmod and vrmod:is_hmd_active()) then rum.t0 = nil; rum_dbg.on = false; return end
    if not cart_ride_now() then rum.t0 = nil; rum_dbg.on = false; rum_dbg.amp = 0.0; spd.t = nil; return end
    local now = os.clock()
    if not rum.t0 then
        rum.t0, rum.next_t = now, 0
        rum.next_clack = now + (tonumber(cfg.rumble_clack_every) or 1.7)
    end
    -- [TEMPO-GATE] JEDEN Frame messen (nicht nur im Puls-Takt), damit die LIVE-Anzeige beim Einstellen
    -- stimmt und das Auslaufen am Ende sofort greift.
    local v     = cart_speed_now()
    local vmin  = tonumber(cfg.rumble_speed_min) or 3.0
    local vfull = math.max(vmin + 0.1, tonumber(cfg.rumble_speed_full) or 9.0)
    if v < vmin then rum_dbg.on = false; rum_dbg.amp = 0.0; return end   -- Schieben/Stillstand: still
    local vk = 1.0
    if cfg.rumble_speed_scale then
        vk = (v - vmin) / (vfull - vmin)
        if vk < 0.0 then vk = 0.0 elseif vk > 1.0 then vk = 1.0 end
    end
    rum_dbg.on = true
    if now < rum.next_t then return end
    rum.next_t = now + math.max(0.03, tonumber(cfg.rumble_rate) or 0.09)

    local t   = now - rum.t0
    local wob = 0.75 + 0.15 * math.sin(t * 7.3) + 0.10 * math.sin(t * 2.1 + 1.3)   -- 0.5..1.0
    local amp = (tonumber(cfg.rumble_amp) or 0.10) * wob * vk   -- [TEMPO-GATE] vk = Tempo-Faktor 0..1
    local dur = math.max(0.02, tonumber(cfg.rumble_dur) or 0.06)
    local frq = math.max(10.0, tonumber(cfg.rumble_freq) or 45.0)

    local la, ra = amp, amp
    if cfg.rumble_clack and now >= (rum.next_clack or 0) then
        rum.next_clack = now + math.max(0.3, tonumber(cfg.rumble_clack_every) or 1.7)
        rum.side = (rum.side == 0) and 1 or 0
        local ca = (tonumber(cfg.rumble_clack_amp) or 0.26) * vk   -- [TEMPO-GATE] Stoesse skalieren mit
        if rum.side == 0 then la, ra = ca, ca * 0.55 else la, ra = ca * 0.55, ca end
        dur = math.min(0.10, dur + 0.03)
    end

    local lj = safe(function() return vrmod:get_left_joystick() end)
    local rj = safe(function() return vrmod:get_right_joystick() end)
    if lj then pcall(function() vrmod:trigger_haptic_vibration(0.0, dur, frq, la, lj) end) end
    if rj then pcall(function() vrmod:trigger_haptic_vibration(0.0, dur, frq, ra, rj) end) end
    rum_dbg.amp = (la + ra) * 0.5
end
-- Eigener on_frame: Haptik gehoert in keinen Render-Pass (die Entries unten laufen mehrfach pro Frame).
re.on_frame(function() pcall(update_cart_rumble) end)

re.on_pre_application_entry("LockScene", function()
    pcall(update_cart_recenter) -- [AUTO-RECENTER] self-gated: zieht die Origin nur im Kart sanft nach
    pcall(update_cart_lean)     -- [KIPP-AUSGLEICH] self-gated: setzt das Global nur im Kart + Kippphase
    pcall(update_yaw_follow)    -- [YAW-FOLLOW] Blick-Basis an die Kart-Fahrtrichtung koppeln (self-gated)
    pcall(cart_knife_swap)      -- [MINECART KNIFE] Messer -> Main wechseln (VOR dem railcar-Gate: auch in den Intros)
    if not railcar_active() then _G.__re4_railcar_reloading = false; return end
    pcall(update_anim_export)
    pcall(update_reload_flag)   -- _G.__re4_railcar_reloading + fade setzen (motion/arm_chain lesen es)
    -- [RELOAD-FADE] Reload-Entry: arm_chain pausiert (ruft den Pin NICHT) -> hier selbst den eased Pin schreiben,
    -- solange fade>0 -> Kopf gleitet in die Reload-Pose statt zu snappen. Nach Reload macht arm_chain den Ease-out.
    if rawget(_G, "__re4_railcar_reloading") == true and (tonumber(rawget(_G, "__re4_railcar_reload_fade")) or 0.0) > 0.0 then
        pcall(apply_spine_pin)
    end
    pcall(force_crosshair)
end)
re.on_application_entry("LateUpdateBehavior", function()
    -- [RELOAD-FADE] Entry-Ease auch post-anim re-asserten (sonst ueberschreibt die Engine-Anim den eased Pin).
    if rawget(_G, "__re4_railcar_reloading") == true and (tonumber(rawget(_G, "__re4_railcar_reload_fade")) or 0.0) > 0.0 then
        pcall(apply_spine_pin)
    end
    pcall(force_crosshair)
end)

re.on_script_reset(function()
    pin.tf = nil; pin.joints = nil; pin.names = nil
    bw_motion = nil; bw_go = nil
end)

-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Minecart" raus (83 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

