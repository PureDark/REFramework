-- Builtin implementation: src/mods/vr/games/re4/RE4VRWeapons.cpp
return

if reframework:get_game_name() ~= "re4" then
  return
end

------------------------------------------------------------
-- RE4 VR - Weapons
-- + Knife instant holster via VR grip release
-- + Assist light: optional world rotation = VR HMD / camera_rot_full (firstperson export)
-- + Body-Holster-Visuals verstecken (Messertasche ac0000_00 + alle nicht
-- equippten wpXXXX-Display-GOs am Player-Root; Enforce 1x pro Frame in
-- LockScene-pre, Engine re-enabled DrawSelf bei Switch/Holster-Refresh.
-- Nach Toggle-OFF zeigt die Engine die Display-Waffen erst beim
-- naechsten Waffenwechsel wieder an.)
------------------------------------------------------------

local ok_ks, killswitch = pcall(function()
    return require("re4vr/re4_vr_killswitch")
end)
if not ok_ks or not killswitch then
    return
end

-- Pause menu + attache case: same checks as firstperson/binding
local attache_case_manager_cached = nil
local gui_manager_cached = nil
local function is_any_menu_open()
    if not attache_case_manager_cached then
        attache_case_manager_cached = sdk.get_managed_singleton("chainsaw.AttacheCaseManager")
    end
    if attache_case_manager_cached then
        local ok, busy = pcall(function() return attache_case_manager_cached:call("get_IsAttacheCaseBusy") end)
        if ok and busy == true then return true end
    end
    if not gui_manager_cached then
        gui_manager_cached = sdk.get_managed_singleton("chainsaw.GuiManager")
    end
    if gui_manager_cached then
        local ok, pause_lock = pcall(function()
            return gui_manager_cached:call("get_hasOccupiedPauseMenuSystemLock")
        end)
        if ok and pause_lock == true then return true end
    end
    return false
end

local mesh_type = sdk.typeof("via.render.Mesh")

local KNIFE_IDS = {
    [5000] = true,
    [5001] = true,
    [5002] = true,
    [5003] = true,
    [5006] = true,
    [6107] = true,
    [6108] = true,
    [6305] = true,   -- Hot Dogger (Mercenaries)
}

------------------------------------------------------------
-- Toggles
------------------------------------------------------------
local hide_assist_light_enabled = false
-- Aim-assist spotlight: rotate with headset view instead of body skeleton (uses _G.vr_camera_fix.camera_rot_full).
local assist_light_follow_vr_cam_enabled = true

local assist_light_cache = {
    body_addr = nil,
    go         = nil,
    tf         = nil,
}

------------------------------------------------------------
-- Hide body weapons config (persisted)
------------------------------------------------------------
local HIDE_BODY_CFG_PATH = "re4_vr/re4_vr_hide_body.json"
local hide_body_cfg = { enabled = true }
local function save_hide_body_cfg()
    pcall(function() json.dump_file(HIDE_BODY_CFG_PATH, hide_body_cfg) end)
end
pcall(function()
    local d = json.load_file(HIDE_BODY_CFG_PATH)
    if type(d) == "table" and d.enabled ~= nil then hide_body_cfg.enabled = d.enabled == true end
end)

------------------------------------------------------------
-- Safe helpers
------------------------------------------------------------
local function safe_call(obj, method)
    if not obj then return nil end
    local ok, r = pcall(function() return obj:call(method) end)
    return ok and r or nil
end

local function safe_call1(obj, method, arg)
    if not obj then return nil end
    local ok, r = pcall(function() return obj:call(method, arg) end)
    return ok and r or nil
end

local function safe_field(obj, name)
    if not obj then return nil end
    local ok, r = pcall(function() return obj:get_field(name) end)
    return ok and r or nil
end

------------------------------------------------------------
-- Core functions
------------------------------------------------------------
local character_manager = nil
-- [STALE-SINGLETON 2026-07-20] Der CharacterManager wurde EINMAL gecacht und nie geprueft.
-- Wird er ungueltig (Save-Load, Stage-/Respawn-Wechsel), liefert getPlayerContextRef nichts mehr ->
-- get_equip_weapon_id = nil -> "keine Granate equippt" -> die native Wurflinie wird NICHT mehr
-- unterdrueckt UND der eigene Wurf feuert nicht. Genau dieses Doppel-Symptom trat auf, und ein
-- "Reset Scripts" hat es behoben (weil der Cache dabei neu entsteht) -- das war der Beweis.
-- Fix: liefert der gecachte Manager keinen Kontext, einmal neu aufloesen und erneut versuchen.
-- [FRAME-CACHE 2026-08-17] Siehe re4vr/re4_vr_frame_cache.lua: einmal pro Frame aufloesen statt bei
-- jedem Aufruf. Semantik unveraendert, alter Weg bleibt als Fallback. NOT-AUS: `_G.__re4_fc_off = true`.
pcall(function() require("re4vr/re4_vr_frame_cache") end)

local function get_player_ctx()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.ctx() end
    if not character_manager then
        character_manager = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    end
    if not character_manager then return nil end
    local ctx = safe_call(character_manager, "getPlayerContextRef")
    if ctx then return ctx end
    -- Cache war stale -> neu holen und ein zweites Mal fragen
    character_manager = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    if not character_manager then return nil end
    return safe_call(character_manager, "getPlayerContextRef")
end

local function get_equip_weapon_id()
    local _fc = rawget(_G, "__re4_frame_cache")
    if _fc and _fc.on() then return _fc.equip_wid() end
    local ctx = get_player_ctx()
    if not ctx then return nil end
    local h = safe_call(ctx, "get_HeadUpdater")
    if not h then return nil end
    local wid = safe_call(h, "get_EquipWeaponID")
    if not wid then return nil end
    if type(wid) == "userdata" then
        local v = safe_field(wid, "value__")
        if type(v) == "number" then return v end
    end
    return type(wid) == "number" and wid or nil
end

------------------------------------------------------------
-- [SCOPE_KILLSWITCH] Zielen durch ein montiertes Scope (_IsViaScope am
-- BusyCameraController) erkennen -> Force-Global setzen, das der Killswitch
-- liest. Dadurch pausieren motion/materials/firstperson etc. (native Scope-
-- Kamera uebernimmt). Logik portiert aus dem deaktivierten re4_vr_scope.lua
-- (check_scope_aim). Nur bei Scope-faehigen Waffen.
------------------------------------------------------------
local SCOPE_WEAPONS = {
    [4400] = true, [4401] = true, [4402] = true,
    [4202] = true, [6105] = true, [6114] = true,
}
-- [SCOPE_BULLET] Vorzeichen der Scope-Kamera-Forward-Achse (+Z oder -Z). Falls die Kugel nach HINTEN
-- geht oder daneben, auf -1.0 stellen (eine Zeile, Reset).
local SCOPE_BULLET_ZSIGN = -1.0
local function check_via_scope()
    local wid = get_equip_weapon_id()
    if not wid or not SCOPE_WEAPONS[wid] then return false end
    local ctx = get_player_ctx()
    if not ctx then return false end
    local hu = safe_call(ctx, "get_HeadUpdater")
    if not hu then return false end
    local cc = safe_call(hu, "get_CameraController")
    if not cc then return false end
    local busy = safe_field(cc, "_BusyCameraController")
    if not busy then return false end
    return safe_field(busy, "_IsViaScope") == true
end

-- [SCOPE_HIDE_BODY] Im Scope ALLE Materials der Child-GOs "body" UND "body_armor" unter ch0a0z0_body
-- ausblenden -> Wildcard, egal wie die Materials heissen -> universell ueber alle Kostueme. Mechanismus
-- wie der alte Materials-Mod (setMaterialsEnable, beide Formen). Beim Verlassen wieder sichtbar.
local SCOPE_HIDE_GOS = { ["body"] = true, ["body_armor"] = true }
local T_SKINMESH = sdk.typeof("via.render.SkinnedMesh")
local function scope_set_all_materials(r, visible)
    if not r then return end
    local n = safe_call(r, "get_MaterialNum")
    if type(n) ~= "number" then return end
    for mi = 0, n - 1 do
        pcall(function() r:call("setMaterialsEnable", mi, visible) end)
        pcall(function() r:call("setMaterialsEnable(System.Int32,System.Boolean)", mi, visible) end)
    end
end
local function scope_walk_body(tf, visible, depth)
    if not tf or depth > 8 then return end
    local go = safe_call(tf, "get_GameObject")
    if go then
        local name = safe_call(go, "get_Name")
        if type(name) == "string" and SCOPE_HIDE_GOS[name] then
            scope_set_all_materials(safe_call1(go, "getComponent(System.Type)", mesh_type), visible)
            scope_set_all_materials(safe_call1(go, "getComponent(System.Type)", T_SKINMESH), visible)
        end
    end
    local child = safe_call(tf, "get_Child")
    local guard = 0
    while child and guard < 256 do
        guard = guard + 1
        scope_walk_body(child, visible, depth + 1)
        child = safe_call(child, "get_Next")
    end
end
local scope_arms_was_on = false
local function scope_hide_arms_tick(on)
    if not on and not scope_arms_was_on then return end
    local ctx  = get_player_ctx()
    local body = ctx and safe_call(ctx, "get_BodyGameObject")
    local tf   = body and safe_call(body, "get_Transform")
    if tf then scope_walk_body(tf, not on, 0) end   -- on -> visible=false (alle body/body_armor-Materials aus)
    scope_arms_was_on = on and true or false
end

-- [SCOPE_ID] Welches Scope ist montiert? Ground-Truth = equippte Scope-Attachment-ItemID
-- (aktualisiert SOFORT beim Wechsel; die ScopeController-Felder sind stale bis zum Durchzielen).
-- Stingray sm72-Scope-Familie: 500=Normal, 503=Thermal, 502=Hi-Power.
local SCOPE_ITEM_IDS = { [116000000] = "normal", [116004800] = "thermal", [116003200] = "hipower" }
local scope_id_throttle = 0
local function detect_scope_id()
    local ctx = get_player_ctx(); if not ctx then return end
    local hu  = safe_call(ctx, "get_HeadUpdater"); if not hu then return end
    local gun = safe_call(hu, "get_EquipWeapon")
    if not gun then _G.__re4_scope_id = nil; return end   -- keine Gun (Messer/Holster) -> nichts erkannt
    local pc    = safe_call(gun, "get_WeaponPartsCustom")
    local datas = pc and safe_field(pc, "_Datas")
    -- List.get_Item(i) liefert hier NULL (generische Methode greift nicht) -> _items-Array direkt indizieren.
    local n = datas and (tonumber(safe_call(datas, "get_Count")) or tonumber(safe_field(datas, "_size")) or 0) or 0
    local items = datas and safe_field(datas, "_items")
    for i = 0, n - 1 do
        local sd = nil
        if items then local ok, e = pcall(function() return items[i] end); if ok then sd = e end end
        if not sd then sd = safe_call(datas, "get_Item", i) end
        local iid = sd and safe_call(sd, "get_ItemId")
        local v   = (type(iid) == "number") and iid or (iid and safe_field(iid, "value__"))
        local name = v and SCOPE_ITEM_IDS[v]
        if name then _G.__re4_scope_id = name; return end
    end
    _G.__re4_scope_id = nil   -- Waffe ohne (bekanntes) Scope montiert
end

-- ============================================================
-- [IRON_SIGHT_NATIVE] Nur die 3 Rifles OHNE montiertes Scope (Iron-Sight): Waffe + Body
-- in den VR-Haenden halten statt nativem Aim-Stand. Portiert aus re4_vr_scope.lua.bak
-- (Punkte 1-3). Kein Killswitch -> motion/firstperson laufen normal weiter.
-- ============================================================
-- [SW 2026-07-19] Separate Ways: 6105 (Anti-Materiel = Stingray-Klon) und 6114
-- (Hunting Rifle = Bolt-Rifle-Klon) brauchen dieselbe Iron-Sight-Behandlung. Ohne Eintrag
-- blieb die Waffe im nativen Aim-Stand haengen statt in den VR-Haenden ("unparented").
local IRON_RIFLES = { [4400] = true, [4401] = true, [4402] = true, [6105] = true, [6114] = true }
local _iron_scene_td  = sdk.find_type_definition("via.SceneManager")
local _iron_mesh_type = sdk.typeof("via.render.Mesh")
local _iron_active_wid = nil   -- von scope_killswitch_tick gesetzt, im LockScene-Pass geforct (nach Game-Hiding)
local IRON_BODY_GOS = { ["body"] = true, ["body_armor"] = true, ["hair"] = true, ["head"] = true }

local function iron_get_scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm or not _iron_scene_td then return nil end
    local ok, sc = pcall(function() return sdk.call_native_func(sm, _iron_scene_td, "get_CurrentScene") end)
    return ok and sc or nil
end
local function iron_find_weapon_go(wid)
    local scene = iron_get_scene(); if not scene then return nil end
    local base = string.format("wp%04d", wid)
    for _, name in ipairs({ base, base .. "_AO", base .. "_MC" }) do
        local go = safe_call1(scene, "findGameObject(System.String)", name)
        if go and tostring(go) ~= "nil" and safe_call(go, "get_Valid") then return go end
    end
    return nil
end
-- Punkt 1: Body/Arme/Haar/Kopf wieder sichtbar (Spiel blendet sie beim Aim aus)
local function iron_walk_body_visible(tf, depth)
    if not tf or depth > 8 then return end
    local go = safe_call(tf, "get_GameObject")
    if go then
        local name = safe_call(go, "get_Name")
        if type(name) == "string" and IRON_BODY_GOS[name] then
            pcall(function() go:call("set_UpdateSelf", true) end)
            pcall(function() go:call("set_DrawSelf", true) end)
            pcall(function() go:write_byte(0x13, 1) end)
        end
    end
    local child = safe_call(tf, "get_Child"); local guard = 0
    while child and guard < 256 do
        guard = guard + 1
        iron_walk_body_visible(child, depth + 1)
        child = safe_call(child, "get_Next")
    end
end
local function iron_force_body_visible()
    local ctx  = get_player_ctx(); if not ctx then return end
    local body = safe_call(ctx, "get_BodyGameObject")
    local tf   = body and safe_call(body, "get_Transform")
    if tf then iron_walk_body_visible(tf, 0) end
end
-- Punkt 2: Waffen-Mesh-Part 0 wieder an (Spiel versteckt es beim Aim)
local function iron_force_weapon_mesh(wid)
    if not _iron_mesh_type then return end
    local go = iron_find_weapon_go(wid); if not go then return end
    local mesh = safe_call1(go, "getComponent(System.Type)", _iron_mesh_type)
    if not mesh or tostring(mesh) == "nil" then return end
    pcall(function() mesh:call("setPartsEnable", 0, true) end)
end
-- Punkt 3: Waffe an den Body zurueckhaengen wenn der Parent verloren ging (nativer Aim koppelt ab)
local function iron_ensure_parented(wid)
    local go = iron_find_weapon_go(wid); if not go then return end
    local wp_tf = safe_call(go, "get_Transform"); if not wp_tf then return end
    local parent = safe_call(wp_tf, "get_Parent")
    if parent and tostring(parent) ~= "nil" then return end
    -- [KEIN BODY-CACHE 2026-08-09, Audit] Hier stand ein gecachter Body-Transform, der nur mit
    -- `tostring(x) == "nil"` geprueft und NIE zurueckgesetzt wurde. Nach Save-Load/Rundenwechsel
    -- ist das gemerkte Objekt eine Leiche (liefert weiter Werte, wirft keinen Fehler) -- die
    -- Waffe waere an einen toten Transform gehaengt worden, bis "Reset Scripts"
    -- (bekannte Falle).
    -- Der Cache ist ohnehin unnoetig: diese Zeilen laufen nur, wenn der Parent WIRKLICH weg ist
    -- (Abbruch oben), und der Weg ctx -> BodyGameObject -> Transform ist ein billiger Lookup
    -- ohne Szenensuche. Also jedes Mal frisch holen.
    local ctx  = get_player_ctx()
    local body = ctx and safe_call(ctx, "get_BodyGameObject")
    local btf  = body and safe_call(body, "get_Transform")
    if btf then pcall(function() wp_tf:call("set_Parent", btf) end) end
end
local function iron_sight_tick(wid)
    iron_force_body_visible()
    iron_force_weapon_mesh(wid)
    iron_ensure_parented(wid)
end

-- [BOLT_CYCLE] Nur die Repetierer: laeuft auf der GUN-MotionFsm2 (Layer 0) gerade die native
-- Bolt-Cycle-/Nachlade-Anim "Aim_Fire.PumpAction"? Robuster Gate als der CameraState
-- (CAM=PumpAction flackert nur 1 Frame, der GUN-Node deckt das ganze Fenster ab).
-- [ADA 2026-08-15] 6114 (Hunting Rifle, Separate Ways) ist derselbe Repetierer wie die
-- SR M1903 4400 -- alle Bolt-Gates hier standen bisher hart auf 4400, dadurch lief bei Ada
-- KEINE der Nachbehandlungen (Body bleibt weg, Force springt zurueck, kein Aim-Cut).
local BOLT_RIFLES = { [4400] = true, [6114] = true }
local _bolt_mfsm_td = sdk.typeof("via.motion.MotionFsm2")
local function gun_bolt_cycle_active(ewid)
    if not BOLT_RIFLES[ewid] or not _bolt_mfsm_td then return false end
    local ctx = get_player_ctx(); if not ctx then return false end
    local hu  = safe_call(ctx, "get_HeadUpdater"); if not hu then return false end
    local gun = safe_call(hu, "get_EquipWeapon"); if not gun then return false end
    local go  = gun and safe_call(gun, "get_GameObject"); if not go then return false end
    local m   = safe_call1(go, "getComponent(System.Type)", _bolt_mfsm_td)
    if not m or tostring(m) == "nil" then return false end
    local n = safe_call1(m, "getCurrentNodeName", 0)
    return n ~= nil and tostring(n):find("PumpAction", 1, true) ~= nil
end

-- [SCOPE_HOLD] Lag seit dem aktuellen Aim-Druck schon einmal ECHTES `_IsViaScope` an? Nur dann
-- darf der Hold unten einen Aussetzer ueberbruecken. Muss HIER oben stehen (Local-Reihenfolge).
local _scope_via_seen = false

local function scope_killswitch_tick()
    local on = check_via_scope()
    -- [VIA_RAW] Das ECHTE `_IsViaScope` des Spiels, bevor der Hold unten es faelscht. Reine
    -- Information: nur so ist von aussen unterscheidbar, ob das Spiel wirklich im Scope steht
    -- oder ob wir den Zustand nur halten (beim Laufen kippt es, s. SCOPE_HOLD).
    _G.__re4_scope_via_raw = on and true or false
    -- [SCOPE_WID] equippte Scope-Waffen-ID IMMER publishen (nicht nur im Scope) -> movement.lua
    -- keyt Augen-Versatz pro Waffe x Zustand UND zeigt sie in der Statuszeile.
    local ewid = get_equip_weapon_id()
    _G.__re4_scope_wid = (type(ewid) == "number" and SCOPE_WEAPONS[ewid]) and ewid or nil
    -- [SCOPE_HOLD 2026-08-08] Das SPIEL setzt `_IsViaScope` zurueck, sobald man sich
    -- bewegt, und baut es erst Sekunden spaeter wieder auf -- live gemessen: kippt bei
    -- t=2.465 und bleibt weg, waehrend der Kamera-Controller unveraendert bleibt. Da unser
    -- kompletter Scope-Zweig an diesem Flag haengt, wartet er genau diese Sekunden mit.
    -- Solange die Aim-Taste gehalten wird UND eine Scope-Waffe in der Hand ist, halten wir
    -- den Zustand deshalb selbst. NUR auf unserem Fork -- ohne ihn bleibt alles wie bisher.
    -- Abschaltbar ueber den Tree "RE4VR - Scope" (`__re4_scope_hold_enable`), weil das Halten
    -- einen Preis hat: der Eintritts-Reset (u.a. scope_pitch_base in movement.lua) laeuft
    -- dann beim Rein-/Raus-Zoomen nicht neu.
    -- [HOLD_NUR_NACH_ECHTEM_SCOPE 2026-08-09] Der Hold darf einen Aussetzer UEBERBRUECKEN,
    -- aber den Zustand niemals ERFINDEN. Vorher fehlte diese Bedingung: eine Waffe aus
    -- SCOPE_WEAPONS (z.B. die LE5 4202) OHNE montiertes Scope bekam beim blossen Aim-Druck
    -- sofort on=true -> Mono + schwarzes Auge, obwohl das Spiel nie ViaScope gemeldet hat.
    -- Jetzt: gehalten wird nur, wenn seit dem AKTUELLEN Aim-Druck schon einmal echtes
    -- `_IsViaScope` anlag. Loslassen loescht den Merker, ohne Scope wird er nie gesetzt.
    if rawget(_G, "__vr_aim_input") ~= true then
        _scope_via_seen = false
    elseif on then
        _scope_via_seen = true
    end
    if not on and _scope_via_seen
       and rawget(_G, "__re4_fork_ok") == true
       and rawget(_G, "__re4_scope_hold_enable") ~= false
       and rawget(_G, "__vr_aim_input") == true
       and _G.__re4_scope_wid ~= nil then
        on = true
    end
    -- [BOLT-SCHUSS 2026-08-09] Erkennung steht HIER OBEN, aus zwei Gruenden: der Aim-Cut
    -- unten im Binding muss im SELBEN Frame greifen (Schuss bei t=0.02, Kamerasprung erst
    -- bei t=0.60 -- gemessen), und das Bolt-Fenster weiter unten nutzt denselben Stempel,
    -- statt die Body-FSM ein zweites Mal abzufragen.
    -- Was hier NICHT mehr versucht wird (alles im Spiel durchgefallen): `on = false` nach
    -- dem Schuss (nahm der Waffe jede Versorgung, Meshes fehlten), Kamera-Position
    -- einfrieren, Kamera-Pitch als Blickquelle, Sprungerkennung im Waffen-Pitch.
    if BOLT_RIFLES[ewid] then
        local _ctx  = get_player_ctx()
        local _body = _ctx and safe_call(_ctx, "get_BodyGameObject")
        local _fsm  = _body and safe_call1(_body, "getComponent(System.Type)",
                                           sdk.typeof("via.motion.MotionFsm2"))
        local _n5   = _fsm and safe_call1(_fsm, "getCurrentNodeName", 5)
        if type(_n5) == "string" and _n5:find("Shoot", 1, true) then
            _G.__re4_bolt_shoot_t = os.clock()
            -- [BOLT_REAIM] Startschuss fuer den kurzen Aim-Cut in re4_vr_binding.lua.
            -- Wird NUR hier gesetzt (Repetierer 4400/6114 + echte Shoot-Node + Aim gehalten) und dort
            -- nach Ablauf sofort geloescht -- sonst existiert die Globale gar nicht.
            if rawget(_G, "__re4_bolt_reaim") ~= false
               and rawget(_G, "__vr_aim_input") == true
               and rawget(_G, "__re4_bolt_aim_cut_t") == nil then
                _G.__re4_bolt_aim_cut_t = os.clock()
            end
        end
    end

    -- [SCOPE_ID] frisch ermitteln (entscheidet Iron-Sight vs Scope).
    if on then detect_scope_id()
    else scope_id_throttle = (scope_id_throttle + 1) % 20; if scope_id_throttle == 0 then detect_scope_id() end end
    -- [IRON_SIGHT_SPLIT] Nur die 3 Rifles OHNE montiertes Scope (scope_id == nil) = Iron-Sight ->
    -- KEIN Killswitch-Scope, stattdessen Waffe nativ in den VR-Haenden (Punkte 1-3). Alles andere
    -- (echtes Scope, LE5, 6105/6114) = scope_aim wie bisher.
    local iron_sight = on and IRON_RIFLES[ewid] and (rawget(_G, "__re4_scope_id") == nil)
    local scope_aim  = on and not iron_sight
    -- [SCOPE_MONO 2026-08-08] Der Scope-Weg bleibt wie er ist: Freeze + Augen-Versatz legen
    -- den Blick vors Okular, gezoomt wird von der SCOPE-KAMERA des Spiels selbst -- genau wie flat.
    -- Neu ist NUR, dass unser eigener Fork dabei auf Mono-Rendering schalten kann, damit beide
    -- Augen dasselbe Bild bekommen. Dieses Flag ist reine INFORMATION fuer re4_vr_scope.lua und
    -- aendert hier nichts. `__re4_scope_mono_enable` ist der Schalter aus dem Tree "RE4VR - Scope".
    _G.__re4_scope_native = (scope_aim and (rawget(_G, "__re4_fork_ok") == true)
                                       and (rawget(_G, "__re4_scope_mono_enable") ~= false)) and true or false
    -- [BOLT-FENSTER 2026-08-02] Live gemessen: waehrend der Bolzen-Anim nach dem Schuss
    -- steht `reason=viascope` an -- dieser Force gewinnt in killswitch.lua vor allem anderen
    -- und macht KS1, also volle 3rd-Person. OHNE montiertes Scope passiert das nicht, dort
    -- greift der Suppress in reload2 sauber und die Anim ist weg (bestaetigt).
    -- Also NUR diesen Force fuer die Dauer der Anim aussetzen -- kein KS4, kein anderer Zweig,
    -- sonst stehen unsere Scripte still und die Waffe wird starr.
    -- Das Fenster haengt am ECHTEN Zustand statt an einer festen Zeit: die Anim laeuft am
    -- SPIELER auf Layer 5 als "Shoot.ch0_500_SHOOT" bis "AfterShoot" (live geloggt). Ein festes
    -- 1.2s-Fenster endete mitten drin -> der Force sprang zurueck und erzeugte einen kurzen
    -- 3rd-Person-Blitz. Kleiner Nachlauf gegen Ein-Frame-Flackern. Nur wp4400.
    -- Merker als Global statt local: weapons.lua ist am 200-Local-Limit, und die
    -- Body-FSM wird hier direkt geholt (wsw_get_comps steht weiter UNTEN und waere
    -- an dieser Stelle nicht sichtbar, siehe Notiz).
    -- [MESSBEFUND 2026-08-09, nur zur Info -- Verhalten unveraendert] Dieses Fenster ist
    -- faktisch NICHT 0.25 s lang, sondern ~1.6 s: `__re4_bolt_shoot_t` wird nachgestempelt,
    -- solange Layer 5 "Shoot" meldet, und diese Node laeuft mit AfterShoot bis ~1.37 s.
    -- In genau diesem Fenster springt die Kamera 0.8 m weg. Ungetestet ist, was passiert,
    -- wenn man das Fenster weglaesst -- vorher NICHT daran drehen (s. Kommentar oben,
    -- ohne das Fenster kam frueher reason=viascope -> KS1 -> volle 3rd-Person).
    -- Zeitstempel kommt aus der Schuss-Erkennung oben (eine FSM-Abfrage statt zwei).
    local bolt_win = false
    if BOLT_RIFLES[ewid] then
        local _st = tonumber(rawget(_G, "__re4_bolt_shoot_t"))
        bolt_win = _st ~= nil and (os.clock() - _st) < 0.25
    end
    _G.__re4_force_killswitch_scope = (scope_aim and not bolt_win) and true or false
    -- LockScene-Pass forct dann Body/Mesh/Parent. NUR fuer Iron-Sight -- im nativen Scope
    -- soll das Spiel die Waffe behalten, wir haengen sie dort BEWUSST nicht zurueck.
    _iron_active_wid = iron_sight and ewid or nil
    -- [BOLT_CYCLE] wp4400: laeuft gerade die native Bolt-Cycle-/Nachlade-Anim ("Aim_Fire.PumpAction")?
    -- Gilt fuer BEIDE Faelle (Iron-Sight UND montiertes Scope) -> Leon in der 3rd-Person-Nachlade-
    -- Anim immer komplett sichtbar.
    local bolt_cycle = BOLT_RIFLES[ewid] and gun_bolt_cycle_active(ewid)
    -- [BOLTCYCLE_PIN 2026-07-18] TEST (wie Skull Shaker wp6001): waehrend der nativen PumpAction NICHT
    -- killswitchen und iron-force WEITERLAUFEN lassen -> motion + iron pinnen die Waffe an die VR-Hand
    -- (statt nativem Absenken aus der Sicht). Die Bolt-Joint-Anim laeuft relativ zum gepinnten Root.
    -- Fallback falls die native Anim gegen den Pin kaempft: __re4_force_killswitch_bolt wieder auf
    -- (bolt_cycle and iron_sight) -> dann KS4 (First-Person, aber Waffe senkt nativ ab).
    _G.__re4_force_killswitch_bolt = false
    -- [SCOPE_HIDE_ARMS] body/body_armor NUR im echten Scope-Zoom ausblenden -- aber NICHT waehrend
    -- der Bolt-Cycle-Anim: dann zeigt das Spiel Leon in 3rd-Person, body muss sichtbar bleiben.
    -- [BOLT_HIDE_WIN 2026-08-09, gemessen] `bolt_cycle` haengt an der WAFFEN-FSM ("PumpAction")
    -- und trifft die Anim praktisch nie -> nach dem Schuss blieb der Body ausgeblendet, obwohl
    -- die Kamera laengst aus dem Zoom raus ist: man stand im normalen Bild ohne Leon.
    -- MESSUNG (re4_bolt_ks_log, 2026-08-09): der Killswitch ist dabei NICHT scharf (ks=false,
    -- is_pure_gameplay=true ueber das ganze Fenster) -- es war allein dieses Ausblenden.
    -- Der Zustand haelt ~1,05 s an (`__re4_scope_native` faellt bei +1.03 s, CamState ist bei
    -- +1.20 s wieder 0), darum 1,10 s Fenster ab dem Schuss-Stempel.
    local bolt_hide_win = false
    if BOLT_RIFLES[ewid] then
        local _st = tonumber(rawget(_G, "__re4_bolt_shoot_t"))
        bolt_hide_win = _st ~= nil and (os.clock() - _st) < 1.10
    end
    scope_hide_arms_tick(scope_aim and not bolt_cycle and not bolt_hide_win)
    -- [SCOPE_KILLSWITCH] Rechten Stick-Y (Pitch) nur im echten Scope freigeben.
    _G.__vr_unlock_ry = scope_aim and true or false
    -- [SCOPE_MONO 2026-08-15] Hier wurde kurzzeitig `set_mono_rendering_eye` gesetzt.
    -- WIEDER RAUS: das Auge war nie gesetzt (die alten Aufrufe `set_scope_mono`/
    -- `set_scope_mono_eye` gibt es im Fork gar nicht), alle Offsets sind also unter dem
    -- Fork-Default getunt -- und aktiv gesetzt ging es in beide Richtungen daneben.
    -- NICHT wieder anfassen, ohne dass die Offsets neu getunt werden.
    -- [SCOPE_AIM_PITCH] Waffen-Zielrichtungs-Pitch (Grad) publishen -> movement.lua laesst den
    -- eingefrorenen Blick diesem Pitch folgen, damit das Scope beim Stick-Hoch/Runter im Bild bleibt.
    if scope_aim then
        local ctx = get_player_ctx()
        local hu  = ctx and safe_call(ctx, "get_HeadUpdater")
        local gun = hu and safe_call(hu, "get_EquipWeapon")
        local go  = gun and safe_call(gun, "get_GameObject")
        local tf  = go and safe_call(go, "get_Transform")
        local rot = tf and safe_call(tf, "get_Rotation")
        if rot then
            local fy = nil
            pcall(function() local f = rot * Vector3f.new(0, 0, 1); fy = f.y end)
            if fy then
                if fy > 1 then fy = 1 elseif fy < -1 then fy = -1 end
                -- [BOLT_PITCH_FREEZE 2026-08-15, gemessen in data/re4_ada_hold.log] Nach dem
                -- Durchladen steht die Waffe REAL verkippt -- der Winkel sprang im Log von
                -- +17 auf +83 Grad. Diese Zeile misst das voellig korrekt, und genau deshalb
                -- reisst es Blick (movement.lua faehrt den rotation_offset 1:1 auf den Pitch)
                -- und Y-Ausgleich mit in die Wand. Der Befund ist alt: s. Notiz
                -- "[BOLT-VERSATZ 2026-08-09 -- VERWORFEN]" in re4_vr_movement.lua, wo damals
                -- schon stand "die Ursache ist die verkippte Waffe -- dort ansetzen".
                -- Also HIER ansetzen: im Bolt-Fenster den letzten guten Winkel STEHEN lassen,
                -- statt der kippenden Waffe zu folgen. Die Quelle bleibt die Waffe -- sie wird
                -- nur kurz nicht neu gelesen. Das ist ausdruecklich NICHT der 09.08. verworfene
                -- Weg (der nahm den KAMERA-Pitch als andere Quelle und lief "anders schief").
                -- Nur Repetierer, nur im Fenster, und nur wenn schon ein Wert dasteht --
                -- sonst bleibt alles exakt wie bisher.
                -- Dauer kommt aus dem Tree "RE4VR - Scope"; 0 = aus.
                local _hold = tonumber(rawget(_G, "__re4_bolt_pitch_hold")) or 0.0
                local _bt   = tonumber(rawget(_G, "__re4_bolt_shoot_t"))
                local _frozen = _hold > 0.0 and BOLT_RIFLES[ewid] and _bt
                                and (os.clock() - _bt) < _hold
                                and rawget(_G, "__re4_scope_aim_pitch") ~= nil
                if not _frozen then
                    _G.__re4_scope_aim_pitch = math.deg(math.asin(fy))
                end
            end
        end
        -- [SCOPE_BULLET] Kugel auf die SCOPE-KAMERA-Achse (= Crosshair-Mitte) umlenken statt Muendung.
        -- Crosshair.lua's Bullet-Hook nutzt vr_scope_aim_pos/dir wenn vr_scope_active -> NUR im Scope aktiv.
        local sctrl = gun and safe_call(gun, "get_ScopeController")
        local cam   = sctrl and safe_field(sctrl, "_CameraRef")        -- via.Camera (Scope-Optik)
        local cgo   = cam and safe_call(cam, "get_GameObject")
        local ctf   = cgo and safe_call(cgo, "get_Transform")
        local cpos  = ctf and safe_call(ctf, "get_Position")
        local crot  = ctf and safe_call(ctf, "get_Rotation")
        if cpos and crot then
            local cf = nil
            pcall(function() cf = crot * Vector3f.new(0, 0, SCOPE_BULLET_ZSIGN) end)   -- Scope-Kamera-Forward
            if cf then
                -- [SCOPE_BULLET] Yaw-Korrektur (Parallaxe vom Eye-X-Shift). Um die UP-Achse der SCOPE-KAMERA
                -- drehen (= lateral IM BILD) statt Welt-Y -> pitch-unabhaengig (auch beim Runterschauen korrekt).
                local byaw = tonumber(rawget(_G, "__re4_scope_bullet_yaw")) or 0.0
                if byaw ~= 0.0 then
                    local up = nil
                    pcall(function() up = crot * Vector3f.new(0, 1, 0) end)   -- Scope-Kamera-UP
                    if up then
                        local len = math.sqrt(up.x * up.x + up.y * up.y + up.z * up.z)
                        if len > 1e-6 then
                            local ux, uy, uz = up.x / len, up.y / len, up.z / len
                            local h = byaw * 0.5; local s = math.sin(h)
                            local yq = Quaternion.new(math.cos(h), ux * s, uy * s, uz * s)
                            local cf2 = nil
                            pcall(function() cf2 = (yq * cf) end)
                            if cf2 then cf = cf2 end
                        end
                    end
                end
                _G.vr_scope_active  = true
                _G.vr_scope_aim_pos = cpos
                _G.vr_scope_aim_dir = cf
            end
        end
    else
        _G.__re4_scope_aim_pitch = nil
        _G.vr_scope_active  = false
        _G.vr_scope_aim_pos = nil
        _G.vr_scope_aim_dir = nil
    end
end

------------------------------------------------------------
-- [SCOPE_PROTO] Machbarkeits-Test Weg A: im Scope das Waffen-Mesh (= traegt die RTT-Glas-
-- flaeche) skalieren + lokal versetzen, damit die Scope-Linse gross + bequem vor der
-- eingefrorenen Kamera sitzt. NUR das Anzeige-Mesh, NICHT die Kamera -> Fadenkreuz bleibt.
-- Waffen-GO sicher ueber die Gun holen (Scene-findGameObject ist unzuverlaessig).
------------------------------------------------------------
local SCOPE_PROTO_CFG = "re4_vr/re4_vr_scope_proto.json"
local scope_proto = { scale = 1.0, ox = 0.0, oy = 0.0, oz = 0.0 }
pcall(function()
    local d = json.load_file(SCOPE_PROTO_CFG)
    if type(d) == "table" then for k, v in pairs(scope_proto) do if type(d[k]) == "number" then scope_proto[k] = d[k] end end end
end)
local function save_scope_proto() pcall(function() json.dump_file(SCOPE_PROTO_CFG, scope_proto) end) end

local function scope_get_gun_go()
    local ctx = get_player_ctx(); if not ctx then return nil end
    local hu = safe_call(ctx, "get_HeadUpdater"); if not hu then return nil end
    local gun = safe_call(hu, "get_EquipWeapon"); if not gun then return nil end
    return safe_call(gun, "get_GameObject")
end

