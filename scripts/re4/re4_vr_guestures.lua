-- Builtin implementation: src/mods/vr/games/re4/RE4VRGestures.cpp
return

-- =====================================================================
-- re4_vr_guestures.lua [2026-07-21]
-- Hand-Gesten der RECHTEN Hand, Port des RE9-Musters (re9_vr_sounds.lua play_direction).
--
-- Ausloeser (kommt aus re4_vr_binding.lua, NUR reines Gameplay + BARE HANDS):
-- L.Trigger halten + R.A -> "point" (Zeigefinger raus / Pistolenfinger)
-- L.Trigger halten + R.B -> "fuck_you" (Stinkefinger)
-- L.Trigger bleibt daneben ganz normal DPAD-Shift; mit Waffe/Messer in der Hand aendert
-- sich GAR NICHTS an A/B. Gilt fuer Leon UND Ada (binding exportiert branch-unabhaengig).
--
-- Ablauf wie in RE9: 0.18s einlerpen, 2.5s halten, 0.30s auslerpen. Bricht sofort ab,
-- sobald die Haende nicht mehr leer sind oder wir das Gameplay verlassen (Menue/KS/...).
--
-- Posen: re4_vr/re4_vr_guestures.json (Quaternion je Finger-Joint, RE4-Namen R_IndexF1...).
-- Angewandt wird ueber den fertigen Joint-Writer aus reload.lua
-- (_G.__re4_reload_apply_pose_bones) -> KEIN eigener Joint-Code, kein Konflikt mit POSES.
-- Sound kommt spaeter (RE9 spielt dort zusaetzlich einen Voice-Trigger).
-- =====================================================================
if reframework:get_game_name() ~= "re4" then return end

local JSON_PATH  = "re4_vr/re4_vr_guestures.json"
local LERP_IN    = 0.18
local HOLD       = 2.50
local LERP_OUT   = 0.30

-- [SAFE_GIBT_IMMER_EINEN_WERT 2026-07-31] Ohne das explizite `return nil` liefert diese
-- Funktion im Fehlerfall GAR KEINEN Wert (nicht nil, NICHTS). In tostring(safe(...)) kommt dann
-- kein Argument an -> "bad argument #1 to 'tostring' (value expected)" -> der ganze umgebende
-- Aufruf stirbt. Genau daran ist am 31.07. der Bogen-Reload gestorben. Im Erfolgsfall unveraendert.
local function safe(fn) local ok, r = pcall(fn); if ok then return r end return nil end

-- ---- Posen werden intern in GRAD gehalten (Kruemmung um die lokale Z-Achse, so wie die
-- RE4-Captures aufgebaut sind) -> die UI-Slider koennen direkt darauf arbeiten. Beim Anwenden
-- und beim Speichern wird daraus wieder ein Quaternion [w,0,0,z] gebaut.
local FINGERS = {
    { key = "R_Index",  label = "Zeigefinger" },
    { key = "R_Middle", label = "Mittelfinger" },
    { key = "R_Ring",   label = "Ringfinger" },
    { key = "R_Pinky",  label = "Kleiner Finger" },
}
local POSE_ORDER = { "point", "fuck_you" }
local POSE_LABEL = { point = "Zeigefinger-Pose (LT + R.A)", fuck_you = "Stinkefinger (LT + R.B)" }

