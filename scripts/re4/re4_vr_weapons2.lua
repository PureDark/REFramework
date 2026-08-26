-- Builtin implementation: src/mods/vr/games/re4/RE4VRWeapons2.cpp
return

-- ============================================================
-- re4_vr_weapons2.lua — KONSOLIDIERT (2026-07-14):
-- re4_vr_knife.lua + re4_vr_knife_lefthand.lua + re4_vr_knife_lh_damage.lua + re4_vr_wildwest.lua
-- Jede Quelle laeuft in eigener IIFE (function...end) -> Locals isoliert (eigenes 200-Budget),
-- top-level 'return' bleibt lokal. Reihenfolge = alte alphabetische Load-Reihenfolge.
-- ============================================================
if reframework:get_game_name() ~= "re4" then return end

-- [WEAPONS2 UI] Parent-Tree "RE4 VR Weapons 2" — die Feature-Trees nesten sich darunter (Opener hier, Closer am Dateiende).
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Weapons2" raus (1 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- ==================== >>> re4_vr_knife.lua <<< ====================
;(function()
-- re4_vr_knife.lua
-- ============================================================================
-- RE4 VR — Messer-FINISHER-Geste (neues Home fuers Messer-Handling).
--
-- Ziel: Wenn der RT-Finisher-Prompt (Gui_ui2200) sichtbar ist UND das Messer im
-- REVERSE-GRIP gehalten wird (__vr_knife_flip == true), loest eine OBEN-UNTEN-
-- Shake-Handbewegung den echten Xbox-RT aus -> Finisher.
-- Messer RICHTIG-herum + Prompt -> RT bleibt gemutet (kein Finisher).
--
-- Aufgabenteilung (alle Scripte arbeiten zusammen):
-- * re4_vr_crosshair.lua -> Trigger: __re4_is_finisher_prompt (Gui_ui2200)
-- * re4_vr_knife.lua -> DIESES Script: erkennt die Shake-Geste, setzt
-- _G.__re4_knife_finisher_shake = true (kurzer Puls)
-- * re4_vr_binding.lua -> feuert/blockt den echten RT (vigem-Ausgabe, Z509)
-- * re4_vr_motion.lua -> Reverse-Grip-Flip (__vr_knife_flip), Swing, Wurf
--
-- Verifikation ( spielt VR, ImGui NICHT lesbar -> Diagnose per Logdatei):
-- reframework/data/re4_knife_finisher.log (Gate an/aus + Shake-Fire). ICH lese es.
--
-- [PARRY] Zusaetzlich: Messer schuetzend vor dem Gesicht -> loest einen Parry aus (chenstacks auto_parry-
-- Muster: PlayerHeadActionSign.updateParryRequest -> ParryInfo:set_RequestAction/Reserve, wenn get_IsEnable).
-- Gegatet auf die Schutz-Pose (Hand nah am HMD + davor). Der Parry-Teil nutzt einen sdk.hook -> GAME-NEUSTART
-- noetig (der Finisher-Shake-Teil bleibt on_frame -> Reset Scripts reicht).
-- ============================================================================

-- ---- TUNING (ich passe hier an; gemeldet nur das Gefuehl) -----------------
local CFG = {
    -- [LEICHTER 2026-07-24 "zu schwer, oft erst beim 2ten mal"] Shake-Geste rundum toleranter gemacht.
    speed     = 0.80,  -- m/s Mindest-Geschwindigkeit pro Halbschwung (war 1.1 -> leichter erreichbar)
    reversals = 1,     -- EIN Richtungswechsel reicht = einfacher Stich/Jab statt voller Shake (war 2)
    window    = 0.80,  -- s Sammelfenster groesser (war 0.55 -> mehr Zeit)
    fire      = 0.12,  -- s: Dauer des RT-Pulses (ein Tastendruck)
    cooldown  = 0.50,  -- s Sperre nach Ausloesung kuerzer -> schnellerer Retry (war 0.80)
    vert_dom  = 0.50,  -- |dy| muss > vert_dom*horizontal -> auch DIAGONALE Stiche zaehlen (war 1.0 = streng vertikal)
}

-- ---- PARRY (Schutz-Pose vors Gesicht) --------------------------------------
local PCFG = {
    pos_tol = 0.30,  -- m: max Positions-Abstand der Hand zur Referenz-Pose (grosszuegiger)
    rot_tol = 0.70,  -- rad (~40 Grad): max Rotations-Abweichung der Hand zur Referenz-Pose
    window  = 0.50,  -- [TIMING] s: Parry NUR so lange nach dem FRISCHEN Einnehmen der Pose (Skill).
                     -- Dauerhalten pariert NICHT -> man muss die Pose auf den Angriff timen.
}
-- [PARRY] Kalibrierte Referenz-Pose (rechter Controller RELATIV zum HMD), Snapshot 2026-07-04 (natuerliche
-- Halte-Pose, nicht ausgestreckt). p = Position im HMD-Frame, q = Rotation (w,x,y,z). Neu snapshotten -> hier.
local PREF = {
    px =  0.026, py =  0.015, pz = -0.469,
    qw =  0.057, qx =  0.653, qy = -0.054, qz =  0.753,
}
-- [PARRY] EIN Slider: Toleranz-Multiplikator um die Referenz-Pose (groesser = leichter). Persistent (JSON).
local KCFG = { tol = 1.0 }
do
    local ok, d = pcall(function() return json.load_file("re4_vr/re4_vr_knife_parry.json") end)
    if ok and type(d) == "table" and type(d.parry_tol) == "number" then KCFG.tol = d.parry_tol end
end
local function kcfg_save() pcall(function() json.dump_file("re4_vr/re4_vr_knife_parry.json", { parry_tol = KCFG.tol }) end) end

-- ---- State (kein top-level local-Sorgen: eigenes Script) ---------------------
local st = {
    last_p = nil, last_time = 0, last_dir = 0, reversals = 0,
    window_end = 0, fire_until = 0, cooldown_end = 0, gate_prev = false,
}

-- ---- Gate-Bedingungen -------------------------------------------------------
local function prompt_visible()
    local fn = rawget(_G, "__re4_is_finisher_prompt")
    return type(fn) == "function" and fn() == true
end
local function reverse_grip() return rawget(_G, "__vr_knife_flip")     == true end
-- [LH_CLONE] auch der Links-Klon zaehlt als "Messer draussen" (nicht engine-equippt -> knife_equipped=false).
local function knife_out()    return rawget(_G, "__re4_knife_equipped") == true or rawget(_G, "__re4_knife_left_clone") == true end

-- ---- Frame ------------------------------------------------------------------
re.on_frame(function()
    -- [KS_GLOBAL 2026-07-15] War nur __re4_ks4_active (= nur der Kick). Jetzt JEDER Killswitch -- weiter
    -- unten wird ohnehin schon gegen __re4_holster_killswitch (= ks_active) geprueft, das hier war die
    -- Luecke. __re4_ks_active ist bei KS4 auch true -> alter Fall bleibt abgedeckt.
    if rawget(_G, "__re4_ks_active") == true then return end
    local now = os.clock()
    -- Fire-Flag = frisch, binding.lua liest es. Auto-Clear nach CFG.fire.
    _G.__re4_knife_finisher_shake = (now < st.fire_until)

    -- [PARRY_POSE] Messer schuetzend vor dem Gesicht? Rechte Hand (Messer) nah am HMD + davor. Alles in
    -- VR-Space (Controller vs HMD) -> konsistent, kein Game-World-Mix. Konsument: Parry-Hook (unten).
    do
        local pose = false
        -- [PARRY] NUR wenn das Messer wirklich in der Hand ist: waehrend eines Wurfs bleibt knife_out
        -- true (das Messer fliegt als Objekt, gilt weiter als equippt) -> __re4_knife_flying zusaetzlich
        -- ausschliessen, sonst liesse sich mitten im Wurf parieren.
        if knife_out() and rawget(_G, "__re4_knife_flying") ~= true and vrmod and vrmod:is_hmd_active() then
            -- [KNIFE_HAND] Messer-Hand: links = ctrls[1] + gespiegelte Referenz, rechts = ctrls[2] + PREF.
            -- [LH_CLONE] der Links-Klon ist auch "links" (hand-Global ist im Klon "none").
            local left  = rawget(_G, "__re4_knife_hand") == "left" or rawget(_G, "__re4_knife_left_clone") == true
            local cidx  = left and 1 or 2
            local ctrls = vrmod:get_controllers()
            if ctrls and #ctrls >= cidx then
                local hp = vrmod:get_position(0)
                local hq = vrmod:get_rotation(0); hq = hq and hq:to_quat()
                local rp = vrmod:get_position(ctrls[cidx])
                local rq = vrmod:get_rotation(ctrls[cidx]); rq = rq and rq:to_quat()
                if hp and hq and rp and rq then
                    -- Referenz je Hand: rechts = PREF (kalibriert), links = PREF horizontal gespiegelt
                    -- (Pos-X negiert, Quaternion (w,x,-y,-z) = sagittale Spiegelung wie bei der Hand-Pose).
                    local rpx = left and -PREF.px or PREF.px
                    local rqw, rqx = PREF.qw, PREF.qx
                    local rqy = left and -PREF.qy or PREF.qy
                    local rqz = left and -PREF.qz or PREF.qz
                    local hqc  = hq:conjugate()
                    local relp = hqc * Vector3f.new(rp.x - hp.x, rp.y - hp.y, rp.z - hp.z)
                    local relq = (hqc * rq):normalized()
                    -- Positions-Abstand zur Referenz
                    local pdx, pdy, pdz = relp.x - rpx, relp.y - PREF.py, relp.z - PREF.pz
                    local pdist = math.sqrt(pdx * pdx + pdy * pdy + pdz * pdz)
                    -- Rotations-Winkel zur Referenz (Quaternion-Dot -> Winkel)
                    local dot = math.abs(relq.w * rqw + relq.x * rqx + relq.y * rqy + relq.z * rqz)
                    if dot > 1.0 then dot = 1.0 end
                    local rang = 2.0 * math.acos(dot)
                    -- EIN Toleranz-Regler skaliert Position UND Rotation gemeinsam
                    if pdist < (PCFG.pos_tol * KCFG.tol) and rang < (PCFG.rot_tol * KCFG.tol) then pose = true end
                end
            end
        end
        _G.__re4_knife_parry_pose = pose
        -- [TIMING] nur die FRISCHE Flanke (Hochreissen in die Pose) oeffnet ein kurzes Parry-Fenster.
        -- Dauerhalten -> Fenster laeuft ab -> kein Auto-Parry mehr, bis man neu hochreisst.
        if pose and not st.parry_pose_prev then
            _G.__re4_knife_parry_fresh_until = now + PCFG.window
        end
        st.parry_pose_prev = pose
    end

    -- GATE: nur Messer draussen + Reverse-Grip + Prompt sichtbar
    local gate = knife_out() and reverse_grip() and prompt_visible()
    if not gate or now < st.cooldown_end then
        st.last_p = nil; st.reversals = 0; st.last_dir = 0
        return
    end

    -- ROHE Controller-Position der MESSER-Hand (wie update_knife_swing in motion).
    -- [LH_CLONE/KNIFE_HAND] Messer links (Klon oder engine-links) -> linker Controller (ctrls[1]),
    -- sonst rechts (ctrls[2]). Der Klon ist im hand-Global "none" -> extra abfragen.
    if not vrmod or not vrmod:is_hmd_active() then st.last_p = nil; return end
    local controllers = vrmod:get_controllers()
    local shake_left  = rawget(_G, "__re4_knife_hand") == "left" or rawget(_G, "__re4_knife_left_clone") == true
    local cidx        = shake_left and 1 or 2
    if not controllers or #controllers < cidx then st.last_p = nil; return end
    -- Hand-Wechsel -> alte last_p stammt vom ANDEREN Controller -> Velocity-Spike -> Phantom-Reversal.
    -- Bei cidx-Wechsel Zaehler+last_p frisch (gleiche Falle wie update_knife_swing im motion).
    if st.last_cidx ~= cidx then
        st.last_cidx = cidx; st.last_p = nil; st.reversals = 0; st.last_dir = 0
    end
    local wp = vrmod:get_position(controllers[cidx])
    if not wp then st.last_p = nil; return end

    local dt = now - st.last_time
    if dt <= 0.001 then return end   -- on_frame kann mehrfach pro Present feuern -> Mini-dt verwerfen, State unangetastet
    st.last_time = now
    if dt >= 0.2 then                -- zu grosse Luecke -> sauberer Neustart
        st.last_p = Vector3f.new(wp.x, wp.y, wp.z); st.last_dir = 0; st.reversals = 0
        return
    end

    -- Sammelfenster abgelaufen -> Zaehler + Richtung zuruecksetzen
    if now > st.window_end then st.reversals = 0; st.last_dir = 0 end

    if st.last_p then
        local dy    = wp.y - st.last_p.y
        local dx    = wp.x - st.last_p.x
        local dz    = wp.z - st.last_p.z
        local horiz = math.sqrt(dx * dx + dz * dz)
        local vy    = dy / dt
        -- nur vertikal-dominante, schnelle Halbschwuenge zaehlen (echtes OBEN-UNTEN)
        if math.abs(dy) > CFG.vert_dom * horiz and math.abs(vy) >= CFG.speed then
            local dir = (vy > 0) and 1 or -1
            if st.last_dir ~= 0 and dir ~= st.last_dir then
                st.reversals = st.reversals + 1
            end
            st.last_dir   = dir
            st.window_end = now + CFG.window
            if st.reversals >= CFG.reversals then
                st.fire_until   = now + CFG.fire
                st.cooldown_end = now + CFG.cooldown
                st.reversals = 0; st.last_dir = 0
            end
        end
    end
    st.last_p = Vector3f.new(wp.x, wp.y, wp.z)
end)

-- [PARRY] chenstacks auto_parry-Muster, aber NUR in der Schutz-Pose: oeffnet das Spiel ein parrybares
-- Fenster (ParryInfo:get_IsEnable) UND das Messer ist schuetzend vor dem Gesicht (__re4_knife_parry_pose)
-- -> RequestAction+RequestReserve = Parry ausloesen. sdk.hook -> braucht kompletten GAME-NEUSTART.
if not _G.__re4_knife_parry_hooked then
    _G.__re4_knife_parry_hooked = true
    local td = sdk.find_type_definition("chainsaw.PlayerHeadActionSign")
    local m  = td and td:get_method("updateParryRequest()")
    if m then
        sdk.hook(m,
            function(args)
                pcall(function()
                    -- [TIMING] nur wenn die Pose FRISCH eingenommen wurde (Fenster laeuft) -> Skill statt Dauerhalt.
                    local u = tonumber(rawget(_G, "__re4_knife_parry_fresh_until"))
                    if not (u and os.clock() < u) then return end
                    local inst = sdk.to_managed_object(args[2]); if not inst then return end
                    local info = inst:call("get_ParryInfo"); if not info then return end
                    if info:call("get_IsEnable") == true then
                        info:call("set_RequestAction", true)
                        info:call("set_RequestReserve", true)
                        -- [PARRY-RESTORE 2026-07-20] Der native Parry equippt das ECHTE Messer --
                        -- also RECHTS. War es vorher als Klon LINKS, kill die "beide Haende"-Regel den
                        -- Klon und das Messer bleibt danach rechts haengen ("nach dem Parry ist es rechts").
                        -- Denselben Latch setzen wie der Finisher: statt zu killen wird das rechte Messer
                        -- geholstert und der Links-Klon neu aufgebaut. Nur wenn wirklich ein Klon links ist.
                        if rawget(_G, "__re4_knife_left_clone") == true then
                            _G.__re4_clone_finisher_restore   = true
                            _G.__re4_clone_finisher_restore_t = os.clock()
                            -- [PARRY_KEEP_GUN 2026-07-31] NUR im Links-Klon-Fall: die rechts
                            -- equippte Waffe soll da bleiben, wo sie ist. Beim Parry mit dem ECHTEN
                            -- Messer (rechts) bleibt alles wie bisher -- deshalb steht das hier drin
                            -- und nicht eine Ebene hoeher.
                            -- Der native Parry equippt gleich das Messer; motion.lua wuerde dann die
                            -- Schusswaffe aus der rechten Hand nehmen (find_weapon folgt der equippten
                            -- Waffe). Dieses Zeitfenster sagt motion: waehrenddessen die zuletzt
                            -- gehaltene Schusswaffe weiter an der rechten Hand fuehren.
                            -- Zeitbasiert -> laeuft von SELBST ab, kann nicht haengenbleiben.
                            _G.__re4_parry_keep_gun_until = os.clock() + 2.0   -- Timeout (Obergrenze)
                            -- Fruehester Rueckhol-Zeitpunkt: die Parry-Anim braucht einen Moment, ein
                            -- sofortiges Equip wuerde sie abwuergen. Vorher lief es stur auf das
                            -- 2-Sekunden-Timeout -> die Waffe war ~2,2 s weg (Log 1475.22 -> 1477.41).
                            _G.__re4_parry_keep_gun_from = os.clock() + 0.30
                            -- [PARRY_KEEP_GUN 2026-07-31] Die Waffen-ID wird hier NICHT gelesen.
                            -- Diese Stelle steht VOR get_ctx/sc/safe (erst ab Z.~393 definiert) -- ein
                            -- Zugriff darauf ist nil, stirbt im umgebenden pcall LAUTLOS, und alles
                            -- dahinter lief nie. Genau daran sind mehrere Testrunden verbrannt.
                            -- Die zuletzt gehaltene Waffe schreibt stattdessen der on_frame-Block am
                            -- DATEIENDE mit (__re4_parry_last_gun_wid) -- dort ist alles sichtbar.
                        end
                    end
                end)
            end,
            function(r) return r end)
    end
end

-- [PARRY] EIN Slider (Desktop-Mirror): Toleranz um die kalibrierte Pose. Groesser = leichter auszuloesen.
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4 VR - Messer Parry" raus (8 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

end)()