local function scope_proto_tick()
    if rawget(_G, "__re4_force_killswitch_scope") ~= true then return end
    if scope_proto.scale == 1.0 and scope_proto.ox == 0 and scope_proto.oy == 0 and scope_proto.oz == 0 then return end
    local go = scope_get_gun_go(); if not go then return end
    local tf = safe_call(go, "get_Transform"); if not tf then return end
    -- Skalierung (uniform) auf das Waffen-Mesh
    if scope_proto.scale ~= 1.0 then
        pcall(function() tf:call("set_LocalScale", Vector3f.new(scope_proto.scale, scope_proto.scale, scope_proto.scale)) end)
    end
    -- Lokaler Positions-Versatz (additiv auf die native Anim-Pose dieses Frames)
    if scope_proto.ox ~= 0 or scope_proto.oy ~= 0 or scope_proto.oz ~= 0 then
        local lp = safe_call(tf, "get_LocalPosition")
        if lp then
            pcall(function() tf:call("set_LocalPosition", Vector3f.new(lp.x + scope_proto.ox, lp.y + scope_proto.oy, lp.z + scope_proto.oz)) end)
        end
    end
end

-- [SCOPE_KILLSWITCH] (ENTFERNT) Waffenmesh wird im Scope NICHT mehr zwangs-sichtbar gehalten.
-- Das Spiel blendet Part 0 der Waffe im Scope selbst aus -> so gewuenscht (Gun-Body raus aus dem Bild).

local function set_mesh_enabled(go, enabled)
    if not go then return end
    if mesh_type then
        local m = safe_call1(go, "getComponent(System.Type)", mesh_type)
        if m then pcall(function() m:call("set_Enabled", enabled) end) end
    end
    local tf = safe_call(go, "get_Transform")
    if tf then
        local cnt = safe_call(tf, "get_ChildCount") or 0
        for i = 0, cnt - 1 do
            local ctf = safe_call1(tf, "get_Child", i)
            if ctf then
                local cgo = safe_call(ctf, "get_GameObject")
                if cgo then set_mesh_enabled(cgo, enabled) end
            end
        end
    end
end

------------------------------------------------------------
-- Hide body weapons: Messertasche + nicht-equippte wp*-Display-GOs
-- Die aktiv equippte Waffe (get_EquipWeaponID) wird NICHT angefasst.
------------------------------------------------------------
local function hide_body_weapons_tick()
    if not hide_body_cfg.enabled then return end
    local ctx = get_player_ctx()
    if not ctx then return end
    local body = safe_call(ctx, "get_BodyGameObject")
    local tf = body and safe_call(body, "get_Transform")
    if not tf then return end

    local cur_wid = get_equip_weapon_id()
    local cur = cur_wid and string.format("wp%04d", cur_wid) or nil
    -- [GO_SUFFIX 2026-07-19] Der GO der equippten Waffe heisst nicht immer exakt "wp####".
    -- Bei Ada haengen Punisher MC / Rocket Launcher als "wp6112_AO" / "wp6111_AO" am Body (ein
    -- plain "wp6112" existiert NIRGENDS in der Szene). Der exakte Vergleich `name ~= cur` hielt
    -- sie fuer eine FREMDE Waffe und hat der EQUIPPTEN Waffe DrawSelf=false verpasst -> unsichtbar
    -- in der Hand. Suffixe wie im alten Mod (SUFFIXES = { "", "_AO", "_MC" }).
    -- MAINGAME-SICHERHEIT: die Suffix-Variante zaehlt NUR, wenn es KEIN plain "wp####" am Koerper
    -- gibt. Existieren beide (plain + _AO-Schattenzwilling, wie es in der Maincampaign vorkommen
    -- kann), bleibt es exakt beim alten Verhalten -- plain ist die Waffe, der Zwilling wird wie
    -- bisher ausgeblendet. Nur im Ada-Fall (plain existiert nachweislich NICHT) greift der Suffix.
    local plain_exists = false
    if cur then
        local c0 = safe_call(tf, "get_Child")
        local n0 = 0
        while c0 and n0 < 64 do
            n0 = n0 + 1
            local g0 = safe_call(c0, "get_GameObject")
            local nm0 = g0 and safe_call(g0, "get_Name")
            if nm0 and tostring(nm0) == cur then plain_exists = true; break end
            c0 = safe_call(c0, "get_Next")
        end
    end
    local function is_current(nm)
        if not cur then return false end
        if nm == cur then return true end
        if plain_exists then return false end   -- altes Verhalten, Maingame unveraendert
        return nm == (cur .. "_AO") or nm == (cur .. "_MC")
    end

    local child = safe_call(tf, "get_Child")
    local n = 0
    while child and n < 64 do
        n = n + 1
        local go = safe_call(child, "get_GameObject")
        local name = go and safe_call(go, "get_Name")
        if name then
            name = tostring(name)
            -- ac0000_00 (Taschenlampe) NICHT mehr verstecken: motion.lua treibt
            -- sie an die linke Hand + steuert ihre Sichtbarkeit selbst (docked).
            local is_wp = name:sub(1, 2) == "wp"
            if is_wp and not is_current(name) then
                local vis = safe_call(go, "get_DrawSelf")
                if vis == true then
                    pcall(function() go:call("set_DrawSelf", false) end)
                end
            end
        end
        child = safe_call(child, "get_Next")
    end
end

------------------------------------------------------------
-- Knife Holster: KnifeCloseTimer auf 0 setzen
------------------------------------------------------------
local HEAD_UPDATER_LEON = "chainsaw.Ch0a0z0HeadUpdater"
local HEAD_UPDATER_ADA  = "chainsaw.Ch3a8z0HeadUpdater"

local knife_holster_state = {
    force_frames = 0,
    original_time_limit = nil,
}

local function get_head_updater()
    local ctx = get_player_ctx()
    if not ctx then return nil end
    local head = safe_call(ctx, "get_HeadGameObject")
    if not head then return nil end

    local updater = safe_call1(head, "getComponent(System.Type)",
                        sdk.typeof(HEAD_UPDATER_LEON))
    if not updater then
        updater = safe_call1(head, "getComponent(System.Type)",
                        sdk.typeof(HEAD_UPDATER_ADA))
    end
    return updater
end

local function get_knife_timer()
    local updater = get_head_updater()
    if not updater then return nil end
    return safe_field(updater, "<KnifeCloseTimer>k__BackingField")
end

local function holster_knife()
    local timer = get_knife_timer()
    if not timer then return false end

    if not knife_holster_state.original_time_limit then
        local orig = nil
        pcall(function() orig = timer._TimeLimit end)
        knife_holster_state.original_time_limit = orig or 5.0
    end

    knife_holster_state.force_frames = 30
    return true
end

local function update_knife_holster_timer()
    if knife_holster_state.force_frames <= 0 then return end

    local timer = get_knife_timer()
    if timer then
        pcall(function() timer._TimeLimit = 0.0 end)
    end

    knife_holster_state.force_frames = knife_holster_state.force_frames - 1

    if knife_holster_state.force_frames == 0 and knife_holster_state.original_time_limit then
        if timer then
            pcall(function()
                timer._TimeLimit = knife_holster_state.original_time_limit
            end)
        end
        knife_holster_state.original_time_limit = nil
    end
end

-- [KNIFE_KEEP_OUT] Auto-Holster verhindern: solange ein Messer equippt ist (und gerade KEIN Holster
-- erzwungen wird), den KnifeCloseTimer jeden Frame resetten -> er erreicht sein _TimeLimit nie, das
-- Spiel steckt das Messer nicht mehr von selbst weg. Gilt fuer ALLE Messer (KNIFE_IDS). Toggle.
local KNIFE_KEEP_OUT = true
-- [LOGGING RAUS 2026-07-17] kko_log + _kko_lastlog (re4_kko_diag.log) entfernt -- der Log hat seinen
-- Zweck erfuellt: er hat den KnifeCloseTimer als Ursache AUSGESCHLOSSEN (TransitTime 0.027 von
-- TimeLimit 5.0 im RPG-Moment) und damit den Weg zum echten Fix (requestChangeWeaponAction-Hook unten)
-- freigemacht.
local function keep_knife_out()
    if not KNIFE_KEEP_OUT then return end
    if knife_holster_state.force_frames > 0 then return end   -- gewollter Holster laeuft -> nicht stoeren
    -- [KS-LUECKE 2026-07-17, -Diagnose -- teuer bezahlt] Hier stand ein Ausstieg:
    -- local eid = get_equip_weapon_id
    -- if not (eid and KNIFE_IDS[eid]) then return end -- "kein Messer equippt"
    -- Genau der war der Bug. Im Killswitch/Stagger nimmt die ENGINE das Messer kurz weg -> eid = -1 ->
    -- KKO stieg aus -> der KnifeCloseTimer lief WAEHREND des KS ungebremst auf sein TimeLimit (5.0s).
    -- Danach holt der Auto-Redraw-Restore das Messer zurueck -- auf einen bereits abgelaufenen Timer ->
    -- die Engine steckt es sofort wieder weg und zieht die letzte HAUPTwaffe (RPG 4902).
    -- REPRO: mit Messer in den Killswitch, danach ein paar Sekunden warten -> RPG kommt.
    -- Der Timer wird jetzt IMMER zurueckgehalten. Ohne Messer in der Hand ist das ein No-op (der
    -- KnifeCloseTimer ist ausschliesslich fuer das Messer da) -> kein Risiko, aber die Luecke ist zu.
    -- NICHT wieder auf "nur wenn eid ein Messer ist" gaten.
    local timer = get_knife_timer()
    if timer then
        -- [KKO] Timer per Feld-Zugriff zurueckhalten. Der frueher hier stehende timer:call("reset") wurde
        -- entfernt: er braucht Argumente (Log-Flut "Invalid number of arguments") und ist redundant -> die
        -- beiden Feld-Zuweisungen halten den KnifeCloseTimer bereits unter seinem TimeLimit.
        pcall(function() timer._TransitTime = 0.0 end)
        pcall(function() timer._Completed = false end)
    end
end

-- [KNIFE_KEEP_OUT / ENGINE-WEGNAHME 2026-07-17] DER eigentliche Weg, auf dem das Spiel das Messer versteckt.
--
-- BEWEIS (re4_equip_trace.log, Game-Neustart 10:49, -Repro "mit Messer in den Killswitch, dann warten"):
-- 10:49:09 requestEquipKnife / execChangeWeapon -> Restore holt das Messer korrekt zurueck (wid 5001)
-- 10:49:16 requestChangeActiveWeapon + requestChangeWeaponAction + execChangeWeapon -> Messer weg, RPG da
-- Der hat dazwischen NICHTS gedrueckt. requestChangeWeaponAction ruft KEIN Script von uns (steht bei uns
-- nur in einem Kommentar) -> das ist die ENGINE. Zum Vergleich derselbe Trace beim EIGENEN Messer-Zug
-- (10:49:02): requestEquipKnife -> execChangeWeapon, KEIN requestChangeWeaponAction. Der Call taucht
-- ausschliesslich beim ungewollten Wechsel auf -> er laesst sich gefahrlos genau dort blocken.
--
-- WARUM NICHT der KnifeCloseTimer: der ist live ausgeschlossen -- im RPG-Moment stand er bei
-- TransitTime=0.027 von TimeLimit=5.0 (kko_diag 10:44:41). Die Engine hat also einen ZWEITEN Weg, das
-- Messer wegzunehmen, und der laeuft am Timer vorbei. Genau den schliesst dieser Hook.
--
-- GUARDS (damit nichts anderes kaputtgeht):
-- * nur wenn wirklich ein Messer in der Hand ist (KNIFE_IDS)
-- * nur bei KNIFE_KEEP_OUT (Toggle bleibt wirksam)
-- * NICHT waehrend eines gewollten Holsters (force_frames -> holster_knife bleibt unberuehrt)
-- * NUR im Gameplay (__re4_frame_is_gameplay): im Inventar/Menue nutzt die Engine denselben Call fuer den
-- normalen Waffenwechsel -- dort NICHT blocken, sonst koennte man mit Messer in der Hand nicht mehr
-- ueber das Inventar wechseln.
-- Unsere eigenen Wechsel laufen ueber requestEquipKnife/requestEquipGun/requestChangeActiveWeapon -> unberuehrt.
-- sdk.hook -> GAME-NEUSTART noetig (Reset Scripts reicht NICHT).
if not _G.__re4_knife_change_block_hooked then
    _G.__re4_knife_change_block_hooked = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        local m  = td and td:get_method("requestChangeWeaponAction")
        if not m then return end   -- Methode nicht gefunden -> Hook entfaellt still (kein Log mehr, s.o.)
        sdk.hook(m,
            function(args)
                local skip = false
                pcall(function()
                    if not KNIFE_KEEP_OUT then return end
                    if knife_holster_state.force_frames > 0 then return end      -- gewollter Holster laeuft
                    if rawget(_G, "__re4_frame_is_gameplay") ~= true then return end   -- Menue/Inventar: nie blocken
                    -- [EIGENER WECHSEL 2026-07-17] DU hast gerade selbst gezogen/gestaut (Holster-Grab oder
                    -- Auto-Redraw-Restore, beide setzen __re4_our_equip_until in holster.lua) -> NIE blocken.
                    -- WARUM NOETIG: unser draw_last_pistol/rifle/grenade ruft requestChangeActiveWeapon, und die
                    -- Engine ruft daraufhin INTERN dieses requestChangeWeaponAction. Ohne diesen Guard blockte
                    -- der Hook den EIGENEN Holster-Zug, solange noch ein Messer in der Hand war -> es liess sich
                    -- KEINE Waffe mehr aus dem Holster ziehen (live 2026-07-17). Nur die Wegnahme durch die
                    -- Engine OHNE dein Zutun soll hier sterben.
                    local u = tonumber(rawget(_G, "__re4_our_equip_until"))
                    if u and os.clock() < u then return end
                    local eid = get_equip_weapon_id()
                    if eid and KNIFE_IDS[eid] then skip = true end   -- Messer in der Hand -> Engine-Wegnahme verwerfen
                end)
                if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
end

-- =====================================================================
-- [QUICK-KNIFE 2026-08-18] Das Messer kommt beim Feuern, ohne dass wir es wollen.
--
-- WOHER: Der rohe rechte Trigger geht an zwei Stellen bewusst OHNE Aim-Pruefung an die Engine --
-- re4_vr_binding.lua:1478 (Grapple) und :1497 (Battle-State), beide als LETZTE Zeile vor dem Versand,
-- also staerker als jede Branch-Sperre. Das ist gewollt: ohne sie kann man sich im Grab nicht wehren
-- und im Kampf nicht feuern. Die Engine macht aus einem RT ohne Aim aber ihren nativen QUICK-KNIFE
-- und equippt dafuer das Messer.
--
-- WARUM NICHT AM TRIGGER: Wir feuern NICHT selbst -- `execFire` laeuft nativ (ein PRE-Hook darauf ist
-- wirkungslos, s. re4_vr_binding.lua:3034: BulletShellGenerator.requestFire kommt eine Millisekunde
-- frueher). RT muss also durchgehen. Genau deshalb wurden am 21.07. schon zwei Trigger-Guards wieder
-- ausgebaut -- sie kosteten Nahkampf-Prompt und Dry-Fire. Der Code haelt dort auch fest, wo es
-- stattdessen hingehoert: "dort unterbunden, wo es entsteht" -- am Messer-Equip.
--
-- WAS HIER PASSIERT: Der native `requestEquipKnife` wird genau dann verworfen, wenn er die Signatur
-- des Quick-Knife hat:
--   * roher RT gedrueckt UND nicht gezielt (mit Aim ist RT ein Schuss, kein Quick-Knife)
--   * reines Gameplay (Menue, Cutscene, Killswitch bleiben unberuehrt)
--   * KEIN Finisher-/Nahkampf-Prompt offen (dort ist RT die gewollte Aktion, das Messer soll kommen)
--   * kein eigener Wechsel (`__re4_our_equip_until` -- das Holster setzt es bei JEDEM eigenen Zug,
--     also bleiben Messer-Grab, Auto-Redraw und der Links-Klon-Restore unberuehrt)
-- Alles andere -- Parry (linker Grip), QTEs, Inventar, Cutscenes, unser Holster-Zug -- laeuft
-- unveraendert weiter.
--
-- NOT-AUS: `_G.__re4_qk_block = false`      -> Hook untaetig, natives Verhalten wie vorher
-- DIAGNOSE: `_G.__re4_qk_blocked`           -> Zaehler; bleibt 0, wenn er nie greift
-- ACHTUNG: sdk.hook -> erst nach GAME-NEUSTART aktiv, "Reset Scripts" genuegt NICHT.
-- =====================================================================
if not _G.__re4_quickknife_hooked then
    _G.__re4_quickknife_hooked = true
    _G.__re4_qk_block = true
    _G.__re4_qk_blocked = 0
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        local m  = td and td:get_method("requestEquipKnife")
        if not m then return end   -- Methode nicht gefunden -> Block entfaellt still

        sdk.hook(m,
            function(args)
                local skip = false
                pcall(function()
                    if rawget(_G, "__re4_qk_block") ~= true then return end

                    -- [KS-GATE 2026-08-18 -- aus dem Watcher-Log] Hier stand `if
                    -- __re4_frame_is_gameplay ~= true then return end`. Genau daran ist der Block
                    -- seit dem 17.07. WIRKUNGSLOS gewesen: jeder mitgeschnittene native
                    -- requestEquipKnife (11:05:40, 11:06:26, 11:06:36 ...) trug
                    -- `RT=1 aim=0 gameplay=0(killswitch)` -- der Quick-Knife entsteht also
                    -- AUSSCHLIESSLICH im Killswitch, und dort stieg der Block in der ersten Zeile
                    -- aus. `__re4_qk_blocked` stand ueber die ganze Sitzung auf 0.
                    --
                    -- Neu: der Killswitch allein ist kein Ausschlussgrund mehr. Ausgenommen bleiben
                    -- nur die Zustaende, in denen das Messer die GEWOLLTE Aktion ist:
                    --   * Grapple (Hund/Ganado haelt fest -- dort wehrt man sich mit dem Messer),
                    --     erkannt am Killswitch-Grund (`ks2_grappled`, `ks4_grappled`, ...),
                    --   * Finisher-/Nahkampf-Prompt (Pruefung steht unveraendert weiter unten),
                    --   * eigener Wechsel (`__re4_our_equip_until`, ebenfalls unten).
                    -- Menue, Boot, Fernglas, Throwsight bleiben komplett unberuehrt: dort gehoert
                    -- RT anderen Funktionen, deshalb wird nur im Gameplay ODER im Killswitch geprueft.
                    -- NOT-AUS unveraendert: `_G.__re4_qk_block = false`.
                    -- Diagnose: `__re4_qk_blocked` (Zaehler) und `__re4_qk_last` (was zuletzt blockte).
                    local gameplay = rawget(_G, "__re4_frame_is_gameplay") == true
                    local why      = rawget(_G, "__re4_gameplay_why")
                    if not gameplay and why ~= "killswitch" then return end

                    local ks_reason = nil
                    if not gameplay and killswitch and type(killswitch.get_activating_controller) == "function" then
                        pcall(function() ks_reason = killswitch.get_activating_controller() end)
                    end
                    if type(ks_reason) == "string" and ks_reason:lower():find("grappl") then return end

                    -- Eigener Wechsel? Dann nie blocken.
                    local u = tonumber(rawget(_G, "__re4_our_equip_until"))
                    if u and os.clock() < u then return end

                    -- Die Quick-Knife-Signatur: Trigger gezogen, aber nicht gezielt.
                    if rawget(_G, "__vr_raw_r_trigger") ~= true then return end
                    if rawget(_G, "__vr_aim_input") == true then return end

                    -- Nahkampf-/Finisher-Prompt offen -> RT ist dort die gewollte Aktion.
                    local fp = rawget(_G, "__re4_is_finisher_prompt")
                    if type(fp) == "function" and fp() == true then return end

                    skip = true
                    _G.__re4_qk_blocked = (tonumber(rawget(_G, "__re4_qk_blocked")) or 0) + 1
                    _G.__re4_qk_last = string.format("%s/%s", gameplay and "gameplay" or "ks",
                        tostring(ks_reason or "-"))
                end)
                if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end)
end

-- =====================================================================
-- [STOW-GUARD 2026-08-18] Wegstecken ist eine ENTSCHEIDUNG DES SPIELERS
-- =====================================================================
-- GEMESSEN (Watcher-Log 13:39:06, ohne Rate-Limit): Steckt der Spieler das Messer weg, laeuft
-- unsere Kette sauber durch --
--   clearRequest / requestEquipBareHand / requestChangeWeaponAction / execChangeWeapon / equipWeapon,
--   alle mit unserem Lua-Frame, und das Messer geht auch WEG (C! WECHSEL wp5001_MC -> keine).
-- Drei Millisekunden spaeter kommt dieselbe Kette noch einmal, diesmal OHNE jeden Lua-Frame:
--   requestChangeActiveWeapon NATIV -> requestChangeWeaponAction NATIV -> execChangeWeapon NATIV
-- und das Messer ist zurueck (C! WECHSEL keine -> wp5001_MC). `requestLastEquipWeapon` ist es NICHT,
-- der taucht kein einziges Mal auf.
--
-- Dieser Block verwirft genau diese beiden nativen Aufrufe -- und NUR sie:
--   * nur im Zeitfenster `__re4_stow_guard_until` (0.5 s, gesetzt beim bewussten Wegstecken in
--     re4_vr_holster.lua),
--   * nur wenn `__re4_stow_ours` false ist, also NACH unserer eigenen Kette,
--   * fuer alle Charaktere, auch in Mercs -- die Entscheidung des Spielers gilt ueberall.
-- Alles ausserhalb dieses Fensters (normaler Waffenwechsel, DPad, Holster-Zug, Engine-Entzug im
-- Killswitch) laeuft voellig unveraendert weiter.
--
-- WICHTIG bei SKIP_ORIGINAL: requestChangeWeaponAction gibt Boolean zurueck, requestChangeActiveWeapon
-- ist void. Ein geskippter Call ohne gesetzten Rueckgabewert hinterlaesst Registermuell -- deshalb
-- gibt der Post-Hook fuer die Boolean-Variante ausdruecklich 0 (= false) zurueck.
-- NOT-AUS:  `_G.__re4_stow_block = false`
-- DIAGNOSE: `_G.__re4_stow_blocked` (Zaehler; bleibt 0, wenn er nie greift)
-- ACHTUNG: sdk.hook -> nach "Reset Scripts" wird neu registriert, ein Spiel-Neustart ist NICHT noetig.
-- =====================================================================
if not _G.__re4_stow_guard_hooked then
    _G.__re4_stow_guard_hooked = true
    _G.__re4_stow_block   = true
    _G.__re4_stow_blocked = 0
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        if not td then return end

        local function haenge(name, ist_bool)
            local m = td:get_method(name)
            if not m then return end
            local geskippt = false
            sdk.hook(m,
                function(args)
                    geskippt = false
                    pcall(function()
                        if rawget(_G, "__re4_stow_block") ~= true then return end
                        local o = tonumber(rawget(_G, "__re4_stow_ours_until"))
                        if o and os.clock() < o then return end   -- unsere eigene Kette (laeuft aus)
                        local u = tonumber(rawget(_G, "__re4_stow_guard_until"))
                        if not (u and os.clock() < u) then return end
                        geskippt = true
                        _G.__re4_stow_blocked = (tonumber(rawget(_G, "__re4_stow_blocked")) or 0) + 1
                    end)
                    if geskippt then return sdk.PreHookResult.SKIP_ORIGINAL end
                    return sdk.PreHookResult.CALL_ORIGINAL
                end,
                function(retval)
                    if geskippt then
                        geskippt = false
                        if ist_bool then return sdk.to_ptr(0) end   -- false statt Registermuell
                    end
                    return retval
                end)
        end

        haenge("requestChangeActiveWeapon", false)
        haenge("requestChangeWeaponAction", true)
    end)
end

-- =====================================================================
-- [QUICK-KNIFE 2. WEG 2026-08-18] Die Engine equippt das Messer auch OHNE requestEquipKnife
-- =====================================================================
-- GEMESSEN (Watcher-Log 15:10:55): das Messer kam bei
--     execChangeWeapon NATIV -> equipWeapon NATIV -> C! WECHSEL keine -> wp5000_MC
--     RT=1  aim=0  gameplay=0(killswitch)
-- Also exakt die Quick-Knife-Signatur (roher Trigger, kein Aim) -- aber OHNE einen einzigen
-- `requestEquipKnife`. Der bestehende Block hing ausschliesslich an dieser Methode und konnte
-- deshalb gar nicht greifen. Hier wird derselbe Fall an `equipWeapon` abgefangen, wo er wirklich
-- passiert: Argument 2 ist die WeaponID -- ist sie ein Messer und liegt die Quick-Knife-Signatur
-- vor, wird der Call verworfen.
-- Bedingungen (identisch zum requestEquipKnife-Block, damit sich beide gleich verhalten):
--   * `__re4_qk_block` an, roher RT gedrueckt, NICHT gezielt
--   * kein eigener Wechsel (`__re4_our_equip_until` -- Holster-Zug, DPad, Auto-Redraw bleiben frei)
--   * kein Finisher-/Nahkampf-Prompt (dort ist das Messer die gewollte Aktion)
--   * im Killswitch nur, wenn es KEIN Grapple ist (dort wehrt man sich mit dem Messer)
-- DIAGNOSE: `_G.__re4_qk_equip_blocked` (Zaehler)   NOT-AUS: `_G.__re4_qk_block = false`
-- =====================================================================
if not _G.__re4_qk_equip_hooked then
    _G.__re4_qk_equip_hooked = true
    _G.__re4_qk_equip_blocked = 0
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.PlayerEquipment")
        local m  = td and td:get_method("equipWeapon")
        if not m then return end

        local geskippt = false
        sdk.hook(m,
            function(args)
                geskippt = false
                pcall(function()
                    if rawget(_G, "__re4_qk_block") ~= true then return end

                    -- Argument 2 = WeaponID (args[1] = Kontext, args[2] = this, args[3] = EquipType)
                    local wid = nil
                    pcall(function() wid = sdk.to_int64(args[4]) & 0xFFFFFFFF end)
                    if not (wid and KNIFE_IDS[wid]) then return end

                    -- Eigener Wechsel? Dann nie blocken.
                    local u = tonumber(rawget(_G, "__re4_our_equip_until"))
                    if u and os.clock() < u then return end

                    -- Die Quick-Knife-Signatur: Trigger gezogen, aber nicht gezielt.
                    if rawget(_G, "__vr_raw_r_trigger") ~= true then return end
                    if rawget(_G, "__vr_aim_input") == true then return end

                    -- Nahkampf-/Finisher-Prompt -> Messer ist gewollt.
                    local fp = rawget(_G, "__re4_is_finisher_prompt")
                    if type(fp) == "function" and fp() == true then return end

                    -- Im Killswitch nur blocken, wenn es kein Grapple ist (dort ist das Messer die Wehr).
                    if rawget(_G, "__re4_frame_is_gameplay") ~= true then
                        local why = rawget(_G, "__re4_gameplay_why")
                        if why ~= "killswitch" then return end
                        local reason = nil
                        if killswitch and type(killswitch.get_activating_controller) == "function" then
                            pcall(function() reason = killswitch.get_activating_controller() end)
                        end
                        if type(reason) == "string" and reason:lower():find("grappl") then return end
                    end

                    geskippt = true
                    _G.__re4_qk_equip_blocked = (tonumber(rawget(_G, "__re4_qk_equip_blocked")) or 0) + 1
                end)
                if geskippt then return sdk.PreHookResult.SKIP_ORIGINAL end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) geskippt = false; return retval end)
    end)
end

------------------------------------------------------------
-- Assist Light (body child "assist_Light")
------------------------------------------------------------
local function get_body_gameobject_addr(ctx)
    local bg = safe_call(ctx, "get_BodyGameObject")
    if not bg then return nil end
    local addr = nil
    pcall(function() addr = bg:get_address() end)
    return addr, bg
end

--- Returns assist_Light GameObject and Transform, with cache keyed to player body address.
local function get_assist_light_go_tf()
    local ctx = get_player_ctx()
    if not ctx then return nil, nil end

    local body_addr, bg = get_body_gameobject_addr(ctx)
    if not body_addr or not bg then return nil, nil end

    if assist_light_cache.body_addr == body_addr and assist_light_cache.tf then
        local go_cached = safe_call(assist_light_cache.tf, "get_GameObject")
        if go_cached then
            assist_light_cache.go = go_cached
            return go_cached, assist_light_cache.tf
        end
    end

    assist_light_cache.body_addr = body_addr
    assist_light_cache.go = nil
    assist_light_cache.tf = nil

    local tf = safe_call(bg, "get_Transform")
    if not tf then return nil, nil end

    local child = safe_call(tf, "get_Child")
    while child do
        local cgo = safe_call(child, "get_GameObject")
        if cgo then
            local name = safe_call(cgo, "get_Name")
            if name == "assist_Light" then
                local alf_tf = safe_call(cgo, "get_Transform")
                assist_light_cache.go = cgo
                assist_light_cache.tf = alf_tf
                return cgo, alf_tf
            end
        end
        child = safe_call(child, "get_Next")
    end
    return nil, nil
end

local function hide_assist_light()
    if not hide_assist_light_enabled then return end

    local cgo, _ = get_assist_light_go_tf()
    if not cgo then return end
    pcall(function() cgo:call("set_DrawSelf", false) end)
    pcall(function() cgo:call("set_UpdateSelf", false) end)
    set_mesh_enabled(cgo, false)
end

-- Match re4_vr_motion docked flashlight: world view rot = game yaw baseline (right stick) * raw HMD quat.
-- camera_rot_full alone is only headset in VR space and lags body / stick yaw.
local function compute_assist_light_world_rotation(cam_fix)
    if not cam_fix.camera_rot then
        return cam_fix.camera_rot_full
    end
    local rot0 = nil
    pcall(function() rot0 = vrmod:get_rotation(0) end)
    if not rot0 then
        return cam_fix.camera_rot_full
    end
    local hmd_quat = nil
    pcall(function() hmd_quat = rot0:to_quat() end)
    if not hmd_quat then
        return cam_fix.camera_rot_full
    end
    local world = nil
    pcall(function()
        world = (cam_fix.camera_rot * hmd_quat):normalized()
    end)
    return world or cam_fix.camera_rot_full
end

local function sync_assist_light_rotation_to_vr_cam()
    if not assist_light_follow_vr_cam_enabled then return end
    if hide_assist_light_enabled then return end
    if killswitch.is_active() then return end
    if is_any_menu_open() then return end

    if not vrmod then return end
    local ok_h, hmd_on = pcall(function() return vrmod:is_hmd_active() end)
    if not ok_h or hmd_on ~= true then return end

    local cam_fix = rawget(_G, "vr_camera_fix")
    if not cam_fix or cam_fix.active ~= true or not cam_fix.camera_rot_full then return end

    local _, alf_tf = get_assist_light_go_tf()
    if not alf_tf then return end

    local world_rot = compute_assist_light_world_rotation(cam_fix)
    if not world_rot then return end

    pcall(function() alf_tf:call("set_Rotation", world_rot) end)
end

------------------------------------------------------------
-- [SNAPPY_WEP] Schneller Waffenwechsel (VR Skip Motion / SnappyControls)
-- Portiert aus dem alten re4_vr_motion.lua. KEINE Waffen-Logik: es editiert den
-- Animations-Tree. MotionFsm2 Layer 4 -> Node "wp4000H_0551_put_away" -> action[4]:
-- _StartFrame auf <frameskip> (statt 0) + _OverwriteInterpolation=true laesst die
-- Wegsteck-/Zieh-Animation direkt nach vorn springen -> Waffenwechsel quasi sofort.
-- Re-Apply bei Body-Wechsel (Save/Load/Tod) via Adress-Vergleich.
------------------------------------------------------------
local SNAPPY_CFG_PATH = "re4_vr/re4_vr_snappy.json"
local snappy_wep = { enabled = true, frameskip = 35.0, fast_re_aim = true, direct_snap = true }
local function save_snappy_cfg() pcall(function() json.dump_file(SNAPPY_CFG_PATH, snappy_wep) end) end
pcall(function()
    local d = json.load_file(SNAPPY_CFG_PATH)
    if type(d) == "table" then
        if d.enabled ~= nil then snappy_wep.enabled = d.enabled == true end
        if type(d.frameskip) == "number" then snappy_wep.frameskip = d.frameskip end
        if d.fast_re_aim ~= nil then snappy_wep.fast_re_aim = d.fast_re_aim == true end
        if d.direct_snap ~= nil then snappy_wep.direct_snap = d.direct_snap == true end
    end
end)
local snappy_applied = false
local snappy_last_body = nil

local function get_mfsm2()
    local ctx = get_player_ctx()
    if not ctx then return nil end
    local bu = safe_field(ctx, "_BodyUpdater")
    if not bu then return nil end
    return safe_field(bu, "<MotionFsm>k__BackingField")
end

-- Setzt BEIDE Snappy-Features auf ihren Soll-Zustand (Layer 4):
-- * Schneller Waffenwechsel: wp4000H_0551_put_away action[4] _StartFrame/_Overwrite.
-- * Fast Re-Aim: HOLD_END action[4] set_Enabled(false) (Inhibit-Hold deaktivieren).
-- revert_all=true -> beide auf Original zurueck (fuer Script-Reset).
-- Gibt true zurueck sobald der Tree erreichbar ist (= angewandt, FSM bereit).
local function apply_snappy(revert_all)
    local mfsm2 = get_mfsm2()
    if not mfsm2 then return false end
    local done = false
    pcall(function()
        local layer4 = mfsm2:call("getLayer", 4)
        if not layer4 then return end
        local tree = layer4:get_tree_object()
        if not tree then return end
        done = true   -- FSM bereit (Developer gated nur auf layer4)

        -- Schneller Waffenwechsel
        local put_away = tree:get_node_by_name("wp4000H_0551_put_away")
        if put_away then
            local actions = put_away:get_actions()
            if actions and actions[4] then
                local on = (not revert_all) and snappy_wep.enabled
                local sf = 0.0
                if on then
                    if snappy_wep.direct_snap then
                        -- Direkt-Snap: StartFrame ans Anim-Ende -> instant. _EndFrame
                        -- wenn vorhanden, sonst hoher Wert (Engine clamped auf Ende).
                        local okE, ef = pcall(function() return actions[4]._EndFrame end)
                        sf = (okE and type(ef) == "number" and ef > 1) and ef or 9999.0
                    else
                        sf = snappy_wep.frameskip
                    end
                end
                actions[4]._StartFrame = sf
                actions[4]._OverwriteInterpolation = on and true or false
            end
        end

        -- Fast Re-Aim: Inhibit-Hold-Action an HOLD_END
        local h_end = tree:get_node_by_name("HOLD_END")
        if h_end then
            local acts = h_end:get_actions()
            local inhibit = acts and acts[4]
            if not inhibit then
                local un = h_end:get_unloaded_actions()
                inhibit = un and un[4]
            end
            if inhibit then
                local on = (not revert_all) and snappy_wep.fast_re_aim
                pcall(function() inhibit:call("set_Enabled", not on) end)  -- enabled=AN heisst Feature AUS
            end
        end
    end)
    return done
end

local function snappy_wep_tick()
    -- [WSW_PIN] motion.lua pinnt Hand+Waffe waehrend des Wechsels, wenn dieses Flag
    -- gesetzt ist -> keine sichtbare native Draw/Holster-Anim (an Direkt-Snap gekoppelt).
    _G.__vr_wsw_pin = (snappy_wep.enabled and snappy_wep.direct_snap) == true
    local ctx = get_player_ctx()
    local body = ctx and safe_call(ctx, "get_BodyGameObject")
    local addr = nil
    if body then pcall(function() addr = body:get_address() end) end
    if addr ~= snappy_last_body then
        snappy_last_body = addr
        snappy_applied = false           -- frischer Body -> Tree neu -> re-apply
    end
    if not snappy_applied then
        if apply_snappy(false) then snappy_applied = true end
    end
end

------------------------------------------------------------
-- [WEAPON_SWITCH_SKIP] Waffenwechsel-Anim komplett skippen (ALLE Waffen).
-- Layer 4 faehrt den Wechsel als generischen State "ChangeWeapon" (put_away =
-- Holster + ch0_541_PUT_OUT = Draw). Solange L4 darin ist, springt der Motion-
-- Layer 4 ans Anim-Ende -> beide Sub-Anims kollabieren auf ~1 Frame = echter Snap,
-- waffenunabhaengig. End-Frame minus Rest, damit die Equip-Notifies noch feuern.
-- (set_Frame ist die bewaehrte anim_freeze-Methode; getCurrentNodeName via der
-- MotionFsm2-KOMPONENTE, nicht der BodyUpdater-FSM.)
------------------------------------------------------------
local WSW_FSM_TD = sdk.typeof("via.motion.MotionFsm2")
local WSW_MOT_TD = sdk.typeof("via.motion.Motion")
local WSW_LAYER = 4
local wsw_cache = { body = nil, fsm = nil, motion = nil }

local function wsw_get_comps()
    local ctx = get_player_ctx()
    local body = ctx and safe_call(ctx, "get_BodyGameObject")
    if not body then wsw_cache.body, wsw_cache.fsm, wsw_cache.motion = nil, nil, nil; return nil, nil end
    if body ~= wsw_cache.body then
        wsw_cache.body = body
        wsw_cache.fsm = safe_call1(body, "getComponent(System.Type)", WSW_FSM_TD)
        wsw_cache.motion = safe_call1(body, "getComponent(System.Type)", WSW_MOT_TD)
    end
    return wsw_cache.fsm, wsw_cache.motion
end