local function joint_names()
    local t = { "R_Palm" }
    for _, f in ipairs(FINGERS) do for i = 1, 3 do t[#t+1] = f.key .. "F" .. i end end
    for i = 1, 3 do t[#t+1] = "R_Thumb" .. i end
    return t
end
local JOINTS = joint_names()

-- [DAUMEN-ACHSEN 2026-07-21, "Fingerspitze dreht weg statt einzukruemmen"]
-- Die vier Finger beugen um ihre lokale Z-Achse, der DAUMEN nicht: in den echten RE4-Captures
-- (knifepose/flamehand/singleaction) liegt die Beugung bei R_Thumb1 auf X und bei R_Thumb2/R_Thumb3
-- auf Y. Deshalb je Joint eine Achse statt pauschal Z. Positiv = zur Handflaeche einrollen.
local AXIS = { R_Thumb1 = 2, R_Thumb2 = 3, R_Thumb3 = 3 }   -- Index im Quaternion {w,x,y,z}; Default 4 = Z
local function axis_of(jn) return AXIS[jn] or 4 end

local function quat_to_deg(v, jn)
    if type(v) ~= "table" or not v[1] then return 0.0 end
    -- atan2 gibt es in Lua 5.4 nicht mehr, in 5.1 dafuer kein zweiargumentiges atan -> beides abdecken.
    local a2 = math.atan2 or math.atan
    return math.deg(2.0 * a2(v[axis_of(jn)] or 0.0, v[1]))
end
local function deg_to_quat(d, jn)
    local r = math.rad(d) * 0.5
    local q = { math.cos(r), 0.0, 0.0, 0.0 }
    q[axis_of(jn)] = math.sin(r)
    return q
end

-- [FINGER-ROTATION 2026-07-21] Zusaetzlich zur Beugung je Glied EIN Wert pro FINGER, der den
-- ganzen Finger dreht (Twist um die Finger-Laengsachse X). Wirkt auf das Grundglied -> Mittelglied und
-- Spitze drehen automatisch mit, weil sie Kinder davon sind. Wird als eigener Block "rot" gespeichert,
-- damit die Beugung beim Zurueckladen sauber getrennt bleibt.
local function qmul(a, b)
    return {
        a[1]*b[1] - a[2]*b[2] - a[3]*b[3] - a[4]*b[4],
        a[1]*b[2] + a[2]*b[1] + a[3]*b[4] - a[4]*b[3],
        a[1]*b[3] - a[2]*b[4] + a[3]*b[1] + a[4]*b[2],
        a[1]*b[4] + a[2]*b[3] - a[3]*b[2] + a[4]*b[1],
    }
end
local function twist_quat(d)
    local r = math.rad(d) * 0.5
    return { math.cos(r), math.sin(r), 0.0, 0.0 }   -- um X = Laengsachse des Fingers
end

local DEG   = nil   -- DEG[posename][joint] = Grad (Beugung je Glied)
local ROT   = nil   -- ROT[posename][fingerkey] = Grad (Drehung des ganzen Fingers)
local POSES = nil   -- POSES[posename] = bones-Dict (Quaternionen, aus DEG/ROT gebaut)

local function rebuild(name)
    local b = {}
    for _, jn in ipairs(JOINTS) do b[jn] = deg_to_quat(DEG[name][jn] or 0.0, jn) end
    for _, f in ipairs(FINGERS) do
        local r = tonumber(ROT[name][f.key]) or 0.0
        if r ~= 0.0 then
            local base = f.key .. "F1"
            b[base] = qmul(b[base], twist_quat(r))
        end
    end
    POSES[name] = b
end

local function load_poses()
    local d = safe(function() return json.load_file(JSON_PATH) end)
    local p = (type(d) == "table") and d.poses or nil
    DEG, ROT, POSES = {}, {}, {}
    for _, name in ipairs(POSE_ORDER) do
        DEG[name], ROT[name] = {}, {}
        local entry = (type(p) == "table") and type(p[name]) == "table" and p[name] or nil
        local src   = entry and entry.bones or nil
        for _, jn in ipairs(JOINTS) do
            DEG[name][jn] = src and quat_to_deg(src[jn], jn) or 0.0
        end
        -- Beugung des Grundglieds ohne die Finger-Drehung lesen (die steckt separat in "rot").
        for _, f in ipairs(FINGERS) do
            ROT[name][f.key] = (entry and type(entry.rot) == "table" and tonumber(entry.rot[f.key])) or 0.0
        end
        rebuild(name)
    end
end

local function save_poses()
    if not DEG then return end
    local out = { version = 1, poses = {} }
    for _, name in ipairs(POSE_ORDER) do
        local b = {}
        -- bones = REINE Beugung (ohne Finger-Drehung), rot = Drehung je Finger -> beim Laden sauber trennbar.
        for _, jn in ipairs(JOINTS) do b[jn] = deg_to_quat(DEG[name][jn] or 0.0, jn) end
        local r = {}
        for _, f in ipairs(FINGERS) do r[f.key] = ROT[name][f.key] or 0.0 end
        out.poses[name] = { hand = "right", bones = b, rot = r }
    end
    pcall(function() json.dump_file(JSON_PATH, out) end)
end

-- [RECHTE HAND FREI 2026-07-21] Die Geste laeuft auf der RECHTEN Hand -- also zaehlt auch nur die.
-- Frei ist sie, wenn gar keine Waffe equippt ist ODER das Messer in der LINKEN Hand steckt (equippt oder
-- als Klon). Messer rechts oder eine Schusswaffe in der Hand -> keine Geste. Gleiche Regel wie im binding.
local function hands_free()
    if rawget(_G, "__re4_knife_hand") == "right" then return false end
    if rawget(_G, "__vr_bare_hands") == true then return true end
    if rawget(_G, "__re4_knife_equipped") == true and rawget(_G, "__re4_knife_hand") == "left" then return true end
    return false
end

-- =====================================================================
-- [STAGGER 2026-07-23] Stinkefinger GEHALTEN -> alle Gegner ringsum staggern.
-- Kurzer Druck = nur die Geste (unveraendert), R.B laenger als STAGGER_HOLD gehalten = Geste + Stagger.
--
-- MECHANIK (live erarbeitet, Herkunft: Flash-Granate wp5402): `HitController.requestAttack` schlaegt den
-- `_KeyNameHash` der AttackUserData in `HC._UserData._AttackHitUserData._AttackDataList` nach. Der
-- Spieler-HitController hat diese Tabelle gar nicht -> Suche laeuft ins Leere -> keine Reaktion. Deshalb
-- bauen wir eine eigene Tabelle mit EINEM Eintrag: die am Bomben-Collider gemessenen Flash-Werte,
-- `_AttackType = 15` (= chainsaw.character.AttackType.Flash), Damage/Wince/Break/Stopping alle 0 --
-- also reine Blend-Reaktion ohne Schaden.
--
-- ZWEI FALLEN, beide teuer bezahlt:
-- 1) Selbst erzeugte Managed Objects sind nicht verankert -- ohne `add_ref` raeumt der GC sie nach dem
-- ersten Einsatz ab, der zweite greift in freigegebenen Speicher -> Access Violation, die kein pcall
-- faengt. Deshalb wird jedes erzeugte Objekt genau einmal gebaut und sofort festgenagelt.
-- 2) Die Tabelle wird NUR fuer die Dauer des Bursts eingehaengt und danach exakt der Vorzustand
-- zurueckgeschrieben. Haengt dort schon eine fremde Tabelle, fassen wir gar nichts an.
-- =====================================================================
-- [GEMESSEN 2026-07-23] Probe re4_zzz_udshare: der Spieler-HitController hat ein EIGENES
-- `_UserData` (0x7DA72B20) -- alle acht Gegner teilen sich dagegen ein gemeinsames (0x772A3BB0).
-- Unser Anhaengen trifft also nichts Fremdes, und das Feld stand danach wieder auf nil.
-- Uebrig bleibt als Ursache der frueher pauschale `set_AttackEnable(false)`: damit lag der
-- Spieler-HitController dauerhaft entschaerft da, was beide Symptome erklaert (er zaehlte weder
-- als Angreifer noch als Ziel -> Gegner trafen nicht mehr, RT blieb wirkungslos). Der Wert wird
-- jetzt exakt so zurueckgeschrieben, wie er vorher war. Notschalter bleibt stehen.
local STAGGER_ENABLED = true
local STAGGER_HOLD  = 0.50   -- s, ab wann aus "gehalten" ein Stagger wird
local STAGGER_REACH = 30.0   -- m, Wirkradius (rundum, kein Zielen)
local STAGGER_MAX   = 16     -- Sicherheitsdeckel pro Ausloesung
local FLASH_KEYHASH = 2056866634
local FLASH_ATTACK_DATA = {
    _KeyNameHash = FLASH_KEYHASH, _Damage = 0, _IsPartnerDamage = true,
    _AttackType = 15,            -- chainsaw.character.AttackType.Flash
    _AttackPower = 1, _DeadType = 1, _Priority = 0, _SortType = 1, _Option = 0,
    _IntervalTime = 0.0, _Enchant = 0, _IsThroughRestriction = false, _ThroughNum = 1,
    _DirectionType = 2, _IsShieldingDecision = true, _EnableBackFacingHits = false,
    _ShieldingDecisioningType = 3, _JointNameHash = 2180083513, _Mute = true,   -- [SOUND-CRASH-FIX 2026-07-24] war false -> jeder Flash-Hit an allen Gegnern postete ein Wwise-Event; einer traf async einen freed Voice -> c0000005 im Audio-Thread (AK::Monitor::PostCode). Stummschalten = kein Post = kein Crash. Kostet nur den Stagger-Sound.
    _SoundTriggerId = 4294967295, _MuteEffect = false, _CheckEffectCollision = false,
    _IsEmitEffect = false, _AxisType = 0, _EffectCheckInterval = 0.0, _CheckRigidBody = false,
    _DefaultThroughNum = 1,
}