-- ==================== >>> re4_vr_knife_lefthand.lua <<< ====================
;(function()
-- re4_vr_knife_lefthand.lua
-- ============================================================================
-- RE4 VR — Messer in der LINKEN Hand (gespiegeltes Gegenstueck zum Rechtshand-Messer).
--
-- SCHRITT 1 (2026-07-07): Nur ZIEHEN/STAUEN mit links + der Tri-State __re4_knife_hand.
-- * LINKER Grip + linke Hand am Brust-Holster (__vr_knife_chest_pos) -> Messer in die LINKE Hand ziehen.
-- * Linker Grip erneut am Holster (Messer schon links) -> wegstecken (bare hands).
-- * Setzt __re4_knife_left_intent (persistent) -> re4_vr_weapons.lua leitet daraus __re4_knife_hand ab.
-- * Das MESH pinnt re4_vr_motion.lua bei hand=="left" an die linke Hand (gespiegelte Offsets).
--
-- Bewusst EIGENES Script (200-Local-Limit der grossen Chunks nicht sprengen). Der linke Grip ist FREI
-- (re4_vr_binding.lua apply_l_grip_knife = No-Op). Deferred Equip laeuft ueber den EXPORTIERTEN Holster-
-- Hook (_G.__re4_knife_defer) -> KEIN zweiter sdk.hook, KEIN Game-Neustart noetig.
--
-- SPAETER (eigene Schritte, gespiegelt von rechts): Swing/Melee, Wurf, Flip (linker Trigger, Tap<Hold),
-- Parry/Finisher-Pose, Hand-Pose (knifepose gespiegelt), FL-Kegel ans HMD bei hand=="left".
-- ============================================================================

local KNIFE_IDS = {
    [5000]=true, [5001]=true, [5002]=true, [5003]=true, [5006]=true,
    [6107]=true, [6108]=true, [6305]=true,
}

-- ---- Greif-Config LINKE Hand (EIGENE Slider, unabhaengig von rechts) -------
-- Die linke Hand referenziert anders als rechts -> eigener Radius + Release, im UI eingestellt.
-- Persistent in re4_vr_knife_lefthand.json. Modell wie rechts: Presse in Trigger-Zone armt, Loslassen in
-- Release-Zone feuert. Defaults grosszuegig (linke Hand sass im Log bei ~0.175-0.18), du tunst nach.
-- tap_sec = Tap/Hold-Grenze fuer den Links-Flip (Flip auf Loslassen, kein Zucken): Release KUERZER als
-- tap_sec = Flip; laenger gehalten = DPAD. Zu klein -> normaler Tap wird faelschlich als Halten gewertet
-- (kein Flip); ~0.15-0.18 ist der Sweet Spot. Live per Slider tunbar.
-- [BLUT_SCHALTER 2026-08-06 -- Crashdump] blood_on = unser Blut-Replay am Links-Messer-Treffer
-- (saveStamp mit eingefangenem Stamp/Joint, s. weiter unten). AUS = nur der Effekt faellt weg, Schaden
-- und Trefferton bleiben. Da fuer den A/B-Test nach dem Wurf-Crash (Nullzeiger in
-- chainsaw.EPVExpertDamageEffect.findTargetJoint, LateUpdate der Engine, kein Lua-Frame im Stack).
local LCFG = { trigger = 0.22, release = 0.30, tap_sec = 0.18, flip_speed = 0.3, swing_speed = 3.0, blood_on = true }
-- [KNIFE_ADA] Aktiver Charakter fuer ALLE Messer-Configs dieses Files. MUSS vor der ersten
-- Nutzung stehen (lcfg_path weiter unten) -- sonst waere es dort ein nil-Global und die
-- Umschaltung liefe still ins Leere. [[feedback-lua-forward-decl]]
local _lh_char = nil   -- "leon" | "ada"; nil = noch nie gesetzt
-- [KNIFE_ADA] Greif-/Flip-Werte der LINKEN Hand ebenfalls pro Charakter (Leon/Ada).
local LCFG_PATH     = "re4_vr/re4_vr_knife_lefthand.json"
local LCFG_PATH_ADA = "re4_vr/re4_vr_knife_lefthand_ada.json"
local function lcfg_path() return (_lh_char == "ada") and LCFG_PATH_ADA or LCFG_PATH end
local function lcfg_load(path)
    local ok, d = pcall(function() return json.load_file(path) end)
    if not (ok and type(d) == "table") then return false end
    if tonumber(d.grab_trigger) then LCFG.trigger = tonumber(d.grab_trigger) end
    if tonumber(d.grab_release) then LCFG.release = tonumber(d.grab_release) end
    if tonumber(d.flip_tap)     then LCFG.tap_sec = tonumber(d.flip_tap) end
    if tonumber(d.flip_speed)   then LCFG.flip_speed = tonumber(d.flip_speed) end
    if tonumber(d.swing_speed)  then LCFG.swing_speed = tonumber(d.swing_speed) end
    if type(d.blood_on) == "boolean" then LCFG.blood_on = d.blood_on end   -- [BLUT_SCHALTER]
    return true
end
lcfg_load(LCFG_PATH)
_G.__re4_knife_blood_on = LCFG.blood_on   -- [BLUT_SCHALTER] Startwert ins Global (Treffer liest es dort)
_G.__re4_knife_lt_flip_tap = LCFG.tap_sec       -- binding.lua liest das fuer die Flip/DPAD-Unterscheidung
_G.__re4_knife_lh_flip_speed = LCFG.flip_speed  -- clone_apply_pose liest das (Flip-Tempo + Finger-Kopplung)
_G.__re4_knife_lh_swing_speed = LCFG.swing_speed  -- Schwung-Schwelle (nur noch SOUND); persistent
local function lcfg_save()
    _G.__re4_knife_lt_flip_tap = LCFG.tap_sec
    _G.__re4_knife_lh_flip_speed = LCFG.flip_speed
    _G.__re4_knife_lh_swing_speed = LCFG.swing_speed
    _G.__re4_knife_blood_on = LCFG.blood_on   -- [BLUT_SCHALTER]
    local p = lcfg_path()
    -- [HARD-GUARD] als Ada NIE in Leons Datei schreiben und umgekehrt
    if _lh_char == "ada"  and p == LCFG_PATH     then return end
    if _lh_char == "leon" and p == LCFG_PATH_ADA then return end
    -- [UNBEKANNT = NICHT SCHREIBEN 2026-07-19] Die Luecke, durch die Adas Greif-Werte in LEONS
    -- re4_vr_knife_lefthand.json gelandet sind (grab_trigger/grab_release, per Baseline-Pruefer gefunden):
    -- setzt die Charakter-Erkennung aus, ist _lh_char nil -> lcfg_path faellt auf Leons Datei zurueck,
    -- und die beiden Guards oben greifen beide NICHT (sie pruefen nur "ada" bzw. "leon").
    -- Bei unbekanntem Charakter wird jetzt GAR NICHT geschrieben. Verlorene Slider-Zuege sind harmlos --
    -- ein falsch beschriebener Leon-Wert ist es nicht.
    if _lh_char ~= "ada" and _lh_char ~= "leon" then return end
    pcall(function() json.dump_file(p,
        { grab_trigger = LCFG.trigger, grab_release = LCFG.release, flip_tap = LCFG.tap_sec, flip_speed = LCFG.flip_speed,
          swing_speed = LCFG.swing_speed, blood_on = LCFG.blood_on }) end)
end
local last_d = nil   -- letzter gemessener Abstand (fuer die UI-Anzeige)

-- ---- kleine Helfer ---------------------------------------------------------
-- [SAFE_GIBT_IMMER_EINEN_WERT 2026-07-31] Ohne das explizite `return nil` liefert diese
-- Funktion im Fehlerfall GAR KEINEN Wert (nicht nil, NICHTS). In tostring(safe(...)) kommt dann
-- kein Argument an -> "bad argument #1 to 'tostring' (value expected)" -> der ganze umgebende
-- Aufruf stirbt. Genau daran ist am 31.07. der Bogen-Reload gestorben. Im Erfolgsfall unveraendert.
local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end
local function sc(o, m, a)   -- nur 0 oder 1 Argument noetig -> kein unpack (LuaJIT/5.1-sicher)
    if not o then return nil end
    if a == nil then return safe(function() return o:call(m) end) end
    return safe(function() return o:call(m, a) end)
end

-- ---- Player / PlayerEquipment (fuer das deferred Equip) --------------------
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
local pe_td = sdk.typeof("chainsaw.PlayerEquipment")
local _pe = nil
local function get_pe()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.pe() end
    if _pe and safe(function() return _pe:call("get_Context") end) then return _pe end
    local ctx = get_ctx(); local head = ctx and sc(ctx, "get_HeadGameObject"); if not head then return nil end
    _pe = sc(head, "getComponent(System.Type)", pe_td); return _pe
end

-- [LH_CLONE RELOAD-KILL] Genereller Reload-Detektor: steht irgendein Motion-FSM-Layer der Body-GO auf einer
-- "RELOAD"-Node, laeuft eine (native) Nachlade-Anim -- egal welche Waffe, egal ob Mag-/Rack-Pose-Flags gesetzt
-- sind. Technik 1:1 aus motion.native_reload_active, aber wid-unabhaengig. Comp gecacht (kein getComponent/Frame
-- ausser bei Body-Wechsel); laeuft eh nur solange der linke Klon existiert.
local _mfsm_td = sdk.typeof("via.motion.MotionFsm2")
local _mfsm = { go = nil, comp = nil }
local function player_is_reloading()
    local ctx = get_ctx(); if not ctx then return false end
    local go = sc(ctx, "get_BodyGameObject"); if not go then return false end
    if _mfsm.go ~= go then _mfsm.go = go; _mfsm.comp = nil end
    if not _mfsm.comp then _mfsm.comp = _mfsm_td and sc(go, "getComponent(System.Type)", _mfsm_td) or nil end
    local m = _mfsm.comp; if not m then return false end
    for layer = 0, 6 do
        local n = sc(m, "getCurrentNodeName", layer)
        if n and tostring(n):find("RELOAD", 1, true) then return true end
    end
    return false
end

-- ---- VR: linker Grip -------------------------------------------------------
local function left_grip_pressed()
    if not vrmod or not vrmod:is_hmd_active() then return false end
    local act = safe(function() return vrmod:get_action_grip() end)
    local lj  = safe(function() return vrmod:get_left_joystick() end)
    if not act or not lj then return false end
    local ok, v = pcall(function() return vrmod:is_action_active(act, lj) end)
    return ok and v == true
end

-- Grab-Haptik: EXAKT derselbe kurze Puls wie rechts (holster do_grab), nur auf den LINKEN Controller.
local function left_grab_haptic()
    local lj = safe(function() return vrmod:get_left_joystick() end)
    if lj then pcall(function() vrmod:trigger_haptic_vibration(0.0, 0.06, 200.0, 0.9, lj) end) end
end
-- Grab-Sound: derselbe wie rechts (Holster-Export, ueber den SoundContainer des Messer-GO = hand-neutral).
local function left_grab_sound()
    local sp = rawget(_G, "__re4_knife_play_grab_sound")
    if type(sp) == "function" then sp() end
end

-- ---- deferred Equip/Stow (im Holster-updateOnFrameHead-Hook ausgefuehrt) ----
local function defer_draw_left()
    local defer = rawget(_G, "__re4_knife_defer"); if type(defer) ~= "function" then return false end
    local sup = rawget(_G, "__re4_knife_set_suppress"); if type(sup) == "function" then sup(false) end
    defer(function()
        local pe = get_pe(); if not pe then return end
        _G.__re4_knife_draw_ours_t = os.clock()   -- [KNIFE-GATE 2026-07-20] eigener Links-Zug -> Hook laesst ihn durch
        pcall(function() pe:call("clearRequest") end)
        pcall(function() pe:call("requestEquipKnife") end)
        pcall(function() pe:call("execChangeWeapon") end)
    end)
    return true
end
local function defer_stow_left()
    local defer = rawget(_G, "__re4_knife_defer"); if type(defer) ~= "function" then return false end
    local sup = rawget(_G, "__re4_knife_set_suppress"); if type(sup) == "function" then sup(true) end
    _G.__vr_post_stow_until = os.clock() + 0.6   -- binding: Aim-Auto-Draw kurz sperren (kein Flackern)
    defer(function()
        local pe = get_pe(); if not pe then return end
        pcall(function() pe:call("clearRequest") end)
        pcall(function() pe:call("requestEquipBareHand", false, false) end)
        pcall(function() pe:call("execChangeWeapon") end)
    end)
    return true
end

-- ---- Hand-Pose (knifepose, gespiegelt R->L) --------------------------------
-- Rechte Capture (gestures "knifepose", 18 Bones, [W,X,Y,Z], R_Palm=Identity) HIER eingebettet, damit das
-- Gestures-Script danach GELOESCHT werden kann. Spiegelung R->L per MIRROR (sagittal, Z-normale Ebene):
-- L = (w, -x, -y, z) -> erhaelt die Flexion (Bones [w,0,0,z]) und spiegelt Splay/Daumen.
local KNIFE_POSE_R = {
    R_IndexF1  = {0.9353885650634766, 0.049021635204553604, -0.018328439444303513, 0.3497273623943329},
    R_IndexF2  = {0.7740004062652588, 0.0, 0.0, 0.633185088634491},
    R_IndexF3  = {0.9165631532669067, 0.0, 0.0, 0.3998900055885315},
    R_MiddleF1 = {0.8989609479904175, 0.005545048974454403, 0.013179749250411987, 0.43779537081718445},
    R_MiddleF2 = {0.7572856545448303, 0.0, 0.0, 0.6530838012695313},
    R_MiddleF3 = {0.9105826020240784, 0.0, 0.0, 0.41332709789276123},
    R_Palm     = {1.0, 0.0, 0.0, 0.0},
    R_PinkyF1  = {0.7959001064300537, -0.05373960733413696, -0.027164660394191742, 0.6024260520935059},
    R_PinkyF2  = {0.8307902216911316, 0.0, 0.0, 0.5565857291221619},
    R_PinkyF3  = {0.9379373788833618, 0.0, 0.0, 0.346804678440094},
    R_RingF1   = {0.8344995379447937, -0.018377188593149185, -0.027703266590833664, 0.5500048398971558},
    R_RingF2   = {0.813831627368927, 0.0, 0.0, 0.5811007618904114},
    R_RingF3   = {0.9315847158432007, 0.0, 0.0, 0.36352434754371643},
    R_Thumb1   = {0.9212102890014648, 0.38289788365364075, -0.0038296207785606384, 0.06889265775680542},
    R_Thumb2   = {0.9909763932228088, 0.0, 0.13403624296188354, 0.0},
    R_Thumb3   = {0.9985861778259277, 0.0, -0.05315697565674782, 0.0},
}
-- Spiegel-Vorzeichen (w,x,y,z). w egal (q == -q). z=-1 = Vorwaerts-Flexion (Finger nach hinten -> z drehen).
-- Aktuell (w,x,-y,-z) = X-normale Spiegel-Ebene. Falls Splay/Daumen noch daneben: Alternative {-1,1,-1} (Y-normal).
local MIRROR = { w = 1, x = 1, y = -1, z = -1 }
local KNIFE_POSE_L = {}
for rname, q in pairs(KNIFE_POSE_R) do
    KNIFE_POSE_L["L_" .. rname:sub(3)] = { q[1]*MIRROR.w, q[2]*MIRROR.x, q[3]*MIRROR.y, q[4]*MIRROR.z }
end
-- [TOTER DUMP RAUS 2026-07-17] Hier stand ein json.dump_file nach "re4_vr/re4_vr_knife_lefthand_pose.json".
-- Reiner Debug-Export: bei JEDEM Script-Load geschrieben, aber von KEINEM Script je gelesen (per Grep ueber
-- alle aktiven Scripte belegt) -- die Pose lebt als Lua-Tabelle KNIFE_POSE_L oben im Code. Die verwaiste
-- JSON wurde mitgeloescht. Zum Anschauen der gespiegelten Pose: KNIFE_POSE_R + MIRROR direkt hier lesen.

-- motion.lua ruft das im Post-Anim-Pass -> linke Hand nimmt die gespiegelte Messer-Griff-Pose ein,
-- solange das Messer LINKS ist. Nutzt den reload.lua-Joint-Writer (getJointByName + set_LocalRotation).
_G.__re4_apply_left_knife_pose = function()
    -- [LH_CLONE] Im Klon-Modus ist __re4_knife_hand "none" (Messer nicht equippt) -> Pose zusaetzlich am
    -- Klon-Flag anwenden, sonst kommt die Links-Messer-Handpose beim Ziehen nicht mehr.
    if rawget(_G, "__re4_knife_hand") ~= "left" and rawget(_G, "__re4_knife_left_clone") ~= true then return end
    local ap = rawget(_G, "__re4_reload_apply_pose_bones")
    if type(ap) == "function" then ap(KNIFE_POSE_L, 1.0) end
    -- [FLIP FINGER] waehrend des Flips die Finger kurz oeffnen (Peak bei halbem Flip), wie rechts (motion
    -- knife_flip_finger_open ist auf __re4_knife_equipped gated -> greift beim Klon nicht). L-Bones, additive
    -- Rotation um lokale X. flip_lerp kommt als Global aus clone_apply_pose (weiter unten).
    local lp = tonumber(rawget(_G, "__re4_knife_lh_flip_lerp")) or 0.0
    local bump = 4.0 * lp * (1.0 - lp)
    if bump > 0.001 then
        local deg = tonumber(rawget(_G, "__re4_knife_flip_finger_deg")) or -35.0
        local h = -(math.rad(deg * bump) * 0.5)   -- links negiert (Spiegelung der rechten Strecke)
        local add = Quaternion.new(math.cos(h), math.sin(h), 0.0, 0.0)
        local ctx = get_ctx(); local body = ctx and sc(ctx, "get_BodyGameObject")
        local tf = body and sc(body, "get_Transform")
        if tf then
            for _, bn in ipairs({ "L_IndexF1", "L_MiddleF1", "L_RingF1", "L_PinkyF1" }) do
                local j = safe(function() return tf:call("getJointByName", bn) end)
                if j then
                    local cur = safe(function() return j:call("get_LocalRotation") end)
                    if cur then pcall(function() j:call("set_LocalRotation", (cur * add):normalized()) end) end
                end
            end
        end
    end
end

-- ---- PRO-MESSER Links-Offsets (Mesh-Feinschliff pro Waffen-ID) --------------
-- __re4_knife_lh_off_map[wid] = {px,py,pz, rx,ry,rz}. motion.lua liest es im Links-Pin (additiv auf die
-- gespiegelte Basis). Persistent in re4_vr_knife_lh_offsets.json. Jedes Messer eigenstaendig.
_G.__re4_knife_lh_off_map = _G.__re4_knife_lh_off_map or {}
-- =====================================================================
-- [KNIFE_ADA 2026-07-19] Messer-Offsets PRO CHARAKTER (Leon/Ada).
-- =====================================================================
-- Gleiches Muster wie das Messer-Holster in re4_vr_holster.lua. Leons Dateien bleiben
-- unangetastet; Ada bekommt eigene, beim ersten Mal aus Leons Werten vorbelegt.
--
-- __re4_char_now: "ada" | "leon" | nil = UNBEKANNT. nil ist entscheidend -- bei unbekanntem
-- Body (Ladebildschirm, Player gerade neu instanziiert) darf NICHT auf Leon zurueckgefallen
-- werden, sonst landet ein Slider-Zug waehrend eines Aussetzers in LEONS Datei.
-- Guarded definiert: motion.lua/holster.lua koennen dieselbe Funktion mitbenutzen, erste gewinnt.
-- [CHAR_STICKY 2026-07-19] IDENTISCH zur Definition in re4_vr_motion.lua (erste gewinnt).
-- Aussetzer der Erkennung (Body kurz weg) lieferten nil -> alle charakter-abhaengigen Keys rutschten
-- fuer ein paar Frames in Leons Namensraum. Jetzt: letzter BEKANNTER Charakter statt nil.
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
    -- [ADA_MERCS_BODY 2026-08-03] Adas Mercs-Body "ch3a8z0_MC_body" zaehlt ebenfalls als "ada"
    -- (dasselbe Modell, gemeinsames Tuning). MUSS identisch zur Kopie in re4_vr_motion.lua bleiben --
    -- beide sind guarded, es gewinnt die zuerst geladene Datei.
    if n == "ch3a8z0_body" or n == "ch3a8z0_MC_body" then c = "ada"
    elseif n == "ch0a0z0_body" or n == "ch0a1z0_body" then c = "leon" end
    if c then _G.__re4_char_last = c; return c end
    return nil   -- [STICKY ZURUECKGENOMMEN] siehe unten
end

local LH_OFF_PATH = "re4_vr/re4_vr_knife_lh_offsets.json"
local LH_OFF_PATH_ADA = "re4_vr/re4_vr_knife_lh_offsets_ada.json"
local LH_FLIP_PATH_ADA = "re4_vr/re4_vr_knife_lh_flip_offsets_ada.json"
local function lh_path()      return (_lh_char == "ada") and LH_OFF_PATH_ADA  or LH_OFF_PATH end
local function lh_flip_path() return (_lh_char == "ada") and LH_FLIP_PATH_ADA or "re4_vr/re4_vr_knife_lh_flip_offsets.json" end
-- [HARD-GUARD] Zweite, unabhaengige Sicherung: waehrend Ada gesteuert wird, kann Leons Datei
-- physisch nicht geschrieben werden -- egal ob irgendwo ein veralteter Pfad durchrutscht.
local function lh_write_allowed(path)
    if _lh_char == "ada"  and (path == LH_OFF_PATH or path == "re4_vr/re4_vr_knife_lh_flip_offsets.json") then return false end
    if _lh_char == "leon" and (path == LH_OFF_PATH_ADA or path == LH_FLIP_PATH_ADA) then return false end
    -- [UNBEKANNT = NICHT SCHREIBEN 2026-07-19] s. lcfg_save: bei ausgesetzter Erkennung ist
    -- _lh_char nil, die Pfad-Wahl faellt auf LEONS Datei und beide Guards oben greifen nicht.
    if _lh_char ~= "ada" and _lh_char ~= "leon" then return false end
    return true
end
do
    local ok, d = pcall(function() return json.load_file(LH_OFF_PATH) end)
    if ok and type(d) == "table" then
        for k, v in pairs(d) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                _G.__re4_knife_lh_off_map[wid] = {
                    px = tonumber(v.px) or 0.0, py = tonumber(v.py) or 0.0, pz = tonumber(v.pz) or 0.0,
                    rx = tonumber(v.rx) or 0.0, ry = tonumber(v.ry) or 0.0, rz = tonumber(v.rz) or 0.0 }
            end
        end
    end
end
-- [DEFAULT VON 5006 2026-07-08, so gewollt] wp5006 als Default-Offset fuer ALLE anderen Messer -- nur wenn
-- sie noch KEINEN eigenen Eintrag haben (per-Messer-Tuning bleibt Vorrang).
do
    local base = _G.__re4_knife_lh_off_map[5006]
    if base then
        for wid in pairs(KNIFE_IDS) do
            if wid ~= 5006 and not _G.__re4_knife_lh_off_map[wid] then
                _G.__re4_knife_lh_off_map[wid] = { px = base.px, py = base.py, pz = base.pz, rx = base.rx, ry = base.ry, rz = base.rz }
            end
        end
    end
end
local function lh_off_save()
    local out = {}
    for wid, v in pairs(_G.__re4_knife_lh_off_map) do out[tostring(wid)] = v end
    local p = lh_path()
    if not lh_write_allowed(p) then return end   -- [HARD-GUARD]
    pcall(function() json.dump_file(p, out) end)
end
local function get_equip_wid()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.equip_wid() end
    local ctx = get_ctx(); local hu = ctx and sc(ctx, "get_HeadUpdater"); if not hu then return nil end
    local wid = sc(hu, "get_EquipWeaponID")
    if type(wid) == "number" then return wid end
    if wid ~= nil then local ok, b = pcall(function() return wid.value__ end); if ok and type(b) == "number" then return b end end
    return nil
end

-- ---- PRO-MESSER Links-FLIP-Offsets (Griff-Feinschliff im geflippten/Reverse-Grip-Zustand) ----------
-- __re4_knife_flip_lh_map[wid] = {x,y,z}. motion.lua liest es im Links-Flip-Offset (linker Hand-Frame,
-- skaliert mit dem Flip-Lerp). EIGENE Werte pro Messer (nicht von rechts gespiegelt). Persistent.
_G.__re4_knife_flip_lh_map = _G.__re4_knife_flip_lh_map or {}
local LH_FLIP_PATH = "re4_vr/re4_vr_knife_lh_flip_offsets.json"
do
    local ok, d = pcall(function() return json.load_file(LH_FLIP_PATH) end)
    if ok and type(d) == "table" then
        for k, v in pairs(d) do
            local wid = tonumber(k)
            if wid and type(v) == "table" then
                _G.__re4_knife_flip_lh_map[wid] = { x = tonumber(v.x) or 0.0, y = tonumber(v.y) or 0.0, z = tonumber(v.z) or 0.0 }
            end
        end
    end
end
-- [DEFAULT VON 5006, so gewollt] wp5006 als Default-Flip-Offset fuer ALLE anderen Messer (ohne eigenen Eintrag).
do
    local base = _G.__re4_knife_flip_lh_map[5006]
    if base then
        for wid in pairs(KNIFE_IDS) do
            if wid ~= 5006 and not _G.__re4_knife_flip_lh_map[wid] then
                _G.__re4_knife_flip_lh_map[wid] = { x = base.x, y = base.y, z = base.z }
            end
        end
    end
end
local function lh_flip_save()
    local out = {}
    for wid, v in pairs(_G.__re4_knife_flip_lh_map) do out[tostring(wid)] = v end
    local p = lh_flip_path()
    if not lh_write_allowed(p) then return end   -- [HARD-GUARD]
    pcall(function() json.dump_file(p, out) end)
end

-- [KNIFE_ADA] Charakter-Flanke: beim Wechsel BEIDE Maps aus den Dateien des neuen Charakters
-- neu einlesen. Fehlt Adas Datei, wird sie einmalig aus dem aktuellen (Leon-)Stand geschrieben
-- -> du tunst von Leons Werten aus weiter. Nur beim WECHSEL, nicht jeden Frame.
local function lh_reload_map(path, map)
    local ok, d = pcall(function() return json.load_file(path) end)
    if not ok or type(d) ~= "table" then return false end
    for k in pairs(map) do map[k] = nil end
    for k, v in pairs(d) do
        local wid = tonumber(k)
        if wid and type(v) == "table" then
            local t = {}
            for kk, vv in pairs(v) do t[kk] = tonumber(vv) or 0.0 end
            map[wid] = t
        end
    end
    return true
end
local function lh_char_tick()
    local want = _G.__re4_char_now()
    if want == nil then return end            -- unbekannt -> NICHT umschalten
    if want == _lh_char then return end
    local first_ada = (want == "ada")
    _lh_char = want
    if first_ada then
        -- Seed schreiben, BEVOR geladen wird (sonst laedt man ins Leere und verliert Leons Stand)
        if type(select(2, pcall(function() return json.load_file(LH_OFF_PATH_ADA) end))) ~= "table" then lh_off_save() end
        if type(select(2, pcall(function() return json.load_file(LH_FLIP_PATH_ADA) end))) ~= "table" then lh_flip_save() end
    end
    lh_reload_map(lh_path(), _G.__re4_knife_lh_off_map)
    lh_reload_map(lh_flip_path(), _G.__re4_knife_flip_lh_map)
    -- Greif-/Flip-Werte der linken Hand mitziehen; Adas Datei beim ersten Mal aus Leons Stand seeden
    if first_ada and type(select(2, pcall(function() return json.load_file(LCFG_PATH_ADA) end))) ~= "table" then
        lcfg_save()
    end
    lcfg_load(lcfg_path())
    _G.__re4_knife_blood_on = LCFG.blood_on   -- [BLUT_SCHALTER] gilt pro Charakter -> beim Wechsel mitziehen
end
-- Eigener Hook statt Einhaengen in einen bestehenden: der Tick ist unabhaengig von jeder
-- anderen Logik hier und soll auch laufen, wenn die anderen Ticks early-returnen.
re.on_frame(function() pcall(lh_char_tick) end)

-- (UI: alle Links-Regler in EINEM Treenode weiter unten, nach der Frame-Logik gebuendelt.)

-- ============================================================================
-- [LH_CLONE 2026-07-08] Messer als sichtbarer MESH-KLON in der LINKEN Hand.
-- Statt requestEquipKnife (das die Gun aus der rechten Hand wirft) zeigen wir beim Links-Zug NUR einen Klon
-- des Messer-Meshs, nativ an das L_Hand-Joint geparentet (lag-frei wie der Brust-Holster-Klon). Die Gun
-- bleibt der echte Equip in der rechten Hand -> kein Slot-Streit mehr. Rezept 1:1 aus dem Holster
-- (Motion+Mesh-Komponente, setMesh vom lebenden Waffen-Holder, Part 0 = ganzes Messer isolieren).
-- Pose = lokale Slider (re4_vr_knife_lh_offsets.json, dieselbe Map -> die Slider bewegen jetzt den Klon).
-- ALLES in DIESER Lua (motion/rechts unberuehrt, kein 200-Local-Limit-Risiko dort).
-- ============================================================================
local _lhc_mesh_td   = sdk.typeof("via.render.Mesh")
local _lhc_motion_td = sdk.typeof("via.motion.Motion")
local clone = { obj = nil, mesh = nil, wid = nil, parented = false, part0 = false }
local orphan_check_t = 0   -- [STALE-CLEANUP] throttled Purge verwaister Klone (Reset Scripts / Save-Load)

local function destroy_go(go)
    if not go then return end
    pcall(function()
        local d = sdk.find_type_definition("via.GameObject"):get_method("destroy(via.GameObject)")
        if d then d:call(nil, go) end
    end)
end

-- [STALE-CLEANUP] Alle verwaisten "vr_lh_knife"-Klone am Body entsorgen (ausser optional dem getrackten
-- keep-Address). Loest den klassischen Reset-Scripts/Save-Load-Waisen (das neue Script-Objekt kennt den
-- alten Klon-GO nicht mehr -> er bleibt stale an der Hand). Erst sammeln, DANN zerstoeren (Baum nicht
-- waehrend der Iteration mutieren). Rueckgabe: Anzahl entsorgt, oder nil wenn der Body (noch) fehlt.
local function destroy_orphan_clones(keep)
    local ctx = get_ctx(); local body = ctx and sc(ctx, "get_BodyGameObject")
    local tf = body and sc(body, "get_Transform"); if not tf then return nil end
    local victims = {}
    local function walk(t, depth)
        if not t or depth > 8 then return end
        local child = safe(function() return t:call("get_Child") end)
        local guard = 0
        while child and guard < 500 do
            guard = guard + 1
            local go = safe(function() return child:call("get_GameObject") end)
            local nm = go and safe(function() return go:call("get_Name") end)
            if type(nm) == "string" and nm == "vr_lh_knife" then
                local addr = safe(function() return go:get_address() end)
                if not (keep and addr == keep) then victims[#victims+1] = go end
            end
            walk(child, depth + 1)
            child = safe(function() return child:call("get_Next") end)
        end
    end
    walk(tf, 0)
    for _, go in ipairs(victims) do destroy_go(go) end
    return #victims
end

local function quat_from_euler_deg(rx, ry, rz)
    local hx, hy, hz = math.rad(rx or 0)*0.5, math.rad(ry or 0)*0.5, math.rad(rz or 0)*0.5
    local cx, sx = math.cos(hx), math.sin(hx)
    local cy, sy = math.cos(hy), math.sin(hy)
    local cz, sz = math.cos(hz), math.sin(hz)
    -- ZYX -> Quaternion (W,X,Y,Z)
    return Quaternion.new(
        cx*cy*cz + sx*sy*sz,
        sx*cy*cz - cx*sy*sz,
        cx*sy*cz + sx*cy*sz,
        cx*cy*sz - sx*sy*cz)
end

-- Das AKTUELL AUSGEWAEHLTE Messer (das die rechte Hand zieht) = das Messer in der Mount-Liste (Shortcut-Slot).
-- get_MountWeaponIDs enthaelt die vier gemounteten Waffen; genau EINE ist ein Messer (KNIFE_IDS).
-- [CURRENT KNIFE 2026-07-08] Die Engine publiziert JEDEN Waffen-Equip via equipWeapon(EquipType, WeaponID,..) --
-- auch das Wechseln des Messers im Inventar. Wir cachen NUR Messer (KNIFE_IDS) -> Klon (links) nimmt SOFORT das
-- aktuelle Messer, ohne auf get_MountWeaponIDs zu warten (das zieht erst beim echten in-Hand-Equip nach). WeaponID
-- = value-type Enum -> sdk.to_int64. sdk.hook -> GAME-NEUSTART (erledigt). Global `__re4_current_knife_wid`.
-- Callback als GLOBAL -> per Reset Scripts aenderbar; der Hook (unten) ruft nur diese Funktion, installiert nur 1x.
-- [ADA ONLY 2026-07-21] Messer, die es NUR bei Ada gibt (Separate Ways). Bewusst OHNE 6305
-- (Hot Dogger, Mercenaries) und ohne Leons 5000..5006 -- der Quick-Knife-Block unten darf Leon nie treffen.
local ADA_KNIFE_IDS = { [6107] = true, [6108] = true }
-- Gesteuerter Body = Ada? (ch3a8z0_body, verifiziert in re4_vr_materials.lua). Unbekannt/nil -> false,
-- damit im Zweifel NICHT geblockt wird.
local function is_ada_body()
    local ctx = get_ctx()
    local body = ctx and safe(function() return ctx:call("get_BodyGameObject") end)
    local name = body and safe(function() return body:call("get_Name") end)
    return name == "ch3a8z0_body"
end

_G.__re4_equipweapon_cb = function(args)
    -- Weg 2: DRAW/Equip -> WeaponID sofort cachen (rechte Hand). WeaponID = value-type Enum -> sdk.to_int64.
    local raw, mval = nil, nil
    pcall(function() raw = sdk.to_int64(args[4]) end)
    pcall(function() local o = sdk.to_managed_object(args[4]); if o then mval = o.value__ end end)
    local v = (raw and KNIFE_IDS[raw]) and raw or ((mval and KNIFE_IDS[mval]) and mval or nil)
    if v then _G.__re4_current_knife_wid = v end

    -- =================================================================================
    -- [QUICK-KNIFE-BLOCK (ADA ONLY) 2026-07-21 -- per Hook lueckenlos belegt]
    -- =================================================================================
    -- BEFUND (re4_zzz_knife_who2.log 21:59:47): die ENGINE ruft "execChangeWeapon" und direkt danach
    -- "equipWeapon(6108)" -- beides NATIV, OHNE requestEquipKnife und OHNE requestChangeActiveWeapon.
    -- Darum greift das Knife-Gate in holster.lua (bewacht requestEquipKnife) hier nicht: diesen Weg
    -- geht die Engine gar nicht. Am RT-Binding wurde bewusst NICHTS geaendert (zwei Versuche kosteten
    -- heute Dry-Fire-bei-voller-Waffe und den toten Nahkampf-Prompt -> komplett zurueckgebaut).
    --
    -- ADA-GATE, DOPPELT (-Vorgabe: "alles gaten auf ADA, Leon hat die Probleme nicht"):
    -- (1) nur ADA_KNIFE_IDS -- 6107/6108 sind Separate-Ways-Messer. Leons 5000..5006 und der
    -- Hot Dogger (6305, Mercenaries) sind NICHT enthalten -> fuer Leon ist der Block tot.
    -- (2) zusaetzlich muss der gesteuerte Body Ada sein (ch3a8z0_body, Name aus der Body-Tabelle in
    -- re4_vr_materials.lua). Schlaegt die Abfrage fehl (nil/unbekannt), wird NICHT geblockt.
    -- Beides muss zutreffen -> selbst wenn Leon je eine 61xx-Waffe fuehrte, passiert nichts.
    --
    -- AUSNAHMEN = exakt die des bestehenden Knife-Gates (holster.lua): jeder Zug, den WIR wollen,
    -- muss durch. Sonst waere das Messer fuer Ada gar nicht mehr ziehbar.
    if v and ADA_KNIFE_IDS[v] and is_ada_body() then
        local want_knife =
               (os.clock() - (tonumber(rawget(_G, "__re4_knife_draw_ours_t")) or -999)) < 1.0  -- eigener Zug (Holster/Links/Auto-Redraw)
            or rawget(_G, "__re4_knife_left_intent")      == true   -- Links-Zug angemeldet
            or rawget(_G, "__re4_knife_left_clone")       == true   -- Klon links -> Messer gehoert uns
            or rawget(_G, "__re4_knife_flying")           == true   -- Wurf unterwegs
            or rawget(_G, "__re4_clone_finisher_restore") == true   -- nativer Finisher braucht das echte Messer
            or rawget(_G, "__re4_holster_killswitch")     == true   -- Cutscene/KS: Engine darf machen was sie will
            or rawget(_G, "__re4_ks4_active")             == true
            or rawget(_G, "__re4_holster_knife_only")     == true   -- Messer-only-Stages (Krauser u.a.)
        if not want_knife then
            -- NATIV? (kein autorun-Script ausser diesem im Stack) -- gleiche Pruefung wie der Gun-Restore unten
            local native = true
            local tb = (debug and debug.traceback) and debug.traceback("", 2) or ""
            for line in tb:gmatch("[^\n]+") do
                if line:find("autorun", 1, true) and not line:find("weapons2", 1, true) then native = false; break end
            end
            if native then
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end
    end
    -- [KNIFE-KEEP vs NATIVE GUN-RESTORE 2026-07-11] Die Engine equippt NACH einem Killswitch nativ die
    -- Main-Gun zurueck, obwohl ein Messer in der Hand ist (per equipwatch-Log bewiesen: Gun-Equip OHNE
    -- Lua-Aufrufer, waehrend der Auto-Redraw korrekt das Messer geholt hatte). Solchen Equip BLOCKEN:
    -- Gun-ID (4000-4999) + Messer AKTUELL in Hand (get_IsEquipKnife) + NATIVER Aufruf (kein autorun-Script
    -- ausser diesem im Stack -> also NICHT /Holster/Binding) -> SKIP_ORIGINAL, das Messer bleibt.
    local wid = raw or mval
    -- [MINECART 2026-07-14] wp4005 = Cart-Gun ("Don Quixote"), existiert AUSSCHLIESSLICH im Minecart. Das Spiel
    -- reicht sie beim Kart-Eintritt NATIV per equipWeapon(4005) an, auch wenn ein Messer in der Hand ist. Dieser
    -- Guard blockte 4000-4999 pauschal -> die native Cart-Gun-Uebergabe wurde gekillt, das Messer blieb (per
    -- re4_equipwatch.log bewiesen: "BLOCK native gun-restore wid=4005 (Messer in Hand)"). wp4005 IMMER durchlassen.
    -- Ausserhalb des Karts kommt 4005 nie vor -> normales Gameplay unveraendert (Bedingung fuer alle anderen wid identisch).
    if type(wid) == "number" and wid >= 4000 and wid < 5000 and wid ~= 4005 then
        local knife_in_hand = false
        pcall(function()
            local cm  = sdk.get_managed_singleton("chainsaw.CharacterManager")
            local ctx = cm and cm:call("getPlayerContextRef")
            local hu  = ctx and ctx:call("get_HeadUpdater")
            knife_in_hand = hu and hu:call("get_IsEquipKnife") == true
        end)
        if knife_in_hand then
            local native = true
            local tb = (debug and debug.traceback) and debug.traceback("", 2) or ""
            for line in tb:gmatch("[^\n]+") do
                if line:find("autorun", 1, true) and not line:find("knife_lefthand", 1, true) then native = false; break end
            end
            if native then
                -- [log entfernt]
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end
    end
end
if not _G.__re4_knife_equipwatch then
    _G.__re4_knife_equipwatch = true
    local etd = sdk.find_type_definition("chainsaw.PlayerEquipment")
    local em = etd and etd:get_method("equipWeapon(chainsaw.EquipType, chainsaw.WeaponID, System.Boolean, System.Boolean)")
    if em then
        sdk.hook(em, function(args) local f = rawget(_G, "__re4_equipweapon_cb"); if f then local ok, res = pcall(function() return f(args) end); if ok then return res end end end, function(r) return r end)
    end
end

-- [CURRENT KNIFE — POLL 2026-07-08] "beide wege": Der equipWeapon-Hook (oben) faengt DRAW/Equip sofort (rechte
-- Hand zieht). Der reine Inventar-Wechsel im Menue (ohne Draw) feuert equipWeapon NICHT -> zusaetzlich POLLen wir
-- den Inventory: getEquippedWeapon(EquipType) haelt das im Shortcut-Slot gewaehlte Messer und aktualisiert sich
-- SOFORT beim Inventar-Equip. Wir iterieren alle EquipTypes (0=Invalid uebersprungen) und nehmen die erste
-- WeaponID, die ein Messer (KNIFE_IDS) ist -> autoritative frische Quelle fuer BEIDE Haende.
local function poll_inventory_knife_wid()
    local pe = get_pe(); if not pe then return nil end
    local inv = sc(pe, "get_InventoryController"); if not inv then return nil end
    for et = 1, 3 do
        local wi = safe(function() return inv:call("getEquippedWeapon(chainsaw.EquipType)", et) end)
        if wi then
            local w = safe(function() return wi:call("get_WeaponId") end)
            local v = (type(w) == "number") and w or (w ~= nil and safe(function() return w.value__ end)) or nil
            v = tonumber(v)
            if v and KNIFE_IDS[v] then return v end
        end
    end
    return nil
end

local function get_selected_knife_wid()
    -- BEIDE WEGE: 1) Inventory-Poll (frisch beim Menue-Wechsel, ohne Draw) ist AUTORITATIV und haelt den
    -- Hook-Cache aktuell. 2) Hook-Cache __re4_current_knife_wid (sofort beim Draw). 3) Mount-Liste letzter Fallback.
    local pv = poll_inventory_knife_wid()
    if pv then _G.__re4_current_knife_wid = pv; return pv end
    local cur = tonumber(rawget(_G, "__re4_current_knife_wid"))
    if cur and KNIFE_IDS[cur] then return cur end
    local ctx = get_ctx(); local arr = ctx and sc(ctx, "get_MountWeaponIDs"); if not arr then return nil end
    local n = tonumber(safe(function() return arr:call("get_Length") end)) or 0
    for i = 0, n - 1 do
        local w = safe(function() return arr[i] end)
        local v = (type(w) == "number") and w or (w ~= nil and safe(function() return w.value__ end)) or nil
        v = tonumber(v)
        if v and KNIFE_IDS[v] then return v end
    end
    return nil