local function weapon_switch_skip_tick()
    if not (snappy_wep.enabled and snappy_wep.direct_snap) then return end
    local fsm, motion = wsw_get_comps()
    if not fsm or not motion then return end
    local node = nil
    pcall(function() node = fsm:call("getCurrentNodeName", WSW_LAYER) end)
    if not node then return end
    if not tostring(node):find("ChangeWeapon", 1, true) then return end
    local layer = safe_call1(motion, "getLayer", WSW_LAYER)
    if not layer then return end
    -- 1) Transition-Pose unsichtbar machen (kein 1-Frame-Flash): Blendgewicht 0.
    pcall(function() layer:call("set_BlendRate", 0.0) end)
    pcall(function() layer:call("set_Weight", 0.0) end)
    -- 2) Trotzdem ans Ende fahren -> FSM transitioniert weiter, Equip-Events feuern.
    local ef = safe_call(layer, "get_EndFrame") or 0
    if ef > 1 then
        pcall(function() layer:call("set_Frame", ef - 0.5) end)
    end
end

------------------------------------------------------------
-- REFramework UI Toggle
------------------------------------------------------------
-- =====================================================================
-- [PUBLIC-UI 2026-07-23] Ohne Tree im nackten Hauptmenue (Platz 60 im Dispatcher
-- #re4_vr_menu.lua): derselbe Schalter wie "Hide Assist Light" im Dev-Tree, nur unter dem
-- Public-Namen "Disable Assist Light" -- geschrieben wird dieselbe Variable
-- `hide_assist_light_enabled`. Hinweis: die wird nirgends gespeichert (auch im Dev-Tree nicht),
-- steht nach einem Spielstart also wieder auf AUS.
-- Beim Release fliegen alle [DEV-UI]-Bloecke raus, dieser bleibt.
-- =====================================================================
do
    local draw = function()
        local c, v = imgui.checkbox("Disable Assist Light", hide_assist_light_enabled)
        if c then hide_assist_light_enabled = v end
    end
    local add = rawget(_G, "__re4_ui_add")
    if type(add) == "function" then add(60, "assist_light", draw) else re.on_draw_ui(draw) end
end

-- [DEV-UI] Voller Weapons-Tree -- beim Public-Release entfaellt dieser Block.
-- [DEV-UI ENTFERNT 2026-08-19, Public Release] ImGui-Tree "RE4VR - Weapons" raus (86 Zeilen). Nur die Oberflaeche: Funktionen, Settings und JSON bleiben unveraendert.

------------------------------------------------------------
-- LockScene: hide pass after game logic (Engine re-enabled DrawSelf)
------------------------------------------------------------
re.on_pre_application_entry("LockScene", hide_body_weapons_tick)
-- [SCOPE_PROTO] Waffen-Mesh im Scope skalieren/versetzen (Machbarkeits-Test Weg A)
re.on_pre_application_entry("LockScene", function() pcall(scope_proto_tick) end)
-- [IRON_SIGHT_NATIVE] Iron-Sight der 3 Rifles: Body/Mesh/Parent NACH dem Game-Hiding forcen.
re.on_pre_application_entry("LockScene", function()
    if _iron_active_wid then pcall(function() iron_sight_tick(_iron_active_wid) end) end
    -- [SCOPE_PARENT 2026-08-15, GEMESSEN in data/re4_ada_hold.log] Beim Zielen durch ein
    -- montiertes Scope stand dort ueber den GANZEN Vorgang `par=NEIN`: Adas Waffe (wp6114_AO)
    -- hing an KEINEM Parent. Sichtbar als frei vor dem Spieler schwebende Waffe, und weil
    -- `__re4_scope_aim_pitch` aus genau deren Rotation kommt, nimmt sie Blick und
    -- Y-Ausgleich mit.
    -- Der Scope-Zweig haengt die Waffe bewusst NICHT zurueck (s. `_iron_active_wid`: dort
    -- soll das Spiel sie behalten) -- bei Leon behaelt das Spiel sie auch, bei Ada nicht.
    -- Darum hier dieselbe eine Zeile wie im Iron-Sight-Paket, aber OHNE dessen zwei andere
    -- Teile: kein Body-Einblenden, kein Mesh-Forcen -- die wuerden im Okular den Koerper
    -- ins Bild holen.
    -- FUER LEON GEFAHRLOS: `iron_ensure_parented` steigt sofort aus, wenn der Parent noch
    -- sitzt -- dann kostet es nur einen Lookup und aendert nichts.
    -- RUECKBAU: `_G.__re4_scope_keep_parent = false`.
end)

-- [SCOPE_KILLSWITCH] Force-Flag jeden Frame frisch setzen (auf UpdateScene, dort wertet auch der
-- Killswitch aus). Laeuft unabhaengig vom Killswitch weiter -> Scope-Austritt wird sicher erkannt.
re.on_pre_application_entry("UpdateScene", function() pcall(scope_killswitch_tick) end)

-- After behavior / motion so body-driven assist rotation does not overwrite HMD alignment.
re.on_application_entry("LateUpdateBehavior", function()
    sync_assist_light_rotation_to_vr_cam()
    snappy_wep_tick()
    weapon_switch_skip_tick()
end)

-- [WEAPON_SWITCH_SKIP] Blend-0 + Frame-Ende in allen Pre-Render-Pässen erzwingen,
-- damit auch der EINTRITTS-Frame der Transition nie sichtbar wird (kein Flackern).
re.on_application_entry("UpdateMotion", function() pcall(weapon_switch_skip_tick) end)
re.on_application_entry("UpdateJointExpression", function() pcall(weapon_switch_skip_tick) end)
re.on_pre_application_entry("BeginRendering", function() pcall(weapon_switch_skip_tick) end)

------------------------------------------------------------
-- [KNIFE_MELEE] VR-Messer-Schwung -> requestAttack auf naechstes Ziel.
-- Weg B: native Messer-Kollision laeuft ueber ein motion-getriebenes System,
-- das wir nicht togglen koennen -> wir replizieren den Schadens-Call.
-- AttackUserData/DamageUserData kommen aus echten nativen Messer-Treffern
-- (poolDamage liefert sie, callbackAttackHit korreliert auf das Messer).
-- Trigger: vr_knife_swing (Velocity-Flanke aus re4_vr_motion).
------------------------------------------------------------
local function safe_mo(ptr)
    if not ptr then return nil end
    local ok, o = pcall(sdk.to_managed_object, ptr)
    return ok and o or nil
end

local hitmgr = nil
local function get_hc(go)
    if not hitmgr then hitmgr = sdk.get_managed_singleton("chainsaw.HitManager") end
    if not hitmgr or not go then return nil end
    return safe_call1(hitmgr, "getHitController", go)
end

local function weapon_id_num(hc)
    local w = safe_call(hc, "get_WeaponID")
    if w == nil then return nil end
    if type(w) == "number" then return w end
    local v = safe_field(w, "value__")
    if type(v) == "number" then return v end
    return tonumber(tostring(w))
end

-- Messer-HC ueber den Player-Body finden (GO-Name wpXXXX, gefiltert gegen KNIFE_IDS), gecacht
local knife_hc_cache = nil
local function find_wp_hc(tf, depth, want_id, allow_holstered)
    if not tf or depth > 12 then return nil end
    local child = safe_call(tf, "get_Child")
    local guard = 0
    while child and guard < 400 do
        guard = guard + 1
        local go = safe_call(child, "get_GameObject")
        local name = go and safe_call(go, "get_Name")
        if name then
            local s = tostring(name)
            -- Bewaehrter Namensfilter (wie urspruenglich) + die zwei neuen Messer explizit. Deckt alle
            -- Messer ab: wp5000-5006 (^wp5), wp6107/6108 (SW), wp6305 (Hot Dogger).
            if s:find("^wp5") or s:find("^wp6107") or s:find("^wp6108") or s:find("^wp6305") then
                local hc = get_hc(go)
                -- Valider Waffen-HC. Normal: NUR mit aktivem Collider (get_RequestSetCollider) -> das
                -- in der Hand gehaltene Messer. [LH_CLONE] allow_holstered=true nimmt auch ein GEHOLSTERTES
                -- Messer (Collider aus) -> gibt dem Klon einen ECHTEN Messer-HC fuer requestAttack (Breakables),
                -- da im Klon-Modus eine GUN equippt ist und kein Messer-Collider aktiv ist.
                if hc and safe_call(go, "get_Valid") ~= false
                   and (allow_holstered or safe_call(hc, "get_RequestSetCollider")) then
                    if (not want_id) or weapon_id_num(hc) == want_id then return hc end
                end
            end
        end
        local r = find_wp_hc(child, depth + 1, want_id, allow_holstered)
        if r then return r end
        child = safe_call(child, "get_Next")
    end
    return nil
end
-- [CACHE_SOLID] Ist der gecachte HC noch das AKTIVE Messer? get_RequestSetCollider allein reicht NICHT:
-- eine nach Save-Load ausgetauschte (tote) Instanz behaelt ihren Collider im Speicher -> stale Zeiger,
-- der bei -1.77 (letzte Wurf-Position) haengt. get_Valid erkennt die tote Instanz.
local knife_hc_refresh_t = 0
local function hc_still_active(hc, want_id)
    if not hc then return false end
    local go = safe_call(hc, "get_GameObject"); if not go then return false end
    if safe_call(go, "get_Valid") == false then return false end          -- tote Instanz nach Save-Load
    if not safe_call(hc, "get_RequestSetCollider") then return false end   -- geholstert/entschaerft
    if want_id and weapon_id_num(hc) ~= want_id then return false end      -- andere Waffe gewechselt -> neu suchen
    return true
end
local function find_knife_hc()
    -- Cache nur behalten, wenn er (a) noch aktiv/valid ist, (b) die AKTUELL equippte WeaponID traegt
    -- UND (c) juenger als 1s -> Save-Load- und Waffenwechsel-fest.
    local now = os.clock()
    local want_id = get_equip_weapon_id()   -- eindeutige aktuelle Waffe (z.B. 5001)
    if knife_hc_cache and hc_still_active(knife_hc_cache, want_id) and (now - knife_hc_refresh_t) < 1.0 then
        return knife_hc_cache
    end
    knife_hc_cache = nil
    knife_hc_refresh_t = now
    -- [LH_REAL 2026-07-08] Klon-Zustand: das an die LINKE Hand GEPINNTE echte Messer hat VORRANG. re4_vr_knife_
    -- lefthand.lua parent das ausgewaehlte Messer-GO an L_Hand -> sein Collider sitzt am Gegner -> requestAttack
    -- landet (Collider-Ueberlappung war die Ursache). NICHT mit einem zufaelligen gemounteten Messer (5001,
    -- Collider im Holster) ueberschreiben -> darum hier zuerst pruefen und direkt zurueckgeben.
    if rawget(_G, "__re4_knife_left_clone") == true then
        local c = rawget(_G, "__re4_knife_hc_cache")
        local cgo = c and safe_call(c, "get_GameObject")
        if cgo and safe_call(cgo, "get_Valid") ~= false then knife_hc_cache = c; return c end
        -- [LH_CLONE HC] Kein gepinntes Messer + im Klon ist eine GUN equippt -> normale Suche findet KEIN
        -- Messer (want_id=Gun) bzw. nur geholsterte (Collider aus). Deshalb hier ein GEHOLSTERTES Messer
        -- zulassen (allow_holstered) -> echter Messer-HC fuer requestAttack (Breakable-Completion beim Klon).
        local ctx = get_player_ctx()
        local body = ctx and safe_call(ctx, "get_BodyGameObject")
        local tf = body and safe_call(body, "get_Transform")
        local kh = tf and find_wp_hc(tf, 0, nil, true)
        if kh then knife_hc_cache = kh; return kh end
    end
    local ctx = get_player_ctx()
    local body = ctx and safe_call(ctx, "get_BodyGameObject")
    local tf = body and safe_call(body, "get_Transform")
    knife_hc_cache = find_wp_hc(tf, 0, want_id)          -- exakt die equippte Waffe
    if not knife_hc_cache then knife_hc_cache = find_wp_hc(tf, 0, nil) end   -- Fallback: irgendein valides Messer
    return knife_hc_cache
end

-- [KNIFE_SND] Messer-Aktions-Sounds ueber den SoundContainer der Waffe (trigger(uint32),
-- wie #re4_sound_player). IDs tunebar via _G.__re4_knife_snd. swing = beim Schwingen (nicht Wurf).
_G.__re4_knife_snd = _G.__re4_knife_snd or { swing = 1800445513 }
_G.__re4_knife_snd.throw = _G.__re4_knife_snd.throw or 3788596668   -- [KNIFE_SND] Wurf-Sound (beim Loslassen)
_G.__re4_knife_snd.hit = _G.__re4_knife_snd.hit or 686504397        -- [KNIFE_SND] Messer trifft Wand/Objekt (Einschlag)
_G.__re4_knife_snd.floor = _G.__re4_knife_snd.floor or 643584649    -- [KNIFE_SND] Boden-Aufprall (Messer kommt am Boden auf)
local _knife_snd_td = sdk.typeof("soundlib.SoundContainer")
local function play_knife_sound(id)
    if not id or id <= 0 or not _knife_snd_td then return end
    local hc = find_knife_hc(); if not hc then return end
    local go = safe_call(hc, "get_GameObject"); if not go then return end
    local scn = safe_call1(go, "getComponent(System.Type)", _knife_snd_td); if not scn then return end
    pcall(function() scn:call("trigger(System.UInt32)", id) end)
end

-- Naechster Gegner (verifizierte EnemyContextList)
local function find_nearest_enemy_go(from, max_dist)
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and safe_call(cm, "get_EnemyContextList")
    if not list then return nil end
    local count = safe_call(list, "get_Count") or 0
    local best, bestd = nil, max_dist
    for i = 0, count - 1 do
        local ctx = safe_call1(list, "get_Item", i)
        local go = ctx and safe_call(ctx, "get_GameObject")
        local tf = go and safe_call(go, "get_Transform")
        local pos = tf and safe_call(tf, "get_Position")
        if pos and from then
            local dx, dy, dz = pos.x - from.x, pos.y - from.y, pos.z - from.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d < bestd then bestd = d; best = go end
        end
    end
    return best, bestd
end

-- [ZIELHILFE] Wurf-Aim-Assist: den Gegner finden, dessen Richtung (vom Wurf-Ursprung zur Brust-Hoehe)
-- am naechsten an der Wurfrichtung liegt UND innerhalb des Einfang-Kegels ist. Gibt die Brust-Weltpos
-- zurueck (oder nil). Global, damit weapons.lua keinen weiteren Top-Level-Local braucht (200-Limit).
-- [ZIEL-CENTER] Adaptiver Zielpunkt eines Gegners: Mittelpunkt zwischen Root (get_Position = Fuesse) und
-- Kopf-GO (get_HeadGameObject) -> passt sich der Groesse an (Huhn niedrig, Ganado mittig), statt festem
-- +0.95. Plus -Offset (assist_target_off_y, JSON/Slider) den man frei nachzieht. Fallback Root+0.9,
-- falls kein/zu tiefer Kopf. Global-Closure (nutzt safe_call) -> keine neue top-level local.
_G.__re4_enemy_aim_point = function(ctx)
    local pos = ctx and safe_call(ctx, "get_Position")
    if not pos then return nil end
    local off = tonumber((_G.__re4_knife_fly_cfg or {}).assist_target_off_y) or 0.0
    -- [SCHLANGE] enemy-spezifischer Y-Versatz (whitelist.lua: Schlange -0.8, sonst 0). Fliesst in beide Returns.
    off = off + (rawget(_G, "__re4_enemy_off_y") and _G.__re4_enemy_off_y(ctx) or 0.0)
    local hgo = safe_call(ctx, "get_HeadGameObject")
    local htf = hgo and safe_call(hgo, "get_Transform")
    local hp  = htf and safe_call(htf, "get_Position")
    -- [KOPF-SANITY] Kopf nur nutzen, wenn er HORIZONTAL nah am Root sitzt (< 1.5m). get_HeadGameObject
    -- lieferte fuer manche Gegner einen FERNEN/fremden Kopf -> die "Mitte" Root<->Kopf lag 30m+ weg
    -- -> Gegner galt als 33m entfernt -> kein Ziel im Wurf-Kegel. Sonst: direkte Gegner-Position.
    if hp and (hp.y - pos.y) > 0.3 then
        local hdx, hdz = hp.x - pos.x, hp.z - pos.z
        if (hdx*hdx + hdz*hdz) < (1.5*1.5) then
            return (pos.x+hp.x)*0.5, (pos.y+hp.y)*0.5 + off, (pos.z+hp.z)*0.5
        end
    end
    return pos.x, pos.y + 0.9 + off, pos.z   -- Fallback (kein/zu tiefer/ferner Kopf)
end

_G.__re4_knife_assist_target = function(from, dir, max_dist, cone_deg)
    _G.__re4_assist_dbg = "no-from-dir"
    if not (from and dir) then return nil end
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and safe_call(cm, "get_EnemyContextList")
    if not list then _G.__re4_assist_dbg = "no-list"; return nil end
    local count = safe_call(list, "get_Count") or 0
    local cone_cos = math.cos(((cone_deg or 20) * math.pi) / 180)   -- Kegel als min. Dot-Schwelle
    local best, best_ctx, seen_best, nearest, npos, best_score = nil, nil, -2.0, 999.0, 0, 1e9
    for i = 0, count - 1 do
        local ctx = safe_call1(list, "get_Item", i)
        -- EnemyContext hat die Position DIREKT (Body-Center) -> nicht ueber get_GameObject (liefert nil).
        local pos = ctx and safe_call(ctx, "get_Position")
        -- [LIVE] NUR lebende Gegner anvisieren -> keine Leichen (sonst flog das Messer zum toten Gegner).
        -- [LIVE-FIX] Lebend-Check wie im Melee (knife_pick_target): get_IsDead + HP>0. Der fruehere
        -- get_IsLive-Check schloss NAHE Gegner faelschlich aus (withpos zu niedrig) -> assist_target
        -- pickte dann einen FERNEN Gegner (27m) statt des nahen -> Wurf flog ins Leere, kein Homing sichtbar.
        local live = false
        if pos then
            local hp = safe_call(ctx, "get_HitPoint")
            live = hp ~= nil and (safe_call(hp, "get_IsDead") ~= true) and ((tonumber(safe_call(hp, "get_CurrentHitPoint")) or 0) > 0)
        end
        if pos and live then
            npos = npos + 1
            local cx, cy, cz = _G.__re4_enemy_aim_point(ctx)         -- [CENTER] adaptiver Zielpunkt (Fuesse<->Kopf-Mitte + Offset)
            local dx, dy, dz = cx - from.x, cy - from.y, cz - from.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d > 0.2 then
                if d < nearest then nearest = d end
                if d <= (max_dist or 30.0) then
                    -- [KEGEL HORIZONTAL 2026-07-10] Dot NUR aus X/Z (wie knife_assist_breakable). Grund: ein
                    -- NAHER Gegner sitzt mit der Brust (Zielpunkt ~Boden+0.9) deutlich UNTER der Augenlinie ->
                    -- der 3D-Dot kippte ihn aus dem engen Kegel (steiler Abwaertswinkel), obwohl man horizontal
                    -- genau draufzielt -> Homing ging bei NAHEN Gegnern nicht (fern = flacher Winkel = ok).
                    -- Horizontal messen -> vertikale Blickneigung egal, konsistent mit Breakables/Animals.
                    local hlen = math.sqrt(dx*dx + dz*dz)
                    local chl  = math.sqrt(dir.x*dir.x + dir.z*dir.z)
                    local dot  = (hlen > 0.001 and chl > 0.001) and ((dx*dir.x + dz*dir.z) / (hlen*chl)) or -2.0
                    if dot > seen_best then seen_best = dot end
                    -- [ZIELWAHL 2026-08-12] Nicht mehr "der NAECHSTE im Kegel", sondern "der, auf den du am
                    -- genauesten zeigst": Score = seitliche Ablage zur Blickachse + kleiner Distanzzuschlag,
                    -- kleinster Score gewinnt. Beide Extreme sind belegt falsch:
                    --   nur Distanz -> ein Gegner 1 m schraeg RECHTS schlaegt den 3 m geradeaus vor dir,
                    --                  sobald der Nahfang-Schlauch ihn ueberhaupt zulaesst,
                    --   nur Winkel  -> ein FERNER, exakt zentrierter Gegner schlaegt den nahen (Befund 10.07., 27 m).
                    -- Der Zuschlag (0.05 pro Meter) haelt beide Faelle richtig:
                    --   3 m/0,10 m Ablage = 0,25  gegen  1 m/0,50 m schraeg = 0,55  -> vorne gewinnt
                    --   3 m/0,35 m        = 0,50  gegen  27 m/0,20 m zentriert = 1,55 -> nah gewinnt
                    -- [LOS 2026-07-11] Freie Sicht vom Auge zum Gegner (castRay Layer 10 = Wand/Boden)? Ein
                    -- Gegner im Stock DRUEBER/DRUNTER ist durch Decke/Boden verdeckt -> Ray blockiert -> raus
                    -- (verhindert "Messer in die Decke"). SICHTBARE Gegner ueber/unter bleiben treffbar. Der
                    -- Gegner-Pfad hatte bisher KEINEN Sicht-Check (nur Breakables) -> das war die eigentliche Luecke.
                    -- [NAHFANG 2026-08-12] Zugelassen wird ueber den Winkel ODER die seitliche Ablage (lat)
                    -- unter dem Mindest-Schlauch assist_min_lat -- mit hartem Winkeldeckel von 30 Grad
                    -- (cos 30 = 0.866): ohne den waeren 0,6 m auf 0,8 m Distanz ein 37-Grad-Wurf "geradeaus".
                    -- Der Schlauch entscheidet nur, wer ueberhaupt MITSPIELT; wer gewinnt, macht der Score.
                    local lat = hlen * math.sqrt(math.max(0.0, 1.0 - dot * dot))
                    local mlat = tonumber((_G.__re4_knife_fly_cfg or {}).assist_min_lat) or 0.0
                    local score = lat + d * 0.05
                    if (dot > cone_cos or (dot > 0.866 and lat <= mlat))
                       and score < best_score and _G.__re4_los_clear(from, { x = cx, y = cy, z = cz }) then
                        best_score = score; best = { x = cx, y = cy, z = cz }; best_ctx = ctx
                    end
                end
            end
        end
    end
    _G.__re4_assist_dbg = string.format("count=%d withpos=%d nearest=%.1f bestdot=%.2f need>%.2f",
        count, npos, nearest, seen_best, math.cos(((cone_deg or 20) * math.pi) / 180))
    -- [ASSIST_DIAG] flush-sicher pro Wurf-Zielwahl: WARUM wurde (k)ein Ziel gewaehlt?
    -- withpos=0 -> keine lebenden Gegner erfasst | bestdot<need -> Gegner ausserhalb Wurf-Kegel
    -- nearest>maxd -> zu weit | TARGET vorhanden aber kein Homing sichtbar -> In-Flight-Homing pruefen.
    -- [ASSIST_DIAG LOG AUS 2026-07-06] (pro Wurf io.open -> FPS; bei Bedarf reaktivieren)
    return best, best_ctx
end

-- ---- Daten-Caching aus nativen Treffern (reload-freundlich via _G) ----
function _G.__re4_knife_pool_cb(args)
    -- poolDamage(CollisionInfo, AttackUserData[4], DamageUserData[5], bool)
    _G.__re4_lp_atk = args[4]
    _G.__re4_lp_dmg = args[5]
end
function _G.__re4_knife_attack_cb(args)
    -- callbackAttackHit(DamageInfo): this=Angreifer-HC (args[2]), DamageInfo=args[3]
    local hc = safe_mo(args[2])
    local wid = weapon_id_num(hc)
    if not (wid and KNIFE_IDS[wid]) then return end
    -- Cache atk/dmg (nur EINMAL) fuer den bootstrap-freien requestAttack
    if _G.__re4_knife_atkUD then return end
    local atk, dmg = safe_mo(_G.__re4_lp_atk), safe_mo(_G.__re4_lp_dmg)
    if atk and dmg then
        pcall(function() atk:add_ref() end)
        pcall(function() dmg:add_ref() end)
        _G.__re4_knife_atkUD = atk
        _G.__re4_knife_dmgUD = dmg
    end
end

if not _G.__re4_knife_hooks_installed then
    _G.__re4_knife_hooks_installed = true
    local td = sdk.find_type_definition("chainsaw.HitController")
    local mp = td and td:get_method("poolDamage")
    if mp then sdk.hook(mp, function(a) _G.__re4_knife_pool_cb(a) end, function(r) return r end) end
    local mc = td and td:get_method("callbackAttackHit")
    if mc then sdk.hook(mc, function(a) _G.__re4_knife_attack_cb(a) end, function(r) return r end) end
end

-- [DMG-CALC] echte Messerschaden-Kontrolle. Feuert auf dem OPFER-HC bei jedem Treffer:
-- args[2]=this(Opfer) [3]=DamageValue(Damage/Wince/Break) [4]=CalculateInfo. Bei einem PLAYER-Messer-
-- Treffer loggen wir den berechneten Schaden und setzen ihn optional auf einen echten Wert
-- (_G.__re4_knife_dmg_override) + optional Wince (_G.__re4_knife_wince_override).
function _G.__re4_knife_dmg_cb(args)
    local ci = safe_mo(args[4]); if not ci then return end
    local w = safe_call(ci, "get_WeaponID")
    local wid = w and (type(w) == "number" and w or tonumber(safe_field(w, "value__")))
    if not (wid and KNIFE_IDS[wid]) then return end
    local dv = safe_mo(args[3]); if not dv then return end
    -- NUR unsere requestAttack-Treffer korrigieren (Marker-Fenster). Native RT = unberuehrt.
    if (rawget(_G, "__re4_knife_our_until") or 0) > os.clock() then
        local ov = rawget(_G, "__re4_knife_dmg_override")
        if ov then pcall(function() dv:call("set_Damage", math.floor(ov)) end) end
        local wv = rawget(_G, "__re4_knife_wince_override")
        if wv then pcall(function() dv:call("set_Wince", wv + 0.0) end) end
    end
end
if not _G.__re4_knife_dmg_hook_installed then
    _G.__re4_knife_dmg_hook_installed = true
    local td = sdk.find_type_definition("chainsaw.HitController")
    local md = td and td:get_method("callbackCalculateDamage")
    if md then sdk.hook(md, function(a) _G.__re4_knife_dmg_cb(a) end, function(r) return r end) end
end

local KNIFE_HIT_RANGE = 2.5      -- (alt, ungenutzt)
-- [KNIFE_REACH] echte Messer-Reichweite: Distanz VR-Rechte-Hand -> Gegner-Koerpermitte muss <= das
-- sein, damit ein Treffer zaehlt. Body-Center = Gegner-Root(Fuesse) + BODY_CENTER_Y (Brust/Bauch).
-- Klein halten -> nur echter Kontakt zaehlt (kein Luft-Schwung auf Naehe). Tunebar.
local KNIFE_REACH    = 0.90
_G.__re4_knife_reach = _G.__re4_knife_reach or KNIFE_REACH   -- [KNIFE_REACH] Stich-Gegner-Radius (Slider), ueberlebt Reset
local BODY_CENTER_Y  = 0.95
-- [B] Kollisions-Weg: wie lange nach einem Schwung der Messer-Attack scharf bleibt (Engine macht
-- die native Kollision in dem Fenster). Tunebar.
local KNIFE_ATTACK_WINDOW = 0.35
-- [KNIFE_DMG] echter Messer-Schaden pro VR-Schwung (nativ ~144-575 je nach Trefferstelle -> Norm ~150).
-- Wird per Damage-Hook NUR auf UNSERE Treffer gesetzt (native RT bleibt unberuehrt). Tunebar.
_G.__re4_knife_dmg_override   = _G.__re4_knife_dmg_override   or 150
_G.__re4_knife_wince_override = _G.__re4_knife_wince_override or 90.0
local knife_melee_prev = false
local last_knife_melee_t = 0

local function type_name(o)
    if o == nil then return "nil" end
    local ok, td = pcall(function() return o:get_type_definition() end)
    if ok and td then local ok2, n = pcall(function() return td:get_full_name() end); if ok2 and n then return tostring(n) end end
    return "?"
end
local function call_args(obj, method, ...)
    if not obj then return nil end
    local a = { ... }
    local ok, r = pcall(function() return obj:call(method, table.unpack(a)) end)
    return ok and r or nil
end
local function safe_create(tn)
    local ok, r = pcall(function() return sdk.create_instance(tn, true) end)
    if ok and r then return r end
    ok, r = pcall(function() return sdk.create_instance(tn) end)
    return ok and r or nil
end

-- Ziel: bevorzugt anvisierter Gegner (get_AimTargetEnemy), sonst naechster Gegner (5m). Loggt
-- Gegner-Anzahl + naechste Distanz, damit wir sehen ob ueberhaupt Gegner da/in Reichweite sind.
-- proximity_only: den Aim-Ziel-Shortcut UEBERSPRINGEN (fuer den Wurf-Flug: nur echte Naehe zaehlt,
-- sonst trifft man ein anvisiertes Ziel egal wo das Messer fliegt).
-- reach: eigene Trefferreichweite (Flug enger als In-Hand-Melee). Default = KNIFE_REACH.
local function knife_pick_target(kpos, proximity_only, reach)
    reach = reach or rawget(_G, "__re4_knife_reach") or KNIFE_REACH
    local ctx = get_player_ctx()
    if not proximity_only then
        local aim = ctx and safe_call(ctx, "get_AimTargetEnemy")
        if aim then return aim, "aim" end
    end
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and safe_call(cm, "get_EnemyContextList")
    local count = list and (tonumber(safe_call(list, "get_Count")) or 0) or 0
    -- kpos-Fallback: Player-Position, falls die VR-Rechte-Hand-Welt noch nicht da ist
    if not kpos then kpos = ctx and safe_call(ctx, "get_Position") end
    local bestctx, bestd = nil, 9999
    if kpos and count > 0 then
        for i = 0, count - 1 do
            local ectx = safe_call1(list, "get_Item", i)
            -- TOTE Gegner (Leichen) ueberspringen -> kein Stich in die Leiche
            local hp = ectx and safe_call(ectx, "get_HitPoint")
            local alive = hp and (safe_call(hp, "get_IsDead") ~= true) and ((tonumber(safe_call(hp, "get_CurrentHitPoint")) or 0) > 0)
            -- CharacterContext hat get_Position DIREKT (kein GameObject->Transform noetig)
            local pos = alive and safe_call(ectx, "get_Position")
            if pos then
                -- Distanz Hand -> Gegner-KOERPERMITTE (Root + Hoehe), nicht zu den Fuessen
                local dx = pos.x - kpos.x
                local dy = (pos.y + BODY_CENTER_Y) - kpos.y
                local dz = pos.z - kpos.z
                local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                if d < bestd then bestd = d; bestctx = ectx end
            end
        end
    end
    if bestctx and bestd <= reach then
        local go = safe_call(bestctx, "get_BodyGameObject")  -- Ziel-GO fuer requestAttack
        _G.__re4_knife_last_target_ctx = bestctx             -- fuer HP-Check-Diag
        if go then return go, string.format("nearest%.1f", bestd) end
        return nil, "no_bodyGO"
    end
    return nil, "none"
end

-- AttackUserData beschaffen: 1) gecacht (nativ), 2) BOOTSTRAP-FREI vom Messer-Collider. Iteriert ALLE
-- RequestSet-UserDatas + Collidable-UserDatas, loggt jeden Typ, nimmt die erste echte AttackUserData.
-- Welcher RequestSet-Index als Angriff genutzt wird. rsUD[2] = stark/Instakill (2159 dmg), daher
-- rsUD[5] probieren (vmtl. normaler Schwung). nil = erste gefundene AttackUserData. Tunebar.
local KNIFE_ATK_IDX = 5
local function knife_get_attack_ud(hc)
    -- IMMER FRISCH vom Collider (gecachte/wiederverwendete UD staggert nur, macht keinen Schaden).
    local rsc = safe_call(hc, "get_RequestSetCollider")
    if not rsc then return nil, "no_rsc" end
    local nrs = tonumber(safe_call(rsc, "get_NumRequestSetIds")) or 0
    local first, first_i, want = nil, nil, nil
    for i = 0, math.min(nrs, 12) - 1 do
        local ud = safe_call1(rsc, "getRequestSetUserData", i)
        if ud and type_name(ud):find("AttackUserData") then
            if not first then first, first_i = ud, i end
            if KNIFE_ATK_IDX and i == KNIFE_ATK_IDX then want = ud end
        end
    end
    if want then _G.__re4_knife_atk_cache = want; return want, string.format("rsUD[%d]", KNIFE_ATK_IDX) end
    if first then _G.__re4_knife_atk_cache = first; return first, string.format("rsUD[%d]", first_i) end
    -- [5002-FIX] Dieses Messer liefert keine eigene AttackUD (z.B. Kitchen Knife) -> von einem anderen leihen.
    local borrowed = _G.__re4_borrow_knife_atk and _G.__re4_borrow_knife_atk()
    if borrowed then return borrowed, "borrowed" end
    return nil, "no_attack_ud"
end
-- [LH_CLONE 2026-07-09] Export: re4_vr_knife_lh_damage.lua zieht die Klingen-AttackUserData direkt vom Messer-
-- Collider (prime-frei fuer die native hitSetting-Kette). Rein additiv, rechte Hand voellig unberuehrt.
_G.__re4_find_knife_hc = find_knife_hc
_G.__re4_knife_get_attack_ud = knife_get_attack_ud

-- [BREAKABLES] Beruehrungs-Position fuer den In-Hand-Melee. Die Messer-Objekt-Root ist NICHT die sichtbare
-- Klinge (entkoppelt/stale, sitzt an der Body-Root) -> die Klinge sitzt an der Hand. Deshalb die echte
-- Hand-Weltposition (__vr_rh_world, jeden Frame frisch) nutzen; nur als Fallback die Objekt-Root.
local function knife_obj_pos()
    local rh = _G.__re4_knife_hand_world()   -- [KNIFE_HAND] Klinge sitzt an der aktiven Messer-Hand (links/rechts)
    if rh then return rh end
    local hc = find_knife_hc(); if not hc then return nil end
    local go = safe_call(hc, "get_GameObject")
    local tf = go and safe_call(go, "get_Transform")
    return tf and safe_call(tf, "get_Position")
end

-- Ueber alle registrierten HitController-GameObjects iterieren (Dictionary<GameObject,HitController>
-- via HitManager) -> enthaelt Gegner UND Breakables. Value-Type-Entries via _entries-Array.
local function iter_hitctrl_gos(cb)
    local hm = sdk.get_managed_singleton("chainsaw.HitManager"); if not hm then return end
    local list = safe_call(hm, "get_HitControllerList"); if not list then return end
    local entries = safe_field(list, "_entries"); if not entries then return end
    local n = tonumber(safe_call(entries, "get_Length")) or 0
    for i = 0, math.min(n, 4096) - 1 do
        local e = entries[i]
        local go = e and (safe_field(e, "key"))
        if go then cb(go) end
    end
end

-- [5002-FIX] Manche Messer (wp5002 Kitchen Knife) liefern KEINE eigene AttackUserData aus ihrem Collider
-- -> requestAttack macht keinen Schaden (atk=false). Fallback: eine AttackUserData leihen (der echte Schaden
-- kommt eh aus dem Damage-Hook; die AttackUD ist nur der Ausloeser). Gecacht.
--
-- [WP5002-STAGE 2026-07-17] In der Anfangs-Stage gibt es NUR wp5002, also KEIN anderes Messer zum Leihen
-- (live bestaetigt). Nativ macht wp5002 trotzdem Melee-Schaden -- aber ueber checkAttackDamage
-- (Kollision), NICHT ueber requestAttack+AttackUD (per sdk.hook-Probe belegt: execMelee -> checkAttackDamage,
-- keine AttackUD). Unser VR-Weg (rechts UND Links-Klon) baut aber auf requestAttack, das eine AttackUD als
-- TRIGGER braucht. Da die UD laut Prinzip nur der Ausloeser ist (Schaden aus dem Hook), taugt JEDE Waffen-
-- AttackUD -- auch die eines GEGNERS (im Kampf immer vorhanden, z.B. wp5801). Darum: Messer bevorzugt,
-- sonst irgendeine Waffe (wp*). Deckt rechts, links UND Klon ab (alle gehen ueber knife_get_attack_ud).
-- Cap auf 32 hoch (manche Waffen tragen die AttackUD an hoeherem Index als 12).
_G.__re4_borrow_knife_atk = function()
    local c = rawget(_G, "__re4_knife_atk_cache")
    if c then return c end
    local found_knife, found_any = nil, nil
    iter_hitctrl_gos(function(go)
        if found_knife then return end   -- Messer gefunden -> fertig; sonst weiter fuer found_any
        local nm = safe_call(go, "get_Name")
        if type(nm) ~= "string" then return end
        local id = nm:match("^wp(%d+)")
        if not id then return end                        -- nur Waffen (wp*), aber JEDE -- nicht nur Messer
        local is_knife = KNIFE_IDS[tonumber(id)] == true
        local hc = get_hc(go)
        local rsc = hc and safe_call(hc, "get_RequestSetCollider")
        if not rsc then return end
        local nrs = tonumber(safe_call(rsc, "get_NumRequestSetIds")) or 0
        for i = 0, math.min(nrs, 32) - 1 do
            local ud = safe_call1(rsc, "getRequestSetUserData", i)
            if ud and type_name(ud):find("AttackUserData") then
                if is_knife then found_knife = ud else found_any = found_any or ud end
                return
            end
        end
    end)
    local found = found_knife or found_any   -- Messer-UD bevorzugt, sonst irgendeine Waffe (Gegner)
    if found then _G.__re4_knife_atk_cache = found end
    return found