local function sc(o, m) if not o then return nil end local ok, r = pcall(function() return o:call(m) end); if ok then return r end end
local function sc1(o, m, a) if not o then return nil end local ok, r = pcall(function() return o:call(m, a) end); if ok then return r end end
local function pin(o) if o then pcall(function() o:add_ref() end) end return o end

local made = {}   -- alles genau einmal gebaut und verankert (siehe Falle 1)

local function flash_ud()
    if made.ud then return made.ud end
    local u = safe(function() return sdk.create_instance("chainsaw.collision.AttackUserData", true) end)
    if not u then return nil end
    pcall(function() u:set_field("_AttackHitDataID", 2) end)
    pcall(function() u:set_field("_KeyNameHash", FLASH_KEYHASH) end)
    pcall(function() u:set_field("<AttackID>k__BackingField", 26) end)
    made.ud = pin(u)
    return made.ud
end

local function flash_table()
    if made.tbl then return made.tbl end
    local ahu = safe(function() return sdk.create_instance("chainsaw.collision.AttackHitUserData", true) end)
    local ad  = safe(function() return sdk.create_instance("chainsaw.collision.AttackHitUserData.AttackData", true) end)
    local arr = safe(function() return sdk.create_managed_array("chainsaw.collision.AttackHitUserData.AttackData", 1) end)
    if not (ahu and ad and arr) then return nil end
    pin(ahu); pin(ad); pin(arr)
    for k, v in pairs(FLASH_ATTACK_DATA) do pcall(function() ad:set_field(k, v) end) end
    -- [BELEGT 2026-07-23] `set_element` wirft hier (REFramework fuellt Klassen-Arrays nicht so), das
    -- Array-Element bleibt null -- und GENAU SO lief der erfolgreiche Test: entscheidend ist offenbar
    -- nur, dass am Spieler-HC ueberhaupt ein `_AttackHitUserData` haengt; die Angriffswerte zieht die
    -- Engine ueber `_KeyNameHash`/`_AttackHitDataID` der AttackUserData. Der Fehlschlag darf den Bau
    -- deshalb NICHT abbrechen -- das tat er hier, Log: "Bau fehlgeschlagen (ud=true tbl=false dmg=true)".
    pcall(function() arr:set_element(0, ad) end)
    if not pcall(function() ahu:set_field("_AttackDataList", arr) end) then return nil end
    made.tbl = ahu
    return made.tbl