end

-- Das AUSGEWAEHLTE Messer (Mount-Liste) -> dessen via.render.Mesh + wid (Quelle fuer den sichtbaren Fake-Klon).
local function find_knife_mesh()
    local want = get_selected_knife_wid()
    local ctx = get_ctx(); local body = ctx and sc(ctx, "get_BodyGameObject")
    local tf = body and sc(body, "get_Transform"); if not tf then return nil, nil end
    local want_mesh, want_id, any_mesh, any_id = nil, nil, nil, nil
    local function walk(t, depth)
        if not t or depth > 12 or want_mesh then return end
        local child = safe(function() return t:call("get_Child") end)
        local guard = 0
        while child and guard < 400 do
            guard = guard + 1
            local go = safe(function() return child:call("get_GameObject") end)
            local nm = go and safe(function() return go:call("get_Name") end)
            if type(nm) == "string" and (nm:find("^wp5") or nm:find("^wp6107") or nm:find("^wp6108") or nm:find("^wp6305")) then
                local id = tonumber(nm:match("^wp(%d+)"))
                if id and KNIFE_IDS[id] then
                    local mesh = sc(go, "getComponent(System.Type)", _lhc_mesh_td)
                    if mesh then
                        if want and id == want then want_mesh, want_id = mesh, id; return
                        elseif not any_mesh then any_mesh, any_id = mesh, id end
                    end
                end
            end
            walk(child, depth + 1)
            if want_mesh then return end
            child = safe(function() return child:call("get_Next") end)
        end
    end
    walk(tf, 0)
    if want_mesh then return want_mesh, want_id end
    return any_mesh, any_id
end

-- [LH_CLONE] Sichtbarer FAKE-KLON (Mesh-Copy) an L_Hand. Das echte Messer-GO an die Hand zu parenten funktioniert
-- NICHT: geskinntes Mesh + Collider haengen am eigenen Skelett, nicht am GO-Root (live verifiziert -> unsichtbar
-- + kein Treffer). Damage geht daher NICHT ueber requestAttack, sondern separat (direkter Gegner-Schaden).
local function clone_destroy()
    destroy_go(clone.obj)
    clone.obj, clone.mesh, clone.wid, clone.parented, clone.part0, clone.was_flying = nil, nil, nil, false, false, false
    clone.vis = nil   -- [KEIN DOPPELMESSER] Sichtbarkeits-Cache fuer den naechsten Klon zuruecksetzen
    _G.__re4_knife_hc_cache = nil
    _G.__re4_knife_lh_clone_go = nil
end

local function clone_spawn()
    local gmesh, wid = find_knife_mesh(); if not gmesh then return false end
    local holder = safe(function() return gmesh:call("getMesh") end); if not holder then return false end
    local gmat   = safe(function() return gmesh:call("get_Material") end)
    local go_td  = sdk.find_type_definition("via.GameObject")
    local create = go_td and go_td:get_method("create(System.String)")
    local go = create and safe(function() return create:call(nil, "vr_lh_knife") end); if not go then return false end
    pcall(function() go:add_ref() end)
    pcall(function() go:call("createComponent(System.Type)", _lhc_motion_td) end)   -- KERN: Skelett (sonst unsichtbar)
    local mesh = safe(function() return go:call("createComponent(System.Type)", _lhc_mesh_td) end)
    if not mesh then return false end
    pcall(function() mesh:call("setMesh", holder) end)
    if gmat then pcall(function() mesh:call("set_Material", gmat) end) end
    pcall(function() mesh:call("set_DrawDefault", true) end)
    pcall(function() mesh:call("set_Enabled", true) end)
    pcall(function() mesh:call("set_FrustumCulling", false) end)
    pcall(function() mesh:call("set_DrawShadowCast", false) end)
    local ctf = safe(function() return go:call("get_Transform") end)
    local ctx = get_ctx(); local bgo = ctx and sc(ctx, "get_BodyGameObject")
    local go_valid  = safe(function() return go:call("get_Valid") end) ~= false
    local bgo_valid = bgo and safe(function() return bgo:call("get_Valid") end) ~= false
    local btf = (bgo and bgo_valid) and safe(function() return bgo:call("get_Transform") end) or nil
    clone.parented = false
    if ctf and btf and go_valid and bgo_valid then
        pcall(function() ctf:call("set_Parent", btf) end)
        if pcall(function() ctf:call("set_ParentJoint", "L_Hand") end) then clone.parented = true end
    end
    clone.obj, clone.mesh, clone.wid, clone.part0 = go, mesh, wid, false
    _G.__re4_knife_lh_clone_go = go   -- [WURF] weapons.lua knife_throw_launch fliegt DIESES GO im Klon-Modus
    return true
end

-- Part 0 = ganzes Messer (-Ansage) -> nur den anzeigen (Rest aus, z.B. Anbauten). Retry bis Mesh ready.
local function clone_isolate_part0()
    if not clone.mesh then return false end
    if safe(function() return clone.mesh:call("get_MeshReady") end) ~= true then return false end
    for i = 0, 63 do pcall(function() clone.mesh:call("setPartsEnable", i, i == 0) end) end
    return true
end

-- Lokale Pose des Klons im L_Hand-Frame = die Pro-Messer-Slider (Map __re4_knife_lh_off_map[wid]).
-- Hinweis: der Referenz-Frame ist jetzt das Hand-JOINT (nicht mehr der gespiegelte Controller-Offset) ->
-- die alten Slider-Werte muessen einmal neu getunt werden (erwartet). Default 0 = am Joint-Ursprung.
-- [FLIP] eigener Lerp fuer den Klon (motion.knife_flip_spin gated auf __re4_knife_equipped -> laeuft im Klon nicht).
local flip_lerp = 0.0
local flip_prev_target = -1.0
-- [LH SOUND] Der Klon hat keinen eigenen SoundContainer (Soundplayer -> "no weapon found"). Loesung: Sounds
-- ueber ein ECHTES Messer-GO am Body spielen (ein gemountetes Messer-GO traegt den Container, auch geholstert).
-- Generisch fuer beliebige Sound-ID (Flip 1007228839, Schwung = __re4_knife_snd.swing). Aufrufer sind throttled
-- (Flip-Flanke / Swing-Cooldown) -> der Body-Walk ist selten und unkritisch.
local _lhc_snd_td = sdk.typeof("soundlib.SoundContainer")
local function lh_body_knife_soundcontainer()
    if not _lhc_snd_td then return nil end
    local ctx = get_ctx(); local body = ctx and sc(ctx, "get_BodyGameObject")
    local tf = body and sc(body, "get_Transform"); if not tf then return nil end
    -- [SOUND FIX 2026-07-09] DIREKTE Body-Children mit EXAKTEM wpXXXX-Namen (Waffen-Root) -- genau wie
    -- #re4_sound_player list_loadout_weapons -> derselbe Container, auf dem "Play" (uint32) den Flip hoerbar
    -- spielt. Der alte Tief-Walk mit Prefix "^wp5" konnte ein verschachteltes Kind treffen, dessen Container stumm blieb.
    local child = safe(function() return tf:call("get_Child") end); local guard = 0
    while child and guard < 256 do
        guard = guard + 1
        local go = safe(function() return child:call("get_GameObject") end)
        local nm = go and safe(function() return go:call("get_Name") end)
        if type(nm) == "string" then
            local wid = tonumber(nm:match("^wp(%d+)$"))
            if wid and KNIFE_IDS[wid] then
                local scn = sc(go, "getComponent(System.Type)", _lhc_snd_td)
                if scn then return scn end
            end
        end
        child = safe(function() return child:call("get_Next") end)
    end
    return nil
end
-- Beliebige Messer-Sound-ID ueber das Body-Messer-GO spielen (fuer den Klon links).
-- [SOUND FIX 2026-07-09] trigger(System.UInt32) = Mode 1, exakt wie #re4_sound_player "Play". bestaetigt:
-- der Flip-Sound (1007228839) spielt so hoerbar. Die Full-Signatur (Mode 2 "combo") war bei dieser ID STUMM
-- und blockte per `if ok then return end` den uint32-Fallback -> darum blieb der Flip lautlos. Jetzt nur uint32.
_G.__re4_knife_lh_play_sound = function(id)
    if not id or id <= 0 then return end
    local scn = lh_body_knife_soundcontainer()
    if scn then pcall(function() scn:call("trigger(System.UInt32)", id) end) end
end
local function play_flip_sound() _G.__re4_knife_lh_play_sound(1007228839) end
local function clone_apply_pose()
    if not clone.obj then return end
    local tf = safe(function() return clone.obj:call("get_Transform") end); if not tf then return end
    local mm = rawget(_G, "__re4_knife_lh_off_map")
    local o  = (mm and clone.wid) and mm[clone.wid] or nil
    local px, py, pz = (o and o.px or 0.0), (o and o.py or 0.0), (o and o.pz or 0.0)
    -- [FLIP] Lerp 0->1 wie motion (180° um lokale X, post-multipliziert). Nur beim Links-Klon.
    local target = (rawget(_G, "__vr_knife_flip") == true) and 1.0 or 0.0
    if flip_prev_target ~= target then flip_prev_target = target; play_flip_sound() end   -- Flip-Sound (hin UND zurueck)
    -- clone_apply_pose laeuft nur 1x/Frame (rechts lerpt motion in ~5 Render-Paessen) -> hoehere Rate, sonst zu
    -- langsam. Live tunbar via __re4_knife_lh_flip_speed. ~0.5 = Flip in ~2 Frames (snappy wie rechts).
    local spd = tonumber(rawget(_G, "__re4_knife_lh_flip_speed")) or 0.5
    if flip_lerp < target then flip_lerp = math.min(target, flip_lerp + spd)
    elseif flip_lerp > target then flip_lerp = math.max(target, flip_lerp - spd) end
    _G.__re4_knife_lh_flip_lerp = flip_lerp   -- [FLIP FINGER] die Handpose-Funktion (weiter oben) liest das
    local rot = quat_from_euler_deg(o and o.rx or 0.0, o and o.ry or 0.0, o and o.rz or 0.0)
    if flip_lerp > 0.0001 then
        local fq = quat_from_euler_deg(180.0 * flip_lerp, 0.0, 0.0)
        local okr, r2 = pcall(function() return (rot * fq):normalized() end); if okr and r2 then rot = r2 end
        -- Pro-Messer Flip-Offset (eigene Map, wie rechts), lerp-skaliert, im lokalen Frame.
        local fm = rawget(_G, "__re4_knife_flip_lh_map"); local fp = (fm and clone.wid) and fm[clone.wid] or nil
        if fp then px = px + (fp.x or 0.0)*flip_lerp; py = py + (fp.y or 0.0)*flip_lerp; pz = pz + (fp.z or 0.0)*flip_lerp end
    end
    pcall(function() tf:call("set_LocalPosition", Vector3f.new(px, py, pz)) end)
    pcall(function() tf:call("set_LocalRotation", rot) end)
    pcall(function() tf:call("set_LocalScale", Vector3f.new(1, 1, 1)) end)
end

-- Lifecycle: nur wenn Klon-Modus aktiv. In KS/KS4 weg (baut sich neu auf). Save-Load-fest via get_Valid.
local function clone_manage()
    -- [STALE-CLEANUP] Selbstheilend & throttled: es darf hoechstens UNSER getrackter Klon existieren. Alle
    -- verwaisten vr_lh_knife (Reset Scripts / Save-Load / Vorlauf) entsorgen -> nie ein stale Messer an der Hand.
    local now = os.clock()
    if now - orphan_check_t > 1.0 then
        orphan_check_t = now
        destroy_orphan_clones(clone.obj and safe(function() return clone.obj:get_address() end) or nil)
    end
    if rawget(_G, "__re4_knife_left_clone") ~= true then
        if clone.obj then clone_destroy() end
        return
    end
    if rawget(_G, "__re4_holster_killswitch") == true or rawget(_G, "__re4_ks4_active") == true then
        if clone.obj then clone_destroy() end
        return
    end
    if clone.obj and not safe(function() return clone.obj:get_Valid() end) then clone_destroy() end
    -- Messer im Menue gewechselt (waehrend der Klon draussen ist) -> Klon auf das neue Messer neu bauen.
    if clone.obj and clone.wid then
        local sel = get_selected_knife_wid()
        if sel and sel ~= clone.wid then clone_destroy() end
    end
    if not clone.obj then clone_spawn() end
    if clone.obj then
        if not clone.part0 then if clone_isolate_part0() then clone.part0 = true end end
        -- [KEIN DOPPELMESSER 2026-07-20] Waehrend der Restore-Phase (Parry/Finisher equippen das
        -- ECHTE Messer rechts, wir holstern es gleich wieder) existiert der Klon links WEITER -- sonst
        -- muesste er neu gebaut werden. Sichtbar waeren dann zwei Messer. Deshalb: solange engine-seitig
        -- ein Messer equippt ist, den Klon nur UNSICHTBAR schalten (Mesh-Farb-Pass aus), nicht zerstoeren.
        -- Sobald das rechte Messer weg ist, kommt er von selbst zurueck.
        if clone.mesh then
            local want = rawget(_G, "__re4_knife_equipped") ~= true
            if clone.vis ~= want then
                clone.vis = want
                pcall(function() clone.mesh:call("set_DrawDefault", want) end)
            end
        end
        -- [WURF] waehrend das Klon-Messer fliegt NICHT pinnen (der Flug-Override in weapons.lua steuert die
        -- Welt-Transform). Nach dem Flug den Klon zurueck an L_Hand parenten (der Wurf hatte ihn geloest).
        if rawget(_G, "__re4_knife_flying") == true then
            clone.was_flying = true
        else
            if clone.was_flying then
                clone.was_flying = false
                local ctx = get_ctx(); local bgo = ctx and sc(ctx, "get_BodyGameObject")
                local btf = bgo and sc(bgo, "get_Transform")
                local ctf = safe(function() return clone.obj:call("get_Transform") end)
                if ctf and btf then
                    pcall(function() ctf:call("set_Parent", btf) end)
                    pcall(function() ctf:call("set_ParentJoint", "L_Hand") end)
                end
            end
            clone_apply_pose()
        end
    end
end

-- [LH_CLONE MELEE 2026-07-08] requestAttack am nicht-equippten Messer macht KEINEN Schaden (live verifiziert:
-- Treffer landet nicht, callbackAttackHit feuert nie). Pivot: NATIVES execMelee (das ist RE4s eigener Weg,
-- Messer-Schaden zu machen WAEHREND eine Gun equippt ist). Auto-Ziel + native Anim, aber echter Schaden.
local _melee_combat = nil
local function exec_native_melee()
    local pe = get_pe(); if not pe then return end
    if _melee_combat == nil then
        local td = sdk.find_type_definition("chainsaw.PlayerDefine.MeleeAttackType")
        local f = td and td:get_field("Combat")
        _melee_combat = (f and f:get_data(nil)) or false
    end
    if _melee_combat == false then return end
    pcall(function() pe:call("execMelee(chainsaw.PlayerDefine.MeleeAttackType, System.UInt32)", _melee_combat, 0) end)
end