end

-- [BREAKABLES] Auf Schwung: alles in Beruehr-Reichweite des Messer-OBJEKTS zerbrechen.
-- Fenster/Vasen (IGimmickDurability) -> addDurability negativ.
-- Kisten/Faesser (KEINE Durability, aber in HitControllerList) -> requestAttack wie bei Gegnern.
-- Gegner (ch*/em*), Spieler-Koerper (ch0a0z0*) und Waffen (wp*) werden ausgelassen: Gegner laufen
-- ueber den eigenen do_knife_melee-Pfad, alles andere waere Eigenbeschuss/Doppeltreffer.
-- GO-Origin != Collider-Mitte -> Radius grosszuegiger als echte Klingenlaenge (per-Waffe unkritisch).
_G.__re4_knife_touch = _G.__re4_knife_touch or 0.90
local _idur_td = nil
local _animal_td = nil   -- chainsaw.GmAnimal (Basis von GmChicken etc.) -> lebende Tiere nicht zerschlagen
-- chainsaw.GmWoodBoxBase = Basis ALLER zerschlagbaren Kisten/Faesser (GmWoodBox, GmWoodBoxMotion,
-- GmPhasedWoodBox, GmSmoothWoodBox). Zerstoerung ueber set_Routine(Break) (offizieller State-Uebergang).
-- [200-LOCAL-LIMIT] als Globals, damit der Haupt-Chunk unter dem Lua-Local-Limit bleibt.
local function get_break_routine()
    if _G.__re4_rt_break ~= nil then return _G.__re4_rt_break end
    local rt = sdk.find_type_definition("chainsaw.GmWoodBoxBase.RoutineType")
    local f = rt and rt:get_field("Break")
    _G.__re4_rt_break = (f and f:get_data(nil)) or false
    return _G.__re4_rt_break
end
-- [BREAKABLE-WHITELIST] Ausgelagert nach re4_vr_whitelist.lua -> _G.__re4_is_real_breakable_prop (+ Typ-Liste
-- __re4_breakable_tds). break_nearby ruft es unten per rawget (Runtime-Call -> Ladereihenfolge egal). Kein
-- Top-Level-Local hier (weapons.lua sitzt am 200-Limit).
-- kp_override: Position explizit vorgeben (z.B. Flug-Position des geworfenen Messers). Sonst
-- die aktuelle Messer-Objekt-Position (In-Hand-Melee).
-- [LH_CLONE BRUCHSOUND 2026-07-11] Der Klon hat keinen aktiven Collider -> die native Damage->Break-Kette
-- (die den objekt-eigenen Bruchsound spielt) laeuft nicht. Loesung: den SoundContainer per Parent-Walk finden
-- (Live-Abfrage 2026-07-11: bei der Vase gm84_520_00_0_壺大 sitzt der Container am PARENT, NICHT am Before/After-
-- Collider-Kind, das break_nearby anfasst -> ein Trigger auf dem Collider-GO war stumm) und seine EIGENE erste
-- Trigger-ID feuern (_TriggerInfoList[0]._TriggerId, Vase hat genau 1 = Bruchsound). VOR set_Routine aufrufen,
-- solange der Emitter noch lebt. Keine hardcodierte ID -> gilt fuer Vase/Fass/Kiste automatisch.
-- GLOBAL (kein Top-Level-Local -> weapons.lua sitzt am 200-Limit). Typecache ebenfalls in _G.
_G.__re4_clone_break_sound = function(start_go)
    if not start_go then return end
    local sctd = rawget(_G, "__re4_snd_sc_td")
    if not sctd then sctd = sdk.typeof("soundlib.SoundContainer"); _G.__re4_snd_sc_td = sctd end
    if not sctd then return end
    local t = safe_call(start_go, "get_Transform")
    local sc = nil
    for _ = 0, 3 do
        if not t then break end
        local g = safe_call(t, "get_GameObject")
        sc = g and safe_call1(g, "getComponent(System.Type)", sctd)
        if sc then break end
        t = safe_call(t, "get_Parent")
    end
    if not sc then return end
    local lst = safe_field(sc, "_TriggerInfoList")
    local cnt = lst and (tonumber(safe_call(lst, "get_Count")) or 0) or 0
    if cnt <= 0 then return end
    local info = safe_call1(lst, "get_Item", 0)
    local id = info and safe_field(info, "_TriggerId")
    if id then pcall(function() sc:call("trigger(System.UInt32)", id) end) end
end

-- [PRAEZISER TREFFER 2026-08-12] Sitzt die Klinge wirklich AM Objekt? Geprueft wird gegen die echte
-- Mesh-Box (via.render.Mesh -> WorldAABB, plus Rand), nicht gegen eine feste Kugel: ein Huhn ist damit
-- 30 cm gross und ein Fass so gross wie das Fass, ohne Sonderregeln pro Objektart. Das Mesh sitzt oft
-- am ELTERN-GO (der HitController haengt an einem Kind wie "Before"), deshalb bis zu zwei Ebenen hoch.
-- Rueckgabe true/false, oder nil wenn gar kein Mesh gefunden wurde -- dann faellt der Aufrufer auf
-- seinen Radius zurueck, damit nichts lautlos untreffbar wird.
-- AABB per get_field lesen: getCenter & Co. liefern bei ValueTypes plausiblen Muell.
_G.__re4_hit_in_mesh_box = function(go, kp, margin)
    if not (go and kp) then return nil end
    if _G.__re4_mesh_td == nil then
        _G.__re4_mesh_td = false
        pcall(function() local t = sdk.typeof("via.render.Mesh"); if t then _G.__re4_mesh_td = t end end)
    end
    if not _G.__re4_mesh_td then return nil end
    local m = tonumber(margin) or 0.15
    local node, res = go, nil
    for _ = 0, 2 do
        if not node then break end
        local ok, r = pcall(function()
            local mesh = node:call("getComponent(System.Type)", _G.__re4_mesh_td)
            if not mesh then return nil end
            local aabb = mesh:call("get_WorldAABB")
            if not aabb then return nil end
            local mn, mx = aabb:get_field("minpos"), aabb:get_field("maxpos")
            if not (mn and mx and type(mn.x) == "number" and type(mx.x) == "number") then return nil end
            if mn.x > mx.x or mn.y > mx.y or mn.z > mx.z then return nil end   -- leere AABB
            return (kp.x >= mn.x - m and kp.x <= mx.x + m
                and kp.y >= mn.y - m and kp.y <= mx.y + m
                and kp.z >= mn.z - m and kp.z <= mx.z + m)
        end)
        if ok and r ~= nil then res = r; break end
        local up = nil
        pcall(function()
            local tf = node:call("get_Transform")
            local pt = tf and tf:call("get_Parent")
            up = pt and pt:call("get_GameObject")
        end)
        node = up
    end
    return res
end

-- max_dy (optional): schaltet die PRAEZISE Pruefung ein (Mesh-Box, sonst Hoehenfenster als Rueckfall).
-- Nur der Flug-Scan setzt ihn. Der Messer-STICH ruft ohne Parameter auf und trifft weiter alles in
-- Klingenreichweite -- dort haengt die Klinge auf Handhoehe ueber einem Huhn am Boden.
local function break_nearby(kp_override, radius_override, max_dy)
    local kp = kp_override or knife_obj_pos()
    if not kp then return end
    if not _idur_td then _idur_td = sdk.typeof("chainsaw.IGimmickDurability") end
    if not _animal_td then _animal_td = sdk.typeof("chainsaw.GmAnimal") end
    if not _G.__re4_woodbox_td then _G.__re4_woodbox_td = sdk.typeof("chainsaw.GmWoodBoxBase") end
    local hc = find_knife_hc()
    local atk = hc and knife_get_attack_ud(hc)
    _G.__re4_knife_atk_hc = hc   -- Angreifer-HitController fuer die Klon-Wiedergabe (weapons2)
    local was_enabled = hc and safe_call(hc, "get_AttackEnable")
    local touch = radius_override or rawget(_G, "__re4_knife_touch") or 0.90
    -- [PROP-RADIUS 2026-07-23] Haengende Whitelist-Props (Muenze) haben ihren Ursprung oben am
    -- Pendel-Drehpunkt: gemessen 0.75 m XZ gegen einen Messer-Radius von 0.708 -- knapp daneben.
    -- Fest verdrahtet und knapp gehalten, gilt NUR fuer den Whitelist-Zweig.
    local PROP_TOUCH = 1.00
    local scharf = false
    -- [FEHLER GEFUNDEN 2026-07-23] Der Ausgangszustand MUSS gemerkt werden: HitController stehen von
    -- Haus aus auf AttackEnable=true (Dump 12:47). Unten wurde bisher bedingungslos auf false
    -- zurueckgesetzt -> nach jedem Treffer in diesem Scan lag der Messer-Collider entschaerft da,
    -- und damit waren Gegner-Nahkampf, Wurf und Kisten tot, die denselben HitController benutzen.
    local broke = 0   -- Anzahl tatsaechlich zerstoerter Breakables (fuer objektbasierte Wurf-Kollision)
    local wb_cd, wb_cnm = 1e9, nil   -- [WB_DIAG] naechste GmWoodBox (min-Distanz) ueber den ganzen Scan
    iter_hitctrl_gos(function(go)
        local nm = safe_call(go, "get_Name")
        if type(nm) == "string" then
            local p2 = nm:sub(1, 2)
            if p2 == "ch" or p2 == "em" or p2 == "wp" then return end   -- Player/Gegner/Waffen aus
        end
        local tf = safe_call(go, "get_Transform"); local pos = tf and safe_call(tf, "get_Position")
        if not pos then return end
        -- [RE9-LEHRE] NUR horizontale Distanz (X/Z), Y ignorieren: der GO-Origin sitzt bei einem Fass
        -- am Boden, bei einer kleinen Regalkiste in der Mesh-Mitte -> die Y-Differenz verfaelscht die
        -- echte 3D-Distanz. XZ misst den Abstand zu der Stelle, wo das Objekt STEHT, nicht zum Root.
        local dx, dz = pos.x - kp.x, pos.z - kp.z
        local d2 = dx*dx + dz*dz
        local scan_t = (PROP_TOUCH > touch) and PROP_TOUCH or touch
        if d2 > scan_t * scan_t then return end
        -- [PRAEZISER TREFFER 2026-08-12] Die X/Z-Messung oben ist eine grobe Vorauswahl: sie kennt kein
        -- Oben und Unten (Wurf meterweit DRUEBER zaehlte als Treffer) und sie ist fuer jedes Objekt
        -- gleich gross (0,7 m Kugel -- bei einem 30-cm-Huhn ein halber Meter Gnade). Im FLUG entscheidet
        -- deshalb die echte Mesh-Box des Objekts. Kein Mesh gefunden -> Rueckfall auf das Hoehenfenster,
        -- damit nichts lautlos untreffbar wird. Ohne max_dy (Messer-STICH) bleibt alles wie bisher.
        if max_dy then
            local inbox = _G.__re4_hit_in_mesh_box(go, kp, tonumber((_G.__re4_knife_fly_cfg or {}).hit_margin) or 0.15)
            if inbox == false then return end
            if inbox == nil and math.abs(pos.y - kp.y) > max_dy then return end
        end
        -- ItemDisp (Item-Anzeige / Pickup) ist KEIN Breakable -> nie treffen (sonst Phantom-Treffersound).
        if type(nm) == "string" and nm:sub(1, 7) == "ItemDis" then return end
        -- Lebende Tiere (GmAnimal, z.B. Huhn): TOTE ignorieren (kein Treffer/Sound). LEBENDE bekommen
        -- HIER ihren eigenen requestAttack (sie haben KEINE WoodBox/Durability -> fielen sonst durch beide
        -- Damage-Zweige = kein Schaden). GmAnimal.onHitDamage(HitController.DamageInfo) empfaengt den Hit.
        local animal = _animal_td and safe_call1(go, "getComponent(System.Type)", _animal_td)
        if animal then
            -- [TIER-RADIUS 2026-08-12] Tiere bekommen einen eigenen, engeren Radius: der allgemeine
            -- Messer-Radius (0,7 m) ist bei einem 30-cm-Huhn ein halber Meter Gnade nach jeder Seite.
            local at = tonumber((_G.__re4_knife_fly_cfg or {}).animal_touch) or 0.35
            if d2 > at * at then return end
            if safe_call(animal, "get_IsDead") == true then return end
            if hc and atk then
                local dmg = safe_create("chainsaw.collision.DamageUserData")
                if dmg then
                    if not scharf then pcall(function() hc:call("set_AttackEnable", true) end); scharf = true end
                    _G.__re4_knife_our_until = os.clock() + 0.25
                    pcall(function() hc:call("requestAttack", go, atk, dmg) end)
                    -- [KLON 2026-07-23] Ohne Klingen-Collider wird requestAttack nie aufgeloest ->
                    -- den Empfang selbst nachbauen (onHitDamage am Ziel, s. weapons2).
                    if rawget(_G, "__re4_knife_left_clone") == true then
                        local rp = rawget(_G, "__re4_knife_onhit_replay")
                        if type(rp) == "function" then pcall(rp, go, atk) end
                        -- [TIER-SOUND 2026-08-12] Tiere waren der einzige Trefferfall, den wir selbst
                        -- herstellen, ohne ihn hoerbar zu machen: der Zweig hier hat nie einen Sound
                        -- gespielt, das Huhn starb lautlos. AUSSCHLIESSLICH linkes Messer und
                        -- AUSSCHLIESSLICH Tiere -- rechte Hand und alle anderen Objekte bleiben
                        -- unveraendert. In der HAND ueber den lh-Container (238304172); im FLUG ist der
                        -- stumm, weil das Messer den Koerper verlassen hat -> dort der Flug-Weg.
                        if rawget(_G, "__re4_knife_flying") == true then
                            play_knife_sound((_G.__re4_knife_snd or {}).hit)
                        else
                            local ps = rawget(_G, "__re4_knife_lh_play_sound")
                            if type(ps) == "function" then
                                pcall(ps, math.floor(tonumber(rawget(_G, "__re4_knife_lh_hit_snd")) or 238304172))
                            end
                        end
                    end
                    broke = broke + 1
                end
            end
            return   -- Huhn behandelt -> nicht als WoodBox weiterpruefen
        end
        -- go SELBST oder dessen Parent traegt WoodBox/Durability (Before/After-Collider -> Parent = WoodBox).
        local woodbox, dur = _G.__re4_wb_of(go)
        if (dur or woodbox) and d2 > touch * touch then return end   -- Kisten/Faesser: unveraendert
        if dur then
            local cur = tonumber(safe_call(dur, "get_CurrentDurability")) or 0
            if cur > 0 then
                -- [BRUCHSOUND 2026-07-20] Der Sound gehoert dem OBJEKT (Vase/Fass), nicht dem Messer.
                -- Dieser Durability-Zweig hat ihn NIE gespielt (auch nicht fuer den Klon) -> beim Wurf blieb
                -- es still. Objekt-eigenen Trigger VOR addDurability feuern, solange der Emitter lebt.
                -- Gilt fuer Links-Klon UND jeden Wurf (beide Haende, __re4_knife_flying). Beim echten
                -- In-Hand-Stich laeuft die native Damage->Break-Kette und spielt ihn selbst -> dort NICHT.
                if rawget(_G, "__re4_knife_left_clone") == true or rawget(_G, "__re4_knife_flying") == true then
                    _G.__re4_clone_break_sound(go)
                end
                pcall(function() dur:call("addDurability", -(cur + 1)) end); broke = broke + 1
            end
        elseif woodbox then
            -- Nur wenn noch nicht zerbrochen -> Routine auf Break setzen (Engine spielt Bruch + Loot-Drop).
            local broken = safe_call(woodbox, "get_IsBroken") == true
            local br = get_break_routine()
            if (not broken) and br ~= nil then
                -- Bruchsound VOR set_Routine (Emitter noch live), nur Klon -- nativ spielt ihn via Collider-Hit.
                -- [BRUCHSOUND 2026-07-20] auch im FLUG spielen: das geworfene Messer wird von uns
                -- bewegt, sein Collider sitzt nicht am Treffer -> die native Kette blieb stumm (beide Haende).
                if rawget(_G, "__re4_knife_left_clone") == true or rawget(_G, "__re4_knife_flying") == true then
                    _G.__re4_clone_break_sound(go)
                end
                -- [ZITTERN 2026-07-23] Beim Wurf laeuft break_nearby PRO FRAME, und `get_IsBroken`
                -- springt nicht sofort um -> set_Routine(Break) wurde mehrfach hintereinander gesetzt
                -- und die Bruch-Animation immer wieder neu gestartet (sichtbares Zittern/Flackern).
                -- Betrifft NUR diesen einen Aufruf: ein Ausloesen pro Objekt und Sekunde.
                local wbk = tostring(nm) .. "|wb"
                local wbt = rawget(_G, "__re4_wb_break_t")
                if type(wbt) ~= "table" then wbt = {}; _G.__re4_wb_break_t = wbt end
                if (os.clock() - (wbt[wbk] or -999)) < 1.0 then return end
                wbt[wbk] = os.clock()
                pcall(function() woodbox:call("set_Routine", br) end)
                -- [NATIVE-FLAG] set_Routine(Break) allein liess einen inkonsistenten Zustand (Rno=3,
                -- IsBroken=False, BasementState=Wait) -> Prompt/Homing hielten die Box fuer intakt.
                -- Der native Tritt ist eine Attacke -> zusaetzlich echten Schaden via requestAttack (wie
                -- GmOilDrum): die Engine faehrt ihre Break-Completion durch (IsBroken=True + Loot-Drop),
                -- der "zertreten"-Prompt verschwindet. (Live-Abfrage nativ vs Messer 2026-07-06.)
                if hc and atk then
                    local dmg = safe_create("chainsaw.collision.DamageUserData")
                    if dmg then
                        if not scharf then pcall(function() hc:call("set_AttackEnable", true) end); scharf = true end
                        _G.__re4_knife_our_until = os.clock() + 0.25
                        pcall(function() hc:call("requestAttack", go, atk, dmg) end)
                    end
                end
                -- [LH_CLONE COMPLETION 2026-07-09] Klon: requestAttack landet mangels Collider nicht -> Box-Break
                -- fuers Spiel ueber hitSetting am Box-HitController abschliessen (wie bei den Gegnern) -> Prompt weg.
                if rawget(_G, "__re4_knife_left_clone") == true then
                    local bf = rawget(_G, "__re4_knife_hitset_box")
                    if type(bf) == "function" then pcall(function() bf(go, pos) end) end
                end
                broke = broke + 1
            end
        elseif hc and atk and rawget(_G, "__re4_is_real_breakable_prop") and _G.__re4_is_real_breakable_prop(go) then
            if d2 > PROP_TOUCH * PROP_TOUCH then return end
            -- [DURCH DIE WAND 2026-07-23] Der Prop-Radius misst nur horizontal und kennt keine
            -- Geometrie: eine Muenze direkt hinter einer Mauer lag im Meter und ging mit kaputt.
            -- Deshalb Sichtlinie pruefen -- derselbe Helfer, den das Wurf-Homing benutzt.
            if type(rawget(_G, "__re4_los_clear")) == "function"
               and not _G.__re4_los_clear(kp, { x = pos.x, y = pos.y, z = pos.z }) then return end
            -- [WHITELIST 2026-07-09] NUR echte Breakables (GmOilDrum etc.) -- nicht jedes HitController-Objekt.
            -- Sonst wurde z.B. eine angelehnte Leiter als Ziel registriert (Treffer-Sound). Tiere/WoodBox/
            -- Durability sind oben separat behandelt. Weitere Typen in get_breakable_tds ergaenzen.
            -- Schadenbasierte Gimmicks OHNE Durability/WoodBox (z.B. GmOilDrum Explosivfass): per requestAttack
            -- treffen (Objekt-eigenes Schadenssystem entscheidet: Fass explodiert).
            local dmg = safe_create("chainsaw.collision.DamageUserData")
            if dmg then
                if not scharf then pcall(function() hc:call("set_AttackEnable", true) end); scharf = true end
                _G.__re4_knife_our_until = os.clock() + 0.25
                pcall(function() hc:call("requestAttack", go, atk, dmg) end)
                -- [KLON 2026-07-23] Wie im Tier-Zweig: den Empfang nachbauen (onHitDamage am Ziel
                -- bzw. an dessen Eltern-Gimmick -- bei der Muenze chainsaw.GmBlueCoin).
                if rawget(_G, "__re4_knife_left_clone") == true then
                    local rp = rawget(_G, "__re4_knife_onhit_replay")
                    if type(rp) == "function" then pcall(rp, go, atk) end
                end
                -- [LH_CLONE COMPLETION] Klon: requestAttack landet mangels Collider nicht -> nativ per hitSetting
                -- (wie WoodBox-Zweig), damit die whitelisteten Props auch vom Links-Klon getroffen werden.
                if rawget(_G, "__re4_knife_left_clone") == true then
                    local bf = rawget(_G, "__re4_knife_hitset_box")
                    if type(bf) == "function" then pcall(function() bf(go, pos) end) end
                end
            end
        end
    end)
    -- Nur zurueckentschaerfen, wenn er vorher AUCH aus war -- sonst bleibt er scharf, wie vorgefunden.
    if scharf and was_enabled ~= true then pcall(function() hc:call("set_AttackEnable", false) end) end
    -- [BREAKABLE] Die NAECHSTE GmWoodBox zerstoeren, wenn das Messer nah genug ist. Grosszuegiger Radius,
    -- weil der Fass/Kisten-Origin weit vom Beruehrpunkt sitzt (der enge touch-Filter oben verpasst sie sonst).
    -- set_Routine(Break) = offizieller Zerstoer-State (Live-Abfrage an chainsaw.GmWoodBoxBase).
    if wb_cnm and wb_cd <= 2.0 and _G.__re4_wb_closest_obj then
        local wbx = _G.__re4_wb_closest_obj
        if safe_call(wbx, "get_IsBroken") ~= true then
            local br = get_break_routine()
            if br ~= nil then
                pcall(function() wbx:call("set_Routine", br) end)
                broke = broke + 1
            end
        end
        _G.__re4_wb_closest_obj = nil
    end
    return broke
end
-- [LH_CLONE 2026-07-09] Export: re4_vr_knife_lefthand.lua ruft break_nearby fuer den Links-MELEE (der Klon-Schwung
-- brach bisher gar keine Boxen -> nur direct_damage_at/gegner). Additiv, rechter Break-Pfad unberuehrt.
_G.__re4_break_nearby = break_nearby

-- [PARENT-WOODBOX] Die zerstoerbaren Kisten haengen als "Before"/"After"-Collider-KINDER unter der WoodBox:
-- die Kinder sitzen an der ECHTEN Position (wo die Kiste steht), die WoodBox-Logik + ihr VERSETZTER Origin
-- am PARENT. Gibt WoodBox-Comp, Durability-Comp + das GO das sie traegt (self ODER parent) zurueck.
-- _G-Helfer wegen 200-Local-Limit. Live-Abfrage: Before.parent = gm84_505 (WoodBox), pwb=true.
_G.__re4_wb_of = function(go)
    if not go then return nil, nil, nil end
    if not _G.__re4_woodbox_td then _G.__re4_woodbox_td = sdk.typeof("chainsaw.GmWoodBoxBase") end
    if not _G.__re4_idur_td2 then _G.__re4_idur_td2 = sdk.typeof("chainsaw.IGimmickDurability") end
    local function gc(g, td)
        if not (g and td) then return nil end
        local ok, r = pcall(function() return g:call("getComponent(System.Type)", td) end)
        return ok and r or nil
    end
    local wb = gc(go, _G.__re4_woodbox_td)
    local du = gc(go, _G.__re4_idur_td2)
    if wb or du then return wb, du, go end
    local pgo = nil
    pcall(function() pgo = go:call("get_Transform"):call("get_Parent"):call("get_GameObject") end)
    if pgo then
        wb = gc(pgo, _G.__re4_woodbox_td)
        du = gc(pgo, _G.__re4_idur_td2)
        if wb or du then return wb, du, pgo end
    end
    return nil, nil, nil
end

-- [ZIELHILFE BREAKABLES] Naechste zerschlagbare Kiste/Fass (WoodBox / Durability-Gimmick) im Kegel um die
-- Wurfrichtung. Wie __re4_knife_assist_target fuer Gegner, nur fuer Breakables -> die Zielhilfe fliegt auch
-- dorthin. Rueckgabe: Zielpunkt + Distanz (statisch, Breakables bewegen sich nicht -> kein Live-Ctx).
-- [KAPUTT-MARKER 2026-07-06] Zuverlaessig ob eine WoodBox tot ist: get_IsBroken ist bei UNSEREN
-- Breaks oft nil (inkonsistenter Zustand) -> zusaetzlich get_Routine pruefen. Wait(0)=intakt/targetbar,
-- alles andere (Break/Broken/Hide) = kaputt -> KEIN Homing-Ziel mehr.
_G.__re4_wb_dead = function(wb)
    if not wb then return true end
    if safe_call(wb, "get_IsBroken") == true then return true end
    local r = safe_call(wb, "get_Routine")
    local ri = type(r) == "number" and r or nil
    if ri == nil and type(r) == "userdata" then
        local ok, v = pcall(function() return r:get_field("value__") end)
        if ok and type(v) == "number" then ri = v end
    end
    return ri ~= nil and ri ~= 0   -- 0 = Wait = intakt; alles andere = kaputt/am brechen
end

-- [LOS 2026-07-09] Synchrone Sichtlinien-Pruefung: freie Sicht von `from` (Auge/Kamera) zu `to` (Ziel)?
-- via.physics.System.castRay (SYNCHRON, id 646610) auf Layer 10 = Welt-Geometrie (Waende/Boden). Liegt eine
-- Wand naeher als das Ziel -> blockiert -> false. Damit peilt das Homing keine Kiste HINTER einer Wand/durch
-- den Boden an. Fail-open: fehlt die Methode oder Fehler -> true (kein Filter, keine Regression).
-- Global (weapons am 200-Local-Limit). Persistentes add_ref'tes Result wiederverwendet (kein Alloc-Spam).
_G.__re4_los_clear = function(from, to)
    if not (from and to) then return true end
    if _G.__re4_los_method == nil then
        _G.__re4_los_method = false
        pcall(function()
            local m = sdk.find_type_definition("via.physics.System")
                :get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
            if m then _G.__re4_los_method = m end
        end)
    end
    if not _G.__re4_los_method then return true end
    local clear = true
    pcall(function()
        local sys = sdk.get_native_singleton("via.physics.System"); if not sys then return end
        if not _G.__re4_los_res then
            _G.__re4_los_res = sdk.create_instance("via.physics.CastRayResult")
            if _G.__re4_los_res then _G.__re4_los_res:add_ref() end
        end
        if not _G.__re4_los_res then return end
        local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
        if dist < 0.05 then return end
        local q = sdk.create_instance("via.physics.CastRayQuery"); if not q then return end
        q:call("setRay(via.vec3, via.vec3)", Vector3f.new(from.x, from.y, from.z), Vector3f.new(to.x, to.y, to.z))
        q:call("clearOptions"); q:call("enableAllHits"); q:call("enableNearSort")
        local fi = q:call("get_FilterInfo")
        if fi then fi:call("set_Group", 0); fi:call("set_MaskBits", 0xFFFFFFFF & ~1); fi:call("set_Layer", 10); q:call("set_FilterInfo", fi) end
        _G.__re4_los_method:call(sys, q, _G.__re4_los_res)
        if (_G.__re4_los_res:call("get_NumContactPoints") or 0) > 0 then
            local cp = _G.__re4_los_res:call("getContactPoint(System.UInt32)", 0)
            local hd = cp and cp:get_field("Distance")
            -- Marge 0.35 m: die Ziel-Oberflaeche selbst (Kiste liegt ja auf Layer 10) darf nicht als "Wand" zaehlen.
            if type(hd) == "number" and hd < (dist - 0.35) then clear = false end
        end
    end)
    return clear
end

local function knife_assist_breakable(from, dir, max_dist, cone_deg)
    if not (from and dir) then return nil end
    if not _idur_td then _idur_td = sdk.typeof("chainsaw.IGimmickDurability") end
    if not _G.__re4_woodbox_td then _G.__re4_woodbox_td = sdk.typeof("chainsaw.GmWoodBoxBase") end
    if not _animal_td then _animal_td = sdk.typeof("chainsaw.GmAnimal") end
    local cone_cos = math.cos(((cone_deg or 20) * math.pi) / 180)
    local best, best_near, best_go = nil, 1e9, nil
    local best_a, best_a_near = nil, 1e9   -- [ANIMAL-PRIO] eigener Tier-Topf; Tiere schlagen Breakables
    -- [DIAG] wieviele Breakables ueberhaupt gefunden, naechstes (egal Kegel), bester Dot -> zeigt, ob die
    -- Kiste erkannt wird und ob nur der Kegel sie verwirft (VR = kein ImGui lesbar -> Log).
    local n_break, dbg_near, dbg_bestdot = 0, 1e9, -2.0
    local hrows = {}   -- [HOMING-LOG 2026-07-09] pro Wurf: jeder gm*-Kandidat + warum (nicht) gepickt
    iter_hitctrl_gos(function(go)
        local nm = safe_call(go, "get_Name")
        if type(nm) == "string" then
            local p2 = nm:sub(1, 2)
            if p2 == "ch" or p2 == "em" or p2 == "wp" then return end   -- Player/Gegner/Waffen aus
            if nm:sub(1, 7) == "ItemDis" then return end                -- Item-Pickup ist kein Breakable
        end
        local woodbox, dur, wb_go = _G.__re4_wb_of(go)   -- self ODER Parent (Before/After -> WoodBox) [nur fuer Diag/best_go]
        local ok = false
        -- [HOMING = NUR WHITELIST 2026-07-09] Das Wurf-Homing zieht AUSSCHLIESSLICH zu Objekten aus
        -- re4_vr_whitelist.lua (Typ ODER Name-Praefix). WoodBox/Durability/Tiere ziehen NICHT mehr an --
        -- steht ein Objekt nicht in der Liste, wird das Messer NICHT dorthin gezogen. Das BRECHEN
        -- (break_nearby) ist davon UNBERUEHRT: per Melee/Aufprall bleibt weiterhin ALLES zerstoerbar.
        -- Gegner laufen ueber __re4_knife_assist_target (separate Funktion) -- hier nicht beruehrt.
        if rawget(_G, "__re4_is_real_breakable_prop") and _G.__re4_is_real_breakable_prop(go) then
            ok = true
            -- [KAPUTT-FILTER 2026-07-09] Bereits zerbrochene Breakables NICHT mehr anpeilen -> das Messer zieht
            -- sonst zur kaputten Kiste statt zur intakten daneben. WoodBox: Routine/IsBroken (wb_dead).
            -- Durability-Gimmick: Rest-Durability <= 0. (Vor der Whitelist filterte der WoodBox-Zweig genau so.)
            if woodbox ~= nil and rawget(_G, "__re4_wb_dead") and _G.__re4_wb_dead(woodbox) then ok = false end
            if ok and dur ~= nil and (tonumber(safe_call(dur, "get_CurrentDurability")) or 0) <= 0 then ok = false end
        end
        -- [ANIMAL-HOMING 2026-07-10] Lebende Tiere (chainsaw.GmAnimal: Kraehen/Huehner etc.) zusaetzlich als
        -- Homing-Ziel ueber den TYP (deckt alle Tiere ab, kein Namens-Scan noetig). TOTE ignorieren. Die
        -- Breakable-Whitelist (oben) bleibt voellig unberuehrt. Reuse _animal_td (wie break_nearby) -> kein neuer Local.
        local is_animal = false
        if not ok and _animal_td then
            local animal = safe_call1(go, "getComponent(System.Type)", _animal_td)
            -- is_animal haelt die GmAnimal-Component (truthy, wie bool) -> unten type_name-Check GmMouse ohne neuen Local.
            if animal and safe_call(animal, "get_IsDead") ~= true then ok = true; is_animal = animal end
        end
        local tf = safe_call(go, "get_Transform"); local pos = tf and safe_call(tf, "get_Position")
        if not pos then return end
        -- [MUENZE] Y-Zielpunkt-Versatz kommt aus re4_vr_whitelist.lua (__re4_breakable_yoff): Muenze haengt am
        -- Pendel -> nach unten; alles andere +0.5 (Kisten-Mitte). AUSGELAGERT -> KEIN neuer Local in weapons (200-Limit).
        -- [ANIMAL-ZIELPUNKT 2026-07-11] Tiere (Kraehe/Huhn) sitzen tief -> Default +0.5 zielt DRUEBER.
        -- Eigener Offset nach unten (__re4_animal_off_y, wie Muenze/Vase). is_animal existiert schon -> kein neuer Local.
        -- [MAUS 2026-07-11] Ratte (GmMouse) sitzt flacher als Kraehe/Huhn -> eigener tieferer Offset via type_name-Check.
        local cx, cy, cz = pos.x, pos.y + (is_animal
            and (type_name(is_animal) == "chainsaw.GmMouse"
                and (tonumber(rawget(_G, "__re4_mouse_off_y")) or -0.5)
                or (tonumber(rawget(_G, "__re4_animal_off_y")) or -0.3))
            or (rawget(_G, "__re4_breakable_yoff") and _G.__re4_breakable_yoff(go) or 0.5)), pos.z
        -- [ANIMAL-CENTER 2026-07-16] Tiere: echter Mesh-Mittelpunkt (GmAnimal->Mesh->WorldAABB->getCenter)
        -- statt der Konstante drueber. Die feste Absenkung zielte INS Gelaender, auf dem der Rabe sitzt
        -- -> los_clear failte -> Tier wurde nie gepickt. Center loest das ohne jeden Offset.
        -- NUR Tiere -- Kisten/Muenzen (breakable_yoff) und Gegner (__re4_enemy_aim_point) bleiben unberuehrt.
        -- Reine Zuweisung auf cx/cy/cz + Helfer als Global in whitelist.lua -> KEIN neuer Local (200-Limit).
        -- Kein Mesh/AABB oder Sanity-Fail -> Helfer gibt die Konstanten-Werte unveraendert zurueck.
        if is_animal and rawget(_G, "__re4_animal_center") then cx, cy, cz = _G.__re4_animal_center(is_animal, cx, cy, cz) end
        local dx, dy, dz = cx - from.x, cy - from.y, cz - from.z
        local d = math.sqrt(dx*dx + dy*dy + dz*dz)
        -- [KEGEL] Kiste sitzt oft tiefer als die Hand -> die vertikale Differenz kippt den 3D-Dot aus dem
        -- engen Kegel, obwohl man horizontal genau draufzielt. Darum den Dot HORIZONTAL (X/Z) messen.
        -- [KEGEL] Horizontaler Dot (X/Z) -> vertikale Blickneigung egal. WICHTIG: caxis MIT normalisieren
        -- (chl), sonst verkleinert die y-Komponente der Blickachse (hier -0.48) den Dot kuenstlich -> Kiste
        -- faellt aus dem Kegel, obwohl man horizontal draufzielt (war der Bug: bestdot 0.75 statt 0.855).
        local hlen = math.sqrt(dx*dx + dz*dz)
        local chl = math.sqrt(dir.x*dir.x + dir.z*dir.z)
        local dot = (hlen > 0.001 and chl > 0.001) and ((dx*dir.x + dz*dir.z) / (hlen*chl)) or -2.0
        -- [BRK-CAND-DIAG] Jeder Nicht-Player/Gegner-Kandidat in Naehe (<=6m): Name + Typ-Flags + Distanz +
        -- Horizontal-Dot zur Wurfachse + ob er als Homing-Ziel taugt (ok). Zeigt, ob DIE Kiste vor dir
        -- ueberhaupt in der HitController-Liste ist, ob sie WoodBox/Durability hat (sonst kein Homing-Ziel),
        -- und ob ihre Richtung positiv (vorne) oder negativ (rechnerisch hinten) ist. TEMP -> nach Fix raus.
        -- [HOMING-LOG] JEDEN gm*-Kandidaten festhalten (egal Distanz): Name, ob Whitelist-Match (ok),
        -- Distanz, Horizontal-Dot, ob im Kegel, ob in Reichweite. Zeigt exakt welches Gate das Fass wirft.
        -- [PRE-WHITELIST-PROBE 2026-07-09] Vor der Whitelist war JEDE WoodBox/Durability ein Homing-Ziel
        -- (Komponenten-Erkennung __re4_wb_of, KEIN Namensfilter). GENAU die logge ich jetzt -- mit dem ECHTEN
        -- Namen (wb_go, oft der Parent der "Before"-Collider), Position (d/dot vom Key-GO), und ob die Whitelist
        -- sie matcht (ok). Zeigt: welche Kiste vor dir ging frueher + wie sie WIRKLICH heisst -> die whitelisten.
        if woodbox ~= nil or dur ~= nil then
            local wbnm = "?"; pcall(function() wbnm = (wb_go or go):call("get_Name") end)
            local adr = ""; pcall(function() adr = string.format(" @0x%X", (wb_go or go):get_address()) end)
            hrows[#hrows + 1] = string.format("  WB key=%s  wbGO=%s%s  ok=%s  d=%.1f  dot=%.3f  cone_ok=%s  range_ok=%s",
                tostring(nm), tostring(wbnm), adr, tostring(ok), d, dot,
                tostring(dot > cone_cos), tostring(d <= (max_dist or 30.0)))
        end
        if ok and d > 0.2 and d <= (max_dist or 30.0) then
            n_break = n_break + 1
            if d < dbg_near then dbg_near = d end
            if dot > dbg_bestdot then dbg_bestdot = dot end
            -- [LOS 2026-07-09] Nur Kandidaten mit FREIER SICHT vom Auge (from) annehmen -> keine Kiste hinter
            -- einer Wand / durch den Boden anpeilen. Cast nur wenn er eh der neue Beste waere (kurzschluss -> selten).
            -- [ANIMAL-PRIO] Tiere in eigenen Topf (best_a); im Return schlagen sie Breakables. Beide GLEICH
            -- gegated: Kegel + freie Sicht (LOS) -> kein Ziel hinter Wand/Boden.
            if dot > cone_cos then
                if is_animal then
                    -- [ANIMAL-GATE 2026-08-11] Zwei Zusatzhuerden NUR fuer Tiere (s. Kommentar bei
                    -- animal_range/animal_max_dy). dy = Hoehen-Ablage des Tiers gegenueber der
                    -- Kegel-Achse auf seiner Distanz -- genau das, was der horizontale Dot nicht sieht.
                    -- Achse selbst normalisieren: dir kommt als HMD-Blick und ist nicht garantiert 1 lang.
                    local akfc = _G.__re4_knife_fly_cfg or {}
                    local alen = math.sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z)
                    local axis_y = (alen > 1e-6) and (from.y + (dir.y / alen) * d) or from.y
                    local a_dy = math.abs(cy - axis_y)
                    if d <= (tonumber(akfc.animal_range) or 8.0)
                       and a_dy <= (tonumber(akfc.animal_max_dy) or 1.0)
                       and d < best_a_near and _G.__re4_los_clear(from, { x = cx, y = cy, z = cz }) then
                        best_a_near = d; best_a = { x = cx, y = cy, z = cz }
                    end
                elseif d < best_near and _G.__re4_los_clear(from, { x = cx, y = cy, z = cz }) then
                    best_near = d; best = { x = cx, y = cy, z = cz }; best_go = wb_go
                end
            end
        end
    end)
    _G.__re4_break_assist_dbg = string.format("nBreak=%d near=%.1f bestdot=%.2f need>%.2f pick=%s",
        n_break, dbg_near, dbg_bestdot, cone_cos, best and string.format("%.1f", best_near) or "nil")
    -- [HOMING-LOG 2026-07-09 WEGWERF] Pro Wurf: alle gm*-Kandidaten + finale Entscheidung ins Log.
    -- [log entfernt]
    -- [ANIMAL-PRIO] Tier > Breakable: lebendes Tier im Kegel (mit LOS) gewinnt, auch wenn eine Kiste naeher
    -- ist. Nur wenn KEIN Tier -> Breakable. (Gegner haben im Aufrufer schon absoluten Vorrang davor.)
    if best_a then return best_a, best_a_near end
    return best, best_near