end

local function dmg_ud()
    if made.dmg then return made.dmg end
    local d = safe(function() return sdk.create_instance("chainsaw.collision.DamageUserData", true) end)
    made.dmg = pin(d)
    return made.dmg
end

local function player_parts()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = sc(cm, "getPlayerContextRef"); if not ctx then return nil end
    local go = sc(ctx, "get_BodyGameObject"); if not go then return nil end
    local hm = sdk.get_managed_singleton("chainsaw.HitManager"); if not hm then return nil end
    local hc = sc1(hm, "getHitController", go); if not hc then return nil end
    local tf = sc(go, "get_Transform")
    local p  = tf and safe(function() return tf:get_position() end)
    return hc, p, cm
end

-- Erkennt die EIGENE Tabelle: genau ein Eintrag. Die Tabellen des Spiels haben viele (die Flash-Bombe
-- trug 173). Wichtig nach einem Script-Reset -- dann haengt evtl. noch die Tabelle aus dem alten
-- Lua-Zustand drin, die nicht mehr verankert ist und ersetzt werden muss.
local function is_own_table(t)
    local lst = t and safe(function() return t:get_field("_AttackDataList") end)
    if not lst then return false end
    local n = tonumber(safe(function() return lst:get_size() end)) or tonumber(sc(lst, "get_Length"))
    return n == 1
end