-- ---- Frame -----------------------------------------------------------------
local prev_lgrip = false
local pending_until = 0   -- [GRACE] bis hierher gilt "Links-Zug laeuft" (Equip ist 1-2 Frames deferred)
local armed = false       -- Presse begann in der Trigger-Zone -> beim Loslassen feuern
-- [LH_CLONE MELEE] eigene Velocity-Schwung-Erkennung der linken Hand (motion unberuehrt).
local prev_lh = nil       -- letzte linke Hand-Weltpos
local lh_t = 0            -- Zeitstempel dazu (fuer dt)
local last_swing = 0      -- Cooldown fuer den Schwung-SOUND
local last_hit   = 0      -- eigener Cooldown fuer den TREFFER
_G.__re4_knife_lh_swing_speed = _G.__re4_knife_lh_swing_speed or 3.0   -- Schwung-Schwelle m/s (live tunebar; physische Controller-Geschw.)
local SWING_CD = 0.30
local unexpected_equip_t = nil   -- [PARRY-FIX] seit wann ist im Klon-Modus unerwartet ein Messer equippt (Parry)
re.on_frame(function()
    local now = os.clock()

    -- [KNIFE_HAND] left_intent PERSISTIERT bewusst (KEIN Auto-Loeschen bei !equipped mehr). Grund: nimmt die
    -- Engine das Messer kurz weg (Stagger/Yank), holt der Auto-Redraw es zurueck -> es soll in die LETZTE Hand
    -- (links). left_intent wird NUR durch einen expliziten Links-Stow (unten) ODER einen Rechts-Draw
    -- (re4_vr_holster.lua on_grab) auf false gesetzt. pending_until bleibt nur noch als harmloser Rest.

    -- Killswitch/KS4: keine Grabs (Grip-Flanke frisch halten -> kein Grab beim Austritt).
    if rawget(_G, "__re4_holster_killswitch") == true or rawget(_G, "__re4_ks4_active") == true then
        if clone.obj then clone_destroy() end   -- [LH_CLONE] Klon in KS/KS4 weg (baut sich danach neu auf)
        prev_lgrip = left_grip_pressed(); armed = false; return
    end

    -- Abstand linke Hand <-> Brust-Anker (fuer Zone + UI-Anzeige)
    -- [EINE ZONE 2026-07-19] Distanz NICHT mehr selbst rechnen: re4_vr_holster.lua berechnet
    -- sie mit demselben Anker, derselben Formel und demselben Radius wie fuer die rechte Hand und
    -- veroeffentlicht sie als __re4_knife_lh_dist. Zwei Rechnungen = zwei Ergebnisse, genau das war
    -- das Problem. Fallback auf die eigene Rechnung nur, falls der Holster (noch) nichts liefert.
    local d = tonumber(rawget(_G, "__re4_knife_lh_dist"))
    if d == nil then
        -- FALLBACK, falls update_grab frueh returned (dormant / Links-Klon / kein Anker) und nichts
        -- publiziert: dann HIER rechnen -- mit der CONTROLLER-Position (__vr_lh_world), NICHT mit dem
        -- L_Hand-Joint. Der Joint kommt durch Arm-IK/Clamp nicht bis an den Brustpunkt, damit blieb die
        -- Distanz immer ueber dem Radius und links liess sich gar nichts greifen.
        local anchor = rawget(_G, "__vr_knife_chest_pos")
        local lh = rawget(_G, "__vr_lh_world") or rawget(_G, "__vr_lh_joint_pos")
        if anchor and lh then
            local dx, dy, dz = lh.x - anchor.x, lh.y - anchor.y, lh.z - anchor.z
            d = math.sqrt(dx*dx + dy*dy + dz*dz)
        end
    end
    last_d = d
    -- [EIN RADIUS 2026-07-19] Greif-/Release-Radius kommt jetzt vom MESSER-HOLSTER (rechts,
    -- re4_vr_knife.json, publiziert in re4_vr_holster.lua). Die eigenen Links-Slider sind entfallen --
    -- seit die Zonen-Distanz links vom Hand-Joint aus gemessen wird, ist der Mittelpunkt fuer beide
    -- Haende derselbe und ein zweiter Regler waere nur eine zweite Fehlerquelle.
    -- Fallback auf die alten LCFG-Werte, falls der Holster (noch) nichts publiziert hat.
    local R_TRIG = tonumber(rawget(_G, "__re4_knife_grab_trigger")) or LCFG.trigger
    local R_REL  = tonumber(rawget(_G, "__re4_knife_grab_release")) or LCFG.release
    -- [KNIFE_HAND] Links-Holster-Zone fuer weapons.lua: linke Hand am Holster -> KEIN Wurf-Windup (dort =
    -- ziehen/stauen). Spiegel von __vr_knife_holster_zone (rechts). Release-Radius = ganze Greifzone.
    -- [EINE ZONE] Flag kommt DIREKT aus re4_vr_holster.lua (gleiche Hysterese wie rechts).
    -- Fallback auf die eigene Distanzpruefung nur, wenn der Holster nichts liefert.
    local IN_ZONE = rawget(_G, "__re4_knife_lh_in_zone")
    if IN_ZONE == nil then IN_ZONE = (d ~= nil and d <= R_REL) end
    _G.__vr_knife_lh_holster_zone = IN_ZONE == true

    -- Modell wie rechts: Presse in Trigger-Zone armt, Loslassen in Release-Zone feuert (Hysterese).
    local lgrip = left_grip_pressed()
    if lgrip and not prev_lgrip then
        armed = (IN_ZONE == true)
    elseif prev_lgrip and not lgrip then
        if armed and IN_ZONE == true then
            -- [LH_CLONE 2026-07-08] Links-Zug holt/staut jetzt einen MESH-KLON (kein Engine-Equip mehr).
            -- Die Gun bleibt der echte Main-Equip in der rechten Hand.
            local in_clone = rawget(_G, "__re4_knife_left_clone") == true
            local equipped = rawget(_G, "__re4_knife_equipped") == true
            if in_clone then
                -- Klon ist in der linken Hand -> wegstecken
                _G.__re4_knife_left_clone = false
                clone_destroy()
                left_grab_haptic(); left_grab_sound()
            elseif equipped then
                -- Messer ist engine-equippt (RECHTE Hand) -> linke Hand am Holster ignorieren (kein Klau)
            else
                -- Messer holstered -> Klon in die LINKE Hand ziehen (kein requestEquipKnife -> Gun bleibt)
                _G.__re4_knife_left_clone = true
                -- [BARE_RIGHT 2026-07-17] War die rechte beim Uebernehmen KEINE echte Gun (bare/Messer -- z.B. das
                -- Messer gerade rechts geholstert)? Dann darf der RIGHT->GUN-Block unten NICHT die letzte Gun
                -- nachziehen -> rechte bleibt bare. get_IsEquipGun ist zuverlaessig (get_EquipWeaponID luegt bei bare).
                local rhu0 = sc(get_ctx(), "get_HeadUpdater")
                _G.__re4_clone_no_autogun = not (rhu0 and sc(rhu0, "get_IsEquipGun") == true)
                left_grab_haptic(); left_grab_sound()
            end
        end
        armed = false
    end
    prev_lgrip = lgrip

    -- [LH_CLONE MELEE] Links-Klon-Schwung: schnelle Bewegung der linken Hand -> do_knife_melee (gecachter HC +
    -- linke Hand-Reichweite, gleiche Damage-Pipeline wie rechts). Nicht am Holster (dort = ziehen/stauen),
    -- nicht waehrend eines Wurf-Flugs. motion bleibt unberuehrt.
    if rawget(_G, "__re4_knife_left_clone") == true and rawget(_G, "__re4_knife_flying") ~= true
       and vrmod and vrmod:is_hmd_active() then
        -- [PHYSISCH 2026-07-08] Schwung aus der PHYSISCHEN Controller-Position (VR-Space), NICHT der Welt-Position.
        -- Die Welt-Pos (__vr_lh_world) aendert sich durch Spieler-Translation UND -Rotation (Stick-Drehung schwenkt
        -- die Hand-Weltpos im Kreis) -> Dauer-Fehltrigger. Der rechte Schwung (update_knife_swing) nutzt genau
        -- deshalb vrmod:get_position(controller): physischer VR-Space, von Spielerbewegung/-drehung UNBERUEHRT.
        -- controllers[1]=links, [2]=rechts. prev_lh haelt jetzt die physische Controller-Pos.
        -- [1:1 VON RECHTS] exakte Logik aus update_knife_swing (re4_vr_motion.lua): physische Controller-Pos,
        -- reines Anheben (dy>0 & dy>horiz) zaehlt NICHT, dt-Fenster, Schwelle, Cooldown. controllers[1]=links.
        local controllers = vrmod:get_controllers()
        local wp = (controllers and #controllers >= 1) and safe(function() return vrmod:get_position(controllers[1]) end) or nil
        if not wp then
            prev_lh = nil
        else
            local dt = now - lh_t
            local spd = 0
            if prev_lh and dt > 0.001 and dt < 0.2 then
                local dx, dy, dz = wp.x - prev_lh.x, wp.y - prev_lh.y, wp.z - prev_lh.z
                local horiz = math.sqrt(dx*dx + dz*dz)
                if dy > 0 and dy > horiz then spd = 0   -- reines Anheben zaehlt nicht (wie rechts)
                else spd = math.sqrt(dx*dx + dy*dy + dz*dz) / dt end
            end
            prev_lh = Vector3f.new(wp.x, wp.y, wp.z); lh_t = now
            local at_holster = (d ~= nil and d <= ((tonumber(rawget(_G, "__re4_knife_grab_release")) or LCFG.release)))   -- [EIN RADIUS] Holster-Wert
            -- [KNIFE_FLIP] Wie rechts (motion.lua update_knife_swing): Flip + sichtbarer Finisher-Prompt -> die
            -- Shake-Finisher-Geste hat VORRANG, KEIN Links-Melee/Box-Break. Ohne Prompt laeuft der Shake ins Leere
            -- -> Melee im Flip normal.
            local finisher_active = rawget(_G, "__vr_knife_flip") == true
                and type(rawget(_G, "__re4_is_finisher_prompt")) == "function"
                and _G.__re4_is_finisher_prompt() == true
            -- [SOUND VS. TREFFER 2026-07-23] Bisher haing beides an DERSELBEN Schwelle. Die ist
            -- bewusst hoch (live 7.93 m/s), damit der Schwung-Sound nicht bei jeder Handbewegung
            -- losgeht -- und genau daran scheiterte jeder Treffer: echte Nahkampf-Schlaege liegen bei
            -- 1-2 m/s (Log re4_zzz_lh, 15:27). Der Sound behaelt seinen Wert, der Treffer bekommt
            -- einen eigenen, tieferen (Slider im selben Tree). Die uebrigen Sperren gelten fuer beide.
            local gates_ok = (not finisher_active) and (not at_holster)
                and rawget(_G, "__re4_knife_throw_gripping") ~= true   -- kein Stich waehrend Wurf-Windup

            if gates_ok
               and spd >= (tonumber(rawget(_G, "__re4_knife_lh_swing_speed")) or 3.0)
               and (now - last_hit) > SWING_CD then
                last_hit = now
                -- [LH_DIRECT] Schaden garantiert via HitPoint.addDamage; Reaktion/Blut best-effort via DamageInfo.
                local hit = false
                local f = rawget(_G, "__re4_knife_direct_damage")
                if type(f) == "function" then pcall(function() hit = f(1.8) end) end
                -- [BREAKABLE 2026-07-09] Boxen im Links-Schwung mitbrechen (bisher rief die Melee break_nearby gar
                -- nicht). break_nearby macht set_Routine + (Klon-)hitSetting-Completion -> Prompt weg. Scan um die
                -- linke Hand-Weltpos.
                local bn = rawget(_G, "__re4_break_nearby"); local lhw = rawget(_G, "__vr_lh_world")
                if type(bn) == "function" and lhw then pcall(function() bn(lhw) end) end
            end

            -- SOUND: unveraenderte, hohe Schwelle -- nur beim echten Ausholen, nicht bei jeder Bewegung.
            if gates_ok
               and spd >= (tonumber(rawget(_G, "__re4_knife_lh_swing_speed")) or 3.0)
               and (now - last_swing) > SWING_CD then
                last_swing = now
                local snd = rawget(_G, "__re4_knife_snd"); local sid = (snd and tonumber(snd.swing)) or 1800445513
                _G.__re4_knife_lh_play_sound(sid)   -- Schwung-Sound (Luft); Hit-Sound laeuft zentral in direct_damage_at
            end
        end
    else
        prev_lh = nil
    end

    -- [RIGHT_HAND_GUN ENTFERNT 2026-07-17, Entscheidung] Hier stand: "Waehrend der Links-Klon oben ist,
    -- zeigt die RECHTE Engine-Hand IMMER die letzte Gun -- nie Messer, nie bare" (Wunsch 2026-07-16, gegen die
    -- Engine, die bei Treffern die Waffe wegwirft). Der Block rief requestEquipGun = "letzte aktive Main-Waffe"
    -- und drueckte damit MITTEN IM GAMEPLAY die Langwaffe in die Hand, obwohl man ein Messer gezogen hatte
    -- und nichts angefasst hat (live belegt: wepmon 10:14:56 wid 5001 -> 10:14:58 wid 4902, KEIN Killswitch,
    -- kein Auto-Redraw/RESTORE im ardlog -- das hier war der einzige verbliebene requestEquipGun-Aufrufer).
    -- Er widersprach ausserdem direkt der Regel von heute ("Messer rechts -> Klon links weg"): beide feuerten
    -- gegeneinander. NEUE REGEL: rechts bleibt IMMER das, was drin ist -- leer bleibt leer, Messer bleibt Messer.
    -- Es kommt NIE von allein eine Gun; Waffen kommen ausschliesslich bewusst ueber die Holster.
    -- NICHT wieder einbauen. Spart nebenbei 2 Engine-Calls pro Frame (get_HeadUpdater + get_EquipWeaponID).
    -- __re4_clone_no_autogun (holster.lua/oben) wird dadurch nur noch gesetzt, nie gelesen -- harmlos, bewusst
    -- stehen gelassen, um nicht mehr anzufassen als noetig.

    -- [LH_CLONE RIGHT-KNIFE-KILL 2026-07-17, -Regel] Messer engine-equippt (= RECHTE Hand) UND Klon
    -- links -> Klon killen. "Sobald rechts das Messer in der Hand ist, ist es links weg." ZUSTANDSBASIERT
    -- (jeden Frame), NICHT am Grab-Event: holster.lua raeumt __re4_knife_left_clone nur beim rechten
    -- Holster-Zug (Z.~1018). Kommt das Messer ANDERS in die rechte Hand -- Auto-Redraw (ar.kind=knife),
    -- Stagger-Draw ueber den Right-Grip, Inventar/Engine-Wechsel -- lief die Zeile NIE -> Messer in BEIDEN
    -- Haenden. Das war die Luecke. __re4_knife_equipped kommt aus weapons.lua (is_knife_equipped, jeden Frame).
    -- Wurf-Ausnahme wie bei den Kills unten: waehrend __re4_knife_flying ist der Klon unterwegs und gar nicht
    -- in der Hand -> nicht killen, sonst verschwindet das geworfene Messer mitten im Flug.
    -- [CLONE-FINISHER RESTORE 2026-07-17, -Wahl "zurueck als Links-Klon"] Der native Finisher braucht das
    -- echte Messer und equippt es RECHTS -> ohne Sonderfall killt die Beide-Haende-Regel unten den Links-Klon
    -- und das Messer bleibt rechts. Stattdessen: Absicht latchen, solange der Finisher-Prompt sichtbar ist +
    -- Klon links; waehrend des Finisher-KS den Zeitstempel frisch halten (die Anim dauert laenger als der Prompt).
    if rawget(_G, "__re4_knife_left_clone") == true
       and type(rawget(_G, "__re4_is_finisher_prompt")) == "function"
       and _G.__re4_is_finisher_prompt() == true then
        _G.__re4_clone_finisher_restore = true
        _G.__re4_clone_finisher_restore_t = now
    end
    local in_ks = rawget(_G, "__re4_holster_killswitch") == true or rawget(_G, "__re4_ks4_active") == true
    if rawget(_G, "__re4_clone_finisher_restore") == true and in_ks then
        _G.__re4_clone_finisher_restore_t = now
    end
    local clone_fin_restoring = rawget(_G, "__re4_clone_finisher_restore") == true
        and (now - (tonumber(rawget(_G, "__re4_clone_finisher_restore_t")) or 0)) < 1.5

    -- [LH_CLONE BOTH-HANDS-KILL] Messer engine-equippt (rechts) waehrend ein Klon links ist -> Konflikt.
    -- Kommt das Messer ANDERS in die rechte Hand (Auto-Redraw, Stagger-Draw, Inventar/Engine-Wechsel) -> Klon killen.
    -- Wurf-Ausnahme: waehrend __re4_knife_flying ist der Klon unterwegs -> nicht killen.
    if rawget(_G, "__re4_knife_left_clone") == true and rawget(_G, "__re4_knife_equipped") == true
       and rawget(_G, "__re4_knife_flying") ~= true then
        if clone_fin_restoring then
            -- Finisher-Fall: NICHT killen. Das rechts equippte Messer bewusst holstern -- aber ERST nach dem KS
            -- (nicht waehrend der Finisher-Anim, sonst koennte der bare-hand-Request die Anim stoeren). suppress+
            -- deferred bare-hand macht holster.lua. left_clone bleibt true -> clone_manage baut den Klon neu,
            -- sobald equipped=false ist. throttle: nicht jeden Frame requesten.
            if not in_ks and (not clone.fin_kick or (now - clone.fin_kick) > 0.2) then
                clone.fin_kick = now
                local hb = rawget(_G, "__re4_knife_holster_bare")
                if type(hb) == "function" then pcall(function() hb() end) end
            end
        else
            _G.__re4_knife_left_clone = false
            clone_destroy()
            left_grab_sound()
        end
    elseif rawget(_G, "__re4_clone_finisher_restore") == true and clone.fin_kick
           and rawget(_G, "__re4_knife_equipped") ~= true then
        -- Holster hat gegriffen (wir hatten equipped gesehen + geholstert, jetzt weg) -> Restore fertig.
        _G.__re4_clone_finisher_restore = false
        clone.fin_kick = nil
    end
    -- Timeout/Abbruch: Latch abgelaufen (Finisher nie ausgefuehrt o.ae.) und nicht mehr im KS -> aufraeumen,
    -- sonst bliebe der Latch haengen und wuerde einen SPAETEREN Rechts-Equip faelschlich als Finisher behandeln.
    if rawget(_G, "__re4_clone_finisher_restore") == true and not clone_fin_restoring and not in_ks then
        _G.__re4_clone_finisher_restore = false
        clone.fin_kick = nil
    end

    -- [LH_CLONE SUPPORT-KILL 2026-07-08] Support-Hand (linke Hand stuetzt die Waffe am Vordergriff) waehrend
    -- ein Klon in der linken Hand ist -> Klon KILLEN (nicht nur ausblenden). Die Hand ist dann frei zum
    -- Stuetzen; wer das Messer wiederhaben will, muss es neu greifen. __vr_support_hand_docked kommt aus
    -- motion.lua (support.docked). Nicht waehrend eines Wurf-Flugs.
    if rawget(_G, "__re4_knife_left_clone") == true and rawget(_G, "__vr_support_hand_docked") == true
       and rawget(_G, "__re4_knife_flying") ~= true then
        _G.__re4_knife_left_clone = false
        clone_destroy()
        left_grab_sound()   -- [SUPPORT-KILL SOUND] gleicher (funktionierender) Holster-Grab-Sound wie beim Ziehen/Stauen
    end

    -- [LH_CLONE RELOAD/RACK-KILL 2026-07-09] Mag-Ziehen (Reload aus dem Holster) ODER Slide-Rack braucht die LINKE
    -- Hand -> Klon killen (wie Support-Dock) + Grab-Sound. Sonst ueberschreibt die Messer-Pose (laeuft in motion.lua
    -- ZULETZT) die Mag/Rack-Pose -> du saehst die Messer-Halte-Pose. Nach dem Kill greift __re4_apply_left_knife_pose
    -- nicht mehr -> Mag/Rack-Pose bleibt stehen. __vr_rack_hand_pose / __vr_mag_hand_pose = Posen-Name != "" wenn aktiv.
    do
        local rackp = rawget(_G, "__vr_rack_hand_pose"); local magp = rawget(_G, "__vr_mag_hand_pose")
        -- __vr_mag_in_hand = das GEMEINSAME "linke Hand am Mag"-Flag ALLER Reload-Module (Gewehr/Revolver/Chicago/
        -- Armbrust/Red9). Manche (z.B. Sturmgewehr in reload2.lua) setzen NUR dieses Flag, KEINE mag_hand_pose ->
        -- ohne diesen Zweig killte der Klon beim Gewehr-Mag-Ziehen nicht. [LH_CLONE 2026-07-10]
        local reload_active = (type(rackp) == "string" and rackp ~= "") or (type(magp) == "string" and magp ~= "")
            or rawget(_G, "__vr_mag_in_hand") == true
            or rawget(_G, "__vr_slide_rack_active") == true       -- [SLIDE] Hand am Slide/Rack (Mag oeffnen/durchladen)
            or rawget(_G, "__vr_rack_block_left_knife") == true   -- [RACK] Reload braucht Rack
            or player_is_reloading()                              -- [GENERELL] jede native Reload-Anim, egal welche Waffe
        if rawget(_G, "__re4_knife_left_clone") == true and rawget(_G, "__re4_knife_flying") ~= true and reload_active then
            _G.__re4_knife_left_clone = false
            clone_destroy()
            left_grab_sound()
        end
    end

    -- [LH_CLONE] Klon-Lifecycle/Pose jeden Frame pflegen.
    clone_manage()
end)

-- ---- UI (Desktop-Mirror; ALLE Links-Regler in EINEM Treenode, logisch geteilt) -
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4 VR - Messer LINKE Hand [" raus (81 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

-- [STALE-CLEANUP] Vorm Script-Reload den getrackten Klon zerstoeren -> kein Waise fuers naechste Script-Objekt.
-- (Der throttled Purge in clone_manage faengt zusaetzlich alles ab, was ohne Reset verwaist ist: Save-Load, Crash.)
re.on_script_reset(function()
    clone_destroy()
    _G.__re4_knife_left_clone = false
    destroy_orphan_clones(nil)   -- zur Sicherheit auch untracked Reste am Body entsorgen
end)

end)()

-- ==================== >>> re4_vr_knife_lh_damage.lua <<< ====================
;(function()
-- re4_vr_knife_lh_damage.lua (frueher re4_zz_knife_dmg_trace.lua)
-- ============================================================================
-- LINKS-KLON MESSER-SCHADEN -- NATIVE Engine-Kette OHNE Collider.
--
-- [2026-07-09] Erkenntnis aus dem HitManager-Typdump: die Engine verarbeitet einen Treffer NACH der Kollision
-- ueber HitManager.calcInfo(DamageInfo, HC, HC) + HitManager.hitSetting(DamageInfo, HC, HC) -- rein ueber
-- Angreifer-HC + Opfer-HC + eine DamageInfo, KEIN Collider-Overlap noetig. requestAttack braucht dagegen einen
-- Collider (den der Mesh-Klon nicht hat) -> darum lief es nie. Der alte synthetische Weg pokte nur
-- callbackDamageHit + addDamage -> Schaden ohne Reaktion/Stagger, weil calcInfo/hitSetting uebersprungen wurden.
--
-- Hier jetzt der ECHTE native Weg: Messer-HC (Angreifer, via Player-Body-HC) + Gegner-HC (Opfer) + eine valide
-- DamageInfo (Basis aus einem gefangenen Rechts-Treffer -> korrekte HitInfo-Struktur) -> calcInfo -> hitSetting.
-- Native Reaktion + Blut kommen aus der Engine selbst. Param-Reihenfolge (Angreifer/Opfer) wird beim Test
-- ermittelt: erst A=(atk,victim), bei ausbleibendem HP-Fall B=(victim,atk); der Gewinner steht im dbg-Log.
-- ============================================================================

local KNIFE_IDS = { [5000]=true,[5001]=true,[5002]=true,[5003]=true,[5006]=true,[6107]=true,[6108]=true,[6305]=true }

local function mo(ptr) if not ptr then return nil end local ok, o = pcall(function() return sdk.to_managed_object(ptr) end); if ok then return o end end
local function callm(o, m) if not o then return nil end local ok, v = pcall(function() return o:call(m) end); if ok then return v end end
local function callm1(o, m, a) if not o then return nil end local ok, v = pcall(function() return o:call(m, a) end); if ok then return v end end
local function widof(hc)
    local w = callm(hc, "get_WeaponID"); if w == nil then return nil end
    if type(w) == "number" then return w end
    local ok, v = pcall(function() return w.value__ end); if ok and type(v) == "number" then return v end
    return nil
end

-- ---- Singletons ------------------------------------------------------------
local charmgr, hitmgr = nil, nil
local function get_charmgr() if not charmgr then charmgr = sdk.get_managed_singleton("chainsaw.CharacterManager") end return charmgr end
local function get_hitmgr() if not hitmgr then hitmgr = sdk.get_managed_singleton("chainsaw.HitManager") end return hitmgr end
local function get_hc(go) local hm = get_hitmgr() return (hm and go) and callm1(hm, "getHitController", go) or nil end

-- ---- Gespeicherte MESSER-Schadenswerte (persistent) ------------------------
_G.__re4_knife_saved_vals = _G.__re4_knife_saved_vals or (function()
    local ok, d = pcall(function() return json.load_file("re4_vr/re4_knife_dmg.json") end)
    if ok and type(d) == "table" and tonumber(d.damage) and tonumber(d.damage) > 0 then return d end
    return nil
end)()

-- ---- Template: DamageInfo aus einem echten Treffer fangen (valide HitInfo-Struktur) ----
-- Eigene Instanz + copy, weil die Engine ihre DamageInfo poolt. Der Capture liefert die korrekt initialisierte
-- HitInfo-Basis, auf die hitSetting angewiesen ist (frische leere Instanz -> AV-Gefahr in hitSetting).
local function capture_dmginfo(realInfo, is_knife)
    if not realInfo then return end
    if not _G.__re4_knife_dmginfo then
        local inst = nil
        pcall(function() inst = sdk.create_instance("chainsaw.HitController.DamageInfo", true) end)
        if not inst then pcall(function() inst = sdk.create_instance("chainsaw.HitController.DamageInfo") end) end
        if inst then pcall(function() inst:add_ref() end); _G.__re4_knife_dmginfo = inst end
    end
    local t = _G.__re4_knife_dmginfo
    if t then pcall(function() t:call("copy", realInfo) end) end
    if is_knife then
        pcall(function()
            local dmg = tonumber(realInfo:call("get_Damage"))
            if dmg and dmg > 0 then
                local w = realInfo:call("get_WeaponID")
                local wv = (type(w) == "number") and w or (w ~= nil and tonumber(w.value__)) or nil
                local vals = { damage = dmg,
                    wince = tonumber(realInfo:call("get_Wince")) or 1.0,
                    brk   = tonumber(realInfo:call("get_Break")) or 1.0,
                    stop  = tonumber(realInfo:call("get_Stopping")) or 1.0,
                    wid   = wv }
                _G.__re4_knife_saved_vals = vals
                json.dump_file("re4_vr/re4_knife_dmg.json", vals)
            end
        end)
    end
end

local function player_body_go()
    local cm = get_charmgr(); local pctx = cm and callm(cm, "getPlayerContextRef")
    return pctx and callm(pctx, "get_BodyGameObject")
end
local function go_addr(o) if not o then return nil end local ok, a = pcall(function() return o:get_address() end); if ok then return a end end

-- callbackAttackHit(DamageInfo): args[2]=Angreifer-HC, args[3]=DamageInfo. Fuellt die valide DamageInfo-Basis
-- + Messer-Schadenswerte aus JEDEM Player-Treffer (Messer bevorzugt). 1x pro Neustart installiert.
_G.__re4_knife_capture_cb = function(args)
    local info = mo(args[3]); if not info then return end
    local wid = widof(mo(args[2]))
    -- [REKONSTRUKTION 2026-07-23] Das ECHTE, von der Engine vollstaendig gefuellte DamageInfo-Objekt
    -- eines Messertreffers festhalten (mit add_ref verankert). Genau dieses Objekt spielen wir fuer
    -- den Links-Klon wieder ab. Kein create_instance (liefert in diesem Build keine DamageInfo,
    -- der Feld-Dump zeigte Dictionary-Interna) und kein Beschreiben fremder Strukturen.
    -- [OHNE PRIMEN 2026-07-23] Nicht auf einen Messertreffer warten: JEDES Treffer-Ereignis
    -- liefert ein vollstaendig gefuelltes DamageInfo (Schuss, Gegnerschlag, Tritt). Struktur ist das,
    -- was wir brauchen -- die messer-eigenen Werte setzen wir beim Abspielen ohnehin selbst.
    -- Ein echter Messertreffer ueberschreibt die Vorlage trotzdem noch einmal (beste Passung).
    local is_knife = (wid and KNIFE_IDS[wid]) and true or false
    if is_knife or not rawget(_G, "__re4_knife_dmginfo_raw") then
        if is_knife or not rawget(_G, "__re4_knife_dmginfo_raw_knife") then
            pcall(function() info:add_ref() end)
            _G.__re4_knife_dmginfo_raw = info
            if is_knife then _G.__re4_knife_dmginfo_raw_knife = true end
        end
    end
    if wid and KNIFE_IDS[wid] then
        capture_dmginfo(info, true)
    elseif not rawget(_G, "__re4_knife_dmginfo") then
        local owner = callm(info, "get_AttackOwnerObject")
        local pb = player_body_go()
        if owner and pb and go_addr(owner) == go_addr(pb) then capture_dmginfo(info, false) end
    end
end
if not _G.__re4_knife_lh_hook2 then
    _G.__re4_knife_lh_hook2 = true
    local td = sdk.find_type_definition("chainsaw.HitController")
    local m = td and td:get_method("callbackAttackHit")
    if m then
        sdk.hook(m, function(args)
            local f = rawget(_G, "__re4_knife_capture_cb"); if f then pcall(function() f(args) end) end
        end, function(r) return r end)
    end
end

-- ---- [DI_SAVELOAD 2026-08-06 -- Crashdump] Vorlagen bei Save-Load/Charakterwechsel verwerfen ----
-- Zwei Objekte ueberleben hier die ganze Session: __re4_knife_dmginfo_raw (das ECHTE, von der Engine
-- GEPOOLTE DamageInfo, per add_ref verankert) und __re4_knife_dmginfo (eine copy davon). Beide tragen
-- Verweise auf GameObjects/Collider/Joints aus dem Moment des Einfangens. Nach einem Save-Load ist die
-- Szene neu instanziiert -> diese Verweise sind tot, der Effekt-Player der Engine zieht sich daraus im
-- LateUpdate seinen Ziel-Joint und deref't null: FULL CRASH (c0000005 @ RIP 140fdb505 =
-- chainsaw.EPVExpertDamageEffect.findTargetJoint, zweimal identisch belegt 11:00 + 12:41). Passt exakt
-- zum -Muster "meist beim ERSTEN Messerangriff nach einem geladenen Save, aber nicht immer".
-- Erkennung ueber die ADRESSE des Player-Body-GO: Save-Load und Charakterwechsel instanziieren ihn neu.
-- Bei nicht lesbarem Body (Ladephase) wird NICHTS verworfen und NICHTS gemerkt -- kein Muell im Cache
-- (s. [[Notiz]]).
-- Bewusst KEIN release auf das gepoolte Objekt: nach dem Load kann es tot sein, ein release darauf
-- waere genau der Deref, den wir vermeiden wollen. Loslassen genuegt, die Engine besitzt es ohnehin.
-- __re4_knife_saved_vals bleibt: das sind reine Zahlen (Schaden/Wince/Break), keine Objektverweise.
-- [CACHE-ABWURF 2026-08-14] ALLE Objekte, die einen Save-Load nicht ueberleben duerfen, an EINER Stelle.
-- Vorher wurden nur die beiden Vorlagen verworfen; `__re4_knife_native_di` (unsere Bau-DamageInfo),
-- `__re4_knife_dud` und die geliehene `__re4_knife_atk_cache` (weapons.lua) blieben stehen und zeigten
-- nach dem Laden auf Objekte der alten Szene. Kein `release` -- nur loslassen, aus demselben Grund wie
-- unten beim gepoolten Objekt beschrieben.
local function knife_drop_caches(grund)
    _G.__re4_knife_dmginfo           = nil
    _G.__re4_knife_dmginfo_raw       = nil
    _G.__re4_knife_dmginfo_raw_knife = nil
    _G.__re4_knife_native_di         = nil   -- add_ref, trug AttackData/UserData der alten Szene
    _G.__re4_knife_dud               = nil   -- add_ref
    _G.__re4_knife_atk_cache         = nil   -- geliehene AttackUserData (weapons.lua __re4_borrow_knife_atk)
    _G.__re4_knife_di_dropped_t      = os.clock()   -- [FORENSIK] wann zuletzt verworfen
    _G.__re4_knife_di_dropped_why    = grund