end

-- [KNIFE_MELEE] Selbst-detektiert: naechstes Ziel (Aim/Nearest) + frische AttackUserData vom Collider
-- + frische DamageUserData -> requestAttack. Der reale Schaden wird per Damage-Calc-Hook korrigiert
-- (siehe __re4_knife_dmg_cb), sonst waere er ~11x zu hoch.
local function do_knife_melee()
    local now = os.clock()
    if now - last_knife_melee_t < 0.2 then return end
    local ok_ks2, ks = pcall(killswitch.is_active)
    if ok_ks2 and ks == true then return end
    last_knife_melee_t = now
    break_nearby()   -- [BREAKABLES] Kisten/Faesser in Klingen-Reichweite zerbrechen (auch ohne Gegner)
    local hc = find_knife_hc()
    if not hc then return end
    local target = knife_pick_target(_G.__re4_knife_hand_world())   -- [KNIFE_HAND] Reichweite ab aktiver Hand
    local atk = hc and knife_get_attack_ud(hc)
    if not target then return end
    if not atk then return end
    local dmg = safe_create("chainsaw.collision.DamageUserData"); if not dmg then return end
    pcall(function() hc:call("set_AttackEnable", true) end)
    -- Marker: die naechste Schadensberechnung (0.1s Fenster) gehoert UNS -> nur die korrigiert der
    -- Damage-Hook. Native RT-Treffer (kein Marker) bleiben voellig unberuehrt.
    _G.__re4_knife_our_until = os.clock() + 0.25
    pcall(function() hc:call("requestAttack", target, atk, dmg) end)
    pcall(function() hc:call("set_AttackEnable", false) end)   -- sofort wieder entschaerfen (nicht dauerhaft scharf)
end
-- [LH_CLONE 2026-07-08] Fuer den Links-Klon-Schwung (re4_vr_knife_lefthand.lua erkennt die Links-Hand-Velocity
-- selbst und ruft das hier auf). do_knife_melee nutzt intern __re4_knife_hand_world (=links im Klon) + den
-- gecachten Messer-HC -> selbe Damage-Pipeline wie rechts, kein Motion-Eingriff.
_G.__re4_do_knife_melee = do_knife_melee

------------------------------------------------------------
-- [KNIFE_THROW / FLIGHT] Das ECHTE Messer fliegt aus der Hand (kein Clone). Die Engine dockt das
-- Messer-GO jeden Frame an die Hand -> wir ueberschreiben seine WELT-Transform im spaeten Pass
-- (gleiche Technik wie Hand-HUDs / ss_place-Clone), damit es der ballistischen Bahn + Tumble folgt.
-- RUECKKEHR gratis: Flug-Ende -> Landepos halten bis return_delay -> Override AUS -> Engine snappt
-- das Messer selbst zurueck in die Hand. Kollision (Gegner/Breakables) nutzt spaeter knife_obj_pos
-- (schon auf die Messer-Objekt-Position umgestellt) -> Stufe 2b.
------------------------------------------------------------
_G.__re4_knife_fly_cfg = _G.__re4_knife_fly_cfg or {
    speed = 12.0, gravity = 7.0, spin = 12.0, max_time = 1.5, return_delay = 0.4, hit_radius = 0.5,
}
_G.__re4_knife_fly_cfg.hit_radius = _G.__re4_knife_fly_cfg.hit_radius or 0.5   -- Backfill (Global ueberlebt Reset)
-- [WURF-OBJEKTRADIUS 2026-07-20] Vasen/Kisten zerbrachen im Flug oft erst beim 2./3. Wurf: die
-- Breakable-Suche lief mit __re4_knife_touch -- demselben Wert wie der STICH. Hochdrehen haette den
-- Nahkampf mitverbogen. Jetzt ein EIGENER Wurf-Wert; Default = bisheriges Verhalten (0.9).
_G.__re4_knife_fly_cfg.break_radius = _G.__re4_knife_fly_cfg.break_radius or (rawget(_G, "__re4_knife_touch") or 0.9)
_G.__re4_knife_fly_cfg.v_min = _G.__re4_knife_fly_cfg.v_min or 4.0    -- [WURF_RANGE] Messer: MIN-Geschwindigkeit (sanfter Wurf)
_G.__re4_knife_fly_cfg.v_max = _G.__re4_knife_fly_cfg.v_max or 14.0   -- [WURF_RANGE] Messer: MAX-Geschwindigkeit (voller Wurf)
_G.__re4_knife_fly_cfg.spin_fly  = _G.__re4_knife_fly_cfg.spin_fly  or 5.0    -- [SALTO] vor dem Treffer: langsamer, sauberer Ueberschlag (Messerwerfer)
_G.__re4_knife_fly_cfg.spin_fall = _G.__re4_knife_fly_cfg.spin_fall or 22.0   -- [SALTO] nach dem Treffer: wildes Taumeln beim Fallen
_G.__re4_knife_fly_cfg.arm_clear = _G.__re4_knife_fly_cfg.arm_clear or 0.7    -- [ARM_CLEAR] erst ab dieser Strecke vom Wurf-Ursprung zaehlt Kollision (nicht den eigenen Koerper treffen)
-- [TOTZONE 2026-08-12] Genau diese arm_clear-Strecke war blind: der Kollisions-Fuehler ist die ersten
-- 0,7 m aus, also flog das Messer durch einen Gegner DIREKT vor der Nase hindurch, ohne ihn zu bemerken.
-- In dieser Zone greift statt des Fuehlers eine kleine Kugel um die Klinge, die NUR Gegner sieht
-- (Waende/Kisten macht weiter allein der Strahl). Gemessen wird zur Gegner-BRUST (pick misst +0.9y),
-- 0,5 m ist also Koerperkontakt und kein Einzugsbereich. 0 = aus, exakt das alte Verhalten.
_G.__re4_knife_fly_cfg.close_hit_radius = _G.__re4_knife_fly_cfg.close_hit_radius or 0.5
_G.__re4_knife_fly_cfg.spin_ax = _G.__re4_knife_fly_cfg.spin_ax or 1.0                       -- [SALTO] freie lokale Ueberschlag-Achse (X/Y/Z frei tunen)
_G.__re4_knife_fly_cfg.spin_ay = _G.__re4_knife_fly_cfg.spin_ay or 0.0
_G.__re4_knife_fly_cfg.spin_az = _G.__re4_knife_fly_cfg.spin_az or 0.0
-- [SALTO_L] EIGENSTAENDIGE Salto-Achse fuer den LINKS-Wurf (Klon, ganz andere Ausgangslage). 3 globale
-- Slider fuer ALLE Links-Messer, voellig getrennt von rechts (kein Fallback auf die Rechts-Werte).
_G.__re4_knife_fly_cfg.spin_ax_l = _G.__re4_knife_fly_cfg.spin_ax_l or 1.0
_G.__re4_knife_fly_cfg.spin_ay_l = _G.__re4_knife_fly_cfg.spin_ay_l or 0.0
_G.__re4_knife_fly_cfg.spin_az_l = _G.__re4_knife_fly_cfg.spin_az_l or 0.0
_G.__re4_knife_fly_cfg.dir_max_deg = _G.__re4_knife_fly_cfg.dir_max_deg or 90                -- [RICHTUNGS-CLAMP] max Abweichung von der Blickrichtung (90=frei)
-- [KEGEL] Basis-Flug = Handrichtung (B). Der Kegel um char_forward macht NUR das graduelle Homing.
-- hmd_force war der Kalibrier-Modus (Force-Flug in char_forward) -> jetzt AUS. yaw/pitch bleiben als
-- Fein-Korrektur der KEGEL-ACHSE (char_forward) nutzbar.
if _G.__re4_knife_fly_cfg.hmd_force == nil then _G.__re4_knife_fly_cfg.hmd_force = false end
_G.__re4_knife_fly_cfg.hmd_yaw   = _G.__re4_knife_fly_cfg.hmd_yaw   or 0.0                    -- [KEGEL] Yaw-Korrektur der Kegel-Achse (Grad)
_G.__re4_knife_fly_cfg.hmd_pitch = _G.__re4_knife_fly_cfg.hmd_pitch or 0.0                    -- [KEGEL] Pitch-Korrektur der Kegel-Achse (Grad)
_G.__re4_knife_fly_cfg.assist_cone_inner_deg = _G.__re4_knife_fly_cfg.assist_cone_inner_deg or 8.0  -- [KEGEL] Voll-Lock-Winkel (innen = 100% Homing)
_G.__re4_knife_fly_cfg.assist_target_off_y = _G.__re4_knife_fly_cfg.assist_target_off_y or 0.0       -- [CENTER] Ziel-Hoehen-Offset ab Center (m, +hoch/-runter)
_G.__re4_knife_fly_cfg.assist_strength = _G.__re4_knife_fly_cfg.assist_strength or 0.0       -- [ZIELHILFE A] Anfangs-Korrektur der Wurfrichtung (einmalig): 0=roh, 1=direkt aufs Ziel
_G.__re4_knife_fly_cfg.assist_homing = _G.__re4_knife_fly_cfg.assist_homing or 0.05          -- [ZIELHILFE B] In-Flug-Homing pro Frame: 0=reine Physik/verfehlbar, hoch=Auto-Lock (kompoundiert)
_G.__re4_knife_fly_cfg.assist_cone_deg = _G.__re4_knife_fly_cfg.assist_cone_deg or 20.0      -- [ZIELHILFE] Einfang-Winkel: wie weit daneben ein Gegner noch gefangen wird
-- [NAHFANG 2026-08-12] Der Kegel misst einen WINKEL, das Nahproblem ist aber eins in METERN: 9,4 Grad
-- sind auf 2 m nur +-0,33 m, auf 10 m +-1,65 m -> der Gegner direkt vor der Nase faellt bei einem halben
-- Schritt Versatz aus dem Kegel, der weiter hinten bleibt drin und wird zum "naechsten Ziel im Kegel".
-- assist_min_lat = seitlicher Mindest-Schlauch (m) um die Kegel-Achse, der ZUSAETZLICH zum Winkel gilt:
-- gefangen wird, wenn lat <= max(assist_min_lat, d*tan(cone)). Ab d = min_lat/tan(cone) (bei 0,6 m und
-- 9,4 Grad ~3,6 m) gewinnt wieder der reine Winkel -> auf Distanz aendert sich nichts.
_G.__re4_knife_fly_cfg.assist_min_lat = _G.__re4_knife_fly_cfg.assist_min_lat or 0.6
-- [STECKZEIT 2026-08-13] Wie lange das Messer nach einem TREFFER im Ziel steckt, bevor es
-- zurueckkommt. Bisher nur ein Code-Default (0.12 = praktisch sofort). Der zweite Wert
-- `return_delay` gilt fuer den Fall OHNE Treffer und bleibt davon unberuehrt.
-- [GLEICHZUG 2026-08-14] Steckzeit nach einem Treffer -- gilt jetzt fuer BEIDE Messer.
-- Die 0.12, die frueher im Code fuer rechts stand, war praktisch WIRKUNGSLOS: bei Ray-Treffern hat
-- `return_t = jetzt + return_delay` (0.4) sie sofort ueberschrieben. Das rechte Messer steckte also
-- real 0.4 s, nicht 0.12 s. Seit dieses Ueberschreiben raus ist, wuerde die 0.12 zum ersten Mal
-- wirklich greifen -- viel zu schnell. Deshalb fuer beide 0.7.
_G.__re4_knife_fly_cfg.hit_return_delay = _G.__re4_knife_fly_cfg.hit_return_delay or 0.7
-- Einmalige Migration: das Global ueberlebt "Reset Scripts", ein `or` greift also nicht mehr. Nur der
-- Zwischenstand 0.12 von vorhin wird nachgezogen; ein selbst eingestellter Wert bleibt unangetastet.
if _G.__re4_knife_fly_cfg.hit_return_delay == 0.12 then _G.__re4_knife_fly_cfg.hit_return_delay = 0.7 end
-- [SICHTBARKEIT 2026-08-14] Wie lange das Messer nach dem Einschlag noch SICHTBAR steckt, bevor das
-- Mesh ausgeblendet wird. Vorher gab es das gar nicht: bei einem Treffer blieb es sichtbar, bis es
-- zurueck in die Hand sprang -- Sichtbarkeit und Rueckkehr hingen am selben Zeitpunkt. Jetzt getrennt:
-- kurz nach dem Einschlag-Sound verschwindet die Klinge, die Rueckkehr bleibt bei hit_return_delay.
_G.__re4_knife_fly_cfg.hit_visible = _G.__re4_knife_fly_cfg.hit_visible or 0.15
_G.__re4_knife_fly_cfg.assist_flatten = _G.__re4_knife_fly_cfg.assist_flatten or 0.0         -- [ZIELHILFE] Bogen-Ausgleich beim assistierten Wurf: 0=voller Bogen (Fall), 1=gerade (kein Fall) -> gegen den Reichweiten-Abfall
_G.__re4_knife_fly_cfg.max_range = _G.__re4_knife_fly_cfg.max_range or 12.0                   -- [WURF_RANGE] max horizontale Wurfweite (m): danach faellt das Messer IMMER zu Boden (Homing/Bogen-Ausgleich aus, horizontal gestoppt)
-- [ANIMAL-GATE 2026-08-11] Tiere (GmAnimal) wurden bis 30 m und mit dem vollen Zielhilfe-Winkel
-- angezogen -- und weil der Kegel bewusst NUR HORIZONTAL misst (die vertikale Ablage faellt raus,
-- damit tief stehende Kisten nicht rauskippen), zaehlte auch ein Wurf METERWEIT DRUEBER als
-- "genau draufgezielt": das Homing holte das Messer runter und das Huhn starb. Zwei eigene Gates,
-- die NUR fuer Tiere gelten -- Gegner und Breakables bleiben voellig unberuehrt:
--   animal_range  = eigene, kurze Reichweite (statt der 30 m des Aufrufers)
--   animal_max_dy = maximale HOEHEN-Ablage des Tiers zur Kegel-Achse; das ist das Gate,
--                   das den Hochwurf ueberhaupt erst aussortiert.
_G.__re4_knife_fly_cfg.animal_range  = _G.__re4_knife_fly_cfg.animal_range  or 8.0
_G.__re4_knife_fly_cfg.animal_max_dy = _G.__re4_knife_fly_cfg.animal_max_dy or 1.0
-- [HOEHENFENSTER 2026-08-12] Die beiden Werte darueber begrenzen nur die ZIELWAHL. Kaputt gemacht hat
-- es trotzdem der Radius-Scan im Flug, und der misst ausschliesslich X/Z -- ein Wurf METERWEIT ueber
-- einer Kiste, einem Fass oder einem Huhn zaehlte deshalb als Treffer. Das hier ist der maximale
-- Hoehenunterschied zwischen Messer und Objekt-Root, ab dem der Flug-Scan gar nichts mehr trifft --
-- fuer ALLE Objekte gleich, keine Sonderregel fuer Tiere. Gilt nur im Flug: der Messer-STICH ruft
-- break_nearby ohne diesen Parameter auf und trifft weiter alles in Klingenreichweite.
-- Bewusst ohne Regler, reine Code-Konstante. 0 = aus (altes Verhalten).
_G.__re4_knife_fly_cfg.hit_max_dy = _G.__re4_knife_fly_cfg.hit_max_dy or 1.0
-- Rand um die Mesh-Box, ab dem ein Flug-Treffer zaehlt (die Box ist die echte Objektgroesse).
_G.__re4_knife_fly_cfg.hit_margin = _G.__re4_knife_fly_cfg.hit_margin or 0.15
-- Eigener, engerer Vorauswahl-Radius fuer Tiere (der allgemeine 0,7-m-Radius ist fuer ein Huhn absurd).
_G.__re4_knife_fly_cfg.animal_touch = _G.__re4_knife_fly_cfg.animal_touch or 0.35
local kfly = { active = false }

-- [KNIFE_RAY] Kollisions-Raycast in FLUGRICHTUNG (Wand + Boden -> Messer bleibt stecken statt durchzufliegen).
-- STRIKT nach dem crosshair-Muster: EIN persistentes, add_ref'tes Result (kfly.ray). Es wird NUR ein neuer
-- Strahl gefeuert, wenn der vorige get_Finished == true ist -> KEINE ueberlappenden async-Strahlen. Genau
-- das (jeden Frame neu feuern ohne Finished-Check) hatte vorher gecrasht. Layer 10 = Welt-Geometrie.
local _kray_method = nil
pcall(function()
    _kray_method = sdk.find_type_definition("via.physics.System")
        :get_method("castRayAsync(via.physics.CastRayQuery, via.physics.CastRayResult)")
end)
local function knife_ray_fire(from, to)
    if not _kray_method then return false end
    local ok = pcall(function()
        local sys = sdk.get_native_singleton("via.physics.System"); if not sys then error("nosys") end
        if not kfly.ray then
            kfly.ray = sdk.create_instance("via.physics.CastRayResult")
            if kfly.ray then kfly.ray:add_ref() end
        end
        if not kfly.ray_wall then
            kfly.ray_wall = sdk.create_instance("via.physics.CastRayResult")
            if kfly.ray_wall then kfly.ray_wall:add_ref() end
        end
        if not kfly.ray or not kfly.ray_wall then error("nores") end
        -- [DAMAGE_FILTER] Strahl 1: vorgefertigtes "DamageCheckOtherThanPlayer" -> Gegner-Hurtboxen + Kisten.
        if _G.__re4_dmg_filter == nil then
            _G.__re4_dmg_filter = false
            pcall(function()
                local ftd = sdk.find_type_definition(sdk.game_namespace("CollisionUtil.Filter"))
                local f = ftd and ftd:get_field("DamageCheckOtherThanPlayer")
                if f then _G.__re4_dmg_filter = f:get_data(nil) end
            end)
        end
        local q = sdk.create_instance("via.physics.CastRayQuery"); if not q then error("noq") end
        q:call("setRay(via.vec3, via.vec3)", from, to)
        q:call("clearOptions"); q:call("enableAllHits"); q:call("enableNearSort")
        if _G.__re4_dmg_filter then
            q:call("set_FilterInfo", _G.__re4_dmg_filter)
        else
            local fi = q:call("get_FilterInfo")
            if fi then fi:call("set_Group", 0); fi:call("set_MaskBits", 0xFFFFFFFF & ~1); fi:call("set_Layer", 5); q:call("set_FilterInfo", fi) end
        end
        _kray_method:call(sys, q, kfly.ray)
        -- [TERRAIN] Strahl 2: Welt-Geometrie (Layer 10) -> Waende/Boden, damit das Messer aufprallt/steckt.
        local q2 = sdk.create_instance("via.physics.CastRayQuery"); if not q2 then error("noq2") end
        q2:call("setRay(via.vec3, via.vec3)", from, to)
        q2:call("clearOptions"); q2:call("enableAllHits"); q2:call("enableNearSort")
        local fi2 = q2:call("get_FilterInfo")
        if fi2 then fi2:call("set_Group", 0); fi2:call("set_MaskBits", 0xFFFFFFFF & ~1); fi2:call("set_Layer", 10); q2:call("set_FilterInfo", fi2) end
        _kray_method:call(sys, q2, kfly.ray_wall)
    end)
    return ok
end
local function knife_ray_finished()
    local f = false
    pcall(function()
        f = (kfly.ray ~= nil) and (kfly.ray:call("get_Finished") == true)
            and (kfly.ray_wall ~= nil) and (kfly.ray_wall:call("get_Finished") == true)
    end)
    return f
end
-- Ein CastRayResult auswerten: Distanz + Normale-Y + getroffenes GameObject.
local function knife_read_ray(res)
    local d, ny, hitgo = nil, nil, nil
    pcall(function()
        if not res or (res:call("get_NumContactPoints") or 0) <= 0 then return end
        local cp = res:call("getContactPoint(System.UInt32)", 0); if not cp then return end
        d = cp:get_field("Distance")
        local n = cp:get_field("Normal")
        if n then ny = n.y end
        local col = res:call("getContactCollidable", 0)
        if col then hitgo = col:call("get_GameObject") end
    end)
    return d, ny, hitgo
end
-- Beide Strahlen (Damage + Terrain) auswerten -> der NAEHERE Treffer gewinnt. Rueckgabe:
-- Distanz, Normale-Y, getroffenes GO, is_wall (true = Terrain/Wand/Boden, false = Gegner/Kiste).
local function knife_ray_hit_dist()
    local dd, dny, dgo = knife_read_ray(kfly.ray)        -- Damage (Gegner/Kiste)
    local wd, wny, wgo = knife_read_ray(kfly.ray_wall)   -- Terrain (Wand/Boden)
    if dd and (not wd or dd <= wd) then
        return dd, dny, dgo, false
    elseif wd then
        return wd, wny, wgo, true
    end
    return nil
end

local function kfly_axis_angle(ax, a)
    local h = a * 0.5; local s = math.sin(h)
    return Quaternion.new(math.cos(h), ax.x * s, ax.y * s, ax.z * s)
end
-- [LANDE_POSE] Euler (rad) -> Quaternion, fuer die feste Ruhe-Pose des gelandeten Messers.
local function kfly_euler(rx, ry, rz)
    local cx,sx = math.cos(rx*0.5), math.sin(rx*0.5)
    local cy,sy = math.cos(ry*0.5), math.sin(ry*0.5)
    local cz,sz = math.cos(rz*0.5), math.sin(rz*0.5)
    return Quaternion.new(cx*cy*cz+sx*sy*sz, sx*cy*cz-cx*sy*sz, cx*sy*cz+sx*cy*sz, cx*cy*sz-sx*sy*cz)
end
-- [LANDE_POSE] Welt-Rotation, die das gelandete Messer flach/steckend hinlegt (tunebar via Slider, rad).
_G.__re4_knife_land_rot = _G.__re4_knife_land_rot or { rx = 1.5708, ry = 0.0, rz = 0.0 }

-- [KNIFE_HAND 2026-07-07] Weltposition der Hand, die das Messer GERADE haelt (links vs rechts). Global
-- (kein neuer top-level local -> 200-Limit unberuehrt). Fallback rechts, wenn links (noch) nicht publiziert.
_G.__re4_knife_hand_world = function()
    -- [LH_CLONE] Klon-Modus = Messer in der LINKEN Hand (nicht equippt) -> ebenfalls die linke Hand.
    if rawget(_G, "__re4_knife_hand") == "left" or rawget(_G, "__re4_knife_left_clone") == true then
        local l = rawget(_G, "__vr_lh_world"); if l then return l end
    end
    return rawget(_G, "__vr_rh_world")
end

-- Wurf starten: aktuelle Messer-GO-Transform als Startpunkt, Flug-Velocity = dir * speed (velocity-abhaengig).
local function knife_throw_launch(dir, speed)
    if kfly.active or not dir then return end
    -- [LH_CLONE WURF] Im Klon-Modus fliegt das KLON-GO (kein equipptes Messer). Von L_Hand loesen -> frei.
    local go, tf
    if rawget(_G, "__re4_knife_left_clone") == true then
        go = rawget(_G, "__re4_knife_lh_clone_go"); if not go then return end
        tf = safe_call(go, "get_Transform"); if not tf then return end
        pcall(function() tf:call("set_Parent(via.Transform)", nil) end)   -- Klon von der Hand loesen
        kfly.clone_throw = true
    else
        local hc = find_knife_hc(); if not hc then return end
        go = safe_call(hc, "get_GameObject"); if not go then return end
        tf = safe_call(go, "get_Transform"); if not tf then return end
        kfly.clone_throw = false
    end
    -- [SALTO_L] Links-Wurf merken (Klon ODER equipptes Links-Messer) -> eigene Salto-Achse im Flug.
    kfly.is_left = kfly.clone_throw or (rawget(_G, "__re4_knife_hand") == "left")
    local p = safe_call(tf, "get_Position"); if not p then return end
    local r = safe_call(tf, "get_Rotation")
    local cfg = _G.__re4_knife_fly_cfg
    local spd = speed or cfg.speed or 12.0   -- [WURF_RANGE] velocity-abhaengige Geschwindigkeit
    kfly.go, kfly.tf = go, tf
    -- [START_POS] Die Objekt-Root ist NICHT die sichtbare Klinge: das Mesh haengt am Hand-Joint, die Root
    -- behaelt unseren letzten Flug-/Boden-Wert (stale). Deshalb IMMER von der echten Hand-Weltposition
    -- (aktive Messer-Hand, jeden Frame frisch) starten, nie von der gelesenen Root. Links -> __vr_lh_world.
    local rh = _G.__re4_knife_hand_world()
    if rh then
        kfly.pos = Vector3f.new(rh.x, rh.y, rh.z)
    else
        kfly.pos = Vector3f.new(p.x, p.y, p.z)   -- Fallback (nur wenn Hand-Pose fehlt)
    end
    kfly.start_pos = Vector3f.new(kfly.pos.x, kfly.pos.y, kfly.pos.z)   -- [ARM_CLEAR] Wurf-Ursprung (Hand)
    kfly.vel = Vector3f.new(dir.x * spd, dir.y * spd, dir.z * spd)
    -- Tumble-Achse = senkrecht zu Flugrichtung und Welt-Hoch (Messer ueberschlaegt sich vorwaerts)
    local axx = dir.y * 0 - dir.z * 1
    local axy = dir.z * 0 - dir.x * 0
    local axz = dir.x * 1 - dir.y * 0
    local al = math.sqrt(axx*axx + axy*axy + axz*axz)
    if al < 0.001 then axx, axy, axz, al = 1, 0, 0, 1 end
    kfly.axis = Vector3f.new(axx/al, axy/al, axz/al)
    -- [SALTO] wilde Taumel-Achse fuer die Fall-Phase nach dem Treffer: saubere Achse gegen
    -- Flugrichtung + Welt-Hoch verkippt -> unkontrolliertes Segeln statt sauberer Ueberschlag
    local fx = axx/al + dir.x * 0.7
    local fy = axy/al + dir.y * 0.7 + 0.4
    local fz = axz/al + dir.z * 0.7
    local fl = math.sqrt(fx*fx + fy*fy + fz*fz)
    if fl < 0.001 then fx, fy, fz, fl = 0, 1, 0, 1 end
    kfly.axis_fall = Vector3f.new(fx/fl, fy/fl, fz/fl)
    kfly.base_rot = r and Quaternion.new(r.w, r.x, r.y, r.z) or Quaternion.new(1, 0, 0, 0)
    kfly.ang = 0.0
    kfly.active = true
    kfly.phase = "fly"
    kfly.hit_done = false
    kfly.hit_t = nil            -- [SICHTBARKEIT] frischer Wurf -> kein alter Einschlag-Zeitpunkt
    kfly.flat = tonumber(rawget(_G, "__re4_knife_assist_flat")) or 0.0   -- [ZIELHILFE] Bogen-Ausgleich fuer DIESEN Wurf (0=voll, 1=gerade)
    kfly.home = rawget(_G, "__re4_knife_home")                            -- [HOMING] Ziel (Brust) fuer die Flug-Lenkung (nil = aus)
    kfly.home_ctx = rawget(_G, "__re4_knife_home_ctx")                    -- [LIVE] Gegner-Context -> Ziel folgt der Bewegung
    kfly.home_str = tonumber(rawget(_G, "__re4_knife_home_str")) or 0.0
    kfly.ray_pending = false   -- [KNIFE_RAY] frischer Wurf -> kein laufender Strahl
    kfly.wall_hit = false       -- [WALL_HIT] noch kein Einschlag
    kfly.min_enemy_d = 1e9      -- [DIAG] engster Abstand zum naechsten Gegner waehrend des Fluges
    kfly.min_bone_d = 1e9       -- [DIAG] engster Knochen-Abstand (falls Gegner < 2m ran kam)
    kfly.detached = false       -- [ZITTER_FIX] frischer Wurf -> Parent noch dran (wird beim Einschlag geloest)
    kfly.hidden = false         -- [MESH_HIDE] frischer Wurf -> Mesh sichtbar; falls ein alter Flug es aus liess, an
    _G.__re4_knife_mesh_vis(true)
    kfly.saved_parent = nil
    -- Boden-Referenz = Player-Fuss-Y (Context-Position). Das Messer faellt nach Kollision/Zeit dorthin.
    -- WICHTIG: floor_y NIE ueber der Wurf-Startposition (p.y). Sonst rastet das Messer sofort ein, wenn
    -- die Hand tiefer als der gemessene Player-Punkt startet (Player-ctx-Y ist nicht immer der Fuss) ->
    -- "Messer fliegt nicht". Mindestens 1.0m unter dem Start als Boden ansetzen.
    local pctx = get_player_ctx()
    local ppos = pctx and safe_call(pctx, "get_Position")
    local start_y = kfly.pos.y   -- Hand-Startposition (NICHT die stale Root)
    local foot = (ppos and ppos.y) or (start_y - 1.5)
    -- [FLOOR] floor_y ist nur ein tiefer NOTFALL-Boden (Spielerfuss minus Puffer). Der ECHTE Landeboden
    -- wird vom Vorwaerts-Raycast bestimmt (is_floor -> floor_y = Trefferpunkt), damit das Messer auch auf
    -- ABFALLENDEM Gelaende auf der echten Geometrie landet statt bei Spielerhoehe zu klemmen.
    kfly.floor_y = foot - 3.0
    local now = os.clock()
    kfly.last_t = now
    kfly.min_fly_until = now + 0.15   -- [MIN_FLY] Boden-Check erst nach kurzer Flugzeit (kein Sofort-rest)
    kfly.end_t = now + (cfg.max_time or 3.0)
    kfly.return_t = 0
    kfly.snd_return = false   -- [RUECKKEHR-SOUND] frisch pro Wurf: kein Rest-Flag vom vorherigen Flug
end

-- [FLIGHT TARGET] Praezise Ziel-Erkennung fuer das GEWORFENE Messer: messe das Messer-OBJEKT
-- (Flug-Position) zum TATSAECHLICHEN KOERPER eines LEBENDEN Gegners (naechster Knochen), nicht
-- zu einem festen Mittelpunkt. So werden Leichen, Huehner und "nearest-center"-Fehltreffer vermieden.

-- Nur echte, lebende Gegner: kein Corpse (IsProcessedCharacterOnDead), nicht eliminiert, HitPoint live.
local function is_live_enemy(ectx)
    if not ectx then return false end
    if safe_call(ectx, "get_Valid") == false then return false end
    if safe_call(ectx, "get_IsEliminated") == true then return false end
    if safe_call(ectx, "get_IsProcessedCharacterOnDead") == true then return false end
    local hp = safe_call(ectx, "get_HitPoint"); if not hp then return false end
    if safe_call(hp, "get_IsLive") ~= true then return false end
    if (tonumber(safe_call(hp, "get_CurrentHitPoint")) or 0) <= 0 then return false end
    return true
end

-- Kleinster Abstand von kp zu irgendeinem Knochen (Child-Transform) unter root_tf (Tiefe/Anzahl
-- begrenzt fuer Performance). = "beruehrt das Messer wirklich den Koerper?".
local function nearest_bone_dist(root_tf, kp)
    if not root_tf then return 999 end
    local best, checked = 1e9, 0
    local function walk(t, depth)
        if not t or depth > 4 or checked >= 120 then return end
        checked = checked + 1
        local pos = safe_call(t, "get_Position")
        if pos then
            local dx, dy, dz = kp.x - pos.x, kp.y - pos.y, kp.z - pos.z
            local d = dx*dx + dy*dy + dz*dz
            if d < best then best = d end
        end
        local child = safe_call(t, "get_Child"); local s = 0
        while child and s < 32 and checked < 120 do
            walk(child, depth + 1)
            child = safe_call(child, "get_Next"); s = s + 1
        end
    end
    walk(root_tf, 0)
    return math.sqrt(best)
end
-- [GEMEINSAM 2026-08-14] Der LINKE Klon soll exakt so treffen wie das rechte Messer. Statt in weapons2
-- eine zweite Geometrie zu pflegen (Kugel/Zylinder/Kasten -- alle drei scheiterten an demselben
-- Zielkonflikt: gross genug fuer die ARME heisst zwangslaeufig zu weit VOR dem Koerper), benutzt der
-- Klon ab jetzt DIESE Funktion mit. Ein Knochen hat keinen Zielkonflikt: Arme, Kopf und Beine bringen
-- ihre eigenen Joints mit. Funktion selbst unveraendert -- sie ist im rechten Wurf bewaehrt.
_G.__re4_nearest_bone_dist = nearest_bone_dist

-- Naechster LEBENDER Gegner, dessen KOERPER (Knochen) innerhalb reach der Flug-Position liegt.
local function knife_flight_pick_enemy(kp, reach)
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and safe_call(cm, "get_EnemyContextList")
    local count = list and (tonumber(safe_call(list, "get_Count")) or 0) or 0
    local pre = reach * 4.0            -- Vorfilter: nur Gegner grob in Naehe bone-scannen
    local best_go, best_d, best_kind = nil, reach, nil
    for i = 0, count - 1 do
        local ectx = safe_call1(list, "get_Item", i)
        if is_live_enemy(ectx) then
            local rpos = safe_call(ectx, "get_Position")
            local go = safe_call(ectx, "get_BodyGameObject")
            local tf = go and safe_call(go, "get_Transform")
            if rpos and tf then
                local dx, dy, dz = rpos.x - kp.x, rpos.y - kp.y, rpos.z - kp.z
                local cd = math.sqrt(dx*dx + dy*dy + dz*dz)
                if cd < (kfly.min_enemy_d or 1e9) then kfly.min_enemy_d = cd end   -- [DIAG] closest center approach
                if (dx*dx + dy*dy + dz*dz) <= pre*pre then
                    local bd = nearest_bone_dist(tf, kp)
                    if bd < (kfly.min_bone_d or 1e9) then kfly.min_bone_d = bd end -- [DIAG] closest bone approach
                    if bd <= best_d then
                        best_d, best_go = bd, go
                        best_kind = safe_call(ectx, "get_KindID")
                    end
                end
            end
        end
    end
    return best_go
end