local function fire_stagger()
    if not STAGGER_ENABLED then return end
    local hc, ppos, cm = player_parts()
    if not (hc and ppos and cm) then return end
    local ud, tbl, dmg = flash_ud(), flash_table(), dmg_ud()
    if not (ud and tbl and dmg) then return end
    local hud = safe(function() return hc:get_field("_UserData") end)
    if not hud then return end
    -- Falle 2: fremde Tabellen bleiben unangetastet -- eine eigene (1 Eintrag) darf ersetzt werden.
    local old = safe(function() return hud:get_field("_AttackHitUserData") end)
    if old and not is_own_table(old) then return end
    if not pcall(function() hud:set_field("_AttackHitUserData", tbl) end) then return end

    local list  = sc(cm, "get_EnemyContextList")
    local count = tonumber(sc(list, "get_Count")) or 0
    local hits  = 0
    for i = 0, count - 1 do
        if hits >= STAGGER_MAX then break end
        local ectx = sc1(list, "get_Item", i)
        local hp   = ectx and sc(ectx, "get_HitPoint")
        local dead = hp and sc(hp, "get_IsDead")
        local chp  = hp and tonumber(sc(hp, "get_CurrentHitPoint"))
        if hp and dead ~= true and (chp or 0) > 0 then
            local pos = sc(ectx, "get_Position")
            local go  = pos and sc(ectx, "get_BodyGameObject")
            if go then
                local dx, dy, dz = pos.x - ppos.x, pos.y - ppos.y, pos.z - ppos.z
                if (dx*dx + dy*dy + dz*dz) <= (STAGGER_REACH * STAGGER_REACH) then
                    -- [FIX 2026-07-23] Frueher wurde hier pauschal auf false zurueckgesetzt --
                    -- der Dump zeigt aber, dass HitController von Haus aus AttackEnable=true haben.
                    -- Wir haben den Spieler-HitController also dauerhaft entschaerft zurueckgelassen.
                    -- Jetzt: vorherigen Wert lesen und exakt den wiederherstellen.
                    local was = sc(hc, "get_AttackEnable")
                    pcall(function() hc:call("set_AttackEnable", true) end)
                    pcall(function() hc:call("requestAttack", go, ud, dmg) end)
                    if was ~= true then pcall(function() hc:call("set_AttackEnable", false) end) end
                    hits = hits + 1
                end
            end
        end
    end
    -- Vorzustand zurueck -- es bleibt nichts haengen. Laesst sich das Feld nicht auf nil setzen,
    -- bleibt unsere (verankerte) Tabelle stehen; der naechste Burst erkennt sie als eigene wieder.
    pcall(function() hud:set_field("_AttackHitUserData", nil) end)
end

-- =====================================================================
-- [TAUNT 2026-08-04] Zu JEDER Geste (LT+R.A und LT+R.B) zusaetzlich ein zufaelliger Spruch.
-- Die IDs sind die im #soundplayer per BROWSER markierten Lines: reframework/data/re4_vr/re4_vr_voice.json.
-- Jeder Eintrag traegt sein `label` = Name des Body-GO, auf dem er markiert wurde:
-- Leon = "ch0a0z0_body", Ada im Separate-Ways-DLC = "ch3a8z0_body" (live gemessen 2026-08-04).
--
-- PRO CHARAKTER EIN EIGENER POOL: beim Laden wird nach label gruppiert, zur Ausloesung der Name des
-- aktuellen Body-GO gelesen und genau dessen Pool gezogen. Wer keinen Pool hat (Mercs-Chars, solange
-- niemand ihre IDs markiert hat), bleibt still -- es wird NIE ein fremder Pool gespielt. Neue Charaktere
-- brauchen deshalb keinen Code, nur Marks im #soundplayer.
--
-- Reihenfolge = Shuffle-Bag JE POOL: alle Lines einmal in zufaelliger Folge, danach neu gemischt -> kein
-- Spruch zweimal hintereinander, trotzdem komplett zufaellig.
-- KEIN Komponenten-Cache: der Container wird pro Ausloesung frisch geholt (haelt Savegame-Loads aus,
-- kostet nur ein getComponent alle paar Sekunden).
-- =====================================================================
local TAUNT_ENABLED = true      -- fest an; KEINE UI, kein Toggle ( 2026-08-04)
local TAUNT_FILE    = "re4_vr/re4_vr_voice.json"   -- [UMBENANNT 2026-08-05] war data/re4_voice_marks.json
local LEON_BODY     = "ch0a0z0_body"
local _snd_t        = sdk.typeof("soundlib.SoundContainer")
-- [TAUNT-SKIP 2026-08-04] Diese Lines gehoeren zum Twirl und sollen NICHT als Geste-Spruch
-- kommen. Sperre steht hier und nicht in der JSON: die schreibt der #soundplayer beim naechsten
-- Mark-Klick aus seinem Speicherstand komplett neu -- geloeschte Eintraege waeren wieder drin.
-- Gilt NUR fuer Leons Pool: es sind seine Wwise-Hashes, bei einem anderen Charakter waere dieselbe
-- Zahl eine voellig andere Line.
local TAUNT_SKIP = {
    [2778708114] = true,   -- "looking good"
    [3778512958] = true,   -- "that was not easy"
    [3878582777] = true,   -- "not bad"
}
local taunt_pools, taunt_bags, taunt_seeded = nil, {}, false