end
-- [ERSTER TREFFER 2026-08-14] Nach einem "Reset Scripts" ist `_di_body_addr` wieder nil, die GLOBALS
-- haben den Reset aber ueberlebt: der Guard merkt sich dann nur die aktuelle Adresse und verwirft
-- NICHTS -- lag dazwischen ein Savegame-Load, arbeitet er ab da mit Leichen und haelt sie fuer gueltig.
-- Deshalb beim Laden einmal bedingungslos abwerfen. Kostet nichts: die Vorlage kommt von JEDEM
-- Treffer-Ereignis zurueck (Schuss, Gegnerschlag, Tritt), nicht nur von einem Messertreffer.
knife_drop_caches("Script-Load")

local _di_body_addr, _di_next_check = nil, 0.0
local function knife_di_guard()
    if os.clock() < _di_next_check then return end
    _di_next_check = os.clock() + 0.25
    local pb = player_body_go(); local a = pb and go_addr(pb) or nil
    if a == nil then return end
    if _di_body_addr == nil then _di_body_addr = a; return end
    if a == _di_body_addr then return end
    _di_body_addr = a
    knife_drop_caches("Body-Wechsel (Save-Load / Stage / Charakter)")
end
re.on_frame(function() pcall(knife_di_guard) end)

-- ---- Ziel: naechster lebender Gegner (get_BodyGameObject + HC + hp>0) -------
local function pick_nearest_enemy(pos, reach)
    local cm = get_charmgr(); if not (cm and pos) then return nil end
    local list = callm(cm, "get_EnemyContextList"); if not list then return nil end
    local n = tonumber(callm(list, "get_Count")) or 0
    local best, bestd = nil, (reach or 1.2) * (reach or 1.2)
    for i = 0, n - 1 do
        local e = callm1(list, "get_Item", i)
        local body = e and callm(e, "get_BodyGameObject")
        local tf = body and callm(body, "get_Transform")
        local p = tf and callm(tf, "get_Position")
        local hc = body and get_hc(body)
        local hp = hc and tonumber(callm(hc, "get_CurrentHitPoint"))
        if p and hc and hp and hp > 0 then
            -- [ZYLINDER 2026-08-14] Vorher eine KUGEL um die Koerpermitte (p.y + 0.9). Die passt zur
            -- Figur nicht: gross genug fuer Kopf- und Beintreffer (~0.8 m ueber/unter der Mitte) ragt sie
            -- fast einen Meter VOR den Gegner -- daher blieb das geworfene Messer sichtbar davor stehen.
            -- Klein genug fuer einen sauberen Kontakt deckt sie nur noch den Torso ab -- dann kam gar
            -- kein Treffer mehr. Beides live durchgespielt.
            -- Jetzt ein stehender Zylinder: horizontal (XZ) gegen `reach`, vertikal nur gegen die
            -- Koerperhoehe. Kopf-, Torso- und Beintreffer zaehlen gleichermassen, ohne dass der Radius
            -- nach vorne aufmacht. Hoehenband live tunebar; Rueckbau auf die Kugel:
            -- _G.__re4_knife_pick_sphere = true.
            -- [KASTEN 2026-08-14] Der runde Querschnitt liess Treffer an den ABGESPREIZTEN ARMEN
            -- durchrutschen: die liegen weiter von der Koerperachse weg als Brust und Kopf, ein Kreis
            -- mit sauberem Frontabstand schneidet sie also ab. Deshalb quadratischer Querschnitt statt
            -- Kreis (Kantenmass `reach * box`), Hoehe weiterhin ueber die volle Figur -- also ein
            -- stehender Kasten bis Kopfhoehe. In den Ecken reicht er ~1.4x weiter als der Kreis, genau
            -- dort sitzen die Arme.
            -- Bewusst OHNE die Drehung des Gegners: der Kasten ist weltachsen-parallel, wird also nach
            -- VORNE ebenso grosszuegig wie zur Seite. Loest es dadurch wieder zu frueh aus, waere der
            -- naechste Schritt, ihn in den lokalen Raum des Gegners zu drehen (seitlich breit, vorne schmal).
            -- Live tunebar: __re4_knife_pick_box (Kantenfaktor), __re4_knife_pick_ylo/_yhi (Hoehenband).
            -- Rueckbau: _G.__re4_knife_pick_sphere = true -> wieder die alte Kugel um die Koerpermitte.
            local d2
            local bonef = rawget(_G, "__re4_nearest_bone_dist")
            -- [ZURUECK AUF KASTEN 2026-08-14] Der Knochen-Scan als ALLEINIGES Kriterium traf gar nichts
            -- mehr. Verdacht: `nearest_bone_dist` laeuft den TRANSFORM-Baum (Kind-GameObjects), nicht das
            -- Skelett -- beim rechten Wurf faellt das nicht auf, weil dort der praezise RAY die Arbeit
            -- macht und der Knochen-Scan nur die Nahbereichs-Ergaenzung ist (`close_hit_radius`, und der
            -- Zweig laeuft ausdruecklich nur fuer `not kfly.clone_throw`). Der Klon hat keinen Ray.
            -- Deshalb wieder der Kasten als Default; der Scan bleibt zuschaltbar, bis gemessen ist, wie
            -- gross der Knochenabstand im Treffermoment ueberhaupt wird (steht als bone=... im dbg-String).
            if type(bonef) == "function" and rawget(_G, "__re4_knife_pick_bone") == true then
                -- [KNOCHEN 2026-08-14] Derselbe Weg wie der RECHTE Wurf (weapons.lua): Abstand zum
                -- naechstgelegenen KNOCHEN statt zu einem Huellkoerper. Damit ist der Zielkonflikt weg,
                -- an dem Kugel, Zylinder und Kasten gescheitert sind -- Arme, Kopf und Beine haben
                -- eigene Joints, es braucht also keinen Radius, der nach vorne aufmacht.
                -- Vorfilter wie rechts (reach * 4): nur grob nahe Gegner werden ueberhaupt gescannt,
                -- sonst laeuft der Baum-Walk (bis 120 Joints) fuer jeden Gegner im Level.
                local cx, cy, cz = p.x - pos.x, (p.y + 0.9) - pos.y, p.z - pos.z
                local pre = (reach or 1.0) * 4.0
                if (cx*cx + cy*cy + cz*cz) <= pre*pre then
                    local bd = tonumber(bonef(tf, pos)) or 999.0
                    d2 = bd * bd
                else
                    d2 = 1e9
                end
            elseif rawget(_G, "__re4_knife_pick_sphere") == true then
                local dx, dy, dz = p.x - pos.x, (p.y + 0.9) - pos.y, p.z - pos.z
                d2 = dx*dx + dy*dy + dz*dz
            else
                local ylo = p.y + (tonumber(rawget(_G, "__re4_knife_pick_ylo")) or 0.0)
                local yhi = p.y + (tonumber(rawget(_G, "__re4_knife_pick_yhi")) or 1.9)
                local dy = 0.0
                if pos.y < ylo then dy = ylo - pos.y elseif pos.y > yhi then dy = pos.y - yhi end
                local dx, dz = math.abs(p.x - pos.x), math.abs(p.z - pos.z)
                local box = tonumber(rawget(_G, "__re4_knife_pick_box")) or 1.30
                -- Kastentest: die groessere der beiden Achsen entscheidet (Chebyshev). Fuer die Auswahl
                -- des NAECHSTEN Gegners bleibt es die echte Distanz -- nur der Reichweitentest ist eckig.
                local edge = math.max(dx, dz) / (box > 0.01 and box or 1.0)
                d2 = edge*edge + dy*dy
            end
            if d2 < bestd then best, bestd = { body = body, hc = hc, pos = p }, d2 end
        end
    end
    return best
end

-- ---- DamageInfo fuer die native Kette bauen (valide Basis + Messer-Werte) ---
local function build_dmginfo(victim_hc, victim_body, contact_pos)
    local di = rawget(_G, "__re4_knife_native_di")
    if not di then
        pcall(function() di = sdk.create_instance("chainsaw.HitController.DamageInfo", true) end)
        if not di then pcall(function() di = sdk.create_instance("chainsaw.HitController.DamageInfo") end) end
        if not di then return nil end
        pcall(function() di:add_ref() end)
        _G.__re4_knife_native_di = di
    end
    -- Valide HitInfo-Basis: gefangener Rechts-Treffer bevorzugt (liefert AttackUserData/AttackData der Klinge),
    -- sonst die DamageCalcInfo des Ziels. Danach die Kontakt-/Ziel-Felder auf den AKTUELLEN Gegner ueberschreiben.
    local base = rawget(_G, "__re4_knife_dmginfo") or callm(victim_hc, "get_DamageCalcInfo")
    if base then pcall(function() di:call("copy", base) end) end
    local sv = rawget(_G, "__re4_knife_saved_vals")
    local dmg  = (sv and tonumber(sv.damage)) or 225
    local wince= (sv and tonumber(sv.wince)) or 64.0
    local brk  = (sv and tonumber(sv.brk))   or 1.0
    local stop = (sv and tonumber(sv.stop))  or 1.0
    local wid  = (sv and tonumber(sv.wid)) or tonumber(rawget(_G, "__re4_current_knife_wid")) or 5006
    local pb = player_body_go()
    pcall(function() di:call("set_Damage", math.floor(dmg)) end)
    pcall(function() di:call("set_Wince", wince + 0.0) end)
    pcall(function() di:call("set_Break", brk + 0.0) end)
    pcall(function() di:call("set_Stopping", stop + 0.0) end)
    pcall(function() di:call("set_IsCritical", false) end)
    pcall(function() di:call("set_IsKill", false) end)
    if pb then pcall(function() di:call("set_AttackOwnerObject", pb) end) end
    pcall(function() di:call("set_WeaponID", wid) end)
    -- [PER-VICTIM] ContactInfo auf den aktuellen Gegner umbiegen -> Schaden + BLUT am richtigen Gegner (nicht am
    -- geprimten). DamageGameObject=Gegner, Position=Kontaktpunkt (Brusthoehe).
    -- AttackGameObject ist hier nur die RUECKFALLEBENE (Player-Body): weiter unten wird es auf das
    -- MESSER-GO umgesetzt, sobald der Messer-HitController gefunden ist -- so steht es nativ.
    if pb then pcall(function() di:call("set_AttackGameObject", pb) end) end
    if victim_body then pcall(function() di:call("set_DamageGameObject", victim_body) end) end
    if contact_pos then
        pcall(function() di:call("set_Position", Vector3f.new(contact_pos.x, contact_pos.y, contact_pos.z)) end)
        if pb then
            local ptf = callm(pb, "get_Transform"); local pp = ptf and callm(ptf, "get_Position")
            if pp then
                local nx, ny, nz = contact_pos.x - pp.x, contact_pos.y - pp.y, contact_pos.z - pp.z
                local L = math.sqrt(nx*nx + ny*ny + nz*nz); if L < 0.001 then L = 1.0 end
                pcall(function() di:call("set_Normal", Vector3f.new(nx/L, ny/L, nz/L)) end)
            end
        end
    end
    -- [PRIME-FREI] Klingen-AttackUserData direkt vom Messer-Collider (statt aus gefangenem Rechts-Treffer) ->
    -- calcInfo/hitSetting haben die Angriffsdefinition auch ohne vorherigen Rechts-Treffer. Additiv + pcall:
    -- primt = base traegt schon die richtige (identisch ueberschrieben), unprimt = korrigiert die falsche.
    local ff = rawget(_G, "__re4_find_knife_hc")
    local gg = rawget(_G, "__re4_knife_get_attack_ud")
    local atk_set, ad_set = false, false
    local go_txt = "player"
    if type(ff) == "function" and type(gg) == "function" then
        local khc = ff()
        -- [1:1 NATIV 2026-08-14 -- gemessen in re4_knife_chain.log] Im echten Rechts-Treffer stehen
        -- AttackGameObject UND WeaponGameObject auf DERSELBEN Adresse: dem GameObject des MESSERS,
        -- nicht auf dem Player-Body (der steht nur im AttackOwnerObject, und das setzen wir bereits so).
        -- Quelle ist derselbe Messer-HitController, aus dem unten auch die AttackUserData kommt --
        -- damit passen Angreifer-GO und Angriffsdefinition garantiert zueinander.
        -- Rueckbau: _G.__re4_knife_atk_go_player = true -> beide Felder bleiben der Player-Body.
        if rawget(_G, "__re4_knife_atk_go_player") ~= true then
            local kgo = khc and callm(khc, "get_GameObject")
            if kgo and sdk.is_managed_object(kgo) then
                pcall(function() di:call("set_AttackGameObject", kgo) end)
                pcall(function() di:call("set_WeaponGameObject", kgo) end)
                go_txt = "messer"
            end
        end
        local atk = khc and gg(khc)
        if atk then
            pcall(function() di:call("set_AttackUserData", atk) end)
            atk_set = true
            -- AttackData aus der AttackUserData ableiten (HitController.getAttackData(AttackUserData)) -> das
            -- brachte bisher nur der Prime aus einem echten Treffer mit. Ohne AttackData lehnt hitSetting ab.
            local ad = nil
            pcall(function() ad = khc:call("getAttackData(chainsaw.collision.AttackUserData)", atk) end)
            if ad then pcall(function() di:call("set_AttackData", ad) end); ad_set = true end
        end
    end
    -- DamageUserData (frisch) + ChildHitController (Opfer) -- die restlichen HitInfo-Felder, die der Prime mitbrachte.
    local dud = rawget(_G, "__re4_knife_dud")
    if not dud then
        pcall(function() dud = sdk.create_instance("chainsaw.collision.DamageUserData", true) end)
        if not dud then pcall(function() dud = sdk.create_instance("chainsaw.collision.DamageUserData") end) end
        if dud then pcall(function() dud:add_ref() end); _G.__re4_knife_dud = dud end
    end
    local dud_set = false
    if dud then pcall(function() di:call("set_DamageUserData", dud) end); dud_set = true end
    -- [1:1 NATIV 2026-08-14 -- gemessen in re4_knife_chain.log] Die ECHTE DamageInfo eines rechten
    -- Messertreffers (wp5001) traegt ChildHitController = nil. Das war im Feld-fuer-Feld-Vergleich
    -- LINKS gegen RECHTS das EINZIGE strukturelle Feld, in dem wir abwichen.
    -- Warum das gefaehrlich ist: dieses DamageInfo (`__re4_knife_native_di`) haengt per add_ref und
    -- wird bei JEDEM Treffer wiederverwendet. Ein hier eingetragener Opfer-HitController bleibt also
    -- ueber den Treffer hinaus stehen -- auch wenn der Gegner Sekunden spaeter stirbt oder despawnt.
    -- Genau das Muster des sporadischen c0000005 (RAX=0, im Spielcode, ohne Lua-Frame).
    -- Deshalb wird das Feld aktiv GELEERT statt gesetzt: das `copy` oben kann aus der Vorlage (oder
    -- aus get_DamageCalcInfo des Ziels) durchaus einen Zeiger mitgebracht haben.
    -- Rueckbau: _G.__re4_knife_set_child = true  -> alte Verhaltensweise.
    local child_txt = "?"
    if rawget(_G, "__re4_knife_set_child") == true and victim_hc then
        pcall(function() di:call("set_ChildHitController", victim_hc) end)
        child_txt = "gesetzt(Rueckbau)"
    else
        pcall(function() di:call("set_ChildHitController", nil) end)
        local c = nil
        pcall(function() c = di:get_field("<ChildHitController>k__BackingField") end)
        child_txt = (c == nil) and "leer-ok" or "LEEREN FEHLGESCHLAGEN"
    end
    -- [COLLIDABLE-LEICHEN 2026-08-18 -- bewiesen aus vier Crash-Dumps + Watcher-Log]
    -- Der Absturz sass IMMER an derselben Instruktion (re4+0xfdb505, `mov ecx,[rax+24h]`, rax=1 in
    -- allen Dumps) und die Funktion darueber ist `EPVExpertDamageEffect.findTargetJoint`, Signatur:
    --   findTargetJoint(via.physics.Collidable) -> via.Joint    [ein einziger Parameter]
    -- Das Argument aus dem Log (arg1=ok@21589930) und das Dump-Register r14=21589930 sind dasselbe
    -- Objekt -- ein Collider. Die einzigen Collidables in unserer DamageInfo sind diese beiden
    -- Felder der Basisklasse chainsaw.collision.ContactInfo. Wir setzen sie NIE: sie stammen aus der
    -- eingefangenen Vorlage, also aus einem frueheren Treffer an einem ANDEREN Gegner. Ist der tot
    -- oder despawnt, ist sein Collider recycelt -- die Typkennung besteht den Engine-Check noch,
    -- der Inhalt gehoert aber laengst etwas anderem: an +0x18 steht die Zahl 1, die Engine
    -- dereferenziert sie und stirbt auf Adresse 0x25. Sporadisch, weil es davon abhaengt, ob der
    -- alte Collider noch lebt -- und unabhaengig davon, was rechts in der Hand liegt.
    -- Warum LEEREN sicher ist: die Disassembly zeigt am Funktionsanfang `test r8,r8` + Sprung ans
    -- Ende -- null wird sauber abgefangen, nur Muell ist toedlich. Gleiches Muster wie beim
    -- ChildHitController, der aus demselben Grund seit dem 14.08. aktiv geleert wird.
    -- Rueckbau: _G.__re4_knife_keep_collidables = true
    if rawget(_G, "__re4_knife_keep_collidables") ~= true then
        local geleert = 0
        for _, feld in ipairs({ "AttackCollidable", "DamageCollidable" }) do
            local vorher = nil
            pcall(function() vorher = di:get_field("<" .. feld .. ">k__BackingField") end)
            pcall(function() di:call("set_" .. feld, nil) end)
            local nachher = nil
            pcall(function() nachher = di:get_field("<" .. feld .. ">k__BackingField") end)
            if nachher == nil and vorher ~= nil then geleert = geleert + 1 end
        end
        _G.__re4_knife_collidables_cleared = (tonumber(rawget(_G, "__re4_knife_collidables_cleared")) or 0) + geleert
    end
    pcall(function() di:call("set_IsActive", true) end)   -- hitSetting prueft evtl. IsActive
    _G.__re4_knife_atk_direct = string.format("%s/%s dud=%s child=%s go=%s", tostring(atk_set), tostring(ad_set), tostring(dud_set), child_txt, go_txt)
    return di, dmg
end

-- ---- NATIVER Treffer: calcInfo + hitSetting (kein Collider) -----------------
local CALC_SIG = "calcInfo(chainsaw.HitController.DamageInfo, chainsaw.HitController, chainsaw.HitController)"
local HIT_SIG  = "hitSetting(chainsaw.HitController.DamageInfo, chainsaw.HitController, chainsaw.HitController)"
local function native_hit(hm, di, a, b)   -- a,b = (Angreifer,Opfer) in EINER Reihenfolge
    pcall(function() hm:call(CALC_SIG, di, a, b) end)
    local ok = nil
    pcall(function() ok = hm:call(HIT_SIG, di, a, b) end)
    return ok
end