-- [FLIGHT COLLISION] An der Flug-Position treffen, mit EIGENEM engen Radius (cfg.hit_radius):
-- Breakables via break_nearby(pos, radius). Gegner via knife_flight_pick_enemy (lebend + Knochen-
-- Distanz -> KEIN Aim-Shortcut, keine Leichen/Huehner-nearest-Fehltreffer).
-- Gegner nur EINMAL treffen (hit_done); danach faellt das Messer gerade runter (Salto stoppt).
-- Sucht am gegebenen Punkt einen lebenden Gegner (Knochen-Distanz) und fuegt EINMALIG Schaden zu.
-- Rueckgabe true, wenn ein Gegner getroffen wurde. Wird sowohl vom engen Flug-Collide als auch vom
-- Raycast-Einschlag (mit groesserem Radius fuer die Collider-Dicke) genutzt.
-- [SOFORT-RUECKKEHR 2026-07-09] Bei JEDEM Treffer (Gegner ODER Breakable): nicht die Restflugdauer
-- weiterfliegen/-fallen, sondern SOFORT in die Rest-Phase + kurze Stick-Zeit, dann zurueck in die Hand.
-- Gilt fuer BEIDE Haende (rechter Wurf + Links-Klon laufen durch dieselbe kfly-Flugmaschine).
-- Stick-Dauer: BEIDE Messer = cfg.hit_return_delay (0.7s). Die frueher hier stehende 0.12 fuer rechts
-- war wirkungslos -- sie wurde bei Ray-Treffern von `return_delay` (0.4) ueberschrieben.
-- GLOBAL (kein neuer Top-Level-Local -> weapons.lua ist am 200-Local-Limit!). Closure faengt kfly als Upvalue.
_G.__re4_knife_flight_mark_hit = function()
    kfly.hit_done = true
    kfly.hit_t = os.clock()   -- [SICHTBARKEIT] Startpunkt fuer hit_visible (Mesh ausblenden nach dem Einschlag)
    kfly.vel.x, kfly.vel.z = 0, 0
    if kfly.phase ~= "rest" then
        kfly.phase = "rest"
        local cfg = _G.__re4_knife_fly_cfg or {}
        -- [STECKZEIT 2026-08-13] Gilt NUR fuer das linke (Klon-)Messer. Der rechte Wurf behaelt seine
        -- bisherigen 0.12 s -- daran wurde nie etwas geaendert, und ein laengeres Stecken waere dort eine
        -- Verhaltensaenderung, die niemand bestellt hat. `clone_throw` ist genau die Unterscheidung.
        -- [GLEICHZUG 2026-08-14] Beide Messer nehmen denselben Wert -- der Klon-Sonderfall ist raus.
        kfly.return_t = os.clock() + (tonumber(cfg.hit_return_delay) or 0.7)
    end
end

local function knife_try_hit_enemy(pos, reach)
    if kfly.hit_done then return false end
    -- [LH_CLONE WURF] Klon: kein aktiver Messer-HC/requestAttack -> direkter Schaden am naechsten Gegner zur Flug-Pos.
    if kfly.clone_throw == true then
        local f = rawget(_G, "__re4_knife_direct_damage_at")
        -- [TREFFERDISTANZ 2026-08-14] Vorher `math.max(reach, 1.5)`: der Klon-Wurf buchte den Treffer,
        -- sobald das Messer 1,5 m von der KOERPERMITTE weg war (pick_nearest_enemy misst gegen p.y+0.9,
        -- nicht gegen die Oberflaeche) -- das Messer blieb sichtbar einen halben Meter VOR dem Gegner
        -- stehen und verschwand dort. Jetzt regelt allein cfg.hit_radius, wie es Z.2589 ohnehin vorsieht.
        if type(f) == "function" and f(pos, cfg.hit_radius or 0.5) then
            _G.__re4_knife_flight_mark_hit()   -- [SOFORT-RUECKKEHR] Treffer -> kurz stecken, dann zurueck
            return true
        end
        return false
    end
    local hc = find_knife_hc(); if not hc then return false end
    local target = knife_flight_pick_enemy(pos, reach); if not target then return false end
    local atk = knife_get_attack_ud(hc); if not atk then return false end
    local dmg = safe_create("chainsaw.collision.DamageUserData"); if not dmg then return false end
    pcall(function() hc:call("set_AttackEnable", true) end)
    _G.__re4_knife_our_until = os.clock() + 0.25
    pcall(function() hc:call("requestAttack", target, atk, dmg) end)
    pcall(function() hc:call("set_AttackEnable", false) end)
    _G.__re4_knife_flight_mark_hit()   -- [SOFORT-RUECKKEHR] Treffer -> kurz stecken, dann zurueck (statt runterfallen)
    return true
end

-- [LH_CLONE ZERO-PRIME 2026-07-08] Klon-Schaden OHNE vorherigen Rechts-Treffer. Der rechte Flug-Treffer beweist:
-- HC:requestAttack(ziel-GO, atk, dmg) landet DIREKT am uebergebenen Gegner-GO (kein Collider-Overlap noetig).
-- Im Klon-Modus liefert find_knife_hc einen gemounteten Messer-HC (das Messer sitzt am Body, auch geholstert)
-- + knife_get_attack_ud dessen Angriffs-Userdata -> nativer Schaden inkl. Effekte/Blut, KEIN Template noetig.
-- Rueckgabe true = requestAttack ausgefuehrt (Ziel im reach). Global -> kein neuer Top-Level-Local (200-Limit).
_G.__re4_knife_clone_attack_at = function(pos, reach)
    if not pos then _G.__re4_knife_clone_dbg = "nopos"; return false end
    -- [TORSO 2026-07-08] Gegner-Wurzel sitzt an den FUESSEN; die Hand ist auf Brusthoehe. Distanz zu den Fuessen
    -- ueberschreitet 1.2m schon beim direkten Zustechen -> Ziel wurde nie gefunden. Deshalb hier gegen die
    -- Gegner-Brust (+0.9y) messen und grosszuegiger Radius. Inline (kein find_nearest_enemy_go, das misst Fuesse).
    local rr = reach or 1.8; if rr < 1.6 then rr = 1.6 end
    local cm = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
    local list = cm and safe_call(cm, "get_EnemyContextList")
    if not list then _G.__re4_knife_clone_dbg = "nolist"; return false end
    local cnt = tonumber(safe_call(list, "get_Count")) or 0
    local go, d = nil, rr
    for i = 0, cnt - 1 do
        local ctx = safe_call1(list, "get_Item", i)
        local ego = ctx and safe_call(ctx, "get_GameObject")
        local etf = ego and safe_call(ego, "get_Transform")
        local ep  = etf and safe_call(etf, "get_Position")
        if ep then
            local dx, dy, dz = ep.x - pos.x, (ep.y + 0.9) - pos.y, ep.z - pos.z
            local dd = math.sqrt(dx*dx + dy*dy + dz*dz)
            if dd < d then d = dd; go = ego end
        end
    end
    if not go then _G.__re4_knife_clone_dbg = "noenemy"; return false end
    local hc = find_knife_hc(); if not hc then _G.__re4_knife_clone_dbg = "nohc"; return false end
    local atk = knife_get_attack_ud(hc); if not atk then _G.__re4_knife_clone_dbg = "noatk"; return false end
    local dmg = safe_create("chainsaw.collision.DamageUserData"); if not dmg then _G.__re4_knife_clone_dbg = "nodmg"; return false end
    local thc = get_hc(go)
    local hp0 = thc and tonumber(safe_call(thc, "get_CurrentHitPoint"))
    pcall(function() hc:call("set_AttackEnable", true) end)
    _G.__re4_knife_our_until = os.clock() + 0.25
    pcall(function() hc:call("requestAttack", go, atk, dmg) end)
    pcall(function() hc:call("set_AttackEnable", false) end)
    _G.__re4_knife_clone_dbg = string.format("fired d=%.2f hp0=%s", d or -1, tostring(hp0))
    return true
end

-- [FLUGBAHN-SCAN 2026-07-20] Frueher stand hier knife_flight_collide mit Gegner- UND Breakable-Fang --
-- die Funktion wurde aber von NIEMANDEM aufgerufen (toter Code seit der Raycast-Umstellung). Genau das war der
-- Grund, warum Vasen/Kisten oft erst beim 2./3. Wurf zerbrachen: sie haben keinen Collider auf dem Raycast-Layer,
-- der Strahl fliegt durch sie hindurch, und der Flugbahn-Scan lief nicht mehr.
-- Wieder aktiv, aber NUR der BREAKABLE-Teil, aufgerufen aus dem Flug-Tick (gilt fuer BEIDE Haende -- Rechts-Wurf
-- und Links-Klon laufen durch dieselbe kfly-Maschine). Der Gegner-Fang bleibt bewusst DRAUSSEN: er rief
-- mark_hit und schnitt damit den Bogen ab, sobald ein Gegner NEBEN der Bahn stand ("Gegner gingen gut").
local function knife_flight_break_scan()
    local cfg = _G.__re4_knife_fly_cfg or {}
    -- [HOEHENFENSTER] dritter Parameter, nur im Flug und fuer ALLES gleich: ein Wurf ueber eine Kiste,
    -- ein Fass oder ein Huhn hinweg darf sie nicht mehr zerlegen. 0 in der Konstante = wieder aus.
    local mdy = tonumber(cfg.hit_max_dy) or 1.0; if mdy <= 0 then mdy = nil end
    break_nearby(kfly.pos, tonumber(cfg.break_radius) or rawget(_G, "__re4_knife_touch") or 0.9, mdy)   -- [WURF-OBJEKTRADIUS]
end