local function taunt_load()
    taunt_pools, taunt_bags = {}, {}
    if not taunt_seeded then
        taunt_seeded = true
        pcall(function() math.randomseed(math.floor(os.time() + os.clock() * 1000)) end)
    end
    local d = safe(function() return json.load_file(TAUNT_FILE) end)
    local e = (type(d) == "table") and d.entries or nil
    if type(e) ~= "table" then return end
    for _, m in ipairs(e) do
        local id  = (type(m) == "table") and tonumber(m.id) or nil
        local lab = (type(m) == "table") and m.label and tostring(m.label) or nil
        if id and id > 0 and lab and lab ~= ""
           and not (lab == LEON_BODY and TAUNT_SKIP[math.floor(id)]) then
            local p = taunt_pools[lab]; if not p then p = {}; taunt_pools[lab] = p end
            p[#p + 1] = math.floor(id)
        end
    end
end

local function taunt_next(body)
    if not taunt_pools then taunt_load() end
    local pool = body and taunt_pools[body]
    if not pool or #pool == 0 then return nil end
    local bag = taunt_bags[body]
    if not bag or #bag == 0 then
        bag = {}
        for i = 1, #pool do bag[i] = pool[i] end
        for i = #bag, 2, -1 do
            local j = math.random(i)
            bag[i], bag[j] = bag[j], bag[i]
        end
        taunt_bags[body] = bag
    end
    return table.remove(bag)
end

-- Body-GO des aktuell gespielten Charakters + sein Name (der Name IST die Pool-Auswahl).
local function player_body()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return nil end
    local ctx = sc(cm, "getPlayerContextRef"); if not ctx then return nil end
    local go = sc(ctx, "get_BodyGameObject"); if not go then return nil end
    local nm = sc(go, "get_Name")
    if not nm then return nil end
    return go, tostring(nm)
end

local function play_taunt()
    if not (TAUNT_ENABLED and _snd_t) then return end
    local go, body = player_body(); if not go then return end
    local id = taunt_next(body); if not id then return end          -- kein Pool -> still
    local con = safe(function() return go:call("getComponent(System.Type)", _snd_t) end)
    if not con then return end
    pcall(function() con:call("trigger(System.UInt32)", id) end)
end

-- Haltezustand der Geste. Wird bei JEDEM Abbruchgrund geleert (Loslassen, Menue/KS, Haende nicht mehr
-- frei, Script-Reset) -> kein Nachzuenden nach einem Branch-Wechsel.
local hold = nil   -- { name = <geste>, t0 = <os.clock>, fired = <bool> }

local active = nil   -- { bones = <dict>, t0 = <os.clock> }

local function start(name)
    if not POSES then load_poses() end
    local bones = POSES[name]; if not bones then return end
    active = { bones = bones, t0 = os.clock() }
end

-- Blend-Faktor aus der Zeit (rein / halten / raus). nil = fertig.
local function blend_now()
    if not active then return nil end
    local e = os.clock() - active.t0
    if e >= (LERP_IN + HOLD + LERP_OUT) then return nil end
    if e < LERP_IN then return e / LERP_IN end
    if e < LERP_IN + HOLD then return 1.0 end
    local f = 1.0 - ((e - LERP_IN - HOLD) / LERP_OUT)
    return (f > 0.0) and f or 0.0
end

-- Der Joint-Writer aus reload.lua nlerpt current->target mit dem Blend -> Ein- und
-- Ausblenden ergeben sich allein aus dem Faktor. Ohne reload (unmoeglich, aber sicher ist sicher)
-- passiert einfach nichts.
local preview = nil   -- Posenname: haelt die Pose dauerhaft zum Tunen (UI), ignoriert die Zeitkurve

local function apply()
    local w = rawget(_G, "__re4_reload_apply_pose_bones")
    if type(w) ~= "function" then return end
    -- [VORSCHAU] Zum Einstellen am Desktop: haelt die Pose, solange die Checkbox an ist. Bewusst OHNE
    -- bare-hands-Gate (sonst koennte man sie mit Waffe in der Hand nicht sehen), aber nur im Gameplay.
    if preview and POSES and POSES[preview] and rawget(_G, "__re4_frame_pure_gameplay") == true then
        pcall(w, POSES[preview], 1.0)
        return
    end
    if not active then return end
    if not hands_free() or rawget(_G, "__re4_frame_pure_gameplay") ~= true then active = nil; return end
    local b = blend_now()
    if not b then active = nil; return end
    pcall(w, active.bones, b)
end

re.on_frame(function()
    -- Zuendung einsammeln (binding setzt den Namen genau einmal pro Tastendruck).
    local fire = rawget(_G, "__re4_gesture_fire")
    if fire ~= nil then
        _G.__re4_gesture_fire = nil
        if hands_free() and rawget(_G, "__re4_frame_pure_gameplay") == true then
            start(fire)
            play_taunt()      -- [TAUNT 2026-08-04] beide Gesten, nur Leon
        end
    end

    -- [STAGGER-HALTEN 2026-07-23] Reines Gameplay hat NICHT Vorrang, sondern ist Vorbedingung:
    -- sobald wir im Menue/Killswitch/Boot/Fernglas sind (oder die Haende nicht mehr frei), wird der
    -- Haltezustand verworfen statt weiterzulaufen -- ein danach erst reifender Halter zuendet also nie.
    -- (Das binding setzt __re4_gest_prev in diesen Branches ohnehin schon auf nil; das hier ist die
    -- zweite, unabhaengige Sperre, damit die Menue-Branch nichts durchscheinen laesst.)
    local gate = (rawget(_G, "__re4_frame_pure_gameplay") == true) and hands_free()
    local g = gate and rawget(_G, "__re4_gest_prev") or nil
    if g ~= "fuck_you" then
        hold = nil
    else
        if not hold then hold = { t0 = os.clock(), fired = false } end
        if not hold.fired and (os.clock() - hold.t0) >= STAGGER_HOLD then
            hold.fired = true            -- genau EINMAL pro Halten; erst Loslassen macht wieder scharf
            pcall(fire_stagger)
        end
    end
end)

-- Gleiche 4 Stufen wie arm_chain/motion -> die Pose ueberlebt die nativen Anim-Passes.
re.on_pre_application_entry("LockScene",         apply)
re.on_application_entry("LateUpdateBehavior",    apply)
re.on_application_entry("UpdateJointExpression", apply)
re.on_pre_application_entry("BeginRendering",    apply)

-- =====================================================================
-- UI (Desktop): Fingerkruemmung je Pose einstellen. Grad = Beugung um die lokale Z-Achse,
-- 0 = gestreckt, positiv = eingerollt (so wie die vorhandenen RE4-Captures aufgebaut sind).
-- Jede Aenderung wird sofort in re4_vr_guestures.json gespeichert.
-- =====================================================================
-- [BEREICH 2026-07-21] Der Daumen braucht mehr Gegenrichtung (Spitze bis -90) als die Finger.
local function dslider(name, jn, label)
    local cur = DEG[name][jn] or 0.0
    local lo = jn:match("Thumb") and -90.0 or -30.0
    local ch, v = imgui.slider_float(label, cur, lo, 140.0, "%.0f Grad")
    if ch then DEG[name][jn] = v; rebuild(name); save_poses() end
end

-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Guestures" raus (33 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

re.on_script_reset(function()
    active = nil; hold = nil; preview = nil; DEG = nil; ROT = nil; POSES = nil
    taunt_pools = nil; taunt_bags = {}              -- [TAUNT] JSON beim naechsten Mal frisch lesen
end)