_G.__re4_knife_direct_damage_at = function(pos, reach)
    if not pos then _G.__re4_knife_clone_dbg = "nopos"; return false end
    local tgt = pick_nearest_enemy(pos, reach or 1.0)
    if not tgt then _G.__re4_knife_clone_dbg = "noenemy"; return false end
    local victim = tgt.hc
    -- Angreifer-HC = Player-Body-HitController (Attack-Owner steht zusaetzlich in der DamageInfo).
    local pb = player_body_go()
    local atkhc = pb and get_hc(pb)
    if not atkhc then _G.__re4_knife_clone_dbg = "noatkhc"; return false end
    local hm = get_hitmgr(); if not hm then _G.__re4_knife_clone_dbg = "nohm"; return false end
    -- [KONTAKTPUNKT 2026-08-14] Vorher lag der Punkt FEST auf Gegner-Wurzel + 1.0 (Brustmitte) -- egal wo
    -- die Klinge wirklich war. Die Engine sucht sich ueber findTargetJoint den Joint ZUR POSITION, deshalb
    -- sah jeder Treffer gleich aus (Kopf, Bein, Ruecken -> immer dieselbe Stelle), waehrend rechts der
    -- echte Kollisionspunkt ankommt.
    -- Jetzt wird der uebergebene `pos` benutzt: bei Melee die linke Hand, beim Wurf die Flugposition des
    -- Messers. Damit er nicht NEBEN dem Koerper landet (Reichweite bis ~0.9 m), wird er auf den Gegner
    -- gezogen -- Hoehe auf Koerperhoehe geklemmt, horizontal auf einen Koerperradius um die Gegner-Achse.
    -- Richtung und Hoehe des Treffers bleiben dabei erhalten, nur der Abstand wird korrigiert.
    -- Live tunebar: __re4_knife_hit_radius / __re4_knife_hit_ymin / __re4_knife_hit_ymax.
    -- Rueckbau: _G.__re4_knife_contact_center = true -> wieder die feste Brustmitte.
    local cpos
    if tgt.pos and pos and rawget(_G, "__re4_knife_contact_center") ~= true then
        -- [RADIUS 2026-08-14] 0.35 war zu weit: der Einschlag lag rund einen halben Meter VOR dem Gegner.
        -- Das ist der Abstand von der KOERPERACHSE, nicht von der Oberflaeche -- ein Ganado misst dort nur
        -- gut 0.15 m. Groesser = weiter aussen/vor dem Gegner, kleiner = tiefer in die Koerpermitte.
        local R    = tonumber(rawget(_G, "__re4_knife_hit_radius")) or 0.15
        local ymin = tonumber(rawget(_G, "__re4_knife_hit_ymin"))   or 0.20
        local ymax = tonumber(rawget(_G, "__re4_knife_hit_ymax"))   or 1.80
        local y = pos.y
        if y < tgt.pos.y + ymin then y = tgt.pos.y + ymin end
        if y > tgt.pos.y + ymax then y = tgt.pos.y + ymax end
        local dx, dz = pos.x - tgt.pos.x, pos.z - tgt.pos.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d > R and d > 0.0001 then dx, dz = dx * (R / d), dz * (R / d) end
        cpos = { x = tgt.pos.x + dx, y = y, z = tgt.pos.z + dz }
    elseif tgt.pos then
        cpos = { x = tgt.pos.x, y = tgt.pos.y + 1.0, z = tgt.pos.z }
    else
        cpos = { x = pos.x, y = pos.y, z = pos.z }
    end
    local di, dmg = build_dmginfo(victim, tgt.body, cpos); if not di then _G.__re4_knife_clone_dbg = "nodi"; return false end

    local hp0 = tonumber(callm(victim, "get_CurrentHitPoint"))
    -- [CRASH-HARDEN 2026-07-20 -- Crashdump belegt] Voller Absturz beim LINKEN Messerwurf auf einen
    -- Gegner: Nullzeiger-Deref MITTEN IM SPIELCODE (rax=0, "mov ecx,[rax+24h]", Stack rein re4! ohne
    -- REFramework). Ursache: das Messer fliegt sekundenlang -- stirbt oder despawnt der Gegner in der Zeit,
    -- existiert sein HitController zwar noch als Objekt, ist intern aber tot. native_hit deref't dann null,
    -- und ein pcall faengt eine Access Violation NICHT ab (siehe auch der inv:reload-Crash).
    -- Deshalb DIREKT vor dem nativen Aufruf gegenpruefen: Objekt gueltig, Gegner lebt, HP > 0.
    -- Faellt einer der Checks -> kein Angriff. Kostet nur einen verpassten Treffer auf eine Leiche.
    do
        local alive = (hp0 ~= nil and hp0 > 0)
        if alive and callm(victim, "get_Valid") == false then alive = false end
        if alive and callm(victim, "get_IsLive") == false then alive = false end
        if alive and tgt.ctx and callm(tgt.ctx, "get_IsEliminated") == true then alive = false end
        if not alive then _G.__re4_knife_clone_dbg = "victim-tot/ungueltig"; return false end
    end
    -- Reihenfolge A fest (Angreifer, Opfer). B ist raus -- sie hat im Test einen Gegner GEHEILT (hp 85->1296).
    -- [CRASH-SPUR] Bleibt drin, bis der Absturz EINMAL gefangen ist: der Logger flusht jede Zeile
    -- sofort, die letzte Zeile im Log benennt also den Aufruf, der das Spiel gerissen hat.
    local ok = native_hit(hm, di, atkhc, victim)
    local hp1 = tonumber(callm(victim, "get_CurrentHitPoint"))

    -- [HIT SOUND 2026-07-09] Messer-Treffer-Sound am Gegner (hitSetting spielt ihn nicht -> explizit ueber den
    -- Messer-Container). MELEE = Stich (238304172), WURF = eigener Impact (797300665, so gewollt). src aus
    -- __re4_knife_hit_src ("melee" gesetzt vom Melee-Entry, sonst Wurf). Nur bei echtem Treffer. Beide tunebar.
    if (ok == true) or (hp0 and hp1 and hp1 < hp0) then
        local melee = rawget(_G, "__re4_knife_hit_src") == "melee"
        local sid = melee and (tonumber(rawget(_G, "__re4_knife_lh_hit_snd")) or 238304172)
                          or  (tonumber(rawget(_G, "__re4_knife_lh_throw_hit_snd")) or 797300665)
        local ps = rawget(_G, "__re4_knife_lh_play_sound")
        if type(ps) == "function" then pcall(function() ps(math.floor(sid)) end) end
    end

    -- [BLUT] explizit am AKTUELLEN Gegner ausloesen (hitSetting rendert selbst kein Blut). saveStamp-Replay
    -- aus __re4_blood_cap (re4_zz_blood_trace saveA-Hook). bstat sagt eindeutig, woran es haengt.
    local bstat = "off"
    if rawget(_G, "__re4_knife_blood_on") ~= false then
        local cap = rawget(_G, "__re4_blood_cap")
        -- [BLUT-GUARD 2026-08-13] Das Blut laeuft NACH dem Schaden. Toetet der Treffer den Gegner (oder
        -- despawnt er im selben Frame), ist sein DamageEffect schon im Abbau -- der native saveStamp
        -- greift dann ins Leere und reisst das Spiel mit (c0000005, RAX=0). Ein pcall faengt so eine
        -- Access Violation NICHT, also wird VORHER geprueft: lebt das Opfer noch, ist es gueltig, sind
        -- Body und Effekt echte Objekte. Faellt eine Pruefung, entfaellt nur der Blutfleck -- Schaden,
        -- Ton und Reaktion sind zu dem Zeitpunkt laengst durch.
        local lebt = (hp1 ~= nil and hp1 > 0)
        if lebt and callm(victim, "get_Valid") == false then lebt = false end
        if lebt and callm(victim, "get_IsLive") == false then lebt = false end
        if lebt and tgt.ctx and callm(tgt.ctx, "get_IsEliminated") == true then lebt = false end
        if lebt and not (tgt.body and sdk.is_managed_object(tgt.body)) then lebt = false end
        if not cap then bstat = "nocap"
        elseif not lebt then bstat = "opfer-tot/ungueltig"
        else
            local de = callm(victim, "get_DamageEffect")
            if de and not sdk.is_managed_object(de) then de = nil end
            if not de then bstat = "node"
            else
                pcall(function() de:call("collectMarkStampController") end)
                local joint = nil
                if cap.jhash then local tf = callm(tgt.body, "get_Transform"); if tf then pcall(function() joint = tf:call("getJointByHash", math.floor(cap.jhash)) end) end end
                if not joint then joint = callm(de, "get_RootJoint") end
                if not joint then bstat = "nojoint"
                else
                    local p = Vector3f.new(cap.px or 0.0, cap.py or 0.0, cap.pz or 0.0)
                    local d = Vector3f.new(cap.dx or 0.0, cap.dy or 1.0, cap.dz or 0.0)
                    _G.__re4_blood_replaying = true
                    pcall(function()
                        de:call("saveStamp(via.relib.effect.behavior.ReLibMarkStampController.Type, System.Int32, via.vec3, System.Single, via.vec3, via.Joint)",
                            math.floor(cap.ty or 0), math.floor(cap.id or 1), p, cap.rot or 0.0, d, joint)
                    end)
                    pcall(function() de:call("applyStampDataToContext") end)
                    _G.__re4_blood_replaying = false
                    bstat = "set"
                end
            end
        end
    end

    local src = rawget(_G, "__re4_knife_hit_src") or "wurf"; _G.__re4_knife_hit_src = nil
    _G.__re4_knife_clone_dbg = string.format("%s set=%s dmg=%s hp %s->%s blut=%s atk=%s", src, tostring(ok), tostring(dmg), tostring(hp0), tostring(hp1), bstat, tostring(rawget(_G, "__re4_knife_atk_direct")))
    return (hp0 and hp1 and hp1 < hp0) or ok == true
end

_G.__re4_knife_direct_damage = function(reach)
    local lh = rawget(_G, "__vr_lh_world"); if not lh then return false end
    _G.__re4_knife_hit_src = "melee"   -- Tag fuers Log (Wurf ruft direct_damage_at direkt -> default "wurf")
    -- [REACH] Links-Melee-Reichweite = wie das RECHTE Messer (__re4_knife_reach, ~0.9). Vorher fest 1.8 -> doppelt
    -- so weit -> traf zu weit entfernte Gegner. Nutzt denselben Reach-Slider wie rechts (live tunbar).
    local r = tonumber(rawget(_G, "__re4_knife_reach")) or 0.9
    return _G.__re4_knife_direct_damage_at(lh, r) == true
end

-- =====================================================================
-- [KLON-TREFFER 2026-07-23] Den EMPFANG nachbauen statt die Anmeldung.
--
-- Belegt (Probe re4_zzz_recv, 14:30): nach einem rechten Messertreffer ruft die Engine am Ziel
-- `onHitDamage(chainsaw.HitController.DamageInfo)` auf -- beim Huhn chainsaw.GmChicken, bei der
-- haengenden Muenze chainsaw.GmBlueCoin. `requestAttack` dagegen ist nur die Anmeldung und wird
-- ohne Beruehrung des Klingen-Colliders nie aufgeloest; der Klon hat keinen.
--
-- WICHTIG: Es wird NUR die weiter oben per copy eingefangene Vorlage `__re4_knife_dmginfo`
-- benutzt. Eine selbst erzeugte, halb gefuellte DamageInfo hat das Spiel Sekunden spaeter in einem
-- Worker-Thread mit c0000005 zerlegt (Dump 15:06) -- genau davor warnt der Kommentar bei
-- capture_dmginfo. Ohne Vorlage wird nicht gefeuert.
local function find_onhit_receiver(go)
    for _ = 0, 3 do
        if not go then return nil end
        local comps = callm(go, "get_Components")
        local n = comps and tonumber(callm(comps, "get_Count")) or 0
        for i = 0, math.min(n, 24) - 1 do
            local c = callm1(comps, "get_Item(System.Int32)", i)
            local ok, m = pcall(function() return c:get_type_definition():get_method("onHitDamage") end)
            if ok and m then return c end
        end
        local tf = callm(go, "get_Transform"); local ptf = tf and callm(tf, "get_Parent")
        go = ptf and callm(ptf, "get_GameObject") or nil
    end
    return nil
end

-- Vorlage OHNE Primen: jeder HitController traegt eine gueltige, von der Engine initialisierte
-- DamageCalcInfo. Die kopieren wir in eine eigene Instanz (gleiches Muster wie capture_dmginfo) und
-- setzen nur die Messerwerte drauf -- die stehen dauerhaft in re4_vr/re4_knife_dmg.json und muessen
-- deshalb nicht in jeder Sitzung neu erspielt werden.

_G.__re4_knife_onhit_replay = function(target_go, atk_ud)
    if not target_go then return false end
    local recv = find_onhit_receiver(target_go)
    if not recv then return false end
    -- Das echte Treffer-Objekt der Engine; ohne das wird NICHT gefeuert.
    local di = rawget(_G, "__re4_knife_dmginfo_raw")
    -- [SAVE-LOAD 2026-07-23] Das eingefangene Objekt gehoert der Engine (Pool). Nach einem
    -- Save-Load kann der Zeiger tot sein -- ein Zugriff darauf waere ein Absturz. Deshalb vor jeder
    -- Benutzung kurz anfassen; faellt das durch, verwerfen und auf den naechsten echten Treffer warten
    -- (der kommt automatisch, es muss nichts "geprimt" werden).
    if di then
        -- Nur pruefen, ob das Objekt ueberhaupt ansprechbar ist -- NICHT ob ein bestimmtes Feld einen
        -- Wert hat: ein nil-Rueckgabewert kam auch bei voellig gueltigen Objekten vor und hat die
        -- Vorlage bei jedem Schlag verworfen (Symptom: Huhn stirbt gar nicht mehr).
        local alive = false
        pcall(function() alive = (di:get_type_definition() ~= nil) end)
        if not alive then
            _G.__re4_knife_dmginfo_raw = nil
            _G.__re4_knife_dmginfo_raw_knife = nil
            di = nil
        end
    end
    -- [KEIN HOOK NOETIG 2026-07-23] Faellt die eingefangene Vorlage aus (der Capture-Hook stirbt
    -- nach mehrfachem "Reset Scripts" -- Hooks stapeln sich und feuern irgendwann nicht mehr), nehmen
    -- wir die DamageInfo, die der Ziel-HitController ohnehin besitzt. Das ist erlaubt, seit wir alle
    -- veraenderten Felder direkt nach dem Aufruf wieder zurueckschreiben.
    if not di then di = callm(get_hc(target_go), "get_DamageCalcInfo") end
    if not di then return false end
    -- [POOL-SCHUTZ 2026-07-23] `di` ist das GEPOOLTE DamageInfo der Engine -- sie beschreibt es
    -- bei jedem echten Treffer neu und zieht daraus u.a. Blut und Trefferreaktion. Wenn wir Felder
    -- darin dauerhaft ueberschreiben, arbeiten alle folgenden echten Treffer mit unseren Werten
    -- weiter (Symptom: Gegner und Huehner bluten nicht mehr). Deshalb: Werte merken, setzen,
    -- aufrufen, danach exakt den Vorzustand zurueckschreiben.
    local v = rawget(_G, "__re4_knife_saved_vals") or {}
    local kgo = callm(rawget(_G, "__re4_knife_atk_hc"), "get_GameObject")
    local FIELDS = {
        { "<Damage>k__BackingField",           tonumber(v.damage) or 225 },
        { "<Wince>k__BackingField",            tonumber(v.wince)  or 86.4 },
        { "<Break>k__BackingField",            tonumber(v.brk)    or 1080.0 },
        { "<Stopping>k__BackingField",         tonumber(v.stop)   or 1008.0 },
        { "<WeaponID>k__BackingField",         tonumber(v.wid)    or 5001 },
        { "<IsActive>k__BackingField",         true },
        { "<DamageGameObject>k__BackingField", target_go },
        { "<WeaponGameObject>k__BackingField", kgo },
        { "<AttackGameObject>k__BackingField", kgo },
        { "<AttackUserData>k__BackingField",   atk_ud },
    }
    local saved = {}
    for i, f in ipairs(FIELDS) do
        if f[2] ~= nil then
            local old = nil
            pcall(function() old = di:get_field(f[1]) end)
            saved[i] = { f[1], old }
            pcall(function() di:set_field(f[1], f[2]) end)
        end
    end

    local ok = pcall(function() recv:call("onHitDamage", di) end)

    -- [SOUND WIE BEIM GEGNER 2026-07-23] Die Engine spielt bei unserem Nachbau nichts -- genau wie
    -- bei den Gegnern, wo wir Ton und Blut seit dem 09.07. selbst ausloesen (s. direct_damage_at).
    -- Also denselben Messer-Trefferton feuern: Stich bzw. Wurf, je nach Quelle.
    if ok then
        local melee = rawget(_G, "__re4_knife_hit_src") == "melee"
        local sid = melee and (tonumber(rawget(_G, "__re4_knife_lh_hit_snd")) or 238304172)
                          or  (tonumber(rawget(_G, "__re4_knife_lh_throw_hit_snd")) or 797300665)
        local ps = rawget(_G, "__re4_knife_lh_play_sound")
        if type(ps) == "function" then pcall(function() ps(math.floor(sid)) end) end
    end

    -- Vorzustand des gepoolten Objekts sofort wiederherstellen
    for _, e in pairs(saved) do
        if e and e[2] ~= nil then pcall(function() di:set_field(e[1], e[2]) end) end
    end

    return ok == true
end

-- [BREAKABLE 2026-07-09] Box-Break-Completion fuer den Klon. break_nearby (weapons.lua) macht set_Routine(Break)
-- = nur Optik; die Engine-Completion (IsBroken=True, Prompt weg) kommt sonst per requestAttack, das beim Klon
-- mangels Collider NICHT landet. Loesung wie bei den Gegnern: hitSetting auf den Box-HitController.
-- box_go = das getroffene Box-GO (aus break_nearby), pos = dessen Position.
_G.__re4_knife_hitset_box = function(box_go, pos)
    if not box_go then return false end
    local boxhc = get_hc(box_go); if not boxhc then return false end
    local pb = player_body_go(); local atkhc = pb and get_hc(pb); if not atkhc then return false end
    local hm = get_hitmgr(); if not hm then return false end
    local cpos = pos and { x = pos.x, y = pos.y + 0.3, z = pos.z } or nil
    local di = build_dmginfo(boxhc, box_go, cpos); if not di then return false end
    local ok = native_hit(hm, di, atkhc, boxhc)
    -- [BREAK SOUND] Der alte hardcodierte trigger(3867644446) auf box_go war stumm (box_go = Before/After-
    -- Collider-Kind OHNE eigenen SoundContainer -- der sitzt am Parent). Ersetzt durch clone_break_sound
    -- in weapons.lua break_nearby (Parent-Walk + objekt-eigene Trigger-ID, VOR set_Routine).
    return true
end

-- ---- STEP 1: nativen RECHTS-Messer-Schaden aufnehmen (persistieren) ---------
re.on_frame(function()
    if rawget(_G, "__re4_knife_saved_vals") then return end
    local cap = rawget(_G, "__re4_knife_dmginfo"); if not cap then return end
    local dmg = nil; pcall(function() dmg = tonumber(cap:call("get_Damage")) end)
    if not (dmg and dmg > 0) then return end
    pcall(function()
        local w = cap:call("get_WeaponID")
        local wv = (type(w) == "number") and w or (w ~= nil and tonumber(w.value__)) or nil
        local vals = { damage = dmg,
            wince = tonumber(cap:call("get_Wince")) or 1.0,
            brk   = tonumber(cap:call("get_Break")) or 1.0,
            stop  = tonumber(cap:call("get_Stopping")) or 1.0,
            wid   = wv }
        _G.__re4_knife_saved_vals = vals
        json.dump_file("re4_vr/re4_knife_dmg.json", vals)
    end)
end)

end)()