-- [OBJEKT-KOLLISION] Das vom Raycast getroffene GameObject behandeln. Rueckgabe:
-- "enemy" = lebender Gegner getroffen (Schaden zugefuegt)
-- "break" = Breakable (Kiste/Fass/Fenster) zerstoert
-- nil = statische Geometrie (Wand/Boden) -> Aufrufer entscheidet per Normale
local function knife_hit_object(hitgo, ip)
    if not hitgo then return nil end
    if not _idur_td then _idur_td = sdk.typeof("chainsaw.IGimmickDurability") end
    if not _G.__re4_woodbox_td then _G.__re4_woodbox_td = sdk.typeof("chainsaw.GmWoodBoxBase") end
    -- [KISTE] hitgo ODER dessen Parent traegt die WoodBox (getroffene "Before"/"After"-Collider sind
    -- Kinder der WoodBox) -> set_Routine(Break) auf die WoodBox.
    local wbx, dur = _G.__re4_wb_of(hitgo)
    -- [LH_CLONE BREAKABLE-SOUND 2026-07-17] Breakable per KLON-Wurf getroffen -> Einschlag-Sound ueber die
    -- LINKE Hand (__re4_knife_lh_play_sound, 686504397). Der native Break-Sound (set_Routine unten) haengt am
    -- geholsterten Klon-Collider -- der sitzt nicht am Trefferort und ist praktisch unhoerbar. Beim Rechts-Wurf
    -- uebernimmt der native Sound (Messer-Collider IST am Treffer) -> darum NUR clone_throw, sonst doppelt.
    -- Kam frueher aus dem [LH_CLONE WURF]-Radius-Block; beim Umstieg auf den Ray-Weg hier neu angesetzt.
    -- [RECHTS-WURF STUMM 2026-07-20] Die Annahme oben ("beim Rechts-Wurf uebernimmt der native
    -- Sound") stimmt nicht: im Flug steuern WIR die Transform, der Messer-Collider haengt nicht mehr am
    -- Trefferpunkt -- es blieb still. Der Hit-Sound laeuft daher jetzt bei JEDEM Wurf (Klon wie echtes
    -- Messer) ueber denselben, im Flug bewaehrten Weg. Doppelt kann er nicht kommen: dieser Zweig feuert
    -- genau einmal pro Raycast-Treffer.
    if (wbx or dur) then
        -- [SOUND 2026-07-17] NICHT ueber lh_play_sound: im FLUG hat das Messer den Koerper verlassen ->
        -- lh_body_knife_soundcontainer findet kein wpXXXX-Body-Kind -> stumm. Der bewaehrte Flug-Weg
        -- (play_knife_sound -> find_knife_hc) spielt hoerbar, wie beim Rechts-Wurf..hit == 686504397.
        play_knife_sound((_G.__re4_knife_snd or {}).hit)
    end
    if wbx then
        if safe_call(wbx, "get_IsBroken") ~= true then
            local br = get_break_routine()
            if br ~= nil then pcall(function() wbx:call("set_Routine", br) end) end
            -- [NATIVE-FLAG] wie im break_nearby-Pfad: echten Schaden nachschieben, sonst bleibt die Box
            -- inkonsistent (IsBroken=False, BasementState=Wait) und der "zertreten"-Prompt haengt.
            -- requestAttack auf das getroffene GO -> Engine-Break-Completion (wie der native Tritt).
            local mhc = find_knife_hc()
            local atk = mhc and knife_get_attack_ud(mhc)
            if mhc and atk then
                local dmg = safe_create("chainsaw.collision.DamageUserData")
                if dmg then
                    pcall(function() mhc:call("set_AttackEnable", true) end)
                    _G.__re4_knife_our_until = os.clock() + 0.25
                    pcall(function() mhc:call("requestAttack", hitgo, atk, dmg) end)
                    pcall(function() mhc:call("set_AttackEnable", false) end)
                end
            end
        end
        return "break"
    end
    -- [FENSTER/VASE] Durability-Breakable -> Haltbarkeit auf 0.
    if dur then
        local cur = tonumber(safe_call(dur, "get_CurrentDurability")) or 0
        if cur > 0 then pcall(function() dur:call("addDurability", -(cur + 1)) end) end
        _G.__re4_knife_flight_mark_hit()   -- [SOFORT-RUECKKEHR]
        return "break"
    end
    -- [GEGNER] Der Damage-Filter trifft nur Damage-Collider ausser Player -> ein getroffenes GO mit einem
    -- HitController (via HitManager) ist ein Gegner. requestAttack DIREKT auf DAS getroffene GO -> praezise,
    -- KEIN Radius. Genau das getroffene Objekt nimmt Schaden (wie ein Bullet-Treffer).
    if not kfly.hit_done then
        -- [KLON-WURF 2026-08-14] Der Ray hatte den Gegner laengst -- nur der Schaden fehlte: unten laeuft
        -- `requestAttack`, und das ist beim Klon wirkungslos (kein aktiver Klingen-Collider, s. ganz oben).
        -- Ergebnis war "Messer steckt in der Schulter, kein Schaden", waehrend Treffer in die Koerpermitte
        -- ueber den Radius-Weg im Flug-Tick trotzdem zaehlten. Deshalb hier fuer den Klon der eigene
        -- Schadensweg -- und zwar am ECHTEN Einschlagpunkt `ip` des Strahls, nicht an einer Naeherung.
        -- Damit gilt fuer links dieselbe Trefferpraezision wie rechts (der Ray entscheidet), waehrend der
        -- Einschlagpunkt der bessere aus dem Klon-Weg bleibt.
        -- Findet sich am Einschlagpunkt kein Gegner (Wand/Sammel-Collider), faellt es unveraendert durch.
        if kfly.clone_throw == true then
            local f = rawget(_G, "__re4_knife_direct_damage_at")
            local r = tonumber((_G.__re4_knife_fly_cfg or {}).hit_radius) or 0.5
            if type(f) == "function" and ip and f(ip, r) == true then
                play_knife_sound((_G.__re4_knife_snd or {}).hit)   -- im Flug ist der lh-Container stumm
                _G.__re4_knife_flight_mark_hit()   -- [SOFORT-RUECKKEHR]
                return "enemy"
            end
            -- Kein Gegner am Einschlagpunkt: bewusst NICHT in den requestAttack-Zweig unten fallen -- der
            -- wuerde beim Klon "enemy" melden und das Messer stecken lassen, ohne Schaden zu machen.
            -- Stattdessen faellt es zum Sammel-Collider-Zweig durch (Kisten hinter Container-Collidern).
        else
            local mhc = find_knife_hc()
            local thc = mhc and get_hc(hitgo)   -- HitController des getroffenen GO (nur echte Damage-Ziele)
            local atk = thc and knife_get_attack_ud(mhc)
            if atk then
                local dmg = safe_create("chainsaw.collision.DamageUserData")
                if dmg then
                    pcall(function() mhc:call("set_AttackEnable", true) end)
                    _G.__re4_knife_our_until = os.clock() + 0.25
                    pcall(function() mhc:call("requestAttack", hitgo, atk, dmg) end)
                    pcall(function() mhc:call("set_AttackEnable", false) end)
                    _G.__re4_knife_flight_mark_hit()   -- [SOFORT-RUECKKEHR]
                    return "enemy"
                end
            end
        end
    end
    -- [SAMMEL-COLLIDER] Der Damage-Strahl traf KEIN direktes Breakable/Gegner-GO -> meist ein
    -- Sammel-Collider/Container ("Before"/"After"/"OptimizedPropsRoot", PropsCompound), der mehrere
    -- Props buendelt; das echte Prop haengt NICHT an diesem GO. Am Einschlagpunkt (ip) suchen
    -- (break_nearby = iter_hitctrl_gos + WoodBox/Durability/HC an der Trefferstelle).
    if ip then
        -- [WURF-OBJEKTRADIUS 2026-07-20] auch hier der Wurf-Wert statt des Stich-Radius (Default gleich).
        local broke = break_nearby(ip, tonumber((_G.__re4_knife_fly_cfg or {}).break_radius))
        if broke and broke > 0 then
            _G.__re4_knife_flight_mark_hit()   -- [SOFORT-RUECKKEHR]
            return "break"
        end
    end
    return nil
end

-- [MESH_HIDE] Sichtbarkeit des fliegenden Messer-GO schalten (Mesh set_DrawSelf). Fuer: nichts getroffen
-- -> ausblenden bis Rueckkehr; bei Rueckkehr in die Hand IMMER wieder einblenden (100% solide).
_G.__re4_knife_mesh_vis = function(vis)
    if not kfly.go then return end
    pcall(function()
        local m = kfly.go:call("getComponent(System.Type)", mesh_type)
        if m then m:call("set_Enabled", vis) end   -- via.render.Mesh: set_Enabled (KEIN set_DrawSelf!)
    end)
end

-- Physik pro Frame (auf on_frame). Integration + Salto + Kollision. Nach Treffer/Zeit faellt das
-- Messer weiter unter Schwerkraft, bis es den Boden (floor_y) erreicht -> ruht dort -> Rueckkehr.
local function knife_flight_tick()
    if not kfly.active then return end
    local now = os.clock()
    local dt = now - (kfly.last_t or now); kfly.last_t = now
    if dt <= 0 then dt = 0.016 elseif dt > 0.1 then dt = 0.1 end
    local cfg = _G.__re4_knife_fly_cfg
    if kfly.phase ~= "rest" then
        kfly.pos.x = kfly.pos.x + kfly.vel.x * dt
        kfly.pos.y = kfly.pos.y + kfly.vel.y * dt
        kfly.pos.z = kfly.pos.z + kfly.vel.z * dt
        -- [LH_CLONE DAMAGE 2026-07-17, so gewollt "nur Gegner-Schaden ohne in der Luft haengen"]
        -- Der praezise Ray trifft beim KLON oft nur einen Sub-Collider -> get_hc(hitgo)=nil -> kein "enemy"
        -- -> kein Schaden (Regression seit der 1.5m-Radius-Fang raus ist). Deshalb hier der BEWAEHRTE Weg
        -- __re4_knife_direct_damage_at (native_hit + Blut, exakt der, den das Links-Melee nutzt -> verifiziert).
        -- ENGER reach (~1.0, NICHT die alten 1.5) -> kein vorzeitiges Cutten des Bogens; das Homing traegt das
        -- Messer eh in den Gegner, also greift's genau am Kontakt. Bei Treffer mark_hit = SAUBER stoppen +
        -- zurueck in die Hand (wie der rechte Wurf, "sieht super aus") -> KEIN Orbit/Salto, KEIN Luft-Haengen.
        if kfly.clone_throw and not kfly.hit_done and kfly.phase == "fly" then
            local dmgfn = rawget(_G, "__re4_knife_direct_damage_at")
            -- [TREFFERDISTANZ 2026-08-14] Die Untergrenze `math.max(..., 1.0)` hat den Regler cfg.hit_radius
            -- (0.5) ausgehebelt -- zwei Stellen fuer dieselbe Groesse, und die haerteste gewann. Jetzt
            -- regelt nur noch cfg.hit_radius. Gemessen wird gegen die Koerpermitte, 0.5 liegt also knapp
            -- an der Oberflaeche. Durchflieger drohen nicht: bei speed 12 m/s sind das ~0.2 m pro Frame.
            if type(dmgfn) == "function" and dmgfn(kfly.pos, cfg.hit_radius or 0.5) then
                -- [SOUND 2026-07-17] direct_damage_at spielt intern ueber den lh-Body-Container -- der ist im FLUG
                -- stumm (das Messer hat den Koerper verlassen -> lh_body_knife_soundcontainer findet kein wpXXXX-
                -- Body-Kind mehr). Deshalb hier den bewaehrten Flug-Sound-Weg (play_knife_sound -> find_knife_hc,
                -- exakt wie der Ray-Enemy-Zweig Z.2527, beim Rechts-Wurf hoerbar).
                play_knife_sound((_G.__re4_knife_snd or {}).hit)
                _G.__re4_knife_flight_mark_hit()
            end
        end
        -- [FLUGBAHN-SCAN 2026-07-20] Breakables ENTLANG der Bahn einsammeln (Vasen/Kisten/Faesser sind
        -- fuer den Raycast unsichtbar). Beide Haende, jeden Flug-Frame solange noch nichts getroffen wurde.
        -- break_nearby setzt KEIN mark_hit -> der Flug laeuft normal weiter, nur die Kiste zerspringt.
        if kfly.phase == "fly" and not kfly.hit_done then knife_flight_break_scan() end
        -- [LH_CLONE WURF: RADIUS-FANG RAUS 2026-07-17, Entscheidung] Hier stand ein Klon-Sonderweg,
        -- der JEDEN Flug-Frame lief:
        -- knife_try_hit_enemy(kfly.pos, 1.5) -- Gegner: 1.5-m-Radius-Einzug
        -- break_nearby(kfly.pos, __re4_knife_touch or 0.9) -- Kisten: 0.9-m-Radius-Einzug
        -- Der 1.5-m-Gegner-Fang brach den Flug ab, sobald ein Gegner bis 1.5 m NEBEN der Bahn stand -> der
        -- Klon-Wurf endete nach ~2.5 m statt zu fliegen (live per re4_clonefly_probe belegt: doofe kurze Bahn
        -- vs. schoener Bogen nur, wenn zufaellig kein Gegner in Reichweite war). Der Rechts-Wurf hat diesen
        -- Fang nicht -> er fliegt sauber. "wenn der linke Wurf nicht beschnitten wird, raus damit."
        --
        -- ER WIRD NICHT BESCHNITTEN: Der Klon nutzt jetzt DENSELBEN Weg wie rechts -- den praezisen Raycast
        -- (laeuft ohnehin fuer beide) -> knife_hit_object. Dessen Gegner-Zweig macht requestAttack DIREKT
        -- aufs getroffene GO (kein Collider-Overlap noetig) mit der AttackUD aus knife_get_attack_ud; die
        -- liefert seit dem borrow-Fix (2026-07-17) auch fuer den Klon/wp5002 eine (leiht notfalls von einer
        -- Gegnerwaffe). Kisten trifft der Ray ebenfalls (wb_of-Zweig in knife_hit_object) -- der alte
        -- Kommentar "Kisten haben keinen Ray-Layer-Collider" war falsch (Rechts-Wurf zerschlaegt Kisten
        -- nachweislich per Ray, bestaetigt). Also: Gegner UND Kisten weiter getroffen, nur praezise
        -- statt per Radius, und der Flug sieht aus wie rechts. Der Block war der EINZIGE Unterschied.
        -- ZURUECK: den try_hit_enemy(1.5)+break_nearby(0.9)-Block hier wieder einsetzen.
        -- [MAX_RANGE] Harte Wurfweiten-Grenze: sobald das Messer horizontal (X/Z) weiter als max_range vom
        -- Wurf-Ursprung ist, faellt es IMMER zu Boden -> Homing + Bogen-Ausgleich aus (volle Gravity) und
        -- horizontale Velocity gestoppt, damit es an dieser Distanz sicher runtergeht statt weiterzufliegen.
        if kfly.phase == "fly" and not kfly.wall_hit and kfly.start_pos then
            local rx = kfly.pos.x - kfly.start_pos.x
            local rz = kfly.pos.z - kfly.start_pos.z
            local mr = cfg.max_range or 12.0
            if (rx * rx + rz * rz) >= (mr * mr) then
                kfly.flat = 0.0
                kfly.home_str = 0.0
                kfly.home = nil
                kfly.vel.x = 0; kfly.vel.z = 0
            end
        end
        -- [HOMING] waehrend des Flugs die Velocity zum Ziel (Brust) lenken. home_str=1 -> Velocity zeigt
        -- jeden Frame VOLL aufs Ziel = sicherer Treffer; kleiner = sanft/subtil. Nur Flugphase (nicht nach Treffer).
        if kfly.phase == "fly" and not kfly.wall_hit and kfly.home and (kfly.home_str or 0) > 0 then
            -- [LIVE TARGET] Ziel-Position jeden Frame vom Gegner nachfuehren -> trifft auch wenn er sich
            -- im letzten Moment bewegt (statt zum Fixpunkt vom Wurf-Moment zu fliegen).
            if kfly.home_ctx then
                local ax, ay, az = _G.__re4_enemy_aim_point(kfly.home_ctx)   -- [CENTER] adaptiver Zielpunkt, live nachgefuehrt
                if ax then kfly.home.x, kfly.home.y, kfly.home.z = ax, ay, az end
            end
            local dx = kfly.home.x - kfly.pos.x
            local dy = kfly.home.y - kfly.pos.y
            local dz = kfly.home.z - kfly.pos.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if (not kfly.home_ctx) and d < 0.7 then
                -- [KEIN-ORBIT 2026-07-06] Breakable-Ziel ist ein FIXER Punkt (kein lebender Gegner, home_ctx=nil).
                -- Sobald das Messer dort ankommt, Homing AUS -> es fliegt gerade durch und faellt, statt drueber
                -- zu kreisen/Saltos zu machen. (Die Kiste selbst zerbricht ueber break_nearby/Ray im Vorbeiflug.)
                kfly.home = nil; kfly.home_str = 0.0; kfly.flat = 0.0
            elseif d > 0.05 then
                local spd = math.sqrt(kfly.vel.x * kfly.vel.x + kfly.vel.y * kfly.vel.y + kfly.vel.z * kfly.vel.z)
                if spd < 0.1 then spd = (cfg.speed or 12.0) end
                local wx, wy, wz = dx / d * spd, dy / d * spd, dz / d * spd   -- gewuenschte Velocity (voll zum Ziel)
                local b = math.min(1.0, kfly.home_str)
                kfly.vel.x = kfly.vel.x + (wx - kfly.vel.x) * b
                kfly.vel.z = kfly.vel.z + (wz - kfly.vel.z) * b
                -- [BOGEN] vertikale Lenkung deutlich schwaecher (35%): die Gravity darf den Fall/Bogen bilden,
                -- das Homing zieht primaer horizontal aufs Ziel -> sichtbarer Wurfbogen statt gerader Z-Linie.
                kfly.vel.y = kfly.vel.y + (wy - kfly.vel.y) * b * 0.35
            end
        end
        -- [ZIELHILFE] Flug-Bogen abflachen um max(manueller Ausgleich, Homing-Staerke). NUR im freien Flug
        -- (nicht nach wall_hit) -> nach jedem Surface-Treffer VOLLE Gravity, damit das Messer garantiert
        -- runterfaellt statt an der Wand haengen zu bleiben und Saltos bis Lebensende zu drehen.
        -- [BOGEN] Gravity NUR noch vom Bogen-Ausgleich (assist_flatten) beeinflusst, NICHT mehr vom Homing.
        -- Vorher kappte max(flat, home_str) die Gravity -> starkes Homing = Laserlinie ohne Bogen. Jetzt darf
        -- die Gravity IMMER den Bogen bilden; das Homing lenkt nur zum Ziel (horizontal voll, vertikal sanft).
        local gmul = (kfly.phase == "fly" and not kfly.wall_hit) and (1.0 - (kfly.flat or 0.0)) or 1.0
        kfly.vel.y = kfly.vel.y - (cfg.gravity or 7.0) * gmul * dt
        -- [SALTO] vor dem Treffer sauberer, langsamer Ueberschlag (spin_fly); nach dem Einschlag
        -- volle, wilde Rotation (spin_fall) -> segelt unkontrolliert zu Boden.
        local sp = kfly.wall_hit and (cfg.spin_fall or 22.0) or (cfg.spin_fly or 5.0)
        kfly.ang = (kfly.ang or 0) + sp * dt
        -- KEIN Radius/Bone-Scan mehr: die Kollision macht AUSSCHLIESSLICH der Damage-Filter-Raycast unten
        -- (praezise = genau das getroffene Objekt, wie ein Bullet).
        -- [KNIFE_RAY] Kollision in FLUGRICHTUNG. crosshair-Muster: nur einen NEUEN Strahl feuern,
        -- wenn der vorige get_Finished ist (keine ueberlappenden async-Strahlen = der Crash von vorher).
        if (not kfly.ray) or knife_ray_finished() then
            if kfly.ray_pending then                      -- Ergebnis des letzten Strahls auswerten
                kfly.ray_pending = false
                local hd, ny, hitgo, is_wall = knife_ray_hit_dist()
                if hd and kfly.ray_len and hd <= kfly.ray_len and kfly.ray_from and kfly.ray_dir and not kfly.wall_hit then
                    -- [OBJEKT-KOLLISION] Einschlagpunkt in Flugrichtung.
                    local ipx = kfly.ray_from.x + kfly.ray_dir.x * hd
                    local ipy = kfly.ray_from.y + kfly.ray_dir.y * hd
                    local ipz = kfly.ray_from.z + kfly.ray_dir.z * hd
                    -- Damage-Strahl (naeher) -> Gegner/Kiste behandeln. Terrain-Strahl -> Wand/Boden.
                    local kind = (not is_wall) and knife_hit_object(hitgo, { x = ipx, y = ipy, z = ipz }) or nil
                    if kind == "break" then
                        -- Breakable zerstoert -> das Messer fliegt WEITER durch (kein Stop, kein Einschlag).
                        -- [KEIN-ORBIT 2026-07-06] ABER das Homing zeigte auf das jetzt zerstoerte Breakable ->
                        -- es kreiste zurueck und machte Saltos drueber. Sobald es gebrochen ist (get_IsBroken
                        -- gesetzt), Homing loeschen -> das Messer fliegt frei ballistisch weiter und faellt weg.
                        kfly.home = nil
                        kfly.home_ctx = nil
                        kfly.home_str = 0.0
                        kfly.flat = 0.0
                    elseif kind == "enemy" then
                        -- [ENEMY_HIT] Gegner getroffen -> sofort STOPPEN, NICHT mehr rotieren (phase=rest ueberspringt
                        -- den Spin-Block oben) und automatisch zurueck in die Hand (Rueckkehr-Timer).
                        kfly.wall_hit = true
                        -- [EINSCHLAGTIEFE 2026-08-14 -- ZURUECKGEBAUT] Hier stand ein Versatz in Flugrichtung
                        -- (`enemy_push`), der den Einschlag tiefer in den Koerper legen sollte. Direkt danach
                        -- traf der RECHTE Wurf kein Ziel mehr und das Spiel ist abgestuerzt -> raus. Der
                        -- Einschlagpunkt ist wieder exakt der Ray-Trefferpunkt wie seit jeher.
                        kfly.pos.x, kfly.pos.y, kfly.pos.z = ipx, ipy, ipz
                        kfly.vel.x, kfly.vel.y, kfly.vel.z = 0, 0, 0
                        kfly.phase = "rest"
                        -- [STECKZEIT 2026-08-14] Hier stand `return_t = jetzt + return_delay` (0.4) und hat
                        -- die Steckzeit aus `mark_hit` (hit_return_delay) still ueberschrieben -- zwei Stellen
                        -- fuer dieselbe Groesse, die spaetere gewann. `return_delay` gilt weiterhin fuer den
                        -- Fall OHNE Treffer (Boden/Zeitablauf), hier nicht mehr.
                        play_knife_sound((_G.__re4_knife_snd or {}).hit)
                    elseif not is_wall then
                        -- [DMG-DURCHFLUG] Damage-Strahl traf KEIN Breakable/Gegner (Sammel-Collider wie
                        -- "Before"/PropsCompound, oder ein schon getroffener Gegner) -> NICHT stoppen. Das
                        -- Messer fliegt weiter, bis es ein echtes Ziel trifft oder der Terrain-Strahl (is_wall)
                        -- eine echte Wand/Boden meldet. FRUEHER stoppte hier JEDER Nicht-Ziel-Treffer den Flug
                        -- direkt vor der Hand ("Before" @0.16m) -> Kiste wurde nie erreicht.
                        -- (bewusst kein Code: NICHT stoppen, einfach weiterfliegen.)
                    else
                        kfly.wall_hit = true
                        -- BODEN nur bei Terrain-Treffer mit horizontaler Flaeche (|ny|>0.6). Wand/Gegner -> fallen.
                        local is_floor = is_wall and (ny ~= nil) and (math.abs(ny) > 0.6)
                        if is_floor then
                            -- Landet GENAU auf der echten Geometrie und bleibt liegen.
                            kfly.pos.x, kfly.pos.y, kfly.pos.z = ipx, ipy, ipz
                            kfly.vel.x, kfly.vel.y, kfly.vel.z = 0, 0, 0
                            kfly.floor_y = ipy
                            play_knife_sound((_G.__re4_knife_snd or {}).floor)   -- [KNIFE_SND] Boden-Aufprall
                        else
                            -- Wand/Objekt/Gegner: knapp davor stoppen, dann faellt es zu Boden (-> spaeter floor-Sound).
                            local back = math.max(0, hd - 0.05)
                            kfly.pos.x = kfly.ray_from.x + kfly.ray_dir.x * back
                            kfly.pos.y = kfly.ray_from.y + kfly.ray_dir.y * back
                            kfly.pos.z = kfly.ray_from.z + kfly.ray_dir.z * back
                            kfly.vel.x, kfly.vel.z = 0, 0
                            if kfly.vel.y > 0 then kfly.vel.y = 0 end
                            play_knife_sound((_G.__re4_knife_snd or {}).hit)   -- [KNIFE_SND] Wand/Objekt/Gegner-Einschlag
                        end
                    end
                end
            end
            -- Raycast nur solange das Messer noch frei fliegt (nicht nach dem Einschlag -> dann faellt es nur noch).
            -- [ARM_CLEAR] UND erst, wenn das Messer den eigenen Koerper verlassen hat (Mindeststrecke vom
            -- Wurf-Ursprung an der Hand) -> sonst trifft der Strahl sofort den eigenen Arm (dist~0.03).
            local sp = kfly.start_pos
            local cleared = true
            if sp then
                local ax, ay, az = kfly.pos.x - sp.x, kfly.pos.y - sp.y, kfly.pos.z - sp.z
                cleared = (ax*ax + ay*ay + az*az) >= ((cfg.arm_clear or 0.7) * (cfg.arm_clear or 0.7))
            end
            -- [TOTZONE-TREFFER 2026-08-12] Solange der Fuehler wegen arm_clear aus ist, wird NUR hier und
            -- NUR auf Gegner der bewaehrte Radius-Weg gefahren (knife_try_hit_enemy -> requestAttack mit
            -- der Messer-AttackUD, markiert den Treffer selbst und holt das Messer zurueck). Der Klon-Wurf
            -- bleibt aussen vor, der hat seinen eigenen Radius-Schaden weiter oben. Die Zone ist bei
            -- 13 m/s nach ~0,05 s durchflogen -- danach uebernimmt wieder ausschliesslich der Strahl.
            if (not cleared) and kfly.phase == "fly" and not kfly.wall_hit
               and not kfly.hit_done and not kfly.clone_throw then
                local cr = tonumber(cfg.close_hit_radius) or 0.0
                if cr > 0 then knife_try_hit_enemy(kfly.pos, cr) end
            end
            if kfly.phase ~= "rest" and not kfly.wall_hit and cleared then
                local vx, vy, vz = kfly.vel.x, kfly.vel.y, kfly.vel.z
                local vlen = math.sqrt(vx*vx + vy*vy + vz*vz)
                if vlen > 0.01 then
                    local dx, dy, dz = vx/vlen, vy/vlen, vz/vlen
                    -- [RAY_LEN] Vorschau = knapp die Bewegung DIESES Frames (dt hart auf 0.03 gedeckelt gegen
                    -- Lag-Spikes) -> der Strahl trifft eine Wand erst, wenn das Messer WIRKLICH davor ist,
                    -- und stoppt es nicht mehr meterweit voraus (sonst erreicht es nie einen entfernten Gegner).
                    local rl = math.max(0.15, vlen * math.min(dt, 0.03) * 1.5)
                    kfly.ray_from = Vector3f.new(kfly.pos.x, kfly.pos.y, kfly.pos.z)
                    kfly.ray_dir = { x = dx, y = dy, z = dz }
                    kfly.ray_len = rl
                    local to = Vector3f.new(kfly.pos.x + dx*rl, kfly.pos.y + dy*rl, kfly.pos.z + dz*rl)
                    if knife_ray_fire(kfly.ray_from, to) then kfly.ray_pending = true end
                end
            end
        end
        -- Boden (Spielerfuss) bzw. Not-Timer -> Messer landet, Boden-Aufprall-Sound, dann Rueckkehr.
        local floor_y = kfly.floor_y or (kfly.pos.y - 10)
        -- [MIN_FLY] Boden-Aufprall erst zulassen, nachdem das Messer kurz geflogen ist -> kein Sofort-rest.
        local flew_enough = now >= (kfly.min_fly_until or 0)
        if (flew_enough and kfly.pos.y <= floor_y) or now >= (kfly.end_t or 0) then
            if kfly.pos.y < floor_y then kfly.pos.y = floor_y end
            kfly.phase = "rest"
            kfly.return_t = now + (cfg.return_delay or 0.4)
            play_knife_sound((_G.__re4_knife_snd or {}).floor)   -- [KNIFE_SND] Boden-Aufprall (auch bei direktem Bodenwurf nur dieser Sound)
        end
    else
        -- [MESH_HIDE] Ruhephase OHNE Gegner-Treffer (nichts getroffen) -> Messer ausblenden. JEDEN Frame
        -- forcieren: die Engine setzt Enabled sonst periodisch selbst wieder auf sichtbar (Culling/LOD) ->
        -- das war das Flackern. Gegner-Treffer (hit_done) bleibt sichtbar (steckt).
        -- [SICHTBARKEIT 2026-08-14] Nach einem TREFFER bleibt die Klinge nur noch `hit_visible` Sekunden
        -- sichtbar stecken (Zeit ab dem Einschlag, also praktisch ab dem Einschlag-Sound) -- danach wird
        -- sie ausgeblendet. Die RUECKKEHR in die Hand bleibt davon unberuehrt und laeuft weiter ueber
        -- `return_t` (hit_return_delay). Vorher hing beides am selben Zeitpunkt, das Messer stand also
        -- bis zum Zurueckspringen sichtbar im Gegner.
        if not kfly.hit_done then
            kfly.hidden = true
            _G.__re4_knife_mesh_vis(false)
        elseif kfly.hit_t and now >= (kfly.hit_t + (tonumber(cfg.hit_visible) or 0.15)) then
            kfly.hidden = true
            _G.__re4_knife_mesh_vis(false)
        end
        if now >= (kfly.return_t or 0) then
            kfly.active = false   -- Override AUS -> Engine snappt das Messer zurueck in die Hand
            -- [MESH_HIDE] Rueckkehr -> Mesh IMMER wieder einblenden (auch wenn nie ausgeblendet) = 100% solide.
            _G.__re4_knife_mesh_vis(true); kfly.hidden = false
            -- [RUECKKEHR-SOUND 2026-07-17, so gewollt] Nur VORMERKEN -- gespielt wird in knife_flight_apply,
            -- NACH __re4_knife_reattach. WARUM NICHT HIER: der Sound laeuft ueber den SoundContainer des
            -- MESSER-GO, und das haengt in diesem Moment noch frei an der Flug-/Boden-Position (detached).
            -- Ein Abspielen hier kommt raeumlich vom Boden -> praktisch unhoerbar. Erst das Reattach setzt
            -- das Messer zurueck an die Hand; ab da ist der Sound da, wo er hingehoert.
            kfly.snd_return = true
        end
    end
end

-- [ZITTER_FIX] Nach dem Einschlag haengt das Messer noch am Transform-Parent (Player/Hand) -> unser
-- set_Position (feste Weltpos) kaempft gegen die Engine-Hand-Anbindung, die mit dem Headset wackelt =
-- Zittern. Loesung: ab dem Einschlag den Parent LOESEN -> das Messer steht frei in Weltposition, keine
-- Kopplung an Hand/Headset. Beim Zurueckkehren in die Hand den Parent wiederherstellen.
-- [200-LOCAL-LIMIT] als Globals (im selben Chunk definiert -> kfly bleibt upvalue).
_G.__re4_knife_detach = function()
    if kfly.detached or not kfly.tf then return end
    -- [CRASH-FIX] set_Parent auf einen STALE Messer-Transform (GO beim Equip-Wechsel getauscht) loest
    -- eine native Access Violation aus, die pcall NICHT faengt -> Game-Crash. Erst get_Valid pruefen.
    if safe_call(kfly.tf, "get_Valid") == false then return end
    kfly.saved_parent = safe_call(kfly.tf, "get_Parent")
    pcall(function() kfly.tf:call("set_Parent(via.Transform)", nil) end)
    kfly.detached = true
end
_G.__re4_knife_reattach = function()
    if not kfly.detached then return end
    -- [CRASH-FIX] kfly.tf UND saved_parent muessen gueltig sein (beide koennen stale werden) -> sonst AV.
    if kfly.tf and safe_call(kfly.tf, "get_Valid") ~= false
       and kfly.saved_parent and safe_call(kfly.saved_parent, "get_Valid") ~= false then
        pcall(function() kfly.tf:call("set_Parent(via.Transform)", kfly.saved_parent) end)
    end
    kfly.detached = false
    kfly.saved_parent = nil
end

-- Transform-Uebernahme im spaeten Pass: solange aktiv, Messer-GO auf Flug-Pos/Rotation zwingen.
local function knife_flight_apply()
    _G.__re4_knife_flying = kfly.active   -- [KNIFE_THROW] Flag fuer motion.lua: Waffen-Pin aussetzen solange das Messer fliegt
    if not kfly.active then
        -- [LH_CLONE WURF] Klon-Wurf: NICHT ueber die equipped-Reattach (die stellt den alten Parent her) ->
        -- re4_vr_knife_lefthand.lua re-parentet den Klon an L_Hand. Nur der equipped-Wurf reattacht hier.
        if kfly.detached and not kfly.clone_throw then _G.__re4_knife_reattach() end
        -- [RUECKKEHR-SOUND 2026-07-17, so gewollt] Messer ist wieder in der Hand -> derselbe Sound wie beim
        -- Ziehen aus dem Holster. HIER und nicht im tick: erst nach dem Reattach oben sitzt das Messer-GO
        -- wieder an der Hand -- der Sound laeuft ueber dessen SoundContainer und kaeme sonst vom Boden.
        -- Der Export (re4_vr_holster.lua) ist HAND-NEUTRAL -> deckt rechten Wurf UND Links-Klon-Wurf ab.
        -- Flanke ueber kfly.snd_return: dieser Zweig laeuft jeden Frame, solange nichts fliegt -> ohne das
        -- Flag waere es Dauerfeuer. Gesetzt wird es genau einmal, wenn der Flug endet (knife_flight_tick).
        if kfly.snd_return then
            kfly.snd_return = false
            local sp = rawget(_G, "__re4_knife_play_grab_sound")
            if type(sp) == "function" then pcall(sp) end
        end
        return
    end
    if not kfly.tf then return end
    -- [CRASH-HAERTUNG 2026-07-22] Harter Gamecrash beim Klon-Wurf mit Gegnertreffer
    -- (reframework_crash.dmp 23:05:10: c0000005, Lesen von 0x24 = Null+Offset, in einem Engine-
    -- Worker-Thread ohne Lua-Frame). Ein pcall faengt eine native AV NICHT ab -- deshalb VOR jedem
    -- Transform-Write pruefen, ob das Objekt ueberhaupt noch lebt. NUR bei explizit false
    -- abbrechen (safe_call liefert bei einem Aufruf-Fehler nil): am gueltigen Wurf aendert das
    -- nichts, es beendet nur den Flug, wenn das Messer-GO waehrenddessen weggeraeumt wurde.
    local tf_valid = safe_call(kfly.tf, "get_Valid")
    if tf_valid == false then kfly.active = false; return end
    -- Ab dem Einschlag (wall_hit) bzw. sobald es liegt/steckt (rest): vom Parent loesen -> kein Zittern.
    if (kfly.wall_hit or kfly.phase == "rest") and not kfly.detached and not kfly.clone_throw then _G.__re4_knife_detach() end
    local okp = pcall(function() kfly.tf:call("set_Position", kfly.pos) end)
    if not okp then kfly.active = false; return end   -- Transform ungueltig (Waffe weg) -> abbrechen
    local newrot
    if kfly.phase == "rest" then
        -- [LANDE_POSE] Gelandet: feste, tunebare Welt-Rotation (flach/steckend) statt der eingefrorenen
        -- Salto-Rotation -> das Messer liegt sauber statt schraeg in der Luft/am Boden.
        local lr = _G.__re4_knife_land_rot or { rx = 1.5708, ry = 0.0, rz = 0.0 }
        newrot = kfly_euler(lr.rx or 0, lr.ry or 0, lr.rz or 0)
    elseif kfly.wall_hit then
        -- NACH dem Einschlag: wilde, verkippte Welt-Achse + Hand-Rotation -> unkontrolliertes Segeln.
        local q = kfly_axis_angle(kfly.axis_fall or kfly.axis, kfly.ang or 0)
        newrot = q
        if kfly.base_rot then
            local okm, m = pcall(function() return (q * kfly.base_rot):normalized() end)
            if okm and m then newrot = m end
        end
    else
        -- [SALTO IM FLUG] Sauberer Ueberschlag um die LOKALE Achse des Messers (via base_rot ausgerichtet).
        -- Die Quer-Achse haengt vom Mesh ab (RE-Engine-Achsen oft vertauscht/schraeg) -> Achse FREI per 3
        -- Slidern feintunen (spin_ax/ay/az), bis das Messer exakt geradeaus ueberschlaegt.
        local cfg2 = _G.__re4_knife_fly_cfg
        -- [SALTO_L] Links-Wurf nutzt AUSSCHLIESSLICH die eigenen Links-Achsen (kein Rueckgriff auf rechts).
        local ax2, ay2, az2
        if kfly.is_left then
            ax2 = cfg2.spin_ax_l or 1.0
            ay2 = cfg2.spin_ay_l or 0.0
            az2 = cfg2.spin_az_l or 0.0
        else
            ax2, ay2, az2 = cfg2.spin_ax or 1.0, cfg2.spin_ay or 0.0, cfg2.spin_az or 0.0
        end
        local al2 = math.sqrt(ax2*ax2 + ay2*ay2 + az2*az2)
        if al2 < 0.001 then ax2, ay2, az2, al2 = 1, 0, 0, 1 end
        local la = Vector3f.new(ax2/al2, ay2/al2, az2/al2)
        local salto = kfly_axis_angle(la, kfly.ang or 0)
        if kfly.base_rot then
            local okm, m = pcall(function() return (kfly.base_rot * salto):normalized() end)
            newrot = (okm and m) or salto
        else
            newrot = salto
        end
    end
    if newrot then pcall(function() kfly.tf:call("set_Rotation", newrot) end) end
end

-- Voller Override-Stack (wie ss-Clone): in allen Paessen setzen, damit die Engine-Hand-Anbindung
-- ueberschrieben wird; BeginRendering-POST (letzter Pass) ist der wirksame.
pcall(function() re.on_pre_application_entry("LockScene", knife_flight_apply) end)
pcall(function() re.on_application_entry("LateUpdateBehavior", knife_flight_apply) end)
pcall(function() re.on_application_entry("UpdateJointExpression", knife_flight_apply) end)
pcall(function() re.on_pre_application_entry("BeginRendering", knife_flight_apply) end)
pcall(function() re.on_application_entry("BeginRendering", knife_flight_apply) end)

------------------------------------------------------------
-- [THROWABLES] VR-Granaten-Wurf (1:1 Port aus RE9 re9_vr_weapons throw-system).
-- Werte 1:1 aus RE9 (re4_vr/re4_vr_throw.json). Detection = Velocity/Direction
-- auf _G.__vr_rh_world (player-kompensiert). Ausfuehrung: nativer Wurf, aber
-- Spawn-Pos + Richtung ueber chainsaw.ThrowingGrenadeGenerator.requestFire/
-- requestGenerate ueberschrieben (gleiches Muster wie crosshair Bullet/Rocket).
------------------------------------------------------------
local THROW_CFG_PATH = "re4_vr/re4_vr_throw.json"
local TCFG = {
    enabled = true,
    hand_speed_min = 5.8, hand_speed_max = 9.2,
    throw_fixed_speed = 10.0,   -- [FESTER WURF] feste Granaten-Wurfgeschwindigkeit (velocity-unabhaengig, wie Messer)
    throw_speed_min = 4.0, throw_speed_max = 12.0,   -- (alt/ungenutzt: velocity-Range)
    cooldown = 1.0, forward_dot_min = 1.0,
    sensitivity_min = 0.67, sensitivity_max = 1.29,
    y_offset = 0.0, x_offset = 0.0, release_window = 0.111,
    knife_pitch = 0.0, grenade_pitch = 0.0,   -- [Y_KORREKTUR] Wurf-Pitch getrennt: hebt die Richtung an (gegen Bogen)
    knife_yaw = 0.0,                           -- [X_KORREKTUR] Messer-Wurf Links/Rechts-Korrektur (analog knife_pitch)
    throw_pitch = 0.6,   -- Wurf-Bogen nach oben (rad, ~34°); RE4-Granaten brauchen Arc
    gravity = 9.8,       -- selbst aufgelegte Schwerkraft auf _CurrentMoveVec (Bogen/Fall)
    throw_speed_mult = 2.0,  -- LIVE-Slider: globaler Wurf-Stärke-Multiplikator
}
pcall(function()
    local d = json.load_file(THROW_CFG_PATH)
    if type(d) == "table" then
        for k, v in pairs(TCFG) do
            if d[k] ~= nil and type(d[k]) == type(v) then TCFG[k] = d[k] end
        end
    end
end)
local function save_throw_cfg() pcall(function() json.dump_file(THROW_CFG_PATH, TCFG) end) end
_G.__re4_throw_cfg = TCFG          -- fuer die UI erreichbar
_G.__re4_throw_save = save_throw_cfg

local GRENADE_ID_MIN, GRENADE_ID_MAX = 5400, 5410
local function is_grenade_equipped()
    local id = get_equip_weapon_id()
    return id ~= nil and id >= GRENADE_ID_MIN and id <= GRENADE_ID_MAX
end

-- [KNIFE_THROW] Ist aktuell ein Messer equippt? (rechter Grip wird dann zum Wurf statt Aim)
local function is_knife_equipped()
    local id = get_equip_weapon_id()
    return id ~= nil and KNIFE_IDS[id] == true
end

-- Rechter Grip gehalten = "Granate scharf / aim" (wie RE9 is_right_grip_held)
local function is_right_grip_held()
    if not vrmod or not vrmod:is_hmd_active() then return false end
    local ok, act = pcall(function() return vrmod:get_action_grip() end)
    if not ok or not act then return false end
    local ok2, rj = pcall(function() return vrmod:get_right_joystick() end)
    if not ok2 or not rj then return false end
    local ok3, v = pcall(function() return vrmod:is_action_active(act, rj) end)
    return ok3 and v == true
end
-- [KNIFE_HAND] Grip der Hand, die das Messer GERADE haelt (links vs rechts). GLOBAL (kein top-level local
-- -> 200-Local-Limit im weapons-Chunk unberuehrt). Liest den passenden Joystick direkt.
_G.__re4_knife_grip_held = function()
    if not vrmod or not vrmod:is_hmd_active() then return false end
    local ok, act = pcall(function() return vrmod:get_action_grip() end)
    if not ok or not act then return false end
    local ok2, js = pcall(function()
        if rawget(_G, "__re4_knife_hand") == "left" or rawget(_G, "__re4_knife_left_clone") == true then return vrmod:get_left_joystick() end
        return vrmod:get_right_joystick()
    end)
    if not ok2 or not js then return false end
    local ok3, v = pcall(function() return vrmod:is_action_active(act, js) end)
    return ok3 and v == true
end

local last_grenade_throw_t = 0
local grenade_throw_reset_t = 0
local tfsm = { logged_peak = 0 }

-- [KNIFE_THROW] eigener Wurf-State (teilt sich die Velocity-Historie tstate mit dem Granaten-Wurf,
-- aber nie gleichzeitig aktiv -> nur eine Waffe equippt). was_gripping = Flanke fuers Loslassen.
local kthrow = { was_gripping = false, peak = 0 }
local last_knife_throw_t = 0
_G.__re4_knife_throw_threshold = _G.__re4_knife_throw_threshold or 4.0   -- [KNIFE_THROW] eigene Wurf-Schwelle m/s (Slider, getrennt von der Granate), ueberlebt Reset

local function get_player_world_pos()
    local ctx = get_player_ctx()
    local body = ctx and safe_call(ctx, "get_BodyGameObject")
    local tf = body and safe_call(body, "get_Transform")
    return tf and safe_call(tf, "get_Position")
end
local function get_char_forward()
    local ctx = get_player_ctx()
    local body = ctx and safe_call(ctx, "get_BodyGameObject")
    local tf = body and safe_call(body, "get_Transform")
    local rot = tf and safe_call(tf, "get_Rotation")
    if not rot then return nil end
    local ok, fwd = pcall(function() return rot * Vector3f.new(0, 0, 1) end)
    return ok and fwd or nil
end

-- [HMD_FORWARD] Echte VR-Blickrichtung (Kopf, MIT Pitch) in WELT-Koordinaten: camera_rot * HMD-Quat.
-- Muster aus compute_assist_light_world_rotation. Fuer den Wurf-Richtungs-Kegel.
local function get_hmd_forward()
    if not vrmod then return nil end
    local rot0 = nil; pcall(function() rot0 = vrmod:get_rotation(0) end)
    if not rot0 then return nil end
    local hq = nil; pcall(function() hq = rot0:to_quat() end)
    if not hq then return nil end
    -- [DOPPEL-ROT-FIX 2026-07-04] get_rotation(0) IST bereits die HMD-WELT-Rotation (enthaelt den
    -- Stick-Turn via rotation_offset UND die Kopfdrehung). Frueher wurde nochmal mit camera_rot
    -- (=Body/Stick-Yaw aus _CameraRotation, OHNE HMD) multipliziert -> Body-Yaw DOPPELT (90° drehen ->
    -- Messer flog 90° zu weit; Schwung-fwd-Check schlug fehl). Darum: NUR die HMD-Welt-Rotation nutzen.
    -- HMD-Vorwaerts ist -Z.
    local ok, fwd = pcall(function() return (hq * Vector3f.new(0, 0, -1)) end)
    return ok and fwd or nil
end

-- [HMD_CAL] Korrigierte Wurf-Vorne-Richtung fuer den Kegel. WICHTIG (per THROWCAL-Messung 2026-07-04):
-- der echte HMD-Sensor (get_hmd_forward/rot0) trackt die Spiel-Drehung NICHT zuverlaessig, und camera_rot
-- ist 180 geflippt. Die zuverlaessige, mitdrehende Vorne-Richtung ist get_char_forward (Body-Forward) --
-- die Handwurf-Richtung draw stimmt damit ueberein. Darauf bauen wir. Fein-Korrektur per JSON:
-- hmd_yaw = Drehung um Welt-Y (Grad) -> horizontale Feinjustage; 180 = Flip vorne/hinten
-- hmd_pitch = Drehung um die horizontale Rechts-Achse (Grad) -> hoch/runter
-- Global-Closure (schliesst ueber get_char_forward) -> KEINE neue top-level local (weapons am Limit).
_G.__re4_hmd_forward_corrected = function()
    local f = get_char_forward()
    if not f then return nil end
    local l = math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
    if l < 1e-6 then return nil end
    local x, y, z = f.x / l, f.y / l, f.z / l
    local kfc = _G.__re4_knife_fly_cfg
    local yaw = math.rad(tonumber(kfc and kfc.hmd_yaw) or 0.0)
    local pitch = math.rad(tonumber(kfc and kfc.hmd_pitch) or 0.0)
    if yaw ~= 0 then                              -- um Welt-Y drehen
        local c, s = math.cos(yaw), math.sin(yaw)
        local nx, nz = x * c + z * s, -x * s + z * c
        x, z = nx, nz
    end
    if pitch ~= 0 then                            -- um horizontale Rechts-Achse (up x f = (z,0,-x)) drehen
        local rx, ry, rz = z, 0.0, -x
        local rl = math.sqrt(rx * rx + rz * rz)
        if rl > 1e-6 then
            rx, rz = rx / rl, rz / rl             -- ry bleibt 0
            local c, s = math.cos(pitch), math.sin(pitch)
            local dotav = rx * x + rz * z         -- ry*y entfaellt (ry=0)
            local cxx = ry * z - rz * y
            local cyy = rz * x - rx * z
            local czz = rx * y - ry * x
            x = x * c + cxx * s + rx * dotav * (1 - c)
            y = y * c + cyy * s + ry * dotav * (1 - c)
            z = z * c + czz * s + rz * dotav * (1 - c)
        end
    end
    local nl = math.sqrt(x * x + y * y + z * z)
    if nl < 1e-6 then return nil end
    return Vector3f.new(x / nl, y / nl, z / nl)
end

local POS_HISTORY_SIZE = 12
local VELOCITY_SMOOTH_FRAMES = 3
local RELEASE_PEAK_WINDOW_SEC = 0.15
local tstate = {
    prev_pos = nil, prev_time = 0, velocity = 0,
    pos_history = {}, player_history = {}, velocity_history = {}, pos_times = {}, pos_idx = 0,
}

local function update_throw_velocity()
    local pos = _G.__re4_knife_hand_world()   -- [KNIFE_HAND] aktive Messer-Hand (Granate=rechts, da hand=="none")
    if not pos then
        tstate.prev_pos = nil; tstate.pos_history = {}; tstate.player_history = {}
        tstate.velocity_history = {}; tstate.pos_times = {}; tstate.pos_idx = 0
        return
    end
    local player_pos = get_player_world_pos()
    local now = os.clock()
    tstate.pos_idx = (tstate.pos_idx % POS_HISTORY_SIZE) + 1
    tstate.pos_history[tstate.pos_idx] = Vector3f.new(pos.x, pos.y, pos.z)
    tstate.player_history[tstate.pos_idx] = player_pos and Vector3f.new(player_pos.x, player_pos.y, player_pos.z) or nil
    tstate.pos_times[tstate.pos_idx] = now
    local lookback = tstate.pos_idx - VELOCITY_SMOOTH_FRAMES
    while lookback <= 0 do lookback = lookback + POS_HISTORY_SIZE end
    local ref_pos, ref_time, ref_player = tstate.pos_history[lookback], tstate.pos_times[lookback], tstate.player_history[lookback]
    if ref_pos and ref_time and (now - ref_time) > 0.001 then
        local dx, dy, dz = pos.x - ref_pos.x, pos.y - ref_pos.y, pos.z - ref_pos.z
        if ref_player and player_pos then
            dx = dx - (player_pos.x - ref_player.x)
            dy = dy - (player_pos.y - ref_player.y)
            dz = dz - (player_pos.z - ref_player.z)
        end
        tstate.velocity = math.sqrt(dx * dx + dy * dy + dz * dz) / (now - ref_time)
    elseif tstate.prev_pos and (now - tstate.prev_time) > 0.001 then
        local dt = now - tstate.prev_time
        local dx, dy, dz = pos.x - tstate.prev_pos.x, pos.y - tstate.prev_pos.y, pos.z - tstate.prev_pos.z
        tstate.velocity = math.sqrt(dx * dx + dy * dy + dz * dz) / dt
    end
    tstate.velocity_history[tstate.pos_idx] = tstate.velocity
    tstate.prev_pos = Vector3f.new(pos.x, pos.y, pos.z)
    tstate.prev_time = now
end

local function compute_release_window_peak()
    if tstate.pos_idx == 0 then return 0 end
    local now_time = tstate.pos_times[tstate.pos_idx]
    if not now_time then return 0 end
    local cutoff = now_time - RELEASE_PEAK_WINDOW_SEC
    local peak = 0
    for i = 0, POS_HISTORY_SIZE - 1 do
        local idx = tstate.pos_idx - i
        while idx <= 0 do idx = idx + POS_HISTORY_SIZE end
        local t = tstate.pos_times[idx]
        if not t or t < cutoff then break end
        local v = tstate.velocity_history[idx]
        if v and v > peak then peak = v end
    end
    return peak
end

local function get_throw_direction(extra_pitch, extra_yaw)
    local dx, dy, dz = 0, 0, 0
    local have_motion = false
    if #tstate.pos_history >= 2 then
        local oldest_idx = (tstate.pos_idx % POS_HISTORY_SIZE) + 1
        if not tstate.pos_history[oldest_idx] then oldest_idx = 1 end
        local oldest, newest = tstate.pos_history[oldest_idx], tstate.pos_history[tstate.pos_idx]
        if oldest and newest then
            dx, dy, dz = newest.x - oldest.x, newest.y - oldest.y, newest.z - oldest.z
            local op, np = tstate.player_history[oldest_idx], tstate.player_history[tstate.pos_idx]
            if op and np then
                dx = dx - (np.x - op.x); dy = dy - (np.y - op.y); dz = dz - (np.z - op.z)
            end
            local total = math.sqrt(dx * dx + dy * dy + dz * dz)
            if total > 0.001 then dx, dy, dz = dx / total, dy / total, dz / total; have_motion = true end
        end
    end
    if not have_motion then
        local fwd = get_char_forward()
        if not fwd then return nil end
        local h = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
        if h < 0.001 then return nil end
        dx, dy, dz = fwd.x / h, 0, fwd.z / h
    end
    -- [X_KORREKTUR] globaler x_offset (Yaw) + optionaler wurf-spezifischer Extra-Yaw (Messer getrennt).
    local yaw = TCFG.x_offset + (extra_yaw or 0)
    if yaw ~= 0 then
        local ca, sa = math.cos(yaw), math.sin(yaw)
        local rx, rz = dx * ca - dz * sa, dx * sa + dz * ca
        dx, dz = rx, rz
    end
    -- Gemeinsamer y_offset + optionaler wurf-spezifischer Extra-Pitch (Messer/Granate getrennt tunebar).
    -- Positiv = Wurfrichtung nach OBEN -> flacherer/hoeherer Wurf gegen den Gravitations-Bogen.
    local pitch = TCFG.y_offset + (extra_pitch or 0)
    if pitch ~= 0 then
        dy = dy + pitch
        local len = math.sqrt(dx * dx + dy * dy + dz * dz)
        if len > 0.001 then dx, dy, dz = dx / len, dy / len, dz / len end
    end
    return Vector3f.new(dx, dy, dz)
end

-- [WURF_RANGE] velocity-abhaengig, aber HART zwischen vmin/vmax: langsamer Schwung -> vmin, schneller -> vmax.
-- Kein sens/mult mehr -> kann NIE ueber vmax hinausschiessen ("kilometerweit"). vmin/vmax pro Waffe einstellbar.
local function map_throw_speed(hs, vmin, vmax)
    vmin = vmin or TCFG.throw_speed_min
    vmax = vmax or TCFG.throw_speed_max
    local t = (hs - TCFG.hand_speed_min) / (TCFG.hand_speed_max - TCFG.hand_speed_min)
    t = math.max(0, math.min(1, t))
    return vmin + t * (vmax - vmin)
end
local function eff_sensitivity(hs)
    local t = (hs - TCFG.hand_speed_min) / (TCFG.hand_speed_max - TCFG.hand_speed_min)
    t = math.max(0, math.min(1, t))
    return TCFG.sensitivity_min + t * (TCFG.sensitivity_max - TCFG.sensitivity_min)
end

-- Value-Type-Argumente ueberschreiben (wie crosshair Bullet/Rocket-Hook)
local _vec3_t = sdk.find_type_definition("via.vec3")
local _quat_t = sdk.find_type_definition("via.Quaternion")
local _set_vec3 = _vec3_t and _vec3_t:get_method("set_Item(System.Int32, System.Single)")
local _set_quat = _quat_t and _quat_t:get_method("set_Item(System.Int32, System.Single)")
local _get_quat = _quat_t and _quat_t:get_method("get_Item(System.Int32)")

-- Hook-Override: args[3]=pos(via.vec3), args[4]=rot(via.Quaternion)
-- (empirisches REF-Layout, wie im crosshair-requestFire-Hook)
-- Schreibt NUR wenn _G.__re4_throw_rot_apply == true.
function _G.__re4_throw_override(a, b)
    -- robust gegen alte (args) + neue (tag, args) Closure
    local tag, args
    if b == nil then tag, args = "?", a else tag, args = a, b end
    -- Generator-Instanz + native Wurf-Rotation einfangen (fuer direkten Spawn)
    if tag == "requestFire" then
        if not _G.__re4_grenade_gen then
            local g = safe_mo(args[2])
            if g then pcall(function() g:add_ref() end); _G.__re4_grenade_gen = g end
        end
        pcall(function()
            local ra = sdk.to_ptr(sdk.to_int64(args[4]))
            _G.__re4_grenade_rot = {
                x = _get_quat:call(ra, 0), y = _get_quat:call(ra, 1),
                z = _get_quat:call(ra, 2), w = _get_quat:call(ra, 3),
            }
        end)
    end
    local gren = is_grenade_equipped()
    local dir = _G.__re4_throw_dir
    if _G.__re4_throw_rot_apply ~= true then return end   -- Rotations-Override DAUERHAFT AUS (killt Velocity)
    if not TCFG.enabled or not gren or not dir or not _set_quat then return end
    -- Nur ROTATION ueberschreiben (native vec3=Spawn an der Hand ist ok).
    -- Horizontale Schwung-Richtung + fester Aufwaerts-Bogen (sonst Wurf in Boden).
    local hlen = math.sqrt(dir.x * dir.x + dir.z * dir.z)
    local hx, hz
    if hlen > 0.05 then
        hx, hz = dir.x / hlen, dir.z / hlen
    else
        local fwd = get_char_forward()
        if not fwd then return end
        local fh = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
        if fh < 0.001 then return end
        hx, hz = fwd.x / fh, fwd.z / fh
    end
    local pitch = TCFG.throw_pitch or 0.6
    local ch, cy = math.cos(pitch), math.sin(pitch)
    local launch = Vector3f.new(hx * ch, cy, hz * ch):normalized()
    local q = launch:to_quat()
    local ra = sdk.to_ptr(sdk.to_int64(args[4]))
    _set_quat:call(ra, 0, q.x)
    _set_quat:call(ra, 1, q.y)
    _set_quat:call(ra, 2, q.z)
    _set_quat:call(ra, 3, q.w)
end

-- calcStartVec POST: nativen Start-Velocity-Vektor lesen (Betrag = Tempo).
-- Spaeter: hier den Velocity-Vektor ersetzen (= Wurf in unsere Richtung/Tempo).
function _G.__re4_calcstart_post(retval)
    pcall(function()
        if _G.__re4_throw_apply ~= true then return end
        if not _set_vec3 then return end
        if not TCFG.enabled or not is_grenade_equipped() then return end
        -- RE9 1:1: Velocity = dir * map_throw_speed(peak) * eff_sensitivity(peak)
        -- calcStartVec-Return ist nicht aenderbar (Value-Type per Register) -> no-op
    end)
    return retval
end

if not _G.__re4_throw_hooks_v3 then
    _G.__re4_throw_hooks_v3 = true
    local td = sdk.find_type_definition("chainsaw.ThrowingGrenadeGenerator")
    local sigs = {
        "requestFire(via.vec3, via.Quaternion)",
        "requestGenerate(via.vec3, via.Quaternion, chainsaw.ShellGeneratorBase.GenerateInfoBase, chainsaw.IShellGeneratorOwner)",
    }
    for _, sig in ipairs(sigs) do
        local m = td and td:get_method(sig)
        local tag = sig:match("^(%w+)")
        if m then
            sdk.hook(m,
                function(a) pcall(function() _G.__re4_throw_override(tag, a) end) end,
                function(r) return r end)
        end
    end
    local mcs = td and td:get_method("calcStartVec")
    if mcs then
        sdk.hook(mcs,
            function(a) end,
            function(r) return _G.__re4_calcstart_post(r) end)
    end
end

-- [CONNECTOR] RE4-Anschluss = RE9s createThrowingShell(vel): nach
-- GrenadeShell.activateRigidbody der gespawnten Shell die LinearVelocity
-- unseres RE9-throw_vel geben. Damit fliegt sie in Schwung-Richtung/Tempo.
local _rbs_type = sdk.typeof("via.dynamics.RigidBodySet")
function _G.__re4_activate_pre(args) _G.__re4_act_shell = args[2] end
function _G.__re4_activate_post(retval)
    pcall(function()
        if _G.__re4_throw_pending ~= true then return end   -- EINMAL pro Wurf
        local v = _G.__re4_throw_vel
        if not v then return end
        local shell = safe_mo(_G.__re4_act_shell)
        if not shell then return end
        -- DER Move-Vektor der Granate: einmal setzen, updateMove_Throwing arct ihn
        shell:set_field("_CurrentMoveVec", Vector3f.new(v.x, v.y, v.z))
        _G.__re4_throw_pending = false
    end)
    return retval
end

-- updateMove_Throwing/_Launch = der eigentliche per-Frame-Mover der Shell.
-- Velocity hier als LETZTES setzen (POST), sonst ueberschreibt der native Mover.
function _G.__re4_move_pre(args)
    _G.__re4_move_shell = args[2]   -- POST braucht die Shell-Instanz
end
function _G.__re4_move_post(retval)
    pcall(function()
        if not _G.__re4_throw_apply_until or os.clock() > _G.__re4_throw_apply_until then return end
        local v = _G.__re4_throw_vel
        if not v then return end
        local shell = safe_mo(_G.__re4_move_shell)
        if not shell then return end
        -- Schwerkraft selbst auf unseren Velocity-Vektor legen (Bogen + Fall),
        -- da der konstante Override sonst die native Gravitation verhindert.
        local now = os.clock()
        local dt = now - (_G.__re4_throw_last_t or now)
        if dt < 0.0 or dt > 0.1 then dt = 1.0 / 60.0 end
        _G.__re4_throw_last_t = now
        local g = TCFG.gravity or 9.8
        _G.__re4_throw_vel = Vector3f.new(v.x, v.y - g * dt, v.z)
        shell:set_field("_CurrentMoveVec", _G.__re4_throw_vel)
    end)
    return retval
end

if not _G.__re4_throw_hooks_v7 then
    _G.__re4_throw_hooks_v7 = true
    local td = sdk.find_type_definition("chainsaw.GrenadeShell")
    local m = td and td:get_method("activateRigidbody")
    if m then
        sdk.hook(m,
            function(a) pcall(function() _G.__re4_activate_pre(a) end) end,
            function(r) return _G.__re4_activate_post(r) end)
    end
    for _, mn in ipairs({ "updateMove_Throwing", "updateMove_Launch", "updateMove" }) do
        local mm = td and td:get_method(mn)
        if mm then
            sdk.hook(mm,
                function(a) pcall(function() _G.__re4_move_pre(a) end) end,
                function(r) return _G.__re4_move_post(r) end)
        end
    end
end

-- [DIRECTION] throwRot im nativen Wurf umbiegen: nach updateTargetPrediction
-- (setzt throwRot aim-/blickbasiert) rotieren wir es um Welt-Y von Blick- auf
-- Schwung-Richtung. Danach rechnet calcStartVec die Velocity in unsere Richtung.
function _G.__re4_pred_pre(args) _G.__re4_pred_this = args[2] end
function _G.__re4_pred_post(retval)
    do return retval end   -- throwRot-Feld beeinflusst die Flugrichtung nicht -> aus
    --[[ futiler Alt-Code:
    pcall(function()
        if _G.__re4_throw_apply ~= true or not is_grenade_equipped() then return end
        local dir = _G.__re4_throw_dir
        if not dir then return end
        local shlen = math.sqrt(dir.x * dir.x + dir.z * dir.z)
        if shlen < 0.05 then return end
        local sx, sz = dir.x / shlen, dir.z / shlen
        local fwd = get_char_forward()
        if not fwd then return end
        local fhlen = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
        if fhlen < 0.001 then return end
        local lx, lz = fwd.x / fhlen, fwd.z / fhlen
        local yaw = math.atan2(sx, sz) - math.atan2(lx, lz)
        if math.abs(yaw) < 0.01 then return end
        local gen = safe_mo(_G.__re4_pred_this)
        if not gen then return end
        local tr = gen:get_field("throwRot")
        if not tr then return end
        local h = yaw * 0.5
        local dq = Quaternion.new(math.cos(h), 0.0, math.sin(h), 0.0)   -- Welt-Y-Rotation
        local trq = Quaternion.new(tr.w, tr.x, tr.y, tr.z)
        local newq = dq * trq
        gen:set_field("throwRot", newq)
        local nowt = os.clock()
        if not _G.__re4_pred_logt or (nowt - _G.__re4_pred_logt) > 0.3 then
            _G.__re4_pred_logt = nowt
            local rb = gen:get_field("throwRot")
            throw_log(string.format("[pred] yaw=%.2f set throwRot=(%.3f,%.3f,%.3f,%.3f) readback=(%.3f,%.3f,%.3f,%.3f)",
                yaw, newq.x, newq.y, newq.z, newq.w,
                rb and rb.x or 0, rb and rb.y or 0, rb and rb.z or 0, rb and rb.w or 0))
        end
    end)
    --]]
    return retval
end

-- [ENTFERNT 2026-07-17] __re4_setupshell + onSetupShell-Hooks (v6) waren ein reiner
-- Component-Dump in den throw_diag.log; der Post-Hook reichte den Return nur durch.
-- Ohne den Dump hatte das Konstrukt keine Wirkung mehr -> Funktion + Hook-Block raus.

if not _G.__re4_throw_hooks_v4 then
    _G.__re4_throw_hooks_v4 = true
    local td = sdk.find_type_definition("chainsaw.ThrowingGrenadeGenerator")
    local m = td and td:get_method("updateTargetPrediction")
    if m then
        sdk.hook(m,
            function(a) pcall(function() _G.__re4_pred_pre(a) end) end,
            function(r) return _G.__re4_pred_post(r) end)
    end
end

-- Generator direkt aus der Szene finden (kein Native-Wurf-Bootstrap noetig)
local _scene_cache = nil
local function get_scene()
    if _scene_cache then return _scene_cache end
    local sm = sdk.get_native_singleton("via.SceneManager")
    if sm then
        _scene_cache = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end
    return _scene_cache
end
local _gen_type = sdk.typeof("chainsaw.ThrowingGrenadeGenerator")
local function find_grenade_generator()
    if _G.__re4_grenade_gen then
        local ok = pcall(function() return _G.__re4_grenade_gen:get_field("throwRot") end)
        if ok then return _G.__re4_grenade_gen end
        _G.__re4_grenade_gen = nil
    end
    local scene = get_scene()
    if not scene then return nil end
    local comps = nil
    pcall(function() comps = scene:call("findComponents(System.Type)", _gen_type) end)
    if not comps then return nil end
    local list = nil
    pcall(function() list = comps:get_elements() end)
    if list and #list > 0 then
        _G.__re4_grenade_gen = list[1]
        return list[1]
    end
    return nil
end

-- [GEN_SAVELOAD 2026-08-06, "die Granaten haengen manchmal nach einem Load, nach Reset Scripts
-- geht alles wieder"] Genau das Muster eines Caches, der nur der Lua-Reset leert:
-- * _G.__re4_grenade_gen -- der ThrowingGrenadeGenerator, per add_ref festgehalten (Z.3191).
-- * _scene_cache -- die Szene selbst; beim Laden wird eine NEUE Szene aufgebaut.
-- Nach einem Save-Load zeigen beide auf tote Objekte. Der vorhandene Gueltigkeits-Check in
-- find_grenade_generator ist dagegen blind: `pcall(gen:get_field("throwRot"))` wirft bei einem toten
-- managed Zeiger nicht, es kommt nur nil zurueck -> ok=true -> der tote Generator wird weiterbenutzt,
-- requestFire laeuft ins Leere und der Wurf passiert nie. Und weil die Szene ebenfalls stale ist,
-- findet auch der Fallback (findComponents) keinen Ersatz. Beides zusammen = "Granate haengt".
-- Erkennung wie im Messer-Pfad (re4_vr_weapons2.lua): Adresse des Player-Body-GO. Sie wechselt beim
-- Save-Load und beim Charakterwechsel. Nicht lesbar (Ladephase) -> nichts verwerfen, nichts merken.
-- Kein release auf den Generator: nach dem Load kann er tot sein, ein release darauf waere genau
-- der Deref, den wir vermeiden. Loslassen genuegt. [[Notiz]]
local _gen_body_addr, _gen_next_check = nil, 0.0
local function grenade_cache_guard()
    if os.clock() < _gen_next_check then return end
    _gen_next_check = os.clock() + 0.25
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager"); if not cm then return end
    local ok, body = pcall(function()
        local c = cm:call("getPlayerContextRef"); if not c then return nil end
        return c:call("get_BodyGameObject")
    end)
    if not (ok and body) then return end
    local ok2, a = pcall(function() return body:get_address() end)
    if not (ok2 and a) then return end
    if _gen_body_addr == nil then _gen_body_addr = a; return end
    if a == _gen_body_addr then return end
    _gen_body_addr = a
    _G.__re4_grenade_gen = nil
    _scene_cache = nil
    _G.__re4_gren_cache_dropped_t = os.clock()   -- [FORENSIK] wann zuletzt verworfen
end
re.on_frame(function() pcall(grenade_cache_guard) end)

-- DIREKT-SPAWN (kein RT, keine native Animation): Granate an der HAND spawnen.
-- Frueher Fehlschlag = kalte _GeneratePos(=0) als Position uebergeben -> Ursprung.
-- Jetzt: Hand-Position als requestFire-Pos. _CurrentMoveVec-Connector lenkt dann.
local function do_vr_throw()
    local gen = find_grenade_generator()
    if not gen then return false end
    local pos = _G.__vr_rh_world
    if not pos then return false end
    local p = Vector3f.new(pos.x, pos.y, pos.z)
    local q = Quaternion.new(1, 0, 0, 0)   -- Identitaet; _CurrentMoveVec bestimmt die Flugbahn
    pcall(function() gen:set_field("_GeneratePos", p) end)
    local ok = pcall(function() gen:call("requestFire(via.vec3, via.Quaternion)", p, q) end)
    return ok
end

-- Body-Motion des Spielers (wird vom GRENADE FAST-FORWARD unten gebraucht).
-- [ENTFERNT 2026-07-17] motion_probe_tick war reiner [MOT]-Log-Spam und lange
-- per "motion_probe_until = 0" tot -- Layer/IDs sind gefunden.
local motion_type = sdk.typeof("via.motion.Motion")
local function get_body_motion()
    local ctx = get_player_ctx()
    local body = ctx and safe_call(ctx, "get_BodyGameObject")
    if not body then return nil end
    return safe_call1(body, "getComponent(System.Type)", motion_type)
end

-- [GRENADE FAST-FORWARD] Native Wurf-Anim (Body-Motion, MotionID 1400, Shell-Spawn ~Frame 59)
-- vorspulen: solange die Wurf-Motion laeuft + Frame < Spawn, Layer-Speed hochsetzen -> Shell kommt
-- fast sofort statt nach ~1.1s, danach Speed zurueck auf 1 (Rest der Anim normal). Flugrichtung
-- (_CurrentMoveVec) + Explosion (nativ) unveraendert. ID/Frame live per Slider tunebar.
_G.__re4_gren_ff = _G.__re4_gren_ff or { id = 1400, frame = 57, speed = 6.0, enabled = true }
local grenade_ff_until = 0
local function grenade_ff_tick()
    if os.clock() > grenade_ff_until then return end
    local cfg = _G.__re4_gren_ff
    if not cfg.enabled then return end
    local m = get_body_motion(); if not m then return end
    local lc = safe_call(m, "getLayerCount") or 0
    for i = 0, lc - 1 do
        local layer = safe_call1(m, "getLayer", i)
        if layer and safe_call(layer, "get_MotionID") == cfg.id then
            local frame = safe_call(layer, "get_Frame") or 0
            if frame < (cfg.frame or 57) then
                pcall(function() layer:call("set_Speed", cfg.speed or 6.0) end)
            else
                pcall(function() layer:call("set_Speed", 1.0) end)   -- Shell da -> Rest normal
                grenade_ff_until = 0
            end
            return
        end
    end
end

------------------------------------------------------------
-- [SHELL_EJECT] Patronenhülsen aus dem VR-Lauf werfen statt aus der Brust.
-- chainsaw.BulletCaseManager.requestGenerateBulletCase(WeaponID, gunObj) wird im
-- Gameplay-Update gerufen, BEVOR die VR-Mod die Waffe in die Hände setzt -> der
-- Manager liest den Emit-Joint (vfx_muzzle2) in der nativen Pose (Brust) -> Hülsen
-- kommen aus der Brust, egal wohin man zielt.
-- Fix: VR-positionierte vfx_muzzle2-Weltlage jeden Frame cachen; die gunObj-
-- Überladung SKIPpen und stattdessen die explizite (WeaponID, vec3, Quaternion)-
-- Überladung mit der gecachten VR-Lage aufrufen -> Hülse spawnt aus dem VR-Lauf.
-- WICHTIG: args[1] ist hier NICHT 'this' (wechselt pro Aufruf = Pointer-Arg) ->
-- Manager als Singleton holen. Cache via _G.__* -> der EINMAL installierte Hook
-- liest nach Reset Scripts die frischen Werte der neuen on_frame (Guard-Muster).
-- HINWEIS: sdk.hook -> greift erst nach KOMPLETTEM Spiel-Neustart.
------------------------------------------------------------
local SHELL_EMIT_JOINTS = { "vfx_muzzle2", "vfx_muzzle1" }   -- Emit-Joint laut BulletCaseUserData (+Fallback)

local function shell_refresh_muzzle()
    local ctx = get_player_ctx(); if not ctx then return end
    local hu  = safe_call(ctx, "get_HeadUpdater"); if not hu then return end
    local gun = safe_call(hu, "get_EquipWeapon"); if not gun then return end
    local go  = safe_call(gun, "get_GameObject"); if not go then return end
    local tf  = safe_call(go, "get_Transform"); if not tf then return end
    local j
    for _, name in ipairs(SHELL_EMIT_JOINTS) do
        j = safe_call1(tf, "getJointByName", name)
        if j then break end
    end
    if not j then return end
    local p = safe_call(j, "get_Position")
    local r = safe_call(j, "get_Rotation")
    if p then _G.__re4_shell_pos = Vector3f.new(p.x, p.y, p.z) end
    if r then _G.__re4_shell_rot = Quaternion.new(r.w, r.x, r.y, r.z) end
    _G.__re4_shell_wid = get_equip_weapon_id()
    -- [ENEMY-FIX 2026-07-16] Adressen der SPIELER-Gun cachen (Waffe + GameObject). Der Hook unten leitet
    -- die Huelsen NUR dann um, wenn genau DIESE gunObj feuert -> Turret-Gegner-Huelsen bleiben nativ.
    pcall(function() _G.__re4_shell_gun_addr = gun:get_address() end)
    pcall(function() _G.__re4_shell_go_addr = go:get_address() end)
end

if not _G.__re4_shell_hooks_installed then
    _G.__re4_shell_hooks_installed = true
    local td = sdk.find_type_definition("chainsaw.BulletCaseManager")
    local m_gunobj, m_pos = nil, nil   -- (WeaponID, gunObj) [vom Spiel genutzt] / (WeaponID, vec3, Quaternion)
    if td then
        for _, m in ipairs(td:get_methods()) do
            if m:get_name() == "requestGenerateBulletCase" then
                local n = #m:get_param_types()
                if n == 2 then m_gunobj = m elseif n == 3 then m_pos = m end
            end
        end
    end
    if m_gunobj and m_pos then
        sdk.hook(m_gunobj,
            function(args)
                -- [ENEMY-FIX 2026-07-16] NUR umleiten, wenn die SPIELER-Gun feuert. Sonst (Turret-Gegner
                -- feuert -> requestGenerateBulletCase mit FREMDER gunObj) native Huelse durchlassen -- sonst
                -- springen Gegner-Huelsen aus der Spieler-Waffe. gunObj-Adresse gegen die gecachte Spieler-Gun
                -- (Waffe ODER GameObject) pruefen, index-robust ueber args[1..4] (this-Position unklar, s.
                -- Kommentar oben). Kein Match / kein Cache -> nativ (fail-safe: schlimmstenfalls Huelse aus der
                -- nativen Brust-Pose wie vor dem Redirect, aber nie aus fremder Waffe).
                local ga = rawget(_G, "__re4_shell_gun_addr")
                local goa = rawget(_G, "__re4_shell_go_addr")
                local mine = false
                if ga or goa then
                    for i = 1, 4 do
                        local a = nil
                        pcall(function() a = sdk.to_int64(args[i]) end)
                        if a and (a == ga or a == goa) then mine = true; break end
                    end
                end
                if not mine then return sdk.PreHookResult.CALL_ORIGINAL end
                local handled = false
                pcall(function()
                    local p = rawget(_G, "__re4_shell_pos")
                    local r = rawget(_G, "__re4_shell_rot")
                    local w = rawget(_G, "__re4_shell_wid")
                    if not (p and r and w) then return end   -- kein Cache -> native Hülse durchlassen
                    local mgr = sdk.get_managed_singleton("chainsaw.BulletCaseManager")
                    if not mgr then return end
                    m_pos:call(mgr, w, p, r)
                    handled = true
                end)
                -- Redirect ok -> native Brust-Hülse unterdrücken; sonst nativ durchlassen.
                if handled then return sdk.PreHookResult.SKIP_ORIGINAL end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end
end

------------------------------------------------------------
-- [THROWSIGHT] Native Granaten-Ziellinie (chainsaw.ThrowSight*) unterdruecken, solange
-- _G.__re4_suppress_throwsight (= Granate equippt). Hook-Body liest nur das Global -> Reset-tauglich.
-- Mechanik uebernommen aus dem alten re4_vr_minecart.lua (update/draw SKIP).
------------------------------------------------------------
if not _G.__re4_throwsight_hooks then
    _G.__re4_throwsight_hooks = true
    for _, tn in ipairs({ "chainsaw.ThrowSightController", "chainsaw.ThrowSight", "chainsaw.ThrowSightManager" }) do
        local td = sdk.find_type_definition(tn)
        if td then
            for _, mn in ipairs({ "update", "onUpdate", "lateUpdate", "draw", "onDraw", "doUpdate", "doLateUpdate" }) do
                local m = td:get_method(mn)
                if m then pcall(function()
                    sdk.hook(m,
                        function()
                            -- [THROWSIGHT-STAGE] Im Del-Lago-Harpunen-Abschnitt (Stage 46900,
                            -- Body an gm02_500_00_1) die native Ziellinie NICHT unterdruecken —
                            -- dort wird nativ gezielt und die Linie soll sichtbar sein.
                            -- [BOAT 2026-07-18] Genauso im Boot (get_IsBoat/KS4, __re4_boat_active): dort
                            -- zielt man nativ ueber die Ziellinie -> NICHT unterdruecken, sonst fehlt die Anzeige.
                            if rawget(_G, "__re4_suppress_throwsight") == true
                                    and rawget(_G, "__re4_throwsight_active") ~= true
                                    and rawget(_G, "__re4_boat_active") ~= true then
                                return sdk.PreHookResult.SKIP_ORIGINAL
                            end
                            return sdk.PreHookResult.CALL_ORIGINAL
                        end,
                        function(retval) return retval end)
                end) end
            end
        end
    end
end

------------------------------------------------------------
-- Frame update
------------------------------------------------------------
re.on_frame(function()
    shell_refresh_muzzle()
    hide_assist_light()
    grenade_ff_tick()   -- [GRENADE FF] Wurf-Anim vorspulen (Shell sofort)
    weapon_switch_skip_tick()

    update_knife_holster_timer()
    keep_knife_out()   -- [KNIFE_KEEP_OUT] Messer bleibt draussen (kein Auto-Holster)

    if vr_holster_knife then
        vr_holster_knife = false
        local equipped_id = get_equip_weapon_id()
        if equipped_id and KNIFE_IDS[equipped_id] then
            holster_knife()
        end
    end

    -- [KNIFE_THROW] Rechter Grip beim Messer = Wurf scharf; LOSLASSEN = Wurf (Peak-Velocity
    -- waehrend des Haltens). Gleiche Velocity-Mathe wie der Granaten-Wurf. Aim (LT) ist beim
    -- Messer per binding.lua unterdrueckt -> rechter Grip dient nur hier dem Wurf.
    local knife_equ = is_knife_equipped()
    _G.__re4_knife_equipped = knife_equ            -- fuer binding.lua (R-Grip -> Wurf statt Aim)
    -- [KNIFE_HAND 2026-07-07] Tri-State: welche VR-Hand haelt das Messer? Single Source of Truth fuer
    -- alle Consumer (Swing/Wurf/Flip/Parry/Pin). Hier NUR ABLEITEN, nie schreiben: __re4_knife_left_intent
    -- gehoert re4_vr_knife_lefthand.lua (setzt/raeumt es inkl. Grace-Fenster gegen die Deferral-Luecke).
    if not knife_equ then
        _G.__re4_knife_hand = "none"
    else
        _G.__re4_knife_hand = (rawget(_G, "__re4_knife_left_intent") == true) and "left" or "right"
    end
    -- [LH_CLONE WURF] auch der Links-Klon (nicht equippt) soll werfen -> Block auch dann laufen lassen.
    if knife_equ or rawget(_G, "__re4_knife_left_clone") == true then
        knife_flight_tick()   -- [FLIGHT] Physik/Tumble/Rueckkehr des fliegenden Messers
        local now = os.clock()
        -- Kein Wurf-Windup waehrend Flug ODER waehrend die (aktive) Hand am Holster-Dummy ist (dort = ziehen).
        -- [KNIFE_HAND] Grip + Holster-Zone der Hand, die das Messer HAELT (links vs rechts / Klon = links).
        local left_knife = rawget(_G, "__re4_knife_hand") == "left" or rawget(_G, "__re4_knife_left_clone") == true
        local grip_raw = _G.__re4_knife_grip_held()
        local hz
        if left_knife then hz = rawget(_G, "__vr_knife_lh_holster_zone") == true
        else hz = rawget(_G, "__vr_knife_holster_zone") == true end
        -- [KNIFE_FLIP] In Flipped-Position KEIN Wurf-Windup (fuer spaeteres Feature reserviert).
        local flipped = rawget(_G, "__vr_knife_flip") == true
        -- [WP5002 WURFSPERRE RAUS 2026-07-17] Hier stand ein `and (not no_throw_knife)` (wp5002 == kein Wurf),
        -- weil der Wurf mangels AttackUD keinen Schaden machte. Der borrow-Fix (leiht die AttackUD jetzt auch
        -- von einer Gegnerwaffe) behebt das -> wp5002 macht wieder Schaden, also darf es auch wieder geworfen
        -- werden. Wurf damit fuer ALLE Messer gleich, kein Sonderfall mehr.
        local gripping = (not kfly.active) and (not hz) and (not flipped) and grip_raw
        _G.__re4_knife_throw_gripping = gripping   -- Melee-Gate: kein Stich waehrend Wurf-Windup
        if gripping then
            update_throw_velocity()
            _G.__re4_knife_throw_dir = get_throw_direction(TCFG.knife_pitch, TCFG.knife_yaw)   -- [Y/X-KORREKTUR] Messer-Pitch + Yaw
            _G.__re4_knife_throw_dir_raw = get_throw_direction(0)              -- rohe Hand-Richtung (Vorwaerts-Check)
            kthrow.peak = compute_release_window_peak()
        end
        if kthrow.was_gripping and not gripping then
            local dir = _G.__re4_knife_throw_dir
            -- [ANTI-NOSEDIVE 2026-07-06] Die Wurfrichtung kommt aus der Hand-SCHWUNG-Velocity; ein natuerlicher
            -- Wurf flickt nach vorne-UNTEN (THROWCAL: draw.y bis -0.80 = 53 Grad runter). Das schickt das Messer
            -- in den Boden, UNABHAENGIG von jeder Zielhilfe. Fix: die steile Abwaerts-Neigung kappen -> die
            -- HORIZONTALE Zielrichtung (x/z, wo du hinzeigst) bleibt exakt, nur der Runter-Anteil wird auf
            -- max ~14 Grad begrenzt. Nach oben bleibt frei (Lob ueber Distanz).
            if dir then
                local MIN_Y = -0.25
                if dir.y < MIN_Y then
                    local h = math.sqrt(dir.x * dir.x + dir.z * dir.z)
                    if h > 0.001 then
                        local hscale = math.sqrt(math.max(0.0001, 1.0 - MIN_Y * MIN_Y)) / h
                        dir = Vector3f.new(dir.x * hscale, MIN_Y, dir.z * hscale)
                        _G.__re4_knife_throw_dir = dir
                    end
                end
            end
            local hmd_cal = (_G.__re4_knife_fly_cfg and _G.__re4_knife_fly_cfg.hmd_force == true)
            -- [VORWAERTS-CHECK] nur werfen, wenn die Hand-Bewegung eine VORWAERTS-Komponente hat (Richtung Blick).
            -- Ein schneller Rueckzug zum Koerper hat hohe Velocity, aber zeigt nach HINTEN -> KEIN Wurf.
            local fwd_ok = true
            do
                local draw = _G.__re4_knife_throw_dir_raw
                local fwd = get_char_forward()   -- [FIX] char_forward trackt die Drehung (HMD/rot0 nicht)
                if draw and fwd then
                    local fl = math.sqrt(fwd.x*fwd.x + fwd.y*fwd.y + fwd.z*fwd.z)
                    if fl > 0.001 then
                        fwd_ok = (draw.x*fwd.x + draw.y*fwd.y + draw.z*fwd.z) / fl > 0.15
                    end
                end
            end
            -- [HMD_CAL] Im Kalibrier-Modus NICHT am Vorwaerts-Check blocken (wir forcen die Richtung eh).
            if hmd_cal then fwd_ok = true end
            if fwd_ok and kthrow.peak >= (rawget(_G, "__re4_knife_throw_threshold") or TCFG.hand_speed_min) and (now - last_knife_throw_t) >= 0.4 and dir then
                -- [FESTER WURF] velocity-unabhaengig: feste Geschwindigkeit (cfg.speed) wie frueher -> gutes,
                -- vorhersehbares Wurfverhalten. Der Schwung entscheidet nur OB + Richtung, nicht die Weite.
                last_knife_throw_t = now
                -- [BASIS-FLUG = HAND] dir bleibt die Handwurf-Richtung (natuerlich, nicht robotic).
                -- [RICHTUNGS-CLAMP] Optional: Wurfrichtung in einen Kegel um char_forward zwingen (default
                -- dir_max_deg=90 = AUS -> voller natuerlicher Hand-Wurf; nur ein Sicherheits-Clamp).
                do
                    local kfc = _G.__re4_knife_fly_cfg
                    local maxd = (kfc and kfc.dir_max_deg) or 90
                    local fwd = (maxd < 89) and get_char_forward() or nil
                    local fl = fwd and math.sqrt(fwd.x*fwd.x + fwd.y*fwd.y + fwd.z*fwd.z) or 0
                    if fl > 0.001 then
                        local fx, fy, fz = fwd.x/fl, fwd.y/fl, fwd.z/fl
                        local dot = math.max(-1, math.min(1, dir.x*fx + dir.y*fy + dir.z*fz))
                        local ang = math.acos(dot)
                        local maxa = maxd * math.pi / 180
                        if ang > maxa and ang > 0.001 then
                            local t = maxa / ang; local s = math.sin(ang)
                            local a = math.sin((1-t)*ang)/s; local b = math.sin(t*ang)/s
                            local nx, ny, nz = fx*a + dir.x*b, fy*a + dir.y*b, fz*a + dir.z*b
                            local nl = math.sqrt(nx*nx+ny*ny+nz*nz)
                            if nl > 0.001 then dir = Vector3f.new(nx/nl, ny/nl, nz/nl) end
                        end
                    end
                end
                -- [ZIELHILFE-KEGEL] Der Kegel um char_forward (validierte, mitdrehende Blickrichtung) macht NUR
                -- das Homing. Basis-Flug bleibt die Handrichtung (dir). Liegt ein Gegner/Breakable im Kegel,
                -- wird das Messer zu ihm gezogen -- GRADUELL nach Zentrierung: innen=voll, zum Rand schwaecher,
                -- ausserhalb=0. Knoepfe (JSON): assist_cone_inner_deg / assist_cone_deg / assist_homing / assist_strength.
                do
                    local kfc    = _G.__re4_knife_fly_cfg
                    local strg   = kfc and tonumber(kfc.assist_strength) or 0   -- [A] Abwurf-Nudge (einmalig)
                    local homing = kfc and tonumber(kfc.assist_homing) or 0     -- [B] In-Flug-Homing pro Frame
                    _G.__re4_knife_assist_flat = 0.0
                    _G.__re4_knife_home = nil
                    _G.__re4_knife_home_ctx = nil
                    _G.__re4_knife_home_str = 0.0
                    if strg > 0 or homing > 0 then
                        local origin = _G.__re4_knife_hand_world()   -- [KNIFE_HAND] aktive Messer-Hand (Fallback wenn Kamera fehlt)
                        -- [CONTROLLER-REF 2026-07-04] Kegel-Achse = tatsaechliche Wurfrichtung der RECHTEN HAND
                        -- (dir), NICHT mehr char_forward. Basis-Flug UND Homing-Kegel teilen so DIESELBE Referenz
                        -- (deine Hand) -> kein Referenz-Drift mehr (char_forward zeigte in Koerper-, nicht Blick-/
                        -- Handrichtung). Normiert fuer den dot-Vergleich in assist_target; Fallback nur wenn dir tot.
                        -- [HMD-KEGEL] Ziel-Erkennung um die ECHTE HMD-Blickrichtung: primaere Kamera get_AxisZ
                        -- (= Forward, enthaelt die HMD-Ausrichtung, Live-Abfrage). NICHT Handbewegung/
                        -- char_forward -- die zeigen in VR oft fast ENTGEGENGESETZT zum Blick (Body-Yaw != Kopf),
                        -- wodurch die Kiste GENAU vor dir als "hinten" (negativer Dot) galt und nie gefangen wurde.
                        -- Basis-Flug bleibt die Handrichtung (dir); nur der Homing-Kegel richtet sich nach dem Blick.
                        local caxis = nil
                        do
                            local cam = sdk.get_primary_camera()
                            local cgo = cam and safe_call(cam, "get_GameObject")
                            local ctf = cgo and safe_call(cgo, "get_Transform")
                            local fwd = ctf and safe_call(ctf, "get_AxisZ")
                            if fwd then
                                -- [FORWARD-VORZEICHEN] get_AxisZ zeigt bei dieser Kamera NACH HINTEN -> negieren,
                                -- damit caxis die echte Blickrichtung nach VORNE ist (Messer flog sonst 180 verkehrt).
                                local l = math.sqrt(fwd.x*fwd.x + fwd.y*fwd.y + fwd.z*fwd.z)
                                if l > 1e-6 then caxis = Vector3f.new(-fwd.x/l, -fwd.y/l, -fwd.z/l) end
                            end
                            -- [BLICK-URSPRUNG] Der Kegel geht vom AUGE/der Kamera aus (nicht von der Hand)
                            -- -> "35 Grad genau vor deiner Nase". Nur wenn Kamera + Achse vorhanden.
                            local cpos = ctf and safe_call(ctf, "get_Position")
                            if caxis and cpos then origin = Vector3f.new(cpos.x, cpos.y, cpos.z) end
                            if not caxis then caxis = dir end   -- Fallback: Handrichtung, falls Kamera fehlt
                        end
                        local outer  = (kfc and tonumber(kfc.assist_cone_deg)) or 20          -- max Fang-Winkel
                        local inner  = (kfc and tonumber(kfc.assist_cone_inner_deg)) or 8      -- Voll-Lock-Winkel
                        local tp, tctx = nil, nil
                        if origin and caxis then
                            -- [ZIELWAHL] Gegner haben IMMER Vorrang: liegt EIN Gegner im Kegel, wird er
                            -- gewaehlt -- auch wenn eine Kiste naeher ist. Nur wenn KEIN Gegner im Kegel
                            -- ist, wird das naechste Breakable im Kegel genommen. Beide Sucher liefern
                            -- jeweils das NAECHSTE Ziel im Kegel (kein Ziel weiter hinten).
                            tp, tctx = _G.__re4_knife_assist_target(origin, caxis, 30.0, outer)
                            if not tp then
                                local bp = knife_assist_breakable(origin, caxis, 30.0, outer)
                                if bp then tp = bp; tctx = nil end
                            end
                        end
                        -- [GRADUELL] Falloff aus dem HORIZONTALEN Winkel (X/Z) des Ziels zur Kegel-Achse. Wichtig:
                        -- 3D-Dot wuerde Breakables (stehen tiefer) faelschlich rauskippen -> kein Homing. Die
                        -- Kegel-Achse ist eh flach; horizontal messen ist konsistent mit knife_assist_breakable.
                        -- [NAHFANG 2026-08-12] Der Falloff rechnet MIT DERSELBEN Metrik wie die Zielwahl --
                        -- sonst waehlt der Mindest-Schlauch den nahen Gegner aus und der Winkel-Falloff gibt
                        -- ihm fall=0, also Homing-Staerke null (Ziel gepeilt, trotzdem kein Zug). Also beide
                        -- Grenzen als RADIUS: aussen max(min_lat, d*tan(outer)), innen im selben Verhaeltnis
                        -- (min_lat*inner/outer). Auf Distanz dominiert der Winkel-Term -> unveraendert; die
                        -- Zwischenwerte laufen jetzt linear ueber die Ablage statt ueber den Cosinus.
                        local fall = 0.0
                        if tp and origin and caxis then
                            local dx,dz = tp.x-origin.x, tp.z-origin.z
                            local dl = math.sqrt(dx*dx+dz*dz)
                            local cl = math.sqrt(caxis.x*caxis.x+caxis.z*caxis.z)
                            if dl>1e-6 and cl>1e-6 then
                                local tdot = (dx*caxis.x+dz*caxis.z)/(dl*cl)
                                -- [NUR GEGNER 2026-08-12] Der Schlauch gilt ausschliesslich fuer Gegner (tctx
                                -- gesetzt). Auf Breakables angewandt bekam jede nahe Kiste statt fall~0 sofort
                                -- fall=1 -> das Messer riss in alles Nahe rein, statt geradeaus zum Fass zu
                                -- fliegen. Kisten/Faesser/Tiere rechnen deshalb weiter rein ueber den Winkel.
                                local mlat = tctx and (tonumber(kfc and kfc.assist_min_lat) or 0.0) or 0.0
                                if mlat > 0.0 then
                                    local tlat = dl * math.sqrt(math.max(0.0, 1.0 - tdot*tdot))
                                    local ro = math.max(mlat, dl*math.tan(outer*math.pi/180))
                                    local ri = math.max(mlat*(inner/math.max(1e-6, outer)), dl*math.tan(inner*math.pi/180))
                                    if tdot <= 0 then fall = 0.0
                                    elseif tlat <= ri then fall = 1.0
                                    elseif tlat >= ro then fall = 0.0
                                    else fall = (ro-tlat)/math.max(1e-6, ro-ri) end
                                else
                                    local ic, oc = math.cos(inner*math.pi/180), math.cos(outer*math.pi/180)
                                    if tdot >= ic then fall = 1.0
                                    elseif tdot <= oc then fall = 0.0
                                    else fall = (tdot-oc)/math.max(1e-6, ic-oc) end
                                end
                            end
                        end
                        if tp and fall > 0.0 then
                            -- [ECHTES ZIEL] Homing zieht direkt zur ERKANNTEN Objekt-Position (Gegner, WoodBox
                            -- oder naechstes Objekt im Blickkegel). Keine Blickachsen-Projektion mehr.
                            _G.__re4_knife_assist_flat = ((kfc and tonumber(kfc.assist_flatten)) or 0.0) * fall
                            _G.__re4_knife_home = { x = tp.x, y = tp.y, z = tp.z }
                            _G.__re4_knife_home_ctx = tctx
                            _G.__re4_knife_home_str = homing * fall                 -- [B] In-Flug-Homing, graduell
                            -- [HAND-URSPRUNG] Der Abwurf-Nudge lenkt die FLUGRICHTUNG -> ab der HAND rechnen
                            -- (Flug-Start), NICHT ab dem Auge (origin=cam_pos). Sonst zeigt dir durch die
                            -- Augen-Hand-Hoehendifferenz nach unten -> Messer geht sofort zu Boden.
                            local hand = _G.__re4_knife_hand_world() or origin   -- [KNIFE_HAND] Nudge ab der aktiven Messer-Hand
                            local tx, ty, tz = tp.x-hand.x, tp.y-hand.y, tp.z-hand.z
                            local tl = math.sqrt(tx*tx + ty*ty + tz*tz)
                            if tl > 0.001 then
                                tx, ty, tz = tx/tl, ty/tl, tz/tl
                                local s = math.max(0, math.min(1, strg * fall))    -- [A] Abwurf-Nudge, graduell
                                local nx, ny, nz = dir.x + (tx-dir.x)*s, dir.y + (ty-dir.y)*s, dir.z + (tz-dir.z)*s
                                local nl = math.sqrt(nx*nx + ny*ny + nz*nz)
                                if nl > 0.001 then dir = Vector3f.new(nx/nl, ny/nl, nz/nl) end
                            end
                        end
                    end
                end
                play_knife_sound((_G.__re4_knife_snd or {}).throw)   -- [KNIFE_SND] Wurf-Sound beim Loslassen
                knife_throw_launch(dir)   -- [FLIGHT] fester cfg.speed
            end
            kthrow.peak = 0
        end
        kthrow.was_gripping = gripping
    else
        _G.__re4_knife_throw_gripping = false
        kthrow.was_gripping = false
    end

    -- [KNIFE_MELEE] auf die vr_knife_swing-Flanke (Velocity aus motion). Waehrend der rechte Grip
    -- gehalten wird (= Wurf-Windup) KEIN Stich -> der Schwung gehoert dann dem Wurf.
    -- [KNIFE_ONLY] NUR feuern, wenn wirklich ein Messer in der Hand ist (knife_equ). Sonst loeste JEDE
    -- schnelle Handbewegung den Melee aus -> z.B. der Granaten-Wurf-Schwung zog das Messer.
    -- [STICH_BEI_GRIP] KEIN throw_gripping-Guard mehr: solange das Messer IN DER HAND ist (nicht kfly.active),
    -- sticht es bei jedem Schwung -> genau wie ohne Grip. Der Grip bereitet nur den Wurf vor (Ausloeser =
    -- Loslassen + genug Velocity); er darf das Stechen nicht sperren.
    if vr_knife_swing == true then
        if not knife_melee_prev then
            knife_melee_prev = true
            if knife_equ and not kfly.active then
                play_knife_sound((_G.__re4_knife_snd or {}).swing)   -- [KNIFE_SND] Schwung-Sound (auch ohne Treffer)
                do_knife_melee()
            end
        end
    else
        knife_melee_prev = false
    end

    -- [THROWABLES] RE9 Release-to-Throw: Grip halten = Granate scharf (wedeln/
    -- ausholen egal), Grip LOSLASSEN = Wurf (mit der Peak-Velocity waehrend des
    -- Haltens). Verhindert versehentliche Wuerfe beim Wedeln mit gehaltenem Grip.
    if TCFG.enabled and is_grenade_equipped() then
        _G.__re4_throw_apply = true
        _G.__re4_suppress_throwsight = true   -- native Granaten-Ziellinie (ThrowSight) aus (wir werfen selbst)
        local now = os.clock()
        -- [HOLSTER] Hand am Granaten-Dummy -> R-Grip = grab (equip/stow), NICHT Wurf-Windup.
        -- grip/zone einzeln halten: kommt die Hand beim Ausholen in die Dummy-Zone, faellt aiming
        -- MITTEN im Windup weg -> Release-Check feuert zu frueh mit halbem peak, und beim echten
        -- Loslassen passiert nichts mehr (erklaert das sporadische Verhalten).
        local grip_now = is_right_grip_held()
        local zone_now = rawget(_G, "__vr_grenade_holster_zone") == true
        local aiming = grip_now and not zone_now
        if aiming then
            update_throw_velocity()
            _G.__re4_throw_dir = get_throw_direction(TCFG.grenade_pitch)   -- [Y_KORREKTUR] Granaten-Pitch
            _G.__re4_throw_dir_raw = get_throw_direction(0)                -- [VORWAERTS-CHECK] rohe Hand-Richtung
            tfsm.peak = compute_release_window_peak()
            -- [WURF-FENSTER 2026-07-23] Solange ausgeholt wird (aiming), Schulter-Holster-Grab sperren
            -- (holster.lua liest __vr_throw_windup_until). ZEITBASIERT + Grace -> schliesst sich von selbst,
            -- kann nicht haengen. Deckt Windup ueber die Schulter + kurzen Nachlauf nach dem Loslassen ab.
            _G.__vr_throw_windup_until = now + 0.40
        end
        -- LOSLASSEN = Wurf
        if tfsm.was_aiming and not aiming then
            local dir = _G.__re4_throw_dir
            -- [VORWAERTS-CHECK] wie beim Messer: nur werfen, wenn die Hand-Bewegung nach VORNE zeigt
            -- (Richtung Blick). Ein schneller Rueckzug zum Koerper hat hohe Velocity, zeigt aber nach
            -- HINTEN -> KEIN Wurf. Rohe Hand-Richtung vs char_forward (Dot > 0.15). do-Block (kein Top-Level-Local).
            local fwd_ok = true
            do
                local draw = _G.__re4_throw_dir_raw
                local fwd = get_char_forward()
                if draw and fwd then
                    local fl = math.sqrt(fwd.x*fwd.x + fwd.y*fwd.y + fwd.z*fwd.z)
                    if fl > 0.001 then
                        fwd_ok = (draw.x*fwd.x + draw.y*fwd.y + draw.z*fwd.z) / fl > 0.15
                    end
                end
            end
            if fwd_ok and tfsm.peak >= TCFG.hand_speed_min and (now - last_grenade_throw_t) >= TCFG.cooldown and dir then
                -- [FESTER WURF] feste Geschwindigkeit wie das Messer (Konsistenz) -> nie "kilometerweit".
                local speed = TCFG.throw_fixed_speed or 10.0
                _G.__re4_throw_vel = Vector3f.new(dir.x * speed, dir.y * speed, dir.z * speed)
                _G.__re4_throw_pending = true
                _G.__re4_throw_apply_until = now + 3.0
                _G.__re4_throw_last_t = now
                vr_grenade_throw = true                 -- RT -> nativer Wurf spawnt die Shell (einziger Weg)
                last_grenade_throw_t = now
                grenade_throw_reset_t = now + 0.20
                grenade_ff_until = now + 1.5             -- [GRENADE FF] Wurf-Anim vorspulen bis Shell-Spawn
            end
            tfsm.peak = 0
        end
        tfsm.was_aiming = aiming
        if not aiming then _G.__re4_throw_dir = nil end
    else
        _G.__re4_throw_apply = nil
        _G.__re4_throw_dir = nil
        _G.__re4_suppress_throwsight = false
        tfsm.was_aiming = false
    end
    if vr_grenade_throw == true and grenade_throw_reset_t > 0 and os.clock() >= grenade_throw_reset_t then
        vr_grenade_throw = false
        grenade_throw_reset_t = 0
    end
end)

------------------------------------------------------------
-- Cleanup: restore state on script reset
------------------------------------------------------------
re.on_script_reset(function()
    -- [SNAPPY_WEP] FSM-Tree-Edits zuruecknehmen (Tree ueberlebt Script-Reload)
    if snappy_applied then pcall(function() apply_snappy(true) end) end
    snappy_applied = false
    snappy_last_body = nil

    character_manager = nil
    assist_light_cache.body_addr = nil
    assist_light_cache.go = nil
    assist_light_cache.tf = nil
    knife_holster_state.force_frames = 0
    knife_holster_state.original_time_limit = nil
end)