-- ==================== >>> re4_vr_wildwest.lua <<< ====================
;(function()
-- re4_vr_wildwest.lua
-- ============================================================================
-- GUNSLINGER-TWIRL: anhaltende AUF-AB-Wippe der Waffenhand (rechts) -> die PISTOLE dreht sich um die
-- Pitch-Achse um den TRIGGER-JOINT (joint_03), plus eine HAND-POSE (Daumen/Finger), die mit dem Spin
-- reinlerpt. Nur Pistolen, nur wenn NICHT gezielt.
-- * Start: Y-Oszillation muss SUSTAIN s anhalten. Laufen: dreht kontinuierlich solange du wippst.
-- Ende (Wippe stoppt / Zielen): laufende Umdrehung faehrt bis zur naechsten vollen 360 (Griffpose).
-- * Pivot: Positions-Korrektur haelt joint_03 fix. Feinjustage per Slider.
-- * Hand-Pose: additive lokale Rotationen pro Finger (wie knife_flip_finger_open), per-Finger X/Y/Z
-- Grad tunebar -> "Daumen hoch, Finger gestreckt, Zeigefinger 90 nach links" live einstellen.
-- Laeuft im motion-Finger-Pass (_G.__re4_wildwest_fingers), geblendet mit dem Spin.
-- Alles in re4_vr/re4_vr_wildwest.json geparkt. UI: REFramework-Menue -> "RE4 VR - Wild West".
-- ============================================================================
if reframework:get_game_name() ~= "re4" then return end

-- Trigger-Joint im WAFFEN-Skelett heisst "_03" (root,_00,_01,_02,_03,...) -- NICHT "joint_03".
-- getJointByName("joint_03") gab null -> Pivot wurde nie berechnet (active_lp nil, Slider wirkungslos,
-- Drehung um den Waffen-Origin statt um den Trigger). Live live am wp4000-Skelett verifiziert.
local TRIGGER_JOINT = "_03"
local JSON_PATH = "re4_vr/re4_vr_wildwest.json"

local PISTOLS = {
    [4000]=true,[4001]=true,[4002]=true,[4003]=true,[4004]=true,
    [4500]=true,[4501]=true,[4502]=true,
    [6000]=true,[6103]=true,[6112]=true,[6113]=true,[6300]=true,
}   -- [SW 2026-07-19] 6112 = Punisher MC (Separate Ways) ergaenzt; 6300 = Mercenaries-DLC.
local FINGERS_UI = {
    { label="Daumen",       joints={"R_Thumb1","R_Thumb2","R_Thumb3"} },
    { label="Zeigefinger",  joints={"R_IndexF1","R_IndexF2","R_IndexF3"} },
    { label="Mittelfinger", joints={"R_MiddleF1","R_MiddleF2","R_MiddleF3"} },
    { label="Ringfinger",   joints={"R_RingF1","R_RingF2","R_RingF3"} },
    { label="Kleiner",      joints={"R_PinkyF1","R_PinkyF2","R_PinkyF3"} },
}
-- Alte per-Finger-Keys -> die 3 Joints (fuer Migration alter JSON).
local FINGER_OLD_MAP = {
    thumb  = {"R_Thumb1","R_Thumb2","R_Thumb3"},   index = {"R_IndexF1","R_IndexF2","R_IndexF3"},
    middle = {"R_MiddleF1","R_MiddleF2","R_MiddleF3"}, ring = {"R_RingF1","R_RingF2","R_RingF3"},
    pinky  = {"R_PinkyF1","R_PinkyF2","R_PinkyF3"},
}
local ALL_JOINTS = {}
for _, f in ipairs(FINGERS_UI) do for _, j in ipairs(f.joints) do ALL_JOINTS[#ALL_JOINTS+1] = j end end

-- ---- Config (Defaults; aus JSON ueberschrieben)
_G.__re4_ww_enabled = (_G.__re4_ww_enabled ~= false)
_G.__re4_ww_sustain = tonumber(_G.__re4_ww_sustain) or 0.60
_G.__re4_ww_sens    = tonumber(_G.__re4_ww_sens)    or 1.20
-- [RT_GATE 2026-07-21] Rechten Trigger GEHALTEN = Direkt-Twirl-Gate: kein Sustain-Anlauf und eine
-- eigene (viel feinere) Wippe-Empfindlichkeit -> die Waffe dreht sofort bei kleinster Bewegung. Loslassen
-- beendet das Gate (laufender Gate-Spin faehrt auf die volle Umdrehung aus). Das Gate liest NUR mit
-- (__vr_raw_r_trigger aus binding.lua) und aendert NICHTS an RTs bestehenden Funktionen -- die haben
-- ausnahmslos Vorrang (Schuss bei Aim/Battle-State, Messer-Flip, Finisher, Grapple, Dual-Trigger-Menue).
-- Deshalb auch die harten Gates: nur reines Gameplay (__re4_frame_is_gameplay -> kein Menu/Boot/Throwsight/
-- Bino/KS) und NIE mit Messer in der Hand (equippt oder Links-Klon).
_G.__re4_ww_rt_gate = (_G.__re4_ww_rt_gate ~= false)                -- Feature an/aus (default an)
_G.__re4_ww_rt_sens = tonumber(_G.__re4_ww_rt_sens) or 0.10
_G.__re4_ww_rt_lockout = tonumber(_G.__re4_ww_rt_lockout) or 1.0   -- s Sperre nach dem letzten Schuss -- Empfindlichkeit NUR bei gehaltenem RT (kleinste Bewegung)
_G.__re4_ww_speed   = tonumber(_G.__re4_ww_speed)   or 720.0
_G.__re4_ww_dir     = tonumber(_G.__re4_ww_dir)     or 1.0
_G.__re4_ww_pivot_x = tonumber(_G.__re4_ww_pivot_x) or 0.0
_G.__re4_ww_pivot_y = tonumber(_G.__re4_ww_pivot_y) or 0.0
_G.__re4_ww_pivot_z = tonumber(_G.__re4_ww_pivot_z) or 0.0
-- Waffen-Positions-Offset WAEHREND der Drehung (Ruhe-Waffen-Frame, m) -> Gun an die Hand schieben.
_G.__re4_ww_off_x = tonumber(_G.__re4_ww_off_x) or 0.0
_G.__re4_ww_off_y = tonumber(_G.__re4_ww_off_y) or 0.0
_G.__re4_ww_off_z = tonumber(_G.__re4_ww_off_z) or 0.0
_G.__re4_ww_prev_angle = tonumber(_G.__re4_ww_prev_angle) or 90.0   -- Vorschau: Gun auf diesen Winkel einfrieren (nur Tuning)
_G.__re4_ww_prev_interp = (_G.__re4_ww_prev_interp == true)         -- Vorschau zeigt interpolierte Keyframe-Offsets statt Live-Slider
_G.__re4_ww_sound = (_G.__re4_ww_sound ~= false)                    -- Twirl-Sound an/aus (default an)
_G.__re4_ww_snd_interval = tonumber(_G.__re4_ww_snd_interval) or 0.12  -- Re-Trigger-Intervall (One-Shot, ~Sound-Laenge)
-- [TWIRL-SPRUCH 2026-08-04] Leon kommentiert seine Show -- fest verdrahtet, KEINE UI:
-- 1.5s am Stueck drehen, dann jeder 7. lange Twirl. Werte stehen unten bei TWIRL_VOICE.
-- Per-Phase Waffen-Offset-KEYFRAMES {a=Salto-Fortschritt 0..360 Grad, x,y,z}. Waehrend des Twirls wird
-- zwischen ihnen interpoliert (offset_at) -> der Finger bleibt in JEDER Phase des Saltos am Trigger.
-- Achse ist dir-unabhaengiger Fortschritt (_G.__re4_wildwest_progress). Aufsteigend nach.a sortiert gehalten.
-- [PER-WAFFE KEYFRAMES 2026-07-18] Salto-Offset-Keyframes jetzt PRO WAFFE (wid -> Array). OKEYS ist der
-- ZEIGER auf das Array der aktuell equippten Waffe; on_frame + UI setzen ihn frisch (repoint). So teilen sich
-- offset_at/save_keyframe/UI denselben Zeiger, ohne neue Main-Chunk-Locals. Store global.
local OKEYS = {}
_G.__re4_ww_okeys_by_wid = _G.__re4_ww_okeys_by_wid or {}
-- Finger-Pose PRO JOINT (additive Euler-Grad, jedes Finger-Segment einzeln). 0 = keine Aenderung -> live tunen.
local FING = {}
for _, jn in ipairs(ALL_JOINTS) do FING[jn] = { x=0.0, y=0.0, z=0.0 } end

local BOB_GAP = 0.5
local BLEND_SPD = 8.0   -- Finger-Pose Ein/Ausblend-Tempo (~0.15s)

local function sc(o, m) if not o then return nil end local ok, r = pcall(function() return o:call(m) end); if ok then return r end end

-- ---- JSON
local function save_cfg()
    local t = {
        enabled=_G.__re4_ww_enabled, sustain=_G.__re4_ww_sustain, sens=_G.__re4_ww_sens,
        speed=_G.__re4_ww_speed, dir=_G.__re4_ww_dir,
        pivot={x=_G.__re4_ww_pivot_x,y=_G.__re4_ww_pivot_y,z=_G.__re4_ww_pivot_z},
        offset={x=_G.__re4_ww_off_x,y=_G.__re4_ww_off_y,z=_G.__re4_ww_off_z},
        sound=_G.__re4_ww_sound,
        snd_interval=_G.__re4_ww_snd_interval,
        rt_gate=_G.__re4_ww_rt_gate, rt_sens=_G.__re4_ww_rt_sens, rt_lockout=_G.__re4_ww_rt_lockout,   -- [RT_GATE]
        joints=FING,
    }
    -- [PER-WAFFE KEYFRAMES] okeys pro Waffe, String-Keys fuer JSON (numerische wid-Keys wuerden als Sparse-Array dumpen).
    local _okw = {}
    for wid, arr in pairs(_G.__re4_ww_okeys_by_wid or {}) do
        if type(arr) == "table" then
            local a = {}
            for _, kf in ipairs(arr) do a[#a+1] = { a = kf.a, x = kf.x, y = kf.y, z = kf.z } end
            _okw[tostring(wid)] = a
        end
    end
    t.okeys_by_wid = _okw
    pcall(function() json.dump_file(JSON_PATH, t) end)
end
local function load_cfg()
    local ok, d = pcall(function() return json.load_file(JSON_PATH) end)
    if not ok or type(d) ~= "table" then return end
    if d.enabled ~= nil then _G.__re4_ww_enabled = d.enabled and true or false end
    if d.sound ~= nil then _G.__re4_ww_sound = d.sound and true or false end
    if tonumber(d.snd_interval) then _G.__re4_ww_snd_interval = d.snd_interval end
    if tonumber(d.sustain) then _G.__re4_ww_sustain = d.sustain end
    if tonumber(d.sens) then _G.__re4_ww_sens = d.sens end
    if d.rt_gate ~= nil then _G.__re4_ww_rt_gate = d.rt_gate and true or false end   -- [RT_GATE]
    if tonumber(d.rt_sens) then _G.__re4_ww_rt_sens = d.rt_sens end
    if tonumber(d.rt_lockout) then _G.__re4_ww_rt_lockout = d.rt_lockout end
    if tonumber(d.speed) then _G.__re4_ww_speed = d.speed end
    if tonumber(d.dir) then _G.__re4_ww_dir = d.dir end
    if type(d.pivot) == "table" then
        _G.__re4_ww_pivot_x = tonumber(d.pivot.x) or 0.0
        _G.__re4_ww_pivot_y = tonumber(d.pivot.y) or 0.0
        _G.__re4_ww_pivot_z = tonumber(d.pivot.z) or 0.0
    end
    if type(d.offset) == "table" then
        _G.__re4_ww_off_x = tonumber(d.offset.x) or 0.0
        _G.__re4_ww_off_y = tonumber(d.offset.y) or 0.0
        _G.__re4_ww_off_z = tonumber(d.offset.z) or 0.0
    end
    if type(d.okeys_by_wid) == "table" then    -- [PER-WAFFE KEYFRAMES] String-Keys zurueck auf wid-Zahl
        _G.__re4_ww_okeys_by_wid = {}
        for k, arr in pairs(d.okeys_by_wid) do
            local wn = tonumber(k)
            if wn and type(arr) == "table" then
                local t2 = {}
                for _, kf in ipairs(arr) do if type(kf) == "table" and tonumber(kf.a) then t2[#t2+1] = { a=tonumber(kf.a), x=tonumber(kf.x) or 0.0, y=tonumber(kf.y) or 0.0, z=tonumber(kf.z) or 0.0 } end end
                table.sort(t2, function(p, q) return p.a < q.a end)
                _G.__re4_ww_okeys_by_wid[wn] = t2
            end
        end
    elseif type(d.okeys) == "table" then       -- [MIGRATION] alte flache Keyframes -> Blacktail (4003)
        local t2 = {}
        for _, kf in ipairs(d.okeys) do if type(kf) == "table" and tonumber(kf.a) then t2[#t2+1] = { a=tonumber(kf.a), x=tonumber(kf.x) or 0.0, y=tonumber(kf.y) or 0.0, z=tonumber(kf.z) or 0.0 } end end
        table.sort(t2, function(p, q) return p.a < q.a end)
        _G.__re4_ww_okeys_by_wid[4003] = t2
    end
    if type(d.joints) == "table" then          -- neues Pro-Joint-Format
        for jn, g in pairs(FING) do
            local s = d.joints[jn]
            if type(s) == "table" then g.x = tonumber(s.x) or 0.0; g.y = tonumber(s.y) or 0.0; g.z = tonumber(s.z) or 0.0 end
        end
    elseif type(d.fingers) == "table" then      -- Migration: altes per-Finger -> alle 3 Joints
        for fn, joints in pairs(FINGER_OLD_MAP) do
            local s = d.fingers[fn]
            if type(s) == "table" then
                for _, jn in ipairs(joints) do
                    if FING[jn] then FING[jn].x = tonumber(s.x) or 0.0; FING[jn].y = tonumber(s.y) or 0.0; FING[jn].z = tonumber(s.z) or 0.0 end
                end
            end
        end
    end
end
load_cfg()

-- ---- Quaternion aus additivem Euler (Grad). Reihenfolge X*Y*Z; (W,X,Y,Z).
local function axis_q(deg, ax, ay, az)
    local h = math.rad(deg) * 0.5
    local s = math.sin(h)
    return Quaternion.new(math.cos(h), s*ax, s*ay, s*az)
end
local function euler_add(dx, dy, dz)
    if dx == 0 and dy == 0 and dz == 0 then return nil end
    local ok, q = pcall(function() return axis_q(dx,1,0,0) * axis_q(dy,0,1,0) * axis_q(dz,0,0,1) end)
    if ok then return q end
    return nil
end

-- ---- Waffen/Body-Zugriff
local function head_updater()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = sc(cm, "getPlayerContextRef"); if not ctx then return nil end
    return sc(ctx, "get_HeadUpdater")
end
local function wid_from_hu(hu)
    local v = sc(hu, "get_EquipWeaponID")
    if type(v) == "number" then return v end
    if type(v) == "userdata" then local ok, n = pcall(function() return v:get_field("value__") end); if ok then return n end end
    return nil
end
-- ============================================================================================
-- [STOCK-SPERRE 2026-08-12] Mit montiertem Stock (Schulterstuetze) ergibt der Gunslinger-Twirl
-- keinen Sinn -- bis heute ging er trotzdem. Betrifft die Twirl-Waffen Red9 (4002) und
-- Matilda (4004); die TMP (4200) steht ohnehin nicht in PISTOLS.
--
-- ERKENNUNG (live gemessen mit #stock_probe.lua, Script danach geloescht):
--   Waffe            ohne Stock                        mit Stock
--   Red9   (4002)    isPartsEquipped=false, count=0    true, count=1, ItemId=116001600
--   Matilda(4004)    isPartsEquipped=false, count=0    true, count=1, ItemId=116009600
-- `getEquippedPartsItemId` liefert ohne Part -1. Alle drei Wege (isPartsEquipped /
-- getPartsCount / WeaponPartsCustom.getPartsIdList) schalten uebereinstimmend um.
--
-- [KORREKTUR 2026-08-14] Frueher stand hier `isPartsEquipped()` mit der Begruendung, beide Waffen
-- kennten nur DIESES eine Anbauteil. Das ist FALSCH: ein montierter LASER ist ebenfalls ein Part
-- und hat den Twirl komplett gesperrt. Gesperrt wird jetzt ausschliesslich ueber die beiden oben
-- gemessenen STOCK-ItemIDs -- jedes andere Anbauteil (Laser etc.) twirlt weiter.
-- `isPartsEquipped()` bleibt nur als billige Vorpruefung: false -> gar kein Part -> sofort raus.
--
-- NICHT ueber den Mesh-Part-Weg (re4_vr_motion.lua:4440, `getPartsEnable(11)`): die Nummer gilt
-- nur fuer die Matilda, wurde live erraten und haengt an der Mesh-Struktur -- sie kippt, sobald
-- Parts aus- oder umgeblendet werden. Die Parts-API kommt aus dem Inventar-Datenmodell.
-- Gelesen wird auf der ECHTEN Instanz ueber den Accessor ([[reference_re4_echte_weaponitem_instanz]]).
--
-- Gecacht (0.25 s bzw. bis zum Waffenwechsel): der Stock wird nur im Koffer montiert, eine
-- Abfrage pro Frame waere Verschwendung. Ist nichts lesbar, gilt "kein Stock" -> der Twirl
-- verhaelt sich exakt wie bisher, statt faelschlich zu sperren.
-- RUECKBAU: _G.__re4_ww_block_with_stock = false
-- ============================================================================================
_G.__re4_ww_block_with_stock = (_G.__re4_ww_block_with_stock ~= false)
-- Nur DIESE ItemIDs sind Schulterstuetzen (live gemessen, s. Tabelle oben). Alles andere am Lauf
-- (Laser usw.) laesst den Twirl in Ruhe. Kommt je ein weiterer Stock dazu: hier eintragen.
-- Stock und Laser sind im Spiel NIE gleichzeitig montierbar (14.08. bestaetigt) -- deshalb genuegt
-- die eine ID aus `getEquippedPartsItemId`, eine Part-LISTE muss hier nicht ausgewertet werden.
local STOCK_ITEM_IDS = { [116001600] = true,   -- Red9   (4002) Schulterstuetze
                         [116009600] = true }  -- Matilda(4004) Schulterstuetze
local stock_c = { wid = nil, t = 0.0, on = false }
local function stock_mounted(wid)
    if _G.__re4_ww_block_with_stock == false then return false end
    local now = os.clock()
    if stock_c.wid == wid and (now - stock_c.t) < 0.25 then return stock_c.on end
    stock_c.wid, stock_c.t, stock_c.on = wid, now, false
    -- [WICHTIG] `get_pe` (Z.373) ist HIER UNTEN NICHT SICHTBAR -- Lua nimmt es als globale nil und
    -- der Aufruf wirft ("global 'get_pe' is not callable"), womit die Funktion still abbrach und
    -- der Twirl trotz Stock weiterlief. Deshalb holt sie sich das PlayerEquipment selbst.
    -- Cache + Typ bewusst in GLOBALS statt in neuen Top-Level-Locals: diese Datei ist gross und
    -- soll nicht ans 200-Local-Limit des Chunks stossen.
    local pe, acc, wi, eqp, pid
    pcall(function()
        pe = rawget(_G, "__re4_ww_pe")
        if pe == nil or select(1, pcall(function() return pe:call("get_Context") end)) ~= true then
            pe = nil
            local td = rawget(_G, "__re4_ww_pe_td")
            if td == nil then td = sdk.typeof("chainsaw.PlayerEquipment"); _G.__re4_ww_pe_td = td end
            local cm   = sdk.get_managed_singleton("chainsaw.CharacterManager")
            local ctx  = cm and sc(cm, "getPlayerContextRef") or nil
            local head = ctx and sc(ctx, "get_HeadGameObject") or nil
            if head and td then
                local ok, v = pcall(function() return head:call("getComponent(System.Type)", td) end)
                if ok then pe = v end
            end
            _G.__re4_ww_pe = pe
        end
        acc = pe and sc(pe, "getEquipWeaponAccessor") or nil
        wi  = acc and sc(acc, "get_Item") or nil
        eqp = wi and sc(wi, "isPartsEquipped") or nil
        -- Erst wenn ueberhaupt ein Part dran ist, die ID holen (ohne Part liefert sie -1).
        if eqp == true then
            pid = sc(wi, "getEquippedPartsItemId")
            if type(pid) == "userdata" then
                local okv, n = pcall(function() return pid:get_field("value__") end)
                pid = okv and n or nil
            end
        end
    end)
    -- Gesperrt wird NUR bei einer bekannten Stock-ID. Laser/sonstige Parts (und alles Unlesbare)
    -- gelten als "kein Stock" -> der Twirl laeuft wie ohne Anbauteil.
    stock_c.on = (type(pid) == "number") and (STOCK_ITEM_IDS[pid] == true)
    return stock_c.on
end
_G.__re4_ww_stock_now = function() return stock_c.on end   -- nur fuer die UI-Anzeige

local function weap_transform(hu)
    local weap = sc(hu, "get_EquipWeapon"); if not weap then return nil end
    local go = sc(weap, "get_GameObject"); if not go then return nil end
    return sc(go, "get_Transform")
end
local function body_transform()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = sc(cm, "getPlayerContextRef"); if not ctx then return nil end
    local body = sc(ctx, "get_BodyGameObject"); if not body then return nil end
    return sc(body, "get_Transform")
end

local function compute_local_pivot(T)
    local O = sc(T, "get_Position"); local Q = sc(T, "get_Rotation")
    if not (O and Q) then return nil end
    local jt = nil; pcall(function() jt = T:call("getJointByName", TRIGGER_JOINT) end)
    if not jt then return nil end
    local J = sc(jt, "get_Position"); if not J then return nil end
    local ok, lp = pcall(function()
        local diff = Vector3f.new(J.x-O.x, J.y-O.y, J.z-O.z)
        local Qc = Quaternion.new(Q.w, -Q.x, -Q.y, -Q.z)
        return Qc * diff
    end)
    if ok and lp then return Vector3f.new(lp.x, lp.y, lp.z) end
    return nil
end

-- ---- Offset-Keyframes: interpolierter Waffen-Offset am Salto-Fortschritt (Grad 0..360, wrap-around).
local function offset_at(phase)
    local n = #OKEYS
    if n == 0 then return nil end
    phase = phase % 360
    if n == 1 then return OKEYS[1].x, OKEYS[1].y, OKEYS[1].z end
    local lo, hi = nil, nil
    for i = 1, n do if OKEYS[i].a <= phase then lo = OKEYS[i] else break end end
    for i = n, 1, -1 do if OKEYS[i].a >= phase then hi = OKEYS[i] else break end end
    if lo and hi and lo == hi then return lo.x, lo.y, lo.z end
    local a0, a1, t
    if not lo or not hi then          -- phase liegt vor dem ersten / nach dem letzten -> Wrap 360->0
        lo = OKEYS[n]; hi = OKEYS[1]
        local span = (OKEYS[1].a + 360.0 - OKEYS[n].a)
        local d = (phase >= OKEYS[n].a) and (phase - OKEYS[n].a) or (phase + 360.0 - OKEYS[n].a)
        t = (span > 0.0001) and (d / span) or 0.0
    else
        local span = hi.a - lo.a
        t = (span > 0.0001) and ((phase - lo.a) / span) or 0.0
    end
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return lo.x + (hi.x - lo.x) * t, lo.y + (hi.y - lo.y) * t, lo.z + (hi.z - lo.z) * t
end
-- Keyframe an Fortschritt `phase` anlegen/ersetzen (Toleranz 4 Grad) und sortiert halten.
local function save_keyframe(phase, x, y, z)
    phase = phase % 360
    for _, k in ipairs(OKEYS) do
        if math.abs(k.a - phase) < 4.0 then k.x = x; k.y = y; k.z = z; save_cfg(); return end
    end
    OKEYS[#OKEYS+1] = { a = phase, x = x, y = y, z = z }
    table.sort(OKEYS, function(p, q) return p.a < q.a end)
    save_cfg()
end

-- ---- Twirl-SOUND (One-Shot 288425943, auf dem Waffen-SoundContainer). Der Sound ist KEIN Loop -> er
-- wird waehrend der Drehung im Intervall (~Sound-Laenge, Slider) neu getriggert, damit er durchgaengig
-- klingt. Beim Parken hoert das Re-Triggern auf; der letzte Anspieler klingt natuerlich aus (kein Stop noetig).
local TWIRL_SND = 288425943
local snd_sc_td = sdk.typeof("soundlib.SoundContainer")
local twirl_snd = { next_t = 0 }
local function ww_sound_container(hu)
    local T = weap_transform(hu); if not (T and snd_sc_td) then return nil end
    local go = sc(T, "get_GameObject"); if not go then return nil end
    local scn = nil; pcall(function() scn = go:call("getComponent(System.Type)", snd_sc_td) end)
    return scn
end
local function ww_sound_tick(hu, now)   -- waehrend der Drehung im Intervall neu anspielen
    if _G.__re4_ww_sound == false then return end
    if now < (twirl_snd.next_t or 0) then return end
    local scn = ww_sound_container(hu); if not scn then return end
    pcall(function() scn:call("trigger(System.UInt32)", TWIRL_SND) end)
    twirl_snd.next_t = now + math.max(0.03, tonumber(_G.__re4_ww_snd_interval) or 0.12)
end
local function ww_sound_reset() twirl_snd.next_t = 0 end   -- Re-Triggern stoppen; naechster Spin spielt sofort

-- ---- [TWIRL-SPRUCH 2026-08-04] Leon kommentiert die Show, wenn sie was hergab.
-- Bedingungen (beide muessen erfuellt sein, sonst schweigt er) -- feste Werte, KEINE UI, KEIN Toggle:
-- 1) MINDESTDAUER: >= TWIRL_VOICE_MIN Sekunden AM STUECK gedreht. Gemessen wird nur die aktive
-- Drehphase -- das automatische Ausfahren auf die volle Umdrehung (spin.finishing) zaehlt NICHT mit.
-- 2) SELTENHEIT: nur jeder TWIRL_VOICE_EVERY-te lange Twirl, sonst ist der Gag nach zehn Minuten tot.
-- [2026-08-04] Gespielt wird MITTEN IM SPIN, in dem Moment, in dem die Mindestdauer voll ist --
-- nicht erst beim Parken. Pro Twirl genau einmal (tvoice.fired), auch wenn weitergedreht wird.
--
-- Die Lines liegen auf LEONS BODY-Container (ch0a0z0_body), nicht auf der Waffe -- der Waffen-Container
-- kennt sie nicht. Gleiches Leon-Gate wie bei den Gesten-Spruechen: heisst der Body anders (Ada, Mercs),
-- passiert gar nichts. Kein Komponenten-Cache (haelt Savegame-Loads aus, laeuft eh nur alle paar Twirls).
local TWIRL_VOICE = {
    1517954045,   -- "not bad, right?"
    2778708114,   -- "looking good"
    3878582777,   -- "not bad"
}
local TWIRL_VOICE_MIN   = 1.5   -- s am Stueck aktiv gedreht, bevor ueberhaupt etwas kommen kann
local TWIRL_VOICE_EVERY = 7     -- und dann nur jeder 7. davon
-- [TWIRL-ABSCHLUSS 2026-08-04] Eigene Line, die erst NACH dem Twirl faellt (Waffe wieder geparkt),
-- und noch seltener als die drei oben. Eigener Zaehler -- zaehlt dieselben langen Twirls (>= 1.5s), aber
-- unabhaengig vom 7er-Rhythmus. Beim 77. langen Twirl kaeme also beides; das ist selten genug und passt.
local TWIRL_VOICE_END       = 3778512958   -- "that was not easy"
local TWIRL_VOICE_END_EVERY = 11
local TWIRL_VOICE_BODY  = "ch0a0z0_body"
local tvoice = { t0 = nil, dur = 0.0, count = 0, end_count = 0, last_id = 0, fired = false }

local function twirl_voice_container()
    if not snd_sc_td then return nil end
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = sc(cm, "getPlayerContextRef"); if not ctx then return nil end
    local go = sc(ctx, "get_BodyGameObject"); if not go then return nil end
    local nm = sc(go, "get_Name")
    if not nm or tostring(nm) ~= TWIRL_VOICE_BODY then return nil end      -- nur Leon
    local scn = nil; pcall(function() scn = go:call("getComponent(System.Type)", snd_sc_td) end)
    return scn
end

-- Laeuft WAEHREND der Drehung mit: schlaegt genau in dem Frame zu, in dem die Mindestdauer voll ist.
local function twirl_voice_tick()
    if tvoice.fired or not tvoice.t0 then return end
    if tvoice.dur < TWIRL_VOICE_MIN then return end
    tvoice.fired = true                       -- pro Twirl nur EINE Pruefung, egal wie lange weitergedreht wird
    tvoice.count = tvoice.count + 1
    if (tvoice.count % TWIRL_VOICE_EVERY) ~= 0 then return end
    local scn = twirl_voice_container(); if not scn then return end
    -- Zufaellig, aber nie zweimal derselbe hintereinander: aus n-1 ziehen und den letzten ueberspringen.
    local n, li = #TWIRL_VOICE, 0
    for i, v in ipairs(TWIRL_VOICE) do if v == tvoice.last_id then li = i end end
    local pick
    if n > 1 and li > 0 then
        pick = math.random(n - 1)
        if pick >= li then pick = pick + 1 end
    else
        pick = math.random(n)
    end
    local id = TWIRL_VOICE[pick]
    if pcall(function() scn:call("trigger(System.UInt32)", id) end) then tvoice.last_id = id end
end

-- Laeuft beim PARKEN: der Abschluss-Kommentar. tvoice.fired ist genau dann true, wenn dieser Twirl die
-- Mindestdauer geschafft hat -- kurze Drehungen zaehlen also gar nicht erst mit.
local function twirl_voice_end()
    if not tvoice.fired then return end
    tvoice.end_count = tvoice.end_count + 1
    if (tvoice.end_count % TWIRL_VOICE_END_EVERY) ~= 0 then return end
    local scn = twirl_voice_container(); if not scn then return end
    pcall(function() scn:call("trigger(System.UInt32)", TWIRL_VOICE_END) end)
end

-- ---- Zustand
local spin = { active=false, finishing=false, deg=0.0, finish_target=0.0 }
_G.__re4_wildwest_angle = 0.0
_G.__re4_wildwest_progress = 0.0   -- Salto-Fortschritt 0..360 (dir-unabhaengig) fuer Offset-Keyframe-Lookup
_G.__re4_wildwest_finger_blend = 0.0
local finger_blend = 0.0
local pivot_cache = {}
local active_lp = nil

local prev_y, prev_t = nil, nil
local prev_vsign = 0
-- [SENS_FIX 2026-07-17] Zeitstempel der letzten Richtung, die das sens-Gate PASSIERT hat. Ohne ihn blieb
-- prev_vsign beliebig lange stehen (reset_bob lief nur, wenn schon ein Wippen erkannt war, s. bob_started-
-- Guard weiter unten) -> eine einzelne kraeftige Bewegung hoch und MINUTEN spaeter eine runter galten als
-- Richtungswechsel. Genau deshalb machte "Wippe-Empfindlichkeit" gefuehlt keinen Unterschied.
local prev_vsign_t = 0
local bob_started, last_flip_t = nil, 0

local function right_ctrl_y()
    if not (vrmod and vrmod.is_hmd_active and vrmod:is_hmd_active()) then return nil end
    local cs = vrmod:get_controllers(); if not cs or #cs < 2 then return nil end
    local p = vrmod:get_position(cs[2]); return p and p.y or nil
end
local function reset_bob() prev_vsign = 0; prev_vsign_t = 0; bob_started = nil; last_flip_t = 0 end
-- [RT_GATE 2026-07-21] Ist der Direkt-Twirl gerade freigeschaltet? Reine LESE-Abfrage, greift nirgends
-- in RT ein. Faellt sie weg (Menue/Boot/Bino/KS/Turret/Jetski via __re4_frame_is_gameplay, Messer in der Hand,
-- RT losgelassen), endet das Gate im selben Frame und RT tut wieder ausschliesslich, was er vorher tat.
local rt_gate_prev = false
-- [KEIN TWIRL NACH DEM BALLERN 2026-07-21] Zwei unabhaengige Sicherungen gegen ungewollte Drehs
-- direkt nach einem Feuergefecht:
-- (1) FRISCHER GRIFF: der RT-Druck muss begonnen haben, WAEHREND nicht gezielt wurde. Wer im Kampf den
-- Trigger haelt und dann das Aim loslaesst, behaelt denselben Druck -> der zaehlt nicht mehr als
-- Twirl-Gate. Einmal loslassen und neu druecken macht ihn wieder scharf.
-- (2) NACHLAUF: nach dem letzten Schuss ist das Gate zusaetzlich __re4_ww_rt_lockout Sekunden gesperrt.
-- Schuss-Erkennung ueber __vr_shot_seq (Crosshair-Hook), dieselbe Quelle wie der Burst-Zaehler.
local rt_press_armed = false     -- hat der laufende RT-Druck ohne Aim begonnen?
local rt_prev_raw    = false
local last_shot_t    = -999
local last_shot_seq  = nil
local function ww_rt_gate()
    if _G.__re4_ww_rt_gate == false then return false end
    -- Schuss-Zaehler beobachten (laeuft IMMER, auch wenn das Gate gerade zu ist)
    local seq = tonumber(rawget(_G, "__vr_shot_seq"))
    if seq and seq ~= last_shot_seq then
        if last_shot_seq ~= nil then last_shot_t = os.clock() end
        last_shot_seq = seq
    end
    local raw = rawget(_G, "__vr_raw_r_trigger") == true
    if raw and not rt_prev_raw then
        -- Flanke: nur ein Druck, der OHNE Aim beginnt, darf spaeter twirlen
        rt_press_armed = (rawget(_G, "__vr_aim_input") ~= true) and (rawget(_G, "is_aim") ~= true)
    elseif not raw then
        rt_press_armed = false
    end
    rt_prev_raw = raw
    if not raw or not rt_press_armed then return false end
    local lock = tonumber(_G.__re4_ww_rt_lockout) or 1.0
    if (os.clock() - last_shot_t) < lock then return false end
    if rawget(_G, "__re4_frame_pure_gameplay") ~= true then return false end   -- inkl. Turret/Jetski raus
    -- [MESSER LINKS ERLAUBT 2026-07-21] Gesperrt wird nur, wenn das Messer in der WAFFENHAND
    -- (rechts) steckt -- dann gibt es keine Pistole zum Drehen. Der LINKS-Klon (__re4_knife_left_clone)
    -- laesst die Gun rechts equippt (s. weapons2 LH_CLONE-Block) und darf deshalb weiter twirlen;
    -- RT gehoert bei Messer-links ohnehin nicht dem Messer (binding: knife_owns_rt nur bei hand ~= left).
    if rawget(_G, "__re4_knife_equipped") == true and rawget(_G, "__re4_knife_hand") ~= "left" then return false end
    return true
end
local function reset_all()
    spin.active=false; spin.finishing=false; spin.deg=0.0; _G.__re4_wildwest_angle = 0.0
    spin.by_rt = false   -- [RT_GATE]
    _G.__re4_wildwest_progress = 0.0
    finger_blend = 0.0; _G.__re4_wildwest_finger_blend = 0.0
    prev_y = nil; active_lp = nil; reset_bob()
    ww_sound_reset()  -- Re-Triggern stoppen (Waffenwechsel / deaktiviert / keine Pistole / gezielt)
end

re.on_frame(function()
    -- When disabled, avoid all native weapon/head lookups. reset_all keeps the
    -- externally visible state exactly as it was before this early return.
    if _G.__re4_ww_enabled == false then reset_all(); return end
    local now = os.clock()
    local hu = head_updater()
    local wid = hu and wid_from_hu(hu)
    local is_pistol = (type(wid) == "number") and PISTOLS[wid] == true
    -- [STOCK-SPERRE 2026-08-12] Mit Schulterstuetze kein Twirl (s. stock_mounted weiter oben).
    if not is_pistol or stock_mounted(wid) then reset_all(); return end
    -- [PER-WAFFE KEYFRAMES] OKEYS auf das Array DIESER Waffe zeigen (offset_at + UI teilen sich den Zeiger).
    OKEYS = _G.__re4_ww_okeys_by_wid[wid]; if not OKEYS then OKEYS = {}; _G.__re4_ww_okeys_by_wid[wid] = OKEYS end
    _G.__re4_ww_cur_wid = wid   -- [GESAMT-OFFSET] apply-Pass braucht die ID (laeuft ohne hu-Zugriff)

    -- [PIVOT FRISCH 2026-07-17] Frueher: `if not pivot_cache[wid] and not spin.active` -> der Pivot wurde
    -- GENAU EINMAL pro Waffe berechnet, beim ERSTEN Frame nach dem Ziehen. Da sitzt die Waffe aber oft noch
    -- nicht sauber an der VR-Hand (Engine positioniert sie im Zieh-Uebergang) -> falscher Pivot, und der blieb
    -- bis zum naechsten Reset Scripts gecacht (genau das Symptom: "nach Reset kreist es wieder richtig").
    -- JETZT: jeden RUHE-Frame (nicht waehrend des Drehens) neu berechnen -- aber nur uebernehmen, wenn
    -- compute_local_pivot gelingt (lp ~= nil). So ist der Pivot beim Wippen immer frisch aus der stabilen
    -- Pose; misslingt die Berechnung (Joint im 1. Frame noch nicht bereit), bleibt der letzte gute Wert.
    -- Waehrend spin.active NICHT neu rechnen: die Waffe rotiert dann -> Pivot bliebe sonst dem Dreh hinterher.
    if not spin.active then
        local T = weap_transform(hu)
        if T then local lp = compute_local_pivot(T); if lp then pivot_cache[wid] = lp end end
    end
    local base = pivot_cache[wid]
    active_lp = base and Vector3f.new(base.x + (tonumber(_G.__re4_ww_pivot_x) or 0),
                                      base.y + (tonumber(_G.__re4_ww_pivot_y) or 0),
                                      base.z + (tonumber(_G.__re4_ww_pivot_z) or 0)) or nil

    local dt = (prev_t and (now - prev_t)) or 0.016
    if dt <= 0 then dt = 0.016 elseif dt > 0.1 then dt = 0.1 end
    local aiming = rawget(_G, "is_aim") == true

    -- [RT_GATE] Gehaltener RT = Direkt-Twirl: feinere Empfindlichkeit + KEIN Sustain-Anlauf.
    -- Faellt das Gate weg, waehrend ein Gate-Spin laeuft, faehrt der Spin sauber auf die volle
    -- Umdrehung aus (kein Einfrieren mitten im Salto) und danach gelten wieder die normalen Regeln.
    local gate = ww_rt_gate()
    local ww_sens_now = gate and (tonumber(_G.__re4_ww_rt_sens) or 0.25) or (tonumber(_G.__re4_ww_sens) or 1.2)
    if rt_gate_prev and not gate and spin.active and spin.by_rt and not spin.finishing then
        spin.finishing = true
        spin.finish_target = math.ceil(spin.deg / 360.0) * 360.0
    end
    rt_gate_prev = gate

    -- Wippe
    local y = right_ctrl_y()
    if y and prev_y and prev_t then
        local d = now - prev_t
        if d > 0.0005 then
            local vy = (y - prev_y) / d
            if math.abs(vy) >= ww_sens_now then
                local vsign = vy > 0 and 1 or -1
                -- [SENS_FIX 2026-07-17, "nur beim kraeftigen Wippen"] Die letzte Richtung VERFAELLT nach
                -- BOB_GAP. Vorher blieb prev_vsign ewig stehen (reset_bob unten haengt an bob_started, das ohne
                -- erkanntes Wippen nil ist) -> zwei EINZELNE kraeftige Bewegungen mit beliebiger Pause dazwischen
                -- galten als Richtungswechsel. Ergebnis: die Empfindlichkeit filterte praktisch nichts, egal ob
                -- 0.3 oder 4.0. Jetzt zaehlt ein Wechsel nur, wenn die vorherige Bewegung, die das sens-Gate
                -- passiert hat, WENIGER als BOB_GAP her ist -- also echtes Hin-und-Her statt zweier Einzelrucke.
                if prev_vsign ~= 0 and (now - prev_vsign_t) > BOB_GAP then prev_vsign = 0 end
                if prev_vsign ~= 0 and vsign ~= prev_vsign then
                    if not bob_started or (now - last_flip_t) > BOB_GAP then bob_started = now end
                    last_flip_t = now
                end
                prev_vsign = vsign
                prev_vsign_t = now
            end
        end
    end
    if bob_started and (now - last_flip_t) > BOB_GAP then reset_bob() end
    local bobbing = (bob_started ~= nil) and ((now - last_flip_t) <= BOB_GAP)

    -- Spin
    if spin.active then
        spin.deg = spin.deg + (tonumber(_G.__re4_ww_speed) or 720.0) * dt
        -- [TWIRL-SPRUCH] Dauer NUR der aktiven Drehung mitschreiben; das Ausfahren zaehlt nicht mehr mit.
        -- Der Spruch faellt hier, mitten im Spin, sobald die Mindestdauer voll ist.
        if (not spin.finishing) and tvoice.t0 then
            tvoice.dur = now - tvoice.t0
            twirl_voice_tick()
        end
        if spin.finishing then
            if spin.deg >= spin.finish_target then
                spin.active=false; spin.finishing=false; spin.deg=0.0; _G.__re4_wildwest_angle = 0.0
                tvoice.t0 = nil               -- [TWIRL-SPRUCH] Stoppuhr aus
                twirl_voice_end()             -- [TWIRL-ABSCHLUSS] geparkt -> jeder 11. lange Twirl kommentiert
            end
        else
            if (not bobbing) or aiming then
                spin.finishing = true
                spin.finish_target = math.ceil(spin.deg / 360.0) * 360.0
            end
        end
        if spin.active then
            local dir = (tonumber(_G.__re4_ww_dir) or 1.0) >= 0 and 1.0 or -1.0
            _G.__re4_wildwest_angle = math.rad(spin.deg) * dir
            _G.__re4_wildwest_progress = spin.deg % 360.0
        end
    else
        -- [RT_GATE] Bei gehaltenem RT faellt der Sustain-Anlauf weg -> erster erkannter Richtungswechsel dreht sofort.
        local sustain_now = gate and 0.0 or (tonumber(_G.__re4_ww_sustain) or 0.6)
        -- [RT_GATE 2026-07-21] Toggle an -> das freie Twirlen (nur Wippen, ohne RT) ist GESPERRT:
        -- der Twirl startet dann ausschliesslich bei gehaltenem RT. Toggle aus = exakt das alte Verhalten.
        local start_allowed = (_G.__re4_ww_rt_gate == false) or gate
        if start_allowed and (not aiming) and bob_started and (now - bob_started) >= sustain_now then
            spin.active=true; spin.finishing=false; spin.deg=0.0
            spin.by_rt = gate   -- [RT_GATE] merkt, ob DIESER Spin aus dem Gate kam (nur der endet beim Loslassen)
            tvoice.t0, tvoice.dur, tvoice.fired = now, 0.0, false   -- [TWIRL-SPRUCH] Stoppuhr fuer die aktive Drehphase
            -- [PIVOT-ERZWINGEN 2026-07-18] Pivot friert waehrend spin.active ein (s. 1852). Direkt nach einem
            -- Waffenwechsel sitzt die neue Waffe im 1. Ruhe-Frame noch nicht sauber in der VR-Hand -> ein nicht-
            -- gesetzter Pivot wuerde den GANZEN ersten Salto verfaelschen (Waffe dreht um falschen Punkt = "Offset
            -- passt nicht"), erst der zweite Dreh war korrekt. Jetzt zum Spin-Start (nach ~sustain=0.6s Wippen sitzt
            -- die Waffe garantiert) den Pivot FRISCH erzwingen, bevor er einfriert.
            local Tsp = weap_transform(hu)
            if Tsp then local lp = compute_local_pivot(Tsp); if lp then pivot_cache[wid] = lp end end
        end
    end

    -- Twirl-Sound: waehrend der Drehung (inkl. Ausfahren) im Intervall neu anspielen, beim Parken aufhoeren.
    -- Preview (nur Offset-Tuning) macht KEINEN Sound.
    if spin.active and (_G.__re4_ww_sound ~= false) then ww_sound_tick(hu, now) else ww_sound_reset() end

    -- Finger-Blend folgt spin.active (lerp). Vorschau haelt die Pose zum Tunen ohne Drehen.
    local tgt = (spin.active or rawget(_G, "__re4_ww_pose_preview") == true) and 1.0 or 0.0
    finger_blend = finger_blend + (tgt - finger_blend) * math.min(1.0, dt * BLEND_SPD)
    if finger_blend < 0.0005 then finger_blend = 0.0 end
    _G.__re4_wildwest_finger_blend = finger_blend

    -- [VORSCHAU] Gun auf festen Winkel einfrieren -> Pivot + Waffen-Offset live tunen ohne zu wippen.
    if (not spin.active) and rawget(_G, "__re4_ww_pose_preview") == true then
        local dir = (tonumber(_G.__re4_ww_dir) or 1.0) >= 0 and 1.0 or -1.0
        local pa = tonumber(_G.__re4_ww_prev_angle) or 90.0
        _G.__re4_wildwest_angle = math.rad(pa) * dir
        _G.__re4_wildwest_progress = pa % 360.0
    end

    prev_y = y; prev_t = now
end)

-- ---- Twirl-Anwendung (motion.lua attach_weapon): Pos+Rot um joint_03.
_G.__re4_wildwest_apply = function(wpos, wrot)
    if not wpos or not wrot then return wpos, wrot end
    local a = tonumber(_G.__re4_wildwest_angle) or 0.0
    -- NUR eingreifen, wenn tatsaechlich gedreht wird. __re4_wildwest_angle ist ausschliesslich bei
    -- Pistolen waehrend der Dreh-/Ausfahr-Phase (bzw. Vorschau) != 0 -> reset_all nullt ihn fuer alles
    -- andere. Damit gelten Pivot UND Waffen-Offset ausschliesslich fuer Pistolen und nur beim Twirl.
    if a == 0.0 then return wpos, wrot end
    local new_wrot, new_wpos = wrot, wpos
    -- Drehung um den Pivot (joint_03 + Feinjustage).
    local h = a * 0.5
    local R = Quaternion.new(math.cos(h), math.sin(h), 0, 0)
    local ok, nr = pcall(function() return (wrot * R):normalized() end)
    if ok and nr then
        new_wrot = nr
        local lp = active_lp
        if lp then
            local okp, res = pcall(function() return (wpos + (wrot * lp)) - (new_wrot * lp) end)
            if okp and res then new_wpos = res end
        end
    end
    -- Waffen-Positions-Offset (Ruhe-Waffen-Frame) -> Gun waehrend der Drehung an die Hand schieben.
    -- Quelle: im EDIT-Vorschau-Modus die Live-Slider (damit das Tunen sichtbar ist), sonst der per-Phase
    -- interpolierte Keyframe-Offset (offset_at am Salto-Fortschritt). Ohne Keyframes -> Live-Slider (alt).
    local ox, oy, oz
    local editing = (rawget(_G, "__re4_ww_pose_preview") == true) and (not spin.active)
                    and (rawget(_G, "__re4_ww_prev_interp") ~= true)
    if editing or #OKEYS == 0 then
        ox = tonumber(_G.__re4_ww_off_x) or 0.0
        oy = tonumber(_G.__re4_ww_off_y) or 0.0
        oz = tonumber(_G.__re4_ww_off_z) or 0.0
    else
        ox, oy, oz = offset_at(tonumber(_G.__re4_wildwest_progress) or 0.0)
        ox = ox or 0.0; oy = oy or 0.0; oz = oz or 0.0
    end
    if ox ~= 0.0 or oy ~= 0.0 or oz ~= 0.0 then
        local oko, off = pcall(function() return wrot * Vector3f.new(ox, oy, oz) end)
        if oko and off then new_wpos = new_wpos + off end
    end
    return new_wpos, new_wrot
end

-- ---- Finger-Pose (motion.lua Finger-Pass): additive lokale Rotation pro Finger, geblendet.
_G.__re4_wildwest_fingers = function()
    local blend = tonumber(_G.__re4_wildwest_finger_blend) or 0.0
    if blend <= 0.001 then return end
    local tf = body_transform(); if not tf then return end
    for _, bn in ipairs(ALL_JOINTS) do
        local e = FING[bn]
        local add = e and euler_add((e.x or 0)*blend, (e.y or 0)*blend, (e.z or 0)*blend)
        if add then
            local ok, j = pcall(function() return tf:call("getJointByName", bn) end)
            if ok and j then
                local okc, cur = pcall(function() return j:call("get_LocalRotation") end)
                if okc and cur then pcall(function() j:call("set_LocalRotation", (cur * add):normalized()) end) end
            end
        end
    end
end

-- ---- UI
local function fslider(label, tbl, key, lo, hi)
    local ch, v = imgui.slider_float(label, tbl[key], lo, hi)
    if ch then tbl[key] = v; save_cfg() end
end
local function gslider(label, gkey, lo, hi)
    local ch, v = imgui.slider_float(label, _G[gkey], lo, hi)
    if ch then _G[gkey] = v; save_cfg() end
end
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4 VR - Wild West (Pistol Twirl)" raus (96 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

end)()

-- [WEAPONS2 UI] Parent-Tree "RE4 VR Weapons 2" schliessen (nur wenn er geoeffnet war).
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree (Closer) raus (1 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.


-- =====================================================================
-- [KANONE 2026-07-15] konsolidiert aus re4_vr_cannon.lua (Datei geloescht).
-- KANONE (大砲, GmCannonV2 auf gm84_572).
-- 1) Kanonen-Jack erkennen (Body-Parent-Kette enthaelt gm84_572) -> _G.__re4_at_cannon = true.
-- binding.lua gibt dann den rechten Stick-Y frei; sonst gelockt. (Pitch reagiert in VR eh nicht.)
-- 2) [YAW ERWEITERN] GmCannonV2._YawRotateRangeRad (via.Range {s@0xE0, r@0xE4}, RAD) begrenzt den Schwenk.
-- Original ~ s=-2.361(-135), r=2.621(+150). Wir schreiben jeden Frame einen weiteren Bereich rein
-- (direkter Notiz-Write; haelt gegen Engine-Resets). Tunebar per Globals:
-- _G.__re4_cannon_yaw_min / _yaw_max (Radiant; Default -3.05 / 3.05 = ~±175 Grad)
-- Aus: _G.__re4_cannon_yaw_widen = false. Beim Neuladen ist wieder original.
-- Als IIFE: eigenes Local-Budget -> kostet weapons2 (129 Top-Level-Locals) keinen Slot. Eigenes sc,
-- weil die beiden sc weiter oben in anderen Scopes liegen.
-- =====================================================================
;(function()

local function sc(o, m, ...) if not o then return nil end local ok, r = pcall(function(...) return o:call(m, ...) end, ...); if ok then return r end end

local gmcannon_td = sdk.typeof("chainsaw.GmCannonV2")
local c_go, c_cc = nil, nil

re.on_frame(function()
    -- Kanone in der Body-Parent-Kette suchen
    local cm  = sdk.get_managed_singleton("chainsaw.CharacterManager")
    local ctx = cm and sc(cm, "getPlayerContextRef")
    local body = ctx and sc(ctx, "get_BodyGameObject")
    local tf  = body and sc(body, "get_Transform")
    local go, x = nil, tf
    for _ = 1, 8 do
        if not x then break end
        local g = sc(x, "get_GameObject"); local nm = g and sc(g, "get_Name")
        if type(nm) == "string" and nm:find("gm84_572") then go = g; break end
        x = sc(x, "get_Parent")
    end
    _G.__re4_at_cannon = (go ~= nil)
    if not go then c_go, c_cc = nil, nil; return end

    if go ~= c_go then
        c_go = go
        c_cc = gmcannon_td and sc(go, "getComponent(System.Type)", gmcannon_td)
    end

    -- [KS_GLOBAL 2026-07-15] Killswitch -> NICHTS in die Engine schreiben. Bewusst ERST HIER und nicht am
    -- Anfang des on_frame: die Kanonen-Suche + __re4_at_cannon oben sind STATE-PFLEGE, die andere Scripte
    -- lesen -- die muss weiterlaufen, sonst haengt das Flag im KS auf einem alten Wert (Regel: nur die
    -- AUSGABE gaten, nicht die Zustandsermittlung).
    if rawget(_G, "__re4_ks_active") == true then return end
    -- [YAW ERWEITERN] via.Range in GmCannonV2 @ 0xE0 (s) / 0xE4 (r) direkt ueberschreiben.
    -- [MK.II AUSNEHMEN 2026-07-11] Die zweite Kanone (gm84_572_00_1_大砲改二) NICHT anfassen -> ihre native
    -- Sektor-Restriktion bleibt unberuehrt (sonst kein Links-Schwenk / Aussteig-Problem). Nur die erste Kanone.
    local cnm = c_cc and sc(go, "get_Name")
    if c_cc and rawget(_G, "__re4_cannon_yaw_widen") ~= false
       and not (type(cnm) == "string" and cnm:find("gm84_572_00_1", 1, true)) then
        local mn = tonumber(rawget(_G, "__re4_cannon_yaw_min")) or -3.05
        local mx = tonumber(rawget(_G, "__re4_cannon_yaw_max")) or  3.05
        pcall(function() c_cc:write_float(0xE0, mn); c_cc:write_float(0xE4, mx) end)
    end
end)

end)()

-- =====================================================================
-- [UNLIMITED 2026-07-15] konsolidiert aus re4_vr_unlimited.lua (Datei geloescht).
-- Manche Waffen haben ein Spezial-Upgrade (Chicago Sweeper wp4201, Handcannon wp4502) = UNLIMITED AMMO.
-- Sie muessen NIE nachladen. Unser Reload-System will beim B-Druck trotzdem ein Mag droppen -> haengt.
-- Funktioniert auch mit Infinite-Ammo-SCRIPTS (dann melden auch andere Waffen unlimited).
--
-- ERKENNUNG (waffen-agnostisch, per Live-Log verifiziert 2026-07-02):
-- WeaponItem.get_IsBulletFull == true <=> unlimited.
-- Beweis: Chicago meldete IsBulletFull=true OBWOHL AmmoCount=0 (kein "Mag voll"-Check, sondern das
-- Engine-Infinite-Flag, das auch die HUD-∞-Anzeige treibt). Selbst ein voll geladener Punisher (24/24)
-- meldet false -> nur Unlimited=true. enableCostAmmo/LimitBreak taugten NICHT (LB=Spiel-Upgrade only).
--
-- WIRKUNG bei Unlimited (frisch pro Frame, self-healing bei Waffenwechsel):
-- 1) Mag-Holster GESPERRT: __re4_reload_set_mag_in_hand wird aussenrum gewrappt -> Grab liefert false.
-- 2) Holster-Lock-Puls: __re4_reload_grab_empty = true.
-- 3) Right-B (Mag-Drop) STILLGELEGT: __re4_block_b_drop = true -> die force_eject-Funktionen in
-- reload/2/3 bailen am Anfang.
--
-- LADEREIHENFOLGE (der Grund, warum das hier funktioniert): Das Original lag in re4_vr_unlimited.lua und
-- verliess sich darauf, NACH reload/2/3 zu laden ("u" > "r") -- damit sitzt der Wrap AUSSEN und das
-- on_frame laeuft ALS LETZTES (gewinnt so ueber die grab_empty-Zuweisungen der reload-Files).
-- weapons2 laedt alphabetisch noch spaeter ("w" > "u" > "r") -> beide Bedingungen bleiben erfuellt,
-- der Wrap sitzt sogar weiter aussen als vorher. NICHT in ein Script mit "a".."t" verschieben.
--
-- KEIN KILLSWITCH-GATE -- ABSICHT, nicht vergessen: Dieses on_frame IST nur State-Pflege (es schreibt
-- nichts in die Engine, nur Lua-Globals). Ein `if rawget(_G,"__re4_ks_active") then return end` wuerde
-- die Flags EINFRIEREN, statt sie zu pflegen -> Reload haengt nach dem Killswitch. Das unterscheidet
-- diesen Block von der Kanone oben (die schreibt Notiz und ist deshalb gegatet).
-- Kein sdk.hook -> Reset Scripts reicht. Diesen Block loeschen = alles wieder nativ.
-- Als IIFE: eigenes Local-Budget -> kostet weapons2 (129 Top-Level-Locals) keinen Slot.
-- =====================================================================
;(function()

-- [SAFE_GIBT_IMMER_EINEN_WERT 2026-07-31] Ohne das explizite `return nil` liefert diese
-- Funktion im Fehlerfall GAR KEINEN Wert (nicht nil, NICHTS). In tostring(safe(...)) kommt dann
-- kein Argument an -> "bad argument #1 to 'tostring' (value expected)" -> der ganze umgebende
-- Aufruf stirbt. Genau daran ist am 31.07. der Bogen-Reload gestorben. Im Erfolgsfall unveraendert.
local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end
local function sc(o, m, ...) if not o then return nil end local a = { ... }
    return safe(function() return o:call(m, table.unpack(a)) end) end

-- Live equippte WeaponItem (gleicher Pfad wie reload.lua).
local function get_equipped_wi()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = sc(cm, "getPlayerContextRef"); if not ctx then return nil end
    local go = sc(ctx, "get_HeadGameObject"); if not go then return nil end
    local pe = safe(function() return go:call("getComponent(System.Type)", sdk.typeof("chainsaw.PlayerEquipment")) end)
    if not pe then return nil end
    return sc(pe, "getEquipWeaponItem")
end

-- Leichter Per-Zeit-Cache (Erkennung wird pro Frame mehrfach abgefragt).
local _cache = { t = -1, val = false }
local function is_unlimited()
    local now = os.clock()
    if (now - _cache.t) < 0.10 then return _cache.val end
    _cache.t = now
    local wi = get_equipped_wi()
    _cache.val = (wi and safe(function() return wi:call("get_IsBulletFull") end) == true) or false
    return _cache.val
end
_G.__re4_is_unlimited = is_unlimited

-- (1) Mag-Holster zentral sperren: unser Wrap sitzt aussen (s. LADEREIHENFOLGE oben).
-- Bei Unlimited liefert der Grab false -> kein Mag in die Hand.
local _orig_smih = _G.__re4_reload_set_mag_in_hand
_G.__re4_reload_set_mag_in_hand = function(active)
    if is_unlimited() then return false end
    if _orig_smih then return _orig_smih(active) end
    return false
end

-- (2)+(3) Pro Frame die Lock-Flags setzen. Laeuft als letzter on_frame -> gewinnt ueber die
-- grab_empty-Zuweisungen der reload-Files. KEIN Gate, s.o.
re.on_frame(function()
    local u = is_unlimited()
    _G.__re4_block_b_drop = u
    if u then _G.__re4_reload_grab_empty = true end
end)

end)()

-- =====================================================================================
-- [PARRY_KEEP_GUN 2026-07-31] Nach einem Parry mit dem KLON-MESSER LINKS soll die vorher
-- rechts gehaltene Schusswaffe zurueck in die Hand.
-- LOG-BEFUND (re4_parry_diag.log 620.34-622.39), der die ersten beiden Versuche erklaert:
-- equipWeapon arg1=1 arg2=5001 -> EquipType 1 = MESSER-Slot
-- equipWeapon arg1=1 arg2=0xFFFFFFFF -> Messer-Slot geleert
-- equipWeapon arg1=0 arg2=6001 -> EquipType 0 = Schusswaffe (nur wenn man selbst zieht)
-- Die Schusswaffe wird also NIE weggenommen -- sie ist nach dem Parry blos nicht mehr AKTIV in der
-- Hand (get_EquipWeaponID = -1). Deshalb ist der richtige Aufruf `requestEquipGun` und NICHT
-- equipWeapon (das haette die Waffe in den falschen Slot gelegt).
-- Haengt bewusst NICHT an der Klon-Restore-Kette (die wurde in diesem Ablauf nie erreicht), sondern
-- an einer eigenen, einfachen Bedingung -- und feuert genau EINMAL.
-- STRENGE GATES, damit nichts anderes betroffen ist:
-- * __re4_parry_keep_gun_wid wird AUSSCHLIESSLICH im Zweig __re4_knife_left_clone gesetzt
-- -> Parry mit dem ECHTEN Messer rechts laeuft hier nie durch (dort kommt weiter nichts zurueck).
-- * nur wenn aktuell GAR KEINE Waffe aktiv ist (wid <= 0) -> hat man inzwischen selbst
-- etwas gezogen, fassen wir es nicht an.
-- * nur wenn das Messer NICHT equippt ist -> wir stoeren keine laufende Messer-Aktion.
-- * Merker wird in jedem Fall geloescht -> kein Dauer-Request (der killt laut Projekt-Erfahrung
-- das Holster).
-- =====================================================================================
-- KEINE lokalen Helfer benutzen (get_ctx/sc/safe/get_pe): die liegen in einem gekapselten Scope und
-- sind hier NICHT sichtbar -- belegt durch den Script-Error "global 'get_ctx' is not callable" an
-- genau dieser Stelle. Alles unten steht deshalb auf eigenen Beinen: nur sdk.* und pcall.
re.on_frame(function()
    local ok = pcall(function()
        -- Kontext -> HeadUpdater -> aktuelle Waffen-ID (derselbe Weg wie in re4_zzz_parry_diag.lua,
        -- der nachweislich laeuft).
        local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return end
        local ctxr = cm:call("getPlayerContextRef()");                     if not ctxr then return end
        local hu   = ctxr:call("get_HeadUpdater");                         if not hu then return end
        local wv   = hu:call("get_EquipWeaponID")
        local wn   = -1
        if type(wv) == "userdata" then
            local v = wv:get_field("value__"); if type(v) == "number" then wn = v end
        elseif type(wv) == "number" then wn = wv end

        -- Fortlaufend die zuletzt gehaltene NICHT-Messer-Waffe mitschreiben -- genau die soll nach
        -- einem Links-Klon-Parry zurueck. Messer-IDs inline (KNIFE_IDS ist hier ebenfalls nicht
        -- sichtbar); -1 = "gar nichts" wird bewusst NICHT gemerkt.
        local kn = (wn == 5000 or wn == 5001 or wn == 5002 or wn == 5003
                 or wn == 5006 or wn == 6107 or wn == 6108 or wn == 6305)
        if wn > 0 and not kn then _G.__re4_parry_last_gun_wid = wn end

        local ku = tonumber(rawget(_G, "__re4_parry_keep_gun_until")); if not ku then return end
        local now = os.clock()
        -- Sobald die Lage stabil ist, sofort zurueckholen -- nicht bis zum Timeout warten. Stabil =
        -- fruehester Zeitpunkt erreicht UND Messer nicht mehr equippt UND nichts in der Hand.
        -- Das Timeout bleibt als Notbremse, falls dieser Zustand nie eintritt.
        local kf     = tonumber(rawget(_G, "__re4_parry_keep_gun_from")) or 0
        local stable = (now >= kf) and (rawget(_G, "__re4_knife_equipped") ~= true) and (wn <= 0)
        if not stable and now < ku then return end
        _G.__re4_parry_keep_gun_until = nil           -- ab hier genau EIN Versuch
        _G.__re4_parry_keep_gun_from  = nil
        if rawget(_G, "__re4_knife_equipped") == true then return end
        if wn > 0 then return end                     -- es haelt schon wieder etwas -> Finger weg
        if not tonumber(rawget(_G, "__re4_parry_last_gun_wid")) then return end
        local eq = hu:call("get_Equipment"); if not eq then return end
        eq:call("requestEquipGun")
    end)
    if not ok then _G.__re4_parry_keep_gun_until = nil end   -- nie in einer Fehlerschleife haengen
end)
